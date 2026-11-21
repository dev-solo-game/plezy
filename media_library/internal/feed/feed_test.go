package feed

import (
	"strconv"
	"testing"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/userdata"
	"plezy/media_library/internal/vault"
)

func TestFeedSnapshotChangesAndDetailDualArtwork(t *testing.T) {
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
	_, _ = store.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1', 'hh1', 'quark', 'Quark', 'qk1', 'm1', 'd1', ?, ?)`, now, now)

	// Seed a matched movie with both remote poster_source and a local sibling poster.jpg sidecar (G10).
	tx, _ := store.DB().Begin()
	res, err := tx.Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, title, sort_title, year, poster_source, tmdb_id, metadata_source, added_at, updated_at)
		VALUES ('hh1', 'tmdb:movie:27205', 'movie', 'movie', 'Inception', 'inception', 2010, '/tmdb_poster.jpg', '27205', 'tmdb', ?, ?)`,
		now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	itemID, _ := res.LastInsertId()

	vRes, err := tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, item_id, state, match_state, duration_ms, video_codec, width, height, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Movies/Inception/Inception.2010.mkv', 'video', ?, 'active', 'matched', 8880000, 'hevc', 3840, 2160, ?, ?, ?)`,
		itemID, now, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	videoFileID, _ := vRes.LastInsertId()

	_, _ = tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, owner_file_id, language, state, match_state, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Movies/Inception/Inception.2010.zh.srt', 'subtitle', ?, 'zh', 'active', 'matched', ?, ?, ?)`,
		videoFileID, now, now, now,
	)
	_, _ = tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, sidecar_sha256, state, match_state, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Movies/Inception/poster.jpg', 'artwork', '1111111111111111111111111111111111111111111111111111111111111111', 'active', 'matched', ?, ?, ?)`,
		now, now, now,
	)
	seq1, err := db.AppendChangeTx(tx, "hh1", nil, "item", "1", "upsert", now)
	if err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit()

	udSvc := userdata.NewService(store, events.NewHub())
	feedSvc := NewService(store, udSvc)
	p := &account.Principal{
		HouseholdID: "hh1",
		MemberID:    "m1",
		Role:        account.RoleOwner,
		Permissions: account.PermAll,
	}

	snap, err := feedSvc.GetSnapshot(p, SnapshotRequest{})
	if err != nil || snap.Total != 1 || snap.SnapshotSeq != seq1 {
		t.Fatalf("unexpected snapshot: %+v err=%v", snap, err)
	}
	if snap.Items[0].PosterURL == "" || snap.Items[0].LocalPosterURL != "/api/v1/sidecars/1111111111111111111111111111111111111111111111111111111111111111" {
		t.Fatalf("expected G10 dual image URLs, got poster=%q local=%q", snap.Items[0].PosterURL, snap.Items[0].LocalPosterURL)
	}

	det, err := feedSvc.GetItemDetail(p, itemID)
	if err != nil || len(det.Files) != 1 || len(det.Files[0].Subtitles) != 1 {
		t.Fatalf("unexpected detail: %+v err=%v", det, err)
	}

	// Incremental changes since 0 returns seq1; since_seq < min_retained_seq triggers reset_required.
	chg, err := feedSvc.GetChanges(p, 0, 50)
	if err != nil || chg.ResetRequired || len(chg.Changes) != 1 {
		t.Fatalf("unexpected changes: %+v err=%v", chg, err)
	}
	_, _ = store.DB().Exec(`UPDATE households SET min_retained_seq = 5, next_change_seq = 10 WHERE id = 'hh1'`)
	chgReset, err := feedSvc.GetChanges(p, 2, 50)
	if err != nil || !chgReset.ResetRequired {
		t.Fatalf("expected reset_required=true when since_seq < min_retained_seq, got %+v err=%v", chgReset, err)
	}
}

func TestFeedSnapshotHierarchyAndIncludeFiles(t *testing.T) {
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
	_, _ = store.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1', 'hh1', 'quark', 'Quark', 'qk1', 'm1', 'd1', ?, ?)`, now, now)

	tx, _ := store.DB().Begin()
	mRes, err := tx.Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, title, sort_title, year, tmdb_id, metadata_source, added_at, updated_at)
		VALUES ('hh1', 'tmdb:movie:27205', 'movie', 'movie', 'Inception', 'inception', 2010, '27205', 'tmdb', ?, ?)`,
		now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	movieID, _ := mRes.LastInsertId()
	mvRes, err := tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, remote_id, role, item_id, state, match_state, size, mtime_s, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Movies/Inception.mkv', 'qk_m1', 'video', ?, 'active', 'matched', 1024, 1700000001, ?, ?, ?)`,
		movieID, now, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	mvFileID, _ := mvRes.LastInsertId()
	_, _ = tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, remote_id, role, owner_file_id, language, state, match_state, size, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Movies/Inception.zh.srt', 'qk_ms1', 'subtitle', ?, 'zh', 'active', 'matched', 512, ?, ?, ?)`,
		mvFileID, now, now, now,
	)

	sRes, err := tx.Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, title, sort_title, year, tmdb_id, metadata_source, added_at, updated_at)
		VALUES ('hh1', 'tmdb:show:100', 'show', 'show', 'Example Show', 'example show', 2022, '100', 'tmdb', ?, ?)`,
		now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	showID, _ := sRes.LastInsertId()

	seRes, err := tx.Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, parent_id, show_id, title, sort_title, season_number, added_at, updated_at)
		VALUES ('hh1', '', 'season', 'show', ?, ?, 'Season 1', 'season 1', 1, ?, ?)`,
		showID, showID, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	seasonID, _ := seRes.LastInsertId()

	epRes, err := tx.Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, parent_id, show_id, title, sort_title, season_number, episode_number, added_at, updated_at)
		VALUES ('hh1', '', 'episode', 'show', ?, ?, 'Pilot', 'pilot', 1, 2, ?, ?)`,
		seasonID, showID, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	epID, _ := epRes.LastInsertId()

	epvRes, err := tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, remote_id, role, item_id, state, match_state, size, mtime_s, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Shows/Example/S01E02.mkv', 'qk_ep2', 'video', ?, 'active', 'matched', 2048, 1700000002, ?, ?, ?)`,
		epID, now, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	epFileID, _ := epvRes.LastInsertId()
	_, _ = tx.Exec(`
		INSERT INTO media_files(household_id, source_id, path, remote_id, role, owner_file_id, language, state, match_state, size, added_at, updated_at, last_seen_at)
		VALUES ('hh1', 'src1', '/Shows/Example/S01E02.zh.srt', 'qk_eps2', 'subtitle', ?, 'zh', 'active', 'matched', 256, ?, ?, ?)`,
		epFileID, now, now, now,
	)
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	feedSvc := NewService(store, userdata.NewService(store, events.NewHub()))
	p := &account.Principal{
		HouseholdID: "hh1",
		MemberID:    "m1",
		Role:        account.RoleOwner,
		Permissions: account.PermAll,
	}

	// Default top-level snapshot returns movie + show, omitting season + episode.
	topSnap, err := feedSvc.GetSnapshot(p, SnapshotRequest{})
	if err != nil {
		t.Fatalf("top snapshot error: %v", err)
	}
	if topSnap.Total != 2 || len(topSnap.Items) != 2 {
		t.Fatalf("expected 2 top-level items, got total=%d items=%d", topSnap.Total, len(topSnap.Items))
	}

	// kind=season without parent_id must return seasons (regression check).
	seasonSnap, err := feedSvc.GetSnapshot(p, SnapshotRequest{Kind: db.KindSeason})
	if err != nil {
		t.Fatalf("season snapshot error: %v", err)
	}
	if seasonSnap.Total != 1 || len(seasonSnap.Items) != 1 || seasonSnap.Items[0].ID != seasonID {
		t.Fatalf("expected season %d, got %+v", seasonID, seasonSnap)
	}

	// kind=episode without parent_id and with IncludeFiles=true returns episode + files + subtitles.
	epSnap, err := feedSvc.GetSnapshot(p, SnapshotRequest{Kind: db.KindEpisode, IncludeFiles: true})
	if err != nil {
		t.Fatalf("episode snapshot error: %v", err)
	}
	if epSnap.Total != 1 || len(epSnap.Items) != 1 {
		t.Fatalf("expected 1 episode, got %+v", epSnap)
	}
	epItem := epSnap.Items[0]
	if len(epItem.Files) != 1 || epItem.Files[0].RemoteID != "qk_ep2" {
		t.Fatalf("expected inline episode file, got %+v", epItem.Files)
	}
	if len(epItem.Files[0].Subtitles) != 1 || epItem.Files[0].Subtitles[0].Language != "zh" {
		t.Fatalf("expected inline episode subtitle, got %+v", epItem.Files[0].Subtitles)
	}

	// kind=movie with IncludeFiles=true returns movie + files + subtitles.
	mvSnap, err := feedSvc.GetSnapshot(p, SnapshotRequest{Kind: db.KindMovie, IncludeFiles: true})
	if err != nil {
		t.Fatalf("movie snapshot error: %v", err)
	}
	if mvSnap.Total != 1 || len(mvSnap.Items) != 1 || len(mvSnap.Items[0].Files) != 1 || len(mvSnap.Items[0].Files[0].Subtitles) != 1 {
		t.Fatalf("expected movie inline file & subtitle, got %+v", mvSnap)
	}

	// Verify SourceID filter works across all 5 GetSnapshot branches + ParentID child lookup.
	for _, tc := range []struct {
		name     string
		req      SnapshotRequest
		wantTot  int
	}{
		{"mixed_src1", SnapshotRequest{SourceID: "src1"}, 2},
		{"movie_src1", SnapshotRequest{Kind: db.KindMovie, SourceID: "src1"}, 1},
		{"show_src1", SnapshotRequest{Kind: db.KindShow, SourceID: "src1"}, 1},
		{"season_src1", SnapshotRequest{Kind: db.KindSeason, SourceID: "src1"}, 1},
		{"episode_src1", SnapshotRequest{Kind: db.KindEpisode, SourceID: "src1"}, 1},
		{"parent_show_src1", SnapshotRequest{ParentID: &showID, SourceID: "src1"}, 1},
		{"mixed_missing_src", SnapshotRequest{SourceID: "nonexistent"}, 0},
		{"parent_show_missing_src", SnapshotRequest{ParentID: &showID, SourceID: "nonexistent"}, 0},
		{"episode_missing_src", SnapshotRequest{Kind: db.KindEpisode, SourceID: "nonexistent"}, 0},
	} {
		got, err := feedSvc.GetSnapshot(p, tc.req)
		if err != nil {
			t.Fatalf("%s error: %v", tc.name, err)
		}
		if got.Total != tc.wantTot {
			t.Fatalf("%s expected total=%d, got %d", tc.name, tc.wantTot, got.Total)
		}
	}

	// Emit item upsert for show, season, and episode and verify GetChangesWithOpts(includeFiles=true).
	tx2, _ := store.DB().Begin()
	_, _ = db.AppendChangeTx(tx2, "hh1", nil, "item", strconv.FormatInt(showID, 10), "upsert", now)
	_, _ = db.AppendChangeTx(tx2, "hh1", nil, "item", strconv.FormatInt(seasonID, 10), "upsert", now)
	_, _ = db.AppendChangeTx(tx2, "hh1", nil, "item", strconv.FormatInt(epID, 10), "upsert", now)
	_ = tx2.Commit()

	chg, err := feedSvc.GetChangesWithOpts(p, 0, 50, true)
	if err != nil || len(chg.Changes) != 3 {
		t.Fatalf("unexpected changes with include_files: %+v err=%v", chg, err)
	}
	epData, ok := chg.Changes[2].Data.(ItemSummaryView)
	if !ok || epData.ShowWorkKey != "tmdb:show:100" || len(epData.Files) != 1 || epData.Files[0].RemoteID != "qk_ep2" || len(epData.Files[0].Subtitles) != 1 {
		t.Fatalf("expected episode change with ShowWorkKey and inline file+subtitle, got %+v", chg.Changes[2].Data)
	}

	// Verify GetItemDetailByWorkKey returns full show episodes + files.
	byWk, err := feedSvc.GetItemDetailByWorkKey(p, "tmdb:show:100")
	if err != nil {
		t.Fatalf("GetItemDetailByWorkKey failed: %v", err)
	}
	if len(byWk.Children) != 1 || len(byWk.Episodes) != 1 || len(byWk.Episodes[0].Files) != 1 {
		t.Fatalf("expected show detail children + episodes with files, got children=%d episodes=%d", len(byWk.Children), len(byWk.Episodes))
	}
}
