package account

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/security"
)

const (
	UserTokenPrefix       = "usr_"
	LoginTicketPrefix     = "tkt_"
	DefaultUserSessionTTL = 30 * 24 * time.Hour
	LoginTicketTTL        = 5 * time.Minute
	minPasswordLength     = 8
	minPINLength          = 4
	maxPINLength          = 32

	defaultRegisterLimit  = 5
	defaultRegisterWindow = time.Hour
	loginIPBurstLimit     = 30
	loginIPBurstWindow    = 5 * time.Minute
	lastSeenTouchInterval = 60 * 1000 // ms
)

var (
	reUsername = regexp.MustCompile(`^[a-zA-Z0-9_.-]{3,32}$`)
	reEmail    = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)
)

type DeviceInput struct {
	DeviceID   string `json:"device_id,omitempty"`
	Class      string `json:"class"`
	Platform   string `json:"platform"`
	Name       string `json:"name"`
	AppVersion string `json:"app_version"`
}

type KeyWrapInput struct {
	WrapType      string `json:"wrap_type"`
	KdfAlg        string `json:"kdf_alg"`
	KdfSalt       string `json:"kdf_salt"`
	KdfParamsJSON string `json:"kdf_params_json"`
	WrappedHK     string `json:"wrapped_hk"`
	KeyEpoch      int    `json:"key_epoch,omitempty"`
}

type RegisterRequest struct {
	Username      string         `json:"username"`
	Email         string         `json:"email,omitempty"`
	Password      string         `json:"password"`
	InviteCode    string         `json:"invite_code,omitempty"`
	HouseholdName string         `json:"household_name,omitempty"`
	DisplayLang   string         `json:"display_lang,omitempty"`
	RecoveryCode  string         `json:"recovery_code,omitempty"`
	Device        DeviceInput    `json:"device"`
	KeyWraps      []KeyWrapInput `json:"key_wraps,omitempty"`
}

type LoginRequest struct {
	Username string      `json:"username"`
	Password string      `json:"password"`
	MemberID string      `json:"member_id,omitempty"`
	PIN      string      `json:"pin,omitempty"`
	Device   DeviceInput `json:"device"`
}

type SelectMemberRequest struct {
	LoginTicket string `json:"login_ticket"`
	MemberID    string `json:"member_id"`
	PIN         string `json:"pin,omitempty"`
	DeviceID    string `json:"device_id,omitempty"`
}

type ChangePasswordRequest struct {
	OldPassword     string        `json:"old_password"`
	NewPassword     string        `json:"new_password"`
	RecoveryCode    string        `json:"recovery_code,omitempty"`
	NewAccountWrap  *KeyWrapInput `json:"new_account_wrap,omitempty"`
	NewRecoveryWrap *KeyWrapInput `json:"new_recovery_wrap,omitempty"`
}

type RecoverPasswordRequest struct {
	Username       string        `json:"username"`
	RecoveryCode   string        `json:"recovery_code"`
	NewPassword    string        `json:"new_password"`
	NewAccountWrap *KeyWrapInput `json:"new_account_wrap,omitempty"`
}

type AuthResult struct {
	RequiresMemberSelect bool              `json:"requires_member_select,omitempty"`
	LoginTicket          string            `json:"login_ticket,omitempty"`
	TicketExpiresAt      int64             `json:"ticket_expires_at,omitempty"`
	AccessToken          string            `json:"access_token,omitempty"`
	TokenID              string            `json:"token_id,omitempty"`
	ExpiresAt            int64             `json:"expires_at,omitempty"`
	LoginMode            string            `json:"login_mode,omitempty"`
	MustChangePassword   bool              `json:"must_change_password,omitempty"`
	Household            *HouseholdInfo    `json:"household,omitempty"`
	Member               *MemberView       `json:"member,omitempty"`
	Members              []MemberView      `json:"members,omitempty"`
	Principal            *Principal        `json:"principal,omitempty"`
	KeyWraps             []keyring.KeyWrap `json:"key_wraps,omitempty"`
}

type Service struct {
	store          *db.Store
	limiter        *security.LoginLimiter
	nowFn          func() time.Time
	registerLimit  int
	registerWindow time.Duration
}

func NewService(store *db.Store, limiter *security.LoginLimiter) *Service {
	if limiter == nil {
		limiter = security.NewLoginLimiter()
	}
	return &Service{
		store:          store,
		limiter:        limiter,
		nowFn:          time.Now,
		registerLimit:  defaultRegisterLimit,
		registerWindow: defaultRegisterWindow,
	}
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
		s.limiter.SetClock(fn)
	}
}

func normalizeDeviceInput(in DeviceInput) (DeviceInput, error) {
	class := strings.TrimSpace(in.Class)
	if class == "" {
		class = db.DeviceClassWeb
	}
	if !IsValidDeviceClass(class) {
		return DeviceInput{}, fmt.Errorf("%w: unsupported device class %q", ErrInvalidInput, class)
	}
	return DeviceInput{
		DeviceID:   strings.TrimSpace(in.DeviceID),
		Class:      class,
		Platform:   strings.TrimSpace(in.Platform),
		Name:       strings.TrimSpace(in.Name),
		AppVersion: strings.TrimSpace(in.AppVersion),
	}, nil
}

func validatePassword(pw string) error {
	if len(pw) < minPasswordLength {
		return fmt.Errorf("%w: password must be at least %d characters", ErrInvalidInput, minPasswordLength)
	}
	return nil
}

func toKeyringWrap(hhID, subjectID string, in KeyWrapInput) (keyring.KeyWrap, error) {
	w := keyring.KeyWrap{
		HouseholdID:   hhID,
		WrapType:      strings.TrimSpace(in.WrapType),
		SubjectID:     strings.TrimSpace(subjectID),
		KdfAlg:        strings.TrimSpace(in.KdfAlg),
		KdfSalt:       strings.TrimSpace(in.KdfSalt),
		KdfParamsJSON: strings.TrimSpace(in.KdfParamsJSON),
		WrappedHK:     strings.TrimSpace(in.WrappedHK),
		KeyEpoch:      in.KeyEpoch,
	}
	if err := keyring.ValidateWrap(w); err != nil {
		return keyring.KeyWrap{}, fmt.Errorf("%w: %v", ErrInvalidInput, err)
	}
	return w, nil
}

// Register creates a new household owner account according to server registration_mode.
func (s *Service) Register(req RegisterRequest, ip string) (*AuthResult, error) {
	cfg := s.store.GetServerSettings()
	if cfg.RegistrationMode == db.RegistrationModeClosed {
		return nil, ErrRegistrationClosed
	}

	clientIP := strings.TrimSpace(ip)
	if !s.limiter.AllowWindow("register:"+clientIP, s.registerLimit, s.registerWindow) {
		return nil, &RateLimitError{RetryAfterSec: int(s.registerWindow.Seconds())}
	}

	user := strings.TrimSpace(req.Username)
	if !reUsername.MatchString(user) {
		return nil, fmt.Errorf("%w: username must be 3-32 chars [a-zA-Z0-9_.-]", ErrInvalidInput)
	}
	if err := validatePassword(req.Password); err != nil {
		return nil, err
	}
	var emailPtr *string
	if email := strings.ToLower(strings.TrimSpace(req.Email)); email != "" {
		if !reEmail.MatchString(email) {
			return nil, fmt.Errorf("%w: invalid email address", ErrInvalidInput)
		}
		emailPtr = &email
	}
	dev, err := normalizeDeviceInput(req.Device)
	if err != nil {
		return nil, err
	}
	hhName := strings.TrimSpace(req.HouseholdName)
	if hhName == "" {
		hhName = user + "的家庭"
	}
	if len([]rune(hhName)) > 64 {
		return nil, fmt.Errorf("%w: household_name too long", ErrInvalidInput)
	}
	lang := strings.TrimSpace(req.DisplayLang)
	if lang == "" {
		lang = "zh-CN"
	}

	var recSalt, recHash string
	if rec := strings.TrimSpace(req.RecoveryCode); rec != "" {
		if len(rec) < minPasswordLength {
			return nil, fmt.Errorf("%w: recovery_code too short", ErrInvalidInput)
		}
		recSalt, recHash, err = security.HashSecret(rec)
		if err != nil {
			return nil, err
		}
	}

	accID := uuid.NewString()
	hhID := uuid.NewString()
	memID := uuid.NewString()
	wraps := make([]keyring.KeyWrap, 0, len(req.KeyWraps))
	for _, kw := range req.KeyWraps {
		if kw.WrapType != keyring.WrapAccountPassword && kw.WrapType != keyring.WrapRecoveryCode {
			return nil, fmt.Errorf("%w: unsupported registration wrap_type %q", ErrInvalidInput, kw.WrapType)
		}
		w, err := toKeyringWrap(hhID, accID, kw)
		if err != nil {
			return nil, err
		}
		wraps = append(wraps, w)
	}

	salt, hash, err := security.HashSecret(req.Password)
	if err != nil {
		return nil, err
	}
	rawToken, tokenID, tokenHash, err := security.GenerateOpaqueToken(UserTokenPrefix)
	if err != nil {
		return nil, err
	}

	now := s.nowFn()
	nowMs := now.UnixMilli()
	expiresAt := now.Add(DefaultUserSessionTTL).UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if cfg.RegistrationMode == db.RegistrationModeInvite {
		code := strings.ToUpper(strings.TrimSpace(req.InviteCode))
		if code == "" {
			return nil, ErrInvalidInvite
		}
		res, err := tx.Exec(`
			UPDATE invite_codes
			SET used_count = used_count + 1
			WHERE code = ? AND revoked = 0 AND used_count < max_uses
			  AND (expires_at IS NULL OR expires_at > ?)`,
			code, nowMs,
		)
		if err != nil {
			return nil, err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return nil, ErrInvalidInvite
		}
	}

	// Ensure username does not collide with any independent member login_username.
	var conflictCnt int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM members WHERE login_username = ?`, user).Scan(&conflictCnt); err != nil {
		return nil, err
	}
	if conflictCnt > 0 {
		return nil, fmt.Errorf("%w: username already exists", ErrConflict)
	}

	if _, err := tx.Exec(`
		INSERT INTO accounts(
			id, username, email, password_salt, password_hash, must_change_password,
			status, registered_ip, last_active_at, created_at, updated_at, recovery_salt, recovery_hash
		) VALUES (?, ?, ?, ?, ?, 0, 'active', ?, ?, ?, ?, ?, ?)`,
		accID, user, emailPtr, salt, hash, clientIP, nowMs, nowMs, nowMs, recSalt, recHash,
	); err != nil {
		if isUniqueErr(err) {
			return nil, fmt.Errorf("%w: username or email already exists", ErrConflict)
		}
		return nil, err
	}

	if _, err := tx.Exec(`
		INSERT INTO households(id, owner_account_id, name, display_lang, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		hhID, accID, hhName, lang, nowMs, nowMs,
	); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`
		INSERT INTO members(id, household_id, nickname, role, permissions, status, created_at, updated_at)
		VALUES (?, ?, ?, 'owner', ?, 'active', ?, ?)`,
		memID, hhID, user, PermAll, nowMs, nowMs,
	); err != nil {
		return nil, err
	}

	devID, err := upsertDeviceTx(tx, hhID, dev, nowMs)
	if err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`
		INSERT INTO sessions(token_id, household_id, member_id, device_id, token_hash, ip, created_at, last_used_at, expires_at, login_mode)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, hhID, memID, devID, tokenHash, clientIP, nowMs, nowMs, expiresAt, LoginModeHousehold,
	); err != nil {
		return nil, err
	}

	for _, w := range wraps {
		if err := keyring.UpsertWrapTx(tx, nowMs, w); err != nil {
			return nil, err
		}
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     accID,
		HouseholdID: hhID,
		Action:      "account.registered",
		TargetType:  "household",
		TargetID:    hhID,
		IP:          clientIP,
		Detail:      map[string]any{"registration_mode": cfg.RegistrationMode},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return s.buildAuthResult(rawToken, tokenID, expiresAt, hhID, memID, devID, LoginModeHousehold, false)
}

// Login authenticates either a household owner account or an independent member login.
func (s *Service) Login(req LoginRequest, ip string) (*AuthResult, error) {
	user := strings.TrimSpace(req.Username)
	if user == "" || req.Password == "" {
		return nil, ErrInvalidCredentials
	}
	dev, err := normalizeDeviceInput(req.Device)
	if err != nil {
		return nil, err
	}
	clientIP := strings.TrimSpace(ip)
	if !s.limiter.AllowWindow("user:ip_burst:"+clientIP, loginIPBurstLimit, loginIPBurstWindow) {
		return nil, &RateLimitError{RetryAfterSec: int(loginIPBurstWindow.Seconds())}
	}

	userKey := "user:id:" + strings.ToLower(user)
	if locked, retry := s.limiter.CheckLockout(userKey); locked {
		return nil, &RateLimitError{RetryAfterSec: retry}
	}

	// 1. Try household account (username or email).
	var (
		accID, hhID        string
		salt, hash, status string
		mustChange         int
	)
	err = s.store.ReadDB().QueryRow(`
		SELECT a.id, COALESCE(h.id, ''), a.password_salt, a.password_hash, a.status, a.must_change_password
		FROM accounts a
		LEFT JOIN households h ON h.owner_account_id = a.id
		WHERE a.username = ? OR (a.email IS NOT NULL AND a.email = ?)`,
		user, strings.ToLower(user),
	).Scan(&accID, &hhID, &salt, &hash, &status, &mustChange)
	if err == nil {
		if !security.VerifySecret(req.Password, salt, hash) {
			s.recordLoginFailure(userKey, "account", accID, hhID, clientIP)
			return nil, ErrInvalidCredentials
		}
		if status == "disabled" {
			return nil, ErrAccountDisabled
		}
		if status == "pending_delete" {
			return nil, ErrAccountPendingDelete
		}
		if status != "active" || hhID == "" {
			return nil, ErrAccountDisabled
		}
		s.limiter.RecordSuccess(userKey)
		return s.completeHouseholdLogin(accID, hhID, mustChange == 1, req, dev, clientIP)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	// 2. Fall back to independent member login.
	var (
		memID, memStatus string
		memSalt, memHash string
		accStatus        string
	)
	err = s.store.ReadDB().QueryRow(`
		SELECT a.id, m.id, m.household_id, COALESCE(m.login_pass_salt, ''), COALESCE(m.login_pass_hash, ''), m.status, a.status
		FROM members m
		JOIN households h ON h.id = m.household_id
		JOIN accounts a ON a.id = h.owner_account_id
		WHERE m.login_username = ?`,
		user,
	).Scan(&accID, &memID, &hhID, &memSalt, &memHash, &memStatus, &accStatus)
	if errors.Is(err, sql.ErrNoRows) || memSalt == "" || memHash == "" {
		s.limiter.RecordFailure(userKey)
		_ = security.WriteAudit(s.store, security.AuditEntry{
			ActorType: "anonymous",
			ActorID:   user,
			Action:    "account.login_failed",
			IP:        clientIP,
		})
		return nil, ErrInvalidCredentials
	}
	if err != nil {
		return nil, err
	}
	if !security.VerifySecret(req.Password, memSalt, memHash) {
		s.recordLoginFailure(userKey, "member", memID, hhID, clientIP)
		return nil, ErrInvalidCredentials
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
	s.limiter.RecordSuccess(userKey)

	return s.issueSessionForMember(accID, hhID, memID, LoginModeMemberOnly, false, dev, clientIP, "member.login")
}

func (s *Service) recordLoginFailure(userKey, actorType, actorID, hhID, ip string) {
	s.limiter.RecordFailure(userKey)
	_ = security.WriteAudit(s.store, security.AuditEntry{
		ActorType:   actorType,
		ActorID:     actorID,
		HouseholdID: hhID,
		Action:      "account.login_failed",
		IP:          ip,
	})
}

func (s *Service) completeHouseholdLogin(
	accID, hhID string,
	mustChange bool,
	req LoginRequest,
	dev DeviceInput,
	clientIP string,
) (*AuthResult, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT id, COALESCE(pin_salt, ''), COALESCE(pin_hash, '')
		FROM members
		WHERE household_id = ? AND status = 'active'
		ORDER BY created_at ASC`, hhID,
	)
	if err != nil {
		return nil, err
	}
	type activeMem struct {
		id, pinSalt, pinHash string
	}
	var active []activeMem
	for rows.Next() {
		var m activeMem
		if err := rows.Scan(&m.id, &m.pinSalt, &m.pinHash); err != nil {
			_ = rows.Close()
			return nil, err
		}
		active = append(active, m)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(active) == 0 {
		return nil, ErrAccountDisabled
	}

	targetID := strings.TrimSpace(req.MemberID)
	if targetID != "" {
		var chosen *activeMem
		for i := range active {
			if active[i].id == targetID {
				chosen = &active[i]
				break
			}
		}
		if chosen == nil {
			return nil, ErrNotFound
		}
		if chosen.pinHash != "" {
			if err := s.verifyMemberPIN(hhID, chosen.id, req.PIN, chosen.pinSalt, chosen.pinHash); err != nil {
				return nil, err
			}
		}
		return s.issueSessionForMember(accID, hhID, chosen.id, LoginModeHousehold, mustChange, dev, clientIP, "account.login")
	}

	// Auto-login when only 1 active member exists and no PIN is set.
	if len(active) == 1 && active[0].pinHash == "" {
		return s.issueSessionForMember(accID, hhID, active[0].id, LoginModeHousehold, mustChange, dev, clientIP, "account.login")
	}

	// Otherwise issue a 5-minute login ticket for member selection / PIN verification.
	rawTicket, _, ticketHash, err := security.GenerateOpaqueToken(LoginTicketPrefix)
	if err != nil {
		return nil, err
	}
	now := s.nowFn()
	nowMs := now.UnixMilli()
	exp := now.Add(LoginTicketTTL).UnixMilli()

	if _, err := s.store.DB().Exec(`
		INSERT INTO account_login_tickets(
			ticket_hash, account_id, household_id, device_class, platform, device_name, app_version, ip, expires_at, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		ticketHash, accID, hhID, dev.Class, dev.Platform, dev.Name, dev.AppVersion, clientIP, exp, nowMs,
	); err != nil {
		return nil, err
	}

	hh, err := s.loadHouseholdInfo(hhID)
	if err != nil {
		return nil, err
	}
	members, err := s.loadHouseholdMembers(hhID, false)
	if err != nil {
		return nil, err
	}
	return &AuthResult{
		RequiresMemberSelect: true,
		LoginTicket:          rawTicket,
		TicketExpiresAt:      exp,
		LoginMode:            LoginModeHousehold,
		MustChangePassword:   mustChange,
		Household:            hh,
		Members:              members,
	}, nil
}

// SelectMember consumes a 5-minute login ticket, checks optional member PIN, and opens a session.
func (s *Service) SelectMember(req SelectMemberRequest, ip string) (*AuthResult, error) {
	if strings.TrimSpace(req.LoginTicket) == "" || strings.TrimSpace(req.MemberID) == "" {
		return nil, fmt.Errorf("%w: login_ticket and member_id are required", ErrInvalidInput)
	}
	ticketHash := security.HashToken(req.LoginTicket)
	nowMs := s.nowFn().UnixMilli()
	clientIP := strings.TrimSpace(ip)

	var (
		accID, hhID, devClass, devPlatform, devName, devAppVer string
		ticketExp                                              int64
		accStatus                                              string
		mustChange                                             int
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT t.account_id, t.household_id, t.device_class, t.platform, t.device_name, t.app_version, t.expires_at,
		       a.status, a.must_change_password
		FROM account_login_tickets t
		JOIN accounts a ON a.id = t.account_id
		WHERE t.ticket_hash = ?`, ticketHash,
	).Scan(&accID, &hhID, &devClass, &devPlatform, &devName, &devAppVer, &ticketExp, &accStatus, &mustChange)
	if errors.Is(err, sql.ErrNoRows) || nowMs >= ticketExp {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if accStatus == "disabled" {
		return nil, ErrAccountDisabled
	}
	if accStatus == "pending_delete" {
		return nil, ErrAccountPendingDelete
	}

	memID := strings.TrimSpace(req.MemberID)
	var pinSalt, pinHash, memStatus string
	err = s.store.ReadDB().QueryRow(`
		SELECT COALESCE(pin_salt, ''), COALESCE(pin_hash, ''), status FROM members WHERE id = ? AND household_id = ?`,
		memID, hhID,
	).Scan(&pinSalt, &pinHash, &memStatus)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if memStatus != "active" {
		return nil, ErrAccountDisabled
	}
	if pinHash != "" {
		if err := s.verifyMemberPIN(hhID, memID, req.PIN, pinSalt, pinHash); err != nil {
			return nil, err
		}
	}

	rawToken, tokenID, tokenHash, err := security.GenerateOpaqueToken(UserTokenPrefix)
	if err != nil {
		return nil, err
	}
	expiresAt := s.nowFn().Add(DefaultUserSessionTTL).UnixMilli()
	dev := DeviceInput{
		DeviceID:   strings.TrimSpace(req.DeviceID),
		Class:      devClass,
		Platform:   devPlatform,
		Name:       devName,
		AppVersion: devAppVer,
	}

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`DELETE FROM account_login_tickets WHERE ticket_hash = ? AND expires_at > ?`, ticketHash, nowMs)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrUnauthorized
	}

	devID, err := upsertDeviceTx(tx, hhID, dev, nowMs)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`
		INSERT INTO sessions(token_id, household_id, member_id, device_id, token_hash, ip, created_at, last_used_at, expires_at, login_mode)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, hhID, memID, devID, tokenHash, clientIP, nowMs, nowMs, expiresAt, LoginModeHousehold,
	); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE accounts SET last_active_at = ? WHERE id = ?`, nowMs, accID); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     accID,
		HouseholdID: hhID,
		Action:      "account.member_selected",
		TargetType:  "member",
		TargetID:    memID,
		IP:          clientIP,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return s.buildAuthResult(rawToken, tokenID, expiresAt, hhID, memID, devID, LoginModeHousehold, mustChange == 1)
}

// SwitchMember changes the active member on an existing household-mode session.
func (s *Service) SwitchMember(p *Principal, targetMemberID, pin, ip string) (*AuthResult, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if p.LoginMode == LoginModeMemberOnly {
		return nil, fmt.Errorf("%w: independent member session cannot switch members", ErrForbidden)
	}
	targetID := strings.TrimSpace(targetMemberID)
	if targetID == "" {
		return nil, fmt.Errorf("%w: member_id is required", ErrInvalidInput)
	}

	var pinSalt, pinHash, status string
	err := s.store.ReadDB().QueryRow(`
		SELECT COALESCE(pin_salt, ''), COALESCE(pin_hash, ''), status FROM members WHERE id = ? AND household_id = ?`,
		targetID, p.HouseholdID,
	).Scan(&pinSalt, &pinHash, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status != "active" {
		return nil, ErrAccountDisabled
	}
	if pinHash != "" {
		if err := s.verifyMemberPIN(p.HouseholdID, targetID, pin, pinSalt, pinHash); err != nil {
			return nil, err
		}
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE sessions SET member_id = ?, last_used_at = ?
		WHERE token_id = ? AND household_id = ?`,
		targetID, nowMs, p.TokenID, p.HouseholdID,
	)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrUnauthorized
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "member",
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "account.member_switched",
		TargetType:  "member",
		TargetID:    targetID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return s.buildAuthResult("", p.TokenID, p.ExpiresAt, p.HouseholdID, targetID, p.DeviceID, p.LoginMode, false)
}

func (s *Service) verifyMemberPIN(hhID, memID, pin, pinSalt, pinHash string) error {
	key := "pin:" + hhID + ":" + memID
	if locked, retry := s.limiter.CheckLockout(key); locked {
		return &RateLimitError{RetryAfterSec: retry}
	}
	if !security.VerifySecret(pin, pinSalt, pinHash) {
		s.limiter.RecordFailure(key)
		return ErrInvalidCredentials
	}
	s.limiter.RecordSuccess(key)
	return nil
}

func (s *Service) issueSessionForMember(
	accID, hhID, memID, loginMode string,
	mustChange bool,
	dev DeviceInput,
	clientIP, auditAction string,
) (*AuthResult, error) {
	rawToken, tokenID, tokenHash, err := security.GenerateOpaqueToken(UserTokenPrefix)
	if err != nil {
		return nil, err
	}
	now := s.nowFn()
	nowMs := now.UnixMilli()
	expiresAt := now.Add(DefaultUserSessionTTL).UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	devID, err := upsertDeviceTx(tx, hhID, dev, nowMs)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`
		INSERT INTO sessions(token_id, household_id, member_id, device_id, token_hash, ip, created_at, last_used_at, expires_at, login_mode)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, hhID, memID, devID, tokenHash, clientIP, nowMs, nowMs, expiresAt, loginMode,
	); err != nil {
		return nil, err
	}
	if accID != "" {
		if _, err := tx.Exec(`UPDATE accounts SET last_active_at = ? WHERE id = ?`, nowMs, accID); err != nil {
			return nil, err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(loginMode),
		ActorID:     memID,
		HouseholdID: hhID,
		Action:      auditAction,
		TargetType:  "session",
		TargetID:    tokenID,
		IP:          clientIP,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return s.buildAuthResult(rawToken, tokenID, expiresAt, hhID, memID, devID, loginMode, mustChange)
}

func loginModeActorType(loginMode string) string {
	if loginMode == LoginModeMemberOnly {
		return "member"
	}
	return "account"
}

func upsertDeviceTx(tx *sql.Tx, hhID string, dev DeviceInput, nowMs int64) (string, error) {
	if dev.DeviceID != "" {
		res, err := tx.Exec(`
			UPDATE devices
			SET device_class = ?, platform = ?, name = ?, app_version = ?, last_seen_at = ?
			WHERE id = ? AND household_id = ?`,
			dev.Class, dev.Platform, dev.Name, dev.AppVersion, nowMs, dev.DeviceID, hhID,
		)
		if err != nil {
			return "", err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			return dev.DeviceID, nil
		}
	}
	devID := uuid.NewString()
	if _, err := tx.Exec(`
		INSERT INTO devices(id, household_id, device_class, platform, name, app_version, last_seen_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		devID, hhID, dev.Class, dev.Platform, dev.Name, dev.AppVersion, nowMs, nowMs,
	); err != nil {
		return "", err
	}
	return devID, nil
}

// Authenticate validates an opaque usr_ session token and resolves tenant/member context.
func (s *Service) Authenticate(rawToken string) (*Principal, error) {
	tok := strings.TrimSpace(rawToken)
	if !strings.HasPrefix(tok, UserTokenPrefix) {
		return nil, ErrUnauthorized
	}
	tokenHash := security.HashToken(tok)
	nowMs := s.nowFn().UnixMilli()

	var (
		p            Principal
		restrictInt  int
		accStatus    string
		memStatus    string
		lastUsedAt   int64
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT s.token_id, s.household_id, h.owner_account_id, s.member_id, m.nickname,
		       s.device_id, d.device_class, m.role, m.permissions, m.restrict_sources,
		       COALESCE(m.max_content_rating, ''), s.login_mode, s.expires_at, s.last_used_at,
		       a.status, m.status
		FROM sessions s
		JOIN households h ON h.id = s.household_id
		JOIN accounts a ON a.id = h.owner_account_id
		JOIN members m ON m.id = s.member_id AND m.household_id = s.household_id
		JOIN devices d ON d.id = s.device_id AND d.household_id = s.household_id
		WHERE s.token_hash = ?`,
		tokenHash,
	).Scan(
		&p.TokenID, &p.HouseholdID, &p.OwnerAccountID, &p.MemberID, &p.Nickname,
		&p.DeviceID, &p.DeviceClass, &p.Role, &p.Permissions, &restrictInt,
		&p.MaxContentRating, &p.LoginMode, &p.ExpiresAt, &lastUsedAt,
		&accStatus, &memStatus,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if nowMs >= p.ExpiresAt {
		_, _ = s.store.DB().Exec(`DELETE FROM sessions WHERE token_id = ?`, p.TokenID)
		return nil, ErrUnauthorized
	}
	if accStatus == "disabled" || accStatus == "pending_delete" || memStatus != "active" {
		return nil, ErrUnauthorized
	}
	p.RestrictSources = restrictInt == 1

	if nowMs-lastUsedAt >= lastSeenTouchInterval {
		_, _ = s.store.DB().Exec(`UPDATE sessions SET last_used_at = ? WHERE token_id = ?`, nowMs, p.TokenID)
		_, _ = s.store.DB().Exec(`UPDATE devices SET last_seen_at = ? WHERE id = ? AND household_id = ?`, nowMs, p.DeviceID, p.HouseholdID)
		_, _ = s.store.DB().Exec(`UPDATE accounts SET last_active_at = ? WHERE id = ?`, nowMs, p.OwnerAccountID)
	}
	return &p, nil
}

func (s *Service) Logout(rawToken string) error {
	tok := strings.TrimSpace(rawToken)
	if !strings.HasPrefix(tok, UserTokenPrefix) {
		return ErrUnauthorized
	}
	res, err := s.store.DB().Exec(`DELETE FROM sessions WHERE token_hash = ?`, security.HashToken(tok))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrUnauthorized
	}
	return nil
}

// ChangeAccountPassword updates the owner account password, optional E2EE wraps, and revokes other sessions.
func (s *Service) ChangeAccountPassword(p *Principal, req ChangePasswordRequest, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	if p.Role != RoleOwner || p.LoginMode != LoginModeHousehold {
		return fmt.Errorf("%w: only household owner session may change account password", ErrForbidden)
	}
	if err := validatePassword(req.NewPassword); err != nil {
		return err
	}

	var curSalt, curHash string
	if err := s.store.ReadDB().QueryRow(`SELECT password_salt, password_hash FROM accounts WHERE id = ?`, p.OwnerAccountID).
		Scan(&curSalt, &curHash); err != nil {
		return err
	}
	if !security.VerifySecret(req.OldPassword, curSalt, curHash) {
		return ErrInvalidCredentials
	}

	var accWrap, recWrap *keyring.KeyWrap
	if req.NewAccountWrap != nil {
		if req.NewAccountWrap.WrapType != keyring.WrapAccountPassword {
			return fmt.Errorf("%w: new_account_wrap must have wrap_type account_password", ErrInvalidInput)
		}
		w, err := toKeyringWrap(p.HouseholdID, p.OwnerAccountID, *req.NewAccountWrap)
		if err != nil {
			return err
		}
		accWrap = &w
	}
	if req.NewRecoveryWrap != nil {
		if req.NewRecoveryWrap.WrapType != keyring.WrapRecoveryCode {
			return fmt.Errorf("%w: new_recovery_wrap must have wrap_type recovery_code", ErrInvalidInput)
		}
		w, err := toKeyringWrap(p.HouseholdID, p.OwnerAccountID, *req.NewRecoveryWrap)
		if err != nil {
			return err
		}
		recWrap = &w
	}

	newSalt, newHash, err := security.HashSecret(req.NewPassword)
	if err != nil {
		return err
	}
	var recSalt, recHash string
	updateRecovery := strings.TrimSpace(req.RecoveryCode) != ""
	if updateRecovery {
		if len(strings.TrimSpace(req.RecoveryCode)) < minPasswordLength {
			return fmt.Errorf("%w: recovery_code too short", ErrInvalidInput)
		}
		recSalt, recHash, err = security.HashSecret(strings.TrimSpace(req.RecoveryCode))
		if err != nil {
			return err
		}
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if updateRecovery {
		_, err = tx.Exec(`
			UPDATE accounts
			SET password_salt = ?, password_hash = ?, recovery_salt = ?, recovery_hash = ?, must_change_password = 0, updated_at = ?
			WHERE id = ?`,
			newSalt, newHash, recSalt, recHash, nowMs, p.OwnerAccountID,
		)
	} else {
		_, err = tx.Exec(`
			UPDATE accounts
			SET password_salt = ?, password_hash = ?, must_change_password = 0, updated_at = ?
			WHERE id = ?`,
			newSalt, newHash, nowMs, p.OwnerAccountID,
		)
	}
	if err != nil {
		return err
	}

	if accWrap != nil {
		if err := keyring.UpsertWrapTx(tx, nowMs, *accWrap); err != nil {
			return err
		}
	}
	if recWrap != nil {
		if err := keyring.UpsertWrapTx(tx, nowMs, *recWrap); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ? AND token_id != ?`, p.HouseholdID, p.TokenID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, p.HouseholdID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     p.OwnerAccountID,
		HouseholdID: p.HouseholdID,
		Action:      "account.password_changed",
		TargetType:  "account",
		TargetID:    p.OwnerAccountID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return err
	}
	return tx.Commit()
}

// GetRecoveryWrap verifies username + recovery_code before returning the household recovery wrap.
func (s *Service) GetRecoveryWrap(username, recoveryCode, ip string) (*keyring.KeyWrap, error) {
	accID, hhID, err := s.verifyRecoveryCode(username, recoveryCode, ip)
	if err != nil {
		return nil, err
	}
	wraps, err := keyring.ListWraps(s.store, hhID, []string{keyring.WrapRecoveryCode}, accID)
	if err != nil {
		return nil, err
	}
	if len(wraps) == 0 {
		return nil, ErrNotFound
	}
	w := wraps[0]
	return &w, nil
}

// RecoverAccountPassword resets the account password using the verified recovery code and optional re-wrapped HK.
func (s *Service) RecoverAccountPassword(req RecoverPasswordRequest, ip string) error {
	if err := validatePassword(req.NewPassword); err != nil {
		return err
	}
	accID, hhID, err := s.verifyRecoveryCode(req.Username, req.RecoveryCode, ip)
	if err != nil {
		return err
	}

	var accWrap *keyring.KeyWrap
	if req.NewAccountWrap != nil {
		if req.NewAccountWrap.WrapType != keyring.WrapAccountPassword {
			return fmt.Errorf("%w: new_account_wrap must have wrap_type account_password", ErrInvalidInput)
		}
		w, err := toKeyringWrap(hhID, accID, *req.NewAccountWrap)
		if err != nil {
			return err
		}
		accWrap = &w
	}

	newSalt, newHash, err := security.HashSecret(req.NewPassword)
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
		UPDATE accounts
		SET password_salt = ?, password_hash = ?, must_change_password = 0, updated_at = ?
		WHERE id = ?`,
		newSalt, newHash, nowMs, accID,
	); err != nil {
		return err
	}
	if accWrap != nil {
		if err := keyring.UpsertWrapTx(tx, nowMs, *accWrap); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, hhID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, hhID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     accID,
		HouseholdID: hhID,
		Action:      "account.password_recovered",
		TargetType:  "account",
		TargetID:    accID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) verifyRecoveryCode(username, recoveryCode, ip string) (accID, hhID string, err error) {
	user := strings.TrimSpace(username)
	code := strings.TrimSpace(recoveryCode)
	if user == "" || code == "" {
		return "", "", ErrInvalidCredentials
	}
	clientIP := strings.TrimSpace(ip)
	if !s.limiter.AllowWindow("recover:ip:"+clientIP, loginIPBurstLimit, loginIPBurstWindow) {
		return "", "", &RateLimitError{RetryAfterSec: int(loginIPBurstWindow.Seconds())}
	}
	key := "recover:user:" + strings.ToLower(user)
	if locked, retry := s.limiter.CheckLockout(key); locked {
		return "", "", &RateLimitError{RetryAfterSec: retry}
	}

	var recSalt, recHash, status string
	qErr := s.store.ReadDB().QueryRow(`
		SELECT a.id, COALESCE(h.id, ''), COALESCE(a.recovery_salt, ''), COALESCE(a.recovery_hash, ''), a.status
		FROM accounts a
		LEFT JOIN households h ON h.owner_account_id = a.id
		WHERE a.username = ? OR (a.email IS NOT NULL AND a.email = ?)`,
		user, strings.ToLower(user),
	).Scan(&accID, &hhID, &recSalt, &recHash, &status)
	if qErr != nil || recSalt == "" || recHash == "" || !security.VerifySecret(code, recSalt, recHash) {
		s.limiter.RecordFailure(key)
		return "", "", ErrInvalidCredentials
	}
	if status == "disabled" {
		return "", "", ErrAccountDisabled
	}
	if status == "pending_delete" {
		return "", "", ErrAccountPendingDelete
	}
	s.limiter.RecordSuccess(key)
	return accID, hhID, nil
}

// ScheduleSelfDelete places the owner's account into a 7-day deletion grace period,
// revoking all active sessions and wiping encrypted source credentials immediately (G11).
func (s *Service) ScheduleSelfDelete(p *Principal, password, ip string) (int64, error) {
	if p == nil {
		return 0, ErrUnauthorized
	}
	if p.Role != RoleOwner || p.LoginMode != LoginModeHousehold || !p.HasPerm(PermDeleteHousehold) {
		return 0, fmt.Errorf("%w: only household owner may delete the account", ErrForbidden)
	}
	if password == "" {
		return 0, ErrInvalidCredentials
	}

	var salt, hash string
	if err := s.store.ReadDB().QueryRow(`SELECT password_salt, password_hash FROM accounts WHERE id = ?`, p.OwnerAccountID).
		Scan(&salt, &hash); err != nil {
		return 0, err
	}
	if !security.VerifySecret(password, salt, hash) {
		return 0, ErrInvalidCredentials
	}

	now := s.nowFn()
	nowMs := now.UnixMilli()
	deleteAfter := now.Add(7 * 24 * time.Hour).UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE accounts SET status = 'pending_delete', delete_after = ?, updated_at = ? WHERE id = ?`,
		deleteAfter, nowMs, p.OwnerAccountID,
	); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, p.HouseholdID); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, p.HouseholdID); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM source_credentials WHERE household_id = ?`, p.HouseholdID); err != nil {
		return 0, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "account",
		ActorID:     p.OwnerAccountID,
		HouseholdID: p.HouseholdID,
		Action:      "account.self_schedule_delete",
		TargetType:  "account",
		TargetID:    p.OwnerAccountID,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"delete_after": deleteAfter},
	}); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleteAfter, nil
}

// ListMyKeyWraps returns only the E2EE wraps the current session principal is authorized to fetch.
func (s *Service) ListMyKeyWraps(p *Principal) ([]keyring.KeyWrap, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if p.LoginMode == LoginModeMemberOnly {
		return keyring.ListWraps(s.store, p.HouseholdID, []string{keyring.WrapMemberPassword}, p.MemberID)
	}
	if p.Role == RoleOwner {
		return keyring.ListWraps(s.store, p.HouseholdID, nil, "")
	}
	accountWraps, err := keyring.ListWraps(s.store, p.HouseholdID, []string{keyring.WrapAccountPassword}, p.OwnerAccountID)
	if err != nil {
		return nil, err
	}
	memberWraps, err := keyring.ListWraps(s.store, p.HouseholdID, []string{keyring.WrapMemberPassword}, p.MemberID)
	if err != nil {
		return nil, err
	}
	return append(accountWraps, memberWraps...), nil
}

// UpsertKeyWrap creates or updates an E2EE household key wrap within the caller's household.
func (s *Service) UpsertKeyWrap(p *Principal, input KeyWrapInput, targetSubjectID, recoveryCode, ip string) (*keyring.KeyWrap, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	wt := strings.TrimSpace(input.WrapType)
	var subjectID string
	switch wt {
	case keyring.WrapAccountPassword, keyring.WrapRecoveryCode:
		if p.Role != RoleOwner || p.LoginMode != LoginModeHousehold {
			return nil, fmt.Errorf("%w: only household owner session may update household key wrap", ErrForbidden)
		}
		subjectID = p.OwnerAccountID
	case keyring.WrapMemberPassword:
		sub := strings.TrimSpace(targetSubjectID)
		if sub == "" {
			sub = p.MemberID
		}
		if sub != p.MemberID && !p.HasPerm(PermManageMembers) {
			return nil, ErrForbidden
		}
		var cnt int
		if err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM members WHERE id = ? AND household_id = ?`, sub, p.HouseholdID).Scan(&cnt); err != nil {
			return nil, err
		}
		if cnt == 0 {
			return nil, ErrNotFound
		}
		subjectID = sub
	default:
		return nil, fmt.Errorf("%w: unsupported wrap_type %q", ErrInvalidInput, input.WrapType)
	}

	w, err := toKeyringWrap(p.HouseholdID, subjectID, input)
	if err != nil {
		return nil, err
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if wt == keyring.WrapRecoveryCode && strings.TrimSpace(recoveryCode) != "" {
		rec := strings.TrimSpace(recoveryCode)
		if len(rec) < minPasswordLength {
			return nil, fmt.Errorf("%w: recovery_code too short", ErrInvalidInput)
		}
		recSalt, recHash, err := security.HashSecret(rec)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`UPDATE accounts SET recovery_salt = ?, recovery_hash = ?, updated_at = ? WHERE id = ?`,
			recSalt, recHash, nowMs, p.OwnerAccountID,
		); err != nil {
			return nil, err
		}
	}

	if err := keyring.UpsertWrapTx(tx, nowMs, w); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "keyring.wrap_upserted",
		TargetType:  wt,
		TargetID:    subjectID,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"key_epoch": w.KeyEpoch},
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	wraps, err := keyring.ListWraps(s.store, p.HouseholdID, []string{wt}, subjectID)
	if err != nil {
		return nil, err
	}
	if len(wraps) == 0 {
		return &w, nil
	}
	out := wraps[0]
	return &out, nil
}

func (s *Service) buildAuthResult(
	rawToken, tokenID string,
	expiresAt int64,
	hhID, memID, devID, loginMode string,
	mustChange bool,
) (*AuthResult, error) {
	hh, err := s.loadHouseholdInfo(hhID)
	if err != nil {
		return nil, err
	}
	member, err := s.loadMemberView(hhID, memID, true)
	if err != nil {
		return nil, err
	}
	p := &Principal{
		TokenID:          tokenID,
		HouseholdID:      hhID,
		OwnerAccountID:   hh.OwnerAccountID,
		MemberID:         member.ID,
		Nickname:         member.Nickname,
		DeviceID:         devID,
		Role:             member.Role,
		Permissions:      member.Permissions,
		RestrictSources:  member.RestrictSources,
		MaxContentRating: member.MaxContentRating,
		LoginMode:        loginMode,
		ExpiresAt:        expiresAt,
	}
	_ = s.store.DB().QueryRow(`SELECT device_class FROM devices WHERE id = ? AND household_id = ?`, devID, hhID).Scan(&p.DeviceClass)

	var members []MemberView
	if loginMode == LoginModeHousehold {
		members, err = s.loadHouseholdMembers(hhID, p.HasPerm(PermManageMembers))
		if err != nil {
			return nil, err
		}
	} else {
		members = []MemberView{*member}
	}

	wraps, err := s.ListMyKeyWraps(p)
	if err != nil {
		return nil, err
	}

	return &AuthResult{
		AccessToken:        rawToken,
		TokenID:            tokenID,
		ExpiresAt:          expiresAt,
		LoginMode:          loginMode,
		MustChangePassword: mustChange,
		Household:          hh,
		Member:             member,
		Members:            members,
		Principal:          p,
		KeyWraps:           wraps,
	}, nil
}

func isUniqueErr(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "unique")
}
