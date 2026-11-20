package api

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
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
		if tok := bearerToken(r); strings.HasPrefix(tok, account.UserTokenPrefix) && s.Acc != nil {
			if _, err := s.Acc.Authenticate(tok); err == nil {
				next(w, r)
				return
			}
		}
		cfg := s.Store.GetServerSettings()
		if !cfg.AllowPublicMetadata {
			writeErrCode(w, r, http.StatusForbidden, "public_metadata_disabled", "public metadata service is disabled")
			return
		}
		if !s.checkPublicRateLimit(s.clientIP(r)) {
			writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", "rate limit exceeded")
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
	res, err := s.Scraper.IdentifyPublic(r.Context(), req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"matched":            res.Matched,
		"kind":               res.Kind,
		"work_key":           res.WorkKey,
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

func (s *Server) serveRemoteArtwork(w http.ResponseWriter, r *http.Request) {
	src := strings.TrimSpace(r.URL.Query().Get("src"))
	size := strings.TrimSpace(r.URL.Query().Get("size"))
	cfg := s.Store.GetServerSettings()

	if !cfg.ProxyImages {
		resolved, err := s.Meta.ResolveRemoteImageURL(src, size)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		http.Redirect(w, r, resolved, http.StatusFound)
		return
	}

	img, err := s.Meta.FetchRemoteImage(r.Context(), src, size)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", img.ContentType)
	w.Header().Set("Cache-Control", "public, max-age=2592000")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(img.Data)
}

func (s *Server) searchMetadataCandidates(
	ctx context.Context,
	q, kind, provider string,
	year int,
	lang string,
	refresh bool,
) ([]metadata.Candidate, error) {
	cfg := s.Store.GetServerSettings()
	if strings.TrimSpace(kind) == "" {
		kind = "movie"
	}
	if strings.TrimSpace(lang) == "" {
		lang = cfg.ScraperLang
	}

	// Direct external ID or URL lookup (e.g. tt1234567, douban:36283066, tmdb:230311, bgm:400602)
	if directProv, directID, kindHint, ok := library.ParseManualDirectID(q); ok {
		effKind := kind
		if kindHint != "" {
			effKind = kindHint
		}
		work, err := s.Meta.GetWork(ctx, directProv, effKind, directID, lang, refresh)
		if err != nil && kindHint == "" {
			altKind := "show"
			if effKind == "show" {
				altKind = "movie"
			}
			if w2, err2 := s.Meta.GetWork(ctx, directProv, altKind, directID, lang, refresh); err2 == nil {
				work = w2
				err = nil
				effKind = altKind
			}
		}
		if err != nil {
			return nil, err
		}

		results := make([]metadata.Candidate, 0, 2)
		if directProv != "tmdb" && cfg.TmdbAPIKey != "" {
			if work.TmdbID != nil && *work.TmdbID != "" {
				if tw, tErr := s.Meta.GetWork(ctx, "tmdb", effKind, *work.TmdbID, lang, refresh); tErr == nil {
					results = append(results, candidateFromWork(tw))
				}
			} else if work.ImdbID != nil && *work.ImdbID != "" {
				if c, _, fErr := s.Meta.FindByExternalID(ctx, "imdb_id", *work.ImdbID, effKind, lang, refresh); fErr == nil && c != nil {
					results = append(results, *c)
				}
			} else if work.TvdbID != nil && *work.TvdbID != "" {
				if c, _, fErr := s.Meta.FindByExternalID(ctx, "tvdb_id", *work.TvdbID, effKind, lang, refresh); fErr == nil && c != nil {
					results = append(results, *c)
				}
			}
		}
		results = append(results, candidateFromWork(work))
		return results, nil
	}

	var providers []string
	if provider != "" && !strings.EqualFold(provider, "all") {
		providers = []string{strings.ToLower(provider)}
	} else {
		if cfg.TmdbAPIKey != "" {
			providers = append(providers, "tmdb")
		}
		if cfg.DoubanEnabled {
			providers = append(providers, "douban")
		}
		if cfg.BangumiEnabled {
			providers = append(providers, "bangumi")
		}
		if cfg.AniListEnabled {
			providers = append(providers, "anilist")
		}
		if cfg.ImdbEnabled {
			providers = append(providers, "imdb")
		}
		if cfg.TvdbEnabled && cfg.TvdbAPIKey != "" {
			providers = append(providers, "tvdb")
		}
	}

	if len(providers) == 0 {
		return []metadata.Candidate{}, nil
	}

	perProv := make([][]metadata.Candidate, len(providers))
	errs := make([]error, len(providers))
	var wg sync.WaitGroup
	for i, p := range providers {
		wg.Add(1)
		go func(idx int, prov string) {
			defer wg.Done()
			searchCtx := ctx
			if prov != "tmdb" {
				var cancel context.CancelFunc
				searchCtx, cancel = context.WithTimeout(searchCtx, 8*time.Second)
				defer cancel()
			}
			cands, err := s.Meta.Search(searchCtx, prov, kind, q, year, lang, refresh)
			if err != nil {
				errs[idx] = err
				return
			}
			perProv[idx] = cands
		}(i, p)
	}
	wg.Wait()

	results := make([]metadata.Candidate, 0)
	var lastErr error
	for i := range providers {
		if errs[i] != nil {
			lastErr = errs[i]
			continue
		}
		results = append(results, perProv[i]...)
	}
	if len(results) == 0 && lastErr != nil {
		return nil, lastErr
	}
	return results, nil
}

func candidateFromWork(w metadata.Work) metadata.Candidate {
	return metadata.Candidate{
		Source:        w.Source,
		ID:            w.ExternalID,
		Title:         w.Title,
		OriginalTitle: w.OriginalTitle,
		Year:          w.Year,
		Summary:       w.Summary,
		PosterPath:    w.PosterPath,
	}
}
