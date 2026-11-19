package api

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/metadata"
)

func (s *Server) handleTaskStatus(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"status": s.Coordinator.TaskStatus(),
	})
}

func (s *Server) handleScanAll(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	full := r.URL.Query().Get("full") == "1" || strings.EqualFold(r.URL.Query().Get("full"), "true")
	s.Coordinator.TriggerScanAllAsync(full)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "started"})
}

func (s *Server) handleScanMount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	if _, err := s.Store.GetMount(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	full := r.URL.Query().Get("full") == "1" || strings.EqualFold(r.URL.Query().Get("full"), "true")
	if r.URL.Query().Get("sync") == "1" {
		res, err := s.Coordinator.Scanner.ScanMount(r.Context(), id, full)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		if res.Videos > 0 || res.AddedPending {
			s.Coordinator.Scanner.ProbePendingFiles(r.Context(), 50)
			_, _ = s.Coordinator.WaitOrRunScrapeSync(r.Context(), false, false)
		}
		writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "result": res})
		return
	}
	s.Coordinator.TriggerMountScanAsync(id, full)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "started"})
}

func (s *Server) handleCancelScan(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	s.Coordinator.Scanner.CancelMount(id)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "cancelling"})
}

func (s *Server) handleScrapeAll(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	retryUnmatched := r.URL.Query().Get("retry_unmatched") == "1" || strings.EqualFold(r.URL.Query().Get("retry_unmatched"), "true")
	refreshAll := r.URL.Query().Get("refresh_all") == "1" || strings.EqualFold(r.URL.Query().Get("refresh_all"), "true")
	if r.URL.Query().Get("sync") == "1" {
		sum, err := s.Coordinator.WaitOrRunScrapeSync(r.Context(), retryUnmatched, refreshAll)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "summary": sum})
		return
	}
	s.Coordinator.TriggerScrapeAsync(retryUnmatched, refreshAll)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "started"})
}

func (s *Server) handleUnmatched(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	items, total, err := s.Store.QueryUnmatched(limit, offset)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"items": items,
		"total": total,
	})
}

func (s *Server) handleScrapeSearch(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	provider := strings.TrimSpace(r.URL.Query().Get("provider"))
	year, _ := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("year")))
	if kind == "" {
		kind = "movie"
	}
	cfg := s.Store.GetServerSettings()

	var providers []string
	if provider != "" {
		providers = []string{provider}
	} else {
		if cfg.TmdbAPIKey != "" {
			providers = append(providers, "tmdb")
		}
		if cfg.BangumiEnabled {
			providers = append(providers, "bangumi")
		}
	}

	results := make([]metadata.Candidate, 0)
	var lastErr error
	for _, p := range providers {
		cands, err := s.Meta.Search(r.Context(), p, kind, q, year, cfg.ScraperLang, false)
		if err != nil {
			lastErr = err
			continue
		}
		results = append(results, cands...)
	}
	if len(results) == 0 && lastErr != nil {
		writeMappedError(w, r, lastErr)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "results": results})
}

func (s *Server) handleManualMatch(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	var req struct {
		Provider    string `json:"provider"`
		ExternalID  string `json:"external_id"`
		AsShow      bool   `json:"as_show"`
		LibraryType string `json:"library_type"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	item, err := s.Coordinator.Scraper.ApplyManualMatch(r.Context(), itemID, req.Provider, req.ExternalID, req.AsShow, req.LibraryType)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "item": item})
}

func (s *Server) handleUnmatchItem(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	if err := s.Coordinator.Scraper.UnmatchItem(itemID); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "unmatched"})
}

func (s *Server) handleUpdateMetadata(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	var req db.ManualItemUpdate
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	updated, err := s.Store.UpdateMediaItemManual(itemID, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	s.Hub.Publish("library_changed", map[string]any{"item_id": itemID})
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "item": updated})
}

func (s *Server) handleRefreshItem(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	item, err := s.Store.GetMediaItem(itemID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	cfg := s.Store.GetServerSettings()
	var prov, extID string
	if item.TmdbID != nil && *item.TmdbID != "" {
		prov, extID = "tmdb", *item.TmdbID
	} else if item.BangumiID != nil && *item.BangumiID != "" {
		prov, extID = "bangumi", *item.BangumiID
	}
	if prov != "" && extID != "" {
		_, _ = s.Meta.GetWork(r.Context(), prov, item.Kind, extID, cfg.ScraperLang, true)
		refreshed, err := s.Coordinator.Scraper.ApplyManualMatch(r.Context(), itemID, prov, extID, item.Kind == db.KindShow, item.LibraryType)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "item": refreshed})
		return
	}

	// Unmatched item: trigger a fresh scrape attempt
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	_, _ = s.Coordinator.Scraper.ScrapePending(ctx, true, false)
	latest, _ := s.Store.GetMediaItem(itemID)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "item": latest})
}
