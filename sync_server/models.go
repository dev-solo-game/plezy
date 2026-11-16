package main

import "encoding/json"

type KdfParams struct {
	Algo string `json:"algo"`
	M    int    `json:"m"`
	T    int    `json:"t"`
	P    int    `json:"p"`
}

type UserRecord struct {
	UserID                   string         `json:"user_id"`
	Username                 string         `json:"username"`
	AuthSalt                 string         `json:"auth_salt"`
	AuthHash                 string         `json:"auth_hash"`
	KdfSalt                  string         `json:"kdf_salt"`
	KdfParams                KdfParams      `json:"kdf_params"`
	EncryptedMasterKeyBackup string         `json:"encrypted_master_key_backup"`
	Settings                 map[string]any `json:"settings"`
	CreatedAt                int64          `json:"created_at"`
	UpdatedAt                int64          `json:"updated_at"`
}

type SyncSource struct {
	SourceID          string         `json:"source_id"`
	CanonicalKey      string         `json:"canonical_key"`
	Name              string         `json:"name"`
	Protocol          string         `json:"protocol"`
	IsLanOnly         bool           `json:"is_lan_only"`
	PrimaryURL        string         `json:"primary_url"`
	FallbackURL       *string        `json:"fallback_url,omitempty"`
	ConfigJSON        map[string]any `json:"config_json,omitempty"`
	IncludePaths      []string       `json:"include_paths"`
	ExcludePaths      []string       `json:"exclude_paths"`
	EncryptedAuth     string         `json:"encrypted_auth"`
	AuthUpdatedAt     int64          `json:"auth_updated_at"`
	ForceAuthOverride bool           `json:"force_auth_override,omitempty"`
	QuarkCheckpoint   *string        `json:"quark_checkpoint,omitempty"`
	ScanLeaseOwner    *string        `json:"scan_lease_owner,omitempty"`
	ScanLeaseUntil    int64          `json:"scan_lease_until,omitempty"`
	ClientUpdatedAt   int64          `json:"client_updated_at"`
	IsDeleted         bool           `json:"is_deleted"`
	ServerSeq         int64          `json:"server_seq"`
}

type SyncWork struct {
	WorkKey         string         `json:"work_key"`
	Kind            string         `json:"kind"`
	LibraryType     string         `json:"library_type"`
	Provider        *string        `json:"provider,omitempty"`
	ExternalID      *string        `json:"external_id,omitempty"`
	MatchStatus     int            `json:"match_status"`
	MetadataJSON    map[string]any `json:"metadata_json"`
	ClientUpdatedAt int64          `json:"client_updated_at"`
	ExplicitUnlock  bool           `json:"explicit_unlock,omitempty"`
	IsDeleted       bool           `json:"is_deleted"`
	ServerSeq       int64          `json:"server_seq"`
}

type SyncFile struct {
	FileID          string         `json:"file_id"`
	SourceID        string         `json:"source_id"`
	RelativePath    string         `json:"relative_path"`
	RemoteID        *string        `json:"remote_id,omitempty"`
	Role            string         `json:"role"`
	OwnerFileID     *string        `json:"owner_file_id,omitempty"`
	Language        *string        `json:"language,omitempty"`
	FileName        string         `json:"file_name"`
	FileSize        int64          `json:"file_size"`
	FileMtime       int64          `json:"file_mtime"`
	FileCreatedAt   int64          `json:"file_created_at,omitempty"`
	WorkKey         *string        `json:"work_key,omitempty"`
	SeasonNum       int            `json:"season_num"`
	EpisodeNum      int            `json:"episode_num"`
	EpisodeEndNum   *int           `json:"episode_end_num,omitempty"`
	MatchStatus     int            `json:"match_status"`
	VersionLabel    *string        `json:"version_label,omitempty"`
	ParsedJSON      *string        `json:"parsed_json,omitempty"`
	MediaSpecJSON   map[string]any `json:"media_spec_json"`
	ClientUpdatedAt int64          `json:"client_updated_at"`
	ExplicitUnlock  bool           `json:"explicit_unlock,omitempty"`
	IsDeleted       bool           `json:"is_deleted"`
	ServerSeq       int64          `json:"server_seq"`
}

type SyncWorkPref struct {
	WorkKey            string  `json:"work_key"`
	IntroEnabled       bool    `json:"intro_enabled"`
	IntroStartMs       int     `json:"intro_start_ms"`
	IntroEndMs         int     `json:"intro_end_ms"`
	CreditsEnabled     bool    `json:"credits_enabled"`
	CreditsFromEndMs   int     `json:"credits_from_end_ms"`
	KeepEasterEggMs    int     `json:"keep_easter_egg_ms"`
	PreferredAudioLang *string `json:"preferred_audio_lang,omitempty"`
	PreferredSubLang   *string `json:"preferred_sub_lang,omitempty"`
	PlaybackSpeed      float64 `json:"playback_speed"`
	DanmakuOffsetMs    int     `json:"danmaku_offset_ms"`
	IsFavorite         bool    `json:"is_favorite"`
	HiddenFromContinue bool    `json:"hidden_from_continue"`
	ClientUpdatedAt    int64   `json:"client_updated_at"`
	ServerSeq          int64   `json:"server_seq"`
}

type SyncWatchProgress struct {
	ProgressKey     string         `json:"progress_key"`
	WorkKey         string         `json:"work_key"`
	SeasonNum       int            `json:"season_num"`
	EpisodeNum      int            `json:"episode_num"`
	LastFileID      *string        `json:"last_file_id,omitempty"`
	PositionMs      int64          `json:"position_ms"`
	DurationMs      int64          `json:"duration_ms"`
	Watched         bool           `json:"watched"`
	PlayCount       int            `json:"play_count"`
	LastPlayedAt    *int64         `json:"last_played_at,omitempty"`
	EpisodeExtJSON  map[string]any `json:"episode_ext_json"`
	ClientUpdatedAt int64          `json:"client_updated_at"`
	ServerSeq       int64          `json:"server_seq"`
}

type AppliedOp struct {
	OpID      string `json:"op_id"`
	ServerSeq int64  `json:"server_seq"`
	CreatedAt int64  `json:"created_at"`
}

type QrSession struct {
	SessionID       string `json:"session_id"`
	TvPubKey        string `json:"tv_pub_key"`
	DeviceName      string `json:"device_name"`
	Status          string `json:"status"` // "pending" | "confirmed"
	UserID          string `json:"user_id,omitempty"`
	Username        string `json:"username,omitempty"`
	AccessToken     string `json:"access_token,omitempty"`
	SealedMasterKey string `json:"sealed_master_key,omitempty"`
	ExpiresAtMs     int64  `json:"expires_at_ms"`
}

type RegisterRequest struct {
	Username                 string         `json:"username"`
	AuthVerifier             string         `json:"auth_verifier"`
	KdfSalt                  string         `json:"kdf_salt"`
	KdfParams                KdfParams      `json:"kdf_params"`
	EncryptedMasterKeyBackup string         `json:"encrypted_master_key_backup"`
	Settings                 map[string]any `json:"settings"`
	DeviceID                 string         `json:"device_id"`
}

type LoginRequest struct {
	Username     string `json:"username"`
	AuthVerifier string `json:"auth_verifier"`
	DeviceID     string `json:"device_id"`
}

type AuthResponse struct {
	Code                     int            `json:"code"`
	UserID                   string         `json:"user_id"`
	Username                 string         `json:"username"`
	AccessToken              string         `json:"access_token"`
	KdfSalt                  string         `json:"kdf_salt,omitempty"`
	KdfParams                KdfParams      `json:"kdf_params"`
	EncryptedMasterKeyBackup string         `json:"encrypted_master_key_backup,omitempty"`
	Settings                 map[string]any `json:"settings"`
	ServerTimeMs             int64          `json:"server_time_ms"`
}

type QrCreateRequest struct {
	TvPubKey   string `json:"tv_pub_key"`
	DeviceName string `json:"device_name"`
}

type QrCreateResponse struct {
	Code        int    `json:"code"`
	SessionID   string `json:"session_id"`
	ExpiresAtMs int64  `json:"expires_at_ms"`
}

type QrConfirmRequest struct {
	SessionID       string `json:"session_id"`
	SealedMasterKey string `json:"sealed_master_key"`
	DeviceID        string `json:"device_id"`
}

type QrPollResponse struct {
	Code            int            `json:"code"`
	Status          string         `json:"status"`
	ExpiresAtMs     int64          `json:"expires_at_ms"`
	UserID          string         `json:"user_id,omitempty"`
	Username        string         `json:"username,omitempty"`
	AccessToken     string         `json:"access_token,omitempty"`
	SealedMasterKey string         `json:"sealed_master_key,omitempty"`
	Settings        map[string]any `json:"settings,omitempty"`
	ServerTimeMs    int64          `json:"server_time_ms"`
}

type PushMutation struct {
	OpID       string          `json:"op_id"`
	EntityType string          `json:"entity_type"`
	EntityKey  string          `json:"entity_key"`
	Payload    json.RawMessage `json:"payload"`
}

type PushRequest struct {
	DeviceID  string         `json:"device_id"`
	Mutations []PushMutation `json:"mutations"`
}

type PushResponse struct {
	Code           int               `json:"code"`
	ServerTimeMs   int64             `json:"server_time_ms"`
	AcceptedOpIDs  []string          `json:"accepted_op_ids"`
	RemappedSources map[string]string `json:"remapped_sources,omitempty"`
}

type PullData struct {
	Sources       []SyncSource        `json:"sources"`
	Works         []SyncWork          `json:"works"`
	Files         []SyncFile          `json:"files"`
	WorkPrefs     []SyncWorkPref      `json:"work_prefs"`
	WatchProgress []SyncWatchProgress `json:"watch_progress"`
}

type PullResponse struct {
	Code          int            `json:"code"`
	ServerTimeMs  int64          `json:"server_time_ms"`
	CurrentMaxSeq int64          `json:"current_max_seq"`
	NextSeq       int64          `json:"next_seq"`
	HasMore       bool           `json:"has_more"`
	ResetRequired bool           `json:"reset_required"`
	UserSettings  map[string]any `json:"user_settings"`
	Data          PullData       `json:"data"`
}

type LeaseRequest struct {
	SourceID string `json:"source_id"`
	DeviceID string `json:"device_id"`
	TtlSec   int    `json:"ttl_sec"`
}

type LeaseResponse struct {
	Code           int    `json:"code"`
	Acquired       bool   `json:"acquired"`
	HolderDeviceID string `json:"holder_device_id,omitempty"`
	ExpiresAtMs    int64  `json:"expires_at_ms"`
}
