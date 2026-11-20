package platform

import (
	"crypto/rand"
	"database/sql"
	"fmt"
	"strings"

	"plezy/media_library/internal/security"
)

const inviteAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

type InviteCode struct {
	Code      string `json:"code"`
	CreatedBy string `json:"created_by"`
	MaxUses   int    `json:"max_uses"`
	UsedCount int    `json:"used_count"`
	ExpiresAt *int64 `json:"expires_at,omitempty"`
	Revoked   bool   `json:"revoked"`
	Note      string `json:"note,omitempty"`
	CreatedAt int64  `json:"created_at"`
}

func generateInviteCode(length int) (string, error) {
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, length)
	for i := range out {
		out[i] = inviteAlphabet[int(b[i])%len(inviteAlphabet)]
	}
	return string(out), nil
}

func (s *Service) CreateInviteCode(adminID string, maxUses int, expiresAt *int64, note, ip string) (*InviteCode, error) {
	if maxUses <= 0 {
		return nil, fmt.Errorf("%w: max_uses must be > 0", ErrInvalidInput)
	}
	code, err := generateInviteCode(12)
	if err != nil {
		return nil, err
	}
	nowMs := s.nowFn().UnixMilli()
	var expVal any
	if expiresAt != nil {
		expVal = *expiresAt
	}

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO invite_codes(code, created_by, max_uses, used_count, expires_at, revoked, note, created_at)
		VALUES (?, ?, ?, 0, ?, 0, ?, ?)`,
		code, adminID, maxUses, expVal, strings.TrimSpace(note), nowMs,
	); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    adminID,
		Action:     "admin.invite_create",
		TargetType: "invite",
		TargetID:   code,
		IP:         ip,
		Detail:     map[string]any{"max_uses": maxUses},
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &InviteCode{
		Code:      code,
		CreatedBy: adminID,
		MaxUses:   maxUses,
		UsedCount: 0,
		ExpiresAt: expiresAt,
		Revoked:   false,
		Note:      strings.TrimSpace(note),
		CreatedAt: nowMs,
	}, nil
}

func (s *Service) ListInviteCodes() ([]InviteCode, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT code, created_by, max_uses, used_count, expires_at, revoked, note, created_at
		FROM invite_codes
		ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]InviteCode, 0)
	for rows.Next() {
		var (
			ic  InviteCode
			exp sql.NullInt64
			rev int
		)
		if scanErr := rows.Scan(
			&ic.Code, &ic.CreatedBy, &ic.MaxUses, &ic.UsedCount, &exp, &rev, &ic.Note, &ic.CreatedAt,
		); scanErr != nil {
			return nil, scanErr
		}
		if exp.Valid {
			v := exp.Int64
			ic.ExpiresAt = &v
		}
		ic.Revoked = rev == 1
		out = append(out, ic)
	}
	return out, rows.Err()
}

func (s *Service) RevokeInviteCode(adminID, code, ip string) error {
	c := strings.TrimSpace(strings.ToUpper(code))
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`UPDATE invite_codes SET revoked = 1 WHERE code = ?`, c)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    adminID,
		Action:     "admin.invite_revoke",
		TargetType: "invite",
		TargetID:   c,
		IP:         ip,
	}); err != nil {
		return err
	}
	return tx.Commit()
}
