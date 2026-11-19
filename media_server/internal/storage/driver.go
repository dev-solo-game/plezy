package storage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type ErrorKind string

const (
	ErrKindNotFound     ErrorKind = "not_found"
	ErrKindUnauthorized ErrorKind = "unauthorized"
	ErrKindRateLimited  ErrorKind = "rate_limited"
	ErrKindNetwork      ErrorKind = "network"
	ErrKindUnsupported  ErrorKind = "unsupported"
	ErrKindOther        ErrorKind = "other"
)

type StorageError struct {
	Kind    ErrorKind
	Message string
	Cause   error
}

func (e *StorageError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("storage(%s): %s: %v", e.Kind, e.Message, e.Cause)
	}
	return fmt.Sprintf("storage(%s): %s", e.Kind, e.Message)
}

func (e *StorageError) Unwrap() error {
	return e.Cause
}

func NewError(kind ErrorKind, msg string, cause ...error) *StorageError {
	var c error
	if len(cause) > 0 {
		c = cause[0]
	}
	return &StorageError{Kind: kind, Message: msg, Cause: c}
}

func IsKind(err error, kind ErrorKind) bool {
	var se *StorageError
	return errors.As(err, &se) && se.Kind == kind
}

type Entry struct {
	Path       string `json:"path"`
	Name       string `json:"name"`
	IsDir      bool   `json:"is_dir"`
	Size       *int64 `json:"size,omitempty"`
	CreatedAt  *int64 `json:"created_at_ms,omitempty"`
	ModifiedAt *int64 `json:"modified_at_ms,omitempty"`
	ID         string `json:"id,omitempty"` // Quark fid
	Hash       string `json:"hash,omitempty"`
}

type RangeResult struct {
	Body      io.ReadCloser
	TotalSize int64
	Start     int64
	End       int64 // inclusive; -1 when file is empty
}

type StreamVariant struct {
	ID      string            `json:"id"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	Width   int               `json:"width,omitempty"`
	Height  int               `json:"height,omitempty"`
	IsHLS   bool              `json:"is_hls"`
}

type DirectLink struct {
	URL       string            `json:"url"`
	Headers   map[string]string `json:"headers,omitempty"`
	ExpiresAt int64             `json:"expires_at_ms,omitempty"`
}

type Driver interface {
	Kind() string
	Check(ctx context.Context) error
	List(ctx context.Context, path string, parent *Entry) ([]Entry, error)
	Stat(ctx context.Context, path string) (Entry, error)
	OpenRange(ctx context.Context, entry Entry, start int64, end *int64, forceRefresh bool) (RangeResult, error)
	Close() error
}

type DirectLinkSource interface {
	ResolveDirectLink(ctx context.Context, entry Entry, forceRefresh bool) (DirectLink, error)
}

type VariantSource interface {
	StreamVariants(ctx context.Context, entry Entry, forceRefresh bool) ([]StreamVariant, error)
	FetchVariantURL(ctx context.Context, targetURL string, headers map[string]string) (*http.Response, error)
}

type IncrementalUpdate struct {
	Entry     Entry
	ParentID  string
	UpdatedAt int64
}

type IncrementalSource interface {
	SupportsIncremental() bool
	RootFolderID() string
	SearchUpdatedPage(ctx context.Context, page, size int) ([]IncrementalUpdate, error)
	FolderAncestry(ctx context.Context, folderID string) ([]struct{ ID, Name string }, error)
}

type MountConfig struct {
	ID      string
	Kind    string
	Config  map[string]any
	Secrets map[string]string
}

func CfgString(cfg map[string]any, key string) string {
	if cfg == nil {
		return ""
	}
	v, ok := cfg[key]
	if !ok || v == nil {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(s)
}

func CfgInt(cfg map[string]any, key string, fallback int) int {
	if cfg == nil {
		return fallback
	}
	v, ok := cfg[key]
	if !ok || v == nil {
		return fallback
	}
	switch x := v.(type) {
	case int:
		return x
	case int64:
		return int(x)
	case float64:
		return int(x)
	default:
		return fallback
	}
}

func CfgBool(cfg map[string]any, key string, fallback bool) bool {
	if cfg == nil {
		return fallback
	}
	v, ok := cfg[key]
	if !ok || v == nil {
		return fallback
	}
	b, ok := v.(bool)
	if !ok {
		return fallback
	}
	return b
}

// DriverFactory creates a storage Driver from a MountConfig and an optional
// secret-update callback (used for Quark Web cookie rotation).
type DriverFactory func(cfg MountConfig, onSecretUpdate func(key, val string)) (Driver, error)

const (
	previewDriverTTL     = 10 * time.Minute
	maxPreviewDrivers    = 8
)

// Manager caches live Driver instances per mount and rebuilds them on edit.
type Manager struct {
	mu           sync.Mutex
	drivers      map[string]cachedDriver
	previewMu    sync.Mutex
	previews     map[string]cachedDriver
	factories    map[string]DriverFactory
	allowedRoots []string
	onSecretSave func(mountID, key, val string)
}

type cachedDriver struct {
	driver    Driver
	createdAt time.Time
}

func NewManager(allowedLocalRoots []string, onSecretSave func(mountID, key, val string)) *Manager {
	m := &Manager{
		drivers:      make(map[string]cachedDriver),
		previews:     make(map[string]cachedDriver),
		factories:    make(map[string]DriverFactory),
		allowedRoots: allowedLocalRoots,
		onSecretSave: onSecretSave,
	}
	m.RegisterFactory("local", func(cfg MountConfig, _ func(string, string)) (Driver, error) {
		return NewLocalDriver(CfgString(cfg.Config, "rootPath"), m.allowedRoots)
	})
	m.RegisterFactory("webdav", func(cfg MountConfig, _ func(string, string)) (Driver, error) {
		return NewWebDavDriver(cfg)
	})
	m.RegisterFactory("smb", func(cfg MountConfig, _ func(string, string)) (Driver, error) {
		return NewSmbDriver(cfg)
	})
	return m
}

func (m *Manager) RegisterFactory(kind string, factory DriverFactory) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.factories[strings.ToLower(kind)] = factory
}

func (m *Manager) AllowedLocalRoots() []string {
	return m.allowedRoots
}

func (m *Manager) DriverFor(cfg MountConfig) (Driver, error) {
	m.mu.Lock()
	if cached, ok := m.drivers[cfg.ID]; ok {
		m.mu.Unlock()
		return cached.driver, nil
	}
	factory, ok := m.factories[strings.ToLower(cfg.Kind)]
	m.mu.Unlock()
	if !ok {
		return nil, NewError(ErrKindUnsupported, "unsupported storage kind: "+cfg.Kind)
	}

	cb := func(k, v string) {
		if m.onSecretSave != nil {
			m.onSecretSave(cfg.ID, k, v)
		}
	}
	drv, err := factory(cfg, cb)
	if err != nil {
		return nil, err
	}

	m.mu.Lock()
	if existing, ok := m.drivers[cfg.ID]; ok {
		m.mu.Unlock()
		_ = drv.Close()
		return existing.driver, nil
	}
	m.drivers[cfg.ID] = cachedDriver{driver: drv, createdAt: time.Now()}
	m.mu.Unlock()
	return drv, nil
}

func (m *Manager) TestMount(ctx context.Context, cfg MountConfig) error {
	m.mu.Lock()
	factory, ok := m.factories[strings.ToLower(cfg.Kind)]
	m.mu.Unlock()
	if !ok {
		return NewError(ErrKindUnsupported, "unsupported storage kind: "+cfg.Kind)
	}
	drv, err := factory(cfg, nil)
	if err != nil {
		return err
	}
	defer drv.Close()
	return drv.Check(ctx)
}

func (m *Manager) Invalidate(mountID string) {
	m.mu.Lock()
	cached, ok := m.drivers[mountID]
	if ok {
		delete(m.drivers, mountID)
	}
	m.mu.Unlock()
	if ok && cached.driver != nil {
		_ = cached.driver.Close()
	}
}

func previewCacheKey(cfg MountConfig) string {
	payload, _ := json.Marshal(struct {
		Kind    string            `json:"k"`
		Config  map[string]any    `json:"c"`
		Secrets map[string]string `json:"s"`
	}{
		Kind:    strings.ToLower(strings.TrimSpace(cfg.Kind)),
		Config:  cfg.Config,
		Secrets: cfg.Secrets,
	})
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}

// PreviewDriver returns a short-lived cached Driver keyed by mount parameters so
// directory-picker navigation reuses Quark folder/token caches and rate limiters.
func (m *Manager) PreviewDriver(cfg MountConfig) (Driver, error) {
	key := previewCacheKey(cfg)
	now := time.Now()
	var toClose []Driver

	m.previewMu.Lock()
	for k, c := range m.previews {
		if now.Sub(c.createdAt) > previewDriverTTL {
			delete(m.previews, k)
			if c.driver != nil {
				toClose = append(toClose, c.driver)
			}
		}
	}
	if cached, ok := m.previews[key]; ok {
		cached.createdAt = now
		m.previews[key] = cached
		m.previewMu.Unlock()
		for _, d := range toClose {
			_ = d.Close()
		}
		return cached.driver, nil
	}
	m.previewMu.Unlock()
	for _, d := range toClose {
		_ = d.Close()
	}

	m.mu.Lock()
	factory, ok := m.factories[strings.ToLower(cfg.Kind)]
	m.mu.Unlock()
	if !ok {
		return nil, NewError(ErrKindUnsupported, "unsupported storage kind: "+cfg.Kind)
	}

	drv, err := factory(cfg, nil)
	if err != nil {
		return nil, err
	}

	var evicted Driver
	m.previewMu.Lock()
	if existing, ok := m.previews[key]; ok {
		m.previewMu.Unlock()
		_ = drv.Close()
		return existing.driver, nil
	}
	if len(m.previews) >= maxPreviewDrivers {
		var oldestKey string
		var oldestTime time.Time
		for k, c := range m.previews {
			if oldestKey == "" || c.createdAt.Before(oldestTime) {
				oldestKey = k
				oldestTime = c.createdAt
			}
		}
		if oldestKey != "" {
			evicted = m.previews[oldestKey].driver
			delete(m.previews, oldestKey)
		}
	}
	m.previews[key] = cachedDriver{driver: drv, createdAt: time.Now()}
	m.previewMu.Unlock()
	if evicted != nil {
		_ = evicted.Close()
	}
	return drv, nil
}

func (m *Manager) CloseAll() {
	m.mu.Lock()
	all := m.drivers
	m.drivers = make(map[string]cachedDriver)
	m.mu.Unlock()
	for _, c := range all {
		if c.driver != nil {
			_ = c.driver.Close()
		}
	}

	m.previewMu.Lock()
	allPreviews := m.previews
	m.previews = make(map[string]cachedDriver)
	m.previewMu.Unlock()
	for _, c := range allPreviews {
		if c.driver != nil {
			_ = c.driver.Close()
		}
	}
}
