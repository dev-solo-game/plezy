package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/vault"

	_ "modernc.org/sqlite"
)

type Store struct {
	db          *sql.DB
	dbPath      string
	dataDir     string
	vault       *vault.Vault
	metaMu      sync.Mutex
	scanLockMu  sync.Mutex
	activeScans map[string]struct{}
}

func Open(dataDir string, v *vault.Vault) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	dbPath := filepath.Join(dataDir, "media.db")
	sqlDB, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)

	s := &Store{
		db:          sqlDB,
		dbPath:      dbPath,
		dataDir:     dataDir,
		vault:       v,
		activeScans: make(map[string]struct{}),
	}
	if err := s.initSchema(); err != nil {
		_ = sqlDB.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

func (s *Store) DB() *sql.DB {
	return s.db
}

func (s *Store) DataDir() string {
	return s.dataDir
}

func (s *Store) Vault() *vault.Vault {
	return s.vault
}

func (s *Store) NowMs() int64 {
	return time.Now().UnixMilli()
}

func (s *Store) initSchema() error {
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
		`CREATE TABLE IF NOT EXISTS admin_account (
			id            INTEGER PRIMARY KEY CHECK (id = 1),
			username      TEXT NOT NULL,
			password_salt TEXT NOT NULL,
			password_hash TEXT NOT NULL,
			created_at    INTEGER NOT NULL,
			updated_at    INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS sessions (
			token_id     TEXT PRIMARY KEY,
			token_hash   TEXT NOT NULL UNIQUE,
			device_name  TEXT NOT NULL DEFAULT '',
			platform     TEXT NOT NULL DEFAULT '',
			ip           TEXT NOT NULL DEFAULT '',
			created_at   INTEGER NOT NULL,
			last_used_at INTEGER NOT NULL,
			expires_at   INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)`,

		`CREATE TABLE IF NOT EXISTS server_settings (
			key   TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,

		`CREATE TABLE IF NOT EXISTS mounts (
			id                TEXT PRIMARY KEY,
			name              TEXT NOT NULL,
			kind              TEXT NOT NULL,
			config_json       TEXT NOT NULL DEFAULT '{}',
			encrypted_secrets TEXT NOT NULL DEFAULT '',
			enabled           INTEGER NOT NULL DEFAULT 1,
			created_at        INTEGER NOT NULL,
			updated_at        INTEGER NOT NULL
		)`,

		`CREATE TABLE IF NOT EXISTS mount_scan_states (
			mount_id         TEXT PRIMARY KEY REFERENCES mounts(id) ON DELETE CASCADE,
			scan_id          INTEGER NOT NULL DEFAULT 0,
			status           TEXT NOT NULL DEFAULT 'idle',
			pending_json     TEXT,
			quark_checkpoint TEXT,
			started_at       INTEGER,
			finished_at      INTEGER,
			last_error       TEXT
		)`,

		`CREATE TABLE IF NOT EXISTS media_items (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			work_key        TEXT,
			kind            TEXT NOT NULL,
			library_type    TEXT NOT NULL,
			parent_id       INTEGER REFERENCES media_items(id) ON DELETE CASCADE,
			show_id         INTEGER REFERENCES media_items(id) ON DELETE CASCADE,
			title           TEXT NOT NULL,
			sort_title      TEXT NOT NULL,
			original_title  TEXT,
			aliases         TEXT,
			year            INTEGER,
			release_date    TEXT,
			summary         TEXT,
			tagline         TEXT,
			content_rating  TEXT,
			studio          TEXT,
			rating          REAL,
			runtime_ms      INTEGER,
			season_number   INTEGER,
			episode_number  INTEGER,
			absolute_number INTEGER,
			poster_source   TEXT,
			backdrop_source TEXT,
			logo_source     TEXT,
			tmdb_id         TEXT,
			imdb_id         TEXT,
			tvdb_id         TEXT,
			bangumi_id      TEXT,
			metadata_source TEXT,
			locked          INTEGER NOT NULL DEFAULT 0,
			added_at        INTEGER NOT NULL,
			source_added_at INTEGER,
			updated_at      INTEGER NOT NULL,
			scraped_at      INTEGER
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_media_items_work_key ON media_items(work_key) WHERE work_key IS NOT NULL AND work_key != ''`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_kind_type ON media_items(kind, library_type)`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_parent ON media_items(parent_id)`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_show ON media_items(show_id)`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_tmdb ON media_items(kind, tmdb_id)`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_added ON media_items(added_at)`,
		`CREATE INDEX IF NOT EXISTS idx_media_items_sort ON media_items(sort_title)`,

		`CREATE TABLE IF NOT EXISTS media_files (
			id                INTEGER PRIMARY KEY AUTOINCREMENT,
			mount_id          TEXT NOT NULL REFERENCES mounts(id) ON DELETE CASCADE,
			path              TEXT NOT NULL,
			remote_id         TEXT,
			role              TEXT NOT NULL,
			item_id           INTEGER REFERENCES media_items(id) ON DELETE SET NULL,
			owner_file_id     INTEGER REFERENCES media_files(id) ON DELETE CASCADE,
			size              INTEGER,
			modified_at       INTEGER,
			source_created_at INTEGER,
			match_state       TEXT NOT NULL DEFAULT 'pending',
			match_locked      INTEGER NOT NULL DEFAULT 0,
			parsed_json       TEXT,
			version_label     TEXT,
			language          TEXT,
			duration_ms       INTEGER,
			bitrate_kbps      INTEGER,
			container         TEXT,
			video_codec       TEXT,
			width             INTEGER,
			height            INTEGER,
			hdr_format        TEXT,
			streams_json      TEXT,
			probed_at         INTEGER,
			seen_in_scan      INTEGER NOT NULL DEFAULT 0,
			added_at          INTEGER NOT NULL
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_mount_path ON media_files(mount_id, path)`,
		`CREATE INDEX IF NOT EXISTS idx_media_files_mount_remote ON media_files(mount_id, remote_id)`,
		`CREATE INDEX IF NOT EXISTS idx_media_files_item ON media_files(item_id)`,
		`CREATE INDEX IF NOT EXISTS idx_media_files_match ON media_files(role, match_state)`,
		`CREATE INDEX IF NOT EXISTS idx_media_files_owner ON media_files(owner_file_id)`,

		`CREATE TABLE IF NOT EXISTS genres (
			id   INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT NOT NULL UNIQUE
		)`,
		`CREATE TABLE IF NOT EXISTS item_genres (
			item_id  INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
			genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
			PRIMARY KEY (item_id, genre_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_item_genres_genre ON item_genres(genre_id)`,

		`CREATE TABLE IF NOT EXISTS people (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			name           TEXT NOT NULL,
			provider       TEXT NOT NULL DEFAULT 'tmdb',
			external_id    TEXT,
			photo_source   TEXT,
			biography      TEXT,
			birthday       TEXT,
			department     TEXT,
			place_of_birth TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS idx_people_ext ON people(provider, external_id)`,
		`CREATE INDEX IF NOT EXISTS idx_people_name ON people(name)`,

		`CREATE TABLE IF NOT EXISTS item_credits (
			item_id    INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
			person_id  INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
			job        TEXT NOT NULL,
			character  TEXT,
			sort_order INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (item_id, person_id, job)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_item_credits_person ON item_credits(person_id)`,

		`CREATE TABLE IF NOT EXISTS watch_states (
			item_id              INTEGER PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
			work_key             TEXT,
			last_file_id         INTEGER,
			position_ms          INTEGER NOT NULL DEFAULT 0,
			duration_ms          INTEGER,
			watched              INTEGER NOT NULL DEFAULT 0,
			play_count           INTEGER NOT NULL DEFAULT 0,
			last_played_at       INTEGER,
			favorite             INTEGER NOT NULL DEFAULT 0,
			hidden_from_continue INTEGER NOT NULL DEFAULT 0,
			updated_at           INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_watch_states_played ON watch_states(last_played_at)`,

		`CREATE TABLE IF NOT EXISTS work_watch_states (
			state_key            TEXT PRIMARY KEY,
			position_ms          INTEGER NOT NULL DEFAULT 0,
			duration_ms          INTEGER,
			watched              INTEGER NOT NULL DEFAULT 0,
			play_count           INTEGER NOT NULL DEFAULT 0,
			last_played_at       INTEGER,
			favorite             INTEGER NOT NULL DEFAULT 0,
			hidden_from_continue INTEGER NOT NULL DEFAULT 0,
			updated_at           INTEGER NOT NULL
		)`,

		`CREATE TABLE IF NOT EXISTS work_prefs (
			work_key             TEXT PRIMARY KEY,
			intro_enabled        INTEGER NOT NULL DEFAULT 0,
			intro_start_ms       INTEGER NOT NULL DEFAULT 0,
			intro_end_ms         INTEGER NOT NULL DEFAULT 0,
			credits_enabled      INTEGER NOT NULL DEFAULT 0,
			credits_from_end_ms  INTEGER NOT NULL DEFAULT 0,
			keep_easter_egg_ms   INTEGER NOT NULL DEFAULT 0,
			preferred_audio_lang TEXT,
			preferred_sub_lang   TEXT,
			playback_speed       REAL NOT NULL DEFAULT 1.0,
			updated_at           INTEGER NOT NULL
		)`,

		`CREATE TABLE IF NOT EXISTS lists (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			kind          TEXT NOT NULL,
			title         TEXT NOT NULL,
			summary       TEXT,
			poster_source TEXT,
			tmdb_id       TEXT,
			created_at    INTEGER NOT NULL,
			updated_at    INTEGER NOT NULL
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_tmdb ON lists(kind, tmdb_id) WHERE tmdb_id IS NOT NULL AND tmdb_id != ''`,

		`CREATE TABLE IF NOT EXISTS list_items (
			list_id    INTEGER NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
			item_id    INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
			sort_order INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (list_id, item_id)
		)`,

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
			expires_at   INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_meta_search_expires ON meta_search_cache(expires_at)`,
	}

	for _, stmt := range stmts {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("init schema: %w", err)
		}
	}
	return nil
}

func SortTitleFor(title string) string {
	lower := strings.ToLower(strings.TrimSpace(title))
	for _, prefix := range []string{"the ", "a ", "an "} {
		if strings.HasPrefix(lower, prefix) && len(lower) > len(prefix) {
			return strings.TrimSpace(lower[len(prefix):])
		}
	}
	return lower
}
