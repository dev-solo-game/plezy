package api

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/library"
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

func (s *Server) handleScrapeSearch(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	provider := strings.TrimSpace(r.URL.Query().Get("provider"))
	year, _ := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("year")))
	refresh := r.URL.Query().Get("refresh") == "1" || strings.EqualFold(r.URL.Query().Get("refresh"), "true")

	results, err := s.searchMetadataCandidates(r.Context(), q, kind, provider, year, "", refresh)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "results": results})
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
	prov, extID := resolveItemProviderID(item)
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

func resolveItemProviderID(item db.MediaItem) (string, string) {
	if item.MetadataSource != nil {
		switch *item.MetadataSource {
		case "tmdb":
			if item.TmdbID != nil && *item.TmdbID != "" {
				return "tmdb", *item.TmdbID
			}
		case "bangumi":
			if item.BangumiID != nil && *item.BangumiID != "" {
				return "bangumi", *item.BangumiID
			}
		case "douban":
			if item.DoubanID != nil && *item.DoubanID != "" {
				return "douban", *item.DoubanID
			}
		case "anilist":
			if item.AniListID != nil && *item.AniListID != "" {
				return "anilist", *item.AniListID
			}
		case "imdb":
			if item.ImdbID != nil && *item.ImdbID != "" {
				return "imdb", *item.ImdbID
			}
		case "tvdb":
			if item.TvdbID != nil && *item.TvdbID != "" {
				return "tvdb", *item.TvdbID
			}
		}
	}
	if item.TmdbID != nil && *item.TmdbID != "" {
		return "tmdb", *item.TmdbID
	}
	if item.BangumiID != nil && *item.BangumiID != "" {
		return "bangumi", *item.BangumiID
	}
	if item.DoubanID != nil && *item.DoubanID != "" {
		return "douban", *item.DoubanID
	}
	if item.AniListID != nil && *item.AniListID != "" {
		return "anilist", *item.AniListID
	}
	if item.ImdbID != nil && *item.ImdbID != "" {
		return "imdb", *item.ImdbID
	}
	if item.TvdbID != nil && *item.TvdbID != "" {
		return "tvdb", *item.TvdbID
	}
	return "", ""
}
