package db

import (
	"strings"
	"testing"
)

// TestMediaItemAggregatesAcrossEpisodes guards the index-friendly rewrite of the
// max_width / hdr_formats / source_kinds subqueries: a show and a season must
// aggregate the video files of their episodes, a movie only its own files.
func TestMediaItemAggregatesAcrossEpisodes(t *testing.T) {
	s := openTestStore(t)
	exec := func(q string, args ...any) int64 {
		t.Helper()
		res, err := s.DB().Exec(q, args...)
		if err != nil {
			t.Fatalf("exec %q: %v", q, err)
		}
		id, _ := res.LastInsertId()
		return id
	}

	exec(`INSERT INTO mounts(id, name, kind, created_at, updated_at) VALUES ('m-local', 'Local', 'local', 1, 1)`)
	exec(`INSERT INTO mounts(id, name, kind, created_at, updated_at) VALUES ('m-quark', 'Quark', 'quark', 1, 1)`)

	item := func(kind, lib, title string, parent, show any, added int64) int64 {
		return exec(`INSERT INTO media_items(kind, library_type, parent_id, show_id, title, sort_title, added_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, kind, lib, parent, show, title, title, added, added)
	}
	file := func(mount string, itemID int64, width int, hdr any) {
		exec(`INSERT INTO media_files(mount_id, path, role, item_id, width, hdr_format, added_at)
			VALUES (?, ?, 'video', ?, ?, ?, 1)`, mount, "/p/"+strings.Repeat("x", int(itemID)), itemID, width, hdr)
	}

	movie := item("movie", "movie", "Movie", nil, nil, 10)
	file("m-local", movie, 1920, nil)

	show := item("show", "show", "Show", nil, nil, 20)
	season := item("season", "show", "S1", show, show, 20)
	ep1 := item("episode", "show", "E1", season, show, 20)
	ep2 := item("episode", "show", "E2", season, show, 20)
	file("m-local", ep1, 1280, nil)
	file("m-quark", ep2, 3840, "DolbyVision")

	// An unrelated 4K file must not leak into the movie's aggregate.
	other := item("movie", "movie", "Other", nil, nil, 5)
	file("m-quark", other, 3840, "HDR10")

	get := func(id int64) MediaItem {
		t.Helper()
		it, err := s.GetMediaItem(id)
		if err != nil {
			t.Fatalf("get item %d: %v", id, err)
		}
		return it
	}

	if m := get(movie); m.QualityBadge != "1080P" || m.HdrBadge != "" || strings.Join(m.SourceKinds, ",") != "local" {
		t.Fatalf("movie aggregates wrong: quality=%q hdr=%q sources=%v", m.QualityBadge, m.HdrBadge, m.SourceKinds)
	}
	for _, id := range []int64{show, season} {
		it := get(id)
		if it.QualityBadge != "4K" || it.HdrBadge != "DoVi" {
			t.Fatalf("item %d aggregates wrong: quality=%q hdr=%q", id, it.QualityBadge, it.HdrBadge)
		}
		kinds := map[string]bool{}
		for _, k := range it.SourceKinds {
			kinds[k] = true
		}
		if !kinds["local"] || !kinds["quark"] || len(kinds) != 2 {
			t.Fatalf("item %d source kinds wrong: %v", id, it.SourceKinds)
		}
	}

	// Library filters reuse the same subquery.
	page, err := s.QueryLibrary(LibraryQuery{Quality: "4k"})
	if err != nil {
		t.Fatalf("query 4k: %v", err)
	}
	got := map[int64]bool{}
	for _, it := range page.Items {
		got[it.ID] = true
	}
	if !got[show] || !got[other] || got[movie] || page.Total != 2 {
		t.Fatalf("4k filter wrong: total=%d items=%v", page.Total, got)
	}
	page, err = s.QueryLibrary(LibraryQuery{MountID: "m-local"})
	if err != nil {
		t.Fatalf("query mount: %v", err)
	}
	got = map[int64]bool{}
	for _, it := range page.Items {
		got[it.ID] = true
	}
	if !got[show] || !got[movie] || got[other] || page.Total != 2 {
		t.Fatalf("mount filter wrong: total=%d items=%v", page.Total, got)
	}

	// Default sort is newest first.
	page, err = s.QueryLibrary(LibraryQuery{Sort: "added_at", Order: "desc", Limit: 10})
	if err != nil {
		t.Fatalf("query recent: %v", err)
	}
	if len(page.Items) != 3 || page.Items[0].ID != show || page.Items[2].ID != other {
		t.Fatalf("unexpected recent order: %+v", page.Items)
	}
}

func TestReadPoolIsReadOnlyAndSeesCommittedWrites(t *testing.T) {
	s := openTestStore(t)
	if s.ReadDB() == s.DB() {
		t.Fatal("expected a separate read pool")
	}
	if _, err := s.ReadDB().Exec(`INSERT INTO server_settings(key, value) VALUES ('x', 'y')`); err == nil {
		t.Fatal("read pool must reject writes (query_only)")
	}
	if err := s.SetSetting("probe", "v1"); err != nil {
		t.Fatal(err)
	}
	var v string
	if err := s.ReadDB().QueryRow(`SELECT value FROM server_settings WHERE key = 'probe'`).Scan(&v); err != nil || v != "v1" {
		t.Fatalf("read pool did not see committed write: v=%q err=%v", v, err)
	}
	// While the writer holds an open transaction, reads must not block.
	tx, err := s.DB().Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE server_settings SET value = 'v2' WHERE key = 'probe'`); err != nil {
		t.Fatal(err)
	}
	if err := s.ReadDB().QueryRow(`SELECT value FROM server_settings WHERE key = 'probe'`).Scan(&v); err != nil || v != "v1" {
		t.Fatalf("expected snapshot read during open write tx: v=%q err=%v", v, err)
	}
}

func TestServerSettingsCacheInvalidation(t *testing.T) {
	s := openTestStore(t)
	if got := s.GetServerSettings().ServerName; got != DefaultServerName {
		t.Fatalf("default server name = %q", got)
	}
	if err := s.SetSetting("server_name", "Living Room"); err != nil {
		t.Fatalf("set setting: %v", err)
	}
	if got := s.GetServerSettings().ServerName; got != "Living Room" {
		t.Fatalf("settings cache not invalidated after SetSetting: %q", got)
	}
	name := "Basement"
	if _, err := s.UpdateServerSettings(ServerSettingsUpdate{ServerName: &name}); err != nil {
		t.Fatalf("update settings: %v", err)
	}
	if got := s.GetServerSettings().ServerName; got != "Basement" {
		t.Fatalf("settings cache not invalidated after UpdateServerSettings: %q", got)
	}
	if got := s.GetSetting("missing_key", "fallback"); got != "fallback" {
		t.Fatalf("GetSetting fallback = %q", got)
	}
}
