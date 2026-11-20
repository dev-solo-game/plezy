package identify

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/vault"
)

func seedQueueHouseholdAndFile(t *testing.T, store *db.Store, hhID, srcID, path string) int64 {
	t.Helper()
	now := store.NowMs()
	_, _ = store.DB().Exec(`INSERT OR IGNORE INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES (?, ?, 's', 'h', ?, ?)`,
		"acc_"+hhID, "u_"+hhID, now, now)
	_, _ = store.DB().Exec(`INSERT OR IGNORE INTO households(id, owner_account_id, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
		hhID, "acc_"+hhID, "HH "+hhID, now, now)
	_, _ = store.DB().Exec(`INSERT OR IGNORE INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES (?, ?, 'Owner', 'owner', 63, ?, ?)`,
		"mem_"+hhID, hhID, now, now)
	_, _ = store.DB().Exec(`INSERT OR IGNORE INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES (?, ?, 'webdav', 'NAS', ?, ?, 'dev', ?, ?)`,
		srcID, hhID, "key:"+srcID, "mem_"+hhID, now, now)

	res, err := store.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, path, role, state, match_state, added_at, updated_at, last_seen_at)
		VALUES (?, ?, ?, 'video', 'active', 'pending', ?, ?, ?)`,
		hhID, srcID, path, now, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func TestRoundRobinFairnessBackoffAndRetry(t *testing.T) {
	var tmdbDown atomic.Bool
	var mu sync.Mutex
	var queryOrder []string

	mockSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/3/search/movie" {
			q := r.URL.Query().Get("query")
			mu.Lock()
			queryOrder = append(queryOrder, q)
			mu.Unlock()
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"results":[{"id":27205,"title":"` + q + `","original_title":"` + q + `","release_date":"2010-01-01"}]}`))
			return
		}
		if r.URL.Path == "/3/movie/27205" {
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"id":27205,"title":"Matched Film","release_date":"2010-01-01"}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
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

	tmdbKey := "k"
	tmdbBase := mockSrv.URL + "/3"
	f := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		DoubanEnabled:  &f,
		BangumiEnabled: &f,
		AniListEnabled: &f,
		ImdbEnabled:    &f,
	}); err != nil {
		t.Fatal(err)
	}

	curTime := time.Unix(1700000000, 0)
	var timeMu sync.Mutex
	clockFn := func() time.Time {
		timeMu.Lock()
		defer timeMu.Unlock()
		return curTime
	}
	advanceTime := func(d time.Duration) {
		timeMu.Lock()
		curTime = curTime.Add(d)
		timeMu.Unlock()
	}

	metaSvc := metadata.NewService(store)
	sc := library.NewScraper(store, metaSvc)
	hub := events.NewHub()
	q := NewQueue(store, sc, hub, WithClock(clockFn), WithMaxAttempts(3), WithBaseBackoff(5*time.Second))

	// Household A gets 2 jobs, Household B gets 1 job.
	seedQueueHouseholdAndFile(t, store, "hh-a", "src-a", "/Movies/AlphaFilm1.2010.mkv")
	seedQueueHouseholdAndFile(t, store, "hh-a", "src-a", "/Movies/AlphaFilm2.2010.mkv")
	seedQueueHouseholdAndFile(t, store, "hh-b", "src-b", "/Movies/BetaFilm1.2010.mkv")

	_, _, gkA1 := library.ParseAndGroup("src-a", "/Movies/AlphaFilm1.2010.mkv")
	_, _, gkA2 := library.ParseAndGroup("src-a", "/Movies/AlphaFilm2.2010.mkv")
	_, _, gkB1 := library.ParseAndGroup("src-b", "/Movies/BetaFilm1.2010.mkv")

	_ = q.Enqueue("hh-a", gkA1, "new", 0)
	_ = q.Enqueue("hh-a", gkA2, "new", 0)
	_ = q.Enqueue("hh-b", gkB1, "new", 0)

	// Pause blocks processing; Resume re-enables.
	q.Pause()
	if did, _ := q.ProcessOne(context.Background()); did {
		t.Fatalf("expected ProcessOne no-op when paused")
	}
	q.Resume()

	// Process 3 jobs sequentially -> order must interleave hh-a, hh-b, hh-a!
	for i := 0; i < 3; i++ {
		did, err := q.ProcessOne(context.Background())
		if err != nil || !did {
			t.Fatalf("ProcessOne #%d failed: did=%v err=%v", i, did, err)
		}
	}
	mu.Lock()
	if len(queryOrder) < 3 || queryOrder[0] != "AlphaFilm1" || queryOrder[1] != "BetaFilm1" || queryOrder[2] != "AlphaFilm2" {
		t.Fatalf("expected round-robin [AlphaFilm1 BetaFilm1 AlphaFilm2], got %v", queryOrder)
	}
	mu.Unlock()

	// Test exponential backoff & maxAttempts -> unmatched + admin RetryFailed.
	tmdbDown.Store(true)
	failFileID := seedQueueHouseholdAndFile(t, store, "hh-c", "src-c", "/Movies/OutageFilm.2010.mkv")
	_, _, gkFail := library.ParseAndGroup("src-c", "/Movies/OutageFilm.2010.mkv")
	_ = q.Enqueue("hh-c", gkFail, "new", 0)

	// Attempt 1 fails -> backoff 5s.
	_, _ = q.ProcessOne(context.Background())
	if did, _ := q.ProcessOne(context.Background()); did {
		t.Fatalf("job should be backed off before 5s")
	}
	advanceTime(6 * time.Second)
	// Attempt 2 fails -> backoff 10s.
	_, _ = q.ProcessOne(context.Background())
	advanceTime(6 * time.Second)
	if did, _ := q.ProcessOne(context.Background()); did {
		t.Fatalf("job should still be backed off at +6s (needs 10s)")
	}
	advanceTime(5 * time.Second)
	// Attempt 3 fails -> status='failed' & file marked unmatched.
	_, _ = q.ProcessOne(context.Background())

	var mfState, qStatus, qErrCode string
	_ = store.ReadDB().QueryRow(`SELECT match_state FROM media_files WHERE id = ?`, failFileID).Scan(&mfState)
	_ = store.ReadDB().QueryRow(`SELECT status, last_error_code FROM identify_queue WHERE household_id = 'hh-c' AND group_key = ?`, gkFail).Scan(&qStatus, &qErrCode)
	if mfState != db.MatchUnmatched || qStatus != "failed" || qErrCode != "tmdb_upstream" {
		t.Fatalf("unexpected failed state: mf=%s queue=%s code=%s", mfState, qStatus, qErrCode)
	}

	stats, err := q.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if stats.Failed != 1 || stats.Done != 3 {
		t.Fatalf("unexpected queue stats: %+v", stats)
	}

	// TMDB comes back -> RetryFailed resets and succeeds.
	tmdbDown.Store(false)
	n, err := q.RetryFailed("hh-c")
	if err != nil || n != 1 {
		t.Fatalf("RetryFailed expected 1 row, got n=%d err=%v", n, err)
	}
	if did, err := q.ProcessOne(context.Background()); err != nil || !did {
		t.Fatalf("retry ProcessOne failed: did=%v err=%v", did, err)
	}
	_ = store.ReadDB().QueryRow(`SELECT match_state FROM media_files WHERE id = ?`, failFileID).Scan(&mfState)
	if mfState != db.MatchMatched {
		t.Fatalf("expected file matched after recovery retry, got %s", mfState)
	}
}
