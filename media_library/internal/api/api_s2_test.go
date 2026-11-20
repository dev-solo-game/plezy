package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/source"
)

func mustRegisterAndLoginDevice(t *testing.T, srv *Server, username, deviceClass, ip string, register bool) (token, hhID, memberID, deviceID string) {
	t.Helper()
	var resBody []byte
	if register {
		r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", ip, nil, map[string]any{
			"username": username,
			"password": "Password123!",
			"device":   map[string]string{"class": deviceClass, "platform": "testos", "name": username + "-" + deviceClass},
		})
		if r.Code != http.StatusOK {
			t.Fatalf("register %s failed: %d %s", username, r.Code, r.Body.String())
		}
		resBody = r.Body.Bytes()
	} else {
		r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", ip, nil, map[string]any{
			"username": username,
			"password": "Password123!",
			"device":   map[string]string{"class": deviceClass, "platform": "testos", "name": username + "-" + deviceClass},
		})
		if r.Code != http.StatusOK {
			t.Fatalf("login %s (%s) failed: %d %s", username, deviceClass, r.Code, r.Body.String())
		}
		resBody = r.Body.Bytes()
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
		Principal   struct {
			HouseholdID string `json:"household_id"`
			MemberID    string `json:"member_id"`
			DeviceID    string `json:"device_id"`
		} `json:"principal"`
	}
	_ = json.Unmarshal(resBody, &parsed)
	return parsed.AccessToken, parsed.Principal.HouseholdID, parsed.Principal.MemberID, parsed.Principal.DeviceID
}

func mustReadyAdminToken(t *testing.T, srv *Server) string {
	t.Helper()
	l := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "", nil, map[string]string{
		"username": "admin", "password": "admin",
	})
	if l.Code != http.StatusOK {
		t.Fatalf("admin login failed: %d %s", l.Code, l.Body.String())
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(l.Body.Bytes(), &parsed)
	c := doJSONReq(srv, http.MethodPost, "/api/admin/auth/change-password", parsed.AccessToken, "", nil, map[string]string{
		"old_password": "admin", "new_password": "AdminStrongPass123!",
	})
	if c.Code != http.StatusOK {
		t.Fatalf("admin change password failed: %d %s", c.Code, c.Body.String())
	}
	return parsed.AccessToken
}

func TestS2DevicePolicyFoldersDedupAndQuota(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")
	admTok := mustReadyAdminToken(t, srv)

	pcTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s2_alice", db.DeviceClassDesktop, "10.5.0.1:1000", true)
	phoneTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s2_alice", db.DeviceClassPhone, "10.5.0.2:1000", false)
	tvTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s2_alice", db.DeviceClassTV, "10.5.0.3:1000", false)

	// 1. Device add policy enforcement
	pcWebDAV := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "webdav", "name": "Bad", "identity_key": "wd1", "ciphertext": "enc",
	})
	if pcWebDAV.Code != http.StatusForbidden || !strings.Contains(pcWebDAV.Body.String(), "source_kind_not_allowed_on_device") {
		t.Fatalf("expected 403 source_kind_not_allowed_on_device on PC WebDAV, got %d %s", pcWebDAV.Code, pcWebDAV.Body.String())
	}

	phoneQuark := doJSONReq(srv, http.MethodPost, "/api/v1/sources", phoneTok, "", nil, map[string]any{
		"kind": "quark", "name": "BadQ", "identity_key": "qk1", "ciphertext": "enc",
	})
	if phoneQuark.Code != http.StatusForbidden || !strings.Contains(phoneQuark.Body.String(), "source_kind_not_allowed_on_device") {
		t.Fatalf("expected 403 on Phone Quark, got %d %s", phoneQuark.Code, phoneQuark.Body.String())
	}

	tvEmby := doJSONReq(srv, http.MethodPost, "/api/v1/sources", tvTok, "", nil, map[string]any{
		"kind": "emby", "name": "BadE", "identity_key": "em1", "ciphertext": "enc",
	})
	if tvEmby.Code != http.StatusForbidden || !strings.Contains(tvEmby.Body.String(), "source_kind_not_allowed_on_device") {
		t.Fatalf("expected 403 on TV Emby, got %d %s", tvEmby.Code, tvEmby.Body.String())
	}

	// PC adds Quark -> 200
	pcQuark := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind":         "quark",
		"name":         "SecretPCQuarkName",
		"identity_key": "qk_uid_1",
		"ciphertext":   "cipher_qk_v1",
	})
	if pcQuark.Code != http.StatusOK {
		t.Fatalf("PC add quark failed: %d %s", pcQuark.Code, pcQuark.Body.String())
	}
	var qkResp struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(pcQuark.Body.Bytes(), &qkResp)

	// Duplicate Quark -> 409 source_already_exists + existing_source_id
	dupQ := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "quark", "name": "Dup", "identity_key": "qk_uid_1", "ciphertext": "cipher_dup",
	})
	if dupQ.Code != http.StatusConflict || !strings.Contains(dupQ.Body.String(), "source_already_exists") || !strings.Contains(dupQ.Body.String(), qkResp.Source.ID) {
		t.Fatalf("expected 409 source_already_exists with existing_source_id, got %d %s", dupQ.Code, dupQ.Body.String())
	}

	// 2. Phone adds folder to PC Quark -> 200, updates -> 200, deletes -> 200
	addF := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+qkResp.Source.ID+"/folders", phoneTok, "", nil, map[string]any{
		"path": "/SecretFolderPath/Movies", "exclude_paths": []string{"/SecretFolderPath/Movies/Sample"}, "library_hint": "movie",
	})
	if addF.Code != http.StatusOK {
		t.Fatalf("phone add folder failed: %d %s", addF.Code, addF.Body.String())
	}
	var fResp struct {
		Folder source.FolderView `json:"folder"`
	}
	_ = json.Unmarshal(addF.Body.Bytes(), &fResp)

	updF := doJSONReq(srv, http.MethodPatch, "/api/v1/sources/"+qkResp.Source.ID+"/folders/"+fResp.Folder.ID, phoneTok, "", nil, map[string]any{
		"library_hint": "show",
	})
	if updF.Code != http.StatusOK || !strings.Contains(updF.Body.String(), `"library_hint":"show"`) {
		t.Fatalf("phone update folder failed: %d %s", updF.Code, updF.Body.String())
	}
	if delF := doJSONReq(srv, http.MethodDelete, "/api/v1/sources/"+qkResp.Source.ID+"/folders/"+fResp.Folder.ID, phoneTok, "", nil, nil); delF.Code != http.StatusOK {
		t.Fatalf("phone delete folder failed: %d %s", delF.Code, delF.Body.String())
	}

	// 3. Phone adds WebDAV + soft dedup confirm_duplicate
	wd1 := doJSONReq(srv, http.MethodPost, "/api/v1/sources", phoneTok, "", nil, map[string]any{
		"kind": "webdav", "name": "NAS A", "identity_key": "dav_hmac", "ciphertext": "d1",
	})
	if wd1.Code != http.StatusOK {
		t.Fatalf("phone add webdav failed: %d %s", wd1.Code, wd1.Body.String())
	}
	wdSim := doJSONReq(srv, http.MethodPost, "/api/v1/sources", phoneTok, "", nil, map[string]any{
		"kind": "webdav", "name": "NAS B", "identity_key": "dav_hmac", "ciphertext": "d2",
	})
	if wdSim.Code != http.StatusConflict || !strings.Contains(wdSim.Body.String(), "similar_source_exists") {
		t.Fatalf("expected 409 similar_source_exists, got %d %s", wdSim.Code, wdSim.Body.String())
	}
	wd2 := doJSONReq(srv, http.MethodPost, "/api/v1/sources", phoneTok, "", nil, map[string]any{
		"kind": "webdav", "name": "NAS B", "identity_key": "dav_hmac", "ciphertext": "d2", "confirm_duplicate": true,
	})
	if wd2.Code != http.StatusOK {
		t.Fatalf("confirmed duplicate webdav failed: %d %s", wd2.Code, wd2.Body.String())
	}

	// Emby folder add fails 400
	embyRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "emby", "name": "Emby", "identity_key": "em_1", "ciphertext": "ec",
	})
	if embyRes.Code != http.StatusOK {
		t.Fatalf("add emby failed: %d %s", embyRes.Code, embyRes.Body.String())
	}
	var emResp struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(embyRes.Body.Bytes(), &emResp)
	if badF := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+emResp.Source.ID+"/folders", phoneTok, "", nil, map[string]any{"path": "/a"}); badF.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 adding folder to Emby, got %d %s", badF.Code, badF.Body.String())
	}

	// 4. Lower household quota_max_sources via admin API -> next create returns 429 quota_exceeded
	listAcc := doJSONReq(srv, http.MethodGet, "/api/admin/accounts", admTok, "", nil, nil)
	var accs struct {
		Accounts []struct {
			AccountID string `json:"account_id"`
		} `json:"accounts"`
	}
	_ = json.Unmarshal(listAcc.Body.Bytes(), &accs)
	if r := doJSONReq(srv, http.MethodPatch, "/api/admin/accounts/"+accs.Accounts[0].AccountID+"/quotas", admTok, "", nil, map[string]any{
		"max_sources": 4,
	}); r.Code != http.StatusOK {
		t.Fatalf("admin update quotas failed: %d %s", r.Code, r.Body.String())
	}
	overQuota := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "jellyfin", "name": "JF Over", "identity_key": "jf_1", "ciphertext": "jc",
	})
	if overQuota.Code != http.StatusTooManyRequests || !strings.Contains(overQuota.Body.String(), "quota_exceeded") {
		t.Fatalf("expected 429 quota_exceeded, got %d %s", overQuota.Code, overQuota.Body.String())
	}
}

func TestS2CredentialsHTTPSConflictRBACIsolationAndSoftDeleteAudit(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")
	admTok := mustReadyAdminToken(t, srv)

	pcTok, hhID, memID, _ := mustRegisterAndLoginDevice(t, srv, "s2_cred", db.DeviceClassDesktop, "10.6.0.1:1000", true)
	phoneTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s2_cred", db.DeviceClassPhone, "10.6.0.2:1000", false)
	bobTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s2_bob", db.DeviceClassDesktop, "10.6.0.9:1000", true)

	ch, unsub := srv.Hub.Subscribe(hhID, memID)
	defer unsub()

	src1Res := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "quark", "name": "HiddenQuarkTitle", "identity_key": "qk_s2", "ciphertext": "secret_cred_v1",
	})
	if src1Res.Code != http.StatusOK {
		t.Fatal(src1Res.Body.String())
	}
	var src1 struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(src1Res.Body.Bytes(), &src1)
	if ev := <-ch; ev.Type != "source.changed" {
		t.Fatalf("expected source.changed SSE, got %+v", ev)
	}

	src2Res := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "emby", "name": "Emby2", "identity_key": "em_s2", "ciphertext": "secret_em_v1",
	})
	var src2 struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(src2Res.Body.Bytes(), &src2)
	_ = <-ch

	// 5. G6 HTTPS check on credential endpoints
	plainGet := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src1.Source.ID+"/credential", phoneTok, "203.0.113.5:1000", nil, nil)
	if plainGet.Code != http.StatusForbidden || !strings.Contains(plainGet.Body.String(), "https_required") {
		t.Fatalf("expected 403 https_required on plain remote HTTP GET credential, got %d %s", plainGet.Code, plainGet.Body.String())
	}
	plainPut := doJSONReq(srv, http.MethodPut, "/api/v1/sources/"+src1.Source.ID+"/credential", phoneTok, "203.0.113.5:1000", nil, map[string]any{
		"base_version": 1, "ciphertext": "secret_v2",
	})
	if plainPut.Code != http.StatusForbidden || !strings.Contains(plainPut.Body.String(), "https_required") {
		t.Fatalf("expected 403 https_required on plain remote HTTP PUT credential, got %d %s", plainPut.Code, plainPut.Body.String())
	}

	httpsGet := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src1.Source.ID+"/credential", phoneTok, "127.0.0.1:1000", map[string]string{
		"X-Forwarded-Proto": "https",
	}, nil)
	if httpsGet.Code != http.StatusOK || httpsGet.Header().Get("Cache-Control") != "no-store" || !strings.Contains(httpsGet.Body.String(), "secret_cred_v1") {
		t.Fatalf("expected 200 no-store credential via loopback XFP=https, got %d cc=%q %s", httpsGet.Code, httpsGet.Header().Get("Cache-Control"), httpsGet.Body.String())
	}

	// Enable debug insecure credentials for subsequent test clarity
	srv.SetAllowInsecureCredentials(true)

	// 6. Optimistic concurrency + identity_key mismatch + status SSE
	putOK := doJSONReq(srv, http.MethodPut, "/api/v1/sources/"+src1.Source.ID+"/credential", phoneTok, "", nil, map[string]any{
		"base_version": 1, "ciphertext": "secret_cred_v2", "mode": "refresh",
	})
	if putOK.Code != http.StatusOK || !strings.Contains(putOK.Body.String(), `"version":2`) {
		t.Fatalf("expected version 2 update, got %d %s", putOK.Code, putOK.Body.String())
	}
	if ev := <-ch; ev.Type != "credential.status" {
		t.Fatalf("expected credential.status SSE, got %+v", ev)
	}

	putStale := doJSONReq(srv, http.MethodPut, "/api/v1/sources/"+src1.Source.ID+"/credential", pcTok, "", nil, map[string]any{
		"base_version": 1, "ciphertext": "secret_stale",
	})
	if putStale.Code != http.StatusConflict ||
		!strings.Contains(putStale.Body.String(), "credential_version_conflict") ||
		!strings.Contains(putStale.Body.String(), "secret_cred_v2") ||
		putStale.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("expected 409 credential_version_conflict with latest ciphertext, got %d cc=%q %s", putStale.Code, putStale.Header().Get("Cache-Control"), putStale.Body.String())
	}

	wrongID := doJSONReq(srv, http.MethodPut, "/api/v1/sources/"+src1.Source.ID+"/credential", pcTok, "", nil, map[string]any{
		"base_version": 2, "ciphertext": "secret_other", "mode": "replace", "identity_key": "qk_different_uid",
	})
	if wrongID.Code != http.StatusConflict || !strings.Contains(wrongID.Body.String(), "identity_mismatch") {
		t.Fatalf("expected 409 identity_mismatch, got %d %s", wrongID.Code, wrongID.Body.String())
	}

	kicked := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src1.Source.ID+"/credential/status", phoneTok, "", nil, map[string]any{
		"status": "kicked", "version": 2,
	})
	if kicked.Code != http.StatusOK || !strings.Contains(kicked.Body.String(), `"status":"kicked"`) {
		t.Fatalf("expected kicked status update, got %d %s", kicked.Code, kicked.Body.String())
	}
	if ev := <-ch; ev.Type != "credential.status" {
		t.Fatalf("expected kicked credential.status SSE, got %+v", ev)
	}

	// 7. Tenant isolation (404), restricted member (403), admin token (401)
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src1.Source.ID, bobTok, "", nil, nil); r.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household GetSource, got %d", r.Code)
	}
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src1.Source.ID+"/credential", bobTok, "", nil, nil); r.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household GetCredential, got %d", r.Code)
	}
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/sources", admTok, "", nil, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 admin token on /api/v1/sources, got %d", r.Code)
	}

	cm := doJSONReq(srv, http.MethodPost, "/api/v1/household/members", pcTok, "", nil, map[string]any{
		"nickname":           "OnlySrc2",
		"role":               account.RoleMember,
		"restrict_sources":   true,
		"allowed_source_ids": []string{src2.Source.ID},
		"login_username":     "only_src2_user",
		"login_password":     "Password123!",
	})
	if cm.Code != http.StatusOK {
		t.Fatalf("create restricted member failed: %d %s", cm.Code, cm.Body.String())
	}
	childTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "only_src2_user", db.DeviceClassPhone, "10.6.0.4:1000", false)
	childList := doJSONReq(srv, http.MethodGet, "/api/v1/sources", childTok, "", nil, nil)
	if childList.Code != http.StatusOK || strings.Contains(childList.Body.String(), src1.Source.ID) || !strings.Contains(childList.Body.String(), src2.Source.ID) {
		t.Fatalf("restricted member list should contain only src2: %s", childList.Body.String())
	}
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src1.Source.ID+"/credential", childTok, "", nil, nil); r.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on disallowed source credential, got %d %s", r.Code, r.Body.String())
	}

	// 8. G15 soft delete -> 410 source_deleted + SSE source.changed + privacy-safe audit logs
	del := doJSONReq(srv, http.MethodDelete, "/api/v1/sources/"+src1.Source.ID, phoneTok, "", nil, nil)
	if del.Code != http.StatusOK {
		t.Fatalf("soft delete failed: %d %s", del.Code, del.Body.String())
	}
	if ev := <-ch; ev.Type != "source.changed" {
		t.Fatalf("expected delete source.changed SSE, got %+v", ev)
	}

	for _, tc := range []struct {
		method, path string
		body         any
	}{
		{http.MethodGet, "/api/v1/sources/" + src1.Source.ID, nil},
		{http.MethodGet, "/api/v1/sources/" + src1.Source.ID + "/credential", nil},
		{http.MethodPost, "/api/v1/sources/" + src1.Source.ID + "/folders", map[string]string{"path": "/new"}},
	} {
		r := doJSONReq(srv, tc.method, tc.path, pcTok, "", nil, tc.body)
		if r.Code != http.StatusGone || !strings.Contains(r.Body.String(), "source_deleted") {
			t.Fatalf("%s %s expected 410 source_deleted, got %d %s", tc.method, tc.path, r.Code, r.Body.String())
		}
	}

	auditRes := doJSONReq(srv, http.MethodGet, "/api/admin/audit-logs", admTok, "", nil, nil)
	if auditRes.Code != http.StatusOK {
		t.Fatalf("admin audit-logs failed: %d %s", auditRes.Code, auditRes.Body.String())
	}
	auditBody := auditRes.Body.String()
	if !strings.Contains(auditBody, "source.credential_read") || !strings.Contains(auditBody, "source.deleted") {
		t.Fatalf("expected source audit actions in %s", auditBody)
	}
	if strings.Contains(auditBody, "HiddenQuarkTitle") || strings.Contains(auditBody, "secret_cred") {
		t.Fatalf("D8 privacy leak in audit logs: %s", auditBody)
	}
}
