package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/platform"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/source"
	"plezy/media_library/internal/vault"
)

func TestPublicMetadataEndpointsAndRouteAllowlist(t *testing.T) {
	tmdbDown := false
	var mockUpstream *httptest.Server
	mockUpstream = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasPrefix(p, "/3/"):
			if tmdbDown {
				w.WriteHeader(http.StatusBadGateway)
				_, _ = w.Write([]byte(`{"status_message":"tmdb outage"}`))
				return
			}
			switch p {
			case "/3/search/movie":
				q := r.URL.Query().Get("query")
				if strings.Contains(q, "Inception") || strings.Contains(q, "盗梦空间") {
					_, _ = w.Write([]byte(`{"results":[{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15","poster_path":"/inc.jpg"}]}`))
				} else if strings.Contains(q, "我的世界大电影") {
					_, _ = w.Write([]byte(`{"results":[{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04","poster_path":"/mc.jpg"}]}`))
				} else {
					_, _ = w.Write([]byte(`{"results":[]}`))
				}
			case "/3/search/tv":
				_, _ = w.Write([]byte(`{"results":[{"id":1399,"name":"权力的游戏","original_name":"Game of Thrones","first_air_date":"2011-04-17","poster_path":"/got.jpg"}]}`))
			case "/3/movie/27205":
				_, _ = w.Write([]byte(`{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15","vote_average":8.8,"poster_path":"/inc.jpg"}`))
			case "/3/movie/950387":
				_, _ = w.Write([]byte(`{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04","vote_average":7.1,"poster_path":"/mc.jpg"}`))
			case "/3/tv/1399":
				_, _ = w.Write([]byte(`{"id":1399,"name":"权力的游戏","original_name":"Game of Thrones","first_air_date":"2011-04-17","poster_path":"/got.jpg","seasons":[{"season_number":1}]}`))
			case "/3/tv/1399/season/1":
				_, _ = w.Write([]byte(`{"season_number":1,"name":"第 1 季","air_date":"2011-04-17","episodes":[{"episode_number":1,"name":"凛冬将至","air_date":"2011-04-17","runtime":62}]}`))
			default:
				_, _ = w.Write([]byte(`{"results":[]}`))
			}
		case strings.HasPrefix(p, "/douban"):
			switch p {
			case "/douban/search/subjects":
				_, _ = w.Write([]byte(`{"subjects":{"items":[{"target_type":"movie","target":{"id":"26149750","title":"我的世界大电影","card_subtitle":"2025 / 美国","pic":{"normal":"` + mockUpstream.URL + `/img/douban.jpg"}}}]}}`))
			case "/douban/movie/26149750":
				_, _ = w.Write([]byte(`{"id":"26149750","title":"我的世界大电影","original_title":"A Minecraft Movie","year":"2025","intro":"方块世界","pic":{"large":"` + mockUpstream.URL + `/img/douban.jpg"}}`))
			default:
				_, _ = w.Write([]byte(`{"items":[]}`))
			}
		case p == "/img/w342/inc.jpg" || p == "/img/douban.jpg":
			w.Header().Set("Content-Type", "image/jpeg")
			_, _ = w.Write([]byte("\xff\xd8\xff\xe0MOCK_REMOTE_IMG"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockUpstream.Close()

	dataDir := t.TempDir()
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	tmdbKey := "mock-key"
	tmdbBase := mockUpstream.URL + "/3"
	tmdbImgBase := mockUpstream.URL + "/img"
	doubanBase := mockUpstream.URL + "/douban"
	falseVal := false
	trueVal := true
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		TmdbImageBase:  &tmdbImgBase,
		DoubanEnabled:  &trueVal,
		DoubanAPIBase:  &doubanBase,
		BangumiEnabled: &falseVal,
		AniListEnabled: &falseVal,
		ImdbEnabled:    &falseVal,
	}); err != nil {
		t.Fatal(err)
	}

	metaSvc := metadata.NewService(store)
	scraper := library.NewScraper(store, metaSvc)
	hub := events.NewHub()
	limiter := security.NewLoginLimiter()
	platSvc, err := platform.NewService(store, limiter, "")
	if err != nil {
		t.Fatal(err)
	}
	accSvc := account.NewService(store, limiter)
	srcSvc := source.NewService(store, hub)
	ingSvc := ingest.NewService(store, hub, limiter)
	srv := NewServer(store, metaSvc, scraper, hub, platSvc, accSvc, srcSvc, ingSvc)
	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	// 1. Health & bootstrap
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status=%v err=%v", resp, err)
	}
	resp.Body.Close()

	resp, err = http.Get(ts.URL + "/api/v1/public/bootstrap")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("bootstrap status=%v err=%v", resp, err)
	}
	var boot struct {
		Code               int    `json:"code"`
		ServerName         string `json:"server_name"`
		ProtocolVersion    int    `json:"protocol_version"`
		MinProtocolVersion int    `json:"min_protocol_version"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&boot); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if boot.Code != 0 || boot.ServerName != db.DefaultServerName || boot.ProtocolVersion != 1 || boot.MinProtocolVersion != 1 {
		t.Fatalf("unexpected bootstrap payload: %+v", boot)
	}

	// 2. Deprecated G2 routes must return 404
	for _, deprecatedPath := range []string{"/api/v1/mounts", "/api/v1/stream/file/1", "/api/v1/ext-servers"} {
		dResp, dErr := http.Get(ts.URL + deprecatedPath)
		if dErr != nil {
			t.Fatalf("get %s: %v", deprecatedPath, dErr)
		}
		dResp.Body.Close()
		if dResp.StatusCode != http.StatusNotFound {
			t.Fatalf("deprecated route %s returned %d, want 404", deprecatedPath, dResp.StatusCode)
		}
	}

	// 3. Public metadata config + search
	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/config")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("metadata config status=%v err=%v", resp, err)
	}
	var cfgResp struct {
		AllowPublic bool     `json:"allow_public_metadata"`
		Tmdb        bool     `json:"tmdb_configured"`
		Providers   []string `json:"enabled_providers"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&cfgResp)
	resp.Body.Close()
	if !cfgResp.AllowPublic || !cfgResp.Tmdb || len(cfgResp.Providers) < 2 {
		t.Fatalf("unexpected public config: %+v", cfgResp)
	}

	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/search?q=Inception&kind=movie")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("search status=%v err=%v", resp, err)
	}
	var searchResp struct {
		Results []metadata.Candidate `json:"results"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&searchResp)
	resp.Body.Close()
	if len(searchResp.Results) == 0 || searchResp.Results[0].ID != "27205" {
		t.Fatalf("unexpected search results: %+v", searchResp.Results)
	}

	// 4. Public identify: direct TMDB + Douban bridge with WorkKey
	idBody, _ := json.Marshal(map[string]any{
		"title": "我的sj大电影",
		"year":  2025,
		"kind":  "movie",
	})
	resp, err = http.Post(ts.URL+"/api/v1/public/metadata/identify", "application/json", bytes.NewReader(idBody))
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("identify status=%v err=%v", resp, err)
	}
	var idResp struct {
		Matched     bool           `json:"matched"`
		WorkKey     string         `json:"work_key"`
		Source      string         `json:"source"`
		BridgedFrom string         `json:"bridged_from"`
		Work        *metadata.Work `json:"work"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&idResp)
	resp.Body.Close()
	if !idResp.Matched || idResp.Source != "tmdb" || idResp.BridgedFrom != "douban" || idResp.WorkKey != "tmdb:movie:950387" || idResp.Work == nil {
		t.Fatalf("unexpected identify response: %+v", idResp)
	}

	// 5. Work, season & batch endpoints
	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/work/tmdb/show/1399")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("work status=%v err=%v", resp, err)
	}
	resp.Body.Close()

	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/season/tmdb/1399/1")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("season status=%v err=%v", resp, err)
	}
	resp.Body.Close()

	batchReq, _ := json.Marshal(map[string]any{
		"works":   []map[string]any{{"provider": "tmdb", "kind": "movie", "id": "27205"}},
		"seasons": []map[string]any{{"provider": "tmdb", "id": "1399", "season": 1}},
	})
	resp, err = http.Post(ts.URL+"/api/v1/public/metadata/batch", "application/json", bytes.NewReader(batchReq))
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("batch status=%v err=%v", resp, err)
	}
	var batchResp struct {
		Works   map[string]metadata.Work   `json:"works"`
		Seasons map[string]metadata.Season `json:"seasons"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&batchResp)
	resp.Body.Close()
	if _, ok := batchResp.Works["tmdb:movie:27205"]; !ok {
		t.Fatalf("missing batch work: %+v", batchResp.Works)
	}
	if _, ok := batchResp.Seasons["tmdb:1399:1"]; !ok {
		t.Fatalf("missing batch season: %+v", batchResp.Seasons)
	}

	// 6. Remote artwork proxy
	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/artwork?src=" + url.QueryEscape("/inc.jpg") + "&size=w342")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("artwork status=%v err=%v", resp, err)
	}
	imgBytes, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Contains(imgBytes, []byte("MOCK_REMOTE_IMG")) {
		t.Fatalf("unexpected artwork body: %q", string(imgBytes))
	}

	// 7. TMDB upstream outage -> 502 Bad Gateway
	tmdbDown = true
	outageReq, _ := json.Marshal(map[string]any{
		"title":   "NonExistentOutage",
		"kind":    "movie",
		"refresh": true,
	})
	resp, err = http.Post(ts.URL+"/api/v1/public/metadata/identify", "application/json", bytes.NewReader(outageReq))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502 on TMDB outage, got %d", resp.StatusCode)
	}
	tmdbDown = false

	// 8. Disabling allow_public_metadata blocks anonymous requests with 403
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{AllowPublicMetadata: &falseVal}); err != nil {
		t.Fatal(err)
	}
	resp, err = http.Get(ts.URL + "/api/v1/public/metadata/config")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 when allow_public_metadata=false, got %d", resp.StatusCode)
	}

	// 9. Authenticated user token bypasses allow_public_metadata=false
	reg, err := accSvc.Register(account.RegisterRequest{
		Username: "auth_meta_user",
		Password: "Password123!",
		Device:   account.DeviceInput{Class: db.DeviceClassDesktop},
	}, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/public/metadata/config", nil)
	req.Header.Set("Authorization", "Bearer "+reg.AccessToken)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for authenticated user when allow_public_metadata=false, got %d", resp.StatusCode)
	}
}
