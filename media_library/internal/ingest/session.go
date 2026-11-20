package ingest

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/pathutil"
	"plezy/media_library/internal/security"
)

type Service struct {
	store              *db.Store
	hub                *events.Hub
	limiter            *security.LoginLimiter
	nowFn              func() time.Time
	bulkDeleteMinCount int
	bulkDeleteRatio    float64
}

func NewService(store *db.Store, hub *events.Hub, limiter *security.LoginLimiter) *Service {
	if limiter == nil {
		limiter = security.NewLoginLimiter()
	}
	return &Service{
		store:              store,
		hub:                hub,
		limiter:            limiter,
		nowFn:              time.Now,
		bulkDeleteMinCount: DefaultBulkDeleteMinCount,
		bulkDeleteRatio:    DefaultBulkDeleteRatio,
	}
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
		s.limiter.SetClock(fn)
	}
}

type queryRunner interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

type scannableSource struct {
	ID          string
	HouseholdID string
	Kind        string
	Status      string
}

func actorTypeForPrincipal(p *account.Principal) string {
	if p != nil && p.LoginMode == account.LoginModeMemberOnly {
		return "member"
	}
	return "account"
}

func parseFullScanAllowedDevices(rawJSON string) map[string]bool {
	out := make(map[string]bool)
	var list []string
	if err := json.Unmarshal([]byte(rawJSON), &list); err != nil || len(list) == 0 {
		_ = json.Unmarshal([]byte(db.DefaultFullScanAllowedDevicesJSON), &list)
	}
	for _, item := range list {
		if dc := strings.ToLower(strings.TrimSpace(item)); dc != "" {
			out[dc] = true
		}
	}
	return out
}

func (s *Service) checkDeviceScanAllowed(deviceClass, scanType string) error {
	dc := strings.ToLower(strings.TrimSpace(deviceClass))
	if dc == db.DeviceClassWeb {
		return ErrScanNotAllowed
	}
	if scanType == ScanTypeFull {
		cfg := s.store.GetServerSettings()
		allowed := parseFullScanAllowedDevices(cfg.FullScanAllowedDevicesJSON)
		if !allowed[dc] {
			return ErrFullScanNotAllowed
		}
	}
	return nil
}

func isValidScanType(t string) bool {
	switch t {
	case ScanTypeFull, ScanTypeIncremental, ScanTypeFolder:
		return true
	default:
		return false
	}
}

func (s *Service) loadScannableSource(q queryRunner, p *account.Principal, sourceID string) (*scannableSource, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	sid := strings.TrimSpace(sourceID)
	if sid == "" {
		return nil, ErrNotFound
	}
	var src scannableSource
	err := q.QueryRow(`
		SELECT id, household_id, kind, status
		FROM sources
		WHERE id = ? AND household_id = ?`,
		sid, p.HouseholdID,
	).Scan(&src.ID, &src.HouseholdID, &src.Kind, &src.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if src.Status == "deleted" {
		return nil, ErrSourceDeleted
	}
	if p.RestrictSources {
		var allowed int
		if err := q.QueryRow(`
			SELECT COUNT(*) FROM member_source_access
			WHERE household_id = ? AND member_id = ? AND source_id = ?`,
			p.HouseholdID, p.MemberID, sid,
		).Scan(&allowed); err != nil {
			return nil, err
		}
		if allowed == 0 {
			return nil, ErrForbidden
		}
	}
	if src.Kind != db.SourceKindQuark && src.Kind != db.SourceKindWebDAV {
		return nil, fmt.Errorf("%w: %s sources cannot be scanned", ErrInvalidInput, src.Kind)
	}
	return &src, nil
}

func loadScopedFolders(q queryRunner, hhID, sourceID string, folderID *string) ([]ScanFolderScope, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if folderID != nil && strings.TrimSpace(*folderID) != "" {
		rows, err = q.Query(`
			SELECT id, path, exclude_paths_json, library_hint
			FROM source_folders
			WHERE id = ? AND household_id = ? AND source_id = ?`,
			strings.TrimSpace(*folderID), hhID, sourceID,
		)
	} else {
		rows, err = q.Query(`
			SELECT id, path, exclude_paths_json, library_hint
			FROM source_folders
			WHERE household_id = ? AND source_id = ?
			ORDER BY path ASC`,
			hhID, sourceID,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]ScanFolderScope, 0)
	for rows.Next() {
		var (
			sc           ScanFolderScope
			excludesJSON string
		)
		if err := rows.Scan(&sc.ID, &sc.Path, &excludesJSON, &sc.LibraryHint); err != nil {
			return nil, err
		}
		sc.ExcludePaths = []string{}
		if excludesJSON != "" {
			var decoded []string
			if json.Unmarshal([]byte(excludesJSON), &decoded) == nil {
				for _, ex := range decoded {
					sc.ExcludePaths = append(sc.ExcludePaths, pathutil.NormalizePath(ex))
				}
			}
		}
		sc.Path = pathutil.NormalizePath(sc.Path)
		out = append(out, sc)
	}
	return out, rows.Err()
}

func inFoldersScope(normPath string, scopes []ScanFolderScope, checkSkippedDirs bool) bool {
	if len(scopes) == 0 {
		return false
	}
	parentDir := pathutil.ParentPath(normPath)
	for _, sc := range scopes {
		if !pathutil.IsFileAllowed(normPath, []string{sc.Path}, sc.ExcludePaths) {
			continue
		}
		if !checkSkippedDirs || !hasSkippedRelSegment(sc.Path, parentDir) {
			return true
		}
	}
	return false
}

func hasSkippedRelSegment(rootPath, dirPath string) bool {
	if dirPath == rootPath || dirPath == pathutil.RootPath {
		return false
	}
	var rel string
	if rootPath == pathutil.RootPath {
		rel = strings.TrimPrefix(dirPath, "/")
	} else if strings.HasPrefix(dirPath, rootPath+"/") {
		rel = strings.TrimPrefix(dirPath, rootPath+"/")
	} else {
		return false
	}
	if rel == "" {
		return false
	}
	for _, seg := range strings.Split(rel, "/") {
		if seg != "" && library.IsSkippedFolder(seg) {
			return true
		}
	}
	return false
}

func (s *Service) CreateSession(p *account.Principal, sourceID string, req CreateSessionRequest, ip string) (*ScanSessionView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) {
		return nil, ErrForbidden
	}

	scanType := strings.ToLower(strings.TrimSpace(req.Type))
	if !isValidScanType(scanType) {
		return nil, fmt.Errorf("%w: scan type must be full, incremental, or folder", ErrInvalidInput)
	}
	if err := s.checkDeviceScanAllowed(p.DeviceClass, scanType); err != nil {
		return nil, err
	}

	folderID := strings.TrimSpace(req.FolderID)
	if scanType == ScanTypeFolder && folderID == "" {
		return nil, fmt.Errorf("%w: folder_id is required for folder scan", ErrInvalidInput)
	}
	if scanType != ScanTypeFolder && folderID != "" {
		return nil, fmt.Errorf("%w: folder_id is only allowed for folder scan", ErrInvalidInput)
	}

	src, err := s.loadScannableSource(s.store.ReadDB(), p, sourceID)
	if err != nil {
		return nil, err
	}

	var folderPtr *string
	if folderID != "" {
		folderPtr = &folderID
	}
	scopes, err := loadScopedFolders(s.store.ReadDB(), p.HouseholdID, src.ID, folderPtr)
	if err != nil {
		return nil, err
	}
	if scanType == ScanTypeFolder && len(scopes) == 0 {
		return nil, ErrNotFound
	}

	var watermark int64
	err = s.store.ReadDB().QueryRow(`
		SELECT incremental_watermark FROM source_scan_state WHERE source_id = ? AND household_id = ?`,
		src.ID, p.HouseholdID,
	).Scan(&watermark)
	if errors.Is(err, sql.ErrNoRows) {
		watermark = 0
	} else if err != nil {
		return nil, err
	}

	sessID := uuid.NewString()
	nowMs := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO scan_sessions(
			id, household_id, source_id, folder_id, type, device_id, member_id,
			started_at, last_activity_at, status, progress_pct
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'running', 0)`,
		sessID, p.HouseholdID, src.ID, folderPtr, scanType, p.DeviceID, p.MemberID, nowMs, nowMs,
	); err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "scan.session_started",
		TargetType:  "source",
		TargetID:    src.ID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"session_id":   sessID,
			"type":         scanType,
			"device_class": p.DeviceClass,
		},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	view := &ScanSessionView{
		ID:                   sessID,
		HouseholdID:          p.HouseholdID,
		SourceID:             src.ID,
		FolderID:             folderPtr,
		Type:                 scanType,
		DeviceID:             p.DeviceID,
		MemberID:             p.MemberID,
		Status:               SessionRunning,
		StartedAt:            nowMs,
		LastActivityAt:       nowMs,
		ProgressPct:          0,
		Folders:              scopes,
		IncrementalWatermark: watermark,
	}

	s.publishScanProgress(view)
	return view, nil
}

func (s *Service) ListSourceSessions(p *account.Principal, sourceID string) ([]ScanSessionView, error) {
	src, err := s.loadScannableSource(s.store.ReadDB(), p, sourceID)
	if err != nil {
		return nil, err
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT id, household_id, source_id, folder_id, type, device_id, member_id,
		       status, started_at, last_activity_at, finished_at,
		       files_reported, files_added, files_changed, files_missing, progress_pct
		FROM scan_sessions
		WHERE household_id = ? AND source_id = ?
		ORDER BY started_at DESC
		LIMIT 20`,
		p.HouseholdID, src.ID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]ScanSessionView, 0)
	for rows.Next() {
		sv, err := scanSessionRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sv)
	}
	return out, rows.Err()
}

func (s *Service) loadSessionForDevice(q queryRunner, p *account.Principal, sessionID string) (*ScanSessionView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) {
		return nil, ErrForbidden
	}
	sid := strings.TrimSpace(sessionID)
	if sid == "" {
		return nil, ErrNotFound
	}

	sv, err := scanSessionRow(q.QueryRow(`
		SELECT id, household_id, source_id, folder_id, type, device_id, member_id,
		       status, started_at, last_activity_at, finished_at,
		       files_reported, files_added, files_changed, files_missing, progress_pct
		FROM scan_sessions
		WHERE id = ? AND household_id = ?`,
		sid, p.HouseholdID,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// Check owning source first (returns 410 if deleted even mid-scan).
	if _, err := s.loadScannableSource(q, p, sv.SourceID); err != nil {
		return nil, err
	}
	if sv.DeviceID != p.DeviceID {
		return nil, fmt.Errorf("%w: scan session belongs to another device", ErrForbidden)
	}
	return &sv, nil
}

func (s *Service) ReportProgress(p *account.Principal, sessionID string, req ProgressRequest) (*ScanSessionView, error) {
	pct := req.ProgressPct
	if pct < 0 {
		pct = 0
	} else if pct > 100 {
		pct = 100
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
	if sv.Status != SessionRunning {
		return nil, ErrSessionNotRunning
	}

	reported := sv.FilesReported
	if req.FilesReported != nil && *req.FilesReported > reported {
		reported = *req.FilesReported
	}

	if _, err := tx.Exec(`
		UPDATE scan_sessions
		SET progress_pct = ?, files_reported = ?, last_activity_at = ?
		WHERE id = ? AND household_id = ? AND status = 'running'`,
		pct, reported, nowMs, sv.ID, p.HouseholdID,
	); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	sv.ProgressPct = pct
	sv.FilesReported = reported
	sv.LastActivityAt = nowMs
	s.publishScanProgress(sv)
	return sv, nil
}

func (s *Service) CancelSession(p *account.Principal, sessionID, ip string) (*ScanSessionView, error) {
	res, err := s.CompleteSession(p, sessionID, CompleteSessionRequest{Complete: false}, ip)
	if err != nil {
		return nil, err
	}
	return &res.Session, nil
}

// MarkStaleSessions transitions abandoned running scan sessions to stale after 30 minutes of inactivity.
// Stale status is purely informational cleanup and never locks other scans.
func (s *Service) MarkStaleSessions() (int64, error) {
	now := s.nowFn()
	nowMs := now.UnixMilli()
	cutoff := now.Add(-StaleSessionTimeout).UnixMilli()
	res, err := s.store.DB().Exec(`
		UPDATE scan_sessions
		SET status = 'stale', finished_at = ?
		WHERE status = 'running' AND last_activity_at <= ?`,
		nowMs, cutoff,
	)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanSessionRow(r rowScanner) (ScanSessionView, error) {
	var (
		sv         ScanSessionView
		folderID   sql.NullString
		finishedAt sql.NullInt64
	)
	err := r.Scan(
		&sv.ID, &sv.HouseholdID, &sv.SourceID, &folderID, &sv.Type, &sv.DeviceID, &sv.MemberID,
		&sv.Status, &sv.StartedAt, &sv.LastActivityAt, &finishedAt,
		&sv.FilesReported, &sv.FilesAdded, &sv.FilesChanged, &sv.FilesMissing, &sv.ProgressPct,
	)
	if err != nil {
		return ScanSessionView{}, err
	}
	if folderID.Valid && folderID.String != "" {
		v := folderID.String
		sv.FolderID = &v
	}
	if finishedAt.Valid {
		v := finishedAt.Int64
		sv.FinishedAt = &v
	}
	return sv, nil
}

func (s *Service) publishScanProgress(sv *ScanSessionView) {
	if s.hub == nil || sv == nil {
		return
	}
	s.hub.PublishToHousehold(sv.HouseholdID, "scan.progress", map[string]any{
		"session_id":     sv.ID,
		"source_id":      sv.SourceID,
		"type":           sv.Type,
		"device_id":      sv.DeviceID,
		"status":         sv.Status,
		"progress_pct":   sv.ProgressPct,
		"files_reported": sv.FilesReported,
		"files_added":    sv.FilesAdded,
		"files_changed":  sv.FilesChanged,
		"files_missing":  sv.FilesMissing,
	})
}

func (s *Service) publishLibraryChanged(hhID string, seq int64) {
	if s.hub == nil || seq <= 0 {
		return
	}
	s.hub.PublishToHousehold(hhID, "library.changed", map[string]any{
		"seq": seq,
	})
}
