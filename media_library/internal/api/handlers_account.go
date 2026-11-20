package api

import (
	"net/http"
	"strings"

	"plezy/media_library/internal/account"
)

type switchMemberBody struct {
	MemberID string `json:"member_id"`
	PIN      string `json:"pin,omitempty"`
}

type recoveryWrapBody struct {
	Username     string `json:"username"`
	RecoveryCode string `json:"recovery_code"`
}

type deleteAccountBody struct {
	Password string `json:"password"`
}

type pollQrBody struct {
	PollSecret string `json:"poll_secret"`
}

type updateHouseholdBody struct {
	Name        *string `json:"name,omitempty"`
	DisplayLang *string `json:"display_lang,omitempty"`
}

type upsertKeyWrapBody struct {
	account.KeyWrapInput
	TargetSubjectID string `json:"target_subject_id,omitempty"`
	RecoveryCode    string `json:"recovery_code,omitempty"`
}

func writeAuthResult(w http.ResponseWriter, r *http.Request, res *account.AuthResult) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*account.AuthResult
	}{
		Code:       0,
		AuthResult: res,
	})
}

func (s *Server) handleUserRegister(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var req account.RegisterRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Acc.Register(req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeAuthResult(w, r, res)
}

func (s *Server) handleUserLogin(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var req account.LoginRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Acc.Login(req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeAuthResult(w, r, res)
}

func (s *Server) handleUserSelectMember(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var req account.SelectMemberRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Acc.SelectMember(req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeAuthResult(w, r, res)
}

func (s *Server) handleUserSwitchMember(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var body switchMemberBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Acc.SwitchMember(p, body.MemberID, body.PIN, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeAuthResult(w, r, res)
}

func (s *Server) handleUserLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.Acc.Logout(bearerToken(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleUserMe(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	hh, err := s.Acc.GetHousehold(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	members, err := s.Acc.ListMembers(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":      0,
		"principal": p,
		"household": hh,
		"members":   members,
	})
}

func (s *Server) handleUserChangePassword(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var req account.ChangePasswordRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Acc.ChangeAccountPassword(p, req, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleUserRecoveryWrap(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var body recoveryWrapBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	wrap, err := s.Acc.GetRecoveryWrap(body.Username, body.RecoveryCode, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"key_wrap": wrap,
	})
}

func (s *Server) handleUserRecoveryReset(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var req account.RecoverPasswordRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Acc.RecoverAccountPassword(req, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleUserDeleteAccount(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var body deleteAccountBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	deleteAfter, err := s.Acc.ScheduleSelfDelete(p, body.Password, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":         0,
		"status":       "pending_delete",
		"delete_after": deleteAfter,
	})
}

func (s *Server) handleQrCreate(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	var req account.CreateQrRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Acc.CreateQrSession(req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*account.QrCreateResult
	}{
		Code:           0,
		QrCreateResult: res,
	})
}

func (s *Server) handleQrGetInfo(w http.ResponseWriter, r *http.Request) {
	info, err := s.Acc.GetQrSessionInfo(r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*account.QrSessionInfo
	}{
		Code:          0,
		QrSessionInfo: info,
	})
}

func (s *Server) handleQrConfirm(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var req account.ConfirmQrRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Acc.ConfirmQrSession(p, r.PathValue("id"), req, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleQrPoll(w http.ResponseWriter, r *http.Request) {
	if s.Acc == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "account service unavailable")
		return
	}
	pollSecret := strings.TrimSpace(r.Header.Get("X-QR-Poll-Secret"))
	var body pollQrBody
	if err := decodeOptionalJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if pollSecret == "" {
		pollSecret = strings.TrimSpace(body.PollSecret)
	}
	res, err := s.Acc.PollQrSession(r.PathValue("id"), pollSecret, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*account.QrPollResult
	}{
		Code:         0,
		QrPollResult: res,
	})
}

func (s *Server) handleGetHousehold(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	hh, err := s.Acc.GetHousehold(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":      0,
		"household": hh,
	})
}

func (s *Server) handleUpdateHousehold(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var body updateHouseholdBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	hh, err := s.Acc.UpdateHousehold(p, body.Name, body.DisplayLang, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":      0,
		"household": hh,
	})
}

func (s *Server) handleListKeyWraps(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	wraps, err := s.Acc.ListMyKeyWraps(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":      0,
		"key_wraps": wraps,
	})
}

func (s *Server) handleUpsertKeyWrap(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var body upsertKeyWrapBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	wrap, err := s.Acc.UpsertKeyWrap(p, body.KeyWrapInput, body.TargetSubjectID, body.RecoveryCode, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"key_wrap": wrap,
	})
}

func (s *Server) handleListMembers(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	members, err := s.Acc.ListMembers(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"members": members,
	})
}

func (s *Server) handleCreateMember(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var req account.CreateMemberRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	m, err := s.Acc.CreateMember(p, req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"member": m,
	})
}

func (s *Server) handleUpdateMember(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	var req account.UpdateMemberRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	m, err := s.Acc.UpdateMember(p, r.PathValue("id"), req, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"member": m,
	})
}

func (s *Server) handleDeleteMember(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	if err := s.Acc.DeleteMember(p, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	devices, err := s.Acc.ListDevices(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"devices": devices,
	})
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	if err := s.Acc.RevokeDevice(p, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	sessions, err := s.Acc.ListSessions(p)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"sessions": sessions,
	})
}

func (s *Server) handleRevokeSession(w http.ResponseWriter, r *http.Request) {
	p := UserPrincipalFromContext(r.Context())
	if err := s.Acc.RevokeSession(p, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}
