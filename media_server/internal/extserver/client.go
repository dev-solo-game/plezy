package extserver

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	ErrUnauthorized = errors.New("external server authentication failed")
	ErrNotFound     = errors.New("external item not found")
	ErrBadRequest   = errors.New("invalid external server parameters")
	ErrUpstream     = errors.New("external server request failed")
)

type HTTPError struct {
	Status int
	Body   string
}

func (e *HTTPError) Error() string {
	if e.Body != "" {
		return fmt.Sprintf("HTTP %d: %s", e.Status, e.Body)
	}
	return fmt.Sprintf("HTTP %d", e.Status)
}

func NormalizeBaseURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", fmt.Errorf("%w: server URL is empty", ErrBadRequest)
	}
	if !strings.Contains(trimmed, "://") {
		trimmed = "http://" + trimmed
	}
	u, err := url.Parse(trimmed)
	if err != nil {
		return "", fmt.Errorf("%w: invalid server URL: %v", ErrBadRequest, err)
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", fmt.Errorf("%w: unsupported URL scheme %q", ErrBadRequest, u.Scheme)
	}
	if strings.TrimSpace(u.Host) == "" {
		return "", fmt.Errorf("%w: server host is required", ErrBadRequest)
	}
	u.RawQuery = ""
	u.Fragment = ""
	out := strings.TrimRight(u.String(), "/")
	return out, nil
}

type Client struct {
	cfg          ServerConfig
	baseURL      string
	apiClient    *http.Client
	streamClient *http.Client
}

func NewClient(cfg ServerConfig) (*Client, error) {
	base, err := NormalizeBaseURL(cfg.BaseURL)
	if err != nil {
		return nil, err
	}
	kind := strings.ToLower(strings.TrimSpace(cfg.Kind))
	if kind != "emby" && kind != "jellyfin" {
		kind = "jellyfin"
	}
	cfg.Kind = kind
	cfg.BaseURL = base
	if strings.TrimSpace(cfg.DeviceID) == "" {
		cfg.DeviceID = "ttplay-web"
	}

	dialer := &net.Dialer{
		Timeout:   15 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	tlsCfg := &tls.Config{InsecureSkipVerify: cfg.AllowInsecureTLS} //nolint:gosec // user-controlled self-signed option

	apiTransport := &http.Transport{
		DialContext:           dialer.DialContext,
		TLSClientConfig:       tlsCfg,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		MaxIdleConns:          32,
		IdleConnTimeout:       60 * time.Second,
	}
	streamTransport := &http.Transport{
		DialContext:           dialer.DialContext,
		TLSClientConfig:       tlsCfg,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		MaxIdleConns:          32,
		IdleConnTimeout:       90 * time.Second,
	}

	return &Client{
		cfg:     cfg,
		baseURL: base,
		apiClient: &http.Client{
			Timeout:   25 * time.Second,
			Transport: apiTransport,
		},
		streamClient: &http.Client{
			Timeout:   0,
			Transport: streamTransport,
		},
	}, nil
}

func (c *Client) Config() ServerConfig {
	out := c.cfg
	out.BaseURL = c.baseURL
	return out
}

func (c *Client) BaseURL() string {
	return c.baseURL
}

func (c *Client) Kind() string {
	return c.cfg.Kind
}

func (c *Client) TokenQueryParam() string {
	if c.cfg.Kind == "emby" {
		return "api_key"
	}
	return "ApiKey"
}

func encodeAuthComponent(val string) string {
	// MediaBrowser expects RFC 3986 percent-encoding (spaces as %20, not +).
	return strings.ReplaceAll(url.QueryEscape(val), "+", "%20")
}

func (c *Client) authHeader(includeToken bool) string {
	parts := []string{
		fmt.Sprintf(`Client="%s"`, encodeAuthComponent("TTPlay Server")),
		fmt.Sprintf(`Device="%s"`, encodeAuthComponent("TTPlay Web")),
		fmt.Sprintf(`DeviceId="%s"`, encodeAuthComponent(c.cfg.DeviceID)),
		fmt.Sprintf(`Version="%s"`, encodeAuthComponent("1.0")),
	}
	if includeToken && strings.TrimSpace(c.cfg.Token) != "" {
		parts = append(parts, fmt.Sprintf(`Token="%s"`, encodeAuthComponent(strings.TrimSpace(c.cfg.Token))))
	}
	return "MediaBrowser " + strings.Join(parts, ", ")
}

func (c *Client) doAPIRequest(ctx context.Context, method, relPath string, body any, withToken bool) ([]byte, int, error) {
	var bodyReader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		bodyReader = bytes.NewReader(raw)
	}
	target := c.baseURL + relPath
	req, err := http.NewRequestWithContext(ctx, method, target, bodyReader)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", c.authHeader(withToken))
	if withToken && strings.TrimSpace(c.cfg.Token) != "" {
		req.Header.Set("X-Emby-Token", strings.TrimSpace(c.cfg.Token))
	}

	resp, err := c.apiClient.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return respBytes, resp.StatusCode, fmt.Errorf("%w: HTTP %d", ErrUnauthorized, resp.StatusCode)
	}
	if resp.StatusCode == http.StatusNotFound {
		return respBytes, resp.StatusCode, &HTTPError{Status: resp.StatusCode, Body: strings.TrimSpace(string(respBytes))}
	}
	if resp.StatusCode >= 400 {
		msg := strings.TrimSpace(string(respBytes))
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return respBytes, resp.StatusCode, &HTTPError{Status: resp.StatusCode, Body: msg}
	}
	return respBytes, resp.StatusCode, nil
}

func (c *Client) getJSON(ctx context.Context, relPath string, out any) error {
	raw, _, err := c.doAPIRequest(ctx, http.MethodGet, relPath, nil, true)
	if err != nil {
		return err
	}
	if out == nil || len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	return json.Unmarshal(raw, out)
}

func (c *Client) getJSONWithFallback(ctx context.Context, primaryPath, fallbackPath string, out any) error {
	err := c.getJSON(ctx, primaryPath, out)
	if err != nil && fallbackPath != "" && fallbackPath != primaryPath {
		var httpErr *HTTPError
		if errors.As(err, &httpErr) && httpErr.Status == http.StatusNotFound {
			return c.getJSON(ctx, fallbackPath, out)
		}
	}
	return err
}

func is404(err error) bool {
	var httpErr *HTTPError
	return errors.As(err, &httpErr) && httpErr.Status == http.StatusNotFound
}

func detectKindFromProductName(productName string) string {
	lower := strings.ToLower(strings.TrimSpace(productName))
	switch {
	case strings.Contains(lower, "emby"):
		return "emby"
	case strings.Contains(lower, "jellyfin"):
		return "jellyfin"
	default:
		return ""
	}
}

func (c *Client) Probe(ctx context.Context) (ServerInfo, error) {
	type publicInfo struct {
		ID          string `json:"Id"`
		ServerName  string `json:"ServerName"`
		Version     string `json:"Version"`
		ProductName string `json:"ProductName"`
	}

	raw, status, err := c.doAPIRequest(ctx, http.MethodGet, "/System/Info/Public", nil, false)
	if err != nil && (status == http.StatusNotFound || is404(err)) && !strings.HasSuffix(strings.ToLower(c.baseURL), "/emby") {
		origBase := c.baseURL
		c.baseURL = origBase + "/emby"
		raw2, _, err2 := c.doAPIRequest(ctx, http.MethodGet, "/System/Info/Public", nil, false)
		if err2 == nil {
			raw = raw2
			err = nil
		} else {
			c.baseURL = origBase
		}
	}
	if err != nil {
		return ServerInfo{}, err
	}
	var pi publicInfo
	if err := json.Unmarshal(raw, &pi); err != nil {
		return ServerInfo{}, fmt.Errorf("%w: unexpected server response (not Emby/Jellyfin JSON)", ErrUpstream)
	}
	if strings.TrimSpace(pi.ID) == "" && strings.TrimSpace(pi.ServerName) == "" {
		return ServerInfo{}, fmt.Errorf("%w: server response missing Id/ServerName", ErrUpstream)
	}
	name := strings.TrimSpace(pi.ServerName)
	if name == "" {
		name = "Media Server"
	}
	return ServerInfo{
		ServerName:       name,
		ServerID:         pi.ID,
		Version:          pi.Version,
		ProductName:      pi.ProductName,
		DetectedKind:     detectKindFromProductName(pi.ProductName),
		EffectiveBaseURL: c.baseURL,
	}, nil
}

func (c *Client) AuthenticateByName(ctx context.Context, username, password string) (AuthResult, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		return AuthResult{}, fmt.Errorf("%w: username is required", ErrBadRequest)
	}
	info, err := c.Probe(ctx)
	if err != nil {
		return AuthResult{}, err
	}

	payload := map[string]string{
		"Username": username,
		"Pw":       password,
	}
	raw, _, err := c.doAPIRequest(ctx, http.MethodPost, "/Users/AuthenticateByName", payload, false)
	if err != nil {
		return AuthResult{}, err
	}
	var resp struct {
		AccessToken string `json:"AccessToken"`
		User        struct {
			ID   string `json:"Id"`
			Name string `json:"Name"`
		} `json:"User"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return AuthResult{}, fmt.Errorf("%w: invalid authentication JSON", ErrUpstream)
	}
	if strings.TrimSpace(resp.AccessToken) == "" || strings.TrimSpace(resp.User.ID) == "" {
		return AuthResult{}, fmt.Errorf("%w: empty AccessToken or User.Id", ErrUnauthorized)
	}

	c.cfg.Token = resp.AccessToken
	c.cfg.UserID = resp.User.ID
	uName := resp.User.Name
	if uName == "" {
		uName = username
	}
	return AuthResult{
		AccessToken: resp.AccessToken,
		UserID:      resp.User.ID,
		Username:    uName,
		ServerInfo:  info,
	}, nil
}

func (c *Client) VerifyAPIKey(ctx context.Context, apiKey, userHint string) (AuthResult, error) {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return AuthResult{}, fmt.Errorf("%w: api_key is required", ErrBadRequest)
	}
	info, err := c.Probe(ctx)
	if err != nil {
		return AuthResult{}, err
	}
	c.cfg.Token = apiKey

	// Validate the key works on an authenticated system endpoint.
	var sys struct {
		ID string `json:"Id"`
	}
	if err := c.getJSON(ctx, "/System/Info", &sys); err != nil {
		return AuthResult{}, err
	}

	type rawUser struct {
		ID     string `json:"Id"`
		Name   string `json:"Name"`
		Policy struct {
			IsAdministrator bool `json:"IsAdministrator"`
			IsDisabled      bool `json:"IsDisabled"`
		} `json:"Policy"`
	}
	var users []rawUser
	if err := c.getJSON(ctx, "/Users", &users); err != nil {
		return AuthResult{}, err
	}
	if len(users) == 0 {
		return AuthResult{}, fmt.Errorf("%w: no users returned for API key", ErrUnauthorized)
	}

	hint := strings.TrimSpace(userHint)
	var chosen *rawUser
	if hint != "" {
		for i := range users {
			if strings.EqualFold(users[i].ID, hint) || strings.EqualFold(users[i].Name, hint) {
				chosen = &users[i]
				break
			}
		}
		if chosen == nil {
			return AuthResult{}, fmt.Errorf("%w: user %q not found on server", ErrBadRequest, hint)
		}
	} else {
		for i := range users {
			if users[i].Policy.IsAdministrator && !users[i].Policy.IsDisabled {
				chosen = &users[i]
				break
			}
		}
		if chosen == nil {
			for i := range users {
				if !users[i].Policy.IsDisabled {
					chosen = &users[i]
					break
				}
			}
		}
		if chosen == nil {
			chosen = &users[0]
		}
	}

	c.cfg.UserID = chosen.ID
	return AuthResult{
		AccessToken: apiKey,
		UserID:      chosen.ID,
		Username:    chosen.Name,
		ServerInfo:  info,
	}, nil
}

func (c *Client) VerifySession(ctx context.Context) (ServerInfo, error) {
	info, err := c.Probe(ctx)
	if err != nil {
		return ServerInfo{}, err
	}
	uid := url.PathEscape(c.cfg.UserID)
	var u struct {
		ID   string `json:"Id"`
		Name string `json:"Name"`
	}
	if c.cfg.Kind == "emby" {
		if err := c.getJSON(ctx, "/Users/"+uid, &u); err != nil {
			return ServerInfo{}, err
		}
	} else {
		if err := c.getJSONWithFallback(ctx, "/Users/Me", "/Users/"+uid, &u); err != nil {
			return ServerInfo{}, err
		}
	}
	return info, nil
}

// ---------- Wire DTOs ----------

type rawImageTags struct {
	Primary string `json:"Primary"`
	Thumb   string `json:"Thumb"`
	Logo    string `json:"Logo"`
}

type rawUserData struct {
	Played                bool  `json:"Played"`
	IsFavorite            bool  `json:"IsFavorite"`
	PlaybackPositionTicks int64 `json:"PlaybackPositionTicks"`
	UnplayedItemCount     int   `json:"UnplayedItemCount"`
}

type rawMediaStream struct {
	Index           int    `json:"Index"`
	Type            string `json:"Type"`
	Codec           string `json:"Codec"`
	Language        string `json:"Language"`
	DisplayTitle    string `json:"DisplayTitle"`
	Title           string `json:"Title"`
	IsDefault       bool   `json:"IsDefault"`
	IsForced        bool   `json:"IsForced"`
	IsExternal      bool   `json:"IsExternal"`
	IsTextSubtitle  bool   `json:"IsTextSubtitleStream"`
	DeliveryURL     string `json:"DeliveryUrl"`
	DeliveryMethod  string `json:"DeliveryMethod"`
	Width           int    `json:"Width"`
	Height          int    `json:"Height"`
	VideoRange      string `json:"VideoRange"`
	VideoRangeType  string `json:"VideoRangeType"`
	Channels        int    `json:"Channels"`
	BitRate         int    `json:"BitRate"`
}

type rawMediaSource struct {
	ID                   string           `json:"Id"`
	Name                 string           `json:"Name"`
	Container            string           `json:"Container"`
	Path                 string           `json:"Path"`
	Size                 int64            `json:"Size"`
	Bitrate              int              `json:"Bitrate"`
	RunTimeTicks         int64            `json:"RunTimeTicks"`
	SupportsDirectPlay   bool             `json:"SupportsDirectPlay"`
	SupportsDirectStream bool             `json:"SupportsDirectStream"`
	SupportsTranscoding  bool             `json:"SupportsTranscoding"`
	TranscodingURL       string           `json:"TranscodingUrl"`
	DirectStreamURL      string           `json:"DirectStreamUrl"`
	MediaStreams         []rawMediaStream `json:"MediaStreams"`
}

type rawPerson struct {
	ID              string `json:"Id"`
	Name            string `json:"Name"`
	Role            string `json:"Role"`
	Type            string `json:"Type"`
	PrimaryImageTag string `json:"PrimaryImageTag"`
}

type rawNameID struct {
	Name string `json:"Name"`
}

type rawBaseItem struct {
	ID                      string           `json:"Id"`
	Name                    string           `json:"Name"`
	OriginalTitle           string           `json:"OriginalTitle"`
	Type                    string           `json:"Type"`
	CollectionType          string           `json:"CollectionType"`
	Overview                string           `json:"Overview"`
	ProductionYear          int              `json:"ProductionYear"`
	PremiereDate            string           `json:"PremiereDate"`
	CommunityRating         float64          `json:"CommunityRating"`
	OfficialRating          string           `json:"OfficialRating"`
	RunTimeTicks            int64            `json:"RunTimeTicks"`
	ParentIndexNumber       int              `json:"ParentIndexNumber"`
	IndexNumber             int              `json:"IndexNumber"`
	SeriesID                string           `json:"SeriesId"`
	SeriesName              string           `json:"SeriesName"`
	SeriesPrimaryImageTag   string           `json:"SeriesPrimaryImageTag"`
	SeasonID                string           `json:"SeasonId"`
	ImageTags               map[string]string `json:"ImageTags"`
	BackdropImageTags       []string         `json:"BackdropImageTags"`
	ParentBackdropItemID    string           `json:"ParentBackdropItemId"`
	ParentBackdropImageTags []string         `json:"ParentBackdropImageTags"`
	UserData                *rawUserData     `json:"UserData"`
	ChildCount              int              `json:"ChildCount"`
	Genres                  []string         `json:"Genres"`
	Taglines                []string         `json:"Taglines"`
	Studios                 []rawNameID      `json:"Studios"`
	MediaSources            []rawMediaSource `json:"MediaSources"`
	MediaStreams            []rawMediaStream `json:"MediaStreams"`
	People                  []rawPerson      `json:"People"`
	Video3DFormat           string           `json:"Video3DFormat"`
	HasSubtitles            bool             `json:"HasSubtitles"`
}

type rawItemsEnvelope struct {
	Items            []rawBaseItem `json:"Items"`
	TotalRecordCount int           `json:"TotalRecordCount"`
}

const ticksPerMs = 10000

func (c *Client) proxyImageURL(itemID, imageType string, maxWidth int, tag string) string {
	if strings.TrimSpace(c.cfg.ID) == "" || strings.TrimSpace(itemID) == "" {
		return ""
	}
	u := fmt.Sprintf("/api/v1/ext/%s/image/%s/%s?maxWidth=%d",
		url.PathEscape(c.cfg.ID),
		url.PathEscape(itemID),
		url.PathEscape(imageType),
		maxWidth,
	)
	if strings.TrimSpace(tag) != "" {
		u += "&tag=" + url.QueryEscape(tag)
	}
	return u
}

func mapRawKind(rawType string) string {
	switch strings.ToLower(strings.TrimSpace(rawType)) {
	case "movie":
		return "movie"
	case "series":
		return "show"
	case "season":
		return "season"
	case "episode":
		return "episode"
	case "boxset":
		return "boxset"
	case "playlist":
		return "playlist"
	default:
		return "video"
	}
}

func (c *Client) mapItem(dto rawBaseItem) ExtItem {
	poster := ""
	if tag := dto.ImageTags["Primary"]; tag != "" {
		poster = c.proxyImageURL(dto.ID, "Primary", 500, tag)
	} else if dto.SeriesID != "" && dto.SeriesPrimaryImageTag != "" {
		poster = c.proxyImageURL(dto.SeriesID, "Primary", 500, dto.SeriesPrimaryImageTag)
	}

	backdrop := ""
	if len(dto.BackdropImageTags) > 0 && dto.BackdropImageTags[0] != "" {
		backdrop = c.proxyImageURL(dto.ID, "Backdrop", 1280, dto.BackdropImageTags[0])
	} else if dto.ParentBackdropItemID != "" && len(dto.ParentBackdropImageTags) > 0 && dto.ParentBackdropImageTags[0] != "" {
		backdrop = c.proxyImageURL(dto.ParentBackdropItemID, "Backdrop", 1280, dto.ParentBackdropImageTags[0])
	}

	thumb := ""
	if tag := dto.ImageTags["Thumb"]; tag != "" {
		thumb = c.proxyImageURL(dto.ID, "Thumb", 780, tag)
	} else if backdrop != "" {
		thumb = backdrop
	} else {
		thumb = poster
	}

	var watched, fav bool
	var posMs int64
	var unplayed int
	if dto.UserData != nil {
		watched = dto.UserData.Played
		fav = dto.UserData.IsFavorite
		posMs = dto.UserData.PlaybackPositionTicks / ticksPerMs
		unplayed = dto.UserData.UnplayedItemCount
	}

	var tagline string
	if len(dto.Taglines) > 0 {
		tagline = dto.Taglines[0]
	}
	studios := make([]string, 0, len(dto.Studios))
	for _, st := range dto.Studios {
		if strings.TrimSpace(st.Name) != "" {
			studios = append(studios, st.Name)
		}
	}

	qBadge, hdrBadge := badgesFromStreams(dto.MediaStreams)
	if qBadge == "" && hdrBadge == "" && len(dto.MediaSources) > 0 {
		qBadge, hdrBadge = badgesFromStreams(dto.MediaSources[0].MediaStreams)
	}

	return ExtItem{
		ID:             dto.ID,
		Kind:           mapRawKind(dto.Type),
		RawType:        dto.Type,
		Title:          dto.Name,
		OriginalTitle:  dto.OriginalTitle,
		Year:           dto.ProductionYear,
		PremiereDate:   dto.PremiereDate,
		Overview:       dto.Overview,
		Rating:         dto.CommunityRating,
		OfficialRating: dto.OfficialRating,
		RuntimeMs:      dto.RunTimeTicks / ticksPerMs,
		SeasonNumber:   dto.ParentIndexNumber,
		EpisodeNumber:  dto.IndexNumber,
		SeriesID:       dto.SeriesID,
		SeriesName:     dto.SeriesName,
		SeasonID:       dto.SeasonID,
		PosterURL:      poster,
		BackdropURL:    backdrop,
		ThumbURL:       thumb,
		Watched:        watched,
		Favorite:       fav,
		PositionMs:     posMs,
		UnplayedCount:  unplayed,
		ChildCount:     dto.ChildCount,
		QualityBadge:   qBadge,
		HdrBadge:       hdrBadge,
		Genres:         dto.Genres,
		Tagline:        tagline,
		Studios:        studios,
	}
}

func badgesFromStreams(streams []rawMediaStream) (quality, hdr string) {
	for _, st := range streams {
		if !strings.EqualFold(st.Type, "Video") {
			continue
		}
		if st.Width >= 3800 || st.Height >= 2100 {
			quality = "4K"
		} else if st.Width >= 1900 || st.Height >= 1060 {
			quality = "1080P"
		}
		vr := strings.ToUpper(st.VideoRangeType + " " + st.VideoRange)
		switch {
		case strings.Contains(vr, "DOVI") || strings.Contains(vr, "DOLBY"):
			hdr = "DV"
		case strings.Contains(vr, "HDR"):
			hdr = "HDR"
		}
		break
	}
	return quality, hdr
}

func evaluateExtSourceCompat(container string, streams []ExtMediaStream) (bool, string) {
	c := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(container, ".")))
	if idx := strings.IndexByte(c, ','); idx >= 0 {
		c = strings.TrimSpace(c[:idx])
	}
	switch c {
	case "avi", "wmv", "rmvb", "rm", "flv", "ts", "mts", "m2ts", "vob", "iso":
		return false, "容器格式 (" + strings.ToUpper(c) + ") 浏览器原生不支持直接解码，建议使用服务端 HLS 转码或呼起本地播放器"
	}

	var hasAudio, hasBrowserAudio bool
	var audioCodecs []string
	var videoCodec string

	for _, st := range streams {
		switch strings.ToLower(st.Type) {
		case "video":
			if videoCodec == "" {
				videoCodec = strings.ToLower(st.Codec)
			}
		case "audio":
			hasAudio = true
			ac := strings.ToLower(st.Codec)
			if ac != "" {
				audioCodecs = append(audioCodecs, strings.ToUpper(ac))
			}
			switch ac {
			case "aac", "mp3", "opus", "flac", "vorbis", "pcm", "pcm_s16le", "pcm_s24le":
				hasBrowserAudio = true
			}
		}
	}

	if hasAudio && !hasBrowserAudio {
		return false, "音轨编码 (" + strings.Join(audioCodecs, "/") + ") 浏览器可能无法播放或无声，建议使用服务端 HLS 转码或外部播放器"
	}
	if videoCodec == "mpeg2video" || videoCodec == "mpeg4" || videoCodec == "vc1" || videoCodec == "wmv3" {
		return false, "视频编码 (" + strings.ToUpper(videoCodec) + ") 浏览器支持受限，建议使用服务端 HLS 转码或外部播放器"
	}
	return true, ""
}

func (c *Client) mapMediaSource(ms rawMediaSource) ExtMediaSource {
	out := ExtMediaSource{
		ID:                   ms.ID,
		Name:                 ms.Name,
		Container:            ms.Container,
		Path:                 ms.Path,
		Size:                 ms.Size,
		Bitrate:              ms.Bitrate,
		RunTimeMs:            ms.RunTimeTicks / ticksPerMs,
		SupportsDirectPlay:   ms.SupportsDirectPlay,
		SupportsDirectStream: ms.SupportsDirectStream,
		SupportsTranscoding:  ms.SupportsTranscoding,
		TranscodingURL:       ms.TranscodingURL,
		DirectStreamURL:      ms.DirectStreamURL,
		Streams:              make([]ExtMediaStream, 0, len(ms.MediaStreams)),
	}
	for _, st := range ms.MediaStreams {
		isText := st.IsTextSubtitle
		if !isText && strings.EqualFold(st.Type, "Subtitle") {
			switch strings.ToLower(st.Codec) {
			case "subrip", "srt", "ass", "ssa", "vtt", "webvtt", "smi":
				isText = true
			}
		}
		vr := strings.TrimSpace(st.VideoRangeType)
		if vr == "" {
			vr = strings.TrimSpace(st.VideoRange)
		}
		mapped := ExtMediaStream{
			Index:          st.Index,
			Type:           st.Type,
			Codec:          st.Codec,
			Language:       st.Language,
			DisplayTitle:   st.DisplayTitle,
			Title:          st.Title,
			IsDefault:      st.IsDefault,
			IsForced:       st.IsForced,
			IsExternal:     st.IsExternal,
			IsTextSubtitle: isText,
			DeliveryURL:    st.DeliveryURL,
			Width:          st.Width,
			Height:         st.Height,
			VideoRange:     vr,
			Channels:       st.Channels,
			BitRate:        st.BitRate,
		}
		if strings.EqualFold(st.Type, "Video") && out.Width == 0 {
			out.VideoCodec = st.Codec
			out.Width = st.Width
			out.Height = st.Height
			vrUpper := strings.ToUpper(vr)
			if strings.Contains(vrUpper, "DOVI") || strings.Contains(vrUpper, "DOLBY") {
				out.HdrFormat = "Dolby Vision"
			} else if strings.Contains(vrUpper, "HDR") {
				out.HdrFormat = "HDR"
			}
		}
		out.Streams = append(out.Streams, mapped)
	}
	out.BrowserCompatible, out.CompatWarning = evaluateExtSourceCompat(out.Container, out.Streams)
	return out
}

func (c *Client) userPrefix() string {
	return "/Users/" + url.PathEscape(c.cfg.UserID)
}

func (c *Client) resumeRoute() (primary, fallback string) {
	u := c.userPrefix() + "/Items/Resume"
	if c.cfg.Kind == "emby" {
		return u, ""
	}
	return "/UserItems/Resume", u
}

func (c *Client) playedRoute(itemID string) (primary, fallback string) {
	id := url.PathEscape(itemID)
	u := c.userPrefix() + "/PlayedItems/" + id
	if c.cfg.Kind == "emby" {
		return u, ""
	}
	return "/UserPlayedItems/" + id, u
}

func (c *Client) favoriteRoute(itemID string) (primary, fallback string) {
	id := url.PathEscape(itemID)
	u := c.userPrefix() + "/FavoriteItems/" + id
	if c.cfg.Kind == "emby" {
		return u, ""
	}
	return "/UserFavoriteItems/" + id, u
}

const defaultItemFields = "PrimaryImageAspectRatio,BasicSyncInfo,Overview,Genres,Studios,MediaSources,MediaStreams,OfficialRating,CommunityRating,DateCreated"

func (c *Client) GetViews(ctx context.Context) ([]ExtView, error) {
	var env rawItemsEnvelope
	if err := c.getJSON(ctx, c.userPrefix()+"/Views", &env); err != nil {
		return nil, err
	}
	views := make([]ExtView, 0, len(env.Items))
	for _, it := range env.Items {
		img := ""
		if tag := it.ImageTags["Primary"]; tag != "" {
			img = c.proxyImageURL(it.ID, "Primary", 780, tag)
		}
		views = append(views, ExtView{
			ID:             it.ID,
			Name:           it.Name,
			CollectionType: it.CollectionType,
			ImageURL:       img,
		})
	}
	return views, nil
}

func (c *Client) GetResumeItems(ctx context.Context, limit int) ([]ExtItem, error) {
	if limit <= 0 {
		limit = 20
	}
	q := url.Values{
		"Recursive":        {"true"},
		"Fields":           {defaultItemFields},
		"ImageTypeLimit":   {"1"},
		"EnableImageTypes": {"Primary,Backdrop,Thumb"},
		"MediaTypes":       {"Video"},
		"Limit":            {strconv.Itoa(limit)},
	}.Encode()
	p1, p2 := c.resumeRoute()
	var env rawItemsEnvelope
	if err := c.getJSONWithFallback(ctx, p1+"?"+q, p2+"?"+q, &env); err != nil {
		return nil, err
	}
	out := make([]ExtItem, 0, len(env.Items))
	for _, it := range env.Items {
		out = append(out, c.mapItem(it))
	}
	return out, nil
}

func (c *Client) GetLatestItems(ctx context.Context, parentID string, limit int) ([]ExtItem, error) {
	if limit <= 0 {
		limit = 16
	}
	q := url.Values{
		"Limit":            {strconv.Itoa(limit)},
		"Fields":           {defaultItemFields},
		"ImageTypeLimit":   {"1"},
		"EnableImageTypes": {"Primary,Backdrop,Thumb"},
	}
	if strings.TrimSpace(parentID) != "" {
		q.Set("ParentId", parentID)
	}
	raw, _, err := c.doAPIRequest(ctx, http.MethodGet, c.userPrefix()+"/Items/Latest?"+q.Encode(), nil, true)
	if err != nil {
		return nil, err
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return []ExtItem{}, nil
	}
	var items []rawBaseItem
	if trimmed[0] == '[' {
		if err := json.Unmarshal(trimmed, &items); err != nil {
			return nil, err
		}
	} else {
		var env rawItemsEnvelope
		if err := json.Unmarshal(trimmed, &env); err != nil {
			return nil, err
		}
		items = env.Items
	}
	out := make([]ExtItem, 0, len(items))
	for _, it := range items {
		out = append(out, c.mapItem(it))
	}
	return out, nil
}

func (c *Client) GetItems(ctx context.Context, opts ListItemsOpts) (ExtItemsPage, error) {
	limit := opts.Limit
	if limit <= 0 {
		limit = 48
	}
	offset := opts.StartIndex
	if offset < 0 {
		offset = 0
	}
	q := url.Values{
		"Fields":           {defaultItemFields},
		"ImageTypeLimit":   {"1"},
		"EnableImageTypes": {"Primary,Backdrop,Thumb"},
		"StartIndex":       {strconv.Itoa(offset)},
		"Limit":            {strconv.Itoa(limit)},
	}
	if opts.Recursive {
		q.Set("Recursive", "true")
	}
	if strings.TrimSpace(opts.ParentID) != "" {
		q.Set("ParentId", strings.TrimSpace(opts.ParentID))
	}
	if strings.TrimSpace(opts.IncludeItemTypes) != "" {
		q.Set("IncludeItemTypes", strings.TrimSpace(opts.IncludeItemTypes))
	}
	if strings.TrimSpace(opts.SortBy) != "" {
		q.Set("SortBy", strings.TrimSpace(opts.SortBy))
	}
	if strings.TrimSpace(opts.SortOrder) != "" {
		q.Set("SortOrder", strings.TrimSpace(opts.SortOrder))
	}
	if strings.TrimSpace(opts.SearchTerm) != "" {
		q.Set("SearchTerm", strings.TrimSpace(opts.SearchTerm))
	}
	if strings.TrimSpace(opts.Filters) != "" {
		q.Set("Filters", strings.TrimSpace(opts.Filters))
	}

	var env rawItemsEnvelope
	if err := c.getJSON(ctx, c.userPrefix()+"/Items?"+q.Encode(), &env); err != nil {
		return ExtItemsPage{}, err
	}
	out := make([]ExtItem, 0, len(env.Items))
	for _, it := range env.Items {
		out = append(out, c.mapItem(it))
	}
	total := env.TotalRecordCount
	if total == 0 && len(out) > 0 {
		total = len(out)
	}
	return ExtItemsPage{
		Items:  out,
		Total:  total,
		Offset: offset,
		Limit:  limit,
	}, nil
}

func (c *Client) GetSeriesEpisodes(ctx context.Context, seriesID string) ([]ExtItem, error) {
	if strings.TrimSpace(seriesID) == "" {
		return []ExtItem{}, nil
	}
	q := url.Values{
		"UserId":           {c.cfg.UserID},
		"Fields":           {"Overview,PrimaryImageAspectRatio,MediaSources"},
		"EnableImageTypes": {"Primary,Backdrop,Thumb"},
	}
	var env rawItemsEnvelope
	if err := c.getJSON(ctx, "/Shows/"+url.PathEscape(seriesID)+"/Episodes?"+q.Encode(), &env); err != nil {
		return nil, err
	}
	out := make([]ExtItem, 0, len(env.Items))
	for _, it := range env.Items {
		out = append(out, c.mapItem(it))
	}
	return out, nil
}

func (c *Client) GetItemDetail(ctx context.Context, itemID string) (ExtItemDetail, error) {
	var raw rawBaseItem
	if err := c.getJSON(ctx, c.userPrefix()+"/Items/"+url.PathEscape(itemID), &raw); err != nil {
		if is404(err) {
			return ExtItemDetail{}, fmt.Errorf("%w: %s", ErrNotFound, itemID)
		}
		return ExtItemDetail{}, err
	}

	detail := ExtItemDetail{
		Item:         c.mapItem(raw),
		MediaSources: make([]ExtMediaSource, 0, len(raw.MediaSources)),
		People:       make([]ExtPerson, 0, len(raw.People)),
	}
	for _, ms := range raw.MediaSources {
		detail.MediaSources = append(detail.MediaSources, c.mapMediaSource(ms))
	}
	for _, p := range raw.People {
		photo := ""
		if p.PrimaryImageTag != "" && p.ID != "" {
			photo = c.proxyImageURL(p.ID, "Primary", 185, p.PrimaryImageTag)
		}
		detail.People = append(detail.People, ExtPerson{
			ID:       p.ID,
			Name:     p.Name,
			Role:     p.Role,
			Type:     p.Type,
			PhotoURL: photo,
		})
	}

	var wg sync.WaitGroup
	var mu sync.Mutex

	switch detail.Item.Kind {
	case "show":
		wg.Add(3)
		go func() {
			defer wg.Done()
			q := url.Values{
				"UserId": {c.cfg.UserID},
				"Fields": {"PrimaryImageAspectRatio,Overview"},
			}
			var env rawItemsEnvelope
			if c.getJSON(ctx, "/Shows/"+url.PathEscape(raw.ID)+"/Seasons?"+q.Encode(), &env) == nil {
				seasons := make([]ExtItem, 0, len(env.Items))
				for _, s := range env.Items {
					seasons = append(seasons, c.mapItem(s))
				}
				mu.Lock()
				detail.Seasons = seasons
				mu.Unlock()
			}
		}()
		go func() {
			defer wg.Done()
			if eps, err := c.GetSeriesEpisodes(ctx, raw.ID); err == nil {
				mu.Lock()
				detail.Episodes = eps
				mu.Unlock()
			}
		}()
		go func() {
			defer wg.Done()
			q := url.Values{
				"SeriesId": {raw.ID},
				"UserId":   {c.cfg.UserID},
				"Limit":    {"1"},
			}
			var env rawItemsEnvelope
			if c.getJSON(ctx, "/Shows/NextUp?"+q.Encode(), &env) == nil && len(env.Items) > 0 {
				ep := c.mapItem(env.Items[0])
				mu.Lock()
				detail.OnDeckEpisode = &ep
				mu.Unlock()
			}
		}()
	case "season":
		if raw.SeriesID != "" {
			wg.Add(2)
			go func() {
				defer wg.Done()
				var sRaw rawBaseItem
				if c.getJSON(ctx, c.userPrefix()+"/Items/"+url.PathEscape(raw.SeriesID), &sRaw) == nil {
					mapped := c.mapItem(sRaw)
					mu.Lock()
					detail.Show = &mapped
					mu.Unlock()
				}
			}()
			go func() {
				defer wg.Done()
				q := url.Values{
					"UserId":   {c.cfg.UserID},
					"SeasonId": {raw.ID},
					"Fields":   {"Overview,PrimaryImageAspectRatio,MediaSources"},
				}
				var env rawItemsEnvelope
				if c.getJSON(ctx, "/Shows/"+url.PathEscape(raw.SeriesID)+"/Episodes?"+q.Encode(), &env) == nil {
					eps := make([]ExtItem, 0, len(env.Items))
					for _, ep := range env.Items {
						eps = append(eps, c.mapItem(ep))
					}
					mu.Lock()
					detail.Episodes = eps
					mu.Unlock()
				}
			}()
		} else {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if page, err := c.GetItems(ctx, ListItemsOpts{ParentID: raw.ID, IncludeItemTypes: "Episode", Limit: 200}); err == nil {
					mu.Lock()
					detail.Episodes = page.Items
					mu.Unlock()
				}
			}()
		}
	case "episode":
		if raw.SeriesID != "" {
			wg.Add(1)
			go func() {
				defer wg.Done()
				var sRaw rawBaseItem
				if c.getJSON(ctx, c.userPrefix()+"/Items/"+url.PathEscape(raw.SeriesID), &sRaw) == nil {
					mapped := c.mapItem(sRaw)
					mu.Lock()
					detail.Show = &mapped
					mu.Unlock()
				}
			}()
		}
	case "boxset", "playlist":
		wg.Add(1)
		go func() {
			defer wg.Done()
			if page, err := c.GetItems(ctx, ListItemsOpts{ParentID: raw.ID, Recursive: false, Limit: 200}); err == nil {
				mu.Lock()
				detail.Children = page.Items
				mu.Unlock()
			}
		}()
	}

	// Best-effort similar works
	if detail.Item.Kind == "movie" || detail.Item.Kind == "show" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			q := url.Values{
				"UserId": {c.cfg.UserID},
				"Limit":  {"12"},
				"Fields": {"PrimaryImageAspectRatio"},
			}
			var env rawItemsEnvelope
			if c.getJSON(ctx, "/Items/"+url.PathEscape(raw.ID)+"/Similar?"+q.Encode(), &env) == nil {
				sim := make([]ExtItem, 0, len(env.Items))
				for _, s := range env.Items {
					sim = append(sim, c.mapItem(s))
				}
				mu.Lock()
				detail.Similar = sim
				mu.Unlock()
			}
		}()
	}

	wg.Wait()

	// Fallback OnDeckEpisode for series if NextUp returned empty
	if detail.Item.Kind == "show" && detail.OnDeckEpisode == nil && len(detail.Episodes) > 0 {
		for i := range detail.Episodes {
			if detail.Episodes[i].PositionMs > 0 && !detail.Episodes[i].Watched {
				ep := detail.Episodes[i]
				detail.OnDeckEpisode = &ep
				break
			}
		}
		if detail.OnDeckEpisode == nil {
			for i := range detail.Episodes {
				if !detail.Episodes[i].Watched {
					ep := detail.Episodes[i]
					detail.OnDeckEpisode = &ep
					break
				}
			}
		}
		if detail.OnDeckEpisode == nil {
			ep := detail.Episodes[0]
			detail.OnDeckEpisode = &ep
		}
	}

	return detail, nil
}

func (c *Client) Search(ctx context.Context, query string, limit int) (ExtSearchResult, error) {
	query = strings.TrimSpace(query)
	out := ExtSearchResult{
		Movies:      []ExtItem{},
		Shows:       []ExtItem{},
		Episodes:    []ExtItem{},
		Collections: []ExtItem{},
	}
	if query == "" {
		return out, nil
	}
	if limit <= 0 {
		limit = 40
	}
	page, err := c.GetItems(ctx, ListItemsOpts{
		Recursive:        true,
		IncludeItemTypes: "Movie,Series,Episode,BoxSet",
		SearchTerm:       query,
		Limit:            limit,
	})
	if err != nil {
		return ExtSearchResult{}, err
	}
	for _, it := range page.Items {
		switch it.Kind {
		case "movie":
			out.Movies = append(out.Movies, it)
		case "show":
			out.Shows = append(out.Shows, it)
		case "episode":
			out.Episodes = append(out.Episodes, it)
		case "boxset", "playlist":
			out.Collections = append(out.Collections, it)
		}
	}
	return out, nil
}

func (c *Client) SetFavorite(ctx context.Context, itemID string, fav bool) error {
	method := http.MethodPost
	if !fav {
		method = http.MethodDelete
	}
	p1, p2 := c.favoriteRoute(itemID)
	_, _, err := c.doAPIRequest(ctx, method, p1, nil, true)
	if err != nil && p2 != "" && is404(err) {
		_, _, err = c.doAPIRequest(ctx, method, p2, nil, true)
	}
	return err
}

func (c *Client) SetPlayed(ctx context.Context, itemID string, played bool) error {
	method := http.MethodPost
	if !played {
		method = http.MethodDelete
	}
	p1, p2 := c.playedRoute(itemID)
	_, _, err := c.doAPIRequest(ctx, method, p1, nil, true)
	if err != nil && p2 != "" && is404(err) {
		_, _, err = c.doAPIRequest(ctx, method, p2, nil, true)
	}
	return err
}

func (c *Client) ReportPlayback(ctx context.Context, req PlaybackReportReq) error {
	if strings.TrimSpace(req.ItemID) == "" {
		return fmt.Errorf("%w: item_id is required", ErrBadRequest)
	}
	endpoint := "/Sessions/Playing/Progress"
	switch strings.ToLower(strings.TrimSpace(req.State)) {
	case "start":
		endpoint = "/Sessions/Playing"
	case "stop":
		endpoint = "/Sessions/Playing/Stopped"
	}
	playMethod := strings.TrimSpace(req.PlayMethod)
	if playMethod == "" {
		playMethod = "DirectStream"
	}
	body := map[string]any{
		"ItemId":        req.ItemID,
		"PositionTicks": req.PositionMs * ticksPerMs,
		"IsPaused":      req.IsPaused,
		"PlayMethod":    playMethod,
		"CanSeek":       true,
	}
	if req.MediaSourceID != "" {
		body["MediaSourceId"] = req.MediaSourceID
	}
	if req.PlaySessionID != "" {
		body["PlaySessionId"] = req.PlaySessionID
	}
	_, _, err := c.doAPIRequest(ctx, http.MethodPost, endpoint, body, true)
	return err
}

func webDeviceProfile() map[string]any {
	return map[string]any{
		"MaxStreamingBitrate": 120000000,
		"DirectPlayProfiles": []map[string]any{
			{
				"Container":  "mp4,m4v,mov,webm",
				"Type":       "Video",
				"VideoCodec": "h264,hevc,h265,vp8,vp9,av1",
				"AudioCodec": "aac,mp3,opus,flac,vorbis",
			},
			{
				"Container":  "mp3,aac,flac,opus,webm",
				"Type":       "Audio",
				"AudioCodec": "mp3,aac,flac,opus,vorbis",
			},
		},
		"TranscodingProfiles": []map[string]any{
			{
				"Container":    "ts",
				"Type":         "Video",
				"VideoCodec":   "h264",
				"AudioCodec":   "aac,mp3",
				"Protocol":     "hls",
				"Context":      "Streaming",
				"MaxAudioChannels": "2",
				"MinSegments":  "1",
				"BreakOnNonKeyFrames": true,
			},
		},
		"SubtitleProfiles": []map[string]any{
			{"Format": "vtt", "Method": "External"},
			{"Format": "srt", "Method": "External"},
			{"Format": "ass", "Method": "External"},
			{"Format": "ssa", "Method": "External"},
		},
	}
}

func (c *Client) GetPlaybackInfo(ctx context.Context, itemID, mediaSourceID string) (PlaybackInfoResult, error) {
	q := url.Values{
		"UserId":              {c.cfg.UserID},
		"IsPlayback":          {"true"},
		"AutoOpenLiveStream":  {"true"},
		"MaxStreamingBitrate": {"120000000"},
	}
	if strings.TrimSpace(mediaSourceID) != "" {
		q.Set("MediaSourceId", strings.TrimSpace(mediaSourceID))
	}
	reqBody := map[string]any{
		"UserId":              c.cfg.UserID,
		"MaxStreamingBitrate": 120000000,
		"EnableDirectPlay":    true,
		"EnableDirectStream":  true,
		"EnableTranscoding":   true,
		"DeviceProfile":       webDeviceProfile(),
	}
	if strings.TrimSpace(mediaSourceID) != "" {
		reqBody["MediaSourceId"] = strings.TrimSpace(mediaSourceID)
	}

	raw, _, err := c.doAPIRequest(ctx, http.MethodPost, "/Items/"+url.PathEscape(itemID)+"/PlaybackInfo?"+q.Encode(), reqBody, true)
	if err == nil {
		var pbResp struct {
			PlaySessionID string           `json:"PlaySessionId"`
			MediaSources  []rawMediaSource `json:"MediaSources"`
		}
		if json.Unmarshal(raw, &pbResp) == nil && len(pbResp.MediaSources) > 0 {
			sources := make([]ExtMediaSource, 0, len(pbResp.MediaSources))
			for _, ms := range pbResp.MediaSources {
				sources = append(sources, c.mapMediaSource(ms))
			}
			return PlaybackInfoResult{
				PlaySessionID: pbResp.PlaySessionID,
				MediaSources:  sources,
			}, nil
		}
	}

	// Fallback: load raw item MediaSources
	var item rawBaseItem
	if err2 := c.getJSON(ctx, c.userPrefix()+"/Items/"+url.PathEscape(itemID), &item); err2 != nil {
		if err != nil {
			return PlaybackInfoResult{}, err
		}
		return PlaybackInfoResult{}, err2
	}
	sources := make([]ExtMediaSource, 0, len(item.MediaSources))
	for _, ms := range item.MediaSources {
		sources = append(sources, c.mapMediaSource(ms))
	}
	return PlaybackInfoResult{MediaSources: sources}, nil
}

// ---------- Upstream URL Builders & Streaming ----------

func safeContainerExt(container string) string {
	c := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(container, ".")))
	if idx := strings.IndexByte(c, ','); idx >= 0 {
		c = strings.TrimSpace(c[:idx])
	}
	if c == "" {
		return ""
	}
	for _, r := range c {
		if !((r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return ""
		}
	}
	return c
}

func (c *Client) BuildDirectStreamURL(itemID, mediaSourceID, container, playSessionID string) string {
	q := url.Values{
		"Static":            {"true"},
		c.TokenQueryParam(): {c.cfg.Token},
		"DeviceId":          {c.cfg.DeviceID},
	}
	if container != "" {
		q.Set("Container", container)
	}
	if mediaSourceID != "" {
		q.Set("MediaSourceId", mediaSourceID)
	}
	if playSessionID != "" {
		q.Set("PlaySessionId", playSessionID)
	}
	streamPath := "stream"
	if ext := safeContainerExt(container); ext != "" {
		streamPath = "stream." + ext
	}
	return fmt.Sprintf("%s/Videos/%s/%s?%s", c.baseURL, url.PathEscape(itemID), streamPath, q.Encode())
}

func (c *Client) ResolveUpstreamURL(relOrAbs string) string {
	relOrAbs = strings.TrimSpace(relOrAbs)
	if strings.HasPrefix(relOrAbs, "http://") || strings.HasPrefix(relOrAbs, "https://") {
		return relOrAbs
	}
	base, err := url.Parse(c.baseURL)
	if err != nil {
		return c.baseURL + "/" + strings.TrimLeft(relOrAbs, "/")
	}
	if !strings.HasPrefix(relOrAbs, "/") {
		relOrAbs = "/" + relOrAbs
	}
	// If baseURL ends with /emby and relOrAbs already starts with /emby/, avoid doubling /emby/emby/
	basePath := strings.TrimRight(base.Path, "/")
	if basePath != "" && strings.HasPrefix(relOrAbs, basePath+"/") {
		return base.Scheme + "://" + base.Host + relOrAbs
	}
	return c.baseURL + relOrAbs
}

func (c *Client) BuildHLSMasterURL(itemID, mediaSourceID, playSessionID string, maxBitrate, maxWidth, maxHeight int, transcodingURL string) string {
	if strings.TrimSpace(transcodingURL) != "" && maxBitrate <= 0 {
		resolved := c.ResolveUpstreamURL(transcodingURL)
		u, err := url.Parse(resolved)
		if err == nil {
			q := u.Query()
			if q.Get(c.TokenQueryParam()) == "" && c.cfg.Token != "" {
				q.Set(c.TokenQueryParam(), c.cfg.Token)
			}
			u.RawQuery = q.Encode()
			return u.String()
		}
		return resolved
	}
	if maxBitrate <= 0 {
		maxBitrate = 8000000
	}
	q := url.Values{
		"DeviceId":                    {c.cfg.DeviceID},
		c.TokenQueryParam():           {c.cfg.Token},
		"VideoCodec":                  {"h264"},
		"AudioCodec":                  {"aac,mp3"},
		"MaxStreamingBitrate":         {strconv.Itoa(maxBitrate)},
		"VideoBitrate":                {strconv.Itoa(maxBitrate)},
		"TranscodingMaxAudioChannels": {"2"},
		"SegmentContainer":            {"ts"},
		"MinSegments":                 {"1"},
		"BreakOnNonKeyFrames":         {"true"},
	}
	if maxWidth > 0 && maxHeight > 0 {
		q.Set("MaxWidth", strconv.Itoa(maxWidth))
		q.Set("MaxHeight", strconv.Itoa(maxHeight))
	}
	if mediaSourceID != "" {
		q.Set("MediaSourceId", mediaSourceID)
	}
	if playSessionID != "" {
		q.Set("PlaySessionId", playSessionID)
	}
	return fmt.Sprintf("%s/Videos/%s/master.m3u8?%s", c.baseURL, url.PathEscape(itemID), q.Encode())
}

func (c *Client) BuildSubtitleVTTURL(itemID, mediaSourceID string, streamIndex int, deliveryURL string) string {
	if strings.TrimSpace(deliveryURL) != "" {
		resolved := c.ResolveUpstreamURL(deliveryURL)
		if u, err := url.Parse(resolved); err == nil {
			q := u.Query()
			if q.Get(c.TokenQueryParam()) == "" && c.cfg.Token != "" {
				q.Set(c.TokenQueryParam(), c.cfg.Token)
			}
			u.RawQuery = q.Encode()
			return u.String()
		}
		return resolved
	}
	if strings.TrimSpace(mediaSourceID) == "" {
		mediaSourceID = itemID
	}
	q := url.Values{
		c.TokenQueryParam(): {c.cfg.Token},
	}
	return fmt.Sprintf("%s/Videos/%s/%s/Subtitles/%d/0/Stream.vtt?%s",
		c.baseURL,
		url.PathEscape(itemID),
		url.PathEscape(mediaSourceID),
		streamIndex,
		q.Encode(),
	)
}

func (c *Client) BuildImageURL(itemID, imageType string, maxWidth int, tag string) string {
	if strings.TrimSpace(imageType) == "" {
		imageType = "Primary"
	}
	q := url.Values{}
	if maxWidth > 0 {
		q.Set("maxWidth", strconv.Itoa(maxWidth))
	}
	if strings.TrimSpace(tag) != "" {
		q.Set("tag", strings.TrimSpace(tag))
	}
	if c.cfg.Token != "" {
		q.Set(c.TokenQueryParam(), c.cfg.Token)
	}
	u := fmt.Sprintf("%s/Items/%s/Images/%s", c.baseURL, url.PathEscape(itemID), url.PathEscape(imageType))
	if enc := q.Encode(); enc != "" {
		u += "?" + enc
	}
	return u
}

func (c *Client) DoStreamRequest(ctx context.Context, method, rawURL string, extraHeaders http.Header) (*http.Response, error) {
	if method == "" {
		method = http.MethodGet
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
	if err != nil {
		return nil, err
	}
	for k, vals := range extraHeaders {
		for _, v := range vals {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Authorization", c.authHeader(true))
	if c.cfg.Token != "" {
		req.Header.Set("X-Emby-Token", c.cfg.Token)
	}
	return c.streamClient.Do(req)
}
