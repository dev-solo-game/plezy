package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/identify"
)

func TestS4MetadataQuotaUnmatchedManualMatchRulesEditAndRescrape(t *testing.T) {
	mockSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/3/search/movie":
			q := r.URL.Query().Get("query")
			if strings.Contains(q, "Inception") {
				_, _ = w.Write([]byte(`{"results":[{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15"}]}`))
				return
			}
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/search/tv":
			_, _ = w.Write([]byte(`{"results":[]}`))
		case "/3/movie/27205":
			_, _ = w.Write([]byte(`{"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-15","imdb_id":"tt1375666"}`))
		case "/3/movie/157336":
			_, _ = w.Write([]byte(`{"id":157336,"title":"星际穿越","original_title":"Interstellar","release_date":"2014-11-05"}`))
		case "/3/person/6193":
			_, _ = w.Write([]byte(`{"id":6193,"name":"Leonardo DiCaprio","biography":"Actor"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockSrv.Close()

	srv, store, advance := newTestAPIServer(t, "")
	tmdbKey := "mock-key"
	tmdbBase := mockSrv.URL + "/3"
	f := false
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		AllowPublicMetadata: &f,
		TmdbAPIKey:          &tmdbKey,
		TmdbAPIBase:         &tmdbBase,
		DoubanEnabled:       &f,
		BangumiEnabled:      &f,
		AniListEnabled:      &f,
		ImdbEnabled:         &f,
	}); err != nil {
		t.Fatal(err)
	}

	tok1, hh1, _, _ := mustRegisterAndLoginDevice(t, srv, "s4_hh1", db.DeviceClassDesktop, "10.8.0.1:1000", true)
	tok2, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s4_hh2", db.DeviceClassDesktop, "10.8.0.2:1000", true)

	// 1. Authenticated metadata endpoints work even when allow_public_metadata=false!
	pubSearch := doJSONReq(srv, http.MethodGet, "/api/v1/public/metadata/search?q=Inception", "", "", nil, nil)
	if pubSearch.Code != http.StatusForbidden {
		t.Fatalf("expected unauthenticated public search 403 when disabled, got %d", pubSearch.Code)
	}
	authSearch := doJSONReq(srv, http.MethodGet, "/api/v1/metadata/search?q=Inception", tok1, "", nil, nil)
	if authSearch.Code != http.StatusOK {
		t.Fatalf("expected auth search 200, got %d %s", authSearch.Code, authSearch.Body.String())
	}
	authPerson := doJSONReq(srv, http.MethodGet, "/api/v1/metadata/people?provider=tmdb&id=6193", tok1, "", nil, nil)
	if authPerson.Code != http.StatusOK || !strings.Contains(authPerson.Body.String(), "Leonardo DiCaprio") {
		t.Fatalf("expected auth person 200, got %d %s", authPerson.Code, authPerson.Body.String())
	}
	authIdent := doJSONReq(srv, http.MethodPost, "/api/v1/metadata/identify", tok1, "", nil, map[string]any{
		"filename": "Inception.2010.mkv",
		"kind":     "movie",
	})
	if authIdent.Code != http.StatusOK || !strings.Contains(authIdent.Body.String(), "tmdb:movie:27205") {
		t.Fatalf("expected auth identify match, got %d %s", authIdent.Code, authIdent.Body.String())
	}

	// 2. Create source, upload an unmatched mystery file & a matched movie via ingest batch + identify worker.
	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", tok1, "", nil, map[string]any{
		"kind": "quark", "name": "Quark S4", "identity_key": "qk_s4", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/Movies"}},
	})
	if srcRes.Code != http.StatusOK {
		t.Fatal(srcRes.Body.String())
	}
	var srcOut struct {
		Source struct {
			ID string `json:"id"`
		} `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &srcOut)

	sessRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+srcOut.Source.ID+"/scan-sessions", tok1, "", nil, map[string]any{"type": "full"})
	if sessRes.Code != http.StatusOK {
		t.Fatal(sessRes.Body.String())
	}
	var sessOut struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	_ = json.Unmarshal(sessRes.Body.Bytes(), &sessOut)

	batchRes := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sessOut.Session.ID+"/batches", tok1, "", nil, map[string]any{
		"batch_no": 1,
		"upserts": []map[string]any{
			{"path": "/Movies/Inception.2010.mkv", "size": 1000, "mtime_s": 1000},
			{"path": "/Movies/Unknown Mystery XYZ.mkv", "size": 2000, "mtime_s": 1001},
		},
	})
	if batchRes.Code != http.StatusOK {
		t.Fatal(batchRes.Body.String())
	}
	_ = doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sessOut.Session.ID+"/complete", tok1, "", nil, map[string]any{"final_batch_no": 1})

	// Advance past 10s ingest debounce and run identify worker directly.
	advance(15 * time.Second)
	srv.SetIdentifyQueue(identify.NewQueue(store, srv.Scraper, srv.Hub, identify.WithClock(func() time.Time {
		return time.UnixMilli(store.NowMs()).Add(20 * time.Second)
	})))
	// Update store clock via direct ProcessOne on not_before-expired rows.
	_, _ = store.DB().Exec(`UPDATE identify_queue SET not_before = 0 WHERE household_id = ?`, hh1)
	for {
		did, pErr := srv.Idf.ProcessOne(context.Background())
		if pErr != nil {
			t.Fatal(pErr)
		}
		if !did {
			break
		}
	}

	// Verify Unknown Mystery XYZ appears in /api/v1/library/unmatched.
	unmRes := doJSONReq(srv, http.MethodGet, "/api/v1/library/unmatched", tok1, "", nil, nil)
	if unmRes.Code != http.StatusOK {
		t.Fatal(unmRes.Body.String())
	}
	var unmOut struct {
		Total int `json:"total"`
		Items []struct {
			ID       int64  `json:"id"`
			Path     string `json:"path"`
			GroupKey string `json:"group_key"`
		} `json:"items"`
	}
	_ = json.Unmarshal(unmRes.Body.Bytes(), &unmOut)
	if unmOut.Total != 1 || !strings.Contains(unmOut.Items[0].Path, "Unknown Mystery XYZ") {
		t.Fatalf("expected 1 unmatched file, got %+v", unmOut)
	}
	unmFileID := unmOut.Items[0].ID

	// Cross-household user sees 0 unmatched and cannot manual-match hh1's file!
	hh2Match := doJSONReq(srv, http.MethodPost, "/api/v1/library/manual-match", tok2, "", nil, map[string]any{
		"file_ids": []int64{unmFileID}, "provider": "tmdb", "kind": "movie", "external_id": "157336",
	})
	if hh2Match.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household manual match, got %d", hh2Match.Code)
	}

	// Owner manual matches Unknown Mystery XYZ to Interstellar (157336).
	mmRes := doJSONReq(srv, http.MethodPost, "/api/v1/library/manual-match", tok1, "", nil, map[string]any{
		"file_ids": []int64{unmFileID}, "provider": "tmdb", "kind": "movie", "external_id": "157336",
	})
	if mmRes.Code != http.StatusOK {
		t.Fatalf("manual match failed: %d %s", mmRes.Code, mmRes.Body.String())
	}
	var mmOut struct {
		ItemID  int64    `json:"item_id"`
		WorkKey string   `json:"work_key"`
		RuleIDs []string `json:"rule_ids"`
	}
	_ = json.Unmarshal(mmRes.Body.Bytes(), &mmOut)
	if mmOut.WorkKey != "tmdb:movie:157336" || len(mmOut.RuleIDs) != 1 {
		t.Fatalf("unexpected manual match payload: %+v", mmOut)
	}

	// Edit & Rescrape keep locked title.
	itemURL := "/api/v1/items/" + strconv.FormatInt(mmOut.ItemID, 10)
	editRes := doJSONReq(srv, http.MethodPatch, itemURL, tok1, "", nil, map[string]any{
		"title": "My Custom Interstellar",
	})
	if editRes.Code != http.StatusOK {
		t.Fatal(editRes.Body.String())
	}
	rescrapeRes := doJSONReq(srv, http.MethodPost, itemURL+"/rescrape", tok1, "", nil, map[string]any{})
	if rescrapeRes.Code != http.StatusOK {
		t.Fatal(rescrapeRes.Body.String())
	}
	var curTitle string
	_ = store.ReadDB().QueryRow(`SELECT title FROM media_items WHERE id = ?`, mmOut.ItemID).Scan(&curTitle)
	if curTitle != "My Custom Interstellar" {
		t.Fatalf("expected locked title preserved after rescrape, got %q", curTitle)
	}

	// List & Delete match rule.
	rulesRes := doJSONReq(srv, http.MethodGet, "/api/v1/match-rules", tok1, "", nil, nil)
	if rulesRes.Code != http.StatusOK || !strings.Contains(rulesRes.Body.String(), mmOut.RuleIDs[0]) {
		t.Fatalf("expected created match rule in list: %d %s", rulesRes.Code, rulesRes.Body.String())
	}
	delRule := doJSONReq(srv, http.MethodDelete, "/api/v1/match-rules/"+mmOut.RuleIDs[0], tok1, "", nil, nil)
	if delRule.Code != http.StatusOK {
		t.Fatalf("delete match rule failed: %d", delRule.Code)
	}

	// Verify household metadata quota (120/min).
	for i := 0; i < 120; i++ {
		if !srv.metaLimiter.AllowWindow("hh_meta:quota-test", householdMetaRateLimitPerMin, time.Minute) {
			t.Fatalf("unexpected throttle at call %d", i)
		}
	}
	if srv.metaLimiter.AllowWindow("hh_meta:quota-test", householdMetaRateLimitPerMin, time.Minute) {
		t.Fatalf("expected household metadata quota exceeded on 121st call")
	}
}
