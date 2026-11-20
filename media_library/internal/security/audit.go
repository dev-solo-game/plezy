package security

import (
	"database/sql"
	"encoding/json"
	"strings"

	"plezy/media_library/internal/db"
)

type AuditEntry struct {
	ActorType   string // admin | member | system
	ActorID     string
	HouseholdID string
	Action      string
	TargetType  string
	TargetID    string
	IP          string
	Detail      map[string]any
}

func WriteAudit(store *db.Store, entry AuditEntry) error {
	raw := marshalDetail(entry.Detail)
	var hhPtr any
	if hh := strings.TrimSpace(entry.HouseholdID); hh != "" {
		hhPtr = hh
	}
	_, err := store.DB().Exec(`
		INSERT INTO audit_logs(actor_type, actor_id, household_id, action, target_type, target_id, detail_json, ip, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		strings.TrimSpace(entry.ActorType),
		strings.TrimSpace(entry.ActorID),
		hhPtr,
		strings.TrimSpace(entry.Action),
		strings.TrimSpace(entry.TargetType),
		strings.TrimSpace(entry.TargetID),
		raw,
		strings.TrimSpace(entry.IP),
		store.NowMs(),
	)
	return err
}

func WriteAuditTx(tx *sql.Tx, nowMs int64, entry AuditEntry) error {
	raw := marshalDetail(entry.Detail)
	var hhPtr any
	if hh := strings.TrimSpace(entry.HouseholdID); hh != "" {
		hhPtr = hh
	}
	_, err := tx.Exec(`
		INSERT INTO audit_logs(actor_type, actor_id, household_id, action, target_type, target_id, detail_json, ip, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		strings.TrimSpace(entry.ActorType),
		strings.TrimSpace(entry.ActorID),
		hhPtr,
		strings.TrimSpace(entry.Action),
		strings.TrimSpace(entry.TargetType),
		strings.TrimSpace(entry.TargetID),
		raw,
		strings.TrimSpace(entry.IP),
		nowMs,
	)
	return err
}

func marshalDetail(detail map[string]any) string {
	if len(detail) == 0 {
		return "{}"
	}
	b, err := json.Marshal(detail)
	if err != nil {
		return "{}"
	}
	return string(b)
}
