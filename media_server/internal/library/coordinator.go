package library

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
)

type Coordinator struct {
	Store   *db.Store
	Storage *storage.Manager
	Meta    *metadata.Service
	Hub     *events.Hub
	Scanner *Scanner
	Scraper *Scraper

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	watchMu  sync.Mutex
	watcher  *fsnotify.Watcher
	watched  map[string]string // os dir -> mountID
	debounce map[string]*time.Timer
}

func NewCoordinator(store *db.Store, st *storage.Manager, meta *metadata.Service, hub *events.Hub) *Coordinator {
	scanner := NewScanner(store, st, hub)
	scraper := NewScraper(store, meta, st, hub)
	return &Coordinator{
		Store:    store,
		Storage:  st,
		Meta:     meta,
		Hub:      hub,
		Scanner:  scanner,
		Scraper:  scraper,
		watched:  make(map[string]string),
		debounce: make(map[string]*time.Timer),
	}
}

func (c *Coordinator) Start() {
	_ = c.Store.ResetStaleRunningScans()
	c.ctx, c.cancel = context.WithCancel(context.Background())

	if w, err := fsnotify.NewWatcher(); err == nil {
		c.watchMu.Lock()
		c.watcher = w
		c.watchMu.Unlock()
		c.RefreshWatchers()
		c.wg.Add(1)
		go c.watchLoop()
	}

	c.wg.Add(1)
	go c.schedulerLoop()
}

func (c *Coordinator) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	c.watchMu.Lock()
	if c.watcher != nil {
		_ = c.watcher.Close()
		c.watcher = nil
	}
	for _, t := range c.debounce {
		t.Stop()
	}
	c.debounce = make(map[string]*time.Timer)
	c.watchMu.Unlock()
	c.wg.Wait()
}

func (c *Coordinator) TriggerMountScanAsync(mountID string, full bool) {
	if c.ctx == nil {
		return
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		res, err := c.Scanner.ScanMount(c.ctx, mountID, full)
		if err != nil || res.Cancelled {
			return
		}
		if res.Videos > 0 || res.AddedPending {
			c.Scanner.ProbePendingFiles(c.ctx, 100)
			_, _ = c.Scraper.ScrapePending(c.ctx, false, false)
		}
	}()
}

func (c *Coordinator) TriggerScanAllAsync(full bool) {
	if c.ctx == nil {
		return
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		mounts, err := c.Store.ListMounts()
		if err != nil {
			return
		}
		anyAdded := false
		for _, m := range mounts {
			if c.ctx.Err() != nil {
				return
			}
			if !m.Enabled {
				continue
			}
			res, err := c.Scanner.ScanMount(c.ctx, m.ID, full)
			if err == nil && !res.Cancelled && (res.Videos > 0 || res.AddedPending) {
				anyAdded = true
			}
		}
		if anyAdded {
			c.Scanner.ProbePendingFiles(c.ctx, 150)
			_, _ = c.Scraper.ScrapePending(c.ctx, false, false)
		}
	}()
}

func (c *Coordinator) TriggerScrapeAsync(retryUnmatched, refreshAll bool) {
	if c.ctx == nil {
		return
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		_, _ = c.Scraper.ScrapePending(c.ctx, retryUnmatched, refreshAll)
	}()
}

func (c *Coordinator) RefreshWatchers() {
	c.watchMu.Lock()
	w := c.watcher
	c.watchMu.Unlock()
	if w == nil {
		return
	}

	cfg := c.Store.GetServerSettings()
	next := make(map[string]string)
	if cfg.WatchLocalFS {
		mounts, err := c.Store.ListMounts()
		if err == nil {
			for _, m := range mounts {
				if !m.Enabled || m.Kind != "local" {
					continue
				}
				rootPath := storage.CfgString(m.Config, "rootPath")
				if rootPath == "" {
					continue
				}
				abs, err := filepath.Abs(rootPath)
				if err != nil {
					continue
				}
				if info, err := os.Stat(abs); err == nil && info.IsDir() {
					next[abs] = m.ID
					// Watch top-level subdirectories too for immediate new episode triggers
					if entries, err := os.ReadDir(abs); err == nil {
						count := 0
						for _, e := range entries {
							if e.IsDir() && !strings.HasPrefix(e.Name(), ".") && count < 100 {
								next[filepath.Join(abs, e.Name())] = m.ID
								count++
							}
						}
					}
				}
			}
		}
	}

	c.watchMu.Lock()
	defer c.watchMu.Unlock()
	if c.watcher == nil {
		return
	}
	for oldDir := range c.watched {
		if _, keep := next[oldDir]; !keep {
			_ = c.watcher.Remove(oldDir)
			delete(c.watched, oldDir)
		}
	}
	for dir, mid := range next {
		if _, exists := c.watched[dir]; !exists {
			if err := c.watcher.Add(dir); err == nil {
				c.watched[dir] = mid
			}
		} else {
			c.watched[dir] = mid
		}
	}
}

func (c *Coordinator) watchLoop() {
	defer c.wg.Done()
	for {
		c.watchMu.Lock()
		w := c.watcher
		c.watchMu.Unlock()
		if w == nil {
			return
		}
		select {
		case <-c.ctx.Done():
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if ev.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Remove|fsnotify.Rename) == 0 {
				continue
			}
			c.scheduleMountRefreshForPath(ev.Name)
		case _, ok := <-w.Errors:
			if !ok {
				return
			}
		}
	}
}

func (c *Coordinator) scheduleMountRefreshForPath(p string) {
	c.watchMu.Lock()
	defer c.watchMu.Unlock()
	var targetMount string
	for dir, mid := range c.watched {
		if p == dir || strings.HasPrefix(p, dir+string(filepath.Separator)) || filepath.Dir(p) == dir {
			targetMount = mid
			break
		}
	}
	if targetMount == "" {
		return
	}
	if old, ok := c.debounce[targetMount]; ok {
		old.Stop()
	}
	mid := targetMount
	c.debounce[mid] = time.AfterFunc(5*time.Second, func() {
		c.TriggerMountScanAsync(mid, false)
	})
}

func (c *Coordinator) schedulerLoop() {
	defer c.wg.Done()
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	lastRun := time.Now()
	for {
		select {
		case <-c.ctx.Done():
			return
		case now := <-ticker.C:
			cfg := c.Store.GetServerSettings()
			if cfg.ScanIntervalMin <= 0 {
				continue
			}
			if now.Sub(lastRun) >= time.Duration(cfg.ScanIntervalMin)*time.Minute {
				lastRun = now
				c.TriggerScanAllAsync(false)
			}
		}
	}
}
