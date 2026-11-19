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

	calls := 0
	gen := func() (string, string) {
		calls++
		return "utdid-fixed-123", "DESKTOP-FIXED1"
	}
	u1, m1 := s.GetOrCreateQuarkPcDevice(gen)
	u2, m2 := s.GetOrCreateQuarkPcDevice(gen)
	if calls != 1 || u1 != "utdid-fixed-123" || u2 != u1 || m1 != "DESKTOP-FIXED1" || m2 != m1 {
		t.Fatalf("expected persisted fixed quark pc device, calls=%d u1=%q u2=%q m1=%q m2=%q", calls, u1, u2, m1, m2)
	}
}

func TestExternalServersCRUDAndEncryption(t *testing.T) {
	s := openTestStore(t)

	created, err := s.CreateExternalServer(ExternalServerRecord{
		Name:          "家庭 Emby",
		Kind:          "emby",
		BaseURL:       "http://192.168.1.20:8096/",
		AuthMode:      "password",
		Username:      "alice",
		UserID:        "uid-1",
		ServerID:      "srv-emby-1",
		ServerVersion: "4.9.5",
		Secrets:       map[string]string{"token": "emby-secret-token-xyz"},
		Enabled:       true,
	})
	if err != nil {
		t.Fatalf("create external server: %v", err)
	}
	if !created.HasToken || created.Secrets["token"] != "emby-secret-token-xyz" {
		t.Fatalf("unexpected created token state: %+v", created)
	}
	if created.BaseURL != "http://192.168.1.20:8096" || created.DeviceID == "" {
		t.Fatalf("unexpected normalized base_url or device_id: %+v", created)
	}

	var rawSecret string
	if err := s.DB().QueryRow(`SELECT encrypted_secrets FROM external_servers WHERE id = ?`, created.ID).Scan(&rawSecret); err != nil {
		t.Fatalf("query raw external server secret: %v", err)
	}
	if rawSecret == "" || rawSecret == "emby-secret-token-xyz" {
		t.Fatalf("external server secret not encrypted on disk")
	}

	newName := "家用 Emby 节点"
	disabled := false
	updated, err := s.UpdateExternalServer(created.ID, ExternalServerUpdate{
		Name:    &newName,
		Enabled: &disabled,
	})
	if err != nil {
		t.Fatalf("update external server: %v", err)
	}
	if updated.Name != newName || updated.Enabled || updated.Secrets["token"] != "emby-secret-token-xyz" {
		t.Fatalf("unexpected updated server: %+v", updated)
	}

	list, err := s.ListExternalServers()
	if err != nil || len(list) != 1 {
		t.Fatalf("list external servers len=%d err=%v", len(list), err)
	}

	page, err := s.QueryInspectableTable("external_servers", "Emby", 10, 0)
	if err != nil {
		t.Fatalf("inspect external_servers: %v", err)
	}
	if page.Total != 1 || len(page.Rows) != 1 {
		t.Fatalf("expected 1 row in inspectable external_servers, got %+v", page)
	}
	if _, leaked := page.Rows[0]["encrypted_secrets"]; leaked {
		t.Fatalf("encrypted_secrets must never be exposed via inspectable tables")
	}

	if err := s.DeleteExternalServer(created.ID); err != nil {
		t.Fatalf("delete external server: %v", err)
	}
	if _, err := s.GetExternalServer(created.ID); err == nil {
		t.Fatalf("expected error after deleting external server")
	}
}
