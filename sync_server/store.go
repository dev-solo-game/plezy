package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrUserExists         = errors.New("username already exists")
	ErrInvalidCreds       = errors.New("invalid username or password")
	ErrUnauthorized       = errors.New("unauthorized")
	ErrForbidden          = errors.New("forbidden")
	ErrRegistrationClosed = errors.New("registration is disabled by administrator")
	ErrUserDisabled       = errors.New("account is disabled")
	ErrQuotaExceeded      = errors.New("sync storage quota exceeded")
	ErrQrNotFound         = errors.New("qr session not found")
	ErrQrExpired          = errors.New("qr session expired")
	ErrInvalidInput       = errors.New("invalid input")
	ErrSourceNotFound     = errors.New("source not found")
	ErrUserNotFound       = errors.New("user not found")
)

const (
	tombstoneRetentionMs int64 = 30 * 24 * 60 * 60 * 1000
	appliedOpRetentionMs int64 = 7 * 24 * 60 * 60 * 1000
	qrSessionTTLMs       int64 = 180 * 1000
	defaultScanLeaseSec  int   = 60
)

type StoreOption func(*SyncStore)

// WithAdminUsername designates an initial administrator username; if omitted,
// the first registered account automatically receives admin privileges.
func WithAdminUsername(username string) StoreOption {
	return func(s *SyncStore) {
		s.adminUsername = strings.TrimSpace(username)
	}
}

// WithInitialAllowRegistration overrides the stored allow_registration flag when
// opening the store, letting self-hosters lock public registration from first boot.
func WithInitialAllowRegistration(allow bool) StoreOption {
	return func(s *SyncStore) {
		v := allow
		s.initialAllowRegister = &v
	}
}

// WithMetadataDefaults overrides server-level scraper and public metadata
// defaults on boot when provided via CLI flags or environment variables.
func WithMetadataDefaults(
	tmdbApiKey string,
	tmdbApiBase string,
	tmdbImageBase string,
	metadataProxy string,
	bangumiEnabled *bool,
	allowPublicMetadata *bool,
) StoreOption {
	return func(s *SyncStore) {
		if v := strings.TrimSpace(tmdbApiKey); v != "" {
			s.initTmdbApiKey = &v
		}
		if v := strings.TrimSpace(tmdbApiBase); v != "" {
			s.initTmdbApiBase = &v
		}
		if v := strings.TrimSpace(tmdbImageBase); v != "" {
			s.initTmdbImageBase = &v
		}
		if v := strings.TrimSpace(metadataProxy); v != "" {
			s.initMetadataProxy = &v
		}
		s.initBangumiEnabled = bangumiEnabled
		s.initAllowPublicMeta = allowPublicMetadata
	}
}

// WithBangumiBase overrides the upstream Bangumi API base URL (used for tests
// or self-hosted mirrors).
func WithBangumiBase(base string) StoreOption {
	return func(s *SyncStore) {
		if v := strings.TrimSpace(base); v != "" {
			s.initBangumiBase = &v
		}
	}
}

type SyncStore struct {
	mu                   sync.Mutex
	db                   *sql.DB
	dbPath               string
	dataDir              string
	adminUsername        string
	initialAllowRegister *bool
	initTmdbApiKey       *string
	initTmdbApiBase      *string
	initTmdbImageBase    *string
	initMetadataProxy    *string
	initBangumiEnabled   *bool
	initAllowPublicMeta  *bool
	initBangumiBase      *string
	qrSessions           map[string]*QrSession
	metaFlight           *sfGroup
	metaHTTPMu           sync.Mutex
	metaHTTPClients      map[string]*http.Client
	metaNow              func() int64
}

func OpenSyncStore(dataDir string, opts ...StoreOption) (*SyncStore, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	dbPath := filepath.Join(dataDir, "sync.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)

	s := &SyncStore{
		db:              db,
		dbPath:          dbPath,
		dataDir:         dataDir,
		qrSessions:      make(map[string]*QrSession),
		metaFlight:      &sfGroup{},
		metaHTTPClients: make(map[string]*http.Client),
	}
	for _, opt := range opts {
		if opt != nil {
			opt(s)
		}
	}

	if err := s.initSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := s.migrateLegacyIfNeeded(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *SyncStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		err := s.db.Close()
		s.db = nil
		return err
	}
	return nil
}

func (s *SyncStore) initSchema() error {
	pragmas := []string{
		`PRAGMA journal_mode = WAL`,
		`PRAGMA busy_timeout = 5000`,
		`PRAGMA synchronous = NORMAL`,
		`PRAGMA foreign_keys = ON`,
	}
	for _, p := range pragmas {
		if _, err := s.db.Exec(p); err != nil {
			return fmt.Errorf("exec %s: %w", p, err)
		}
	}

	stmts := []string{
		`CREATE TABLE IF NOT EXISTS server_config (
			key   TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS users (
			user_id                     TEXT PRIMARY KEY,
			username                    TEXT NOT NULL,
			username_lower              TEXT NOT NULL UNIQUE,
			auth_salt                   TEXT NOT NULL,
			auth_hash                   TEXT NOT NULL,
			kdf_salt                    TEXT NOT NULL,
			kdf_params_json             TEXT NOT NULL,
			encrypted_master_key_backup TEXT NOT NULL,
			settings_json               TEXT NOT NULL DEFAULT '{}',
			is_admin                    INTEGER NOT NULL DEFAULT 0,
			is_disabled                 INTEGER NOT NULL DEFAULT 0,
			next_seq                    INTEGER NOT NULL DEFAULT 0,
			min_retained_seq            INTEGER NOT NULL DEFAULT 0,
			created_at                  INTEGER NOT NULL,
			updated_at                  INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS tokens (
			token_id     TEXT PRIMARY KEY,
			token        TEXT NOT NULL UNIQUE,
			user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			device_id    TEXT NOT NULL,
			device_name  TEXT NOT NULL DEFAULT '',
			platform     TEXT NOT NULL DEFAULT '',
			created_at   INTEGER NOT NULL,
			last_seen_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_tokens_user ON tokens(user_id)`,
		`CREATE TABLE IF NOT EXISTS sync_sources (
			user_id            TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			source_id          TEXT NOT NULL,
			canonical_key      TEXT NOT NULL DEFAULT '',
			name               TEXT NOT NULL DEFAULT '',
			protocol           TEXT NOT NULL DEFAULT '',
			is_lan_only        INTEGER NOT NULL DEFAULT 0,
			primary_url        TEXT NOT NULL DEFAULT '',
			fallback_url       TEXT,
			config_json        TEXT NOT NULL DEFAULT '{}',
			include_paths_json TEXT NOT NULL DEFAULT '[]',
			exclude_paths_json TEXT NOT NULL DEFAULT '[]',
			encrypted_auth     TEXT NOT NULL DEFAULT '',
			auth_updated_at    INTEGER NOT NULL DEFAULT 0,
			quark_checkpoint   TEXT,
			scan_finished_at   INTEGER NOT NULL DEFAULT 0,
			scan_lease_owner   TEXT,
			scan_lease_until   INTEGER NOT NULL DEFAULT 0,
			client_updated_at  INTEGER NOT NULL DEFAULT 0,
			is_deleted         INTEGER NOT NULL DEFAULT 0,
			server_seq         INTEGER NOT NULL,
			PRIMARY KEY (user_id, source_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_sources_seq ON sync_sources(user_id, server_seq)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_sources_canonical ON sync_sources(user_id, canonical_key)`,
		`CREATE TABLE IF NOT EXISTS remapped_sources (
			user_id       TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			old_source_id TEXT NOT NULL,
			new_source_id TEXT NOT NULL,
			PRIMARY KEY (user_id, old_source_id)
		)`,
		`CREATE TABLE IF NOT EXISTS remapped_files (
			user_id     TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			old_file_id TEXT NOT NULL,
			new_file_id TEXT NOT NULL,
			PRIMARY KEY (user_id, old_file_id)
		)`,
		`CREATE TABLE IF NOT EXISTS sync_works (
			user_id           TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			work_key          TEXT NOT NULL,
			kind              TEXT NOT NULL,
			library_type      TEXT NOT NULL,
			provider          TEXT,
			external_id       TEXT,
			match_status      INTEGER NOT NULL DEFAULT 1,
			metadata_json     TEXT NOT NULL DEFAULT '{}',
			client_updated_at INTEGER NOT NULL DEFAULT 0,
			is_deleted        INTEGER NOT NULL DEFAULT 0,
			server_seq        INTEGER NOT NULL,
			PRIMARY KEY (user_id, work_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_works_seq ON sync_works(user_id, server_seq)`,
		`CREATE TABLE IF NOT EXISTS sync_files (
			user_id           TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			file_id           TEXT NOT NULL,
			source_id         TEXT NOT NULL,
			relative_path     TEXT NOT NULL,
			remote_id         TEXT,
			role              TEXT NOT NULL DEFAULT 'video',
			owner_file_id     TEXT,
			language          TEXT,
			file_name         TEXT NOT NULL DEFAULT '',
			file_size         INTEGER NOT NULL DEFAULT 0,
			file_mtime        INTEGER NOT NULL DEFAULT 0,
			file_created_at   INTEGER NOT NULL DEFAULT 0,
			work_key          TEXT,
			season_num        INTEGER NOT NULL DEFAULT -1,
			episode_num       INTEGER NOT NULL DEFAULT -1,
			episode_end_num   INTEGER,
			match_status      INTEGER NOT NULL DEFAULT 1,
			version_label     TEXT,
			parsed_json       TEXT,
			media_spec_json   TEXT NOT NULL DEFAULT '{}',
			client_updated_at INTEGER NOT NULL DEFAULT 0,
			is_deleted        INTEGER NOT NULL DEFAULT 0,
			server_seq        INTEGER NOT NULL,
			PRIMARY KEY (user_id, file_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_files_seq ON sync_files(user_id, server_seq)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_files_source ON sync_files(user_id, source_id)`,
		`CREATE TABLE IF NOT EXISTS sync_work_prefs (
			user_id              TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			work_key             TEXT NOT NULL,
			intro_enabled        INTEGER NOT NULL DEFAULT 0,
			intro_start_ms       INTEGER NOT NULL DEFAULT 0,
			intro_end_ms         INTEGER NOT NULL DEFAULT 0,
			credits_enabled      INTEGER NOT NULL DEFAULT 0,
			credits_from_end_ms  INTEGER NOT NULL DEFAULT 0,
			keep_easter_egg_ms   INTEGER NOT NULL DEFAULT 0,
			preferred_audio_lang TEXT,
			preferred_sub_lang   TEXT,
			playback_speed       REAL NOT NULL DEFAULT 1.0,
			danmaku_offset_ms    INTEGER NOT NULL DEFAULT 0,
			is_favorite          INTEGER NOT NULL DEFAULT 0,
			hidden_from_continue INTEGER NOT NULL DEFAULT 0,
			client_updated_at    INTEGER NOT NULL DEFAULT 0,
			server_seq           INTEGER NOT NULL,
			PRIMARY KEY (user_id, work_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_work_prefs_seq ON sync_work_prefs(user_id, server_seq)`,
		`CREATE TABLE IF NOT EXISTS sync_watch_progress (
			user_id           TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			progress_key      TEXT NOT NULL,
			work_key          TEXT NOT NULL,
			season_num        INTEGER NOT NULL DEFAULT -1,
			episode_num       INTEGER NOT NULL DEFAULT -1,
			last_file_id      TEXT,
			position_ms       INTEGER NOT NULL DEFAULT 0,
			duration_ms       INTEGER NOT NULL DEFAULT 0,
			watched           INTEGER NOT NULL DEFAULT 0,
			play_count        INTEGER NOT NULL DEFAULT 0,
			last_played_at    INTEGER,
			episode_ext_json  TEXT NOT NULL DEFAULT '{}',
			client_updated_at INTEGER NOT NULL DEFAULT 0,
			server_seq        INTEGER NOT NULL,
			PRIMARY KEY (user_id, progress_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_progress_seq ON sync_watch_progress(user_id, server_seq)`,
		`CREATE TABLE IF NOT EXISTS sync_lists (
			user_id              TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			list_key             TEXT NOT NULL,
			kind                 TEXT NOT NULL,
			title                TEXT NOT NULL,
			summary              TEXT,
			poster_path          TEXT,
			tmdb_id              TEXT,
			item_work_keys_json  TEXT NOT NULL DEFAULT '[]',
			client_updated_at    INTEGER NOT NULL DEFAULT 0,
			is_deleted           INTEGER NOT NULL DEFAULT 0,
			server_seq           INTEGER NOT NULL,
			PRIMARY KEY (user_id, list_key)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sync_lists_seq ON sync_lists(user_id, server_seq)`,
		`CREATE TABLE IF NOT EXISTS applied_ops (
			user_id    TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
			op_id      TEXT NOT NULL,
			server_seq INTEGER NOT NULL,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (user_id, op_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_applied_ops_created ON applied_ops(created_at)`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('allow_registration', 'true')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('max_entities_per_user', '0')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('tmdb_api_key', '')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('tmdb_api_base', 'https://api.tmdb.org/3')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('tmdb_image_base', 'https://image.tmdb.org/t/p')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('metadata_proxy', '')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('bangumi_enabled', 'true')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('allow_public_metadata', 'true')`,
		`INSERT OR IGNORE INTO server_config(key, value) VALUES ('bangumi_api_base', 'https://api.bgm.tv')`,
		`CREATE TABLE IF NOT EXISTS meta_works_cache (
			provider     TEXT NOT NULL,
			kind         TEXT NOT NULL,
			external_id  TEXT NOT NULL,
			lang         TEXT NOT NULL,
			payload_json TEXT NOT NULL,
			status       TEXT NOT NULL DEFAULT '',
			release_date TEXT NOT NULL DEFAULT '',
			fetched_at   INTEGER NOT NULL,
			expires_at   INTEGER NOT NULL,
			PRIMARY KEY (provider, kind, external_id, lang)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meta_works_expires ON meta_works_cache(expires_at)`,
		`CREATE TABLE IF NOT EXISTS meta_seasons_cache (
			provider      TEXT NOT NULL,
			external_id   TEXT NOT NULL,
			season_number INTEGER NOT NULL,
			lang          TEXT NOT NULL,
			payload_json  TEXT NOT NULL,
			fetched_at    INTEGER NOT NULL,
			expires_at    INTEGER NOT NULL,
			PRIMARY KEY (provider, external_id, season_number, lang)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meta_seasons_expires ON meta_seasons_cache(expires_at)`,
		`CREATE TABLE IF NOT EXISTS meta_people_cache (
			provider     TEXT NOT NULL,
			person_id    TEXT NOT NULL,
			name         TEXT NOT NULL,
			profile_path TEXT NOT NULL DEFAULT '',
			extra_json   TEXT NOT NULL DEFAULT '{}',
			fetched_at   INTEGER NOT NULL,
			expires_at   INTEGER NOT NULL,
			PRIMARY KEY (provider, person_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meta_people_expires ON meta_people_cache(expires_at)`,
		`CREATE TABLE IF NOT EXISTS meta_search_cache (
			cache_key    TEXT PRIMARY KEY,
			provider     TEXT NOT NULL,
			kind         TEXT NOT NULL,
			query        TEXT NOT NULL,
			year         INTEGER NOT NULL DEFAULT 0,
			lang         TEXT NOT NULL,
			payload_json TEXT NOT NULL,
			fetched_at   INTEGER NOT NULL,
			expires_at   BIGINT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meta_search_expires ON meta_search_cache(expires_at)`,
	}

	for _, stmt := range stmts {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("init schema: %w", err)
		}
	}
	if s.initialAllowRegister != nil {
		val := "false"
		if *s.initialAllowRegister {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('allow_registration', ?)`, val); err != nil {
			return fmt.Errorf("set allow_registration: %w", err)
		}
	}
	if s.initTmdbApiKey != nil {
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_api_key', ?)`, *s.initTmdbApiKey); err != nil {
			return fmt.Errorf("set tmdb_api_key: %w", err)
		}
	}
	if s.initTmdbApiBase != nil {
		norm := normalizeTmdbBase(*s.initTmdbApiBase, defaultTmdbApiBase, "/3")
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_api_base', ?)`, norm); err != nil {
			return fmt.Errorf("set tmdb_api_base: %w", err)
		}
	}
	if s.initTmdbImageBase != nil {
		norm := normalizeTmdbBase(*s.initTmdbImageBase, defaultTmdbImageBase, "/t/p")
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_image_base', ?)`, norm); err != nil {
			return fmt.Errorf("set tmdb_image_base: %w", err)
		}
	}
	if s.initMetadataProxy != nil {
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('metadata_proxy', ?)`, *s.initMetadataProxy); err != nil {
			return fmt.Errorf("set metadata_proxy: %w", err)
		}
	}
	if s.initBangumiEnabled != nil {
		val := "false"
		if *s.initBangumiEnabled {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('bangumi_enabled', ?)`, val); err != nil {
			return fmt.Errorf("set bangumi_enabled: %w", err)
		}
	}
	if s.initAllowPublicMeta != nil {
		val := "false"
		if *s.initAllowPublicMeta {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('allow_public_metadata', ?)`, val); err != nil {
			return fmt.Errorf("set allow_public_metadata: %w", err)
		}
	}
	if s.initBangumiBase != nil {
		norm := strings.TrimRight(*s.initBangumiBase, "/")
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('bangumi_api_base', ?)`, norm); err != nil {
			return fmt.Errorf("set bangumi_api_base: %w", err)
		}
	}
	return nil
}

// Legacy migration types for upgrading snapshot/WAL files from the pre-SQLite build.
type legacyUserSyncState struct {
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

type legacyTokenEntry struct {
	UserID    string `json:"user_id"`
	DeviceID  string `json:"device_id"`
	CreatedAt int64  `json:"created_at"`
}

type legacySnapshot struct {
	Users        map[string]*UserRecord          `json:"users"`
	ByUsername   map[string]string               `json:"by_username"`
	Tokens       map[string]legacyTokenEntry     `json:"tokens"`
	UserSyncData map[string]*legacyUserSyncState `json:"user_sync_data"`
}

type legacyWalRecord struct {
	Kind       string            `json:"kind"`
	NowMs      int64             `json:"now_ms"`
	User       *UserRecord       `json:"user,omitempty"`
	Token      string            `json:"token,omitempty"`
	TokenEntry *legacyTokenEntry `json:"token_entry,omitempty"`
	UserID     string            `json:"user_id,omitempty"`
	Settings   map[string]any    `json:"settings,omitempty"`
	Mutations  []PushMutation    `json:"mutations,omitempty"`
}

func (s *SyncStore) migrateLegacyIfNeeded() error {
	var userCount int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&userCount); err != nil || userCount > 0 {
		return err
	}

	snapPath := filepath.Join(s.dataDir, "sync.snapshot.json")
	walPath := filepath.Join(s.dataDir, "sync.wal.jsonl")
	_, snapErr := os.Stat(snapPath)
	_, walErr := os.Stat(walPath)
	if errors.Is(snapErr, os.ErrNotExist) && errors.Is(walErr, os.ErrNotExist) {
		return nil
	}

	var snap legacySnapshot
	snap.Users = make(map[string]*UserRecord)
	snap.Tokens = make(map[string]legacyTokenEntry)
	snap.UserSyncData = make(map[string]*legacyUserSyncState)

	if raw, err := os.ReadFile(snapPath); err == nil {
		_ = json.Unmarshal(raw, &snap)
	}

	var walMutations []legacyWalRecord
	if f, err := os.Open(walPath); err == nil {
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			var rec legacyWalRecord
			if err := json.Unmarshal([]byte(line), &rec); err != nil {
				continue
			}
			switch rec.Kind {
			case "register":
				if rec.User != nil {
					snap.Users[rec.User.UserID] = rec.User
				}
			case "token":
				if rec.Token != "" && rec.TokenEntry != nil {
					snap.Tokens[rec.Token] = *rec.TokenEntry
				}
			case "settings":
				if u, ok := snap.Users[rec.UserID]; ok && rec.Settings != nil {
					if u.Settings == nil {
						u.Settings = map[string]any{}
					}
					for k, v := range rec.Settings {
						u.Settings[k] = v
					}
					u.UpdatedAt = rec.NowMs
				}
			case "push":
				walMutations = append(walMutations, rec)
			}
		}
		_ = f.Close()
	}

	if len(snap.Users) == 0 {
		return nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	hasAnyAdmin := false
	for _, u := range snap.Users {
		if u.IsAdmin || (s.adminUsername != "" && strings.EqualFold(u.Username, s.adminUsername)) {
			hasAnyAdmin = true
			break
		}
	}

	first := true
	for _, u := range snap.Users {
		isAdmin := u.IsAdmin || (s.adminUsername != "" && strings.EqualFold(u.Username, s.adminUsername))
		if !hasAnyAdmin && first {
			isAdmin = true
		}
		first = false

		kdfJSON, _ := json.Marshal(u.KdfParams)
		settingsJSON, _ := json.Marshal(nonNilMap(u.Settings))
		st := snap.UserSyncData[u.UserID]
		var nextSeq, minRet int64
		if st != nil {
			nextSeq = st.NextSeq
			minRet = st.MinRetainedSeq
		}
		if _, err := tx.Exec(`
			INSERT OR IGNORE INTO users (
				user_id, username, username_lower, auth_salt, auth_hash,
				kdf_salt, kdf_params_json, encrypted_master_key_backup, settings_json,
				is_admin, is_disabled, next_seq, min_retained_seq, created_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			u.UserID, u.Username, strings.ToLower(u.Username), u.AuthSalt, u.AuthHash,
			u.KdfSalt, string(kdfJSON), u.EncryptedMasterKeyBackup, string(settingsJSON),
			boolToInt(isAdmin), boolToInt(u.IsDisabled), nextSeq, minRet, u.CreatedAt, u.UpdatedAt,
		); err != nil {
			return err
		}

		if st != nil {
			for oldID, newID := range st.RemappedSources {
				_, _ = tx.Exec(`INSERT OR REPLACE INTO remapped_sources(user_id, old_source_id, new_source_id) VALUES (?, ?, ?)`,
					u.UserID, oldID, newID)
			}
			for oldID, newID := range st.RemappedFiles {
				_, _ = tx.Exec(`INSERT OR REPLACE INTO remapped_files(user_id, old_file_id, new_file_id) VALUES (?, ?, ?)`,
					u.UserID, oldID, newID)
			}
			for _, src := range st.Sources {
				if err := insertSourceRow(tx, u.UserID, src); err != nil {
					return err
				}
			}
			for _, w := range st.Works {
				if err := insertWorkRow(tx, u.UserID, w); err != nil {
					return err
				}
			}
			for _, f := range st.Files {
				if err := insertFileRow(tx, u.UserID, f); err != nil {
					return err
				}
			}
			for _, p := range st.WorkPrefs {
				if err := insertWorkPrefRow(tx, u.UserID, p); err != nil {
					return err
				}
			}
			for _, g := range st.WatchProgress {
				if err := insertWatchProgressRow(tx, u.UserID, g); err != nil {
					return err
				}
			}
			for _, op := range st.AppliedOps {
				_, _ = tx.Exec(`INSERT OR IGNORE INTO applied_ops(user_id, op_id, server_seq, created_at) VALUES (?, ?, ?, ?)`,
					u.UserID, op.OpID, op.ServerSeq, op.CreatedAt)
			}
		}
	}

	for tok, entry := range snap.Tokens {
		_, _ = tx.Exec(`
			INSERT OR IGNORE INTO tokens(token_id, token, user_id, device_id, device_name, platform, created_at, last_seen_at)
			VALUES (?, ?, ?, ?, '', '', ?, ?)`,
			"tok_"+randomHex(8), tok, entry.UserID, entry.DeviceID, entry.CreatedAt, entry.CreatedAt,
		)
	}

	for _, rec := range walMutations {
		if _, _, err := s.applyMutationsTx(tx, rec.UserID, rec.Mutations, rec.NowMs, false); err != nil {
			return err
		}
	}

	if err := tx.Commit(); err != nil {
		return err
	}
	if _, err := os.Stat(snapPath); err == nil {
		_ = os.Rename(snapPath, snapPath+".migrated")
	}
	if _, err := os.Stat(walPath); err == nil {
		_ = os.Rename(walPath, walPath+".migrated")
	}
	return nil
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

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func nonNilMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func (s *SyncStore) getConfigBool(key string, fallback bool) bool {
	var raw string
	if err := s.db.QueryRow(`SELECT value FROM server_config WHERE key = ?`, key).Scan(&raw); err != nil {
		return fallback
	}
	return raw == "true" || raw == "1"
}

func (s *SyncStore) getConfigInt64(key string, fallback int64) int64 {
	return getConfigInt64Q(s.db, key, fallback)
}

func getConfigInt64Q(q sqlQuerier, key string, fallback int64) int64 {
	var raw string
	if err := q.QueryRow(`SELECT value FROM server_config WHERE key = ?`, key).Scan(&raw); err != nil {
		return fallback
	}
	var out int64
	if _, err := fmt.Sscanf(raw, "%d", &out); err != nil {
		return fallback
	}
	return out
}

func (s *SyncStore) GetPublicInfo() PublicServerInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	var userCount int64
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&userCount)
	return PublicServerInfo{
		Code:               0,
		AllowRegistration:  s.getConfigBool("allow_registration", true),
		MaxEntitiesPerUser: s.getConfigInt64("max_entities_per_user", 0),
		UserCount:          userCount,
	}
}

func (s *SyncStore) Register(req RegisterRequest) (AuthResponse, error) {
	username := strings.TrimSpace(req.Username)
	if username == "" || strings.TrimSpace(req.AuthVerifier) == "" || strings.TrimSpace(req.EncryptedMasterKeyBackup) == "" {
		return AuthResponse{}, ErrInvalidInput
	}
	if req.KdfParams.Algo == "" {
		req.KdfParams = DefaultKdfParams()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	var userCount int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&userCount); err != nil {
		return AuthResponse{}, err
	}
	isDesignatedAdmin := s.adminUsername != "" && strings.EqualFold(username, s.adminUsername)
	if (userCount > 0 || s.adminUsername != "") && !isDesignatedAdmin && !s.getConfigBool("allow_registration", true) {
		return AuthResponse{}, ErrRegistrationClosed
	}

	var existing int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM users WHERE username_lower = ?`, strings.ToLower(username)).Scan(&existing); err != nil {
		return AuthResponse{}, err
	}
	if existing > 0 {
		return AuthResponse{}, ErrUserExists
	}

	isAdmin := isDesignatedAdmin || (s.adminUsername == "" && userCount == 0)
	ts := nowMs()
	userID := "usr_" + randomHex(12)
	authSalt := randomHex(16)
	authHash := hashAuthVerifier(authSalt, req.AuthVerifier)
	settings := nonNilMap(req.Settings)
	settingsJSON, _ := json.Marshal(settings)
	kdfJSON, _ := json.Marshal(req.KdfParams)

	tokenID := "tok_" + randomHex(8)
	token := "plezy_tok_" + randomHex(24)
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		deviceID = "web-" + randomHex(4)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return AuthResponse{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO users (
			user_id, username, username_lower, auth_salt, auth_hash,
			kdf_salt, kdf_params_json, encrypted_master_key_backup, settings_json,
			is_admin, is_disabled, next_seq, min_retained_seq, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?)`,
		userID, username, strings.ToLower(username), authSalt, authHash,
		req.KdfSalt, string(kdfJSON), req.EncryptedMasterKeyBackup, string(settingsJSON),
		boolToInt(isAdmin), ts, ts,
	); err != nil {
		return AuthResponse{}, err
	}

	if _, err := tx.Exec(`
		INSERT INTO tokens(token_id, token, user_id, device_id, device_name, platform, created_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, token, userID, deviceID, strings.TrimSpace(req.DeviceName), strings.TrimSpace(req.Platform), ts, ts,
	); err != nil {
		return AuthResponse{}, err
	}

	if err := tx.Commit(); err != nil {
		return AuthResponse{}, err
	}

	return AuthResponse{
		Code:                     0,
		UserID:                   userID,
		Username:                 username,
		IsAdmin:                  isAdmin,
		AccessToken:              token,
		KdfSalt:                  req.KdfSalt,
		KdfParams:                req.KdfParams,
		EncryptedMasterKeyBackup: req.EncryptedMasterKeyBackup,
		Settings:                 settings,
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

	user, _, _, err := s.loadUserByLowerUsername(strings.ToLower(username))
	if err != nil {
		return AuthResponse{}, ErrInvalidCreds
	}
	if user.IsDisabled {
		return AuthResponse{}, ErrUserDisabled
	}

	expected := hashAuthVerifier(user.AuthSalt, req.AuthVerifier)
	if subtle.ConstantTimeCompare([]byte(expected), []byte(user.AuthHash)) != 1 {
		return AuthResponse{}, ErrInvalidCreds
	}

	ts := nowMs()
	tokenID := "tok_" + randomHex(8)
	token := "plezy_tok_" + randomHex(24)
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		deviceID = "web-" + randomHex(4)
	}

	if _, err := s.db.Exec(`
		INSERT INTO tokens(token_id, token, user_id, device_id, device_name, platform, created_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, token, user.UserID, deviceID, strings.TrimSpace(req.DeviceName), strings.TrimSpace(req.Platform), ts, ts,
	); err != nil {
		return AuthResponse{}, err
	}

	return AuthResponse{
		Code:                     0,
		UserID:                   user.UserID,
		Username:                 user.Username,
		IsAdmin:                  user.IsAdmin,
		AccessToken:              token,
		KdfSalt:                  user.KdfSalt,
		KdfParams:                user.KdfParams,
		EncryptedMasterKeyBackup: user.EncryptedMasterKeyBackup,
		Settings:                 user.Settings,
		ServerTimeMs:             ts,
	}, nil
}

// WebRegister creates an account with server-assisted Argon2id + AES-GCM MasterKey backup
// matching SyncCrypto.derivePasswordKeys so the account works seamlessly across Web and App.
func (s *SyncStore) WebRegister(req WebAuthRequest) (AuthResponse, error) {
	username := strings.TrimSpace(req.Username)
	if username == "" || len(req.Password) < 6 {
		return AuthResponse{}, fmt.Errorf("%w: username required and password must be at least 6 chars", ErrInvalidInput)
	}
	salt, err := randomBytes(16)
	if err != nil {
		return AuthResponse{}, err
	}
	masterKey, err := randomBytes(32)
	if err != nil {
		return AuthResponse{}, err
	}
	params := DefaultKdfParams()
	kek, verifier, err := DerivePasswordKeys(req.Password, salt, params)
	if err != nil {
		return AuthResponse{}, err
	}
	backup, err := SealMasterKeyBackup(masterKey, kek)
	if err != nil {
		return AuthResponse{}, err
	}
	platform := strings.TrimSpace(req.Platform)
	if platform == "" {
		platform = "Web"
	}
	devName := strings.TrimSpace(req.DeviceName)
	if devName == "" {
		devName = "Web Browser"
	}
	return s.Register(RegisterRequest{
		Username:                 username,
		AuthVerifier:             verifier,
		KdfSalt:                  base64.StdEncoding.EncodeToString(salt),
		KdfParams:                params,
		EncryptedMasterKeyBackup: backup,
		Settings:                 map[string]any{},
		DeviceID:                 req.DeviceID,
		DeviceName:               devName,
		Platform:                 platform,
	})
}

func (s *SyncStore) WebLogin(req WebAuthRequest) (AuthResponse, error) {
	username := strings.TrimSpace(req.Username)
	if username == "" || req.Password == "" {
		return AuthResponse{}, ErrInvalidCreds
	}
	kdfSalt, params, ok := s.LookupKdf(username)
	if !ok {
		return AuthResponse{}, ErrInvalidCreds
	}
	saltBytes, err := base64.StdEncoding.DecodeString(kdfSalt)
	if err != nil {
		return AuthResponse{}, ErrInvalidCreds
	}
	_, verifier, err := DerivePasswordKeys(req.Password, saltBytes, params)
	if err != nil {
		return AuthResponse{}, ErrInvalidCreds
	}
	platform := strings.TrimSpace(req.Platform)
	if platform == "" {
		platform = "Web"
	}
	devName := strings.TrimSpace(req.DeviceName)
	if devName == "" {
		devName = "Web Browser"
	}
	return s.Login(LoginRequest{
		Username:     username,
		AuthVerifier: verifier,
		DeviceID:     req.DeviceID,
		DeviceName:   devName,
		Platform:     platform,
	})
}

func (s *SyncStore) WebChangePassword(userID string, req WebPasswordChangeRequest) error {
	if req.OldPassword == "" || len(req.NewPassword) < 6 {
		return fmt.Errorf("%w: new password must be at least 6 chars", ErrInvalidInput)
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	user, _, _, err := s.loadUserByID(userID)
	if err != nil {
		return ErrUnauthorized
	}
	oldSalt, err := base64.StdEncoding.DecodeString(user.KdfSalt)
	if err != nil {
		return ErrInvalidCreds
	}
	oldKek, oldVerifier, err := DerivePasswordKeys(req.OldPassword, oldSalt, user.KdfParams)
	if err != nil {
		return ErrInvalidCreds
	}
	expected := hashAuthVerifier(user.AuthSalt, oldVerifier)
	if subtle.ConstantTimeCompare([]byte(expected), []byte(user.AuthHash)) != 1 {
		return ErrInvalidCreds
	}

	masterKey, err := UnsealMasterKeyBackup(user.EncryptedMasterKeyBackup, oldKek)
	if err != nil {
		return fmt.Errorf("%w: failed to unseal master key", ErrInvalidCreds)
	}

	newSalt, err := randomBytes(16)
	if err != nil {
		return err
	}
	newParams := DefaultKdfParams()
	newKek, newVerifier, err := DerivePasswordKeys(req.NewPassword, newSalt, newParams)
	if err != nil {
		return err
	}
	newBackup, err := SealMasterKeyBackup(masterKey, newKek)
	if err != nil {
		return err
	}
	newAuthSalt := randomHex(16)
	newAuthHash := hashAuthVerifier(newAuthSalt, newVerifier)
	kdfJSON, _ := json.Marshal(newParams)
	ts := nowMs()

	_, err = s.db.Exec(`
		UPDATE users
		SET auth_salt = ?, auth_hash = ?, kdf_salt = ?, kdf_params_json = ?,
		    encrypted_master_key_backup = ?, updated_at = ?
		WHERE user_id = ?`,
		newAuthSalt, newAuthHash, base64.StdEncoding.EncodeToString(newSalt), string(kdfJSON),
		newBackup, ts, userID,
	)
	return err
}

func (s *SyncStore) LookupKdf(username string) (salt string, params KdfParams, exists bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var kdfJSON string
	err := s.db.QueryRow(
		`SELECT kdf_salt, kdf_params_json FROM users WHERE username_lower = ?`,
		strings.ToLower(strings.TrimSpace(username)),
	).Scan(&salt, &kdfJSON)
	if err != nil {
		return "", KdfParams{}, false
	}
	_ = json.Unmarshal([]byte(kdfJSON), &params)
	return salt, params, true
}

func (s *SyncStore) Authenticate(token string) (*UserRecord, error) {
	u, _, err := s.AuthenticateWithTokenID(token)
	return u, err
}

func (s *SyncStore) AuthenticateWithTokenID(token string) (*UserRecord, string, error) {
	trimmed := strings.TrimSpace(token)
	if trimmed == "" {
		return nil, "", ErrUnauthorized
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	var tokenID, userID string
	var lastSeen int64
	err := s.db.QueryRow(
		`SELECT token_id, user_id, last_seen_at FROM tokens WHERE token = ?`,
		trimmed,
	).Scan(&tokenID, &userID, &lastSeen)
	if err != nil {
		return nil, "", ErrUnauthorized
	}

	user, _, _, err := s.loadUserByID(userID)
	if err != nil {
		return nil, "", ErrUnauthorized
	}
	if user.IsDisabled {
		return nil, "", ErrUserDisabled
	}

	ts := nowMs()
	if ts-lastSeen > 60000 {
		_, _ = s.db.Exec(`UPDATE tokens SET last_seen_at = ? WHERE token_id = ?`, ts, tokenID)
	}
	return user, tokenID, nil
}

func (s *SyncStore) UpdateUserSettings(userID string, updates map[string]any) (map[string]any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	user, _, _, err := s.loadUserByID(userID)
	if err != nil {
		return nil, ErrUnauthorized
	}
	if user.Settings == nil {
		user.Settings = map[string]any{}
	}
	for k, v := range updates {
		if v == nil {
			delete(user.Settings, k)
		} else {
			user.Settings[k] = v
		}
	}
	raw, err := json.Marshal(user.Settings)
	if err != nil {
		return nil, err
	}
	ts := nowMs()
	if _, err := s.db.Exec(`UPDATE users SET settings_json = ?, updated_at = ? WHERE user_id = ?`, string(raw), ts, userID); err != nil {
		return nil, err
	}
	return user.Settings, nil
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
	tokenID := "tok_" + randomHex(8)
	deviceName := strings.TrimSpace(req.DeviceName)
	if deviceName == "" {
		deviceName = sess.DeviceName
	}
	platform := strings.TrimSpace(req.Platform)
	if platform == "" {
		platform = "TV"
	}
	if _, err := s.db.Exec(`
		INSERT INTO tokens(token_id, token, user_id, device_id, device_name, platform, created_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		tokenID, tvToken, user.UserID, req.DeviceID, deviceName, platform, ts, ts,
	); err != nil {
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
	s.mu.Lock()
	defer s.mu.Unlock()

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
		if u, _, _, err := s.loadUserByID(sess.UserID); err == nil {
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

	resolvedID := s.resolveSourceIDDB(s.db, userID, req.SourceID)
	var holder sql.NullString
	var leaseUntil int64
	var isDeleted int
	err := s.db.QueryRow(`
		SELECT scan_lease_owner, scan_lease_until, is_deleted
		FROM sync_sources WHERE user_id = ? AND source_id = ?`,
		userID, resolvedID,
	).Scan(&holder, &leaseUntil, &isDeleted)
	if errors.Is(err, sql.ErrNoRows) || isDeleted == 1 {
		return LeaseResponse{}, ErrSourceNotFound
	}
	if err != nil {
		return LeaseResponse{}, err
	}

	ts := nowMs()
	ttlSec := req.TtlSec
	if ttlSec <= 0 {
		ttlSec = defaultScanLeaseSec
	}
	until := ts + int64(ttlSec)*1000

	if holder.Valid && holder.String != "" && holder.String != req.DeviceID && leaseUntil > ts {
		return LeaseResponse{
			Code:           0,
			Acquired:       false,
			HolderDeviceID: holder.String,
			ExpiresAtMs:    leaseUntil,
		}, nil
	}

	if _, err := s.db.Exec(`
		UPDATE sync_sources SET scan_lease_owner = ?, scan_lease_until = ?
		WHERE user_id = ? AND source_id = ?`,
		req.DeviceID, until, userID, resolvedID,
	); err != nil {
		return LeaseResponse{}, err
	}
	return LeaseResponse{
		Code:           0,
		Acquired:       true,
		HolderDeviceID: req.DeviceID,
		ExpiresAtMs:    until,
	}, nil
}

func (s *SyncStore) GetUserProfile(userID string) (UserProfileResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	user, _, _, err := s.loadUserByID(userID)
	if err != nil {
		return UserProfileResponse{}, ErrUnauthorized
	}
	stats := s.queryUserStatsLocked(userID)
	return UserProfileResponse{
		Code:               0,
		UserID:             user.UserID,
		Username:           user.Username,
		IsAdmin:            user.IsAdmin,
		CreatedAt:          user.CreatedAt,
		UpdatedAt:          user.UpdatedAt,
		Settings:           user.Settings,
		Stats:              stats,
		MaxEntitiesPerUser: s.getConfigInt64("max_entities_per_user", 0),
	}, nil
}

func (s *SyncStore) ListUserDevices(userID, currentTokenID string) ([]DeviceTokenInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`
		SELECT token_id, device_id, device_name, platform, created_at, last_seen_at
		FROM tokens WHERE user_id = ? ORDER BY last_seen_at DESC, created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]DeviceTokenInfo, 0)
	for rows.Next() {
		var d DeviceTokenInfo
		if err := rows.Scan(&d.TokenID, &d.DeviceID, &d.DeviceName, &d.Platform, &d.CreatedAt, &d.LastSeenAt); err != nil {
			return nil, err
		}
		d.IsCurrent = d.TokenID == currentTokenID
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *SyncStore) RevokeUserDevice(userID, tokenID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`DELETE FROM tokens WHERE user_id = ? AND token_id = ?`, userID, strings.TrimSpace(tokenID))
	if err != nil {
		return err
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return ErrUserNotFound
	}
	return nil
}

func (s *SyncStore) ClearUserSyncData(userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	tables := []string{
		"applied_ops",
		"remapped_files",
		"remapped_sources",
		"sync_lists",
		"sync_watch_progress",
		"sync_work_prefs",
		"sync_files",
		"sync_works",
		"sync_sources",
	}
	for _, tbl := range tables {
		if _, err := tx.Exec(`DELETE FROM `+tbl+` WHERE user_id = ?`, userID); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`UPDATE users SET next_seq = 0, min_retained_seq = 0, updated_at = ? WHERE user_id = ?`, nowMs(), userID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *SyncStore) AdminOverview() (AdminOverviewResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var resp AdminOverviewResponse
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&resp.TotalUsers)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM tokens`).Scan(&resp.ActiveTokens)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_works WHERE is_deleted = 0`).Scan(&resp.TotalWorks)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_files WHERE is_deleted = 0`).Scan(&resp.TotalFiles)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_lists WHERE is_deleted = 0`).Scan(&resp.TotalLists)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_watch_progress`).Scan(&resp.TotalProgress)
	resp.AllowRegistration = s.getConfigBool("allow_registration", true)
	resp.MaxEntitiesPerUser = s.getConfigInt64("max_entities_per_user", 0)
	if st, err := os.Stat(s.dbPath); err == nil {
		resp.DbSizeBytes = st.Size()
	}
	return resp, nil
}

func (s *SyncStore) AdminUpdateConfig(req AdminConfigRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if req.AllowRegistration != nil {
		val := "false"
		if *req.AllowRegistration {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('allow_registration', ?)`, val); err != nil {
			return err
		}
	}
	if req.MaxEntitiesPerUser != nil {
		v := *req.MaxEntitiesPerUser
		if v < 0 {
			v = 0
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('max_entities_per_user', ?)`, fmt.Sprintf("%d", v)); err != nil {
			return err
		}
	}
	return nil
}

func (s *SyncStore) AdminListUsers() ([]AdminUserSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`
		SELECT user_id, username, is_admin, is_disabled, created_at, updated_at
		FROM users ORDER BY created_at ASC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AdminUserSummary, 0)
	for rows.Next() {
		var u AdminUserSummary
		var isAdmin, isDisabled int
		if err := rows.Scan(&u.UserID, &u.Username, &isAdmin, &isDisabled, &u.CreatedAt, &u.UpdatedAt); err != nil {
			return nil, err
		}
		u.IsAdmin = isAdmin == 1
		u.IsDisabled = isDisabled == 1
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		uid := out[i].UserID
		_ = s.db.QueryRow(`SELECT COUNT(*) FROM tokens WHERE user_id = ?`, uid).Scan(&out[i].DeviceCount)
		stats := s.queryUserStatsLocked(uid)
		out[i].EntityCount = stats.TotalEntities
		out[i].ProgressRows = stats.WatchProgress
	}
	return out, nil
}

func (s *SyncStore) AdminSetUserDisabled(actorUserID, targetUserID string, disabled bool) error {
	if actorUserID == targetUserID && disabled {
		return fmt.Errorf("%w: cannot disable current admin account", ErrInvalidInput)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`UPDATE users SET is_disabled = ?, updated_at = ? WHERE user_id = ?`, boolToInt(disabled), nowMs(), targetUserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrUserNotFound
	}
	if disabled {
		_, _ = s.db.Exec(`DELETE FROM tokens WHERE user_id = ?`, targetUserID)
	}
	return nil
}

func (s *SyncStore) AdminDeleteUser(actorUserID, targetUserID string) error {
	if actorUserID == targetUserID {
		return fmt.Errorf("%w: cannot delete current admin account", ErrInvalidInput)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`DELETE FROM users WHERE user_id = ?`, targetUserID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrUserNotFound
	}
	return nil
}

func (s *SyncStore) queryUserStatsLocked(userID string) UserStats {
	var st UserStats
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_sources WHERE user_id = ? AND is_deleted = 0`, userID).Scan(&st.Sources)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_works WHERE user_id = ? AND is_deleted = 0`, userID).Scan(&st.Works)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_files WHERE user_id = ? AND is_deleted = 0`, userID).Scan(&st.Files)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_work_prefs WHERE user_id = ?`, userID).Scan(&st.WorkPrefs)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_watch_progress WHERE user_id = ?`, userID).Scan(&st.WatchProgress)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM sync_lists WHERE user_id = ? AND is_deleted = 0`, userID).Scan(&st.Lists)
	st.TotalEntities = st.Sources + st.Works + st.Files + st.Lists
	return st
}

func (s *SyncStore) RunGC(atMs int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tombstoneCutoff := atMs - tombstoneRetentionMs
	opCutoff := atMs - appliedOpRetentionMs

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	rows, err := tx.Query(`SELECT user_id, min_retained_seq FROM users`)
	if err != nil {
		return err
	}
	type userSeq struct {
		id     string
		minSeq int64
	}
	var users []userSeq
	for rows.Next() {
		var u userSeq
		if err := rows.Scan(&u.id, &u.minSeq); err != nil {
			rows.Close()
			return err
		}
		users = append(users, u)
	}
	rows.Close()

	tables := []string{"sync_sources", "sync_works", "sync_files", "sync_lists"}
	for _, u := range users {
		maxPurged := u.minSeq
		for _, tbl := range tables {
			var seq sql.NullInt64
			if err := tx.QueryRow(
				`SELECT MAX(server_seq) FROM `+tbl+` WHERE user_id = ? AND is_deleted = 1 AND client_updated_at <= ?`,
				u.id, tombstoneCutoff,
			).Scan(&seq); err == nil && seq.Valid && seq.Int64 > maxPurged {
				maxPurged = seq.Int64
			}
			if _, err := tx.Exec(
				`DELETE FROM `+tbl+` WHERE user_id = ? AND is_deleted = 1 AND client_updated_at <= ?`,
				u.id, tombstoneCutoff,
			); err != nil {
				return err
			}
		}
		if maxPurged > u.minSeq {
			if _, err := tx.Exec(`UPDATE users SET min_retained_seq = ? WHERE user_id = ?`, maxPurged, u.id); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(`DELETE FROM applied_ops WHERE created_at <= ?`, opCutoff); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM meta_search_cache WHERE expires_at <= ?`, atMs); err != nil {
		return err
	}
	staleCacheCutoff := atMs - 7*24*60*60*1000
	for _, tbl := range []string{"meta_works_cache", "meta_seasons_cache", "meta_people_cache"} {
		if _, err := tx.Exec(`DELETE FROM `+tbl+` WHERE expires_at <= ?`, staleCacheCutoff); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *SyncStore) ValidateUsernameCheck(username string) error {
	if strings.TrimSpace(username) == "" {
		return fmt.Errorf("%w: username required", ErrInvalidInput)
	}
	return nil
}

type sqlQuerier interface {
	QueryRow(query string, args ...any) *sql.Row
}

func (s *SyncStore) loadUserByLowerUsername(lower string) (*UserRecord, int64, int64, error) {
	row := s.db.QueryRow(`
		SELECT user_id, username, auth_salt, auth_hash, kdf_salt, kdf_params_json,
		       encrypted_master_key_backup, settings_json, is_admin, is_disabled,
		       next_seq, min_retained_seq, created_at, updated_at
		FROM users WHERE username_lower = ?`, lower)
	return scanUserRow(row)
}

func (s *SyncStore) loadUserByID(userID string) (*UserRecord, int64, int64, error) {
	row := s.db.QueryRow(`
		SELECT user_id, username, auth_salt, auth_hash, kdf_salt, kdf_params_json,
		       encrypted_master_key_backup, settings_json, is_admin, is_disabled,
		       next_seq, min_retained_seq, created_at, updated_at
		FROM users WHERE user_id = ?`, userID)
	return scanUserRow(row)
}

func scanUserRow(row *sql.Row) (*UserRecord, int64, int64, error) {
	var u UserRecord
	var kdfJSON, settingsJSON string
	var isAdmin, isDisabled int
	var nextSeq, minRetainedSeq int64
	if err := row.Scan(
		&u.UserID, &u.Username, &u.AuthSalt, &u.AuthHash, &u.KdfSalt, &kdfJSON,
		&u.EncryptedMasterKeyBackup, &settingsJSON, &isAdmin, &isDisabled,
		&nextSeq, &minRetainedSeq, &u.CreatedAt, &u.UpdatedAt,
	); err != nil {
		return nil, 0, 0, err
	}
	u.IsAdmin = isAdmin == 1
	u.IsDisabled = isDisabled == 1
	_ = json.Unmarshal([]byte(kdfJSON), &u.KdfParams)
	u.Settings = map[string]any{}
	_ = json.Unmarshal([]byte(settingsJSON), &u.Settings)
	return &u, nextSeq, minRetainedSeq, nil
}
