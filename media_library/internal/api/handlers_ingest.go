package api

import (
	"io"
	"net/http"
	"strconv"
	"strings"

	"plezy/media_library/internal/ingest"
)

func (s *Server) handleCreateScanSession(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req ingest.CreateSessionRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	sess, err := s.Ing.CreateSession(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"session": sess,
	})
}

func (s *Server) handleListSourceScanSessions(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	sessions, err := s.Ing.ListSourceSessions(p, r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"sessions": sessions,
	})
}

func (s *Server) handleSubmitScanBatch(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req ingest.SubmitBatchRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	receipt, err := s.Ing.SubmitBatch(p, r.PathValue("sid"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Idf != nil {
		s.Idf.Wake()
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"receipt": receipt,
	})
}

func (s *Server) handleReportScanProgress(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req ingest.ProgressRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	sess, err := s.Ing.ReportProgress(p, r.PathValue("sid"), req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"session": sess,
	})
}

func (s *Server) handleCompleteScanSession(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req ingest.CompleteSessionRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Ing.CompleteSession(p, r.PathValue("sid"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if s.Idf != nil {
		s.Idf.Wake()
	}
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*ingest.CompleteSessionResult
	}{
		Code:                  0,
		CompleteSessionResult: res,
	})
}

func (s *Server) handleCancelScanSession(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	sess, err := s.Ing.CancelSession(p, r.PathValue("sid"), s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"session": sess,
	})
}

func (s *Server) handleListPendingDeletions(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	items, err := s.Ing.ListPendingDeletions(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":              0,
		"pending_deletions": items,
	})
}

func (s *Server) handleConfirmPendingDeletion(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	item, err := s.Ing.ConfirmPendingDeletion(p, r.PathValue("id"), s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":             0,
		"pending_deletion": item,
	})
}

func (s *Server) handleDismissPendingDeletion(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	item, err := s.Ing.DismissPendingDeletion(p, r.PathValue("id"), s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":             0,
		"pending_deletion": item,
	})
}

func (s *Server) handleHeadSidecar(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	p := UserPrincipalFromContext(r.Context())
	exists, err := s.Ing.SidecarExists(p, r.PathValue("sha256"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if !exists {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *Server) handlePutSidecar(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	maxRead := int64(ingest.MaxArtworkSidecarBytes + 1)
	data, err := io.ReadAll(io.LimitReader(http.MaxBytesReader(w, r.Body, maxRead), maxRead))
	if err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "failed to read sidecar payload")
		return
	}
	kindHint := strings.TrimSpace(r.URL.Query().Get("kind"))
	if kindHint == "" {
		kindHint = strings.TrimSpace(r.Header.Get("X-Sidecar-Kind"))
	}
	if err := s.Ing.PutSidecar(p, r.PathValue("sha256"), kindHint, r.Header.Get("Content-Type"), data); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleReportMediaSpec(w http.ResponseWriter, r *http.Request) {
	if s.Ing == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "ingest service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	fileID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || fileID <= 0 {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid file id")
		return
	}
	var req ingest.MediaSpecInput
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Ing.ReportMediaSpec(p, fileID, req); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}
