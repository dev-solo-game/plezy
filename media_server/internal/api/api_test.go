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
	"strings"
	"testing"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/extserver"
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
		"config": map[string]any{"rootPath": mediaDir},
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

	// 5. Query task status, home & movie shelf
	tResp, err := cli.Get(ts.URL + "/api/v1/tasks/status")
	if err != nil || tResp.StatusCode != http.StatusOK {
		t.Fatalf("task status failed: %v", err)
	}
	tResp.Body.Close()

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

	// 7. Metadata inspector tables & security whitelist
	tblResp, err := cli.Get(ts.URL + "/api/v1/metadata/tables")
	if err != nil || tblResp.StatusCode != http.StatusOK {
		t.Fatalf("metadata tables list failed: %v", err)
	}
	var tblList struct {
		Tables []db.InspectTableInfo `json:"tables"`
	}
	_ = json.NewDecoder(tblResp.Body).Decode(&tblList)
	tblResp.Body.Close()
	if len(tblList.Tables) != 13 {
		t.Fatalf("expected 13 inspectable tables, got %d", len(tblList.Tables))
	}

	miResp, err := cli.Get(ts.URL + "/api/v1/metadata/tables/media_items?limit=10&offset=0")
	if err != nil || miResp.StatusCode != http.StatusOK {
		t.Fatalf("query media_items table failed: %v", err)
	}
	miResp.Body.Close()

	blockedResp, err := cli.Get(ts.URL + "/api/v1/metadata/tables/admin_account")
	if err != nil {
		t.Fatal(err)
	}
	blockedResp.Body.Close()
	if blockedResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for restricted table admin_account, got %d", blockedResp.StatusCode)
	}

	// 8. Live disk SPA index & immediate reload on HTML change without restarting server
	webDir := filepath.Join(dataDir, "web", "dist")
	if err := os.MkdirAll(webDir, 0o755); err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(webDir, "index.html")
	if err := os.WriteFile(indexPath, []byte("<!doctype html><html><body>TTPlay v1</body></html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv.SetWebDir(webDir)

	spaResp, err := cli.Get(ts.URL + "/")
	if err != nil || spaResp.StatusCode != http.StatusOK {
		t.Fatalf("SPA index failed: %v", err)
	}
	spaBody, _ := io.ReadAll(spaResp.Body)
	spaResp.Body.Close()
	if !bytes.Contains(spaBody, []byte("TTPlay v1")) {
		t.Fatalf("expected disk index.html v1, got: %q", string(spaBody))
	}

	if err := os.WriteFile(indexPath, []byte("<!doctype html><html><body>TTPlay v2</body></html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	spaResp2, err := cli.Get(ts.URL + "/some/client/route")
	if err != nil || spaResp2.StatusCode != http.StatusOK {
		t.Fatalf("SPA fallback after HTML update failed: %v", err)
	}
	spaBody2, _ := io.ReadAll(spaResp2.Body)
	spaResp2.Body.Close()
	if !bytes.Contains(spaBody2, []byte("TTPlay v2")) {
		t.Fatalf("expected updated disk index.html v2 immediately, got: %q", string(spaBody2))
	}
}

func TestExternalServerAPIEndToEnd(t *testing.T) {
	// 1. Setup TTPlay Server instance
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

	authSvc := auth.NewService(store)
	stMgr := storage.NewManager(nil, nil)
	defer stMgr.CloseAll()
	metaSvc := metadata.NewService(store)
	hub := events.NewHub()
	coord := library.NewCoordinator(store, stMgr, metaSvc, hub)
	srv := NewServer(store, authSvc, stMgr, metaSvc, hub, coord)

	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	jar, _ := cookiejar.New(nil)
	cli := &http.Client{Jar: jar}

	setupBody, _ := json.Marshal(map[string]string{
		"username":    "admin",
		"password":    "strongpass123",
		"server_name": "TTPlay ExtTest",
	})
	resp, err := cli.Post(ts.URL+"/api/v1/auth/setup", "application/json", bytes.NewReader(setupBody))
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("setup failed: %v", err)
	}
	resp.Body.Close()

	// 2. Mock upstream Jellyfin/Emby media server
	videoPayload := []byte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	mockMedia := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/System/Info/Public":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id":          "mock-jf-01",
				"ServerName":  "测试 Jellyfin",
				"Version":     "10.10.7",
				"ProductName": "Jellyfin Server",
			})
		case r.URL.Path == "/Users/AuthenticateByName" && r.Method == http.MethodPost:
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			if b["Username"] != "tester" || b["Pw"] != "pass123" {
				http.Error(w, "invalid", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"AccessToken": "jf-tok-secret",
				"User":        map[string]any{"Id": "jf-u1", "Name": "tester"},
			})
		case r.URL.Path == "/Users/jf-u1/Views":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{
					{"Id": "lib-mov", "Name": "电影", "CollectionType": "movies", "ImageTags": map[string]string{"Primary": "v1"}},
				},
			})
		case r.URL.Path == "/UserItems/Resume":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{}})
		case r.URL.Path == "/Users/jf-u1/Items/Latest":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"Id": "mov-99", "Name": "流浪地球2", "Type": "Movie", "ProductionYear": 2023, "ImageTags": map[string]string{"Primary": "p99"}},
			})
		case r.URL.Path == "/Users/jf-u1/Items/mov-99":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id":             "mov-99",
				"Name":           "流浪地球2",
				"Type":           "Movie",
				"ProductionYear": 2023,
				"ImageTags":      map[string]string{"Primary": "p99"},
				"MediaSources": []map[string]any{
					{"Id": "src-99", "Container": "mp4"},
				},
			})
		case r.URL.Path == "/Items/mov-99/Similar":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{}})
		case r.URL.Path == "/Items/mov-99/PlaybackInfo":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"PlaySessionId": "ps-99",
				"MediaSources": []map[string]any{
					{
						"Id":                   "src-99",
						"Container":            "mp4",
						"SupportsDirectStream": true,
						"SupportsTranscoding":  true,
						"TranscodingUrl":       "/Videos/mov-99/master.m3u8?MediaSourceId=src-99&PlaySessionId=ps-99",
						"MediaStreams": []map[string]any{
							{"Index": 0, "Type": "Video", "Codec": "h264", "Width": 1920, "Height": 1080},
							{"Index": 1, "Type": "Audio", "Codec": "aac"},
							{"Index": 2, "Type": "Subtitle", "Codec": "srt", "Language": "chi", "IsTextSubtitleStream": true},
						},
					},
				},
			})
		case r.URL.Path == "/Videos/mov-99/stream.mp4":
			if r.Header.Get("Range") == "bytes=0-9" {
				w.Header().Set("Content-Type", "video/mp4")
				w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-9/%d", len(videoPayload)))
				w.WriteHeader(http.StatusPartialContent)
				_, _ = w.Write(videoPayload[:10])
				return
			}
			w.Header().Set("Content-Type", "video/mp4")
			_, _ = w.Write(videoPayload)
		case r.URL.Path == "/Videos/mov-99/master.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts?ApiKey=jf-tok-secret\n#EXT-X-ENDLIST\n")
		case r.URL.Path == "/Videos/mov-99/seg0.ts":
			w.Header().Set("Content-Type", "video/mp2t")
			_, _ = w.Write([]byte("MOCK-TS-SEGMENT"))
		case r.URL.Path == "/Videos/mov-99/src-99/Subtitles/2/0/Stream.vtt":
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = io.WriteString(w, "1\n00:00:00,000 --> 00:00:02,000\n外部测试字幕\n")
		case r.URL.Path == "/Items/mov-99/Images/Primary":
			w.Header().Set("Content-Type", "image/jpeg")
			_, _ = w.Write([]byte("MOCK-JPEG"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer mockMedia.Close()

	// 3. Test connection
	testBody, _ := json.Marshal(map[string]any{
		"kind":      "jellyfin",
		"base_url":  mockMedia.URL,
		"auth_mode": "password",
		"username":  "tester",
		"password":  "pass123",
	})
	testResp, err := cli.Post(ts.URL+"/api/v1/ext-servers/test", "application/json", bytes.NewReader(testBody))
	if err != nil || testResp.StatusCode != http.StatusOK {
		t.Fatalf("test external server failed: %v", err)
	}
	testResp.Body.Close()

	// 4. Create external server
	createResp, err := cli.Post(ts.URL+"/api/v1/ext-servers", "application/json", bytes.NewReader(testBody))
	if err != nil || createResp.StatusCode != http.StatusOK {
		t.Fatalf("create external server failed: %v", err)
	}
	var createObj struct {
		Server db.ExternalServerRecord `json:"server"`
	}
	_ = json.NewDecoder(createResp.Body).Decode(&createObj)
	createResp.Body.Close()
	srvID := createObj.Server.ID
	if srvID == "" || createObj.Server.Name != "测试 Jellyfin" || !createObj.Server.HasToken {
		t.Fatalf("unexpected created external server: %+v", createObj.Server)
	}

	// 5. List & check Home
	homeResp, err := cli.Get(ts.URL + "/api/v1/ext/" + srvID + "/home")
	if err != nil || homeResp.StatusCode != http.StatusOK {
		t.Fatalf("ext home failed: %v", err)
	}
	var homeObj struct {
		Home extserver.ExtHomePayload `json:"home"`
	}
	_ = json.NewDecoder(homeResp.Body).Decode(&homeObj)
	homeResp.Body.Close()
	if len(homeObj.Home.Views) != 1 || len(homeObj.Home.LatestByView) != 1 || homeObj.Home.LatestByView[0].Items[0].ID != "mov-99" {
		t.Fatalf("unexpected ext home: %+v", homeObj.Home)
	}

	// 6. Item detail + image proxy
	detResp, err := cli.Get(ts.URL + "/api/v1/ext/" + srvID + "/items/mov-99")
	if err != nil || detResp.StatusCode != http.StatusOK {
		t.Fatalf("ext detail failed: %v", err)
	}
	var detObj struct {
		Detail extserver.ExtItemDetail `json:"detail"`
	}
	_ = json.NewDecoder(detResp.Body).Decode(&detObj)
	detResp.Body.Close()
	if detObj.Detail.Item.PosterURL == "" {
		t.Fatalf("expected proxied PosterURL")
	}
	imgResp, err := cli.Get(ts.URL + detObj.Detail.Item.PosterURL)
	if err != nil || imgResp.StatusCode != http.StatusOK {
		t.Fatalf("ext image proxy failed: %v", err)
	}
	imgBytes, _ := io.ReadAll(imgResp.Body)
	imgResp.Body.Close()
	if !bytes.Equal(imgBytes, []byte("MOCK-JPEG")) {
		t.Fatalf("unexpected image proxy payload: %q", string(imgBytes))
	}

	// 7. PlaybackInfo + Range Direct Stream + Rewritten HLS Proxy + Subtitle VTT
	pbResp, err := cli.Get(ts.URL + "/api/v1/ext/" + srvID + "/playback/mov-99")
	if err != nil || pbResp.StatusCode != http.StatusOK {
		t.Fatalf("ext playback info failed: %v", err)
	}
	var pbObj struct {
		Versions  []extPlaybackVersion  `json:"versions"`
		Subtitles []extPlaybackSubtitle `json:"subtitles"`
	}
	_ = json.NewDecoder(pbResp.Body).Decode(&pbObj)
	pbResp.Body.Close()
	if len(pbObj.Versions) != 1 || len(pbObj.Versions[0].Variants) < 2 || len(pbObj.Subtitles) != 1 {
		t.Fatalf("unexpected ext playback payload: %+v", pbObj)
	}

	// Range direct stream (token-only, no cookies)
	tokenCli := &http.Client{}
	sReq, _ := http.NewRequest(http.MethodGet, ts.URL+pbObj.Versions[0].StreamURL, nil)
	sReq.Header.Set("Range", "bytes=0-9")
	sResp, err := tokenCli.Do(sReq)
	if err != nil {
		t.Fatal(err)
	}
	sSlice, _ := io.ReadAll(sResp.Body)
	sResp.Body.Close()
	if sResp.StatusCode != http.StatusPartialContent || !bytes.Equal(sSlice, videoPayload[:10]) {
		t.Fatalf("ext range stream 206 failed: status=%d slice=%q", sResp.StatusCode, string(sSlice))
	}

	// HLS Master rewrite + signed segment fetch + tampered signature rejection
	m3u8Resp, err := tokenCli.Get(ts.URL + pbObj.Versions[0].Variants[0].StreamURL)
	if err != nil || m3u8Resp.StatusCode != http.StatusOK {
		t.Fatalf("ext hls master failed: %v", err)
	}
	m3u8Bytes, _ := io.ReadAll(m3u8Resp.Body)
	m3u8Resp.Body.Close()
	m3u8Text := string(m3u8Bytes)
	if strings.Contains(m3u8Text, "jf-tok-secret") || !strings.Contains(m3u8Text, "/api/v1/ext/"+srvID+"/hls-proxy?") {
		t.Fatalf("expected rewritten m3u8 without leaked token, got:\n%s", m3u8Text)
	}
	var segProxyPath string
	for _, line := range strings.Split(m3u8Text, "\n") {
		if strings.HasPrefix(line, "/api/v1/ext/") {
			segProxyPath = strings.TrimSpace(line)
			break
		}
	}
	if segProxyPath == "" {
		t.Fatalf("no rewritten segment URL found in m3u8")
	}
	segResp, err := tokenCli.Get(ts.URL + segProxyPath)
	if err != nil || segResp.StatusCode != http.StatusOK {
		t.Fatalf("ext hls-proxy segment failed: %v", err)
	}
	segData, _ := io.ReadAll(segResp.Body)
	segResp.Body.Close()
	if string(segData) != "MOCK-TS-SEGMENT" {
		t.Fatalf("unexpected hls segment data: %q", string(segData))
	}

	// Bad signature rejected
	badResp, err := tokenCli.Get(ts.URL + segProxyPath + "tampered")
	if err != nil {
		t.Fatal(err)
	}
	badResp.Body.Close()
	if badResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 for tampered hls-proxy sig, got %d", badResp.StatusCode)
	}

	// Subtitle converted to WEBVTT
	subResp, err := tokenCli.Get(ts.URL + pbObj.Subtitles[0].VttURL)
	if err != nil || subResp.StatusCode != http.StatusOK {
		t.Fatalf("ext subtitle failed: %v", err)
	}
	subData, _ := io.ReadAll(subResp.Body)
	subResp.Body.Close()
	if !bytes.Contains(subData, []byte("WEBVTT")) || !bytes.Contains(subData, []byte("外部测试字幕")) {
		t.Fatalf("unexpected ext subtitle payload: %s", string(subData))
	}

	// 8. Delete external server
	delReq, _ := http.NewRequest(http.MethodDelete, ts.URL+"/api/v1/ext-servers/"+srvID, nil)
	delResp, err := cli.Do(delReq)
	if err != nil || delResp.StatusCode != http.StatusOK {
		t.Fatalf("delete external server failed: %v", err)
	}
	delResp.Body.Close()
}
