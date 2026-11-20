package api

import (
	"bytes"
	"compress/gzip"
	"strings"
	"sync"
)

// gzipped SPA assets, keyed by file name. The built bundle is ~1MB of JS that
// compresses to roughly a quarter of that; compressing once and reusing the
// result keeps first-load latency low without per-request CPU cost.
type gzipStaticEntry struct {
	modNano int64
	size    int
	data    []byte
}

var (
	gzipStaticMu    sync.RWMutex
	gzipStaticCache = map[string]gzipStaticEntry{}
)

const gzipStaticMaxEntries = 256

func isCompressibleStatic(contentType string) bool {
	ct := strings.ToLower(contentType)
	return strings.HasPrefix(ct, "text/") ||
		strings.Contains(ct, "javascript") ||
		strings.Contains(ct, "json") ||
		strings.Contains(ct, "svg") ||
		strings.Contains(ct, "wasm")
}

// gzipStaticCached returns the gzip-compressed form of data, reusing a cached copy
// while the file's mtime and size are unchanged. Returns nil if compression does
// not shrink the payload.
func gzipStaticCached(name string, modNano int64, data []byte) []byte {
	gzipStaticMu.RLock()
	e, ok := gzipStaticCache[name]
	gzipStaticMu.RUnlock()
	if ok && e.modNano == modNano && e.size == len(data) {
		return e.data
	}

	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil
	}
	if _, err := zw.Write(data); err != nil {
		return nil
	}
	if err := zw.Close(); err != nil {
		return nil
	}
	out := buf.Bytes()
	if len(out) >= len(data) {
		out = nil
	}

	gzipStaticMu.Lock()
	if len(gzipStaticCache) >= gzipStaticMaxEntries {
		gzipStaticCache = map[string]gzipStaticEntry{}
	}
	gzipStaticCache[name] = gzipStaticEntry{modNano: modNano, size: len(data), data: out}
	gzipStaticMu.Unlock()
	return out
}
