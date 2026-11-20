package ingest

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
)

func (s *Service) ReportMediaSpec(p *account.Principal, fileID int64, req MediaSpecInput) error {
	if p == nil {
		return ErrUnauthorized
	}
	if !p.HasPerm(account.PermBrowse) && !p.HasPerm(account.PermUploadFacts) && !p.HasPerm(account.PermManageSources) {
		return ErrForbidden
	}
	if fileID <= 0 {
		return ErrNotFound
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var (
		sourceID  string
		role      string
		srcStatus string
	)
	err = tx.QueryRow(`
		SELECT mf.source_id, mf.role, s.status
		FROM media_files mf
		JOIN sources s ON s.id = mf.source_id AND s.household_id = mf.household_id
		WHERE mf.id = ? AND mf.household_id = ?`,
		fileID, p.HouseholdID,
	).Scan(&sourceID, &role, &srcStatus)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if srcStatus == "deleted" {
		return ErrSourceDeleted
	}
	if p.RestrictSources {
		var allowed int
		if err := tx.QueryRow(`
			SELECT COUNT(*) FROM member_source_access
			WHERE household_id = ? AND member_id = ? AND source_id = ?`,
			p.HouseholdID, p.MemberID, sourceID,
		).Scan(&allowed); err != nil {
			return err
		}
		if allowed == 0 {
			return ErrForbidden
		}
	}
	if role != db.FileRoleVideo {
		return fmt.Errorf("%w: media-spec is only applicable to video files", ErrInvalidInput)
	}

	var streamsJSON *string
	if req.Streams != nil {
		b, err := json.Marshal(req.Streams)
		if err != nil {
			return err
		}
		str := string(b)
		streamsJSON = &str
	}

	if _, err := tx.Exec(`
		UPDATE media_files
		SET duration_ms = COALESCE(?, duration_ms),
		    bitrate_kbps = COALESCE(?, bitrate_kbps),
		    container = COALESCE(?, container),
		    video_codec = COALESCE(?, video_codec),
		    width = COALESCE(?, width),
		    height = COALESCE(?, height),
		    hdr_format = COALESCE(?, hdr_format),
		    streams_json = COALESCE(?, streams_json),
		    probed_at = ?,
		    updated_at = ?
		WHERE id = ? AND household_id = ?`,
		nullableInt64Ptr(req.DurationMs), nullableIntPtr(req.BitrateKbps),
		nullableStrTrimPtr(req.Container), nullableStrTrimPtr(req.VideoCodec),
		nullableIntPtr(req.Width), nullableIntPtr(req.Height),
		nullableStrTrimPtr(req.HdrFormat), nullableStrPtr(streamsJSON),
		nowMs, nowMs, fileID, p.HouseholdID,
	); err != nil {
		return err
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "media_file", fmt.Sprintf("%d", fileID), "media_spec", nowMs)
	if err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	s.publishLibraryChanged(p.HouseholdID, seq)
	return nil
}

func nullableStrTrimPtr(p *string) any {
	if p == nil {
		return nil
	}
	t := strings.TrimSpace(*p)
	if t == "" {
		return nil
	}
	return t
}
