package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"plezy/media_library/internal/vault"

	_ "modernc.org/sqlite"
)

type Store struct {
	db      *sql.DB
	rdb     *sql.DB
	dbPath  string
	dataDir string
	vault   *vault.Vault
	metaMu  sync.Mutex

	// In-memory cache of server_settings (see store_settings.go).
	settingsMu       sync.RWMutex
	settingsCache    map[string]string
	settingsSnapshot *ServerSettings
	settingsGen      uint64
}

func Open(dataDir string, v *vault.Vault) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	dbPath := filepath.Join(dataDir, "library.db")
	sqlDB, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)

	s := &Store{
		db:      sqlDB,
		dbPath:  dbPath,
		dataDir: dataDir,
		vault:   v,
	}
	if err := s.initSchema(); err != nil {
		_ = sqlDB.Close()
		return nil, err
	}

	// Separate read-only pool. The writer connection above stays single (SQLite
	// allows one writer), but in WAL mode readers never block on it.
	readDB, err := sql.Open("sqlite", dbPath+"?_pragma=busy_timeout(5000)&_pragma=query_only(1)&_pragma=foreign_keys(ON)")
	if err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("open sqlite read pool: %w", err)
	}
	readDB.SetMaxOpenConns(readPoolSize)
	readDB.SetMaxIdleConns(readPoolSize)
	readDB.SetConnMaxIdleTime(5 * time.Minute)
	if err := readDB.Ping(); err != nil {
		_ = readDB.Close()
		_ = sqlDB.Close()
		return nil, fmt.Errorf("open sqlite read pool: %w", err)
	}
	s.rdb = readDB
	return s, nil
}

// readPoolSize bounds concurrent read connections.
const readPoolSize = 6

func (s *Store) Close() error {
	if s.rdb != nil {
		_ = s.rdb.Close()
	}
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// DB returns the single writer connection. Use it for writes and for reads that
// must observe an in-progress write sequence.
func (s *Store) DB() *sql.DB {
	return s.db
}

// ReadDB returns the read-only connection pool for independent queries.
func (s *Store) ReadDB() *sql.DB {
	if s.rdb != nil {
		return s.rdb
	}
	return s.db
}

func (s *Store) DataDir() string {
	return s.dataDir
}

func (s *Store) Vault() *vault.Vault {
	return s.vault
}

func (s *Store) NowMs() int64 {
	return time.Now().UnixMilli()
}

func (s *Store) initSchema() error {
	pragmas := []string{
		`PRAGMA journal_mode = WAL`,
		`PRAGMA busy_timeout = 5000`,
		`PRAGMA synchronous = NORMAL`,
		`PRAGMA foreign_keys = ON`,
	}
	for _, p := range pragmas {
		if _, err := s.db.Exec(p); err != nil {
			return fmt.Errorf("exec %s: %w", p, err)
		}
	}

	if err := s.runMigrations(); err != nil {
		return err
	}
	s.Optimize()
	return nil
}

// Optimize refreshes SQLite planner statistics (bounded cost).
func (s *Store) Optimize() {
	_, _ = s.db.Exec(`PRAGMA analysis_limit = 1000`)
	_, _ = s.db.Exec(`PRAGMA optimize = 0x10002`)
}

func SortTitleFor(title string) string {
	lower := strings.ToLower(strings.TrimSpace(title))
	for _, prefix := range []string{"the ", "a ", "an "} {
		if strings.HasPrefix(lower, prefix) && len(lower) > len(prefix) {
			return strings.TrimSpace(lower[len(prefix):])
		}
	}
	return lower
}
