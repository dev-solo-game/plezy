package feed

import (
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
