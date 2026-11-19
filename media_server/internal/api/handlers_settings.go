package api

import (
	"net/http"

	"plezy/media_server/internal/db"
)

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	cfg := s.Store.GetServerSettings()
	stats := s.Meta.CacheStats()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"settings":    cfg,
		"cache_stats": stats,
	})
}

func (s *Server) handleUpdateSettings(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req db.ServerSettingsUpdate
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	updated, err := s.Store.UpdateServerSettings(req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if req.WatchLocalFS != nil {
		s.Coordinator.RefreshWatchers()
	}
	if req.TmdbAPIKey != nil || (req.BangumiEnabled != nil && *req.BangumiEnabled) {
		s.Coordinator.NotifyScrape()
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"settings":    updated,
		"cache_stats": s.Meta.CacheStats(),
	})
}

func (s *Server) handleTestTmdb(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		TmdbAPIKey    *string `json:"tmdb_api_key,omitempty"`
		TmdbAPIBase   *string `json:"tmdb_api_base,omitempty"`
		MetadataProxy *string `json:"metadata_proxy,omitempty"`
	}
	if r.Body != nil {
		_ = decodeJSON(w, r, &req)
	}
	latency, err := s.Meta.TestTmdbConnection(r.Context(), req.TmdbAPIKey, req.TmdbAPIBase, req.MetadataProxy)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"ok":         true,
		"latency_ms": latency,
	})
}

func (s *Server) handleClearMetaCache(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		Scope string `json:"scope"`
	}
	if r.Body != nil {
		_ = decodeJSON(w, r, &req)
	}
	deleted, stats, err := s.Meta.ClearCache(req.Scope)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"deleted":     deleted,
		"cache_stats": stats,
	})
}

func (s *Server) handleSystemOverview(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	ov := s.Store.GetSystemOverview()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"overview":    ov,
		"cache_stats": s.Meta.CacheStats(),
	})
}
