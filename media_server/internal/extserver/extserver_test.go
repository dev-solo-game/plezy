package extserver

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEmbyClientFlowAndPrefixFallback(t *testing.T) {
	var seenFavMethod, seenPlayedMethod string
	var seenReportPath string
	var seenAuthHeader string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAuthHeader = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")

		switch {
		case r.URL.Path == "/System/Info/Public":
			// Simulate reverse-proxied Emby under /emby prefix
			http.NotFound(w, r)
		case r.URL.Path == "/emby/System/Info/Public":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id":          "emby-machine-1",
				"ServerName":  "家庭 Emby",
				"Version":     "4.9.5.0",
				"ProductName": "Emby Server",
			})
		case r.URL.Path == "/emby/Users/AuthenticateByName" && r.Method == http.MethodPost:
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["Username"] != "alice" || body["Pw"] != "secret123" {
				http.Error(w, "bad creds", http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"AccessToken": "tok-emby-abc",
				"User": map[string]any{
					"Id":   "uid-emby-1",
					"Name": "alice",
				},
			})
		case r.URL.Path == "/emby/Users/uid-emby-1/Views":
			if r.Header.Get("X-Emby-Token") != "tok-emby-abc" {
				http.Error(w, "missing token", http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{
					{"Id": "view-mov", "Name": "电影库", "CollectionType": "movies", "ImageTags": map[string]string{"Primary": "t1"}},
				},
			})
		case r.URL.Path == "/emby/Users/uid-emby-1/Items/Latest":
			// Bare JSON array returned by /Items/Latest
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"Id":             "mov-1",
					"Name":           "星际穿越",
					"Type":           "Movie",
					"ProductionYear": 2014,
					"ImageTags":      map[string]string{"Primary": "tag-p1"},
					"UserData":       map[string]any{"Played": false, "IsFavorite": true, "PlaybackPositionTicks": 1200000000},
				},
			})
		case r.URL.Path == "/emby/Users/uid-emby-1/Items/Resume":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{
					{"Id": "ep-9", "Name": "S01E02", "Type": "Episode", "SeriesId": "ser-1", "SeriesName": "剧集A"},
				},
			})
		case r.URL.Path == "/emby/Users/uid-emby-1/FavoriteItems/mov-1":
			seenFavMethod = r.Method
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/emby/Users/uid-emby-1/PlayedItems/mov-1":
			seenPlayedMethod = r.Method
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/emby/Sessions/Playing/Progress":
			seenReportPath = r.URL.Path
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/emby/Items/mov-1/PlaybackInfo":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"PlaySessionId": "ps-emby-1",
				"MediaSources": []map[string]any{
					{
						"Id":                   "ms-1",
						"Container":            "mkv",
						"SupportsDirectPlay":   true,
						"SupportsDirectStream": true,
						"SupportsTranscoding":  true,
						"TranscodingUrl":       "/Videos/mov-1/master.m3u8?MediaSourceId=ms-1&PlaySessionId=ps-emby-1",
						"MediaStreams": []map[string]any{
							{"Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160, "VideoRangeType": "DOVI"},
							{"Index": 1, "Type": "Audio", "Codec": "ac3", "Language": "eng"},
							{"Index": 2, "Type": "Subtitle", "Codec": "ass", "Language": "chi", "IsTextSubtitleStream": true},
						},
					},
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	cli, err := NewClient(ServerConfig{
		ID:       "srv-e1",
		Kind:     "emby",
		BaseURL:  srv.URL,
		DeviceID: "dev-unit-1",
	})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	ctx := context.Background()
	authRes, err := cli.AuthenticateByName(ctx, "alice", "secret123")
	if err != nil {
		t.Fatalf("AuthenticateByName: %v", err)
	}
	if authRes.AccessToken != "tok-emby-abc" || authRes.UserID != "uid-emby-1" {
		t.Fatalf("unexpected auth result: %+v", authRes)
	}
	if authRes.ServerInfo.DetectedKind != "emby" || !strings.HasSuffix(authRes.ServerInfo.EffectiveBaseURL, "/emby") {
		t.Fatalf("expected emby prefix detection, got: %+v", authRes.ServerInfo)
	}
	if !strings.Contains(seenAuthHeader, `Client="TTPlay%20Server"`) {
		t.Fatalf("unexpected MediaBrowser Authorization header: %q", seenAuthHeader)
	}

	views, err := cli.GetViews(ctx)
	if err != nil || len(views) != 1 || views[0].Name != "电影库" {
		t.Fatalf("GetViews failed: views=%+v err=%v", views, err)
	}

	latest, err := cli.GetLatestItems(ctx, "view-mov", 10)
	if err != nil || len(latest) != 1 || latest[0].Title != "星际穿越" || latest[0].PositionMs != 120000 {
		t.Fatalf("GetLatestItems failed: latest=%+v err=%v", latest, err)
	}

	resume, err := cli.GetResumeItems(ctx, 10)
	if err != nil || len(resume) != 1 || resume[0].ID != "ep-9" {
		t.Fatalf("GetResumeItems failed: resume=%+v err=%v", resume, err)
	}

	if err := cli.SetFavorite(ctx, "mov-1", true); err != nil || seenFavMethod != http.MethodPost {
		t.Fatalf("SetFavorite failed: method=%q err=%v", seenFavMethod, err)
	}
	if err := cli.SetPlayed(ctx, "mov-1", false); err != nil || seenPlayedMethod != http.MethodDelete {
		t.Fatalf("SetPlayed failed: method=%q err=%v", seenPlayedMethod, err)
	}
	if err := cli.ReportPlayback(ctx, PlaybackReportReq{
		State:      "progress",
		ItemID:     "mov-1",
		PositionMs: 45000,
	}); err != nil || seenReportPath != "/emby/Sessions/Playing/Progress" {
		t.Fatalf("ReportPlayback failed: path=%q err=%v", seenReportPath, err)
	}

	pb, err := cli.GetPlaybackInfo(ctx, "mov-1", "")
	if err != nil || len(pb.MediaSources) != 1 {
		t.Fatalf("GetPlaybackInfo failed: pb=%+v err=%v", pb, err)
	}
	ms := pb.MediaSources[0]
	if ms.BrowserCompatible || ms.HdrFormat != "Dolby Vision" {
		t.Fatalf("expected incompatible browser audio warning & Dolby Vision, got: %+v", ms)
	}

	direct := cli.BuildDirectStreamURL("mov-1", "ms-1", "mkv", pb.PlaySessionID)
	if !strings.Contains(direct, "api_key=tok-emby-abc") {
		t.Fatalf("expected api_key query param on Emby stream URL, got: %s", direct)
	}
	hls := cli.BuildHLSMasterURL("mov-1", "ms-1", pb.PlaySessionID, 0, 0, 0, ms.TranscodingURL)
	if strings.Contains(hls, "/emby/emby/") {
		t.Fatalf("should not double /emby prefix in resolved HLS URL: %s", hls)
	}
}

func TestJellyfinModernRoutesAndAPIKey(t *testing.T) {
	var playedRouteHit string
	var favRouteHit string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/System/Info/Public":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id":          "jf-machine-1",
				"ServerName":  "公益 Jellyfin",
				"Version":     "10.10.7",
				"ProductName": "Jellyfin Server",
			})
		case r.URL.Path == "/System/Info":
			if r.Header.Get("X-Emby-Token") != "jf-apikey-999" {
				http.Error(w, "unauth", http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"Id": "jf-machine-1"})
		case r.URL.Path == "/Users":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"Id": "jf-u1", "Name": "bob", "Policy": map[string]any{"IsAdministrator": true, "IsDisabled": false}},
			})
		case r.URL.Path == "/UserItems/Resume":
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{}})
		case r.URL.Path == "/UserPlayedItems/m-2":
			playedRouteHit = r.URL.Path
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/UserFavoriteItems/m-2":
			favRouteHit = r.URL.Path
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/Users/jf-u1/Items":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"TotalRecordCount": 2,
				"Items": []map[string]any{
					{"Id": "m-2", "Name": "Movie Two", "Type": "Movie"},
					{"Id": "s-2", "Name": "Show Two", "Type": "Series"},
				},
			})
		case r.URL.Path == "/Users/jf-u1/Items/s-2":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id": "s-2", "Name": "Show Two", "Type": "Series",
			})
		case r.URL.Path == "/Shows/s-2/Seasons":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{{"Id": "sea-1", "Name": "Season 1", "Type": "Season", "IndexNumber": 1}},
			})
		case r.URL.Path == "/Shows/s-2/Episodes":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{{"Id": "ep-1", "Name": "Pilot", "Type": "Episode", "ParentIndexNumber": 1, "IndexNumber": 1}},
			})
		case r.URL.Path == "/Shows/NextUp":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Items": []map[string]any{{"Id": "ep-1", "Name": "Pilot", "Type": "Episode", "ParentIndexNumber": 1, "IndexNumber": 1}},
			})
		case r.URL.Path == "/Items/s-2/Similar":
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	cli, err := NewClient(ServerConfig{
		ID:      "srv-jf1",
		Kind:    "jellyfin",
		BaseURL: srv.URL,
	})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	ctx := context.Background()
	authRes, err := cli.VerifyAPIKey(ctx, "jf-apikey-999", "bob")
	if err != nil {
		t.Fatalf("VerifyAPIKey: %v", err)
	}
	if authRes.UserID != "jf-u1" || authRes.ServerInfo.DetectedKind != "jellyfin" {
		t.Fatalf("unexpected VerifyAPIKey result: %+v", authRes)
	}

	if _, err := cli.GetResumeItems(ctx, 10); err != nil {
		t.Fatalf("GetResumeItems: %v", err)
	}
	if err := cli.SetPlayed(ctx, "m-2", true); err != nil || playedRouteHit != "/UserPlayedItems/m-2" {
		t.Fatalf("expected Jellyfin /UserPlayedItems route, got %q err=%v", playedRouteHit, err)
	}
	if err := cli.SetFavorite(ctx, "m-2", true); err != nil || favRouteHit != "/UserFavoriteItems/m-2" {
		t.Fatalf("expected Jellyfin /UserFavoriteItems route, got %q err=%v", favRouteHit, err)
	}

	sr, err := cli.Search(ctx, "Two", 20)
	if err != nil || len(sr.Movies) != 1 || len(sr.Shows) != 1 {
		t.Fatalf("Search failed: sr=%+v err=%v", sr, err)
	}

	detail, err := cli.GetItemDetail(ctx, "s-2")
	if err != nil || len(detail.Seasons) != 1 || len(detail.Episodes) != 1 || detail.OnDeckEpisode == nil || detail.OnDeckEpisode.ID != "ep-1" {
		t.Fatalf("GetItemDetail failed: detail=%+v err=%v", detail, err)
	}

	direct := cli.BuildDirectStreamURL("ep-1", "ms-2", "mp4", "")
	if !strings.Contains(direct, "ApiKey=jf-apikey-999") {
		t.Fatalf("expected ApiKey query param on Jellyfin stream URL: %s", direct)
	}
}
