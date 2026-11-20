package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/platform"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/source"
	"plezy/media_library/internal/vault"
)

func newTestAPIServer(t *testing.T, adminCIDRs string) (*Server, *db.Store, func(time.Duration)) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	limiter := security.NewLoginLimiter()
	platSvc, err := platform.NewService(store, limiter, adminCIDRs)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := platSvc.EnsureDefaultAdmin("", ""); err != nil {
		t.Fatal(err)
	}
	accSvc := account.NewService(store, limiter)

	now := time.Unix(1700000000, 0)
	platSvc.SetClock(func() time.Time { return now })
	accSvc.SetClock(func() time.Time { return now })

	metaSvc := metadata.NewService(store)
	scraper := library.NewScraper(store, metaSvc)
	hub := events.NewHub()
	srcSvc := source.NewService(store, hub)
	srcSvc.SetClock(func() time.Time { return now })
	ingSvc := ingest.NewService(store, hub, limiter)
	ingSvc.SetClock(func() time.Time { return now })
	srv := NewServer(store, metaSvc, scraper, hub, platSvc, accSvc, srcSvc, ingSvc)

	return srv, store, func(d time.Duration) { now = now.Add(d) }
}

func doJSONReq(srv *Server, method, path, token, remoteAddr string, headers map[string]string, body any) *httptest.ResponseRecorder {
	var rBody io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rBody = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, rBody)
	if remoteAddr != "" {
		req.RemoteAddr = remoteAddr
	} else {
		req.RemoteAddr = "127.0.0.1:45678"
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	srv.Mux.ServeHTTP(rec, req)
	return rec
}

func TestS1AdminDefaultPasswordForceChangeAndTokenIsolation(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")

	// 1. Default admin/admin login
	loginRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "", nil, map[string]string{
		"username": "admin",
		"password": "admin",
	})
	if loginRes.Code != http.StatusOK {
		t.Fatalf("admin login status=%d body=%s", loginRes.Code, loginRes.Body.String())
	}
	var admLogin struct {
		AccessToken string `json:"access_token"`
		Admin       struct {
			MustChangePassword bool `json:"must_change_password"`
		} `json:"admin"`
	}
	_ = json.Unmarshal(loginRes.Body.Bytes(), &admLogin)
	if !admLogin.Admin.MustChangePassword || !strings.HasPrefix(admLogin.AccessToken, "adm_") {
		t.Fatalf("unexpected admin login payload: %+v", admLogin)
	}

	// Before changing password -> 403 password_change_required on management endpoints
	accListBlocked := doJSONReq(srv, http.MethodGet, "/api/admin/accounts", admLogin.AccessToken, "", nil, nil)
	if accListBlocked.Code != http.StatusForbidden || !strings.Contains(accListBlocked.Body.String(), "password_change_required") {
		t.Fatalf("expected 403 password_change_required, got %d body=%s", accListBlocked.Code, accListBlocked.Body.String())
	}

	// /api/admin/auth/me works while must_change_password=true
	meRes := doJSONReq(srv, http.MethodGet, "/api/admin/auth/me", admLogin.AccessToken, "", nil, nil)
	if meRes.Code != http.StatusOK {
		t.Fatalf("expected /api/admin/auth/me 200, got %d", meRes.Code)
	}

	// Admin token rejected by user endpoints (401)
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/auth/me", admLogin.AccessToken, "", nil, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("expected admin token on /api/v1/auth/me -> 401, got %d", r.Code)
	}
	if r := doJSONReq(srv, http.MethodGet, "/api/v1/household", admLogin.AccessToken, "", nil, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("expected admin token on /api/v1/household -> 401, got %d", r.Code)
	}

	// Change admin password -> unlocks /api/admin/accounts
	chgRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/change-password", admLogin.AccessToken, "", nil, map[string]string{
		"old_password": "admin",
		"new_password": "StrongAdminPassword123!",
	})
	if chgRes.Code != http.StatusOK {
		t.Fatalf("change-password status=%d body=%s", chgRes.Code, chgRes.Body.String())
	}
	accListOK := doJSONReq(srv, http.MethodGet, "/api/admin/accounts", admLogin.AccessToken, "", nil, nil)
	if accListOK.Code != http.StatusOK {
		t.Fatalf("expected /api/admin/accounts 200 after password change, got %d body=%s", accListOK.Code, accListOK.Body.String())
	}

	// Register a normal user and verify usr_ token cannot hit /api/admin/*
	regRes := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.0.1.10:1234", nil, map[string]any{
		"username": "normal_alice",
		"password": "UserPass123!",
		"device":   map[string]string{"class": "desktop", "platform": "windows", "name": "PC"},
	})
	if regRes.Code != http.StatusOK {
		t.Fatalf("register status=%d body=%s", regRes.Code, regRes.Body.String())
	}
	var usrAuth struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(regRes.Body.Bytes(), &usrAuth)
	if r := doJSONReq(srv, http.MethodGet, "/api/admin/accounts", usrAuth.AccessToken, "", nil, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("expected user token on /api/admin/accounts -> 401, got %d", r.Code)
	}
	if r := doJSONReq(srv, http.MethodGet, "/api/admin/auth/me", usrAuth.AccessToken, "", nil, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("expected user token on /api/admin/auth/me -> 401, got %d", r.Code)
	}
}

func TestS1AdminCIDRAndUntrustedXFFBypassPrevention(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "127.0.0.1,10.0.0.0/8")

	// Disallowed peer IP blocked even if attacker sends spoofed X-Forwarded-For
	res := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "203.0.113.50:9999",
		map[string]string{"X-Forwarded-For": "127.0.0.1"},
		map[string]string{"username": "admin", "password": "admin"},
	)
	if res.Code != http.StatusForbidden || !strings.Contains(res.Body.String(), "forbidden_ip") {
		t.Fatalf("expected 403 forbidden_ip when untrusted peer spoofs XFF, got %d body=%s", res.Code, res.Body.String())
	}

	// Allowed IP succeeds
	ok := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "127.0.0.1:9999", nil,
		map[string]string{"username": "admin", "password": "admin"},
	)
	if ok.Code != http.StatusOK {
		t.Fatalf("expected 200 from allowed CIDR, got %d body=%s", ok.Code, ok.Body.String())
	}

	// Configure trusted proxy and confirm forwarded IP is honored only from trusted peer
	if err := srv.SetTrustedProxies("10.0.0.0/8"); err != nil {
		t.Fatal(err)
	}
	proxied := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "10.0.0.5:8080",
		map[string]string{"X-Forwarded-For": "203.0.113.99"},
		map[string]string{"username": "admin", "password": "admin"},
	)
	if proxied.Code != http.StatusForbidden || !strings.Contains(proxied.Body.String(), "forbidden_ip") {
		t.Fatalf("expected trusted proxy's external XFF rejected by admin CIDR, got %d", proxied.Code)
	}
}

func TestS1CrossHousehold404AndRBAC403(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")

	regA := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.1.0.1:1000", nil, map[string]any{
		"username": "household_a",
		"password": "Password123!",
		"device":   map[string]string{"class": "phone"},
	})
	var authA struct {
		AccessToken string `json:"access_token"`
		Member      struct {
			ID string `json:"id"`
		} `json:"member"`
		Principal struct {
			DeviceID string `json:"device_id"`
		} `json:"principal"`
	}
	_ = json.Unmarshal(regA.Body.Bytes(), &authA)

	regB := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.1.0.2:1000", nil, map[string]any{
		"username": "household_b",
		"password": "Password123!",
		"device":   map[string]string{"class": "phone"},
	})
	var authB struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(regB.Body.Bytes(), &authB)

	// Cross-household access must return 404
	if r := doJSONReq(srv, http.MethodPatch, "/api/v1/household/members/"+authA.Member.ID, authB.AccessToken, "", nil, map[string]string{
		"nickname": "pwned",
	}); r.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household member update, got %d body=%s", r.Code, r.Body.String())
	}
	if r := doJSONReq(srv, http.MethodDelete, "/api/v1/household/devices/"+authA.Principal.DeviceID, authB.AccessToken, "", nil, nil); r.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household device delete, got %d body=%s", r.Code, r.Body.String())
	}

	// Plain member in household A lacks PermManageMembers / PermManageSettings / PermDeleteHousehold -> 403
	createMem := doJSONReq(srv, http.MethodPost, "/api/v1/household/members", authA.AccessToken, "", nil, map[string]any{
		"nickname":       "Viewer",
		"role":           account.RoleMember,
		"login_username": "viewer_a",
		"login_password": "Password123!",
	})
	if createMem.Code != http.StatusOK {
		t.Fatalf("create member failed: %d %s", createMem.Code, createMem.Body.String())
	}
	loginMem := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", "10.1.0.3:1000", nil, map[string]any{
		"username": "viewer_a",
		"password": "Password123!",
		"device":   map[string]string{"class": "phone"},
	})
	var memAuth struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(loginMem.Body.Bytes(), &memAuth)

	for _, tc := range []struct {
		method string
		path   string
		body   any
	}{
		{http.MethodPatch, "/api/v1/household", map[string]string{"name": "X"}},
		{http.MethodPost, "/api/v1/household/members", map[string]string{"nickname": "X", "role": "member"}},
		{http.MethodDelete, "/api/v1/household/members/" + authA.Member.ID, nil},
		{http.MethodPost, "/api/v1/auth/delete-account", map[string]string{"password": "Password123!"}},
	} {
		r := doJSONReq(srv, tc.method, tc.path, memAuth.AccessToken, "", nil, tc.body)
		if r.Code != http.StatusForbidden {
			t.Fatalf("%s %s expected 403 for plain member, got %d body=%s", tc.method, tc.path, r.Code, r.Body.String())
		}
	}
}

func TestS1RegistrationModesRateLimitAndInvites(t *testing.T) {
	srv, store, _ := newTestAPIServer(t, "")

	// Login & change admin password first
	admLoginRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "", nil, map[string]string{
		"username": "admin", "password": "admin",
	})
	var adm struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(admLoginRes.Body.Bytes(), &adm)
	_ = doJSONReq(srv, http.MethodPost, "/api/admin/auth/change-password", adm.AccessToken, "", nil, map[string]string{
		"old_password": "admin", "new_password": "AdminPassword123!",
	})

	// Admin switches registration_mode -> closed via API
	if r := doJSONReq(srv, http.MethodPatch, "/api/admin/settings", adm.AccessToken, "", nil, map[string]any{
		"registration_mode": db.RegistrationModeClosed,
	}); r.Code != http.StatusOK {
		t.Fatalf("update settings closed failed: %d %s", r.Code, r.Body.String())
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.2.0.1:1000", nil, map[string]any{
		"username": "blocked_u", "password": "Password123!", "device": map[string]string{"class": "desktop"},
	}); r.Code != http.StatusForbidden {
		t.Fatalf("expected 403 registration closed, got %d", r.Code)
	}

	// Invite mode + invite code creation via admin API
	_ = doJSONReq(srv, http.MethodPatch, "/api/admin/settings", adm.AccessToken, "", nil, map[string]any{
		"registration_mode": db.RegistrationModeInvite,
	})
	invRes := doJSONReq(srv, http.MethodPost, "/api/admin/invites", adm.AccessToken, "", nil, map[string]any{
		"max_uses": 1, "note": "vip",
	})
	if invRes.Code != http.StatusOK {
		t.Fatalf("create invite failed: %d %s", invRes.Code, invRes.Body.String())
	}
	var inv struct {
		Invite struct {
			Code string `json:"code"`
		} `json:"invite"`
	}
	_ = json.Unmarshal(invRes.Body.Bytes(), &inv)

	if r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.2.0.2:1000", nil, map[string]any{
		"username": "inv_u1", "password": "Password123!", "invite_code": inv.Invite.Code, "device": map[string]string{"class": "desktop"},
	}); r.Code != http.StatusOK {
		t.Fatalf("invite reg failed: %d %s", r.Code, r.Body.String())
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.2.0.3:1000", nil, map[string]any{
		"username": "inv_u2", "password": "Password123!", "invite_code": inv.Invite.Code, "device": map[string]string{"class": "desktop"},
	}); r.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on exhausted invite code, got %d", r.Code)
	}

	// Open mode -> G8 per-IP rate limit (5 allowed, 6th -> 429)
	open := db.RegistrationModeOpen
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{RegistrationMode: &open}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "198.51.100.7:1234", nil, map[string]any{
			"username": "rl_user_" + string(rune('a'+i)),
			"password": "Password123!",
			"device":   map[string]string{"class": "phone"},
		})
		if r.Code != http.StatusOK {
			t.Fatalf("open reg #%d status=%d body=%s", i, r.Code, r.Body.String())
		}
	}
	rl := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "198.51.100.7:1234", nil, map[string]any{
		"username": "rl_user_6",
		"password": "Password123!",
		"device":   map[string]string{"class": "phone"},
	})
	if rl.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on 6th reg from same IP, got %d body=%s", rl.Code, rl.Body.String())
	}
}

func TestS1QrE2EEHandshakeAndAdminPrivacyLifecycle(t *testing.T) {
	srv, store, _ := newTestAPIServer(t, "")

	// Admin setup
	admRes := doJSONReq(srv, http.MethodPost, "/api/admin/auth/login", "", "", nil, map[string]string{"username": "admin", "password": "admin"})
	var adm struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(admRes.Body.Bytes(), &adm)
	_ = doJSONReq(srv, http.MethodPost, "/api/admin/auth/change-password", adm.AccessToken, "", nil, map[string]string{
		"old_password": "admin", "new_password": "AdminPassword123!",
	})

	// Register phone owner with E2EE wraps
	reg := doJSONReq(srv, http.MethodPost, "/api/v1/auth/register", "", "10.3.0.1:1000", nil, map[string]any{
		"username": "e2ee_owner",
		"password": "Password123!",
		"device":   map[string]string{"class": "phone", "platform": "ios", "name": "Phone"},
		"key_wraps": []map[string]any{
			{
				"wrap_type":       keyring.WrapAccountPassword,
				"kdf_alg":         keyring.KdfAlgPBKDF2,
				"kdf_salt":        "c2FsdA",
				"kdf_params_json": `{"iterations":600000}`,
				"wrapped_hk":      "cipher_hk_v1",
			},
		},
	})
	var ownerAuth struct {
		AccessToken string `json:"access_token"`
		Principal   struct {
			HouseholdID string `json:"household_id"`
			MemberID    string `json:"member_id"`
			DeviceID    string `json:"device_id"`
		} `json:"principal"`
	}
	_ = json.Unmarshal(reg.Body.Bytes(), &ownerAuth)

	// QR E2EE flow
	qrCreate := doJSONReq(srv, http.MethodPost, "/api/v1/auth/qr", "", "10.3.0.2:1000", nil, map[string]string{
		"device_class":     "tv",
		"platform":         "androidtv",
		"device_name":      "TV",
		"ephemeral_pubkey": "tv_pub_key",
	})
	if qrCreate.Code != http.StatusOK {
		t.Fatalf("qr create failed: %d %s", qrCreate.Code, qrCreate.Body.String())
	}
	var qr struct {
		QrID       string `json:"qr_id"`
		PollSecret string `json:"poll_secret"`
	}
	_ = json.Unmarshal(qrCreate.Body.Bytes(), &qr)

	info := doJSONReq(srv, http.MethodGet, "/api/v1/auth/qr/"+qr.QrID, ownerAuth.AccessToken, "", nil, nil)
	if info.Code != http.StatusOK || !strings.Contains(info.Body.String(), "tv_pub_key") {
		t.Fatalf("qr info failed: %d %s", info.Code, info.Body.String())
	}

	if conf := doJSONReq(srv, http.MethodPost, "/api/v1/auth/qr/"+qr.QrID+"/confirm", ownerAuth.AccessToken, "", nil, map[string]string{
		"encrypted_hk": "tv_encrypted_hk_payload",
	}); conf.Code != http.StatusOK {
		t.Fatalf("qr confirm failed: %d %s", conf.Code, conf.Body.String())
	}

	if badPoll := doJSONReq(srv, http.MethodPost, "/api/v1/auth/qr/"+qr.QrID+"/poll", "", "10.3.0.2:1000", nil, map[string]string{
		"poll_secret": "qrs_wrong",
	}); badPoll.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 wrong poll secret, got %d", badPoll.Code)
	}

	goodPoll := doJSONReq(srv, http.MethodPost, "/api/v1/auth/qr/"+qr.QrID+"/poll", "", "10.3.0.2:1000", nil, map[string]string{
		"poll_secret": qr.PollSecret,
	})
	if goodPoll.Code != http.StatusOK {
		t.Fatalf("qr poll failed: %d %s", goodPoll.Code, goodPoll.Body.String())
	}
	var pollRes struct {
		AccessToken string `json:"access_token"`
		EncryptedHK string `json:"encrypted_hk"`
	}
	_ = json.Unmarshal(goodPoll.Body.Bytes(), &pollRes)
	if pollRes.EncryptedHK != "tv_encrypted_hk_payload" || !strings.HasPrefix(pollRes.AccessToken, "usr_") {
		t.Fatalf("unexpected qr poll response: %+v", pollRes)
	}
	// Replay must fail 409
	if replay := doJSONReq(srv, http.MethodPost, "/api/v1/auth/qr/"+qr.QrID+"/poll", "", "10.3.0.2:1000", nil, map[string]string{
		"poll_secret": qr.PollSecret,
	}); replay.Code != http.StatusConflict {
		t.Fatalf("expected 409 on qr poll replay, got %d", replay.Code)
	}
	// TV token authenticates cleanly
	if meTV := doJSONReq(srv, http.MethodGet, "/api/v1/auth/me", pollRes.AccessToken, "", nil, nil); meTV.Code != http.StatusOK {
		t.Fatalf("TV token /auth/me failed: %d %s", meTV.Code, meTV.Body.String())
	}

	// Seed a private source & file to verify D8 privacy isolation on GET /api/admin/accounts
	if _, err := store.DB().Exec(`
		INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at)
		VALUES ('s1', ?, 'quark', 'SecretQuarkName', 'idk_s1', ?, ?, 1, 1);
		INSERT INTO media_items(household_id, kind, library_type, title, sort_title, added_at, updated_at)
		VALUES (?, 'movie', 'movie', 'TopSecretMovieTitle', 'TopSecretMovieTitle', 1, 1);`,
		ownerAuth.Principal.HouseholdID, ownerAuth.Principal.MemberID, ownerAuth.Principal.DeviceID,
		ownerAuth.Principal.HouseholdID,
	); err != nil {
		t.Fatal(err)
	}

	listAcc := doJSONReq(srv, http.MethodGet, "/api/admin/accounts", adm.AccessToken, "", nil, nil)
	if listAcc.Code != http.StatusOK {
		t.Fatalf("admin list accounts failed: %d %s", listAcc.Code, listAcc.Body.String())
	}
	bodyStr := listAcc.Body.String()
	if strings.Contains(bodyStr, "SecretQuarkName") || strings.Contains(bodyStr, "TopSecretMovieTitle") || strings.Contains(bodyStr, "cipher_hk") {
		t.Fatalf("D8 privacy violation in /api/admin/accounts response: %s", bodyStr)
	}
	var listParsed struct {
		Accounts []struct {
			AccountID string         `json:"account_id"`
			ItemCount int            `json:"item_count"`
			SourceCnt map[string]int `json:"source_counts"`
		} `json:"accounts"`
	}
	_ = json.Unmarshal(listAcc.Body.Bytes(), &listParsed)
	if len(listParsed.Accounts) != 1 || listParsed.Accounts[0].ItemCount != 1 || listParsed.Accounts[0].SourceCnt["quark"] != 1 {
		t.Fatalf("unexpected aggregate counts: %+v", listParsed.Accounts)
	}
	accID := listParsed.Accounts[0].AccountID

	// G7 reset-password: wipes wraps & sets must_change_password
	rst := doJSONReq(srv, http.MethodPost, "/api/admin/accounts/"+accID+"/reset-password", adm.AccessToken, "", nil, map[string]string{
		"new_password": "TempUserPass123!",
	})
	if rst.Code != http.StatusOK || !strings.Contains(rst.Body.String(), `"key_wraps_wiped":true`) {
		t.Fatalf("reset-password failed: %d %s", rst.Code, rst.Body.String())
	}
	tempLogin := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", "10.3.0.1:1000", nil, map[string]any{
		"username": "e2ee_owner", "password": "TempUserPass123!", "device": map[string]string{"class": "phone"},
	})
	if tempLogin.Code != http.StatusOK || !strings.Contains(tempLogin.Body.String(), `"must_change_password":true`) {
		t.Fatalf("temp login unexpected: %d %s", tempLogin.Code, tempLogin.Body.String())
	}
	var wrapCnt int
	if err := store.ReadDB().QueryRow(`SELECT COUNT(*) FROM household_key_wraps WHERE household_id = ?`, ownerAuth.Principal.HouseholdID).Scan(&wrapCnt); err != nil || wrapCnt != 0 {
		t.Fatalf("expected wraps wiped on G7 reset, cnt=%d err=%v", wrapCnt, err)
	}

	// G11 7-day delete & restore via admin API
	if del := doJSONReq(srv, http.MethodDelete, "/api/admin/accounts/"+accID, adm.AccessToken, "", nil, nil); del.Code != http.StatusOK {
		t.Fatalf("schedule delete failed: %d %s", del.Code, del.Body.String())
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", "10.3.0.1:1000", nil, map[string]any{
		"username": "e2ee_owner", "password": "TempUserPass123!", "device": map[string]string{"class": "phone"},
	}); r.Code != http.StatusForbidden {
		t.Fatalf("expected 403 pending_delete on login, got %d", r.Code)
	}
	if res := doJSONReq(srv, http.MethodPost, "/api/admin/accounts/"+accID+"/restore", adm.AccessToken, "", nil, nil); res.Code != http.StatusOK {
		t.Fatalf("restore failed: %d %s", res.Code, res.Body.String())
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", "10.3.0.1:1000", nil, map[string]any{
		"username": "e2ee_owner", "password": "TempUserPass123!", "device": map[string]string{"class": "phone"},
	}); r.Code != http.StatusOK {
		t.Fatalf("expected restored login 200, got %d body=%s", r.Code, r.Body.String())
	}
}

func TestS1ProtocolVersionCheckAndSecureTransport(t *testing.T) {
	srv, store, _ := newTestAPIServer(t, "")

	minProto := 2
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{MinProtocolVersion: &minProto}); err != nil {
		t.Fatal(err)
	}

	// Bootstrap remains reachable with old protocol header and announces min_protocol_version=2
	boot := doJSONReq(srv, http.MethodGet, "/api/v1/public/bootstrap", "", "", map[string]string{
		"X-TTPlay-Client": "android/1.0.0/1",
	}, nil)
	if boot.Code != http.StatusOK || !strings.Contains(boot.Body.String(), `"min_protocol_version":2`) {
		t.Fatalf("bootstrap unexpected: %d %s", boot.Code, boot.Body.String())
	}

	// Regular /api/v1/* endpoints reject old protocol version with 426 upgrade_required
	upd := doJSONReq(srv, http.MethodPost, "/api/v1/auth/login", "", "", map[string]string{
		"X-TTPlay-Client": "android/1.0.0/1",
	}, map[string]string{"username": "a", "password": "b"})
	if upd.Code != http.StatusUpgradeRequired || !strings.Contains(upd.Body.String(), "upgrade_required") {
		t.Fatalf("expected 426 upgrade_required, got %d body=%s", upd.Code, upd.Body.String())
	}

	// Compliant client header proceeds normally
	okProto := doJSONReq(srv, http.MethodGet, "/api/v1/public/metadata/config", "", "", map[string]string{
		"X-TTPlay-Client": "android/2.0.0/2",
	}, nil)
	if okProto.Code != http.StatusOK {
		t.Fatalf("expected compliant protocol header 200, got %d", okProto.Code)
	}

	// G6 isSecureTransport checks
	plainReq := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	plainReq.RemoteAddr = "203.0.113.10:1234"
	if srv.isSecureTransport(plainReq) {
		t.Fatalf("plain remote HTTP must not be treated as secure transport")
	}
	spoofReq := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	spoofReq.RemoteAddr = "203.0.113.10:1234"
	spoofReq.Header.Set("X-Forwarded-Proto", "https")
	if srv.isSecureTransport(spoofReq) {
		t.Fatalf("untrusted peer X-Forwarded-Proto: https must be rejected")
	}
	loopbackProxyReq := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	loopbackProxyReq.RemoteAddr = "127.0.0.1:1234"
	loopbackProxyReq.Header.Set("X-Forwarded-Proto", "https")
	if !srv.isSecureTransport(loopbackProxyReq) {
		t.Fatalf("loopback X-Forwarded-Proto: https should be accepted as secure transport")
	}
	srv.SetAllowInsecureCredentials(true)
	if !srv.isSecureTransport(plainReq) {
		t.Fatalf("SetAllowInsecureCredentials(true) should allow transport in debug mode")
	}
}
