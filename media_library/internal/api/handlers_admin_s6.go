package api

import (
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/security"
	"plezy/media_library/web"
)

type PlatformOverview struct {
	AccountsTotal   int64            `json:"accounts_total"`
	AccountsActive  int64            `json:"accounts_active"`
	AccountsToday   int64            `json:"accounts_today"`
	HouseholdsTotal int64            `json:"households_total"`
	DevicesTotal    int64            `json:"devices_total"`
	DevicesActive7d int64            `json:"devices_active_7d"`
	SourcesTotal    int64            `json:"sources_total"`
	SourcesByKind   map[string]int64 `json:"sources_by_kind"`
	ItemsTotal      int64            `json:"items_total"`
	FilesTotal      int64            `json:"files_total"`
	SidecarBytes    int64            `json:"sidecar_bytes"`
	DBBytes         int64            `json:"db_bytes"`
}

func (s *Server) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).UnixMilli()
	sevenDaysAgo := now.Add(-7 * 24 * time.Hour).UnixMilli()

	ov := PlatformOverview{
		SourcesByKind: map[string]int64{},
	}
	rdb := s.Store.ReadDB()
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM accounts`).Scan(&ov.AccountsTotal)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM accounts WHERE status = 'active'`).Scan(&ov.AccountsActive)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM accounts WHERE created_at >= ?`, todayStart).Scan(&ov.AccountsToday)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM households`).Scan(&ov.HouseholdsTotal)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM devices`).Scan(&ov.DevicesTotal)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM devices WHERE last_seen_at >= ?`, sevenDaysAgo).Scan(&ov.DevicesActive7d)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM sources WHERE deleted_at IS NULL`).Scan(&ov.SourcesTotal)
	if rows, err := rdb.Query(`SELECT kind, COUNT(*) FROM sources WHERE deleted_at IS NULL GROUP BY kind`); err == nil {
		for rows.Next() {
			var kind string
			var cnt int64
			if err := rows.Scan(&kind, &cnt); err == nil && kind != "" {
				ov.SourcesByKind[kind] = cnt
			}
		}
		_ = rows.Close()
	}
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM media_items`).Scan(&ov.ItemsTotal)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM media_files WHERE state = 'active'`).Scan(&ov.FilesTotal)
	_ = rdb.QueryRow(`SELECT COALESCE(SUM(size_bytes), 0) FROM sidecars`).Scan(&ov.SidecarBytes)
	_ = rdb.QueryRow(`SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()`).Scan(&ov.DBBytes)

	resp := map[string]any{
		"code":     0,
		"overview": ov,
	}
	if s.Meta != nil {
		resp["cache_stats"] = s.Meta.CacheStats()
	}
	if s.Idf != nil {
		if qStats, err := s.Idf.Stats(); err == nil {
			resp["identify_queue"] = qStats
		}
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (s *Server) handleAdminTestTmdb(w http.ResponseWriter, r *http.Request) {
	if s.Meta == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "metadata service unavailable")
		return
	}
	var req struct {
		TmdbAPIKey    *string `json:"tmdb_api_key"`
		TmdbAPIBase   *string `json:"tmdb_api_base"`
		MetadataProxy *string `json:"metadata_proxy"`
	}
	if err := decodeOptionalJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	latencyMs, err := s.Meta.TestTmdbConnection(r.Context(), req.TmdbAPIKey, req.TmdbAPIBase, req.MetadataProxy)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"ok":         true,
		"latency_ms": latencyMs,
	})
}

func (s *Server) handleAdminTestProvider(w http.ResponseWriter, r *http.Request) {
	if s.Meta == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "metadata service unavailable")
		return
	}
	var req struct {
		Provider      string  `json:"provider"`
		APIKey        *string `json:"api_key"`
		Pin           *string `json:"pin"`
		Token         *string `json:"token"`
		Cookie        *string `json:"cookie"`
		APIBase       *string `json:"api_base"`
		MetadataProxy *string `json:"metadata_proxy"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	latencyMs, msg, err := s.Meta.TestProviderConnection(r.Context(), req.Provider, metadata.ProviderTestOverrides{
		APIKey:        req.APIKey,
		Pin:           req.Pin,
		Token:         req.Token,
		Cookie:        req.Cookie,
		APIBase:       req.APIBase,
		MetadataProxy: req.MetadataProxy,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"ok":         true,
		"latency_ms": latencyMs,
		"message":    msg,
	})
}

func (s *Server) handleAdminClearMetaCache(w http.ResponseWriter, r *http.Request) {
	if s.Meta == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "metadata service unavailable")
		return
	}
	p := AdminPrincipalFromContext(r.Context())
	var req struct {
		Scope string `json:"scope"`
	}
	_ = decodeOptionalJSON(w, r, &req)
	deleted, stats, err := s.Meta.ClearCache(req.Scope)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.metadata_cache_cleared",
		TargetType: "metadata_cache",
		TargetID:   firstNonEmpty(strings.TrimSpace(req.Scope), "all"),
		Detail:     map[string]any{"deleted": deleted},
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"deleted":     deleted,
		"cache_stats": stats,
	})
}

func (s *Server) handleAdminListMetadataTables(w http.ResponseWriter, r *http.Request) {
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

func (s *Server) handleAdminQueryMetadataTable(w http.ResponseWriter, r *http.Request) {
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

func (s *Server) handleAdminDeleteMetadataCacheRow(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	tableName := strings.TrimSpace(r.PathValue("table"))
	var req struct {
		PK map[string]string `json:"pk"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	deleted, err := s.Store.DeleteMetaCacheRow(tableName, req.PK)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.metadata_cache_row_deleted",
		TargetType: "metadata_cache",
		TargetID:   tableName,
		Detail:     map[string]any{"deleted": deleted},
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"deleted": deleted,
	})
}

func (s *Server) handleAdminIdentifyStatus(w http.ResponseWriter, r *http.Request) {
	if s.Idf == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "identify queue unavailable")
		return
	}
	stats, err := s.Idf.Stats()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"status": stats,
	})
}

func (s *Server) handleAdminIdentifyPause(w http.ResponseWriter, r *http.Request) {
	if s.Idf == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "identify queue unavailable")
		return
	}
	p := AdminPrincipalFromContext(r.Context())
	s.Idf.Pause()
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.identify_paused",
		TargetType: "identify_queue",
		TargetID:   "global",
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "paused": true})
}

func (s *Server) handleAdminIdentifyResume(w http.ResponseWriter, r *http.Request) {
	if s.Idf == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "identify queue unavailable")
		return
	}
	p := AdminPrincipalFromContext(r.Context())
	s.Idf.Resume()
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.identify_resumed",
		TargetType: "identify_queue",
		TargetID:   "global",
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "paused": false})
}

func (s *Server) handleAdminIdentifyRetryFailed(w http.ResponseWriter, r *http.Request) {
	if s.Idf == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "identify queue unavailable")
		return
	}
	p := AdminPrincipalFromContext(r.Context())
	var req struct {
		HouseholdID string `json:"household_id"`
	}
	_ = decodeOptionalJSON(w, r, &req)
	retried, err := s.Idf.RetryFailed(strings.TrimSpace(req.HouseholdID))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.identify_retry_failed",
		TargetType: "identify_queue",
		TargetID:   firstNonEmpty(strings.TrimSpace(req.HouseholdID), "all"),
		Detail:     map[string]any{"retried": retried},
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"retried": retried,
	})
}

func (s *Server) handleAdminGetSystemLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	afterSeq, _ := strconv.ParseUint(strings.TrimSpace(q.Get("after_seq")), 10, 64)
	limit, _ := strconv.Atoi(strings.TrimSpace(q.Get("limit")))

	entries, latestSeq := applog.Query(applog.QueryFilter{
		AfterSeq:  afterSeq,
		Limit:     limit,
		Level:     q.Get("level"),
		Component: q.Get("component"),
		Keyword:   q.Get("q"),
	})
	logPath, sizeBytes := applog.FileInfo()

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":            0,
		"entries":         entries,
		"latest_seq":      latestSeq,
		"log_file_path":   logPath,
		"file_size_bytes": sizeBytes,
	})
}

func (s *Server) handleAdminClearSystemLogs(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	truncateFile := r.URL.Query().Get("truncate_file") == "1" || strings.EqualFold(r.URL.Query().Get("truncate_file"), "true")
	var req struct {
		TruncateFile bool `json:"truncate_file"`
	}
	if err := decodeOptionalJSON(w, r, &req); err == nil && req.TruncateFile {
		truncateFile = true
	}
	if err := applog.Clear(truncateFile); err != nil {
		writeErrCode(w, r, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.logs_cleared",
		TargetType: "logs",
		TargetID:   "system",
		Detail:     map[string]any{"truncate_file": truncateFile},
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "ok": true})
}

func (s *Server) handleAdminDownloadSystemLogs(w http.ResponseWriter, r *http.Request) {
	logPath, _ := applog.FileInfo()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="media-library.log"`)
	w.Header().Set("Cache-Control", "no-store")

	if logPath != "" {
		if f, err := os.Open(logPath); err == nil {
			defer f.Close()
			w.WriteHeader(http.StatusOK)
			_, _ = io.Copy(w, f)
			return
		}
	}

	entries, _ := applog.Query(applog.QueryFilter{Limit: 1500, Level: "DEBUG"})
	w.WriteHeader(http.StatusOK)
	for _, e := range entries {
		ts := time.UnixMilli(e.TimeMs).Format("2006-01-02 15:04:05.000")
		_, _ = fmt.Fprintf(w, "%s [%s] [%s] %s\n", ts, e.Level, e.Component, e.Message)
	}
}

func (s *Server) handleWebSPA(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		writeErrCode(w, r, http.StatusNotFound, "not_found", "API route not found")
		return
	}
	fsys, _ := web.ResolveDiskFS(s.webDir)
	if fsys == nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("Web UI bundle not found. Build media_library/web or pass -web-dir."))
		return
	}

	clean := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if clean == "" || clean == "." {
		clean = "index.html"
	}

	serveFile := func(name string, cacheControl string) bool {
		info, err := fs.Stat(fsys, name)
		if err != nil || info.IsDir() {
			return false
		}
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return false
		}
		ct := mime.TypeByExtension(path.Ext(name))
		if ct == "" {
			ct = http.DetectContentType(data)
		}
		w.Header().Set("Content-Type", ct)
		if cacheControl != "" {
			w.Header().Set("Cache-Control", cacheControl)
		}
		if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") && isCompressibleStatic(ct) && len(data) > 512 {
			if gz := gzipStaticCached(name, info.ModTime().UnixNano(), data); len(gz) > 0 {
				w.Header().Set("Content-Encoding", "gzip")
				w.Header().Add("Vary", "Accept-Encoding")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(gz)
				return true
			}
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
		return true
	}

	cacheCtrl := "no-cache"
	if strings.HasPrefix(clean, "assets/") {
		cacheCtrl = "public, max-age=31536000, immutable"
	}
	if serveFile(clean, cacheCtrl) {
		return
	}
	if strings.HasPrefix(clean, "assets/") || path.Ext(clean) != "" {
		http.NotFound(w, r)
		return
	}
	if !serveFile("index.html", "no-cache") {
		http.NotFound(w, r)
	}
}
