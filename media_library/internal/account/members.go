package account

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/security"
)

type HouseholdInfo struct {
	ID                   string `json:"id"`
	OwnerAccountID       string `json:"owner_account_id"`
	Name                 string `json:"name"`
	DisplayLang          string `json:"display_lang"`
	QuotaMaxSources      int    `json:"quota_max_sources"`
	QuotaMaxFiles        int    `json:"quota_max_files"`
	QuotaMaxSidecarBytes int64  `json:"quota_max_sidecar_bytes"`
	NextChangeSeq        int64  `json:"next_change_seq"`
	MinRetainedSeq       int64  `json:"min_retained_seq"`
	MemberCount          int    `json:"member_count"`
	DeviceCount          int    `json:"device_count"`
	CreatedAt            int64  `json:"created_at"`
	UpdatedAt            int64  `json:"updated_at"`
}

type MemberView struct {
	ID                  string   `json:"id"`
	HouseholdID         string   `json:"household_id"`
	Nickname            string   `json:"nickname"`
	Avatar              string   `json:"avatar,omitempty"`
	Role                string   `json:"role"`
	Permissions         int      `json:"permissions"`
	RestrictSources     bool     `json:"restrict_sources"`
	HasPIN              bool     `json:"has_pin"`
	HasIndependentLogin bool     `json:"has_independent_login"`
	LoginUsername       string   `json:"login_username,omitempty"`
	MaxContentRating    string   `json:"max_content_rating,omitempty"`
	Status              string   `json:"status"`
	AllowedSourceIDs    []string `json:"allowed_source_ids,omitempty"`
	CreatedAt           int64    `json:"created_at"`
	UpdatedAt           int64    `json:"updated_at"`
}

type CreateMemberRequest struct {
	Nickname         string        `json:"nickname"`
	Avatar           string        `json:"avatar,omitempty"`
	Role             string        `json:"role"`
	Permissions      *int          `json:"permissions,omitempty"`
	RestrictSources  bool          `json:"restrict_sources"`
	PIN              string        `json:"pin,omitempty"`
	LoginUsername    string        `json:"login_username,omitempty"`
	LoginPassword    string        `json:"login_password,omitempty"`
	MaxContentRating string        `json:"max_content_rating,omitempty"`
	AllowedSourceIDs []string      `json:"allowed_source_ids,omitempty"`
	MemberWrap       *KeyWrapInput `json:"member_wrap,omitempty"`
}

type UpdateMemberRequest struct {
	Nickname         *string       `json:"nickname,omitempty"`
	Avatar           *string       `json:"avatar,omitempty"`
	Role             *string       `json:"role,omitempty"`
	Permissions      *int          `json:"permissions,omitempty"`
	RestrictSources  *bool         `json:"restrict_sources,omitempty"`
	PIN              *string       `json:"pin,omitempty"`
	LoginUsername    *string       `json:"login_username,omitempty"`
	LoginPassword    *string       `json:"login_password,omitempty"`
	MaxContentRating *string       `json:"max_content_rating,omitempty"`
	Status           *string       `json:"status,omitempty"`
	AllowedSourceIDs *[]string     `json:"allowed_source_ids,omitempty"`
	MemberWrap       *KeyWrapInput `json:"member_wrap,omitempty"`
}

type DeviceView struct {
	ID              string `json:"id"`
	HouseholdID     string `json:"household_id"`
	DeviceClass     string `json:"device_class"`
	Platform        string `json:"platform"`
	Name            string `json:"name"`
	AppVersion      string `json:"app_version"`
	LastSeenAt      *int64 `json:"last_seen_at,omitempty"`
	CreatedAt       int64  `json:"created_at"`
	IsCurrentDevice bool   `json:"is_current_device"`
}

type SessionView struct {
	TokenID          string `json:"token_id"`
	HouseholdID      string `json:"household_id"`
	MemberID         string `json:"member_id"`
	MemberNickname   string `json:"member_nickname,omitempty"`
	DeviceID         string `json:"device_id"`
	DeviceName       string `json:"device_name,omitempty"`
	DeviceClass      string `json:"device_class,omitempty"`
	LoginMode        string `json:"login_mode"`
	IP               string `json:"ip,omitempty"`
	CreatedAt        int64  `json:"created_at"`
	LastUsedAt       int64  `json:"last_used_at"`
	ExpiresAt        int64  `json:"expires_at"`
	IsCurrentSession bool   `json:"is_current_session"`
}

func (s *Service) GetHousehold(p *Principal) (*HouseholdInfo, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	return s.loadHouseholdInfo(p.HouseholdID)
}

func (s *Service) UpdateHousehold(p *Principal, name, displayLang *string, ip string) (*HouseholdInfo, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(PermManageSettings) {
		return nil, ErrForbidden
	}

	cur, err := s.loadHouseholdInfo(p.HouseholdID)
	if err != nil {
		return nil, err
	}

	newName := cur.Name
	if name != nil {
		trimmed := strings.TrimSpace(*name)
		if trimmed == "" || len([]rune(trimmed)) > 64 {
			return nil, fmt.Errorf("%w: household name must be 1-64 characters", ErrInvalidInput)
		}
		newName = trimmed
	}
	newLang := cur.DisplayLang
	if displayLang != nil {
		trimmed := strings.TrimSpace(*displayLang)
		if len(trimmed) < 2 || len(trimmed) > 16 {
			return nil, fmt.Errorf("%w: display_lang must be 2-16 characters", ErrInvalidInput)
		}
		newLang = trimmed
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE households SET name = ?, display_lang = ?, updated_at = ? WHERE id = ?`,
		newName, newLang, nowMs, p.HouseholdID,
	); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "household.updated",
		TargetType:  "household",
		TargetID:    p.HouseholdID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.loadHouseholdInfo(p.HouseholdID)
}

func (s *Service) ListMembers(p *Principal) ([]MemberView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if p.LoginMode == LoginModeMemberOnly && !p.HasPerm(PermManageMembers) {
		m, err := s.loadMemberView(p.HouseholdID, p.MemberID, true)
		if err != nil {
			return nil, err
		}
		return []MemberView{*m}, nil
	}
	return s.loadHouseholdMembers(p.HouseholdID, p.HasPerm(PermManageMembers))
}

func (s *Service) CreateMember(p *Principal, req CreateMemberRequest, ip string) (*MemberView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if !p.HasPerm(PermManageMembers) {
		return nil, ErrForbidden
	}

	nickname := strings.TrimSpace(req.Nickname)
	if nickname == "" || len([]rune(nickname)) > 64 {
		return nil, fmt.Errorf("%w: nickname must be 1-64 characters", ErrInvalidInput)
	}
	role := strings.TrimSpace(req.Role)
	if role == "" {
		role = RoleMember
	}
	if !IsValidRole(role) || role == RoleOwner {
		return nil, fmt.Errorf("%w: invalid member role %q", ErrInvalidInput, role)
	}

	perms := DefaultPermissionsForRole(role)
	if req.Permissions != nil {
		perms = SanitizePermissionsForRole(role, *req.Permissions)
	}

	var pinSalt, pinHash string
	if req.PIN != "" {
		if len(req.PIN) < minPINLength || len(req.PIN) > maxPINLength {
			return nil, fmt.Errorf("%w: PIN must be %d-%d characters", ErrInvalidInput, minPINLength, maxPINLength)
		}
		var err error
		pinSalt, pinHash, err = security.HashSecret(req.PIN)
		if err != nil {
			return nil, err
		}
	}

	loginUser := strings.TrimSpace(req.LoginUsername)
	var loginUserPtr *string
	var loginSalt, loginHash string
	if loginUser != "" || req.LoginPassword != "" {
		if loginUser == "" || req.LoginPassword == "" {
			return nil, fmt.Errorf("%w: both login_username and login_password are required", ErrInvalidInput)
		}
		if !reUsername.MatchString(loginUser) {
			return nil, fmt.Errorf("%w: login_username must be 3-32 chars [a-zA-Z0-9_.-]", ErrInvalidInput)
		}
		if err := validatePassword(req.LoginPassword); err != nil {
			return nil, err
		}
		var err error
		loginSalt, loginHash, err = security.HashSecret(req.LoginPassword)
		if err != nil {
			return nil, err
		}
		loginUserPtr = &loginUser
	}

	memID := uuid.NewString()
	var wrap *keyring.KeyWrap
	if req.MemberWrap != nil {
		if req.MemberWrap.WrapType != keyring.WrapMemberPassword {
			return nil, fmt.Errorf("%w: member_wrap must have wrap_type member_password", ErrInvalidInput)
		}
		w, err := toKeyringWrap(p.HouseholdID, memID, *req.MemberWrap)
		if err != nil {
			return nil, err
		}
		wrap = &w
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if loginUserPtr != nil {
		var accDup int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM accounts WHERE username = ?`, *loginUserPtr).Scan(&accDup); err != nil {
			return nil, err
		}
		if accDup > 0 {
			return nil, fmt.Errorf("%w: login_username already taken", ErrConflict)
		}
	}

	if err := validateAllowedSourcesTx(tx, p.HouseholdID, req.AllowedSourceIDs); err != nil {
		return nil, err
	}

	restrictInt := 0
	if req.RestrictSources {
		restrictInt = 1
	}

	if _, err := tx.Exec(`
		INSERT INTO members(
			id, household_id, nickname, avatar, role, permissions, restrict_sources,
			pin_salt, pin_hash, login_username, login_pass_salt, login_pass_hash,
			max_content_rating, status, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
		memID, p.HouseholdID, nickname, strings.TrimSpace(req.Avatar), role, perms, restrictInt,
		pinSalt, pinHash, loginUserPtr, loginSalt, loginHash,
		strings.TrimSpace(req.MaxContentRating), nowMs, nowMs,
	); err != nil {
		if isUniqueErr(err) {
			return nil, fmt.Errorf("%w: login_username already exists", ErrConflict)
		}
		return nil, err
	}

	for _, srcID := range dedupStrings(req.AllowedSourceIDs) {
		if _, err := tx.Exec(`
			INSERT INTO member_source_access(household_id, member_id, source_id) VALUES (?, ?, ?)`,
			p.HouseholdID, memID, srcID,
		); err != nil {
			return nil, err
		}
	}

	if wrap != nil {
		if err := keyring.UpsertWrapTx(tx, nowMs, *wrap); err != nil {
			return nil, err
		}
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "member.created",
		TargetType:  "member",
		TargetID:    memID,
		IP:          strings.TrimSpace(ip),
		Detail:      map[string]any{"role": role},
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.loadMemberView(p.HouseholdID, memID, true)
}

func (s *Service) UpdateMember(p *Principal, memberID string, req UpdateMemberRequest, ip string) (*MemberView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	targetID := strings.TrimSpace(memberID)
	if targetID == "" {
		return nil, ErrNotFound
	}

	canManage := p.HasPerm(PermManageMembers)
	if !canManage {
		if targetID != p.MemberID {
			return nil, ErrForbidden
		}
		if req.Role != nil || req.Permissions != nil || req.RestrictSources != nil ||
			req.AllowedSourceIDs != nil || req.MaxContentRating != nil || req.Status != nil || req.LoginUsername != nil {
			return nil, ErrForbidden
		}
		if p.Role == RoleChild && (req.PIN != nil || req.LoginPassword != nil || req.MemberWrap != nil) {
			return nil, ErrForbidden
		}
	}

	var (
		curNickname, curAvatar, curRole, curRating, curStatus string
		curPerms, curRestrict                                 int
		curPinSalt, curPinHash                                string
		curLoginUser                                          sql.NullString
		curLoginSalt, curLoginHash                            string
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT nickname, avatar, role, permissions, restrict_sources,
		       COALESCE(pin_salt, ''), COALESCE(pin_hash, ''), login_username,
		       COALESCE(login_pass_salt, ''), COALESCE(login_pass_hash, ''),
		       COALESCE(max_content_rating, ''), status
		FROM members
		WHERE id = ? AND household_id = ?`,
		targetID, p.HouseholdID,
	).Scan(
		&curNickname, &curAvatar, &curRole, &curPerms, &curRestrict,
		&curPinSalt, &curPinHash, &curLoginUser, &curLoginSalt, &curLoginHash,
		&curRating, &curStatus,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// Only owner may modify the household owner profile.
	if curRole == RoleOwner && p.Role != RoleOwner {
		return nil, fmt.Errorf("%w: non-owner cannot modify household owner", ErrForbidden)
	}

	newNickname := curNickname
	if req.Nickname != nil {
		trimmed := strings.TrimSpace(*req.Nickname)
		if trimmed == "" || len([]rune(trimmed)) > 64 {
			return nil, fmt.Errorf("%w: nickname must be 1-64 characters", ErrInvalidInput)
		}
		newNickname = trimmed
	}
	newAvatar := curAvatar
	if req.Avatar != nil {
		newAvatar = strings.TrimSpace(*req.Avatar)
	}

	newRole := curRole
	if req.Role != nil {
		r := strings.TrimSpace(*req.Role)
		if !IsValidRole(r) {
			return nil, fmt.Errorf("%w: invalid role %q", ErrInvalidInput, r)
		}
		if curRole == RoleOwner && r != RoleOwner {
			return nil, fmt.Errorf("%w: cannot demote household owner", ErrForbidden)
		}
		if curRole != RoleOwner && r == RoleOwner {
			return nil, fmt.Errorf("%w: cannot promote member to owner", ErrForbidden)
		}
		newRole = r
	}

	newPerms := curPerms
	if curRole == RoleOwner {
		newPerms = PermAll
	} else if req.Permissions != nil {
		newPerms = SanitizePermissionsForRole(newRole, *req.Permissions)
	} else if req.Role != nil && newRole != curRole {
		newPerms = DefaultPermissionsForRole(newRole)
	}

	newRestrict := curRestrict
	if req.RestrictSources != nil {
		if curRole == RoleOwner && *req.RestrictSources {
			return nil, fmt.Errorf("%w: household owner cannot be source-restricted", ErrForbidden)
		}
		if *req.RestrictSources {
			newRestrict = 1
		} else {
			newRestrict = 0
		}
	}

	newRating := curRating
	if req.MaxContentRating != nil {
		newRating = strings.TrimSpace(*req.MaxContentRating)
	}

	newStatus := curStatus
	if req.Status != nil {
		st := strings.TrimSpace(*req.Status)
		if st != "active" && st != "disabled" {
			return nil, fmt.Errorf("%w: status must be active or disabled", ErrInvalidInput)
		}
		if curRole == RoleOwner && st != "active" {
			return nil, fmt.Errorf("%w: cannot disable household owner", ErrForbidden)
		}
		newStatus = st
	}

	newPinSalt, newPinHash := curPinSalt, curPinHash
	if req.PIN != nil {
		if *req.PIN == "" {
			newPinSalt, newPinHash = "", ""
		} else {
			if len(*req.PIN) < minPINLength || len(*req.PIN) > maxPINLength {
				return nil, fmt.Errorf("%w: PIN must be %d-%d characters", ErrInvalidInput, minPINLength, maxPINLength)
			}
			newPinSalt, newPinHash, err = security.HashSecret(*req.PIN)
			if err != nil {
				return nil, err
			}
		}
	}

	var newLoginUserPtr *string
	if curLoginUser.Valid && curLoginUser.String != "" {
		v := curLoginUser.String
		newLoginUserPtr = &v
	}
	newLoginSalt, newLoginHash := curLoginSalt, curLoginHash
	revokeMemberOnlySessions := false

	if req.LoginUsername != nil {
		u := strings.TrimSpace(*req.LoginUsername)
		if u == "" {
			newLoginUserPtr = nil
			newLoginSalt, newLoginHash = "", ""
			revokeMemberOnlySessions = true
		} else {
			if !reUsername.MatchString(u) {
				return nil, fmt.Errorf("%w: login_username must be 3-32 chars [a-zA-Z0-9_.-]", ErrInvalidInput)
			}
			newLoginUserPtr = &u
		}
	}
	if req.LoginPassword != nil && *req.LoginPassword != "" {
		if newLoginUserPtr == nil {
			return nil, fmt.Errorf("%w: login_username must be set before setting login_password", ErrInvalidInput)
		}
		if err := validatePassword(*req.LoginPassword); err != nil {
			return nil, err
		}
		newLoginSalt, newLoginHash, err = security.HashSecret(*req.LoginPassword)
		if err != nil {
			return nil, err
		}
		revokeMemberOnlySessions = true
	}
	if newLoginUserPtr != nil && newLoginHash == "" {
		return nil, fmt.Errorf("%w: login_password is required when enabling independent login", ErrInvalidInput)
	}

	var wrap *keyring.KeyWrap
	if req.MemberWrap != nil {
		if req.MemberWrap.WrapType != keyring.WrapMemberPassword {
			return nil, fmt.Errorf("%w: member_wrap must have wrap_type member_password", ErrInvalidInput)
		}
		w, err := toKeyringWrap(p.HouseholdID, targetID, *req.MemberWrap)
		if err != nil {
			return nil, err
		}
		wrap = &w
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if newLoginUserPtr != nil {
		var accDup int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM accounts WHERE username = ?`, *newLoginUserPtr).Scan(&accDup); err != nil {
			return nil, err
		}
		if accDup > 0 {
			return nil, fmt.Errorf("%w: login_username already taken", ErrConflict)
		}
	}

	if req.AllowedSourceIDs != nil {
		if err := validateAllowedSourcesTx(tx, p.HouseholdID, *req.AllowedSourceIDs); err != nil {
			return nil, err
		}
	}

	if _, err := tx.Exec(`
		UPDATE members
		SET nickname = ?, avatar = ?, role = ?, permissions = ?, restrict_sources = ?,
		    pin_salt = ?, pin_hash = ?, login_username = ?, login_pass_salt = ?, login_pass_hash = ?,
		    max_content_rating = ?, status = ?, updated_at = ?
		WHERE id = ? AND household_id = ?`,
		newNickname, newAvatar, newRole, newPerms, newRestrict,
		newPinSalt, newPinHash, newLoginUserPtr, newLoginSalt, newLoginHash,
		newRating, newStatus, nowMs, targetID, p.HouseholdID,
	); err != nil {
		if isUniqueErr(err) {
			return nil, fmt.Errorf("%w: login_username already exists", ErrConflict)
		}
		return nil, err
	}

	if req.AllowedSourceIDs != nil {
		if _, err := tx.Exec(`DELETE FROM member_source_access WHERE household_id = ? AND member_id = ?`, p.HouseholdID, targetID); err != nil {
			return nil, err
		}
		for _, srcID := range dedupStrings(*req.AllowedSourceIDs) {
			if _, err := tx.Exec(`
				INSERT INTO member_source_access(household_id, member_id, source_id) VALUES (?, ?, ?)`,
				p.HouseholdID, targetID, srcID,
			); err != nil {
				return nil, err
			}
		}
	}

	if wrap != nil {
		if err := keyring.UpsertWrapTx(tx, nowMs, *wrap); err != nil {
			return nil, err
		}
	}

	if newStatus != "active" {
		if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ? AND member_id = ?`, p.HouseholdID, targetID); err != nil {
			return nil, err
		}
	} else if revokeMemberOnlySessions {
		if _, err := tx.Exec(`
			DELETE FROM sessions WHERE household_id = ? AND member_id = ? AND login_mode = ?`,
			p.HouseholdID, targetID, LoginModeMemberOnly,
		); err != nil {
			return nil, err
		}
	}

	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "member.updated",
		TargetType:  "member",
		TargetID:    targetID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.loadMemberView(p.HouseholdID, targetID, canManage || targetID == p.MemberID)
}

func (s *Service) DeleteMember(p *Principal, memberID, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	if !p.HasPerm(PermManageMembers) {
		return ErrForbidden
	}
	targetID := strings.TrimSpace(memberID)
	if targetID == "" {
		return ErrNotFound
	}
	if targetID == p.MemberID {
		return fmt.Errorf("%w: cannot delete current session member", ErrForbidden)
	}

	var role string
	err := s.store.ReadDB().QueryRow(`
		SELECT role FROM members WHERE id = ? AND household_id = ?`,
		targetID, p.HouseholdID,
	).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if role == RoleOwner {
		return fmt.Errorf("%w: cannot delete household owner", ErrForbidden)
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ? AND member_id = ?`, p.HouseholdID, targetID); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		DELETE FROM household_key_wraps WHERE household_id = ? AND wrap_type = ? AND subject_id = ?`,
		p.HouseholdID, keyring.WrapMemberPassword, targetID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM members WHERE id = ? AND household_id = ?`, targetID, p.HouseholdID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "member.deleted",
		TargetType:  "member",
		TargetID:    targetID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) ListDevices(p *Principal) ([]DeviceView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	query := `
		SELECT id, household_id, device_class, platform, name, app_version, last_seen_at, created_at
		FROM devices
		WHERE household_id = ?`
	args := []any{p.HouseholdID}
	if p.LoginMode == LoginModeMemberOnly && !p.HasPerm(PermManageMembers) {
		query += ` AND id IN (SELECT device_id FROM sessions WHERE household_id = ? AND member_id = ?)`
		args = append(args, p.HouseholdID, p.MemberID)
	}
	query += ` ORDER BY COALESCE(last_seen_at, created_at) DESC`

	rows, err := s.store.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]DeviceView, 0)
	for rows.Next() {
		var (
			d    DeviceView
			last sql.NullInt64
		)
		if err := rows.Scan(&d.ID, &d.HouseholdID, &d.DeviceClass, &d.Platform, &d.Name, &d.AppVersion, &last, &d.CreatedAt); err != nil {
			return nil, err
		}
		if last.Valid {
			v := last.Int64
			d.LastSeenAt = &v
		}
		d.IsCurrentDevice = d.ID == p.DeviceID
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Service) RevokeDevice(p *Principal, deviceID, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	targetID := strings.TrimSpace(deviceID)
	if targetID == "" {
		return ErrNotFound
	}
	var exists int
	if err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM devices WHERE id = ? AND household_id = ?`, targetID, p.HouseholdID).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return ErrNotFound
	}
	if !p.HasPerm(PermManageMembers) && targetID != p.DeviceID {
		return ErrForbidden
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ? AND device_id = ?`, p.HouseholdID, targetID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM devices WHERE id = ? AND household_id = ?`, targetID, p.HouseholdID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "device.revoked",
		TargetType:  "device",
		TargetID:    targetID,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) ListSessions(p *Principal) ([]SessionView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	query := `
		SELECT s.token_id, s.household_id, s.member_id, m.nickname, s.device_id, d.name, d.device_class,
		       s.login_mode, s.ip, s.created_at, s.last_used_at, s.expires_at
		FROM sessions s
		LEFT JOIN members m ON m.id = s.member_id AND m.household_id = s.household_id
		LEFT JOIN devices d ON d.id = s.device_id AND d.household_id = s.household_id
		WHERE s.household_id = ?`
	args := []any{p.HouseholdID}
	if !p.HasPerm(PermManageMembers) {
		query += ` AND s.member_id = ?`
		args = append(args, p.MemberID)
	}
	query += ` ORDER BY s.last_used_at DESC`

	rows, err := s.store.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SessionView, 0)
	for rows.Next() {
		var (
			sv                     SessionView
			memNick, devName, devC sql.NullString
		)
		if err := rows.Scan(
			&sv.TokenID, &sv.HouseholdID, &sv.MemberID, &memNick, &sv.DeviceID, &devName, &devC,
			&sv.LoginMode, &sv.IP, &sv.CreatedAt, &sv.LastUsedAt, &sv.ExpiresAt,
		); err != nil {
			return nil, err
		}
		sv.MemberNickname = memNick.String
		sv.DeviceName = devName.String
		sv.DeviceClass = devC.String
		sv.IsCurrentSession = sv.TokenID == p.TokenID
		out = append(out, sv)
	}
	return out, rows.Err()
}

func (s *Service) RevokeSession(p *Principal, tokenID, ip string) error {
	if p == nil {
		return ErrUnauthorized
	}
	targetTok := strings.TrimSpace(tokenID)
	if targetTok == "" {
		return ErrNotFound
	}
	var targetMemberID string
	err := s.store.ReadDB().QueryRow(`
		SELECT member_id FROM sessions WHERE token_id = ? AND household_id = ?`,
		targetTok, p.HouseholdID,
	).Scan(&targetMemberID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if targetMemberID != p.MemberID && !p.HasPerm(PermManageMembers) {
		return ErrForbidden
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM sessions WHERE token_id = ? AND household_id = ?`, targetTok, p.HouseholdID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   loginModeActorType(p.LoginMode),
		ActorID:     p.MemberID,
		HouseholdID: p.HouseholdID,
		Action:      "session.revoked",
		TargetType:  "session",
		TargetID:    targetTok,
		IP:          strings.TrimSpace(ip),
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) loadHouseholdInfo(hhID string) (*HouseholdInfo, error) {
	var h HouseholdInfo
	err := s.store.ReadDB().QueryRow(`
		SELECT id, owner_account_id, name, display_lang,
		       quota_max_sources, quota_max_files, quota_max_sidecar_bytes,
		       next_change_seq, min_retained_seq, created_at, updated_at
		FROM households WHERE id = ?`, hhID,
	).Scan(
		&h.ID, &h.OwnerAccountID, &h.Name, &h.DisplayLang,
		&h.QuotaMaxSources, &h.QuotaMaxFiles, &h.QuotaMaxSidecarBytes,
		&h.NextChangeSeq, &h.MinRetainedSeq, &h.CreatedAt, &h.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	_ = s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM members WHERE household_id = ?`, hhID).Scan(&h.MemberCount)
	_ = s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM devices WHERE household_id = ?`, hhID).Scan(&h.DeviceCount)
	return &h, nil
}

func (s *Service) loadMemberView(hhID, memID string, includeSensitiveMeta bool) (*MemberView, error) {
	var (
		m            MemberView
		restrictInt  int
		pinHash      string
		loginUser    sql.NullString
		loginHash    string
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT id, household_id, nickname, avatar, role, permissions, restrict_sources,
		       COALESCE(pin_hash, ''), login_username, COALESCE(login_pass_hash, ''),
		       COALESCE(max_content_rating, ''), status, created_at, updated_at
		FROM members WHERE id = ? AND household_id = ?`,
		memID, hhID,
	).Scan(
		&m.ID, &m.HouseholdID, &m.Nickname, &m.Avatar, &m.Role, &m.Permissions, &restrictInt,
		&pinHash, &loginUser, &loginHash, &m.MaxContentRating, &m.Status, &m.CreatedAt, &m.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	m.RestrictSources = restrictInt == 1
	m.HasPIN = pinHash != ""
	m.HasIndependentLogin = loginUser.Valid && loginUser.String != "" && loginHash != ""
	if includeSensitiveMeta && loginUser.Valid {
		m.LoginUsername = loginUser.String
	}

	if m.RestrictSources {
		srcIDs, err := s.loadMemberAllowedSources(hhID, memID)
		if err != nil {
			return nil, err
		}
		m.AllowedSourceIDs = srcIDs
	}
	return &m, nil
}

func (s *Service) loadHouseholdMembers(hhID string, includeLoginUsername bool) ([]MemberView, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT id, household_id, nickname, avatar, role, permissions, restrict_sources,
		       COALESCE(pin_hash, ''), login_username, COALESCE(login_pass_hash, ''),
		       COALESCE(max_content_rating, ''), status, created_at, updated_at
		FROM members
		WHERE household_id = ?
		ORDER BY created_at ASC`, hhID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]MemberView, 0)
	for rows.Next() {
		var (
			m           MemberView
			restrictInt int
			pinHash     string
			loginUser   sql.NullString
			loginHash   string
		)
		if err := rows.Scan(
			&m.ID, &m.HouseholdID, &m.Nickname, &m.Avatar, &m.Role, &m.Permissions, &restrictInt,
			&pinHash, &loginUser, &loginHash, &m.MaxContentRating, &m.Status, &m.CreatedAt, &m.UpdatedAt,
		); err != nil {
			return nil, err
		}
		m.RestrictSources = restrictInt == 1
		m.HasPIN = pinHash != ""
		m.HasIndependentLogin = loginUser.Valid && loginUser.String != "" && loginHash != ""
		if includeLoginUsername && loginUser.Valid {
			m.LoginUsername = loginUser.String
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for i := range out {
		if out[i].RestrictSources {
			ids, err := s.loadMemberAllowedSources(hhID, out[i].ID)
			if err != nil {
				return nil, err
			}
			out[i].AllowedSourceIDs = ids
		}
	}
	return out, nil
}

func (s *Service) loadMemberAllowedSources(hhID, memID string) ([]string, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT source_id FROM member_source_access WHERE household_id = ? AND member_id = ? ORDER BY source_id ASC`,
		hhID, memID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func validateAllowedSourcesTx(tx *sql.Tx, hhID string, sourceIDs []string) error {
	unique := dedupStrings(sourceIDs)
	if len(unique) == 0 {
		return nil
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(unique)), ",")
	args := make([]any, 0, len(unique)+1)
	args = append(args, hhID)
	for _, id := range unique {
		args = append(args, id)
	}
	var cnt int
	if err := tx.QueryRow(
		fmt.Sprintf(`SELECT COUNT(*) FROM sources WHERE household_id = ? AND id IN (%s)`, placeholders),
		args...,
	).Scan(&cnt); err != nil {
		return err
	}
	if cnt != len(unique) {
		return ErrNotFound
	}
	return nil
}

func dedupStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, raw := range in {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}
