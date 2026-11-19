package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
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

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/extserver"
	"plezy/media_server/internal/stream"
)

const extHLSSegTTL = 4 * time.Hour

var reExtHLSAttrURI = regexp.MustCompile(`URI="([^"]+)"`)

type extPlaybackVariant struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Width     int    `json:"width,omitempty"`
	Height    int    `json:"height,omitempty"`
	IsHLS     bool   `json:"is_hls"`
	StreamURL string `json:"stream_url"`
}

type extPlaybackVersion struct {
	SourceID          string                    `json:"source_id"`
	Label             string                    `json:"label"`
	Container         string                    `json:"container,omitempty"`
	VideoCodec        string                    `json:"video_codec,omitempty"`
	Width             int                       `json:"width,omitempty"`
	Height            int                       `json:"height,omitempty"`
	HdrFormat         string                    `json:"hdr_format,omitempty"`
	Size              int64                     `json:"size,omitempty"`
	Bitrate           int                       `json:"bitrate,omitempty"`
	BrowserCompatible bool                      `json:"browser_compatible"`
	CompatWarning     string                    `json:"compat_warning,omitempty"`
	StreamURL         string                    `json:"stream_url"`
	StreamToken       string                    `json:"stream_token"`
	Variants          []extPlaybackVariant      `json:"variants"`
	Streams           []extserver.ExtMediaStream `json:"streams,omitempty"`
}

type extPlaybackSubtitle struct {
	Index    int    `json:"index"`
	FileName string `json:"file_name"`
	Language string `json:"language,omitempty"`
	Ext      string `json:"ext"`
	VttURL   string `json:"vtt_url"`
}

func writeMappedExtError(w http.ResponseWriter, r *http.Request, err error) {
	var httpErr *extserver.HTTPError
	switch {
	case errors.Is(err, db.ErrNotFound), errors.Is(err, extserver.ErrNotFound):
		writeErr(w, r, http.StatusNotFound, err.Error())
	case errors.Is(err, extserver.ErrUnauthorized):
		writeErr(w, r, http.StatusUnauthorized, err.Error())
	case errors.Is(err, extserver.ErrBadRequest), errors.Is(err, db.ErrInvalidInput):
		writeErr(w, r, http.StatusBadRequest, err.Error())
	case errors.As(err, &httpErr):
		status := httpErr.Status
		if status < 400 || status >= 600 {
			status = http.StatusBadGateway
		}
		writeErr(w, r, status, httpErr.Error())
	case errors.Is(err, extserver.ErrUpstream):
		writeErr(w, r, http.StatusBadGateway, err.Error())
	default:
		writeMappedError(w, r, err)
	}
}

func (s *Server) extClientForRecord(srv db.ExternalServerRecord) (*extserver.Client, error) {
	return extserver.NewClient(extserver.ServerConfig{
		ID:               srv.ID,
		Kind:             srv.Kind,
		BaseURL:          srv.BaseURL,
		UserID:           srv.UserID,
		DeviceID:         srv.DeviceID,
		Token:            srv.Secrets["token"],
		AllowInsecureTLS: srv.AllowInsecureTLS,
	})
}

func (s *Server) extClientByID(id string, requireEnabled bool) (db.ExternalServerRecord, *extserver.Client, error) {
	srv, err := s.Store.GetExternalServer(id)
	if err != nil {
		return db.ExternalServerRecord{}, nil, err
	}
	if requireEnabled && !srv.Enabled {
		return db.ExternalServerRecord{}, nil, fmt.Errorf("%w: external server %q is disabled", extserver.ErrBadRequest, srv.Name)
	}
	cli, err := s.extClientForRecord(srv)
	if err != nil {
		return db.ExternalServerRecord{}, nil, err
	}
	return srv, cli, nil
}

// ---------- Management Endpoints ----------

func (s *Server) handleListExternalServers(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	list, err := s.Store.ListExternalServers()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "servers": list})
}

type extServerWriteReq struct {
	ID               string `json:"id,omitempty"`
	Name             string `json:"name"`
	Kind             string `json:"kind"`
	BaseURL          string `json:"base_url"`
	AuthMode         string `json:"auth_mode"`
	Username         string `json:"username"`
	Password         string `json:"password"`
	APIKey           string `json:"api_key"`
	UserID           string `json:"user_id"`
	AllowInsecureTLS *bool  `json:"allow_insecure_tls"`
	Enabled          *bool  `json:"enabled"`
}

func (s *Server) handleTestExternalServer(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req extServerWriteReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}

	var existing *db.ExternalServerRecord
	if strings.TrimSpace(req.ID) != "" {
		rec, err := s.Store.GetExternalServer(req.ID)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		existing = &rec
		if strings.TrimSpace(req.Kind) == "" {
			req.Kind = rec.Kind
		}
		if strings.TrimSpace(req.BaseURL) == "" {
			req.BaseURL = rec.BaseURL
		}
		if strings.TrimSpace(req.AuthMode) == "" {
			req.AuthMode = rec.AuthMode
		}
		if strings.TrimSpace(req.Username) == "" {
			req.Username = rec.Username
		}
		if strings.TrimSpace(req.UserID) == "" {
			req.UserID = rec.UserID
		}
		if req.AllowInsecureTLS == nil {
			v := rec.AllowInsecureTLS
			req.AllowInsecureTLS = &v
		}
	}

	authMode := strings.ToLower(strings.TrimSpace(req.AuthMode))
	if authMode == "" {
		authMode = "password"
	}
	insecure := req.AllowInsecureTLS != nil && *req.AllowInsecureTLS
	deviceID := ""
	savedToken := ""
	if existing != nil {
		deviceID = existing.DeviceID
		savedToken = existing.Secrets["token"]
	}

	cli, err := extserver.NewClient(extserver.ServerConfig{
		Kind:             req.Kind,
		BaseURL:          req.BaseURL,
		UserID:           req.UserID,
		DeviceID:         deviceID,
		Token:            savedToken,
		AllowInsecureTLS: insecure,
	})
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	started := time.Now()
	var info extserver.ServerInfo
	userID := req.UserID
	username := req.Username

	if authMode == "apikey" {
		key := strings.TrimSpace(req.APIKey)
		if key == "" {
			key = savedToken
		}
		hint := strings.TrimSpace(req.UserID)
		if hint == "" {
			hint = strings.TrimSpace(req.Username)
		}
		authRes, err := cli.VerifyAPIKey(r.Context(), key, hint)
		if err != nil {
			writeMappedExtError(w, r, err)
			return
		}
		info = authRes.ServerInfo
		userID = authRes.UserID
		username = authRes.Username
	} else if strings.TrimSpace(req.Password) != "" || savedToken == "" {
		authRes, err := cli.AuthenticateByName(r.Context(), req.Username, req.Password)
		if err != nil {
			writeMappedExtError(w, r, err)
			return
		}
		info = authRes.ServerInfo
		userID = authRes.UserID
		username = authRes.Username
	} else {
		info, err = cli.VerifySession(r.Context())
		if err != nil {
			writeMappedExtError(w, r, err)
			return
		}
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"ok":                 true,
		"server_name":        info.ServerName,
		"server_id":          info.ServerID,
		"version":            info.Version,
		"product_name":       info.ProductName,
		"detected_kind":      info.DetectedKind,
		"effective_base_url": info.EffectiveBaseURL,
		"user_id":            userID,
		"username":           username,
		"latency_ms":         time.Since(started).Milliseconds(),
	})
}

func (s *Server) handleCreateExternalServer(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req extServerWriteReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}

	kind := strings.ToLower(strings.TrimSpace(req.Kind))
	if !db.ValidExternalServerKind(kind) {
		writeErr(w, r, http.StatusBadRequest, "kind must be emby or jellyfin")
		return
	}
	authMode := strings.ToLower(strings.TrimSpace(req.AuthMode))
	if authMode == "" {
		authMode = "password"
	}
	if !db.ValidExternalAuthMode(authMode) {
		writeErr(w, r, http.StatusBadRequest, "auth_mode must be password or apikey")
		return
	}

	insecure := req.AllowInsecureTLS != nil && *req.AllowInsecureTLS
	enabled := req.Enabled == nil || *req.Enabled

	cli, err := extserver.NewClient(extserver.ServerConfig{
		Kind:             kind,
		BaseURL:          req.BaseURL,
		AllowInsecureTLS: insecure,
	})
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	var authRes extserver.AuthResult
	if authMode == "apikey" {
		hint := strings.TrimSpace(req.UserID)
		if hint == "" {
			hint = strings.TrimSpace(req.Username)
		}
		authRes, err = cli.VerifyAPIKey(r.Context(), req.APIKey, hint)
	} else {
		authRes, err = cli.AuthenticateByName(r.Context(), req.Username, req.Password)
	}
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	displayName := strings.TrimSpace(req.Name)
	if displayName == "" {
		displayName = authRes.ServerInfo.ServerName
	}

	rec, err := s.Store.CreateExternalServer(db.ExternalServerRecord{
		Name:             displayName,
		Kind:             kind,
		BaseURL:          authRes.ServerInfo.EffectiveBaseURL,
		AuthMode:         authMode,
		Username:         authRes.Username,
		UserID:           authRes.UserID,
		DeviceID:         cli.Config().DeviceID,
		ServerID:         authRes.ServerInfo.ServerID,
		ServerVersion:    authRes.ServerInfo.Version,
		AllowInsecureTLS: insecure,
		Secrets:          map[string]string{"token": authRes.AccessToken},
		Enabled:          enabled,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "server": rec})
}

func (s *Server) handleUpdateExternalServer(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	existing, err := s.Store.GetExternalServer(id)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	var req extServerWriteReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}

	// Quick enable/disable or rename without touching connection
	kind := existing.Kind
	if strings.TrimSpace(req.Kind) != "" {
		kind = strings.ToLower(strings.TrimSpace(req.Kind))
	}
	baseURL := existing.BaseURL
	if strings.TrimSpace(req.BaseURL) != "" {
		baseURL = req.BaseURL
	}
	authMode := existing.AuthMode
	if strings.TrimSpace(req.AuthMode) != "" {
		authMode = strings.ToLower(strings.TrimSpace(req.AuthMode))
	}
	insecure := existing.AllowInsecureTLS
	if req.AllowInsecureTLS != nil {
		insecure = *req.AllowInsecureTLS
	}
	username := existing.Username
	if strings.TrimSpace(req.Username) != "" {
		username = strings.TrimSpace(req.Username)
	}
	userID := existing.UserID
	if strings.TrimSpace(req.UserID) != "" {
		userID = strings.TrimSpace(req.UserID)
	}

	needsReauth := strings.TrimSpace(req.Password) != "" ||
		strings.TrimSpace(req.APIKey) != "" ||
		(strings.TrimSpace(req.BaseURL) != "" && strings.TrimRight(req.BaseURL, "/") != existing.BaseURL) ||
		(strings.TrimSpace(req.Kind) != "" && kind != existing.Kind)

	var upd db.ExternalServerUpdate
	if strings.TrimSpace(req.Name) != "" {
		n := strings.TrimSpace(req.Name)
		upd.Name = &n
	}
	if req.Enabled != nil {
		upd.Enabled = req.Enabled
	}
	if req.AllowInsecureTLS != nil {
		upd.AllowInsecureTLS = &insecure
	}

	if needsReauth {
		cli, err := extserver.NewClient(extserver.ServerConfig{
			Kind:             kind,
			BaseURL:          baseURL,
			UserID:           userID,
			DeviceID:         existing.DeviceID,
			Token:            existing.Secrets["token"],
			AllowInsecureTLS: insecure,
		})
		if err != nil {
			writeMappedExtError(w, r, err)
			return
		}

		if authMode == "apikey" {
			key := strings.TrimSpace(req.APIKey)
			if key == "" {
				key = existing.Secrets["token"]
			}
			hint := strings.TrimSpace(req.UserID)
			if hint == "" {
				hint = username
			}
			res, err := cli.VerifyAPIKey(r.Context(), key, hint)
			if err != nil {
				writeMappedExtError(w, r, err)
				return
			}
			upd.Kind = &kind
			upd.AuthMode = &authMode
			upd.BaseURL = &res.ServerInfo.EffectiveBaseURL
			upd.Username = &res.Username
			upd.UserID = &res.UserID
			upd.ServerID = &res.ServerInfo.ServerID
			upd.ServerVersion = &res.ServerInfo.Version
			sec := map[string]string{"token": res.AccessToken}
			upd.Secrets = &sec
		} else if strings.TrimSpace(req.Password) != "" {
			res, err := cli.AuthenticateByName(r.Context(), username, req.Password)
			if err != nil {
				writeMappedExtError(w, r, err)
				return
			}
			upd.Kind = &kind
			upd.AuthMode = &authMode
			upd.BaseURL = &res.ServerInfo.EffectiveBaseURL
			upd.Username = &res.Username
			upd.UserID = &res.UserID
			upd.ServerID = &res.ServerInfo.ServerID
			upd.ServerVersion = &res.ServerInfo.Version
			sec := map[string]string{"token": res.AccessToken}
			upd.Secrets = &sec
		} else {
			info, err := cli.VerifySession(r.Context())
			if err != nil {
				writeMappedExtError(w, r, err)
				return
			}
			upd.Kind = &kind
			upd.AuthMode = &authMode
			upd.BaseURL = &info.EffectiveBaseURL
			upd.ServerID = &info.ServerID
			upd.ServerVersion = &info.Version
		}
	}

	updated, err := s.Store.UpdateExternalServer(id, upd)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "server": updated})
}

func (s *Server) handleDeleteExternalServer(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	if err := s.Store.DeleteExternalServer(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "deleted"})
}

// ---------- Browse, Detail, Search & State Sync ----------

func (s *Server) handleExtHome(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	srv, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	ctx := r.Context()
	var views []extserver.ExtView
	var resume []extserver.ExtItem
	var viewsErr, resumeErr error

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		views, viewsErr = cli.GetViews(ctx)
	}()
	go func() {
		defer wg.Done()
		resume, resumeErr = cli.GetResumeItems(ctx, 20)
	}()
	wg.Wait()

	if viewsErr != nil {
		writeMappedExtError(w, r, viewsErr)
		return
	}
	if resumeErr != nil {
		resume = []extserver.ExtItem{}
	}

	// Fetch latest items for up to 6 views concurrently
	type indexedLatest struct {
		idx   int
		group extserver.ExtLatestGroup
	}
	maxViews := 6
	if len(views) < maxViews {
		maxViews = len(views)
	}
	groups := make([]extserver.ExtLatestGroup, 0, maxViews)
	ch := make(chan indexedLatest, maxViews)
	var latestWg sync.WaitGroup
	for i := 0; i < maxViews; i++ {
		ct := strings.ToLower(views[i].CollectionType)
		if ct == "playlists" || ct == "livetv" || ct == "folders" {
			continue
		}
		latestWg.Add(1)
		go func(idx int, v extserver.ExtView) {
			defer latestWg.Done()
			items, err := cli.GetLatestItems(ctx, v.ID, 16)
			if err != nil || len(items) == 0 {
				return
			}
			ch <- indexedLatest{idx: idx, group: extserver.ExtLatestGroup{View: v, Items: items}}
		}(i, views[i])
	}
	latestWg.Wait()
	close(ch)

	byIdx := make(map[int]extserver.ExtLatestGroup)
	for g := range ch {
		byIdx[g.idx] = g.group
	}
	for i := 0; i < maxViews; i++ {
		if g, ok := byIdx[i]; ok {
			groups = append(groups, g)
		}
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"server": srv,
		"home": extserver.ExtHomePayload{
			Views:        views,
			Resume:       resume,
			LatestByView: groups,
		},
	})
}

func (s *Server) handleExtItems(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	srv, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	q := r.URL.Query()
	offset, _ := strconv.Atoi(q.Get("offset"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 {
		limit = 48
	}

	sortKey := strings.TrimSpace(q.Get("sort"))
	sortBy := "DateCreated,SortName"
	switch sortKey {
	case "title":
		sortBy = "SortName"
	case "year":
		sortBy = "ProductionYear,SortName"
	case "rating":
		sortBy = "CommunityRating,SortName"
	case "added":
		sortBy = "DateCreated,SortName"
	}
	order := strings.ToLower(strings.TrimSpace(q.Get("order")))
	sortOrder := "Descending"
	if order == "asc" {
		sortOrder = "Ascending"
	} else if sortKey == "title" && order == "" {
		sortOrder = "Ascending"
	}

	filterKey := strings.ToLower(strings.TrimSpace(q.Get("filter")))
	var filters string
	switch filterKey {
	case "unplayed":
		filters = "IsUnplayed"
	case "played":
		filters = "IsPlayed"
	case "favorite":
		filters = "IsFavorite"
	}

	types := strings.TrimSpace(q.Get("types"))
	if types == "" {
		// Default video library items unless parent is boxsets/playlists
		switch strings.ToLower(strings.TrimSpace(q.Get("collection_type"))) {
		case "movies":
			types = "Movie"
		case "tvshows":
			types = "Series"
		case "boxsets":
			types = "BoxSet"
		}
	}

	page, err := cli.GetItems(r.Context(), extserver.ListItemsOpts{
		ParentID:         strings.TrimSpace(q.Get("parent_id")),
		IncludeItemTypes: types,
		Recursive:        true,
		SortBy:           sortBy,
		SortOrder:        sortOrder,
		StartIndex:       offset,
		Limit:            limit,
		SearchTerm:       strings.TrimSpace(q.Get("q")),
		Filters:          filters,
	})
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"server": srv,
		"items":  page.Items,
		"total":  page.Total,
		"offset": page.Offset,
		"limit":  page.Limit,
	})
}

func (s *Server) handleExtItemDetail(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	srv, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	detail, err := cli.GetItemDetail(r.Context(), r.PathValue("item_id"))
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"server": srv,
		"detail": detail,
	})
}

func (s *Server) handleExtSearch(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	srv, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	res, err := cli.Search(r.Context(), r.URL.Query().Get("q"), 40)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"server":  srv,
		"results": res,
	})
}

func (s *Server) handleExtFavorite(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	_, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	var req struct {
		Favorite bool `json:"favorite"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := cli.SetFavorite(r.Context(), r.PathValue("item_id"), req.Favorite); err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "favorite": req.Favorite})
}

func (s *Server) handleExtWatched(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	_, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	var req struct {
		Watched bool `json:"watched"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := cli.SetPlayed(r.Context(), r.PathValue("item_id"), req.Watched); err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "watched": req.Watched})
}

func (s *Server) handleExtPlaybackReport(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	_, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	var req extserver.PlaybackReportReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := cli.ReportPlayback(r.Context(), req); err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok"})
}

func formatExtVersionLabel(ms extserver.ExtMediaSource, idx int) string {
	var parts []string
	if strings.TrimSpace(ms.Name) != "" {
		parts = append(parts, strings.TrimSpace(ms.Name))
	}
	if ms.Width >= 3800 || ms.Height >= 2100 {
		parts = append(parts, "4K")
	} else if ms.Width >= 1900 || ms.Height >= 1060 {
		parts = append(parts, "1080p")
	} else if ms.Width >= 1200 || ms.Height >= 700 {
		parts = append(parts, "720p")
	}
	if ms.Container != "" {
		parts = append(parts, strings.ToUpper(ms.Container))
	}
	if ms.VideoCodec != "" {
		parts = append(parts, strings.ToUpper(ms.VideoCodec))
	}
	if len(parts) == 0 {
		return fmt.Sprintf("片源 #%d", idx+1)
	}
	return strings.Join(parts, " · ")
}

func sanitizeContainerToken(container string) string {
	c := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(container, ".")))
	if idx := strings.IndexByte(c, ','); idx >= 0 {
		c = strings.TrimSpace(c[:idx])
	}
	var b strings.Builder
	for _, r := range c {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "mp4"
	}
	return b.String()
}

func (s *Server) handleExtPlaybackInfo(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	srv, cli, err := s.extClientByID(r.PathValue("id"), true)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	reqItemID := r.PathValue("item_id")
	requestedSourceID := strings.TrimSpace(r.URL.Query().Get("source_id"))

	ctx := r.Context()
	detail, err := cli.GetItemDetail(ctx, reqItemID)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}

	playItem := detail.Item
	showPtr := detail.Show
	episodes := detail.Episodes

	if detail.Item.Kind == "show" {
		if detail.OnDeckEpisode != nil {
			playItem = *detail.OnDeckEpisode
		} else if len(detail.Episodes) > 0 {
			playItem = detail.Episodes[0]
		} else {
			writeErr(w, r, http.StatusNotFound, "该剧集暂无可播放剧集")
			return
		}
		showCopy := detail.Item
		showPtr = &showCopy
		if epDetail, err := cli.GetItemDetail(ctx, playItem.ID); err == nil {
			playItem = epDetail.Item
			detail.MediaSources = epDetail.MediaSources
		}
	} else if playItem.Kind == "episode" && playItem.SeriesID != "" && len(episodes) == 0 {
		if eps, err := cli.GetSeriesEpisodes(ctx, playItem.SeriesID); err == nil {
			episodes = eps
		}
	}

	var prevEp, nextEp *extserver.ExtItem
	for i := range episodes {
		if episodes[i].ID == playItem.ID {
			if i > 0 {
				p := episodes[i-1]
				prevEp = &p
			}
			if i+1 < len(episodes) {
				n := episodes[i+1]
				nextEp = &n
			}
			break
		}
	}

	pbRes, pbErr := cli.GetPlaybackInfo(ctx, playItem.ID, requestedSourceID)
	sources := pbRes.MediaSources
	if pbErr != nil || len(sources) == 0 {
		sources = detail.MediaSources
	}
	if len(sources) == 0 {
		sources = []extserver.ExtMediaSource{{
			ID:                   playItem.ID,
			SupportsDirectStream: true,
			SupportsTranscoding:  true,
			BrowserCompatible:    true,
		}}
	}

	selectedSourceID := requestedSourceID
	foundSelected := false
	for _, ms := range sources {
		if ms.ID == selectedSourceID {
			foundSelected = true
			break
		}
	}
	if !foundSelected {
		selectedSourceID = sources[0].ID
	}

	resourceKey := srv.ID + ":" + playItem.ID
	streamTok := s.Auth.SignStreamToken("ext-stream", resourceKey, auth.DefaultStreamTTL)
	subTok := s.Auth.SignStreamToken("ext-sub", resourceKey, auth.DefaultStreamTTL)

	versions := make([]extPlaybackVersion, 0, len(sources))
	for i, ms := range sources {
		ext := sanitizeContainerToken(ms.Container)
		streamURL := fmt.Sprintf(
			"/api/v1/ext/%s/stream/%s/play.%s?msid=%s&psid=%s&container=%s&token=%s",
			url.PathEscape(srv.ID),
			url.PathEscape(playItem.ID),
			ext,
			url.QueryEscape(ms.ID),
			url.QueryEscape(pbRes.PlaySessionID),
			url.QueryEscape(ms.Container),
			url.QueryEscape(streamTok),
		)

		variants := make([]extPlaybackVariant, 0, 6)
		if strings.TrimSpace(ms.TranscodingURL) != "" {
			tu := base64.RawURLEncoding.EncodeToString([]byte(ms.TranscodingURL))
			variants = append(variants, extPlaybackVariant{
				ID:    "auto",
				Label: "自适应码率",
				IsHLS: true,
				StreamURL: fmt.Sprintf(
					"/api/v1/ext/%s/hls/%s/master.m3u8?msid=%s&quality=auto&psid=%s&tu=%s&token=%s",
					url.PathEscape(srv.ID),
					url.PathEscape(playItem.ID),
					url.QueryEscape(ms.ID),
					url.QueryEscape(pbRes.PlaySessionID),
					url.QueryEscape(tu),
					url.QueryEscape(streamTok),
				),
			})
		}

		presets := []struct {
			id              string
			label           string
			w               int
			h               int
			minSourceHeight int
		}{
			{"1080p_20m", "1080p 20 Mbps", 1920, 1080, 1000},
			{"1080p", "1080p 8 Mbps", 1920, 1080, 1000},
			{"720p", "720p 4 Mbps", 1280, 720, 680},
			{"720p_2m", "720p 2 Mbps", 1280, 720, 680},
			{"480p", "480p 1.5 Mbps", 854, 480, 0},
		}
		for _, p := range presets {
			if ms.Height > 0 && ms.Height < p.minSourceHeight {
				continue
			}
			variants = append(variants, extPlaybackVariant{
				ID:     p.id,
				Label:  p.label,
				Width:  p.w,
				Height: p.h,
				IsHLS:  true,
				StreamURL: fmt.Sprintf(
					"/api/v1/ext/%s/hls/%s/master.m3u8?msid=%s&quality=%s&psid=%s&token=%s",
					url.PathEscape(srv.ID),
					url.PathEscape(playItem.ID),
					url.QueryEscape(ms.ID),
					p.id,
					url.QueryEscape(pbRes.PlaySessionID),
					url.QueryEscape(streamTok),
				),
			})
		}

		versions = append(versions, extPlaybackVersion{
			SourceID:          ms.ID,
			Label:             formatExtVersionLabel(ms, i),
			Container:         ms.Container,
			VideoCodec:        ms.VideoCodec,
			Width:             ms.Width,
			Height:            ms.Height,
			HdrFormat:         ms.HdrFormat,
			Size:              ms.Size,
			Bitrate:           ms.Bitrate,
			BrowserCompatible: ms.BrowserCompatible,
			CompatWarning:     ms.CompatWarning,
			StreamURL:         streamURL,
			StreamToken:       streamTok,
			Variants:          variants,
			Streams:           ms.Streams,
		})
	}

	// Build subtitles list for selected media source
	var selectedSource extserver.ExtMediaSource
	for _, ms := range sources {
		if ms.ID == selectedSourceID {
			selectedSource = ms
			break
		}
	}
	subs := make([]extPlaybackSubtitle, 0)
	for _, st := range selectedSource.Streams {
		if !strings.EqualFold(st.Type, "Subtitle") || !st.IsTextSubtitle {
			continue
		}
		label := strings.TrimSpace(st.DisplayTitle)
		if label == "" {
			label = strings.TrimSpace(st.Title)
		}
		if label == "" {
			label = strings.TrimSpace(st.Language)
		}
		if label == "" {
			label = fmt.Sprintf("字幕 #%d", st.Index)
		}
		vttURL := fmt.Sprintf(
			"/api/v1/ext/%s/subtitles/%s/%s/%d?token=%s",
			url.PathEscape(srv.ID),
			url.PathEscape(playItem.ID),
			url.PathEscape(selectedSource.ID),
			st.Index,
			url.QueryEscape(subTok),
		)
		if strings.TrimSpace(st.DeliveryURL) != "" {
			vttURL += "&du=" + url.QueryEscape(base64.RawURLEncoding.EncodeToString([]byte(st.DeliveryURL)))
		}
		if st.Codec != "" {
			vttURL += "&ext=" + url.QueryEscape(st.Codec)
		}
		subs = append(subs, extPlaybackSubtitle{
			Index:    st.Index,
			FileName: label,
			Language: st.Language,
			Ext:      st.Codec,
			VttURL:   vttURL,
		})
	}

	origin := s.buildOriginBase(r)
	extPlayers := map[string]string{}
	if len(versions) > 0 {
		idx := 0
		for i, v := range versions {
			if v.SourceID == selectedSourceID {
				idx = i
				break
			}
		}
		fullURL := versions[idx].StreamURL
		if origin != "" {
			fullURL = origin + fullURL
		}
		extPlayers = externalPlayersForURL(fullURL)
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"server":             srv,
		"item":               playItem,
		"show":               showPtr,
		"episodes":           episodes,
		"prev_episode":       prevEp,
		"next_episode":       nextEp,
		"play_session_id":    pbRes.PlaySessionID,
		"selected_source_id": selectedSourceID,
		"resume_position_ms": playItem.PositionMs,
		"versions":           versions,
		"subtitles":          subs,
		"external_players":   extPlayers,
	})
}

// ---------- Media Proxies (Images, Direct Stream, HLS, Subtitles) ----------

func (s *Server) handleExtImage(w http.ResponseWriter, r *http.Request) {
	if !s.authenticateArtworkRequest(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	_, cli, err := s.extClientByID(r.PathValue("id"), false)
	if err != nil {
		writeMappedExtError(w, r, err)
		return
	}
	maxW, _ := strconv.Atoi(r.URL.Query().Get("maxWidth"))
	if maxW <= 0 {
		maxW = 500
	}
	tag := strings.TrimSpace(r.URL.Query().Get("tag"))
	imgURL := cli.BuildImageURL(r.PathValue("item_id"), r.PathValue("image_type"), maxW, tag)

	resp, err := cli.DoStreamRequest(r.Context(), http.MethodGet, imgURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream image HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 15*1024*1024))
	if err != nil {
		http.Error(w, "read upstream image failed", http.StatusBadGateway)
		return
	}
	ct := resp.Header.Get("Content-Type")
	if ct == "" {
		ct = http.DetectContentType(data)
	}
	w.Header().Set("Content-Type", ct)
	if tag != "" {
		w.Header().Set("Cache-Control", "public, max-age=2592000")
	} else {
		w.Header().Set("Cache-Control", "public, max-age=3600")
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) handleExtStream(w http.ResponseWriter, r *http.Request) {
	srvID := r.PathValue("id")
	itemID := r.PathValue("item_id")
	if !s.authorizeStream(r, "ext-stream", srvID+":"+itemID) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	_, cli, err := s.extClientByID(srvID, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	q := r.URL.Query()
	msid := strings.TrimSpace(q.Get("msid"))
	psid := strings.TrimSpace(q.Get("psid"))
	container := strings.TrimSpace(q.Get("container"))
	if container == "" {
		fname := r.PathValue("filename")
		if dot := strings.LastIndex(fname, "."); dot >= 0 && dot+1 < len(fname) {
			container = fname[dot+1:]
		}
	}

	upstreamURL := cli.BuildDirectStreamURL(itemID, msid, container, psid)
	fwd := http.Header{}
	if rng := r.Header.Get("Range"); rng != "" {
		fwd.Set("Range", rng)
	}
	if ifRange := r.Header.Get("If-Range"); ifRange != "" {
		fwd.Set("If-Range", ifRange)
	}

	resp, err := cli.DoStreamRequest(r.Context(), r.Method, upstreamURL, fwd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	if w.Header().Get("Content-Type") == "" && container != "" {
		w.Header().Set("Content-Type", stream.ContentTypeForExt(sanitizeContainerToken(container)))
	}
	w.WriteHeader(resp.StatusCode)
	if r.Method != http.MethodHead {
		_, _ = io.Copy(w, resp.Body)
	}
}

func (s *Server) signExtHLSURL(serverID, targetURL string, expMs int64) string {
	msg := serverID + "\x00" + targetURL + "\x00" + strconv.FormatInt(expMs, 10)
	mac := hmac.New(sha256.New, s.Store.Vault().StreamSigningKey())
	_, _ = mac.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *Server) verifyExtHLSURL(serverID, targetURL string, expMs int64, sig string) bool {
	if time.Now().UnixMilli() > expMs {
		return false
	}
	gotSig, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return false
	}
	msg := serverID + "\x00" + targetURL + "\x00" + strconv.FormatInt(expMs, 10)
	mac := hmac.New(sha256.New, s.Store.Vault().StreamSigningKey())
	_, _ = mac.Write([]byte(msg))
	return hmac.Equal(gotSig, mac.Sum(nil))
}

func (s *Server) makeExtHLSProxyURL(serverID, absURL, streamToken string) string {
	expMs := time.Now().Add(extHLSSegTTL).UnixMilli()
	sig := s.signExtHLSURL(serverID, absURL, expMs)
	q := url.Values{
		"u":   {base64.RawURLEncoding.EncodeToString([]byte(absURL))},
		"exp": {strconv.FormatInt(expMs, 10)},
		"sig": {sig},
	}
	if streamToken != "" {
		q.Set("token", streamToken)
	}
	return fmt.Sprintf("/api/v1/ext/%s/hls-proxy?%s", url.PathEscape(serverID), q.Encode())
}

func (s *Server) rewriteExtPlaylist(playlistText, baseURL, serverID, streamToken string) (string, error) {
	base, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	resolve := func(raw string) string {
		ref, err := url.Parse(strings.TrimSpace(raw))
		if err != nil {
			return raw
		}
		return base.ResolveReference(ref).String()
	}

	lines := strings.Split(strings.ReplaceAll(playlistText, "\r\n", "\n"), "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			if strings.Contains(trimmed, `URI="`) {
				rewritten := reExtHLSAttrURI.ReplaceAllStringFunc(line, func(match string) string {
					sub := reExtHLSAttrURI.FindStringSubmatch(match)
					if len(sub) < 2 {
						return match
					}
					abs := resolve(sub[1])
					return `URI="` + s.makeExtHLSProxyURL(serverID, abs, streamToken) + `"`
				})
				out = append(out, rewritten)
			} else {
				out = append(out, line)
			}
			continue
		}
		abs := resolve(trimmed)
		out = append(out, s.makeExtHLSProxyURL(serverID, abs, streamToken))
	}
	return strings.Join(out, "\n"), nil
}

func presetSpecForQuality(quality string) (bitrate, maxW, maxH int) {
	switch strings.ToLower(strings.TrimSpace(quality)) {
	case "1080p_20m":
		return 20000000, 1920, 1080
	case "1080p":
		return 8000000, 1920, 1080
	case "720p":
		return 4000000, 1280, 720
	case "720p_2m":
		return 2000000, 1280, 720
	case "480p":
		return 1500000, 854, 480
	case "auto":
		return 0, 0, 0
	default:
		return 8000000, 1920, 1080
	}
}

func (s *Server) handleExtHLSMaster(w http.ResponseWriter, r *http.Request) {
	srvID := r.PathValue("id")
	itemID := r.PathValue("item_id")
	if !s.authorizeStream(r, "ext-stream", srvID+":"+itemID) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	_, cli, err := s.extClientByID(srvID, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	q := r.URL.Query()
	msid := strings.TrimSpace(q.Get("msid"))
	psid := strings.TrimSpace(q.Get("psid"))
	quality := strings.TrimSpace(q.Get("quality"))
	tu := ""
	if tuB64 := strings.TrimSpace(q.Get("tu")); tuB64 != "" {
		if b, err := base64.RawURLEncoding.DecodeString(tuB64); err == nil {
			tu = string(b)
		}
	}

	bitrate, maxW, maxH := presetSpecForQuality(quality)
	upstreamURL := cli.BuildHLSMasterURL(itemID, msid, psid, bitrate, maxW, maxH, tu)
	resp, err := cli.DoStreamRequest(r.Context(), http.MethodGet, upstreamURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream returned HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
	if err != nil {
		http.Error(w, "read upstream playlist failed", http.StatusBadGateway)
		return
	}
	finalBase := upstreamURL
	if resp.Request != nil && resp.Request.URL != nil {
		finalBase = resp.Request.URL.String()
	}
	rewritten, err := s.rewriteExtPlaylist(string(raw), finalBase, srvID, strings.TrimSpace(q.Get("token")))
	if err != nil {
		http.Error(w, "rewrite playlist failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, rewritten)
}

func (s *Server) handleExtHLSProxy(w http.ResponseWriter, r *http.Request) {
	srvID := r.PathValue("id")
	q := r.URL.Query()
	uB64 := strings.TrimSpace(q.Get("u"))
	expStr := strings.TrimSpace(q.Get("exp"))
	sig := strings.TrimSpace(q.Get("sig"))
	if uB64 == "" || expStr == "" || sig == "" {
		http.Error(w, "missing hls proxy parameters", http.StatusBadRequest)
		return
	}
	expMs, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid exp", http.StatusBadRequest)
		return
	}
	rawTarget, err := base64.RawURLEncoding.DecodeString(uB64)
	if err != nil {
		http.Error(w, "invalid target encoding", http.StatusBadRequest)
		return
	}
	targetURL := string(rawTarget)
	if !s.verifyExtHLSURL(srvID, targetURL, expMs, sig) {
		http.Error(w, "invalid or expired hls proxy signature", http.StatusForbidden)
		return
	}

	_, cli, err := s.extClientByID(srvID, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	// SSRF defense: ensure target host strictly matches the configured server base URL host.
	srvURL, err := url.Parse(cli.BaseURL())
	targetParsed, err2 := url.Parse(targetURL)
	if err != nil || err2 != nil || !strings.EqualFold(targetParsed.Host, srvURL.Host) {
		http.Error(w, "target host mismatch", http.StatusForbidden)
		return
	}

	fwd := http.Header{}
	if rng := r.Header.Get("Range"); rng != "" {
		fwd.Set("Range", rng)
	}
	resp, err := cli.DoStreamRequest(r.Context(), http.MethodGet, targetURL, fwd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream returned HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}

	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if strings.Contains(ct, "mpegurl") || strings.Contains(strings.ToLower(targetParsed.Path), ".m3u8") {
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
		if err != nil {
			http.Error(w, "read child playlist failed", http.StatusBadGateway)
			return
		}
		finalBase := targetURL
		if resp.Request != nil && resp.Request.URL != nil {
			finalBase = resp.Request.URL.String()
		}
		rewritten, err := s.rewriteExtPlaylist(string(raw), finalBase, srvID, strings.TrimSpace(q.Get("token")))
		if err != nil {
			http.Error(w, "rewrite child playlist failed", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, rewritten)
		return
	}

	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "video/mp2t")
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (s *Server) handleExtSubtitle(w http.ResponseWriter, r *http.Request) {
	srvID := r.PathValue("id")
	itemID := r.PathValue("item_id")
	if !s.authorizeStream(r, "ext-sub", srvID+":"+itemID) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	_, cli, err := s.extClientByID(srvID, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	sourceID := r.PathValue("source_id")
	idx, err := strconv.Atoi(r.PathValue("index"))
	if err != nil {
		http.Error(w, "invalid subtitle index", http.StatusBadRequest)
		return
	}
	q := r.URL.Query()
	du := ""
	if duB64 := strings.TrimSpace(q.Get("du")); duB64 != "" {
		if b, err := base64.RawURLEncoding.DecodeString(duB64); err == nil {
			du = string(b)
		}
	}
	extHint := strings.TrimSpace(q.Get("ext"))

	subURL := cli.BuildSubtitleVTTURL(itemID, sourceID, idx, du)
	resp, err := cli.DoStreamRequest(r.Context(), http.MethodGet, subURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream subtitle HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		http.Error(w, "read upstream subtitle failed", http.StatusBadGateway)
		return
	}
	text := stream.DecodeSubtitleToUTF8(raw)
	if !strings.HasPrefix(strings.TrimSpace(text), "WEBVTT") {
		if extHint == "" {
			extHint = "srt"
		}
		text = stream.ConvertSubtitleToVTT(text, extHint)
	}
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, text)
}
