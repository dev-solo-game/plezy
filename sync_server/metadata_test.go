package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func boolPtr(v bool) *bool { return &v }
func strPtr(v string) *string { return &v }

func TestServerMetadataCacheCenterAndAdminControls(t *testing.T) {
	var tmdbHits atomic.Int64
	var tmdbSearchHits atomic.Int64
	var tmdbSeasonHits atomic.Int64
	var tmdbPersonHits atomic.Int64
	var bangumiHits atomic.Int64
	var returnServerError atomic.Bool

	fakeTMDB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if returnServerError.Load() && r.URL.Path != "/3/configuration" {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if r.URL.Query().Get("api_key") != "secret-v3-key" && r.Header.Get("Authorization") != "Bearer secret-v3-key" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/3/configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{"images": map[string]any{}})
		case "/3/search/movie":
			tmdbSearchHits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"results": []map[string]any{
					{
						"id":             438631,
						"title":          "沙丘",
						"original_title": "Dune",
						"release_date":   "2021-09-15",
						"overview":       "Arrakis",
						"poster_path":    "/dune_poster.jpg",
					},
				},
			})
		case "/3/movie/438631":
			tmdbHits.Add(1)
			time.Sleep(25 * time.Millisecond) // widen window to verify singleflight coalescing
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":            438631,
				"title":         "沙丘",
				"original_title": "Dune",
				"release_date":  "2021-09-15",
				"status":        "Released",
				"overview":      "Paul Atreides on Arrakis.",
				"tagline":       "Beyond fear, destiny awaits.",
				"runtime":       155,
				"vote_average":  7.8,
				"imdb_id":       "tt1160419",
				"poster_path":   "/dune_poster.jpg",
				"backdrop_path": "/dune_backdrop.jpg",
				"genres":        []map[string]any{{"id": 878, "name": "科幻"}},
				"images": map[string]any{
					"logos": []map[string]any{
						{"iso_639_1": "zh", "file_path": "/dune_logo_zh.png"},
					},
				},
				"alternative_titles": map[string]any{
					"titles": []map[string]any{{"title": "沙丘：第一部"}},
				},
				"credits": map[string]any{
					"crew": []map[string]any{
						{"id": 137427, "name": "Denis Villeneuve", "job": "Director", "profile_path": "/denis.jpg"},
					},
					"cast": []map[string]any{
						{"id": 1190668, "name": "Timothée Chalamet", "character": "Paul Atreides", "profile_path": "/timothee.jpg"},
					},
				},
			})
		case "/3/tv/94997":
			tmdbHits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":             94997,
				"name":           "龙之家族",
				"original_name":  "House of the Dragon",
				"first_air_date": "2022-08-21",
				"status":         "Returning Series",
				"overview":       "Targaryen civil war.",
				"poster_path":    "/hotd_poster.jpg",
				"backdrop_path":  "/hotd_bg.jpg",
				"genres":         []map[string]any{{"id": 18, "name": "剧情"}},
				"credits": map[string]any{
					"cast": []map[string]any{
						{"id": 1190668, "name": "Timothée Chalamet", "character": "Cameo", "profile_path": "/timothee_new.jpg"},
					},
				},
			})
		case "/3/tv/94997/season/1":
			tmdbSeasonHits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":        "第 1 季",
				"overview":    "Season 1 overview",
				"poster_path": "/hotd_s1.jpg",
				"episodes": []map[string]any{
					{
						"episode_number": 1,
						"name":           "龙之继承人",
						"overview":       "Viserys hosts a tournament.",
						"air_date":       "2022-08-21",
						"runtime":        66,
						"still_path":     "/hotd_s1e1.jpg",
						"vote_average":   8.1,
					},
				},
			})
		case "/3/person/1190668":
			tmdbPersonHits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":                   1190668,
				"name":                 "Timothée Chalamet",
				"profile_path":         "/timothee_full.jpg",
				"biography":            "Actor known for Dune.",
				"birthday":             "1995-12-27",
				"known_for_department": "Acting",
				"place_of_birth":       "New York City",
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer fakeTMDB.Close()

	fakeBangumi := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bangumiHits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v0/search/subjects":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{"id": 328609, "name": "葬送のフリーレン", "name_cn": "葬送的芙莉莲", "date": "2023-09-29"},
				},
			})
		case "/v0/subjects/328609":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":      328609,
				"name":    "葬送のフリーレン",
				"name_cn": "葬送的芙莉莲",
				"date":    "2023-09-29",
				"summary": "Magic journey.",
				"rating":  map[string]any{"score": 8.7},
				"images":  map[string]any{"large": "https://lain.bgm.tv/frieren.jpg"},
				"tags":    []map[string]any{{"name": "2023"}, {"name": "奇幻"}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer fakeBangumi.Close()

	var fakeNow atomic.Int64
	fakeNow.Store(time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC).UnixMilli())

	store, err := OpenSyncStore(t.TempDir(), WithBangumiBase(fakeBangumi.URL))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	store.metaNow = fakeNow.Load
	mux := NewSyncMux(store)

	// Register admin & ordinary user.
	adminReg := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username: "admin", AuthVerifier: "v1", KdfSalt: "s", KdfParams: KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1}, EncryptedMasterKeyBackup: "b", DeviceID: "d-adm",
	})
	var adminAuth AuthResponse
	_ = json.Unmarshal(adminReg.Body.Bytes(), &adminAuth)

	userReg := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username: "member", AuthVerifier: "v1", KdfSalt: "s", KdfParams: KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1}, EncryptedMasterKeyBackup: "b", DeviceID: "d-mem",
	})
	var userAuth AuthResponse
	_ = json.Unmarshal(userReg.Body.Bytes(), &userAuth)

	// 1. Before configuring TMDB API key: /metadata/config reports tmdb_configured=false & search returns 412.
	pubCfgRec := doReq(t, mux, "GET", "/api/v1/metadata/config", "", nil)
	var pubCfg MetadataPublicConfig
	_ = json.Unmarshal(pubCfgRec.Body.Bytes(), &pubCfg)
	if pubCfg.TmdbConfigured || !pubCfg.AllowPublicMetadata || !pubCfg.BangumiEnabled {
		t.Fatalf("unexpected initial public metadata config: %+v", pubCfg)
	}
	unconfRec := doReq(t, mux, "GET", "/api/v1/metadata/search?provider=tmdb&kind=movie&q=Dune", "", nil)
	if unconfRec.Code != http.StatusPreconditionFailed {
		t.Fatalf("expected 412 when TMDB key unconfigured, got %d %s", unconfRec.Code, unconfRec.Body.String())
	}

	// Non-admin cannot touch /api/v1/admin/metadata/*.
	nonAdminRec := doReq(t, mux, "GET", "/api/v1/admin/metadata/config", userAuth.AccessToken, nil)
	if nonAdminRec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for non-admin metadata config, got %d", nonAdminRec.Code)
	}

	// 2. Admin configures TMDB + image mirror + tests connection.
	updRec := doReq(t, mux, "POST", "/api/v1/admin/metadata/config", adminAuth.AccessToken, AdminMetadataConfigRequest{
		TmdbApiKey:    strPtr("secret-v3-key"),
		TmdbApiBase:   strPtr(fakeTMDB.URL + "/3"),
		TmdbImageBase: strPtr("https://img-mirror.example/t/p"),
	})
	if updRec.Code != http.StatusOK {
		t.Fatalf("admin metadata update failed: %d %s", updRec.Code, updRec.Body.String())
	}
	var admCfg AdminMetadataConfig
	_ = json.Unmarshal(updRec.Body.Bytes(), &admCfg)
	if !admCfg.TmdbApiKeySet || admCfg.TmdbApiKeyMasked != "****-key" {
		t.Fatalf("unexpected masked admin config: %+v", admCfg)
	}

	// Updating unrelated field without tmdb_api_key must preserve saved key.
	upd2Rec := doReq(t, mux, "POST", "/api/v1/admin/metadata/config", adminAuth.AccessToken, AdminMetadataConfigRequest{
		BangumiEnabled: boolPtr(true),
	})
	var admCfg2 AdminMetadataConfig
	_ = json.Unmarshal(upd2Rec.Body.Bytes(), &admCfg2)
	if !admCfg2.TmdbApiKeySet {
		t.Fatalf("expected tmdb key preserved when omitted")
	}

	testRec := doReq(t, mux, "POST", "/api/v1/admin/metadata/test", adminAuth.AccessToken, map[string]any{})
	if testRec.Code != http.StatusOK {
		t.Fatalf("admin metadata connection test failed: %d %s", testRec.Code, testRec.Body.String())
	}

	// 3. Concurrent anonymous requests for the same movie coalesce into 1 upstream TMDB hit (singleflight + SQLite cache).
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/movie/438631?lang=zh-CN", "", nil)
			if rec.Code != http.StatusOK {
				t.Errorf("concurrent work fetch failed: %d %s", rec.Code, rec.Body.String())
			}
		}()
	}
	wg.Wait()
	if tmdbHits.Load() != 1 {
		t.Fatalf("expected singleflight coalescing to hit TMDB exactly once, got %d", tmdbHits.Load())
	}

	// Second call hits DB cache (`cached: true`) and returns relative TMDB paths + server image_base.
	cachedWorkRec := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/movie/438631?lang=zh-CN", "", nil)
	var cachedWork MetadataWorkResponse
	_ = json.Unmarshal(cachedWorkRec.Body.Bytes(), &cachedWork)
	if !cachedWork.Cached || cachedWork.ImageBase != "https://img-mirror.example/t/p" {
		t.Fatalf("expected cached work with mirror image base, got %+v", cachedWork)
	}
	if cachedWork.Work.PosterPath == nil || *cachedWork.Work.PosterPath != "/dune_poster.jpg" {
		t.Fatalf("expected relative poster_path, got %v", cachedWork.Work.PosterPath)
	}
	if cachedWork.Work.LogoPath == nil || *cachedWork.Work.LogoPath != "/dune_logo_zh.png" {
		t.Fatalf("expected relative logo_path, got %v", cachedWork.Work.LogoPath)
	}

	// 4. Person endpoint upgrades stub credit row to full bio + hydrates updated profile_path across works!
	person1 := doReq(t, mux, "GET", "/api/v1/metadata/person/tmdb/1190668", "", nil)
	var p1Resp MetadataPersonResponse
	_ = json.Unmarshal(person1.Body.Bytes(), &p1Resp)
	if p1Resp.Cached || p1Resp.Person.Biography == nil || *p1Resp.Person.Biography != "Actor known for Dune." {
		t.Fatalf("unexpected person response: %+v", p1Resp)
	}
	person2 := doReq(t, mux, "GET", "/api/v1/metadata/person/tmdb/1190668", "", nil)
	var p2Resp MetadataPersonResponse
	_ = json.Unmarshal(person2.Body.Bytes(), &p2Resp)
	if !p2Resp.Cached || tmdbPersonHits.Load() != 1 {
		t.Fatalf("expected second person lookup cached, hits=%d", tmdbPersonHits.Load())
	}
	// Cached work 438631 now hydrates Timothee's updated profile_path (/timothee_full.jpg) from meta_people_cache!
	cachedWork2Rec := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/movie/438631?lang=zh-CN", "", nil)
	var cachedWork2 MetadataWorkResponse
	_ = json.Unmarshal(cachedWork2Rec.Body.Bytes(), &cachedWork2)
	foundTimothee := false
	for _, c := range cachedWork2.Work.Credits {
		if c.TmdbID != nil && *c.TmdbID == "1190668" && c.PhotoPath != nil && *c.PhotoPath == "/timothee_full.jpg" {
			foundTimothee = true
		}
	}
	if !foundTimothee {
		t.Fatalf("expected shared meta_people_cache portrait to hydrate into cached work credits: %+v", cachedWork2.Work.Credits)
	}

	// 5. Batch endpoint fetches show + season + movie concurrently, plus Bangumi works cleanly.
	batchRec := doReq(t, mux, "POST", "/api/v1/metadata/batch", "", MetadataBatchRequest{
		Lang: "zh-CN",
		Works: []MetadataBatchWorkRef{
			{Provider: "tmdb", Kind: "movie", ID: "438631"},
			{Provider: "tmdb", Kind: "show", ID: "94997"},
			{Provider: "bangumi", Kind: "show", ID: "328609"},
		},
		Seasons: []MetadataBatchSeasonRef{
			{Provider: "tmdb", ID: "94997", Season: 1},
		},
	})
	if batchRec.Code != http.StatusOK {
		t.Fatalf("batch failed: %d %s", batchRec.Code, batchRec.Body.String())
	}
	var batchResp MetadataBatchResponse
	_ = json.Unmarshal(batchRec.Body.Bytes(), &batchResp)
	if len(batchResp.Works) != 3 || len(batchResp.Seasons) != 1 || batchResp.Seasons["tmdb:94997:s1"].Episodes[0].StillPath == nil {
		t.Fatalf("unexpected batch response: %+v", batchResp)
	}
	if bangumiHits.Load() != 1 || tmdbSeasonHits.Load() != 1 {
		t.Fatalf("unexpected hit counts bangumi=%d season=%d", bangumiHits.Load(), tmdbSeasonHits.Load())
	}

	// Search cache hit check.
	s1 := doReq(t, mux, "GET", "/api/v1/metadata/search?provider=tmdb&kind=movie&q=Dune&year=2021", "", nil)
	s2 := doReq(t, mux, "GET", "/api/v1/metadata/search?provider=tmdb&kind=movie&q=dune&year=2021", "", nil)
	if s1.Code != http.StatusOK || s2.Code != http.StatusOK || tmdbSearchHits.Load() != 1 {
		t.Fatalf("expected normalized search query to share 1 upstream hit, got hits=%d", tmdbSearchHits.Load())
	}
	// refresh=1 bypasses search cache.
	_ = doReq(t, mux, "GET", "/api/v1/metadata/search?provider=tmdb&kind=movie&q=Dune&year=2021&refresh=1", "", nil)
	if tmdbSearchHits.Load() != 2 {
		t.Fatalf("expected refresh=1 to hit upstream, got %d", tmdbSearchHits.Load())
	}

	// 6. Toggle allow_public_metadata=false rejects anonymous callers with 401 while keeping authenticated access open.
	_ = doReq(t, mux, "POST", "/api/v1/admin/metadata/config", adminAuth.AccessToken, AdminMetadataConfigRequest{
		AllowPublicMetadata: boolPtr(false),
	})
	anonBlocked := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/movie/438631", "", nil)
	if anonBlocked.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 when allow_public_metadata=false, got %d", anonBlocked.Code)
	}
	memAllowed := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/movie/438631", userAuth.AccessToken, nil)
	if memAllowed.Code != http.StatusOK {
		t.Fatalf("expected 200 for authenticated user, got %d", memAllowed.Code)
	}

	// Re-enable public access and verify stale-if-error after >24h TTL on Returning Series 94997!
	_ = doReq(t, mux, "POST", "/api/v1/admin/metadata/config", adminAuth.AccessToken, AdminMetadataConfigRequest{
		AllowPublicMetadata: boolPtr(true),
	})
	fakeNow.Add((25 * time.Hour).Milliseconds())
	returnServerError.Store(true)
	staleShowRec := doReq(t, mux, "GET", "/api/v1/metadata/work/tmdb/show/94997?lang=zh-CN", "", nil)
	var staleShow MetadataWorkResponse
	_ = json.Unmarshal(staleShowRec.Body.Bytes(), &staleShow)
	if staleShowRec.Code != http.StatusOK || !staleShow.Cached || staleShow.Work.Title != "龙之家族" {
		t.Fatalf("expected stale-if-error fallback for expired returning show, got code=%d %+v", staleShowRec.Code, staleShow)
	}
	returnServerError.Store(false)

	// RunGC after 25h purges 24h search cache, but keeps >7d-grace old movie 438631 (30d TTL).
	if err := store.RunGC(fakeNow.Load()); err != nil {
		t.Fatalf("RunGC failed: %v", err)
	}
	statsAfterGC := store.GetPublicMetadataConfig().CacheStats
	if statsAfterGC.Searches != 0 || statsAfterGC.Works == 0 {
		t.Fatalf("expected expired searches pruned and long-TTL works retained, got %+v", statsAfterGC)
	}

	// Admin clear-cache clears remaining entries.
	clrRec := doReq(t, mux, "POST", "/api/v1/admin/metadata/clear-cache", adminAuth.AccessToken, MetadataClearCacheRequest{Scope: "all"})
	if clrRec.Code != http.StatusOK {
		t.Fatalf("clear cache failed: %d %s", clrRec.Code, clrRec.Body.String())
	}
	statsZero := store.GetPublicMetadataConfig().CacheStats
	if statsZero.Works != 0 || statsZero.Seasons != 0 || statsZero.People != 0 || statsZero.Searches != 0 {
		t.Fatalf("expected all metadata caches emptied, got %+v", statsZero)
	}
}
