package ingest

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/uuid"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/pathutil"
	"plezy/media_library/internal/security"
)

func (s *Service) CompleteSession(p *account.Principal, sessionID string, req CompleteSessionRequest, ip string) (*CompleteSessionResult, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) {
		return nil, ErrForbidden
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

	var curWatermark int64
	_ = tx.QueryRow(`SELECT incremental_watermark FROM source_scan_state WHERE source_id = ? AND household_id = ?`,
		sv.SourceID, p.HouseholdID,
	).Scan(&curWatermark)

	// Already finalized -> idempotent return.
	if sv.Status == SessionCompleted || sv.Status == SessionPartial {
		return &CompleteSessionResult{
			Session:      *sv,
			MissingCount: sv.FilesMissing,
			NewWatermark: curWatermark,
		}, nil
	}

	var (
		missingCount      int
		pendingDeletionID string
		maxChangeSeq      int64
	)

	// Stale sessions or complete=false always finish as partial with no missing derivation and no watermark update.
	if sv.Status == SessionStale || !req.Complete {
		if sv.Status == SessionRunning {
			if _, err := tx.Exec(`
				UPDATE scan_sessions
				SET status = 'partial', finished_at = ?, last_activity_at = ?
				WHERE id = ? AND household_id = ?`,
				nowMs, nowMs, sv.ID, p.HouseholdID,
			); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(`
				UPDATE source_scan_state SET last_scan_result = 'partial', updated_at = ?
				WHERE source_id = ? AND household_id = ?`,
				nowMs, sv.SourceID, p.HouseholdID,
			); err != nil {
				return nil, err
			}
			sv.Status = SessionPartial
			sv.FinishedAt = &nowMs
			sv.LastActivityAt = nowMs
		}
		if err := expediteSourceIdentifyQueueTx(tx, p.HouseholdID, sv.SourceID, nowMs); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		s.publishScanProgress(sv)
		return &CompleteSessionResult{
			Session:      *sv,
			MissingCount: 0,
			NewWatermark: curWatermark,
		}, nil
	}

	// Derive missing files for full / folder scans using timestamp watermark (V1-6 concurrent-safe).
	if sv.Type == ScanTypeFull || sv.Type == ScanTypeFolder {
		scopes, err := loadScopedFolders(tx, p.HouseholdID, sv.SourceID, sv.FolderID)
		if err != nil {
			return nil, err
		}
		if len(scopes) > 0 {
			rows, err := tx.Query(`
				SELECT id, path, last_seen_at
				FROM media_files
				WHERE household_id = ? AND source_id = ? AND state = 'active'`,
				p.HouseholdID, sv.SourceID,
			)
			if err != nil {
				return nil, err
			}
			var (
				totalInScope      int
				missingCandidates []int64
			)
			for rows.Next() {
				var (
					fid      int64
					fPath    string
					lastSeen int64
				)
				if scanErr := rows.Scan(&fid, &fPath, &lastSeen); scanErr != nil {
					_ = rows.Close()
					return nil, scanErr
				}
				if !inFoldersScope(fPath, scopes, false) {
					continue
				}
				totalInScope++
				if lastSeen < sv.StartedAt {
					missingCandidates = append(missingCandidates, fid)
				}
			}
			_ = rows.Close()
			if err := rows.Err(); err != nil {
				return nil, err
			}

			bulkDelete := len(missingCandidates) > s.bulkDeleteMinCount &&
				totalInScope > 0 &&
				float64(len(missingCandidates))/float64(totalInScope) > s.bulkDeleteRatio

			if bulkDelete {
				pendingDeletionID = uuid.NewString()
				scopePath := pathutil.RootPath
				if len(scopes) == 1 {
					scopePath = scopes[0].Path
				}
				if _, err := tx.Exec(`
					INSERT INTO pending_deletions(
						id, household_id, source_id, session_id, scope_path,
						file_count, total_in_scope, status, created_at
					) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)`,
					pendingDeletionID, p.HouseholdID, sv.SourceID, sv.ID, scopePath,
					len(missingCandidates), totalInScope, nowMs,
				); err != nil {
					return nil, err
				}
				for _, fid := range missingCandidates {
					if _, err := tx.Exec(`INSERT INTO pending_deletion_files(pending_id, file_id) VALUES (?, ?)`,
						pendingDeletionID, fid,
					); err != nil {
						return nil, err
					}
				}
				seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "pending_deletion", pendingDeletionID, "create", nowMs)
				if err != nil {
					return nil, err
				}
				if seq > maxChangeSeq {
					maxChangeSeq = seq
				}
			} else if len(missingCandidates) > 0 {
				missingCount = len(missingCandidates)
				for _, fid := range missingCandidates {
					if _, err := tx.Exec(`
						UPDATE media_files
						SET state = 'missing', missing_since = COALESCE(missing_since, ?), updated_at = ?
						WHERE id = ? AND household_id = ? AND state = 'active'`,
						nowMs, nowMs, fid, p.HouseholdID,
					); err != nil {
						return nil, err
					}
					seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", fid), "missing", nowMs)
					if err != nil {
						return nil, err
					}
					if seq > maxChangeSeq {
						maxChangeSeq = seq
					}
				}
				if seq, err := recomputeRootSourceAddedAtTx(tx, p.HouseholdID, missingCandidates, nowMs); err != nil {
					return nil, err
				} else if seq > maxChangeSeq {
					maxChangeSeq = seq
				}
			}

			for _, sc := range scopes {
				if _, err := tx.Exec(`
					UPDATE source_folders
					SET baseline_at = COALESCE(baseline_at, ?), updated_at = ?
					WHERE id = ? AND household_id = ?`,
					nowMs, nowMs, sc.ID, p.HouseholdID,
				); err != nil {
					return nil, err
				}
			}
		}
	}

	// Monotonic watermark advance (§5.5): never regresses.
	if req.NewWatermark > curWatermark {
		curWatermark = req.NewWatermark
	}
	if _, err := tx.Exec(`
		UPDATE source_scan_state
		SET incremental_watermark = MAX(incremental_watermark, ?),
		    last_full_scan_at = CASE WHEN ? = 'full' THEN ? ELSE last_full_scan_at END,
		    last_scan_result = 'completed',
		    updated_at = ?
		WHERE source_id = ? AND household_id = ?`,
		req.NewWatermark, sv.Type, nowMs, nowMs, sv.SourceID, p.HouseholdID,
	); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`
		UPDATE scan_sessions
		SET status = 'completed', finished_at = ?, last_activity_at = ?, progress_pct = 100, files_missing = ?
		WHERE id = ? AND household_id = ?`,
		nowMs, nowMs, missingCount, sv.ID, p.HouseholdID,
	); err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "scan.session_completed",
		TargetType:  "source",
		TargetID:    sv.SourceID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"session_id":          sv.ID,
			"files_missing":       missingCount,
			"pending_deletion_id": pendingDeletionID,
		},
	}); err != nil {
		return nil, err
	}

	if err := expediteSourceIdentifyQueueTx(tx, p.HouseholdID, sv.SourceID, nowMs); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	sv.Status = SessionCompleted
	sv.FinishedAt = &nowMs
	sv.LastActivityAt = nowMs
	sv.ProgressPct = 100
	sv.FilesMissing = missingCount
	sv.IncrementalWatermark = curWatermark

	s.publishScanProgress(sv)
	if maxChangeSeq > 0 {
		s.publishLibraryChanged(p.HouseholdID, maxChangeSeq)
	}

	return &CompleteSessionResult{
		Session:           *sv,
		MissingCount:      missingCount,
		PendingDeletionID: pendingDeletionID,
		NewWatermark:      curWatermark,
	}, nil
}

func (s *Service) ListPendingDeletions(p *account.Principal) ([]PendingDeletionView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	query := `
		SELECT pd.id, pd.household_id, pd.source_id, pd.session_id, pd.scope_path,
		       pd.file_count, pd.total_in_scope, pd.status, pd.created_at, pd.resolved_at
		FROM pending_deletions pd
		JOIN sources s ON s.id = pd.source_id AND s.household_id = pd.household_id
		WHERE pd.household_id = ? AND s.status = 'active'`
	args := []any{p.HouseholdID}
	if p.RestrictSources {
		query += ` AND EXISTS (
			SELECT 1 FROM member_source_access msa
			WHERE msa.household_id = pd.household_id AND msa.member_id = ? AND msa.source_id = pd.source_id
		)`
		args = append(args, p.MemberID)
	}
	query += ` ORDER BY pd.created_at DESC`

	rows, err := s.store.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PendingDeletionView, 0)
	for rows.Next() {
		var (
			pd         PendingDeletionView
			resolvedAt sql.NullInt64
		)
		if err := rows.Scan(
			&pd.ID, &pd.HouseholdID, &pd.SourceID, &pd.SessionID, &pd.ScopePath,
			&pd.FileCount, &pd.TotalInScope, &pd.Status, &pd.CreatedAt, &resolvedAt,
		); err != nil {
			return nil, err
		}
		if resolvedAt.Valid {
			v := resolvedAt.Int64
			pd.ResolvedAt = &v
		}
		out = append(out, pd)
	}
	return out, rows.Err()
}

func (s *Service) ConfirmPendingDeletion(p *account.Principal, pendingID, ip string) (*PendingDeletionView, error) {
	return s.resolvePendingDeletion(p, pendingID, true, ip)
}

func (s *Service) DismissPendingDeletion(p *account.Principal, pendingID, ip string) (*PendingDeletionView, error) {
	return s.resolvePendingDeletion(p, pendingID, false, ip)
}

func expediteSourceIdentifyQueueTx(tx *sql.Tx, hhID, sourceID string, nowMs int64) error {
	sid := strings.TrimSpace(sourceID)
	if hhID == "" || sid == "" {
		return nil
	}
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	pat := likeEsc.Replace(sid) + ":%"
	_, err := tx.Exec(`
		UPDATE identify_queue
		SET not_before = ?, updated_at = ?
		WHERE household_id = ? AND status = 'queued' AND not_before > ?
		  AND group_key LIKE ? ESCAPE '\'`,
		nowMs, nowMs, hhID, nowMs, pat,
	)
	return err
}

func (s *Service) resolvePendingDeletion(p *account.Principal, pendingID string, confirm bool, ip string) (*PendingDeletionView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}
	pid := strings.TrimSpace(pendingID)
	if pid == "" {
		return nil, ErrNotFound
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var (
		pd         PendingDeletionView
		resolvedAt sql.NullInt64
	)
	err = tx.QueryRow(`
		SELECT id, household_id, source_id, session_id, scope_path,
		       file_count, total_in_scope, status, created_at, resolved_at
		FROM pending_deletions
		WHERE id = ? AND household_id = ?`,
		pid, p.HouseholdID,
	).Scan(
		&pd.ID, &pd.HouseholdID, &pd.SourceID, &pd.SessionID, &pd.ScopePath,
		&pd.FileCount, &pd.TotalInScope, &pd.Status, &pd.CreatedAt, &resolvedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if _, err := s.loadScannableSource(tx, p, pd.SourceID); err != nil {
		return nil, err
	}
	if pd.Status != "pending" {
		return nil, fmt.Errorf("%w: pending deletion already resolved (%s)", ErrConflict, pd.Status)
	}

	var maxSeq int64
	newStatus := "dismissed"
	auditAction := "source.pending_deletion_dismissed"
	affectedCount := 0

	if confirm {
		newStatus = "confirmed"
		auditAction = "source.pending_deletion_confirmed"

		rows, err := tx.Query(`SELECT file_id FROM pending_deletion_files WHERE pending_id = ?`, pid)
		if err != nil {
			return nil, err
		}
		var fileIDs []int64
		for rows.Next() {
			var fid int64
			if rows.Scan(&fid) == nil {
				fileIDs = append(fileIDs, fid)
			}
		}
		_ = rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}

		for _, fid := range fileIDs {
			res, err := tx.Exec(`
				UPDATE media_files
				SET state = 'missing', missing_since = COALESCE(missing_since, ?), updated_at = ?
				WHERE id = ? AND household_id = ? AND state = 'active'`,
				nowMs, nowMs, fid, p.HouseholdID,
			)
			if err != nil {
				return nil, err
			}
			if n, _ := res.RowsAffected(); n > 0 {
				affectedCount++
				seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", fid), "missing", nowMs)
				if err != nil {
					return nil, err
				}
				if seq > maxSeq {
					maxSeq = seq
				}
			}
		}
		if seq, err := recomputeRootSourceAddedAtTx(tx, p.HouseholdID, fileIDs, nowMs); err != nil {
			return nil, err
		} else if seq > maxSeq {
			maxSeq = seq
		}
	}

	if _, err := tx.Exec(`
		UPDATE pending_deletions SET status = ?, resolved_at = ? WHERE id = ? AND household_id = ?`,
		newStatus, nowMs, pid, p.HouseholdID,
	); err != nil {
		return nil, err
	}
	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "pending_deletion", pid, newStatus, nowMs)
	if err != nil {
		return nil, err
	}
	if seq > maxSeq {
		maxSeq = seq
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      auditAction,
		TargetType:  "pending_deletion",
		TargetID:    pid,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"source_id":      pd.SourceID,
			"affected_files": affectedCount,
		},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	pd.Status = newStatus
	pd.ResolvedAt = &nowMs
	if maxSeq > 0 {
		s.publishLibraryChanged(p.HouseholdID, maxSeq)
	}
	return &pd, nil
}

// recomputeRootSourceAddedAtTx recalculates media_items.source_added_at for
// every movie or show owning any of fileIDs after files are marked missing.
func recomputeRootSourceAddedAtTx(tx *sql.Tx, householdID string, fileIDs []int64, nowMs int64) (int64, error) {
	if len(fileIDs) == 0 {
		return 0, nil
	}
	rootSet := make(map[int64]struct{})
	const chunkSize = 200
	for start := 0; start < len(fileIDs); start += chunkSize {
		end := start + chunkSize
		if end > len(fileIDs) {
			end = len(fileIDs)
		}
		chunk := fileIDs[start:end]
		placeholders := strings.Repeat("?,", len(chunk))
		placeholders = placeholders[:len(placeholders)-1]
		args := make([]any, 0, 1+len(chunk))
		args = append(args, householdID)
		for _, id := range chunk {
			args = append(args, id)
		}
		rows, err := tx.Query(`
			SELECT DISTINCT COALESCE(mi.show_id, mi.id)
			FROM media_files mf
			JOIN media_items mi ON mi.id = mf.item_id
			WHERE mf.household_id = ? AND mf.role = 'video' AND mf.item_id IS NOT NULL
			  AND mf.id IN (`+placeholders+`)`,
			args...,
		)
		if err != nil {
			return 0, err
		}
		for rows.Next() {
			var rootID int64
			if scanErr := rows.Scan(&rootID); scanErr == nil && rootID > 0 {
				rootSet[rootID] = struct{}{}
			}
		}
		_ = rows.Close()
		if err := rows.Err(); err != nil {
			return 0, err
		}
	}
	if len(rootSet) == 0 {
		return 0, nil
	}
	var maxSeq int64
	for rootID := range rootSet {
		var curSrcAdded, nextSrcAdded sql.NullInt64
		if err := tx.QueryRow(`
			SELECT source_added_at FROM media_items
			WHERE id = ? AND household_id = ? AND kind IN ('movie', 'show')`,
			rootID, householdID,
		).Scan(&curSrcAdded); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			return 0, err
		}
		if err := tx.QueryRow(`
			SELECT MAX(CASE WHEN mf.mtime_s > 0 THEN mf.mtime_s WHEN mf.ctime_s > 0 THEN mf.ctime_s END) * 1000
			FROM media_items leaf
			JOIN media_files mf ON mf.item_id = leaf.id AND mf.role = 'video' AND mf.state = 'active'
			JOIN sources src ON src.id = mf.source_id AND src.status = 'active'
			WHERE leaf.household_id = ? AND (leaf.id = ? OR leaf.show_id = ?)`,
			householdID, rootID, rootID,
		).Scan(&nextSrcAdded); err != nil {
			return 0, err
		}
		if !nextSrcAdded.Valid || nextSrcAdded.Int64 <= 0 {
			continue
		}
		if curSrcAdded.Valid && curSrcAdded.Int64 == nextSrcAdded.Int64 {
			continue
		}
		if _, err := tx.Exec(`
			UPDATE media_items SET source_added_at = ?, updated_at = ?
			WHERE id = ? AND household_id = ?`,
			nextSrcAdded.Int64, nowMs, rootID, householdID,
		); err != nil {
			return 0, err
		}
		seq, err := db.AppendChangeTx(tx, householdID, nil, "item", strconv.FormatInt(rootID, 10), "upsert", nowMs)
		if err != nil {
			return 0, err
		}
		if seq > maxSeq {
			maxSeq = seq
		}
	}
	return maxSeq, nil
}
