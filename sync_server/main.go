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
)

func main() {
	addr := flag.String("addr", ":8088", "HTTP listen address")
	dataDir := flag.String("data-dir", "./sync_data", "Directory for SQLite database")
	adminUser := flag.String("admin-user", os.Getenv("SYNC_ADMIN_USER"), "Initial administrator username (defaults to first registered user)")
	allowRegister := flag.String("allow-register", os.Getenv("SYNC_ALLOW_REGISTER"), "Override allow_registration ('true' or 'false'; defaults to stored setting)")
	tmdbApiKey := flag.String("tmdb-api-key", os.Getenv("SYNC_TMDB_API_KEY"), "Default TMDB v3 API key or v4 read token")
	tmdbApiBase := flag.String("tmdb-api-base", os.Getenv("SYNC_TMDB_API_BASE"), "Default TMDB API base URL")
	tmdbImageBase := flag.String("tmdb-image-base", os.Getenv("SYNC_TMDB_IMAGE_BASE"), "Default TMDB image base URL")
	metadataProxy := flag.String("metadata-proxy", os.Getenv("SYNC_METADATA_PROXY"), "HTTP proxy URL (or host:port) for upstream metadata lookups")
	bangumiEnabled := flag.String("bangumi-enabled", os.Getenv("SYNC_BANGUMI_ENABLED"), "Override bangumi_enabled ('true' or 'false'; defaults to stored setting)")
	allowPublicMeta := flag.String("allow-public-metadata", os.Getenv("SYNC_ALLOW_PUBLIC_METADATA"), "Override allow_public_metadata ('true' or 'false'; defaults to stored setting)")
	bangumiApiBase := flag.String("bangumi-api-base", os.Getenv("SYNC_BANGUMI_API_BASE"), "Override Bangumi API base URL")
	gcInterval := flag.Duration("gc-interval", 6*time.Hour, "Periodic tombstone and op compaction interval")
	flag.Parse()

	opts := []StoreOption{WithAdminUsername(*adminUser)}
	if raw := strings.TrimSpace(*allowRegister); raw != "" {
		parsed, err := strconv.ParseBool(raw)
		if err != nil {
			log.Fatalf("invalid -allow-register value %q: %v", raw, err)
		}
		opts = append(opts, WithInitialAllowRegistration(parsed))
	}
	var bangumiPtr *bool
	if raw := strings.TrimSpace(*bangumiEnabled); raw != "" {
		parsed, err := strconv.ParseBool(raw)
		if err != nil {
			log.Fatalf("invalid -bangumi-enabled value %q: %v", raw, err)
		}
		bangumiPtr = &parsed
	}
	var publicMetaPtr *bool
	if raw := strings.TrimSpace(*allowPublicMeta); raw != "" {
		parsed, err := strconv.ParseBool(raw)
		if err != nil {
			log.Fatalf("invalid -allow-public-metadata value %q: %v", raw, err)
		}
		publicMetaPtr = &parsed
	}
	if strings.TrimSpace(*tmdbApiKey) != "" ||
		strings.TrimSpace(*tmdbApiBase) != "" ||
		strings.TrimSpace(*tmdbImageBase) != "" ||
		strings.TrimSpace(*metadataProxy) != "" ||
		bangumiPtr != nil ||
		publicMetaPtr != nil {
		opts = append(opts, WithMetadataDefaults(
			*tmdbApiKey,
			*tmdbApiBase,
			*tmdbImageBase,
			*metadataProxy,
			bangumiPtr,
			publicMetaPtr,
		))
	}
	if strings.TrimSpace(*bangumiApiBase) != "" {
		opts = append(opts, WithBangumiBase(*bangumiApiBase))
	}

	store, err := OpenSyncStore(*dataDir, opts...)
	if err != nil {
		log.Fatalf("open sync store: %v", err)
	}
	defer func() {
		if err := store.Close(); err != nil {
			log.Printf("close store: %v", err)
		}
	}()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen %s: %v", *addr, err)
	}

	srv := &http.Server{
		Handler:           NewSyncMux(store),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		ticker := time.NewTicker(*gcInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := store.RunGC(nowMs()); err != nil {
					log.Printf("gc error: %v", err)
				}
			}
		}
	}()

	// Deterministic line parsed by subprocess integration tests when binding ":0".
	fmt.Printf("LISTENING http://%s\n", ln.Addr().String())
	_ = os.Stdout.Sync()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve error: %v", err)
	}
}
