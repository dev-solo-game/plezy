package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
)

func mustLoginReadyAdmin(t *testing.T, srv *Server) string {
	t.Helper()
	loginRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "127.0.0.1:2000", nil, map[string]any{
		"username": "admin", "password": "admin",
	})
	if loginRes.Code != http.StatusOK {
		t.Fatalf("admin login failed: %d %s", loginRes.Code, loginRes.Body.String())
	}
	var l struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(loginRes.Body.Bytes(), &l)

	// Verify S6 endpoints block default password before change
	blocked := doJSONReq(srv, http.MethodGet, "/api/admin/overview", l.AccessToken, "127.0.0.1:2000", nil, nil)
	if blocked.Code != http.StatusForbidden || !strings.Contains(blocked.Body.String(), "password_change_required") {
		t.Fatalf("expected 403 password_change_required before changing default password, got %d %s", blocked.Code, blocked.Body.String())
	}

	chgRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/change-password", l.AccessToken, "127.0.0.1:2000", nil, map[string]any{
		"old_password": "admin", "new_password": "AdminNewPassword123!",
	})
	if chgRes.Code != http.StatusOK {
		t.Fatalf("change admin password failed: %d %s", chgRes.Code, chgRes.Body.String())
	}
	return l.AccessToken
}

func TestS6AdminOverviewPrivacySettingsTestsMetadataIdentifyAndLogs(t *testing.T) {
	mockTmdb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"images":{"base_url":"https://image.tmdb.org/t/p/"}}`))
	}))
	defer mockTmdb.Close()

	srv, store, _ := newTestAPIServer(t, "")
	adminTok := mustLoginReadyAdmin(t, srv)
	userTok, hhID, _, _ := mustRegisterAndLoginDevice(t, srv, "s6_private_user", db.DeviceClassDesktop, "10.10.0.1:1000", true)

	// Seed private user data to assert D8 privacy compliance
	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", userTok, "", nil, map[string]any{
		"kind": "quark", "name": "SECRET_MOUNT_NAME_XYZ", "identity_key": "qk_s6_secret", "ciphertext": "SUPER_SECRET_CIPHER",
		"folders": []map[string]any{{"path": "/SecretPrivateFolder"}},
	})
	if srcRes.Code != http.StatusOK {
		t.Fatalf("create source: %d %s", srcRes.Code, srcRes.Body.String())
	}
	nowMs := time.Now().UnixMilli()
	if _, err := store.DB().Exec(`
		INSERT INTO media_items(household_id, kind, library_type, work_key, title, sort_title, added_at, updated_at)
		VALUES (?, 'movie', 'movie', 'tmdb:movie:999', 'SECRET_MOVIE_TITLE_XYZ', 'secret', ?, ?)`,
		hhID, nowMs, nowMs,
	); err != nil {
		t.Fatal(err)
	}

	// Token isolation: user token -> /api/admin/* must return 401; admin token -> /api/v1/* must return 401
	if res := doJSONReq(srv, http.MethodGet, "/api/admin/overview", userTok, "", nil, nil); res.Code != http.StatusUnauthorized {
		t.Fatalf("user token on /api/admin/overview expected 401, got %d", res.Code)
	}
	if res := doJSONReq(srv, http.MethodGet, "/api/v1/library/snapshot", adminTok, "", nil, nil); res.Code != http.StatusUnauthorized {
		t.Fatalf("admin token on /api/v1/library/snapshot expected 401, got %d", res.Code)
	}

	// 1. Admin Overview (non-privacy stats only, D8)
	ovRes := doJSONReq(srv, http.MethodGet, "/api/admin/overview", adminTok, "127.0.0.1:2000", nil, nil)
	if ovRes.Code != http.StatusOK {
		t.Fatalf("admin overview failed: %d %s", ovRes.Code, ovRes.Body.String())
	}
	ovBody := ovRes.Body.String()
	for _, secret := range []string{"SECRET_MOUNT_NAME_XYZ", "SECRET_MOVIE_TITLE_XYZ", "SUPER_SECRET_CIPHER", "SecretPrivateFolder"} {
		if strings.Contains(ovBody, secret) {
			t.Fatalf("D8 privacy leak in admin overview: found %q", secret)
		}
	}
	var ovParsed struct {
		Overview PlatformOverview `json:"overview"`
	}
	_ = json.Unmarshal(ovRes.Body.Bytes(), &ovParsed)
	if ovParsed.Overview.AccountsTotal < 1 || ovParsed.Overview.SourcesTotal < 1 || ovParsed.Overview.ItemsTotal < 1 {
		t.Fatalf("unexpected overview counts: %+v", ovParsed.Overview)
	}

	// 2. Test TMDB & Clear Cache
	testTmdb := doJSONReq(srv, http.MethodPost, "/api/admin/settings/test-tmdb", adminTok, "127.0.0.1:2000", nil, map[string]any{
		"tmdb_api_key":  "fake-v3-key",
		"tmdb_api_base": mockTmdb.URL + "/3",
	})
	if testTmdb.Code != http.StatusOK || !strings.Contains(testTmdb.Body.String(), `"ok":true`) {
		t.Fatalf("test-tmdb failed: %d %s", testTmdb.Code, testTmdb.Body.String())
	}

	clearCache := doJSONReq(srv, http.MethodPost, "/api/admin/settings/clear-cache", adminTok, "127.0.0.1:2000", nil, map[string]any{
		"scope": "all",
	})
	if clearCache.Code != http.StatusOK {
		t.Fatalf("clear-cache failed: %d %s", clearCache.Code, clearCache.Body.String())
	}

	// 3. Metadata tables inspection (public metadata cache only)
	tblsRes := doJSONReq(srv, http.MethodGet, "/api/admin/metadata/tables", adminTok, "127.0.0.1:2000", nil, nil)
	if tblsRes.Code != http.StatusOK || !strings.Contains(tblsRes.Body.String(), "meta_works_cache") {
		t.Fatalf("metadata tables failed: %d %s", tblsRes.Code, tblsRes.Body.String())
	}
	qTblRes := doJSONReq(srv, http.MethodGet, "/api/admin/metadata/tables/meta_works_cache", adminTok, "127.0.0.1:2000", nil, nil)
	if qTblRes.Code != http.StatusOK {
		t.Fatalf("query metadata table failed: %d %s", qTblRes.Code, qTblRes.Body.String())
	}

	// 4. Identify queue pause / resume / status / retry-failed
	pauseRes := doJSONReq(srv, http.MethodPost, "/api/admin/identify/pause", adminTok, "127.0.0.1:2000", nil, nil)
	if pauseRes.Code != http.StatusOK {
		t.Fatalf("identify pause failed: %d %s", pauseRes.Code, pauseRes.Body.String())
	}
	stRes := doJSONReq(srv, http.MethodGet, "/api/admin/identify/status", adminTok, "127.0.0.1:2000", nil, nil)
	if stRes.Code != http.StatusOK || !strings.Contains(stRes.Body.String(), `"paused":true`) {
		t.Fatalf("identify status expected paused=true: %d %s", stRes.Code, stRes.Body.String())
	}
	resumeRes := doJSONReq(srv, http.MethodPost, "/api/admin/identify/resume", adminTok, "127.0.0.1:2000", nil, nil)
	if resumeRes.Code != http.StatusOK {
		t.Fatalf("identify resume failed: %d %s", resumeRes.Code, resumeRes.Body.String())
	}
	retryRes := doJSONReq(srv, http.MethodPost, "/api/admin/identify/retry-failed", adminTok, "127.0.0.1:2000", nil, map[string]any{})
	if retryRes.Code != http.StatusOK {
		t.Fatalf("identify retry-failed failed: %d %s", retryRes.Code, retryRes.Body.String())
	}

	// 5. System logs view / download / clear
	applog.Infof("system", "s6 test log marker")
	logsRes := doJSONReq(srv, http.MethodGet, "/api/admin/logs?limit=20&q=s6+test+log+marker", adminTok, "127.0.0.1:2000", nil, nil)
	if logsRes.Code != http.StatusOK || !strings.Contains(logsRes.Body.String(), "s6 test log marker") {
		t.Fatalf("admin logs failed: %d %s", logsRes.Code, logsRes.Body.String())
	}
	dlRes := doJSONReq(srv, http.MethodGet, "/api/admin/logs/download", adminTok, "127.0.0.1:2000", nil, nil)
	if dlRes.Code != http.StatusOK || !strings.Contains(dlRes.Header().Get("Content-Disposition"), "media-library.log") {
		t.Fatalf("admin logs download failed: %d", dlRes.Code)
	}
	clrLogsRes := doJSONReq(srv, http.MethodPost, "/api/admin/logs/clear", adminTok, "127.0.0.1:2000", nil, map[string]any{})
	if clrLogsRes.Code != http.StatusOK {
		t.Fatalf("admin logs clear failed: %d %s", clrLogsRes.Code, clrLogsRes.Body.String())
	}

	// 6. Web SPA fallback serves built static index.html when webDir is set
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<!doctype html><html><body>OK_SPA</body></html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv.SetWebDir(webDir)
	spaRes := doJSONReq(srv, http.MethodGet, "/admin/settings", "", "", nil, nil)
	if spaRes.Code != http.StatusOK || !strings.Contains(spaRes.Body.String(), "OK_SPA") {
		t.Fatalf("SPA fallback failed: %d %s", spaRes.Code, spaRes.Body.String())
	}
}
