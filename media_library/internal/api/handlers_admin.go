package api

import (
	"net/http"
	"strconv"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/platform"
	"plezy/media_library/internal/security"
)

type adminLoginBody struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type adminChangePasswordBody struct {
	OldPassword string `json:"old_password"`
	NewUsername string `json:"new_username,omitempty"`
	NewPassword string `json:"new_password"`
}

type adminCreateAccountBody struct {
	Username      string `json:"username"`
	Email         string `json:"email,omitempty"`
	Password      string `json:"password"`
	HouseholdName string `json:"household_name,omitempty"`
}

type adminAccountStatusBody struct {
	Status string `json:"status"`
}

type adminResetAccountPasswordBody struct {
	NewPassword string `json:"new_password"`
}

type adminUpdateQuotasBody struct {
	MaxSources      *int   `json:"max_sources,omitempty"`
	MaxFiles        *int   `json:"max_files,omitempty"`
	MaxSidecarBytes *int64 `json:"max_sidecar_bytes,omitempty"`
}

type adminCreateInviteBody struct {
	MaxUses   int    `json:"max_uses"`
	ExpiresAt *int64 `json:"expires_at,omitempty"`
	Note      string `json:"note,omitempty"`
}

func parseIntQuery(r *http.Request, name string, fallback int) int {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return v
}

func (s *Server) handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	var body adminLoginBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	res, err := s.Plat.Login(body.Username, body.Password, s.clientIP(r), r.UserAgent())
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, struct {
		Code int `json:"code"`
		*platform.AdminLoginResult
	}{
		Code:             0,
		AdminLoginResult: res,
	})
}

func (s *Server) handleAdminLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.Plat.Logout(bearerToken(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminMe(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"admin": p,
	})
}

func (s *Server) handleAdminChangePassword(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminChangePasswordBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Plat.ChangePassword(p.AdminID, body.OldPassword, body.NewUsername, body.NewPassword, p.TokenID, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminListAccounts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	status := r.URL.Query().Get("status")
	limit := parseIntQuery(r, "limit", 30)
	offset := parseIntQuery(r, "offset", 0)

	accounts, total, err := s.Plat.ListAccounts(q, status, limit, offset)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"accounts": accounts,
		"total":    total,
		"limit":    limit,
		"offset":   offset,
	})
}

func (s *Server) handleAdminCreateAccount(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminCreateAccountBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	acc, err := s.Plat.CreateAccountByAdmin(p.AdminID, body.Username, body.Email, body.Password, body.HouseholdName, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"account": acc,
	})
}

func (s *Server) handleAdminSetAccountStatus(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminAccountStatusBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Plat.SetAccountStatus(p.AdminID, r.PathValue("id"), body.Status, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminResetAccountPassword(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminResetAccountPasswordBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Plat.ResetAccountPassword(p.AdminID, r.PathValue("id"), body.NewPassword, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                 0,
		"must_change_password": true,
		"key_wraps_wiped":      true,
		"warning":              "E2EE household key wraps were wiped and saved source credentials were marked expired; the user must re-enter source credentials after logging in.",
	})
}

func (s *Server) handleAdminForceLogout(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	if err := s.Plat.ForceLogoutAccount(p.AdminID, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminScheduleDelete(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	if err := s.Plat.ScheduleDeleteAccount(p.AdminID, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"status":     "pending_delete",
		"grace_days": 7,
	})
}

func (s *Server) handleAdminRestoreAccount(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	if err := s.Plat.RestoreAccount(p.AdminID, r.PathValue("id"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"status": "active",
	})
}

func (s *Server) handleAdminUpdateQuotas(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminUpdateQuotasBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if err := s.Plat.UpdateHouseholdQuotas(p.AdminID, r.PathValue("id"), body.MaxSources, body.MaxFiles, body.MaxSidecarBytes, s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminListInvites(w http.ResponseWriter, r *http.Request) {
	invites, err := s.Plat.ListInviteCodes()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"invites": invites,
	})
}

func (s *Server) handleAdminCreateInvite(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var body adminCreateInviteBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	maxUses := body.MaxUses
	if maxUses == 0 {
		maxUses = 1
	}
	inv, err := s.Plat.CreateInviteCode(p.AdminID, maxUses, body.ExpiresAt, body.Note, s.clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"invite": inv,
	})
}

func (s *Server) handleAdminRevokeInvite(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	if err := s.Plat.RevokeInviteCode(p.AdminID, r.PathValue("code"), s.clientIP(r)); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0})
}

func (s *Server) handleAdminListAuditLogs(w http.ResponseWriter, r *http.Request) {
	actorType := r.URL.Query().Get("actor_type")
	hhID := r.URL.Query().Get("household_id")
	action := r.URL.Query().Get("action")
	limit := parseIntQuery(r, "limit", 50)
	offset := parseIntQuery(r, "offset", 0)

	logs, total, err := s.Plat.ListAuditLogs(actorType, hhID, action, limit, offset)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"logs":   logs,
		"total":  total,
		"limit":  limit,
		"offset": offset,
	})
}

func (s *Server) handleAdminGetSettings(w http.ResponseWriter, r *http.Request) {
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"settings": cfg,
	})
}

func (s *Server) handleAdminUpdateSettings(w http.ResponseWriter, r *http.Request) {
	p := AdminPrincipalFromContext(r.Context())
	var req db.ServerSettingsUpdate
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	updated, err := s.Store.UpdateServerSettings(req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.settings_updated",
		TargetType: "settings",
		TargetID:   "server_settings",
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"settings": updated,
	})
}
