package security

import (
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/vault"
)

func TestHashAndVerifySecretAndTokens(t *testing.T) {
	salt, hash, err := HashSecret("super-secret-pass")
	if err != nil {
		t.Fatalf("HashSecret: %v", err)
	}
	if !VerifySecret("super-secret-pass", salt, hash) {
		t.Fatal("expected VerifySecret to match correct password")
	}
	if VerifySecret("wrong-password", salt, hash) {
		t.Fatal("expected VerifySecret to reject wrong password")
	}
	if VerifySecret("super-secret-pass", "bad-salt", hash) {
		t.Fatal("expected VerifySecret to reject invalid salt")
	}

	raw, tid, thash, err := GenerateOpaqueToken("adm_")
	if err != nil {
		t.Fatalf("GenerateOpaqueToken: %v", err)
	}
	if !strings.HasPrefix(raw, "adm_") || tid == "" || thash != HashToken(raw) {
		t.Fatalf("unexpected token properties: raw=%q tid=%q thash=%q", raw, tid, thash)
	}
}

func TestParseCIDRListAndIPAllowed(t *testing.T) {
	if !IPAllowed("203.0.113.5", nil) {
		t.Fatal("empty allowlist must allow all IPs")
	}
	nets, err := ParseCIDRList("127.0.0.1, 10.0.0.0/8, ::1")
	if err != nil {
		t.Fatalf("ParseCIDRList: %v", err)
	}
	if !IPAllowed("127.0.0.1:51234", nets) || !IPAllowed("10.1.2.3", nets) || !IPAllowed("[::1]:8090", nets) {
		t.Fatal("expected allowed IPs to pass")
	}
	if IPAllowed("192.168.1.5", nets) || IPAllowed("not-an-ip", nets) {
		t.Fatal("expected disallowed IP to be rejected")
	}
	if _, err := ParseCIDRList("invalid/cidr"); err == nil {
		t.Fatal("expected error for invalid CIDR")
	}
}

func TestLoginLimiterLockoutAndWindow(t *testing.T) {
	now := time.Unix(1700000000, 0)
	lim := NewLoginLimiter()
	lim.SetClock(func() time.Time { return now })

	for i := 0; i < DefaultMaxLoginFailures; i++ {
		if locked, _ := lim.CheckLockout("u1"); locked {
			t.Fatalf("should not be locked at failure %d", i)
		}
		lim.RecordFailure("u1")
	}
	locked, retrySec := lim.CheckLockout("u1")
	if !locked || retrySec <= 0 {
		t.Fatalf("expected lockout after 5 failures, locked=%v retry=%d", locked, retrySec)
	}

	// Advance past lockout duration
	now = now.Add(DefaultLockoutDuration + time.Second)
	if locked, _ := lim.CheckLockout("u1"); locked {
		t.Fatal("expected lockout to expire")
	}

	// RecordSuccess clears failures
	lim.RecordFailure("u2")
	lim.RecordSuccess("u2")
	for i := 0; i < DefaultMaxLoginFailures-1; i++ {
		lim.RecordFailure("u2")
	}
	if locked, _ := lim.CheckLockout("u2"); locked {
		t.Fatal("expected fewer than 5 failures after reset not to lock")
	}

	// Sliding/fixed window rate limit
	for i := 0; i < 5; i++ {
		if !lim.AllowWindow("reg:1.2.3.4", 5, time.Hour) {
			t.Fatalf("unexpected deny at attempt %d", i)
		}
	}
	if lim.AllowWindow("reg:1.2.3.4", 5, time.Hour) {
		t.Fatal("expected 6th attempt in same hour to be denied")
	}
	now = now.Add(time.Hour + time.Second)
	if !lim.AllowWindow("reg:1.2.3.4", 5, time.Hour) {
		t.Fatal("expected attempt after window reset to pass")
	}
}

func TestWriteAudit(t *testing.T) {
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	if err := WriteAudit(store, AuditEntry{
		ActorType:   "admin",
		ActorID:     "adm-1",
		HouseholdID: "",
		Action:      "admin.login",
		TargetType:  "admin",
		TargetID:    "adm-1",
		IP:          "127.0.0.1",
		Detail:      map[string]any{"ok": true},
	}); err != nil {
		t.Fatalf("WriteAudit: %v", err)
	}

	var action, detail string
	var hhNull *string
	if err := store.ReadDB().QueryRow(`SELECT action, detail_json, household_id FROM audit_logs LIMIT 1`).Scan(&action, &detail, &hhNull); err != nil {
		t.Fatalf("query audit_logs: %v", err)
	}
	if action != "admin.login" || detail != `{"ok":true}` || hhNull != nil {
		t.Fatalf("unexpected audit row: action=%q detail=%q hh=%v", action, detail, hhNull)
	}
}
