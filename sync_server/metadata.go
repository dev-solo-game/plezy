package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	ErrMetadataNotConfigured = errors.New("tmdb api key is not configured on sync server")
	ErrMetadataDisabled      = errors.New("metadata endpoint or provider is disabled")
	ErrMetadataNotFound      = errors.New("metadata not found")
	ErrMetadataUpstream      = errors.New("metadata upstream request failed")
)

const (
	defaultTmdbApiBase   = "https://api.tmdb.org/3"
	defaultTmdbImageBase = "https://image.tmdb.org/t/p"
	defaultBangumiBase   = "https://api.bgm.tv"

	metaSearchTTLMs int64 = 24 * 60 * 60 * 1000
	metaShortTTLMs  int64 = 24 * 60 * 60 * 1000
	metaLongTTLMs   int64 = 30 * 24 * 60 * 60 * 1000
	metaPersonTTLMs int64 = 30 * 24 * 60 * 60 * 1000

	maxMetaBatchItems     = 50
	metaUpstreamBodyLimit = 16 * 1024 * 1024
)

type sfCall struct {
	wg  sync.WaitGroup
	val any
	err error
}

type sfGroup struct {
	mu sync.Mutex
	m  map[string]*sfCall
}

func (g *sfGroup) Do(key string, fn func() (any, error)) (any, error) {
	g.mu.Lock()
	if g.m == nil {
		g.m = make(map[string]*sfCall)
	}
	if c, ok := g.m[key]; ok {
		g.mu.Unlock()
		c.wg.Wait()
		return c.val, c.err
	}
	c := &sfCall{}
	c.wg.Add(1)
	g.m[key] = c
	g.mu.Unlock()

	defer func() {
		g.mu.Lock()
		delete(g.m, key)
		g.mu.Unlock()
		c.wg.Done()
	}()

	c.val, c.err = fn()
	return c.val, c.err
}

type MetadataCacheStats struct {
	Works    int64 `json:"works"`
	Seasons  int64 `json:"seasons"`
	People   int64 `json:"people"`
	Searches int64 `json:"searches"`
}

type MetadataPublicConfig struct {
	Code                int                `json:"code"`
	TmdbConfigured      bool               `json:"tmdb_configured"`
	BangumiEnabled      bool               `json:"bangumi_enabled"`
	TmdbImageBase       string             `json:"tmdb_image_base"`
	AllowPublicMetadata bool               `json:"allow_public_metadata"`
	CacheStats          MetadataCacheStats `json:"cache_stats"`
}

type AdminMetadataConfig struct {
	Code                int                `json:"code"`
	TmdbApiKeySet       bool               `json:"tmdb_api_key_set"`
	TmdbApiKeyMasked    string             `json:"tmdb_api_key_masked"`
	TmdbApiBase         string             `json:"tmdb_api_base"`
	TmdbImageBase       string             `json:"tmdb_image_base"`
	MetadataProxy       string             `json:"metadata_proxy"`
	BangumiEnabled      bool               `json:"bangumi_enabled"`
	AllowPublicMetadata bool               `json:"allow_public_metadata"`
	CacheStats          MetadataCacheStats `json:"cache_stats"`
}

type AdminMetadataConfigRequest struct {
	TmdbApiKey          *string `json:"tmdb_api_key,omitempty"`
	ClearTmdbApiKey     bool    `json:"clear_tmdb_api_key,omitempty"`
	TmdbApiBase         *string `json:"tmdb_api_base,omitempty"`
	TmdbImageBase       *string `json:"tmdb_image_base,omitempty"`
	MetadataProxy       *string `json:"metadata_proxy,omitempty"`
	BangumiEnabled      *bool   `json:"bangumi_enabled,omitempty"`
	AllowPublicMetadata *bool   `json:"allow_public_metadata,omitempty"`
	BangumiApiBase      *string `json:"bangumi_api_base,omitempty"`
}

type AdminMetadataTestRequest struct {
	TmdbApiKey    *string `json:"tmdb_api_key,omitempty"`
	TmdbApiBase   *string `json:"tmdb_api_base,omitempty"`
	MetadataProxy *string `json:"metadata_proxy,omitempty"`
}

type MetadataClearCacheRequest struct {
	Scope string `json:"scope"`
}

type MetadataCandidate struct {
	Source        string  `json:"source"`
	ID            string  `json:"id"`
	Title         string  `json:"title"`
	OriginalTitle *string `json:"original_title,omitempty"`
	Year          *int    `json:"year,omitempty"`
	Summary       *string `json:"summary,omitempty"`
	PosterPath    *string `json:"poster_path,omitempty"`
}

type MetadataCredit struct {
	Name      string  `json:"name"`
	Job       string  `json:"job"`
	Character *string `json:"character,omitempty"`
	TmdbID    *string `json:"tmdb_id,omitempty"`
	PhotoPath *string `json:"photo_path,omitempty"`
}

type MetadataWork struct {
	Source          string           `json:"source"`
	Kind            string           `json:"kind"`
	ExternalID      string           `json:"external_id"`
	TmdbID          *string          `json:"tmdb_id,omitempty"`
	ImdbID          *string          `json:"imdb_id,omitempty"`
	TvdbID          *string          `json:"tvdb_id,omitempty"`
	BangumiID       *string          `json:"bangumi_id,omitempty"`
	Title           string           `json:"title"`
	OriginalTitle   *string          `json:"original_title,omitempty"`
	Aliases         []string         `json:"aliases,omitempty"`
	Year            *int             `json:"year,omitempty"`
	ReleaseDate     *string          `json:"release_date,omitempty"`
	Summary         *string          `json:"summary,omitempty"`
	Tagline         *string          `json:"tagline,omitempty"`
	Rating          *float64         `json:"rating,omitempty"`
	RuntimeMs       *int             `json:"runtime_ms,omitempty"`
	ContentRating   *string          `json:"content_rating,omitempty"`
	Studio          *string          `json:"studio,omitempty"`
	Genres          []string         `json:"genres,omitempty"`
	PosterPath      *string          `json:"poster_path,omitempty"`
	BackdropPath    *string          `json:"backdrop_path,omitempty"`
	LogoPath        *string          `json:"logo_path,omitempty"`
	Credits         []MetadataCredit `json:"credits,omitempty"`
	CollectionID    *string          `json:"collection_id,omitempty"`
	CollectionTitle *string          `json:"collection_title,omitempty"`
	Category        *string          `json:"category,omitempty"`
	Status          string           `json:"status,omitempty"`
}

type MetadataEpisode struct {
	Number    int      `json:"number"`
	Title     *string  `json:"title,omitempty"`
	Summary   *string  `json:"summary,omitempty"`
	AirDate   *string  `json:"air_date,omitempty"`
	RuntimeMs *int     `json:"runtime_ms,omitempty"`
	StillPath *string  `json:"still_path,omitempty"`
	Rating    *float64 `json:"rating,omitempty"`
}

type MetadataSeason struct {
	Number     int               `json:"number"`
	Title      *string           `json:"title,omitempty"`
	Summary    *string           `json:"summary,omitempty"`
	PosterPath *string           `json:"poster_path,omitempty"`
	Episodes   []MetadataEpisode `json:"episodes"`
}

type MetadataPerson struct {
	Provider           string  `json:"provider"`
	PersonID           string  `json:"person_id"`
	Name               string  `json:"name"`
	ProfilePath        *string `json:"profile_path,omitempty"`
	Biography          *string `json:"biography,omitempty"`
	Birthday           *string `json:"birthday,omitempty"`
	KnownForDepartment *string `json:"known_for_department,omitempty"`
	PlaceOfBirth       *string `json:"place_of_birth,omitempty"`
}

type MetadataSearchResponse struct {
	Code      int                 `json:"code"`
	Provider  string              `json:"provider"`
	Kind      string              `json:"kind"`
	ImageBase string              `json:"image_base"`
	Cached    bool                `json:"cached"`
	Results   []MetadataCandidate `json:"results"`
}

type MetadataWorkResponse struct {
	Code      int          `json:"code"`
	ImageBase string       `json:"image_base"`
	Cached    bool         `json:"cached"`
	Work      MetadataWork `json:"work"`
}

type MetadataSeasonResponse struct {
	Code      int            `json:"code"`
	ImageBase string         `json:"image_base"`
	Cached    bool           `json:"cached"`
	Season    MetadataSeason `json:"season"`
}

type MetadataPersonResponse struct {
	Code      int            `json:"code"`
	ImageBase string         `json:"image_base"`
	Cached    bool           `json:"cached"`
	Person    MetadataPerson `json:"person"`
}

type MetadataBatchWorkRef struct {
	Provider string `json:"provider"`
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Lang     string `json:"lang,omitempty"`
}

type MetadataBatchSeasonRef struct {
	Provider string `json:"provider"`
	ID       string `json:"id"`
	Season   int    `json:"season"`
	Lang     string `json:"lang,omitempty"`
}

type MetadataBatchRequest struct {
	Works   []MetadataBatchWorkRef   `json:"works,omitempty"`
	Seasons []MetadataBatchSeasonRef `json:"seasons,omitempty"`
	Lang    string                   `json:"lang,omitempty"`
	Refresh bool                     `json:"refresh,omitempty"`
}

type MetadataBatchResponse struct {
	Code      int                       `json:"code"`
	ImageBase string                    `json:"image_base"`
	Works     map[string]MetadataWork   `json:"works"`
	Seasons   map[string]MetadataSeason `json:"seasons"`
	Errors    map[string]string         `json:"errors,omitempty"`
}

type metadataRuntimeConfig struct {
	TmdbApiKey          string
	TmdbApiBase         string
	TmdbImageBase       string
	MetadataProxy       string
	BangumiEnabled      bool
	AllowPublicMetadata bool
	BangumiApiBase      string
}

var (
	schemeRegex      = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*://`)
	bangumiDatedTag  = regexp.MustCompile(`^\d{2,4}(?:年|\s|$)|\d{1,2}月|^\d+$`)
	bangumiNoiseTags = map[string]bool{
		"tv": true, "web": true, "ova": true, "oad": true, "bd": true, "dvd": true, "sp": true,
		"剧场版": true, "劇場版": true, "电影": true, "電影": true, "动画": true, "動畫": true, "动画电影": true,
		"anime": true, "tv动画": true, "tv動畫": true, "原创": true, "原創": true,
		"日本": true, "中国": true, "中國": true, "国产": true, "國產": true, "日漫": true, "国漫": true, "國漫": true,
		"漫画改": true, "漫改": true, "轻小说改": true, "輕小說改": true, "小说改": true, "小說改": true, "游戏改": true, "遊戲改": true,
		"续作": true, "續作": true, "短片": true, "泡面番": true, "未上映": true, "季番": true, "新番": true,
		"3d": true, "2d": true, "cg": true,
	}
)

func (s *SyncStore) metaNowMs() int64 {
	if s.metaNow != nil {
		return s.metaNow()
	}
	return nowMs()
}

func normalizeTmdbBase(raw, fallback, defaultPath string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return fallback
	}
	if !schemeRegex.MatchString(text) {
		text = "https://" + text
	}
	text = strings.TrimRight(text, "/")
	u, err := url.Parse(text)
	if err != nil || u.Host == "" {
		return fallback
	}
	if u.Path == "" {
		return text + defaultPath
	}
	return text
}

func normalizeBangumiBase(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return defaultBangumiBase
	}
	if !schemeRegex.MatchString(text) {
		text = "https://" + text
	}
	text = strings.TrimRight(text, "/")
	if u, err := url.Parse(text); err != nil || u.Host == "" {
		return defaultBangumiBase
	}
	return text
}

func maskSecret(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if len(trimmed) <= 4 {
		return "****"
	}
	return "****" + trimmed[len(trimmed)-4:]
}

func normalizeLang(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "zh-CN"
	}
	return trimmed
}

func (s *SyncStore) getConfigStringLocked(key, fallback string) string {
	var raw string
	if err := s.db.QueryRow(`SELECT value FROM server_config WHERE key = ?`, key).Scan(&raw); err != nil {
		return fallback
	}
	return raw
}

func (s *SyncStore) loadMetadataRuntimeConfig() metadataRuntimeConfig {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadMetadataRuntimeConfigLocked()
}

func (s *SyncStore) loadMetadataRuntimeConfigLocked() metadataRuntimeConfig {
	return metadataRuntimeConfig{
		TmdbApiKey:          strings.TrimSpace(s.getConfigStringLocked("tmdb_api_key", "")),
		TmdbApiBase:         normalizeTmdbBase(s.getConfigStringLocked("tmdb_api_base", defaultTmdbApiBase), defaultTmdbApiBase, "/3"),
		TmdbImageBase:       normalizeTmdbBase(s.getConfigStringLocked("tmdb_image_base", defaultTmdbImageBase), defaultTmdbImageBase, "/t/p"),
		MetadataProxy:       strings.TrimSpace(s.getConfigStringLocked("metadata_proxy", "")),
		BangumiEnabled:      s.getConfigBool("bangumi_enabled", true),
		AllowPublicMetadata: s.getConfigBool("allow_public_metadata", true),
		BangumiApiBase:      normalizeBangumiBase(s.getConfigStringLocked("bangumi_api_base", defaultBangumiBase)),
	}
}

func (s *SyncStore) queryMetadataCacheStatsLocked() MetadataCacheStats {
	var st MetadataCacheStats
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM meta_works_cache`).Scan(&st.Works)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM meta_seasons_cache`).Scan(&st.Seasons)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM meta_people_cache`).Scan(&st.People)
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM meta_search_cache`).Scan(&st.Searches)
	return st
}

func (s *SyncStore) AllowPublicMetadata() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.getConfigBool("allow_public_metadata", true)
}

func (s *SyncStore) GetPublicMetadataConfig() MetadataPublicConfig {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg := s.loadMetadataRuntimeConfigLocked()
	stats := s.queryMetadataCacheStatsLocked()
	return MetadataPublicConfig{
		Code:                0,
		TmdbConfigured:      cfg.TmdbApiKey != "",
		BangumiEnabled:      cfg.BangumiEnabled,
		TmdbImageBase:       cfg.TmdbImageBase,
		AllowPublicMetadata: cfg.AllowPublicMetadata,
		CacheStats:          stats,
	}
}

func (s *SyncStore) AdminGetMetadataConfig() AdminMetadataConfig {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg := s.loadMetadataRuntimeConfigLocked()
	stats := s.queryMetadataCacheStatsLocked()
	return AdminMetadataConfig{
		Code:                0,
		TmdbApiKeySet:       cfg.TmdbApiKey != "",
		TmdbApiKeyMasked:    maskSecret(cfg.TmdbApiKey),
		TmdbApiBase:         cfg.TmdbApiBase,
		TmdbImageBase:       cfg.TmdbImageBase,
		MetadataProxy:       cfg.MetadataProxy,
		BangumiEnabled:      cfg.BangumiEnabled,
		AllowPublicMetadata: cfg.AllowPublicMetadata,
		CacheStats:          stats,
	}
}

func (s *SyncStore) AdminUpdateMetadataConfig(req AdminMetadataConfigRequest) (AdminMetadataConfig, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if req.ClearTmdbApiKey {
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_api_key', '')`); err != nil {
			return AdminMetadataConfig{}, err
		}
	} else if req.TmdbApiKey != nil {
		trimmed := strings.TrimSpace(*req.TmdbApiKey)
		if trimmed != "" {
			if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_api_key', ?)`, trimmed); err != nil {
				return AdminMetadataConfig{}, err
			}
		}
	}

	if req.TmdbApiBase != nil {
		norm := normalizeTmdbBase(*req.TmdbApiBase, defaultTmdbApiBase, "/3")
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_api_base', ?)`, norm); err != nil {
			return AdminMetadataConfig{}, err
		}
	}
	if req.TmdbImageBase != nil {
		norm := normalizeTmdbBase(*req.TmdbImageBase, defaultTmdbImageBase, "/t/p")
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('tmdb_image_base', ?)`, norm); err != nil {
			return AdminMetadataConfig{}, err
		}
	}
	if req.MetadataProxy != nil {
		proxy := strings.TrimSpace(*req.MetadataProxy)
		if proxy != "" {
			if _, err := parseProxyURL(proxy); err != nil {
				return AdminMetadataConfig{}, fmt.Errorf("%w: invalid proxy URL: %v", ErrInvalidInput, err)
			}
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('metadata_proxy', ?)`, proxy); err != nil {
			return AdminMetadataConfig{}, err
		}
	}
	if req.BangumiEnabled != nil {
		val := "false"
		if *req.BangumiEnabled {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('bangumi_enabled', ?)`, val); err != nil {
			return AdminMetadataConfig{}, err
		}
	}
	if req.AllowPublicMetadata != nil {
		val := "false"
		if *req.AllowPublicMetadata {
			val = "true"
		}
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('allow_public_metadata', ?)`, val); err != nil {
			return AdminMetadataConfig{}, err
		}
	}
	if req.BangumiApiBase != nil {
		norm := normalizeBangumiBase(*req.BangumiApiBase)
		if _, err := s.db.Exec(`INSERT OR REPLACE INTO server_config(key, value) VALUES ('bangumi_api_base', ?)`, norm); err != nil {
			return AdminMetadataConfig{}, err
		}
	}

	cfg := s.loadMetadataRuntimeConfigLocked()
	stats := s.queryMetadataCacheStatsLocked()
	return AdminMetadataConfig{
		Code:                0,
		TmdbApiKeySet:       cfg.TmdbApiKey != "",
		TmdbApiKeyMasked:    maskSecret(cfg.TmdbApiKey),
		TmdbApiBase:         cfg.TmdbApiBase,
		TmdbImageBase:       cfg.TmdbImageBase,
		MetadataProxy:       cfg.MetadataProxy,
		BangumiEnabled:      cfg.BangumiEnabled,
		AllowPublicMetadata: cfg.AllowPublicMetadata,
		CacheStats:          stats,
	}, nil
}

func (s *SyncStore) AdminClearMetadataCache(scope string) (int64, MetadataCacheStats, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	normalized := strings.ToLower(strings.TrimSpace(scope))
	if normalized == "" {
		normalized = "all"
	}

	var tables []string
	switch normalized {
	case "all":
		tables = []string{"meta_works_cache", "meta_seasons_cache", "meta_people_cache", "meta_search_cache"}
	case "works":
		tables = []string{"meta_works_cache"}
	case "seasons":
		tables = []string{"meta_seasons_cache"}
	case "people":
		tables = []string{"meta_people_cache"}
	case "search":
		tables = []string{"meta_search_cache"}
	default:
		return 0, MetadataCacheStats{}, fmt.Errorf("%w: unknown cache scope %q", ErrInvalidInput, scope)
	}

	var deleted int64
	for _, tbl := range tables {
		res, err := s.db.Exec(`DELETE FROM ` + tbl)
		if err != nil {
			return deleted, MetadataCacheStats{}, err
		}
		n, _ := res.RowsAffected()
		deleted += n
	}
	return deleted, s.queryMetadataCacheStatsLocked(), nil
}

func (s *SyncStore) AdminTestMetadataConnection(ctx context.Context, req AdminMetadataTestRequest) (int64, error) {
	cfg := s.loadMetadataRuntimeConfig()
	key := cfg.TmdbApiKey
	if req.TmdbApiKey != nil && strings.TrimSpace(*req.TmdbApiKey) != "" {
		key = strings.TrimSpace(*req.TmdbApiKey)
	}
	if key == "" {
		return 0, ErrMetadataNotConfigured
	}
	apiBase := cfg.TmdbApiBase
	if req.TmdbApiBase != nil && strings.TrimSpace(*req.TmdbApiBase) != "" {
		apiBase = normalizeTmdbBase(*req.TmdbApiBase, defaultTmdbApiBase, "/3")
	}
	proxy := cfg.MetadataProxy
	if req.MetadataProxy != nil {
		proxy = strings.TrimSpace(*req.MetadataProxy)
	}

	start := time.Now()
	_, status, err := s.tmdbRequest(ctx, apiBase, key, proxy, "/configuration", nil)
	if err != nil {
		return 0, err
	}
	if status == http.StatusNotFound {
		return 0, fmt.Errorf("%w: TMDB API not found at %s", ErrMetadataUpstream, apiBase)
	}
	return time.Since(start).Milliseconds(), nil
}

func parseProxyURL(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil
	}
	if !strings.Contains(trimmed, "://") {
		trimmed = "http://" + trimmed
	}
	trimmed = strings.TrimRight(trimmed, "/")
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("invalid proxy host")
	}
	return u, nil
}

func (s *SyncStore) getMetaHTTPClient(proxyRaw string) (*http.Client, error) {
	proxyKey := strings.TrimSpace(proxyRaw)
	s.metaHTTPMu.Lock()
	defer s.metaHTTPMu.Unlock()
	if s.metaHTTPClients == nil {
		s.metaHTTPClients = make(map[string]*http.Client)
	}
	if cli, ok := s.metaHTTPClients[proxyKey]; ok {
		return cli, nil
	}

	var tr *http.Transport
	if base, ok := http.DefaultTransport.(*http.Transport); ok && base != nil {
		tr = base.Clone()
	} else {
		tr = &http.Transport{}
	}
	if proxyKey != "" {
		proxyURL, err := parseProxyURL(proxyKey)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrMetadataUpstream, err)
		}
		tr.Proxy = http.ProxyURL(proxyURL)
	}
	cli := &http.Client{
		Timeout:   20 * time.Second,
		Transport: tr,
	}
	s.metaHTTPClients[proxyKey] = cli
	return cli, nil
}

func (s *SyncStore) doUpstreamJSON(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	headers map[string]string,
	reqBody any,
	service string,
) (map[string]any, int, error) {
	cli, err := s.getMetaHTTPClient(proxyRaw)
	if err != nil {
		return nil, 0, err
	}
	var bodyReader io.Reader
	if reqBody != nil {
		b, mErr := json.Marshal(reqBody)
		if mErr != nil {
			return nil, 0, mErr
		}
		bodyReader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, bodyReader)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: %v", ErrMetadataUpstream, err)
	}
	req.Header.Set("Accept", "application/json")
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := cli.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: %s request failed: %v", ErrMetadataUpstream, service, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, http.StatusNotFound, nil
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return nil, resp.StatusCode, fmt.Errorf("%w: %s rejected credentials (HTTP %d)", ErrMetadataUpstream, service, resp.StatusCode)
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, resp.StatusCode, fmt.Errorf("%w: %s is rate limiting (HTTP 429)", ErrMetadataUpstream, service)
	}
	if resp.StatusCode >= 400 {
		return nil, resp.StatusCode, fmt.Errorf("%w: %s returned HTTP %d", ErrMetadataUpstream, service, resp.StatusCode)
	}

	rawBytes, err := io.ReadAll(io.LimitReader(resp.Body, metaUpstreamBodyLimit))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%w: read %s response failed: %v", ErrMetadataUpstream, service, err)
	}
	dec := json.NewDecoder(bytes.NewReader(rawBytes))
	dec.UseNumber()
	var parsed map[string]any
	if err := dec.Decode(&parsed); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%w: invalid %s JSON: %v", ErrMetadataUpstream, service, err)
	}
	return parsed, resp.StatusCode, nil
}

func (s *SyncStore) tmdbRequest(
	ctx context.Context,
	apiBase string,
	apiKey string,
	proxyRaw string,
	apiPath string,
	query url.Values,
) (map[string]any, int, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, 0, ErrMetadataNotConfigured
	}
	u, err := url.Parse(apiBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: invalid TMDB API base: %v", ErrMetadataUpstream, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + apiPath
	q := url.Values{}
	for k, vals := range query {
		for _, v := range vals {
			q.Add(k, v)
		}
	}
	usesBearer := strings.HasPrefix(apiKey, "eyJ")
	if !usesBearer {
		q.Set("api_key", apiKey)
	}
	u.RawQuery = q.Encode()

	headers := map[string]string{}
	if usesBearer {
		headers["Authorization"] = "Bearer " + apiKey
	}
	return s.doUpstreamJSON(ctx, http.MethodGet, u.String(), proxyRaw, headers, nil, "TMDB")
}

func (s *SyncStore) bangumiRequest(
	ctx context.Context,
	apiBase string,
	proxyRaw string,
	method string,
	apiPath string,
	query url.Values,
	body any,
) (map[string]any, int, error) {
	u, err := url.Parse(apiBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: invalid Bangumi API base: %v", ErrMetadataUpstream, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + apiPath
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	headers := map[string]string{
		"User-Agent": "local-media-library/1.0 (anime metadata lookup)",
	}
	return s.doUpstreamJSON(ctx, method, u.String(), proxyRaw, headers, body, "Bangumi")
}

func computeWorkSeasonTTLMs(status, releaseDate string, now int64) int64 {
	st := strings.TrimSpace(strings.ToLower(status))
	if st == "returning series" || st == "in production" || st == "planned" {
		return metaShortTTLMs
	}
	trimmedDate := strings.TrimSpace(releaseDate)
	if trimmedDate == "" {
		return metaShortTTLMs
	}
	t, err := time.Parse("2006-01-02", trimmedDate)
	if err != nil {
		return metaShortTTLMs
	}
	age := time.UnixMilli(now).Sub(t)
	if age < 90*24*time.Hour {
		return metaShortTTLMs
	}
	return metaLongTTLMs
}

func searchCacheKey(provider, kind, query string, year int, lang string) string {
	normQuery := strings.ToLower(strings.TrimSpace(query))
	raw := fmt.Sprintf("%s|%s|%s|%d|%s", provider, kind, normQuery, year, lang)
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])[:32]
}

// ─── Public Metadata Queries ──────────────────────────────────────────────

func (s *SyncStore) MetadataSearch(
	ctx context.Context,
	provider string,
	kind string,
	query string,
	year int,
	lang string,
	refresh bool,
) (MetadataSearchResponse, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	k := strings.ToLower(strings.TrimSpace(kind))
	q := strings.TrimSpace(query)
	if (prov != "tmdb" && prov != "bangumi") || (k != "movie" && k != "show") || q == "" {
		return MetadataSearchResponse{}, fmt.Errorf("%w: invalid search parameters", ErrInvalidInput)
	}
	effectiveLang := normalizeLang(lang)
	if prov == "bangumi" {
		effectiveLang = "default"
	}

	cfg := s.loadMetadataRuntimeConfig()
	if prov == "tmdb" && cfg.TmdbApiKey == "" {
		return MetadataSearchResponse{}, ErrMetadataNotConfigured
	}
	if prov == "bangumi" && !cfg.BangumiEnabled {
		return MetadataSearchResponse{}, ErrMetadataDisabled
	}

	now := s.metaNowMs()
	ck := searchCacheKey(prov, k, q, year, effectiveLang)

	var stale []MetadataCandidate
	var hasStale bool

	s.mu.Lock()
	var payloadJSON string
	var expiresAt int64
	err := s.db.QueryRow(
		`SELECT payload_json, expires_at FROM meta_search_cache WHERE cache_key = ?`,
		ck,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached []MetadataCandidate
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				s.mu.Unlock()
				return MetadataSearchResponse{
					Code:      0,
					Provider:  prov,
					Kind:      k,
					ImageBase: cfg.TmdbImageBase,
					Cached:    true,
					Results:   nonNilCandidates(cached),
				}, nil
			}
		}
	}
	s.mu.Unlock()

	val, sfErr := s.metaFlight.Do("search:"+ck, func() (any, error) {
		freshCfg := s.loadMetadataRuntimeConfig()
		var fetched []MetadataCandidate
		var fErr error
		if prov == "tmdb" {
			fetched, fErr = s.fetchTmdbSearch(ctx, freshCfg, k, q, year, effectiveLang)
		} else {
			fetched, fErr = s.fetchBangumiSearch(ctx, freshCfg, q)
		}
		if fErr != nil {
			return nil, fErr
		}
		fetched = nonNilCandidates(fetched)
		raw, _ := json.Marshal(fetched)
		writeNow := s.metaNowMs()
		s.mu.Lock()
		_, _ = s.db.Exec(`
			INSERT OR REPLACE INTO meta_search_cache (
				cache_key, provider, kind, query, year, lang, payload_json, fetched_at, expires_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ck, prov, k, q, year, effectiveLang, string(raw), writeNow, writeNow+metaSearchTTLMs,
		)
		s.mu.Unlock()
		return fetched, nil
	})
	if sfErr != nil {
		if hasStale && errors.Is(sfErr, ErrMetadataUpstream) {
			return MetadataSearchResponse{
				Code:      0,
				Provider:  prov,
				Kind:      k,
				ImageBase: cfg.TmdbImageBase,
				Cached:    true,
				Results:   nonNilCandidates(stale),
			}, nil
		}
		return MetadataSearchResponse{}, sfErr
	}
	results, _ := val.([]MetadataCandidate)
	return MetadataSearchResponse{
		Code:      0,
		Provider:  prov,
		Kind:      k,
		ImageBase: cfg.TmdbImageBase,
		Cached:    false,
		Results:   nonNilCandidates(results),
	}, nil
}

func (s *SyncStore) MetadataGetWork(
	ctx context.Context,
	provider string,
	kind string,
	externalID string,
	lang string,
	refresh bool,
) (MetadataWorkResponse, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	k := strings.ToLower(strings.TrimSpace(kind))
	id := strings.TrimSpace(externalID)
	if (prov != "tmdb" && prov != "bangumi") || (k != "movie" && k != "show") || id == "" {
		return MetadataWorkResponse{}, fmt.Errorf("%w: invalid work parameters", ErrInvalidInput)
	}
	effectiveLang := normalizeLang(lang)
	if prov == "bangumi" {
		effectiveLang = "default"
	}

	cfg := s.loadMetadataRuntimeConfig()
	if prov == "tmdb" && cfg.TmdbApiKey == "" {
		return MetadataWorkResponse{}, ErrMetadataNotConfigured
	}
	if prov == "bangumi" && !cfg.BangumiEnabled {
		return MetadataWorkResponse{}, ErrMetadataDisabled
	}

	now := s.metaNowMs()
	var stale MetadataWork
	var hasStale bool

	s.mu.Lock()
	var payloadJSON string
	var expiresAt int64
	err := s.db.QueryRow(
		`SELECT payload_json, expires_at FROM meta_works_cache WHERE provider = ? AND kind = ? AND external_id = ? AND lang = ?`,
		prov, k, id, effectiveLang,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached MetadataWork
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			if prov == "tmdb" {
				s.hydrateWorkCreditsLocked(&cached)
			}
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				s.mu.Unlock()
				return MetadataWorkResponse{
					Code:      0,
					ImageBase: cfg.TmdbImageBase,
					Cached:    true,
					Work:      cached,
				}, nil
			}
		}
	}
	s.mu.Unlock()

	flightKey := fmt.Sprintf("work:%s:%s:%s:%s", prov, k, id, effectiveLang)
	val, sfErr := s.metaFlight.Do(flightKey, func() (any, error) {
		freshCfg := s.loadMetadataRuntimeConfig()
		var fetched MetadataWork
		var fErr error
		if prov == "tmdb" {
			fetched, fErr = s.fetchTmdbWork(ctx, freshCfg, k, id, effectiveLang)
		} else {
			fetched, fErr = s.fetchBangumiWork(ctx, freshCfg, k, id)
		}
		if fErr != nil {
			return nil, fErr
		}

		writeNow := s.metaNowMs()
		relDate := ""
		if fetched.ReleaseDate != nil {
			relDate = *fetched.ReleaseDate
		}
		ttl := computeWorkSeasonTTLMs(fetched.Status, relDate, writeNow)
		raw, _ := json.Marshal(fetched)

		s.mu.Lock()
		_, _ = s.db.Exec(`
			INSERT OR REPLACE INTO meta_works_cache (
				provider, kind, external_id, lang, payload_json, status, release_date, fetched_at, expires_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			prov, k, id, effectiveLang, string(raw), fetched.Status, relDate, writeNow, writeNow+ttl,
		)
		if prov == "tmdb" {
			s.upsertPeopleFromCreditsLocked(fetched.Credits, writeNow)
		}
		s.mu.Unlock()
		return fetched, nil
	})
	if sfErr != nil {
		if hasStale && errors.Is(sfErr, ErrMetadataUpstream) {
			return MetadataWorkResponse{
				Code:      0,
				ImageBase: cfg.TmdbImageBase,
				Cached:    true,
				Work:      stale,
			}, nil
		}
		return MetadataWorkResponse{}, sfErr
	}
	work, _ := val.(MetadataWork)
	return MetadataWorkResponse{
		Code:      0,
		ImageBase: cfg.TmdbImageBase,
		Cached:    false,
		Work:      work,
	}, nil
}

func (s *SyncStore) MetadataGetSeason(
	ctx context.Context,
	provider string,
	externalID string,
	seasonNumber int,
	lang string,
	refresh bool,
) (MetadataSeasonResponse, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	id := strings.TrimSpace(externalID)
	if (prov != "tmdb" && prov != "bangumi") || id == "" || seasonNumber < 0 {
		return MetadataSeasonResponse{}, fmt.Errorf("%w: invalid season parameters", ErrInvalidInput)
	}
	if prov == "bangumi" && seasonNumber != 1 {
		return MetadataSeasonResponse{}, ErrMetadataNotFound
	}
	effectiveLang := normalizeLang(lang)
	if prov == "bangumi" {
		effectiveLang = "default"
	}

	cfg := s.loadMetadataRuntimeConfig()
	if prov == "tmdb" && cfg.TmdbApiKey == "" {
		return MetadataSeasonResponse{}, ErrMetadataNotConfigured
	}
	if prov == "bangumi" && !cfg.BangumiEnabled {
		return MetadataSeasonResponse{}, ErrMetadataDisabled
	}

	now := s.metaNowMs()
	var stale MetadataSeason
	var hasStale bool

	s.mu.Lock()
	var payloadJSON string
	var expiresAt int64
	err := s.db.QueryRow(
		`SELECT payload_json, expires_at FROM meta_seasons_cache WHERE provider = ? AND external_id = ? AND season_number = ? AND lang = ?`,
		prov, id, seasonNumber, effectiveLang,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached MetadataSeason
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				s.mu.Unlock()
				return MetadataSeasonResponse{
					Code:      0,
					ImageBase: cfg.TmdbImageBase,
					Cached:    true,
					Season:    cached,
				}, nil
			}
		}
	}
	s.mu.Unlock()

	flightKey := fmt.Sprintf("season:%s:%s:%d:%s", prov, id, seasonNumber, effectiveLang)
	val, sfErr := s.metaFlight.Do(flightKey, func() (any, error) {
		freshCfg := s.loadMetadataRuntimeConfig()
		var fetched MetadataSeason
		var fErr error
		if prov == "tmdb" {
			fetched, fErr = s.fetchTmdbSeason(ctx, freshCfg, id, seasonNumber, effectiveLang)
		} else {
			fetched, fErr = s.fetchBangumiSeason(ctx, freshCfg, id)
		}
		if fErr != nil {
			return nil, fErr
		}

		writeNow := s.metaNowMs()
		raw, _ := json.Marshal(fetched)

		s.mu.Lock()
		var workStatus, workRelDate string
		_ = s.db.QueryRow(
			`SELECT status, release_date FROM meta_works_cache WHERE provider = ? AND kind = 'show' AND external_id = ? AND lang = ?`,
			prov, id, effectiveLang,
		).Scan(&workStatus, &workRelDate)
		refDate := latestEpisodeAirDate(fetched.Episodes)
		if refDate == "" {
			refDate = workRelDate
		}
		ttl := computeWorkSeasonTTLMs(workStatus, refDate, writeNow)
		_, _ = s.db.Exec(`
			INSERT OR REPLACE INTO meta_seasons_cache (
				provider, external_id, season_number, lang, payload_json, fetched_at, expires_at
			) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			prov, id, seasonNumber, effectiveLang, string(raw), writeNow, writeNow+ttl,
		)
		s.mu.Unlock()
		return fetched, nil
	})
	if sfErr != nil {
		if hasStale && errors.Is(sfErr, ErrMetadataUpstream) {
			return MetadataSeasonResponse{
				Code:      0,
				ImageBase: cfg.TmdbImageBase,
				Cached:    true,
				Season:    stale,
			}, nil
		}
		return MetadataSeasonResponse{}, sfErr
	}
	season, _ := val.(MetadataSeason)
	return MetadataSeasonResponse{
		Code:      0,
		ImageBase: cfg.TmdbImageBase,
		Cached:    false,
		Season:    season,
	}, nil
}

func (s *SyncStore) MetadataGetPerson(
	ctx context.Context,
	provider string,
	personID string,
	lang string,
	refresh bool,
) (MetadataPersonResponse, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	pid := strings.TrimSpace(personID)
	if (prov != "tmdb" && prov != "bangumi") || pid == "" {
		return MetadataPersonResponse{}, fmt.Errorf("%w: invalid person parameters", ErrInvalidInput)
	}
	if prov != "tmdb" {
		return MetadataPersonResponse{}, ErrMetadataNotFound
	}
	cfg := s.loadMetadataRuntimeConfig()
	if cfg.TmdbApiKey == "" {
		return MetadataPersonResponse{}, ErrMetadataNotConfigured
	}
	effectiveLang := normalizeLang(lang)

	now := s.metaNowMs()
	var stale MetadataPerson
	var hasStale bool

	s.mu.Lock()
	var name, profilePath, extraJSON string
	var expiresAt int64
	err := s.db.QueryRow(
		`SELECT name, profile_path, extra_json, expires_at FROM meta_people_cache WHERE provider = ? AND person_id = ?`,
		prov, pid,
	).Scan(&name, &profilePath, &extraJSON, &expiresAt)
	if err == nil && name != "" {
		var extra map[string]any
		_ = json.Unmarshal([]byte(extraJSON), &extra)
		person := MetadataPerson{
			Provider:           prov,
			PersonID:           pid,
			Name:               name,
			ProfilePath:        nonEmptyStrPtr(profilePath),
			Biography:          mapStrPtr(extra, "biography"),
			Birthday:           mapStrPtr(extra, "birthday"),
			KnownForDepartment: mapStrPtr(extra, "known_for_department"),
			PlaceOfBirth:       mapStrPtr(extra, "place_of_birth"),
		}
		isFull, _ := extra["_full"].(bool)
		if isFull {
			stale = person
			hasStale = true
			if !refresh && expiresAt > now {
				s.mu.Unlock()
				return MetadataPersonResponse{
					Code:      0,
					ImageBase: cfg.TmdbImageBase,
					Cached:    true,
					Person:    person,
				}, nil
			}
		}
	}
	s.mu.Unlock()

	flightKey := fmt.Sprintf("person:%s:%s:%s", prov, pid, effectiveLang)
	val, sfErr := s.metaFlight.Do(flightKey, func() (any, error) {
		freshCfg := s.loadMetadataRuntimeConfig()
		person, fErr := s.fetchTmdbPerson(ctx, freshCfg, pid, effectiveLang)
		if fErr != nil {
			return nil, fErr
		}
		writeNow := s.metaNowMs()
		extra := map[string]any{
			"_full": true,
		}
		if person.Biography != nil {
			extra["biography"] = *person.Biography
		}
		if person.Birthday != nil {
			extra["birthday"] = *person.Birthday
		}
		if person.KnownForDepartment != nil {
			extra["known_for_department"] = *person.KnownForDepartment
		}
		if person.PlaceOfBirth != nil {
			extra["place_of_birth"] = *person.PlaceOfBirth
		}
		extraRaw, _ := json.Marshal(extra)
		pp := ""
		if person.ProfilePath != nil {
			pp = *person.ProfilePath
		}

		s.mu.Lock()
		_, _ = s.db.Exec(`
			INSERT OR REPLACE INTO meta_people_cache (
				provider, person_id, name, profile_path, extra_json, fetched_at, expires_at
			) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			prov, pid, person.Name, pp, string(extraRaw), writeNow, writeNow+metaPersonTTLMs,
		)
		s.mu.Unlock()
		return person, nil
	})
	if sfErr != nil {
		if hasStale && errors.Is(sfErr, ErrMetadataUpstream) {
			return MetadataPersonResponse{
				Code:      0,
				ImageBase: cfg.TmdbImageBase,
				Cached:    true,
				Person:    stale,
			}, nil
		}
		return MetadataPersonResponse{}, sfErr
	}
	person, _ := val.(MetadataPerson)
	return MetadataPersonResponse{
		Code:      0,
		ImageBase: cfg.TmdbImageBase,
		Cached:    false,
		Person:    person,
	}, nil
}

func (s *SyncStore) MetadataBatch(ctx context.Context, req MetadataBatchRequest) (MetadataBatchResponse, error) {
	if len(req.Works) > maxMetaBatchItems || len(req.Seasons) > maxMetaBatchItems {
		return MetadataBatchResponse{}, fmt.Errorf("%w: batch limit is %d works and %d seasons", ErrInvalidInput, maxMetaBatchItems, maxMetaBatchItems)
	}
	cfg := s.loadMetadataRuntimeConfig()
	defaultLang := normalizeLang(req.Lang)

	resp := MetadataBatchResponse{
		Code:      0,
		ImageBase: cfg.TmdbImageBase,
		Works:     make(map[string]MetadataWork, len(req.Works)),
		Seasons:   make(map[string]MetadataSeason, len(req.Seasons)),
	}
	if len(req.Works) == 0 && len(req.Seasons) == 0 {
		return resp, nil
	}

	type batchJob struct {
		isWork bool
		wRef   MetadataBatchWorkRef
		sRef   MetadataBatchSeasonRef
	}
	jobs := make([]batchJob, 0, len(req.Works)+len(req.Seasons))
	for _, w := range req.Works {
		jobs = append(jobs, batchJob{isWork: true, wRef: w})
	}
	for _, sRef := range req.Seasons {
		jobs = append(jobs, batchJob{isWork: false, sRef: sRef})
	}

	var mu sync.Mutex
	errs := make(map[string]string)
	sem := make(chan struct{}, 6)
	var wg sync.WaitGroup

	for _, job := range jobs {
		wg.Add(1)
		go func(j batchJob) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			if j.isWork {
				prov := strings.ToLower(strings.TrimSpace(j.wRef.Provider))
				kind := strings.ToLower(strings.TrimSpace(j.wRef.Kind))
				id := strings.TrimSpace(j.wRef.ID)
				lang := strings.TrimSpace(j.wRef.Lang)
				if lang == "" {
					lang = defaultLang
				}
				key := fmt.Sprintf("%s:%s:%s", prov, kind, id)
				wResp, err := s.MetadataGetWork(ctx, prov, kind, id, lang, req.Refresh)
				mu.Lock()
				if err != nil {
					errs[key] = err.Error()
				} else {
					resp.Works[key] = wResp.Work
				}
				mu.Unlock()
				return
			}

			prov := strings.ToLower(strings.TrimSpace(j.sRef.Provider))
			id := strings.TrimSpace(j.sRef.ID)
			lang := strings.TrimSpace(j.sRef.Lang)
			if lang == "" {
				lang = defaultLang
			}
			key := fmt.Sprintf("%s:%s:s%d", prov, id, j.sRef.Season)
			sResp, err := s.MetadataGetSeason(ctx, prov, id, j.sRef.Season, lang, req.Refresh)
			mu.Lock()
			if err != nil {
				errs[key] = err.Error()
			} else {
				resp.Seasons[key] = sResp.Season
			}
			mu.Unlock()
		}(job)
	}
	wg.Wait()

	if len(errs) > 0 {
		resp.Errors = errs
	}
	return resp, nil
}

func (s *SyncStore) hydrateWorkCreditsLocked(work *MetadataWork) {
	if len(work.Credits) == 0 {
		return
	}
	updated := make([]MetadataCredit, len(work.Credits))
	copy(updated, work.Credits)
	for i := range updated {
		if updated[i].TmdbID == nil || *updated[i].TmdbID == "" {
			continue
		}
		var profilePath string
		if err := s.db.QueryRow(
			`SELECT profile_path FROM meta_people_cache WHERE provider = 'tmdb' AND person_id = ?`,
			*updated[i].TmdbID,
		).Scan(&profilePath); err == nil && profilePath != "" {
			pp := profilePath
			updated[i].PhotoPath = &pp
		}
	}
	work.Credits = updated
}

func (s *SyncStore) upsertPeopleFromCreditsLocked(credits []MetadataCredit, now int64) {
	exp := now + metaPersonTTLMs
	for _, c := range credits {
		if c.TmdbID == nil || strings.TrimSpace(*c.TmdbID) == "" || strings.TrimSpace(c.Name) == "" {
			continue
		}
		pp := ""
		if c.PhotoPath != nil {
			pp = *c.PhotoPath
		}
		_, _ = s.db.Exec(`
			INSERT INTO meta_people_cache (provider, person_id, name, profile_path, extra_json, fetched_at, expires_at)
			VALUES ('tmdb', ?, ?, ?, '{}', ?, ?)
			ON CONFLICT(provider, person_id) DO UPDATE SET
				name = excluded.name,
				profile_path = CASE WHEN excluded.profile_path != '' THEN excluded.profile_path ELSE meta_people_cache.profile_path END,
				fetched_at = excluded.fetched_at,
				expires_at = MAX(meta_people_cache.expires_at, excluded.expires_at)`,
			*c.TmdbID, c.Name, pp, now, exp,
		)
	}
}

// ─── TMDB Upstream Fetch & Parsing ────────────────────────────────────────

func (s *SyncStore) fetchTmdbSearch(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	kind string,
	queryStr string,
	year int,
	lang string,
) ([]MetadataCandidate, error) {
	q := url.Values{}
	q.Set("query", queryStr)
	q.Set("include_adult", "false")
	q.Set("language", lang)
	apiPath := "/search/movie"
	if kind == "show" {
		apiPath = "/search/tv"
		if year > 0 {
			q.Set("first_air_date_year", strconv.Itoa(year))
		}
	} else if year > 0 {
		q.Set("year", strconv.Itoa(year))
	}

	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbApiBase, cfg.TmdbApiKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return nil, fmt.Errorf("%w: TMDB API not found at %s", ErrMetadataUpstream, cfg.TmdbApiBase)
	}

	out := make([]MetadataCandidate, 0)
	for _, row := range jsonObjs(raw, "results") {
		id := jsonStr(row, "id")
		var title string
		if kind == "show" {
			title = jsonStr(row, "name")
		} else {
			title = jsonStr(row, "title")
		}
		if id == "" || title == "" {
			continue
		}
		origKey := "original_title"
		dateKey := "release_date"
		if kind == "show" {
			origKey = "original_name"
			dateKey = "first_air_date"
		}
		out = append(out, MetadataCandidate{
			Source:        "tmdb",
			ID:            id,
			Title:         title,
			OriginalTitle: nonEmptyStrPtr(jsonStr(row, origKey)),
			Year:          yearPtrOfDate(jsonStr(row, dateKey)),
			Summary:       nonEmptyStrPtr(jsonStr(row, "overview")),
			PosterPath:    nonEmptyStrPtr(jsonStr(row, "poster_path")),
		})
	}
	return out, nil
}

func (s *SyncStore) fetchTmdbWork(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	kind string,
	id string,
	lang string,
) (MetadataWork, error) {
	langPrefix := strings.Split(lang, "-")[0]
	q := url.Values{}
	q.Set("language", lang)
	q.Set("include_image_language", fmt.Sprintf("%s,en,null", langPrefix))

	apiPath := "/movie/" + url.PathEscape(id)
	if kind == "show" {
		apiPath = "/tv/" + url.PathEscape(id)
		q.Set("append_to_response", "credits,content_ratings,external_ids,alternative_titles,images")
	} else {
		q.Set("append_to_response", "credits,release_dates,alternative_titles,images")
	}

	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbApiBase, cfg.TmdbApiKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return MetadataWork{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return MetadataWork{}, fmt.Errorf("%w: TMDB %s %s", ErrMetadataNotFound, kind, id)
	}

	if kind == "show" {
		return parseTmdbShow(raw, id, lang), nil
	}
	return parseTmdbMovie(raw, id, lang), nil
}

func parseTmdbMovie(raw map[string]any, fallbackID, lang string) MetadataWork {
	id := jsonStr(raw, "id")
	if id == "" {
		id = fallbackID
	}
	title := jsonStr(raw, "title")
	if title == "" {
		title = jsonStr(raw, "original_title")
	}
	relDate := jsonStr(raw, "release_date")
	runtimeMin := jsonInt(raw, "runtime")
	var runtimeMs *int
	if runtimeMin != nil && *runtimeMin > 0 {
		v := (*runtimeMin) * 60000
		runtimeMs = &v
	}
	coll := jsonObj(raw, "belongs_to_collection")
	var studio *string
	if companies := jsonObjs(raw, "production_companies"); len(companies) > 0 {
		studio = nonEmptyStrPtr(jsonStr(companies[0], "name"))
	}
	genres := make([]string, 0)
	for _, g := range jsonObjs(raw, "genres") {
		if name := jsonStr(g, "name"); name != "" {
			genres = append(genres, name)
		}
	}
	cat := tmdbCategory(raw, false)
	return MetadataWork{
		Source:          "tmdb",
		Kind:            "movie",
		ExternalID:      id,
		TmdbID:          &id,
		ImdbID:          nonEmptyStrPtr(jsonStr(raw, "imdb_id")),
		Title:           title,
		OriginalTitle:   nonEmptyStrPtr(jsonStr(raw, "original_title")),
		Aliases:         parseTmdbAliases(jsonObjs(jsonObj(raw, "alternative_titles"), "titles")),
		Year:            yearPtrOfDate(relDate),
		ReleaseDate:     nonEmptyStrPtr(relDate),
		Summary:         nonEmptyStrPtr(jsonStr(raw, "overview")),
		Tagline:         nonEmptyStrPtr(jsonStr(raw, "tagline")),
		Rating:          tmdbRating(raw),
		RuntimeMs:       runtimeMs,
		ContentRating:   parseTmdbMovieCert(jsonObj(raw, "release_dates"), lang),
		Studio:          studio,
		Genres:          genres,
		PosterPath:      nonEmptyStrPtr(jsonStr(raw, "poster_path")),
		BackdropPath:    nonEmptyStrPtr(jsonStr(raw, "backdrop_path")),
		LogoPath:        parseTmdbLogoPath(jsonObj(raw, "images"), lang),
		Credits:         parseTmdbCredits(jsonObj(raw, "credits"), nil),
		CollectionID:    nonEmptyStrPtr(jsonStr(coll, "id")),
		CollectionTitle: nonEmptyStrPtr(jsonStr(coll, "name")),
		Category:        &cat,
		Status:          jsonStr(raw, "status"),
	}
}

func parseTmdbShow(raw map[string]any, fallbackID, lang string) MetadataWork {
	id := jsonStr(raw, "id")
	if id == "" {
		id = fallbackID
	}
	title := jsonStr(raw, "name")
	if title == "" {
		title = jsonStr(raw, "original_name")
	}
	firstAir := jsonStr(raw, "first_air_date")
	var runtimeMs *int
	if arr, ok := raw["episode_run_time"].([]any); ok {
		for _, item := range arr {
			if n, ok := anyInt(item); ok && n > 0 {
				v := n * 60000
				runtimeMs = &v
				break
			}
		}
	}
	ext := jsonObj(raw, "external_ids")
	var studio *string
	if networks := jsonObjs(raw, "networks"); len(networks) > 0 {
		studio = nonEmptyStrPtr(jsonStr(networks[0], "name"))
	}
	genres := make([]string, 0)
	for _, g := range jsonObjs(raw, "genres") {
		if name := jsonStr(g, "name"); name != "" {
			genres = append(genres, name)
		}
	}
	cat := tmdbCategory(raw, true)
	return MetadataWork{
		Source:        "tmdb",
		Kind:          "show",
		ExternalID:    id,
		TmdbID:        &id,
		ImdbID:        nonEmptyStrPtr(jsonStr(ext, "imdb_id")),
		TvdbID:        nonEmptyStrPtr(jsonStr(ext, "tvdb_id")),
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(jsonStr(raw, "original_name")),
		Aliases:       parseTmdbAliases(jsonObjs(jsonObj(raw, "alternative_titles"), "results")),
		Year:          yearPtrOfDate(firstAir),
		ReleaseDate:   nonEmptyStrPtr(firstAir),
		Summary:       nonEmptyStrPtr(jsonStr(raw, "overview")),
		Tagline:       nonEmptyStrPtr(jsonStr(raw, "tagline")),
		Rating:        tmdbRating(raw),
		RuntimeMs:     runtimeMs,
		ContentRating: parseTmdbShowRating(jsonObj(raw, "content_ratings"), lang),
		Studio:        studio,
		Genres:        genres,
		PosterPath:    nonEmptyStrPtr(jsonStr(raw, "poster_path")),
		BackdropPath:  nonEmptyStrPtr(jsonStr(raw, "backdrop_path")),
		LogoPath:      parseTmdbLogoPath(jsonObj(raw, "images"), lang),
		Credits:       parseTmdbCredits(jsonObj(raw, "credits"), jsonObjs(raw, "created_by")),
		Category:      &cat,
		Status:        jsonStr(raw, "status"),
	}
}

func (s *SyncStore) fetchTmdbSeason(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	showID string,
	seasonNumber int,
	lang string,
) (MetadataSeason, error) {
	q := url.Values{}
	q.Set("language", lang)
	apiPath := fmt.Sprintf("/tv/%s/season/%d", url.PathEscape(showID), seasonNumber)
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbApiBase, cfg.TmdbApiKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return MetadataSeason{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return MetadataSeason{}, fmt.Errorf("%w: TMDB show %s season %d", ErrMetadataNotFound, showID, seasonNumber)
	}
	episodes := make([]MetadataEpisode, 0)
	for _, row := range jsonObjs(raw, "episodes") {
		num := jsonInt(row, "episode_number")
		if num == nil {
			continue
		}
		var runtimeMs *int
		if rt := jsonInt(row, "runtime"); rt != nil && *rt > 0 {
			v := (*rt) * 60000
			runtimeMs = &v
		}
		episodes = append(episodes, MetadataEpisode{
			Number:    *num,
			Title:     nonEmptyStrPtr(jsonStr(row, "name")),
			Summary:   nonEmptyStrPtr(jsonStr(row, "overview")),
			AirDate:   nonEmptyStrPtr(jsonStr(row, "air_date")),
			RuntimeMs: runtimeMs,
			StillPath: nonEmptyStrPtr(jsonStr(row, "still_path")),
			Rating:    tmdbRating(row),
		})
	}
	return MetadataSeason{
		Number:     seasonNumber,
		Title:      nonEmptyStrPtr(jsonStr(raw, "name")),
		Summary:    nonEmptyStrPtr(jsonStr(raw, "overview")),
		PosterPath: nonEmptyStrPtr(jsonStr(raw, "poster_path")),
		Episodes:   episodes,
	}, nil
}

func (s *SyncStore) fetchTmdbPerson(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	personID string,
	lang string,
) (MetadataPerson, error) {
	q := url.Values{}
	q.Set("language", lang)
	apiPath := "/person/" + url.PathEscape(personID)
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbApiBase, cfg.TmdbApiKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return MetadataPerson{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return MetadataPerson{}, fmt.Errorf("%w: TMDB person %s", ErrMetadataNotFound, personID)
	}
	id := jsonStr(raw, "id")
	if id == "" {
		id = personID
	}
	return MetadataPerson{
		Provider:           "tmdb",
		PersonID:           id,
		Name:               jsonStr(raw, "name"),
		ProfilePath:        nonEmptyStrPtr(jsonStr(raw, "profile_path")),
		Biography:          nonEmptyStrPtr(jsonStr(raw, "biography")),
		Birthday:           nonEmptyStrPtr(jsonStr(raw, "birthday")),
		KnownForDepartment: nonEmptyStrPtr(jsonStr(raw, "known_for_department")),
		PlaceOfBirth:       nonEmptyStrPtr(jsonStr(raw, "place_of_birth")),
	}, nil
}

func tmdbCategory(raw map[string]any, isShow bool) string {
	genreSet := make(map[int]bool)
	for _, g := range jsonObjs(raw, "genres") {
		if id := jsonInt(g, "id"); id != nil {
			genreSet[*id] = true
		}
	}
	if genreSet[16] {
		return "anime"
	}
	if isShow && (genreSet[10764] || genreSet[10767]) {
		return "variety"
	}
	if genreSet[99] {
		return "documentary"
	}
	if isShow {
		return "show"
	}
	return "movie"
}

func tmdbRating(raw map[string]any) *float64 {
	v, ok := jsonFloat(raw, "vote_average")
	if !ok || v <= 0 {
		return nil
	}
	return &v
}

func parseTmdbAliases(rows []map[string]any) []string {
	seen := make(map[string]bool)
	var out []string
	for _, row := range rows {
		name := jsonStr(row, "title")
		if name == "" {
			continue
		}
		lower := strings.ToLower(name)
		if seen[lower] {
			continue
		}
		seen[lower] = true
		out = append(out, name)
	}
	return out
}

func parseTmdbLogoPath(images map[string]any, lang string) *string {
	logos := jsonObjs(images, "logos")
	if len(logos) == 0 {
		return nil
	}
	wanted := strings.Split(lang, "-")[0]
	var enMatch, firstMatch string
	for _, l := range logos {
		fp := jsonStr(l, "file_path")
		if fp == "" {
			continue
		}
		if firstMatch == "" {
			firstMatch = fp
		}
		iso := jsonStr(l, "iso_639_1")
		if iso == wanted {
			return &fp
		}
		if iso == "en" && enMatch == "" {
			enMatch = fp
		}
	}
	if enMatch != "" {
		return &enMatch
	}
	if firstMatch != "" {
		return &firstMatch
	}
	return nil
}

func parseTmdbMovieCert(relDates map[string]any, lang string) *string {
	region := "US"
	if parts := strings.Split(lang, "-"); len(parts) > 1 && parts[len(parts)-1] != "" {
		region = parts[len(parts)-1]
	}
	var fallback string
	for _, country := range jsonObjs(relDates, "results") {
		var cert string
		for _, r := range jsonObjs(country, "release_dates") {
			if c := jsonStr(r, "certification"); c != "" {
				cert = c
				break
			}
		}
		if cert == "" {
			continue
		}
		iso := jsonStr(country, "iso_3166_1")
		if iso == region {
			return &cert
		}
		if iso == "US" && fallback == "" {
			fallback = cert
		}
	}
	if fallback != "" {
		return &fallback
	}
	return nil
}

func parseTmdbShowRating(ratings map[string]any, lang string) *string {
	region := "US"
	if parts := strings.Split(lang, "-"); len(parts) > 1 && parts[len(parts)-1] != "" {
		region = parts[len(parts)-1]
	}
	var fallback string
	for _, row := range jsonObjs(ratings, "results") {
		rating := jsonStr(row, "rating")
		if rating == "" {
			continue
		}
		iso := jsonStr(row, "iso_3166_1")
		if iso == region {
			return &rating
		}
		if iso == "US" && fallback == "" {
			fallback = rating
		}
	}
	if fallback != "" {
		return &fallback
	}
	return nil
}

func parseTmdbCredits(credits map[string]any, creators []map[string]any) []MetadataCredit {
	const castLimit = 20
	out := make([]MetadataCredit, 0)
	for _, person := range creators {
		name := jsonStr(person, "name")
		if name == "" {
			continue
		}
		out = append(out, MetadataCredit{
			Name:      name,
			Job:       "director",
			TmdbID:    nonEmptyStrPtr(jsonStr(person, "id")),
			PhotoPath: nonEmptyStrPtr(jsonStr(person, "profile_path")),
		})
	}
	for _, person := range jsonObjs(credits, "crew") {
		name := jsonStr(person, "name")
		if name == "" {
			continue
		}
		var mappedJob string
		switch jsonStr(person, "job") {
		case "Director":
			mappedJob = "director"
		case "Screenplay", "Writer", "Story":
			mappedJob = "writer"
		default:
			continue
		}
		out = append(out, MetadataCredit{
			Name:      name,
			Job:       mappedJob,
			TmdbID:    nonEmptyStrPtr(jsonStr(person, "id")),
			PhotoPath: nonEmptyStrPtr(jsonStr(person, "profile_path")),
		})
	}
	cast := jsonObjs(credits, "cast")
	if len(cast) > castLimit {
		cast = cast[:castLimit]
	}
	for _, person := range cast {
		name := jsonStr(person, "name")
		if name == "" {
			continue
		}
		out = append(out, MetadataCredit{
			Name:      name,
			Job:       "actor",
			Character: nonEmptyStrPtr(jsonStr(person, "character")),
			TmdbID:    nonEmptyStrPtr(jsonStr(person, "id")),
			PhotoPath: nonEmptyStrPtr(jsonStr(person, "profile_path")),
		})
	}
	return out
}

// ─── Bangumi Upstream Fetch & Parsing ─────────────────────────────────────

func isBangumiNoiseTag(raw string) bool {
	name := strings.ToLower(strings.TrimSpace(raw))
	if name == "" {
		return true
	}
	return bangumiDatedTag.MatchString(name) || bangumiNoiseTags[name]
}

func (s *SyncStore) fetchBangumiSearch(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	queryStr string,
) ([]MetadataCandidate, error) {
	q := url.Values{}
	q.Set("limit", "10")
	reqBody := map[string]any{
		"keyword": queryStr,
		"filter": map[string]any{
			"type": []int{2},
		},
	}
	raw, status, err := s.bangumiRequest(ctx, cfg.BangumiApiBase, cfg.MetadataProxy, http.MethodPost, "/v0/search/subjects", q, reqBody)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return []MetadataCandidate{}, nil
	}
	out := make([]MetadataCandidate, 0)
	for _, row := range jsonObjs(raw, "data") {
		id := jsonStr(row, "id")
		if id == "" {
			continue
		}
		title := jsonStr(row, "name_cn")
		orig := jsonStr(row, "name")
		if title == "" {
			title = orig
		}
		images := jsonObj(row, "images")
		out = append(out, MetadataCandidate{
			Source:        "bangumi",
			ID:            id,
			Title:         title,
			OriginalTitle: nonEmptyStrPtr(orig),
			Year:          yearPtrOfDate(jsonStr(row, "date")),
			Summary:       nonEmptyStrPtr(jsonStr(row, "summary")),
			PosterPath:    nonEmptyStrPtr(jsonStr(images, "common")),
		})
	}
	return out, nil
}

func (s *SyncStore) fetchBangumiWork(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	kind string,
	id string,
) (MetadataWork, error) {
	raw, status, err := s.bangumiRequest(ctx, cfg.BangumiApiBase, cfg.MetadataProxy, http.MethodGet, "/v0/subjects/"+url.PathEscape(id), nil, nil)
	if err != nil {
		return MetadataWork{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return MetadataWork{}, fmt.Errorf("%w: Bangumi subject %s", ErrMetadataNotFound, id)
	}

	subjectID := jsonStr(raw, "id")
	if subjectID == "" {
		subjectID = id
	}
	title := jsonStr(raw, "name_cn")
	orig := jsonStr(raw, "name")
	if title == "" {
		title = orig
	}
	dateStr := jsonStr(raw, "date")
	images := jsonObj(raw, "images")
	poster := jsonStr(images, "large")
	if poster == "" {
		poster = jsonStr(images, "common")
	}
	var scorePtr *float64
	if ratingObj := jsonObj(raw, "rating"); ratingObj != nil {
		if sc, ok := jsonFloat(ratingObj, "score"); ok && sc > 0 {
			scorePtr = &sc
		}
	}
	genres := make([]string, 0, 6)
	for _, tag := range jsonObjs(raw, "tags") {
		if len(genres) >= 6 {
			break
		}
		if name := jsonStr(tag, "name"); name != "" && !isBangumiNoiseTag(name) {
			genres = append(genres, name)
		}
	}
	var aliases []string
	for _, box := range jsonObjs(raw, "infobox") {
		if jsonStr(box, "key") != "别名" {
			continue
		}
		switch v := box["value"].(type) {
		case string:
			if trimmed := strings.TrimSpace(v); trimmed != "" {
				aliases = append(aliases, trimmed)
			}
		case []any:
			for _, elem := range v {
				if m, ok := elem.(map[string]any); ok {
					if alias := jsonStr(m, "v"); alias != "" {
						aliases = append(aliases, alias)
					}
				}
			}
		}
	}
	cat := "anime"
	return MetadataWork{
		Source:        "bangumi",
		Kind:          kind,
		ExternalID:    subjectID,
		BangumiID:     &subjectID,
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(orig),
		Aliases:       aliases,
		Year:          yearPtrOfDate(dateStr),
		ReleaseDate:   nonEmptyStrPtr(dateStr),
		Summary:       nonEmptyStrPtr(jsonStr(raw, "summary")),
		Rating:        scorePtr,
		Genres:        genres,
		PosterPath:    nonEmptyStrPtr(poster),
		Category:      &cat,
	}, nil
}

func (s *SyncStore) fetchBangumiSeason(
	ctx context.Context,
	cfg metadataRuntimeConfig,
	subjectID string,
) (MetadataSeason, error) {
	const pageSize = 100
	episodes := make([]MetadataEpisode, 0)
	for offset := 0; ; offset += pageSize {
		q := url.Values{}
		q.Set("subject_id", subjectID)
		q.Set("type", "0")
		q.Set("limit", strconv.Itoa(pageSize))
		q.Set("offset", strconv.Itoa(offset))

		raw, status, err := s.bangumiRequest(ctx, cfg.BangumiApiBase, cfg.MetadataProxy, http.MethodGet, "/v0/episodes", q, nil)
		if err != nil {
			return MetadataSeason{}, err
		}
		if status == http.StatusNotFound || raw == nil {
			if offset == 0 {
				return MetadataSeason{}, fmt.Errorf("%w: Bangumi subject %s episodes", ErrMetadataNotFound, subjectID)
			}
			break
		}
		rows := jsonObjs(raw, "data")
		for _, row := range rows {
			epNum := jsonInt(row, "ep")
			if epNum == nil {
				if sortFloat, ok := jsonFloat(row, "sort"); ok {
					rounded := int(sortFloat + 0.5)
					epNum = &rounded
				}
			}
			if epNum == nil || *epNum <= 0 {
				continue
			}
			title := jsonStr(row, "name_cn")
			if title == "" {
				title = jsonStr(row, "name")
			}
			episodes = append(episodes, MetadataEpisode{
				Number:  *epNum,
				Title:   nonEmptyStrPtr(title),
				Summary: nonEmptyStrPtr(jsonStr(row, "desc")),
				AirDate: nonEmptyStrPtr(jsonStr(row, "airdate")),
			})
		}
		if len(rows) < pageSize {
			break
		}
	}
	return MetadataSeason{
		Number:   1,
		Episodes: episodes,
	}, nil
}

// ─── JSON Helpers ─────────────────────────────────────────────────────────

func nonNilCandidates(s []MetadataCandidate) []MetadataCandidate {
	if s == nil {
		return []MetadataCandidate{}
	}
	return s
}

func nonEmptyStrPtr(s string) *string {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func mapStrPtr(m map[string]any, key string) *string {
	if m == nil {
		return nil
	}
	return nonEmptyStrPtr(jsonStr(m, key))
}

func jsonStr(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return strings.TrimSpace(x)
	case json.Number:
		return x.String()
	case float64:
		return strconv.FormatInt(int64(x), 10)
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	default:
		return ""
	}
}

func jsonInt(m map[string]any, key string) *int {
	if m == nil {
		return nil
	}
	n, ok := anyInt(m[key])
	if !ok {
		return nil
	}
	return &n
}

func anyInt(v any) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return int(i), true
		}
		if f, err := x.Float64(); err == nil {
			return int(f), true
		}
		return 0, false
	case string:
		i, err := strconv.Atoi(strings.TrimSpace(x))
		return i, err == nil
	default:
		return 0, false
	}
}

func jsonFloat(m map[string]any, key string) (float64, bool) {
	if m == nil {
		return 0, false
	}
	switch x := m[key].(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f, err == nil
	default:
		return 0, false
	}
}

func jsonObj(m map[string]any, key string) map[string]any {
	if m == nil {
		return nil
	}
	v, ok := m[key].(map[string]any)
	if !ok {
		return nil
	}
	return v
}

func jsonObjs(m map[string]any, key string) []map[string]any {
	if m == nil {
		return nil
	}
	raw, ok := m[key].([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if sub, ok := item.(map[string]any); ok {
			out = append(out, sub)
		}
	}
	return out
}

func yearPtrOfDate(date string) *int {
	if len(date) < 4 {
		return nil
	}
	y, err := strconv.Atoi(date[:4])
	if err != nil {
		return nil
	}
	return &y
}

func latestEpisodeAirDate(eps []MetadataEpisode) string {
	latest := ""
	for _, ep := range eps {
		if ep.AirDate != nil && *ep.AirDate > latest {
			latest = *ep.AirDate
		}
	}
	return latest
}
