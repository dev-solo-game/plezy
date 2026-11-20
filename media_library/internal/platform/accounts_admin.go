package platform

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/security"
)

const AccountDeletionGracePeriod = 7 * 24 * time.Hour

var reUsername = regexp.MustCompile(`^[a-zA-Z0-9_.-]{3,32}$`)

// AccountSummary contains strictly non-private account info and aggregate counts (D8).
type AccountSummary struct {
	AccountID            string         `json:"account_id"`
	Username             string         `json:"username"`
	Email                *string        `json:"email,omitempty"`
	Status               string         `json:"status"`
	MustChangePassword   bool           `json:"must_change_password"`
	DeleteAfter          *int64         `json:"delete_after,omitempty"`
	RegisteredIP         string         `json:"registered_ip,omitempty"`
	LastActiveAt         *int64         `json:"last_active_at,omitempty"`
	CreatedAt            int64          `json:"created_at"`
	UpdatedAt            int64          `json:"updated_at"`
	HouseholdID          string         `json:"household_id"`
	HouseholdName        string         `json:"household_name"`
	QuotaMaxSources      int            `json:"quota_max_sources"`
	QuotaMaxFiles        int            `json:"quota_max_files"`
	QuotaMaxSidecarBytes int64          `json:"quota_max_sidecar_bytes"`
	MemberCount          int            `json:"member_count"`
	DeviceCount          int            `json:"device_count"`
	SourceCounts         map[string]int `json:"source_counts"`
	ItemCount            int            `json:"item_count"`
	FileCount            int            `json:"file_count"`
	SidecarBytes         int64          `json:"sidecar_bytes"`
}

type AuditLogRecord struct {
	ID          int64   `json:"id"`
	ActorType   string  `json:"actor_type"`
	ActorID     string  `json:"actor_id"`
	HouseholdID *string `json:"household_id,omitempty"`
	Action      string  `json:"action"`
	TargetType  string  `json:"target_type,omitempty"`
	TargetID    string  `json:"target_id,omitempty"`
	DetailJSON  string  `json:"detail_json"`
	IP          string  `json:"ip,omitempty"`
	CreatedAt   int64   `json:"created_at"`
}

func (s *Service) ListAccounts(q, status string, limit, offset int) ([]AccountSummary, int64, error) {
	if limit <= 0 {
		limit = 30
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	var clauses []string
	var args []any
	if trimmedQ := strings.TrimSpace(q); trimmedQ != "" {
		r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
		pat := "%" + r.Replace(trimmedQ) + "%"
		clauses = append(clauses, `(a.username LIKE ? ESCAPE '\' OR COALESCE(a.email, '') LIKE ? ESCAPE '\' OR a.id LIKE ? ESCAPE '\')`)
		args = append(args, pat, pat, pat)
	}
	if st := strings.TrimSpace(status); st != "" && st != "all" {
		clauses = append(clauses, `a.status = ?`)
		args = append(args, st)
	}
	whereSQL := ""
	if len(clauses) > 0 {
		whereSQL = "WHERE " + strings.Join(clauses, " AND ")
	}

	var total int64
	if err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM accounts a `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	queryArgs := append(append([]any{}, args...), limit, offset)
	rows, err := s.store.ReadDB().Query(`
		SELECT a.id, a.username, a.email, a.status, a.must_change_password, a.delete_after,
		       a.registered_ip, a.last_active_at, a.created_at, a.updated_at,
		       COALESCE(h.id, ''), COALESCE(h.name, ''),
		       COALESCE(h.quota_max_sources, 0), COALESCE(h.quota_max_files, 0), COALESCE(h.quota_max_sidecar_bytes, 0)
		FROM accounts a
		LEFT JOIN households h ON h.owner_account_id = a.id
		`+whereSQL+`
		ORDER BY a.created_at DESC LIMIT ? OFFSET ?`, queryArgs...,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := make([]AccountSummary, 0)
	hhIDs := make([]string, 0)
	hhIndex := make(map[string]int)

	for rows.Next() {
		var (
			rec     AccountSummary
			email   sql.NullString
			mustChg int
			delAt   sql.NullInt64
			lastAct sql.NullInt64
		)
		if scanErr := rows.Scan(
			&rec.AccountID, &rec.Username, &email, &rec.Status, &mustChg, &delAt,
			&rec.RegisteredIP, &lastAct, &rec.CreatedAt, &rec.UpdatedAt,
			&rec.HouseholdID, &rec.HouseholdName,
			&rec.QuotaMaxSources, &rec.QuotaMaxFiles, &rec.QuotaMaxSidecarBytes,
		); scanErr != nil {
			return nil, 0, scanErr
		}
		if email.Valid {
			v := email.String
			rec.Email = &v
		}
		rec.MustChangePassword = mustChg == 1
		if delAt.Valid {
			v := delAt.Int64
			rec.DeleteAfter = &v
		}
		if lastAct.Valid {
			v := lastAct.Int64
			rec.LastActiveAt = &v
		}
		rec.SourceCounts = make(map[string]int)
		if rec.HouseholdID != "" {
			hhIndex[rec.HouseholdID] = len(out)
			hhIDs = append(hhIDs, rec.HouseholdID)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	if len(hhIDs) > 0 {
		if err := s.populateAggregateCounts(out, hhIndex, hhIDs); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (s *Service) populateAggregateCounts(out []AccountSummary, hhIndex map[string]int, hhIDs []string) error {
	ph := strings.Repeat("?,", len(hhIDs))
	ph = ph[:len(ph)-1]
	inArgs := make([]any, len(hhIDs))
	for i, id := range hhIDs {
		inArgs[i] = id
	}

	fillCount := func(sqlFmt string, setter func(idx int, val int)) error {
		r, err := s.store.ReadDB().Query(fmt.Sprintf(sqlFmt, ph), inArgs...)
		if err != nil {
			return err
		}
		defer r.Close()
		for r.Next() {
			var hh string
			var cnt int
			if r.Scan(&hh, &cnt) == nil {
				if idx, ok := hhIndex[hh]; ok {
					setter(idx, cnt)
				}
			}
		}
		return r.Err()
	}

	if err := fillCount(`SELECT household_id, COUNT(*) FROM members WHERE status = 'active' AND household_id IN (%s) GROUP BY household_id`, func(i, c int) {
		out[i].MemberCount = c
	}); err != nil {
		return err
	}
	if err := fillCount(`SELECT household_id, COUNT(*) FROM devices WHERE household_id IN (%s) GROUP BY household_id`, func(i, c int) {
		out[i].DeviceCount = c
	}); err != nil {
		return err
	}
	if err := fillCount(`SELECT household_id, COUNT(*) FROM media_items WHERE kind IN ('movie','show') AND household_id IN (%s) GROUP BY household_id`, func(i, c int) {
		out[i].ItemCount = c
	}); err != nil {
		return err
	}
	if err := fillCount(`SELECT household_id, COUNT(*) FROM media_files WHERE state != 'tombstoned' AND household_id IN (%s) GROUP BY household_id`, func(i, c int) {
		out[i].FileCount = c
	}); err != nil {
		return err
	}

	// Source counts grouped by kind
	srcRows, err := s.store.ReadDB().Query(
		fmt.Sprintf(`SELECT household_id, kind, COUNT(*) FROM sources WHERE status = 'active' AND household_id IN (%s) GROUP BY household_id, kind`, ph),
		inArgs...,
	)
	if err != nil {
		return err
	}
	for srcRows.Next() {
		var hh, kind string
		var cnt int
		if srcRows.Scan(&hh, &kind, &cnt) == nil {
			if idx, ok := hhIndex[hh]; ok {
				out[idx].SourceCounts[kind] = cnt
			}
		}
	}
	_ = srcRows.Close()

	// Sidecar storage bytes
	scRows, err := s.store.ReadDB().Query(
		fmt.Sprintf(`SELECT household_id, COALESCE(SUM(size_bytes), 0) FROM sidecars WHERE household_id IN (%s) GROUP BY household_id`, ph),
		inArgs...,
	)
	if err != nil {
		return err
	}
	for scRows.Next() {
		var hh string
		var total int64
		if scRows.Scan(&hh, &total) == nil {
			if idx, ok := hhIndex[hh]; ok {
				out[idx].SidecarBytes = total
			}
		}
	}
	_ = scRows.Close()
	return nil
}

func (s *Service) CreateAccountByAdmin(adminID, username, email, tempPassword, householdName, ip string) (*AccountSummary, error) {
	user := strings.TrimSpace(username)
	if !reUsername.MatchString(user) {
		return nil, fmt.Errorf("%w: username must be 3-32 chars [a-zA-Z0-9_.-]", ErrInvalidInput)
	}
	if len(tempPassword) < minPasswordLength {
		return nil, fmt.Errorf("%w: temporary password must be at least %d characters", ErrInvalidInput, minPasswordLength)
	}
	var emailPtr *string
	if e := strings.TrimSpace(email); e != "" {
		emailPtr = &e
	}
	hhName := strings.TrimSpace(householdName)
	if hhName == "" {
		hhName = user + "的家庭"
	}

	salt, hash, err := security.HashSecret(tempPassword)
	if err != nil {
		return nil, err
	}
	nowMs := s.nowFn().UnixMilli()
	accID := uuid.NewString()
	hhID := uuid.NewString()
	memID := uuid.NewString()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO accounts(id, username, email, password_salt, password_hash, must_change_password, status, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 1, 'active', ?, ?)`,
		accID, user, emailPtr, salt, hash, nowMs, nowMs,
	); err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return nil, fmt.Errorf("%w: username or email already exists", ErrConflict)
		}
		return nil, err
	}
	if _, err := tx.Exec(`
		INSERT INTO households(id, owner_account_id, name, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?)`,
		hhID, accID, hhName, nowMs, nowMs,
	); err != nil {
		return nil, err
	}
	// Owner has all 6 permission bits set (63).
	if _, err := tx.Exec(`
		INSERT INTO members(id, household_id, nickname, role, permissions, status, created_at, updated_at)
		VALUES (?, ?, ?, 'owner', 63, 'active', ?, ?)`,
		memID, hhID, user, nowMs, nowMs,
	); err != nil {
		return nil, err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_create",
		TargetType:  "account",
		TargetID:    accID,
		IP:          ip,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return &AccountSummary{
		AccountID:            accID,
		Username:             user,
		Email:                emailPtr,
		Status:               "active",
		MustChangePassword:   true,
		CreatedAt:            nowMs,
		UpdatedAt:            nowMs,
		HouseholdID:          hhID,
		HouseholdName:        hhName,
		QuotaMaxSources:      20,
		QuotaMaxFiles:        200000,
		QuotaMaxSidecarBytes: 524288000,
		MemberCount:          1,
		SourceCounts:         map[string]int{},
	}, nil
}

func (s *Service) lookupAccountHousehold(accountID string) (string, string, error) {
	var status, hhID string
	err := s.store.ReadDB().QueryRow(`
		SELECT a.status, COALESCE(h.id, '')
		FROM accounts a
		LEFT JOIN households h ON h.owner_account_id = a.id
		WHERE a.id = ?`, strings.TrimSpace(accountID),
	).Scan(&status, &hhID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrNotFound
	}
	return status, hhID, err
}

func (s *Service) SetAccountStatus(adminID, accountID, status, ip string) error {
	st := strings.TrimSpace(status)
	if st != "active" && st != "disabled" {
		return fmt.Errorf("%w: status must be 'active' or 'disabled'", ErrInvalidInput)
	}
	_, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	nowMs := s.nowFn().UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`UPDATE accounts SET status = ?, delete_after = NULL, updated_at = ? WHERE id = ?`, st, nowMs, accountID); err != nil {
		return err
	}
	if st == "disabled" && hhID != "" {
		if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, hhID); err != nil {
			return err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_status",
		TargetType:  "account",
		TargetID:    accountID,
		IP:          ip,
		Detail:      map[string]any{"status": st},
	}); err != nil {
		return err
	}
	return tx.Commit()
}

// ResetAccountPassword resets an account's password to a temporary one, clears
// unrecoverable E2EE wraps, expires source credentials, and revokes sessions (G7 + §4.4.4).
func (s *Service) ResetAccountPassword(adminID, accountID, newTempPassword, ip string) error {
	if len(newTempPassword) < minPasswordLength {
		return fmt.Errorf("%w: temporary password must be at least %d characters", ErrInvalidInput, minPasswordLength)
	}
	_, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	salt, hash, err := security.HashSecret(newTempPassword)
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
		SET password_salt = ?, password_hash = ?, must_change_password = 1,
		    recovery_salt = '', recovery_hash = '', updated_at = ?
		WHERE id = ?`,
		salt, hash, nowMs, accountID,
	); err != nil {
		return err
	}
	if hhID != "" {
		if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if err := keyring.DeleteHouseholdWrapsTx(tx, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`
			UPDATE source_credentials
			SET status = 'expired', ciphertext = '', updated_at = ?
			WHERE household_id = ?`, nowMs, hhID,
		); err != nil {
			return err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_password_reset",
		TargetType:  "account",
		TargetID:    accountID,
		IP:          ip,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) ForceLogoutAccount(adminID, accountID, ip string) error {
	_, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if hhID != "" {
		if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, hhID); err != nil {
			return err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_force_logout",
		TargetType:  "account",
		TargetID:    accountID,
		IP:          ip,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

// ScheduleDeleteAccount places an account into the 7-day deletion grace period (G11).
func (s *Service) ScheduleDeleteAccount(adminID, accountID, ip string) error {
	_, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	now := s.nowFn()
	nowMs := now.UnixMilli()
	deleteAfter := now.Add(AccountDeletionGracePeriod).UnixMilli()

	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE accounts SET status = 'pending_delete', delete_after = ?, updated_at = ? WHERE id = ?`,
		deleteAfter, nowMs, accountID,
	); err != nil {
		return err
	}
	if hhID != "" {
		if _, err := tx.Exec(`DELETE FROM sessions WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM account_login_tickets WHERE household_id = ?`, hhID); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM source_credentials WHERE household_id = ?`, hhID); err != nil {
			return err
		}
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_schedule_delete",
		TargetType:  "account",
		TargetID:    accountID,
		IP:          ip,
		Detail:      map[string]any{"delete_after": deleteAfter},
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) RestoreAccount(adminID, accountID, ip string) error {
	status, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	if status != "pending_delete" {
		return fmt.Errorf("%w: account is not pending deletion", ErrConflict)
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`UPDATE accounts SET status = 'active', delete_after = NULL, updated_at = ? WHERE id = ?`, nowMs, accountID); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_restore",
		TargetType:  "account",
		TargetID:    accountID,
		IP:          ip,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) PurgeExpiredDeletedAccounts() (int64, error) {
	nowMs := s.nowFn().UnixMilli()
	rows, err := s.store.ReadDB().Query(`
		SELECT a.id, COALESCE(h.id, '')
		FROM accounts a
		LEFT JOIN households h ON h.owner_account_id = a.id
		WHERE a.status = 'pending_delete' AND a.delete_after IS NOT NULL AND a.delete_after <= ?`,
		nowMs,
	)
	if err != nil {
		return 0, err
	}
	type target struct {
		accID string
		hhID  string
	}
	var targets []target
	for rows.Next() {
		var t target
		if rows.Scan(&t.accID, &t.hhID) == nil {
			targets = append(targets, t)
		}
	}
	_ = rows.Close()

	var purged int64
	for _, t := range targets {
		tx, err := s.store.DB().Begin()
		if err != nil {
			return purged, err
		}
		res, err := tx.Exec(`DELETE FROM accounts WHERE id = ?`, t.accID)
		if err != nil {
			_ = tx.Rollback()
			return purged, err
		}
		n, _ := res.RowsAffected()
		if n > 0 {
			if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
				ActorType:  "system",
				ActorID:    "cleanup",
				Action:     "system.account_purged",
				TargetType: "account",
				TargetID:   t.accID,
				Detail:     map[string]any{"household_id": t.hhID},
			}); err != nil {
				_ = tx.Rollback()
				return purged, err
			}
		}
		if err := tx.Commit(); err != nil {
			return purged, err
		}
		if n > 0 {
			purged += n
			if t.hhID != "" {
				_ = os.RemoveAll(filepath.Join(s.store.DataDir(), "sidecars", t.hhID))
			}
		}
	}
	return purged, nil
}

func (s *Service) UpdateHouseholdQuotas(adminID, accountID string, maxSources, maxFiles *int, maxSidecarBytes *int64, ip string) error {
	_, hhID, err := s.lookupAccountHousehold(accountID)
	if err != nil {
		return err
	}
	if hhID == "" {
		return ErrNotFound
	}
	if maxSources != nil && *maxSources <= 0 {
		return fmt.Errorf("%w: quota_max_sources must be > 0", ErrInvalidInput)
	}
	if maxFiles != nil && *maxFiles <= 0 {
		return fmt.Errorf("%w: quota_max_files must be > 0", ErrInvalidInput)
	}
	if maxSidecarBytes != nil && *maxSidecarBytes <= 0 {
		return fmt.Errorf("%w: quota_max_sidecar_bytes must be > 0", ErrInvalidInput)
	}

	var curSources, curFiles int
	var curBytes int64
	if err := s.store.ReadDB().QueryRow(`
		SELECT quota_max_sources, quota_max_files, quota_max_sidecar_bytes FROM households WHERE id = ?`, hhID,
	).Scan(&curSources, &curFiles, &curBytes); err != nil {
		return err
	}
	if maxSources != nil {
		curSources = *maxSources
	}
	if maxFiles != nil {
		curFiles = *maxFiles
	}
	if maxSidecarBytes != nil {
		curBytes = *maxSidecarBytes
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE households
		SET quota_max_sources = ?, quota_max_files = ?, quota_max_sidecar_bytes = ?, updated_at = ?
		WHERE id = ?`,
		curSources, curFiles, curBytes, nowMs, hhID,
	); err != nil {
		return err
	}
	if err := security.WriteAuditTx(tx, nowMs, security.AuditEntry{
		ActorType:   "admin",
		ActorID:     adminID,
		HouseholdID: hhID,
		Action:      "admin.account_quotas",
		TargetType:  "household",
		TargetID:    hhID,
		IP:          ip,
		Detail: map[string]any{
			"quota_max_sources":       curSources,
			"quota_max_files":         curFiles,
			"quota_max_sidecar_bytes": curBytes,
		},
	}); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) ListAuditLogs(actorType, householdID, action string, limit, offset int) ([]AuditLogRecord, int64, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	if offset < 0 {
		offset = 0
	}

	var clauses []string
	var args []any
	if at := strings.TrimSpace(actorType); at != "" && at != "all" {
		clauses = append(clauses, `actor_type = ?`)
		args = append(args, at)
	}
	if hh := strings.TrimSpace(householdID); hh != "" {
		clauses = append(clauses, `household_id = ?`)
		args = append(args, hh)
	}
	if act := strings.TrimSpace(action); act != "" {
		clauses = append(clauses, `action = ?`)
		args = append(args, act)
	}
	whereSQL := ""
	if len(clauses) > 0 {
		whereSQL = "WHERE " + strings.Join(clauses, " AND ")
	}

	var total int64
	if err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM audit_logs `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	queryArgs := append(append([]any{}, args...), limit, offset)
	rows, err := s.store.ReadDB().Query(`
		SELECT id, actor_type, actor_id, household_id, action, target_type, target_id, detail_json, ip, created_at
		FROM audit_logs `+whereSQL+`
		ORDER BY id DESC LIMIT ? OFFSET ?`, queryArgs...,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := make([]AuditLogRecord, 0)
	for rows.Next() {
		var rec AuditLogRecord
		var hh sql.NullString
		if scanErr := rows.Scan(
			&rec.ID, &rec.ActorType, &rec.ActorID, &hh,
			&rec.Action, &rec.TargetType, &rec.TargetID, &rec.DetailJSON, &rec.IP, &rec.CreatedAt,
		); scanErr != nil {
			return nil, 0, scanErr
		}
		if hh.Valid {
			v := hh.String
			rec.HouseholdID = &v
		}
		out = append(out, rec)
	}
	return out, total, rows.Err()
}
