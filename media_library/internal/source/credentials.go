package source

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/security"
)

func (s *Service) GetCredential(p *account.Principal, sourceID, ip string) (*Credential, error) {
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}

	var cred Credential
	err = s.store.ReadDB().QueryRow(`
		SELECT source_id, household_id, ciphertext, version, key_epoch, status, updated_by_device, updated_at
		FROM source_credentials
		WHERE source_id = ? AND household_id = ?`,
		src.ID, p.HouseholdID,
	).Scan(
		&cred.SourceID, &cred.HouseholdID, &cred.Ciphertext,
		&cred.Version, &cred.KeyEpoch, &cred.Status, &cred.UpdatedByDevice, &cred.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	_ = security.WriteAudit(s.store, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.credential_read",
		TargetType:  "source",
		TargetID:    src.ID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"device_id": p.DeviceID,
			"version":   cred.Version,
		},
	})
	return &cred, nil
}

func (s *Service) UpdateCredential(p *account.Principal, sourceID string, req UpdateCredentialRequest, ip string) (*Credential, error) {
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}

	ciphertext := strings.TrimSpace(req.Ciphertext)
	if ciphertext == "" || len(ciphertext) > MaxCredentialBytes {
		return nil, fmt.Errorf("%w: ciphertext must be non-empty and <= %d bytes", ErrInvalidInput, MaxCredentialBytes)
	}
	if req.BaseVersion < 1 {
		return nil, fmt.Errorf("%w: base_version must be >= 1", ErrInvalidInput)
	}
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode == "" {
		mode = CredUpdateModeRefresh
	}
	if mode != CredUpdateModeRefresh && mode != CredUpdateModeReplace {
		return nil, fmt.Errorf("%w: unsupported credential update mode %q", ErrInvalidInput, req.Mode)
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var cur Credential
	err = tx.QueryRow(`
		SELECT source_id, household_id, ciphertext, version, key_epoch, status, updated_by_device, updated_at
		FROM source_credentials
		WHERE source_id = ? AND household_id = ?`,
		src.ID, p.HouseholdID,
	).Scan(
		&cur.SourceID, &cur.HouseholdID, &cur.Ciphertext,
		&cur.Version, &cur.KeyEpoch, &cur.Status, &cur.UpdatedByDevice, &cur.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	isReplace := mode == CredUpdateModeReplace || cur.Status != CredStatusValid
	if isReplace {
		if !p.HasPerm(account.PermManageSources) {
			return nil, ErrForbidden
		}
		if err := s.checkDevicePolicy(p.DeviceClass, src.Kind); err != nil {
			return nil, err
		}
		if idKey := strings.TrimSpace(req.IdentityKey); src.IdentityUnique && idKey != "" && idKey != src.IdentityKey {
			return nil, ErrIdentityMismatch
		}
	} else if !p.HasPerm(account.PermManageSources) && !p.HasPerm(account.PermUploadFacts) {
		return nil, ErrForbidden
	}

	if req.BaseVersion != cur.Version {
		return nil, &CredentialConflictError{Current: cur}
	}

	newEpoch := cur.KeyEpoch
	if req.KeyEpoch > 0 {
		newEpoch = req.KeyEpoch
	}

	res, err := tx.Exec(`
		UPDATE source_credentials
		SET ciphertext = ?, version = version + 1, key_epoch = ?, status = 'valid', updated_by_device = ?, updated_at = ?
		WHERE source_id = ? AND household_id = ? AND version = ?`,
		ciphertext, newEpoch, p.DeviceID, nowMs, src.ID, p.HouseholdID, req.BaseVersion,
	)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var latest Credential
		_ = tx.QueryRow(`
			SELECT source_id, household_id, ciphertext, version, key_epoch, status, updated_by_device, updated_at
			FROM source_credentials
			WHERE source_id = ? AND household_id = ?`,
			src.ID, p.HouseholdID,
		).Scan(
			&latest.SourceID, &latest.HouseholdID, &latest.Ciphertext,
			&latest.Version, &latest.KeyEpoch, &latest.Status, &latest.UpdatedByDevice, &latest.UpdatedAt,
		)
		return nil, &CredentialConflictError{Current: latest}
	}

	newVer := req.BaseVersion + 1
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source", src.ID, "credential_updated", nowMs); err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.credential_updated",
		TargetType:  "source",
		TargetID:    src.ID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"mode":      mode,
			"version":   newVer,
			"key_epoch": newEpoch,
		},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if s.hub != nil {
		s.hub.PublishToHousehold(p.HouseholdID, "credential.status", map[string]any{
			"source_id":         src.ID,
			"status":            CredStatusValid,
			"version":           newVer,
			"key_epoch":         newEpoch,
			"updated_by_device": p.DeviceID,
		})
	}

	return &Credential{
		SourceID:        src.ID,
		HouseholdID:     p.HouseholdID,
		Ciphertext:      ciphertext,
		Version:         newVer,
		KeyEpoch:        newEpoch,
		Status:          CredStatusValid,
		UpdatedByDevice: p.DeviceID,
		UpdatedAt:       nowMs,
	}, nil
}

func (s *Service) ReportCredentialStatus(p *account.Principal, sourceID string, req ReportCredentialStatusRequest, ip string) (*CredentialMeta, error) {
	src, err := s.loadSourceForPrincipal(p, sourceID)
	if err != nil {
		return nil, err
	}
	if !p.HasPerm(account.PermBrowse) && !p.HasPerm(account.PermUploadFacts) && !p.HasPerm(account.PermManageSources) {
		return nil, ErrForbidden
	}
	st := strings.ToLower(strings.TrimSpace(req.Status))
	if st != CredStatusExpired && st != CredStatusKicked {
		return nil, fmt.Errorf("%w: status must be expired or kicked", ErrInvalidInput)
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var cur CredentialMeta
	err = tx.QueryRow(`
		SELECT version, key_epoch, status, updated_by_device, updated_at
		FROM source_credentials
		WHERE source_id = ? AND household_id = ?`,
		src.ID, p.HouseholdID,
	).Scan(&cur.Version, &cur.KeyEpoch, &cur.Status, &cur.UpdatedByDevice, &cur.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// Ignore stale reports targeting older credential versions.
	if req.Version > 0 && req.Version < cur.Version {
		return &cur, nil
	}

	if _, err := tx.Exec(`
		UPDATE source_credentials
		SET status = ?, updated_by_device = ?, updated_at = ?
		WHERE source_id = ? AND household_id = ?`,
		st, p.DeviceID, nowMs, src.ID, p.HouseholdID,
	); err != nil {
		return nil, err
	}

	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "source", src.ID, "credential_status", nowMs); err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   actorTypeForPrincipal(p),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "source.credential_status_reported",
		TargetType:  "source",
		TargetID:    src.ID,
		IP:          strings.TrimSpace(ip),
		Detail: map[string]any{
			"status":  st,
			"version": cur.Version,
		},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if s.hub != nil {
		s.hub.PublishToHousehold(p.HouseholdID, "credential.status", map[string]any{
			"source_id":          src.ID,
			"status":             st,
			"version":            cur.Version,
			"key_epoch":          cur.KeyEpoch,
			"reported_by_device": p.DeviceID,
		})
	}

	cur.Status = st
	cur.UpdatedByDevice = p.DeviceID
	cur.UpdatedAt = nowMs
	return &cur, nil
}
