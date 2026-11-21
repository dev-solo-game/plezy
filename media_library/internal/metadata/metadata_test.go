package metadata

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/vault"
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

func TestMultiSourceFetchersFindAndTmdbErrorStrictness(t *testing.T) {
	svc, store := openTestMetadataService(t)
	var failTmdb atomic.Bool

	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/3/search/movie":
			if failTmdb.Load() {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case r.URL.Path == "/3/find/tt9999999":
			if failTmdb.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"tv_results":[{"id":230311,"name":"爱情有烟火","original_name":"爱情有烟火","first_air_date":"2026-02-01"}],"movie_results":[]}`))
		case r.URL.Path == "/douban/search/subjects":
			if r.Header.Get("Cookie") != "bid=testcookie" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"tv","target":{"id":"36283066","title":"爱情有烟火","card_subtitle":"2026 / 中国大陆 / 爱情","cover_url":"https://img9.doubanio.com/p1.jpg"}}]}}`))
		case r.URL.Path == "/douban/tv/36283066":
			_, _ = w.Write([]byte(`{"id":"36283066","title":"爱情有烟火","original_title":"爱情有烟火","aka":["我们住在一起"],"year":"2026","pubdate":["2026-02-01(中国大陆)"],"intro":"租房故事","rating":{"value":7.8},"genres":["剧情","爱情"],"imdb":"tt9999999","pic":{"large":"https://img9.doubanio.com/p1.jpg"}}`))
		case r.URL.Path == "/anilist":
			_, _ = w.Write([]byte(`{"data":{"Page":{"media":[{"id":154587,"title":{"romaji":"Sousou no Frieren","english":"Frieren","native":"葬送のフリーレン"},"seasonYear":2023,"coverImage":{"extraLarge":"https://s4.anilist.co/f.jpg"}}]},"Media":{"id":154587,"title":{"romaji":"Sousou no Frieren","english":"Frieren","native":"葬送のフリーレン"},"synonyms":["葬送的芙莉莲"],"seasonYear":2023,"averageScore":91,"duration":24,"genres":["Adventure","Fantasy"],"studios":{"nodes":[{"name":"Madhouse"}]}}}}`))
		case r.URL.Path == "/imdb/search/titles":
			_, _ = w.Write([]byte(`{"titles":[{"id":"tt1375666","type":"movie","primaryTitle":"Inception","startYear":2010,"primaryImage":{"url":"https://m.media-amazon.com/inc.jpg"}}]}`))
		case r.URL.Path == "/imdb/titles/tt1375666":
			_, _ = w.Write([]byte(`{"id":"tt1375666","type":"movie","primaryTitle":"Inception","originalTitle":"Inception","startYear":2010,"runtimeSeconds":8880,"rating":{"aggregateRating":8.8},"genres":["Sci-Fi"],"primaryImage":{"url":"https://m.media-amazon.com/inc.jpg"}}`))
		case r.URL.Path == "/tvdb/login":
			_, _ = w.Write([]byte(`{"data":{"token":"tvdb-jwt-123"}}`))
		case r.URL.Path == "/tvdb/search":
			if r.Header.Get("Authorization") != "Bearer tvdb-jwt-123" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte(`{"data":[{"tvdb_id":"12345","name":"Test Series","translations":{"zho":"测试剧集"},"year":"2024"}]}`))
		case r.URL.Path == "/tvdb/series/12345/extended":
			_, _ = w.Write([]byte(`{"data":{"id":12345,"name":"Test Series","firstAired":"2024-03-01","remoteIds":[{"sourceName":"IMDB","id":"tt7777777"},{"sourceName":"TheMovieDB","id":"88888"}]}}`))
		case r.URL.Path == "/tvdb/series/12345/translations/zho":
			_, _ = w.Write([]byte(`{"data":{"name":"测试剧集","overview":"中文简介"}}`))
		case r.URL.Path == "/tvdb/series/12345/episodes/default/zho":
			_, _ = w.Write([]byte(`{"data":{"episodes":[{"seasonNumber":1,"number":1,"name":"第一集","aired":"2024-03-01"}]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mock.Close()

	tmdbKey := "k1"
	tmdbBase := mock.URL + "/3"
	doubanBase := mock.URL + "/douban"
	doubanCookie := "bid=testcookie"
	anilistBase := mock.URL + "/anilist"
	imdbBase := mock.URL + "/imdb"
	tvdbEnabled := true
	tvdbBase := mock.URL + "/tvdb"
	tvdbKey := "tvdb-key"
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		DoubanAPIBase:  &doubanBase,
		DoubanCookie:   &doubanCookie,
		AniListAPIBase: &anilistBase,
		ImdbAPIBase:    &imdbBase,
		TvdbEnabled:    &tvdbEnabled,
		TvdbAPIBase:    &tvdbBase,
		TvdbAPIKey:     &tvdbKey,
	}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()

	// 1. Douban search & detail with aka + imdb_id
	dbCands, err := svc.Search(ctx, "douban", "show", "我们住在一起", 0, "zh-CN", false)
	if err != nil || len(dbCands) != 1 || dbCands[0].ID != "36283066" {
		t.Fatalf("douban search failed: %+v err=%v", dbCands, err)
	}
	dbWork, err := svc.GetWork(ctx, "douban", "show", "36283066", "zh-CN", false)
	if err != nil || dbWork.ImdbID == nil || *dbWork.ImdbID != "tt9999999" || len(dbWork.Aliases) == 0 {
		t.Fatalf("unexpected douban work: %+v err=%v", dbWork, err)
	}

	// 2. TMDB FindByExternalID
	foundCand, foundKind, err := svc.FindByExternalID(ctx, "imdb_id", "tt9999999", "show", "zh-CN", false)
	if err != nil || foundCand == nil || foundCand.ID != "230311" || foundKind != "show" {
		t.Fatalf("TMDB FindByExternalID failed: cand=%+v kind=%s err=%v", foundCand, foundKind, err)
	}

	// 3. AniList search & detail
	aliCands, err := svc.Search(ctx, "anilist", "show", "Frieren", 0, "zh-CN", false)
	if err != nil || len(aliCands) != 1 || aliCands[0].ID != "154587" {
		t.Fatalf("anilist search failed: %+v err=%v", aliCands, err)
	}
	aliWork, err := svc.GetWork(ctx, "anilist", "show", "154587", "zh-CN", false)
	if err != nil || aliWork.Studio == nil || *aliWork.Studio != "Madhouse" {
		t.Fatalf("anilist work failed: %+v err=%v", aliWork, err)
	}

	// 4. IMDb text + direct tt-ID search
	imdbCands, err := svc.Search(ctx, "imdb", "movie", "tt1375666", 0, "zh-CN", false)
	if err != nil || len(imdbCands) != 1 || imdbCands[0].Title != "Inception" {
		t.Fatalf("imdb direct search failed: %+v err=%v", imdbCands, err)
	}

	// 5. TheTvDb search, extended + translation + season
	tvCands, err := svc.Search(ctx, "tvdb", "show", "Test", 2024, "zh-CN", false)
	if err != nil || len(tvCands) != 1 || tvCands[0].Title != "测试剧集" {
		t.Fatalf("tvdb search failed: %+v err=%v", tvCands, err)
	}
	tvWork, err := svc.GetWork(ctx, "tvdb", "show", "12345", "zh-CN", false)
	if err != nil || tvWork.TmdbID == nil || *tvWork.TmdbID != "88888" || tvWork.Title != "测试剧集" {
		t.Fatalf("tvdb work failed: %+v err=%v", tvWork, err)
	}
	tvSeason, err := svc.GetSeason(ctx, "tvdb", "12345", 1, "zh-CN", false)
	if err != nil || len(tvSeason.Episodes) != 1 || *tvSeason.Episodes[0].Title != "第一集" {
		t.Fatalf("tvdb season failed: %+v err=%v", tvSeason, err)
	}

	// 6. Strict TMDB error propagation: even after caching an empty TMDB search, a 500 error on refresh MUST NOT return stale empty cache
	empty, err := svc.Search(ctx, "tmdb", "movie", "Unavailable", 2026, "zh-CN", false)
	if err != nil || len(empty) != 0 {
		t.Fatalf("expected empty tmdb search, got %+v err=%v", empty, err)
	}
	failTmdb.Store(true)
	if _, err := svc.Search(ctx, "tmdb", "movie", "Unavailable", 2026, "zh-CN", true); !errors.Is(err, ErrTmdbUpstream) {
		t.Fatalf("expected ErrTmdbUpstream on TMDB failure, got %v", err)
	}
	if _, _, err := svc.FindByExternalID(ctx, "imdb_id", "tt9999999", "show", "zh-CN", true); !errors.Is(err, ErrTmdbUpstream) {
		t.Fatalf("expected ErrTmdbUpstream on FindByExternalID failure, got %v", err)
	}
}

func TestDoubanImageProxyRefererAndAllowlist(t *testing.T) {
	svc, store := openTestMetadataService(t)
	var seenReferer string
	var seenHost string

	proxySrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenReferer = r.Header.Get("Referer")
		seenHost = r.Host
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("\xff\xd8\xff\xe0DOUBANJPG"))
	}))
	defer proxySrv.Close()

	proxyURL := proxySrv.URL
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{MetadataProxy: &proxyURL}); err != nil {
		t.Fatal(err)
	}

	img, err := svc.FetchRemoteImage(context.Background(), "http://img9.doubanio.com/view/photo/test.jpg", "w500")
	if err != nil {
		t.Fatalf("FetchRemoteImage for doubanio failed: %v", err)
	}
	if len(img.Data) == 0 || !strings.Contains(seenHost, "doubanio.com") {
		t.Fatalf("expected proxied request to doubanio.com, got host=%q", seenHost)
	}
	if seenReferer != "https://movie.douban.com/" {
		t.Fatalf("expected Douban Referer header, got %q", seenReferer)
	}
}

func TestFetchRemoteImageTransientRetryAndNoRetryOn404(t *testing.T) {
	svc, store := openTestMetadataService(t)
	var retryHits atomic.Int32
	var missingHits atomic.Int32

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/t/p/w500/flaky.jpg":
			if retryHits.Add(1) == 1 {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			w.Header().Set("Content-Type", "image/jpeg")
			_, _ = w.Write([]byte("\xff\xd8\xff\xe0OK"))
		case "/t/p/w500/missing.jpg":
			missingHits.Add(1)
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	imgBase := srv.URL + "/t/p"
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{TmdbImageBase: &imgBase}); err != nil {
		t.Fatal(err)
	}

	img, err := svc.FetchRemoteImage(context.Background(), "/flaky.jpg", "w500")
	if err != nil || len(img.Data) == 0 {
		t.Fatalf("expected retry to recover from transient 502, got err=%v", err)
	}
	if retryHits.Load() != 2 {
		t.Fatalf("expected 2 upstream hits (1 failure + 1 retry), got %d", retryHits.Load())
	}

	if _, err := svc.FetchRemoteImage(context.Background(), "/missing.jpg", "w500"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound on 404, got %v", err)
	}
	if missingHits.Load() != 1 {
		t.Fatalf("404 must not retry, got %d hits", missingHits.Load())
	}
}
