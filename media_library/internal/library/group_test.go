package library

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/vault"
)

type mapSidecarReader map[string]string

func (m mapSidecarReader) ReadText(_ context.Context, householdID, sha256 string) (string, error) {
	if txt, ok := m[householdID+":"+sha256]; ok {
		return txt, nil
	}
	return "", db.ErrNotFound
}

func seedTestHouseholdAndSource(t *testing.T, store *db.Store, hhID, accID, memID, srcID string) {
	t.Helper()
	now := store.NowMs()
	if _, err := store.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES (?, ?, 'salt', 'hash', ?, ?)`,
		accID, "user_"+accID, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES (?, ?, 'Home', ?, ?)`,
		hhID, accID, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES (?, ?, 'Owner', 'owner', 63, ?, ?)`,
		memID, hhID, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES (?, ?, 'webdav', 'NAS', ?, ?, 'dev-1', ?, ?)`,
		srcID, hhID, "webdav:"+srcID, memID, now, now); err != nil {
		t.Fatal(err)
	}
}

func insertTestMediaFile(t *testing.T, store *db.Store, hhID, srcID, path, role, sha string) int64 {
	t.Helper()
	now := store.NowMs()
	var shaPtr *string
	if sha != "" {
		shaPtr = &sha
	}
	res, err := store.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, sidecar_sha256, state, match_state, added_at, updated_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, 'active', 'pending', ?, ?, ?)`,
		hhID, srcID, path, role, shaPtr, now, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func TestIdentifyGroupShowNFOArtworkRulesAndG2G3Migrations(t *testing.T) {
	mockSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/tv":
			q := r.URL.Query().Get("query")
			if strings.Contains(q, "Severance") || strings.Contains(q, "人生切割术") {
				_, _ = w.Write([]byte(`{"results":[{"id":95396,"name":"人生切割术","original_name":"Severance","first_air_date":"2022-02-18"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/search/movie":
			q := r.URL.Query().Get("query")
			if strings.Contains(q, "Inception") {
				_, _ = w.Write([]byte(`{"results":[{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/tv/95396":
			_, _ = w.Write([]byte(`{
				"id":95396,
				"name":"人生切割术",
				"original_name":"Severance",
				"first_air_date":"2022-02-18",
				"overview":"Macrodata Refinement",
				"genres":[{"name":"Sci-Fi & Fantasy"},{"name":"Mystery"}],
				"credits":{"cast":[{"id":36801,"name":"Adam Scott","character":"Mark Scout"}]}
			}`))
		case "/3/tv/95396/season/1":
			_, _ = w.Write([]byte(`{
				"season_number":1,
				"name":"Season 1",
				"episodes":[{"episode_number":1,"name":"Good News About Hell","overview":"Ep1"}]
			}`))
		case "/3/movie/27205":
			_, _ = w.Write([]byte(`{
				"id":27205,
				"title":"盗梦空间",
				"original_title":"Inception",
				"release_date":"2010-07-15",
				"imdb_id":"tt1375666",
				"genres":[{"name":"Action"}]
			}`))
		case "/3/movie/157336":
			_, _ = w.Write([]byte(`{
				"id":157336,
				"title":"星际穿越",
				"original_title":"Interstellar",
				"release_date":"2014-11-05"
			}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockSrv.Close()

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

	tmdbKey := "mock-key"
	tmdbBase := mockSrv.URL + "/3"
	falseVal := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		DoubanEnabled:  &falseVal,
		BangumiEnabled: &falseVal,
		AniListEnabled: &falseVal,
		ImdbEnabled:    &falseVal,
	}); err != nil {
		t.Fatal(err)
	}

	seedTestHouseholdAndSource(t, store, "hh-1", "acc-1", "mem-1", "src-1")

	ep1ID := insertTestMediaFile(t, store, "hh-1", "src-1", "/Shows/Severance/Season 1/S01E01.mkv", db.FileRoleVideo, "")
	insertTestMediaFile(t, store, "hh-1", "src-1", "/Shows/Severance/tvshow.nfo", db.FileRoleNfo, "nfohash1")
	insertTestMediaFile(t, store, "hh-1", "src-1", "/Shows/Severance/poster.jpg", db.FileRoleArtwork, "artposter1")

	// Seed unmatched G3 file progress ("file:<ep1ID>") before identification.
	now := store.NowMs()
	if _, err := store.DB().Exec(`
		INSERT INTO member_watch_progress(household_id, member_id, progress_key, work_key, season_number, episode_number, last_file_id, position_ms, watched, updated_at)
		VALUES ('hh-1', 'mem-1', ?, NULL, -1, -1, ?, 12345, 0, ?)`,
		"file:"+itoa64(ep1ID), ep1ID, now,
	); err != nil {
		t.Fatal(err)
	}

	metaSvc := metadata.NewService(store)
	sc := NewScraper(store, metaSvc)
	sc.SetSidecarReader(mapSidecarReader{
		"hh-1:nfohash1": `<tvshow><title>Severance</title><tmdbid>95396</tmdbid></tvshow>`,
	})

	_, _, showGK := ParseAndGroup("src-1", "/Shows/Severance/Season 1/S01E01.mkv")
	if showGK != "src-1:dir:/Shows/Severance" {
		t.Fatalf("unexpected group key: %s", showGK)
	}

	ctx := context.Background()
	if err := sc.IdentifyGroup(ctx, "hh-1", showGK); err != nil {
		t.Fatalf("IdentifyGroup failed: %v", err)
	}

	// Verify root show item carries work_key + fallback local poster, while season/episode have NULL work_key.
	var showID int64
	var showWK, posterSrc string
	if err := store.ReadDB().QueryRow(`
		SELECT id, work_key, COALESCE(poster_source, '') FROM media_items
		WHERE household_id = 'hh-1' AND kind = 'show'`).Scan(&showID, &showWK, &posterSrc); err != nil {
		t.Fatalf("query show item failed: %v", err)
	}
	if showWK != "tmdb:show:95396" {
		t.Fatalf("expected tmdb:show:95396, got %s", showWK)
	}
	if posterSrc != "sidecar:artposter1" {
		t.Fatalf("expected sidecar poster fallback, got %q", posterSrc)
	}

	var childWithWK int
	if err := store.ReadDB().QueryRow(`
		SELECT COUNT(*) FROM media_items WHERE household_id = 'hh-1' AND kind IN ('season', 'episode') AND work_key IS NOT NULL`).Scan(&childWithWK); err != nil {
		t.Fatal(err)
	}
	if childWithWK != 0 {
		t.Fatalf("season/episode must keep NULL work_key, got %d", childWithWK)
	}

	var epTitle string
	var linkedItemID sql.NullInt64
	if err := store.ReadDB().QueryRow(`
		SELECT mi.title, mf.item_id FROM media_files mf
		JOIN media_items mi ON mi.id = mf.item_id
		WHERE mf.id = ?`, ep1ID).Scan(&epTitle, &linkedItemID); err != nil {
		t.Fatal(err)
	}
	if epTitle != "Good News About Hell" || !linkedItemID.Valid {
		t.Fatalf("unexpected episode link: title=%q itemID=%v", epTitle, linkedItemID)
	}

	// Verify G3 progress migrated from file:<id> to tmdb:show:95396:s1:e1.
	var migratedPos int64
	if err := store.ReadDB().QueryRow(`
		SELECT position_ms FROM member_watch_progress
		WHERE member_id = 'mem-1' AND progress_key = 'tmdb:show:95396:s1:e1'`).Scan(&migratedPos); err != nil {
		t.Fatalf("expected G3 migrated progress: %v", err)
	}
	if migratedPos != 12345 {
		t.Fatalf("expected migrated pos 12345, got %d", migratedPos)
	}

	// Verify EditMediaItem sets locked=1 and subsequent IdentifyGroup/Rescrape preserves manual edit.
	newTitle := "Custom Severance Title"
	if err := sc.EditMediaItem("hh-1", nil, showID, EditItemRequest{Title: &newTitle}); err != nil {
		t.Fatal(err)
	}
	if err := sc.RescrapeMediaItem(ctx, "hh-1", nil, showID, RescrapeRequest{}); err != nil {
		t.Fatal(err)
	}
	var keptTitle string
	if err := store.ReadDB().QueryRow(`SELECT title FROM media_items WHERE id = ?`, showID).Scan(&keptTitle); err != nil {
		t.Fatal(err)
	}
	if keptTitle != newTitle {
		t.Fatalf("expected locked title %q preserved, got %q", newTitle, keptTitle)
	}

	// Verify ResolveWorkKey recorded link.
	ck, _, ok := sc.ResolveWorkKey("show", "tmdb", "95396")
	if !ok || ck != "tmdb:show:95396" {
		t.Fatalf("expected work_id_links hit, got ok=%v ck=%s", ok, ck)
	}

	// Verify Movie + ApplyManualMatch creates match_rules + runs G2 user data migration!
	movID := insertTestMediaFile(t, store, "hh-1", "src-1", "/Movies/Inception.2010.mkv", db.FileRoleVideo, "")
	_, _, movGK := ParseAndGroup("src-1", "/Movies/Inception.2010.mkv")
	if err := sc.IdentifyGroup(ctx, "hh-1", movGK); err != nil {
		t.Fatal(err)
	}

	// Seed user data tied to tmdb:movie:27205 before remapping movie to 157336.
	if _, err := store.DB().Exec(`INSERT INTO member_favorites(household_id, member_id, work_key, created_at) VALUES ('hh-1', 'mem-1', 'tmdb:movie:27205', 1000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO member_watch_progress(household_id, member_id, progress_key, work_key, position_ms, watched, updated_at) VALUES ('hh-1', 'mem-1', 'tmdb:movie:27205', 'tmdb:movie:27205', 5555, 0, 2000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO household_work_prefs(household_id, work_key, intro_enabled, intro_start_ms, intro_end_ms, updated_at) VALUES ('hh-1', 'tmdb:movie:27205', 1, 100, 900, 2000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO member_work_prefs(household_id, member_id, work_key, preferred_audio_lang, playback_speed, updated_at) VALUES ('hh-1', 'mem-1', 'tmdb:movie:27205', 'en', 1.25, 2000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO lists(id, household_id, member_id, kind, title, created_at, updated_at) VALUES ('list-1', 'hh-1', 'mem-1', 'collection', 'Favs', 1000, 1000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO list_entries(list_id, entry_key, work_key, added_at) VALUES ('list-1', 'tmdb:movie:27205', 'tmdb:movie:27205', 1000)`); err != nil {
		t.Fatal(err)
	}

	res, err := sc.ApplyManualMatch(ctx, "hh-1", "mem-1", nil, ManualMatchRequest{
		FileIDs:    []int64{movID},
		Provider:   "tmdb",
		Kind:       "movie",
		ExternalID: "157336",
	})
	if err != nil {
		t.Fatalf("ApplyManualMatch failed: %v", err)
	}
	if res.WorkKey != "tmdb:movie:157336" || len(res.RuleIDs) != 1 {
		t.Fatalf("unexpected manual match result: %+v", res)
	}

	var favCnt, listCnt, hhPrefCnt, memPrefCnt int
	var newPos int64
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM member_favorites WHERE member_id = 'mem-1' AND work_key = 'tmdb:movie:157336'`).Scan(&favCnt)
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM list_entries WHERE list_id = 'list-1' AND entry_key = 'tmdb:movie:157336'`).Scan(&listCnt)
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM household_work_prefs WHERE household_id = 'hh-1' AND work_key = 'tmdb:movie:157336'`).Scan(&hhPrefCnt)
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM member_work_prefs WHERE member_id = 'mem-1' AND work_key = 'tmdb:movie:157336'`).Scan(&memPrefCnt)
	_ = store.ReadDB().QueryRow(`SELECT position_ms FROM member_watch_progress WHERE member_id = 'mem-1' AND progress_key = 'tmdb:movie:157336'`).Scan(&newPos)
	if favCnt != 1 || listCnt != 1 || hhPrefCnt != 1 || memPrefCnt != 1 || newPos != 5555 {
		t.Fatalf("G2 user data migration incomplete: fav=%d list=%d hhPref=%d memPref=%d pos=%d", favCnt, listCnt, hhPrefCnt, memPrefCnt, newPos)
	}
}

func itoa64(v int64) string {
	const digits = "0123456789"
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = digits[v%10]
		v /= 10
	}
	return string(buf[i:])
}
