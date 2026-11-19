package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"testing"
	"time"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/vault"
)

func TestHomeResponseCacheETagAndInvalidation(t *testing.T) {
	dataDir := t.TempDir()
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	stMgr := storage.NewManager(nil, nil)
	defer stMgr.CloseAll()
	metaSvc := metadata.NewService(store)
	hub := events.NewHub()
	coord := library.NewCoordinator(store, stMgr, metaSvc, hub)
	srv := NewServer(store, auth.NewService(store), stMgr, metaSvc, hub, coord)
	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	jar, _ := cookiejar.New(nil)
	cli := &http.Client{Jar: jar}
	setupBody, _ := json.Marshal(map[string]string{"username": "admin", "password": "strongpass123"})
	resp, err := cli.Post(ts.URL+"/api/v1/auth/setup", "application/json", bytes.NewReader(setupBody))
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("setup failed: %v", err)
	}
	resp.Body.Close()

	getHome := func(ifNoneMatch string) (int, string, int64) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/home", nil)
		if ifNoneMatch != "" {
			req.Header.Set("If-None-Match", ifNoneMatch)
		}
		r, err := cli.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		var payload struct {
			Home struct {
				Counts map[string]int64 `json:"counts"`
			} `json:"home"`
		}
		if r.StatusCode == http.StatusOK {
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
		}
		return r.StatusCode, r.Header.Get("ETag"), payload.Home.Counts["movie"]
	}

	st, etag1, movies := getHome("")
	if st != http.StatusOK || etag1 == "" || movies != 0 {
		t.Fatalf("first home: status=%d etag=%q movies=%d", st, etag1, movies)
	}
	if st, etag, _ := getHome(etag1); st != http.StatusNotModified || etag != etag1 {
		t.Fatalf("expected 304 with same etag, got %d %q", st, etag)
	}

	// A background write (scanner/scraper style) followed by a hub event invalidates.
	now := time.Now().UnixMilli()
	res, err := store.DB().Exec(`INSERT INTO media_items(kind, library_type, title, sort_title, added_at, updated_at)
		VALUES ('movie', 'movie', 'Inception', 'Inception', ?, ?)`, now, now)
	if err != nil {
		t.Fatal(err)
	}
	itemID, _ := res.LastInsertId()
	hub.Publish("library_changed", map[string]any{"item_id": itemID})
	deadline := time.Now().Add(2 * time.Second)
	var etag2 string
	for {
		st, etag2, movies = getHome(etag1)
		if st == http.StatusOK || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if st != http.StatusOK || etag2 == etag1 || movies != 1 {
		t.Fatalf("expected refreshed home after hub event: status=%d etag=%q movies=%d", st, etag2, movies)
	}

	// Mutating API requests invalidate synchronously.
	favBody, _ := json.Marshal(map[string]bool{"favorite": true})
	r, err := cli.Post(ts.URL+"/api/v1/items/"+itoa(itemID)+"/favorite", "application/json", bytes.NewReader(favBody))
	if err != nil || r.StatusCode != http.StatusOK {
		t.Fatalf("favorite failed: %v status=%v", err, r)
	}
	r.Body.Close()
	if st, etag3, _ := getHome(etag2); st != http.StatusOK || etag3 == etag2 {
		t.Fatalf("expected new etag after mutation, got %d %q", st, etag3)
	}
}

func itoa(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}
