package source

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/pathutil"
	"plezy/media_library/internal/security"
)

type normalizedFolder struct {
	path         string
	excludes     []string
	excludesJSON string
	libraryHint  string
}

func normalizeExcludePaths(in []string) ([]string, string) {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, raw := range in {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		norm := pathutil.NormalizePath(raw)
		if _, ok := seen[norm]; ok {
			continue
		}
		seen[norm] = struct{}{}
		out = append(out, norm)
	}
	b, _ := json.Marshal(out)
	return out, string(b)
}

func normalizeFolderInput(in FolderInput) (normalizedFolder, error) {
	rawPath := strings.TrimSpace(in.Path)
	if rawPath == "" {
		return normalizedFolder{}, fmt.Errorf("%w: folder path is required", ErrInvalidInput)
	}
	normPath := pathutil.NormalizePath(rawPath)
	hint := strings.TrimSpace(in.LibraryHint)
	if hint == "" {
		hint = "auto"
	}
	if !IsValidLibraryHint(hint) {
		return normalizedFolder{}, fmt.Errorf("%w: unsupported library_hint %q", ErrInvalidInput, in.LibraryHint)
	}
	excludes, excludesJSON := normalizeExcludePaths(in.ExcludePaths)
	return normalizedFolder{
		path:         normPath,
		excludes:     excludes,
		excludesJSON: excludesJSON,
		libraryHint:  hint,
	}, nil
}

type scannable interface {
	Scan(dest ...any) error
}

func scanFolderView(row scannable) (FolderView, error) {
	var (
		fv           FolderView
		excludesJSON string
		baselineAt   sql.NullInt64
	)
	if err := row.Scan(
		&fv.ID, &fv.HouseholdID, &fv.SourceID, &fv.Path,
		&excludesJSON, &fv.LibraryHint, &baselineAt, &fv.CreatedAt, &fv.UpdatedAt,
	); err != nil {
		return FolderView{}, err
	}
	fv.ExcludePaths = []string{}
	if excludesJSON != "" {
		var decoded []string
		if json.Unmarshal([]byte(excludesJSON), &decoded) == nil && decoded != nil {
			fv.ExcludePaths = decoded
		}
	}
	if baselineAt.Valid {
		v := baselineAt.Int64
		fv.BaselineAt = &v
	}
	return fv, nil
}

func (s *Service) ListFolders(p *account.Principal, sourceID string) ([]FolderView, error) {
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}
	if !KindHasFoldersAndScan(src.Kind) {
		return nil, fmt.Errorf("%w: %s sources do not have folders", ErrInvalidInput, src.Kind)
	}
	rows, err := s.store.ReadDB().Query(`
		SELECT id, household_id, source_id, path, exclude_paths_json, library_hint, baseline_at, created_at, updated_at
		FROM source_folders
		WHERE household_id = ? AND source_id = ?
		ORDER BY path ASC`,
		p.HouseholdID, src.ID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]FolderView, 0)
	for rows.Next() {
		fv, err := scanFolderView(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, fv)
	}
	return out, rows.Err()
}

func (s *Service) AddFolder(p *account.Principal, sourceID string, req FolderInput, ip string) (*FolderView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}
	if !KindHasFoldersAndScan(src.Kind) {
		return nil, fmt.Errorf("%w: %s sources do not support folders", ErrInvalidInput, src.Kind)
	}
	nf, err := normalizeFolderInput(req)
	if err != nil {
		return nil, err
	}

	fid := uuid.NewString()
	nowMs := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO source_folders(
			id, household_id, source_id, path, exclude_paths_json, library_hint, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		fid, p.HouseholdID, src.ID, nf.path, nf.excludesJSON, nf.libraryHint, nowMs, nowMs,
	); err != nil {
		if isUniqueConstraintErr(err) {
			return nil, fmt.Errorf("%w: folder path already exists on source", ErrConflict)
		}
		return nil, err
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source_folder", fid, "upsert", nowMs)
	if err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.folder_added",
		TargetType:  "source_folder",
		TargetID:    fid,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"source_id": src.ID},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if s.hub != nil {
		s.hub.PublishToHousehold(p.HouseholdID, "source.changed", map[string]any{
			"source_id": src.ID,
			"folder_id": fid,
			"op":        "folder_upsert",
			"seq":       seq,
		})
	}
	return &FolderView{
		ID:           fid,
		HouseholdID:  p.HouseholdID,
		SourceID:     src.ID,
		Path:         nf.path,
		ExcludePaths: nf.excludes,
		LibraryHint:  nf.libraryHint,
		CreatedAt:    nowMs,
		UpdatedAt:    nowMs,
	}, nil
}

func (s *Service) UpdateFolder(p *account.Principal, sourceID, folderID string, req UpdateFolderRequest, ip string) (*FolderView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}
	if !KindHasFoldersAndScan(src.Kind) {
		return nil, fmt.Errorf("%w: %s sources do not support folders", ErrInvalidInput, src.Kind)
	}
	fid := strings.TrimSpace(folderID)
	if fid == "" {
		return nil, ErrNotFound
	}

	cur, err := scanFolderView(s.store.ReadDB().QueryRow(`
		SELECT id, household_id, source_id, path, exclude_paths_json, library_hint, baseline_at, created_at, updated_at
		FROM source_folders
		WHERE id = ? AND household_id = ? AND source_id = ?`,
		fid, p.HouseholdID, src.ID,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	newPath := cur.Path
	if req.Path != nil {
		trimmed := strings.TrimSpace(*req.Path)
		if trimmed == "" {
			return nil, fmt.Errorf("%w: folder path cannot be empty", ErrInvalidInput)
		}
		newPath = pathutil.NormalizePath(trimmed)
	}
	newExcludes := cur.ExcludePaths
	if req.ExcludePaths != nil {
		newExcludes = *req.ExcludePaths
	}
	normExcludes, excludesJSON := normalizeExcludePaths(newExcludes)

	newHint := cur.LibraryHint
	if req.LibraryHint != nil {
		hint := strings.TrimSpace(*req.LibraryHint)
		if hint == "" {
			hint = "auto"
		}
		if !IsValidLibraryHint(hint) {
			return nil, fmt.Errorf("%w: unsupported library_hint %q", ErrInvalidInput, *req.LibraryHint)
		}
		newHint = hint
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE source_folders
		SET path = ?, exclude_paths_json = ?, library_hint = ?, updated_at = ?
		WHERE id = ? AND household_id = ? AND source_id = ?`,
		newPath, excludesJSON, newHint, nowMs, fid, p.HouseholdID, src.ID,
	)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, fmt.Errorf("%w: folder path already exists on source", ErrConflict)
		}
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotFound
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source_folder", fid, "upsert", nowMs)
	if err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.folder_updated",
		TargetType:  "source_folder",
		TargetID:    fid,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"source_id": src.ID},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if s.hub != nil {
		s.hub.PublishToHousehold(p.HouseholdID, "source.changed", map[string]any{
			"source_id": src.ID,
			"folder_id": fid,
			"op":        "folder_upsert",
			"seq":       seq,
		})
	}
	cur.Path = newPath
	cur.ExcludePaths = normExcludes
	cur.LibraryHint = newHint
	cur.UpdatedAt = nowMs
	return &cur, nil
}

func (s *Service) DeleteFolder(p *account.Principal, sourceID, folderID, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return ErrForbidden
	}
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return err
	}
	fid := strings.TrimSpace(folderID)
	if fid == "" {
		return ErrNotFound
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		DELETE FROM source_folders WHERE id = ? AND household_id = ? AND source_id = ?`,
		fid, p.HouseholdID, src.ID,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source_folder", fid, "delete", nowMs)
	if err != nil {
		return err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.folder_deleted",
		TargetType:  "source_folder",
		TargetID:    fid,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"source_id": src.ID},
	}); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	if s.hub != nil {
		s.hub.PublishToHousehold(p.HouseholdID, "source.changed", map[string]any{
			"source_id": src.ID,
			"folder_id": fid,
			"op":        "folder_delete",
			"seq":       seq,
		})
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "unique")
}
