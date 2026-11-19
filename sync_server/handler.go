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

	mux.HandleFunc("GET /", h.handleWebIndex)
	mux.HandleFunc("GET /healthz", h.handleHealth)
	mux.HandleFunc("GET /api/v1/public/info", h.handlePublicInfo)

	// App E2EE client auth & sync routes
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

	// Web user panel routes (KDF-compatible with App E2EE)
	mux.HandleFunc("POST /api/v1/web/register", h.handleWebRegister)
	mux.HandleFunc("POST /api/v1/web/login", h.handleWebLogin)
	mux.HandleFunc("POST /api/v1/web/password", h.handleWebChangePassword)
	mux.HandleFunc("GET /api/v1/user/me", h.handleUserMe)
	mux.HandleFunc("GET /api/v1/user/devices", h.handleUserDevices)
	mux.HandleFunc("DELETE /api/v1/user/devices/{token_id}", h.handleUserRevokeDevice)
	mux.HandleFunc("POST /api/v1/user/clear-sync-data", h.handleUserClearSyncData)

	// Public / shared metadata cache routes
	mux.HandleFunc("GET /api/v1/metadata/config", h.handleMetadataPublicConfig)
	mux.HandleFunc("GET /api/v1/metadata/search", h.handleMetadataSearch)
	mux.HandleFunc("GET /api/v1/metadata/work/{provider}/{kind}/{id}", h.handleMetadataWork)
	mux.HandleFunc("GET /api/v1/metadata/season/{provider}/{id}/{season}", h.handleMetadataSeason)
	mux.HandleFunc("GET /api/v1/metadata/person/{provider}/{id}", h.handleMetadataPerson)
	mux.HandleFunc("POST /api/v1/metadata/batch", h.handleMetadataBatch)

	// Web admin panel routes
	mux.HandleFunc("GET /api/v1/admin/overview", h.handleAdminOverview)
	mux.HandleFunc("POST /api/v1/admin/config", h.handleAdminConfig)
	mux.HandleFunc("GET /api/v1/admin/metadata/config", h.handleAdminMetadataConfigGet)
	mux.HandleFunc("POST /api/v1/admin/metadata/config", h.handleAdminMetadataConfigUpdate)
	mux.HandleFunc("POST /api/v1/admin/metadata/test", h.handleAdminMetadataTest)
	mux.HandleFunc("POST /api/v1/admin/metadata/clear-cache", h.handleAdminMetadataClearCache)
	mux.HandleFunc("GET /api/v1/admin/users", h.handleAdminUsers)
	mux.HandleFunc("POST /api/v1/admin/users/{user_id}/status", h.handleAdminUserStatus)
	mux.HandleFunc("DELETE /api/v1/admin/users/{user_id}", h.handleAdminDeleteUser)

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

func writeMappedErr(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, ErrUserExists):
		writeErr(w, r, http.StatusConflict, err.Error())
	case errors.Is(err, ErrRegistrationClosed), errors.Is(err, ErrUserDisabled), errors.Is(err, ErrForbidden), errors.Is(err, ErrMetadataDisabled):
		writeErr(w, r, http.StatusForbidden, err.Error())
	case errors.Is(err, ErrMetadataNotConfigured):
		writeErr(w, r, http.StatusPreconditionFailed, err.Error())
	case errors.Is(err, ErrMetadataUpstream):
		writeErr(w, r, http.StatusBadGateway, err.Error())
	case errors.Is(err, ErrQuotaExceeded):
		writeErr(w, r, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, ErrInvalidCreds), errors.Is(err, ErrUnauthorized):
		writeErr(w, r, http.StatusUnauthorized, err.Error())
	case errors.Is(err, ErrQrNotFound), errors.Is(err, ErrSourceNotFound), errors.Is(err, ErrUserNotFound), errors.Is(err, ErrMetadataNotFound):
		writeErr(w, r, http.StatusNotFound, err.Error())
	case errors.Is(err, ErrQrExpired):
		writeErr(w, r, http.StatusGone, err.Error())
	case errors.Is(err, ErrInvalidInput):
		writeErr(w, r, http.StatusBadRequest, err.Error())
	default:
		writeErr(w, r, http.StatusInternalServerError, err.Error())
	}
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

func (h *syncHandler) authenticate(r *http.Request) (*UserRecord, string, error) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, "", ErrUnauthorized
	}
	token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	if token == "" {
		return nil, "", ErrUnauthorized
	}
	return h.store.AuthenticateWithTokenID(token)
}

func (h *syncHandler) authenticateAdmin(r *http.Request) (*UserRecord, error) {
	user, _, err := h.authenticate(r)
	if err != nil {
		return nil, err
	}
	if !user.IsAdmin {
		return nil, ErrForbidden
	}
	return user, nil
}

func (h *syncHandler) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok", "server_time_ms": nowMs()})
}

func (h *syncHandler) handlePublicInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, h.store.GetPublicInfo())
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
		writeMappedErr(w, r, err)
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
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleWebRegister(w http.ResponseWriter, r *http.Request) {
	var req WebAuthRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.WebRegister(req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleWebLogin(w http.ResponseWriter, r *http.Request) {
	var req WebAuthRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.WebLogin(req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleWebChangePassword(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req WebPasswordChangeRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.store.WebChangePassword(user.UserID, req); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok"})
}

func (h *syncHandler) handleUserMe(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	prof, err := h.store.GetUserProfile(user.UserID)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, prof)
}

func (h *syncHandler) handleUserDevices(w http.ResponseWriter, r *http.Request) {
	user, tokenID, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	devices, err := h.store.ListUserDevices(user.UserID, tokenID)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "devices": devices})
}

func (h *syncHandler) handleUserRevokeDevice(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	tokenID := r.PathValue("token_id")
	if err := h.store.RevokeUserDevice(user.UserID, tokenID); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "revoked"})
}

func (h *syncHandler) handleUserClearSyncData(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	if err := h.store.ClearUserSyncData(user.UserID); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "cleared"})
}

func (h *syncHandler) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	ov, err := h.store.AdminOverview()
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, ov)
}

func (h *syncHandler) handleAdminConfig(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req AdminConfigRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.store.AdminUpdateConfig(req); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "updated"})
}

func (h *syncHandler) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	users, err := h.store.AdminListUsers()
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "users": users})
}

func (h *syncHandler) handleAdminUserStatus(w http.ResponseWriter, r *http.Request) {
	admin, err := h.authenticateAdmin(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	targetID := r.PathValue("user_id")
	var req AdminUserStatusRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.store.AdminSetUserDisabled(admin.UserID, targetID, req.IsDisabled); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "updated"})
}

func (h *syncHandler) handleAdminDeleteUser(w http.ResponseWriter, r *http.Request) {
	admin, err := h.authenticateAdmin(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	targetID := r.PathValue("user_id")
	if err := h.store.AdminDeleteUser(admin.UserID, targetID); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "deleted"})
}

func (h *syncHandler) handleQrCreate(w http.ResponseWriter, r *http.Request) {
	var req QrCreateRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.CreateQrSession(req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleQrConfirm(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req QrConfirmRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := h.store.ConfirmQrSession(user, req); err != nil {
		writeMappedErr(w, r, err)
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
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handlePull(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
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
	activeOnly := sinceSeq == 0
	if raw := strings.TrimSpace(r.URL.Query().Get("active_only")); raw != "" {
		switch strings.ToLower(raw) {
		case "1", "true":
			activeOnly = true
		case "0", "false":
			activeOnly = false
		default:
			writeErr(w, r, http.StatusBadRequest, "invalid active_only")
			return
		}
	}
	writeJSON(w, r, http.StatusOK, h.store.PullWithOptions(user, sinceSeq, limit, activeOnly))
}

func (h *syncHandler) handlePush(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req PushRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.Push(user.UserID, req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleLease(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req LeaseRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.AcquireLease(user.UserID, req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleSettings(w http.ResponseWriter, r *http.Request) {
	user, _, err := h.authenticate(r)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var updates map[string]any
	if err := decodeBody(w, r, &updates); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	merged, err := h.store.UpdateUserSettings(user.UserID, updates)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "settings": merged, "server_time_ms": nowMs()})
}

func (h *syncHandler) authorizeMetadataRead(r *http.Request) error {
	if h.store.AllowPublicMetadata() {
		return nil
	}
	_, _, err := h.authenticate(r)
	return err
}

func isRefreshParam(r *http.Request) bool {
	v := strings.TrimSpace(strings.ToLower(r.URL.Query().Get("refresh")))
	return v == "1" || v == "true"
}

func (h *syncHandler) handleMetadataPublicConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, h.store.GetPublicMetadataConfig())
}

func (h *syncHandler) handleMetadataSearch(w http.ResponseWriter, r *http.Request) {
	if err := h.authorizeMetadataRead(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	q := r.URL.Query()
	provider := strings.TrimSpace(q.Get("provider"))
	if provider == "" {
		provider = "tmdb"
	}
	kind := strings.TrimSpace(q.Get("kind"))
	if kind == "" {
		kind = "movie"
	}
	queryStr := strings.TrimSpace(q.Get("q"))
	var year int
	if rawY := strings.TrimSpace(q.Get("year")); rawY != "" {
		parsed, err := strconv.Atoi(rawY)
		if err != nil || parsed < 0 {
			writeErr(w, r, http.StatusBadRequest, "invalid year")
			return
		}
		year = parsed
	}
	resp, err := h.store.MetadataSearch(r.Context(), provider, kind, queryStr, year, q.Get("lang"), isRefreshParam(r))
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleMetadataWork(w http.ResponseWriter, r *http.Request) {
	if err := h.authorizeMetadataRead(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	resp, err := h.store.MetadataGetWork(
		r.Context(),
		r.PathValue("provider"),
		r.PathValue("kind"),
		r.PathValue("id"),
		r.URL.Query().Get("lang"),
		isRefreshParam(r),
	)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleMetadataSeason(w http.ResponseWriter, r *http.Request) {
	if err := h.authorizeMetadataRead(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	seasonNum, err := strconv.Atoi(strings.TrimSpace(r.PathValue("season")))
	if err != nil || seasonNum < 0 {
		writeErr(w, r, http.StatusBadRequest, "invalid season")
		return
	}
	resp, err := h.store.MetadataGetSeason(
		r.Context(),
		r.PathValue("provider"),
		r.PathValue("id"),
		seasonNum,
		r.URL.Query().Get("lang"),
		isRefreshParam(r),
	)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleMetadataPerson(w http.ResponseWriter, r *http.Request) {
	if err := h.authorizeMetadataRead(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	resp, err := h.store.MetadataGetPerson(
		r.Context(),
		r.PathValue("provider"),
		r.PathValue("id"),
		r.URL.Query().Get("lang"),
		isRefreshParam(r),
	)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleMetadataBatch(w http.ResponseWriter, r *http.Request) {
	if err := h.authorizeMetadataRead(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req MetadataBatchRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := h.store.MetadataBatch(r.Context(), req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (h *syncHandler) handleAdminMetadataConfigGet(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, h.store.AdminGetMetadataConfig())
}

func (h *syncHandler) handleAdminMetadataConfigUpdate(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req AdminMetadataConfigRequest
	if err := decodeBody(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	cfg, err := h.store.AdminUpdateMetadataConfig(req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, cfg)
}

func (h *syncHandler) handleAdminMetadataTest(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req AdminMetadataTestRequest
	if r.Body != nil {
		_ = decodeBody(w, r, &req)
	}
	latencyMs, err := h.store.AdminTestMetadataConnection(r.Context(), req)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "ok": true, "latency_ms": latencyMs})
}

func (h *syncHandler) handleAdminMetadataClearCache(w http.ResponseWriter, r *http.Request) {
	if _, err := h.authenticateAdmin(r); err != nil {
		writeMappedErr(w, r, err)
		return
	}
	var req MetadataClearCacheRequest
	if r.Body != nil {
		_ = decodeBody(w, r, &req)
	}
	deleted, stats, err := h.store.AdminClearMetadataCache(req.Scope)
	if err != nil {
		writeMappedErr(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":        0,
		"deleted":     deleted,
		"cache_stats": stats,
	})
}
