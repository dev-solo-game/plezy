package metadata

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

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
)

var (
	ErrNotConfigured = errors.New("tmdb api key is not configured")
	ErrDisabled      = errors.New("metadata provider is disabled")
	ErrNotFound      = errors.New("metadata not found")
	ErrUpstream      = errors.New("metadata upstream request failed")
	ErrTmdbUpstream  = errors.New("tmdb upstream unreachable")
	ErrInvalidInput  = errors.New("invalid metadata query parameters")
)

const (
	metaSearchTTLMs int64 = 24 * 60 * 60 * 1000
	metaShortTTLMs  int64 = 24 * 60 * 60 * 1000
	metaLongTTLMs   int64 = 30 * 24 * 60 * 60 * 1000
	metaPersonTTLMs int64 = 30 * 24 * 60 * 60 * 1000

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

type CacheStats struct {
	Works    int64 `json:"works"`
	Seasons  int64 `json:"seasons"`
	People   int64 `json:"people"`
	Searches int64 `json:"searches"`
}

type Candidate struct {
	Source        string  `json:"source"`
	ID            string  `json:"id"`
	Title         string  `json:"title"`
	OriginalTitle *string `json:"original_title,omitempty"`
	Year          *int    `json:"year,omitempty"`
	Summary       *string `json:"summary,omitempty"`
	PosterPath    *string `json:"poster_path,omitempty"`
}

type Credit struct {
	Name      string  `json:"name"`
	Job       string  `json:"job"`
	Character *string `json:"character,omitempty"`
	TmdbID    *string `json:"tmdb_id,omitempty"`
	PhotoPath *string `json:"photo_path,omitempty"`
}

type Work struct {
	Source          string   `json:"source"`
	Kind            string   `json:"kind"`
	ExternalID      string   `json:"external_id"`
	TmdbID          *string  `json:"tmdb_id,omitempty"`
	ImdbID          *string  `json:"imdb_id,omitempty"`
	TvdbID          *string  `json:"tvdb_id,omitempty"`
	BangumiID       *string  `json:"bangumi_id,omitempty"`
	DoubanID        *string  `json:"douban_id,omitempty"`
	AniListID       *string  `json:"anilist_id,omitempty"`
	Title           string   `json:"title"`
	OriginalTitle   *string  `json:"original_title,omitempty"`
	Aliases         []string `json:"aliases,omitempty"`
	Year            *int     `json:"year,omitempty"`
	ReleaseDate     *string  `json:"release_date,omitempty"`
	Summary         *string  `json:"summary,omitempty"`
	Tagline         *string  `json:"tagline,omitempty"`
	Rating          *float64 `json:"rating,omitempty"`
	RuntimeMs       *int64   `json:"runtime_ms,omitempty"`
	ContentRating   *string  `json:"content_rating,omitempty"`
	Studio          *string  `json:"studio,omitempty"`
	Genres          []string `json:"genres,omitempty"`
	PosterPath      *string  `json:"poster_path,omitempty"`
	BackdropPath    *string  `json:"backdrop_path,omitempty"`
	LogoPath        *string  `json:"logo_path,omitempty"`
	Credits         []Credit `json:"credits,omitempty"`
	CollectionID    *string  `json:"collection_id,omitempty"`
	CollectionTitle *string  `json:"collection_title,omitempty"`
	Category        *string  `json:"category,omitempty"`
	Status          string   `json:"status,omitempty"`
}

type Episode struct {
	Number    int      `json:"number"`
	Title     *string  `json:"title,omitempty"`
	Summary   *string  `json:"summary,omitempty"`
	AirDate   *string  `json:"air_date,omitempty"`
	RuntimeMs *int64   `json:"runtime_ms,omitempty"`
	StillPath *string  `json:"still_path,omitempty"`
	Rating    *float64 `json:"rating,omitempty"`
}

type Season struct {
	Number     int       `json:"number"`
	Title      *string   `json:"title,omitempty"`
	Summary    *string   `json:"summary,omitempty"`
	AirDate    *string   `json:"air_date,omitempty"`
	PosterPath *string   `json:"poster_path,omitempty"`
	Episodes   []Episode `json:"episodes"`
}

type Person struct {
	Provider           string  `json:"provider"`
	PersonID           string  `json:"person_id"`
	Name               string  `json:"name"`
	ProfilePath        *string `json:"profile_path,omitempty"`
	Biography          *string `json:"biography,omitempty"`
	Birthday           *string `json:"birthday,omitempty"`
	KnownForDepartment *string `json:"known_for_department,omitempty"`
	PlaceOfBirth       *string `json:"place_of_birth,omitempty"`
}

var (
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

func IsBangumiNoiseTag(raw string) bool {
	name := strings.ToLower(strings.TrimSpace(raw))
	if name == "" {
		return true
	}
	return bangumiDatedTag.MatchString(name) || bangumiNoiseTags[name]
}

type Service struct {
	store        *db.Store
	flight       *sfGroup
	httpMu       sync.Mutex
	httpClients  map[string]*http.Client
	nowFn        func() int64
	tvdbMu       sync.Mutex
	tvdbToken    string
	tvdbTokenKey string
	tvdbTokenExp time.Time
}

func NewService(store *db.Store) *Service {
	return &Service{
		store:       store,
		flight:      &sfGroup{},
		httpClients: make(map[string]*http.Client),
		nowFn:       func() int64 { return time.Now().UnixMilli() },
	}
}

func (s *Service) SetNowFunc(fn func() int64) {
	if fn != nil {
		s.nowFn = fn
	}
}

func (s *Service) HTTPClientForProxy(proxyRaw string) (*http.Client, error) {
	proxyKey := strings.TrimSpace(proxyRaw)
	s.httpMu.Lock()
	defer s.httpMu.Unlock()
	if cli, ok := s.httpClients[proxyKey]; ok {
		return cli, nil
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if proxyKey != "" {
		proxyURL, err := db.ParseProxyURL(proxyKey)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrUpstream, err)
		}
		tr.Proxy = http.ProxyURL(proxyURL)
	}
	cli := &http.Client{
		Timeout:   20 * time.Second,
		Transport: tr,
	}
	s.httpClients[proxyKey] = cli
	return cli, nil
}

func (s *Service) CacheStats() CacheStats {
	var st CacheStats
	d := s.store.DB()
	_ = d.QueryRow(`SELECT COUNT(*) FROM meta_works_cache`).Scan(&st.Works)
	_ = d.QueryRow(`SELECT COUNT(*) FROM meta_seasons_cache`).Scan(&st.Seasons)
	_ = d.QueryRow(`SELECT COUNT(*) FROM meta_people_cache`).Scan(&st.People)
	_ = d.QueryRow(`SELECT COUNT(*) FROM meta_search_cache`).Scan(&st.Searches)
	return st
}

func (s *Service) ClearCache(scope string) (int64, CacheStats, error) {
	norm := strings.ToLower(strings.TrimSpace(scope))
	if norm == "" {
		norm = "all"
	}
	var tables []string
	switch norm {
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
		return 0, CacheStats{}, fmt.Errorf("%w: unknown cache scope %q", ErrInvalidInput, scope)
	}
	var deleted int64
	for _, tbl := range tables {
		res, err := s.store.DB().Exec(`DELETE FROM ` + tbl)
		if err != nil {
			return deleted, CacheStats{}, err
		}
		n, _ := res.RowsAffected()
		deleted += n
	}
	applog.Infof("metadata", "已清理元数据缓存 scope=%s 删除=%d 条", norm, deleted)
	return deleted, s.CacheStats(), nil
}

func (s *Service) TestTmdbConnection(ctx context.Context, overrideKey, overrideBase, overrideProxy *string) (int64, error) {
	cfg := s.store.GetServerSettings()
	key := cfg.TmdbAPIKey
	if overrideKey != nil && strings.TrimSpace(*overrideKey) != "" {
		key = strings.TrimSpace(*overrideKey)
	}
	if key == "" {
		return 0, ErrNotConfigured
	}
	apiBase := cfg.TmdbAPIBase
	if overrideBase != nil && strings.TrimSpace(*overrideBase) != "" {
		apiBase = db.NormalizeTmdbBase(*overrideBase, db.DefaultTmdbAPIBase, "/3")
	}
	proxy := cfg.MetadataProxy
	if overrideProxy != nil {
		proxy = strings.TrimSpace(*overrideProxy)
	}

	start := time.Now()
	_, status, err := s.tmdbRequest(ctx, apiBase, key, proxy, "/configuration", nil)
	if err != nil {
		applog.Warnf("metadata", "TMDB 连通性测试失败 base=%s: %v", apiBase, err)
		return 0, err
	}
	if status == http.StatusNotFound {
		applog.Warnf("metadata", "TMDB 连通性测试返回 404: base=%s", apiBase)
		return 0, fmt.Errorf("%w: %w: TMDB API not found at %s", ErrTmdbUpstream, ErrUpstream, apiBase)
	}
	ms := time.Since(start).Milliseconds()
	applog.Infof("metadata", "TMDB 连通性测试成功 base=%s 延迟=%dms", apiBase, ms)
	return ms, nil
}

type ProviderTestOverrides struct {
	APIKey        *string `json:"api_key,omitempty"`
	Pin           *string `json:"pin,omitempty"`
	Token         *string `json:"token,omitempty"`
	Cookie        *string `json:"cookie,omitempty"`
	APIBase       *string `json:"api_base,omitempty"`
	MetadataProxy *string `json:"metadata_proxy,omitempty"`
}

func (s *Service) TestProviderConnection(ctx context.Context, provider string, ov ProviderTestOverrides) (int64, string, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	cfg := s.store.GetServerSettings()
	if ov.MetadataProxy != nil {
		cfg.MetadataProxy = strings.TrimSpace(*ov.MetadataProxy)
	}
	start := time.Now()
	switch prov {
	case "tmdb":
		ms, err := s.TestTmdbConnection(ctx, ov.APIKey, ov.APIBase, ov.MetadataProxy)
		if err != nil {
			return 0, "", err
		}
		return ms, "TMDB 连接正常", nil
	case "douban":
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.DoubanAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultDoubanAPIBase)
		}
		if ov.Cookie != nil && strings.TrimSpace(*ov.Cookie) != "" {
			cfg.DoubanCookie = strings.TrimSpace(*ov.Cookie)
		}
		cands, err := s.fetchDoubanSearch(ctx, cfg, "movie", "肖申克的救赎")
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("豆瓣连通正常，返回 %d 条测试结果", len(cands)), nil
	case "bangumi":
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.BangumiAPIBase = db.NormalizeBangumiBase(*ov.APIBase)
		}
		if ov.Token != nil && strings.TrimSpace(*ov.Token) != "" {
			cfg.BangumiToken = strings.TrimSpace(*ov.Token)
		}
		cands, err := s.fetchBangumiSearch(ctx, cfg, "芙莉莲")
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("Bangumi 连通正常，返回 %d 条测试结果", len(cands)), nil
	case "anilist":
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.AniListAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultAniListAPIBase)
		}
		cands, err := s.fetchAniListSearch(ctx, cfg, "show", "Frieren")
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("AniList GraphQL 连通正常，返回 %d 条测试结果", len(cands)), nil
	case "imdb":
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.ImdbAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultImdbAPIBase)
		}
		cands, err := s.fetchImdbSearch(ctx, cfg, "movie", "Inception")
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("IMDb 数据源连通正常，返回 %d 条测试结果", len(cands)), nil
	case "tvdb":
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.TvdbAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultTvdbAPIBase)
		}
		if ov.APIKey != nil && strings.TrimSpace(*ov.APIKey) != "" {
			cfg.TvdbAPIKey = strings.TrimSpace(*ov.APIKey)
		}
		if ov.Pin != nil && strings.TrimSpace(*ov.Pin) != "" {
			cfg.TvdbPin = strings.TrimSpace(*ov.Pin)
		}
		if cfg.TvdbAPIKey == "" {
			return 0, "", fmt.Errorf("%w: thetvdb api key is not configured", ErrNotConfigured)
		}
		if _, err := s.tvdbLoginToken(ctx, cfg, true); err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), "TheTvDb 登录鉴权正常", nil
	default:
		return 0, "", fmt.Errorf("%w: unsupported provider %q", ErrInvalidInput, provider)
	}
}

func (s *Service) doUpstreamBytes(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	headers map[string]string,
	reqBody any,
	service string,
) ([]byte, int, error) {
	cli, err := s.HTTPClientForProxy(proxyRaw)
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
		return nil, 0, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if _, hasAccept := headers["Accept"]; !hasAccept {
		req.Header.Set("Accept", "application/json")
	}
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	start := time.Now()
	resp, err := cli.Do(req)
	if err != nil {
		redacted := applog.RedactURL(err.Error())
		applog.Warnf("metadata", "%s HTTP 请求失败 (%dms): %s -> %s", service, time.Since(start).Milliseconds(), applog.RedactURL(rawURL), redacted)
		return nil, 0, fmt.Errorf("%w: %s request failed: %s", ErrUpstream, service, redacted)
	}
	defer resp.Body.Close()
	elapsedMs := time.Since(start).Milliseconds()

	if resp.StatusCode == http.StatusNotFound {
		applog.Debugf("metadata", "HTTP %s %s -> 404 (%dms)", method, applog.RedactURL(rawURL), elapsedMs)
		return nil, http.StatusNotFound, nil
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		applog.Warnf("metadata", "%s 鉴权失败 HTTP %d (%dms): %s", service, resp.StatusCode, elapsedMs, applog.RedactURL(rawURL))
		return nil, resp.StatusCode, fmt.Errorf("%w: %s rejected credentials (HTTP %d)", ErrUpstream, service, resp.StatusCode)
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		applog.Warnf("metadata", "%s 触发限流 HTTP 429 (%dms): %s", service, elapsedMs, applog.RedactURL(rawURL))
		return nil, resp.StatusCode, fmt.Errorf("%w: %s is rate limiting (HTTP 429)", ErrUpstream, service)
	}
	if resp.StatusCode >= 400 {
		applog.Warnf("metadata", "%s 返回异常状态 HTTP %d (%dms): %s", service, resp.StatusCode, elapsedMs, applog.RedactURL(rawURL))
		return nil, resp.StatusCode, fmt.Errorf("%w: %s returned HTTP %d", ErrUpstream, service, resp.StatusCode)
	}

	rawBytes, err := io.ReadAll(io.LimitReader(resp.Body, metaUpstreamBodyLimit))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%w: read %s response failed: %v", ErrUpstream, service, err)
	}
	applog.Debugf("metadata", "HTTP %s %s -> %d (%dms)", method, applog.RedactURL(rawURL), resp.StatusCode, elapsedMs)
	return rawBytes, resp.StatusCode, nil
}

func (s *Service) doUpstreamJSON(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	headers map[string]string,
	reqBody any,
	service string,
) (map[string]any, int, error) {
	rawBytes, status, err := s.doUpstreamBytes(ctx, method, rawURL, proxyRaw, headers, reqBody, service)
	if err != nil || status == http.StatusNotFound {
		return nil, status, err
	}
	dec := json.NewDecoder(bytes.NewReader(rawBytes))
	dec.UseNumber()
	var parsed map[string]any
	if err := dec.Decode(&parsed); err != nil {
		applog.Warnf("metadata", "%s 响应 JSON 解析失败: %v", service, err)
		return nil, status, fmt.Errorf("%w: invalid %s JSON: %v", ErrUpstream, service, err)
	}
	return parsed, status, nil
}

func (s *Service) doUpstreamJSONAny(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	headers map[string]string,
	reqBody any,
	service string,
) (any, int, error) {
	rawBytes, status, err := s.doUpstreamBytes(ctx, method, rawURL, proxyRaw, headers, reqBody, service)
	if err != nil || status == http.StatusNotFound {
		return nil, status, err
	}
	dec := json.NewDecoder(bytes.NewReader(rawBytes))
	dec.UseNumber()
	var parsed any
	if err := dec.Decode(&parsed); err != nil {
		applog.Warnf("metadata", "%s 响应 JSON 解析失败: %v", service, err)
		return nil, status, fmt.Errorf("%w: invalid %s JSON: %v", ErrUpstream, service, err)
	}
	return parsed, status, nil
}

func (s *Service) tmdbRequest(
	ctx context.Context,
	apiBase, apiKey, proxyRaw, apiPath string,
	query url.Values,
) (map[string]any, int, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, 0, ErrNotConfigured
	}
	u, err := url.Parse(apiBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: %w: invalid TMDB API base: %v", ErrTmdbUpstream, ErrUpstream, err)
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
	parsed, status, err := s.doUpstreamJSON(ctx, http.MethodGet, u.String(), proxyRaw, headers, nil, "TMDB")
	if err != nil {
		return nil, status, fmt.Errorf("%w: %w", ErrTmdbUpstream, err)
	}
	return parsed, status, nil
}

func (s *Service) bangumiRequest(
	ctx context.Context,
	apiBase, token, proxyRaw, method, apiPath string,
	query url.Values,
	body any,
) (map[string]any, int, error) {
	u, err := url.Parse(apiBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: invalid Bangumi API base: %v", ErrUpstream, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + apiPath
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	headers := map[string]string{
		"User-Agent": "ttplay-media-server/1.0 (anime metadata lookup)",
	}
	if strings.TrimSpace(token) != "" {
		headers["Authorization"] = "Bearer " + strings.TrimSpace(token)
	}
	return s.doUpstreamJSON(ctx, method, u.String(), proxyRaw, headers, body, "Bangumi")
}

func normalizeLang(raw string) string {
	t := strings.TrimSpace(raw)
	if t == "" {
		return "zh-CN"
	}
	return t
}

func computeWorkSeasonTTLMs(status, releaseDate string, now int64) int64 {
	st := strings.TrimSpace(strings.ToLower(status))
	if st == "returning series" || st == "in production" || st == "planned" {
		return metaShortTTLMs
	}
	trimmed := strings.TrimSpace(releaseDate)
	if trimmed == "" {
		return metaShortTTLMs
	}
	t, err := time.Parse("2006-01-02", trimmed)
	if err != nil {
		return metaShortTTLMs
	}
	if time.UnixMilli(now).Sub(t) < 90*24*time.Hour {
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

func checkProviderAccess(prov string, cfg db.ServerSettings) error {
	switch prov {
	case "tmdb":
		if cfg.TmdbAPIKey == "" {
			return ErrNotConfigured
		}
		return nil
	case "bangumi":
		if !cfg.BangumiEnabled {
			return ErrDisabled
		}
		return nil
	case "douban":
		if !cfg.DoubanEnabled {
			return ErrDisabled
		}
		return nil
	case "anilist":
		if !cfg.AniListEnabled {
			return ErrDisabled
		}
		return nil
	case "imdb":
		if !cfg.ImdbEnabled {
			return ErrDisabled
		}
		return nil
	case "tvdb":
		if !cfg.TvdbEnabled {
			return ErrDisabled
		}
		if cfg.TvdbAPIKey == "" {
			return fmt.Errorf("%w: thetvdb api key is not configured", ErrNotConfigured)
		}
		return nil
	default:
		return fmt.Errorf("%w: unsupported provider %q", ErrInvalidInput, prov)
	}
}

func effectiveLangForProvider(prov, lang string) string {
	switch prov {
	case "tmdb", "tvdb":
		return normalizeLang(lang)
	default:
		return "default"
	}
}

type findExternalEnvelope struct {
	Movie []Candidate `json:"movie,omitempty"`
	Show  []Candidate `json:"show,omitempty"`
}

// FindByExternalID queries TMDB /find/{external_id} using an IMDb ("imdb_id")
// or TheTVDB ("tvdb_id") identifier to bridge external sources back to TMDB.
func (s *Service) FindByExternalID(ctx context.Context, externalSource, externalID, preferredKind, lang string, refresh bool) (*Candidate, string, error) {
	src := strings.ToLower(strings.TrimSpace(externalSource))
	extID := strings.TrimSpace(externalID)
	if (src != "imdb_id" && src != "tvdb_id") || extID == "" {
		return nil, "", fmt.Errorf("%w: invalid external_id lookup", ErrInvalidInput)
	}
	cfg := s.store.GetServerSettings()
	if cfg.TmdbAPIKey == "" {
		return nil, "", ErrNotConfigured
	}
	if lang == "" {
		lang = cfg.ScraperLang
	}
	effectiveLang := normalizeLang(lang)
	now := s.nowFn()
	ck := searchCacheKey("tmdb_find", src, extID, 0, effectiveLang)

	pickEnvelope := func(env findExternalEnvelope) (*Candidate, string) {
		pref := strings.ToLower(strings.TrimSpace(preferredKind))
		if pref == "show" {
			if len(env.Show) > 0 {
				c := env.Show[0]
				return &c, "show"
			}
			if len(env.Movie) > 0 {
				c := env.Movie[0]
				return &c, "movie"
			}
		} else {
			if len(env.Movie) > 0 {
				c := env.Movie[0]
				return &c, "movie"
			}
			if len(env.Show) > 0 {
				c := env.Show[0]
				return &c, "show"
			}
		}
		return nil, ""
	}

	var payloadJSON string
	var expiresAt int64
	if !refresh {
		err := s.store.DB().QueryRow(
			`SELECT payload_json, expires_at FROM meta_search_cache WHERE cache_key = ?`, ck,
		).Scan(&payloadJSON, &expiresAt)
		if err == nil && payloadJSON != "" && expiresAt > now {
			var cached findExternalEnvelope
			if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
				c, k := pickEnvelope(cached)
				applog.Debugf("metadata", "外键反查缓存命中 [tmdb_find/%s=%s] -> found=%v", src, extID, c != nil)
				return c, k, nil
			}
		}
	}

	val, sfErr := s.flight.Do("find:"+ck, func() (any, error) {
		start := time.Now()
		freshCfg := s.store.GetServerSettings()
		if freshCfg.TmdbAPIKey == "" {
			return nil, ErrNotConfigured
		}
		q := url.Values{}
		q.Set("external_source", src)
		q.Set("language", effectiveLang)
		apiPath := "/find/" + url.PathEscape(extID)
		raw, status, err := s.tmdbRequest(ctx, freshCfg.TmdbAPIBase, freshCfg.TmdbAPIKey, freshCfg.MetadataProxy, apiPath, q)
		if err != nil {
			applog.Warnf("metadata", "TMDB 外键反查失败 [%s=%s] (%dms): %s", src, extID, time.Since(start).Milliseconds(), applog.RedactURL(err.Error()))
			return nil, err
		}
		var env findExternalEnvelope
		if status != http.StatusNotFound && raw != nil {
			for _, row := range jsonObjs(raw, "movie_results") {
				id := jsonStr(row, "id")
				title := jsonStr(row, "title")
				if id == "" || title == "" {
					continue
				}
				env.Movie = append(env.Movie, Candidate{
					Source:        "tmdb",
					ID:            id,
					Title:         title,
					OriginalTitle: nonEmptyStrPtr(jsonStr(row, "original_title")),
					Year:          yearPtrOfDate(jsonStr(row, "release_date")),
					Summary:       nonEmptyStrPtr(jsonStr(row, "overview")),
					PosterPath:    nonEmptyStrPtr(jsonStr(row, "poster_path")),
				})
			}
			for _, row := range jsonObjs(raw, "tv_results") {
				id := jsonStr(row, "id")
				title := jsonStr(row, "name")
				if id == "" || title == "" {
					continue
				}
				env.Show = append(env.Show, Candidate{
					Source:        "tmdb",
					ID:            id,
					Title:         title,
					OriginalTitle: nonEmptyStrPtr(jsonStr(row, "original_name")),
					Year:          yearPtrOfDate(jsonStr(row, "first_air_date")),
					Summary:       nonEmptyStrPtr(jsonStr(row, "overview")),
					PosterPath:    nonEmptyStrPtr(jsonStr(row, "poster_path")),
				})
			}
		}
		applog.Infof("metadata", "TMDB 外键反查 [%s=%s] -> movie=%d tv=%d (%dms)", src, extID, len(env.Movie), len(env.Show), time.Since(start).Milliseconds())
		b, _ := json.Marshal(env)
		writeNow := s.nowFn()
		_, _ = s.store.DB().Exec(`
			INSERT OR REPLACE INTO meta_search_cache(cache_key, provider, kind, query, year, lang, payload_json, fetched_at, expires_at)
			VALUES (?, 'tmdb_find', ?, ?, 0, ?, ?, ?, ?)`,
			ck, src, extID, effectiveLang, string(b), writeNow, writeNow+metaSearchTTLMs,
		)
		return env, nil
	})
	if sfErr != nil {
		return nil, "", sfErr
	}
	env, _ := val.(findExternalEnvelope)
	c, k := pickEnvelope(env)
	return c, k, nil
}

func (s *Service) Search(ctx context.Context, provider, kind, query string, year int, lang string, refresh bool) ([]Candidate, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	k := strings.ToLower(strings.TrimSpace(kind))
	q := strings.TrimSpace(query)
	if (k != "movie" && k != "show") || q == "" {
		return nil, fmt.Errorf("%w: invalid search parameters", ErrInvalidInput)
	}
	cfg := s.store.GetServerSettings()
	if err := checkProviderAccess(prov, cfg); err != nil {
		return nil, err
	}
	if lang == "" {
		lang = cfg.ScraperLang
	}
	effectiveLang := effectiveLangForProvider(prov, lang)

	now := s.nowFn()
	ck := searchCacheKey(prov, k, q, year, effectiveLang)
	var stale []Candidate
	var hasStale bool

	var payloadJSON string
	var expiresAt int64
	err := s.store.DB().QueryRow(
		`SELECT payload_json, expires_at FROM meta_search_cache WHERE cache_key = ?`, ck,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached []Candidate
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				applog.Debugf("metadata", "搜索缓存命中 [%s/%s] year=%d -> %d 条候选", prov, k, year, len(cached))
				return cached, nil
			}
		}
	}

	val, sfErr := s.flight.Do("search:"+ck, func() (any, error) {
		start := time.Now()
		freshCfg := s.store.GetServerSettings()
		var fetched []Candidate
		var fErr error
		switch prov {
		case "tmdb":
			fetched, fErr = s.fetchTmdbSearch(ctx, freshCfg, k, q, year, effectiveLang)
		case "bangumi":
			fetched, fErr = s.fetchBangumiSearch(ctx, freshCfg, q)
		case "douban":
			fetched, fErr = s.fetchDoubanSearch(ctx, freshCfg, k, q)
		case "anilist":
			fetched, fErr = s.fetchAniListSearch(ctx, freshCfg, k, q)
		case "imdb":
			fetched, fErr = s.fetchImdbSearch(ctx, freshCfg, k, q)
		case "tvdb":
			fetched, fErr = s.fetchTvdbSearch(ctx, freshCfg, k, q, year, effectiveLang)
		default:
			fErr = fmt.Errorf("%w: unsupported provider %q", ErrInvalidInput, prov)
		}
		if fErr != nil {
			applog.Errorf("metadata", "上游搜索失败 [%s/%s] year=%d (%dms): %s", prov, k, year, time.Since(start).Milliseconds(), applog.RedactURL(fErr.Error()))
			return nil, fErr
		}
		if fetched == nil {
			fetched = []Candidate{}
		}
		applog.Infof("metadata", "上游搜索 [%s/%s] year=%d lang=%s refresh=%v -> %d 条候选 (%dms)", prov, k, year, effectiveLang, refresh, len(fetched), time.Since(start).Milliseconds())
		raw, _ := json.Marshal(fetched)
		writeNow := s.nowFn()
		_, _ = s.store.DB().Exec(`
			INSERT OR REPLACE INTO meta_search_cache(cache_key, provider, kind, query, year, lang, payload_json, fetched_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			ck, prov, k, q, year, effectiveLang, string(raw), writeNow, writeNow+metaSearchTTLMs,
		)
		return fetched, nil
	})
	if sfErr != nil {
		if prov != "tmdb" && !refresh && hasStale && errors.Is(sfErr, ErrUpstream) {
			return stale, nil
		}
		return nil, sfErr
	}
	res, _ := val.([]Candidate)
	return res, nil
}

func (s *Service) GetWork(ctx context.Context, provider, kind, externalID, lang string, refresh bool) (Work, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	k := strings.ToLower(strings.TrimSpace(kind))
	id := strings.TrimSpace(externalID)
	if (k != "movie" && k != "show") || id == "" {
		return Work{}, fmt.Errorf("%w: invalid work parameters", ErrInvalidInput)
	}
	cfg := s.store.GetServerSettings()
	if err := checkProviderAccess(prov, cfg); err != nil {
		return Work{}, err
	}
	if lang == "" {
		lang = cfg.ScraperLang
	}
	effectiveLang := effectiveLangForProvider(prov, lang)

	now := s.nowFn()
	var stale Work
	var hasStale bool

	var payloadJSON string
	var expiresAt int64
	err := s.store.DB().QueryRow(
		`SELECT payload_json, expires_at FROM meta_works_cache WHERE provider = ? AND kind = ? AND external_id = ? AND lang = ?`,
		prov, k, id, effectiveLang,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached Work
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			if prov == "tmdb" {
				s.hydrateWorkCredits(&cached)
			}
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				applog.Debugf("metadata", "作品详情缓存命中 [%s/%s:%s]", prov, k, id)
				return cached, nil
			}
		}
	}

	flightKey := fmt.Sprintf("work:%s:%s:%s:%s", prov, k, id, effectiveLang)
	val, sfErr := s.flight.Do(flightKey, func() (any, error) {
		start := time.Now()
		freshCfg := s.store.GetServerSettings()
		var fetched Work
		var fErr error
		switch prov {
		case "tmdb":
			fetched, fErr = s.fetchTmdbWork(ctx, freshCfg, k, id, effectiveLang)
		case "bangumi":
			fetched, fErr = s.fetchBangumiWork(ctx, freshCfg, k, id)
		case "douban":
			fetched, fErr = s.fetchDoubanWork(ctx, freshCfg, k, id)
		case "anilist":
			fetched, fErr = s.fetchAniListWork(ctx, freshCfg, k, id)
		case "imdb":
			fetched, fErr = s.fetchImdbWork(ctx, freshCfg, k, id)
		case "tvdb":
			fetched, fErr = s.fetchTvdbWork(ctx, freshCfg, k, id, effectiveLang)
		default:
			fErr = fmt.Errorf("%w: unsupported provider %q", ErrInvalidInput, prov)
		}
		if fErr != nil {
			applog.Errorf("metadata", "拉取作品详情失败 [%s/%s:%s] (%dms): %s", prov, k, id, time.Since(start).Milliseconds(), applog.RedactURL(fErr.Error()))
			return nil, fErr
		}
		applog.Infof("metadata", "拉取作品详情 [%s/%s:%s] (%dms)", prov, k, id, time.Since(start).Milliseconds())
		writeNow := s.nowFn()
		relDate := ""
		if fetched.ReleaseDate != nil {
			relDate = *fetched.ReleaseDate
		}
		ttl := computeWorkSeasonTTLMs(fetched.Status, relDate, writeNow)
		raw, _ := json.Marshal(fetched)
		_, _ = s.store.DB().Exec(`
			INSERT OR REPLACE INTO meta_works_cache(provider, kind, external_id, lang, payload_json, status, release_date, fetched_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			prov, k, id, effectiveLang, string(raw), fetched.Status, relDate, writeNow, writeNow+ttl,
		)
		if prov == "tmdb" {
			s.upsertPeopleFromCredits(fetched.Credits, writeNow)
		}
		return fetched, nil
	})
	if sfErr != nil {
		if prov != "tmdb" && !refresh && hasStale && errors.Is(sfErr, ErrUpstream) {
			return stale, nil
		}
		return Work{}, sfErr
	}
	w, _ := val.(Work)
	return w, nil
}

func (s *Service) GetSeason(ctx context.Context, provider, externalID string, seasonNumber int, lang string, refresh bool) (Season, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	id := strings.TrimSpace(externalID)
	if id == "" || seasonNumber < 0 {
		return Season{}, fmt.Errorf("%w: invalid season parameters", ErrInvalidInput)
	}
	if prov == "douban" || prov == "anilist" || prov == "imdb" {
		return Season{}, ErrNotFound
	}
	if prov == "bangumi" && seasonNumber != 1 {
		return Season{}, ErrNotFound
	}
	cfg := s.store.GetServerSettings()
	if err := checkProviderAccess(prov, cfg); err != nil {
		return Season{}, err
	}
	if lang == "" {
		lang = cfg.ScraperLang
	}
	effectiveLang := effectiveLangForProvider(prov, lang)

	now := s.nowFn()
	var stale Season
	var hasStale bool

	var payloadJSON string
	var expiresAt int64
	err := s.store.DB().QueryRow(
		`SELECT payload_json, expires_at FROM meta_seasons_cache WHERE provider = ? AND external_id = ? AND season_number = ? AND lang = ?`,
		prov, id, seasonNumber, effectiveLang,
	).Scan(&payloadJSON, &expiresAt)
	if err == nil && payloadJSON != "" {
		var cached Season
		if json.Unmarshal([]byte(payloadJSON), &cached) == nil {
			stale = cached
			hasStale = true
			if !refresh && expiresAt > now {
				return cached, nil
			}
		}
	}

	flightKey := fmt.Sprintf("season:%s:%s:%d:%s", prov, id, seasonNumber, effectiveLang)
	val, sfErr := s.flight.Do(flightKey, func() (any, error) {
		freshCfg := s.store.GetServerSettings()
		var fetched Season
		var fErr error
		switch prov {
		case "tmdb":
			fetched, fErr = s.fetchTmdbSeason(ctx, freshCfg, id, seasonNumber, effectiveLang)
		case "bangumi":
			fetched, fErr = s.fetchBangumiSeason(ctx, freshCfg, id)
		case "tvdb":
			fetched, fErr = s.fetchTvdbSeason(ctx, freshCfg, id, seasonNumber, effectiveLang)
		default:
			fErr = ErrNotFound
		}
		if fErr != nil {
			return nil, fErr
		}
		writeNow := s.nowFn()
		raw, _ := json.Marshal(fetched)
		var workStatus, workRelDate string
		_ = s.store.DB().QueryRow(
			`SELECT status, release_date FROM meta_works_cache WHERE provider = ? AND kind = 'show' AND external_id = ? AND lang = ?`,
			prov, id, effectiveLang,
		).Scan(&workStatus, &workRelDate)
		refDate := latestEpisodeAirDate(fetched.Episodes)
		if refDate == "" {
			refDate = workRelDate
		}
		ttl := computeWorkSeasonTTLMs(workStatus, refDate, writeNow)
		_, _ = s.store.DB().Exec(`
			INSERT OR REPLACE INTO meta_seasons_cache(provider, external_id, season_number, lang, payload_json, fetched_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			prov, id, seasonNumber, effectiveLang, string(raw), writeNow, writeNow+ttl,
		)
		return fetched, nil
	})
	if sfErr != nil {
		if prov != "tmdb" && !refresh && hasStale && errors.Is(sfErr, ErrUpstream) {
			return stale, nil
		}
		return Season{}, sfErr
	}
	se, _ := val.(Season)
	return se, nil
}

func (s *Service) GetPerson(ctx context.Context, provider, personID, lang string, refresh bool) (Person, error) {
	prov := strings.ToLower(strings.TrimSpace(provider))
	pid := strings.TrimSpace(personID)
	if prov != "tmdb" || pid == "" {
		return Person{}, ErrNotFound
	}
	cfg := s.store.GetServerSettings()
	if cfg.TmdbAPIKey == "" {
		return Person{}, ErrNotConfigured
	}
	if lang == "" {
		lang = cfg.ScraperLang
	}
	effectiveLang := normalizeLang(lang)
	now := s.nowFn()

	var name, profilePath, extraJSON string
	var expiresAt int64
	var stale Person
	var hasStale bool
	err := s.store.DB().QueryRow(
		`SELECT name, profile_path, extra_json, expires_at FROM meta_people_cache WHERE provider = ? AND person_id = ?`,
		prov, pid,
	).Scan(&name, &profilePath, &extraJSON, &expiresAt)
	if err == nil && name != "" {
		var extra map[string]any
		_ = json.Unmarshal([]byte(extraJSON), &extra)
		person := Person{
			Provider:           prov,
			PersonID:           pid,
			Name:               name,
			ProfilePath:        nonEmptyStrPtr(profilePath),
			Biography:          mapStrPtr(extra, "biography"),
			Birthday:           mapStrPtr(extra, "birthday"),
			KnownForDepartment: mapStrPtr(extra, "known_for_department"),
			PlaceOfBirth:       mapStrPtr(extra, "place_of_birth"),
		}
		if isFull, _ := extra["_full"].(bool); isFull {
			stale = person
			hasStale = true
			if !refresh && expiresAt > now {
				return person, nil
			}
		}
	}

	flightKey := fmt.Sprintf("person:%s:%s:%s", prov, pid, effectiveLang)
	val, sfErr := s.flight.Do(flightKey, func() (any, error) {
		freshCfg := s.store.GetServerSettings()
		person, fErr := s.fetchTmdbPerson(ctx, freshCfg, pid, effectiveLang)
		if fErr != nil {
			return nil, fErr
		}
		writeNow := s.nowFn()
		extra := map[string]any{"_full": true}
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
		_, _ = s.store.DB().Exec(`
			INSERT OR REPLACE INTO meta_people_cache(provider, person_id, name, profile_path, extra_json, fetched_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			prov, pid, person.Name, pp, string(extraRaw), writeNow, writeNow+metaPersonTTLMs,
		)
		return person, nil
	})
	if sfErr != nil {
		if hasStale && errors.Is(sfErr, ErrUpstream) {
			return stale, nil
		}
		return Person{}, sfErr
	}
	p, _ := val.(Person)
	return p, nil
}

func (s *Service) hydrateWorkCredits(work *Work) {
	if len(work.Credits) == 0 {
		return
	}
	for i := range work.Credits {
		if work.Credits[i].TmdbID == nil || *work.Credits[i].TmdbID == "" {
			continue
		}
		var profilePath string
		if err := s.store.DB().QueryRow(
			`SELECT profile_path FROM meta_people_cache WHERE provider = 'tmdb' AND person_id = ?`,
			*work.Credits[i].TmdbID,
		).Scan(&profilePath); err == nil && profilePath != "" {
			pp := profilePath
			work.Credits[i].PhotoPath = &pp
		}
	}
}

func (s *Service) upsertPeopleFromCredits(credits []Credit, now int64) {
	exp := now + metaPersonTTLMs
	for _, c := range credits {
		if c.TmdbID == nil || strings.TrimSpace(*c.TmdbID) == "" || strings.TrimSpace(c.Name) == "" {
			continue
		}
		pp := ""
		if c.PhotoPath != nil {
			pp = *c.PhotoPath
		}
		_, _ = s.store.DB().Exec(`
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

// ─── TMDB & Bangumi Fetchers ──────────────────────────────────────────────

func (s *Service) fetchTmdbSearch(ctx context.Context, cfg db.ServerSettings, kind, queryStr string, year int, lang string) ([]Candidate, error) {
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
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbAPIBase, cfg.TmdbAPIKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return nil, fmt.Errorf("%w: %w: TMDB API not found at %s", ErrTmdbUpstream, ErrUpstream, cfg.TmdbAPIBase)
	}
	out := make([]Candidate, 0)
	for _, row := range jsonObjs(raw, "results") {
		id := jsonStr(row, "id")
		title := jsonStr(row, "title")
		origKey, dateKey := "original_title", "release_date"
		if kind == "show" {
			title = jsonStr(row, "name")
			origKey, dateKey = "original_name", "first_air_date"
		}
		if id == "" || title == "" {
			continue
		}
		out = append(out, Candidate{
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

func (s *Service) fetchTmdbWork(ctx context.Context, cfg db.ServerSettings, kind, id, lang string) (Work, error) {
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
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbAPIBase, cfg.TmdbAPIKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return Work{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Work{}, fmt.Errorf("%w: TMDB %s %s", ErrNotFound, kind, id)
	}
	if kind == "show" {
		return parseTmdbShow(raw, id, lang), nil
	}
	return parseTmdbMovie(raw, id, lang), nil
}

func parseTmdbMovie(raw map[string]any, fallbackID, lang string) Work {
	id := jsonStr(raw, "id")
	if id == "" {
		id = fallbackID
	}
	title := jsonStr(raw, "title")
	if title == "" {
		title = jsonStr(raw, "original_title")
	}
	relDate := jsonStr(raw, "release_date")
	var runtimeMs *int64
	if rm := jsonInt(raw, "runtime"); rm != nil && *rm > 0 {
		v := int64(*rm) * 60000
		runtimeMs = &v
	}
	coll := jsonObj(raw, "belongs_to_collection")
	var studio *string
	if comps := jsonObjs(raw, "production_companies"); len(comps) > 0 {
		studio = nonEmptyStrPtr(jsonStr(comps[0], "name"))
	}
	genres := make([]string, 0)
	for _, g := range jsonObjs(raw, "genres") {
		if name := jsonStr(g, "name"); name != "" {
			genres = append(genres, name)
		}
	}
	cat := tmdbCategory(raw, false)
	return Work{
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

func parseTmdbShow(raw map[string]any, fallbackID, lang string) Work {
	id := jsonStr(raw, "id")
	if id == "" {
		id = fallbackID
	}
	title := jsonStr(raw, "name")
	if title == "" {
		title = jsonStr(raw, "original_name")
	}
	firstAir := jsonStr(raw, "first_air_date")
	var runtimeMs *int64
	if arr, ok := raw["episode_run_time"].([]any); ok {
		for _, item := range arr {
			if n, ok := anyInt(item); ok && n > 0 {
				v := int64(n) * 60000
				runtimeMs = &v
				break
			}
		}
	}
	ext := jsonObj(raw, "external_ids")
	var studio *string
	if nets := jsonObjs(raw, "networks"); len(nets) > 0 {
		studio = nonEmptyStrPtr(jsonStr(nets[0], "name"))
	}
	genres := make([]string, 0)
	for _, g := range jsonObjs(raw, "genres") {
		if name := jsonStr(g, "name"); name != "" {
			genres = append(genres, name)
		}
	}
	cat := tmdbCategory(raw, true)
	return Work{
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

func (s *Service) fetchTmdbSeason(ctx context.Context, cfg db.ServerSettings, showID string, seasonNumber int, lang string) (Season, error) {
	q := url.Values{}
	q.Set("language", lang)
	apiPath := fmt.Sprintf("/tv/%s/season/%d", url.PathEscape(showID), seasonNumber)
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbAPIBase, cfg.TmdbAPIKey, cfg.MetadataProxy, apiPath, q)
	if err != nil {
		return Season{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Season{}, fmt.Errorf("%w: TMDB show %s season %d", ErrNotFound, showID, seasonNumber)
	}
	episodes := make([]Episode, 0)
	for _, row := range jsonObjs(raw, "episodes") {
		num := jsonInt(row, "episode_number")
		if num == nil {
			continue
		}
		var runtimeMs *int64
		if rt := jsonInt(row, "runtime"); rt != nil && *rt > 0 {
			v := int64(*rt) * 60000
			runtimeMs = &v
		}
		episodes = append(episodes, Episode{
			Number:    *num,
			Title:     nonEmptyStrPtr(jsonStr(row, "name")),
			Summary:   nonEmptyStrPtr(jsonStr(row, "overview")),
			AirDate:   nonEmptyStrPtr(jsonStr(row, "air_date")),
			RuntimeMs: runtimeMs,
			StillPath: nonEmptyStrPtr(jsonStr(row, "still_path")),
			Rating:    tmdbRating(row),
		})
	}
	return Season{
		Number:     seasonNumber,
		Title:      nonEmptyStrPtr(jsonStr(raw, "name")),
		Summary:    nonEmptyStrPtr(jsonStr(raw, "overview")),
		AirDate:    nonEmptyStrPtr(jsonStr(raw, "air_date")),
		PosterPath: nonEmptyStrPtr(jsonStr(raw, "poster_path")),
		Episodes:   episodes,
	}, nil
}

func (s *Service) fetchTmdbPerson(ctx context.Context, cfg db.ServerSettings, personID, lang string) (Person, error) {
	q := url.Values{}
	q.Set("language", lang)
	raw, status, err := s.tmdbRequest(ctx, cfg.TmdbAPIBase, cfg.TmdbAPIKey, cfg.MetadataProxy, "/person/"+url.PathEscape(personID), q)
	if err != nil {
		return Person{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Person{}, fmt.Errorf("%w: TMDB person %s", ErrNotFound, personID)
	}
	id := jsonStr(raw, "id")
	if id == "" {
		id = personID
	}
	return Person{
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
		return db.ShelfAnime
	}
	if isShow && (genreSet[10764] || genreSet[10767]) {
		return db.ShelfVariety
	}
	if genreSet[99] {
		return db.ShelfDocumentary
	}
	if isShow {
		return db.ShelfShow
	}
	return db.ShelfMovie
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
		low := strings.ToLower(name)
		if seen[low] {
			continue
		}
		seen[low] = true
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

func parseTmdbCredits(credits map[string]any, creators []map[string]any) []Credit {
	const castLimit = 20
	out := make([]Credit, 0)
	for _, person := range creators {
		name := jsonStr(person, "name")
		if name == "" {
			continue
		}
		out = append(out, Credit{
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
		out = append(out, Credit{
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
		out = append(out, Credit{
			Name:      name,
			Job:       "actor",
			Character: nonEmptyStrPtr(jsonStr(person, "character")),
			TmdbID:    nonEmptyStrPtr(jsonStr(person, "id")),
			PhotoPath: nonEmptyStrPtr(jsonStr(person, "profile_path")),
		})
	}
	return out
}

func (s *Service) fetchBangumiSearch(ctx context.Context, cfg db.ServerSettings, queryStr string) ([]Candidate, error) {
	q := url.Values{}
	q.Set("limit", "10")
	reqBody := map[string]any{
		"keyword": queryStr,
		"filter": map[string]any{
			"type": []int{2},
		},
	}
	raw, status, err := s.bangumiRequest(ctx, cfg.BangumiAPIBase, cfg.BangumiToken, cfg.MetadataProxy, http.MethodPost, "/v0/search/subjects", q, reqBody)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return []Candidate{}, nil
	}
	out := make([]Candidate, 0)
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
		out = append(out, Candidate{
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

func (s *Service) fetchBangumiWork(ctx context.Context, cfg db.ServerSettings, kind, id string) (Work, error) {
	raw, status, err := s.bangumiRequest(ctx, cfg.BangumiAPIBase, cfg.BangumiToken, cfg.MetadataProxy, http.MethodGet, "/v0/subjects/"+url.PathEscape(id), nil, nil)
	if err != nil {
		return Work{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Work{}, fmt.Errorf("%w: Bangumi subject %s", ErrNotFound, id)
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
		if name := jsonStr(tag, "name"); name != "" && !IsBangumiNoiseTag(name) {
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
	cat := db.ShelfAnime
	return Work{
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

func (s *Service) fetchBangumiSeason(ctx context.Context, cfg db.ServerSettings, subjectID string) (Season, error) {
	const pageSize = 100
	episodes := make([]Episode, 0)
	for offset := 0; ; offset += pageSize {
		q := url.Values{}
		q.Set("subject_id", subjectID)
		q.Set("type", "0")
		q.Set("limit", strconv.Itoa(pageSize))
		q.Set("offset", strconv.Itoa(offset))

		raw, status, err := s.bangumiRequest(ctx, cfg.BangumiAPIBase, cfg.BangumiToken, cfg.MetadataProxy, http.MethodGet, "/v0/episodes", q, nil)
		if err != nil {
			return Season{}, err
		}
		if status == http.StatusNotFound || raw == nil {
			if offset == 0 {
				return Season{}, fmt.Errorf("%w: Bangumi subject %s episodes", ErrNotFound, subjectID)
			}
			break
		}
		rows := jsonObjs(raw, "data")
		for _, row := range rows {
			epNum := jsonInt(row, "ep")
			if epNum == nil {
				if sf, ok := jsonFloat(row, "sort"); ok {
					r := int(sf + 0.5)
					epNum = &r
				}
			}
			if epNum == nil || *epNum <= 0 {
				continue
			}
			title := jsonStr(row, "name_cn")
			if title == "" {
				title = jsonStr(row, "name")
			}
			episodes = append(episodes, Episode{
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
	return Season{Number: 1, Episodes: episodes}, nil
}

// ─── JSON helpers ─────────────────────────────────────────────────────────

func nonEmptyStrPtr(s string) *string {
	t := strings.TrimSpace(s)
	if t == "" {
		return nil
	}
	return &t
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
	v, _ := m[key].(map[string]any)
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

func latestEpisodeAirDate(eps []Episode) string {
	latest := ""
	for _, ep := range eps {
		if ep.AirDate != nil && *ep.AirDate > latest {
			latest = *ep.AirDate
		}
	}
	return latest
}
