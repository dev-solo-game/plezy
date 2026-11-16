package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	ErrUserExists       = errors.New("username already exists")
	ErrInvalidCreds     = errors.New("invalid username or password")
	ErrUnauthorized     = errors.New("unauthorized")
	ErrQrNotFound       = errors.New("qr session not found")
	ErrQrExpired        = errors.New("qr session expired")
	ErrInvalidInput     = errors.New("invalid input")
	ErrSourceNotFound   = errors.New("source not found")
)

const (
	tombstoneRetentionMs  int64 = 30 * 24 * 60 * 60 * 1000
	appliedOpRetentionMs  int64 = 7 * 24 * 60 * 60 * 1000
	qrSessionTTLMs        int64 = 180 * 1000
	defaultScanLeaseSec   int   = 60
	walCompactThreshold   int   = 200
)

type UserSyncState struct {
	NextSeq           int64                         `json:"next_seq"`
	MinRetainedSeq    int64                         `json:"min_retained_seq"`
	Sources           map[string]*SyncSource        `json:"sources"`
	CanonicalToSource map[string]string             `json:"canonical_to_source"`
	RemappedSources   map[string]string             `json:"remapped_sources"`
	RemappedFiles     map[string]string             `json:"remapped_files"`
	Works             map[string]*SyncWork          `json:"works"`
	Files             map[string]*SyncFile          `json:"files"`
	WorkPrefs         map[string]*SyncWorkPref      `json:"work_prefs"`
	WatchProgress     map[string]*SyncWatchProgress `json:"watch_progress"`
	AppliedOps        map[string]AppliedOp          `json:"applied_ops"`
}

func newUserSyncState() *UserSyncState {
	return &UserSyncState{
		Sources:           make(map[string]*SyncSource),
		CanonicalToSource: make(map[string]string),
		RemappedSources:   make(map[string]string),
		RemappedFiles:     make(map[string]string),
		Works:             make(map[string]*SyncWork),
		Files:             make(map[string]*SyncFile),
		WorkPrefs:         make(map[string]*SyncWorkPref),
		WatchProgress:     make(map[string]*SyncWatchProgress),
		AppliedOps:        make(map[string]AppliedOp),
	}
}

func (u *UserSyncState) allocSeq() int64 {
	u.NextSeq++
	return u.NextSeq
}

func (u *UserSyncState) resolveSourceID(id string) string {
	visited := map[string]bool{}
	cur := id
	for {
		if visited[cur] {
			return cur
		}
		visited[cur] = true
		next, ok := u.RemappedSources[cur]
		if !ok || next == "" || next == cur {
			return cur
		}
		cur = next
	}
}

func (u *UserSyncState) resolveFileID(id string) string {
	visited := map[string]bool{}
	cur := id
	for {
		if visited[cur] {
			return cur
		}
		visited[cur] = true
		next, ok := u.RemappedFiles[cur]
		if !ok || next == "" || next == cur {
			return cur
		}
		cur = next
	}
}

type PersistedSnapshot struct {
	Users        map[string]*UserRecord    `json:"users"`
	ByUsername   map[string]string         `json:"by_username"`
	Tokens       map[string]TokenEntry     `json:"tokens"`
	UserSyncData map[string]*UserSyncState `json:"user_sync_data"`
}

type TokenEntry struct {
	UserID    string `json:"user_id"`
	DeviceID  string `json:"device_id"`
	CreatedAt int64  `json:"created_at"`
}

type walRecord struct {
	Kind       string          `json:"kind"`
	NowMs      int64           `json:"now_ms"`
	User       *UserRecord     `json:"user,omitempty"`
	Token      string          `json:"token,omitempty"`
	TokenEntry *TokenEntry     `json:"token_entry,omitempty"`
	UserID     string          `json:"user_id,omitempty"`
	Settings   map[string]any  `json:"settings,omitempty"`
	Mutations  []PushMutation  `json:"mutations,omitempty"`
}

type SyncStore struct {
	mu           sync.RWMutex
	dataDir      string
	snapshotPath string
	walPath      string
	walFile      *os.File
	walCount     int

	users        map[string]*UserRecord
	byUsername   map[string]string
	tokens       map[string]TokenEntry
	qrSessions   map[string]*QrSession
	userSyncData map[string]*UserSyncState
}

func OpenSyncStore(dataDir string) (*SyncStore, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	s := &SyncStore{
		dataDir:      dataDir,
		snapshotPath: filepath.Join(dataDir, "sync.snapshot.json"),
		walPath:      filepath.Join(dataDir, "sync.wal.jsonl"),
		users:        make(map[string]*UserRecord),
		byUsername:   make(map[string]string),
		tokens:       make(map[string]TokenEntry),
		qrSessions:   make(map[string]*QrSession),
		userSyncData: make(map[string]*UserSyncState),
	}
	if err := s.loadSnapshot(); err != nil {
		return nil, err
	}
	if err := s.replayWAL(); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(s.walPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	s.walFile = f
	return s, nil
}

func (s *SyncStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.walFile != nil {
		_ = s.walFile.Sync()
		err := s.walFile.Close()
		s.walFile = nil
		return err
	}
	return nil
}

func (s *SyncStore) loadSnapshot() error {
	raw, err := os.ReadFile(s.snapshotPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var snap PersistedSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return err
	}
	if snap.Users != nil {
		s.users = snap.Users
	}
	if snap.ByUsername != nil {
		s.byUsername = snap.ByUsername
	}
	if snap.Tokens != nil {
		s.tokens = snap.Tokens
	}
	if snap.UserSyncData != nil {
		for _, u := range snap.UserSyncData {
			if u.Sources == nil {
				u.Sources = make(map[string]*SyncSource)
			}
			if u.CanonicalToSource == nil {
				u.CanonicalToSource = make(map[string]string)
			}
			if u.RemappedSources == nil {
				u.RemappedSources = make(map[string]string)
			}
			if u.RemappedFiles == nil {
				u.RemappedFiles = make(map[string]string)
			}
			if u.Works == nil {
				u.Works = make(map[string]*SyncWork)
			}
			if u.Files == nil {
				u.Files = make(map[string]*SyncFile)
			}
			if u.WorkPrefs == nil {
				u.WorkPrefs = make(map[string]*SyncWorkPref)
			}
			if u.WatchProgress == nil {
				u.WatchProgress = make(map[string]*SyncWatchProgress)
			}
			if u.AppliedOps == nil {
				u.AppliedOps = make(map[string]AppliedOp)
			}
		}
		s.userSyncData = snap.UserSyncData
	}
	return nil
}

func (s *SyncStore) replayWAL() error {
	f, err := os.Open(s.walPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var rec walRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			continue
		}
		s.walCount++
		switch rec.Kind {
		case "register":
			if rec.User != nil {
				s.users[rec.User.UserID] = rec.User
				s.byUsername[strings.ToLower(rec.User.Username)] = rec.User.UserID
				s.ensureUserState(rec.User.UserID)
			}
		case "token":
			if rec.Token != "" && rec.TokenEntry != nil {
				s.tokens[rec.Token] = *rec.TokenEntry
			}
		case "settings":
			if u, ok := s.users[rec.UserID]; ok && rec.Settings != nil {
				if u.Settings == nil {
					u.Settings = make(map[string]any)
				}
				for k, v := range rec.Settings {
					u.Settings[k] = v
				}
				u.UpdatedAt = rec.NowMs
			}
		case "push":
			_, _ = s.applyMutationsLocked(rec.UserID, rec.Mutations, rec.NowMs)
		case "gc":
			s.runGCLocked(rec.NowMs)
		}
	}
	return scanner.Err()
}

func (s *SyncStore) appendWAL(rec walRecord) error {
	if s.walFile == nil {
		return nil
	}
	line, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	if _, err := s.walFile.Write(append(line, '\n')); err != nil {
		return err
	}
	if err := s.walFile.Sync(); err != nil {
		return err
	}
	s.walCount++
	if s.walCount >= walCompactThreshold {
		return s.compactLocked()
	}
	return nil
}

func (s *SyncStore) compactLocked() error {
	snap := PersistedSnapshot{
		Users:        s.users,
		ByUsername:   s.byUsername,
		Tokens:       s.tokens,
		UserSyncData: s.userSyncData,
	}
	raw, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	tmp := s.snapshotPath + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.snapshotPath); err != nil {
		return err
	}
	if s.walFile != nil {
		_ = s.walFile.Close()
		s.walFile = nil
	}
	f, err := os.OpenFile(s.walPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	s.walFile = f
	s.walCount = 0
	return nil
}

func (s *SyncStore) ensureUserState(userID string) *UserSyncState {
	st, ok := s.userSyncData[userID]
	if !ok {
		st = newUserSyncState()
		s.userSyncData[userID] = st
	}
	return st
}

func randomHex(nBytes int) string {
	b := make([]byte, nBytes)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func hashAuthVerifier(salt, verifier string) string {
	h := sha256.Sum256([]byte(salt + ":" + verifier))
	return base64.StdEncoding.EncodeToString(h[:])
}

func nowMs() int64 {
	return time.Now().UnixMilli()
}

func (s *SyncStore) Register(req RegisterRequest) (AuthResponse, error) {
	username := strings.TrimSpace(req.Username)
	if username == "" || strings.TrimSpace(req.AuthVerifier) == "" || strings.TrimSpace(req.EncryptedMasterKeyBackup) == "" {
		return AuthResponse{}, ErrInvalidInput
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.byUsername[strings.ToLower(username)]; exists {
		return AuthResponse{}, ErrUserExists
	}

	ts := nowMs()
	userID := "usr_" + randomHex(12)
	authSalt := randomHex(16)
	settings := req.Settings
	if settings == nil {
		settings = map[string]any{}
	}
	user := &UserRecord{
		UserID:                   userID,
		Username:                 username,
		AuthSalt:                 authSalt,
		AuthHash:                 hashAuthVerifier(authSalt, req.AuthVerifier),
		KdfSalt:                  req.KdfSalt,
		KdfParams:                req.KdfParams,
		EncryptedMasterKeyBackup: req.EncryptedMasterKeyBackup,
		Settings:                 settings,
		CreatedAt:                ts,
		UpdatedAt:                ts,
	}
	token := "plezy_tok_" + randomHex(24)
	entry := TokenEntry{UserID: userID, DeviceID: req.DeviceID, CreatedAt: ts}

	s.users[userID] = user
	s.byUsername[strings.ToLower(username)] = userID
	s.tokens[token] = entry
	s.ensureUserState(userID)

	if err := s.appendWAL(walRecord{Kind: "register", NowMs: ts, User: user}); err != nil {
		return AuthResponse{}, err
	}
	if err := s.appendWAL(walRecord{Kind: "token", NowMs: ts, Token: token, TokenEntry: &entry}); err != nil {
		return AuthResponse{}, err
	}

	return AuthResponse{
		Code:                     0,
		UserID:                   user.UserID,
		Username:                 user.Username,
		AccessToken:              token,
		KdfSalt:                  user.KdfSalt,
		KdfParams:                user.KdfParams,
		EncryptedMasterKeyBackup: user.EncryptedMasterKeyBackup,
		Settings:                 user.Settings,
		ServerTimeMs:             ts,
	}, nil
}

func (s *SyncStore) Login(req LoginRequest) (AuthResponse, error) {
	username := strings.TrimSpace(req.Username)
	if username == "" || strings.TrimSpace(req.AuthVerifier) == "" {
		return AuthResponse{}, ErrInvalidCreds
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	userID, ok := s.byUsername[strings.ToLower(username)]
	if !ok {
		return AuthResponse{}, ErrInvalidCreds
	}
	user := s.users[userID]
	expected := hashAuthVerifier(user.AuthSalt, req.AuthVerifier)
	if subtle.ConstantTimeCompare([]byte(expected), []byte(user.AuthHash)) != 1 {
		return AuthResponse{}, ErrInvalidCreds
	}

	ts := nowMs()
	token := "plezy_tok_" + randomHex(24)
	entry := TokenEntry{UserID: userID, DeviceID: req.DeviceID, CreatedAt: ts}
	s.tokens[token] = entry
	if err := s.appendWAL(walRecord{Kind: "token", NowMs: ts, Token: token, TokenEntry: &entry}); err != nil {
		return AuthResponse{}, err
	}

	return AuthResponse{
		Code:                     0,
		UserID:                   user.UserID,
		Username:                 user.Username,
		AccessToken:              token,
		KdfSalt:                  user.KdfSalt,
		KdfParams:                user.KdfParams,
		EncryptedMasterKeyBackup: user.EncryptedMasterKeyBackup,
		Settings:                 user.Settings,
		ServerTimeMs:             ts,
	}, nil
}

func (s *SyncStore) LookupKdf(username string) (salt string, params KdfParams, exists bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	userID, ok := s.byUsername[strings.ToLower(strings.TrimSpace(username))]
	if !ok {
		return "", KdfParams{}, false
	}
	u := s.users[userID]
	return u.KdfSalt, u.KdfParams, true
}

func (s *SyncStore) Authenticate(token string) (*UserRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entry, ok := s.tokens[strings.TrimSpace(token)]
	if !ok {
		return nil, ErrUnauthorized
	}
	u, ok := s.users[entry.UserID]
	if !ok {
		return nil, ErrUnauthorized
	}
	return u, nil
}

func (s *SyncStore) UpdateUserSettings(userID string, updates map[string]any) (map[string]any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[userID]
	if !ok {
		return nil, ErrUnauthorized
	}
	if u.Settings == nil {
		u.Settings = map[string]any{}
	}
	for k, v := range updates {
		u.Settings[k] = v
	}
	ts := nowMs()
	u.UpdatedAt = ts
	if err := s.appendWAL(walRecord{Kind: "settings", NowMs: ts, UserID: userID, Settings: updates}); err != nil {
		return nil, err
	}
	return u.Settings, nil
}

func (s *SyncStore) CreateQrSession(req QrCreateRequest) (QrCreateResponse, error) {
	if strings.TrimSpace(req.TvPubKey) == "" {
		return QrCreateResponse{}, ErrInvalidInput
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	ts := nowMs()
	for id, sess := range s.qrSessions {
		if sess.ExpiresAtMs < ts {
			delete(s.qrSessions, id)
		}
	}
	sessionID := "qr_" + randomHex(16)
	sess := &QrSession{
		SessionID:   sessionID,
		TvPubKey:    req.TvPubKey,
		DeviceName:  req.DeviceName,
		Status:      "pending",
		ExpiresAtMs: ts + qrSessionTTLMs,
	}
	s.qrSessions[sessionID] = sess
	return QrCreateResponse{
		Code:        0,
		SessionID:   sessionID,
		ExpiresAtMs: sess.ExpiresAtMs,
	}, nil
}

func (s *SyncStore) ConfirmQrSession(user *UserRecord, req QrConfirmRequest) error {
	if strings.TrimSpace(req.SessionID) == "" || strings.TrimSpace(req.SealedMasterKey) == "" {
		return ErrInvalidInput
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	sess, ok := s.qrSessions[req.SessionID]
	if !ok {
		return ErrQrNotFound
	}
	ts := nowMs()
	if sess.ExpiresAtMs < ts {
		delete(s.qrSessions, req.SessionID)
		return ErrQrExpired
	}

	tvToken := "plezy_tok_" + randomHex(24)
	entry := TokenEntry{UserID: user.UserID, DeviceID: req.DeviceID, CreatedAt: ts}
	s.tokens[tvToken] = entry
	if err := s.appendWAL(walRecord{Kind: "token", NowMs: ts, Token: tvToken, TokenEntry: &entry}); err != nil {
		return err
	}

	sess.Status = "confirmed"
	sess.UserID = user.UserID
	sess.Username = user.Username
	sess.AccessToken = tvToken
	sess.SealedMasterKey = req.SealedMasterKey
	return nil
}

func (s *SyncStore) PollQrSession(sessionID string) (QrPollResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sess, ok := s.qrSessions[strings.TrimSpace(sessionID)]
	if !ok {
		return QrPollResponse{}, ErrQrNotFound
	}
	ts := nowMs()
	if sess.ExpiresAtMs < ts && sess.Status != "confirmed" {
		return QrPollResponse{Code: 0, Status: "expired", ExpiresAtMs: sess.ExpiresAtMs, ServerTimeMs: ts}, nil
	}
	resp := QrPollResponse{
		Code:         0,
		Status:       sess.Status,
		ExpiresAtMs:  sess.ExpiresAtMs,
		ServerTimeMs: ts,
	}
	if sess.Status == "confirmed" {
		resp.UserID = sess.UserID
		resp.Username = sess.Username
		resp.AccessToken = sess.AccessToken
		resp.SealedMasterKey = sess.SealedMasterKey
		if u, exists := s.users[sess.UserID]; exists {
			resp.Settings = u.Settings
		}
	}
	return resp, nil
}

func (s *SyncStore) AcquireLease(userID string, req LeaseRequest) (LeaseResponse, error) {
	if strings.TrimSpace(req.SourceID) == "" || strings.TrimSpace(req.DeviceID) == "" {
		return LeaseResponse{}, ErrInvalidInput
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	st := s.ensureUserState(userID)
	resolvedID := st.resolveSourceID(req.SourceID)
	src, ok := st.sourcesSliceFind(resolvedID)
	if !ok || src.IsDeleted {
		return LeaseResponse{}, ErrSourceNotFound
	}

	ts := nowMs()
	ttlSec := req.TtlSec
	if ttlSec <= 0 {
		ttlSec = defaultScanLeaseSec
	}
	ttlMs := int64(ttlSec) * 1000

	if src.ScanLeaseOwner != nil && *src.ScanLeaseOwner != "" && *src.ScanLeaseOwner != req.DeviceID && src.ScanLeaseUntil > ts {
		return LeaseResponse{
			Code:           0,
			Acquired:       false,
			HolderDeviceID: *src.ScanLeaseOwner,
			ExpiresAtMs:    src.ScanLeaseUntil,
		}, nil
	}

	owner := req.DeviceID
	until := ts + ttlMs
	src.ScanLeaseOwner = &owner
	src.ScanLeaseUntil = until
	return LeaseResponse{
		Code:           0,
		Acquired:       true,
		HolderDeviceID: owner,
		ExpiresAtMs:    until,
	}, nil
}

func (u *UserSyncState) sourcesSliceFind(id string) (*SyncSource, bool) {
	src, ok := u.Sources[id]
	return src, ok
}

func (s *SyncStore) Push(userID string, req PushRequest) (PushResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	ts := nowMs()
	accepted, remaps := s.applyMutationsLocked(userID, req.Mutations, ts)
	if err := s.appendWAL(walRecord{Kind: "push", NowMs: ts, UserID: userID, Mutations: req.Mutations}); err != nil {
		return PushResponse{}, err
	}
	return PushResponse{
		Code:            0,
		ServerTimeMs:    ts,
		AcceptedOpIDs:   accepted,
		RemappedSources: remaps,
	}, nil
}

func (s *SyncStore) applyMutationsLocked(userID string, mutations []PushMutation, ts int64) ([]string, map[string]string) {
	u := s.ensureUserState(userID)
	accepted := make([]string, 0, len(mutations))
	remaps := make(map[string]string)

	for _, mut := range mutations {
		if mut.OpID == "" {
			continue
		}
		if _, dup := u.AppliedOps[mut.OpID]; dup {
			accepted = append(accepted, mut.OpID)
			continue
		}

		var seq int64
		switch mut.EntityType {
		case "source":
			var src SyncSource
			if err := json.Unmarshal(mut.Payload, &src); err != nil {
				continue
			}
			seq = s.applySourceLocked(u, &src, remaps)
		case "work":
			var work SyncWork
			if err := json.Unmarshal(mut.Payload, &work); err != nil {
				continue
			}
			seq = s.applyWorkLocked(u, &work)
		case "file":
			var file SyncFile
			if err := json.Unmarshal(mut.Payload, &file); err != nil {
				continue
			}
			seq = s.applyFileLocked(u, &file)
		case "work_pref":
			var pref SyncWorkPref
			if err := json.Unmarshal(mut.Payload, &pref); err != nil {
				continue
			}
			seq = s.applyWorkPrefLocked(u, &pref)
		case "watch_progress":
			var prog SyncWatchProgress
			if err := json.Unmarshal(mut.Payload, &prog); err != nil {
				continue
			}
			seq = s.applyWatchProgressLocked(u, &prog)
		default:
			continue
		}

		u.AppliedOps[mut.OpID] = AppliedOp{
			OpID:      mut.OpID,
			ServerSeq: seq,
			CreatedAt: ts,
		}
		accepted = append(accepted, mut.OpID)
	}

	if len(remaps) == 0 {
		return accepted, nil
	}
	return accepted, remaps
}

func (s *SyncStore) applySourceLocked(u *UserSyncState, incoming *SyncSource, batchRemaps map[string]string) int64 {
	if incoming.IncludePaths == nil {
		incoming.IncludePaths = []string{}
	}
	if incoming.ExcludePaths == nil {
		incoming.ExcludePaths = []string{}
	}
	if incoming.ConfigJSON == nil {
		incoming.ConfigJSON = map[string]any{}
	}

	originalID := incoming.SourceID
	resolved := u.resolveSourceID(incoming.SourceID)
	if resolved != incoming.SourceID {
		incoming.SourceID = resolved
		if originalID != resolved {
			batchRemaps[originalID] = resolved
		}
	}

	// Deduplicate across devices when two devices offline-created the same mount with different UUIDs.
	if !incoming.IsDeleted && incoming.CanonicalKey != "" {
		if winnerID, ok := u.CanonicalToSource[incoming.CanonicalKey]; ok && winnerID != incoming.SourceID {
			if winner, exists := u.Sources[winnerID]; exists && !winner.IsDeleted {
				u.RemappedSources[originalID] = winnerID
				u.RemappedSources[incoming.SourceID] = winnerID
				batchRemaps[originalID] = winnerID
				batchRemaps[incoming.SourceID] = winnerID
				incoming.SourceID = winnerID
			}
		}
	}

	existing, exists := u.Sources[incoming.SourceID]
	seq := u.allocSeq()
	if !exists {
		copySrc := *incoming
		copySrc.ServerSeq = seq
		u.Sources[copySrc.SourceID] = &copySrc
		if !copySrc.IsDeleted && copySrc.CanonicalKey != "" {
			u.CanonicalToSource[copySrc.CanonicalKey] = copySrc.SourceID
		}
		return seq
	}

	if incoming.IsDeleted && !existing.IsDeleted {
		if incoming.ClientUpdatedAt >= existing.ClientUpdatedAt {
			existing.IsDeleted = true
			existing.ClientUpdatedAt = incoming.ClientUpdatedAt
			existing.ServerSeq = seq
			if winner, ok := u.CanonicalToSource[existing.CanonicalKey]; ok && winner == existing.SourceID {
				delete(u.CanonicalToSource, existing.CanonicalKey)
			}
			// Soft-delete files under this deleted source so pulling devices stay clean.
			for _, f := range u.Files {
				if f.SourceID == existing.SourceID && !f.IsDeleted {
					f.IsDeleted = true
					f.ClientUpdatedAt = incoming.ClientUpdatedAt
					f.ServerSeq = u.allocSeq()
				}
			}
		}
		return seq
	}

	// Update / merge non-deleted (or resurrected) source.
	existing.IsDeleted = incoming.IsDeleted
	existing.QuarkCheckpoint = mergeQuarkCheckpoint(existing.QuarkCheckpoint, incoming.QuarkCheckpoint)
	if incoming.EncryptedAuth != "" && (incoming.ForceAuthOverride || incoming.AuthUpdatedAt >= existing.AuthUpdatedAt || existing.EncryptedAuth == "") {
		existing.EncryptedAuth = incoming.EncryptedAuth
		if incoming.AuthUpdatedAt > existing.AuthUpdatedAt {
			existing.AuthUpdatedAt = incoming.AuthUpdatedAt
		}
	}
	if incoming.ClientUpdatedAt >= existing.ClientUpdatedAt {
		existing.Name = incoming.Name
		existing.Protocol = incoming.Protocol
		existing.IsLanOnly = incoming.IsLanOnly
		existing.PrimaryURL = incoming.PrimaryURL
		if incoming.FallbackURL != nil {
			existing.FallbackURL = incoming.FallbackURL
		}
		if len(incoming.ConfigJSON) > 0 {
			existing.ConfigJSON = incoming.ConfigJSON
		}
		existing.IncludePaths = incoming.IncludePaths
		existing.ExcludePaths = incoming.ExcludePaths
		if incoming.CanonicalKey != "" {
			existing.CanonicalKey = incoming.CanonicalKey
		}
		existing.ClientUpdatedAt = incoming.ClientUpdatedAt
	}
	existing.ServerSeq = seq
	if !existing.IsDeleted && existing.CanonicalKey != "" {
		u.CanonicalToSource[existing.CanonicalKey] = existing.SourceID
	}
	return seq
}

func shouldOverrideEntity(remoteDeleted, localDeleted bool, remoteMatch, localMatch int, remoteUpdated, localUpdated int64, explicitUnlock bool) bool {
	if remoteDeleted != localDeleted {
		return remoteUpdated >= localUpdated
	}
	if explicitUnlock {
		return remoteUpdated >= localUpdated
	}
	if remoteMatch != localMatch {
		return remoteMatch > localMatch
	}
	return remoteUpdated >= localUpdated
}

func (s *SyncStore) applyWorkLocked(u *UserSyncState, incoming *SyncWork) int64 {
	if incoming.MetadataJSON == nil {
		incoming.MetadataJSON = map[string]any{}
	}
	existing, exists := u.Works[incoming.WorkKey]
	if exists && !shouldOverrideEntity(
		incoming.IsDeleted,
		existing.IsDeleted,
		incoming.MatchStatus,
		existing.MatchStatus,
		incoming.ClientUpdatedAt,
		existing.ClientUpdatedAt,
		incoming.ExplicitUnlock,
	) {
		return existing.ServerSeq
	}
	seq := u.allocSeq()
	copyWork := *incoming
	copyWork.ExplicitUnlock = false
	copyWork.ServerSeq = seq
	u.Works[copyWork.WorkKey] = &copyWork
	return seq
}

func generateFileID(sourceID, relativePath string) string {
	sum := sha256.Sum256([]byte(sourceID + ":" + relativePath))
	return hex.EncodeToString(sum[:])[:32]
}

func (s *SyncStore) applyFileLocked(u *UserSyncState, incoming *SyncFile) int64 {
	if incoming.MediaSpecJSON == nil {
		incoming.MediaSpecJSON = map[string]any{}
	}
	resolvedSrc := u.resolveSourceID(incoming.SourceID)
	if resolvedSrc != incoming.SourceID {
		oldFileID := incoming.FileID
		newFileID := generateFileID(resolvedSrc, incoming.RelativePath)
		incoming.SourceID = resolvedSrc
		incoming.FileID = newFileID
		if oldFileID != "" && oldFileID != newFileID {
			u.RemappedFiles[oldFileID] = newFileID
		}
	}
	if incoming.OwnerFileID != nil && *incoming.OwnerFileID != "" {
		resolvedOwner := u.resolveFileID(*incoming.OwnerFileID)
		incoming.OwnerFileID = &resolvedOwner
	}

	existing, exists := u.Files[incoming.FileID]
	if exists && !shouldOverrideEntity(
		incoming.IsDeleted,
		existing.IsDeleted,
		incoming.MatchStatus,
		existing.MatchStatus,
		incoming.ClientUpdatedAt,
		existing.ClientUpdatedAt,
		incoming.ExplicitUnlock,
	) {
		return existing.ServerSeq
	}
	seq := u.allocSeq()
	copyFile := *incoming
	copyFile.ExplicitUnlock = false
	copyFile.ServerSeq = seq
	u.Files[copyFile.FileID] = &copyFile
	return seq
}

func (s *SyncStore) applyWorkPrefLocked(u *UserSyncState, incoming *SyncWorkPref) int64 {
	existing, exists := u.WorkPrefs[incoming.WorkKey]
	if exists && incoming.ClientUpdatedAt < existing.ClientUpdatedAt {
		return existing.ServerSeq
	}
	seq := u.allocSeq()
	copyPref := *incoming
	copyPref.ServerSeq = seq
	u.WorkPrefs[copyPref.WorkKey] = &copyPref
	return seq
}

func (s *SyncStore) applyWatchProgressLocked(u *UserSyncState, incoming *SyncWatchProgress) int64 {
	if incoming.EpisodeExtJSON == nil {
		incoming.EpisodeExtJSON = map[string]any{}
	}
	existing, exists := u.WatchProgress[incoming.ProgressKey]
	if exists && incoming.ClientUpdatedAt < existing.ClientUpdatedAt {
		return existing.ServerSeq
	}
	seq := u.allocSeq()
	copyProg := *incoming
	copyProg.ServerSeq = seq
	u.WatchProgress[copyProg.ProgressKey] = &copyProg
	return seq
}

func mergeQuarkCheckpoint(local, remote *string) *string {
	var cleanLocal, cleanRemote string
	if local != nil {
		cleanLocal = strings.TrimSpace(*local)
	}
	if remote != nil {
		cleanRemote = strings.TrimSpace(*remote)
	}
	if cleanLocal == "" {
		if cleanRemote == "" {
			return nil
		}
		return &cleanRemote
	}
	if cleanRemote == "" {
		return &cleanLocal
	}
	localSep := strings.IndexByte(cleanLocal, ':')
	remoteSep := strings.IndexByte(cleanRemote, ':')
	if localSep <= 0 || remoteSep <= 0 {
		return &cleanRemote
	}
	localRoot := cleanLocal[:localSep]
	remoteRoot := cleanRemote[:remoteSep]
	if localRoot != remoteRoot {
		return &cleanRemote
	}
	localW, errL := strconv.ParseInt(cleanLocal[localSep+1:], 10, 64)
	remoteW, errR := strconv.ParseInt(cleanRemote[remoteSep+1:], 10, 64)
	if errL != nil {
		return &cleanRemote
	}
	if errR != nil {
		return &cleanLocal
	}
	if localW >= remoteW {
		return &cleanLocal
	}
	return &cleanRemote
}

type deltaEnvelope struct {
	seq  int64
	kind string
	item any
}

func (s *SyncStore) Pull(user *UserRecord, sinceSeq int64, limit int) PullResponse {
	if limit <= 0 {
		limit = 500
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	ts := nowMs()
	u := s.userSyncData[user.UserID]
	if u == nil {
		return PullResponse{
			Code:         0,
			ServerTimeMs: ts,
			UserSettings: user.Settings,
			Data: PullData{
				Sources:       []SyncSource{},
				Works:         []SyncWork{},
				Files:         []SyncFile{},
				WorkPrefs:     []SyncWorkPref{},
				WatchProgress: []SyncWatchProgress{},
			},
		}
	}

	if sinceSeq > 0 && sinceSeq < u.MinRetainedSeq {
		return PullResponse{
			Code:          0,
			ServerTimeMs:  ts,
			CurrentMaxSeq: u.NextSeq,
			NextSeq:       0,
			ResetRequired: true,
			UserSettings:  user.Settings,
			Data: PullData{
				Sources:       []SyncSource{},
				Works:         []SyncWork{},
				Files:         []SyncFile{},
				WorkPrefs:     []SyncWorkPref{},
				WatchProgress: []SyncWatchProgress{},
			},
		}
	}

	deltas := make([]deltaEnvelope, 0)
	for _, src := range u.Sources {
		if src.ServerSeq > sinceSeq {
			deltas = append(deltas, deltaEnvelope{seq: src.ServerSeq, kind: "source", item: *src})
		}
	}
	for _, w := range u.Works {
		if w.ServerSeq > sinceSeq {
			deltas = append(deltas, deltaEnvelope{seq: w.ServerSeq, kind: "work", item: *w})
		}
	}
	for _, f := range u.Files {
		if f.ServerSeq > sinceSeq {
			deltas = append(deltas, deltaEnvelope{seq: f.ServerSeq, kind: "file", item: *f})
		}
	}
	for _, p := range u.WorkPrefs {
		if p.ServerSeq > sinceSeq {
			deltas = append(deltas, deltaEnvelope{seq: p.ServerSeq, kind: "work_pref", item: *p})
		}
	}
	for _, g := range u.WatchProgress {
		if g.ServerSeq > sinceSeq {
			deltas = append(deltas, deltaEnvelope{seq: g.ServerSeq, kind: "watch_progress", item: *g})
		}
	}

	sort.Slice(deltas, func(i, j int) bool {
		return deltas[i].seq < deltas[j].seq
	})

	hasMore := len(deltas) > limit
	if hasMore {
		deltas = deltas[:limit]
	}

	nextSeq := sinceSeq
	if len(deltas) > 0 {
		nextSeq = deltas[len(deltas)-1].seq
	}

	out := PullData{
		Sources:       []SyncSource{},
		Works:         []SyncWork{},
		Files:         []SyncFile{},
		WorkPrefs:     []SyncWorkPref{},
		WatchProgress: []SyncWatchProgress{},
	}
	for _, d := range deltas {
		switch d.kind {
		case "source":
			out.Sources = append(out.Sources, d.item.(SyncSource))
		case "work":
			out.Works = append(out.Works, d.item.(SyncWork))
		case "file":
			out.Files = append(out.Files, d.item.(SyncFile))
		case "work_pref":
			out.WorkPrefs = append(out.WorkPrefs, d.item.(SyncWorkPref))
		case "watch_progress":
			out.WatchProgress = append(out.WatchProgress, d.item.(SyncWatchProgress))
		}
	}

	return PullResponse{
		Code:          0,
		ServerTimeMs:  ts,
		CurrentMaxSeq: u.NextSeq,
		NextSeq:       nextSeq,
		HasMore:       hasMore,
		ResetRequired: false,
		UserSettings:  user.Settings,
		Data:          out,
	}
}

func (s *SyncStore) RunGC(atMs int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.runGCLocked(atMs)
	return s.appendWAL(walRecord{Kind: "gc", NowMs: atMs})
}

func (s *SyncStore) runGCLocked(atMs int64) {
	tombstoneCutoff := atMs - tombstoneRetentionMs
	opCutoff := atMs - appliedOpRetentionMs

	for _, u := range s.userSyncData {
		maxPurgedSeq := u.MinRetainedSeq
		for id, src := range u.Sources {
			if src.IsDeleted && src.ClientUpdatedAt <= tombstoneCutoff {
				if src.ServerSeq > maxPurgedSeq {
					maxPurgedSeq = src.ServerSeq
				}
				delete(u.Sources, id)
			}
		}
		for key, w := range u.Works {
			if w.IsDeleted && w.ClientUpdatedAt <= tombstoneCutoff {
				if w.ServerSeq > maxPurgedSeq {
					maxPurgedSeq = w.ServerSeq
				}
				delete(u.Works, key)
			}
		}
		for id, f := range u.Files {
			if f.IsDeleted && f.ClientUpdatedAt <= tombstoneCutoff {
				if f.ServerSeq > maxPurgedSeq {
					maxPurgedSeq = f.ServerSeq
				}
				delete(u.Files, id)
			}
		}
		for opID, op := range u.AppliedOps {
			if op.CreatedAt <= opCutoff {
				delete(u.AppliedOps, opID)
			}
		}
		u.MinRetainedSeq = maxPurgedSeq
	}
}

func (s *SyncStore) ValidateUsernameCheck(username string) error {
	if strings.TrimSpace(username) == "" {
		return fmt.Errorf("%w: username required", ErrInvalidInput)
	}
	return nil
}
