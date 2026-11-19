package metadata

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/vault"
)

func openTestMetadataService(t *testing.T) (*Service, *db.Store) {
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
	return NewService(store), store
}

func TestMetadataSearchWorkAndImageCacheProxy(t *testing.T) {
	svc, store := openTestMetadataService(t)
	var apiHits atomic.Int32
	var imgHits atomic.Int32

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/movie":
			apiHits.Add(1)
			_, _ = w.Write([]byte(`{"results":[{"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27","poster_path":"/dune2.jpg"}]}`))
		case "/3/movie/693134":
			apiHits.Add(1)
			_, _ = w.Write([]byte(`{
				"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27",
				"overview":"续集","runtime":166,"vote_average":8.3,"poster_path":"/dune2.jpg","backdrop_path":"/dune2_bg.jpg",
				"genres":[{"id":878,"name":"科幻"}],
				"belongs_to_collection":{"id":726871,"name":"沙丘系列"},
				"credits":{"cast":[{"id":1190668,"name":"Timothee Chalamet","character":"Paul","profile_path":"/tim.jpg"}]}
			}`))
		case "/t/p/w500/dune2.jpg":
			imgHits.Add(1)
			w.Header().Set("Content-Type", "image/jpeg")
			_, _ = w.Write([]byte("\xff\xd8\xff\xe0FAKEJPEG"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	key := "test_tmdb_key"
	apiBase := srv.URL + "/3"
	imgBase := srv.URL + "/t/p"
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:    &key,
		TmdbAPIBase:   &apiBase,
		TmdbImageBase: &imgBase,
	}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	cands, err := svc.Search(ctx, "tmdb", "movie", "沙丘2", 2024, "zh-CN", false)
	if err != nil || len(cands) != 1 || cands[0].ID != "693134" {
		t.Fatalf("unexpected search results: %+v err=%v", cands, err)
	}
	// Second call hits cache
	_, err = svc.Search(ctx, "tmdb", "movie", "沙丘2", 2024, "zh-CN", false)
	if err != nil {
		t.Fatal(err)
	}
	if apiHits.Load() != 1 {
		t.Fatalf("expected cached search (1 upstream hit), got %d", apiHits.Load())
	}

	work, err := svc.GetWork(ctx, "tmdb", "movie", "693134", "zh-CN", false)
	if err != nil || work.Title != "沙丘2" || work.CollectionID == nil || *work.CollectionID != "726871" {
		t.Fatalf("unexpected work: %+v err=%v", work, err)
	}

	// Fetch and disk-cache image
	img1, err := svc.FetchRemoteImage(ctx, "/dune2.jpg", "w500")
	if err != nil || len(img1.Data) == 0 {
		t.Fatalf("fetch image failed: %v", err)
	}
	img2, err := svc.FetchRemoteImage(ctx, "/dune2.jpg", "w500")
	if err != nil || len(img2.Data) != len(img1.Data) {
		t.Fatalf("cached image mismatch: %v", err)
	}
	if imgHits.Load() != 1 {
		t.Fatalf("expected 1 upstream image hit, got %d", imgHits.Load())
	}

	// SSRF protection: reject unapproved hosts
	if _, err := svc.FetchRemoteImage(ctx, "http://127.0.0.1:8080/internal.png", "w500"); err == nil {
		t.Fatal("expected unapproved host to be rejected")
	}
}
