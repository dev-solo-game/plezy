package source

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/security"
)

type Service struct {
	store *db.Store
	hub   *events.Hub
	nowFn func() time.Time
}

func NewService(store *db.Store, hub *events.Hub) *Service {
	return &Service{
		store: store,
		hub:   hub,
		nowFn: time.Now,
	}
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
	}
}

type sourceRow struct {
	ID              string
	HouseholdID     string
	Kind            string
	Name            string
	IdentityKey     string
	IdentityUnique  bool
	CreatedByMember string
	CreatedByDevice string
	Status          string
	CreatedAt       int64
	UpdatedAt       int64
}

func (r *sourceRow) toView() SourceView {
	return SourceView{
		ID:              r.ID,
		HouseholdID:     r.HouseholdID,
		Kind:            r.Kind,
		Name:            r.Name,
		IdentityKey:     r.IdentityKey,
		IdentityUnique:  r.IdentityUnique,
		CreatedByMember: r.CreatedByMember,
		CreatedByDevice: r.CreatedByDevice,
		Status:          r.Status,
		CreatedAt:       r.CreatedAt,
		UpdatedAt:       r.UpdatedAt,
	}
}

func parseSourceAddPolicy(rawJSON string) map[string][]string {
	out := make(map[string][]string)
	var parsed map[string][]string
	if err := json.Unmarshal([]byte(rawJSON), &parsed); err == nil && parsed != nil {
		for dev, kinds := range parsed {
			d := strings.ToLower(strings.TrimSpace(dev))
			if d == "" {
				continue
			}
			normKinds := make([]string, 0, len(kinds))
			for _, k := range kinds {
				if kn := strings.ToLower(strings.TrimSpace(k)); kn != "" {
					normKinds = append(normKinds, kn)
				}
			}
			out[d] = normKinds
		}
		return out
	}
	_ = json.Unmarshal([]byte(db.DefaultSourceAddPolicyJSON), &out)
	return out
}

func deviceCanAddKind(policy map[string][]string, deviceClass, kind string) bool {
	dc := strings.ToLower(strings.TrimSpace(deviceClass))
	k := strings.ToLower(strings.TrimSpace(kind))
	for _, allowed := range policy[dc] {
		if allowed == k {
			return true
		}
	}
	return false
}

func allowedDevicesForKind(policy map[string][]string, kind string) []string {
	k := strings.ToLower(strings.TrimSpace(kind))
	var out []string
	for dev, kinds := range policy {
		for _, allowed := range kinds {
			if allowed == k {
				out = append(out, dev)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

func (s *Service) checkDevicePolicy(deviceClass, kind string) error {
	cfg := s.store.GetServerSettings()
	policy := parseSourceAddPolicy(cfg.SourceAddPolicyJSON)
	if deviceCanAddKind(policy, deviceClass, kind) {
		return nil
	}
	return &KindNotAllowedError{
		DeviceClass:    deviceClass,
		Kind:           kind,
		AllowedDevices: allowedDevicesForKind(policy, kind),
	}
}

func actorTypeForPrincipal(p *account.Principal) string {
	if p != nil && p.LoginMode == account.LoginModeMemberOnly {
		return "member"
	}
	return "account"
}

func (s *Service) loadSourceForPrincipal(p *account.Principal, sourceID string) (*sourceRow, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	sid := strings.TrimSpace(sourceID)
	if sid == "" {
		return nil, ErrNotFound
	}

	var (
		row       sourceRow
		uniqueInt int
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT id, household_id, kind, name, identity_key, identity_unique,
		       created_by_member, created_by_device, status, created_at, updated_at
		FROM sources
		WHERE id = ? AND household_id = ?`,
		sid, p.HouseholdID,
	).Scan(
		&row.ID, &row.HouseholdID, &row.Kind, &row.Name, &row.IdentityKey, &uniqueInt,
		&row.CreatedByMember, &row.CreatedByDevice, &row.Status, &row.CreatedAt, &row.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if row.Status == StatusDeleted {
		return nil, ErrSourceDeleted
	}
	row.IdentityUnique = uniqueInt == 1

	if p.RestrictSources {
		var allowed int
		if err := s.store.ReadDB().QueryRow(`
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
	return &row, nil
}

func (s *Service) ListSources(p *account.Principal) ([]SourceView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}

	query := `
		SELECT s.id, s.household_id, s.kind, s.name, s.identity_key, s.identity_unique,
		       s.created_by_member, s.created_by_device, s.status, s.created_at, s.updated_at
		FROM sources s
		WHERE s.household_id = ? AND s.status = 'active'`
	args := []any{p.HouseholdID}
	if p.RestrictSources {
		query += ` AND EXISTS (
			SELECT 1 FROM member_source_access msa
			WHERE msa.household_id = s.household_id AND msa.member_id = ? AND msa.source_id = s.id
		)`
		args = append(args, p.MemberID)
	}
	query += ` ORDER BY s.created_at ASC`

	rows, err := s.store.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SourceView, 0)
	for rows.Next() {
		var (
			sv        SourceView
			uniqueInt int
		)
		if err := rows.Scan(
			&sv.ID, &sv.HouseholdID, &sv.Kind, &sv.Name, &sv.IdentityKey, &uniqueInt,
			&sv.CreatedByMember, &sv.CreatedByDevice, &sv.Status, &sv.CreatedAt, &sv.UpdatedAt,
		); err != nil {
			return nil, err
		}
		sv.IdentityUnique = uniqueInt == 1
		out = append(out, sv)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}

	if err := s.hydrateSources(p.HouseholdID, out); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Service) GetSource(p *account.Principal, sourceID string) (*SourceView, error) {
	row, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}
	out := []SourceView{row.toView()}
	if err := s.hydrateSources(p.HouseholdID, out); err != nil {
		return nil, err
	}
	return &out[0], nil
}

func (s *Service) CreateSource(p *account.Principal, req CreateSourceRequest, ip string) (*SourceView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}

	kind := strings.ToLower(strings.TrimSpace(req.Kind))
	if !IsValidKind(kind) {
		return nil, fmt.Errorf("%w: unsupported source kind %q", ErrInvalidInput, req.Kind)
	}
	if err := s.checkDevicePolicy(p.DeviceClass, kind); err != nil {
		return nil, err
	}

	name := strings.TrimSpace(req.Name)
	if name == "" || len([]rune(name)) > 128 {
		return nil, fmt.Errorf("%w: name must be 1-128 characters", ErrInvalidInput)
	}
	identityKey := strings.TrimSpace(req.IdentityKey)
	if identityKey == "" || len(identityKey) > 256 {
		return nil, fmt.Errorf("%w: identity_key must be 1-256 characters", ErrInvalidInput)
	}
	ciphertext := strings.TrimSpace(req.Ciphertext)
	if ciphertext == "" || len(ciphertext) > MaxCredentialBytes {
		return nil, fmt.Errorf("%w: ciphertext must be non-empty and <= %d bytes", ErrInvalidInput, MaxCredentialBytes)
	}
	keyEpoch := req.KeyEpoch
	if keyEpoch <= 0 {
		keyEpoch = 1
	}

	hasFoldersAndScan := KindHasFoldersAndScan(kind)
	if !hasFoldersAndScan && len(req.Folders) > 0 {
		return nil, fmt.Errorf("%w: %s sources do not support folders", ErrInvalidInput, kind)
	}

	normFolders := make([]normalizedFolder, 0, len(req.Folders))
	seenPaths := make(map[string]struct{}, len(req.Folders))
	for _, f := range req.Folders {
		nf, err := normalizeFolderInput(f)
		if err != nil {
			return nil, err
		}
		if _, dup := seenPaths[nf.path]; dup {
			return nil, fmt.Errorf("%w: duplicate folder path %q", ErrConflict, nf.path)
		}
		seenPaths[nf.path] = struct{}{}
		normFolders = append(normFolders, nf)
	}

	identityUnique := KindHasUniqueIdentity(kind)
	uniqueInt := 0
	if identityUnique {
		uniqueInt = 1
	}
	srcID := uuid.NewString()
	nowMs := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	// Quota check (G9)
	var maxSources, activeCount int
	if err := tx.QueryRow(`SELECT quota_max_sources FROM households WHERE id = ?`, p.HouseholdID).Scan(&maxSources); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if err := tx.QueryRow(`SELECT COUNT(*) FROM sources WHERE household_id = ? AND status = 'active'`, p.HouseholdID).Scan(&activeCount); err != nil {
		return nil, err
	}
	if activeCount >= maxSources {
		return nil, &QuotaExceededError{Quota: "sources", Limit: maxSources, Current: activeCount}
	}

	// Deduplication (§4.3)
	if identityUnique {
		var existingID string
		err := tx.QueryRow(`
			SELECT id FROM sources
			WHERE household_id = ? AND kind = ? AND identity_key = ? AND status = 'active'
			LIMIT 1`,
			p.HouseholdID, kind, identityKey,
		).Scan(&existingID)
		if err == nil {
			return nil, &DuplicateSourceError{ExistingSourceID: existingID}
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
	} else {
		rows, err := tx.Query(`
			SELECT id, name, created_at FROM sources
			WHERE household_id = ? AND kind = ? AND identity_key = ? AND status = 'active'
			ORDER BY created_at ASC`,
			p.HouseholdID, kind, identityKey,
		)
		if err != nil {
			return nil, err
		}
		var similar []SimilarSourceRef
		for rows.Next() {
			var ref SimilarSourceRef
			if scanErr := rows.Scan(&ref.ID, &ref.Name, &ref.CreatedAt); scanErr != nil {
				_ = rows.Close()
				return nil, scanErr
			}
			similar = append(similar, ref)
		}
		_ = rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
		if len(similar) > 0 && !req.ConfirmDuplicate {
			return nil, &SimilarSourceError{SimilarSources: similar}
		}
	}

	if _, err := tx.Exec(`
		INSERT INTO sources(
			id, household_id, kind, name, identity_key, identity_unique,
			created_by_member, created_by_device, status, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
		srcID, p.HouseholdID, kind, name, identityKey, uniqueInt,
		p.MemberID, p.DeviceID, nowMs, nowMs,
	); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`
		INSERT INTO source_credentials(
			source_id, household_id, ciphertext, version, key_epoch, status, updated_by_device, updated_at
		) VALUES (?, ?, ?, 1, ?, 'valid', ?, ?)`,
		srcID, p.HouseholdID, ciphertext, keyEpoch, p.DeviceID, nowMs,
	); err != nil {
		return nil, err
	}

	if hasFoldersAndScan {
		if _, err := tx.Exec(`
			INSERT INTO source_scan_state(source_id, household_id, incremental_watermark, last_scan_result, updated_at)
			VALUES (?, ?, 0, '', ?)`,
			srcID, p.HouseholdID, nowMs,
		); err != nil {
			return nil, err
		}
		for _, nf := range normFolders {
			fid := uuid.NewString()
			if _, err := tx.Exec(`
				INSERT INTO source_folders(
					id, household_id, source_id, path, exclude_paths_json, library_hint, created_at, updated_at
				) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
				fid, p.HouseholdID, srcID, nf.path, nf.excludesJSON, nf.libraryHint, nowMs, nowMs,
			); err != nil {
				return nil, err
			}
		}
	}

	if p.RestrictSources {
		if _, err := tx.Exec(`
			INSERT OR IGNORE INTO member_source_access(household_id, member_id, source_id)
			VALUES (?, ?, ?)`,
			p.HouseholdID, p.MemberID, srcID,
		); err != nil {
			return nil, err
		}
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source", srcID, "create", nowMs)
	if err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.created",
		TargetType:  "source",
		TargetID:    srcID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"kind":         kind,
			"device_class": p.DeviceClass,
			"folder_count": len(normFolders),
		},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	s.publishSourceChanged(p.HouseholdID, srcID, "create", seq)
	return s.GetSource(p, srcID)
}

func (s *Service) UpdateSource(p *account.Principal, sourceID string, req UpdateSourceRequest, ip string) (*SourceView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}
	if req.Name == nil {
		return nil, fmt.Errorf("%w: name is required", ErrInvalidInput)
	}
	name := strings.TrimSpace(*req.Name)
	if name == "" || len([]rune(name)) > 128 {
		return nil, fmt.Errorf("%w: name must be 1-128 characters", ErrInvalidInput)
	}

	row, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE sources SET name = ?, updated_at = ?
		WHERE id = ? AND household_id = ? AND status = 'active'`,
		name, nowMs, row.ID, p.HouseholdID,
	); err != nil {
		return nil, err
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source", row.ID, "update", nowMs)
	if err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.updated",
		TargetType:  "source",
		TargetID:    row.ID,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"kind": row.Kind},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	s.publishSourceChanged(p.HouseholdID, row.ID, "update", seq)
	return s.GetSource(p, row.ID)
}

// DeleteSource soft-deletes a media source, immediately purges its encrypted credential,
// stops any running scan sessions, and notifies connected clients (G15).
func (s *Service) DeleteSource(p *account.Principal, sourceID, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	if !p.HasPerm(account.PermManageSources) {
		return ErrForbidden
	}
	row, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return err
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE sources SET status = 'deleted', deleted_at = ?, updated_at = ?
		WHERE id = ? AND household_id = ? AND status = 'active'`,
		nowMs, nowMs, row.ID, p.HouseholdID,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrSourceDeleted
	}

	if _, err := tx.Exec(`DELETE FROM source_credentials WHERE source_id = ? AND household_id = ?`, row.ID, p.HouseholdID); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		UPDATE scan_sessions SET status = 'partial', finished_at = ?
		WHERE source_id = ? AND household_id = ? AND status = 'running'`,
		nowMs, row.ID, p.HouseholdID,
	); err != nil {
		return err
	}

	seq, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source", row.ID, "delete", nowMs)
	if err != nil {
		return err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.deleted",
		TargetType:  "source",
		TargetID:    row.ID,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"kind": row.Kind},
	}); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	s.publishSourceChanged(p.HouseholdID, row.ID, "delete", seq)
	return nil
}

// PurgeExpiredDeletedSources permanently removes soft-deleted sources older than 30 days.
func (s *Service) PurgeExpiredDeletedSources() (int64, error) {
	now := s.nowFn()
	nowMs := now.UnixMilli()
	cutoff := now.Add(-SourceDeletionRetention).UnixMilli()

	rows, err := s.store.ReadDB().Query(`
		SELECT id, household_id, kind
		FROM sources
		WHERE status = 'deleted' AND deleted_at IS NOT NULL AND deleted_at <= ?`,
		cutoff,
	)
	if err != nil {
		return 0, err
	}
	type purgeTarget struct {
		id   string
		hhID string
		kind string
	}
	var targets []purgeTarget
	for rows.Next() {
		var t purgeTarget
		if rows.Scan(&t.id, &t.hhID, &t.kind) == nil {
			targets = append(targets, t)
		}
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	var purged int64
	for _, t := range targets {
		tx, err := s.store.DB().Begin()
		if err != nil {
			return purged, err
		}
		res, err := tx.Exec(`DELETE FROM sources WHERE id = ? AND household_id = ? AND status = 'deleted'`, t.id, t.hhID)
		if err != nil {
			_ = tx.Rollback()
			return purged, err
		}
		n, _ := res.RowsAffected()
		if n > 0 {
			if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
				ActorType:   "system",
				ActorID:     "cleanup",
				HouseholdID: t.hhID,
				Action:      "system.source_purged",
				TargetType:  "source",
				TargetID:    t.id,
				Detail:      map[string]any{"kind": t.kind},
			}); err != nil {
				_ = tx.Rollback()
				return purged, err
			}
		}
		if err := tx.Commit(); err != nil {
			return purged, err
		}
		purged += n
	}
	return purged, nil
}

func (s *Service) hydrateSources(hhID string, items []SourceView) error {
	if len(items) == 0 {
		return nil
	}
	idxMap := make(map[string]int, len(items))
	inArgs := make([]any, 0, len(items)+1)
	inArgs = append(inArgs, hhID)
	for i := range items {
		idxMap[items[i].ID] = i
		inArgs = append(inArgs, items[i].ID)
		if KindHasFoldersAndScan(items[i].Kind) {
			items[i].Folders = make([]FolderView, 0)
		}
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(items)), ",")

	// Credential metadata (never ciphertext)
	credRows, err := s.store.ReadDB().Query(
		fmt.Sprintf(`
			SELECT source_id, version, key_epoch, status, updated_by_device, updated_at
			FROM source_credentials
			WHERE household_id = ? AND source_id IN (%s)`, ph),
		inArgs...,
	)
	if err != nil {
		return err
	}
	for credRows.Next() {
		var (
			sid string
			m   CredentialMeta
		)
		if err := credRows.Scan(&sid, &m.Version, &m.KeyEpoch, &m.Status, &m.UpdatedByDevice, &m.UpdatedAt); err != nil {
			_ = credRows.Close()
			return err
		}
		if idx, ok := idxMap[sid]; ok {
			cm := m
			items[idx].CredentialMeta = &cm
		}
	}
	_ = credRows.Close()
	if err := credRows.Err(); err != nil {
		return err
	}

	// Scan states
	scanRows, err := s.store.ReadDB().Query(
		fmt.Sprintf(`
			SELECT source_id, incremental_watermark, last_full_scan_at, last_scan_result, updated_at
			FROM source_scan_state
			WHERE household_id = ? AND source_id IN (%s)`, ph),
		inArgs...,
	)
	if err != nil {
		return err
	}
	for scanRows.Next() {
		var (
			sid      string
			st       ScanState
			lastFull sql.NullInt64
		)
		if err := scanRows.Scan(&sid, &st.IncrementalWatermark, &lastFull, &st.LastScanResult, &st.UpdatedAt); err != nil {
			_ = scanRows.Close()
			return err
		}
		if lastFull.Valid {
			v := lastFull.Int64
			st.LastFullScanAt = &v
		}
		if idx, ok := idxMap[sid]; ok && KindHasFoldersAndScan(items[idx].Kind) {
			copySt := st
			items[idx].ScanState = &copySt
		}
	}
	_ = scanRows.Close()
	if err := scanRows.Err(); err != nil {
		return err
	}

	// Folders
	fRows, err := s.store.ReadDB().Query(
		fmt.Sprintf(`
			SELECT id, household_id, source_id, path, exclude_paths_json, library_hint, baseline_at, created_at, updated_at
			FROM source_folders
			WHERE household_id = ? AND source_id IN (%s)
			ORDER BY path ASC`, ph),
		inArgs...,
	)
	if err != nil {
		return err
	}
	for fRows.Next() {
		fv, err := scanFolderView(fRows)
		if err != nil {
			_ = fRows.Close()
			return err
		}
		if idx, ok := idxMap[fv.SourceID]; ok && KindHasFoldersAndScan(items[idx].Kind) {
			items[idx].Folders = append(items[idx].Folders, fv)
		}
	}
	_ = fRows.Close()
	return fRows.Err()
}

func (s *Service) publishSourceChanged(hhID, sourceID, op string, seq int64) {
	if s.hub == nil {
		return
	}
	s.hub.PublishToHousehold(hhID, "source.changed", map[string]any{
		"source_id": sourceID,
		"op":        op,
		"seq":       seq,
	})
}
