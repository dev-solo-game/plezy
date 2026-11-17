package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
	var allSources []SyncSource
	var seq int64
	for {
		rec := doReq(t, mux, "GET", "/api/v1/sync/pull?limit=2&since_seq="+itoa64(seq), tok, nil)
		var pull PullResponse
		_ = json.Unmarshal(rec.Body.Bytes(), &pull)
		allSources = append(allSources, pull.Data.Sources...)
		allWorks = append(allWorks, pull.Data.Works...)
		allFiles = append(allFiles, pull.Data.Files...)
		seq = pull.NextSeq
		if !pull.HasMore {
			break
		}
	}

	if len(allSources) != 1 || allSources[0].SourceID != "uuid-A" || *allSources[0].QuarkCheckpoint != "0:8000" {
		t.Fatalf("unexpected merged source: %+v", allSources)
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
