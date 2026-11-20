package platform

import (
	"database/sql"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/security"
)

const (
	AdminTokenPrefix       = "adm_"
	DefaultAdminSessionTTL = 12 * time.Hour
	minPasswordLength      = 8
)

type AdminPrincipal struct {
	AdminID            string `json:"admin_id"`
	Username           string `json:"username"`
	MustChangePassword bool   `json:"must_change_password"`
	TokenID            string `json:"token_id"`
	LastLoginAt        *int64 `json:"last_login_at,omitempty"`
	LastLoginIP        string `json:"last_login_ip,omitempty"`
	ExpiresAt          int64  `json:"expires_at"`
}

type AdminLoginResult struct {
	AccessToken string         `json:"access_token"`
	TokenID     string         `json:"token_id"`
	ExpiresAt   int64          `json:"expires_at"`
	Admin       AdminPrincipal `json:"admin"`
}

type Service struct {
	store        *db.Store
	limiter      *security.LoginLimiter
	allowedCIDRs []*net.IPNet
	nowFn        func() time.Time
}

func NewService(store *db.Store, limiter *security.LoginLimiter, allowedCIDRsCSV string) (*Service, error) {
	nets, err := security.ParseCIDRList(allowedCIDRsCSV)
	if err != nil {
		return nil, err
	}
	if limiter == nil {
		limiter = security.NewLoginLimiter()
	}
	return &Service{
		store:        store,
		limiter:      limiter,
		allowedCIDRs: nets,
		nowFn:        time.Now,
	}, nil
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
		s.limiter.SetClock(fn)
	}
}

func (s *Service) CheckAllowedIP(ip string) error {
	if !security.IPAllowed(ip, s.allowedCIDRs) {
		return ErrForbiddenIP
	}
	return nil
}

// EnsureDefaultAdmin seeds the initial platform admin if none exists.
// Returns true when any platform admin still has must_change_password set.
func (s *Service) EnsureDefaultAdmin(username, password string) (bool, error) {
	var cnt int
	if err := s.store.DB().QueryRow(`SELECT COUNT(*) FROM platform_admins`).Scan(&cnt); err != nil {
		return false, err
	}
	if cnt == 0 {
		user := strings.TrimSpace(username)
		if user == "" {
			user = "admin"
		}
		pass := password
		mustChange := 0
		if strings.TrimSpace(pass) == "" {
			pass = "admin"
			mustChange = 1
		}
		salt, hash, err := security.HashSecret(pass)
		if err != nil {
			return false, err
		}
		now := s.nowFn().UnixMilli()
		if _, err := s.store.DB().Exec(`
			INSERT INTO platform_admins(id, username, password_salt, password_hash, must_change_password, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			uuid.NewString(), user, salt, hash, mustChange, now, now,
		); err != nil {
			return false, err
		}
		return mustChange == 1, nil
	}

	var flagged int
	if err := s.store.ReadDB().QueryRow(`SELECT EXISTS(SELECT 1 FROM platform_admins WHERE must_change_password = 1)`).Scan(&flagged); err != nil {
		return false, err
	}
	return flagged == 1, nil
}

// ResetAdminPasswordCLI resets a platform admin password locally via CLI.
func (s *Service) ResetAdminPasswordCLI(username, newPassword string) error {
	user := strings.TrimSpace(username)
	if user == "" {
		user = "admin"
	}
	if len(newPassword) < minPasswordLength {
		return fmt.Errorf("%w: password must be at least %d characters", ErrInvalidInput, minPasswordLength)
	}
	var adminID string
	if err := s.store.ReadDB().QueryRow(`SELECT id FROM platform_admins WHERE username = ?`, user).Scan(&adminID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}

	salt, hash, err := security.HashSecret(newPassword)
	if err != nil {
		return err
	}
	now := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE platform_admins
		SET password_salt = ?, password_hash = ?, must_change_password = 0, updated_at = ?
		WHERE id = ?`,
		salt, hash, now, adminID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM admin_sessions WHERE admin_id = ?`, adminID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, now, security.AuditEntry{
		ActorType:  "system",
		ActorID:    "cli",
		Action:     "admin.password_reset_cli",
		TargetType: "admin",
		TargetID:   adminID,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) Login(username, password, ip, userAgent string) (*AdminLoginResult, error) {
	if err := s.CheckAllowedIP(ip); err != nil {
		return nil, err
	}
	user := strings.TrimSpace(username)
	ipKey := "admin:ip:" + strings.TrimSpace(ip)
	userKey := "admin:user:" + strings.ToLower(user)

	if locked, retry := s.limiter.CheckLockout(ipKey); locked {
		return nil, &RateLimitError{RetryAfterSec: retry}
	}
	if user != "" {
		if locked, retry := s.limiter.CheckLockout(userKey); locked {
			return nil, &RateLimitError{RetryAfterSec: retry}
		}
	}

	var (
		adminID    string
		salt, hash string
		mustChange int
		lastAt     sql.NullInt64
		lastIP     string
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT id, password_salt, password_hash, must_change_password, last_login_at, last_login_ip
		FROM platform_admins WHERE username = ?`, user,
	).Scan(&adminID, &salt, &hash, &mustChange, &lastAt, &lastIP)
	if err != nil || !security.VerifySecret(password, salt, hash) {
		s.limiter.RecordFailure(ipKey)
		if user != "" {
			s.limiter.RecordFailure(userKey)
		}
		_ = security.WriteAudit(s.store, security.AuditEntry{
			ActorType:  "admin",
			ActorID:    user,
			Action:     "admin.login_failed",
			TargetType: "admin",
			TargetID:   user,
			IP:         ip,
		})
		return nil, ErrInvalidCredentials
	}

	s.limiter.RecordSuccess(ipKey)
	s.limiter.RecordSuccess(userKey)

	rawToken, tokenID, tokenHash, err := security.GenerateOpaqueToken(AdminTokenPrefix)
	if err != nil {
		return nil, err
	}
	now := s.nowFn()
	nowMs := now.UnixMilli()
	expiresAt := now.Add(DefaultAdminSessionTTL).UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO admin_sessions(token_id, admin_id, token_hash, ip, user_agent, created_at, last_used_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, adminID, tokenHash, strings.TrimSpace(ip), strings.TrimSpace(userAgent), nowMs, nowMs, expiresAt,
	); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE platform_admins SET last_login_at = ?, last_login_ip = ?, updated_at = ? WHERE id = ?`,
		nowMs, strings.TrimSpace(ip), nowMs, adminID,
	); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    adminID,
		Action:     "admin.login",
		TargetType: "admin",
		TargetID:   adminID,
		IP:         ip,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	var prevAt *int64
	if lastAt.Valid {
		v := lastAt.Int64
		prevAt = &v
	}

	return &AdminLoginResult{
		AccessToken: rawToken,
		TokenID:     tokenID,
		ExpiresAt:   expiresAt,
		Admin: AdminPrincipal{
			AdminID:            adminID,
			Username:           user,
			MustChangePassword: mustChange == 1,
			TokenID:            tokenID,
			LastLoginAt:        prevAt,
			LastLoginIP:        lastIP,
			ExpiresAt:          expiresAt,
		},
	}, nil
}

func (s *Service) Authenticate(rawToken string) (*AdminPrincipal, error) {
	tok := strings.TrimSpace(rawToken)
	if !strings.HasPrefix(tok, AdminTokenPrefix) {
		return nil, ErrUnauthorized
	}
	tokenHash := security.HashToken(tok)
	nowMs := s.nowFn().UnixMilli()

	var (
		p          AdminPrincipal
		mustChange int
		lastAt     sql.NullInt64
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT s.token_id, a.id, a.username, a.must_change_password, a.last_login_at, a.last_login_ip, s.expires_at
		FROM admin_sessions s
		JOIN platform_admins a ON a.id = s.admin_id
		WHERE s.token_hash = ?`, tokenHash,
	).Scan(&p.TokenID, &p.AdminID, &p.Username, &mustChange, &lastAt, &p.LastLoginIP, &p.ExpiresAt)
	if err != nil {
		return nil, ErrUnauthorized
	}
	if p.ExpiresAt <= nowMs {
		_, _ = s.store.DB().Exec(`DELETE FROM admin_sessions WHERE token_id = ?`, p.TokenID)
		return nil, ErrUnauthorized
	}
	p.MustChangePassword = mustChange == 1
	if lastAt.Valid {
		v := lastAt.Int64
		p.LastLoginAt = &v
	}

	_, _ = s.store.DB().Exec(`UPDATE admin_sessions SET last_used_at = ? WHERE token_id = ?`, nowMs, p.TokenID)
	return &p, nil
}

func (s *Service) Logout(rawToken string) error {
	tok := strings.TrimSpace(rawToken)
	if !strings.HasPrefix(tok, AdminTokenPrefix) {
		return nil
	}
	_, err := s.store.DB().Exec(`DELETE FROM admin_sessions WHERE token_hash = ?`, security.HashToken(tok))
	return err
}

func (s *Service) ChangePassword(adminID, oldPassword, newUsername, newPassword, keepTokenID, ip string) error {
	if len(newPassword) < minPasswordLength {
		return fmt.Errorf("%w: new password must be at least %d characters", ErrInvalidInput, minPasswordLength)
	}
	var curUser, salt, hash string
	err := s.store.ReadDB().QueryRow(`
		SELECT username, password_salt, password_hash FROM platform_admins WHERE id = ?`, adminID,
	).Scan(&curUser, &salt, &hash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if !security.VerifySecret(oldPassword, salt, hash) {
		return ErrInvalidCredentials
	}

	targetUser := strings.TrimSpace(newUsername)
	if targetUser == "" {
		targetUser = curUser
	}
	if len(targetUser) < 2 || len(targetUser) > 32 {
		return fmt.Errorf("%w: invalid username length", ErrInvalidInput)
	}

	newSalt, newHash, err := security.HashSecret(newPassword)
	if err != nil {
		return err
	}
	nowMs := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE platform_admins
		SET username = ?, password_salt = ?, password_hash = ?, must_change_password = 0, updated_at = ?
		WHERE id = ?`,
		targetUser, newSalt, newHash, nowMs, adminID,
	); err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return fmt.Errorf("%w: username already exists", ErrConflict)
		}
		return err
	}
	if strings.TrimSpace(keepTokenID) != "" {
		if _, err := tx.Exec(`DELETE FROM admin_sessions WHERE admin_id = ? AND token_id != ?`, adminID, keepTokenID); err != nil {
			return err
		}
	} else {
		if _, err := tx.Exec(`DELETE FROM admin_sessions WHERE admin_id = ?`, adminID); err != nil {
			return err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    adminID,
		Action:     "admin.password_change",
		TargetType: "admin",
		TargetID:   adminID,
		IP:         ip,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) CleanupExpiredSessions() error {
	nowMs := s.nowFn().UnixMilli()
	_, err := s.store.DB().Exec(`DELETE FROM admin_sessions WHERE expires_at <= ?`, nowMs)
	return err
}
