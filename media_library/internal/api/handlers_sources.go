package api

import (
	"net/http"

	"plezy/media_library/internal/source"
)

func (s *Server) handleListSources(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	sources, err := s.Src.ListSources(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"sources": sources,
	})
}

func (s *Server) handleCreateSource(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.CreateSourceRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	src, err := s.Src.CreateSource(p, req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"source": src,
	})
}

func (s *Server) handleGetSource(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	src, err := s.Src.GetSource(p, r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"source": src,
	})
}

func (s *Server) handleUpdateSource(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.UpdateSourceRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	src, err := s.Src.UpdateSource(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"source": src,
	})
}

func (s *Server) handleDeleteSource(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	if err := s.Src.DeleteSource(p, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleListFolders(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	folders, err := s.Src.ListFolders(p, r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"folders": folders,
	})
}

func (s *Server) handleAddFolder(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.FolderInput
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	folder, err := s.Src.AddFolder(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"folder": folder,
	})
}

func (s *Server) handleUpdateFolder(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.UpdateFolderRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	folder, err := s.Src.UpdateFolder(p, r.PathValue("id"), r.PathValue("fid"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"folder": folder,
	})
}

func (s *Server) handleDeleteFolder(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	if err := s.Src.DeleteFolder(p, r.PathValue("id"), r.PathValue("fid"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleGetSourceCredential(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	if !s.requireSecureTransport(w, r) {
		return
	}
	p := UserPrincipalFromContext(r.Context())
	cred, err := s.Src.GetCredential(p, r.PathValue("id"), s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"credential": cred,
	})
}

func (s *Server) handleUpdateSourceCredential(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	if !s.requireSecureTransport(w, r) {
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.UpdateCredentialRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	cred, err := s.Src.UpdateCredential(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"credential": cred,
	})
}

func (s *Server) handleReportSourceCredentialStatus(w http.ResponseWriter, r *http.Request) {
	if s.Src == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "source service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	var req source.ReportCredentialStatusRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	meta, err := s.Src.ReportCredentialStatus(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":            0,
		"credential_meta": meta,
	})
}
