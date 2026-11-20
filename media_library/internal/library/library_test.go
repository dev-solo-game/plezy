package library

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/vault"
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

func TestMediaFileHelpersAndSubtitleMatching(t *testing.T) {
	if !IsVideoFile("Dune.Part.Two.2024.mkv") {
		t.Fatal("expected Dune mkv to be video")
	}
	if IsVideoFile("Dune.Part.Two-sample.mkv") || IsVideoFile("trailer.mp4") || !IsSampleName("movie.preview.01") {
		t.Fatal("expected sample/trailer/preview files to be filtered")
	}
	if IsVideoFile("movie.srt") {
		t.Fatal("subtitle must not be treated as video")
	}
	if !IsSkippedFolder("@eaDir") || !IsSkippedFolder(".git") || !IsSkippedFolder("Extras") || IsSkippedFolder("Season 1") {
		t.Fatal("unexpected IsSkippedFolder behavior")
	}
	if ClassifyFileRole("ep01.mkv") != db.FileRoleVideo ||
		ClassifyFileRole("ep01.zh.ass") != db.FileRoleSubtitle ||
		ClassifyFileRole("poster.webp") != db.FileRoleArtwork ||
		ClassifyFileRole("tvshow.nfo") != db.FileRoleNfo ||
		ClassifyFileRole("readme.txt") != "" {
		t.Fatal("unexpected ClassifyFileRole mapping")
	}

	files := []DirFile{
		{Path: "/Movies/Dune.2024.mkv", Name: "Dune.2024.mkv"},
		{Path: "/Movies/Dune.2024.zh-cn.ass", Name: "Dune.2024.zh-cn.ass"},
		{Path: "/Movies/Other.2024.mkv", Name: "Other.2024.mkv"},
		{Path: "/Movies/Other.2024.srt", Name: "Other.2024.srt"},
	}
	matched := MatchSubtitles(files)
	if len(matched) != 2 {
		t.Fatalf("expected 2 matched subtitles, got %d", len(matched))
	}
	if matched[0].Owner.Name != "Dune.2024.mkv" || matched[0].Language != "cn" {
		t.Fatalf("unexpected match[0]: %+v", matched[0])
	}
	if matched[1].Owner.Name != "Other.2024.mkv" || matched[1].Language != "" {
		t.Fatalf("unexpected match[1]: %+v", matched[1])
	}

	// Single video in dir owns any unmatched subtitle name.
	single := MatchSubtitles([]DirFile{
		{Path: "/S01/Show.S01E01.mkv", Name: "Show.S01E01.mkv"},
		{Path: "/S01/eng.srt", Name: "eng.srt"},
	})
	if len(single) != 1 || single[0].Owner.Name != "Show.S01E01.mkv" || single[0].Language != "eng" {
		t.Fatalf("unexpected single-video subtitle fallback: %+v", single)
	}
	if GuessSubtitleLanguage("Movie.chs.eng", "Movie") != "eng" {
		t.Fatalf("unexpected GuessSubtitleLanguage output")
	}
}

func TestBuildWorkKeyPriority(t *testing.T) {
	strPtr := func(s string) *string { return &s }

	full := metadata.Work{
		Source:     "douban",
		ExternalID: "db1",
		TmdbID:     strPtr("100"),
		ImdbID:     strPtr("tt200"),
		TvdbID:     strPtr("300"),
		BangumiID:  strPtr("400"),
		DoubanID:   strPtr("500"),
		AniListID:  strPtr("600"),
	}
	if got := BuildWorkKey(db.KindMovie, full); got != "tmdb:movie:100" {
		t.Fatalf("got %q want tmdb:movie:100", got)
	}
	full.TmdbID = nil
	if got := BuildWorkKey(db.KindShow, full); got != "imdb:show:tt200" {
		t.Fatalf("got %q want imdb:show:tt200", got)
	}
	full.ImdbID = nil
	if got := BuildWorkKey(db.KindShow, full); got != "tvdb:show:300" {
		t.Fatalf("got %q want tvdb:show:300", got)
	}
	full.TvdbID = nil
	if got := BuildWorkKey(db.KindShow, full); got != "bangumi:show:400" {
		t.Fatalf("got %q want bangumi:show:400", got)
	}
	full.BangumiID = nil
	if got := BuildWorkKey(db.KindMovie, full); got != "douban:movie:500" {
		t.Fatalf("got %q want douban:movie:500", got)
	}
	full.DoubanID = nil
	if got := BuildWorkKey(db.KindShow, full); got != "anilist:show:600" {
		t.Fatalf("got %q want anilist:show:600", got)
	}
}

func TestIdentifyPublicBridgingAndTmdbOutage(t *testing.T) {
	var tmdbDown atomic.Bool
	var mockSrv *httptest.Server
	mockSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case p == "/3/search/movie":
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				_, _ = w.Write([]byte(`{"status_message":"outage"}`))
				return
			}
			q := r.URL.Query().Get("query")
			switch {
			case strings.Contains(q, "Inception"):
				_, _ = w.Write([]byte(`{"results":[{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15"}]}`))
			case strings.Contains(q, "我的世界大电影"):
				_, _ = w.Write([]byte(`{"results":[{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04"}]}`))
			default:
				_, _ = w.Write([]byte(`{"results":[]}`))
			}
		case p == "/3/search/tv":
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case p == "/3/find/tt1375666":
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"movie_results":[{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15"}]}`))
		case p == "/3/movie/27205":
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15","imdb_id":"tt1375666"}`))
		case p == "/3/movie/950387":
			if tmdbDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04"}`))
		case p == "/douban/search/subjects":
			_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"movie","target":{"id":"26149750","title":"我的世界大电影","card_subtitle":"2025 / 美国","pic":{"normal":""}}}]}}`))
		case p == "/douban/movie/26149750":
			_, _ = w.Write([]byte(`{"id":"26149750","title":"我的世界大电影","original_title":"A Minecraft Movie","year":"2025","intro":"方块世界","pic":{"large":""}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
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

	tmdbKey := "mock-key"
	tmdbBase := mockSrv.URL + "/3"
	doubanBase := mockSrv.URL + "/douban"
	trueVal := true
	falseVal := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		DoubanEnabled:  &trueVal,
		DoubanAPIBase:  &doubanBase,
		BangumiEnabled: &falseVal,
		AniListEnabled: &falseVal,
		ImdbEnabled:    &falseVal,
	}); err != nil {
		t.Fatal(err)
	}

	metaSvc := metadata.NewService(store)
	sc := NewScraper(store, metaSvc)
	ctx := context.Background()

	// 1. Direct TMDB hit populates WorkKey
	res1, err := sc.IdentifyPublic(ctx, PublicIdentifyRequest{
		Filename: "Inception.2010.1080p.mkv",
		Kind:     "movie",
	})
	if err != nil || !res1.Matched || res1.WorkKey != "tmdb:movie:27205" || res1.Source != "tmdb" {
		t.Fatalf("unexpected direct TMDB result: res=%+v err=%v", res1, err)
	}

	// 2. Douban CJK abbrev skeleton ("我的sj大电影") bridges back to TMDB
	y2025 := 2025
	res2, err := sc.IdentifyPublic(ctx, PublicIdentifyRequest{
		Title: "我的sj大电影",
		Year:  &y2025,
		Kind:  "movie",
	})
	if err != nil || !res2.Matched || res2.Source != "tmdb" || res2.BridgedFrom != "douban" || res2.WorkKey != "tmdb:movie:950387" {
		t.Fatalf("unexpected douban bridge result: res=%+v err=%v", res2, err)
	}

	// 3. Embedded IMDb ID bridges to TMDB
	res3, err := sc.IdentifyPublic(ctx, PublicIdentifyRequest{
		Filename: "SomeMovie [tt1375666].mkv",
		Kind:     "movie",
	})
	if err != nil || !res3.Matched || res3.WorkKey != "tmdb:movie:27205" {
		t.Fatalf("unexpected imdb bridge result: res=%+v err=%v", res3, err)
	}

	// 4. TMDB upstream outage fails strictly without silent fallback
	tmdbDown.Store(true)
	_, err = sc.IdentifyPublic(ctx, PublicIdentifyRequest{
		Title:   "UnknownOutageTest",
		Kind:    "movie",
		Refresh: true,
	})
	if !errors.Is(err, metadata.ErrTmdbUpstream) {
		t.Fatalf("expected ErrTmdbUpstream on outage, got %v", err)
	}
}
