package db

import (
	"database/sql"
	"fmt"
	"strings"
)

// AppendChangeTx allocates the next household-monotonic change_log sequence number
// inside tx and inserts an incremental sync record for downstream clients.
func AppendChangeTx(tx *sql.Tx, householdID string, memberID *string, entity, entityID, op string, nowMs int64) (int64, error) {
	hhID := strings.TrimSpace(householdID)
	ent := strings.TrimSpace(entity)
	eid := strings.TrimSpace(entityID)
	act := strings.TrimSpace(op)
	if tx == nil || hhID == "" || ent == "" || eid == "" || act == "" {
		return 0, fmt.Errorf("%w: invalid change_log arguments", ErrInvalidInput)
	}

	res, err := tx.Exec(`UPDATE households SET next_change_seq = next_change_seq + 1 WHERE id = ?`, hhID)
	if err != nil {
		return 0, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return 0, ErrNotFound
	}

	var seq int64
	if err := tx.QueryRow(`SELECT next_change_seq FROM households WHERE id = ?`, hhID).Scan(&seq); err != nil {
		return 0, err
	}

	var memVal any
	if memberID != nil {
		if trimmed := strings.TrimSpace(*memberID); trimmed != "" {
			memVal = trimmed
		}
	}

	if _, err := tx.Exec(`
		INSERT INTO change_log(household_id, seq, member_id, entity, entity_id, op, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		hhID, seq, memVal, ent, eid, act, nowMs,
	); err != nil {
		return 0, err
	}
	return seq, nil
}
