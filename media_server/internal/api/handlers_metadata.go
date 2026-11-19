package api

import (
	"net/http"
	"strconv"
	"strings"

	"plezy/media_server/internal/db"
)

func (s *Server) handleListMetadataTables(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	tables, imgCache, err := s.Store.ListInspectableTables()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"tables":      tables,
		"image_cache": imgCache,
	})
}

func (s *Server) handleQueryMetadataTable(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	tableName := strings.TrimSpace(r.PathValue("table"))
	q := r.URL.Query().Get("q")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	page, err := s.Store.QueryInspectableTable(tableName, q, limit, offset)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"table":  page.Table,
		"total":  page.Total,
		"offset": page.Offset,
		"limit":  page.Limit,
		"rows":   page.Rows,
	})
}

func (s *Server) handleDeleteMetadataCacheRow(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	tableName := strings.TrimSpace(r.PathValue("table"))
	var req struct {
		PK map[string]string `json:"pk"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	deleted, err := s.Store.DeleteMetaCacheRow(tableName, req.PK)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"deleted": deleted,
	})
}
