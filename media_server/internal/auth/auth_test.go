package auth

import (
	"errors"
	"testing"
	"time"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/vault"
)

func openTestAuth(t *testing.T) (*Service, *db.Store) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return NewService(store), store
}

func TestAdminSetupLoginPasswordAndSessions(t *testing.T) {
	svc, _ := openTestAuth(t)
	if svc.IsInitialized() {
		t.Fatal("fresh store should not be initialized")
	}

	sess, err := svc.SetupAdmin("admin", "secret123", "Chrome", "web", "127.0.0.1")
	if err != nil {
		t.Fatalf("setup admin: %v", err)
	}
	if sess.Username != "admin" || sess.AccessToken == "" {
		t.Fatalf("unexpected setup session: %+v", sess)
	}
	if !svc.IsInitialized() {
		t.Fatal("expected initialized after setup")
	}
	if _, err := svc.SetupAdmin("admin", "secret123", "Chrome", "web", "127.0.0.1"); !errors.Is(err, ErrAlreadyInitialized) {
		t.Fatalf("second setup must fail with ErrAlreadyInitialized, got %v", err)
	}

	if _, _, err := svc.Authenticate(sess.AccessToken); err != nil {
		t.Fatalf("authenticate setup token: %v", err)
	}
	if _, _, err := svc.Authenticate("bad-token"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected ErrUnauthorized, got %v", err)
	}

	// Login with wrong password fails.
	if _, err := svc.Login("admin", "wrongpass", "Edge", "web", "127.0.0.1"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}

	// Second device login works.
	sess2, err := svc.Login("ADMIN", "secret123", "Safari", "web", "10.0.0.2")
	if err != nil {
		t.Fatalf("login failed: %v", err)
	}
	sessions, err := svc.ListSessions(sess2.TokenID)
	if err != nil || len(sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d err=%v", len(sessions), err)
	}

	// Change password keeps sess2 and invalidates sess1.
	if err := svc.ChangePassword("secret123", "newsecret456", "", sess2.TokenID); err != nil {
		t.Fatalf("change password: %v", err)
	}
	if _, _, err := svc.Authenticate(sess.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old session should have been invalidated, got %v", err)
	}
	if _, _, err := svc.Authenticate(sess2.AccessToken); err != nil {
		t.Fatalf("kept session should still authenticate: %v", err)
	}
	if _, err := svc.Login("admin", "secret123", "x", "web", "127.0.0.1"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatal("old password must no longer work")
	}
	if _, err := svc.Login("admin", "newsecret456", "x", "web", "127.0.0.1"); err != nil {
		t.Fatalf("new password login failed: %v", err)
	}
}

func TestRevokeAndLogoutBypassSessionCache(t *testing.T) {
	svc, _ := openTestAuth(t)
	sess, err := svc.SetupAdmin("admin", "secret123", "Chrome", "web", "127.0.0.1")
	if err != nil {
		t.Fatalf("setup admin: %v", err)
	}
	sess2, err := svc.Login("admin", "secret123", "Safari", "web", "127.0.0.1")
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	// Warm the cache for both sessions.
	for _, tok := range []string{sess.AccessToken, sess2.AccessToken} {
		if _, _, err := svc.Authenticate(tok); err != nil {
			t.Fatalf("authenticate: %v", err)
		}
	}
	if err := svc.RevokeSession(sess.TokenID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, _, err := svc.Authenticate(sess.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked session must not authenticate from cache, got %v", err)
	}
	if err := svc.Logout(sess2.AccessToken); err != nil {
		t.Fatalf("logout: %v", err)
	}
	if _, _, err := svc.Authenticate(sess2.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("logged out session must not authenticate from cache, got %v", err)
	}
}

func TestStreamTokenSigningAndExpiry(t *testing.T) {
	svc, _ := openTestAuth(t)
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	svc.SetClock(func() time.Time { return now })

	tok := svc.SignStreamToken("file", "42", 10*time.Minute)
	if err := svc.VerifyStreamToken(tok, "file", "42"); err != nil {
		t.Fatalf("verify valid stream token: %v", err)
	}
	if err := svc.VerifyStreamToken(tok, "file", "43"); !errors.Is(err, ErrInvalidStreamToken) {
		t.Fatalf("expected mismatch error for wrong resource id, got %v", err)
	}
	if err := svc.VerifyStreamToken(tok, "sub", "42"); !errors.Is(err, ErrInvalidStreamToken) {
		t.Fatalf("expected mismatch error for wrong scope, got %v", err)
	}

	// Advance past expiry.
	now = now.Add(11 * time.Minute)
	if err := svc.VerifyStreamToken(tok, "file", "42"); !errors.Is(err, ErrInvalidStreamToken) {
		t.Fatalf("expected expiry error, got %v", err)
	}
}
