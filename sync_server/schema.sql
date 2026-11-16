-- Plezy Lightweight Multi-Device Sync Schema (Reference PostgreSQL / SQLite DDL)

CREATE TABLE IF NOT EXISTS users (
    user_id                     VARCHAR(64)  PRIMARY KEY,
    username                    VARCHAR(128) NOT NULL UNIQUE,
    password_hash               TEXT         NOT NULL,
    kdf_salt                    VARCHAR(64)  NOT NULL,
    kdf_params_json             TEXT         NOT NULL,
    encrypted_master_key_backup TEXT         NOT NULL,
    settings_json               TEXT         NOT NULL DEFAULT '{}',
    created_at                  BIGINT       NOT NULL,
    updated_at                  BIGINT       NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_sources (
    user_id           VARCHAR(64)  NOT NULL,
    source_id         VARCHAR(64)  NOT NULL,
    canonical_key     VARCHAR(512) NOT NULL,
    name              VARCHAR(128) NOT NULL,
    protocol          VARCHAR(32)  NOT NULL,
    is_lan_only       BOOLEAN      NOT NULL DEFAULT FALSE,
    primary_url       VARCHAR(512) NOT NULL,
    fallback_url      VARCHAR(512) DEFAULT NULL,
    config_json       TEXT         NOT NULL DEFAULT '{}',
    include_paths     TEXT         NOT NULL DEFAULT '[]',
    exclude_paths     TEXT         NOT NULL DEFAULT '[]',
    encrypted_auth    TEXT         NOT NULL,
    auth_updated_at   BIGINT       NOT NULL DEFAULT 0,
    quark_checkpoint  VARCHAR(128) DEFAULT NULL,
    scan_lease_owner  VARCHAR(64)  DEFAULT NULL,
    scan_lease_until  BIGINT       NOT NULL DEFAULT 0,
    client_updated_at BIGINT       NOT NULL DEFAULT 0,
    is_deleted        BOOLEAN      NOT NULL DEFAULT FALSE,
    server_seq        BIGINT       NOT NULL,
    PRIMARY KEY (user_id, source_id)
);
CREATE INDEX IF NOT EXISTS idx_sources_user_seq ON sync_sources (user_id, server_seq);

CREATE TABLE IF NOT EXISTS sync_works (
    user_id           VARCHAR(64)  NOT NULL,
    work_key          VARCHAR(128) NOT NULL,
    kind              VARCHAR(16)  NOT NULL,
    library_type      VARCHAR(32)  NOT NULL,
    provider          VARCHAR(32)  DEFAULT NULL,
    external_id       VARCHAR(64)  DEFAULT NULL,
    match_status      SMALLINT     NOT NULL DEFAULT 1,
    metadata_json     TEXT         NOT NULL DEFAULT '{}',
    client_updated_at BIGINT       NOT NULL DEFAULT 0,
    is_deleted        BOOLEAN      NOT NULL DEFAULT FALSE,
    server_seq        BIGINT       NOT NULL,
    PRIMARY KEY (user_id, work_key)
);
CREATE INDEX IF NOT EXISTS idx_works_user_seq ON sync_works (user_id, server_seq);

CREATE TABLE IF NOT EXISTS sync_files (
    user_id           VARCHAR(64)  NOT NULL,
    file_id           VARCHAR(32)  NOT NULL,
    source_id         VARCHAR(64)  NOT NULL,
    relative_path     TEXT         NOT NULL,
    remote_id         VARCHAR(128) DEFAULT NULL,
    role              VARCHAR(16)  NOT NULL DEFAULT 'video',
    owner_file_id     VARCHAR(32)  DEFAULT NULL,
    language          VARCHAR(32)  DEFAULT NULL,
    file_name         VARCHAR(512) NOT NULL,
    file_size         BIGINT       NOT NULL DEFAULT 0,
    file_mtime        BIGINT       NOT NULL DEFAULT 0,
    file_created_at   BIGINT       NOT NULL DEFAULT 0,
    work_key          VARCHAR(128) DEFAULT NULL,
    season_num        SMALLINT     NOT NULL DEFAULT -1,
    episode_num       SMALLINT     NOT NULL DEFAULT -1,
    episode_end_num   SMALLINT     DEFAULT NULL,
    match_status      SMALLINT     NOT NULL DEFAULT 1,
    version_label     VARCHAR(64)  DEFAULT NULL,
    parsed_json       TEXT         DEFAULT NULL,
    media_spec_json   TEXT         NOT NULL DEFAULT '{}',
    client_updated_at BIGINT       NOT NULL DEFAULT 0,
    is_deleted        BOOLEAN      NOT NULL DEFAULT FALSE,
    server_seq        BIGINT       NOT NULL,
    PRIMARY KEY (user_id, file_id)
);
CREATE INDEX IF NOT EXISTS idx_files_user_seq ON sync_files (user_id, server_seq);
CREATE INDEX IF NOT EXISTS idx_files_work ON sync_files (user_id, work_key);

CREATE TABLE IF NOT EXISTS sync_work_prefs (
    user_id              VARCHAR(64)  NOT NULL,
    work_key             VARCHAR(128) NOT NULL,
    intro_enabled        BOOLEAN      NOT NULL DEFAULT FALSE,
    intro_start_ms       INTEGER      NOT NULL DEFAULT 0,
    intro_end_ms         INTEGER      NOT NULL DEFAULT 0,
    credits_enabled      BOOLEAN      NOT NULL DEFAULT FALSE,
    credits_from_end_ms  INTEGER      NOT NULL DEFAULT 0,
    keep_easter_egg_ms   INTEGER      NOT NULL DEFAULT 0,
    preferred_audio_lang VARCHAR(16)  DEFAULT NULL,
    preferred_sub_lang   VARCHAR(16)  DEFAULT NULL,
    playback_speed       REAL         NOT NULL DEFAULT 1.0,
    danmaku_offset_ms    INTEGER      NOT NULL DEFAULT 0,
    is_favorite          BOOLEAN      NOT NULL DEFAULT FALSE,
    hidden_from_continue BOOLEAN      NOT NULL DEFAULT FALSE,
    client_updated_at    BIGINT       NOT NULL DEFAULT 0,
    server_seq           BIGINT       NOT NULL,
    PRIMARY KEY (user_id, work_key)
);
CREATE INDEX IF NOT EXISTS idx_work_prefs_user_seq ON sync_work_prefs (user_id, server_seq);

CREATE TABLE IF NOT EXISTS sync_watch_progress (
    user_id           VARCHAR(64)  NOT NULL,
    progress_key      VARCHAR(160) NOT NULL,
    work_key          VARCHAR(128) NOT NULL,
    season_num        SMALLINT     NOT NULL DEFAULT -1,
    episode_num       SMALLINT     NOT NULL DEFAULT -1,
    last_file_id      VARCHAR(32)  DEFAULT NULL,
    position_ms       BIGINT       NOT NULL DEFAULT 0,
    duration_ms       BIGINT       NOT NULL DEFAULT 0,
    watched           BOOLEAN      NOT NULL DEFAULT FALSE,
    play_count        INTEGER      NOT NULL DEFAULT 0,
    last_played_at    BIGINT       DEFAULT NULL,
    episode_ext_json  TEXT         NOT NULL DEFAULT '{}',
    client_updated_at BIGINT       NOT NULL DEFAULT 0,
    server_seq        BIGINT       NOT NULL,
    PRIMARY KEY (user_id, progress_key)
);
CREATE INDEX IF NOT EXISTS idx_progress_user_seq ON sync_watch_progress (user_id, server_seq);

CREATE TABLE IF NOT EXISTS sync_applied_ops (
    user_id    VARCHAR(64) NOT NULL,
    op_id      VARCHAR(64) NOT NULL,
    server_seq BIGINT      NOT NULL,
    created_at BIGINT      NOT NULL,
    PRIMARY KEY (user_id, op_id)
);
