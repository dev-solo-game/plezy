package metadata

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"plezy/media_library/internal/applog"
)

type CachedImage struct {
	Data        []byte
	ContentType string
}

// ResolveRemoteImageURL resolves a TMDB relative path (e.g. "/abc.jpg") or full
// image URL (Bangumi / custom URL) and verifies the host is permitted.
func (s *Service) ResolveRemoteImageURL(raw string, size string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", fmt.Errorf("%w: empty image source", ErrInvalidInput)
	}
	cfg := s.store.GetServerSettings()
	if strings.HasPrefix(trimmed, "/") && !strings.HasPrefix(trimmed, "//") {
		sz := strings.TrimSpace(size)
		if sz == "" {
			sz = "w500"
		}
		if !isSafeTmdbSize(sz) {
			return "", fmt.Errorf("%w: invalid tmdb image size", ErrInvalidInput)
		}
		return strings.TrimRight(cfg.TmdbImageBase, "/") + "/" + sz + trimmed, nil
	}
	u, err := url.Parse(trimmed)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", fmt.Errorf("%w: invalid image url", ErrInvalidInput)
	}
	if !s.isAllowedImageHost(u.Hostname(), cfg.TmdbImageBase) {
		return "", fmt.Errorf("%w: image host %q not in allowlist", ErrInvalidInput, u.Hostname())
	}
	return u.String(), nil
}

func isSafeTmdbSize(sz string) bool {
	if sz == "original" {
		return true
	}
	if len(sz) >= 2 && (sz[0] == 'w' || sz[0] == 'h') {
		for _, ch := range sz[1:] {
			if ch < '0' || ch > '9' {
				return false
			}
		}
		return true
	}
	return false
}

func (s *Service) isAllowedImageHost(host, tmdbImageBase string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	allowed := []string{
		"image.tmdb.org",
		"lain.bgm.tv",
		"bgm.tv",
		"chii.in",
		"doubanio.com",
		"anilist.co",
		"media-amazon.com",
		"imdb.com",
		"thetvdb.com",
	}
	if u, err := url.Parse(tmdbImageBase); err == nil && u.Hostname() != "" {
		allowed = append(allowed, strings.ToLower(u.Hostname()))
	}
	for _, cand := range allowed {
		if h == cand || strings.HasSuffix(h, "."+cand) {
			return true
		}
	}
	return false
}

// FetchRemoteImage fetches and disk-caches a remote poster/backdrop/still/avatar image
// through the configured metadata proxy.
func (s *Service) FetchRemoteImage(ctx context.Context, src, size string) (CachedImage, error) {
	targetURL, err := s.ResolveRemoteImageURL(src, size)
	if err != nil {
		return CachedImage{}, err
	}
	sum := sha256.Sum256([]byte(targetURL))
	hashHex := hex.EncodeToString(sum[:])

	cacheDir := filepath.Join(s.store.DataDir(), "artwork_cache", hashHex[:2])
	dataPath := filepath.Join(cacheDir, hashHex)
	metaPath := dataPath + ".ct"

	if data, err := os.ReadFile(dataPath); err == nil && len(data) > 0 {
		ct := "image/jpeg"
		if rawCT, err := os.ReadFile(metaPath); err == nil && strings.TrimSpace(string(rawCT)) != "" {
			ct = strings.TrimSpace(string(rawCT))
		}
		return CachedImage{Data: data, ContentType: ct}, nil
	}

	val, sfErr := s.flight.Do("img:"+hashHex, func() (any, error) {
		if data, err := os.ReadFile(dataPath); err == nil && len(data) > 0 {
			ct := "image/jpeg"
			if rawCT, err := os.ReadFile(metaPath); err == nil && strings.TrimSpace(string(rawCT)) != "" {
				ct = strings.TrimSpace(string(rawCT))
			}
			return CachedImage{Data: data, ContentType: ct}, nil
		}
		cfg := s.store.GetServerSettings()
		cli, err := s.HTTPClientForProxy(cfg.MetadataProxy)
		if err != nil {
			return nil, err
		}
		redactedURL := applog.RedactURL(targetURL)
		for attempt := 1; attempt <= 2; attempt++ {
			start := time.Now()
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
			if err != nil {
				return nil, err
			}
			req.Header.Set("User-Agent", "ttplay-media-server/1.0")
			if parsedImgURL, pErr := url.Parse(targetURL); pErr == nil {
				h := strings.ToLower(parsedImgURL.Hostname())
				if h == "doubanio.com" || strings.HasSuffix(h, ".doubanio.com") {
					req.Header.Set("Referer", "https://movie.douban.com/")
					req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
				}
			}
			resp, err := cli.Do(req)
			if err != nil {
				elapsedMs := time.Since(start).Milliseconds()
				applog.Warnf("metadata", "拉取图片失败 (第%d次, %dms): %s -> %s", attempt, elapsedMs, redactedURL, applog.RedactURL(err.Error()))
				if attempt == 1 && ctx.Err() == nil {
					select {
					case <-time.After(250 * time.Millisecond):
						continue
					case <-ctx.Done():
						return nil, fmt.Errorf("%w: fetch image failed: %v", ErrUpstream, ctx.Err())
					}
				}
				return nil, fmt.Errorf("%w: fetch image failed: %v", ErrUpstream, err)
			}

			if resp.StatusCode == http.StatusNotFound {
				_ = resp.Body.Close()
				return nil, ErrNotFound
			}
			if resp.StatusCode >= 400 {
				status := resp.StatusCode
				_ = resp.Body.Close()
				elapsedMs := time.Since(start).Milliseconds()
				applog.Warnf("metadata", "图片上游返回 HTTP %d (第%d次, %dms): %s", status, attempt, elapsedMs, redactedURL)
				retryable := status == http.StatusTooManyRequests || status >= 500
				if attempt == 1 && retryable && ctx.Err() == nil {
					select {
					case <-time.After(250 * time.Millisecond):
						continue
					case <-ctx.Done():
						return nil, fmt.Errorf("%w: upstream image returned HTTP %d", ErrUpstream, status)
					}
				}
				return nil, fmt.Errorf("%w: upstream image returned HTTP %d", ErrUpstream, status)
			}

			data, err := io.ReadAll(io.LimitReader(resp.Body, 12*1024*1024))
			ct := resp.Header.Get("Content-Type")
			_ = resp.Body.Close()
			if err != nil {
				elapsedMs := time.Since(start).Milliseconds()
				applog.Warnf("metadata", "读取图片响应失败 (第%d次, %dms): %s -> %v", attempt, elapsedMs, redactedURL, err)
				if attempt == 1 && ctx.Err() == nil {
					select {
					case <-time.After(250 * time.Millisecond):
						continue
					case <-ctx.Done():
						return nil, fmt.Errorf("%w: read image failed: %v", ErrUpstream, ctx.Err())
					}
				}
				return nil, fmt.Errorf("%w: read image failed: %v", ErrUpstream, err)
			}
			if ct == "" {
				ct = http.DetectContentType(data)
			}
			if !strings.HasPrefix(strings.ToLower(ct), "image/") {
				return nil, fmt.Errorf("%w: upstream did not return an image", ErrUpstream)
			}
			if err := os.MkdirAll(cacheDir, 0o755); err == nil {
				_ = os.WriteFile(dataPath, data, 0o644)
				_ = os.WriteFile(metaPath, []byte(ct), 0o644)
			}
			return CachedImage{Data: data, ContentType: ct}, nil
		}
		return nil, fmt.Errorf("%w: fetch image exhausted retries", ErrUpstream)
	})
	if sfErr != nil {
		return CachedImage{}, sfErr
	}
	img, ok := val.(CachedImage)
	if !ok {
		return CachedImage{}, errors.New("unexpected image cache result")
	}
	return img, nil
}
