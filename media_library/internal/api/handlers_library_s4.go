package api

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/library"
)

const householdMetaRateLimitPerMin = 120

func (s *Server) requireUserMetadataQuota(next http.HandlerFunc) http.HandlerFunc {
	return s.requireUser(func(w http.ResponseWriter, r *http.Request) {
		p := UserPrincipalFromContext(r.Context())
		if p == nil {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "authentication required")
			return
		}
		if s.metaLimiter != nil && !s.metaLimiter.AllowWindow("hh_meta:"+p.HouseholdID, householdMetaRateLimitPerMin, time.Minute) {
			writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", "household metadata rate limit exceeded")
			return
		}
		next(w, r)
	})
}

func (s *Server) allowedSourceIDs(p *account.Principal) ([]string, error) {
	if p == nil {
		return nil, account.ErrUnauthorized
	}
	if !p.RestrictSources {
		return nil, nil
	}
	rows, err := s.Store.ReadDB().Query(`
		SELECT source_id FROM member_source_access
		WHERE household_id = ? AND member_id = ?`,
		p.HouseholdID, p.MemberID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	ids := make([]string, 0)
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil && id != "" {
			ids = append(ids, id)
		}
	}
	return ids, rows.Err()
}

func (s *Server) handleUserMetadataSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "q is required")
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
		"artwork_proxy_path": "/api/v1/metadata/artwork",
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handleUserMetadataWork(w http.ResponseWriter, r *http.Request) {
	provider := normalizePublicProvider(firstNonEmpty(r.PathValue("provider"), r.URL.Query().Get("provider")))
	kind := normalizePublicWorkKind(firstNonEmpty(r.PathValue("kind"), r.URL.Query().Get("kind")))
	id := strings.TrimSpace(firstNonEmpty(r.PathValue("id"), r.URL.Query().Get("id")))
	if provider == "" || id == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "provider and id are required")
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
		"artwork_proxy_path": "/api/v1/metadata/artwork",
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handleUserMetadataSeason(w http.ResponseWriter, r *http.Request) {
	provider := normalizePublicProvider(firstNonEmpty(r.PathValue("provider"), r.URL.Query().Get("provider")))
	id := strings.TrimSpace(firstNonEmpty(r.PathValue("id"), r.URL.Query().Get("id")))
	seasonStr := strings.TrimSpace(firstNonEmpty(r.PathValue("season"), r.URL.Query().Get("season")))
	seasonNum, err := strconv.Atoi(seasonStr)
	if provider == "" || id == "" || err != nil || seasonNum < 0 {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "valid provider, id and season are required")
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
		"artwork_proxy_path": "/api/v1/metadata/artwork",
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handleUserMetadataPerson(w http.ResponseWriter, r *http.Request) {
	provider := normalizePublicProvider(firstNonEmpty(r.PathValue("provider"), r.URL.Query().Get("provider")))
	if provider == "" {
		provider = "tmdb"
	}
	id := strings.TrimSpace(firstNonEmpty(r.PathValue("id"), r.URL.Query().Get("id")))
	if id == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "id is required")
		return
	}
	cfg := s.Store.GetServerSettings()
	lang := strings.TrimSpace(r.URL.Query().Get("lang"))
	if lang == "" {
		lang = cfg.ScraperLang
	}
	refresh := r.URL.Query().Get("refresh") == "1" || strings.EqualFold(r.URL.Query().Get("refresh"), "true")

	person, err := s.Meta.GetPerson(r.Context(), provider, id, lang, refresh)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":               0,
		"person":             person,
		"image_base":         cfg.TmdbImageBase,
		"artwork_proxy_path": "/api/v1/metadata/artwork",
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handleUserMetadataIdentify(w http.ResponseWriter, r *http.Request) {
	var req library.PublicIdentifyRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
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
		"artwork_proxy_path": "/api/v1/metadata/artwork",
		"proxy_images":       cfg.ProxyImages,
	})
}

func (s *Server) handleListUnmatched(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	q := r.URL.Query()
	page, _ := strconv.Atoi(q.Get("page"))
	pageSize, _ := strconv.Atoi(q.Get("page_size"))

	res, err := s.Scraper.ListUnmatchedFiles(p.HouseholdID, allowed, q.Get("source_id"), q.Get("state"), page, pageSize)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":      0,
		"items":     res.Items,
		"total":     res.Total,
		"page":      res.Page,
		"page_size": res.PageSize,
	})
}

func (s *Server) handleIgnoreUnmatched(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	var req library.IgnoreUnmatchedRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	updated, err := s.Scraper.IgnoreUnmatchedFiles(p.HouseholdID, p.MemberID, allowed, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"updated": updated,
	})
}

func (s *Server) handleManualMatch(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	var req library.ManualMatchRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Scraper.ApplyManualMatch(r.Context(), p.HouseholdID, p.MemberID, allowed, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Hub != nil {
		s.Hub.PublishToHousehold(p.HouseholdID, "library.changed", map[string]any{
			"item_id": res.ItemID,
		})
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":          0,
		"item_id":       res.ItemID,
		"work_key":      res.WorkKey,
		"kind":          res.Kind,
		"title":         res.Title,
		"matched_files": res.MatchedFiles,
		"rule_ids":      res.RuleIDs,
	})
}

func (s *Server) handleListMatchRules(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	rules, err := s.Scraper.ListMatchRules(p.HouseholdID, allowed, r.URL.Query().Get("source_id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"rules": rules,
	})
}

func (s *Server) handleUpsertMatchRule(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	var req library.UpsertMatchRuleRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	rule, err := s.Scraper.UpsertMatchRule(p.HouseholdID, p.MemberID, allowed, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Idf != nil {
		s.Idf.Wake()
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"rule": rule,
	})
}

func (s *Server) handleDeleteMatchRule(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if err := s.Scraper.DeleteMatchRule(p.HouseholdID, allowed, r.PathValue("id")); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleEditItem(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || itemID <= 0 {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid item id")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	var req library.EditItemRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Scraper.EditMediaItem(p.HouseholdID, allowed, itemID, req); err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Hub != nil {
		s.Hub.PublishToHousehold(p.HouseholdID, "library.changed", map[string]any{
			"item_id": itemID,
		})
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"item_id": itemID,
	})
}

func (s *Server) handleRescrapeItem(w http.ResponseWriter, r *http.Request) {
	if s.Scraper == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "scraper unavailable")
		return
	}
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || itemID <= 0 {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid item id")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	allowed, err := s.allowedSourceIDs(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	var req library.RescrapeRequest
	if r.ContentLength != 0 {
		if err := decodeJSON(w, r, &req); err != nil {
			writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
			return
		}
	}
	if err := s.Scraper.RescrapeMediaItem(r.Context(), p.HouseholdID, allowed, itemID, req); err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Hub != nil {
		s.Hub.PublishToHousehold(p.HouseholdID, "library.changed", map[string]any{
			"item_id": itemID,
		})
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"item_id": itemID,
	})
}

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return strings.TrimSpace(a)
	}
	return strings.TrimSpace(b)
}
