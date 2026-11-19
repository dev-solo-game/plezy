package api

import (
	"net"
	"net/http"
	"strings"
	"time"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
)

func setSessionCookie(w http.ResponseWriter, r *http.Request, token string, expiresAtMs int64) {
	isHTTPS := r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
	http.SetCookie(w, &http.Cookie{
		Name:     auth.SessionCookieName,
		Value:    token,
		Path:     "/",
		Expires:  time.UnixMilli(expiresAtMs),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS,
	})
}

func clearSessionCookie(w http.ResponseWriter, r *http.Request) {
	isHTTPS := r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
	http.SetCookie(w, &http.Cookie{
		Name:     auth.SessionCookieName,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS,
	})
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.SplitN(xff, ",", 2)[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) handleAuthSetup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username      string `json:"username"`
		Password      string `json:"password"`
		ServerName    string `json:"server_name"`
		TmdbAPIKey    string `json:"tmdb_api_key"`
		MetadataProxy string `json:"metadata_proxy"`
		DeviceName    string `json:"device_name"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Username) == "" {
		req.Username = "admin"
	}
	sess, err := s.Auth.SetupAdmin(req.Username, req.Password, req.DeviceName, "web", clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	upd := db.ServerSettingsUpdate{}
	if strings.TrimSpace(req.ServerName) != "" {
		sn := strings.TrimSpace(req.ServerName)
		upd.ServerName = &sn
	}
	if strings.TrimSpace(req.TmdbAPIKey) != "" {
		k := strings.TrimSpace(req.TmdbAPIKey)
		upd.TmdbAPIKey = &k
	}
	if strings.TrimSpace(req.MetadataProxy) != "" {
		p := strings.TrimSpace(req.MetadataProxy)
		upd.MetadataProxy = &p
	}
	_, _ = s.Store.UpdateServerSettings(upd)

	setSessionCookie(w, r, sess.AccessToken, sess.ExpiresAt)
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":         0,
		"username":     sess.Username,
		"access_token": sess.AccessToken,
		"token_id":     sess.TokenID,
		"expires_at":   sess.ExpiresAt,
	})
}

func (s *Server) handleAuthLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	sess, err := s.Auth.Login(req.Username, req.Password, req.DeviceName, req.Platform, clientIP(r))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	setSessionCookie(w, r, sess.AccessToken, sess.ExpiresAt)
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":         0,
		"username":     sess.Username,
		"access_token": sess.AccessToken,
		"token_id":     sess.TokenID,
		"expires_at":   sess.ExpiresAt,
	})
}

func (s *Server) handleAuthLogout(w http.ResponseWriter, r *http.Request) {
	tok := s.extractToken(r)
	if tok != "" {
		_ = s.Auth.Logout(tok)
	}
	clearSessionCookie(w, r)
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok"})
}

func (s *Server) handleAuthMe(w http.ResponseWriter, r *http.Request, acc *db.AdminAccount, sess *db.SessionRecord) {
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"username": acc.Username,
		"token_id": sess.TokenID,
	})
}

func (s *Server) handleAuthPassword(w http.ResponseWriter, r *http.Request, acc *db.AdminAccount, sess *db.SessionRecord) {
	var req struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
		NewUsername string `json:"new_username"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.Auth.ChangePassword(req.OldPassword, req.NewPassword, req.NewUsername, sess.TokenID); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "ok"})
}

func (s *Server) handleAuthSessions(w http.ResponseWriter, r *http.Request, acc *db.AdminAccount, sess *db.SessionRecord) {
	list, err := s.Auth.ListSessions(sess.TokenID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "sessions": list})
}

func (s *Server) handleAuthRevokeSession(w http.ResponseWriter, r *http.Request, acc *db.AdminAccount, sess *db.SessionRecord) {
	id := r.PathValue("token_id")
	if err := s.Auth.RevokeSession(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "revoked"})
}
