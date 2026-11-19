package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/vault"
)

func TestPublicMetadataEndpointsAndArtworkToken(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	mediaDir := filepath.Join(root, "media")
	if err := os.MkdirAll(mediaDir, 0o755); err != nil {
		t.Fatal(err)
	}
	posterBytes := []byte("\xff\xd8\xff\xe0LOCAL_ARTWORK")
	if err := os.WriteFile(filepath.Join(mediaDir, "poster.jpg"), posterBytes, 0o644); err != nil {
		t.Fatal(err)
	}

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
			case "/3/find/tt3566834":
				_, _ = w.Write([]byte(`{"movie_results":[{"id":950387,"title":"我的世界大电影","original_title":"A Minecraft Movie","release_date":"2025-04-04","poster_path":"/mc.jpg"}]}`))
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
		case strings.HasPrefix(p, "/System/Info"):
			_, _ = w.Write([]byte(`{"ServerName":"MockEmby","Version":"4.8"}`))
		case p == "/Items/ext100/Images/Primary":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("\x89PNG\r\n\x1a\nMOCK_EXT_IMG"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockUpstream.Close()

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

	// Setup admin to obtain a bearer session token, local mount, and external server
	sess, err := authSvc.SetupAdmin("admin", "pass1234", "test", "pc", "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	tmdbKey := "mock-key"
	tmdbBase := mockUpstream.URL + "/3"
	tmdbImgBase := mockUpstream.URL + "/img"
	doubanBase := mockUpstream.URL + "/douban"
	falseVal := false
	trueVal := true
	_, err = store.UpdateServerSettings(db.ServerSettingsUpdate{
		TmdbAPIKey:     &tmdbKey,
		TmdbAPIBase:    &tmdbBase,
		TmdbImageBase:  &tmdbImgBase,
		DoubanEnabled:  &trueVal,
		DoubanAPIBase:  &doubanBase,
		BangumiEnabled: &falseVal,
		AniListEnabled: &falseVal,
		ImdbEnabled:    &falseVal,
	})
	if err != nil {
		t.Fatal(err)
	}

	mRec, err := store.CreateMount(
		"本地测试",
		"local",
		map[string]any{"rootPath": mediaDir},
		nil,
		true,
	)
	if err != nil {
		t.Fatal(err)
	}
	extRec, err := store.CreateExternalServer(db.ExternalServerRecord{
		Name:     "MockEmby",
		Kind:     "emby",
		BaseURL:  mockUpstream.URL,
		AuthMode: "apikey",
		Secrets:  map[string]string{"token": "emby-secret"},
		Enabled:  true,
	})
	if err != nil {
		t.Fatal(err)
	}

	unauthCli := &http.Client{}

	// 1. Config (unauthenticated)
	cfgResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/config")
	if err != nil || cfgResp.StatusCode != http.StatusOK {
		t.Fatalf("public metadata config failed: status=%v err=%v", cfgResp, err)
	}
	var cfgObj struct {
		Code             int      `json:"code"`
		AllowPublic      bool     `json:"allow_public_metadata"`
		TmdbConfigured   bool     `json:"tmdb_configured"`
		ArtworkProxyPath string   `json:"artwork_proxy_path"`
		EnabledProviders []string `json:"enabled_providers"`
	}
	_ = json.NewDecoder(cfgResp.Body).Decode(&cfgObj)
	cfgResp.Body.Close()
	if !cfgObj.AllowPublic || !cfgObj.TmdbConfigured || cfgObj.ArtworkProxyPath != publicMetadataArtworkPath {
		t.Fatalf("unexpected public metadata config: %+v", cfgObj)
	}

	// 2. Search (unauthenticated)
	sResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/search?q=" + url.QueryEscape("盗梦空间") + "&kind=movie&provider=tmdb")
	if err != nil || sResp.StatusCode != http.StatusOK {
		t.Fatalf("public metadata search failed: status=%v err=%v", sResp, err)
	}
	var sObj struct {
		Results []metadata.Candidate `json:"results"`
	}
	_ = json.NewDecoder(sResp.Body).Decode(&sObj)
	sResp.Body.Close()
	if len(sObj.Results) == 0 || sObj.Results[0].ID != "27205" {
		t.Fatalf("expected tmdb 27205 in public search, got %+v", sObj.Results)
	}

	// 3. Work + Season + Batch (unauthenticated)
	wResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/work/tmdb/show/1399")
	if err != nil || wResp.StatusCode != http.StatusOK {
		t.Fatalf("public work failed: status=%v err=%v", wResp, err)
	}
	var wObj struct {
		Work metadata.Work `json:"work"`
	}
	_ = json.NewDecoder(wResp.Body).Decode(&wObj)
	wResp.Body.Close()
	if wObj.Work.Title != "权力的游戏" {
		t.Fatalf("unexpected work title: %+v", wObj.Work)
	}

	snResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/season/tmdb/1399/1")
	if err != nil || snResp.StatusCode != http.StatusOK {
		t.Fatalf("public season failed: status=%v err=%v", snResp, err)
	}
	var snObj struct {
		Season metadata.Season `json:"season"`
	}
	_ = json.NewDecoder(snResp.Body).Decode(&snObj)
	snResp.Body.Close()
	if len(snObj.Season.Episodes) != 1 || *snObj.Season.Episodes[0].Title != "凛冬将至" {
		t.Fatalf("unexpected season episodes: %+v", snObj.Season)
	}

	batchReqBody, _ := json.Marshal(map[string]any{
		"works":   []map[string]any{{"provider": "tmdb", "kind": "movie", "id": "27205"}},
		"seasons": []map[string]any{{"provider": "tmdb", "id": "1399", "season": 1}},
	})
	bResp, err := unauthCli.Post(ts.URL+"/api/v1/public/metadata/batch", "application/json", bytes.NewReader(batchReqBody))
	if err != nil || bResp.StatusCode != http.StatusOK {
		t.Fatalf("public batch failed: status=%v err=%v", bResp, err)
	}
	var bObj struct {
		Works   map[string]metadata.Work   `json:"works"`
		Seasons map[string]metadata.Season `json:"seasons"`
	}
	_ = json.NewDecoder(bResp.Body).Decode(&bObj)
	bResp.Body.Close()
	if bObj.Works["tmdb:movie:27205"].Title != "盗梦空间" || len(bObj.Seasons["tmdb:1399:1"].Episodes) != 1 {
		t.Fatalf("unexpected batch result: works=%+v seasons=%+v", bObj.Works, bObj.Seasons)
	}

	// 4. Identify (Douban cjkAbbrev -> bridge to TMDB) without mutating DB
	yr2025 := 2025
	idBody, _ := json.Marshal(library.PublicIdentifyRequest{
		Title: "我的sj大电影",
		Year:  &yr2025,
		Kind:  "movie",
	})
	idResp, err := unauthCli.Post(ts.URL+"/api/v1/public/metadata/identify", "application/json", bytes.NewReader(idBody))
	if err != nil || idResp.StatusCode != http.StatusOK {
		t.Fatalf("public identify failed: status=%v err=%v", idResp, err)
	}
	var idObj struct {
		Matched     bool           `json:"matched"`
		Source      string         `json:"source"`
		BridgedFrom string         `json:"bridged_from"`
		Work        *metadata.Work `json:"work"`
	}
	_ = json.NewDecoder(idResp.Body).Decode(&idObj)
	idResp.Body.Close()
	if !idObj.Matched || idObj.Source != "tmdb" || idObj.BridgedFrom != "douban" || idObj.Work == nil || idObj.Work.ExternalID != "950387" {
		t.Fatalf("expected bridged tmdb:950387 from douban, got %+v", idObj)
	}

	// 5. Strict TMDB outage guard on /identify
	tmdbDown = true
	outageBody, _ := json.Marshal(library.PublicIdentifyRequest{
		Title: "Uncached Title During Outage",
		Kind:  "movie",
	})
	outageResp, err := unauthCli.Post(ts.URL+"/api/v1/public/metadata/identify", "application/json", bytes.NewReader(outageBody))
	if err != nil {
		t.Fatal(err)
	}
	outageResp.Body.Close()
	if outageResp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502 on TMDB outage in /identify, got %d", outageResp.StatusCode)
	}
	tmdbDown = false

	// 6. Public artwork proxy (unauthenticated)
	pubArtResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/artwork?src=/inc.jpg&size=w342")
	if err != nil || pubArtResp.StatusCode != http.StatusOK {
		t.Fatalf("public artwork proxy failed: status=%v err=%v", pubArtResp, err)
	}
	pubArtResp.Body.Close()

	// 7. Query-token authentication on self-hosted local/remote/ext artwork endpoints
	tokQ := url.QueryEscape(sess.AccessToken)
	localUnauth, _ := unauthCli.Get(ts.URL + "/api/v1/artwork/local/" + mRec.ID + "?path=/poster.jpg")
	localUnauth.Body.Close()
	if localUnauth.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token on local artwork, got %d", localUnauth.StatusCode)
	}
	localTokResp, err := unauthCli.Get(ts.URL + "/api/v1/artwork/local/" + mRec.ID + "?path=/poster.jpg&token=" + tokQ)
	if err != nil || localTokResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with query token on local artwork, got %v %v", localTokResp, err)
	}
	localTokResp.Body.Close()

	remoteTokResp, err := unauthCli.Get(ts.URL + "/api/v1/artwork/remote?src=/inc.jpg&size=w342&token=" + tokQ)
	if err != nil || remoteTokResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with query token on remote artwork, got %v %v", remoteTokResp, err)
	}
	remoteTokResp.Body.Close()

	extTokResp, err := unauthCli.Get(ts.URL + "/api/v1/ext/" + extRec.ID + "/image/ext100/Primary?token=" + tokQ)
	if err != nil || extTokResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with query token on ext artwork, got %v %v", extTokResp, err)
	}
	extTokResp.Body.Close()

	// 8. Disabling allow_public_metadata blocks unauthenticated public calls while allowing authed admin
	_, err = store.UpdateServerSettings(db.ServerSettingsUpdate{AllowPublicMetadata: &falseVal})
	if err != nil {
		t.Fatal(err)
	}
	blockedResp, err := unauthCli.Get(ts.URL + "/api/v1/public/metadata/config")
	if err != nil {
		t.Fatal(err)
	}
	blockedResp.Body.Close()
	if blockedResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 when allow_public_metadata=false, got %d", blockedResp.StatusCode)
	}
	authedReq, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/public/metadata/config", nil)
	authedReq.Header.Set("Authorization", "Bearer "+sess.AccessToken)
	authedResp, err := unauthCli.Do(authedReq)
	if err != nil || authedResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for authenticated admin even when public disabled, got %v %v", authedResp, err)
	}
	authedResp.Body.Close()
}
