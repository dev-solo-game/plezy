package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"

	"plezy/media_server/internal/db"
)

var (
	ErrAlreadyInitialized = errors.New("admin account already initialized")
	ErrNotInitialized     = errors.New("admin account not initialized")
	ErrInvalidCredentials = errors.New("invalid username or password")
	ErrUnauthorized       = errors.New("unauthorized")
	ErrInvalidInput       = errors.New("invalid input")
	ErrInvalidStreamToken = errors.New("invalid or expired stream token")
)

const (
	SessionCookieName = "ttplay_session"
	DefaultSessionTTL = 30 * 24 * time.Hour
	DefaultStreamTTL  = 6 * time.Hour
)

type Service struct {
	store *db.Store
	nowFn func() time.Time

	// Authenticate runs on every API, artwork and image request. Caching the
	// admin row and recently validated sessions avoids two SQLite round trips per
	// request (the store uses a single connection, so these queue behind heavy
	// library queries). Every mutation of admin_account/sessions in this file
	// invalidates the caches.
	cacheMu      sync.Mutex
	adminCache   *db.AdminAccount
	sessionCache map[string]cachedSession
	cacheGen     uint64
}

type cachedSession struct {
	sess     db.SessionRecord
	cachedAt int64
}

// sessionCacheTTLMs bounds how long a validated session is trusted without
// re-reading the sessions table.
const sessionCacheTTLMs = 30_000

func (s *Service) invalidateAuthCache(admin bool) {
	s.cacheMu.Lock()
	if admin {
		s.adminCache = nil
	}
	s.sessionCache = nil
	s.cacheGen++
	s.cacheMu.Unlock()
}

type AdminSession struct {
	Username    string `json:"username"`
	AccessToken string `json:"access_token"`
	TokenID     string `json:"token_id"`
	ExpiresAt   int64  `json:"expires_at"`
}

func NewService(store *db.Store) *Service {
	return &Service{
		store: store,
		nowFn: time.Now,
	}
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
	}
}

func (s *Service) IsInitialized() bool {
	s.cacheMu.Lock()
	known := s.adminCache != nil
	s.cacheMu.Unlock()
	if known {
		return true
	}
	var cnt int
	err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM admin_account WHERE id = 1`).Scan(&cnt)
	return err == nil && cnt > 0
}

func (s *Service) GetAdmin() (*db.AdminAccount, error) {
	s.cacheMu.Lock()
	cached := s.adminCache
	s.cacheMu.Unlock()
	if cached != nil {
		cp := *cached
		return &cp, nil
	}
	acc, err := s.loadAdmin()
	if err != nil {
		return nil, err
	}
	s.cacheMu.Lock()
	cp := *acc
	s.adminCache = &cp
	s.cacheMu.Unlock()
	return acc, nil
}

func (s *Service) loadAdmin() (*db.AdminAccount, error) {
	var acc db.AdminAccount
	err := s.store.ReadDB().QueryRow(`
		SELECT username, password_salt, password_hash, created_at, updated_at
		FROM admin_account WHERE id = 1`,
	).Scan(&acc.Username, &acc.PasswordSalt, &acc.PasswordHash, &acc.CreatedAt, &acc.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotInitialized
	}
	if err != nil {
		return nil, err
	}
	return &acc, nil
}

func hashPassword(password string, salt []byte) string {
	derived := argon2.IDKey([]byte(password), salt, 2, 19456, 1, 32)
	return base64.RawStdEncoding.EncodeToString(derived)
}

func generateSalt() ([]byte, string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return nil, "", err
	}
	return b, base64.RawStdEncoding.EncodeToString(b), nil
}

func verifyPassword(password, saltB64, expectedHash string) bool {
	salt, err := base64.RawStdEncoding.DecodeString(saltB64)
	if err != nil || len(salt) == 0 {
		return false
	}
	got := hashPassword(password, salt)
	return subtle.ConstantTimeCompare([]byte(got), []byte(expectedHash)) == 1
}

func (s *Service) EnsureSeedAdmin(username, password string) error {
	if strings.TrimSpace(password) == "" || s.IsInitialized() {
		return nil
	}
	if strings.TrimSpace(username) == "" {
		username = "admin"
	}
	_, err := s.createAdmin(username, password)
	return err
}

func (s *Service) createAdmin(username, password string) (db.AdminAccount, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		username = "admin"
	}
	if len(username) < 2 || len(username) > 64 {
		return db.AdminAccount{}, fmt.Errorf("%w: username must be 2..64 characters", ErrInvalidInput)
	}
	if len(password) < 6 {
		return db.AdminAccount{}, fmt.Errorf("%w: password must be at least 6 characters", ErrInvalidInput)
	}
	saltBytes, saltB64, err := generateSalt()
	if err != nil {
		return db.AdminAccount{}, err
	}
	hash := hashPassword(password, saltBytes)
	now := s.nowFn().UnixMilli()

	res, err := s.store.DB().Exec(`
		INSERT OR IGNORE INTO admin_account(id, username, password_salt, password_hash, created_at, updated_at)
		VALUES (1, ?, ?, ?, ?, ?)`,
		username, saltB64, hash, now, now,
	)
	if err != nil {
		return db.AdminAccount{}, err
	}
	s.invalidateAuthCache(true)
	if n, _ := res.RowsAffected(); n == 0 {
		return db.AdminAccount{}, ErrAlreadyInitialized
	}
	return db.AdminAccount{
		Username:     username,
		PasswordSalt: saltB64,
		PasswordHash: hash,
		CreatedAt:    now,
		UpdatedAt:    now,
	}, nil
}

func (s *Service) SetupAdmin(username, password, deviceName, platform, ip string) (*AdminSession, error) {
	if s.IsInitialized() {
		return nil, ErrAlreadyInitialized
	}
	acc, err := s.createAdmin(username, password)
	if err != nil {
		return nil, err
	}
	return s.createSession(acc.Username, deviceName, platform, ip)
}

func (s *Service) Login(username, password, deviceName, platform, ip string) (*AdminSession, error) {
	acc, err := s.GetAdmin()
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(strings.TrimSpace(username), acc.Username) {
		return nil, ErrInvalidCredentials
	}
	if !verifyPassword(password, acc.PasswordSalt, acc.PasswordHash) {
		return nil, ErrInvalidCredentials
	}
	return s.createSession(acc.Username, deviceName, platform, ip)
}

func (s *Service) createSession(username, deviceName, platform, ip string) (*AdminSession, error) {
	rawToken := make([]byte, 32)
	if _, err := rand.Read(rawToken); err != nil {
		return nil, err
	}
	token := "ttp_" + base64.RawURLEncoding.EncodeToString(rawToken)
	tokenHash := hashToken(token)
	tokenID := uuid.NewString()
	now := s.nowFn()
	nowMs := now.UnixMilli()
	expMs := now.Add(DefaultSessionTTL).UnixMilli()

	if strings.TrimSpace(deviceName) == "" {
		deviceName = "Web Browser"
	}
	if strings.TrimSpace(platform) == "" {
		platform = "web"
	}

	_, err := s.store.DB().Exec(`
		INSERT INTO sessions(token_id, token_hash, device_name, platform, ip, created_at, last_used_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, tokenHash, deviceName, platform, ip, nowMs, nowMs, expMs,
	)
	if err != nil {
		return nil, err
	}
	// Prune expired sessions opportunistically
	_, _ = s.store.DB().Exec(`DELETE FROM sessions WHERE expires_at <= ?`, nowMs)

	return &AdminSession{
		Username:    username,
		AccessToken: token,
		TokenID:     tokenID,
		ExpiresAt:   expMs,
	}, nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *Service) Authenticate(token string) (*db.AdminAccount, *db.SessionRecord, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, nil, ErrUnauthorized
	}
	acc, err := s.GetAdmin()
	if err != nil {
		return nil, nil, ErrUnauthorized
	}
	th := hashToken(token)
	nowMs := s.nowFn().UnixMilli()

	s.cacheMu.Lock()
	if c, ok := s.sessionCache[th]; ok && nowMs >= c.cachedAt && nowMs-c.cachedAt < sessionCacheTTLMs && c.sess.ExpiresAt > nowMs {
		sess := c.sess
		s.cacheMu.Unlock()
		return acc, &sess, nil
	}
	gen := s.cacheGen
	s.cacheMu.Unlock()

	var sess db.SessionRecord
	err = s.store.ReadDB().QueryRow(`
		SELECT token_id, token_hash, device_name, platform, ip, created_at, last_used_at, expires_at
		FROM sessions WHERE token_hash = ?`, th,
	).Scan(&sess.TokenID, &sess.TokenHash, &sess.DeviceName, &sess.Platform, &sess.IP, &sess.CreatedAt, &sess.LastUsedAt, &sess.ExpiresAt)
	if err != nil {
		return nil, nil, ErrUnauthorized
	}
	if sess.ExpiresAt <= nowMs {
		_, _ = s.store.DB().Exec(`DELETE FROM sessions WHERE token_id = ?`, sess.TokenID)
		return nil, nil, ErrUnauthorized
	}
	if nowMs-sess.LastUsedAt > int64(time.Minute/time.Millisecond) {
		_, _ = s.store.DB().Exec(`UPDATE sessions SET last_used_at = ? WHERE token_id = ?`, nowMs, sess.TokenID)
		sess.LastUsedAt = nowMs
	}
	s.cacheMu.Lock()
	// Skip caching if a logout/revoke raced with this lookup.
	if s.cacheGen == gen {
		if s.sessionCache == nil || len(s.sessionCache) >= 256 {
			s.sessionCache = make(map[string]cachedSession)
		}
		s.sessionCache[th] = cachedSession{sess: sess, cachedAt: nowMs}
	}
	s.cacheMu.Unlock()
	return acc, &sess, nil
}

func (s *Service) Logout(token string) error {
	th := hashToken(strings.TrimSpace(token))
	if th == "" {
		return nil
	}
	_, err := s.store.DB().Exec(`DELETE FROM sessions WHERE token_hash = ?`, th)
	s.invalidateAuthCache(false)
	return err
}

func (s *Service) ChangePassword(oldPassword, newPassword, newUsername, keepTokenID string) error {
	acc, err := s.GetAdmin()
	if err != nil {
		return err
	}
	if !verifyPassword(oldPassword, acc.PasswordSalt, acc.PasswordHash) {
		return ErrInvalidCredentials
	}
	if len(newPassword) < 6 {
		return fmt.Errorf("%w: new password must be at least 6 characters", ErrInvalidInput)
	}
	username := acc.Username
	if u := strings.TrimSpace(newUsername); u != "" {
		if len(u) < 2 || len(u) > 64 {
			return fmt.Errorf("%w: username must be 2..64 characters", ErrInvalidInput)
		}
		username = u
	}
	saltBytes, saltB64, err := generateSalt()
	if err != nil {
		return err
	}
	hash := hashPassword(newPassword, saltBytes)
	nowMs := s.nowFn().UnixMilli()

	_, err = s.store.DB().Exec(`
		UPDATE admin_account
		SET username = ?, password_salt = ?, password_hash = ?, updated_at = ?
		WHERE id = 1`,
		username, saltB64, hash, nowMs,
	)
	if err != nil {
		return err
	}
	defer s.invalidateAuthCache(true)
	if keepTokenID != "" {
		_, _ = s.store.DB().Exec(`DELETE FROM sessions WHERE token_id != ?`, keepTokenID)
	} else {
		_, _ = s.store.DB().Exec(`DELETE FROM sessions`)
	}
	return nil
}

func (s *Service) ListSessions(currentTokenID string) ([]db.SessionRecord, error) {
	nowMs := s.nowFn().UnixMilli()
	_, _ = s.store.DB().Exec(`DELETE FROM sessions WHERE expires_at <= ?`, nowMs)
	rows, err := s.store.DB().Query(`
		SELECT token_id, token_hash, device_name, platform, ip, created_at, last_used_at, expires_at
		FROM sessions
		ORDER BY last_used_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.SessionRecord, 0)
	for rows.Next() {
		var r db.SessionRecord
		if err := rows.Scan(&r.TokenID, &r.TokenHash, &r.DeviceName, &r.Platform, &r.IP, &r.CreatedAt, &r.LastUsedAt, &r.ExpiresAt); err != nil {
			return nil, err
		}
		r.Current = r.TokenID == currentTokenID
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Service) RevokeSession(tokenID string) error {
	res, err := s.store.DB().Exec(`DELETE FROM sessions WHERE token_id = ?`, tokenID)
	s.invalidateAuthCache(false)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return db.ErrNotFound
	}
	return nil
}

// SignStreamToken issues a short-lived HMAC-SHA256 token bound to (scope, resourceID).
func (s *Service) SignStreamToken(scope, resourceID string, ttl time.Duration) string {
	if ttl <= 0 {
		ttl = DefaultStreamTTL
	}
	expMs := s.nowFn().Add(ttl).UnixMilli()
	payloadRaw := scope + "\x00" + resourceID + "\x00" + strconv.FormatInt(expMs, 10)
	payloadB64 := base64.RawURLEncoding.EncodeToString([]byte(payloadRaw))

	mac := hmac.New(sha256.New, s.store.Vault().StreamSigningKey())
	_, _ = mac.Write([]byte(payloadB64))
	sigB64 := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return payloadB64 + "." + sigB64
}

// VerifyStreamToken validates an HMAC stream token against scope, resourceID, and expiry.
func (s *Service) VerifyStreamToken(token, expectedScope, expectedResourceID string) error {
	dot := strings.IndexByte(token, '.')
	if dot <= 0 || dot >= len(token)-1 {
		return ErrInvalidStreamToken
	}
	payloadB64 := token[:dot]
	sigB64 := token[dot+1:]

	sig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil {
		return ErrInvalidStreamToken
	}
	mac := hmac.New(sha256.New, s.store.Vault().StreamSigningKey())
	_, _ = mac.Write([]byte(payloadB64))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return ErrInvalidStreamToken
	}

	raw, err := base64.RawURLEncoding.DecodeString(payloadB64)
	if err != nil {
		return ErrInvalidStreamToken
	}
	parts := strings.Split(string(raw), "\x00")
	if len(parts) != 3 {
		return ErrInvalidStreamToken
	}
	if parts[0] != expectedScope || parts[1] != expectedResourceID {
		return ErrInvalidStreamToken
	}
	expMs, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || s.nowFn().UnixMilli() > expMs {
		return ErrInvalidStreamToken
	}
	return nil
}
