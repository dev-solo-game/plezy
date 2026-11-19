package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
)

func ValidMountKind(kind string) bool {
	switch kind {
	case "local", "smb", "webdav", "quark":
		return true
	default:
		return false
	}
}

func (s *Store) sealSecretsMap(secrets map[string]string) (string, error) {
	clean := make(map[string]string)
	for k, v := range secrets {
		if strings.TrimSpace(v) != "" {
			clean[k] = v
		}
	}
	if len(clean) == 0 {
		return "", nil
	}
	raw, err := json.Marshal(clean)
	if err != nil {
		return "", err
	}
	return s.vault.Seal(string(raw))
}

func (s *Store) openSecretsMap(sealed string) map[string]string {
	out := make(map[string]string)
	if strings.TrimSpace(sealed) == "" {
		return out
	}
	plain, err := s.vault.Open(sealed)
	if err != nil {
		return out
	}
	_ = json.Unmarshal([]byte(plain), &out)
	return out
}

func (s *Store) CreateMount(name, kind string, config map[string]any, secrets map[string]string, enabled bool) (MountRecord, error) {
	name = strings.TrimSpace(name)
	kind = strings.ToLower(strings.TrimSpace(kind))
	if name == "" || !ValidMountKind(kind) {
		return MountRecord{}, fmt.Errorf("%w: invalid mount name or kind", ErrInvalidInput)
	}
	if config == nil {
		config = make(map[string]any)
	}
	cfgBytes, err := json.Marshal(config)
	if err != nil {
		return MountRecord{}, err
	}
	sealed, err := s.sealSecretsMap(secrets)
	if err != nil {
		return MountRecord{}, err
	}
	now := s.NowMs()
	id := uuid.NewString()
	enInt := 0
	if enabled {
		enInt = 1
	}

	tx, err := s.db.Begin()
	if err != nil {
		return MountRecord{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO mounts(id, name, kind, config_json, encrypted_secrets, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, name, kind, string(cfgBytes), sealed, enInt, now, now,
	); err != nil {
		return MountRecord{}, err
	}
	if _, err := tx.Exec(`
		INSERT INTO mount_scan_states(mount_id, scan_id, status) VALUES (?, 0, 'idle')`,
		id,
	); err != nil {
		return MountRecord{}, err
	}
	if err := tx.Commit(); err != nil {
		return MountRecord{}, err
	}
	return s.GetMount(id)
}

func (s *Store) UpdateMount(id string, name string, config map[string]any, secrets *map[string]string, enabled *bool) (MountRecord, error) {
	existing, err := s.GetMount(id)
	if err != nil {
		return MountRecord{}, err
	}
	if trimmed := strings.TrimSpace(name); trimmed != "" {
		existing.Name = trimmed
	}
	if config != nil {
		existing.Config = config
	}
	if secrets != nil {
		merged := make(map[string]string, len(existing.Secrets))
		for k, v := range existing.Secrets {
			merged[k] = v
		}
		for k, v := range *secrets {
			if strings.TrimSpace(v) == "" {
				delete(merged, k)
			} else {
				merged[k] = v
			}
		}
		existing.Secrets = merged
	}
	if enabled != nil {
		existing.Enabled = *enabled
	}

	cfgBytes, err := json.Marshal(existing.Config)
	if err != nil {
		return MountRecord{}, err
	}
	sealed, err := s.sealSecretsMap(existing.Secrets)
	if err != nil {
		return MountRecord{}, err
	}
	enInt := 0
	if existing.Enabled {
		enInt = 1
	}
	now := s.NowMs()

	res, err := s.db.Exec(`
		UPDATE mounts
		SET name = ?, config_json = ?, encrypted_secrets = ?, enabled = ?, updated_at = ?
		WHERE id = ?`,
		existing.Name, string(cfgBytes), sealed, enInt, now, id,
	)
	if err != nil {
		return MountRecord{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return MountRecord{}, ErrNotFound
	}
	return s.GetMount(id)
}

func (s *Store) UpdateMountSecretKey(id, key, val string) error {
	existing, err := s.GetMount(id)
	if err != nil {
		return err
	}
	if existing.Secrets == nil {
		existing.Secrets = make(map[string]string)
	}
	if val == "" {
		delete(existing.Secrets, key)
	} else {
		existing.Secrets[key] = val
	}
	sealed, err := s.sealSecretsMap(existing.Secrets)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`UPDATE mounts SET encrypted_secrets = ?, updated_at = ? WHERE id = ?`, sealed, s.NowMs(), id)
	return err
}

func (s *Store) DeleteMount(id string) error {
	res, err := s.db.Exec(`DELETE FROM mounts WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) scanMountRow(row interface {
	Scan(dest ...any) error
}) (MountRecord, error) {
	var m MountRecord
	var cfgJSON, sealed string
	var enabledInt int
	var scanID sql.NullInt64
	var scanStatus sql.NullString
	var pendingJSON sql.NullString
	var quarkCP sql.NullString
	var startedAt, finishedAt sql.NullInt64
	var lastErr sql.NullString
	if err := row.Scan(
		&m.ID, &m.Name, &m.Kind, &cfgJSON, &sealed, &enabledInt, &m.CreatedAt, &m.UpdatedAt,
		&scanID, &scanStatus, &pendingJSON, &quarkCP, &startedAt, &finishedAt, &lastErr,
		&m.VideoCount, &m.TotalFileBytes, &m.MatchedItemCount,
	); err != nil {
		return MountRecord{}, err
	}
	m.Enabled = enabledInt != 0
	m.Config = make(map[string]any)
	_ = json.Unmarshal([]byte(cfgJSON), &m.Config)
	m.Secrets = s.openSecretsMap(sealed)
	m.HasSecret = len(m.Secrets) > 0
	if scanStatus.Valid {
		st := &MountScanState{
			MountID: m.ID,
			ScanID:  scanID.Int64,
			Status:  scanStatus.String,
		}
		if pendingJSON.Valid {
			st.PendingJSON = &pendingJSON.String
		}
		if quarkCP.Valid {
			st.QuarkCheckpoint = &quarkCP.String
		}
		if startedAt.Valid {
			st.StartedAt = &startedAt.Int64
		}
		if finishedAt.Valid {
			st.FinishedAt = &finishedAt.Int64
		}
		if lastErr.Valid {
			st.LastError = &lastErr.String
		}
		m.ScanState = st
	}
	return m, nil
}

const mountSelectCols = `
	SELECT m.id, m.name, m.kind, m.config_json, m.encrypted_secrets, m.enabled, m.created_at, m.updated_at,
		st.scan_id, st.status, st.pending_json, st.quark_checkpoint, st.started_at, st.finished_at, st.last_error,
		COALESCE((SELECT COUNT(*) FROM media_files mf WHERE mf.mount_id = m.id AND mf.role = 'video'), 0),
		COALESCE((SELECT SUM(COALESCE(mf.size, 0)) FROM media_files mf WHERE mf.mount_id = m.id AND mf.role = 'video'), 0),
		COALESCE((SELECT COUNT(DISTINCT COALESCE(mi.show_id, mi.id))
			FROM media_files mf
			JOIN media_items mi ON mi.id = mf.item_id
			WHERE mf.mount_id = m.id AND mf.role = 'video' AND mf.match_state = 'matched'), 0)
	FROM mounts m
	LEFT JOIN mount_scan_states st ON st.mount_id = m.id`

func (s *Store) GetMount(id string) (MountRecord, error) {
	row := s.ReadDB().QueryRow(mountSelectCols+` WHERE m.id = ?`, id)
	m, err := s.scanMountRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return MountRecord{}, ErrNotFound
	}
	return m, err
}

func (s *Store) ListMounts() ([]MountRecord, error) {
	rows, err := s.ReadDB().Query(mountSelectCols + ` ORDER BY m.created_at ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]MountRecord, 0)
	for rows.Next() {
		m, err := s.scanMountRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Store) TryAcquireScanLock(mountID string) bool {
	s.scanLockMu.Lock()
	defer s.scanLockMu.Unlock()
	if _, busy := s.activeScans[mountID]; busy {
		return false
	}
	s.activeScans[mountID] = struct{}{}
	return true
}

func (s *Store) ReleaseScanLock(mountID string) {
	s.scanLockMu.Lock()
	defer s.scanLockMu.Unlock()
	delete(s.activeScans, mountID)
}

func (s *Store) IsMountScanning(mountID string) bool {
	s.scanLockMu.Lock()
	defer s.scanLockMu.Unlock()
	_, busy := s.activeScans[mountID]
	return busy
}

func (s *Store) GetScanState(mountID string) (MountScanState, error) {
	var st MountScanState
	var pending, cp, lastErr sql.NullString
	var started, finished sql.NullInt64
	err := s.db.QueryRow(`
		SELECT mount_id, scan_id, status, pending_json, quark_checkpoint, started_at, finished_at, last_error
		FROM mount_scan_states WHERE mount_id = ?`,
		mountID,
	).Scan(&st.MountID, &st.ScanID, &st.Status, &pending, &cp, &started, &finished, &lastErr)
	if errors.Is(err, sql.ErrNoRows) {
		return MountScanState{MountID: mountID, Status: "idle"}, nil
	}
	if err != nil {
		return MountScanState{}, err
	}
	if pending.Valid {
		st.PendingJSON = &pending.String
	}
	if cp.Valid {
		st.QuarkCheckpoint = &cp.String
	}
	if started.Valid {
		st.StartedAt = &started.Int64
	}
	if finished.Valid {
		st.FinishedAt = &finished.Int64
	}
	if lastErr.Valid {
		st.LastError = &lastErr.String
	}
	return st, nil
}

func (s *Store) SaveScanState(st MountScanState) error {
	_, err := s.db.Exec(`
		INSERT INTO mount_scan_states(mount_id, scan_id, status, pending_json, quark_checkpoint, started_at, finished_at, last_error)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(mount_id) DO UPDATE SET
			scan_id = excluded.scan_id,
			status = excluded.status,
			pending_json = excluded.pending_json,
			quark_checkpoint = excluded.quark_checkpoint,
			started_at = excluded.started_at,
			finished_at = excluded.finished_at,
			last_error = excluded.last_error`,
		st.MountID, st.ScanID, st.Status, st.PendingJSON, st.QuarkCheckpoint, st.StartedAt, st.FinishedAt, st.LastError,
	)
	return err
}

// ResetStaleRunningScans resets any scans left in 'running' state after a crash/restart.
func (s *Store) ResetStaleRunningScans() error {
	_, err := s.db.Exec(`UPDATE mount_scan_states SET status = 'idle' WHERE status = 'running'`)
	return err
}
