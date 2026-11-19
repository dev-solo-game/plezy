package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
)

func (s *SyncStore) resolveSourceIDDB(q sqlQuerier, userID, id string) string {
	visited := map[string]bool{}
	cur := id
	for {
		if visited[cur] {
			return cur
		}
		visited[cur] = true
		var next string
		err := q.QueryRow(`SELECT new_source_id FROM remapped_sources WHERE user_id = ? AND old_source_id = ?`, userID, cur).Scan(&next)
		if err != nil || next == "" || next == cur {
			return cur
		}
		cur = next
	}
}

func (s *SyncStore) resolveFileIDDB(q sqlQuerier, userID, id string) string {
	visited := map[string]bool{}
	cur := id
	for {
		if visited[cur] {
			return cur
		}
		visited[cur] = true
		var next string
		err := q.QueryRow(`SELECT new_file_id FROM remapped_files WHERE user_id = ? AND old_file_id = ?`, userID, cur).Scan(&next)
		if err != nil || next == "" || next == cur {
			return cur
		}
		cur = next
	}
}

func (s *SyncStore) Push(userID string, req PushRequest) (PushResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	ts := nowMs()
	tx, err := s.db.Begin()
	if err != nil {
		return PushResponse{}, err
	}
	defer func() { _ = tx.Rollback() }()

	accepted, remaps, err := s.applyMutationsTx(tx, userID, req.Mutations, ts, true)
	if err != nil {
		return PushResponse{}, err
	}
	if err := tx.Commit(); err != nil {
		return PushResponse{}, err
	}
	return PushResponse{
		Code:            0,
		ServerTimeMs:    ts,
		AcceptedOpIDs:   accepted,
		RemappedSources: remaps,
	}, nil
}

func (s *SyncStore) applyMutationsTx(
	tx *sql.Tx,
	userID string,
	mutations []PushMutation,
	ts int64,
	enforceQuota bool,
) ([]string, map[string]string, error) {
	var nextSeq int64
	if err := tx.QueryRow(`SELECT next_seq FROM users WHERE user_id = ?`, userID).Scan(&nextSeq); err != nil {
		return nil, nil, ErrUnauthorized
	}
	origNextSeq := nextSeq
	allocSeq := func() int64 {
		nextSeq++
		return nextSeq
	}

	var maxEntities int64
	var activeCount int64
	if enforceQuota {
		maxEntities = getConfigInt64Q(tx, "max_entities_per_user", 0)
		if maxEntities > 0 {
			activeCount = countActiveEntitiesTx(tx, userID)
		}
	}
	checkQuotaDelta := func(delta int64) error {
		if !enforceQuota || maxEntities <= 0 {
			return nil
		}
		activeCount += delta
		if delta > 0 && activeCount > maxEntities {
			return ErrQuotaExceeded
		}
		return nil
	}

	accepted := make([]string, 0, len(mutations))
	remaps := make(map[string]string)

	for _, mut := range mutations {
		if mut.OpID == "" {
			continue
		}
		var dup int
		if err := tx.QueryRow(`SELECT 1 FROM applied_ops WHERE user_id = ? AND op_id = ?`, userID, mut.OpID).Scan(&dup); err == nil {
			accepted = append(accepted, mut.OpID)
			continue
		}

		var seq int64
		var err error
		switch mut.EntityType {
		case "source":
			var src SyncSource
			if uerr := json.Unmarshal(mut.Payload, &src); uerr != nil {
				continue
			}
			seq, err = s.applySourceTx(tx, userID, &src, remaps, allocSeq, checkQuotaDelta)
		case "work":
			var work SyncWork
			if uerr := json.Unmarshal(mut.Payload, &work); uerr != nil {
				continue
			}
			seq, err = s.applyWorkTx(tx, userID, &work, allocSeq, checkQuotaDelta)
		case "file":
			var file SyncFile
			if uerr := json.Unmarshal(mut.Payload, &file); uerr != nil {
				continue
			}
			seq, err = s.applyFileTx(tx, userID, &file, allocSeq, checkQuotaDelta)
		case "work_pref":
			var pref SyncWorkPref
			if uerr := json.Unmarshal(mut.Payload, &pref); uerr != nil {
				continue
			}
			seq, err = s.applyWorkPrefTx(tx, userID, &pref, allocSeq)
		case "watch_progress":
			var prog SyncWatchProgress
			if uerr := json.Unmarshal(mut.Payload, &prog); uerr != nil {
				continue
			}
			seq, err = s.applyWatchProgressTx(tx, userID, &prog, allocSeq)
		case "list":
			var list SyncList
			if uerr := json.Unmarshal(mut.Payload, &list); uerr != nil {
				continue
			}
			seq, err = s.applyListTx(tx, userID, &list, allocSeq, checkQuotaDelta)
		default:
			continue
		}
		if err != nil {
			return nil, nil, err
		}

		if _, err := tx.Exec(
			`INSERT OR IGNORE INTO applied_ops(user_id, op_id, server_seq, created_at) VALUES (?, ?, ?, ?)`,
			userID, mut.OpID, seq, ts,
		); err != nil {
			return nil, nil, err
		}
		accepted = append(accepted, mut.OpID)
	}

	if nextSeq != origNextSeq {
		if _, err := tx.Exec(`UPDATE users SET next_seq = ?, updated_at = ? WHERE user_id = ?`, nextSeq, ts, userID); err != nil {
			return nil, nil, err
		}
	}
	if len(remaps) == 0 {
		return accepted, nil, nil
	}
	return accepted, remaps, nil
}

func countActiveEntitiesTx(tx *sql.Tx, userID string) int64 {
	var total, n int64
	for _, tbl := range []string{"sync_sources", "sync_works", "sync_files", "sync_lists"} {
		_ = tx.QueryRow(`SELECT COUNT(*) FROM `+tbl+` WHERE user_id = ? AND is_deleted = 0`, userID).Scan(&n)
		total += n
	}
	return total
}

func (s *SyncStore) applySourceTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncSource,
	batchRemaps map[string]string,
	allocSeq func() int64,
	checkQuota func(int64) error,
) (int64, error) {
	if incoming.IncludePaths == nil {
		incoming.IncludePaths = []string{}
	}
	if incoming.ExcludePaths == nil {
		incoming.ExcludePaths = []string{}
	}
	if incoming.ConfigJSON == nil {
		incoming.ConfigJSON = map[string]any{}
	}

	originalID := incoming.SourceID
	resolved := s.resolveSourceIDDB(tx, userID, incoming.SourceID)
	if resolved != incoming.SourceID {
		incoming.SourceID = resolved
		if originalID != resolved {
			batchRemaps[originalID] = resolved
		}
	}

	if !incoming.IsDeleted && incoming.CanonicalKey != "" {
		var winnerID string
		err := tx.QueryRow(`
			SELECT source_id FROM sync_sources
			WHERE user_id = ? AND canonical_key = ? AND is_deleted = 0 AND source_id != ?
			ORDER BY server_seq ASC LIMIT 1`,
			userID, incoming.CanonicalKey, incoming.SourceID,
		).Scan(&winnerID)
		if err == nil && winnerID != "" {
			_, _ = tx.Exec(`INSERT OR REPLACE INTO remapped_sources(user_id, old_source_id, new_source_id) VALUES (?, ?, ?)`,
				userID, originalID, winnerID)
			_, _ = tx.Exec(`INSERT OR REPLACE INTO remapped_sources(user_id, old_source_id, new_source_id) VALUES (?, ?, ?)`,
				userID, incoming.SourceID, winnerID)
			batchRemaps[originalID] = winnerID
			batchRemaps[incoming.SourceID] = winnerID
			incoming.SourceID = winnerID
		}
	}

	existing, err := loadSourceRow(tx, userID, incoming.SourceID)
	if errors.Is(err, sql.ErrNoRows) {
		if incoming.IsDeleted {
			return 0, nil
		}
		if err := checkQuota(1); err != nil {
			return 0, err
		}
		seq := allocSeq()
		copySrc := *incoming
		copySrc.ServerSeq = seq
		if err := insertSourceRow(tx, userID, &copySrc); err != nil {
			return 0, err
		}
		return seq, nil
	}
	if err != nil {
		return 0, err
	}

	if existing.IsDeleted && incoming.IsDeleted {
		return existing.ServerSeq, nil
	}

	if incoming.IsDeleted && !existing.IsDeleted {
		if incoming.ClientUpdatedAt >= existing.ClientUpdatedAt {
			seq := allocSeq()
			existing.IsDeleted = true
			existing.ClientUpdatedAt = incoming.ClientUpdatedAt
			existing.ServerSeq = seq
			if err := insertSourceRow(tx, userID, existing); err != nil {
				return 0, err
			}
			_ = checkQuota(-1)

			// Soft-delete active files under this deleted source so pulling devices stay clean.
			rows, err := tx.Query(`SELECT file_id FROM sync_files WHERE user_id = ? AND source_id = ? AND is_deleted = 0`, userID, existing.SourceID)
			if err != nil {
				return 0, err
			}
			var fileIDs []string
			for rows.Next() {
				var fid string
				if err := rows.Scan(&fid); err == nil {
					fileIDs = append(fileIDs, fid)
				}
			}
			rows.Close()
			for _, fid := range fileIDs {
				fseq := allocSeq()
				if _, err := tx.Exec(`
					UPDATE sync_files SET is_deleted = 1, client_updated_at = ?, server_seq = ?
					WHERE user_id = ? AND file_id = ?`,
					incoming.ClientUpdatedAt, fseq, userID, fid,
				); err != nil {
					return 0, err
				}
				_ = checkQuota(-1)
			}
			return seq, nil
		}
		return existing.ServerSeq, nil
	}

	resurrected := existing.IsDeleted != incoming.IsDeleted
	if resurrected && !incoming.IsDeleted {
		if err := checkQuota(1); err != nil {
			return 0, err
		}
	}
	mergedCp := mergeQuarkCheckpoint(existing.QuarkCheckpoint, incoming.QuarkCheckpoint)
	cpChanged := !strPtrEqual(mergedCp, existing.QuarkCheckpoint)
	if incoming.ScanFinishedAt > existing.ScanFinishedAt {
		existing.ScanFinishedAt = incoming.ScanFinishedAt
	}

	authChanged := false
	if incoming.EncryptedAuth != "" &&
		(incoming.ForceAuthOverride ||
			incoming.AuthUpdatedAt > existing.AuthUpdatedAt ||
			existing.EncryptedAuth == "") {
		existing.EncryptedAuth = incoming.EncryptedAuth
		if incoming.AuthUpdatedAt > existing.AuthUpdatedAt {
			existing.AuthUpdatedAt = incoming.AuthUpdatedAt
		}
		authChanged = true
	}

	metaChanged := false
	if incoming.ClientUpdatedAt >= existing.ClientUpdatedAt {
		if incoming.Name != existing.Name ||
			incoming.Protocol != existing.Protocol ||
			incoming.IsLanOnly != existing.IsLanOnly ||
			incoming.PrimaryURL != existing.PrimaryURL ||
			(incoming.FallbackURL != nil && !strPtrEqual(incoming.FallbackURL, existing.FallbackURL)) ||
			(len(incoming.ConfigJSON) > 0 && !jsonMapEqual(incoming.ConfigJSON, existing.ConfigJSON)) ||
			!strSliceEqual(incoming.IncludePaths, existing.IncludePaths) ||
			!strSliceEqual(incoming.ExcludePaths, existing.ExcludePaths) ||
			(incoming.CanonicalKey != "" && incoming.CanonicalKey != existing.CanonicalKey) {
			metaChanged = true
		}
		existing.Name = incoming.Name
		existing.Protocol = incoming.Protocol
		existing.IsLanOnly = incoming.IsLanOnly
		existing.PrimaryURL = incoming.PrimaryURL
		if incoming.FallbackURL != nil {
			existing.FallbackURL = incoming.FallbackURL
		}
		if len(incoming.ConfigJSON) > 0 {
			existing.ConfigJSON = incoming.ConfigJSON
		}
		existing.IncludePaths = incoming.IncludePaths
		existing.ExcludePaths = incoming.ExcludePaths
		if incoming.CanonicalKey != "" {
			existing.CanonicalKey = incoming.CanonicalKey
		}
		existing.ClientUpdatedAt = incoming.ClientUpdatedAt
	}

	existing.IsDeleted = incoming.IsDeleted
	existing.QuarkCheckpoint = mergedCp

	if !resurrected && !cpChanged && !authChanged && !metaChanged {
		return existing.ServerSeq, nil
	}
	seq := allocSeq()
	existing.ServerSeq = seq
	if err := insertSourceRow(tx, userID, existing); err != nil {
		return 0, err
	}
	return seq, nil
}

func (s *SyncStore) applyWorkTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncWork,
	allocSeq func() int64,
	checkQuota func(int64) error,
) (int64, error) {
	if incoming.MetadataJSON == nil {
		incoming.MetadataJSON = map[string]any{}
	}
	existing, err := loadWorkRow(tx, userID, incoming.WorkKey)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil {
		if !shouldOverrideEntity(
			incoming.IsDeleted,
			existing.IsDeleted,
			incoming.MatchStatus,
			existing.MatchStatus,
			incoming.ClientUpdatedAt,
			existing.ClientUpdatedAt,
			incoming.ExplicitUnlock,
		) || sameSyncWork(existing, incoming) {
			return existing.ServerSeq, nil
		}
		if existing.IsDeleted != incoming.IsDeleted {
			if err := checkQuota(boolDelta(!incoming.IsDeleted)); err != nil {
				return 0, err
			}
		}
	} else if incoming.IsDeleted {
		return 0, nil
	} else {
		if err := checkQuota(1); err != nil {
			return 0, err
		}
	}

	seq := allocSeq()
	copyWork := *incoming
	copyWork.ExplicitUnlock = false
	copyWork.ServerSeq = seq
	if err := insertWorkRow(tx, userID, &copyWork); err != nil {
		return 0, err
	}
	return seq, nil
}

func generateFileID(sourceID, relativePath string) string {
	sum := sha256.Sum256([]byte(sourceID + ":" + relativePath))
	return hex.EncodeToString(sum[:])[:32]
}

func (s *SyncStore) applyFileTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncFile,
	allocSeq func() int64,
	checkQuota func(int64) error,
) (int64, error) {
	if incoming.MediaSpecJSON == nil {
		incoming.MediaSpecJSON = map[string]any{}
	}
	resolvedSrc := s.resolveSourceIDDB(tx, userID, incoming.SourceID)
	if resolvedSrc != incoming.SourceID {
		oldFileID := incoming.FileID
		newFileID := generateFileID(resolvedSrc, incoming.RelativePath)
		incoming.SourceID = resolvedSrc
		incoming.FileID = newFileID
		if oldFileID != "" && oldFileID != newFileID {
			_, _ = tx.Exec(`INSERT OR REPLACE INTO remapped_files(user_id, old_file_id, new_file_id) VALUES (?, ?, ?)`,
				userID, oldFileID, newFileID)
		}
	}
	if incoming.OwnerFileID != nil && *incoming.OwnerFileID != "" {
		resolvedOwner := s.resolveFileIDDB(tx, userID, *incoming.OwnerFileID)
		incoming.OwnerFileID = &resolvedOwner
	}

	existing, err := loadFileRow(tx, userID, incoming.FileID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil {
		if !shouldOverrideEntity(
			incoming.IsDeleted,
			existing.IsDeleted,
			incoming.MatchStatus,
			existing.MatchStatus,
			incoming.ClientUpdatedAt,
			existing.ClientUpdatedAt,
			incoming.ExplicitUnlock,
		) || sameSyncFile(existing, incoming) {
			return existing.ServerSeq, nil
		}
		if existing.IsDeleted != incoming.IsDeleted {
			if err := checkQuota(boolDelta(!incoming.IsDeleted)); err != nil {
				return 0, err
			}
		}
	} else if incoming.IsDeleted {
		return 0, nil
	} else {
		if err := checkQuota(1); err != nil {
			return 0, err
		}
	}

	seq := allocSeq()
	copyFile := *incoming
	copyFile.ExplicitUnlock = false
	copyFile.ServerSeq = seq
	if err := insertFileRow(tx, userID, &copyFile); err != nil {
		return 0, err
	}
	return seq, nil
}

func (s *SyncStore) applyWorkPrefTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncWorkPref,
	allocSeq func() int64,
) (int64, error) {
	existing, err := loadWorkPrefRow(tx, userID, incoming.WorkKey)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil {
		if incoming.ClientUpdatedAt < existing.ClientUpdatedAt || sameSyncWorkPref(existing, incoming) {
			return existing.ServerSeq, nil
		}
	}
	seq := allocSeq()
	copyPref := *incoming
	copyPref.ServerSeq = seq
	if err := insertWorkPrefRow(tx, userID, &copyPref); err != nil {
		return 0, err
	}
	return seq, nil
}

func incomingProgressWinsTie(incoming, existing *SyncWatchProgress) bool {
	if incoming.Watched != existing.Watched {
		return incoming.Watched
	}
	if incoming.PositionMs != existing.PositionMs {
		return incoming.PositionMs > existing.PositionMs
	}
	if incoming.PlayCount != existing.PlayCount {
		return incoming.PlayCount > existing.PlayCount
	}
	return incoming.DurationMs > existing.DurationMs
}

func (s *SyncStore) applyWatchProgressTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncWatchProgress,
	allocSeq func() int64,
) (int64, error) {
	if incoming.EpisodeExtJSON == nil {
		incoming.EpisodeExtJSON = map[string]any{}
	}
	if incoming.LastFileID != nil && *incoming.LastFileID != "" {
		resolved := s.resolveFileIDDB(tx, userID, *incoming.LastFileID)
		incoming.LastFileID = &resolved
	}
	existing, err := loadWatchProgressRow(tx, userID, incoming.ProgressKey)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil {
		if incoming.ClientUpdatedAt < existing.ClientUpdatedAt || sameSyncWatchProgress(existing, incoming) {
			return existing.ServerSeq, nil
		}
		if incoming.ClientUpdatedAt == existing.ClientUpdatedAt && !incomingProgressWinsTie(incoming, existing) {
			return existing.ServerSeq, nil
		}
	}
	seq := allocSeq()
	copyProg := *incoming
	copyProg.ServerSeq = seq
	if err := insertWatchProgressRow(tx, userID, &copyProg); err != nil {
		return 0, err
	}
	return seq, nil
}

func (s *SyncStore) applyListTx(
	tx *sql.Tx,
	userID string,
	incoming *SyncList,
	allocSeq func() int64,
	checkQuota func(int64) error,
) (int64, error) {
	if incoming.ItemWorkKeys == nil {
		incoming.ItemWorkKeys = []string{}
	}
	existing, err := loadListRow(tx, userID, incoming.ListKey)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil {
		if incoming.ClientUpdatedAt < existing.ClientUpdatedAt || sameSyncList(existing, incoming) {
			return existing.ServerSeq, nil
		}
		if existing.IsDeleted != incoming.IsDeleted {
			if err := checkQuota(boolDelta(!incoming.IsDeleted)); err != nil {
				return 0, err
			}
		}
	} else if incoming.IsDeleted {
		return 0, nil
	} else {
		if err := checkQuota(1); err != nil {
			return 0, err
		}
	}

	seq := allocSeq()
	copyList := *incoming
	copyList.ServerSeq = seq
	if err := insertListRow(tx, userID, &copyList); err != nil {
		return 0, err
	}
	return seq, nil
}

func boolDelta(becameActive bool) int64 {
	if becameActive {
		return 1
	}
	return -1
}

type deltaEnvelope struct {
	seq  int64
	kind string
	item any
}

func (s *SyncStore) Pull(user *UserRecord, sinceSeq int64, limit int) PullResponse {
	return s.PullWithOptions(user, sinceSeq, limit, sinceSeq == 0)
}

func (s *SyncStore) PullWithOptions(user *UserRecord, sinceSeq int64, limit int, activeOnly bool) PullResponse {
	if limit <= 0 {
		limit = 500
	}
	if limit > 5000 {
		limit = 5000
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	ts := nowMs()
	freshUser, nextSeqMax, minRetainedSeq, err := s.loadUserByID(user.UserID)
	settings := user.Settings
	if err == nil {
		settings = freshUser.Settings
	}

	if sinceSeq > 0 && sinceSeq < minRetainedSeq {
		return PullResponse{
			Code:          0,
			ServerTimeMs:  ts,
			CurrentMaxSeq: nextSeqMax,
			NextSeq:       0,
			ResetRequired: true,
			UserSettings:  settings,
			Data: PullData{
				Sources:       []SyncSource{},
				Works:         []SyncWork{},
				Files:         []SyncFile{},
				WorkPrefs:     []SyncWorkPref{},
				WatchProgress: []SyncWatchProgress{},
				Lists:         []SyncList{},
			},
		}
	}

	queryLimit := limit + 1
	deltas := make([]deltaEnvelope, 0)

	if sources, err := querySourcesSince(s.db, user.UserID, sinceSeq, queryLimit, activeOnly); err == nil {
		for _, src := range sources {
			deltas = append(deltas, deltaEnvelope{seq: src.ServerSeq, kind: "source", item: src})
		}
	}
	if works, err := queryWorksSince(s.db, user.UserID, sinceSeq, queryLimit, activeOnly); err == nil {
		for _, w := range works {
			deltas = append(deltas, deltaEnvelope{seq: w.ServerSeq, kind: "work", item: w})
		}
	}
	if files, err := queryFilesSince(s.db, user.UserID, sinceSeq, queryLimit, activeOnly); err == nil {
		for _, f := range files {
			deltas = append(deltas, deltaEnvelope{seq: f.ServerSeq, kind: "file", item: f})
		}
	}
	if prefs, err := queryWorkPrefsSince(s.db, user.UserID, sinceSeq, queryLimit); err == nil {
		for _, p := range prefs {
			deltas = append(deltas, deltaEnvelope{seq: p.ServerSeq, kind: "work_pref", item: p})
		}
	}
	if progs, err := queryWatchProgressSince(s.db, user.UserID, sinceSeq, queryLimit); err == nil {
		for _, g := range progs {
			deltas = append(deltas, deltaEnvelope{seq: g.ServerSeq, kind: "watch_progress", item: g})
		}
	}
	if lists, err := queryListsSince(s.db, user.UserID, sinceSeq, queryLimit, activeOnly); err == nil {
		for _, l := range lists {
			deltas = append(deltas, deltaEnvelope{seq: l.ServerSeq, kind: "list", item: l})
		}
	}

	sort.Slice(deltas, func(i, j int) bool {
		return deltas[i].seq < deltas[j].seq
	})

	hasMore := len(deltas) > limit
	if hasMore {
		deltas = deltas[:limit]
	}

	nextSeq := sinceSeq
	if len(deltas) > 0 {
		nextSeq = deltas[len(deltas)-1].seq
	}
	if !hasMore && activeOnly && nextSeqMax > nextSeq {
		nextSeq = nextSeqMax
	}

	out := PullData{
		Sources:       []SyncSource{},
		Works:         []SyncWork{},
		Files:         []SyncFile{},
		WorkPrefs:     []SyncWorkPref{},
		WatchProgress: []SyncWatchProgress{},
		Lists:         []SyncList{},
	}
	for _, d := range deltas {
		switch d.kind {
		case "source":
			out.Sources = append(out.Sources, d.item.(SyncSource))
		case "work":
			out.Works = append(out.Works, d.item.(SyncWork))
		case "file":
			out.Files = append(out.Files, d.item.(SyncFile))
		case "work_pref":
			out.WorkPrefs = append(out.WorkPrefs, d.item.(SyncWorkPref))
		case "watch_progress":
			out.WatchProgress = append(out.WatchProgress, d.item.(SyncWatchProgress))
		case "list":
			out.Lists = append(out.Lists, d.item.(SyncList))
		}
	}

	if len(out.Files) > 0 {
		seenSourceIDs := make(map[string]struct{}, len(out.Sources))
		for _, src := range out.Sources {
			seenSourceIDs[src.SourceID] = struct{}{}
		}
		for _, f := range out.Files {
			if f.IsDeleted || f.SourceID == "" {
				continue
			}
			if _, ok := seenSourceIDs[f.SourceID]; ok {
				continue
			}
			seenSourceIDs[f.SourceID] = struct{}{}
			src, err := loadSourceRow(s.db, user.UserID, f.SourceID)
			if err == nil && !src.IsDeleted && src.ServerSeq > nextSeq {
				out.Sources = append(out.Sources, *src)
			}
		}
	}

	return PullResponse{
		Code:          0,
		ServerTimeMs:  ts,
		CurrentMaxSeq: nextSeqMax,
		NextSeq:       nextSeq,
		HasMore:       hasMore,
		ResetRequired: false,
		UserSettings:  settings,
		Data:          out,
	}
}

type sqlExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

func insertSourceRow(ex sqlExecer, userID string, src *SyncSource) error {
	cfgJSON, _ := json.Marshal(nonNilMap(src.ConfigJSON))
	incJSON, _ := json.Marshal(nonNilStrings(src.IncludePaths))
	excJSON, _ := json.Marshal(nonNilStrings(src.ExcludePaths))
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_sources (
			user_id, source_id, canonical_key, name, protocol, is_lan_only, primary_url, fallback_url,
			config_json, include_paths_json, exclude_paths_json, encrypted_auth, auth_updated_at,
			quark_checkpoint, scan_finished_at, scan_lease_owner, scan_lease_until,
			client_updated_at, is_deleted, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, src.SourceID, src.CanonicalKey, src.Name, src.Protocol, boolToInt(src.IsLanOnly),
		src.PrimaryURL, nullStrPtr(src.FallbackURL), string(cfgJSON), string(incJSON), string(excJSON),
		src.EncryptedAuth, src.AuthUpdatedAt, nullStrPtr(src.QuarkCheckpoint), src.ScanFinishedAt,
		nullStrPtr(src.ScanLeaseOwner), src.ScanLeaseUntil, src.ClientUpdatedAt, boolToInt(src.IsDeleted), src.ServerSeq,
	)
	return err
}

func loadSourceRow(q sqlQuerier, userID, sourceID string) (*SyncSource, error) {
	row := q.QueryRow(`
		SELECT source_id, canonical_key, name, protocol, is_lan_only, primary_url, fallback_url,
		       config_json, include_paths_json, exclude_paths_json, encrypted_auth, auth_updated_at,
		       quark_checkpoint, scan_finished_at, scan_lease_owner, scan_lease_until,
		       client_updated_at, is_deleted, server_seq
		FROM sync_sources WHERE user_id = ? AND source_id = ?`, userID, sourceID)
	return scanSourceRow(row)
}

func scanSourceRow(s interface{ Scan(...any) error }) (*SyncSource, error) {
	var out SyncSource
	var isLanOnly, isDeleted int
	var fallbackURL, quarkCp, leaseOwner sql.NullString
	var cfgJSON, incJSON, excJSON string
	if err := s.Scan(
		&out.SourceID, &out.CanonicalKey, &out.Name, &out.Protocol, &isLanOnly, &out.PrimaryURL, &fallbackURL,
		&cfgJSON, &incJSON, &excJSON, &out.EncryptedAuth, &out.AuthUpdatedAt,
		&quarkCp, &out.ScanFinishedAt, &leaseOwner, &out.ScanLeaseUntil,
		&out.ClientUpdatedAt, &isDeleted, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.IsLanOnly = isLanOnly == 1
	out.IsDeleted = isDeleted == 1
	out.FallbackURL = nullToPtr(fallbackURL)
	out.QuarkCheckpoint = nullToPtr(quarkCp)
	out.ScanLeaseOwner = nullToPtr(leaseOwner)
	out.ConfigJSON = map[string]any{}
	_ = json.Unmarshal([]byte(cfgJSON), &out.ConfigJSON)
	out.IncludePaths = []string{}
	_ = json.Unmarshal([]byte(incJSON), &out.IncludePaths)
	out.ExcludePaths = []string{}
	_ = json.Unmarshal([]byte(excJSON), &out.ExcludePaths)
	return &out, nil
}

func querySourcesSince(db *sql.DB, userID string, sinceSeq int64, limit int, activeOnly bool) ([]SyncSource, error) {
	filter := ""
	if activeOnly {
		filter = " AND is_deleted = 0"
	}
	rows, err := db.Query(`
		SELECT source_id, canonical_key, name, protocol, is_lan_only, primary_url, fallback_url,
		       config_json, include_paths_json, exclude_paths_json, encrypted_auth, auth_updated_at,
		       quark_checkpoint, scan_finished_at, scan_lease_owner, scan_lease_until,
		       client_updated_at, is_deleted, server_seq
		FROM sync_sources WHERE user_id = ? AND server_seq > ?`+filter+` ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncSource
	for rows.Next() {
		item, err := scanSourceRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func insertWorkRow(ex sqlExecer, userID string, w *SyncWork) error {
	metaJSON, _ := json.Marshal(nonNilMap(w.MetadataJSON))
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_works (
			user_id, work_key, kind, library_type, provider, external_id,
			match_status, metadata_json, client_updated_at, is_deleted, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, w.WorkKey, w.Kind, w.LibraryType, nullStrPtr(w.Provider), nullStrPtr(w.ExternalID),
		w.MatchStatus, string(metaJSON), w.ClientUpdatedAt, boolToInt(w.IsDeleted), w.ServerSeq,
	)
	return err
}

func loadWorkRow(q sqlQuerier, userID, workKey string) (*SyncWork, error) {
	row := q.QueryRow(`
		SELECT work_key, kind, library_type, provider, external_id,
		       match_status, metadata_json, client_updated_at, is_deleted, server_seq
		FROM sync_works WHERE user_id = ? AND work_key = ?`, userID, workKey)
	return scanWorkRow(row)
}

func scanWorkRow(s interface{ Scan(...any) error }) (*SyncWork, error) {
	var out SyncWork
	var provider, externalID sql.NullString
	var metaJSON string
	var isDeleted int
	if err := s.Scan(
		&out.WorkKey, &out.Kind, &out.LibraryType, &provider, &externalID,
		&out.MatchStatus, &metaJSON, &out.ClientUpdatedAt, &isDeleted, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.Provider = nullToPtr(provider)
	out.ExternalID = nullToPtr(externalID)
	out.IsDeleted = isDeleted == 1
	out.MetadataJSON = map[string]any{}
	_ = json.Unmarshal([]byte(metaJSON), &out.MetadataJSON)
	return &out, nil
}

func queryWorksSince(db *sql.DB, userID string, sinceSeq int64, limit int, activeOnly bool) ([]SyncWork, error) {
	filter := ""
	if activeOnly {
		filter = " AND is_deleted = 0"
	}
	rows, err := db.Query(`
		SELECT work_key, kind, library_type, provider, external_id,
		       match_status, metadata_json, client_updated_at, is_deleted, server_seq
		FROM sync_works WHERE user_id = ? AND server_seq > ?`+filter+` ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncWork
	for rows.Next() {
		item, err := scanWorkRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func insertFileRow(ex sqlExecer, userID string, f *SyncFile) error {
	specJSON, _ := json.Marshal(nonNilMap(f.MediaSpecJSON))
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_files (
			user_id, file_id, source_id, relative_path, remote_id, role, owner_file_id, language,
			file_name, file_size, file_mtime, file_created_at, work_key, season_num, episode_num,
			episode_end_num, match_status, version_label, parsed_json, media_spec_json,
			client_updated_at, is_deleted, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, f.FileID, f.SourceID, f.RelativePath, nullStrPtr(f.RemoteID), f.Role, nullStrPtr(f.OwnerFileID), nullStrPtr(f.Language),
		f.FileName, f.FileSize, f.FileMtime, f.FileCreatedAt, nullStrPtr(f.WorkKey), f.SeasonNum, f.EpisodeNum,
		nullIntPtr(f.EpisodeEndNum), f.MatchStatus, nullStrPtr(f.VersionLabel), nullStrPtr(f.ParsedJSON), string(specJSON),
		f.ClientUpdatedAt, boolToInt(f.IsDeleted), f.ServerSeq,
	)
	return err
}

func loadFileRow(q sqlQuerier, userID, fileID string) (*SyncFile, error) {
	row := q.QueryRow(`
		SELECT file_id, source_id, relative_path, remote_id, role, owner_file_id, language,
		       file_name, file_size, file_mtime, file_created_at, work_key, season_num, episode_num,
		       episode_end_num, match_status, version_label, parsed_json, media_spec_json,
		       client_updated_at, is_deleted, server_seq
		FROM sync_files WHERE user_id = ? AND file_id = ?`, userID, fileID)
	return scanFileRow(row)
}

func scanFileRow(s interface{ Scan(...any) error }) (*SyncFile, error) {
	var out SyncFile
	var remoteID, ownerFileID, language, workKey, versionLabel, parsedJSON sql.NullString
	var episodeEndNum sql.NullInt64
	var specJSON string
	var isDeleted int
	if err := s.Scan(
		&out.FileID, &out.SourceID, &out.RelativePath, &remoteID, &out.Role, &ownerFileID, &language,
		&out.FileName, &out.FileSize, &out.FileMtime, &out.FileCreatedAt, &workKey, &out.SeasonNum, &out.EpisodeNum,
		&episodeEndNum, &out.MatchStatus, &versionLabel, &parsedJSON, &specJSON,
		&out.ClientUpdatedAt, &isDeleted, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.RemoteID = nullToPtr(remoteID)
	out.OwnerFileID = nullToPtr(ownerFileID)
	out.Language = nullToPtr(language)
	out.WorkKey = nullToPtr(workKey)
	out.VersionLabel = nullToPtr(versionLabel)
	out.ParsedJSON = nullToPtr(parsedJSON)
	if episodeEndNum.Valid {
		v := int(episodeEndNum.Int64)
		out.EpisodeEndNum = &v
	}
	out.IsDeleted = isDeleted == 1
	out.MediaSpecJSON = map[string]any{}
	_ = json.Unmarshal([]byte(specJSON), &out.MediaSpecJSON)
	return &out, nil
}

func queryFilesSince(db *sql.DB, userID string, sinceSeq int64, limit int, activeOnly bool) ([]SyncFile, error) {
	filter := ""
	if activeOnly {
		filter = " AND is_deleted = 0"
	}
	rows, err := db.Query(`
		SELECT file_id, source_id, relative_path, remote_id, role, owner_file_id, language,
		       file_name, file_size, file_mtime, file_created_at, work_key, season_num, episode_num,
		       episode_end_num, match_status, version_label, parsed_json, media_spec_json,
		       client_updated_at, is_deleted, server_seq
		FROM sync_files WHERE user_id = ? AND server_seq > ?`+filter+` ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncFile
	for rows.Next() {
		item, err := scanFileRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func insertWorkPrefRow(ex sqlExecer, userID string, p *SyncWorkPref) error {
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_work_prefs (
			user_id, work_key, intro_enabled, intro_start_ms, intro_end_ms,
			credits_enabled, credits_from_end_ms, keep_easter_egg_ms,
			preferred_audio_lang, preferred_sub_lang, playback_speed, danmaku_offset_ms,
			is_favorite, hidden_from_continue, client_updated_at, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, p.WorkKey, boolToInt(p.IntroEnabled), p.IntroStartMs, p.IntroEndMs,
		boolToInt(p.CreditsEnabled), p.CreditsFromEndMs, p.KeepEasterEggMs,
		nullStrPtr(p.PreferredAudioLang), nullStrPtr(p.PreferredSubLang), p.PlaybackSpeed, p.DanmakuOffsetMs,
		boolToInt(p.IsFavorite), boolToInt(p.HiddenFromContinue), p.ClientUpdatedAt, p.ServerSeq,
	)
	return err
}

func loadWorkPrefRow(q sqlQuerier, userID, workKey string) (*SyncWorkPref, error) {
	row := q.QueryRow(`
		SELECT work_key, intro_enabled, intro_start_ms, intro_end_ms,
		       credits_enabled, credits_from_end_ms, keep_easter_egg_ms,
		       preferred_audio_lang, preferred_sub_lang, playback_speed, danmaku_offset_ms,
		       is_favorite, hidden_from_continue, client_updated_at, server_seq
		FROM sync_work_prefs WHERE user_id = ? AND work_key = ?`, userID, workKey)
	return scanWorkPrefRow(row)
}

func scanWorkPrefRow(s interface{ Scan(...any) error }) (*SyncWorkPref, error) {
	var out SyncWorkPref
	var introEn, creditsEn, fav, hidden int
	var audioLang, subLang sql.NullString
	if err := s.Scan(
		&out.WorkKey, &introEn, &out.IntroStartMs, &out.IntroEndMs,
		&creditsEn, &out.CreditsFromEndMs, &out.KeepEasterEggMs,
		&audioLang, &subLang, &out.PlaybackSpeed, &out.DanmakuOffsetMs,
		&fav, &hidden, &out.ClientUpdatedAt, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.IntroEnabled = introEn == 1
	out.CreditsEnabled = creditsEn == 1
	out.IsFavorite = fav == 1
	out.HiddenFromContinue = hidden == 1
	out.PreferredAudioLang = nullToPtr(audioLang)
	out.PreferredSubLang = nullToPtr(subLang)
	return &out, nil
}

func queryWorkPrefsSince(db *sql.DB, userID string, sinceSeq int64, limit int) ([]SyncWorkPref, error) {
	rows, err := db.Query(`
		SELECT work_key, intro_enabled, intro_start_ms, intro_end_ms,
		       credits_enabled, credits_from_end_ms, keep_easter_egg_ms,
		       preferred_audio_lang, preferred_sub_lang, playback_speed, danmaku_offset_ms,
		       is_favorite, hidden_from_continue, client_updated_at, server_seq
		FROM sync_work_prefs WHERE user_id = ? AND server_seq > ? ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncWorkPref
	for rows.Next() {
		item, err := scanWorkPrefRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func insertWatchProgressRow(ex sqlExecer, userID string, g *SyncWatchProgress) error {
	extJSON, _ := json.Marshal(nonNilMap(g.EpisodeExtJSON))
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_watch_progress (
			user_id, progress_key, work_key, season_num, episode_num, last_file_id,
			position_ms, duration_ms, watched, play_count, last_played_at,
			episode_ext_json, client_updated_at, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, g.ProgressKey, g.WorkKey, g.SeasonNum, g.EpisodeNum, nullStrPtr(g.LastFileID),
		g.PositionMs, g.DurationMs, boolToInt(g.Watched), g.PlayCount, nullInt64Ptr(g.LastPlayedAt),
		string(extJSON), g.ClientUpdatedAt, g.ServerSeq,
	)
	return err
}

func loadWatchProgressRow(q sqlQuerier, userID, progressKey string) (*SyncWatchProgress, error) {
	row := q.QueryRow(`
		SELECT progress_key, work_key, season_num, episode_num, last_file_id,
		       position_ms, duration_ms, watched, play_count, last_played_at,
		       episode_ext_json, client_updated_at, server_seq
		FROM sync_watch_progress WHERE user_id = ? AND progress_key = ?`, userID, progressKey)
	return scanWatchProgressRow(row)
}

func scanWatchProgressRow(s interface{ Scan(...any) error }) (*SyncWatchProgress, error) {
	var out SyncWatchProgress
	var lastFileID sql.NullString
	var lastPlayedAt sql.NullInt64
	var watched int
	var extJSON string
	if err := s.Scan(
		&out.ProgressKey, &out.WorkKey, &out.SeasonNum, &out.EpisodeNum, &lastFileID,
		&out.PositionMs, &out.DurationMs, &watched, &out.PlayCount, &lastPlayedAt,
		&extJSON, &out.ClientUpdatedAt, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.LastFileID = nullToPtr(lastFileID)
	if lastPlayedAt.Valid {
		v := lastPlayedAt.Int64
		out.LastPlayedAt = &v
	}
	out.Watched = watched == 1
	out.EpisodeExtJSON = map[string]any{}
	_ = json.Unmarshal([]byte(extJSON), &out.EpisodeExtJSON)
	return &out, nil
}

func queryWatchProgressSince(db *sql.DB, userID string, sinceSeq int64, limit int) ([]SyncWatchProgress, error) {
	rows, err := db.Query(`
		SELECT progress_key, work_key, season_num, episode_num, last_file_id,
		       position_ms, duration_ms, watched, play_count, last_played_at,
		       episode_ext_json, client_updated_at, server_seq
		FROM sync_watch_progress WHERE user_id = ? AND server_seq > ? ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncWatchProgress
	for rows.Next() {
		item, err := scanWatchProgressRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func insertListRow(ex sqlExecer, userID string, l *SyncList) error {
	keysJSON, _ := json.Marshal(nonNilStrings(l.ItemWorkKeys))
	_, err := ex.Exec(`
		INSERT OR REPLACE INTO sync_lists (
			user_id, list_key, kind, title, summary, poster_path, tmdb_id,
			item_work_keys_json, client_updated_at, is_deleted, server_seq
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, l.ListKey, l.Kind, l.Title, nullStrPtr(l.Summary), nullStrPtr(l.PosterPath), nullStrPtr(l.TmdbID),
		string(keysJSON), l.ClientUpdatedAt, boolToInt(l.IsDeleted), l.ServerSeq,
	)
	return err
}

func loadListRow(q sqlQuerier, userID, listKey string) (*SyncList, error) {
	row := q.QueryRow(`
		SELECT list_key, kind, title, summary, poster_path, tmdb_id,
		       item_work_keys_json, client_updated_at, is_deleted, server_seq
		FROM sync_lists WHERE user_id = ? AND list_key = ?`, userID, listKey)
	return scanListRow(row)
}

func scanListRow(s interface{ Scan(...any) error }) (*SyncList, error) {
	var out SyncList
	var summary, posterPath, tmdbID sql.NullString
	var keysJSON string
	var isDeleted int
	if err := s.Scan(
		&out.ListKey, &out.Kind, &out.Title, &summary, &posterPath, &tmdbID,
		&keysJSON, &out.ClientUpdatedAt, &isDeleted, &out.ServerSeq,
	); err != nil {
		return nil, err
	}
	out.Summary = nullToPtr(summary)
	out.PosterPath = nullToPtr(posterPath)
	out.TmdbID = nullToPtr(tmdbID)
	out.IsDeleted = isDeleted == 1
	out.ItemWorkKeys = []string{}
	_ = json.Unmarshal([]byte(keysJSON), &out.ItemWorkKeys)
	return &out, nil
}

func queryListsSince(db *sql.DB, userID string, sinceSeq int64, limit int, activeOnly bool) ([]SyncList, error) {
	filter := ""
	if activeOnly {
		filter = " AND is_deleted = 0"
	}
	rows, err := db.Query(`
		SELECT list_key, kind, title, summary, poster_path, tmdb_id,
		       item_work_keys_json, client_updated_at, is_deleted, server_seq
		FROM sync_lists WHERE user_id = ? AND server_seq > ?`+filter+` ORDER BY server_seq ASC LIMIT ?`,
		userID, sinceSeq, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncList
	for rows.Next() {
		item, err := scanListRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}

func nonNilStrings(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func nullStrPtr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullIntPtr(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullInt64Ptr(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullToPtr(ns sql.NullString) *string {
	if !ns.Valid {
		return nil
	}
	v := ns.String
	return &v
}

func strPtrEqual(a, b *string) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func intPtrEqual(a, b *int) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func int64PtrEqual(a, b *int64) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func strSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func jsonMapEqual(a, b map[string]any) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	ba, errA := json.Marshal(a)
	bb, errB := json.Marshal(b)
	if errA != nil || errB != nil {
		return false
	}
	return bytes.Equal(ba, bb)
}

func sameSyncWork(a, b *SyncWork) bool {
	return a.Kind == b.Kind &&
		a.LibraryType == b.LibraryType &&
		strPtrEqual(a.Provider, b.Provider) &&
		strPtrEqual(a.ExternalID, b.ExternalID) &&
		a.MatchStatus == b.MatchStatus &&
		a.IsDeleted == b.IsDeleted &&
		jsonMapEqual(a.MetadataJSON, b.MetadataJSON)
}

func sameSyncFile(a, b *SyncFile) bool {
	return a.SourceID == b.SourceID &&
		a.RelativePath == b.RelativePath &&
		strPtrEqual(a.RemoteID, b.RemoteID) &&
		a.Role == b.Role &&
		strPtrEqual(a.OwnerFileID, b.OwnerFileID) &&
		strPtrEqual(a.Language, b.Language) &&
		a.FileName == b.FileName &&
		a.FileSize == b.FileSize &&
		a.FileMtime == b.FileMtime &&
		a.FileCreatedAt == b.FileCreatedAt &&
		strPtrEqual(a.WorkKey, b.WorkKey) &&
		a.SeasonNum == b.SeasonNum &&
		a.EpisodeNum == b.EpisodeNum &&
		intPtrEqual(a.EpisodeEndNum, b.EpisodeEndNum) &&
		a.MatchStatus == b.MatchStatus &&
		strPtrEqual(a.VersionLabel, b.VersionLabel) &&
		strPtrEqual(a.ParsedJSON, b.ParsedJSON) &&
		a.IsDeleted == b.IsDeleted &&
		jsonMapEqual(a.MediaSpecJSON, b.MediaSpecJSON)
}

func sameSyncWorkPref(a, b *SyncWorkPref) bool {
	return a.WorkKey == b.WorkKey &&
		a.IntroEnabled == b.IntroEnabled &&
		a.IntroStartMs == b.IntroStartMs &&
		a.IntroEndMs == b.IntroEndMs &&
		a.CreditsEnabled == b.CreditsEnabled &&
		a.CreditsFromEndMs == b.CreditsFromEndMs &&
		a.KeepEasterEggMs == b.KeepEasterEggMs &&
		strPtrEqual(a.PreferredAudioLang, b.PreferredAudioLang) &&
		strPtrEqual(a.PreferredSubLang, b.PreferredSubLang) &&
		a.PlaybackSpeed == b.PlaybackSpeed &&
		a.DanmakuOffsetMs == b.DanmakuOffsetMs &&
		a.IsFavorite == b.IsFavorite &&
		a.HiddenFromContinue == b.HiddenFromContinue
}

func sameSyncWatchProgress(a, b *SyncWatchProgress) bool {
	return a.ProgressKey == b.ProgressKey &&
		a.WorkKey == b.WorkKey &&
		a.SeasonNum == b.SeasonNum &&
		a.EpisodeNum == b.EpisodeNum &&
		strPtrEqual(a.LastFileID, b.LastFileID) &&
		a.PositionMs == b.PositionMs &&
		a.DurationMs == b.DurationMs &&
		a.Watched == b.Watched &&
		a.PlayCount == b.PlayCount &&
		int64PtrEqual(a.LastPlayedAt, b.LastPlayedAt) &&
		jsonMapEqual(a.EpisodeExtJSON, b.EpisodeExtJSON)
}

func sameSyncList(a, b *SyncList) bool {
	return a.ListKey == b.ListKey &&
		a.Kind == b.Kind &&
		a.Title == b.Title &&
		strPtrEqual(a.Summary, b.Summary) &&
		strPtrEqual(a.PosterPath, b.PosterPath) &&
		strPtrEqual(a.TmdbID, b.TmdbID) &&
		a.IsDeleted == b.IsDeleted &&
		strSliceEqual(a.ItemWorkKeys, b.ItemWorkKeys)
}

func shouldOverrideEntity(remoteDeleted, localDeleted bool, remoteMatch, localMatch int, remoteUpdated, localUpdated int64, explicitUnlock bool) bool {
	if remoteDeleted != localDeleted {
		return remoteUpdated >= localUpdated
	}
	if explicitUnlock {
		return remoteUpdated >= localUpdated
	}
	if remoteMatch != localMatch {
		return remoteMatch > localMatch
	}
	return remoteUpdated >= localUpdated
}

func mergeQuarkCheckpoint(local, remote *string) *string {
	var cleanLocal, cleanRemote string
	if local != nil {
		cleanLocal = strings.TrimSpace(*local)
	}
	if remote != nil {
		cleanRemote = strings.TrimSpace(*remote)
	}
	if cleanLocal == "" {
		if cleanRemote == "" {
			return nil
		}
		return &cleanRemote
	}
	if cleanRemote == "" {
		return &cleanLocal
	}
	localSep := strings.IndexByte(cleanLocal, ':')
	remoteSep := strings.IndexByte(cleanRemote, ':')
	if localSep <= 0 || remoteSep <= 0 {
		return &cleanRemote
	}
	localRoot := cleanLocal[:localSep]
	remoteRoot := cleanRemote[:remoteSep]
	if localRoot != remoteRoot {
		return &cleanRemote
	}
	localW, errL := strconv.ParseInt(cleanLocal[localSep+1:], 10, 64)
	remoteW, errR := strconv.ParseInt(cleanRemote[remoteSep+1:], 10, 64)
	if errL != nil {
		return &cleanRemote
	}
	if errR != nil {
		return &cleanLocal
	}
	if localW >= remoteW {
		return &cleanLocal
	}
	return &cleanRemote
}
