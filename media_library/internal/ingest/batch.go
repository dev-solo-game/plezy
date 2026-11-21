package ingest

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/pathutil"
)

type existingFileRow struct {
	ID            int64
	Path          string
	RemoteID      sql.NullString
	Role          string
	ItemID        sql.NullInt64
	OwnerFileID   sql.NullInt64
	Size          sql.NullInt64
	MtimeS        sql.NullInt64
	SidecarSHA256 sql.NullString
	State         string
	MatchState    string
	MatchLocked   int
	ProbedAt      sql.NullInt64
	LastSeenAt    int64
}

func (s *Service) SubmitBatch(p *account.Principal, sessionID string, req SubmitBatchRequest, ip string) (*BatchReceipt, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) {
		return nil, ErrForbidden
	}
	if req.BatchNo < 1 {
		return nil, fmt.Errorf("%w: batch_no must be >= 1", ErrInvalidInput)
	}
	if len(req.Upserts)+len(req.Removed) > MaxItemsPerBatch {
		return nil, fmt.Errorf("%w: batch item count exceeds limit %d", ErrInvalidInput, MaxItemsPerBatch)
	}

	if !s.limiter.AllowWindow("ingest_batch:"+p.HouseholdID, BatchRateLimitPerMin, time.Minute) {
		return nil, &QuotaExceededError{Quota: "ingest_batches_per_min", Limit: BatchRateLimitPerMin}
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	sv, err := s.loadSessionForDevice(tx, p, sessionID)
	if err != nil {
		return nil, err
	}

	// Idempotent replay check before running state checks so already-committed batches replay cleanly.
	var storedJSON string
	err = tx.QueryRow(`
		SELECT response_json FROM ingest_batches WHERE session_id = ? AND batch_no = ?`,
		sv.ID, req.BatchNo,
	).Scan(&storedJSON)
	if err == nil {
		var receipt BatchReceipt
		if uErr := json.Unmarshal([]byte(storedJSON), &receipt); uErr == nil {
			if receipt.FileIDs == nil {
				receipt.FileIDs = make(map[string]int64)
			}
			if receipt.MissingSidecars == nil {
				receipt.MissingSidecars = []string{}
			}
			return &receipt, nil
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	if sv.Status != SessionRunning {
		return nil, ErrSessionNotRunning
	}

	scopes, err := loadScopedFolders(tx, p.HouseholdID, sv.SourceID, sv.FolderID)
	if err != nil {
		return nil, err
	}

	var maxFiles, curFiles int
	if err := tx.QueryRow(`SELECT quota_max_files FROM households WHERE id = ?`, p.HouseholdID).Scan(&maxFiles); err != nil {
		return nil, err
	}
	if err := tx.QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = ? AND state != 'tombstoned'`, p.HouseholdID).Scan(&curFiles); err != nil {
		return nil, err
	}

	receipt := &BatchReceipt{
		BatchNo:         req.BatchNo,
		FileIDs:         make(map[string]int64),
		MissingSidecars: make([]string, 0),
	}
	missingSeen := make(map[string]struct{})
	dirtyDirs := make(map[string]struct{})
	queuedGroups := make(map[string]string) // group_key -> reason
	var maxChangeSeq int64
	var changedNfoOrArtDirs = make(map[string]struct{})

	for _, item := range req.Upserts {
		if strings.TrimSpace(item.Path) == "" {
			receipt.Ignored++
			continue
		}
		normPath := pathutil.NormalizePath(item.Path)
		if !inFoldersScope(normPath, scopes, true) {
			receipt.Ignored++
			continue
		}
		role := library.ClassifyFileRole(pathutil.BaseName(normPath))
		if role == "" {
			receipt.Ignored++
			continue
		}

		var remoteIDPtr *string
		if item.RemoteID != nil {
			if trimmed := strings.TrimSpace(*item.RemoteID); trimmed != "" {
				remoteIDPtr = &trimmed
			}
		}

		var sidecarHashPtr *string
		if rawSH := strings.TrimSpace(item.SidecarHash); rawSH != "" {
			normSH, err := normalizeSHA256(rawSH)
			if err != nil {
				return nil, fmt.Errorf("%w: invalid sidecar_hash %q", ErrInvalidInput, item.SidecarHash)
			}
			sidecarHashPtr = &normSH
		}

		existing, found, err := lookupExistingMediaFileTx(tx, p.HouseholdID, sv.SourceID, normPath, remoteIDPtr)
		if err != nil {
			return nil, err
		}

		var fileID int64
		if found {
			fileID = existing.ID
			unchanged := existing.State == db.FileStateActive &&
				existing.Path == normPath &&
				equalStrPtr(existing.RemoteID, remoteIDPtr) &&
				existing.Role == role &&
				equalInt64Ptr(existing.Size, item.Size) &&
				equalInt64Ptr(existing.MtimeS, item.MtimeS) &&
				equalStrPtr(existing.SidecarSHA256, sidecarHashPtr)

			if unchanged {
				if _, err := tx.Exec(`
					UPDATE media_files
					SET last_seen_at = MAX(last_seen_at, ?)
					WHERE id = ? AND household_id = ?`,
					nowMs, fileID, p.HouseholdID,
				); err != nil {
					return nil, err
				}
				receipt.Unchanged++
				receipt.Accepted++
				receipt.FileIDs[normPath] = fileID
				if err := clearPendingDeletionFileTx(tx, fileID, nowMs); err != nil {
					return nil, err
				}
			} else {
				pathChanged := existing.Path != normPath
				contentChanged := !equalInt64Ptr(existing.Size, item.Size) ||
					!equalInt64Ptr(existing.MtimeS, item.MtimeS) ||
					!equalStrPtr(existing.SidecarSHA256, sidecarHashPtr)
				oldDir := pathutil.ParentPath(existing.Path)

				if pathChanged {
					// If another row currently holds normPath on this source, drop it so Quark move stays unique.
					if _, err := tx.Exec(`
						DELETE FROM media_files
						WHERE household_id = ? AND source_id = ? AND path = ? AND id != ?`,
						p.HouseholdID, sv.SourceID, normPath, fileID,
					); err != nil {
						return nil, err
					}
				}

				parsedJSON, versionLabel, groupKey := buildVideoMetadataForItem(role, sv.SourceID, normPath)
				clientHintsJSON := encodeOptionalJSON(item.ClientHints)

				newMatchState := existing.MatchState
				if contentChanged && existing.MatchLocked == 0 && role == db.FileRoleVideo {
					newMatchState = db.MatchPending
				}

				if _, err := tx.Exec(`
					UPDATE media_files
					SET path = ?, remote_id = ?, role = ?, size = ?, mtime_s = ?, ctime_s = ?,
					    sidecar_sha256 = ?, state = 'active', missing_since = NULL,
					    match_state = ?,
					    parsed_json = COALESCE(?, parsed_json),
					    client_hints_json = COALESCE(?, client_hints_json),
					    version_label = COALESCE(?, version_label),
					    last_seen_at = MAX(last_seen_at, ?),
					    reported_by_device = ?,
					    updated_at = ?
					WHERE id = ? AND household_id = ?`,
					normPath, nullableStrPtr(remoteIDPtr), role, nullableInt64Ptr(item.Size), nullableInt64Ptr(item.MtimeS), nullableInt64Ptr(item.CtimeS),
					nullableStrPtr(sidecarHashPtr), newMatchState,
					nullableStrPtr(parsedJSON), nullableStrPtr(clientHintsJSON), nullableStrPtr(versionLabel),
					nowMs, p.DeviceID, nowMs,
					fileID, p.HouseholdID,
				); err != nil {
					return nil, err
				}

				if item.MediaSpec != nil && !existing.ProbedAt.Valid {
					if err := applyBatchMediaSpecTx(tx, p.HouseholdID, fileID, item.MediaSpec); err != nil {
						return nil, err
					}
				}

				if err := clearPendingDeletionFileTx(tx, fileID, nowMs); err != nil {
					return nil, err
				}

				seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", fileID), "upsert", nowMs)
				if err != nil {
					return nil, err
				}
				if seq > maxChangeSeq {
					maxChangeSeq = seq
				}

				receipt.Changed++
				receipt.Accepted++
				receipt.FileIDs[normPath] = fileID

				dir := pathutil.ParentPath(normPath)
				dirtyDirs[dir] = struct{}{}
				if pathChanged {
					dirtyDirs[oldDir] = struct{}{}
				}

				if role == db.FileRoleVideo && (contentChanged || !existing.ItemID.Valid || (pathChanged && !existing.ItemID.Valid)) {
					if groupKey != "" {
						queuedGroups[groupKey] = "changed"
					}
				} else if role == db.FileRoleVideo && existing.ItemID.Valid {
					itemSeq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "item", fmt.Sprintf("%d", existing.ItemID.Int64), "upsert", nowMs)
					if err != nil {
						return nil, err
					}
					if itemSeq > maxChangeSeq {
						maxChangeSeq = itemSeq
					}
				} else if role == db.FileRoleNfo || role == db.FileRoleArtwork {
					changedNfoOrArtDirs[dir] = struct{}{}
				}
			}
		} else {
			// New file insert (enforce quota_max_files).
			if curFiles >= maxFiles {
				return nil, &QuotaExceededError{
					Quota:   "files",
					Limit:   int64(maxFiles),
					Current: int64(curFiles),
				}
			}
			curFiles++

			parsedJSON, versionLabel, groupKey := buildVideoMetadataForItem(role, sv.SourceID, normPath)
			clientHintsJSON := encodeOptionalJSON(item.ClientHints)

			var (
				durMs, width, height, bitrate any
				container, vCodec, hdr, sJSON any
			)
			if item.MediaSpec != nil {
				durMs = nullableInt64Ptr(item.MediaSpec.DurationMs)
				bitrate = nullableIntPtr(item.MediaSpec.BitrateKbps)
				container = nullableStrPtr(item.MediaSpec.Container)
				vCodec = nullableStrPtr(item.MediaSpec.VideoCodec)
				width = nullableIntPtr(item.MediaSpec.Width)
				height = nullableIntPtr(item.MediaSpec.Height)
				hdr = nullableStrPtr(item.MediaSpec.HdrFormat)
				if len(item.MediaSpec.Streams) > 0 {
					if b, mErr := json.Marshal(item.MediaSpec.Streams); mErr == nil {
						str := string(b)
						sJSON = str
					}
				}
			}

			res, err := tx.Exec(`
				INSERT INTO media_files(
					household_id, source_id, path, remote_id, role, size, mtime_s, ctime_s, sidecar_sha256,
					state, match_state, match_locked, parsed_json, client_hints_json, version_label,
					duration_ms, bitrate_kbps, container, video_codec, width, height, hdr_format, streams_json,
					last_seen_at, reported_by_device, added_at, updated_at
				) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', 'pending', 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				p.HouseholdID, sv.SourceID, normPath, nullableStrPtr(remoteIDPtr), role,
				nullableInt64Ptr(item.Size), nullableInt64Ptr(item.MtimeS), nullableInt64Ptr(item.CtimeS), nullableStrPtr(sidecarHashPtr),
				nullableStrPtr(parsedJSON), nullableStrPtr(clientHintsJSON), nullableStrPtr(versionLabel),
				durMs, bitrate, container, vCodec, width, height, hdr, sJSON,
				nowMs, p.DeviceID, nowMs, nowMs,
			)
			if err != nil {
				return nil, err
			}
			fileID, err = res.LastInsertId()
			if err != nil {
				return nil, err
			}

			seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", fileID), "upsert", nowMs)
			if err != nil {
				return nil, err
			}
			if seq > maxChangeSeq {
				maxChangeSeq = seq
			}

			receipt.Added++
			receipt.Accepted++
			receipt.FileIDs[normPath] = fileID

			dir := pathutil.ParentPath(normPath)
			dirtyDirs[dir] = struct{}{}
			if role == db.FileRoleVideo && groupKey != "" {
				queuedGroups[groupKey] = "new"
			} else if role == db.FileRoleNfo || role == db.FileRoleArtwork {
				changedNfoOrArtDirs[dir] = struct{}{}
			}
		}

		if (role == db.FileRoleNfo || role == db.FileRoleArtwork) && sidecarHashPtr != nil {
			var exists int
			if err := tx.QueryRow(`SELECT COUNT(*) FROM sidecars WHERE household_id = ? AND sha256 = ?`, p.HouseholdID, *sidecarHashPtr).Scan(&exists); err != nil {
				return nil, err
			}
			if exists == 0 {
				if _, seen := missingSeen[*sidecarHashPtr]; !seen {
					missingSeen[*sidecarHashPtr] = struct{}{}
					receipt.MissingSidecars = append(receipt.MissingSidecars, *sidecarHashPtr)
				}
			}
		}
	}

	// Process explicit removals from incremental scans.
	var removedFileIDs []int64
	for _, rem := range req.Removed {
		var (
			normPath string
			remID    = strings.TrimSpace(rem.RemoteID)
		)
		if strings.TrimSpace(rem.Path) != "" {
			normPath = pathutil.NormalizePath(rem.Path)
		}
		if remID == "" && normPath == "" {
			continue
		}

		var res sql.Result
		var err error
		if remID != "" {
			res, err = tx.Exec(`
				UPDATE media_files
				SET state = 'missing', missing_since = COALESCE(missing_since, ?), updated_at = ?
				WHERE household_id = ? AND source_id = ? AND remote_id = ? AND state = 'active'`,
				nowMs, nowMs, p.HouseholdID, sv.SourceID, remID,
			)
		} else {
			res, err = tx.Exec(`
				UPDATE media_files
				SET state = 'missing', missing_since = COALESCE(missing_since, ?), updated_at = ?
				WHERE household_id = ? AND source_id = ? AND path = ? AND state = 'active'`,
				nowMs, nowMs, p.HouseholdID, sv.SourceID, normPath,
			)
		}
		if err != nil {
			return nil, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			var removedID int64
			if remID != "" {
				_ = tx.QueryRow(`SELECT id FROM media_files WHERE household_id = ? AND source_id = ? AND remote_id = ?`, p.HouseholdID, sv.SourceID, remID).Scan(&removedID)
			} else {
				_ = tx.QueryRow(`SELECT id FROM media_files WHERE household_id = ? AND source_id = ? AND path = ?`, p.HouseholdID, sv.SourceID, normPath).Scan(&removedID)
			}
			if removedID > 0 {
				removedFileIDs = append(removedFileIDs, removedID)
				seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", removedID), "missing", nowMs)
				if err != nil {
					return nil, err
				}
				if seq > maxChangeSeq {
					maxChangeSeq = seq
				}
			}
			receipt.Removed += int(n)
		}
	}
	if len(removedFileIDs) > 0 {
		if seq, err := recomputeRootSourceAddedAtTx(tx, p.HouseholdID, removedFileIDs, nowMs); err != nil {
			return nil, err
		} else if seq > maxChangeSeq {
			maxChangeSeq = seq
		}
	}

	// Match subtitles and per-video NFOs in touched directories.
	for dir := range dirtyDirs {
		seq, err := matchDirectorySidecarsTx(tx, p.HouseholdID, sv.SourceID, dir, nowMs)
		if err != nil {
			return nil, err
		}
		if seq > maxChangeSeq {
			maxChangeSeq = seq
		}
	}

	// Ensure newly arrived NFO/artwork sidecars re-trigger identification of existing videos in their folder.
	for dir := range changedNfoOrArtDirs {
		if err := collectDirVideoGroupsTx(tx, p.HouseholdID, sv.SourceID, dir, queuedGroups); err != nil {
			return nil, err
		}
	}

	for gKey, reason := range queuedGroups {
		if err := enqueueIdentifyTx(tx, p.HouseholdID, gKey, reason, nowMs); err != nil {
			return nil, err
		}
	}

	newReported := sv.FilesReported + len(req.Upserts)
	newAdded := sv.FilesAdded + receipt.Added
	newChanged := sv.FilesChanged + receipt.Changed
	if _, err := tx.Exec(`
		UPDATE scan_sessions
		SET files_reported = ?, files_added = ?, files_changed = ?, last_activity_at = ?
		WHERE id = ? AND household_id = ?`,
		newReported, newAdded, newChanged, nowMs, sv.ID, p.HouseholdID,
	); err != nil {
		return nil, err
	}

	receiptBytes, err := json.Marshal(receipt)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`
		INSERT INTO ingest_batches(session_id, batch_no, response_json, created_at)
		VALUES (?, ?, ?, ?)`,
		sv.ID, req.BatchNo, string(receiptBytes), nowMs,
	); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if maxChangeSeq > 0 {
		s.publishLibraryChanged(p.HouseholdID, maxChangeSeq)
	}
	return receipt, nil
}

func lookupExistingMediaFileTx(tx *sql.Tx, hhID, sourceID, normPath string, remoteID *string) (existingFileRow, bool, error) {
	scanRow := func(row *sql.Row) (existingFileRow, bool, error) {
		var r existingFileRow
		err := row.Scan(
			&r.ID, &r.Path, &r.RemoteID, &r.Role, &r.ItemID, &r.OwnerFileID,
			&r.Size, &r.MtimeS, &r.SidecarSHA256, &r.State, &r.MatchState,
			&r.MatchLocked, &r.ProbedAt, &r.LastSeenAt,
		)
		if errors.Is(err, sql.ErrNoRows) {
			return existingFileRow{}, false, nil
		}
		if err != nil {
			return existingFileRow{}, false, err
		}
		return r, true, nil
	}

	const selectCols = `
		SELECT id, path, remote_id, role, item_id, owner_file_id,
		       size, mtime_s, sidecar_sha256, state, match_state,
		       match_locked, probed_at, last_seen_at
		FROM media_files`

	if remoteID != nil && *remoteID != "" {
		r, ok, err := scanRow(tx.QueryRow(selectCols+` WHERE household_id = ? AND source_id = ? AND remote_id = ?`, hhID, sourceID, *remoteID))
		if err != nil || ok {
			return r, ok, err
		}
	}
	return scanRow(tx.QueryRow(selectCols+` WHERE household_id = ? AND source_id = ? AND path = ?`, hhID, sourceID, normPath))
}

func clearPendingDeletionFileTx(tx *sql.Tx, fileID int64, nowMs int64) error {
	rows, err := tx.Query(`SELECT pending_id FROM pending_deletion_files WHERE file_id = ?`, fileID)
	if err != nil {
		return err
	}
	var pendingIDs []string
	for rows.Next() {
		var pid string
		if rows.Scan(&pid) == nil {
			pendingIDs = append(pendingIDs, pid)
		}
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(pendingIDs) == 0 {
		return nil
	}

	if _, err := tx.Exec(`DELETE FROM pending_deletion_files WHERE file_id = ?`, fileID); err != nil {
		return err
	}
	for _, pid := range pendingIDs {
		if _, err := tx.Exec(`
			UPDATE pending_deletions
			SET file_count = (SELECT COUNT(*) FROM pending_deletion_files WHERE pending_id = ?),
			    status = CASE WHEN (SELECT COUNT(*) FROM pending_deletion_files WHERE pending_id = ?) = 0 THEN 'dismissed' ELSE status END,
			    resolved_at = CASE WHEN (SELECT COUNT(*) FROM pending_deletion_files WHERE pending_id = ?) = 0 THEN ? ELSE resolved_at END
			WHERE id = ? AND status = 'pending'`,
			pid, pid, pid, nowMs, pid,
		); err != nil {
			return err
		}
	}
	return nil
}

func buildVideoMetadataForItem(role, sourceID, normPath string) (parsedJSON *string, versionLabel *string, groupKey string) {
	if role != db.FileRoleVideo {
		return nil, nil, ""
	}
	parsed, vLabel, gKey := ParseAndGroup(sourceID, normPath)
	if b, err := json.Marshal(parsed); err == nil {
		s := string(b)
		parsedJSON = &s
	}
	if vLabel != "" {
		versionLabel = &vLabel
	}
	return parsedJSON, versionLabel, gKey
}

func applyBatchMediaSpecTx(tx *sql.Tx, hhID string, fileID int64, spec *MediaSpecInput) error {
	if spec == nil {
		return nil
	}
	var streamsJSON *string
	if len(spec.Streams) > 0 {
		if b, err := json.Marshal(spec.Streams); err == nil {
			s := string(b)
			streamsJSON = &s
		}
	}
	_, err := tx.Exec(`
		UPDATE media_files
		SET duration_ms = COALESCE(?, duration_ms),
		    bitrate_kbps = COALESCE(?, bitrate_kbps),
		    container = COALESCE(?, container),
		    video_codec = COALESCE(?, video_codec),
		    width = COALESCE(?, width),
		    height = COALESCE(?, height),
		    hdr_format = COALESCE(?, hdr_format),
		    streams_json = COALESCE(?, streams_json)
		WHERE id = ? AND household_id = ? AND probed_at IS NULL`,
		nullableInt64Ptr(spec.DurationMs), nullableIntPtr(spec.BitrateKbps),
		nullableStrPtr(spec.Container), nullableStrPtr(spec.VideoCodec),
		nullableIntPtr(spec.Width), nullableIntPtr(spec.Height),
		nullableStrPtr(spec.HdrFormat), nullableStrPtr(streamsJSON),
		fileID, hhID,
	)
	return err
}

func matchDirectorySidecarsTx(tx *sql.Tx, hhID, sourceID, dir string, nowMs int64) (int64, error) {
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	var (
		rows *sql.Rows
		err  error
	)
	if dir == pathutil.RootPath {
		rows, err = tx.Query(`
			SELECT id, path, role, owner_file_id, item_id, COALESCE(language, '')
			FROM media_files
			WHERE household_id = ? AND source_id = ? AND state = 'active'
			  AND role IN ('video', 'subtitle', 'nfo')
			  AND path LIKE '/%' AND path NOT LIKE '/%/%'`,
			hhID, sourceID,
		)
	} else {
		patDirect := likeEsc.Replace(dir) + "/%"
		patDeeper := likeEsc.Replace(dir) + "/%/%"
		rows, err = tx.Query(`
			SELECT id, path, role, owner_file_id, item_id, COALESCE(language, '')
			FROM media_files
			WHERE household_id = ? AND source_id = ? AND state = 'active'
			  AND role IN ('video', 'subtitle', 'nfo')
			  AND path LIKE ? ESCAPE '\' AND path NOT LIKE ? ESCAPE '\'`,
			hhID, sourceID, patDirect, patDeeper,
		)
	}
	if err != nil {
		return 0, err
	}

	type dirEntry struct {
		id      int64
		path    string
		name    string
		role    string
		ownerID sql.NullInt64
		itemID  sql.NullInt64
		lang    string
	}
	var entries []dirEntry
	for rows.Next() {
		var e dirEntry
		if scanErr := rows.Scan(&e.id, &e.path, &e.role, &e.ownerID, &e.itemID, &e.lang); scanErr != nil {
			_ = rows.Close()
			return 0, scanErr
		}
		if pathutil.ParentPath(e.path) != dir {
			continue
		}
		e.name = pathutil.BaseName(e.path)
		entries = append(entries, e)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	dirFiles := make([]library.DirFile, 0, len(entries))
	pathToID := make(map[string]int64, len(entries))
	videoItemByID := make(map[int64]int64)
	videoStemToID := make(map[string]int64)
	for _, e := range entries {
		dirFiles = append(dirFiles, library.DirFile{Path: e.path, Name: e.name})
		pathToID[e.path] = e.id
		if e.role == db.FileRoleVideo {
			if e.itemID.Valid && e.itemID.Int64 > 0 {
				videoItemByID[e.id] = e.itemID.Int64
			}
			stem := strings.ToLower(library.FileStem(e.name))
			videoStemToID[stem] = e.id
		}
	}

	subMatches := make(map[string]library.MatchedSubtitle)
	for _, ms := range library.MatchSubtitles(dirFiles) {
		subMatches[ms.Subtitle.Path] = ms
	}

	var maxSeq int64
	notifiedItems := make(map[int64]struct{})
	for _, e := range entries {
		switch e.role {
		case db.FileRoleSubtitle:
			if m, ok := subMatches[e.path]; ok {
				ownerID := pathToID[m.Owner.Path]
				if !e.ownerID.Valid || e.ownerID.Int64 != ownerID || e.lang != m.Language {
					if _, err := tx.Exec(`
						UPDATE media_files
						SET owner_file_id = ?, language = ?, updated_at = ?
						WHERE id = ? AND household_id = ?`,
						ownerID, m.Language, nowMs, e.id, hhID,
					); err != nil {
						return 0, err
					}
					if ownerItemID, ok := videoItemByID[ownerID]; ok && ownerItemID > 0 {
						if _, seen := notifiedItems[ownerItemID]; !seen {
							notifiedItems[ownerItemID] = struct{}{}
							seq, err := db.AppendChangeTx(tx, hhID, nil, "item", fmt.Sprintf("%d", ownerItemID), "upsert", nowMs)
							if err != nil {
								return 0, err
							}
							if seq > maxSeq {
								maxSeq = seq
							}
						}
					}
				}
			}
		case db.FileRoleNfo:
			stem := strings.ToLower(library.FileStem(e.name))
			if ownerID, ok := videoStemToID[stem]; ok {
				if !e.ownerID.Valid || e.ownerID.Int64 != ownerID {
					if _, err := tx.Exec(`
						UPDATE media_files
						SET owner_file_id = ?, updated_at = ?
						WHERE id = ? AND household_id = ?`,
						ownerID, nowMs, e.id, hhID,
					); err != nil {
						return 0, err
					}
				}
			}
		}
	}
	return maxSeq, nil
}

func collectDirVideoGroupsTx(tx *sql.Tx, hhID, sourceID, dir string, out map[string]string) error {
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	var (
		rows *sql.Rows
		err  error
	)
	if dir == pathutil.RootPath {
		rows, err = tx.Query(`
			SELECT path FROM media_files
			WHERE household_id = ? AND source_id = ? AND state = 'active' AND role = 'video'
			  AND path LIKE '/%'`,
			hhID, sourceID,
		)
	} else {
		pat := likeEsc.Replace(dir) + "/%"
		rows, err = tx.Query(`
			SELECT path FROM media_files
			WHERE household_id = ? AND source_id = ? AND state = 'active' AND role = 'video'
			  AND path LIKE ? ESCAPE '\'`,
			hhID, sourceID, pat,
		)
	}
	if err != nil {
		return err
	}
	var paths []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil {
			paths = append(paths, p)
		}
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, vp := range paths {
		_, _, gKey := ParseAndGroup(sourceID, vp)
		if gKey != "" {
			if _, exists := out[gKey]; !exists {
				out[gKey] = "changed"
			}
		}
	}
	return nil
}

func enqueueIdentifyTx(tx *sql.Tx, hhID, groupKey, reason string, nowMs int64) error {
	notBefore := nowMs + IdentifyDebounceDuration.Milliseconds()
	_, err := tx.Exec(`
		INSERT INTO identify_queue(
			household_id, group_key, reason, status, not_before, attempts, last_error_code, created_at, updated_at
		) VALUES (?, ?, ?, 'queued', ?, 0, '', ?, ?)
		ON CONFLICT(household_id, group_key) DO UPDATE SET
			reason = CASE WHEN identify_queue.reason = 'new' THEN 'new' ELSE excluded.reason END,
			status = 'queued',
			not_before = excluded.not_before,
			attempts = 0,
			last_error_code = '',
			updated_at = excluded.updated_at`,
		hhID, groupKey, reason, notBefore, nowMs, nowMs,
	)
	return err
}

func encodeOptionalJSON(v any) *string {
	if v == nil {
		return nil
	}
	switch t := v.(type) {
	case map[string]any:
		if len(t) == 0 {
			return nil
		}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	s := string(b)
	return &s
}

func equalStrPtr(sqlVal sql.NullString, p *string) bool {
	if p == nil {
		return !sqlVal.Valid || sqlVal.String == ""
	}
	return sqlVal.Valid && sqlVal.String == *p
}

func equalInt64Ptr(sqlVal sql.NullInt64, p *int64) bool {
	if p == nil {
		return !sqlVal.Valid
	}
	return sqlVal.Valid && sqlVal.Int64 == *p
}

func nullableStrPtr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullableInt64Ptr(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func nullableIntPtr(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}
