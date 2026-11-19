package api

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/db"
)

func (s *Server) handleHome(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	home, err := s.Store.GetHomeData()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "home": home})
}

func (s *Server) handleLibraryItems(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	q := r.URL.Query()
	genreID, _ := strconv.ParseInt(q.Get("genre_id"), 10, 64)
	year, _ := strconv.Atoi(q.Get("year"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	limit, _ := strconv.Atoi(q.Get("limit"))

	var watchedPtr *bool
	switch strings.ToLower(strings.TrimSpace(q.Get("watched"))) {
	case "1", "true":
		v := true
		watchedPtr = &v
	case "0", "false":
		v := false
		watchedPtr = &v
	}

	fav := q.Get("favorite") == "1" || strings.EqualFold(q.Get("favorite"), "true")
	page, err := s.Store.QueryLibrary(db.LibraryQuery{
		LibraryType: strings.TrimSpace(q.Get("shelf")),
		Kind:        strings.TrimSpace(q.Get("kind")),
		MountID:     strings.TrimSpace(q.Get("mount_id")),
		GenreID:     genreID,
		Year:        year,
		Quality:     strings.TrimSpace(q.Get("quality")),
		Watched:     watchedPtr,
		Favorite:    fav,
		Letter:      strings.TrimSpace(q.Get("letter")),
		Search:      strings.TrimSpace(q.Get("search")),
		Sort:        strings.TrimSpace(q.Get("sort")),
		Order:       strings.TrimSpace(q.Get("order")),
		Offset:      offset,
		Limit:       limit,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"items":  page.Items,
		"total":  page.Total,
		"offset": page.Offset,
		"limit":  page.Limit,
	})
}

func (s *Server) handleLibraryFacets(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	shelf := strings.TrimSpace(r.URL.Query().Get("shelf"))
	facets, err := s.Store.GetLibraryFacets(shelf)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "facets": facets})
}

func (s *Server) handleItemDetail(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	detail, err := s.Store.GetItemDetail(itemID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	// Probe unprobed files lazily when viewing item detail
	probedAny := false
	for i := range detail.Files {
		if detail.Files[i].ProbedAt == nil {
			pCtx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
			if updated, pErr := s.Coordinator.Scanner.ProbeFileByID(pCtx, detail.Files[i].ID); pErr == nil {
				detail.Files[i] = updated
				probedAny = true
			}
			cancel()
		}
	}
	if probedAny {
		if refreshed, err := s.Store.GetItemDetail(itemID); err == nil {
			detail = refreshed
		}
	}

	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "detail": detail})
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	res, err := s.Store.SearchAll(q, limit)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "results": res})
}

func (s *Server) handlePersonDetail(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	pid, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid person id")
		return
	}
	detail, err := s.Store.GetPersonDetail(pid)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if detail.Person.Biography == nil && detail.Person.Provider == "tmdb" && detail.Person.ExternalID != nil && *detail.Person.ExternalID != "" {
		cfg := s.Store.GetServerSettings()
		if cfg.TmdbAPIKey != "" {
			if pMeta, mErr := s.Meta.GetPerson(r.Context(), "tmdb", *detail.Person.ExternalID, cfg.ScraperLang, false); mErr == nil {
				_, _ = s.Store.DB().Exec(`
					UPDATE people SET photo_source = COALESCE(NULLIF(photo_source,''), ?),
						biography = ?, birthday = ?, department = ?, place_of_birth = ?
					WHERE id = ?`,
					pMeta.ProfilePath, pMeta.Biography, pMeta.Birthday, pMeta.KnownForDepartment, pMeta.PlaceOfBirth, pid,
				)
				if refreshed, rErr := s.Store.GetPersonDetail(pid); rErr == nil {
					detail = refreshed
				}
			}
		}
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "detail": detail})
}

func (s *Server) handleFavorite(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	var req struct {
		Favorite bool `json:"favorite"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	ws, err := s.Store.SetFavorite(itemID, req.Favorite)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "watch_state": ws})
}

func (s *Server) handleWatched(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	var req struct {
		Watched bool `json:"watched"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	ws, err := s.Store.SetWatched(itemID, req.Watched)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "watch_state": ws})
}

func (s *Server) handleHideContinue(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	if err := s.Store.SetHiddenFromContinue(itemID, true); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok"})
}

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		ItemID     int64  `json:"item_id"`
		FileID     *int64 `json:"file_id,omitempty"`
		PositionMs int64  `json:"position_ms"`
		DurationMs *int64 `json:"duration_ms,omitempty"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	cfg := s.Store.GetServerSettings()
	ws, err := s.Store.UpdateProgress(req.ItemID, req.FileID, req.PositionMs, req.DurationMs, cfg.WatchedThreshold)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "watch_state": ws})
}

func (s *Server) handleWorkPrefs(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var wp db.WorkPrefs
	if err := decodeJSON(w, r, &wp); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	saved, err := s.Store.UpsertWorkPrefs(wp)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "work_prefs": saved})
}

// ─── Lists (Collections & Playlists) ──────────────────────────────────────

func (s *Server) handleListLists(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	lists, err := s.Store.ListMediaLists(kind)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "lists": lists})
}

func (s *Server) handleCreateList(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		Kind         string  `json:"kind"`
		Title        string  `json:"title"`
		Summary      *string `json:"summary,omitempty"`
		PosterSource *string `json:"poster_source,omitempty"`
		ItemIDs      []int64 `json:"item_ids,omitempty"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if req.Kind == "" {
		req.Kind = db.ListPlaylist
	}
	lst, err := s.Store.CreateList(req.Kind, req.Title, req.Summary, req.PosterSource, nil)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if len(req.ItemIDs) > 0 {
		_ = s.Store.AddItemsToList(lst.ID, req.ItemIDs)
		lst, _ = s.Store.GetMediaListDetail(lst.ID)
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "list": lst})
}

func (s *Server) handleGetList(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	lst, err := s.Store.GetMediaListDetail(id)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "list": lst})
}

func (s *Server) handleUpdateList(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	var req struct {
		Title        string  `json:"title"`
		Summary      *string `json:"summary,omitempty"`
		PosterSource *string `json:"poster_source,omitempty"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	lst, err := s.Store.UpdateList(id, req.Title, req.Summary, req.PosterSource)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "list": lst})
}

func (s *Server) handleDeleteList(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	if err := s.Store.DeleteList(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "deleted"})
}

func (s *Server) handleAddListItems(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	var req struct {
		ItemIDs []int64 `json:"item_ids"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.Store.AddItemsToList(id, req.ItemIDs); err != nil {
		writeMappedError(w, r, err)
		return
	}
	lst, _ := s.Store.GetMediaListDetail(id)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "list": lst})
}

func (s *Server) handleRemoveListItem(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	listID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	itemID, err := strconv.ParseInt(r.PathValue("item_id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	if err := s.Store.RemoveItemFromList(listID, itemID); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "removed"})
}

func (s *Server) handleReorderList(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	listID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid list id")
		return
	}
	var req struct {
		ItemIDs []int64 `json:"item_ids"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.Store.ReorderListItems(listID, req.ItemIDs); err != nil {
		writeMappedError(w, r, err)
		return
	}
	lst, _ := s.Store.GetMediaListDetail(listID)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "list": lst})
}
