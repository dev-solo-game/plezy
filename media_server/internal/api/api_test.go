package api

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/vault"
)

func buildTestMP4(width, height uint16) []byte {
	box := func(t string, body []byte) []byte {
		out := make([]byte, 8+len(body))
		binary.BigEndian.PutUint32(out[:4], uint32(len(out)))
		copy(out[4:8], t)
		copy(out[8:], body)
		return out
	}
	ftyp := box("ftyp", []byte("isom\x00\x00\x02\x00isom"))
	mvhdBody := make([]byte, 100)
	binary.BigEndian.PutUint32(mvhdBody[12:16], 1000)
	binary.BigEndian.PutUint32(mvhdBody[16:20], 60000)
	mvhd := box("mvhd", mvhdBody)

	tkhdBody := make([]byte, 84)
	tkhdBody[3] = 1
	tkhd := box("tkhd", tkhdBody)

	mdhdBody := make([]byte, 24)
	binary.BigEndian.PutUint32(mdhdBody[12:16], 1000)
	binary.BigEndian.PutUint32(mdhdBody[16:20], 60000)
	mdhd := box("mdhd", mdhdBody)

	hdlrBody := make([]byte, 24)
	copy(hdlrBody[8:12], "vide")
	hdlr := box("hdlr", hdlrBody)

	vEntry := make([]byte, 78)
	binary.BigEndian.PutUint16(vEntry[24:26], width)
	binary.BigEndian.PutUint16(vEntry[26:28], height)
	stsdBody := make([]byte, 8)
	binary.BigEndian.PutUint32(stsdBody[4:8], 1)
	stsdBody = append(stsdBody, box("avc1", vEntry)...)
	stsd := box("stsd", stsdBody)

	stbl := box("stbl", stsd)
	minf := box("minf", stbl)
	mdia := box("mdia", append(append(mdhd, hdlr...), minf...))
	trak := box("trak", append(tkhd, mdia...))
	moov := box("moov", append(mvhd, trak...))
	return append(ftyp, moov...)
}

func TestEndToEndMediaServerAPI(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	mediaDir := filepath.Join(root, "media")
	movieSub := filepath.Join(mediaDir, "Dune Part Two (2024)")
	if err := os.MkdirAll(movieSub, 0o755); err != nil {
		t.Fatal(err)
	}
	mp4Bytes := buildTestMP4(1920, 1080)
	if err := os.WriteFile(filepath.Join(movieSub, "Dune Part Two (2024).mp4"), mp4Bytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(movieSub, "Dune Part Two (2024).zh.srt"), []byte("1\n00:00:01,000 --> 00:00:03,000\n中文字幕\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(movieSub, "poster.jpg"), []byte("\xff\xd8\xff\xe0POSTER"), 0o644); err != nil {
		t.Fatal(err)
	}

	mockTmdb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/movie":
			_, _ = w.Write([]byte(`{"results":[{"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27","poster_path":"/d2.jpg"}]}`))
		case "/3/movie/693134":
			_, _ = w.Write([]byte(`{"id":693134,"title":"沙丘2","original_title":"Dune: Part Two","release_date":"2024-02-27","vote_average":8.5,"poster_path":"/d2.jpg","backdrop_path":"/d2bg.jpg","genres":[{"id":878,"name":"科幻"}]}`))
		default:
			_, _ = w.Write([]byte(`{"results":[]}`))
		}
	}))
	defer mockTmdb.Close()

	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	authSvc := auth.NewService(store)
	hub := events.NewHub()
	stMgr := storage.NewManager(nil, nil)
	defer stMgr.CloseAll()
	metaSvc := metadata.NewService(store)
	coord := library.NewCoordinator(store, stMgr, metaSvc, hub)
	coord.Start()
	defer coord.Stop()

	srv := NewServer(store, authSvc, stMgr, metaSvc, hub, coord)
	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	jar, _ := cookiejar.New(nil)
	cli := &http.Client{Jar: jar}

	// 1. Bootstrap uninitialized + auth guard
	resp, err := cli.Get(ts.URL + "/api/v1/public/bootstrap")
	if err != nil {
		t.Fatal(err)
	}
	var boot map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&boot)
	resp.Body.Close()
	if boot["initialized"] != false {
		t.Fatalf("expected uninitialized, got %+v", boot)
	}

	unauthResp, err := cli.Get(ts.URL + "/api/v1/home")
	if err != nil {
		t.Fatal(err)
	}
	unauthResp.Body.Close()
	if unauthResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 before login, got %d", unauthResp.StatusCode)
	}

	// 2. Setup admin & configure mock TMDB
	setupBody, _ := json.Marshal(map[string]any{
		"username":    "admin",
		"password":    "pass1234",
		"server_name": "客厅影院",
		"tmdb_api_key": "k1",
	})
	setupResp, err := cli.Post(ts.URL+"/api/v1/auth/setup", "application/json", bytes.NewReader(setupBody))
	if err != nil || setupResp.StatusCode != http.StatusOK {
		t.Fatalf("setup failed: status=%v err=%v", setupResp, err)
	}
	setupResp.Body.Close()

	apiBase := mockTmdb.URL + "/3"
	_, _ = store.UpdateServerSettings(db.ServerSettingsUpdate{TmdbAPIBase: &apiBase})

	// 3. Preview mount browsing before/after creating mount
	prevReq, _ := json.Marshal(map[string]any{
		"kind":   "local",
		"config": map[string]any{"rootPath": tmp},
		"path":   "/",
	})
	prevResp, err := cli.Post(ts.URL+"/api/v1/mounts/browse-preview", "application/json", bytes.NewReader(prevReq))
	if err != nil || prevResp.StatusCode != http.StatusOK {
		t.Fatalf("browse-preview failed: err=%v status=%v", err, prevResp)
	}
	var prevObj struct {
		Dirs []storage.Entry `json:"dirs"`
	}
	_ = json.NewDecoder(prevResp.Body).Decode(&prevObj)
	prevResp.Body.Close()
	if len(prevObj.Dirs) == 0 {
		t.Fatalf("expected dirs from browse-preview, got 0")
	}

	// Create local mount (disable auto_scan so we test explicit sync scan cleanly)
	mountReq, _ := json.Marshal(map[string]any{
		"name":      "本地影视",
		"kind":      "local",
		"config":    map[string]any{"rootPath": mediaDir},
		"auto_scan": false,
	})
	mResp, err := cli.Post(ts.URL+"/api/v1/mounts", "application/json", bytes.NewReader(mountReq))
	if err != nil || mResp.StatusCode != http.StatusOK {
		t.Fatalf("create mount failed: %v", err)
	}
	var mPayload struct {
		Mount db.MountRecord `json:"mount"`
	}
	_ = json.NewDecoder(mResp.Body).Decode(&mPayload)
	mResp.Body.Close()

	// 4. Synchronous scan + scrape
	scanResp, err := cli.Post(ts.URL+"/api/v1/mounts/"+mPayload.Mount.ID+"/scan?sync=1", "application/json", nil)
	if err != nil || scanResp.StatusCode != http.StatusOK {
		t.Fatalf("sync scan failed: %v", err)
	}
	scanResp.Body.Close()

	// 5. Query home & movie shelf
	homeResp, err := cli.Get(ts.URL + "/api/v1/home")
	if err != nil {
		t.Fatal(err)
	}
	var homeObj struct {
		Home db.HomePayload `json:"home"`
	}
	_ = json.NewDecoder(homeResp.Body).Decode(&homeObj)
	homeResp.Body.Close()
	if homeObj.Home.Counts["movie"] != 1 {
		t.Fatalf("expected 1 movie in home counts, got %+v", homeObj.Home.Counts)
	}

	itemsResp, err := cli.Get(ts.URL + "/api/v1/library/items?shelf=movie&quality=1080p")
	if err != nil {
		t.Fatal(err)
	}
	var pageObj struct {
		Items []db.MediaItem `json:"items"`
		Total int            `json:"total"`
	}
	_ = json.NewDecoder(itemsResp.Body).Decode(&pageObj)
	itemsResp.Body.Close()
	if pageObj.Total != 1 || pageObj.Items[0].Title != "沙丘2" {
		t.Fatalf("unexpected library items: %+v", pageObj)
	}
	itemID := pageObj.Items[0].ID

	// 6. Playback info + Range stream without cookie (token-only) + subtitle VTT + local artwork
	pbResp, err := cli.Get(fmt.Sprintf("%s/api/v1/playback/info/%d", ts.URL, itemID))
	if err != nil || pbResp.StatusCode != http.StatusOK {
		t.Fatalf("playback info failed: %v", err)
	}
	var pbObj struct {
		Versions  []playbackVersionInfo  `json:"versions"`
		Subtitles []playbackSubtitleInfo `json:"subtitles"`
	}
	_ = json.NewDecoder(pbResp.Body).Decode(&pbObj)
	pbResp.Body.Close()
	if len(pbObj.Versions) != 1 || len(pbObj.Subtitles) != 1 {
		t.Fatalf("unexpected playback versions/subtitles: %+v", pbObj)
	}

	// Token-only HTTP client (no cookies) simulating external player / video tag
	tokenClient := &http.Client{}
	sReq, _ := http.NewRequest(http.MethodGet, ts.URL+pbObj.Versions[0].StreamURL, nil)
	sReq.Header.Set("Range", "bytes=0-15")
	sResp, err := tokenClient.Do(sReq)
	if err != nil {
		t.Fatal(err)
	}
	gotSlice, _ := io.ReadAll(sResp.Body)
	sResp.Body.Close()
	if sResp.StatusCode != http.StatusPartialContent || !bytes.Equal(gotSlice, mp4Bytes[:16]) {
		t.Fatalf("stream 206 failed: status=%d len=%d", sResp.StatusCode, len(gotSlice))
	}

	subResp, err := tokenClient.Get(ts.URL + pbObj.Subtitles[0].VttURL)
	if err != nil {
		t.Fatal(err)
	}
	subText, _ := io.ReadAll(subResp.Body)
	subResp.Body.Close()
	if subResp.StatusCode != http.StatusOK || !bytes.Contains(subText, []byte("WEBVTT")) || !bytes.Contains(subText, []byte("中文字幕")) {
		t.Fatalf("subtitle VTT failed: status=%d body=%s", subResp.StatusCode, string(subText))
	}

	artResp, err := cli.Get(fmt.Sprintf("%s/api/v1/artwork/local/%s?path=%s", ts.URL, mPayload.Mount.ID, url.QueryEscape("/Dune Part Two (2024)/poster.jpg")))
	if err != nil {
		t.Fatal(err)
	}
	artBytes, _ := io.ReadAll(artResp.Body)
	artResp.Body.Close()
	if artResp.StatusCode != http.StatusOK || !bytes.Contains(artBytes, []byte("POSTER")) {
		t.Fatalf("local artwork failed: status=%d", artResp.StatusCode)
	}

	// 7. Embedded SPA index
	spaResp, err := cli.Get(ts.URL + "/")
	if err != nil || spaResp.StatusCode != http.StatusOK {
		t.Fatalf("SPA index failed: %v", err)
	}
	spaResp.Body.Close()
}
