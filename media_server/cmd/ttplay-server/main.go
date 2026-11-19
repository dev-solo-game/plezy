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
	"strconv"
	"strings"
	"syscall"
	"time"

	"plezy/media_server/internal/api"
	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/library"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/vault"
)

func splitCSV(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if t := strings.TrimSpace(part); t != "" {
			out = append(out, t)
		}
	}
	return out
}

func main() {
	addr := flag.String("addr", envOr("MEDIA_ADDR", ":8090"), "HTTP listen address")
	dataDir := flag.String("data-dir", envOr("MEDIA_DATA_DIR", "./media_data"), "Directory for SQLite database, master.key and artwork cache")
	adminUser := flag.String("admin-user", envOr("MEDIA_ADMIN_USER", "admin"), "Initial administrator username")
	adminPass := flag.String("admin-password", os.Getenv("MEDIA_ADMIN_PASSWORD"), "Optional initial administrator password (if omitted, configure via Web setup)")
	allowedLocalRoots := flag.String("allowed-local-roots", os.Getenv("MEDIA_ALLOWED_LOCAL_ROOTS"), "Comma-separated whitelist of host directories permitted for local mounts")
	tmdbAPIKey := flag.String("tmdb-api-key", os.Getenv("MEDIA_TMDB_API_KEY"), "Default TMDB v3 API key or v4 bearer token")
	tmdbAPIBase := flag.String("tmdb-api-base", os.Getenv("MEDIA_TMDB_API_BASE"), "Default TMDB API base URL")
	tmdbImageBase := flag.String("tmdb-image-base", os.Getenv("MEDIA_TMDB_IMAGE_BASE"), "Default TMDB image base URL")
	metadataProxy := flag.String("metadata-proxy", os.Getenv("MEDIA_METADATA_PROXY"), "HTTP/SOCKS5 proxy for TMDB/Bangumi and artwork proxy")
	bangumiEnabled := flag.String("bangumi-enabled", os.Getenv("MEDIA_BANGUMI_ENABLED"), "Default bangumi_enabled ('true' or 'false')")
	flag.Parse()

	v, err := vault.Open(*dataDir, os.Getenv("MEDIA_MASTER_KEY"))
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

	authSvc := auth.NewService(store)
	if err := authSvc.EnsureSeedAdmin(*adminUser, *adminPass); err != nil {
		log.Fatalf("seed admin: %v", err)
	}

	hub := events.NewHub()
	stMgr := storage.NewManager(splitCSV(*allowedLocalRoots), func(mountID, key, val string) {
		_ = store.UpdateMountSecretKey(mountID, key, val)
	})
	defer stMgr.CloseAll()

	metaSvc := metadata.NewService(store)
	coord := library.NewCoordinator(store, stMgr, metaSvc, hub)
	coord.Start()
	defer coord.Stop()

	srvHandler := api.NewServer(store, authSvc, stMgr, metaSvc, hub, coord)

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen %s: %v", *addr, err)
	}

	// WriteTimeout must remain 0 so long video Range streams and SSE stay alive.
	httpSrv := &http.Server{
		Handler:           srvHandler.Mux,
		ReadHeaderTimeout: 15 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Printf("LISTENING http://%s\n", ln.Addr().String())
	_ = os.Stdout.Sync()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
	}()

	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve error: %v", err)
	}
}

func envOr(k, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return fallback
}
