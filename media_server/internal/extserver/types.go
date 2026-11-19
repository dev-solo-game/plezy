package extserver

type ServerConfig struct {
	ID               string
	Kind             string // emby | jellyfin
	BaseURL          string
	UserID           string
	DeviceID         string
	Token            string
	AllowInsecureTLS bool
}

type ServerInfo struct {
	ServerName       string `json:"server_name"`
	ServerID         string `json:"server_id"`
	Version          string `json:"version"`
	ProductName      string `json:"product_name,omitempty"`
	DetectedKind     string `json:"detected_kind,omitempty"`
	EffectiveBaseURL string `json:"effective_base_url"`
}

type AuthResult struct {
	AccessToken string     `json:"-"`
	UserID      string     `json:"user_id"`
	Username    string     `json:"username"`
	ServerInfo  ServerInfo `json:"server_info"`
}

type ExtView struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	CollectionType string `json:"collection_type,omitempty"`
	ImageURL       string `json:"image_url,omitempty"`
}

type ExtItem struct {
	ID            string   `json:"id"`
	Kind          string   `json:"kind"` // movie | show | season | episode | boxset | playlist | video
	RawType       string   `json:"raw_type,omitempty"`
	Title         string   `json:"title"`
	OriginalTitle string   `json:"original_title,omitempty"`
	Year          int      `json:"year,omitempty"`
	PremiereDate  string   `json:"premiere_date,omitempty"`
	Overview      string   `json:"overview,omitempty"`
	Rating        float64  `json:"rating,omitempty"`
	OfficialRating string  `json:"official_rating,omitempty"`
	RuntimeMs     int64    `json:"runtime_ms,omitempty"`
	SeasonNumber  int      `json:"season_number,omitempty"`
	EpisodeNumber int      `json:"episode_number,omitempty"`
	SeriesID      string   `json:"series_id,omitempty"`
	SeriesName    string   `json:"series_name,omitempty"`
	SeasonID      string   `json:"season_id,omitempty"`
	PosterURL     string   `json:"poster_url,omitempty"`
	BackdropURL   string   `json:"backdrop_url,omitempty"`
	ThumbURL      string   `json:"thumb_url,omitempty"`
	Watched       bool     `json:"watched"`
	Favorite      bool     `json:"favorite"`
	PositionMs    int64    `json:"position_ms,omitempty"`
	UnplayedCount int      `json:"unplayed_count,omitempty"`
	ChildCount    int      `json:"child_count,omitempty"`
	QualityBadge  string   `json:"quality_badge,omitempty"`
	HdrBadge      string   `json:"hdr_badge,omitempty"`
	Genres        []string `json:"genres,omitempty"`
	Tagline       string   `json:"tagline,omitempty"`
	Studios       []string `json:"studios,omitempty"`
}

type ExtMediaStream struct {
	Index          int    `json:"index"`
	Type           string `json:"type"` // Video | Audio | Subtitle
	Codec          string `json:"codec,omitempty"`
	Language       string `json:"language,omitempty"`
	DisplayTitle   string `json:"display_title,omitempty"`
	Title          string `json:"title,omitempty"`
	IsDefault      bool   `json:"is_default,omitempty"`
	IsForced       bool   `json:"is_forced,omitempty"`
	IsExternal     bool   `json:"is_external,omitempty"`
	IsTextSubtitle bool   `json:"is_text_subtitle,omitempty"`
	DeliveryURL    string `json:"delivery_url,omitempty"`
	Width          int    `json:"width,omitempty"`
	Height         int    `json:"height,omitempty"`
	VideoRange     string `json:"video_range,omitempty"`
	Channels       int    `json:"channels,omitempty"`
	BitRate        int    `json:"bit_rate,omitempty"`
}

type ExtMediaSource struct {
	ID                   string           `json:"id"`
	Name                 string           `json:"name,omitempty"`
	Container            string           `json:"container,omitempty"`
	Path                 string           `json:"path,omitempty"`
	Size                 int64            `json:"size,omitempty"`
	Bitrate              int              `json:"bitrate,omitempty"`
	RunTimeMs            int64            `json:"runtime_ms,omitempty"`
	SupportsDirectPlay   bool             `json:"supports_direct_play"`
	SupportsDirectStream bool             `json:"supports_direct_stream"`
	SupportsTranscoding  bool             `json:"supports_transcoding"`
	TranscodingURL       string           `json:"transcoding_url,omitempty"`
	DirectStreamURL      string           `json:"direct_stream_url,omitempty"`
	VideoCodec           string           `json:"video_codec,omitempty"`
	Width                int              `json:"width,omitempty"`
	Height               int              `json:"height,omitempty"`
	HdrFormat            string           `json:"hdr_format,omitempty"`
	BrowserCompatible    bool             `json:"browser_compatible"`
	CompatWarning        string           `json:"compat_warning,omitempty"`
	Streams              []ExtMediaStream `json:"streams,omitempty"`
}

type ExtPerson struct {
	ID       string `json:"id,omitempty"`
	Name     string `json:"name"`
	Role     string `json:"role,omitempty"`
	Type     string `json:"type,omitempty"`
	PhotoURL string `json:"photo_url,omitempty"`
}

type ExtItemDetail struct {
	Item          ExtItem          `json:"item"`
	Show          *ExtItem         `json:"show,omitempty"`
	Seasons       []ExtItem        `json:"seasons,omitempty"`
	Episodes      []ExtItem        `json:"episodes,omitempty"`
	OnDeckEpisode *ExtItem         `json:"on_deck_episode,omitempty"`
	Children      []ExtItem        `json:"children,omitempty"`
	MediaSources  []ExtMediaSource `json:"media_sources,omitempty"`
	People        []ExtPerson      `json:"people,omitempty"`
	Similar       []ExtItem        `json:"similar,omitempty"`
}

type ExtItemsPage struct {
	Items  []ExtItem `json:"items"`
	Total  int       `json:"total"`
	Offset int       `json:"offset"`
	Limit  int       `json:"limit"`
}

type ExtSearchResult struct {
	Movies      []ExtItem `json:"movies"`
	Shows       []ExtItem `json:"shows"`
	Episodes    []ExtItem `json:"episodes"`
	Collections []ExtItem `json:"collections"`
}

type ExtLatestGroup struct {
	View  ExtView   `json:"view"`
	Items []ExtItem `json:"items"`
}

type ExtHomePayload struct {
	Views        []ExtView        `json:"views"`
	Resume       []ExtItem        `json:"resume"`
	LatestByView []ExtLatestGroup `json:"latest_by_view"`
}

type ListItemsOpts struct {
	ParentID         string
	IncludeItemTypes string
	Recursive        bool
	SortBy           string
	SortOrder        string
	StartIndex       int
	Limit            int
	SearchTerm       string
	Filters          string
}

type PlaybackReportReq struct {
	State         string `json:"state"` // start | progress | stop
	ItemID        string `json:"item_id"`
	MediaSourceID string `json:"media_source_id,omitempty"`
	PlaySessionID string `json:"play_session_id,omitempty"`
	PositionMs    int64  `json:"position_ms"`
	IsPaused      bool   `json:"is_paused"`
	PlayMethod    string `json:"play_method,omitempty"` // DirectStream | Transcode
}

type PlaybackInfoResult struct {
	PlaySessionID string           `json:"play_session_id,omitempty"`
	MediaSources  []ExtMediaSource `json:"media_sources"`
}
