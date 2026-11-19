package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// homeCacheMaxAge caps staleness for writes that bypass both the API mutation
// middleware and the event hub (defensive; normally invalidation is immediate).
const homeCacheMaxAge = 60 * time.Second

// homeCache memoizes the serialized /api/v1/home response. Every client opens
// with this request (the Flutter app and the Web UI), so serving it from memory
// makes repeat entries effectively free. Invalidated by bumping gen.
type homeCache struct {
	gen atomic.Uint64

	mu       sync.Mutex
	builtGen uint64
	builtAt  time.Time
	body     []byte
	etag     string
}

func (c *homeCache) invalidate() { c.gen.Add(1) }

// get returns the cached body/etag, rebuilding it with build() when stale.
// Concurrent callers wait for a single rebuild.
func (c *homeCache) get(build func() (any, error)) ([]byte, string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	gen := c.gen.Load()
	if c.body != nil && c.builtGen == gen && time.Since(c.builtAt) < homeCacheMaxAge {
		return c.body, c.etag, nil
	}
	payload, err := build()
	if err != nil {
		return nil, "", err
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(raw)
	c.body = raw
	c.etag = `"h-` + hex.EncodeToString(sum[:12]) + `"`
	c.builtGen = gen
	c.builtAt = time.Now()
	return c.body, c.etag, nil
}

// withDataInvalidation drops server-side response caches after any request that
// may mutate state.
func (s *Server) withDataInvalidation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r)
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			return
		}
		s.home.invalidate()
	})
}

// watchHubForInvalidation invalidates caches on every hub event (scan, scrape,
// probe and library change notifications all imply data changes).
func (s *Server) watchHubForInvalidation() {
	if s.Hub == nil {
		return
	}
	ch, _ := s.Hub.Subscribe()
	go func() {
		for range ch {
			s.home.invalidate()
		}
	}()
}

func etagMatches(ifNoneMatch, etag string) bool {
	if ifNoneMatch == "" || etag == "" {
		return false
	}
	for _, part := range strings.Split(ifNoneMatch, ",") {
		p := strings.TrimSpace(part)
		p = strings.TrimPrefix(p, "W/")
		if p == etag || p == "*" {
			return true
		}
	}
	return false
}
