package db

import (
	"testing"

	"plezy/media_server/internal/vault"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	s, err := Open(dir, v)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestSettingsAndMountSecretsEncryption(t *testing.T) {
	s := openTestStore(t)
	apiKey := "v3-secret-tmdb-key-9988"
	updated, err := s.UpdateServerSettings(ServerSettingsUpdate{
		TmdbAPIKey: &apiKey,
	})
	if err != nil {
		t.Fatalf("update settings: %v", err)
	}
	if !updated.TmdbAPIKeySet || updated.TmdbAPIKey != apiKey || updated.TmdbAPIKeyMasked != "****9988" {
		t.Fatalf("unexpected settings state: %+v", updated)
	}

	// Verify raw setting in SQLite is encrypted, not plaintext.
	rawStored := s.GetSetting("tmdb_api_key_enc", "")
	if rawStored == "" || rawStored == apiKey {
		t.Fatalf("tmdb_api_key_enc was not encrypted: %q", rawStored)
	}

	m, err := s.CreateMount("Home NAS", "smb", map[string]any{"host": "192.168.1.10", "share": "media"}, map[string]string{"password": "nas-password"}, true)
	if err != nil {
		t.Fatalf("create mount: %v", err)
	}
	if !m.HasSecret || m.Secrets["password"] != "nas-password" {
		t.Fatalf("unexpected mount secrets: %+v", m)
	}

	var rawMountSecret string
	if err := s.DB().QueryRow(`SELECT encrypted_secrets FROM mounts WHERE id = ?`, m.ID).Scan(&rawMountSecret); err != nil {
		t.Fatalf("query raw mount secrets: %v", err)
	}
	if rawMountSecret == "" || rawMountSecret == "nas-password" {
		t.Fatalf("mount secrets not encrypted on disk")
	}

	if err := s.UpdateMountSecretKey(m.ID, "cookie", "rotated-cookie"); err != nil {
		t.Fatalf("update secret key: %v", err)
	}
	reloaded, err := s.GetMount(m.ID)
	if err != nil {
		t.Fatalf("get mount: %v", err)
	}
	if reloaded.Secrets["password"] != "nas-password" || reloaded.Secrets["cookie"] != "rotated-cookie" {
		t.Fatalf("unexpected merged secrets: %+v", reloaded.Secrets)
	}
}
