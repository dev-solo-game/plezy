package api

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
)

const (
	publicMetadataArtworkPath = "/api/v1/public/metadata/artwork"
	publicRateLimitPerMin     = 180
	maxPublicBatchItems       = 50
)

type ipRateBucket struct {
	windowStart time.Time
	count       int
}

func (s *Server) checkPublicRateLimit(ip string) bool {
	if ip == "" {
		ip = "unknown"
	}
	now := time.Now()
	s.pubRateMu.Lock()
	defer s.pubRateMu.Unlock()
	if s.pubRate == nil {
		s.pubRate = make(map[string]*ipRateBucket)
	}
	b, ok := s.pubRate[ip]
	if !ok || now.Sub(b.windowStart) >= time.Minute {
		// Opportunistically prune stale entries when the map grows
		if len(s.pubRate) > 1024 {
			for k, v := range s.pubRate {
				if now.Sub(v.windowStart) >= 2*time.Minute {
					delete(s.pubRate, k)
				}
			}
		}
		s.pubRate[ip] = &ipRateBucket{windowStart: now, count: 1}
		return true
	}
	b.count++
	return b.count <= publicRateLimitPerMin
}

func (s *Server) requirePublicMetadata(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_, _, authErr := s.authenticateRequest(r)
		isAuthed := authErr == nil
		cfg := s.Store.GetServerSettings()
		if !cfg.AllowPublicMetadata && !isAuthed {
			writeErr(w, r, http.StatusForbidden, "public metadata service is disabled")
			return
		}
		if !isAuthed && !s.checkPublicRateLimit(clientIP(r)) {
			writeErr(w, r, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		next(w, r)
	}
}

func enabledMetadataProviders(cfg db.ServerSettings) []string {
	var out []string
	if cfg.TmdbAPIKey != "" {
		out = append(out, "tmdb")
	}
	if cfg.DoubanEnabled {
		out = append(out, "douban")
	}
	if cfg.BangumiEnabled {
		out = append(out, "bangumi")
	}
	if cfg.AniListEnabled {
		out = append(out, "anilist")
	}
	if cfg.ImdbEnabled {
		out = append(out, "imdb")
	}
	if cfg.TvdbEnabled && cfg.TvdbAPIKey != "" {
		out = append(out, "tvdb")
	}
	return out
}

func (s *Server) handlePublicMetadataConfig(w http.ResponseWriter, r *http.Request) {
	cfg := s.Store.GetServerSettings()
	stats := s.Meta.CacheStats()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                  0,
		"allow_public_metadata": cfg.AllowPublicMetadata,
		"tmdb_configured":       cfg.TmdbAPIKeySet,
		"bangumi_enabled":       cfg.BangumiEnabled,
		"douban_enabled":        cfg.DoubanEnabled,
		"anilist_enabled":       cfg.AniListEnabled,
		"imdb_enabled":          cfg.ImdbEnabled,
		"tvdb_enabled":          cfg.TvdbEnabled && cfg.TvdbAPIKeySet,
		"enabled_providers":     enabledMetadataProviders(cfg),
		"tmdb_image_base":       cfg.TmdbImageBase,
		"artwork_proxy_path":    publicMetadataArtworkPath,
		"proxy_images":          cfg.ProxyImages,
		"cache_stats":           stats,
	})
}

func (s *Server) handlePublicMetadataSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeErr(w, r, http.StatusBadRequest, "q is required")
		return
	}
	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	provider := strings.TrimSpace(r.URL.Query().Get("provider"))
	if provider == "" {
		provider = "all"
	}
	lang := strings.TrimSpace(r.URL.Query().Get("lang"))
	year, _ := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("year")))
	refresh := r.URL.Query().Get("refresh") == "1" || strings.EqualFold(r.URL.Query().Get("refresh"), "true")

	results, err := s.searchMetadataCandidates(r.Context(), q, kind, provider, year, lang, refresh)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"results":            results,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": publicMetadataArtworkPath,
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handlePublicMetadataIdentify(w http.ResponseWriter, r *http.Request) {
	var req library.PublicIdentifyRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	res, err := s.Coordinator.Scraper.IdentifyPublic(r.Context(), req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"matched":            res.Matched,
		"kind":               res.Kind,
		"source":             res.Source,
		"bridged_from":       res.BridgedFrom,
		"implied_season":     res.ImpliedSeason,
		"work":               res.Work,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": publicMetadataArtworkPath,
		"proxy_images":       cfg.ProxyImages,
	})
}

func normalizePublicWorkKind(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "show", "tv", "series":
		return db.KindShow
	default:
		return db.KindMovie
	}
}

func normalizePublicProvider(raw string) string {
	p := strings.ToLower(strings.TrimSpace(raw))
	if p == "bgm" {
		return "bangumi"
	}
	return p
}

func (s *Server) handlePublicMetadataWork(w http.ResponseWriter, r *http.Request) {
	provider := normalizePublicProvider(r.PathValue("provider"))
	kind := normalizePublicWorkKind(r.PathValue("kind"))
	id := strings.TrimSpace(r.PathValue("id"))
	if provider == "" || id == "" {
		writeErr(w, r, http.StatusBadRequest, "provider and id are required")
		return
	}
	cfg := s.Store.GetServerSettings()
	lang := strings.TrimSpace(r.URL.Query().Get("lang"))
	if lang == "" {
		lang = cfg.ScraperLang
	}
	refresh := r.URL.Query().Get("refresh") == "1" || strings.EqualFold(r.URL.Query().Get("refresh"), "true")

	work, err := s.Meta.GetWork(r.Context(), provider, kind, id, lang, refresh)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"work":               work,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": publicMetadataArtworkPath,
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handlePublicMetadataSeason(w http.ResponseWriter, r *http.Request) {
	provider := normalizePublicProvider(r.PathValue("provider"))
	id := strings.TrimSpace(r.PathValue("id"))
	seasonNum, err := strconv.Atoi(strings.TrimSpace(r.PathValue("season")))
	if provider == "" || id == "" || err != nil || seasonNum < 0 {
		writeErr(w, r, http.StatusBadRequest, "valid provider, id and season are required")
		return
	}
	cfg := s.Store.GetServerSettings()
	lang := strings.TrimSpace(r.URL.Query().Get("lang"))
	if lang == "" {
		lang = cfg.ScraperLang
	}
	refresh := r.URL.Query().Get("refresh") == "1" || strings.EqualFold(r.URL.Query().Get("refresh"), "true")

	season, err := s.Meta.GetSeason(r.Context(), provider, id, seasonNum, lang, refresh)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"season":             season,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": publicMetadataArtworkPath,
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handlePublicMetadataBatch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Lang    string `json:"lang"`
		Refresh bool   `json:"refresh"`
		Works   []struct {
			Provider string `json:"provider"`
			Kind     string `json:"kind"`
			ID       string `json:"id"`
			Lang     string `json:"lang"`
		} `json:"works"`
		Seasons []struct {
			Provider string `json:"provider"`
			ID       string `json:"id"`
			Season   int    `json:"season"`
			Lang     string `json:"lang"`
		} `json:"seasons"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if len(req.Works) > maxPublicBatchItems || len(req.Seasons) > maxPublicBatchItems {
		writeErr(w, r, http.StatusBadRequest, fmt.Sprintf("batch requests may contain at most %d items per type", maxPublicBatchItems))
		return
	}

	cfg := s.Store.GetServerSettings()
	defaultLang := strings.TrimSpace(req.Lang)
	if defaultLang == "" {
		defaultLang = cfg.ScraperLang
	}

	worksOut := make(map[string]metadata.Work)
	seasonsOut := make(map[string]metadata.Season)
	errorsOut := make(map[string]string)
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 6)

	for _, wItem := range req.Works {
		prov := normalizePublicProvider(wItem.Provider)
		kind := normalizePublicWorkKind(wItem.Kind)
		id := strings.TrimSpace(wItem.ID)
		if prov == "" || id == "" {
			continue
		}
		lang := strings.TrimSpace(wItem.Lang)
		if lang == "" {
			lang = defaultLang
		}
		key := fmt.Sprintf("%s:%s:%s", prov, kind, id)
		wg.Add(1)
		go func(k, p, knd, extID, l string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			work, err := s.Meta.GetWork(r.Context(), p, knd, extID, l, req.Refresh)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errorsOut[k] = err.Error()
			} else {
				worksOut[k] = work
			}
		}(key, prov, kind, id, lang)
	}

	for _, sItem := range req.Seasons {
		prov := normalizePublicProvider(sItem.Provider)
		id := strings.TrimSpace(sItem.ID)
		if prov == "" || id == "" || sItem.Season < 0 {
			continue
		}
		lang := strings.TrimSpace(sItem.Lang)
		if lang == "" {
			lang = defaultLang
		}
		key := fmt.Sprintf("%s:%s:%d", prov, id, sItem.Season)
		wg.Add(1)
		go func(k, p, extID string, sNum int, l string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			season, err := s.Meta.GetSeason(r.Context(), p, extID, sNum, l, req.Refresh)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errorsOut[k] = err.Error()
			} else {
				seasonsOut[k] = season
			}
		}(key, prov, id, sItem.Season, lang)
	}

	wg.Wait()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"works":              worksOut,
		"seasons":            seasonsOut,
		"errors":             errorsOut,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": publicMetadataArtworkPath,
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handlePublicMetadataArtwork(w http.ResponseWriter, r *http.Request) {
	s.serveRemoteArtwork(w, r)
}
