package account

import (
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/security"
)

const (
	QrSessionTTL       = 5 * time.Minute
	qrCreateBurstLimit = 20
	qrCreateBurstWin   = time.Minute
	maxQrPayloadLen    = 8192
)

type CreateQrRequest struct {
	DeviceClass     string `json:"device_class"`
	Platform        string `json:"platform"`
	DeviceName      string `json:"device_name"`
	EphemeralPubkey string `json:"ephemeral_pubkey"`
}

type QrCreateResult struct {
	QrID       string `json:"qr_id"`
	PollSecret string `json:"poll_secret"`
	ExpiresAt  int64  `json:"expires_at"`
}

type QrSessionInfo struct {
	QrID            string `json:"qr_id"`
	DeviceClass     string `json:"device_class"`
	Platform        string `json:"platform"`
	DeviceName      string `json:"device_name"`
	EphemeralPubkey string `json:"ephemeral_pubkey"`
	Status          string `json:"status"`
	ExpiresAt       int64  `json:"expires_at"`
}

type ConfirmQrRequest struct {
	TargetMemberID string `json:"target_member_id,omitempty"`
	EncryptedHK    string `json:"encrypted_hk"`
}

type QrPollResult struct {
	Status      string         `json:"status"` // pending | confirmed | expired
	ExpiresAt   int64          `json:"expires_at"`
	AccessToken string         `json:"access_token,omitempty"`
	TokenID     string         `json:"token_id,omitempty"`
	HouseholdID string         `json:"household_id,omitempty"`
	MemberID    string         `json:"member_id,omitempty"`
	DeviceID    string         `json:"device_id,omitempty"`
	EncryptedHK string         `json:"encrypted_hk,omitempty"`
	Household   *HouseholdInfo `json:"household,omitempty"`
	Member      *MemberView    `json:"member,omitempty"`
	Principal   *Principal     `json:"principal,omitempty"`
}

// CreateQrSession starts an unauthenticated QR login handshake with a one-time poll_secret.
func (s *Service) CreateQrSession(req CreateQrRequest, ip string) (*QrCreateResult, error) {
	clientIP := strings.TrimSpace(ip)
	if !s.limiter.AllowWindow("qr_create:"+clientIP, qrCreateBurstLimit, qrCreateBurstWin) {
		return nil, &RateLimitError{RetryAfterSec: int(qrCreateBurstWin.Seconds())}
	}

	devClass := strings.TrimSpace(req.DeviceClass)
	if !IsValidDeviceClass(devClass) {
		return nil, fmt.Errorf("%w: invalid device_class %q", ErrInvalidInput, req.DeviceClass)
	}
	pub := strings.TrimSpace(req.EphemeralPubkey)
	if pub == "" || len(pub) > 1024 {
		return nil, fmt.Errorf("%w: ephemeral_pubkey is required", ErrInvalidInput)
	}

	rawSecret, _, secretHash, err := security.GenerateOpaqueToken("qrs_")
	if err != nil {
		return nil, err
	}
	qrID := uuid.NewString()
	now := s.nowFn()
	nowMs := now.UnixMilli()
	exp := now.Add(QrSessionTTL).UnixMilli()

	if _, err := s.store.DB().Exec(`
		INSERT INTO qr_login_sessions(
			qr_id, device_class, platform, device_name, ephemeral_pubkey,
			status, expires_at, created_at, poll_secret_hash
		) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		qrID, devClass, strings.TrimSpace(req.Platform), strings.TrimSpace(req.DeviceName), pub,
		exp, nowMs, secretHash,
	); err != nil {
		return nil, err
	}

	return &QrCreateResult{
		QrID:       qrID,
		PollSecret: rawSecret,
		ExpiresAt:  exp,
	}, nil
}

// GetQrSessionInfo returns public handshake metadata (ephemeral_pubkey, device details) for a scanner app.
func (s *Service) GetQrSessionInfo(qrID string) (*QrSessionInfo, error) {
	id := strings.TrimSpace(qrID)
	if id == "" {
		return nil, ErrNotFound
	}
	var info QrSessionInfo
	err := s.store.ReadDB().QueryRow(`
		SELECT qr_id, device_class, platform, device_name, ephemeral_pubkey, status, expires_at
		FROM qr_login_sessions WHERE qr_id = ?`, id,
	).Scan(
		&info.QrID, &info.DeviceClass, &info.Platform, &info.DeviceName,
		&info.EphemeralPubkey, &info.Status, &info.ExpiresAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if s.nowFn().UnixMilli() >= info.ExpiresAt && info.Status == "pending" {
		info.Status = "expired"
	}
	return &info, nil
}

// ConfirmQrSession transitions a QR handshake from pending to confirmed and attaches E2EE HK payload.
func (s *Service) ConfirmQrSession(p *Principal, qrID string, req ConfirmQrRequest, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	if p.LoginMode != LoginModeHousehold {
		return fmt.Errorf("%w: independent member session cannot approve household QR login", ErrForbidden)
	}
	id := strings.TrimSpace(qrID)
	if id == "" {
		return ErrNotFound
	}
	encHK := strings.TrimSpace(req.EncryptedHK)
	if encHK == "" || len(encHK) > maxQrPayloadLen {
		return fmt.Errorf("%w: encrypted_hk is required", ErrInvalidInput)
	}

	targetMemberID := strings.TrimSpace(req.TargetMemberID)
	if targetMemberID == "" {
		targetMemberID = p.MemberID
	}
	if targetMemberID != p.MemberID && !p.HasPerm(PermManageMembers) {
		return ErrForbidden
	}

	var targetRole, targetStatus string
	err := s.store.ReadDB().QueryRow(`
		SELECT role, status FROM members WHERE id = ? AND household_id = ?`,
		targetMemberID, p.HouseholdID,
	).Scan(&targetRole, &targetStatus)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if targetStatus != "active" {
		return ErrAccountDisabled
	}
	if targetRole == RoleOwner && p.Role != RoleOwner {
		return ErrForbidden
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE qr_login_sessions
		SET status = 'confirmed', household_id = ?, member_id = ?, encrypted_hk = ?
		WHERE qr_id = ? AND status = 'pending' AND expires_at > ?`,
		p.HouseholdID, targetMemberID, encHK, id, nowMs,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var existingStatus string
		qErr := tx.QueryRow(`SELECT status FROM qr_login_sessions WHERE qr_id = ?`, id).Scan(&existingStatus)
		if errors.Is(qErr, sql.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("%w: qr session is no longer pending", ErrConflict)
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "qr.confirmed",
		TargetType:  "qr_session",
		TargetID:    id,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"target_member_id": targetMemberID},
	}); err != nil {
		return err
	}
	return tx.Commit()
}

// PollQrSession verifies poll_secret and atomically consumes a confirmed QR handshake into a session.
func (s *Service) PollQrSession(qrID, pollSecret, ip string) (*QrPollResult, error) {
	id := strings.TrimSpace(qrID)
	if id == "" || strings.TrimSpace(pollSecret) == "" {
		return nil, ErrUnauthorized
	}

	var (
		devClass, platform, devName, status, secretHash string
		hhID, memID, encHK                              sql.NullString
		expiresAt                                       int64
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT device_class, platform, device_name, status, household_id, member_id, encrypted_hk, expires_at, poll_secret_hash
		FROM qr_login_sessions WHERE qr_id = ?`, id,
	).Scan(&devClass, &platform, &devName, &status, &hhID, &memID, &encHK, &expiresAt, &secretHash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	gotHash := security.HashToken(pollSecret)
	if secretHash == "" || subtle.ConstantTimeCompare([]byte(gotHash), []byte(secretHash)) != 1 {
		return nil, ErrUnauthorized
	}

	now := s.nowFn()
	nowMs := now.UnixMilli()
	if nowMs >= expiresAt && status != "consumed" {
		_, _ = s.store.DB().Exec(`UPDATE qr_login_sessions SET status = 'expired' WHERE qr_id = ? AND status = 'pending'`, id)
		return &QrPollResult{Status: "expired", ExpiresAt: expiresAt}, nil
	}
	if status == "pending" {
		return &QrPollResult{Status: "pending", ExpiresAt: expiresAt}, nil
	}
	if status == "expired" {
		return &QrPollResult{Status: "expired", ExpiresAt: expiresAt}, nil
	}
	if status != "confirmed" || !hhID.Valid || !memID.Valid || !encHK.Valid {
		return nil, fmt.Errorf("%w: qr session already consumed", ErrConflict)
	}

	rawToken, tokenID, tokenHash, err := security.GenerateOpaqueToken(UserTokenPrefix)
	if err != nil {
		return nil, err
	}
	sessExp := now.Add(DefaultUserSessionTTL).UnixMilli()
	devID := uuid.NewString()
	clientIP := strings.TrimSpace(ip)

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE qr_login_sessions
		SET status = 'consumed', encrypted_hk = NULL
		WHERE qr_id = ? AND status = 'confirmed' AND expires_at > ?`,
		id, nowMs,
	)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, fmt.Errorf("%w: qr session already consumed or expired", ErrConflict)
	}

	var accID, accStatus, memStatus string
	if err := tx.QueryRow(`
		SELECT a.id, a.status, m.status
		FROM households h
		JOIN accounts a ON a.id = h.owner_account_id
		JOIN members m ON m.id = ? AND m.household_id = h.id
		WHERE h.id = ?`,
		memID.String, hhID.String,
	).Scan(&accID, &accStatus, &memStatus); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if accStatus == "disabled" {
		return nil, ErrAccountDisabled
	}
	if accStatus == "pending_delete" {
		return nil, ErrAccountPendingDelete
	}
	if accStatus != "active" || memStatus != "active" {
		return nil, ErrAccountDisabled
	}

	if _, err := tx.Exec(`
		INSERT INTO devices(id, household_id, device_class, platform, name, app_version, last_seen_at, created_at)
		VALUES (?, ?, ?, ?, ?, '', ?, ?)`,
		devID, hhID.String, devClass, platform, devName, nowMs, nowMs,
	); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`
		INSERT INTO sessions(token_id, household_id, member_id, device_id, token_hash, ip, created_at, last_used_at, expires_at, login_mode)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, hhID.String, memID.String, devID, tokenHash, clientIP, nowMs, nowMs, sessExp, LoginModeHousehold,
	); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`UPDATE accounts SET last_active_at = ? WHERE id = ?`, nowMs, accID); err != nil {
		return nil, err
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     memID.String,
		HouseholdID: hhID.String,
		Action:      "qr.consumed",
		TargetType:  "device",
		TargetID:    devID,
		IP:          clientIP,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	authRes, err := s.buildAuthResult(rawToken, tokenID, sessExp, hhID.String, memID.String, devID, LoginModeHousehold, false)
	if err != nil {
		return nil, err
	}

	return &QrPollResult{
		Status:      "confirmed",
		ExpiresAt:   sessExp,
		AccessToken: rawToken,
		TokenID:     tokenID,
		HouseholdID: hhID.String,
		MemberID:    memID.String,
		DeviceID:    devID,
		EncryptedHK: encHK.String,
		Household:   authRes.Household,
		Member:      authRes.Member,
		Principal:   authRes.Principal,
	}, nil
}

// CleanupExpired purges expired sessions, login tickets, and QR handshake records.
func (s *Service) CleanupExpired() error {
	nowMs := s.nowFn().UnixMilli()
	if _, err := s.store.DB().Exec(`DELETE FROM sessions WHERE expires_at <= ?`, nowMs); err != nil {
		return err
	}
	if _, err := s.store.DB().Exec(`DELETE FROM account_login_tickets WHERE expires_at <= ?`, nowMs); err != nil {
		return err
	}
	if _, err := s.store.DB().Exec(`DELETE FROM qr_login_sessions WHERE expires_at <= ?`, nowMs); err != nil {
		return err
	}
	return nil
}
