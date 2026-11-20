package api

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"plezy/media_library/internal/userdata"
)

func (s *Server) handleListProgress(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))

	items, err := s.UserData.ListProgress(p, q.Get("work_key"), limit, offset)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"items": items,
	})
}

func (s *Server) handleUpsertProgress(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req userdata.UpsertProgressRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	item, err := s.UserData.UpsertProgress(p, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"progress": item,
	})
}

func (s *Server) handleDeleteProgress(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	key, _ := url.PathUnescape(r.PathValue("key"))
	if err := s.UserData.DeleteProgress(p, key); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleListContinueWatching(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	items, err := s.UserData.ListContinueWatching(p, limit)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"items": items,
	})
}

func (s *Server) handleHideContinueWatching(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	key, _ := url.PathUnescape(r.PathValue("key"))
	if err := s.UserData.HideFromContinue(p, key); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleListFavorites(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	items, err := s.UserData.ListFavorites(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"items": items,
	})
}

func (s *Server) handleAddFavorite(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	wk, _ := url.PathUnescape(r.PathValue("work_key"))
	item, err := s.UserData.AddFavorite(p, wk)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"favorite": item,
	})
}

func (s *Server) handleRemoveFavorite(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	wk, _ := url.PathUnescape(r.PathValue("work_key"))
	if err := s.UserData.RemoveFavorite(p, wk); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleGetWorkPrefs(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	wk, _ := url.PathUnescape(r.PathValue("work_key"))
	prefs, err := s.UserData.GetWorkPrefs(p, wk)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"prefs": prefs,
	})
}

func (s *Server) handleUpsertHouseholdWorkPrefs(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	wk, _ := url.PathUnescape(r.PathValue("work_key"))
	var req userdata.HouseholdWorkPrefsInput
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	prefs, err := s.UserData.UpsertHouseholdWorkPrefs(p, wk, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"prefs": prefs,
	})
}

func (s *Server) handleUpsertMemberWorkPrefs(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	wk, _ := url.PathUnescape(r.PathValue("work_key"))
	var req userdata.MemberWorkPrefsInput
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	prefs, err := s.UserData.UpsertMemberWorkPrefs(p, wk, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"prefs": prefs,
	})
}

func (s *Server) handleListLists(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	lists, err := s.UserData.ListLists(p, r.URL.Query().Get("kind"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"lists": lists,
	})
}

func (s *Server) handleCreateList(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req userdata.CreateListRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	lst, err := s.UserData.CreateList(p, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"list": lst,
	})
}

func (s *Server) handleGetList(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	det, err := s.UserData.GetList(p, r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"list": det,
	})
}

func (s *Server) handleUpdateList(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req userdata.UpdateListRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	lst, err := s.UserData.UpdateList(p, r.PathValue("id"), req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"list": lst,
	})
}

func (s *Server) handleDeleteList(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	if err := s.UserData.DeleteList(p, r.PathValue("id")); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleAddListEntry(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req userdata.AddListEntryRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	entry, err := s.UserData.AddListEntry(p, r.PathValue("id"), req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"entry": entry,
	})
}

func (s *Server) handleRemoveListEntry(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	ek, _ := url.PathUnescape(r.PathValue("entry_key"))
	if err := s.UserData.RemoveListEntry(p, r.PathValue("id"), ek); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}

func (s *Server) handleMigrateWorkData(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req struct {
		FromWorkKey string `json:"from_work_key"`
		ToWorkKey   string `json:"to_work_key"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.UserData.MigrateWorkData(p, strings.TrimSpace(req.FromWorkKey), strings.TrimSpace(req.ToWorkKey)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}
