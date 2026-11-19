package api

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/storage/quark"
	"plezy/media_server/internal/stream"
	"plezy/media_server/web"
)

const maxJSONBodyBytes = 8 * 1024 * 1024

type Server struct {
	Store       *db.Store
	Auth        *auth.Service
	Storage     *storage.Manager
	Meta        *metadata.Service
	Hub         *events.Hub
	Coordinator *library.Coordinator
	HLS         *stream.HLSProxy
	QuarkQR     *quark.QrManager
	Mux         http.Handler

	webDir    string
	bgMu      sync.Mutex
	bgProbing map[int64]bool
	bgPeople  map[int64]bool
}

func (s *Server) SetWebDir(dir string) {
	s.webDir = strings.TrimSpace(dir)
}

func NewServer(
	store *db.Store,
	authSvc *auth.Service,
	stMgr *storage.Manager,
	metaSvc *metadata.Service,
	hub *events.Hub,
	coord *library.Coordinator,
) *Server {
	deviceProvider := func() quark.PcDevice {
		ut, mach := store.GetOrCreateQuarkPcDevice(func() (string, string) {
			d := quark.GeneratePcDevice()
			return d.Utdid, d.Machine
		})
		return quark.PcDevice{Utdid: ut, Machine: mach}
	}
	stMgr.RegisterFactory("quark", func(cfg storage.MountConfig, cb func(string, string)) (storage.Driver, error) {
		return quark.NewDriverWithDevice(cfg, cb, deviceProvider)
	})
	s := &Server{
		Store:       store,
		Auth:        authSvc,
		Storage:     stMgr,
		Meta:        metaSvc,
		Hub:         hub,
		Coordinator: coord,
		HLS:         stream.NewHLSProxy(store.Vault().StreamSigningKey()),
		QuarkQR:     quark.NewQrManagerWithDevice(deviceProvider),
		bgProbing:   make(map[int64]bool),
		bgPeople:    make(map[int64]bool),
	}
	s.Mux = s.buildMux()
	return s
}

func (s *Server) buildMux() http.Handler {
	mux := http.NewServeMux()

	// Health & bootstrap
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/v1/public/bootstrap", s.handleBootstrap)

	// Auth
	mux.HandleFunc("POST /api/v1/auth/setup", s.handleAuthSetup)
	mux.HandleFunc("POST /api/v1/auth/login", s.handleAuthLogin)
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleAuthLogout)
	mux.HandleFunc("GET /api/v1/auth/me", s.requireAuth(s.handleAuthMe))
	mux.HandleFunc("POST /api/v1/auth/password", s.requireAuth(s.handleAuthPassword))
	mux.HandleFunc("GET /api/v1/auth/sessions", s.requireAuth(s.handleAuthSessions))
	mux.HandleFunc("DELETE /api/v1/auth/sessions/{token_id}", s.requireAuth(s.handleAuthRevokeSession))

	// SSE Events (never gzipped)
	mux.HandleFunc("GET /api/v1/events", s.requireAuth(s.handleSSE))

	// System settings & overview
	mux.HandleFunc("GET /api/v1/settings", s.requireAuth(s.handleGetSettings))
	mux.HandleFunc("PUT /api/v1/settings", s.requireAuth(s.handleUpdateSettings))
	mux.HandleFunc("POST /api/v1/settings/test-tmdb", s.requireAuth(s.handleTestTmdb))
	mux.HandleFunc("POST /api/v1/settings/clear-cache", s.requireAuth(s.handleClearMetaCache))
	mux.HandleFunc("GET /api/v1/system/overview", s.requireAuth(s.handleSystemOverview))
	mux.HandleFunc("GET /api/v1/metadata/tables", s.requireAuth(s.handleListMetadataTables))
	mux.HandleFunc("GET /api/v1/metadata/tables/{table}", s.requireAuth(s.handleQueryMetadataTable))
	mux.HandleFunc("DELETE /api/v1/metadata/tables/{table}/row", s.requireAuth(s.handleDeleteMetadataCacheRow))

	// Mounts, host filesystem browser, Quark QR
	mux.HandleFunc("GET /api/v1/mounts", s.requireAuth(s.handleListMounts))
	mux.HandleFunc("POST /api/v1/mounts", s.requireAuth(s.handleCreateMount))
	mux.HandleFunc("PUT /api/v1/mounts/{id}", s.requireAuth(s.handleUpdateMount))
	mux.HandleFunc("DELETE /api/v1/mounts/{id}", s.requireAuth(s.handleDeleteMount))
	mux.HandleFunc("POST /api/v1/mounts/test", s.requireAuth(s.handleTestMount))
	mux.HandleFunc("POST /api/v1/mounts/browse-preview", s.requireAuth(s.handleMountBrowsePreview))
	mux.HandleFunc("GET /api/v1/mounts/{id}/quark-account", s.requireAuth(s.handleQuarkAccount))
	mux.HandleFunc("POST /api/v1/quark/account-preview", s.requireAuth(s.handleQuarkAccountPreview))
	mux.HandleFunc("GET /api/v1/fs/browse", s.requireAuth(s.handleHostFSBrowse))
	mux.HandleFunc("GET /api/v1/mounts/{id}/browse", s.requireAuth(s.handleMountBrowse))
	mux.HandleFunc("POST /api/v1/quark/qr/start", s.requireAuth(s.handleQuarkQrStart))
	mux.HandleFunc("GET /api/v1/quark/qr/poll", s.requireAuth(s.handleQuarkQrPoll))

	// Scan, scrape, unmatched & metadata edit
	mux.HandleFunc("GET /api/v1/tasks/status", s.requireAuth(s.handleTaskStatus))
	mux.HandleFunc("POST /api/v1/tasks/scan-all", s.requireAuth(s.handleScanAll))
	mux.HandleFunc("POST /api/v1/mounts/{id}/scan", s.requireAuth(s.handleScanMount))
	mux.HandleFunc("POST /api/v1/mounts/{id}/cancel-scan", s.requireAuth(s.handleCancelScan))
	mux.HandleFunc("POST /api/v1/tasks/scrape", s.requireAuth(s.handleScrapeAll))
	mux.HandleFunc("GET /api/v1/library/unmatched", s.requireAuth(s.handleUnmatched))
	mux.HandleFunc("GET /api/v1/scrape/search", s.requireAuth(s.handleScrapeSearch))
	mux.HandleFunc("POST /api/v1/items/{id}/match", s.requireAuth(s.handleManualMatch))
	mux.HandleFunc("POST /api/v1/items/{id}/unmatch", s.requireAuth(s.handleUnmatchItem))
	mux.HandleFunc("PUT /api/v1/items/{id}/metadata", s.requireAuth(s.handleUpdateMetadata))
	mux.HandleFunc("POST /api/v1/items/{id}/refresh", s.requireAuth(s.handleRefreshItem))

	// Library browsing, search, people, watch state & lists
	mux.HandleFunc("GET /api/v1/home", s.requireAuth(s.handleHome))
	mux.HandleFunc("GET /api/v1/library/items", s.requireAuth(s.handleLibraryItems))
	mux.HandleFunc("GET /api/v1/library/facets", s.requireAuth(s.handleLibraryFacets))
	mux.HandleFunc("GET /api/v1/items/{id}", s.requireAuth(s.handleItemDetail))
	mux.HandleFunc("GET /api/v1/search", s.requireAuth(s.handleSearch))
	mux.HandleFunc("GET /api/v1/people/{id}", s.requireAuth(s.handlePersonDetail))

	mux.HandleFunc("POST /api/v1/items/{id}/favorite", s.requireAuth(s.handleFavorite))
	mux.HandleFunc("POST /api/v1/items/{id}/watched", s.requireAuth(s.handleWatched))
	mux.HandleFunc("POST /api/v1/items/{id}/hide-continue", s.requireAuth(s.handleHideContinue))
	mux.HandleFunc("POST /api/v1/playback/progress", s.requireAuth(s.handleProgress))
	mux.HandleFunc("PUT /api/v1/work-prefs", s.requireAuth(s.handleWorkPrefs))

	mux.HandleFunc("GET /api/v1/lists", s.requireAuth(s.handleListLists))
	mux.HandleFunc("POST /api/v1/lists", s.requireAuth(s.handleCreateList))
	mux.HandleFunc("GET /api/v1/lists/{id}", s.requireAuth(s.handleGetList))
	mux.HandleFunc("PUT /api/v1/lists/{id}", s.requireAuth(s.handleUpdateList))
	mux.HandleFunc("DELETE /api/v1/lists/{id}", s.requireAuth(s.handleDeleteList))
	mux.HandleFunc("POST /api/v1/lists/{id}/items", s.requireAuth(s.handleAddListItems))
	mux.HandleFunc("DELETE /api/v1/lists/{id}/items/{item_id}", s.requireAuth(s.handleRemoveListItem))
	mux.HandleFunc("PUT /api/v1/lists/{id}/reorder", s.requireAuth(s.handleReorderList))

	// Playback resolve, streaming, subtitles & artwork (no gzip wrapper)
	mux.HandleFunc("GET /api/v1/playback/info/{id}", s.requireAuth(s.handlePlaybackInfoItem))
	mux.HandleFunc("GET /api/v1/playback/file/{file_id}", s.requireAuth(s.handlePlaybackInfoFile))
	mux.HandleFunc("GET /api/v1/stream/file/{file_id}", s.handleStreamFile)
	mux.HandleFunc("HEAD /api/v1/stream/file/{file_id}", s.handleStreamFile)
	mux.HandleFunc("GET /api/v1/stream/variant/{file_id}/{variant_id}/{filename}", s.handleStreamVariant)
	mux.HandleFunc("GET /api/v1/stream/hls-seg", s.handleStreamHLSSeg)
	mux.HandleFunc("GET /api/v1/subtitles/{file_id}", s.handleSubtitle)
	mux.HandleFunc("GET /api/v1/artwork/local/{mount_id}", s.requireAuth(s.handleLocalArtwork))
	mux.HandleFunc("GET /api/v1/artwork/remote", s.handleRemoteArtwork)

	// External Emby / Jellyfin servers
	mux.HandleFunc("GET /api/v1/ext-servers", s.requireAuth(s.handleListExternalServers))
	mux.HandleFunc("POST /api/v1/ext-servers", s.requireAuth(s.handleCreateExternalServer))
	mux.HandleFunc("POST /api/v1/ext-servers/test", s.requireAuth(s.handleTestExternalServer))
	mux.HandleFunc("PUT /api/v1/ext-servers/{id}", s.requireAuth(s.handleUpdateExternalServer))
	mux.HandleFunc("DELETE /api/v1/ext-servers/{id}", s.requireAuth(s.handleDeleteExternalServer))

	mux.HandleFunc("GET /api/v1/ext/{id}/home", s.requireAuth(s.handleExtHome))
	mux.HandleFunc("GET /api/v1/ext/{id}/items", s.requireAuth(s.handleExtItems))
	mux.HandleFunc("GET /api/v1/ext/{id}/items/{item_id}", s.requireAuth(s.handleExtItemDetail))
	mux.HandleFunc("GET /api/v1/ext/{id}/search", s.requireAuth(s.handleExtSearch))
	mux.HandleFunc("POST /api/v1/ext/{id}/items/{item_id}/favorite", s.requireAuth(s.handleExtFavorite))
	mux.HandleFunc("POST /api/v1/ext/{id}/items/{item_id}/watched", s.requireAuth(s.handleExtWatched))
	mux.HandleFunc("POST /api/v1/ext/{id}/playback/report", s.requireAuth(s.handleExtPlaybackReport))
	mux.HandleFunc("GET /api/v1/ext/{id}/playback/{item_id}", s.requireAuth(s.handleExtPlaybackInfo))
	mux.HandleFunc("GET /api/v1/ext/{id}/image/{item_id}/{image_type}", s.requireAuth(s.handleExtImage))
	mux.HandleFunc("GET /api/v1/ext/{id}/stream/{item_id}/{filename}", s.handleExtStream)
	mux.HandleFunc("HEAD /api/v1/ext/{id}/stream/{item_id}/{filename}", s.handleExtStream)
	mux.HandleFunc("GET /api/v1/ext/{id}/hls/{item_id}/master.m3u8", s.handleExtHLSMaster)
	mux.HandleFunc("GET /api/v1/ext/{id}/hls-proxy", s.handleExtHLSProxy)
	mux.HandleFunc("GET /api/v1/ext/{id}/subtitles/{item_id}/{source_id}/{index}", s.handleExtSubtitle)

	// Embedded SPA static files
	mux.HandleFunc("GET /", s.handleSPA)

	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":           0,
		"status":         "ok",
		"server_time_ms": time.Now().UnixMilli(),
	})
}

func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":         0,
		"initialized":  s.Auth.IsInitialized(),
		"server_name":  cfg.ServerName,
		"accent_theme": cfg.AccentTheme,
		"version":      "1.0.0",
	})
}

func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	ch, unsub := s.Hub.Subscribe()
	defer unsub()

	_, _ = io.WriteString(w, ": connected\n\n")
	flusher.Flush()

	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			_, _ = io.WriteString(w, ": ping\n\n")
			flusher.Flush()
		case ev, ok := <-ch:
			if !ok {
				return
			}
			raw, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			_, _ = io.WriteString(w, "event: "+ev.Type+"\ndata: "+string(raw)+"\n\n")
			flusher.Flush()
		}
	}
}

func (s *Server) handleSPA(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		writeErr(w, r, http.StatusNotFound, "not found")
		return
	}
	dist, _ := web.ResolveDiskFS(s.webDir)
	if dist == nil {
		http.Error(w, "Web UI files not found under ./web/dist or ./web", http.StatusNotFound)
		return
	}
	reqPath := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if reqPath == "" {
		reqPath = "index.html"
	}

	serveFile := func(name string, noStore bool) bool {
		f, err := dist.Open(name)
		if err != nil {
			return false
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || info.IsDir() {
			return false
		}
		data, err := io.ReadAll(f)
		if err != nil {
			return false
		}
		ct := mime.TypeByExtension(path.Ext(name))
		if ct == "" {
			if strings.HasSuffix(name, ".html") {
				ct = "text/html; charset=utf-8"
			} else if strings.HasSuffix(name, ".js") || strings.HasSuffix(name, ".mjs") {
				ct = "application/javascript; charset=utf-8"
			} else if strings.HasSuffix(name, ".css") {
				ct = "text/css; charset=utf-8"
			} else if strings.HasSuffix(name, ".svg") {
				ct = "image/svg+xml"
			} else {
				ct = http.DetectContentType(data)
			}
		}
		w.Header().Set("Content-Type", ct)
		if noStore || strings.HasSuffix(name, ".html") {
			w.Header().Set("Cache-Control", "no-store")
		} else if strings.HasPrefix(name, "assets/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "no-cache")
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
		return true
	}

	if serveFile(reqPath, false) {
		return
	}
	if !serveFile("index.html", true) {
		http.NotFound(w, r)
	}
}

func (s *Server) extractToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		if t := strings.TrimSpace(strings.TrimPrefix(h, "Bearer ")); t != "" {
			return t
		}
	}
	if c, err := r.Cookie(auth.SessionCookieName); err == nil && strings.TrimSpace(c.Value) != "" {
		return strings.TrimSpace(c.Value)
	}
	return ""
}

func (s *Server) authenticateRequest(r *http.Request) (*db.AdminAccount, *db.SessionRecord, error) {
	return s.Auth.Authenticate(s.extractToken(r))
}

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, *db.AdminAccount, *db.SessionRecord)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		acc, sess, err := s.authenticateRequest(r)
		if err != nil {
			writeErr(w, r, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r, acc, sess)
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	reader := http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	dec := json.NewDecoder(reader)
	return dec.Decode(dst)
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	raw, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"code":500,"message":"marshal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") && len(raw) > 512 {
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(status)
		gz := gzip.NewWriter(w)
		_, _ = gz.Write(raw)
		_ = gz.Close()
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(raw)
}

func writeErr(w http.ResponseWriter, r *http.Request, status int, msg string) {
	writeJSON(w, r, status, map[string]any{
		"code":    status,
		"message": msg,
	})
}

func writeMappedError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, db.ErrNotFound), errors.Is(err, metadata.ErrNotFound), storage.IsKind(err, storage.ErrKindNotFound):
		writeErr(w, r, http.StatusNotFound, err.Error())
	case errors.Is(err, auth.ErrUnauthorized), errors.Is(err, auth.ErrInvalidCredentials), storage.IsKind(err, storage.ErrKindUnauthorized):
		writeErr(w, r, http.StatusUnauthorized, err.Error())
	case errors.Is(err, auth.ErrAlreadyInitialized), errors.Is(err, db.ErrConflict):
		writeErr(w, r, http.StatusConflict, err.Error())
	case errors.Is(err, db.ErrInvalidInput), errors.Is(err, auth.ErrInvalidInput), errors.Is(err, metadata.ErrInvalidInput):
		writeErr(w, r, http.StatusBadRequest, err.Error())
	case errors.Is(err, metadata.ErrNotConfigured):
		writeErr(w, r, http.StatusPreconditionFailed, err.Error())
	case errors.Is(err, metadata.ErrDisabled):
		writeErr(w, r, http.StatusForbidden, err.Error())
	case errors.Is(err, metadata.ErrUpstream), storage.IsKind(err, storage.ErrKindNetwork):
		writeErr(w, r, http.StatusBadGateway, err.Error())
	case storage.IsKind(err, storage.ErrKindRateLimited):
		writeErr(w, r, http.StatusTooManyRequests, err.Error())
	default:
		writeErr(w, r, http.StatusInternalServerError, err.Error())
	}
}
