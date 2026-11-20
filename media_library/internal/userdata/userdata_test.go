package userdata

import (
	"testing"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/vault"
)

func TestUserDataProgressFavoritesPrefsListsAndMigration(t *testing.T) {
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

	now := store.NowMs()
	_, _ = store.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES ('acc1', 'u1', 's', 'h', ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES ('hh1', 'acc1', 'Home', ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES ('m1', 'hh1', 'User1', 'owner', 63, ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1', 'hh1', 'quark', 'Q', 'qk1', 'm1', 'd1', ?, ?)`, now, now)
	res, err := store.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, role, state, match_state, added_at, updated_at, last_seen_at) VALUES ('hh1', 'src1', '/Movies/Unmatched.mkv', 'video', 'active', 'unmatched', ?, ?, ?)`, now, now, now)
	if err != nil {
		t.Fatal(err)
	}
	fileID, _ := res.LastInsertId()

	svc := NewService(store, events.NewHub())
	p := &account.Principal{
		HouseholdID: "hh1",
		MemberID:    "m1",
		Role:        account.RoleOwner,
		Permissions: account.PermAll,
	}

	// 1. G3 unmatched file progress
	fp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		FileID:     &fileID,
		PositionMs: 42000,
	})
	if err != nil || fp.ProgressKey != "file:1" || fp.PositionMs != 42000 {
		t.Fatalf("unexpected file progress: %+v err=%v", fp, err)
	}

	// 2. Work progress + continue watching + hide
	s1, e2 := 1, 2
	wp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey:       "douban:show:999",
		SeasonNumber:  &s1,
		EpisodeNumber: &e2,
		PositionMs:    90000,
	})
	if err != nil || wp.ProgressKey != "douban:show:999:s1:e2" {
		t.Fatalf("unexpected episode progress: %+v err=%v", wp, err)
	}
	cw, err := svc.ListContinueWatching(p, 10)
	if err != nil || len(cw) != 2 {
		t.Fatalf("expected 2 continue watching items, got %d err=%v", len(cw), err)
	}
	if err := svc.HideFromContinue(p, fp.ProgressKey); err != nil {
		t.Fatal(err)
	}
	cw2, _ := svc.ListContinueWatching(p, 10)
	if len(cw2) != 1 || cw2[0].ProgressKey != "douban:show:999:s1:e2" {
		t.Fatalf("expected 1 continue watching item after hide, got %+v", cw2)
	}

	// 3. Favorites, work prefs, list & explicit G2 work-data migration
	if _, err := svc.AddFavorite(p, "douban:show:999"); err != nil {
		t.Fatal(err)
	}
	tr := true
	iEnd := int64(85000)
	if _, err := svc.UpsertHouseholdWorkPrefs(p, "douban:show:999", HouseholdWorkPrefsInput{
		IntroEnabled: &tr,
		IntroEndMs:   &iEnd,
	}); err != nil {
		t.Fatal(err)
	}
	audio := "ja"
	spd := 1.5
	prefs, err := svc.UpsertMemberWorkPrefs(p, "douban:show:999", MemberWorkPrefsInput{
		PreferredAudioLang: &audio,
		PlaybackSpeed:      &spd,
	})
	if err != nil || !prefs.IntroEnabled || prefs.IntroEndMs != 85000 || prefs.PreferredAudioLang != "ja" || prefs.PlaybackSpeed != 1.5 {
		t.Fatalf("unexpected merged prefs: %+v err=%v", prefs, err)
	}

	lst, err := svc.CreateList(p, CreateListRequest{Kind: "watchlist", Title: "My Watchlist"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.AddListEntry(p, lst.ID, AddListEntryRequest{WorkKey: "douban:show:999"}); err != nil {
		t.Fatal(err)
	}

	if err := svc.MigrateWorkData(p, "douban:show:999", "tmdb:show:100"); err != nil {
		t.Fatal(err)
	}
	favs, _ := svc.ListFavorites(p)
	if len(favs) != 1 || favs[0].WorkKey != "tmdb:show:100" {
		t.Fatalf("expected favorite migrated to tmdb:show:100, got %+v", favs)
	}
	det, _ := svc.GetList(p, lst.ID)
	if len(det.Entries) != 1 || det.Entries[0].WorkKey != "tmdb:show:100" {
		t.Fatalf("expected list entry migrated to tmdb:show:100, got %+v", det.Entries)
	}
}
