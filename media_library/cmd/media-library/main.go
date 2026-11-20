package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/api"
	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/platform"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/source"
	"plezy/media_library/internal/vault"
)

func main() {
	if len(os.Args) >= 3 && os.Args[1] == "admin" && os.Args[2] == "reset-password" {
		runAdminResetPasswordCLI(os.Args[3:])
		return
	}

	addr := flag.String("addr", envOr("LIBRARY_ADDR", ":8090"), "HTTP listen address")
	dataDir := flag.String("data-dir", envOr("LIBRARY_DATA_DIR", "./library_data"), "Directory for SQLite database, master.key and artwork cache")
	tmdbAPIKey := flag.String("tmdb-api-key", os.Getenv("LIBRARY_TMDB_API_KEY"), "Default TMDB v3 API key or v4 bearer token")
	tmdbAPIBase := flag.String("tmdb-api-base", os.Getenv("LIBRARY_TMDB_API_BASE"), "Default TMDB API base URL")
	tmdbImageBase := flag.String("tmdb-image-base", os.Getenv("LIBRARY_TMDB_IMAGE_BASE"), "Default TMDB image base URL")
	metadataProxy := flag.String("metadata-proxy", os.Getenv("LIBRARY_METADATA_PROXY"), "HTTP/SOCKS5 proxy for TMDB/Bangumi and artwork proxy")
	bangumiEnabled := flag.String("bangumi-enabled", os.Getenv("LIBRARY_BANGUMI_ENABLED"), "Default bangumi_enabled ('true' or 'false')")
	allowPublicMetadata := flag.String("allow-public-metadata", os.Getenv("LIBRARY_ALLOW_PUBLIC_METADATA"), "Default allow_public_metadata ('true' or 'false')")
	adminUser := flag.String("admin-user", envOr("LIBRARY_ADMIN_USER", "admin"), "Initial platform admin username")
	adminPassword := flag.String("admin-password", os.Getenv("LIBRARY_ADMIN_PASSWORD"), "Initial platform admin password (defaults to 'admin' with forced change on first login)")
	adminAllowedCIDRs := flag.String("admin-allowed-cidrs", os.Getenv("LIBRARY_ADMIN_ALLOWED_CIDRS"), "Optional comma-separated IP/CIDR allowlist for /api/admin/*")
	trustedProxies := flag.String("trusted-proxies", os.Getenv("LIBRARY_TRUSTED_PROXIES"), "Optional comma-separated reverse proxy IPs/CIDRs allowed to set X-Forwarded-For/Proto")
	allowInsecureCredentials := flag.Bool("allow-insecure-credentials", envBool("LIBRARY_ALLOW_INSECURE_CREDENTIALS", false), "Allow credential transport over plain HTTP (debug/LAN only)")
	webDir := flag.String("web-dir", os.Getenv("LIBRARY_WEB_DIR"), "Optional path to web static directory")
	logLevel := flag.String("log-level", envOr("LIBRARY_LOG_LEVEL", "debug"), "Server log level (debug, info, warn, error)")
	flag.Parse()

	if err := applog.Init(filepath.Join(*dataDir, "logs"), *logLevel, true); err != nil {
		log.Printf("init logger warning: %v", err)
	}
	defer func() { _ = applog.Close() }()

	v, err := vault.Open(*dataDir, os.Getenv("LIBRARY_MASTER_KEY"))
	if err != nil {
		log.Fatalf("open vault: %v", err)
	}
	store, err := db.Open(*dataDir, v)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer func() {
		if err := store.Close(); err != nil {
			log.Printf("close db: %v", err)
		}
	}()

	var bgmPtr *bool
	if raw := strings.TrimSpace(*bangumiEnabled); raw != "" {
		parsed, pErr := strconv.ParseBool(raw)
		if pErr != nil {
			log.Fatalf("invalid -bangumi-enabled value %q: %v", raw, pErr)
		}
		bgmPtr = &parsed
	}
	if err := store.SeedDefaultSettingsIfAbsent(*tmdbAPIKey, *tmdbAPIBase, *tmdbImageBase, *metadataProxy, bgmPtr); err != nil {
		log.Fatalf("seed settings: %v", err)
	}
	var pubPtr *bool
	if raw := strings.TrimSpace(*allowPublicMetadata); raw != "" {
		parsed, pErr := strconv.ParseBool(raw)
		if pErr != nil {
			log.Fatalf("invalid -allow-public-metadata value %q: %v", raw, pErr)
		}
		pubPtr = &parsed
	}
	if err := store.SeedPublicMetadataIfAbsent(pubPtr); err != nil {
		log.Fatalf("seed public metadata setting: %v", err)
	}

	limiter := security.NewLoginLimiter()
	platSvc, err := platform.NewService(store, limiter, *adminAllowedCIDRs)
	if err != nil {
		log.Fatalf("init platform service: %v", err)
	}
	usingDefaultAdmin, err := platSvc.EnsureDefaultAdmin(*adminUser, *adminPassword)
	if err != nil {
		log.Fatalf("ensure default admin: %v", err)
	}
	if usingDefaultAdmin {
		warnMsg := "平台管理员仍在使用默认密码或待首次改密，请尽快登录管理后台修改管理员密码！"
		log.Printf("SECURITY WARNING: %s", warnMsg)
		applog.Warnf("security", "%s", warnMsg)
	}

	accSvc := account.NewService(store, limiter)
	hub := events.NewHub()
	metaSvc := metadata.NewService(store)
	scraper := library.NewScraper(store, metaSvc)
	srcSvc := source.NewService(store, hub)
	ingSvc := ingest.NewService(store, hub, limiter)
	scraper.SetSidecarReader(ingSvc)

	srvHandler := api.NewServer(store, metaSvc, scraper, hub, platSvc, accSvc, srcSvc, ingSvc)
	srvHandler.SetWebDir(*webDir)
	srvHandler.SetAllowInsecureCredentials(*allowInsecureCredentials)
	if err := srvHandler.SetTrustedProxies(*trustedProxies); err != nil {
		log.Fatalf("invalid -trusted-proxies: %v", err)
	}
	if srvHandler.Idf != nil {
		srvHandler.Idf.Start()
		defer srvHandler.Idf.Stop()
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen %s: %v", *addr, err)
	}

	// WriteTimeout must remain 0 so SSE streams stay alive.
	httpSrv := &http.Server{
		Handler:           srvHandler.Mux,
		ReadHeaderTimeout: 15 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var bgWG sync.WaitGroup
	bgWG.Add(1)
	go func() {
		defer bgWG.Done()
		runPeriodicCleanup(ctx, accSvc, platSvc, srcSvc, ingSvc)
	}()

	fmt.Printf("LISTENING http://%s\n", ln.Addr().String())
	_ = os.Stdout.Sync()

	cfg := store.GetServerSettings()
	logPath, _ := applog.FileInfo()
	proxyDesc := "(直连)"
	if strings.TrimSpace(cfg.MetadataProxy) != "" {
		proxyDesc = applog.RedactURL(cfg.MetadataProxy)
	}
	applog.Infof("system", "服务启动完成: listen=http://%s data_dir=%s log_file=%s level=%s", ln.Addr().String(), *dataDir, logPath, *logLevel)
	applog.Infof("system", "环境参数: tmdb_key=%v tmdb_base=%s bangumi=%v proxy=%s", strings.TrimSpace(cfg.TmdbAPIKey) != "", cfg.TmdbAPIBase, cfg.BangumiEnabled, proxyDesc)

	go func() {
		<-ctx.Done()
		applog.Infof("system", "收到退出信号，正在优雅关闭服务...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
	}()

	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		applog.Errorf("system", "HTTP 服务异常退出: %v", err)
		log.Fatalf("serve error: %v", err)
	}
	stop()
	bgWG.Wait()
	applog.Infof("system", "服务已关闭")
}

func runPeriodicCleanup(ctx context.Context, accSvc *account.Service, platSvc *platform.Service, srcSvc *source.Service, ingSvc *ingest.Service) {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := accSvc.CleanupExpired(); err != nil {
				applog.Warnf("cleanup", "account cleanup error: %v", err)
			}
			if err := platSvc.CleanupExpiredSessions(); err != nil {
				applog.Warnf("cleanup", "admin session cleanup error: %v", err)
			}
			if purged, err := platSvc.PurgeExpiredDeletedAccounts(); err != nil {
				applog.Warnf("cleanup", "purge expired accounts error: %v", err)
			} else if purged > 0 {
				applog.Infof("cleanup", "purged %d expired deleted accounts", purged)
			}
			if purgedSrc, err := srcSvc.PurgeExpiredDeletedSources(); err != nil {
				applog.Warnf("cleanup", "purge expired sources error: %v", err)
			} else if purgedSrc > 0 {
				applog.Infof("cleanup", "purged %d expired deleted sources", purgedSrc)
			}
			if stale, err := ingSvc.MarkStaleSessions(); err != nil {
				applog.Warnf("cleanup", "mark stale scan sessions error: %v", err)
			} else if stale > 0 {
				applog.Infof("cleanup", "marked %d stale scan sessions", stale)
			}
		}
	}
}

func runAdminResetPasswordCLI(args []string) {
	fs := flag.NewFlagSet("admin reset-password", flag.ExitOnError)
	dataDir := fs.String("data-dir", envOr("LIBRARY_DATA_DIR", "./library_data"), "Directory for SQLite database and master.key")
	username := fs.String("username", "admin", "Platform admin username")
	password := fs.String("password", "", "New platform admin password (minimum 8 characters)")
	_ = fs.Parse(args)

	if *password == "" {
		log.Fatalf("admin reset-password requires -password")
	}

	v, err := vault.Open(*dataDir, os.Getenv("LIBRARY_MASTER_KEY"))
	if err != nil {
		log.Fatalf("open vault: %v", err)
	}
	store, err := db.Open(*dataDir, v)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer func() {
		if err := store.Close(); err != nil {
			log.Printf("close db: %v", err)
		}
	}()

	platSvc, err := platform.NewService(store, nil, "")
	if err != nil {
		log.Fatalf("init platform service: %v", err)
	}
	if err := platSvc.ResetAdminPasswordCLI(*username, *password); err != nil {
		log.Fatalf("reset admin password: %v", err)
	}
	fmt.Printf("Password reset completed for platform admin %q.\n", strings.TrimSpace(*username))
}

func envOr(k, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return fallback
}

func envBool(k string, fallback bool) bool {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return fallback
}
