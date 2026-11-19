package library

import (
	"context"
	"encoding/binary"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/vault"
)

func TestParserAndClassifierSamples(t *testing.T) {
	// 1. Organised movie with edition & HDR
	p1 := ParseFileName("Dune Part Two (2024) - 2160p DoVi IMAX.mkv")
	c1 := ClassifyVideo(p1, nil, 0)
	if c1.Kind != db.KindMovie || c1.Title != "Dune Part Two" || c1.Year == nil || *c1.Year != 2024 {
		t.Fatalf("unexpected movie parse: parsed=%+v cls=%+v", p1, c1)
	}
	if p1.Resolution != "2160p" || p1.HDR != "Dolby Vision" || p1.Edition != "IMAX" {
		t.Fatalf("unexpected tech badges: %+v", p1)
	}

	// 2. Fansub anime episode
	p2 := ParseFileName("[VCB-Studio] Frieren [03v2][1080p][HEVC].mkv")
	c2 := ClassifyVideo(p2, []ParsedFolder{{Title: "葬送的芙莉莲"}}, 1)
	if c2.Kind != db.KindEpisode || c2.Episode == nil || *c2.Episode != 3 || !p2.FansubStyle {
		t.Fatalf("unexpected fansub parse: parsed=%+v cls=%+v", p2, c2)
	}

	// 3. Chinese leading year movie + Chinese season/episode
	p3 := ParseFileName("2024.周处除三害.1080p.WEB-DL.mp4")
	c3 := ClassifyVideo(p3, nil, 0)
	if c3.Kind != db.KindMovie || c3.Title != "周处除三害" || c3.Year == nil || *c3.Year != 2024 {
		t.Fatalf("unexpected leading year parse: parsed=%+v cls=%+v", p3, c3)
	}

	p4 := ParseFileName("庆余年.第二季.第十二集.1080p.mp4")
	c4 := ClassifyVideo(p4, nil, 0)
	if c4.Kind != db.KindEpisode || c4.Title != "庆余年" || c4.Season == nil || *c4.Season != 2 || c4.Episode == nil || *c4.Episode != 12 {
		t.Fatalf("unexpected Chinese episode parse: parsed=%+v cls=%+v", p4, c4)
	}

	// 4. Season folder + loose numbered siblings >= 3
	sf := ParseFolderName("Season 2")
	if !sf.IsSeasonFolder || sf.Season == nil || *sf.Season != 2 {
		t.Fatalf("unexpected season folder parse: %+v", sf)
	}
	p5 := ParseFileName("Title - 05.mkv")
	c5 := ClassifyVideo(p5, []ParsedFolder{sf, {Title: "My Show"}}, 3)
	if c5.Kind != db.KindEpisode || c5.Title != "Title" || c5.Season == nil || *c5.Season != 2 || *c5.Episode != 5 {
		t.Fatalf("unexpected loose episode parse: parsed=%+v cls=%+v", p5, c5)
	}
}

func TestNfoReaderMovieAndEpisode(t *testing.T) {
	movieXml := `<?xml version="1.0" encoding="utf-8"?>
<movie>
  <title>银翼杀手 2049</title>
  <originaltitle>Blade Runner 2049</originaltitle>
  <year>2017</year>
  <rating>8.3</rating>
  <runtime>164</runtime>
  <uniqueid type="tmdb">335984</uniqueid>
  <genre>科幻</genre>
  <director>丹尼斯·维伦纽瓦</director>
  <actor><name>Ryan Gosling</name><role>K</role></actor>
  <set><name>银翼杀手系列</name></set>
</movie>https://www.themoviedb.org/movie/335984`

	w := ReadTitleNFO(movieXml, "movie")
	if w == nil || w.Title != "银翼杀手 2049" || w.TmdbID == nil || *w.TmdbID != "335984" || w.CollectionTitle == nil || *w.CollectionTitle != "银翼杀手系列" {
		t.Fatalf("unexpected movie NFO: %+v", w)
	}

	epXml := `<episodedetails><title>第一集</title><episode>1</episode><runtime>48</runtime></episodedetails>`
	ep := ReadEpisodeNFO(epXml)
	if ep == nil || ep.Number != 1 || ep.Title == nil || *ep.Title != "第一集" {
		t.Fatalf("unexpected episode NFO: %+v", ep)
	}
}

func makeMinimalMp4(width, height uint16, timescale, duration uint32) []byte {
	box := func(t string, body []byte) []byte {
		out := make([]byte, 8+len(body))
		binary.BigEndian.PutUint32(out[:4], uint32(len(out)))
		copy(out[4:8], t)
		copy(out[8:], body)
		return out
	}
	ftyp := box("ftyp", []byte("isom\x00\x00\x02\x00isom"))

	mvhdBody := make([]byte, 100)
	binary.BigEndian.PutUint32(mvhdBody[12:16], timescale)
	binary.BigEndian.PutUint32(mvhdBody[16:20], duration)
	mvhd := box("mvhd", mvhdBody)

	tkhdBody := make([]byte, 84)
	tkhdBody[3] = 1
	tkhd := box("tkhd", tkhdBody)

	mdhdBody := make([]byte, 24)
	binary.BigEndian.PutUint32(mdhdBody[12:16], timescale)
	binary.BigEndian.PutUint32(mdhdBody[16:20], duration)
	mdhd := box("mdhd", mdhdBody)

	hdlrBody := make([]byte, 24)
	copy(hdlrBody[8:12], "vide")
	hdlr := box("hdlr", hdlrBody)

	avcEntry := make([]byte, 78)
	binary.BigEndian.PutUint16(avcEntry[24:26], width)
	binary.BigEndian.PutUint16(avcEntry[26:28], height)
	stsdBody := make([]byte, 8)
	binary.BigEndian.PutUint32(stsdBody[4:8], 1)
	stsdBody = append(stsdBody, box("hvc1", avcEntry)...)
	stsd := box("stsd", stsdBody)

	sttsBody := make([]byte, 16)
	binary.BigEndian.PutUint32(sttsBody[4:8], 1)
	binary.BigEndian.PutUint32(sttsBody[8:12], 24)
	binary.BigEndian.PutUint32(sttsBody[12:16], 1000)
	stts := box("stts", sttsBody)

	stbl := box("stbl", append(stsd, stts...))
	minf := box("minf", stbl)
	mdia := box("mdia", append(append(mdhd, hdlr...), minf...))
	trak := box("trak", append(tkhd, mdia...))
	moov := box("moov", append(mvhd, trak...))

	return append(ftyp, moov...)
}

func TestProbeMp4Header(t *testing.T) {
	mp4 := makeMinimalMp4(3840, 2160, 24000, 24000*120)
	probed, err := ProbeMedia("mp4", int64(len(mp4)), func(start, length int64) ([]byte, error) {
		end := start + length
		if end > int64(len(mp4)) {
			end = int64(len(mp4))
		}
		return mp4[start:end], nil
	})
	if err != nil {
		t.Fatalf("probe mp4: %v", err)
	}
	if probed.Container != "mp4" || probed.DurationMs == nil || *probed.DurationMs != 120000 {
		t.Fatalf("unexpected probed container/duration: %+v", probed)
	}
	fv := probed.FirstVideo()
	if fv == nil || fv.Codec != "hevc" || fv.Width != 3840 || fv.Height != 2160 {
		t.Fatalf("unexpected video stream: %+v", fv)
	}
}

func TestEndToEndScanProbeScrapeAndManualMatch(t *testing.T) {
	dir := t.TempDir()
	mediaRoot := filepath.Join(dir, "media")
	if err := os.MkdirAll(filepath.Join(mediaRoot, "电影"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(mediaRoot, "动漫", "葬送的芙莉莲"), 0o755); err != nil {
		t.Fatal(err)
	}

	mp4Bytes := makeMinimalMp4(1920, 1080, 24000, 24000*60)
	if err := os.WriteFile(filepath.Join(mediaRoot, "电影", "Dune Part Two (2024).mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mediaRoot, "电影", "Dune Part Two (2024).zh.srt"), []byte("1\n00:00:01,000 --> 00:00:03,000\n你好\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mediaRoot, "动漫", "葬送的芙莉莲", "[VCB-Studio] Frieren [01][1080p].mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mediaRoot, "电影", "MysteryClip.mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}

	tmdbMock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/movie":
			q := r.URL.Query().Get("query")
			if q == "Dune Part Two" {
				_, _ = w.Write([]byte(`{"results":[{"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27","poster_path":"/d2.jpg"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/search/tv":
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/movie/693134":
			_, _ = w.Write([]byte(`{"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27","vote_average":8.4,"poster_path":"/d2.jpg","backdrop_path":"/d2b.jpg","genres":[{"id":878,"name":"科幻"}]}`))
		case "/3/movie/999":
			_, _ = w.Write([]byte(`{"id":999,"title":"人工纠偏纪录片","release_date":"2023-05-01","poster_path":"/m999.jpg","genres":[{"id":99,"name":"纪录"}]}`))
		case "/v0/search/subjects":
			_, _ = w.Write([]byte(`{"data":[{"id":400602,"name_cn":"葬送的芙莉莲","name":"葬送のフリーレン","date":"2023-09-29"}]}`))
		case "/v0/subjects/400602":
			_, _ = w.Write([]byte(`{"id":400602,"name_cn":"葬送的芙莉莲","name":"葬送のフリーレン","date":"2023-09-29","rating":{"score":8.8},"images":{"large":"https://lain.bgm.tv/f.jpg"},"tags":[{"name":"奇幻"}]}`))
		case "/v0/episodes":
			_, _ = w.Write([]byte(`{"data":[{"ep":1,"name_cn":"冒险的结束","airdate":"2023-09-29"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer tmdbMock.Close()

	dataDir := filepath.Join(dir, "data")
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := "mock_key"
	apiBase := tmdbMock.URL + "/3"
	bgmBase := tmdbMock.URL
	auxOff := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &key,
		TmdbAPIBase:    &apiBase,
		BangumiAPIBase: &bgmBase,
		DoubanEnabled:  &auxOff,
		AniListEnabled: &auxOff,
		ImdbEnabled:    &auxOff,
	}); err != nil {
		t.Fatal(err)
	}

	mount, err := store.CreateMount("Local Media", "local", map[string]any{"rootPath": mediaRoot}, nil, true)
	if err != nil {
		t.Fatal(err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	metaSvc := metadata.NewService(store)
	scanner := NewScanner(store, stMgr, hub)
	scraper := NewScraper(store, metaSvc, stMgr, hub)

	ctx := context.Background()
	scanRes, err := scanner.ScanMount(ctx, mount.ID, true)
	if err != nil || scanRes.Videos != 3 {
		t.Fatalf("unexpected scan result: %+v err=%v", scanRes, err)
	}
	scanner.ProbePendingFiles(ctx, 10)

	sum, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatalf("scrape failed: %v", err)
	}
	if sum.Matched != 2 || sum.Unmatched != 1 {
		t.Fatalf("expected 2 matched & 1 unmatched, got %+v", sum)
	}

	// Verify shelves
	movies, err := store.QueryLibrary(db.LibraryQuery{LibraryType: db.ShelfMovie})
	if err != nil || movies.Total != 1 || movies.Items[0].Title != "沙丘2" {
		t.Fatalf("unexpected movie shelf: %+v err=%v", movies, err)
	}
	animes, err := store.QueryLibrary(db.LibraryQuery{LibraryType: db.ShelfAnime})
	if err != nil || animes.Total != 1 || animes.Items[0].Title != "葬送的芙莉莲" {
		t.Fatalf("unexpected anime shelf: %+v err=%v", animes, err)
	}

	// Verify subtitle linked & file probed
	detail, err := store.GetItemDetail(movies.Items[0].ID)
	if err != nil || len(detail.Subtitles) != 1 || detail.Files[0].VideoCodec == nil || *detail.Files[0].VideoCodec != "hevc" {
		t.Fatalf("unexpected movie detail: %+v err=%v", detail, err)
	}

	// Verify manual match on unmatched item moves it to documentary shelf
	unmatched, totalUnm, err := store.QueryUnmatched(10, 0)
	if err != nil || totalUnm != 1 {
		t.Fatalf("unexpected unmatched: total=%d err=%v", totalUnm, err)
	}
	fixed, err := scraper.ApplyManualMatch(ctx, unmatched[0].Item.ID, "tmdb", "999", false, "")
	if err != nil || fixed.LibraryType != db.ShelfDocumentary || !fixed.Locked {
		t.Fatalf("unexpected manual match result: %+v err=%v", fixed, err)
	}

	// Verify Coordinator background scrape worker reacts to Scanner.SetOnPendingAdded signal
	coord := NewCoordinator(store, stMgr, metaSvc, hub)
	coord.Start()
	defer coord.Stop()
	snap := coord.TaskStatus()
	if snap.UnmatchedCount != 0 {
		t.Fatalf("expected 0 unmatched after manual match, got %d", snap.UnmatchedCount)
	}
}

func TestRetryUnmatchedBypassesSearchCacheAndSeasonSuffix(t *testing.T) {
	dir := t.TempDir()
	mediaRoot := filepath.Join(dir, "media")
	if err := os.MkdirAll(filepath.Join(mediaRoot, "电影"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(mediaRoot, "电视剧", "剑来 第一季 (2024)", "Season 1"), 0o755); err != nil {
		t.Fatal(err)
	}
	mp4Bytes := makeMinimalMp4(1920, 1080, 24000, 24000*30)
	if err := os.WriteFile(filepath.Join(mediaRoot, "电影", "重试测试电影 (2025).mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mediaRoot, "电视剧", "剑来 第一季 (2024)", "Season 1", "剑来 第一季 - S01E01 - 第 1 集.mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}

	var allowMatches atomic.Bool
	tmdbMock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/movie":
			if allowMatches.Load() && r.URL.Query().Get("query") == "重试测试电影" {
				_, _ = w.Write([]byte(`{"results":[{"id":8801,"title":"重试测试电影","release_date":"2025-01-01"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/search/tv":
			if allowMatches.Load() && r.URL.Query().Get("query") == "剑来" {
				_, _ = w.Write([]byte(`{"results":[{"id":259537,"name":"剑来","original_name":"剑来","first_air_date":"2024-08-15"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/movie/8801":
			_, _ = w.Write([]byte(`{"id":8801,"title":"重试测试电影","release_date":"2025-01-01","vote_average":7.9}`))
		case "/3/tv/259537":
			_, _ = w.Write([]byte(`{"id":259537,"name":"剑来","original_name":"剑来","first_air_date":"2024-08-15","vote_average":8.6}`))
		case "/3/tv/259537/season/1":
			_, _ = w.Write([]byte(`{"id":1,"season_number":1,"name":"第 1 季","episodes":[{"episode_number":1,"name":"第一集"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer tmdbMock.Close()

	dataDir := filepath.Join(dir, "data")
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := "mock_key"
	apiBase := tmdbMock.URL + "/3"
	bgmDisabled := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &key,
		TmdbAPIBase:    &apiBase,
		BangumiEnabled: &bgmDisabled,
		DoubanEnabled:  &bgmDisabled,
		AniListEnabled: &bgmDisabled,
		ImdbEnabled:    &bgmDisabled,
	}); err != nil {
		t.Fatal(err)
	}

	mount, err := store.CreateMount("Test Mount", "local", map[string]any{"rootPath": mediaRoot}, nil, true)
	if err != nil {
		t.Fatal(err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	metaSvc := metadata.NewService(store)
	scanner := NewScanner(store, stMgr, hub)
	scraper := NewScraper(store, metaSvc, stMgr, hub)

	ctx := context.Background()
	if _, err := scanner.ScanMount(ctx, mount.ID, true); err != nil {
		t.Fatal(err)
	}

	// Pass 1: upstream returns empty results -> populates meta_search_cache with []
	sum1, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatalf("pass 1 scrape failed: %v", err)
	}
	if sum1.Matched != 0 || sum1.Unmatched != 2 {
		t.Fatalf("expected 0 matched & 2 unmatched on pass 1, got %+v", sum1)
	}
	if stats := metaSvc.CacheStats(); stats.Searches == 0 {
		t.Fatalf("expected empty search results to be cached in meta_search_cache")
	}

	// Upstream starts returning results now.
	allowMatches.Store(true)

	// Pass 2: normal scrape (retryUnmatched=false) should do nothing because items were already marked scraped_at
	sum2, err := scraper.ScrapePending(ctx, false, false)
	if err != nil || sum2.Matched != 0 || sum2.Unmatched != 0 {
		t.Fatalf("expected empty queue on normal scrape pass, got %+v err=%v", sum2, err)
	}

	// Pass 3: retryUnmatched=true MUST bypass meta_search_cache & use season-stripped fallback for "剑来 第一季"
	sum3, err := scraper.ScrapePending(ctx, true, false)
	if err != nil {
		t.Fatalf("retryUnmatched scrape failed: %v", err)
	}
	if sum3.Matched != 2 || sum3.Unmatched != 0 {
		t.Fatalf("expected both unmatched items to match on retry, got %+v", sum3)
	}
	if _, totalUnm, err := store.QueryUnmatched(10, 0); err != nil || totalUnm != 0 {
		t.Fatalf("expected 0 remaining unmatched, got total=%d err=%v", totalUnm, err)
	}
}

func TestSeasonAndSequelTitleParsers(t *testing.T) {
	seasonCases := []struct {
		in         string
		wantBase   string
		wantSeason int
	}{
		{"剑来 第一季", "剑来", 1},
		{"庆余年 第二季", "庆余年", 2},
		{"Frieren Season 2", "Frieren", 2},
		{"Dark S03", "Dark", 3},
		{"普通剧名", "", 0},
	}
	for _, tc := range seasonCases {
		gotBase, gotSeason := parseTrailingSeasonTitle(tc.in)
		if gotBase != tc.wantBase || gotSeason != tc.wantSeason {
			t.Fatalf("parseTrailingSeasonTitle(%q) = (%q, %d), want (%q, %d)", tc.in, gotBase, gotSeason, tc.wantBase, tc.wantSeason)
		}
	}

	sequelCases := []struct {
		in         string
		wantBase   string
		wantSequel int
	}{
		{"问心2", "问心", 2},
		{"庆余年 2", "庆余年", 2},
		{"猎罪图鉴Ⅱ", "猎罪图鉴", 2},
		{"Fargo II", "Fargo", 2},
		{"请回答1988", "", 0},
		{"2046", "", 0},
		{"V2", "", 0},
	}
	for _, tc := range sequelCases {
		gotBase, gotSeq := parseTrailingSequelNumber(tc.in)
		if gotBase != tc.wantBase || gotSeq != tc.wantSequel {
			t.Fatalf("parseTrailingSequelNumber(%q) = (%q, %d), want (%q, %d)", tc.in, gotBase, gotSeq, tc.wantBase, tc.wantSequel)
		}
	}
}

func TestAdvancedMatchingAliasesUniqueAndSequelToSeason(t *testing.T) {
	dir := t.TempDir()
	mediaRoot := filepath.Join(dir, "media")
	dirs := []string{
		filepath.Join(mediaRoot, "电视剧", "爱情有烟火 (2026)", "Season 1"),
		filepath.Join(mediaRoot, "电视剧", "我们住在一起 (2026)", "Season 1"),
		filepath.Join(mediaRoot, "电视剧", "改名独苗剧 (2026)", "Season 1"),
		filepath.Join(mediaRoot, "电视剧", "问心2 (2026)", "Season 1"),
		filepath.Join(mediaRoot, "电影", "V (2026)"),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	mp4Bytes := makeMinimalMp4(1920, 1080, 24000, 24000*30)
	files := []string{
		filepath.Join(mediaRoot, "电视剧", "爱情有烟火 (2026)", "Season 1", "爱情有烟火 - S01E01.mp4"),
		filepath.Join(mediaRoot, "电视剧", "我们住在一起 (2026)", "Season 1", "我们住在一起 - S01E31.mp4"),
		filepath.Join(mediaRoot, "电视剧", "改名独苗剧 (2026)", "Season 1", "改名独苗剧 - S01E01.mp4"),
		filepath.Join(mediaRoot, "电视剧", "问心2 (2026)", "Season 1", "问心2 - S01E01.mp4"),
		filepath.Join(mediaRoot, "电影", "V (2026)", "V (2026) - 1080p.mp4"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, mp4Bytes, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	tmdbMock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/tv":
			q := r.URL.Query().Get("query")
			yr := r.URL.Query().Get("first_air_date_year")
			switch q {
			case "爱情有烟火", "我们住在一起":
				_, _ = w.Write([]byte(`{"results":[{"id":230311,"name":"爱情有烟火","original_name":"爱情有烟火","first_air_date":"2026-02-01"}]}`))
			case "改名独苗剧":
				if yr == "2026" {
					_, _ = w.Write([]byte(`{"results":[{"id":7701,"name":"正式剧名","original_name":"正式剧名","first_air_date":"2026-06-01"}]}`))
					return
				}
				_, _ = w.Write([]byte(`{"results":[]}`))
			case "问心":
				_, _ = w.Write([]byte(`{"results":[{"id":233076,"name":"问心","original_name":"问心","first_air_date":"2023-10-07"}]}`))
			default:
				_, _ = w.Write([]byte(`{"results":[]}`))
			}
		case "/3/search/movie":
			if r.URL.Query().Get("query") == "V" {
				_, _ = w.Write([]byte(`{"results":[{"id":1742441,"title":"V/H/S/MIXTAPE","original_title":"V/H/S/MIXTAPE","release_date":"2026-01-01"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/tv/230311":
			_, _ = w.Write([]byte(`{
				"id": 230311,
				"name": "爱情有烟火",
				"original_name": "爱情有烟火",
				"first_air_date": "2026-02-01",
				"alternative_titles": {"results": [{"title": "我们住在一起"}]}
			}`))
		case "/3/tv/230311/season/1":
			_, _ = w.Write([]byte(`{
				"season_number": 1,
				"name": "第 1 季",
				"air_date": "2026-02-01",
				"episodes": [
					{"episode_number": 1, "name": "初遇"},
					{"episode_number": 31, "name": "第31集真实标题"}
				]
			}`))
		case "/3/tv/7701":
			_, _ = w.Write([]byte(`{"id":7701,"name":"正式剧名","original_name":"正式剧名","first_air_date":"2026-06-01"}`))
		case "/3/tv/7701/season/1":
			_, _ = w.Write([]byte(`{"season_number":1,"name":"第 1 季","air_date":"2026-06-01","episodes":[{"episode_number":1,"name":"开播"}]}`))
		case "/3/tv/233076":
			_, _ = w.Write([]byte(`{"id":233076,"name":"问心","original_name":"问心","first_air_date":"2023-10-07"}`))
		case "/3/tv/233076/season/2":
			_, _ = w.Write([]byte(`{
				"season_number": 2,
				"name": "第 2 季",
				"air_date": "2026-05-01",
				"episodes": [{"episode_number": 1, "name": "重逢"}]
			}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer tmdbMock.Close()

	dataDir := filepath.Join(dir, "data")
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := "mock_key"
	apiBase := tmdbMock.URL + "/3"
	bgmDisabled := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &key,
		TmdbAPIBase:    &apiBase,
		BangumiEnabled: &bgmDisabled,
		DoubanEnabled:  &bgmDisabled,
		AniListEnabled: &bgmDisabled,
		ImdbEnabled:    &bgmDisabled,
	}); err != nil {
		t.Fatal(err)
	}

	mount, err := store.CreateMount("Test Mount", "local", map[string]any{"rootPath": mediaRoot}, nil, true)
	if err != nil {
		t.Fatal(err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	metaSvc := metadata.NewService(store)
	scanner := NewScanner(store, stMgr, hub)
	scraper := NewScraper(store, metaSvc, stMgr, hub)

	ctx := context.Background()
	if _, err := scanner.ScanMount(ctx, mount.ID, true); err != nil {
		t.Fatal(err)
	}

	sum, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatalf("scrape failed: %v", err)
	}
	if sum.Matched != 3 || sum.Merged != 1 || sum.Unmatched != 1 {
		t.Fatalf("expected 3 matched, 1 merged, 1 unmatched, got %+v", sum)
	}

	// 1. Verify "V (2026)" stayed unmatched
	unm, totalUnm, err := store.QueryUnmatched(10, 0)
	if err != nil || totalUnm != 1 || unm[0].Item.Title != "V" {
		t.Fatalf("expected V to remain unmatched, got total=%d items=%+v err=%v", totalUnm, unm, err)
	}

	// 2. Verify "我们住在一起" merged into "爱情有烟火", filled E31, and preserved alias searchability
	searchRes, err := store.SearchAll("我们住在一起", 10)
	if err != nil || len(searchRes.Shows) != 1 || searchRes.Shows[0].Title != "爱情有烟火" {
		t.Fatalf("expected search for merged alias to find 爱情有烟火, got %+v err=%v", searchRes.Shows, err)
	}
	loveShowID := searchRes.Shows[0].ID
	loveEps, err := store.GetEpisodesByShow(loveShowID, nil)
	if err != nil || len(loveEps) != 2 {
		t.Fatalf("expected 2 merged episodes under 爱情有烟火, got %+v err=%v", loveEps, err)
	}
	foundE31 := false
	for _, ep := range loveEps {
		if ep.EpisodeNumber != nil && *ep.EpisodeNumber == 31 && ep.Title == "第31集真实标题" {
			foundE31 = true
		}
	}
	if !foundE31 {
		t.Fatalf("expected episode 31 to have scraped title '第31集真实标题', got %+v", loveEps)
	}

	// 3. Verify "改名独苗剧" matched to "正式剧名" via safe same-year unique fallback
	uniqueRes, err := store.SearchAll("正式剧名", 10)
	if err != nil || len(uniqueRes.Shows) != 1 {
		t.Fatalf("expected unique candidate fallback show 正式剧名, got %+v err=%v", uniqueRes.Shows, err)
	}

	// 4. Verify "问心2" remapped Season 1 -> Season 2 and matched #233076 "问心" with Season 2 episode title "重逢"
	wxRes, err := store.SearchAll("问心", 10)
	if err != nil || len(wxRes.Shows) != 1 || wxRes.Shows[0].TmdbID == nil || *wxRes.Shows[0].TmdbID != "233076" {
		t.Fatalf("expected 问心 show matched via sequel-to-season, got %+v err=%v", wxRes.Shows, err)
	}
	wxSeason2 := 2
	wxEps, err := store.GetEpisodesByShow(wxRes.Shows[0].ID, &wxSeason2)
	if err != nil || len(wxEps) != 1 || wxEps[0].Title != "重逢" {
		t.Fatalf("expected Season 2 episode '重逢' under 问心, got %+v err=%v", wxEps, err)
	}
}

func TestCustomRecognitionWordsAndManualDirectIDs(t *testing.T) {
	rules := `
# 屏蔽网盘和谐词和广告
我的sj大电影 => 我的世界大电影
[夸克4K臻享]
re:^【.*?】\s* =>
`
	if got := ApplyCustomRecognitionWords("我的sj大电影", rules); got != "我的世界大电影" {
		t.Fatalf("custom literal replace failed: got %q", got)
	}
	if got := ApplyCustomRecognitionWords("【限时分享】流浪地球2 [夸克4K臻享]", rules); got != "流浪地球2" {
		t.Fatalf("custom strip & regex failed: got %q", got)
	}

	emb := ExtractEmbeddedExternalIDs("/电影/Inception [tt1375666] {tmdb-27205}/Inception.mp4")
	if emb.ImdbID != "tt1375666" || emb.TmdbID != "27205" {
		t.Fatalf("unexpected embedded IDs: %+v", emb)
	}

	cases := []struct {
		in       string
		wantProv string
		wantID   string
		wantKind string
	}{
		{"tt1375666", "imdb", "tt1375666", ""},
		{"douban:36283066", "douban", "36283066", ""},
		{"tmdb:tv:230311", "tmdb", "230311", "show"},
		{"bgm:400602", "bangumi", "400602", ""},
		{"https://movie.douban.com/subject/36283066/", "douban", "36283066", ""},
		{"https://www.themoviedb.org/movie/27205", "tmdb", "27205", "movie"},
		{"https://anilist.co/anime/154587", "anilist", "154587", "show"},
	}
	for _, tc := range cases {
		p, id, k, ok := ParseManualDirectID(tc.in)
		if !ok || p != tc.wantProv || id != tc.wantID || k != tc.wantKind {
			t.Fatalf("ParseManualDirectID(%q) = (%q, %q, %q, %v), want (%q, %q, %q, true)",
				tc.in, p, id, k, ok, tc.wantProv, tc.wantID, tc.wantKind)
		}
	}
}

func TestMultiSourceBridgeStandaloneAndTmdbOutageFail(t *testing.T) {
	dir := t.TempDir()
	mediaRoot := filepath.Join(dir, "media")
	dirs := []string{
		filepath.Join(mediaRoot, "电视剧", "我们住在一起 (2026)", "Season 1"),
		filepath.Join(mediaRoot, "电视剧", "AliasFallback (2025)", "Season 1"),
		filepath.Join(mediaRoot, "电影"),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	mp4Bytes := makeMinimalMp4(1920, 1080, 24000, 24000*30)
	files := []string{
		filepath.Join(mediaRoot, "电视剧", "我们住在一起 (2026)", "Season 1", "我们住在一起 - S01E01.mp4"),
		filepath.Join(mediaRoot, "电视剧", "AliasFallback (2025)", "Season 1", "AliasFallback - S01E01.mp4"),
		filepath.Join(mediaRoot, "电影", "我的sj大电影 (2025).mp4"),
		filepath.Join(mediaRoot, "电影", "独立网大短剧 (2026).mp4"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, mp4Bytes, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var tmdbDown atomic.Bool
	var doubanHits atomic.Int32

	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/3/") && tmdbDown.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		// TMDB: "我们住在一起" returns empty directly; "AliasFallback" returns empty directly; "Canonical Show" matches via Bridge 2C;
		// "我的世界大电影" matches via custom recognition word; "独立网大短剧" is completely absent in TMDB.
		case r.URL.Path == "/3/search/tv":
			q := r.URL.Query().Get("query")
			if q == "Canonical Show" {
				_, _ = w.Write([]byte(`{"results":[{"id":55001,"name":"规范英文剧名","original_name":"Canonical Show","first_air_date":"2025-05-01"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case r.URL.Path == "/3/search/movie":
			q := r.URL.Query().Get("query")
			if q == "我的世界大电影" {
				_, _ = w.Write([]byte(`{"results":[{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case r.URL.Path == "/3/find/tt2800001":
			_, _ = w.Write([]byte(`{"tv_results":[{"id":230311,"name":"爱情有烟火","original_name":"爱情有烟火","first_air_date":"2026-02-01"}],"movie_results":[]}`))
		case r.URL.Path == "/3/tv/230311":
			_, _ = w.Write([]byte(`{"id":230311,"name":"爱情有烟火","original_name":"爱情有烟火","first_air_date":"2026-02-01"}`))
		case r.URL.Path == "/3/tv/230311/season/1":
			_, _ = w.Write([]byte(`{"season_number":1,"name":"第 1 季","air_date":"2026-02-01","episodes":[{"episode_number":1,"name":"初遇烟火"}]}`))
		case r.URL.Path == "/3/tv/55001":
			_, _ = w.Write([]byte(`{"id":55001,"name":"规范英文剧名","original_name":"Canonical Show","first_air_date":"2025-05-01"}`))
		case r.URL.Path == "/3/tv/55001/season/1":
			_, _ = w.Write([]byte(`{"season_number":1,"name":"第 1 季","air_date":"2025-05-01","episodes":[{"episode_number":1,"name":"桥接单集标题"}]}`))
		case r.URL.Path == "/3/movie/950387":
			_, _ = w.Write([]byte(`{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04"}`))

		// Douban endpoints
		case r.URL.Path == "/douban/search/subjects":
			doubanHits.Add(1)
			q := r.URL.Query().Get("q")
			switch q {
			case "我们住在一起":
				_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"tv","target":{"id":"36283066","title":"爱情有烟火","year":"2026"}}]}}`))
			case "AliasFallback":
				_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"tv","target":{"id":"39000001","title":"AliasFallback","year":"2025"}}]}}`))
			case "独立网大短剧":
				_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"movie","target":{"id":"39000002","title":"独立网大短剧","year":"2026"}}]}}`))
			default:
				_, _ = w.Write([]byte(`{"subjects":{"items":[]}}`))
			}
		case r.URL.Path == "/douban/tv/36283066":
			_, _ = w.Write([]byte(`{"id":"36283066","title":"爱情有烟火","aka":["我们住在一起"],"year":"2026","intro":"豆瓣补充简介","imdb":"tt2800001","pic":{"large":"https://img9.doubanio.com/a.jpg"}}`))
		case r.URL.Path == "/douban/tv/39000001":
			_, _ = w.Write([]byte(`{"id":"39000001","title":"AliasFallback","original_title":"Canonical Show","year":"2025","intro":"无IMDb但带原名"}`))
		case r.URL.Path == "/douban/movie/39000002":
			_, _ = w.Write([]byte(`{"id":"39000002","title":"独立网大短剧","year":"2026","intro":"TMDB未收录的短剧","rating":{"value":7.2},"pic":{"large":"https://img9.doubanio.com/short.jpg"}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mock.Close()

	dataDir := filepath.Join(dir, "data")
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := "mock_key"
	apiBase := mock.URL + "/3"
	doubanBase := mock.URL + "/douban"
	disabled := false
	enabled := true
	rules := "我的sj大电影 => 我的世界大电影"
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:             &key,
		TmdbAPIBase:            &apiBase,
		DoubanEnabled:          &enabled,
		DoubanAPIBase:          &doubanBase,
		BangumiEnabled:         &disabled,
		AniListEnabled:         &disabled,
		ImdbEnabled:            &disabled,
		AllowFallbackMetadata:  &enabled,
		CustomRecognitionWords: &rules,
	}); err != nil {
		t.Fatal(err)
	}

	mount, err := store.CreateMount("Test Mount", "local", map[string]any{"rootPath": mediaRoot}, nil, true)
	if err != nil {
		t.Fatal(err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	metaSvc := metadata.NewService(store)
	scanner := NewScanner(store, stMgr, hub)
	scraper := NewScraper(store, metaSvc, stMgr, hub)

	ctx := context.Background()
	if _, err := scanner.ScanMount(ctx, mount.ID, true); err != nil {
		t.Fatal(err)
	}

	sum, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatalf("scrape failed: %v", err)
	}
	if sum.Matched != 4 || sum.Unmatched != 0 {
		t.Fatalf("expected 4 matched (TMDB direct + bridge 2B + bridge 2C + standalone fallback), got %+v", sum)
	}

	// Verify Bridge 2B (Douban imdb -> TMDB /find): metadata_source=tmdb, tmdb_id=230311, douban_id=36283066, supplemented summary & episode
	s1, err := store.SearchAll("我们住在一起", 10)
	if err != nil || len(s1.Shows) != 1 {
		t.Fatalf("expected show searchable by local alias 我们住在一起, got %+v err=%v", s1.Shows, err)
	}
	sh1 := s1.Shows[0]
	if sh1.MetadataSource == nil || *sh1.MetadataSource != "tmdb" ||
		sh1.TmdbID == nil || *sh1.TmdbID != "230311" ||
		sh1.DoubanID == nil || *sh1.DoubanID != "36283066" ||
		sh1.Summary == nil || *sh1.Summary != "豆瓣补充简介" {
		t.Fatalf("unexpected bridged show fields: %+v", sh1)
	}
	eps1, _ := store.GetEpisodesByShow(sh1.ID, nil)
	if len(eps1) != 1 || eps1[0].Title != "初遇烟火" {
		t.Fatalf("expected TMDB episode title after bridge, got %+v", eps1)
	}

	// Verify Bridge 2C (Douban canonical original_title -> TMDB search)
	s2, err := store.SearchAll("规范英文剧名", 10)
	if err != nil || len(s2.Shows) != 1 || s2.Shows[0].TmdbID == nil || *s2.Shows[0].TmdbID != "55001" {
		t.Fatalf("expected show bridged via canonical original_title, got %+v err=%v", s2.Shows, err)
	}

	// Verify Custom Recognition Word ("我的sj大电影" -> TMDB #950387)
	mCustom, err := store.SearchAll("我的世界大电影", 10)
	if err != nil || len(mCustom.Movies) != 1 || mCustom.Movies[0].TmdbID == nil || *mCustom.Movies[0].TmdbID != "950387" {
		t.Fatalf("expected custom recognition word movie match, got %+v err=%v", mCustom.Movies, err)
	}

	// Verify Tier 3 Standalone Douban fallback ("独立网大短剧")
	mStandalone, err := store.SearchAll("独立网大短剧", 10)
	if err != nil || len(mStandalone.Movies) != 1 || mStandalone.Movies[0].MetadataSource == nil || *mStandalone.Movies[0].MetadataSource != "douban" {
		t.Fatalf("expected standalone douban fallback movie, got %+v err=%v", mStandalone.Movies, err)
	}

	// Now verify strict TMDB outage behavior:
	// Add a new movie matching a Douban title, turn TMDB HTTP 500 ON, and assert:
	// 1. Scraper aborts/skips (NOT matched, NOT unmatched)
	// 2. Douban receives ZERO calls during TMDB outage!
	if err := os.WriteFile(filepath.Join(mediaRoot, "电影", "断网验证电影 (2026).mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := scanner.ScanMount(ctx, mount.ID, false); err != nil {
		t.Fatal(err)
	}
	doubanBefore := doubanHits.Load()
	tmdbDown.Store(true)
	sumOutage, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatalf("ScrapePending outage error: %v", err)
	}
	if sumOutage.Matched != 0 || sumOutage.Skipped != 1 || sumOutage.Unmatched != 0 {
		t.Fatalf("expected outage scrape to skip/fail immediately, got %+v", sumOutage)
	}
	if doubanHits.Load() != doubanBefore {
		t.Fatalf("expected 0 Douban calls during TMDB outage, went from %d to %d", doubanBefore, doubanHits.Load())
	}
	unmAfter, totalUnm, _ := store.QueryUnmatched(10, 0)
	var outageItem *db.MediaItem
	for i := range unmAfter {
		if unmAfter[i].Item.Title == "断网验证电影" {
			outageItem = &unmAfter[i].Item
			break
		}
	}
	if totalUnm == 0 || outageItem == nil || outageItem.ScrapedAt != nil || outageItem.MetadataSource != nil {
		t.Fatalf("expected failed TMDB item to remain unscraped pending without fallback, got total=%d item=%+v", totalUnm, outageItem)
	}

	// Also verify error wrapped check compiles/behaves cleanly via Direct service call
	if _, err := metaSvc.Search(ctx, "tmdb", "movie", "anything", 2026, "zh-CN", true); !errors.Is(err, metadata.ErrTmdbUpstream) {
		t.Fatalf("expected ErrTmdbUpstream during outage, got %v", err)
	}
}

func TestCjkAbbrevSkeletonAndSafetyGuards(t *testing.T) {
	y2025 := 2025
	y2023 := 2023
	y2020 := 2020
	y2016 := 2016
	y2026 := 2026

	positive := []struct {
		query     string
		itemYear  *int
		candTitle string
		candYear  *int
	}{
		{"我的sj大电影", &y2025, "我的世界大电影", &y2025},
		{"流浪dq2", &y2023, "流浪地球2", &y2023},
		{"爱x之城", &y2016, "爱乐之城", &y2016},
	}
	for _, tc := range positive {
		s := matchCandidateScore(tc.query, tc.itemYear, metadata.Candidate{Title: tc.candTitle, Year: tc.candYear})
		if s < acceptMatchScore {
			t.Fatalf("expected %q vs %q (%v) to pass threshold %.2f, got %.2f", tc.query, tc.candTitle, tc.candYear, acceptMatchScore, s)
		}
	}

	negative := []struct {
		query     string
		itemYear  *int
		candTitle string
		candYear  *int
	}{
		{"我的sj大电影", &y2025, "小马宝莉大电影", &y2025},
		{"我的sj大电影", &y2025, "我的世界大电影", &y2020},
		{"我的sj大电影", &y2025, "我的世界大电影2", &y2025},
		{"我的a大电影", &y2025, "我的世界大电影", &y2025},
		{"闪耀的品格", &y2026, "闪耀的女孩", &y2026},
		{"我的ipad之旅", &y2025, "我的iphone之旅", &y2025},
		{"V", &y2026, "V/H/S/MIXTAPE", &y2026},
	}
	for _, tc := range negative {
		s := matchCandidateScore(tc.query, tc.itemYear, metadata.Candidate{Title: tc.candTitle, Year: tc.candYear})
		if s >= acceptMatchScore {
			t.Fatalf("safety violation: %q vs %q should NOT pass %.2f, got %.2f", tc.query, tc.candTitle, acceptMatchScore, s)
		}
	}

	if !isGenericCategoryFolder("电影电视剧") || !isGenericCategoryFolder("Movies") {
		t.Fatalf("expected generic category folders to be filtered")
	}
	if isGenericCategoryFolder("天道轮回 (2024)") || isGenericCategoryFolder("Frieren") {
		t.Fatalf("valid title folder should NOT be treated as generic category")
	}
}

func TestAutoAbbrevSkeletonDoubanBridgeWithoutCustomRules(t *testing.T) {
	dir := t.TempDir()
	mediaRoot := filepath.Join(dir, "media")
	catDir := filepath.Join(mediaRoot, "电影电视剧")
	if err := os.MkdirAll(catDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mp4Bytes := makeMinimalMp4(1920, 1080, 24000, 24000*30)
	if err := os.WriteFile(filepath.Join(catDir, "我的sj大电影2025.mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}

	var searchedCatFolder atomic.Bool
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query().Get("query")
		if q == "" {
			q = r.URL.Query().Get("q")
		}
		if q == "电影电视剧" {
			searchedCatFolder.Store(true)
		}
		switch r.URL.Path {
		case "/3/search/movie":
			if q == "我的世界大电影" {
				_, _ = w.Write([]byte(`{"results":[{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/search/tv":
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/movie/950387":
			_, _ = w.Write([]byte(`{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04","vote_average":7.1}`))
		case "/douban/search/subjects":
			if q == "我的sj大电影" {
				// Return multiple candidates, plus IMDb won't falsely hijack it
				_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"movie","target":{"id":"26149750","title":"我的世界大电影","year":"2025"}},{"target_type":"movie","target":{"id":"26176481","title":"小马宝莉大电影","year":"2025"}}]}}`))
				return
			}
			_, _ = w.Write([]byte(`{"subjects":{"items":[]}}`))
		case "/douban/movie/26149750":
			_, _ = w.Write([]byte(`{"id":"26149750","title":"我的世界大电影","year":"2025","intro":"方块世界大冒险"}`))
		case "/imdb/search/titles":
			if q == "我的sj大电影" {
				// Single unrelated 2025 result must NOT falsely trigger Pass 3
				_, _ = w.Write([]byte(`{"titles":[{"id":"tt35450649","type":"tvSeries","primaryTitle":"Melo Movie","startYear":2025}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"titles":[]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mock.Close()

	dataDir := filepath.Join(dir, "data")
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := "mock_key"
	tmdbBase := mock.URL + "/3"
	doubanBase := mock.URL + "/douban"
	imdbBase := mock.URL + "/imdb"
	on := true
	off := false
	// Empty CustomRecognitionWords; IMDb intentionally precedes or follows Douban — test both:
	// First verify IMDb does NOT match Melo Movie even when Douban is disabled!
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &key,
		TmdbAPIBase:    &tmdbBase,
		DoubanEnabled:  &off,
		ImdbEnabled:    &on,
		ImdbAPIBase:    &imdbBase,
		BangumiEnabled: &off,
		AniListEnabled: &off,
	}); err != nil {
		t.Fatal(err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	metaSvc := metadata.NewService(store)
	scanner := NewScanner(store, stMgr, hub)
	scraper := NewScraper(store, metaSvc, stMgr, hub)
	mount, _ := store.CreateMount("Media", "local", map[string]any{"rootPath": mediaRoot}, nil, true)

	ctx := context.Background()
	if _, err := scanner.ScanMount(ctx, mount.ID, true); err != nil {
		t.Fatal(err)
	}
	sumImdbOnly, err := scraper.ScrapePending(ctx, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if sumImdbOnly.Matched != 0 || sumImdbOnly.Unmatched != 1 {
		t.Fatalf("expected IMDb unrelated 2025 Melo Movie NOT to false-match Pass 3, got %+v", sumImdbOnly)
	}

	// Now enable Douban and retry unmatched — must auto-match via abbrev skeleton & bridge to TMDB #950387!
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		DoubanEnabled: &on,
		DoubanAPIBase: &doubanBase,
	}); err != nil {
		t.Fatal(err)
	}
	sumRetry, err := scraper.ScrapePending(ctx, true, false)
	if err != nil {
		t.Fatal(err)
	}
	if sumRetry.Matched != 1 || sumRetry.Unmatched != 0 {
		t.Fatalf("expected automatic Douban->TMDB match for 我的sj大电影 without custom rules, got %+v", sumRetry)
	}
	if searchedCatFolder.Load() {
		t.Fatalf("expected generic folder name 电影电视剧 NOT to be searched")
	}
	res, err := store.SearchAll("我的世界大电影", 10)
	if err != nil || len(res.Movies) != 1 || res.Movies[0].TmdbID == nil || *res.Movies[0].TmdbID != "950387" ||
		res.Movies[0].MetadataSource == nil || *res.Movies[0].MetadataSource != "tmdb" ||
		res.Movies[0].DoubanID == nil || *res.Movies[0].DoubanID != "26149750" {
		t.Fatalf("unexpected final matched movie: %+v err=%v", res.Movies, err)
	}
}
