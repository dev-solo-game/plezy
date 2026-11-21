package db

import (
	"os"
	"path/filepath"
	"testing"

	"plezy/media_library/internal/vault"
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

func TestMigrationsIdempotencyAndAllTables(t *testing.T) {
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	s1, err := Open(dir, v)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "library.db")); err != nil {
		t.Fatalf("expected library.db file: %v", err)
	}
	ver, err := s1.SchemaVersion()
	if err != nil || ver != 3 {
		t.Fatalf("schema version = %d, err = %v, want 3", ver, err)
	}
	_ = s1.Close()

	// Reopening must be idempotent without failing on existing tables/indexes.
	s2, err := Open(dir, v)
	if err != nil {
		t.Fatalf("second open: %v", err)
	}
	defer s2.Close()
	ver2, err := s2.SchemaVersion()
	if err != nil || ver2 != 3 {
		t.Fatalf("schema version on reopen = %d, err = %v, want 3", ver2, err)
	}

	expectedTables := []string{
		"schema_migrations",
		"platform_admins", "admin_sessions", "server_settings", "invite_codes", "audit_logs",
		"meta_works_cache", "meta_seasons_cache", "meta_people_cache", "meta_search_cache",
		"work_id_links", "genres", "people",
		"accounts", "households", "household_key_wraps", "members", "devices", "sessions",
		"qr_login_sessions", "account_login_tickets",
		"sources", "member_source_access", "source_folders", "source_credentials", "source_scan_state",
		"scan_sessions", "ingest_batches", "sidecars", "pending_deletions", "pending_deletion_files",
		"media_items", "media_files", "item_genres", "item_credits", "match_rules", "identify_queue",
		"member_watch_progress", "member_favorites", "household_work_prefs", "member_work_prefs",
		"lists", "list_entries", "change_log",
	}
	for _, tbl := range expectedTables {
		var name string
		if err := s2.ReadDB().QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name = ?`, tbl).Scan(&name); err != nil {
			t.Fatalf("missing table %s: %v", tbl, err)
		}
	}

	// Verify Migration 2 columns exist on sessions, accounts, and qr_login_sessions.
	for _, checkSQL := range []string{
		`SELECT login_mode FROM sessions LIMIT 0`,
		`SELECT recovery_salt, recovery_hash FROM accounts LIMIT 0`,
		`SELECT poll_secret_hash FROM qr_login_sessions LIMIT 0`,
	} {
		if _, err := s2.ReadDB().Exec(checkSQL); err != nil {
			t.Fatalf("migration 2 column check failed (%s): %v", checkSQL, err)
		}
	}
}

func TestTenantConstraintsSourceUniquenessAndMediaFiles(t *testing.T) {
	s := openTestStore(t)
	now := s.NowMs()

	seedHousehold := func(id string) {
		accID := "acc-" + id
		memID := "mem-" + id
		devID := "dev-" + id
		if _, err := s.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES (?, ?, 's', 'h', ?, ?)`, accID, "user-"+id, now, now); err != nil {
			t.Fatalf("insert account: %v", err)
		}
		if _, err := s.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES (?, ?, 'Home', ?, ?)`, id, accID, now, now); err != nil {
			t.Fatalf("insert household: %v", err)
		}
		if _, err := s.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, created_at, updated_at) VALUES (?, ?, 'Owner', 'owner', ?, ?)`, memID, id, now, now); err != nil {
			t.Fatalf("insert member: %v", err)
		}
		if _, err := s.DB().Exec(`INSERT INTO devices(id, household_id, device_class, last_seen_at, created_at) VALUES (?, ?, 'desktop', ?, ?)`, devID, id, now, now); err != nil {
			t.Fatalf("insert device: %v", err)
		}
	}
	seedHousehold("hh1")
	seedHousehold("hh2")

	// Strong identity source: unique within active household, allowed across households.
	if _, err := s.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, identity_unique, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1', 'hh1', 'quark', 'Quark A', 'hmac-uid-a', 1, 'mem-hh1', 'dev-hh1', ?, ?)`, now, now); err != nil {
		t.Fatalf("insert src1: %v", err)
	}
	if _, err := s.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, identity_unique, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1-dup', 'hh1', 'quark', 'Quark Dup', 'hmac-uid-a', 1, 'mem-hh1', 'dev-hh1', ?, ?)`, now, now); err == nil {
		t.Fatal("expected duplicate active strong identity within same household to fail")
	}
	if _, err := s.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, identity_unique, created_by_member, created_by_device, created_at, updated_at) VALUES ('src2', 'hh2', 'quark', 'Quark A', 'hmac-uid-a', 1, 'mem-hh2', 'dev-hh2', ?, ?)`, now, now); err != nil {
		t.Fatalf("same identity across households should succeed: %v", err)
	}

	// Weak identity source (WebDAV): duplicates within same household are permitted.
	for _, sid := range []string{"dav1", "dav2"} {
		if _, err := s.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, identity_unique, created_by_member, created_by_device, created_at, updated_at) VALUES (?, 'hh1', 'webdav', 'NAS', 'hmac-dav', 0, 'mem-hh1', 'dev-hh1', ?, ?)`, sid, now, now); err != nil {
			t.Fatalf("weak identity insert %s failed: %v", sid, err)
		}
	}

	// media_files: (source_id, path) unique, (source_id, remote_id) unique when non-null, multiple NULL remote_id allowed.
	if _, err := s.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, remote_id, role, last_seen_at, added_at, updated_at) VALUES ('hh1', 'src1', '/A/ep01.mkv', 'fid-1', 'video', ?, ?, ?)`, now, now, now); err != nil {
		t.Fatalf("insert file1: %v", err)
	}
	if _, err := s.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, remote_id, role, last_seen_at, added_at, updated_at) VALUES ('hh1', 'src1', '/A/ep01-renamed.mkv', 'fid-1', 'video', ?, ?, ?)`, now, now, now); err == nil {
		t.Fatal("expected duplicate (source_id, remote_id) to fail")
	}
	if _, err := s.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, remote_id, role, last_seen_at, added_at, updated_at) VALUES ('hh1', 'dav1', '/Movies/a.mkv', NULL, 'video', ?, ?, ?)`, now, now, now); err != nil {
		t.Fatalf("insert null remote_id 1: %v", err)
	}
	if _, err := s.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, remote_id, role, last_seen_at, added_at, updated_at) VALUES ('hh1', 'dav1', '/Movies/b.mkv', NULL, 'video', ?, ?, ?)`, now, now, now); err != nil {
		t.Fatalf("multiple NULL remote_id should be allowed: %v", err)
	}

	// Cascade delete household cleans up its sources and files.
	if _, err := s.DB().Exec(`DELETE FROM households WHERE id = 'hh1'`); err != nil {
		t.Fatalf("delete household: %v", err)
	}
	var remaining int
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = 'hh1'`).Scan(&remaining)
	if remaining != 0 {
		t.Fatalf("expected cascade delete of hh1 media_files, got %d", remaining)
	}
}

func TestSettingsEncryptionAndInspectableTablesAllowlist(t *testing.T) {
	s := openTestStore(t)

	apiKey := "v3-secret-tmdb-key-9988"
	regMode := RegistrationModeInvite
	minProto := 2
	updated, err := s.UpdateServerSettings(ServerSettingsUpdate{
		TmdbAPIKey:         &apiKey,
		RegistrationMode:   &regMode,
		MinProtocolVersion: &minProto,
	})
	if err != nil {
		t.Fatalf("update settings: %v", err)
	}
	if !updated.TmdbAPIKeySet || updated.TmdbAPIKey != apiKey || updated.TmdbAPIKeyMasked != "****9988" {
		t.Fatalf("unexpected tmdb key state: %+v", updated)
	}
	if updated.ServerName != DefaultServerName || updated.RegistrationMode != RegistrationModeInvite || updated.MinProtocolVersion != 2 {
		t.Fatalf("unexpected v1 settings: %+v", updated)
	}

	rawStored := s.GetSetting("tmdb_api_key_enc", "")
	if rawStored == "" || rawStored == apiKey {
		t.Fatalf("tmdb_api_key_enc was not encrypted: %q", rawStored)
	}

	// Reject invalid registration_mode or source_add_policy_json
	badMode := "everyone"
	if _, err := s.UpdateServerSettings(ServerSettingsUpdate{RegistrationMode: &badMode}); err == nil {
		t.Fatal("expected error for invalid registration_mode")
	}
	badPolicy := "not-json"
	if _, err := s.UpdateServerSettings(ServerSettingsUpdate{SourceAddPolicyJSON: &badPolicy}); err == nil {
		t.Fatal("expected error for invalid source_add_policy_json")
	}

	// Inspectable tables must only include public metadata tables (D8).
	tables, _, err := s.ListInspectableTables()
	if err != nil {
		t.Fatalf("list inspectable tables: %v", err)
	}
	if len(tables) != 5 {
		t.Fatalf("expected 5 public inspectable tables, got %d", len(tables))
	}
	for _, tbl := range tables {
		if tbl.Group != "cache" && tbl.Group != "link" {
			t.Fatalf("unexpected inspectable table group: %+v", tbl)
		}
	}
	for _, forbidden := range []string{"media_items", "media_files", "accounts", "sources", "source_credentials"} {
		if _, err := s.QueryInspectableTable(forbidden, "", 10, 0); err == nil {
			t.Fatalf("querying private table %q must fail", forbidden)
		}
	}
}

func TestAppendChangeTxMonotonicAndTenantIsolated(t *testing.T) {
	s := openTestStore(t)
	now := s.NowMs()

	for _, id := range []string{"hh-a", "hh-b"} {
		if _, err := s.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES (?, ?, 's', 'h', ?, ?)`, "acc-"+id, "u-"+id, now, now); err != nil {
			t.Fatal(err)
		}
		if _, err := s.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES (?, ?, 'Home', ?, ?)`, id, "acc-"+id, now, now); err != nil {
			t.Fatal(err)
		}
	}

	tx, err := s.DB().Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()

	seqA1, err := AppendChangeTx(tx, "hh-a", nil, "source", "src1", "create", now)
	if err != nil {
		t.Fatal(err)
	}
	seqA2, err := AppendChangeTx(tx, "hh-a", nil, "source", "src1", "update", now)
	if err != nil {
		t.Fatal(err)
	}
	seqB1, err := AppendChangeTx(tx, "hh-b", nil, "source", "src2", "create", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := AppendChangeTx(tx, "missing-hh", nil, "source", "srcX", "create", now); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound for unknown household, got %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	if seqA1 != 1 || seqA2 != 2 || seqB1 != 1 {
		t.Fatalf("unexpected sequences: a1=%d a2=%d b1=%d (want 1, 2, 1)", seqA1, seqA2, seqB1)
	}

	var cntA, cntB int
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = 'hh-a'`).Scan(&cntA)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = 'hh-b'`).Scan(&cntB)
	if cntA != 2 || cntB != 1 {
		t.Fatalf("unexpected change_log counts: hh-a=%d hh-b=%d", cntA, cntB)
	}
}

func TestMigration3RecomputesSourceAddedAtToMax(t *testing.T) {
	s := openTestStore(t)
	now := s.NowMs()

	_, _ = s.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES ('acc-m3', 'u-m3', 's', 'h', ?, ?)`, now, now)
	_, _ = s.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES ('hh-m3', 'acc-m3', 'Home', ?, ?)`, now, now)
	_, _ = s.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES ('mem-m3', 'hh-m3', 'Owner', 'owner', 63, ?, ?)`, now, now)
	_, _ = s.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, status, created_by_member, created_by_device, created_at, updated_at) VALUES ('src-m3', 'hh-m3', 'quark', 'Quark', 'qk-m3', 'active', 'mem-m3', 'dev-m3', ?, ?)`, now, now)

	res, err := s.DB().Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, title, sort_title, added_at, source_added_at, updated_at)
		VALUES ('hh-m3', 'tmdb:show:9001', 'show', 'show', 'Test', 'test', ?, 1000000, ?)`, now, now)
	if err != nil {
		t.Fatal(err)
	}
	showID, _ := res.LastInsertId()
	epRes, _ := s.DB().Exec(`
		INSERT INTO media_items(household_id, kind, library_type, parent_id, show_id, title, sort_title, season_number, episode_number, added_at, updated_at)
		VALUES ('hh-m3', 'episode', 'show', ?, ?, 'E1', 'e1', 1, 1, ?, ?)`, showID, showID, now, now)
	epID, _ := epRes.LastInsertId()
	_, _ = s.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, item_id, mtime_s, state, match_state, added_at, updated_at, last_seen_at)
		VALUES ('hh-m3', 'src-m3', '/TV/Test/E1.mkv', 'video', ?, 1000, 'active', 'matched', ?, ?, ?)`, epID, now, now, now)
	_, _ = s.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, item_id, mtime_s, state, match_state, added_at, updated_at, last_seen_at)
		VALUES ('hh-m3', 'src-m3', '/TV/Test/E2.mkv', 'video', ?, 4500, 'active', 'matched', ?, ?, ?)`, epID, now, now, now)

	// Roll back migration 3 marker and re-run migrations to test upgrade path.
	if _, err := s.DB().Exec(`DELETE FROM schema_migrations WHERE version = 3`); err != nil {
		t.Fatal(err)
	}
	if err := s.runMigrations(); err != nil {
		t.Fatalf("rerun migration 3 failed: %v", err)
	}

	var migrated int64
	if err := s.ReadDB().QueryRow(`SELECT source_added_at FROM media_items WHERE id = ?`, showID).Scan(&migrated); err != nil {
		t.Fatal(err)
	}
	if migrated != 4500*1000 {
		t.Fatalf("expected migration 3 to set source_added_at=%d, got %d", 4500*1000, migrated)
	}
}
