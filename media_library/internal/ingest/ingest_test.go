package ingest_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/source"
	"plezy/media_library/internal/vault"
)

type testEnv struct {
	store   *db.Store
	hub     *events.Hub
	accSvc  *account.Service
	srcSvc  *source.Service
	ingSvc  *ingest.Service
	advance func(time.Duration)
	nowFn   func() time.Time
}

func openTestEnv(t *testing.T) *testEnv {
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

	now := time.Unix(1700000000, 0)
	nowFn := func() time.Time { return now }
	advance := func(d time.Duration) { now = now.Add(d) }

	hub := events.NewHub()
	limiter := security.NewLoginLimiter()
	accSvc := account.NewService(store, limiter)
	accSvc.SetClock(nowFn)
	srcSvc := source.NewService(store, hub)
	srcSvc.SetClock(nowFn)
	ingSvc := ingest.NewService(store, hub, limiter)
	ingSvc.SetClock(nowFn)

	return &testEnv{
		store:   store,
		hub:     hub,
		accSvc:  accSvc,
		srcSvc:  srcSvc,
		ingSvc:  ingSvc,
		advance: advance,
		nowFn:   nowFn,
	}
}

func (e *testEnv) registerDevice(t *testing.T, username, deviceClass, ip string) *account.Principal {
	t.Helper()
	res, err := e.accSvc.Register(account.RegisterRequest{
		Username: username,
		Password: "Password123!",
		Device:   account.DeviceInput{Class: deviceClass, Platform: "testos", Name: username + "-" + deviceClass},
	}, ip)
	if err != nil {
		t.Fatalf("register %s: %v", username, err)
	}
	return res.Principal
}

func (e *testEnv) loginDevice(t *testing.T, username, deviceClass, ip string) *account.Principal {
	t.Helper()
	res, err := e.accSvc.Login(account.LoginRequest{
		Username: username,
		Password: "Password123!",
		Device:   account.DeviceInput{Class: deviceClass, Platform: "testos", Name: username + "-" + deviceClass},
	}, ip)
	if err != nil {
		t.Fatalf("login %s (%s): %v", username, deviceClass, err)
	}
	return res.Principal
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func i64(v int64) *int64 { return &v }
func sPtr(v string) *string {
	return &v
}

func TestConcurrentDualDeviceScanAndTimestampMissingDerivation(t *testing.T) {
	env := openTestEnv(t)
	pc1 := env.registerDevice(t, "dual_owner", db.DeviceClassDesktop, "10.0.0.1")
	pc2 := env.loginDevice(t, "dual_owner", db.DeviceClassDesktop, "10.0.0.2")

	src, err := env.srcSvc.CreateSource(pc1, source.CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Quark Dual",
		IdentityKey: "qk_dual",
		Ciphertext:  "c",
		Folders:     []source.FolderInput{{Path: "/Movies"}},
	}, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Prior scan seeds genuinely absent file Z at T_init.
	initSess, err := env.ingSvc.CreateSession(pc1, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.SubmitBatch(pc1, initSess.ID, ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{
			{Path: "/Movies/OldGone (2020).mkv", RemoteID: sPtr("fid-z"), Size: i64(100), MtimeS: i64(10)},
		},
	}, "10.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.CompleteSession(pc1, initSess.ID, ingest.CompleteSessionRequest{Complete: true, NewWatermark: 50}, "10.0.0.1"); err != nil {
		t.Fatal(err)
	}

	// Concurrent full scans: PC1 starts at T0, PC2 starts at T1 (neither blocks the other).
	env.advance(10 * time.Second)
	s1, err := env.ingSvc.CreateSession(pc1, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	env.advance(2 * time.Second)
	s2, err := env.ingSvc.CreateSession(pc2, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.0.0.2")
	if err != nil {
		t.Fatal(err)
	}

	// Both devices report shared file X (fid-x), plus PC2 doesn't see PC1's Y yet, then PC1 reports Y.
	env.advance(2 * time.Second)
	if _, err := env.ingSvc.SubmitBatch(pc2, s2.ID, ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{
			{Path: "/Movies/SharedX (2024).mkv", RemoteID: sPtr("fid-x"), Size: i64(200), MtimeS: i64(20)},
		},
	}, "10.0.0.2"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.SubmitBatch(pc1, s1.ID, ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{
			{Path: "/Movies/SharedX (2024).mkv", RemoteID: sPtr("fid-x"), Size: i64(200), MtimeS: i64(20)},
			{Path: "/Movies/OnlyY (2024).mkv", RemoteID: sPtr("fid-y"), Size: i64(300), MtimeS: i64(30)},
		},
	}, "10.0.0.1"); err != nil {
		t.Fatal(err)
	}

	// PC2 completes first without reporting OnlyY, yet OnlyY was seen at T2 >= s2.StartedAt -> must stay active!
	env.advance(2 * time.Second)
	if res2, err := env.ingSvc.CompleteSession(pc2, s2.ID, ingest.CompleteSessionRequest{Complete: true, NewWatermark: 500}, "10.0.0.2"); err != nil {
		t.Fatal(err)
	} else if res2.MissingCount != 1 { // Only OldGone (fid-z) should be missing
		t.Fatalf("expected 1 missing file (fid-z) after PC2 completes, got %d", res2.MissingCount)
	}

	// PC1 later finishes with a stale lower watermark (300 < 500) -> watermark must stay 500!
	res1, err := env.ingSvc.CompleteSession(pc1, s1.ID, ingest.CompleteSessionRequest{Complete: true, NewWatermark: 300}, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if res1.NewWatermark != 500 {
		t.Fatalf("expected monotonic watermark 500, got %d", res1.NewWatermark)
	}

	var totalX, yState, zState int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = ? AND remote_id = 'fid-x'`, pc1.HouseholdID).Scan(&totalX)
	if totalX != 1 {
		t.Fatalf("expected exactly 1 deduplicated row for fid-x, got %d", totalX)
	}
	var stY, stZ string
	_ = env.store.ReadDB().QueryRow(`SELECT state FROM media_files WHERE household_id = ? AND remote_id = 'fid-y'`, pc1.HouseholdID).Scan(&stY)
	_ = env.store.ReadDB().QueryRow(`SELECT state FROM media_files WHERE household_id = ? AND remote_id = 'fid-z'`, pc1.HouseholdID).Scan(&stZ)
	_, _ = yState, zState
	if stY != db.FileStateActive {
		t.Fatalf("expected fid-y to remain active under concurrent scan, got %q", stY)
	}
	if stZ != db.FileStateMissing {
		t.Fatalf("expected fid-z to be missing, got %q", stZ)
	}
}

func TestBatchIdempotencyUnchangedNoopMoveSidecarsSubtitlesAndDebounce(t *testing.T) {
	env := openTestEnv(t)
	pc := env.registerDevice(t, "ingest_details", db.DeviceClassDesktop, "10.1.0.1")

	src, err := env.srcSvc.CreateSource(pc, source.CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Quark TV",
		IdentityKey: "qk_tv",
		Ciphertext:  "c",
		Folders:     []source.FolderInput{{Path: "/TV", ExcludePaths: []string{"/TV/Excluded"}}},
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}

	sess, err := env.ingSvc.CreateSession(pc, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}

	nfoBytes := []byte(`<tvshow><title>Frieren</title></tvshow>`)
	nfoHash := sha256Hex(nfoBytes)

	batchReq := ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{
			{Path: "/TV/Frieren/Season 01/Frieren - S01E01.mkv", RemoteID: sPtr("qk-e1"), Size: i64(1000), MtimeS: i64(100)},
			{Path: "/TV/Frieren/Season 01/Frieren - S01E02.mkv", RemoteID: sPtr("qk-e2"), Size: i64(1000), MtimeS: i64(100)},
			{Path: "/TV/Frieren/Season 01/Frieren - S01E01.zh-cn.srt", RemoteID: sPtr("qk-sub1"), Size: i64(50), MtimeS: i64(100)},
			{Path: "/TV/Frieren/Season 01/Frieren - S01E01.nfo", RemoteID: sPtr("qk-nfo1"), Size: i64(int64(len(nfoBytes))), MtimeS: i64(100), SidecarHash: "sha256:" + nfoHash},
			// Filtered out: sample clip, skipped folder (.trash), excluded path, non-media txt
			{Path: "/TV/Frieren/Season 01/Frieren.sample.mkv", RemoteID: sPtr("qk-samp"), Size: i64(10), MtimeS: i64(1)},
			{Path: "/TV/.trash/Deleted.mkv", RemoteID: sPtr("qk-trash"), Size: i64(10), MtimeS: i64(1)},
			{Path: "/TV/Excluded/Hidden.mkv", RemoteID: sPtr("qk-exc"), Size: i64(10), MtimeS: i64(1)},
			{Path: "/TV/Frieren/readme.txt", RemoteID: sPtr("qk-txt"), Size: i64(10), MtimeS: i64(1)},
		},
	}

	rec1, err := env.ingSvc.SubmitBatch(pc, sess.ID, batchReq, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if rec1.Added != 4 || rec1.Ignored != 4 || len(rec1.MissingSidecars) != 1 || rec1.MissingSidecars[0] != nfoHash {
		t.Fatalf("unexpected batch 1 receipt: %+v", rec1)
	}

	// Idempotent retry of batch_no=1 returns exact same receipt without extra change_log rows
	var changeCntBefore int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = ?`, pc.HouseholdID).Scan(&changeCntBefore)
	recRetry, err := env.ingSvc.SubmitBatch(pc, sess.ID, batchReq, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}
	var changeCntAfter int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = ?`, pc.HouseholdID).Scan(&changeCntAfter)
	if recRetry.Added != rec1.Added || changeCntAfter != changeCntBefore {
		t.Fatalf("batch retry should be a strict no-op: recRetry=%+v changes %d->%d", recRetry, changeCntBefore, changeCntAfter)
	}

	// Verify subtitle & per-video NFO owner_file_id and 10s debounced single group_key in identify_queue
	ep1ID := rec1.FileIDs["/TV/Frieren/Season 01/Frieren - S01E01.mkv"]
	var subOwner, nfoOwner int64
	var subLang string
	_ = env.store.ReadDB().QueryRow(`SELECT owner_file_id, COALESCE(language, '') FROM media_files WHERE id = ?`, rec1.FileIDs["/TV/Frieren/Season 01/Frieren - S01E01.zh-cn.srt"]).Scan(&subOwner, &subLang)
	_ = env.store.ReadDB().QueryRow(`SELECT owner_file_id FROM media_files WHERE id = ?`, rec1.FileIDs["/TV/Frieren/Season 01/Frieren - S01E01.nfo"]).Scan(&nfoOwner)
	if subOwner != ep1ID || nfoOwner != ep1ID || subLang != "cn" {
		t.Fatalf("sidecar ownership mismatch: ep1=%d subOwner=%d lang=%q nfoOwner=%d", ep1ID, subOwner, subLang, nfoOwner)
	}

	var iqCount int
	var gKey string
	var notBefore int64
	if err := env.store.ReadDB().QueryRow(`SELECT COUNT(*), MIN(group_key), MIN(not_before) FROM identify_queue WHERE household_id = ?`, pc.HouseholdID).Scan(&iqCount, &gKey, &notBefore); err != nil {
		t.Fatal(err)
	}
	wantGroupKey := src.ID + ":dir:/TV/Frieren"
	if iqCount != 1 || gKey != wantGroupKey || notBefore != env.nowFn().UnixMilli()+10000 {
		t.Fatalf("unexpected identify_queue state: cnt=%d key=%q want=%q notBefore=%d", iqCount, gKey, wantGroupKey, notBefore)
	}

	// Sidecar upload + SidecarReader check
	exists, err := env.ingSvc.SidecarExists(pc, nfoHash)
	if err != nil || exists {
		t.Fatalf("expected sidecar not yet uploaded, exists=%v err=%v", exists, err)
	}
	if err := env.ingSvc.PutSidecar(pc, nfoHash, "nfo", "text/xml", nfoBytes); err != nil {
		t.Fatalf("PutSidecar failed: %v", err)
	}
	readTxt, err := env.ingSvc.ReadText(context.Background(), pc.HouseholdID, nfoHash)
	if err != nil || readTxt != string(nfoBytes) {
		t.Fatalf("ReadText mismatch: %q err=%v", readTxt, err)
	}

	// Re-report ep1 unchanged -> unchanged++, zero new change_log rows
	// Seed item_id on ep1 first to verify remote_id move preserves item_id!
	itemRes, err := env.store.DB().Exec(`
		INSERT INTO media_items(household_id, work_key, kind, library_type, title, sort_title, added_at, updated_at)
		VALUES (?, 'tmdb:tv:999', 'episode', 'anime', 'Ep 1', 'Ep 1', 1, 1)`,
		pc.HouseholdID,
	)
	if err != nil {
		t.Fatal(err)
	}
	seededItemID, _ := itemRes.LastInsertId()
	if _, err := env.store.DB().Exec(`
		UPDATE media_files SET item_id = ?, match_state = 'matched' WHERE id = ?`,
		seededItemID, ep1ID,
	); err != nil {
		t.Fatal(err)
	}

	env.advance(5 * time.Second)
	recUnchanged, err := env.ingSvc.SubmitBatch(pc, sess.ID, ingest.SubmitBatchRequest{
		BatchNo: 2,
		Upserts: []ingest.BatchFileItem{
			{Path: "/TV/Frieren/Season 01/Frieren - S01E01.mkv", RemoteID: sPtr("qk-e1"), Size: i64(1000), MtimeS: i64(100)},
		},
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}
	var changeCntAfterUnchanged int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = ?`, pc.HouseholdID).Scan(&changeCntAfterUnchanged)
	if recUnchanged.Unchanged != 1 || changeCntAfterUnchanged != changeCntAfter {
		t.Fatalf("unchanged re-report should emit 0 changes: rec=%+v changes %d->%d", recUnchanged, changeCntAfter, changeCntAfterUnchanged)
	}

	// Move ep1 to a renamed folder with same remote_id -> updates path in-place and preserves item_id
	recMove, err := env.ingSvc.SubmitBatch(pc, sess.ID, ingest.SubmitBatchRequest{
		BatchNo: 3,
		Upserts: []ingest.BatchFileItem{
			{Path: "/TV/Frieren (2023)/Season 01/Frieren - S01E01.mkv", RemoteID: sPtr("qk-e1"), Size: i64(1000), MtimeS: i64(100)},
		},
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if recMove.Changed != 1 || recMove.FileIDs["/TV/Frieren (2023)/Season 01/Frieren - S01E01.mkv"] != ep1ID {
		t.Fatalf("move should update existing row %d in-place: %+v", ep1ID, recMove)
	}
	var keptItemID int64
	var keptMatchState string
	if err := env.store.ReadDB().QueryRow(`SELECT item_id, match_state FROM media_files WHERE id = ?`, ep1ID).Scan(&keptItemID, &keptMatchState); err != nil {
		t.Fatal(err)
	}
	if keptItemID != seededItemID || keptMatchState != db.MatchMatched {
		t.Fatalf("expected item_id %d preserved on remote_id move, got item=%d state=%q", seededItemID, keptItemID, keptMatchState)
	}
}

func TestPartialStaleBulkDeleteProtectionDeviceRulesQuotasAndSoftDelete(t *testing.T) {
	env := openTestEnv(t)
	phone := env.registerDevice(t, "bulk_owner", db.DeviceClassPhone, "10.2.0.1")
	tv := env.loginDevice(t, "bulk_owner", db.DeviceClassTV, "10.2.0.2")
	web := env.loginDevice(t, "bulk_owner", db.DeviceClassWeb, "10.2.0.3")

	src, err := env.srcSvc.CreateSource(phone, source.CreateSourceRequest{
		Kind:        db.SourceKindWebDAV,
		Name:        "Phone NAS",
		IdentityKey: "wd_bulk",
		Ciphertext:  "c",
		Folders:     []source.FolderInput{{Path: "/Bulk"}},
	}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Device scan rules (D5 / V1-6)
	if _, err := env.ingSvc.CreateSession(web, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeIncremental}, "10.2.0.3"); !errors.Is(err, ingest.ErrScanNotAllowed) {
		t.Fatalf("expected Web ErrScanNotAllowed, got %v", err)
	}
	if _, err := env.ingSvc.CreateSession(tv, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.2.0.2"); !errors.Is(err, ingest.ErrFullScanNotAllowed) {
		t.Fatalf("expected TV full scan ErrFullScanNotAllowed, got %v", err)
	}
	if tvInc, err := env.ingSvc.CreateSession(tv, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeIncremental}, "10.2.0.2"); err != nil {
		t.Fatalf("TV incremental scan should be allowed: %v", err)
	} else {
		// Stale test: advance 31 min -> MarkStaleSessions -> CompleteSession becomes partial
		env.advance(31 * time.Minute)
		if n, err := env.ingSvc.MarkStaleSessions(); err != nil || n != 1 {
			t.Fatalf("expected 1 stale session marked, got n=%d err=%v", n, err)
		}
		if _, err := env.ingSvc.SubmitBatch(tv, tvInc.ID, ingest.SubmitBatchRequest{BatchNo: 1}, "10.2.0.2"); !errors.Is(err, ingest.ErrSessionNotRunning) {
			t.Fatalf("expected ErrSessionNotRunning on stale session batch, got %v", err)
		}
	}

	// Seed 105 files in /Bulk
	s1, err := env.ingSvc.CreateSession(phone, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	var items []ingest.BatchFileItem
	for i := 1; i <= 105; i++ {
		items = append(items, ingest.BatchFileItem{
			Path:   fmt.Sprintf("/Bulk/Movie %03d (2024).mkv", i),
			Size:   i64(100),
			MtimeS: i64(10),
		})
	}
	if _, err := env.ingSvc.SubmitBatch(phone, s1.ID, ingest.SubmitBatchRequest{BatchNo: 1, Upserts: items}, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.CompleteSession(phone, s1.ID, ingest.CompleteSessionRequest{Complete: true}, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}

	// Complete=false (cancelled) must NOT mark missing even if empty
	env.advance(5 * time.Second)
	sCancel, err := env.ingSvc.CreateSession(phone, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if res, err := env.ingSvc.CancelSession(phone, sCancel.ID, "10.2.0.1"); err != nil || res.Status != ingest.SessionPartial {
		t.Fatalf("CancelSession unexpected: %+v err=%v", res, err)
	}

	// Full scan reporting ONLY 1 file leaves 104 missing (>100 and >50%) -> triggers pending_deletions!
	env.advance(5 * time.Second)
	s2, err := env.ingSvc.CreateSession(phone, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFull}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.SubmitBatch(phone, s2.ID, ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{items[0]},
	}, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}
	compRes, err := env.ingSvc.CompleteSession(phone, s2.ID, ingest.CompleteSessionRequest{Complete: true}, "10.2.0.1")
	if err != nil || compRes.PendingDeletionID == "" {
		t.Fatalf("expected PendingDeletionID created, got %+v err=%v", compRes, err)
	}

	// Files remain active until confirmed; re-reporting items[1] clears it from pending_deletion_files
	var activeCnt int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE source_id = ? AND state = 'active'`, src.ID).Scan(&activeCnt)
	if activeCnt != 105 {
		t.Fatalf("expected all 105 files still active while pending confirmation, got %d", activeCnt)
	}

	env.advance(5 * time.Second)
	s3, err := env.ingSvc.CreateSession(phone, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeFolder, FolderID: src.Folders[0].ID}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.SubmitBatch(phone, s3.ID, ingest.SubmitBatchRequest{BatchNo: 1, Upserts: []ingest.BatchFileItem{items[1]}}, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.CancelSession(phone, s3.ID, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}

	// Confirm pending deletion -> remaining 103 files become missing (items[0] and items[1] stay active)
	if _, err := env.ingSvc.ConfirmPendingDeletion(phone, compRes.PendingDeletionID, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}
	var missingCnt int
	_ = env.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE source_id = ? AND state = 'missing'`, src.ID).Scan(&missingCnt)
	if missingCnt != 103 {
		t.Fatalf("expected 103 missing after confirmation (2 revived), got %d", missingCnt)
	}

	// Quota checks: quota_max_files & quota_max_sidecar_bytes
	if _, err := env.store.DB().Exec(`UPDATE households SET quota_max_files = 105, quota_max_sidecar_bytes = 10 WHERE id = ?`, phone.HouseholdID); err != nil {
		t.Fatal(err)
	}
	sQuota, _ := env.ingSvc.CreateSession(phone, src.ID, ingest.CreateSessionRequest{Type: ingest.ScanTypeIncremental}, "10.2.0.1")
	_, err = env.ingSvc.SubmitBatch(phone, sQuota.ID, ingest.SubmitBatchRequest{
		BatchNo: 1,
		Upserts: []ingest.BatchFileItem{{Path: "/Bulk/Movie 999 (2024).mkv", Size: i64(10), MtimeS: i64(1)}},
	}, "10.2.0.1")
	var qErr *ingest.QuotaExceededError
	if !errors.As(err, &qErr) || qErr.Quota != "files" {
		t.Fatalf("expected quota_max_files QuotaExceededError, got %v", err)
	}
	smallNfo := []byte("<movie><title>TinyTooBig</title></movie>")
	err = env.ingSvc.PutSidecar(phone, sha256Hex(smallNfo), "nfo", "text/xml", smallNfo)
	if !errors.As(err, &qErr) || qErr.Quota != "sidecar_bytes" {
		t.Fatalf("expected sidecar_bytes QuotaExceededError, got %v", err)
	}

	// G15 soft-deleted source mid-scan -> SubmitBatch returns ErrSourceDeleted without writing data
	if err := env.srcSvc.DeleteSource(phone, src.ID, "10.2.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.ingSvc.SubmitBatch(phone, sQuota.ID, ingest.SubmitBatchRequest{
		BatchNo: 2,
		Upserts: []ingest.BatchFileItem{{Path: "/Bulk/NewAfterDelete.mkv", Size: i64(10), MtimeS: i64(1)}},
	}, "10.2.0.1"); !errors.Is(err, ingest.ErrSourceDeleted) && !strings.Contains(err.Error(), "deleted") {
		t.Fatalf("expected ErrSourceDeleted after source deletion, got %v", err)
	}
}
