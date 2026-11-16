package main

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
)

const maxRequestBodyBytes = 16 * 1024 * 1024

type errorResponse struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func NewSyncMux(store *SyncStore) http.Handler {
	mux := http.NewServeMux()
	h := &syncHandler{store: store}

	mux.HandleFunc("GET /healthz", h.handleHealth)
	mux.HandleFunc("GET /api/v1/auth/kdf", h.handleAuthKdf)
	mux.HandleFunc("POST /api/v1/auth/register", h.handleRegister)
	mux.HandleFunc("POST /api/v1/auth/login", h.handleLogin)
	mux.HandleFunc("POST /api/v1/auth/qr/create", h.handleQrCreate)
	mux.HandleFunc("POST /api/v1/auth/qr/confirm", h.handleQrConfirm)
	mux.HandleFunc("GET /api/v1/auth/qr/poll", h.handleQrPoll)
	mux.HandleFunc("GET /api/v1/sync/pull", h.handlePull)
	mux.HandleFunc("POST /api/v1/sync/push", h.handlePush)
	mux.HandleFunc("POST /api/v1/sync/lease", h.handleLease)
	mux.HandleFunc("POST /api/v1/user/settings", h.handleSettings)

	return mux
}

type syncHandler struct {
	store *SyncStore
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	raw, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"code":500,"message":"marshal error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") && len(raw) > 512 {
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(status)
		gz := gzip.NewWriter(w)
		_, _ = gz.Write(raw)
		_ = gz.Close()
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(raw)
}

func writeErr(w http.ResponseWriter, r *http.Request, status int, msg string) {
	writeJSON(w, r, status, errorResponse{Code: status, Message: msg})
}

func decodeBody(w http.ResponseWriter, r *http.Request, dst any) error {
	var reader io.Reader = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	if strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
		gz, err := gzip.NewReader(reader)
		if err != nil {
			return err
		}
		defer gz.Close()
		reader = gz
	}
	return json.NewDecoder(reader).Decode(dst)
}

func (h *syncHandler) authenticate(r *http.Request) (*UserRecord, error) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, ErrUnauthorized
	}
	token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	if token == "" {
		return nil, ErrUnauthorized
	}
	return h.store.Authenticate(token)
}

func (h *syncHandler) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok", "server_time_ms": nowMs()})
}

func (h *syncHandler) handleAuthKdf(w http.ResponseWriter, r *http.Request) {
	username := strings.TrimSpace(r.URL.Query().Get("username"))
	if username == "" {
		writeErr(w, r, http.StatusBadRequest, "username is required")
		return
	}
	salt, params, ok := h.store.LookupKdf(username)
	if !ok {
		writeErr(w, r, http.StatusNotFound, "user not found")
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"kdf_salt":   salt,
		"kdf_params": params,
	})
}

func (h *syncHandler) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.Register(req)
	if err != nil {
		switch {
		case errors.Is(err, ErrUserExists):
			writeErr(w, r, http.StatusConflict, err.Error())
		case errors.Is(err, ErrInvalidInput):
			writeErr(w, r, http.StatusBadRequest, err.Error())
		default:
			writeErr(w, r, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.Login(req)
	if err != nil {
		if errors.Is(err, ErrInvalidCreds) {
			writeErr(w, r, http.StatusUnauthorized, err.Error())
		} else {
			writeErr(w, r, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleQrCreate(w http.ResponseWriter, r *http.Request) {
	var req QrCreateRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.CreateQrSession(req)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleQrConfirm(w http.ResponseWriter, r *http.Request) {
	user, err := h.authenticate(r)
	if err != nil {
		writeErr(w, r, http.StatusUnauthorized, err.Error())
		return
	}
	var req QrConfirmRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.store.ConfirmQrSession(user, req); err != nil {
		switch {
		case errors.Is(err, ErrQrNotFound):
			writeErr(w, r, http.StatusNotFound, err.Error())
		case errors.Is(err, ErrQrExpired):
			writeErr(w, r, http.StatusGone, err.Error())
		default:
			writeErr(w, r, http.StatusBadRequest, err.Error())
		}
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "confirmed"})
}

func (h *syncHandler) handleQrPoll(w http.ResponseWriter, r *http.Request) {
	sessionID := strings.TrimSpace(r.URL.Query().Get("session_id"))
	if sessionID == "" {
		writeErr(w, r, http.StatusBadRequest, "session_id is required")
		return
	}
	resp, err := h.store.PollQrSession(sessionID)
	if err != nil {
		if errors.Is(err, ErrQrNotFound) {
			writeErr(w, r, http.StatusNotFound, err.Error())
		} else {
			writeErr(w, r, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handlePull(w http.ResponseWriter, r *http.Request) {
	user, err := h.authenticate(r)
	if err != nil {
		writeErr(w, r, http.StatusUnauthorized, err.Error())
		return
	}
	var sinceSeq int64
	if raw := r.URL.Query().Get("since_seq"); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeErr(w, r, http.StatusBadRequest, "invalid since_seq")
			return
		}
		sinceSeq = parsed
	}
	limit := 500
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeErr(w, r, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = parsed
	}
	writeJSON(w, r, http.StatusOK, h.store.Pull(user, sinceSeq, limit))
}

func (h *syncHandler) handlePush(w http.ResponseWriter, r *http.Request) {
	user, err := h.authenticate(r)
	if err != nil {
		writeErr(w, r, http.StatusUnauthorized, err.Error())
		return
	}
	var req PushRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.Push(user.UserID, req)
	if err != nil {
		writeErr(w, r, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleLease(w http.ResponseWriter, r *http.Request) {
	user, err := h.authenticate(r)
	if err != nil {
		writeErr(w, r, http.StatusUnauthorized, err.Error())
		return
	}
	var req LeaseRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.AcquireLease(user.UserID, req)
	if err != nil {
		if errors.Is(err, ErrSourceNotFound) {
			writeErr(w, r, http.StatusNotFound, err.Error())
		} else {
			writeErr(w, r, http.StatusBadRequest, err.Error())
		}
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleSettings(w http.ResponseWriter, r *http.Request) {
	user, err := h.authenticate(r)
	if err != nil {
		writeErr(w, r, http.StatusUnauthorized, err.Error())
		return
	}
	var updates map[string]any
	if err := decodeBody(w, r, &updates); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	merged, err := h.store.UpdateUserSettings(user.UserID, updates)
	if err != nil {
		writeErr(w, r, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "settings": merged, "server_time_ms": nowMs()})
}
