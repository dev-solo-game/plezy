package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/source"
)

func TestS5FeedSnapshotChangesSidecarSSEAndUserData(t *testing.T) {
	srv, store, _ := newTestAPIServer(t, "")

	tok1, hh1, _, _ := mustRegisterAndLoginDevice(t, srv, "s5_user1", db.DeviceClassDesktop, "10.9.0.1:1000", true)
	tok2, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s5_user2", db.DeviceClassDesktop, "10.9.0.2:1000", true)

	// Create a source, upload a sidecar, and ingest a movie file
	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", tok1, "", nil, map[string]any{
		"kind": "quark", "name": "My Quark", "identity_key": "qk_s5", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/Movies"}},
	})
	if srcRes.Code != http.StatusOK {
		t.Fatalf("create source: %d %s", srcRes.Code, srcRes.Body.String())
	}
	var srcBody struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &srcBody)

	nfoData := []byte("<movie><title>Inception</title><year>2010</year></movie>")
	nfoSum := sha256.Sum256(nfoData)
	nfoHex := hex.EncodeToString(nfoSum[:])
	putSidecar := doRawReq(srv, http.MethodPut, "/api/v1/sidecars/"+nfoHex, tok1, "application/xml", nfoData)
	if putSidecar.Code != http.StatusOK {
		t.Fatalf("put sidecar: %d %s", putSidecar.Code, putSidecar.Body.String())
	}

	// GET sidecar works for owner, 404 for another account
	getSidecar := doJSONReq(srv, http.MethodGet, "/api/v1/sidecars/"+nfoHex, tok1, "", nil, nil)
	if getSidecar.Code != http.StatusOK || getSidecar.Body.String() != string(nfoData) {
		t.Fatalf("get sidecar: %d %q", getSidecar.Code, getSidecar.Body.String())
	}
	getSidecarCross := doJSONReq(srv, http.MethodGet, "/api/v1/sidecars/"+nfoHex, tok2, "", nil, nil)
	if getSidecarCross.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-tenant sidecar, got %d", getSidecarCross.Code)
	}

	// Seed an identified movie item & active file directly for snapshot/detail tests
	nowMs := time.Now().UnixMilli()
	res, err := store.DB().Exec(`
		INSERT INTO media_items(household_id, kind, library_type, work_key, title, sort_title, year, added_at, updated_at)
		VALUES (?, 'movie', 'movie', 'tmdb:movie:27205', 'Inception', 'inception', 2010, ?, ?)`,
		hh1, nowMs, nowMs,
	)
	if err != nil {
		t.Fatal(err)
	}
	itemID, _ := res.LastInsertId()
	if _, err := store.DB().Exec(`
		INSERT INTO media_files(household_id, source_id, item_id, path, role, size, state, match_state, last_seen_at, added_at, updated_at)
		VALUES (?, ?, ?, '/Movies/Inception.2010.mkv', 'video', 4096, 'active', 'matched', ?, ?, ?)`,
		hh1, srcBody.Source.ID, itemID, nowMs, nowMs, nowMs,
	); err != nil {
		t.Fatal(err)
	}

	// Snapshot returns the movie for account 1, empty for account 2
	snap1 := doJSONReq(srv, http.MethodGet, "/api/v1/library/snapshot?kind=movie", tok1, "", nil, nil)
	if snap1.Code != http.StatusOK || !strings.Contains(snap1.Body.String(), "Inception") {
		t.Fatalf("snapshot1 failed: %d %s", snap1.Code, snap1.Body.String())
	}
	var snap1Data struct {
		SnapshotSeq int64 `json:"snapshot_seq"`
		Total       int   `json:"total"`
	}
	_ = json.Unmarshal(snap1.Body.Bytes(), &snap1Data)
	if snap1Data.Total != 1 {
		t.Fatalf("expected total=1, got %d", snap1Data.Total)
	}

	snap2 := doJSONReq(srv, http.MethodGet, "/api/v1/library/snapshot?kind=movie", tok2, "", nil, nil)
	if snap2.Code != http.StatusOK || strings.Contains(snap2.Body.String(), "Inception") {
		t.Fatalf("snapshot2 leaked cross-tenant data: %d %s", snap2.Code, snap2.Body.String())
	}

	// Item detail works for owner, 404 for another account
	det1 := doJSONReq(srv, http.MethodGet, "/api/v1/items/"+strconv.FormatInt(itemID, 10), tok1, "", nil, nil)
	if det1.Code != http.StatusOK || !strings.Contains(det1.Body.String(), "Inception.2010.mkv") {
		t.Fatalf("item detail failed: %d %s", det1.Code, det1.Body.String())
	}
	det2 := doJSONReq(srv, http.MethodGet, "/api/v1/items/"+strconv.FormatInt(itemID, 10), tok2, "", nil, nil)
	if det2.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-tenant item detail, got %d", det2.Code)
	}

	// User data: progress, continue watching, favorites, work prefs, lists
	wk := "tmdb:movie:27205"
	encWK := url.PathEscape(wk)

	progRes := doJSONReq(srv, http.MethodPost, "/api/v1/progress", tok1, "", nil, map[string]any{
		"work_key":    wk,
		"position_ms": 120000,
		"duration_ms": 600000,
	})
	if progRes.Code != http.StatusOK {
		t.Fatalf("upsert progress: %d %s", progRes.Code, progRes.Body.String())
	}
	cwRes := doJSONReq(srv, http.MethodGet, "/api/v1/continue-watching", tok1, "", nil, nil)
	if cwRes.Code != http.StatusOK || !strings.Contains(cwRes.Body.String(), wk) {
		t.Fatalf("continue watching: %d %s", cwRes.Code, cwRes.Body.String())
	}
	hideRes := doJSONReq(srv, http.MethodPost, "/api/v1/continue-watching/"+encWK+"/hide", tok1, "", nil, nil)
	if hideRes.Code != http.StatusOK {
		t.Fatalf("hide continue watching: %d %s", hideRes.Code, hideRes.Body.String())
	}

	favAdd := doJSONReq(srv, http.MethodPut, "/api/v1/favorites/"+encWK, tok1, "", nil, nil)
	if favAdd.Code != http.StatusOK {
		t.Fatalf("add favorite: %d %s", favAdd.Code, favAdd.Body.String())
	}
	favList := doJSONReq(srv, http.MethodGet, "/api/v1/favorites", tok1, "", nil, nil)
	if favList.Code != http.StatusOK || !strings.Contains(favList.Body.String(), wk) {
		t.Fatalf("list favorites: %d %s", favList.Code, favList.Body.String())
	}
	favDel := doJSONReq(srv, http.MethodDelete, "/api/v1/favorites/"+encWK, tok1, "", nil, nil)
	if favDel.Code != http.StatusOK {
		t.Fatalf("remove favorite: %d %s", favDel.Code, favDel.Body.String())
	}

	hhPref := doJSONReq(srv, http.MethodPut, "/api/v1/work-prefs/"+encWK+"/household", tok1, "", nil, map[string]any{
		"intro_enabled": true, "intro_start_ms": 1000, "intro_end_ms": 90000,
	})
	if hhPref.Code != http.StatusOK {
		t.Fatalf("household prefs: %d %s", hhPref.Code, hhPref.Body.String())
	}
	memPref := doJSONReq(srv, http.MethodPut, "/api/v1/work-prefs/"+encWK+"/member", tok1, "", nil, map[string]any{
		"playback_speed": 1.25, "audio_lang": "en",
	})
	if memPref.Code != http.StatusOK || !strings.Contains(memPref.Body.String(), "1.25") {
		t.Fatalf("member prefs: %d %s", memPref.Code, memPref.Body.String())
	}
	getPref := doJSONReq(srv, http.MethodGet, "/api/v1/work-prefs/"+encWK, tok1, "", nil, nil)
	if getPref.Code != http.StatusOK || !strings.Contains(getPref.Body.String(), "90000") {
		t.Fatalf("get work prefs: %d %s", getPref.Code, getPref.Body.String())
	}

	// Lists CRUD + entries + cross-tenant 404
	listCreate := doJSONReq(srv, http.MethodPost, "/api/v1/lists", tok1, "", nil, map[string]any{
		"kind": "playlist", "title": "Sci-Fi Watchlist",
	})
	if listCreate.Code != http.StatusOK {
		t.Fatalf("create list: %d %s", listCreate.Code, listCreate.Body.String())
	}
	var listBody struct {
		List struct {
			ID string `json:"id"`
		} `json:"list"`
	}
	_ = json.Unmarshal(listCreate.Body.Bytes(), &listBody)
	if listBody.List.ID == "" {
		t.Fatalf("missing list id")
	}

	addEntry := doJSONReq(srv, http.MethodPost, "/api/v1/lists/"+listBody.List.ID+"/entries", tok1, "", nil, map[string]any{
		"work_key": wk,
	})
	if addEntry.Code != http.StatusOK {
		t.Fatalf("add list entry: %d %s", addEntry.Code, addEntry.Body.String())
	}
	getListCross := doJSONReq(srv, http.MethodGet, "/api/v1/lists/"+listBody.List.ID, tok2, "", nil, nil)
	if getListCross.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-tenant list get, got %d", getListCross.Code)
	}
	delList := doJSONReq(srv, http.MethodDelete, "/api/v1/lists/"+listBody.List.ID, tok1, "", nil, nil)
	if delList.Code != http.StatusOK {
		t.Fatalf("delete list: %d %s", delList.Code, delList.Body.String())
	}

	// Incremental changes since snapshot_seq must capture the user data changes
	chgRes := doJSONReq(srv, http.MethodGet, "/api/v1/library/changes?since_seq="+strconv.FormatInt(snap1Data.SnapshotSeq, 10), tok1, "", nil, nil)
	if chgRes.Code != http.StatusOK {
		t.Fatalf("changes: %d %s", chgRes.Code, chgRes.Body.String())
	}
	var chgData struct {
		ResetRequired bool             `json:"reset_required"`
		Changes       []map[string]any `json:"changes"`
	}
	_ = json.Unmarshal(chgRes.Body.Bytes(), &chgData)
	if chgData.ResetRequired || len(chgData.Changes) == 0 {
		t.Fatalf("expected incremental changes without reset, got reset=%v count=%d", chgData.ResetRequired, len(chgData.Changes))
	}

	// SSE stream delivers live events and terminates cleanly on cancel
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/api/v1/events", nil).WithContext(ctx)
	req.RemoteAddr = "127.0.0.1:45678"
	req.Header.Set("Authorization", "Bearer "+tok1)
	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		srv.Mux.ServeHTTP(rec, req)
		close(done)
	}()

	time.Sleep(30 * time.Millisecond)
	_ = doJSONReq(srv, http.MethodPut, "/api/v1/favorites/"+encWK, tok1, "", nil, nil)
	time.Sleep(40 * time.Millisecond)
	cancel()
	<-done

	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "event: userdata.changed") {
		t.Fatalf("expected SSE userdata.changed event, got status=%d body=%q", rec.Code, rec.Body.String())
	}
}
