package db

import (
	"fmt"
	"sort"
)

type Migration struct {
	Version    int
	Name       string
	Statements []string
}

var migrations = []Migration{
	{
		Version: 1,
		Name:    "0001_v1_initial_schema",
		Statements: []string{
			// 1. 平台与全局公共表（无 household_id）
			`CREATE TABLE IF NOT EXISTS platform_admins (
				id                   TEXT PRIMARY KEY,
				username             TEXT NOT NULL UNIQUE,
				password_salt        TEXT NOT NULL,
				password_hash        TEXT NOT NULL,
				must_change_password INTEGER NOT NULL DEFAULT 1,
				last_login_at        INTEGER,
				last_login_ip        TEXT NOT NULL DEFAULT '',
				created_at           INTEGER NOT NULL,
				updated_at           INTEGER NOT NULL
			)`,
			`CREATE TABLE IF NOT EXISTS admin_sessions (
				token_id     TEXT PRIMARY KEY,
				admin_id     TEXT NOT NULL REFERENCES platform_admins(id) ON DELETE CASCADE,
				token_hash   TEXT NOT NULL UNIQUE,
				ip           TEXT NOT NULL DEFAULT '',
				user_agent   TEXT NOT NULL DEFAULT '',
				created_at   INTEGER NOT NULL,
				last_used_at INTEGER NOT NULL,
				expires_at   INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires ON admin_sessions(expires_at)`,
			`CREATE INDEX IF NOT EXISTS idx_admin_sessions_admin ON admin_sessions(admin_id)`,

			`CREATE TABLE IF NOT EXISTS server_settings (
				key   TEXT PRIMARY KEY,
				value TEXT NOT NULL
			)`,
			`CREATE TABLE IF NOT EXISTS invite_codes (
				code       TEXT PRIMARY KEY,
				created_by TEXT NOT NULL,
				max_uses   INTEGER NOT NULL DEFAULT 1,
				used_count INTEGER NOT NULL DEFAULT 0,
				expires_at INTEGER,
				revoked    INTEGER NOT NULL DEFAULT 0,
				note       TEXT NOT NULL DEFAULT '',
				created_at INTEGER NOT NULL
			)`,
			`CREATE TABLE IF NOT EXISTS audit_logs (
				id           INTEGER PRIMARY KEY AUTOINCREMENT,
				actor_type   TEXT NOT NULL,
				actor_id     TEXT NOT NULL,
				household_id TEXT,
				action       TEXT NOT NULL,
				target_type  TEXT NOT NULL DEFAULT '',
				target_id    TEXT NOT NULL DEFAULT '',
				detail_json  TEXT NOT NULL DEFAULT '{}',
				ip           TEXT NOT NULL DEFAULT '',
				created_at   INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at)`,
			`CREATE INDEX IF NOT EXISTS idx_audit_logs_household ON audit_logs(household_id, created_at)`,
			`CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON audit_logs(actor_type, actor_id, created_at)`,

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

			`CREATE TABLE IF NOT EXISTS work_id_links (
				kind           TEXT NOT NULL,
				provider       TEXT NOT NULL,
				external_id    TEXT NOT NULL,
				canonical_key  TEXT NOT NULL,
				implied_season INTEGER NOT NULL DEFAULT 0,
				updated_at     INTEGER NOT NULL,
				PRIMARY KEY (kind, provider, external_id)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_work_id_links_canonical ON work_id_links(canonical_key)`,

			`CREATE TABLE IF NOT EXISTS genres (
				id   INTEGER PRIMARY KEY AUTOINCREMENT,
				name TEXT NOT NULL UNIQUE
			)`,
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

			// 2. 账号、家庭、成员、设备、会话、E2EE 密钥环
			`CREATE TABLE IF NOT EXISTS accounts (
				id                   TEXT PRIMARY KEY,
				username             TEXT NOT NULL UNIQUE,
				email                TEXT UNIQUE,
				password_salt        TEXT NOT NULL,
				password_hash        TEXT NOT NULL,
				must_change_password INTEGER NOT NULL DEFAULT 0,
				status               TEXT NOT NULL DEFAULT 'active',
				delete_after         INTEGER,
				registered_ip        TEXT NOT NULL DEFAULT '',
				last_active_at       INTEGER,
				created_at           INTEGER NOT NULL,
				updated_at           INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_accounts_status ON accounts(status, delete_after)`,

			`CREATE TABLE IF NOT EXISTS households (
				id                      TEXT PRIMARY KEY,
				owner_account_id        TEXT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
				name                    TEXT NOT NULL,
				display_lang            TEXT NOT NULL DEFAULT 'zh-CN',
				quota_max_sources       INTEGER NOT NULL DEFAULT 20,
				quota_max_files         INTEGER NOT NULL DEFAULT 200000,
				quota_max_sidecar_bytes INTEGER NOT NULL DEFAULT 524288000,
				next_change_seq         INTEGER NOT NULL DEFAULT 0,
				min_retained_seq        INTEGER NOT NULL DEFAULT 0,
				created_at              INTEGER NOT NULL,
				updated_at              INTEGER NOT NULL
			)`,
			`CREATE TABLE IF NOT EXISTS household_key_wraps (
				id              TEXT PRIMARY KEY,
				household_id    TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				wrap_type       TEXT NOT NULL,
				subject_id      TEXT NOT NULL,
				kdf_alg         TEXT NOT NULL,
				kdf_salt        TEXT NOT NULL,
				kdf_params_json TEXT NOT NULL,
				wrapped_hk      TEXT NOT NULL,
				key_epoch       INTEGER NOT NULL DEFAULT 1,
				created_at      INTEGER NOT NULL,
				updated_at      INTEGER NOT NULL,
				UNIQUE (household_id, wrap_type, subject_id)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_key_wraps_subject ON household_key_wraps(wrap_type, subject_id)`,

			`CREATE TABLE IF NOT EXISTS members (
				id                 TEXT PRIMARY KEY,
				household_id       TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				nickname           TEXT NOT NULL,
				avatar             TEXT NOT NULL DEFAULT '',
				role               TEXT NOT NULL,
				permissions        INTEGER NOT NULL DEFAULT 0,
				restrict_sources   INTEGER NOT NULL DEFAULT 0,
				pin_salt           TEXT,
				pin_hash           TEXT,
				login_username     TEXT UNIQUE,
				login_pass_salt    TEXT,
				login_pass_hash    TEXT,
				max_content_rating TEXT,
				status             TEXT NOT NULL DEFAULT 'active',
				created_at         INTEGER NOT NULL,
				updated_at         INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_members_household ON members(household_id, status)`,

			`CREATE TABLE IF NOT EXISTS devices (
				id           TEXT PRIMARY KEY,
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				device_class TEXT NOT NULL,
				platform     TEXT NOT NULL DEFAULT '',
				name         TEXT NOT NULL DEFAULT '',
				app_version  TEXT NOT NULL DEFAULT '',
				last_seen_at INTEGER NOT NULL,
				created_at   INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_devices_household ON devices(household_id)`,

			`CREATE TABLE IF NOT EXISTS sessions (
				token_id     TEXT PRIMARY KEY,
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id    TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
				device_id    TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
				token_hash   TEXT NOT NULL UNIQUE,
				ip           TEXT NOT NULL DEFAULT '',
				created_at   INTEGER NOT NULL,
				last_used_at INTEGER NOT NULL,
				expires_at   INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)`,
			`CREATE INDEX IF NOT EXISTS idx_sessions_household ON sessions(household_id)`,
			`CREATE INDEX IF NOT EXISTS idx_sessions_member ON sessions(member_id)`,
			`CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id)`,

			`CREATE TABLE IF NOT EXISTS qr_login_sessions (
				qr_id            TEXT PRIMARY KEY,
				device_class     TEXT NOT NULL,
				platform         TEXT NOT NULL DEFAULT '',
				device_name      TEXT NOT NULL DEFAULT '',
				ephemeral_pubkey TEXT NOT NULL,
				status           TEXT NOT NULL DEFAULT 'pending',
				household_id     TEXT,
				member_id        TEXT,
				encrypted_hk     TEXT,
				issued_token     TEXT,
				expires_at       INTEGER NOT NULL,
				created_at       INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_qr_login_expires ON qr_login_sessions(expires_at)`,

			// 3. 媒体源、目录、E2EE 凭据、扫描状态
			`CREATE TABLE IF NOT EXISTS sources (
				id                TEXT PRIMARY KEY,
				household_id      TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				kind              TEXT NOT NULL,
				name              TEXT NOT NULL,
				identity_key      TEXT NOT NULL,
				identity_unique   INTEGER NOT NULL DEFAULT 1,
				created_by_member TEXT NOT NULL,
				created_by_device TEXT NOT NULL,
				status            TEXT NOT NULL DEFAULT 'active',
				deleted_at        INTEGER,
				created_at        INTEGER NOT NULL,
				updated_at        INTEGER NOT NULL
			)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_hh_unique_id ON sources(household_id, kind, identity_key) WHERE status = 'active' AND identity_unique = 1`,
			`CREATE INDEX IF NOT EXISTS idx_sources_hh_idkey ON sources(household_id, kind, identity_key)`,
			`CREATE INDEX IF NOT EXISTS idx_sources_hh_status ON sources(household_id, status)`,

			`CREATE TABLE IF NOT EXISTS member_source_access (
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id    TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
				source_id    TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				PRIMARY KEY (member_id, source_id)
			)`,
			`CREATE TABLE IF NOT EXISTS source_folders (
				id                 TEXT PRIMARY KEY,
				household_id       TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				source_id          TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				path               TEXT NOT NULL,
				exclude_paths_json TEXT NOT NULL DEFAULT '[]',
				library_hint       TEXT NOT NULL DEFAULT 'auto',
				baseline_at        INTEGER,
				created_at         INTEGER NOT NULL,
				updated_at         INTEGER NOT NULL,
				UNIQUE (source_id, path)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_source_folders_hh ON source_folders(household_id, source_id)`,

			`CREATE TABLE IF NOT EXISTS source_credentials (
				source_id         TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
				household_id      TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				ciphertext        TEXT NOT NULL,
				version           INTEGER NOT NULL DEFAULT 1,
				key_epoch         INTEGER NOT NULL DEFAULT 1,
				status            TEXT NOT NULL DEFAULT 'valid',
				updated_by_device TEXT NOT NULL,
				updated_at        INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_source_credentials_hh ON source_credentials(household_id)`,

			`CREATE TABLE IF NOT EXISTS source_scan_state (
				source_id             TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
				household_id          TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				incremental_watermark INTEGER NOT NULL DEFAULT 0,
				last_full_scan_at     INTEGER,
				last_scan_result      TEXT NOT NULL DEFAULT '',
				updated_at            INTEGER NOT NULL
			)`,

			// 4. 扫描会话、多租户片库、文件索引、匹配规则、识别队列与待删确认
			`CREATE TABLE IF NOT EXISTS scan_sessions (
				id               TEXT PRIMARY KEY,
				household_id     TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				source_id        TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				folder_id        TEXT REFERENCES source_folders(id) ON DELETE SET NULL,
				type             TEXT NOT NULL,
				device_id        TEXT NOT NULL,
				member_id        TEXT NOT NULL,
				started_at       INTEGER NOT NULL,
				last_activity_at INTEGER NOT NULL,
				finished_at      INTEGER,
				status           TEXT NOT NULL DEFAULT 'running',
				files_reported   INTEGER NOT NULL DEFAULT 0,
				files_added      INTEGER NOT NULL DEFAULT 0,
				files_changed    INTEGER NOT NULL DEFAULT 0,
				files_missing    INTEGER NOT NULL DEFAULT 0,
				progress_pct     INTEGER NOT NULL DEFAULT 0
			)`,
			`CREATE INDEX IF NOT EXISTS idx_scan_sessions_hh ON scan_sessions(household_id, status)`,
			`CREATE INDEX IF NOT EXISTS idx_scan_sessions_source ON scan_sessions(source_id, status)`,

			`CREATE TABLE IF NOT EXISTS ingest_batches (
				session_id    TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
				batch_no      INTEGER NOT NULL,
				response_json TEXT NOT NULL,
				created_at    INTEGER NOT NULL,
				PRIMARY KEY (session_id, batch_no)
			)`,

			`CREATE TABLE IF NOT EXISTS sidecars (
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				sha256       TEXT NOT NULL,
				kind         TEXT NOT NULL,
				content_type TEXT NOT NULL,
				size_bytes   INTEGER NOT NULL,
				storage_path TEXT NOT NULL,
				created_at   INTEGER NOT NULL,
				PRIMARY KEY (household_id, sha256)
			)`,

			`CREATE TABLE IF NOT EXISTS media_items (
				id              INTEGER PRIMARY KEY AUTOINCREMENT,
				household_id    TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
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
				douban_id       TEXT,
				anilist_id      TEXT,
				metadata_source TEXT,
				locked          INTEGER NOT NULL DEFAULT 0,
				added_at        INTEGER NOT NULL,
				source_added_at INTEGER,
				updated_at      INTEGER NOT NULL,
				scraped_at      INTEGER
			)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_media_items_hh_work_key ON media_items(household_id, work_key) WHERE work_key IS NOT NULL AND work_key != ''`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_kind_type ON media_items(household_id, kind, library_type)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_parent ON media_items(household_id, parent_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_show ON media_items(household_id, show_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_tmdb ON media_items(household_id, kind, tmdb_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_imdb ON media_items(household_id, kind, imdb_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_tvdb ON media_items(household_id, kind, tvdb_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_bangumi ON media_items(household_id, kind, bangumi_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_douban ON media_items(household_id, kind, douban_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_anilist ON media_items(household_id, kind, anilist_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_added ON media_items(household_id, COALESCE(source_added_at, added_at), id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_items_hh_sort ON media_items(household_id, sort_title)`,

			`CREATE TABLE IF NOT EXISTS media_files (
				id                 INTEGER PRIMARY KEY AUTOINCREMENT,
				household_id       TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				source_id          TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				path               TEXT NOT NULL,
				remote_id          TEXT,
				role               TEXT NOT NULL,
				item_id            INTEGER REFERENCES media_items(id) ON DELETE SET NULL,
				owner_file_id      INTEGER REFERENCES media_files(id) ON DELETE CASCADE,
				size               INTEGER,
				mtime_s            INTEGER,
				ctime_s            INTEGER,
				sidecar_sha256     TEXT,
				state              TEXT NOT NULL DEFAULT 'active',
				missing_since      INTEGER,
				match_state        TEXT NOT NULL DEFAULT 'pending',
				match_locked       INTEGER NOT NULL DEFAULT 0,
				parsed_json        TEXT,
				client_hints_json  TEXT,
				version_label      TEXT,
				language           TEXT,
				duration_ms        INTEGER,
				bitrate_kbps       INTEGER,
				container          TEXT,
				video_codec        TEXT,
				width              INTEGER,
				height             INTEGER,
				hdr_format         TEXT,
				streams_json       TEXT,
				probed_at          INTEGER,
				last_seen_at       INTEGER NOT NULL,
				reported_by_device TEXT NOT NULL DEFAULT '',
				added_at           INTEGER NOT NULL,
				updated_at         INTEGER NOT NULL
			)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_source_path ON media_files(source_id, path)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_source_remote ON media_files(source_id, remote_id) WHERE remote_id IS NOT NULL AND remote_id != ''`,
			`CREATE INDEX IF NOT EXISTS idx_media_files_hh_source_state ON media_files(household_id, source_id, state)`,
			`CREATE INDEX IF NOT EXISTS idx_media_files_item ON media_files(item_id, role)`,
			`CREATE INDEX IF NOT EXISTS idx_media_files_owner ON media_files(owner_file_id)`,
			`CREATE INDEX IF NOT EXISTS idx_media_files_hh_match ON media_files(household_id, role, match_state)`,

			`CREATE TABLE IF NOT EXISTS pending_deletions (
				id             TEXT PRIMARY KEY,
				household_id   TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				source_id      TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				session_id     TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
				scope_path     TEXT NOT NULL,
				file_count     INTEGER NOT NULL,
				total_in_scope INTEGER NOT NULL,
				status         TEXT NOT NULL DEFAULT 'pending',
				created_at     INTEGER NOT NULL,
				resolved_at    INTEGER
			)`,
			`CREATE TABLE IF NOT EXISTS pending_deletion_files (
				pending_id TEXT NOT NULL REFERENCES pending_deletions(id) ON DELETE CASCADE,
				file_id    INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
				PRIMARY KEY (pending_id, file_id)
			)`,

			`CREATE TABLE IF NOT EXISTS item_genres (
				item_id  INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
				genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
				PRIMARY KEY (item_id, genre_id)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_item_genres_genre ON item_genres(genre_id)`,

			`CREATE TABLE IF NOT EXISTS item_credits (
				item_id    INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
				person_id  INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
				job        TEXT NOT NULL,
				character  TEXT,
				sort_order INTEGER NOT NULL DEFAULT 0,
				PRIMARY KEY (item_id, person_id, job)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_item_credits_person ON item_credits(person_id)`,

			`CREATE TABLE IF NOT EXISTS match_rules (
				id              TEXT PRIMARY KEY,
				household_id    TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				source_id       TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
				path_prefix     TEXT NOT NULL,
				action          TEXT NOT NULL,
				target_provider TEXT,
				target_kind     TEXT,
				target_ext_id   TEXT,
				season_offset   INTEGER NOT NULL DEFAULT 0,
				created_by      TEXT NOT NULL,
				created_at      INTEGER NOT NULL,
				updated_at      INTEGER NOT NULL,
				UNIQUE (source_id, path_prefix)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_match_rules_hh ON match_rules(household_id, source_id)`,

			`CREATE TABLE IF NOT EXISTS identify_queue (
				id              INTEGER PRIMARY KEY AUTOINCREMENT,
				household_id    TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				group_key       TEXT NOT NULL,
				reason          TEXT NOT NULL DEFAULT 'new',
				status          TEXT NOT NULL DEFAULT 'queued',
				not_before      INTEGER NOT NULL,
				attempts        INTEGER NOT NULL DEFAULT 0,
				last_error_code TEXT NOT NULL DEFAULT '',
				created_at      INTEGER NOT NULL,
				updated_at      INTEGER NOT NULL,
				UNIQUE (household_id, group_key)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_identify_queue_ready ON identify_queue(status, not_before, household_id)`,

			// 5. 成员观看数据、列表、变更日志
			`CREATE TABLE IF NOT EXISTS member_watch_progress (
				household_id         TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id            TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
				progress_key         TEXT NOT NULL,
				work_key             TEXT,
				season_number        INTEGER NOT NULL DEFAULT -1,
				episode_number       INTEGER NOT NULL DEFAULT -1,
				last_file_id         INTEGER,
				position_ms          INTEGER NOT NULL DEFAULT 0,
				duration_ms          INTEGER,
				watched              INTEGER NOT NULL DEFAULT 0,
				play_count           INTEGER NOT NULL DEFAULT 0,
				last_played_at       INTEGER,
				hidden_from_continue INTEGER NOT NULL DEFAULT 0,
				updated_at           INTEGER NOT NULL,
				PRIMARY KEY (member_id, progress_key)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_mwp_hh_member_played ON member_watch_progress(household_id, member_id, last_played_at)`,
			`CREATE INDEX IF NOT EXISTS idx_mwp_hh_work ON member_watch_progress(household_id, member_id, work_key)`,

			`CREATE TABLE IF NOT EXISTS member_favorites (
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id    TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
				work_key     TEXT NOT NULL,
				created_at   INTEGER NOT NULL,
				PRIMARY KEY (member_id, work_key)
			)`,

			`CREATE TABLE IF NOT EXISTS household_work_prefs (
				household_id        TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				work_key            TEXT NOT NULL,
				intro_enabled       INTEGER NOT NULL DEFAULT 0,
				intro_start_ms      INTEGER NOT NULL DEFAULT 0,
				intro_end_ms        INTEGER NOT NULL DEFAULT 0,
				credits_enabled     INTEGER NOT NULL DEFAULT 0,
				credits_from_end_ms INTEGER NOT NULL DEFAULT 0,
				keep_easter_egg_ms  INTEGER NOT NULL DEFAULT 0,
				updated_at          INTEGER NOT NULL,
				PRIMARY KEY (household_id, work_key)
			)`,

			`CREATE TABLE IF NOT EXISTS member_work_prefs (
				household_id         TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id            TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
				work_key             TEXT NOT NULL,
				preferred_audio_lang TEXT,
				preferred_sub_lang   TEXT,
				playback_speed       REAL NOT NULL DEFAULT 1.0,
				updated_at           INTEGER NOT NULL,
				PRIMARY KEY (member_id, work_key)
			)`,

			`CREATE TABLE IF NOT EXISTS lists (
				id            TEXT PRIMARY KEY,
				household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				member_id     TEXT REFERENCES members(id) ON DELETE CASCADE,
				kind          TEXT NOT NULL,
				title         TEXT NOT NULL,
				summary       TEXT,
				poster_source TEXT,
				tmdb_id       TEXT,
				created_at    INTEGER NOT NULL,
				updated_at    INTEGER NOT NULL
			)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_hh_tmdb ON lists(household_id, kind, tmdb_id) WHERE tmdb_id IS NOT NULL AND tmdb_id != ''`,
			`CREATE INDEX IF NOT EXISTS idx_lists_hh_member ON lists(household_id, member_id, kind)`,

			`CREATE TABLE IF NOT EXISTS list_entries (
				list_id        TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
				entry_key      TEXT NOT NULL,
				work_key       TEXT NOT NULL,
				season_number  INTEGER NOT NULL DEFAULT -1,
				episode_number INTEGER NOT NULL DEFAULT -1,
				sort_order     INTEGER NOT NULL DEFAULT 0,
				added_at       INTEGER NOT NULL,
				PRIMARY KEY (list_id, entry_key)
			)`,

			`CREATE TABLE IF NOT EXISTS change_log (
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				seq          INTEGER NOT NULL,
				member_id    TEXT,
				entity       TEXT NOT NULL,
				entity_id    TEXT NOT NULL,
				op           TEXT NOT NULL,
				created_at   INTEGER NOT NULL,
				PRIMARY KEY (household_id, seq)
			)`,
			`CREATE INDEX IF NOT EXISTS idx_change_log_hh_member_seq ON change_log(household_id, member_id, seq)`,
		},
	},
	{
		Version: 2,
		Name:    "0002_s1_auth_and_recovery",
		Statements: []string{
			`ALTER TABLE sessions ADD COLUMN login_mode TEXT NOT NULL DEFAULT 'household'`,
			`ALTER TABLE accounts ADD COLUMN recovery_salt TEXT NOT NULL DEFAULT ''`,
			`ALTER TABLE accounts ADD COLUMN recovery_hash TEXT NOT NULL DEFAULT ''`,
			`ALTER TABLE qr_login_sessions ADD COLUMN poll_secret_hash TEXT NOT NULL DEFAULT ''`,
			`CREATE TABLE IF NOT EXISTS account_login_tickets (
				ticket_hash  TEXT PRIMARY KEY,
				account_id   TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
				household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
				device_class TEXT NOT NULL,
				platform     TEXT NOT NULL DEFAULT '',
				device_name  TEXT NOT NULL DEFAULT '',
				app_version  TEXT NOT NULL DEFAULT '',
				ip           TEXT NOT NULL DEFAULT '',
				expires_at   INTEGER NOT NULL,
				created_at   INTEGER NOT NULL
			)`,
			`CREATE INDEX IF NOT EXISTS idx_account_login_tickets_expires ON account_login_tickets(expires_at)`,
		},
	},
}

func (s *Store) runMigrations() error {
	if _, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version    INTEGER PRIMARY KEY,
		name       TEXT NOT NULL,
		applied_at INTEGER NOT NULL
	)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	applied := make(map[int]bool)
	rows, err := s.db.Query(`SELECT version FROM schema_migrations`)
	if err != nil {
		return fmt.Errorf("query schema_migrations: %w", err)
	}
	for rows.Next() {
		var v int
		if scanErr := rows.Scan(&v); scanErr != nil {
			_ = rows.Close()
			return fmt.Errorf("scan schema_migrations: %w", scanErr)
		}
		applied[v] = true
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return fmt.Errorf("iterate schema_migrations: %w", err)
	}
	_ = rows.Close()

	ordered := make([]Migration, len(migrations))
	copy(ordered, migrations)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Version < ordered[j].Version })

	for _, m := range ordered {
		if applied[m.Version] {
			continue
		}
		tx, err := s.db.Begin()
		if err != nil {
			return fmt.Errorf("begin migration %d (%s): %w", m.Version, m.Name, err)
		}
		for _, stmt := range m.Statements {
			if _, err := tx.Exec(stmt); err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("migration %d (%s): %w", m.Version, m.Name, err)
			}
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(version, name, applied_at) VALUES (?, ?, ?)`, m.Version, m.Name, s.NowMs()); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("record migration %d (%s): %w", m.Version, m.Name, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit migration %d (%s): %w", m.Version, m.Name, err)
		}
	}
	return nil
}

// SchemaVersion returns the highest applied migration version, or 0 if none.
func (s *Store) SchemaVersion() (int, error) {
	var v int
	if err := s.ReadDB().QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&v); err != nil {
		return 0, err
	}
	return v, nil
}
