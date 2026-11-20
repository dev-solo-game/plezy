package api

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/feed"
	"plezy/media_library/internal/identify"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/platform"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/source"
	"plezy/media_library/internal/userdata"
)

const (
	maxJSONBodyBytes       = 8 * 1024 * 1024
	currentProtocolVersion = 1
)

type ctxKey string

const (
	ctxKeyUserPrincipal  ctxKey = "user_principal"
	ctxKeyAdminPrincipal ctxKey = "admin_principal"
)

type Server struct {
	Store    *db.Store
	Meta     *metadata.Service
	Scraper  *library.Scraper
	Hub      *events.Hub
	Plat     *platform.Service
	Acc      *account.Service
	Src      *source.Service
	Ing      *ingest.Service
	Idf      *identify.Queue
	UserData *userdata.Service
	Feed     *feed.Service
	Mux      http.Handler

	webDir                   string
	allowInsecureCredentials bool
	trustedProxies           []*net.IPNet
	pubRateMu                sync.Mutex
	pubRate                  map[string]*ipRateBucket
	metaLimiter              *security.LoginLimiter
}

func (s *Server) SetWebDir(dir string) {
	s.webDir = strings.TrimSpace(dir)
}

func (s *Server) SetAllowInsecureCredentials(allow bool) {
	s.allowInsecureCredentials = allow
}

func (s *Server) SetTrustedProxies(csv string) error {
	nets, err := security.ParseCIDRList(csv)
	if err != nil {
		return err
	}
	s.trustedProxies = nets
	return nil
}

func NewServer(
	store *db.Store,
	metaSvc *metadata.Service,
	scraper *library.Scraper,
	hub *events.Hub,
	platSvc *platform.Service,
	accSvc *account.Service,
	srcSvc *source.Service,
	ingSvc *ingest.Service,
) *Server {
	var idfQueue *identify.Queue
	if store != nil && scraper != nil {
		idfQueue = identify.NewQueue(store, scraper, hub)
	}
	var udSvc *userdata.Service
	var feedSvc *feed.Service
	if store != nil {
		udSvc = userdata.NewService(store, hub)
		feedSvc = feed.NewService(store, udSvc)
	}
	s := &Server{
		Store:       store,
		Meta:        metaSvc,
		Scraper:     scraper,
		Hub:         hub,
		Plat:        platSvc,
		Acc:         accSvc,
		Src:         srcSvc,
		Ing:         ingSvc,
		Idf:         idfQueue,
		UserData:    udSvc,
		Feed:        feedSvc,
		pubRate:     make(map[string]*ipRateBucket),
		metaLimiter: security.NewLoginLimiter(),
	}
	s.Mux = s.buildMux()
	return s
}

func (s *Server) SetIdentifyQueue(q *identify.Queue) {
	s.Idf = q
}

func (s *Server) buildMux() http.Handler {
	mux := http.NewServeMux()

	// Health & bootstrap
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/v1/health", s.handleHealth)
	mux.HandleFunc("GET /api/v1/public/bootstrap", s.handleBootstrap)

	// Generic public metadata & recognition service (offline clients + authenticated bypass)
	mux.HandleFunc("GET /api/v1/public/metadata/config", s.requirePublicMetadata(s.handlePublicMetadataConfig))
	mux.HandleFunc("GET /api/v1/public/metadata/search", s.requirePublicMetadata(s.handlePublicMetadataSearch))
	mux.HandleFunc("POST /api/v1/public/metadata/identify", s.requirePublicMetadata(s.handlePublicMetadataIdentify))
	mux.HandleFunc("GET /api/v1/public/metadata/work/{provider}/{kind}/{id}", s.requirePublicMetadata(s.handlePublicMetadataWork))
	mux.HandleFunc("GET /api/v1/public/metadata/season/{provider}/{id}/{season}", s.requirePublicMetadata(s.handlePublicMetadataSeason))
	mux.HandleFunc("POST /api/v1/public/metadata/batch", s.requirePublicMetadata(s.handlePublicMetadataBatch))
	mux.HandleFunc("GET /api/v1/public/metadata/artwork", s.requirePublicMetadata(s.handlePublicMetadataArtwork))

	// User account authentication & recovery
	mux.HandleFunc("POST /api/v1/auth/register", s.handleUserRegister)
	mux.HandleFunc("POST /api/v1/auth/login", s.handleUserLogin)
	mux.HandleFunc("POST /api/v1/auth/select-member", s.handleUserSelectMember)
	mux.HandleFunc("POST /api/v1/auth/switch-member", s.requireUser(s.handleUserSwitchMember))
	mux.HandleFunc("POST /api/v1/auth/logout", s.requireUser(s.handleUserLogout))
	mux.HandleFunc("GET /api/v1/auth/me", s.requireUser(s.handleUserMe))
	mux.HandleFunc("POST /api/v1/auth/change-password", s.requireUser(s.handleUserChangePassword))
	mux.HandleFunc("POST /api/v1/auth/recovery/wrap", s.handleUserRecoveryWrap)
	mux.HandleFunc("POST /api/v1/auth/recovery/reset", s.handleUserRecoveryReset)
	mux.HandleFunc("POST /api/v1/auth/delete-account", s.requireUser(s.requirePerm(account.PermDeleteHousehold, s.handleUserDeleteAccount)))

	// QR code E2EE login handshake
	mux.HandleFunc("POST /api/v1/auth/qr", s.handleQrCreate)
	mux.HandleFunc("GET /api/v1/auth/qr/{id}", s.requireUser(s.handleQrGetInfo))
	mux.HandleFunc("POST /api/v1/auth/qr/{id}/confirm", s.requireUser(s.handleQrConfirm))
	mux.HandleFunc("POST /api/v1/auth/qr/{id}/poll", s.handleQrPoll)

	// Household, keyring, members, devices & sessions
	mux.HandleFunc("GET /api/v1/household", s.requireUser(s.handleGetHousehold))
	mux.HandleFunc("PATCH /api/v1/household", s.requireUser(s.requirePerm(account.PermManageSettings, s.handleUpdateHousehold)))
	mux.HandleFunc("GET /api/v1/household/key-wraps", s.requireUser(s.handleListKeyWraps))
	mux.HandleFunc("PUT /api/v1/household/key-wraps", s.requireUser(s.handleUpsertKeyWrap))
	mux.HandleFunc("GET /api/v1/household/members", s.requireUser(s.handleListMembers))
	mux.HandleFunc("POST /api/v1/household/members", s.requireUser(s.requirePerm(account.PermManageMembers, s.handleCreateMember)))
	mux.HandleFunc("PATCH /api/v1/household/members/{id}", s.requireUser(s.handleUpdateMember))
	mux.HandleFunc("DELETE /api/v1/household/members/{id}", s.requireUser(s.requirePerm(account.PermManageMembers, s.handleDeleteMember)))
	mux.HandleFunc("GET /api/v1/household/devices", s.requireUser(s.handleListDevices))
	mux.HandleFunc("DELETE /api/v1/household/devices/{id}", s.requireUser(s.handleRevokeDevice))
	mux.HandleFunc("GET /api/v1/household/sessions", s.requireUser(s.handleListSessions))
	mux.HandleFunc("DELETE /api/v1/household/sessions/{id}", s.requireUser(s.handleRevokeSession))

	// Media sources, folders & E2EE credentials
	mux.HandleFunc("GET /api/v1/sources", s.requireUser(s.handleListSources))
	mux.HandleFunc("POST /api/v1/sources", s.requireUser(s.requirePerm(account.PermManageSources, s.handleCreateSource)))
	mux.HandleFunc("GET /api/v1/sources/{id}", s.requireUser(s.handleGetSource))
	mux.HandleFunc("PATCH /api/v1/sources/{id}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleUpdateSource)))
	mux.HandleFunc("DELETE /api/v1/sources/{id}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleDeleteSource)))
	mux.HandleFunc("GET /api/v1/sources/{id}/folders", s.requireUser(s.handleListFolders))
	mux.HandleFunc("POST /api/v1/sources/{id}/folders", s.requireUser(s.requirePerm(account.PermManageSources, s.handleAddFolder)))
	mux.HandleFunc("PATCH /api/v1/sources/{id}/folders/{fid}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleUpdateFolder)))
	mux.HandleFunc("DELETE /api/v1/sources/{id}/folders/{fid}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleDeleteFolder)))
	mux.HandleFunc("GET /api/v1/sources/{id}/credential", s.requireUser(s.handleGetSourceCredential))
	mux.HandleFunc("PUT /api/v1/sources/{id}/credential", s.requireUser(s.handleUpdateSourceCredential))
	mux.HandleFunc("POST /api/v1/sources/{id}/credential/status", s.requireUser(s.handleReportSourceCredentialStatus))

	// Scan sessions, idempotent batch ingest, sidecars, media-spec & pending deletions
	mux.HandleFunc("POST /api/v1/sources/{id}/scan-sessions", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handleCreateScanSession)))
	mux.HandleFunc("GET /api/v1/sources/{id}/scan-sessions", s.requireUser(s.handleListSourceScanSessions))
	mux.HandleFunc("POST /api/v1/scan-sessions/{sid}/batches", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handleSubmitScanBatch)))
	mux.HandleFunc("POST /api/v1/scan-sessions/{sid}/progress", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handleReportScanProgress)))
	mux.HandleFunc("POST /api/v1/scan-sessions/{sid}/complete", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handleCompleteScanSession)))
	mux.HandleFunc("POST /api/v1/scan-sessions/{sid}/cancel", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handleCancelScanSession)))
	mux.HandleFunc("GET /api/v1/pending-deletions", s.requireUser(s.handleListPendingDeletions))
	mux.HandleFunc("POST /api/v1/pending-deletions/{id}/confirm", s.requireUser(s.requirePerm(account.PermManageSources, s.handleConfirmPendingDeletion)))
	mux.HandleFunc("POST /api/v1/pending-deletions/{id}/dismiss", s.requireUser(s.requirePerm(account.PermManageSources, s.handleDismissPendingDeletion)))
	mux.HandleFunc("HEAD /api/v1/sidecars/{sha256}", s.requireUser(s.handleHeadSidecar))
	mux.HandleFunc("PUT /api/v1/sidecars/{sha256}", s.requireUser(s.requirePerm(account.PermUploadFacts, s.handlePutSidecar)))
	mux.HandleFunc("POST /api/v1/files/{id}/media-spec", s.requireUser(s.handleReportMediaSpec))

	// Authenticated metadata & library identification management (S4)
	mux.HandleFunc("GET /api/v1/metadata/search", s.requireUserMetadataQuota(s.handleUserMetadataSearch))
	mux.HandleFunc("GET /api/v1/metadata/works", s.requireUserMetadataQuota(s.handleUserMetadataWork))
	mux.HandleFunc("GET /api/v1/metadata/works/{provider}/{kind}/{id}", s.requireUserMetadataQuota(s.handleUserMetadataWork))
	mux.HandleFunc("GET /api/v1/metadata/seasons", s.requireUserMetadataQuota(s.handleUserMetadataSeason))
	mux.HandleFunc("GET /api/v1/metadata/seasons/{provider}/{id}/{season}", s.requireUserMetadataQuota(s.handleUserMetadataSeason))
	mux.HandleFunc("GET /api/v1/metadata/people", s.requireUserMetadataQuota(s.handleUserMetadataPerson))
	mux.HandleFunc("GET /api/v1/metadata/people/{provider}/{id}", s.requireUserMetadataQuota(s.handleUserMetadataPerson))
	mux.HandleFunc("POST /api/v1/metadata/identify", s.requireUserMetadataQuota(s.handleUserMetadataIdentify))
	mux.HandleFunc("GET /api/v1/metadata/artwork", s.requireUser(s.handlePublicMetadataArtwork))

	mux.HandleFunc("GET /api/v1/library/unmatched", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListUnmatched)))
	mux.HandleFunc("POST /api/v1/library/unmatched/ignore", s.requireUser(s.requirePerm(account.PermManageSources, s.handleIgnoreUnmatched)))
	mux.HandleFunc("POST /api/v1/library/manual-match", s.requireUser(s.requirePerm(account.PermManageSources, s.handleManualMatch)))
	mux.HandleFunc("GET /api/v1/match-rules", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListMatchRules)))
	mux.HandleFunc("POST /api/v1/match-rules", s.requireUser(s.requirePerm(account.PermManageSources, s.handleUpsertMatchRule)))
	mux.HandleFunc("DELETE /api/v1/match-rules/{id}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleDeleteMatchRule)))
	mux.HandleFunc("PATCH /api/v1/items/{id}", s.requireUser(s.requirePerm(account.PermManageSources, s.handleEditItem)))
	mux.HandleFunc("POST /api/v1/items/{id}/rescrape", s.requireUser(s.requirePerm(account.PermManageSources, s.handleRescrapeItem)))

	// Downstream library sync, sidecar download, SSE & member user data (S5)
	mux.HandleFunc("GET /api/v1/library/snapshot", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetLibrarySnapshot)))
	mux.HandleFunc("GET /api/v1/library/changes", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetLibraryChanges)))
	mux.HandleFunc("GET /api/v1/items/{id}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetItemDetail)))
	mux.HandleFunc("GET /api/v1/sidecars/{sha256}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetSidecar)))
	mux.HandleFunc("GET /api/v1/events", s.requireUser(s.requirePerm(account.PermBrowse, s.handleEventsSSE)))

	mux.HandleFunc("GET /api/v1/progress", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListProgress)))
	mux.HandleFunc("POST /api/v1/progress", s.requireUser(s.requirePerm(account.PermBrowse, s.handleUpsertProgress)))
	mux.HandleFunc("PUT /api/v1/progress", s.requireUser(s.requirePerm(account.PermBrowse, s.handleUpsertProgress)))
	mux.HandleFunc("DELETE /api/v1/progress/{key}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleDeleteProgress)))
	mux.HandleFunc("GET /api/v1/continue-watching", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListContinueWatching)))
	mux.HandleFunc("POST /api/v1/continue-watching/{key}/hide", s.requireUser(s.requirePerm(account.PermBrowse, s.handleHideContinueWatching)))
	mux.HandleFunc("GET /api/v1/favorites", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListFavorites)))
	mux.HandleFunc("PUT /api/v1/favorites/{work_key}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleAddFavorite)))
	mux.HandleFunc("DELETE /api/v1/favorites/{work_key}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleRemoveFavorite)))
	mux.HandleFunc("GET /api/v1/work-prefs/{work_key}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetWorkPrefs)))
	mux.HandleFunc("PUT /api/v1/work-prefs/{work_key}/household", s.requireUser(s.handleUpsertHouseholdWorkPrefs))
	mux.HandleFunc("PUT /api/v1/work-prefs/{work_key}/member", s.requireUser(s.requirePerm(account.PermBrowse, s.handleUpsertMemberWorkPrefs)))
	mux.HandleFunc("GET /api/v1/lists", s.requireUser(s.requirePerm(account.PermBrowse, s.handleListLists)))
	mux.HandleFunc("POST /api/v1/lists", s.requireUser(s.requirePerm(account.PermBrowse, s.handleCreateList)))
	mux.HandleFunc("GET /api/v1/lists/{id}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleGetList)))
	mux.HandleFunc("PATCH /api/v1/lists/{id}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleUpdateList)))
	mux.HandleFunc("DELETE /api/v1/lists/{id}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleDeleteList)))
	mux.HandleFunc("POST /api/v1/lists/{id}/entries", s.requireUser(s.requirePerm(account.PermBrowse, s.handleAddListEntry)))
	mux.HandleFunc("DELETE /api/v1/lists/{id}/entries/{entry_key}", s.requireUser(s.requirePerm(account.PermBrowse, s.handleRemoveListEntry)))
	mux.HandleFunc("POST /api/v1/userdata/migrate-work", s.requireUser(s.requirePerm(account.PermManageSources, s.handleMigrateWorkData)))

	// Platform administrator endpoints (strictly isolated from /api/v1 user sessions)
	mux.HandleFunc("POST /api/admin/auth/login", s.requireAdminIP(s.handleAdminLogin))
	mux.HandleFunc("POST /api/admin/auth/logout", s.requireAdmin(s.handleAdminLogout))
	mux.HandleFunc("GET /api/admin/auth/me", s.requireAdmin(s.handleAdminMe))
	mux.HandleFunc("POST /api/admin/auth/change-password", s.requireAdmin(s.handleAdminChangePassword))

	mux.HandleFunc("GET /api/admin/overview", s.requireAdminReady(s.handleAdminOverview))
	mux.HandleFunc("GET /api/admin/accounts", s.requireAdminReady(s.handleAdminListAccounts))
	mux.HandleFunc("POST /api/admin/accounts", s.requireAdminReady(s.handleAdminCreateAccount))
	mux.HandleFunc("POST /api/admin/accounts/{id}/status", s.requireAdminReady(s.handleAdminSetAccountStatus))
	mux.HandleFunc("POST /api/admin/accounts/{id}/reset-password", s.requireAdminReady(s.handleAdminResetAccountPassword))
	mux.HandleFunc("POST /api/admin/accounts/{id}/force-logout", s.requireAdminReady(s.handleAdminForceLogout))
	mux.HandleFunc("DELETE /api/admin/accounts/{id}", s.requireAdminReady(s.handleAdminScheduleDelete))
	mux.HandleFunc("POST /api/admin/accounts/{id}/restore", s.requireAdminReady(s.handleAdminRestoreAccount))
	mux.HandleFunc("PATCH /api/admin/accounts/{id}/quotas", s.requireAdminReady(s.handleAdminUpdateQuotas))

	mux.HandleFunc("GET /api/admin/invites", s.requireAdminReady(s.handleAdminListInvites))
	mux.HandleFunc("POST /api/admin/invites", s.requireAdminReady(s.handleAdminCreateInvite))
	mux.HandleFunc("DELETE /api/admin/invites/{code}", s.requireAdminReady(s.handleAdminRevokeInvite))

	mux.HandleFunc("GET /api/admin/audit-logs", s.requireAdminReady(s.handleAdminListAuditLogs))
	mux.HandleFunc("GET /api/admin/settings", s.requireAdminReady(s.handleAdminGetSettings))
	mux.HandleFunc("PATCH /api/admin/settings", s.requireAdminReady(s.handleAdminUpdateSettings))
	mux.HandleFunc("POST /api/admin/settings/test-tmdb", s.requireAdminReady(s.handleAdminTestTmdb))
	mux.HandleFunc("POST /api/admin/settings/test-provider", s.requireAdminReady(s.handleAdminTestProvider))
	mux.HandleFunc("POST /api/admin/settings/clear-cache", s.requireAdminReady(s.handleAdminClearMetaCache))

	mux.HandleFunc("GET /api/admin/metadata/tables", s.requireAdminReady(s.handleAdminListMetadataTables))
	mux.HandleFunc("GET /api/admin/metadata/tables/{table}", s.requireAdminReady(s.handleAdminQueryMetadataTable))
	mux.HandleFunc("DELETE /api/admin/metadata/tables/{table}/row", s.requireAdminReady(s.handleAdminDeleteMetadataCacheRow))

	mux.HandleFunc("GET /api/admin/identify/status", s.requireAdminReady(s.handleAdminIdentifyStatus))
	mux.HandleFunc("POST /api/admin/identify/pause", s.requireAdminReady(s.handleAdminIdentifyPause))
	mux.HandleFunc("POST /api/admin/identify/resume", s.requireAdminReady(s.handleAdminIdentifyResume))
	mux.HandleFunc("POST /api/admin/identify/retry-failed", s.requireAdminReady(s.handleAdminIdentifyRetryFailed))

	mux.HandleFunc("GET /api/admin/logs", s.requireAdminReady(s.handleAdminGetSystemLogs))
	mux.HandleFunc("POST /api/admin/logs/clear", s.requireAdminReady(s.handleAdminClearSystemLogs))
	mux.HandleFunc("GET /api/admin/logs/download", s.requireAdminReady(s.handleAdminDownloadSystemLogs))

	mux.HandleFunc("GET /", s.handleWebSPA)

	return s.withRequestLogging(s.withProtocolVersionCheck(mux))
}

func UserPrincipalFromContext(ctx context.Context) *account.Principal {
	p, _ := ctx.Value(ctxKeyUserPrincipal).(*account.Principal)
	return p
}

func AdminPrincipalFromContext(ctx context.Context) *platform.AdminPrincipal {
	p, _ := ctx.Value(ctxKeyAdminPrincipal).(*platform.AdminPrincipal)
	return p
}

func bearerToken(r *http.Request) string {
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	if len(raw) < 7 {
		return ""
	}
	if !strings.EqualFold(raw[:7], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(raw[7:])
}

func (s *Server) requireUser(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.Acc == nil {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "user auth service unavailable")
			return
		}
		tok := bearerToken(r)
		if tok == "" {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "authentication required")
			return
		}
		p, err := s.Acc.Authenticate(tok)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyUserPrincipal, p)
		next(w, r.WithContext(ctx))
	}
}

func (s *Server) requirePerm(perm int, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p := UserPrincipalFromContext(r.Context())
		if p == nil {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "authentication required")
			return
		}
		if !p.HasPerm(perm) {
			writeErrCode(w, r, http.StatusForbidden, "forbidden", "insufficient member permissions")
			return
		}
		next(w, r)
	}
}

func (s *Server) requireAdminIP(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.Plat == nil {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "admin auth service unavailable")
			return
		}
		if err := s.Plat.CheckAllowedIP(s.clientIP(r)); err != nil {
			writeMappedError(w, r, err)
			return
		}
		next(w, r)
	}
}

func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return s.requireAdminIP(func(w http.ResponseWriter, r *http.Request) {
		tok := bearerToken(r)
		if tok == "" {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "admin authentication required")
			return
		}
		p, err := s.Plat.Authenticate(tok)
		if err != nil {
			writeMappedError(w, r, err)
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyAdminPrincipal, p)
		next(w, r.WithContext(ctx))
	})
}

func (s *Server) requireAdminReady(next http.HandlerFunc) http.HandlerFunc {
	return s.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		p := AdminPrincipalFromContext(r.Context())
		if p == nil {
			writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", "admin authentication required")
			return
		}
		if p.MustChangePassword {
			writeErrCode(w, r, http.StatusForbidden, "password_change_required", "admin must change default password before performing management actions")
			return
		}
		next(w, r)
	})
}

func (s *Server) isTrustedProxy(peer string) bool {
	if len(s.trustedProxies) == 0 {
		return false
	}
	return security.IPAllowed(peer, s.trustedProxies)
}

func peerIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}

func (s *Server) clientIP(r *http.Request) string {
	peer := peerIP(r)
	if s.isTrustedProxy(peer) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			first := strings.TrimSpace(strings.SplitN(xff, ",", 2)[0])
			if net.ParseIP(first) != nil {
				return first
			}
		}
	}
	return peer
}

func (s *Server) isSecureTransport(r *http.Request) bool {
	if s.allowInsecureCredentials {
		return true
	}
	if r.TLS != nil {
		return true
	}
	if strings.EqualFold(strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")), "https") {
		peer := peerIP(r)
		ip := net.ParseIP(peer)
		if (ip != nil && ip.IsLoopback()) || s.isTrustedProxy(peer) {
			return true
		}
	}
	return false
}

func (s *Server) requireSecureTransport(w http.ResponseWriter, r *http.Request) bool {
	if s.isSecureTransport(r) {
		return true
	}
	writeErrCode(w, r, http.StatusForbidden, "https_required", "HTTPS is required for credential transport")
	return false
}

func (s *Server) withProtocolVersionCheck(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if strings.HasPrefix(p, "/api/v1/") && p != "/api/v1/public/bootstrap" && p != "/api/v1/health" {
			if raw := strings.TrimSpace(r.Header.Get("X-TTPlay-Client")); raw != "" {
				parts := strings.Split(raw, "/")
				if len(parts) >= 3 {
					if ver, err := strconv.Atoi(strings.TrimSpace(parts[2])); err == nil {
						cfg := s.Store.GetServerSettings()
						if ver < cfg.MinProtocolVersion {
							writeJSON(w, r, http.StatusUpgradeRequired, map[string]any{
								"code":                 http.StatusUpgradeRequired,
								"error":                "upgrade_required",
								"message":              "client protocol version is too old; please upgrade",
								"protocol_version":     currentProtocolVersion,
								"min_protocol_version": cfg.MinProtocolVersion,
							})
							return
						}
					}
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

type loggingResponseWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (rw *loggingResponseWriter) WriteHeader(code int) {
	if !rw.wroteHeader {
		rw.status = code
		rw.wroteHeader = true
	}
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *loggingResponseWriter) Write(p []byte) (int, error) {
	if !rw.wroteHeader {
		rw.status = http.StatusOK
		rw.wroteHeader = true
	}
	return rw.ResponseWriter.Write(p)
}

func (rw *loggingResponseWriter) Flush() {
	if f, ok := rw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (rw *loggingResponseWriter) Unwrap() http.ResponseWriter {
	return rw.ResponseWriter
}

func (s *Server) withRequestLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(lw, r)
		elapsedMs := time.Since(start).Milliseconds()

		p := r.URL.Path
		st := lw.status

		if !strings.HasPrefix(p, "/api/") {
			if st >= http.StatusInternalServerError {
				applog.Errorf("api", "%s %s -> %d (%dms)", r.Method, p, st, elapsedMs)
			}
			return
		}

		if st < http.StatusBadRequest {
			switch {
			case p == "/healthz", p == "/api/v1/health",
				strings.HasPrefix(p, "/api/v1/public/metadata/artwork"):
				return
			}
			if r.Method != http.MethodPost && r.Method != http.MethodPut && r.Method != http.MethodPatch && r.Method != http.MethodDelete {
				return
			}
		}

		target := p
		if r.URL.RawQuery != "" {
			target += "?" + applog.RedactQuery(r.URL.RawQuery)
		}

		switch {
		case st >= http.StatusInternalServerError:
			applog.Errorf("api", "%s %s -> %d (%dms)", r.Method, target, st, elapsedMs)
		case st >= http.StatusBadRequest:
			applog.Warnf("api", "%s %s -> %d (%dms)", r.Method, target, st, elapsedMs)
		default:
			applog.Infof("api", "%s %s -> %d (%dms)", r.Method, target, st, elapsedMs)
		}
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"status": "ok",
		"role":   "media_library",
	})
}

func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                 0,
		"server_name":          cfg.ServerName,
		"accent_theme":         cfg.AccentTheme,
		"version":              "1.0.0",
		"protocol_version":     currentProtocolVersion,
		"min_protocol_version": cfg.MinProtocolVersion,
		"registration_mode":    cfg.RegistrationMode,
	})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	var body io.Reader = http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	if strings.EqualFold(strings.TrimSpace(r.Header.Get("Content-Encoding")), "gzip") {
		gz, err := gzip.NewReader(body)
		if err != nil {
			return err
		}
		defer gz.Close()
		body = io.LimitReader(gz, maxJSONBodyBytes)
	}
	dec := json.NewDecoder(body)
	return dec.Decode(dst)
}

func decodeOptionalJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	err := decodeJSON(w, r, dst)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	raw, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"code":500,"message":"marshal error"}`, http.StatusInternalServerError)
		return
	}
	writeRawJSON(w, r, status, raw)
}

// writeRawJSON writes pre-serialized JSON, gzip-compressing larger payloads.
func writeRawJSON(w http.ResponseWriter, r *http.Request, status int, raw []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if len(raw) > 512 {
		w.Header().Add("Vary", "Accept-Encoding")
	}
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
	writeJSON(w, r, status, map[string]any{
		"code":    status,
		"message": msg,
	})
}

func writeErrCode(w http.ResponseWriter, r *http.Request, status int, errCode, msg string) {
	writeJSON(w, r, status, map[string]any{
		"code":    status,
		"error":   errCode,
		"message": msg,
	})
}

func writeMappedError(w http.ResponseWriter, r *http.Request, err error) {
	var accRL *account.RateLimitError
	if errors.As(err, &accRL) {
		w.Header().Set("Retry-After", strconv.Itoa(accRL.RetryAfterSec))
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", err.Error())
		return
	}
	var platRL *platform.RateLimitError
	if errors.As(err, &platRL) {
		w.Header().Set("Retry-After", strconv.Itoa(platRL.RetryAfterSec))
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", err.Error())
		return
	}
	var kindErr *source.KindNotAllowedError
	if errors.As(err, &kindErr) {
		writeJSON(w, r, http.StatusForbidden, map[string]any{
			"code":            http.StatusForbidden,
			"error":           "source_kind_not_allowed_on_device",
			"message":         err.Error(),
			"allowed_devices": kindErr.AllowedDevices,
		})
		return
	}
	var dupErr *source.DuplicateSourceError
	if errors.As(err, &dupErr) {
		writeJSON(w, r, http.StatusConflict, map[string]any{
			"code":               http.StatusConflict,
			"error":              "source_already_exists",
			"message":            err.Error(),
			"existing_source_id": dupErr.ExistingSourceID,
		})
		return
	}
	var simErr *source.SimilarSourceError
	if errors.As(err, &simErr) {
		writeJSON(w, r, http.StatusConflict, map[string]any{
			"code":            http.StatusConflict,
			"error":           "similar_source_exists",
			"message":         err.Error(),
			"similar_sources": simErr.SimilarSources,
		})
		return
	}
	var quotaErr *source.QuotaExceededError
	if errors.As(err, &quotaErr) {
		writeJSON(w, r, http.StatusTooManyRequests, map[string]any{
			"code":    http.StatusTooManyRequests,
			"error":   "quota_exceeded",
			"message": err.Error(),
			"quota":   quotaErr.Quota,
			"limit":   quotaErr.Limit,
			"current": quotaErr.Current,
		})
		return
	}
	var credConflictErr *source.CredentialConflictError
	if errors.As(err, &credConflictErr) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Pragma", "no-cache")
		writeJSON(w, r, http.StatusConflict, map[string]any{
			"code":       http.StatusConflict,
			"error":      "credential_version_conflict",
			"message":    err.Error(),
			"credential": credConflictErr.Current,
		})
		return
	}
	var ingQuotaErr *ingest.QuotaExceededError
	if errors.As(err, &ingQuotaErr) {
		writeJSON(w, r, http.StatusTooManyRequests, map[string]any{
			"code":    http.StatusTooManyRequests,
			"error":   "quota_exceeded",
			"message": err.Error(),
			"quota":   ingQuotaErr.Quota,
			"limit":   ingQuotaErr.Limit,
			"current": ingQuotaErr.Current,
		})
		return
	}

	switch {
	case errors.Is(err, source.ErrSourceDeleted), errors.Is(err, ingest.ErrSourceDeleted):
		writeErrCode(w, r, http.StatusGone, "source_deleted", err.Error())
	case errors.Is(err, source.ErrIdentityMismatch):
		writeErrCode(w, r, http.StatusConflict, "identity_mismatch", err.Error())
	case errors.Is(err, ingest.ErrFullScanNotAllowed):
		writeErrCode(w, r, http.StatusForbidden, "full_scan_not_allowed_on_device", err.Error())
	case errors.Is(err, ingest.ErrScanNotAllowed):
		writeErrCode(w, r, http.StatusForbidden, "scan_not_allowed_on_device", err.Error())
	case errors.Is(err, ingest.ErrSessionNotRunning):
		writeErrCode(w, r, http.StatusConflict, "scan_session_not_running", err.Error())
	case errors.Is(err, account.ErrRateLimited), errors.Is(err, platform.ErrRateLimited):
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", err.Error())
	case errors.Is(err, account.ErrUnauthorized), errors.Is(err, platform.ErrUnauthorized), errors.Is(err, source.ErrUnauthorized), errors.Is(err, ingest.ErrUnauthorized):
		writeErrCode(w, r, http.StatusUnauthorized, "unauthorized", err.Error())
	case errors.Is(err, account.ErrInvalidCredentials), errors.Is(err, platform.ErrInvalidCredentials):
		writeErrCode(w, r, http.StatusUnauthorized, "invalid_credentials", err.Error())
	case errors.Is(err, platform.ErrPasswordChangeRequired):
		writeErrCode(w, r, http.StatusForbidden, "password_change_required", err.Error())
	case errors.Is(err, platform.ErrForbiddenIP):
		writeErrCode(w, r, http.StatusForbidden, "forbidden_ip", err.Error())
	case errors.Is(err, account.ErrRegistrationClosed):
		writeErrCode(w, r, http.StatusForbidden, "registration_closed", err.Error())
	case errors.Is(err, account.ErrInvalidInvite):
		writeErrCode(w, r, http.StatusForbidden, "invalid_invite", err.Error())
	case errors.Is(err, account.ErrAccountDisabled):
		writeErrCode(w, r, http.StatusForbidden, "account_disabled", err.Error())
	case errors.Is(err, account.ErrAccountPendingDelete):
		writeErrCode(w, r, http.StatusForbidden, "account_pending_delete", err.Error())
	case errors.Is(err, account.ErrForbidden), errors.Is(err, source.ErrForbidden), errors.Is(err, ingest.ErrForbidden), errors.Is(err, library.ErrForbidden), errors.Is(err, metadata.ErrDisabled):
		writeErrCode(w, r, http.StatusForbidden, "forbidden", err.Error())
	case errors.Is(err, account.ErrNotFound), errors.Is(err, platform.ErrNotFound), errors.Is(err, source.ErrNotFound), errors.Is(err, ingest.ErrNotFound), errors.Is(err, db.ErrNotFound), errors.Is(err, metadata.ErrNotFound):
		writeErrCode(w, r, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, account.ErrConflict), errors.Is(err, platform.ErrConflict), errors.Is(err, source.ErrConflict), errors.Is(err, ingest.ErrConflict), errors.Is(err, db.ErrConflict):
		writeErrCode(w, r, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, account.ErrInvalidInput), errors.Is(err, platform.ErrInvalidInput), errors.Is(err, source.ErrInvalidInput), errors.Is(err, ingest.ErrInvalidInput), errors.Is(err, keyring.ErrInvalidWrap), errors.Is(err, db.ErrInvalidInput), errors.Is(err, metadata.ErrInvalidInput):
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", err.Error())
	case errors.Is(err, metadata.ErrNotConfigured):
		writeErrCode(w, r, http.StatusPreconditionFailed, "not_configured", err.Error())
	case errors.Is(err, metadata.ErrUpstream):
		writeErrCode(w, r, http.StatusBadGateway, "upstream_error", err.Error())
	default:
		writeErrCode(w, r, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
