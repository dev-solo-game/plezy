package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func doReq(t *testing.T, handler http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode req: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func TestAuthAndQrFlow(t *testing.T) {
	store, err := OpenSyncStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	regRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "alice",
		AuthVerifier:             "verifier-1",
		KdfSalt:                  "c2FsdA==",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:mk:v1:abc",
		Settings:                 map[string]any{"tmdb_image_base_url": "https://mirror.example/t/p"},
		DeviceID:                 "phone-1",
	})
	if regRec.Code != http.StatusOK {
		t.Fatalf("register status=%d body=%s", regRec.Code, regRec.Body.String())
	}
	var regResp AuthResponse
	_ = json.Unmarshal(regRec.Body.Bytes(), &regResp)
	if regResp.AccessToken == "" || regResp.UserID == "" {
		t.Fatalf("missing token/userId: %+v", regResp)
	}

	kdfRec := doReq(t, mux, "GET", "/api/v1/auth/kdf?username=alice", "", nil)
	if kdfRec.Code != http.StatusOK {
		t.Fatalf("kdf status=%d", kdfRec.Code)
	}

	badLogin := doReq(t, mux, "POST", "/api/v1/auth/login", "", LoginRequest{
		Username:     "alice",
		AuthVerifier: "wrong",
		DeviceID:     "pc-1",
	})
	if badLogin.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on wrong verifier, got %d", badLogin.Code)
	}

	okLogin := doReq(t, mux, "POST", "/api/v1/auth/login", "", LoginRequest{
		Username:     "alice",
		AuthVerifier: "verifier-1",
		DeviceID:     "pc-1",
	})
	if okLogin.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", okLogin.Code, okLogin.Body.String())
	}

	qrCreate := doReq(t, mux, "POST", "/api/v1/auth/qr/create", "", QrCreateRequest{
		TvPubKey:   "tv-pub-key",
		DeviceName: "LivingRoomTV",
	})
	if qrCreate.Code != http.StatusOK {
		t.Fatalf("qr create failed: %d", qrCreate.Code)
	}
	var qrResp QrCreateResponse
	_ = json.Unmarshal(qrCreate.Body.Bytes(), &qrResp)

	qrConfirm := doReq(t, mux, "POST", "/api/v1/auth/qr/confirm", regResp.AccessToken, QrConfirmRequest{
		SessionID:       qrResp.SessionID,
		SealedMasterKey: "sealed-x25519-box",
		DeviceID:        "tv-1",
	})
	if qrConfirm.Code != http.StatusOK {
		t.Fatalf("qr confirm failed: %d %s", qrConfirm.Code, qrConfirm.Body.String())
	}

	qrPoll := doReq(t, mux, "GET", "/api/v1/auth/qr/poll?session_id="+qrResp.SessionID, "", nil)
	var pollResp QrPollResponse
	_ = json.Unmarshal(qrPoll.Body.Bytes(), &pollResp)
	if pollResp.Status != "confirmed" || pollResp.AccessToken == "" || pollResp.SealedMasterKey != "sealed-x25519-box" {
		t.Fatalf("unexpected qr poll response: %+v", pollResp)
	}
}

func TestSourceDedupFileRekeyMonotonicAndLww(t *testing.T) {
	dataDir := t.TempDir()
	store, err := OpenSyncStore(dataDir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	regRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "bob",
		AuthVerifier:             "v1",
		KdfSalt:                  "salt",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:mk",
		DeviceID:                 "dev-a",
	})
	var auth AuthResponse
	_ = json.Unmarshal(regRec.Body.Bytes(), &auth)
	tok := auth.AccessToken

	// Device A pushes Quark source uuid-A with checkpoint 0:3000 + Level 4 locked work + file + subtitle.
	cpA := "0:3000"
	providerTmdb := "tmdb"
	ext27205 := "27205"
	workKey := "tmdb:movie:27205"
	vidIDOnA := generateFileID("uuid-A", "/Movies/Inception.mkv")
	subIDOnA := generateFileID("uuid-A", "/Movies/Inception.srt")

	pushA := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "dev-a",
		Mutations: []PushMutation{
			{
				OpID:       "op-1",
				EntityType: "source",
				EntityKey:  "uuid-A",
				Payload: mustJSON(t, SyncSource{
					SourceID:        "uuid-A",
					CanonicalKey:    "quark:888999:0",
					Name:            "Phone Quark",
					Protocol:        "quark",
					PrimaryURL:      "quark://0",
					IncludePaths:    []string{"/Movies"},
					ExcludePaths:    []string{},
					EncryptedAuth:   "enc:auth:old",
					AuthUpdatedAt:   1000,
					QuarkCheckpoint: &cpA,
					ClientUpdatedAt: 1000,
				}),
			},
			{
				OpID:       "op-2",
				EntityType: "work",
				EntityKey:  workKey,
				Payload: mustJSON(t, SyncWork{
					WorkKey:         workKey,
					Kind:            "movie",
					LibraryType:     "movie",
					Provider:        &providerTmdb,
					ExternalID:      &ext27205,
					MatchStatus:     4, // matchLocked
					MetadataJSON:    map[string]any{"title": "盗梦空间"},
					ClientUpdatedAt: 1000,
				}),
			},
			{
				OpID:       "op-3",
				EntityType: "file",
				EntityKey:  vidIDOnA,
				Payload: mustJSON(t, SyncFile{
					FileID:          vidIDOnA,
					SourceID:        "uuid-A",
					RelativePath:    "/Movies/Inception.mkv",
					Role:            "video",
					FileName:        "Inception.mkv",
					FileSize:        4000,
					WorkKey:         &workKey,
					MatchStatus:     4,
					MediaSpecJSON:   map[string]any{},
					ClientUpdatedAt: 1000,
				}),
			},
		},
	})
	if pushA.Code != http.StatusOK {
		t.Fatalf("pushA status=%d", pushA.Code)
	}

	// Device B independently created the same Quark account as uuid-B with newer checkpoint 0:8000,
	// older/stale unmatched work (Level 2 at t=999999), and a subtitle referencing uuid-B.
	cpB := "0:8000"
	vidIDOnB := generateFileID("uuid-B", "/Movies/Inception2.mkv")
	subIDOnB := generateFileID("uuid-B", "/Movies/Inception2.srt")
	pushB := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "dev-b",
		Mutations: []PushMutation{
			{
				OpID:       "op-b1",
				EntityType: "source",
				EntityKey:  "uuid-B",
				Payload: mustJSON(t, SyncSource{
					SourceID:        "uuid-B",
					CanonicalKey:    "quark:888999:0",
					Name:            "TV Quark",
					Protocol:        "quark",
					PrimaryURL:      "quark://0",
					EncryptedAuth:   "enc:auth:new",
					AuthUpdatedAt:   2000,
					QuarkCheckpoint: &cpB,
					ClientUpdatedAt: 2000,
				}),
			},
			{
				OpID:       "op-b2",
				EntityType: "work",
				EntityKey:  workKey,
				Payload: mustJSON(t, SyncWork{
					WorkKey:         workKey,
					Kind:            "movie",
					LibraryType:     "pending",
					MatchStatus:     2, // unmatched -> MUST NOT overwrite Level 4 even with huge timestamp!
					MetadataJSON:    map[string]any{"title": "Wrong"},
					ClientUpdatedAt: 9999999,
				}),
			},
			{
				OpID:       "op-b3",
				EntityType: "file",
				EntityKey:  vidIDOnB,
				Payload: mustJSON(t, SyncFile{
					FileID:          vidIDOnB,
					SourceID:        "uuid-B",
					RelativePath:    "/Movies/Inception2.mkv",
					Role:            "video",
					FileName:        "Inception2.mkv",
					FileSize:        5000,
					WorkKey:         &workKey,
					MatchStatus:     3,
					MediaSpecJSON:   map[string]any{},
					ClientUpdatedAt: 2000,
				}),
			},
			{
				OpID:       "op-b4",
				EntityType: "file",
				EntityKey:  subIDOnB,
				Payload: mustJSON(t, SyncFile{
					FileID:          subIDOnB,
					SourceID:        "uuid-B",
					RelativePath:    "/Movies/Inception2.srt",
					Role:            "subtitle",
					OwnerFileID:     &vidIDOnB,
					FileName:        "Inception2.srt",
					FileSize:        50,
					MediaSpecJSON:   map[string]any{},
					ClientUpdatedAt: 2000,
				}),
			},
		},
	})
	var pushBResp PushResponse
	_ = json.Unmarshal(pushB.Body.Bytes(), &pushBResp)
	if pushBResp.RemappedSources["uuid-B"] != "uuid-A" {
		t.Fatalf("expected uuid-B remapped to uuid-A, got %+v", pushBResp.RemappedSources)
	}
	_ = subIDOnA

	// Paginated pull (limit=2) should yield all entities cleanly without losing any seq.
	var allWorks []SyncWork
	var allFiles []SyncFile
	mergedSources := map[string]SyncSource{}
	var seq int64
	for {
		rec := doReq(t, mux, "GET", "/api/v1/sync/pull?limit=2&since_seq="+itoa64(seq), tok, nil)
		var pull PullResponse
		_ = json.Unmarshal(rec.Body.Bytes(), &pull)
		for _, src := range pull.Data.Sources {
			mergedSources[src.SourceID] = src
		}
		allWorks = append(allWorks, pull.Data.Works...)
		allFiles = append(allFiles, pull.Data.Files...)
		seq = pull.NextSeq
		if !pull.HasMore {
			break
		}
	}

	mergedSource := mergedSources["uuid-A"]
	if len(mergedSources) != 1 || mergedSource.QuarkCheckpoint == nil || *mergedSource.QuarkCheckpoint != "0:8000" {
		t.Fatalf("unexpected merged sources: %+v", mergedSources)
	}
	if len(allWorks) != 1 || allWorks[0].MatchStatus != 4 || allWorks[0].MetadataJSON["title"] != "盗梦空间" {
		t.Fatalf("Level 4 work overwritten unexpectedly: %+v", allWorks)
	}
	expectedVidID := generateFileID("uuid-A", "/Movies/Inception2.mkv")
	foundSub := false
	for _, f := range allFiles {
		if f.FileID == generateFileID("uuid-A", "/Movies/Inception2.srt") {
			foundSub = true
			if f.OwnerFileID == nil || *f.OwnerFileID != expectedVidID {
				t.Fatalf("expected subtitle owner remapped to %s, got %v", expectedVidID, f.OwnerFileID)
			}
		}
	}
	if !foundSub {
		t.Fatalf("remapped subtitle not found in pull files: %+v", allFiles)
	}

	// Lease mutual exclusion check.
	leaseA := doReq(t, mux, "POST", "/api/v1/sync/lease", tok, LeaseRequest{SourceID: "uuid-B", DeviceID: "dev-a", TtlSec: 60})
	var lA LeaseResponse
	_ = json.Unmarshal(leaseA.Body.Bytes(), &lA)
	if !lA.Acquired {
		t.Fatalf("expected dev-a to acquire lease")
	}
	leaseB := doReq(t, mux, "POST", "/api/v1/sync/lease", tok, LeaseRequest{SourceID: "uuid-A", DeviceID: "dev-b", TtlSec: 60})
	var lB LeaseResponse
	_ = json.Unmarshal(leaseB.Body.Bytes(), &lB)
	if lB.Acquired || lB.HolderDeviceID != "dev-a" {
		t.Fatalf("expected dev-b blocked by dev-a lease, got %+v", lB)
	}

	// Verify WAL reload after server restart + GC reset_required flow.
	_ = store.Close()
	reloaded, err := OpenSyncStore(dataDir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reloaded.Close()

	// Delete a work in the distant past and run GC so minRetainedSeq advances.
	reloadedUser, err := reloaded.Authenticate(tok)
	if err != nil {
		t.Fatalf("reloaded auth failed: %v", err)
	}
	oldDeletedAt := nowMs() - tombstoneRetentionMs - 5000
	_, _ = reloaded.Push(reloadedUser.UserID, PushRequest{
		DeviceID: "dev-a",
		Mutations: []PushMutation{
			{
				OpID:       "op-old-del",
				EntityType: "work",
				EntityKey:  "tmdb:movie:999",
				Payload: mustJSON(t, SyncWork{
					WorkKey:         "tmdb:movie:999",
					Kind:            "movie",
					LibraryType:     "movie",
					MatchStatus:     3,
					IsDeleted:       true,
					ClientUpdatedAt: oldDeletedAt,
				}),
			},
		},
	})
	if err := reloaded.RunGC(nowMs()); err != nil {
		t.Fatalf("gc: %v", err)
	}
	stalePull := reloaded.Pull(reloadedUser, 1, 100)
	if !stalePull.ResetRequired {
		t.Fatalf("expected reset_required=true after 30d tombstone GC")
	}
}

func TestPushIdempotencyDoesNotAdvanceSeqForUnchangedEntities(t *testing.T) {
	store, err := OpenSyncStore(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	regRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "idemp",
		AuthVerifier:             "v1",
		KdfSalt:                  "salt",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:mk",
		DeviceID:                 "pc-1",
	})
	var auth AuthResponse
	_ = json.Unmarshal(regRec.Body.Bytes(), &auth)
	tok := auth.AccessToken

	cp := "0:1000"
	providerTmdb := "tmdb"
	extID := "693134"
	workKey := "tmdb:movie:693134"
	fileID := generateFileID("src-1", "/Movies/Dune2.mkv")
	srcPayload := SyncSource{
		SourceID:        "src-1",
		CanonicalKey:    "quark:111:0",
		Name:            "Quark",
		Protocol:        "quark",
		PrimaryURL:      "quark://0",
		IncludePaths:    []string{},
		ExcludePaths:    []string{},
		EncryptedAuth:   "enc:a",
		AuthUpdatedAt:   1000,
		QuarkCheckpoint: &cp,
		ScanFinishedAt:  1000,
		ClientUpdatedAt: 1000,
	}
	workPayload := SyncWork{
		WorkKey:         workKey,
		Kind:            "movie",
		LibraryType:     "movie",
		Provider:        &providerTmdb,
		ExternalID:      &extID,
		MatchStatus:     3,
		MetadataJSON:    map[string]any{"title": "沙丘2", "year": 2024},
		ClientUpdatedAt: 1000,
	}
	filePayload := SyncFile{
		FileID:          fileID,
		SourceID:        "src-1",
		RelativePath:    "/Movies/Dune2.mkv",
		Role:            "video",
		FileName:        "Dune2.mkv",
		FileSize:        9000,
		FileMtime:       1000,
		WorkKey:         &workKey,
		SeasonNum:       -1,
		EpisodeNum:      -1,
		MatchStatus:     3,
		MediaSpecJSON:   map[string]any{"width": 3840},
		ClientUpdatedAt: 1000,
	}
	prefPayload := SyncWorkPref{
		WorkKey:         workKey,
		IntroEnabled:    true,
		IntroEndMs:      90000,
		IsFavorite:      true,
		ClientUpdatedAt: 1000,
	}
	progPayload := SyncWatchProgress{
		ProgressKey:     workKey,
		WorkKey:         workKey,
		SeasonNum:       -1,
		EpisodeNum:      -1,
		PositionMs:      60000,
		DurationMs:      3600000,
		Watched:         false,
		ClientUpdatedAt: 1000,
	}

	firstPush := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "pc-1",
		Mutations: []PushMutation{
			{OpID: "op-1", EntityType: "source", EntityKey: "src-1", Payload: mustJSON(t, srcPayload)},
			{OpID: "op-2", EntityType: "work", EntityKey: workKey, Payload: mustJSON(t, workPayload)},
			{OpID: "op-3", EntityType: "file", EntityKey: fileID, Payload: mustJSON(t, filePayload)},
			{OpID: "op-4", EntityType: "work_pref", EntityKey: workKey, Payload: mustJSON(t, prefPayload)},
			{OpID: "op-5", EntityType: "watch_progress", EntityKey: workKey, Payload: mustJSON(t, progPayload)},
		},
	})
	if firstPush.Code != http.StatusOK {
		t.Fatalf("first push failed: %d %s", firstPush.Code, firstPush.Body.String())
	}

	pull1 := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq=0", tok, nil)
	var p1 PullResponse
	_ = json.Unmarshal(pull1.Body.Bytes(), &p1)
	if p1.NextSeq != 5 {
		t.Fatalf("expected next_seq=5 after initial 5 entities, got %d", p1.NextSeq)
	}

	// Re-push identical semantics with brand-new opIds, newer ClientUpdatedAt, ScanFinishedAt, and re-encrypted auth nonce.
	srcPayload.ScanFinishedAt = 2000
	srcPayload.EncryptedAuth = "enc:re-encrypted-with-new-nonce"
	srcPayload.ClientUpdatedAt = 2000
	workPayload.ClientUpdatedAt = 2000
	filePayload.ClientUpdatedAt = 2000
	prefPayload.ClientUpdatedAt = 2000
	progPayload.ClientUpdatedAt = 2000

	secondPush := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "pc-1",
		Mutations: []PushMutation{
			{OpID: "op-2-1", EntityType: "source", EntityKey: "src-1", Payload: mustJSON(t, srcPayload)},
			{OpID: "op-2-2", EntityType: "work", EntityKey: workKey, Payload: mustJSON(t, workPayload)},
			{OpID: "op-2-3", EntityType: "file", EntityKey: fileID, Payload: mustJSON(t, filePayload)},
			{OpID: "op-2-4", EntityType: "work_pref", EntityKey: workKey, Payload: mustJSON(t, prefPayload)},
			{OpID: "op-2-5", EntityType: "watch_progress", EntityKey: workKey, Payload: mustJSON(t, progPayload)},
		},
	})
	if secondPush.Code != http.StatusOK {
		t.Fatalf("second push failed: %d", secondPush.Code)
	}
	var push2Resp PushResponse
	_ = json.Unmarshal(secondPush.Body.Bytes(), &push2Resp)
	if len(push2Resp.AcceptedOpIDs) != 5 {
		t.Fatalf("expected all 5 opIds acked, got %d", len(push2Resp.AcceptedOpIDs))
	}

	pull2 := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq="+itoa64(p1.NextSeq), tok, nil)
	var p2 PullResponse
	_ = json.Unmarshal(pull2.Body.Bytes(), &p2)
	if p2.NextSeq != p1.NextSeq || p2.CurrentMaxSeq != p1.CurrentMaxSeq ||
		len(p2.Data.Sources)+len(p2.Data.Works)+len(p2.Data.Files)+len(p2.Data.WorkPrefs)+len(p2.Data.WatchProgress) != 0 {
		t.Fatalf("expected 0 deltas and unchanged seq=%d, got next=%d max=%d counts=(%d,%d,%d,%d,%d)",
			p1.NextSeq, p2.NextSeq, p2.CurrentMaxSeq,
			len(p2.Data.Sources), len(p2.Data.Works), len(p2.Data.Files), len(p2.Data.WorkPrefs), len(p2.Data.WatchProgress))
	}
}

func itoa64(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func TestWebAuthUserPanelAndAdminConsole(t *testing.T) {
	store, err := OpenSyncStore(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	// Web index serves HTML.
	idxRec := doReq(t, mux, "GET", "/", "", nil)
	if idxRec.Code != http.StatusOK || !bytes.Contains(idxRec.Body.Bytes(), []byte("Plezy Sync Server")) {
		t.Fatalf("unexpected web index status=%d", idxRec.Code)
	}

	// First user registered via Web becomes admin.
	regAdmin := doReq(t, mux, "POST", "/api/v1/web/register", "", WebAuthRequest{
		Username:   "admin_user",
		Password:   "Secret123!",
		DeviceID:   "web-1",
		DeviceName: "Desktop Browser",
		Platform:   "Windows",
	})
	if regAdmin.Code != http.StatusOK {
		t.Fatalf("web register admin status=%d body=%s", regAdmin.Code, regAdmin.Body.String())
	}
	var adminAuth AuthResponse
	_ = json.Unmarshal(regAdmin.Body.Bytes(), &adminAuth)
	if !adminAuth.IsAdmin {
		t.Fatalf("expected first user to be admin")
	}

	// Verify Flutter-compatible KDF & MasterKey envelope unsealing.
	saltBytes, err := base64.StdEncoding.DecodeString(adminAuth.KdfSalt)
	if err != nil {
		t.Fatalf("decode salt: %v", err)
	}
	kek1, verifier1, err := DerivePasswordKeys("Secret123!", saltBytes, adminAuth.KdfParams)
	if err != nil {
		t.Fatalf("derive keys: %v", err)
	}
	mk1, err := UnsealMasterKeyBackup(adminAuth.EncryptedMasterKeyBackup, kek1)
	if err != nil || len(mk1) != 32 {
		t.Fatalf("unseal master key failed: err=%v len=%d", err, len(mk1))
	}

	// Same derived verifier works on the App login route.
	appLogin := doReq(t, mux, "POST", "/api/v1/auth/login", "", LoginRequest{
		Username:     "admin_user",
		AuthVerifier: verifier1,
		DeviceID:     "tv-living",
		DeviceName:   "Living Room TV",
		Platform:     "AndroidTV",
	})
	if appLogin.Code != http.StatusOK {
		t.Fatalf("app login after web register failed: %d %s", appLogin.Code, appLogin.Body.String())
	}
	var appLoginResp AuthResponse
	_ = json.Unmarshal(appLogin.Body.Bytes(), &appLoginResp)

	// Change password via Web -> MasterKey must remain identical.
	pwRec := doReq(t, mux, "POST", "/api/v1/web/password", adminAuth.AccessToken, WebPasswordChangeRequest{
		OldPassword: "Secret123!",
		NewPassword: "NewSecret456!",
	})
	if pwRec.Code != http.StatusOK {
		t.Fatalf("web change password failed: %d %s", pwRec.Code, pwRec.Body.String())
	}
	reLogin := doReq(t, mux, "POST", "/api/v1/web/login", "", WebAuthRequest{
		Username: "admin_user",
		Password: "NewSecret456!",
		DeviceID: "web-2",
	})
	if reLogin.Code != http.StatusOK {
		t.Fatalf("web relogin failed: %d %s", reLogin.Code, reLogin.Body.String())
	}
	var reAuth AuthResponse
	_ = json.Unmarshal(reLogin.Body.Bytes(), &reAuth)
	salt2, _ := base64.StdEncoding.DecodeString(reAuth.KdfSalt)
	kek2, _, _ := DerivePasswordKeys("NewSecret456!", salt2, reAuth.KdfParams)
	mk2, err := UnsealMasterKeyBackup(reAuth.EncryptedMasterKeyBackup, kek2)
	if err != nil || !bytes.Equal(mk1, mk2) {
		t.Fatalf("expected master key preserved across password change, err=%v", err)
	}

	// List devices and revoke the TV token.
	devRec := doReq(t, mux, "GET", "/api/v1/user/devices", adminAuth.AccessToken, nil)
	var devResp struct {
		Devices []DeviceTokenInfo `json:"devices"`
	}
	_ = json.Unmarshal(devRec.Body.Bytes(), &devResp)
	if len(devResp.Devices) != 3 {
		t.Fatalf("expected 3 devices, got %d", len(devResp.Devices))
	}
	var tvTokenID string
	for _, d := range devResp.Devices {
		if d.DeviceID == "tv-living" {
			tvTokenID = d.TokenID
		}
	}
	if tvTokenID == "" {
		t.Fatalf("tv-living token not found in device list")
	}
	revRec := doReq(t, mux, "DELETE", "/api/v1/user/devices/"+tvTokenID, adminAuth.AccessToken, nil)
	if revRec.Code != http.StatusOK {
		t.Fatalf("revoke device failed: %d", revRec.Code)
	}
	tvPull := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq=0", appLoginResp.AccessToken, nil)
	if tvPull.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for revoked device token, got %d", tvPull.Code)
	}

	// Second user is non-admin and blocked from admin endpoints.
	regUser := doReq(t, mux, "POST", "/api/v1/web/register", "", WebAuthRequest{
		Username: "bob_public",
		Password: "Password123",
		DeviceID: "phone-bob",
	})
	if regUser.Code != http.StatusOK {
		t.Fatalf("register bob failed: %d", regUser.Code)
	}
	var bobAuth AuthResponse
	_ = json.Unmarshal(regUser.Body.Bytes(), &bobAuth)
	if bobAuth.IsAdmin {
		t.Fatalf("expected second user not to be admin")
	}
	if rec := doReq(t, mux, "GET", "/api/v1/admin/overview", bobAuth.AccessToken, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for non-admin overview, got %d", rec.Code)
	}

	// Admin closes registration and enforces quota = 1.
	allowFalse := false
	quotaOne := int64(1)
	cfgRec := doReq(t, mux, "POST", "/api/v1/admin/config", adminAuth.AccessToken, AdminConfigRequest{
		AllowRegistration:  &allowFalse,
		MaxEntitiesPerUser: &quotaOne,
	})
	if cfgRec.Code != http.StatusOK {
		t.Fatalf("admin config failed: %d", cfgRec.Code)
	}
	regBlocked := doReq(t, mux, "POST", "/api/v1/web/register", "", WebAuthRequest{
		Username: "charlie",
		Password: "Password123",
	})
	if regBlocked.Code != http.StatusForbidden {
		t.Fatalf("expected 403 when registration closed, got %d", regBlocked.Code)
	}

	quotaPush := doReq(t, mux, "POST", "/api/v1/sync/push", bobAuth.AccessToken, PushRequest{
		DeviceID: "phone-bob",
		Mutations: []PushMutation{
			{
				OpID:       "q1",
				EntityType: "work",
				EntityKey:  "tmdb:movie:1",
				Payload: mustJSON(t, SyncWork{
					WorkKey: "tmdb:movie:1", Kind: "movie", LibraryType: "movie", MatchStatus: 3, ClientUpdatedAt: 1000,
				}),
			},
			{
				OpID:       "q2",
				EntityType: "work",
				EntityKey:  "tmdb:movie:2",
				Payload: mustJSON(t, SyncWork{
					WorkKey: "tmdb:movie:2", Kind: "movie", LibraryType: "movie", MatchStatus: 3, ClientUpdatedAt: 1001,
				}),
			},
		},
	})
	if quotaPush.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 quota exceeded, got %d body=%s", quotaPush.Code, quotaPush.Body.String())
	}

	// Admin disables bob: active token is invalidated (401) and re-login returns 403.
	disableRec := doReq(t, mux, "POST", "/api/v1/admin/users/"+bobAuth.UserID+"/status", adminAuth.AccessToken, AdminUserStatusRequest{
		IsDisabled: true,
	})
	if disableRec.Code != http.StatusOK {
		t.Fatalf("disable user failed: %d", disableRec.Code)
	}
	if rec := doReq(t, mux, "GET", "/api/v1/user/me", bobAuth.AccessToken, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for invalidated token of disabled user, got %d", rec.Code)
	}
	if rec := doReq(t, mux, "POST", "/api/v1/web/login", "", WebAuthRequest{
		Username: "bob_public",
		Password: "Password123",
	}); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on login for disabled user, got %d", rec.Code)
	}
	if rec := doReq(t, mux, "GET", "/api/v1/admin/overview", adminAuth.AccessToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("admin overview failed: %d", rec.Code)
	}
	if rec := doReq(t, mux, "GET", "/api/v1/admin/users", adminAuth.AccessToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("admin users list failed: %d", rec.Code)
	}
	if rec := doReq(t, mux, "DELETE", "/api/v1/admin/users/"+bobAuth.UserID, adminAuth.AccessToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("admin delete user failed: %d", rec.Code)
	}
}

func TestSyncListsAndSameMsWatchProgressTieBreak(t *testing.T) {
	runTieOrder := func(firstWatched, secondWatched bool, firstPos, secondPos int64) SyncWatchProgress {
		store, err := OpenSyncStore(t.TempDir())
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		defer store.Close()
		mux := NewSyncMux(store)

		reg := doReq(t, mux, "POST", "/api/v1/web/register", "", WebAuthRequest{
			Username: "tieuser",
			Password: "Password123",
		})
		var auth AuthResponse
		_ = json.Unmarshal(reg.Body.Bytes(), &auth)

		_ = doReq(t, mux, "POST", "/api/v1/sync/push", auth.AccessToken, PushRequest{
			DeviceID: "dev-1",
			Mutations: []PushMutation{
				{
					OpID:       "p1",
					EntityType: "watch_progress",
					EntityKey:  "tmdb:movie:100",
					Payload: mustJSON(t, SyncWatchProgress{
						ProgressKey: "tmdb:movie:100", WorkKey: "tmdb:movie:100", SeasonNum: -1, EpisodeNum: -1,
						PositionMs: firstPos, DurationMs: 600000, Watched: firstWatched, ClientUpdatedAt: 5000,
					}),
				},
			},
		})
		_ = doReq(t, mux, "POST", "/api/v1/sync/push", auth.AccessToken, PushRequest{
			DeviceID: "dev-2",
			Mutations: []PushMutation{
				{
					OpID:       "p2",
					EntityType: "watch_progress",
					EntityKey:  "tmdb:movie:100",
					Payload: mustJSON(t, SyncWatchProgress{
						ProgressKey: "tmdb:movie:100", WorkKey: "tmdb:movie:100", SeasonNum: -1, EpisodeNum: -1,
						PositionMs: secondPos, DurationMs: 600000, Watched: secondWatched, ClientUpdatedAt: 5000,
					}),
				},
			},
		})

		pull := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq=0", auth.AccessToken, nil)
		var resp PullResponse
		_ = json.Unmarshal(pull.Body.Bytes(), &resp)
		if len(resp.Data.WatchProgress) != 1 {
			t.Fatalf("expected 1 progress row, got %d", len(resp.Data.WatchProgress))
		}
		return resp.Data.WatchProgress[0]
	}

	resAB := runTieOrder(true, false, 100, 500)
	resBA := runTieOrder(false, true, 500, 100)
	if !resAB.Watched || !resBA.Watched || resAB.PositionMs != resBA.PositionMs {
		t.Fatalf("same-ms tie-break order mismatch: AB=%+v BA=%+v", resAB, resBA)
	}

	// Sync lists push & pull.
	store, err := OpenSyncStore(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)
	reg := doReq(t, mux, "POST", "/api/v1/web/register", "", WebAuthRequest{
		Username: "listuser",
		Password: "Password123",
	})
	var auth AuthResponse
	_ = json.Unmarshal(reg.Body.Bytes(), &auth)

	pushList := doReq(t, mux, "POST", "/api/v1/sync/push", auth.AccessToken, PushRequest{
		DeviceID: "phone",
		Mutations: []PushMutation{
			{
				OpID:       "l1",
				EntityType: "list",
				EntityKey:  "playlist:My Favorites",
				Payload: mustJSON(t, SyncList{
					ListKey:         "playlist:My Favorites",
					Kind:            "playlist",
					Title:           "My Favorites",
					ItemWorkKeys:    []string{"tmdb:movie:27205", "tmdb:show:1399"},
					ClientUpdatedAt: 1000,
				}),
			},
		},
	})
	if pushList.Code != http.StatusOK {
		t.Fatalf("push list failed: %d", pushList.Code)
	}
	pull := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq=0", auth.AccessToken, nil)
	var resp PullResponse
	_ = json.Unmarshal(pull.Body.Bytes(), &resp)
	if len(resp.Data.Lists) != 1 || resp.Data.Lists[0].Title != "My Favorites" || len(resp.Data.Lists[0].ItemWorkKeys) != 2 {
		t.Fatalf("unexpected pulled lists: %+v", resp.Data.Lists)
	}
}

func TestLegacySnapshotMigration(t *testing.T) {
	dir := t.TempDir()
	snap := legacySnapshot{
		Users: map[string]*UserRecord{
			"usr_legacy": {
				UserID:                   "usr_legacy",
				Username:                 "legacy_user",
				AuthSalt:                 "salt1",
				AuthHash:                 hashAuthVerifier("salt1", "ver1"),
				KdfSalt:                  "kdfsalt",
				KdfParams:                DefaultKdfParams(),
				EncryptedMasterKeyBackup: "enc:mk:v1:legacy",
				Settings:                 map[string]any{"preferred_scrape_lang": "zh-CN"},
				CreatedAt:                1000,
				UpdatedAt:                1000,
			},
		},
		ByUsername: map[string]string{"legacy_user": "usr_legacy"},
		Tokens: map[string]legacyTokenEntry{
			"legacy_tok_123": {UserID: "usr_legacy", DeviceID: "old-pc", CreatedAt: 1000},
		},
		UserSyncData: map[string]*legacyUserSyncState{
			"usr_legacy": {
				NextSeq: 1,
				Works: map[string]*SyncWork{
					"tmdb:movie:10": {
						WorkKey: "tmdb:movie:10", Kind: "movie", LibraryType: "movie",
						MatchStatus: 3, MetadataJSON: map[string]any{"title": "Legacy Movie"},
						ClientUpdatedAt: 1000, ServerSeq: 1,
					},
				},
			},
		},
	}
	raw, _ := json.Marshal(snap)
	if err := os.WriteFile(filepath.Join(dir, "sync.snapshot.json"), raw, 0o600); err != nil {
		t.Fatalf("write legacy snapshot: %v", err)
	}

	store, err := OpenSyncStore(dir)
	if err != nil {
		t.Fatalf("open migrated store: %v", err)
	}
	defer store.Close()

	u, err := store.Authenticate("legacy_tok_123")
	if err != nil || !u.IsAdmin || u.Username != "legacy_user" {
		t.Fatalf("expected migrated legacy user as admin, got u=%+v err=%v", u, err)
	}
	pull := store.Pull(u, 0, 100)
	if len(pull.Data.Works) != 1 || pull.Data.Works[0].MetadataJSON["title"] != "Legacy Movie" {
		t.Fatalf("expected migrated work in pull, got %+v", pull.Data.Works)
	}
	if _, err := os.Stat(filepath.Join(dir, "sync.snapshot.json.migrated")); err != nil {
		t.Fatalf("expected legacy snapshot renamed to .migrated: %v", err)
	}
}

func TestPullPreIncludesFutureSeqSourceForEarlierFiles(t *testing.T) {
	store, err := OpenSyncStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	regRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "preinc",
		AuthVerifier:             "hash",
		KdfSalt:                  "salt",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:backup",
		DeviceID:                 "pc-1",
	})
	var auth AuthResponse
	_ = json.Unmarshal(regRec.Body.Bytes(), &auth)
	tok := auth.AccessToken

	workKey := "tmdb:movie:9901"
	src := SyncSource{
		SourceID:        "src-1",
		CanonicalKey:    "webdav|http://nas/dav",
		Name:            "NAS",
		Protocol:        "webdav",
		PrimaryURL:      "http://nas/dav",
		EncryptedAuth:   "enc:auth",
		AuthUpdatedAt:   1000,
		ClientUpdatedAt: 1000,
	}
	file1 := SyncFile{
		FileID: "f-1", SourceID: "src-1", RelativePath: "/Movies/A.mkv", Role: "video",
		FileName: "A.mkv", FileSize: 100, FileMtime: 1000, WorkKey: &workKey,
		SeasonNum: -1, EpisodeNum: -1, MatchStatus: 3, ClientUpdatedAt: 1000,
	}
	file2 := SyncFile{
		FileID: "f-2", SourceID: "src-1", RelativePath: "/Movies/B.mkv", Role: "video",
		FileName: "B.mkv", FileSize: 200, FileMtime: 1000, WorkKey: &workKey,
		SeasonNum: -1, EpisodeNum: -1, MatchStatus: 3, ClientUpdatedAt: 1000,
	}

	// Push source + 2 files initially (seqs 1, 2, 3), then update src-1 (e.g. checkpoint) to move it to seq 4.
	push1 := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "pc-1",
		Mutations: []PushMutation{
			{OpID: "op-s1", EntityType: "source", EntityKey: "src-1", Payload: mustJSON(t, src)},
			{OpID: "op-f1", EntityType: "file", EntityKey: "f-1", Payload: mustJSON(t, file1)},
			{OpID: "op-f2", EntityType: "file", EntityKey: "f-2", Payload: mustJSON(t, file2)},
		},
	})
	if push1.Code != http.StatusOK {
		t.Fatalf("initial push failed: %d %s", push1.Code, push1.Body.String())
	}
	cp := "cp-99"
	src.QuarkCheckpoint = &cp
	src.ScanFinishedAt = 2000
	src.ClientUpdatedAt = 2000
	push2 := doReq(t, mux, "POST", "/api/v1/sync/push", tok, PushRequest{
		DeviceID: "pc-1",
		Mutations: []PushMutation{
			{OpID: "op-s2", EntityType: "source", EntityKey: "src-1", Payload: mustJSON(t, src)},
		},
	})
	if push2.Code != http.StatusOK {
		t.Fatalf("update source push failed: %d %s", push2.Code, push2.Body.String())
	}

	// Pull Page 1 with limit=2 (gets only f-1 and f-2 at seqs 2 & 3 while src-1 sits at seq 4).
	pullRec := doReq(t, mux, "GET", "/api/v1/sync/pull?since_seq=0&limit=2", tok, nil)
	var pull PullResponse
	_ = json.Unmarshal(pullRec.Body.Bytes(), &pull)
	if !pull.HasMore {
		t.Fatalf("expected HasMore=true on page 1")
	}
	if len(pull.Data.Files) != 2 {
		t.Fatalf("expected 2 files on page 1, got %d", len(pull.Data.Files))
	}
	if len(pull.Data.Sources) != 1 || pull.Data.Sources[0].SourceID != "src-1" {
		t.Fatalf("expected referenced src-1 pre-included on page 1, got %+v", pull.Data.Sources)
	}
}

func TestInitialAllowRegistrationOption(t *testing.T) {
	store, err := OpenSyncStore(t.TempDir(), WithAdminUsername("owner"), WithInitialAllowRegistration(false))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	mux := NewSyncMux(store)

	info := store.GetPublicInfo()
	if info.AllowRegistration {
		t.Fatalf("expected AllowRegistration=false on first boot")
	}

	// Stranger cannot snipe first slot when -admin-user is set and registration is closed.
	blockedRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "blocked",
		AuthVerifier:             "hash",
		KdfSalt:                  "salt",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:backup",
		DeviceID:                 "dev-1",
	})
	if blockedRec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 when stranger registers with -allow-register=false and -admin-user=owner, got %d %s", blockedRec.Code, blockedRec.Body.String())
	}

	// Designated admin can still bootstrap, while subsequent strangers remain rejected.
	ownerRec := doReq(t, mux, "POST", "/api/v1/auth/register", "", RegisterRequest{
		Username:                 "owner",
		AuthVerifier:             "hash",
		KdfSalt:                  "salt",
		KdfParams:                KdfParams{Algo: "argon2id", M: 1024, T: 1, P: 1},
		EncryptedMasterKeyBackup: "enc:backup",
		DeviceID:                 "dev-owner",
	})
	if ownerRec.Code != http.StatusOK {
		t.Fatalf("expected designated admin registration to succeed, got %d %s", ownerRec.Code, ownerRec.Body.String())
	}
}
