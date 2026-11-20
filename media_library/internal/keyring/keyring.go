package keyring

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"plezy/media_library/internal/db"
)

const (
	WrapAccountPassword = "account_password"
	WrapRecoveryCode    = "recovery_code"
	WrapMemberPassword  = "member_password"

	KdfAlgPBKDF2  = "pbkdf2-sha256"
	KdfAlgArgon2id = "argon2id"
)

var ErrInvalidWrap = errors.New("invalid key wrap")

type KeyWrap struct {
	ID            string `json:"id"`
	HouseholdID   string `json:"household_id"`
	WrapType      string `json:"wrap_type"`
	SubjectID     string `json:"subject_id"`
	KdfAlg        string `json:"kdf_alg"`
	KdfSalt       string `json:"kdf_salt"`
	KdfParamsJSON string `json:"kdf_params_json"`
	WrappedHK     string `json:"wrapped_hk"`
	KeyEpoch      int    `json:"key_epoch"`
	CreatedAt     int64  `json:"created_at"`
	UpdatedAt     int64  `json:"updated_at"`
}

func ValidateWrap(w KeyWrap) error {
	switch strings.TrimSpace(w.WrapType) {
	case WrapAccountPassword, WrapRecoveryCode, WrapMemberPassword:
	default:
		return fmt.Errorf("%w: unsupported wrap_type %q", ErrInvalidWrap, w.WrapType)
	}
	switch strings.TrimSpace(w.KdfAlg) {
	case KdfAlgPBKDF2, KdfAlgArgon2id:
	default:
		return fmt.Errorf("%w: unsupported kdf_alg %q", ErrInvalidWrap, w.KdfAlg)
	}
	if strings.TrimSpace(w.SubjectID) == "" {
		return fmt.Errorf("%w: subject_id is required", ErrInvalidWrap)
	}
	if strings.TrimSpace(w.KdfSalt) == "" {
		return fmt.Errorf("%w: kdf_salt is required", ErrInvalidWrap)
	}
	if strings.TrimSpace(w.WrappedHK) == "" {
		return fmt.Errorf("%w: wrapped_hk is required", ErrInvalidWrap)
	}
	params := strings.TrimSpace(w.KdfParamsJSON)
	if params == "" || !json.Valid([]byte(params)) {
		return fmt.Errorf("%w: kdf_params_json must be valid JSON", ErrInvalidWrap)
	}
	return nil
}

func UpsertWrapTx(tx *sql.Tx, nowMs int64, w KeyWrap) error {
	if strings.TrimSpace(w.HouseholdID) == "" {
		return fmt.Errorf("%w: household_id is required", ErrInvalidWrap)
	}
	if err := ValidateWrap(w); err != nil {
		return err
	}
	id := strings.TrimSpace(w.ID)
	if id == "" {
		id = uuid.NewString()
	}
	epoch := w.KeyEpoch
	if epoch <= 0 {
		epoch = 1
	}
	_, err := tx.Exec(`
		INSERT INTO household_key_wraps(
			id, household_id, wrap_type, subject_id, kdf_alg, kdf_salt, kdf_params_json, wrapped_hk, key_epoch, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(household_id, wrap_type, subject_id) DO UPDATE SET
			kdf_alg = excluded.kdf_alg,
			kdf_salt = excluded.kdf_salt,
			kdf_params_json = excluded.kdf_params_json,
			wrapped_hk = excluded.wrapped_hk,
			key_epoch = excluded.key_epoch,
			updated_at = excluded.updated_at`,
		id,
		strings.TrimSpace(w.HouseholdID),
		strings.TrimSpace(w.WrapType),
		strings.TrimSpace(w.SubjectID),
		strings.TrimSpace(w.KdfAlg),
		strings.TrimSpace(w.KdfSalt),
		strings.TrimSpace(w.KdfParamsJSON),
		strings.TrimSpace(w.WrappedHK),
		epoch,
		nowMs,
		nowMs,
	)
	return err
}

func UpsertWrap(store *db.Store, w KeyWrap) error {
	tx, err := store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := UpsertWrapTx(tx, store.NowMs(), w); err != nil {
		return err
	}
	return tx.Commit()
}

func ListWraps(store *db.Store, householdID string, wrapTypes []string, subjectID string) ([]KeyWrap, error) {
	hh := strings.TrimSpace(householdID)
	if hh == "" {
		return nil, fmt.Errorf("%w: household_id is required", ErrInvalidWrap)
	}
	query := `SELECT id, household_id, wrap_type, subject_id, kdf_alg, kdf_salt, kdf_params_json, wrapped_hk, key_epoch, created_at, updated_at
		FROM household_key_wraps WHERE household_id = ?`
	args := []any{hh}

	if len(wrapTypes) > 0 {
		placeholders := make([]string, 0, len(wrapTypes))
		for _, wt := range wrapTypes {
			placeholders = append(placeholders, "?")
			args = append(args, strings.TrimSpace(wt))
		}
		query += ` AND wrap_type IN (` + strings.Join(placeholders, ",") + `)`
	}
	if sub := strings.TrimSpace(subjectID); sub != "" {
		query += ` AND subject_id = ?`
		args = append(args, sub)
	}
	query += ` ORDER BY wrap_type ASC, created_at ASC`

	rows, err := store.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]KeyWrap, 0)
	for rows.Next() {
		var w KeyWrap
		if scanErr := rows.Scan(
			&w.ID, &w.HouseholdID, &w.WrapType, &w.SubjectID,
			&w.KdfAlg, &w.KdfSalt, &w.KdfParamsJSON, &w.WrappedHK,
			&w.KeyEpoch, &w.CreatedAt, &w.UpdatedAt,
		); scanErr != nil {
			return nil, scanErr
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

func CurrentEpoch(store *db.Store, householdID string) (int, error) {
	hh := strings.TrimSpace(householdID)
	if hh == "" {
		return 0, fmt.Errorf("%w: household_id is required", ErrInvalidWrap)
	}
	var epoch int
	err := store.ReadDB().QueryRow(
		`SELECT COALESCE(MAX(key_epoch), 0) FROM household_key_wraps WHERE household_id = ?`, hh,
	).Scan(&epoch)
	return epoch, err
}

func DeleteHouseholdWrapsTx(tx *sql.Tx, householdID string) error {
	hh := strings.TrimSpace(householdID)
	if hh == "" {
		return fmt.Errorf("%w: household_id is required", ErrInvalidWrap)
	}
	_, err := tx.Exec(`DELETE FROM household_key_wraps WHERE household_id = ?`, hh)
	return err
}
