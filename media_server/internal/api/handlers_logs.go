package api

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/applog"
	"plezy/media_server/internal/db"
)

func (s *Server) handleGetSystemLogs(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
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
		"code":          0,
		"entries":       entries,
		"latest_seq":    latestSeq,
		"log_file_path": logPath,
		"file_size_bytes": sizeBytes,
	})
}

func (s *Server) handleClearSystemLogs(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	truncateFile := r.URL.Query().Get("truncate_file") == "1" || strings.EqualFold(r.URL.Query().Get("truncate_file"), "true")
	var req struct {
		TruncateFile bool `json:"truncate_file"`
	}
	if r.Body != nil {
		if err := decodeJSON(w, r, &req); err == nil && req.TruncateFile {
			truncateFile = true
		}
	}
	if err := applog.Clear(truncateFile); err != nil {
		writeErr(w, r, http.StatusInternalServerError, err.Error())
		return
	}
	applog.Infof("system", "已清理运行日志 (truncate_file=%v)", truncateFile)
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"ok":   true,
	})
}

func (s *Server) handleDownloadSystemLogs(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	logPath, _ := applog.FileInfo()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="ttplay-server.log"`)
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
