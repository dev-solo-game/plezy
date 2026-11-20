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

	FileStateActive     = "active"
	FileStateMissing    = "missing"
	FileStateTombstoned = "tombstoned"

	MatchPending   = "pending"
	MatchMatched   = "matched"
	MatchUnmatched = "unmatched"
	MatchIgnored   = "ignored"

	ListCollection = "collection"
	ListPlaylist   = "playlist"

	DeviceClassDesktop = "desktop"
	DeviceClassPhone   = "phone"
	DeviceClassTablet  = "tablet"
	DeviceClassTV      = "tv"
	DeviceClassWeb     = "web"

	SourceKindQuark    = "quark"
	SourceKindWebDAV   = "webdav"
	SourceKindEmby     = "emby"
	SourceKindJellyfin = "jellyfin"

	RegistrationModeOpen   = "open"
	RegistrationModeInvite = "invite"
	RegistrationModeClosed = "closed"
)

var AllShelves = []string{
	ShelfMovie,
	ShelfShow,
	ShelfAnime,
	ShelfVariety,
	ShelfDocumentary,
}

type ServerSettings struct {
	ServerName                 string  `json:"server_name"`
	TmdbAPIKeySet              bool    `json:"tmdb_api_key_set"`
	TmdbAPIKeyMasked           string  `json:"tmdb_api_key_masked"`
	TmdbAPIKey                 string  `json:"-"`
	TmdbAPIBase                string  `json:"tmdb_api_base"`
	TmdbImageBase              string  `json:"tmdb_image_base"`
	MetadataProxy              string  `json:"metadata_proxy"`
	BangumiEnabled             bool    `json:"bangumi_enabled"`
	BangumiAPIBase             string  `json:"bangumi_api_base"`
	BangumiTokenSet            bool    `json:"bangumi_token_set"`
	BangumiTokenMasked         string  `json:"bangumi_token_masked"`
	BangumiToken               string  `json:"-"`
	DoubanEnabled              bool    `json:"douban_enabled"`
	DoubanAPIBase              string  `json:"douban_api_base"`
	DoubanCookieSet            bool    `json:"douban_cookie_set"`
	DoubanCookieMasked         string  `json:"douban_cookie_masked"`
	DoubanCookie               string  `json:"-"`
	AniListEnabled             bool    `json:"anilist_enabled"`
	AniListAPIBase             string  `json:"anilist_api_base"`
	ImdbEnabled                bool    `json:"imdb_enabled"`
	ImdbAPIBase                string  `json:"imdb_api_base"`
	TvdbEnabled                bool    `json:"tvdb_enabled"`
	TvdbAPIBase                string  `json:"tvdb_api_base"`
	TvdbAPIKeySet              bool    `json:"tvdb_api_key_set"`
	TvdbAPIKeyMasked           string  `json:"tvdb_api_key_masked"`
	TvdbAPIKey                 string  `json:"-"`
	TvdbPinSet                 bool    `json:"tvdb_pin_set"`
	TvdbPinMasked              string  `json:"tvdb_pin_masked"`
	TvdbPin                    string  `json:"-"`
	AllowPublicMetadata        bool    `json:"allow_public_metadata"`
	AllowFallbackMetadata      bool    `json:"allow_fallback_metadata"`
	CustomRecognitionWords     string  `json:"custom_recognition_words"`
	ProxyImages                bool    `json:"proxy_images"`
	ScraperLang                string  `json:"scraper_lang"`
	PreferNfo                  bool    `json:"prefer_nfo"`
	WatchedThreshold           float64 `json:"watched_threshold"`
	AccentTheme                string  `json:"accent_theme"`
	RegistrationMode           string  `json:"registration_mode"`
	SourceAddPolicyJSON        string  `json:"source_add_policy_json"`
	FullScanAllowedDevicesJSON string  `json:"full_scan_allowed_devices_json"`
	MinProtocolVersion         int     `json:"min_protocol_version"`
}

type ServerSettingsUpdate struct {
	ServerName                 *string  `json:"server_name,omitempty"`
	TmdbAPIKey                 *string  `json:"tmdb_api_key,omitempty"`
	ClearTmdbAPIKey            bool     `json:"clear_tmdb_api_key,omitempty"`
	TmdbAPIBase                *string  `json:"tmdb_api_base,omitempty"`
	TmdbImageBase              *string  `json:"tmdb_image_base,omitempty"`
	MetadataProxy              *string  `json:"metadata_proxy,omitempty"`
	BangumiEnabled             *bool    `json:"bangumi_enabled,omitempty"`
	BangumiAPIBase             *string  `json:"bangumi_api_base,omitempty"`
	BangumiToken               *string  `json:"bangumi_token,omitempty"`
	ClearBangumiToken          bool     `json:"clear_bangumi_token,omitempty"`
	DoubanEnabled              *bool    `json:"douban_enabled,omitempty"`
	DoubanAPIBase              *string  `json:"douban_api_base,omitempty"`
	DoubanCookie               *string  `json:"douban_cookie,omitempty"`
	ClearDoubanCookie          bool     `json:"clear_douban_cookie,omitempty"`
	AniListEnabled             *bool    `json:"anilist_enabled,omitempty"`
	AniListAPIBase             *string  `json:"anilist_api_base,omitempty"`
	ImdbEnabled                *bool    `json:"imdb_enabled,omitempty"`
	ImdbAPIBase                *string  `json:"imdb_api_base,omitempty"`
	TvdbEnabled                *bool    `json:"tvdb_enabled,omitempty"`
	TvdbAPIBase                *string  `json:"tvdb_api_base,omitempty"`
	TvdbAPIKey                 *string  `json:"tvdb_api_key,omitempty"`
	ClearTvdbAPIKey            bool     `json:"clear_tvdb_api_key,omitempty"`
	TvdbPin                    *string  `json:"tvdb_pin,omitempty"`
	ClearTvdbPin               bool     `json:"clear_tvdb_pin,omitempty"`
	AllowPublicMetadata        *bool    `json:"allow_public_metadata,omitempty"`
	AllowFallbackMetadata      *bool    `json:"allow_fallback_metadata,omitempty"`
	CustomRecognitionWords     *string  `json:"custom_recognition_words,omitempty"`
	ProxyImages                *bool    `json:"proxy_images,omitempty"`
	ScraperLang                *string  `json:"scraper_lang,omitempty"`
	PreferNfo                  *bool    `json:"prefer_nfo,omitempty"`
	WatchedThreshold           *float64 `json:"watched_threshold,omitempty"`
	AccentTheme                *string  `json:"accent_theme,omitempty"`
	RegistrationMode           *string  `json:"registration_mode,omitempty"`
	SourceAddPolicyJSON        *string  `json:"source_add_policy_json,omitempty"`
	FullScanAllowedDevicesJSON *string  `json:"full_scan_allowed_devices_json,omitempty"`
	MinProtocolVersion         *int     `json:"min_protocol_version,omitempty"`
}

type MediaItem struct {
	ID             int64    `json:"id"`
	HouseholdID    string   `json:"household_id"`
	WorkKey        *string  `json:"work_key,omitempty"`
	Kind           string   `json:"kind"`
	LibraryType    string   `json:"library_type"`
	ParentID       *int64   `json:"parent_id,omitempty"`
	ShowID         *int64   `json:"show_id,omitempty"`
	Title          string   `json:"title"`
	SortTitle      string   `json:"sort_title"`
	OriginalTitle  *string  `json:"original_title,omitempty"`
	Aliases        *string  `json:"aliases,omitempty"`
	Year           *int     `json:"year,omitempty"`
	ReleaseDate    *string  `json:"release_date,omitempty"`
	Summary        *string  `json:"summary,omitempty"`
	Tagline        *string  `json:"tagline,omitempty"`
	ContentRating  *string  `json:"content_rating,omitempty"`
	Studio         *string  `json:"studio,omitempty"`
	Rating         *float64 `json:"rating,omitempty"`
	RuntimeMs      *int64   `json:"runtime_ms,omitempty"`
	SeasonNumber   *int     `json:"season_number,omitempty"`
	EpisodeNumber  *int     `json:"episode_number,omitempty"`
	AbsoluteNumber *int     `json:"absolute_number,omitempty"`
	PosterSource   *string  `json:"poster_source,omitempty"`
	BackdropSource *string  `json:"backdrop_source,omitempty"`
	LogoSource     *string  `json:"logo_source,omitempty"`
	TmdbID         *string  `json:"tmdb_id,omitempty"`
	ImdbID         *string  `json:"imdb_id,omitempty"`
	TvdbID         *string  `json:"tvdb_id,omitempty"`
	BangumiID      *string  `json:"bangumi_id,omitempty"`
	DoubanID       *string  `json:"douban_id,omitempty"`
	AniListID      *string  `json:"anilist_id,omitempty"`
	MetadataSource *string  `json:"metadata_source,omitempty"`
	Locked         bool     `json:"locked"`
	AddedAt        int64    `json:"added_at"`
	SourceAddedAt  *int64   `json:"source_added_at,omitempty"`
	UpdatedAt      int64    `json:"updated_at"`
	ScrapedAt      *int64   `json:"scraped_at,omitempty"`
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
	ID               int64          `json:"id"`
	HouseholdID      string         `json:"household_id"`
	SourceID         string         `json:"source_id"`
	Path             string         `json:"path"`
	FileName         string         `json:"file_name,omitempty"`
	RemoteID         *string        `json:"remote_id,omitempty"`
	Role             string         `json:"role"`
	ItemID           *int64         `json:"item_id,omitempty"`
	OwnerFileID      *int64         `json:"owner_file_id,omitempty"`
	Size             *int64         `json:"size,omitempty"`
	ModifiedAt       *int64         `json:"modified_at,omitempty"` // mtime_s
	CreatedAt        *int64         `json:"created_at,omitempty"`  // ctime_s
	SidecarSHA256    *string        `json:"sidecar_sha256,omitempty"`
	State            string         `json:"state"`
	MissingSince     *int64         `json:"missing_since,omitempty"`
	MatchState       string         `json:"match_state"`
	MatchLocked      bool           `json:"match_locked"`
	ParsedJSON       *string        `json:"parsed_json,omitempty"`
	ClientHintsJSON  *string        `json:"client_hints_json,omitempty"`
	VersionLabel     *string        `json:"version_label,omitempty"`
	Language         *string        `json:"language,omitempty"`
	DurationMs       *int64         `json:"duration_ms,omitempty"`
	BitrateKbps      *int           `json:"bitrate_kbps,omitempty"`
	Container        *string        `json:"container,omitempty"`
	VideoCodec       *string        `json:"video_codec,omitempty"`
	Width            *int           `json:"width,omitempty"`
	Height           *int           `json:"height,omitempty"`
	HdrFormat        *string        `json:"hdr_format,omitempty"`
	Streams          []ProbedStream `json:"streams,omitempty"`
	StreamsJSON      *string        `json:"-"`
	ProbedAt         *int64         `json:"probed_at,omitempty"`
	LastSeenAt       int64          `json:"last_seen_at"`
	ReportedByDevice string         `json:"reported_by_device,omitempty"`
	AddedAt          int64          `json:"added_at"`
	UpdatedAt        int64          `json:"updated_at"`
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
