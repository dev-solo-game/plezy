package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
)

func ValidExternalServerKind(kind string) bool {
	switch kind {
	case "emby", "jellyfin":
		return true
	default:
		return false
	}
}

func ValidExternalAuthMode(mode string) bool {
	switch mode {
	case "password", "apikey":
		return true
	default:
		return false
	}
}

func (s *Store) ListExternalServers() ([]ExternalServerRecord, error) {
	rows, err := s.ReadDB().Query(`
		SELECT id, name, kind, base_url, auth_mode, username, user_id, device_id,
		       server_id, server_version, allow_insecure_tls, encrypted_secrets,
		       enabled, created_at, updated_at
		FROM external_servers
		ORDER BY created_at ASC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]ExternalServerRecord, 0)
	for rows.Next() {
		rec, err := s.scanExternalServerRow(rows)
		if err != nil {
			continue
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

func (s *Store) GetExternalServer(id string) (ExternalServerRecord, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return ExternalServerRecord{}, ErrNotFound
	}
	row := s.ReadDB().QueryRow(`
		SELECT id, name, kind, base_url, auth_mode, username, user_id, device_id,
		       server_id, server_version, allow_insecure_tls, encrypted_secrets,
		       enabled, created_at, updated_at
		FROM external_servers
		WHERE id = ?`, id,
	)
	rec, err := s.scanExternalServerRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return ExternalServerRecord{}, ErrNotFound
	}
	return rec, err
}

func (s *Store) scanExternalServerRow(sc interface{ Scan(...any) error }) (ExternalServerRecord, error) {
	var rec ExternalServerRecord
	var sealed string
	var insecureInt, enabledInt int
	if err := sc.Scan(
		&rec.ID,
		&rec.Name,
		&rec.Kind,
		&rec.BaseURL,
		&rec.AuthMode,
		&rec.Username,
		&rec.UserID,
		&rec.DeviceID,
		&rec.ServerID,
		&rec.ServerVersion,
		&insecureInt,
		&sealed,
		&enabledInt,
		&rec.CreatedAt,
		&rec.UpdatedAt,
	); err != nil {
		return ExternalServerRecord{}, err
	}
	rec.AllowInsecureTLS = insecureInt == 1
	rec.Enabled = enabledInt == 1
	rec.Secrets = s.openSecretsMap(sealed)
	rec.HasToken = strings.TrimSpace(rec.Secrets["token"]) != ""
	return rec, nil
}

func (s *Store) CreateExternalServer(rec ExternalServerRecord) (ExternalServerRecord, error) {
	rec.Name = strings.TrimSpace(rec.Name)
	rec.Kind = strings.ToLower(strings.TrimSpace(rec.Kind))
	rec.BaseURL = strings.TrimRight(strings.TrimSpace(rec.BaseURL), "/")
	rec.AuthMode = strings.ToLower(strings.TrimSpace(rec.AuthMode))
	if rec.AuthMode == "" {
		rec.AuthMode = "password"
	}
	if rec.Name == "" || !ValidExternalServerKind(rec.Kind) || !ValidExternalAuthMode(rec.AuthMode) || rec.BaseURL == "" {
		return ExternalServerRecord{}, fmt.Errorf("%w: invalid external server configuration", ErrInvalidInput)
	}
	if strings.TrimSpace(rec.ID) == "" {
		rec.ID = uuid.NewString()
	}
	if strings.TrimSpace(rec.DeviceID) == "" {
		rec.DeviceID = "ttplay-" + uuid.NewString()
	}
	sealed, err := s.sealSecretsMap(rec.Secrets)
	if err != nil {
		return ExternalServerRecord{}, err
	}
	now := s.NowMs()
	insecureInt := 0
	if rec.AllowInsecureTLS {
		insecureInt = 1
	}
	enabledInt := 0
	if rec.Enabled {
		enabledInt = 1
	}

	_, err = s.db.Exec(`
		INSERT INTO external_servers(
			id, name, kind, base_url, auth_mode, username, user_id, device_id,
			server_id, server_version, allow_insecure_tls, encrypted_secrets,
			enabled, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.ID,
		rec.Name,
		rec.Kind,
		rec.BaseURL,
		rec.AuthMode,
		strings.TrimSpace(rec.Username),
		strings.TrimSpace(rec.UserID),
		strings.TrimSpace(rec.DeviceID),
		strings.TrimSpace(rec.ServerID),
		strings.TrimSpace(rec.ServerVersion),
		insecureInt,
		sealed,
		enabledInt,
		now,
		now,
	)
	if err != nil {
		return ExternalServerRecord{}, err
	}
	return s.GetExternalServer(rec.ID)
}

func (s *Store) UpdateExternalServer(id string, upd ExternalServerUpdate) (ExternalServerRecord, error) {
	existing, err := s.GetExternalServer(id)
	if err != nil {
		return ExternalServerRecord{}, err
	}
	if upd.Name != nil {
		if trimmed := strings.TrimSpace(*upd.Name); trimmed != "" {
			existing.Name = trimmed
		} else {
			return ExternalServerRecord{}, fmt.Errorf("%w: server name cannot be empty", ErrInvalidInput)
		}
	}
	if upd.Kind != nil {
		k := strings.ToLower(strings.TrimSpace(*upd.Kind))
		if !ValidExternalServerKind(k) {
			return ExternalServerRecord{}, fmt.Errorf("%w: invalid external server kind", ErrInvalidInput)
		}
		existing.Kind = k
	}
	if upd.BaseURL != nil {
		u := strings.TrimRight(strings.TrimSpace(*upd.BaseURL), "/")
		if u == "" {
			return ExternalServerRecord{}, fmt.Errorf("%w: base_url cannot be empty", ErrInvalidInput)
		}
		existing.BaseURL = u
	}
	if upd.AuthMode != nil {
		m := strings.ToLower(strings.TrimSpace(*upd.AuthMode))
		if !ValidExternalAuthMode(m) {
			return ExternalServerRecord{}, fmt.Errorf("%w: invalid auth_mode", ErrInvalidInput)
		}
		existing.AuthMode = m
	}
	if upd.Username != nil {
		existing.Username = strings.TrimSpace(*upd.Username)
	}
	if upd.UserID != nil {
		existing.UserID = strings.TrimSpace(*upd.UserID)
	}
	if upd.DeviceID != nil && strings.TrimSpace(*upd.DeviceID) != "" {
		existing.DeviceID = strings.TrimSpace(*upd.DeviceID)
	}
	if upd.ServerID != nil {
		existing.ServerID = strings.TrimSpace(*upd.ServerID)
	}
	if upd.ServerVersion != nil {
		existing.ServerVersion = strings.TrimSpace(*upd.ServerVersion)
	}
	if upd.AllowInsecureTLS != nil {
		existing.AllowInsecureTLS = *upd.AllowInsecureTLS
	}
	if upd.Enabled != nil {
		existing.Enabled = *upd.Enabled
	}
	if upd.Secrets != nil {
		merged := make(map[string]string, len(existing.Secrets))
		for k, v := range existing.Secrets {
			merged[k] = v
		}
		for k, v := range *upd.Secrets {
			if strings.TrimSpace(v) == "" {
				delete(merged, k)
			} else {
				merged[k] = v
			}
		}
		existing.Secrets = merged
	}

	sealed, err := s.sealSecretsMap(existing.Secrets)
	if err != nil {
		return ExternalServerRecord{}, err
	}
	insecureInt := 0
	if existing.AllowInsecureTLS {
		insecureInt = 1
	}
	enabledInt := 0
	if existing.Enabled {
		enabledInt = 1
	}
	now := s.NowMs()

	res, err := s.db.Exec(`
		UPDATE external_servers
		SET name = ?, kind = ?, base_url = ?, auth_mode = ?, username = ?, user_id = ?,
		    device_id = ?, server_id = ?, server_version = ?, allow_insecure_tls = ?,
		    encrypted_secrets = ?, enabled = ?, updated_at = ?
		WHERE id = ?`,
		existing.Name,
		existing.Kind,
		existing.BaseURL,
		existing.AuthMode,
		existing.Username,
		existing.UserID,
		existing.DeviceID,
		existing.ServerID,
		existing.ServerVersion,
		insecureInt,
		sealed,
		enabledInt,
		now,
		id,
	)
	if err != nil {
		return ExternalServerRecord{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ExternalServerRecord{}, ErrNotFound
	}
	return s.GetExternalServer(id)
}

func (s *Store) DeleteExternalServer(id string) error {
	res, err := s.db.Exec(`DELETE FROM external_servers WHERE id = ?`, strings.TrimSpace(id))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}
