package db

const (
	KindMovie   = "movie"
	KindShow    = "show"
	KindSeason  = "season"
	KindEpisode = "episode"

	ShelfMovie       = "movie"
	ShelfShow        = "show"
	ShelfAnime       = "anime"
	ShelfVariety     = "variety"
	ShelfDocumentary = "documentary"
	ShelfPending     = "pending"

	FileRoleVideo    = "video"
	FileRoleSubtitle = "subtitle"
	FileRoleArtwork  = "artwork"
	FileRoleNfo      = "nfo"

	MatchPending   = "pending"
	MatchMatched   = "matched"
	MatchUnmatched = "unmatched"
	MatchIgnored   = "ignored"

	ListCollection = "collection"
	ListPlaylist   = "playlist"
)

var AllShelves = []string{
	ShelfMovie,
	ShelfShow,
	ShelfAnime,
	ShelfVariety,
	ShelfDocumentary,
}

type AdminAccount struct {
	Username     string `json:"username"`
	PasswordSalt string `json:"-"`
	PasswordHash string `json:"-"`
	CreatedAt    int64  `json:"created_at"`
	UpdatedAt    int64  `json:"updated_at"`
}

type SessionRecord struct {
	TokenID    string `json:"token_id"`
	TokenHash  string `json:"-"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
	IP         string `json:"ip"`
	CreatedAt  int64  `json:"created_at"`
	LastUsedAt int64  `json:"last_used_at"`
	ExpiresAt  int64  `json:"expires_at"`
	Current    bool   `json:"current,omitempty"`
}

type ServerSettings struct {
	ServerName              string  `json:"server_name"`
	TmdbAPIKeySet           bool    `json:"tmdb_api_key_set"`
	TmdbAPIKeyMasked        string  `json:"tmdb_api_key_masked"`
	TmdbAPIKey              string  `json:"-"`
	TmdbAPIBase             string  `json:"tmdb_api_base"`
	TmdbImageBase           string  `json:"tmdb_image_base"`
	MetadataProxy           string  `json:"metadata_proxy"`
	BangumiEnabled          bool    `json:"bangumi_enabled"`
	BangumiAPIBase          string  `json:"bangumi_api_base"`
	ProxyImages             bool    `json:"proxy_images"`
	ScraperLang             string  `json:"scraper_lang"`
	PreferNfo               bool    `json:"prefer_nfo"`
	WatchedThreshold        float64 `json:"watched_threshold"`
	ScanIntervalMin         int     `json:"scan_interval_min"`
	WatchLocalFS            bool    `json:"watch_local_fs"`
	WebPreferCloudTranscode bool    `json:"web_prefer_cloud_transcode"`
	AccentTheme             string  `json:"accent_theme"`
}

type ServerSettingsUpdate struct {
	ServerName              *string  `json:"server_name,omitempty"`
	TmdbAPIKey              *string  `json:"tmdb_api_key,omitempty"`
	ClearTmdbAPIKey         bool     `json:"clear_tmdb_api_key,omitempty"`
	TmdbAPIBase             *string  `json:"tmdb_api_base,omitempty"`
	TmdbImageBase           *string  `json:"tmdb_image_base,omitempty"`
	MetadataProxy           *string  `json:"metadata_proxy,omitempty"`
	BangumiEnabled          *bool    `json:"bangumi_enabled,omitempty"`
	BangumiAPIBase          *string  `json:"bangumi_api_base,omitempty"`
	ProxyImages             *bool    `json:"proxy_images,omitempty"`
	ScraperLang             *string  `json:"scraper_lang,omitempty"`
	PreferNfo               *bool    `json:"prefer_nfo,omitempty"`
	WatchedThreshold        *float64 `json:"watched_threshold,omitempty"`
	ScanIntervalMin         *int     `json:"scan_interval_min,omitempty"`
	WatchLocalFS            *bool    `json:"watch_local_fs,omitempty"`
	WebPreferCloudTranscode *bool    `json:"web_prefer_cloud_transcode,omitempty"`
	AccentTheme             *string  `json:"accent_theme,omitempty"`
}

type MountRecord struct {
	ID               string            `json:"id"`
	Name             string            `json:"name"`
	Kind             string            `json:"kind"` // local | smb | webdav | quark
	Config           map[string]any    `json:"config"`
	Secrets          map[string]string `json:"-"`
	HasSecret        bool              `json:"has_secret"`
	Enabled          bool              `json:"enabled"`
	CreatedAt        int64             `json:"created_at"`
	UpdatedAt        int64             `json:"updated_at"`
	ScanState        *MountScanState   `json:"scan_state,omitempty"`
	VideoCount       int64             `json:"video_count"`
	TotalFileBytes   int64             `json:"total_file_bytes"`
	MatchedItemCount int64             `json:"matched_item_count"`
}

type MountScanState struct {
	MountID         string  `json:"mount_id"`
	ScanID          int64   `json:"scan_id"`
	Status          string  `json:"status"` // idle | running | failed
	PendingJSON     *string `json:"-"`
	QuarkCheckpoint *string `json:"quark_checkpoint,omitempty"`
	StartedAt       *int64  `json:"started_at,omitempty"`
	FinishedAt      *int64  `json:"finished_at,omitempty"`
	LastError       *string `json:"last_error,omitempty"`
}

type MediaItem struct {
	ID             int64       `json:"id"`
	WorkKey        *string     `json:"work_key,omitempty"`
	Kind           string      `json:"kind"`
	LibraryType    string      `json:"library_type"`
	ParentID       *int64      `json:"parent_id,omitempty"`
	ShowID         *int64      `json:"show_id,omitempty"`
	Title          string      `json:"title"`
	SortTitle      string      `json:"sort_title"`
	OriginalTitle  *string     `json:"original_title,omitempty"`
	Aliases        *string     `json:"aliases,omitempty"`
	Year           *int        `json:"year,omitempty"`
	ReleaseDate    *string     `json:"release_date,omitempty"`
	Summary        *string     `json:"summary,omitempty"`
	Tagline        *string     `json:"tagline,omitempty"`
	ContentRating  *string     `json:"content_rating,omitempty"`
	Studio         *string     `json:"studio,omitempty"`
	Rating         *float64    `json:"rating,omitempty"`
	RuntimeMs      *int64      `json:"runtime_ms,omitempty"`
	SeasonNumber   *int        `json:"season_number,omitempty"`
	EpisodeNumber  *int        `json:"episode_number,omitempty"`
	AbsoluteNumber *int        `json:"absolute_number,omitempty"`
	PosterSource   *string     `json:"poster_source,omitempty"`
	BackdropSource *string     `json:"backdrop_source,omitempty"`
	LogoSource     *string     `json:"logo_source,omitempty"`
	TmdbID         *string     `json:"tmdb_id,omitempty"`
	ImdbID         *string     `json:"imdb_id,omitempty"`
	TvdbID         *string     `json:"tvdb_id,omitempty"`
	BangumiID      *string     `json:"bangumi_id,omitempty"`
	MetadataSource *string     `json:"metadata_source,omitempty"`
	Locked         bool        `json:"locked"`
	AddedAt        int64       `json:"added_at"`
	SourceAddedAt  *int64      `json:"source_added_at,omitempty"`
	UpdatedAt      int64       `json:"updated_at"`
	ScrapedAt      *int64      `json:"scraped_at,omitempty"`
	WatchState     *WatchState `json:"watch_state,omitempty"`
	ShowTitle      *string     `json:"show_title,omitempty"`
	ShowPoster     *string     `json:"show_poster,omitempty"`
	ShowBackdrop   *string     `json:"show_backdrop,omitempty"`
	EpisodeCount   int         `json:"episode_count,omitempty"`
	WatchedEpCount int         `json:"watched_episode_count,omitempty"`
	QualityBadge   string      `json:"quality_badge,omitempty"`
	HdrBadge       string      `json:"hdr_badge,omitempty"`
	SourceKinds    []string    `json:"source_kinds,omitempty"`
}

type ProbedStream struct {
	Kind       string   `json:"kind"` // video | audio | subtitle
	Index      int      `json:"index"`
	Codec      string   `json:"codec,omitempty"`
	Language   string   `json:"language,omitempty"`
	Title      string   `json:"title,omitempty"`
	Default    bool     `json:"default,omitempty"`
	Forced     bool     `json:"forced,omitempty"`
	Width      int      `json:"width,omitempty"`
	Height     int      `json:"height,omitempty"`
	FrameRate  float64  `json:"frame_rate,omitempty"`
	HDR        string   `json:"hdr,omitempty"`
	Channels   int      `json:"channels,omitempty"`
	SampleRate int      `json:"sample_rate,omitempty"`
	BitDepth   int      `json:"bit_depth,omitempty"`
	Extra      []string `json:"-"`
}

type MediaFile struct {
	ID              int64          `json:"id"`
	MountID         string         `json:"mount_id"`
	MountName       string         `json:"mount_name,omitempty"`
	MountKind       string         `json:"mount_kind,omitempty"`
	Path            string         `json:"path"`
	FileName        string         `json:"file_name,omitempty"`
	RemoteID        *string        `json:"remote_id,omitempty"`
	Role            string         `json:"role"`
	ItemID          *int64         `json:"item_id,omitempty"`
	OwnerFileID     *int64         `json:"owner_file_id,omitempty"`
	Size            *int64         `json:"size,omitempty"`
	ModifiedAt      *int64         `json:"modified_at,omitempty"`
	SourceCreatedAt *int64         `json:"source_created_at,omitempty"`
	MatchState      string         `json:"match_state"`
	MatchLocked     bool           `json:"match_locked"`
	ParsedJSON      *string        `json:"parsed_json,omitempty"`
	VersionLabel    *string        `json:"version_label,omitempty"`
	Language        *string        `json:"language,omitempty"`
	DurationMs      *int64         `json:"duration_ms,omitempty"`
	BitrateKbps     *int           `json:"bitrate_kbps,omitempty"`
	Container       *string        `json:"container,omitempty"`
	VideoCodec      *string        `json:"video_codec,omitempty"`
	Width           *int           `json:"width,omitempty"`
	Height          *int           `json:"height,omitempty"`
	HdrFormat       *string        `json:"hdr_format,omitempty"`
	Streams         []ProbedStream `json:"streams,omitempty"`
	StreamsJSON     *string        `json:"-"`
	ProbedAt        *int64         `json:"probed_at,omitempty"`
	SeenInScan      int64          `json:"seen_in_scan"`
	AddedAt         int64          `json:"added_at"`
}

type WatchState struct {
	ItemID             int64  `json:"item_id"`
	WorkKey            string `json:"work_key,omitempty"`
	LastFileID         *int64 `json:"last_file_id,omitempty"`
	PositionMs         int64  `json:"position_ms"`
	DurationMs         *int64 `json:"duration_ms,omitempty"`
	Watched            bool   `json:"watched"`
	PlayCount          int    `json:"play_count"`
	LastPlayedAt       *int64 `json:"last_played_at,omitempty"`
	Favorite           bool   `json:"favorite"`
	HiddenFromContinue bool   `json:"hidden_from_continue"`
	UpdatedAt          int64  `json:"updated_at"`
}

type WorkPrefs struct {
	WorkKey            string  `json:"work_key"`
	IntroEnabled       bool    `json:"intro_enabled"`
	IntroStartMs       int64   `json:"intro_start_ms"`
	IntroEndMs         int64   `json:"intro_end_ms"`
	CreditsEnabled     bool    `json:"credits_enabled"`
	CreditsFromEndMs   int64   `json:"credits_from_end_ms"`
	KeepEasterEggMs    int64   `json:"keep_easter_egg_ms"`
	PreferredAudioLang string  `json:"preferred_audio_lang,omitempty"`
	PreferredSubLang   string  `json:"preferred_sub_lang,omitempty"`
	PlaybackSpeed      float64 `json:"playback_speed"`
	UpdatedAt          int64   `json:"updated_at"`
}

type Genre struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Count int    `json:"count,omitempty"`
}

type Person struct {
	ID           int64   `json:"id"`
	Name         string  `json:"name"`
	Provider     string  `json:"provider,omitempty"`
	ExternalID   *string `json:"external_id,omitempty"`
	PhotoSource  *string `json:"photo_source,omitempty"`
	Biography    *string `json:"biography,omitempty"`
	Birthday     *string `json:"birthday,omitempty"`
	Department   *string `json:"department,omitempty"`
	PlaceOfBirth *string `json:"place_of_birth,omitempty"`
}

type Credit struct {
	Person    Person  `json:"person"`
	Job       string  `json:"job"` // actor | director | writer
	Character *string `json:"character,omitempty"`
	SortOrder int     `json:"sort_order"`
}

type MediaList struct {
	ID           int64       `json:"id"`
	Kind         string      `json:"kind"` // collection | playlist
	Title        string      `json:"title"`
	Summary      *string     `json:"summary,omitempty"`
	PosterSource *string     `json:"poster_source,omitempty"`
	TmdbID       *string     `json:"tmdb_id,omitempty"`
	ItemCount    int         `json:"item_count"`
	Items        []MediaItem `json:"items,omitempty"`
	CreatedAt    int64       `json:"created_at"`
	UpdatedAt    int64       `json:"updated_at"`
}

type LibraryQuery struct {
	LibraryType string
	Kind        string
	MountID     string
	GenreID     int64
	Year        int
	Quality     string // 4k | 1080p | hdr | dv
	Watched     *bool
	Favorite    bool
	Letter      string
	Search      string
	Sort        string // added_at | title | release_date | rating | last_played | year
	Order       string // asc | desc
	Offset      int
	Limit       int
}

type LibraryPage struct {
	Items  []MediaItem `json:"items"`
	Total  int         `json:"total"`
	Offset int         `json:"offset"`
	Limit  int         `json:"limit"`
}

type LibraryFacets struct {
	Genres  []Genre       `json:"genres"`
	Years   []int         `json:"years"`
	Mounts  []MountOption `json:"mounts"`
	Letters []string      `json:"letters"`
}

type MountOption struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
}

type ItemDetail struct {
	Item          MediaItem    `json:"item"`
	Parent        *MediaItem   `json:"parent,omitempty"`
	Show          *MediaItem   `json:"show,omitempty"`
	Files         []MediaFile  `json:"files"`
	Subtitles     []MediaFile  `json:"subtitles"`
	Seasons       []MediaItem  `json:"seasons,omitempty"`
	Episodes      []MediaItem  `json:"episodes,omitempty"`
	Genres        []Genre      `json:"genres"`
	Credits       []Credit     `json:"credits"`
	Collections   []MediaList  `json:"collections,omitempty"`
	Similar       []MediaItem  `json:"similar,omitempty"`
	OnDeckEpisode *MediaItem   `json:"on_deck_episode,omitempty"`
	WorkPrefs     *WorkPrefs   `json:"work_prefs,omitempty"`
	NextEpisode   *MediaItem   `json:"next_episode,omitempty"`
	PrevEpisode   *MediaItem   `json:"prev_episode,omitempty"`
}

type HomeShelf struct {
	Key   string      `json:"key"`
	Title string      `json:"title"`
	Items []MediaItem `json:"items"`
}

type HomePayload struct {
	Hero            []MediaItem      `json:"hero"`
	ContinueWatching []MediaItem     `json:"continue_watching"`
	RecentAll       []MediaItem      `json:"recent_all"`
	Shelves         []HomeShelf      `json:"shelves"`
	Counts          map[string]int64 `json:"counts"`
	UnmatchedCount  int64            `json:"unmatched_count"`
	MountCount      int64            `json:"mount_count"`
}

type UnmatchedEntry struct {
	Item        MediaItem `json:"item"`
	SampleFile  MediaFile `json:"sample_file"`
	FileCount   int       `json:"file_count"`
	GuessedKind string    `json:"guessed_kind"`
	GuessedYear *int      `json:"guessed_year,omitempty"`
}

type SystemOverview struct {
	Movies      int64 `json:"movies"`
	Shows       int64 `json:"shows"`
	Episodes    int64 `json:"episodes"`
	Files       int64 `json:"files"`
	Collections int64 `json:"collections"`
	Playlists   int64 `json:"playlists"`
	Unmatched   int64 `json:"unmatched"`
	Mounts      int64 `json:"mounts"`
	People      int64 `json:"people"`
	Genres      int64 `json:"genres"`
	DBBytes     int64 `json:"db_bytes"`
}

type ExternalServerRecord struct {
	ID               string            `json:"id"`
	Name             string            `json:"name"`
	Kind             string            `json:"kind"` // emby | jellyfin
	BaseURL          string            `json:"base_url"`
	AuthMode         string            `json:"auth_mode"` // password | apikey
	Username         string            `json:"username"`
	UserID           string            `json:"user_id"`
	DeviceID         string            `json:"device_id"`
	ServerID         string            `json:"server_id"`
	ServerVersion    string            `json:"server_version"`
	AllowInsecureTLS bool              `json:"allow_insecure_tls"`
	Secrets          map[string]string `json:"-"`
	HasToken         bool              `json:"has_token"`
	Enabled          bool              `json:"enabled"`
	CreatedAt        int64             `json:"created_at"`
	UpdatedAt        int64             `json:"updated_at"`
}

type ExternalServerUpdate struct {
	Name             *string
	Kind             *string
	BaseURL          *string
	AuthMode         *string
	Username         *string
	UserID           *string
	DeviceID         *string
	ServerID         *string
	ServerVersion    *string
	AllowInsecureTLS *bool
	Secrets          *map[string]string
	Enabled          *bool
}
