package platform

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/vault"
)

func openTestPlatform(t *testing.T, allowedCIDRs string) (*Service, *db.Store, func(time.Duration)) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	svc, err := NewService(store, security.NewLoginLimiter(), allowedCIDRs)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1700000000, 0)
	svc.SetClock(func() time.Time { return now })
	return svc, store, func(d time.Duration) { now = now.Add(d) }
}

func TestAdminSeedLoginLockoutChangeAndCLIReset(t *testing.T) {
	svc, _, advance := openTestPlatform(t, "127.0.0.1,10.0.0.0/8")

	usingDef, err := svc.EnsureDefaultAdmin("", "")
	if err != nil || !usingDef {
		t.Fatalf("expected default admin flag true, usingDef=%v err=%v", usingDef, err)
	}

	// Disallowed IP rejected
	if _, err := svc.Login("admin", "admin", "203.0.113.9", "ua"); !errors.Is(err, ErrForbiddenIP) {
		t.Fatalf("expected ErrForbiddenIP, got %v", err)
	}

	// Default admin/admin login yields must_change_password=true
	loginRes, err := svc.Login("admin", "admin", "127.0.0.1", "browser")
	if err != nil || !loginRes.Admin.MustChangePassword || !strings.HasPrefix(loginRes.AccessToken, AdminTokenPrefix) {
		t.Fatalf("unexpected default admin login: res=%+v err=%v", loginRes, err)
	}
	// Another login so we verify ChangePassword revokes other sessions
	loginRes2, err := svc.Login("admin", "admin", "10.0.0.5", "browser2")
	if err != nil {
		t.Fatal(err)
	}

	// User token prefix must never authenticate as admin
	if _, err := svc.Authenticate("usr_fake_token"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected ErrUnauthorized for user-prefixed token, got %v", err)
	}

	// ChangePassword clears must_change_password and revokes other sessions
	if err := svc.ChangePassword(loginRes.Admin.AdminID, "admin", "", "StrongAdminPass1!", loginRes.TokenID, "127.0.0.1"); err != nil {
		t.Fatalf("ChangePassword: %v", err)
	}
	if p, err := svc.Authenticate(loginRes.AccessToken); err != nil || p.MustChangePassword {
		t.Fatalf("expected kept session valid and flag cleared, p=%+v err=%v", p, err)
	}
	if _, err := svc.Authenticate(loginRes2.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected other admin session to be revoked, got %v", err)
	}
	if stillDef, _ := svc.EnsureDefaultAdmin("", ""); stillDef {
		t.Fatal("expected usingDefaultPass false after password change")
	}

	// 5 failed logins trigger 15-minute lockout
	for i := 0; i < 5; i++ {
		if _, err := svc.Login("admin", "wrong-pass", "127.0.0.1", "ua"); !errors.Is(err, ErrInvalidCredentials) {
			t.Fatalf("attempt %d err=%v", i, err)
		}
	}
	if _, err := svc.Login("admin", "StrongAdminPass1!", "127.0.0.1", "ua"); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("expected ErrRateLimited during lockout, got %v", err)
	}
	advance(16 * time.Minute)

	// CLI reset revokes remaining sessions and allows login with new password
	if err := svc.ResetAdminPasswordCLI("admin", "CliResetPass9!"); err != nil {
		t.Fatalf("ResetAdminPasswordCLI: %v", err)
	}
	if _, err := svc.Authenticate(loginRes.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected old session revoked after CLI reset, got %v", err)
	}
	if _, err := svc.Login("admin", "CliResetPass9!", "127.0.0.1", "ua"); err != nil {
		t.Fatalf("expected login with CLI-reset password to succeed: %v", err)
	}
}

func TestAccountsAdminPrivacySafeStatsResetAndGraceDelete(t *testing.T) {
	svc, store, advance := openTestPlatform(t, "")
	_, _ = svc.EnsureDefaultAdmin("admin", "CustomAdminPass!")
	admLogin, err := svc.Login("admin", "CustomAdminPass!", "127.0.0.1", "web")
	if err != nil {
		t.Fatal(err)
	}
	admID := admLogin.Admin.AdminID

	acc, err := svc.CreateAccountByAdmin(admID, "alice", "alice@example.com", "TempPass123!", "Alice家", "127.0.0.1")
	if err != nil {
		t.Fatalf("CreateAccountByAdmin: %v", err)
	}
	if !acc.MustChangePassword || acc.HouseholdName != "Alice家" {
		t.Fatalf("unexpected created account: %+v", acc)
	}

	// Seed a source, E2EE credential, E2EE key wrap, media item, file, sidecar dir
	nowMs := svc.nowFn().UnixMilli()
	if err := keyring.UpsertWrap(store, keyring.KeyWrap{
		HouseholdID:   acc.HouseholdID,
		WrapType:      keyring.WrapAccountPassword,
		SubjectID:     acc.AccountID,
		KdfAlg:        keyring.KdfAlgArgon2id,
		KdfSalt:       "c2FsdA==",
		KdfParamsJSON: `{"m":16384}`,
		WrappedHK:     "enc:hk:secret",
		KeyEpoch:      1,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`
		INSERT INTO sources(id, household_id, kind, name, identity_key, identity_unique, created_by_member, created_by_device, created_at, updated_at)
		VALUES ('src-q1', ?, 'quark', 'Secret Quark Name', 'hmac-q1', 1, 'm1', 'd1', ?, ?)`,
		acc.HouseholdID, nowMs, nowMs,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`
		INSERT INTO source_credentials(source_id, household_id, ciphertext, version, key_epoch, status, updated_by_device, updated_at)
		VALUES ('src-q1', ?, 'secret-cipher', 1, 1, 'valid', 'd1', ?)`,
		acc.HouseholdID, nowMs,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`
		INSERT INTO media_items(household_id, kind, library_type, title, sort_title, added_at, updated_at)
		VALUES (?, 'movie', 'movie', 'Secret Title', 'secret title', ?, ?)`,
		acc.HouseholdID, nowMs, nowMs,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, path, remote_id, role, last_seen_at, added_at, updated_at)
		VALUES (?, 'src-q1', '/SecretPath/movie.mkv', 'fid-1', 'video', ?, ?, ?)`,
		acc.HouseholdID, nowMs, nowMs, nowMs,
	); err != nil {
		t.Fatal(err)
	}
	sidecarDir := filepath.Join(store.DataDir(), "sidecars", acc.HouseholdID)
	if err := os.MkdirAll(sidecarDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sidecarDir, "test.nfo"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	list, total, err := svc.ListAccounts("alice", "", 20, 0)
	if err != nil || total != 1 || len(list) != 1 {
		t.Fatalf("ListAccounts total=%d len=%d err=%v", total, len(list), err)
	}
	item := list[0]
	if item.MemberCount != 1 || item.SourceCounts["quark"] != 1 || item.ItemCount != 1 || item.FileCount != 1 {
		t.Fatalf("unexpected aggregate stats: %+v", item)
	}

	// ResetAccountPassword wipes wraps and expires credentials while keeping library items
	if err := svc.ResetAccountPassword(admID, acc.AccountID, "ResetTemp99!", "127.0.0.1"); err != nil {
		t.Fatalf("ResetAccountPassword: %v", err)
	}
	wraps, _ := keyring.ListWraps(store, acc.HouseholdID, nil, "")
	if len(wraps) != 0 {
		t.Fatalf("expected E2EE wraps wiped after admin password reset, got %d", len(wraps))
	}
	var credStatus, credCipher string
	_ = store.ReadDB().QueryRow(`SELECT status, ciphertext FROM source_credentials WHERE source_id = 'src-q1'`).Scan(&credStatus, &credCipher)
	if credStatus != "expired" || credCipher != "" {
		t.Fatalf("expected source credential expired and wiped, got status=%q cipher=%q", credStatus, credCipher)
	}

	// Quotas & Invites
	newMax := 50
	if err := svc.UpdateHouseholdQuotas(admID, acc.AccountID, &newMax, nil, nil, "127.0.0.1"); err != nil {
		t.Fatalf("UpdateHouseholdQuotas: %v", err)
	}
	inv, err := svc.CreateInviteCode(admID, 3, nil, "friends", "127.0.0.1")
	if err != nil || len(inv.Code) != 12 {
		t.Fatalf("CreateInviteCode: %+v err=%v", inv, err)
	}
	if err := svc.RevokeInviteCode(admID, inv.Code, "127.0.0.1"); err != nil {
		t.Fatalf("RevokeInviteCode: %v", err)
	}

	// ScheduleDeleteAccount -> RestoreAccount -> ScheduleDeleteAccount -> Purge
	if err := svc.ScheduleDeleteAccount(admID, acc.AccountID, "127.0.0.1"); err != nil {
		t.Fatalf("ScheduleDeleteAccount: %v", err)
	}
	if err := svc.RestoreAccount(admID, acc.AccountID, "127.0.0.1"); err != nil {
		t.Fatalf("RestoreAccount: %v", err)
	}
	if err := svc.ScheduleDeleteAccount(admID, acc.AccountID, "127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if n, err := svc.PurgeExpiredDeletedAccounts(); err != nil || n != 0 {
		t.Fatalf("should not purge before 7-day grace period: n=%d err=%v", n, err)
	}
	advance(AccountDeletionGracePeriod + time.Minute)
	if n, err := svc.PurgeExpiredDeletedAccounts(); err != nil || n != 1 {
		t.Fatalf("expected 1 purged account, got n=%d err=%v", n, err)
	}
	if _, err := os.Stat(sidecarDir); !os.IsNotExist(err) {
		t.Fatalf("expected sidecar directory removed on purge")
	}

	audits, aTotal, err := svc.ListAuditLogs("", "", "", 50, 0)
	if err != nil || aTotal < 5 || len(audits) < 5 {
		t.Fatalf("expected audit logs recorded, total=%d err=%v", aTotal, err)
	}
}
