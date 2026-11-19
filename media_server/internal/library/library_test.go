package library

import (
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &key,
		TmdbAPIBase:    &apiBase,
		BangumiAPIBase: &bgmBase,
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
}
