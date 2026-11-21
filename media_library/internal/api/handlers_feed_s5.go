package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"plezy/media_library/internal/feed"
)

func (s *Server) handleGetLibrarySnapshot(w http.ResponseWriter, r *http.Request) {
	if s.Feed == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "feed service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	q := r.URL.Query()
	page, _ := strconv.Atoi(q.Get("page"))
	pageSize, _ := strconv.Atoi(firstNonEmpty(q.Get("page_size"), q.Get("limit")))
	var parentID *int64
	if rawPID := strings.TrimSpace(q.Get("parent_id")); rawPID != "" {
		if pid, err := strconv.ParseInt(rawPID, 10, 64); err == nil && pid > 0 {
			parentID = &pid
		}
	}

	incFilesRaw := strings.ToLower(strings.TrimSpace(q.Get("include_files")))
	includeFiles := incFilesRaw == "1" || incFilesRaw == "true"

	res, err := s.Feed.GetSnapshot(p, feed.SnapshotRequest{
		Kind:         q.Get("kind"),
		LibraryType:  firstNonEmpty(q.Get("library_type"), q.Get("shelf")),
		SourceID:     q.Get("source_id"),
		ParentID:     parentID,
		Query:        q.Get("q"),
		Sort:         q.Get("sort"),
		Page:         page,
		PageSize:     pageSize,
		IncludeFiles: includeFiles,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":         0,
		"snapshot_seq": res.SnapshotSeq,
		"items":        res.Items,
		"total":        res.Total,
		"page":         res.Page,
		"page_size":    res.PageSize,
		"has_more":     res.HasMore,
	})
}

func (s *Server) handleGetLibraryChanges(w http.ResponseWriter, r *http.Request) {
	if s.Feed == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "feed service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	q := r.URL.Query()
	sinceSeq, err := strconv.ParseInt(strings.TrimSpace(firstNonEmpty(q.Get("since_seq"), "0")), 10, 64)
	if err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid since_seq")
		return
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	incFilesRaw := strings.ToLower(strings.TrimSpace(q.Get("include_files")))
	includeFiles := incFilesRaw == "1" || incFilesRaw == "true"

	res, err := s.Feed.GetChangesWithOpts(p, sinceSeq, limit, includeFiles)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":             0,
		"reset_required":   res.ResetRequired,
		"latest_seq":       res.LatestSeq,
		"min_retained_seq": res.MinRetainedSeq,
		"next_since_seq":   res.NextSinceSeq,
		"has_more":         res.HasMore,
		"changes":          res.Changes,
	})
}

func (s *Server) handleGetItemDetail(w http.ResponseWriter, r *http.Request) {
	if s.Feed == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "feed service unavailable")
		return
	}
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || itemID <= 0 {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid item id")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	det, err := s.Feed.GetItemDetail(p, itemID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"item": det,
	})
}

func (s *Server) handleGetItemDetailByWorkKey(w http.ResponseWriter, r *http.Request) {
	if s.Feed == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "feed service unavailable")
		return
	}
	wk := strings.TrimSpace(r.URL.Query().Get("work_key"))
	if wk == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "work_key is required")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	det, err := s.Feed.GetItemDetailByWorkKey(p, wk)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"item": det,
	})
}

func (s *Server) handleGetSidecar(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	data, contentType, err := s.Ing.ReadBytes(p.HouseholdID, r.PathValue("sha256"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=604800")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) handleEventsSSE(w http.ResponseWriter, r *http.Request) {
	if s.Hub == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "event hub unavailable")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErrCode(w, r, http.StatusInternalServerError, "internal_error", "streaming unsupported")
		return
	}
	p := UserPrincipalFromContext(r.Context())

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-store")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	ch, unsub := s.Hub.Subscribe(p.HouseholdID, p.MemberID)
	defer unsub()

	_, _ = fmt.Fprintf(w, ": connected\n\n")
	flusher.Flush()

	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			_, _ = fmt.Fprintf(w, ": ping\n\n")
			flusher.Flush()
		case ev, open := <-ch:
			if !open {
				return
			}
			payload, _ := json.Marshal(ev)
			_, _ = fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", ev.ID, ev.Type, string(payload))
			flusher.Flush()
		}
	}
}
