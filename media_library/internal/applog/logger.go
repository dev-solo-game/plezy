package applog

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	LevelDebug = 0
	LevelInfo  = 1
	LevelWarn  = 2
	LevelError = 3

	defaultRingCapacity   = 1500
	defaultMaxFileBytes   = 10 * 1024 * 1024
	defaultQueryLimit     = 300
	maxQueryLimit         = 1500
	logFileName           = "server.log"
)

type Entry struct {
	Seq       uint64 `json:"seq"`
	TimeMs    int64  `json:"time_ms"`
	Level     string `json:"level"`
	Component string `json:"component"`
	Message   string `json:"message"`
}

type QueryFilter struct {
	AfterSeq  uint64
	Limit     int
	Level     string
	Component string
	Keyword   string
}

type Logger struct {
	mu           sync.Mutex
	minLevel     int
	alsoStdout   bool
	stdout       io.Writer
	ringCap      int
	ring         []Entry
	head         int
	count        int
	seq          uint64
	logDir       string
	filePath     string
	file         *os.File
	fileSize     int64
	maxFileBytes int64
}

func NewLogger(ringCap int, maxFileBytes int64) *Logger {
	if ringCap <= 0 {
		ringCap = defaultRingCapacity
	}
	if maxFileBytes <= 0 {
		maxFileBytes = defaultMaxFileBytes
	}
	return &Logger{
		minLevel:     LevelInfo,
		stdout:       os.Stdout,
		ringCap:      ringCap,
		ring:         make([]Entry, ringCap),
		maxFileBytes: maxFileBytes,
	}
}

var defaultLogger = NewLogger(defaultRingCapacity, defaultMaxFileBytes)

func ParseLevel(raw string) int {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case "DEBUG", "TRACE":
		return LevelDebug
	case "INFO", "":
		return LevelInfo
	case "WARN", "WARNING":
		return LevelWarn
	case "ERROR", "ERR", "ONLY_ERROR":
		return LevelError
	default:
		return LevelInfo
	}
}

func levelName(lvl int) string {
	switch lvl {
	case LevelDebug:
		return "DEBUG"
	case LevelInfo:
		return "INFO"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	default:
		return "INFO"
	}
}

func Init(logDir string, minLevel string, alsoStdout bool) error {
	return defaultLogger.Init(logDir, minLevel, alsoStdout)
}

func Close() error {
	return defaultLogger.Close()
}

func SetLevel(minLevel string) {
	defaultLogger.SetLevel(minLevel)
}

func Debugf(component, format string, args ...any) {
	defaultLogger.logf(LevelDebug, component, format, args...)
}

func Infof(component, format string, args ...any) {
	defaultLogger.logf(LevelInfo, component, format, args...)
}

func Warnf(component, format string, args ...any) {
	defaultLogger.logf(LevelWarn, component, format, args...)
}

func Errorf(component, format string, args ...any) {
	defaultLogger.logf(LevelError, component, format, args...)
}

func Query(filter QueryFilter) ([]Entry, uint64) {
	return defaultLogger.Query(filter)
}

func Clear(truncateFile bool) error {
	return defaultLogger.Clear(truncateFile)
}

func FileInfo() (string, int64) {
	return defaultLogger.FileInfo()
}

func (l *Logger) SetLevel(minLevel string) {
	l.mu.Lock()
	l.minLevel = ParseLevel(minLevel)
	l.mu.Unlock()
}

func (l *Logger) Init(logDir string, minLevel string, alsoStdout bool) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.file != nil {
		_ = l.file.Close()
		l.file = nil
		l.fileSize = 0
	}

	l.minLevel = ParseLevel(minLevel)
	l.alsoStdout = alsoStdout
	l.logDir = strings.TrimSpace(logDir)
	l.filePath = ""

	if l.logDir == "" {
		return nil
	}
	if err := os.MkdirAll(l.logDir, 0o755); err != nil {
		return fmt.Errorf("create log dir %s: %w", l.logDir, err)
	}
	l.filePath = filepath.Join(l.logDir, logFileName)
	return l.openFileLocked(false)
}

func (l *Logger) openFileLocked(truncate bool) error {
	if l.filePath == "" {
		return nil
	}
	flags := os.O_CREATE | os.O_WRONLY
	if truncate {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_APPEND
	}
	f, err := os.OpenFile(l.filePath, flags, 0o644)
	if err != nil {
		return fmt.Errorf("open log file %s: %w", l.filePath, err)
	}
	info, err := f.Stat()
	if err == nil {
		l.fileSize = info.Size()
	} else {
		l.fileSize = 0
	}
	l.file = f
	return nil
}

func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	l.fileSize = 0
	return err
}

func (l *Logger) FileInfo() (string, int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	path := l.filePath
	size := l.fileSize
	if path != "" {
		if st, err := os.Stat(path); err == nil {
			size = st.Size()
			l.fileSize = size
		}
	}
	return path, size
}

func (l *Logger) Clear(truncateFile bool) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.head = 0
	l.count = 0
	if !truncateFile || l.filePath == "" {
		return nil
	}
	if l.file != nil {
		_ = l.file.Close()
		l.file = nil
	}
	_ = os.Remove(l.filePath + ".1")
	_ = os.Remove(l.filePath + ".2")
	return l.openFileLocked(true)
}

func (l *Logger) Debugf(component, format string, args ...any) {
	l.logf(LevelDebug, component, format, args...)
}

func (l *Logger) Infof(component, format string, args ...any) {
	l.logf(LevelInfo, component, format, args...)
}

func (l *Logger) Warnf(component, format string, args ...any) {
	l.logf(LevelWarn, component, format, args...)
}

func (l *Logger) Errorf(component, format string, args ...any) {
	l.logf(LevelError, component, format, args...)
}

func (l *Logger) logf(lvl int, component, format string, args ...any) {
	now := time.Now()
	msg := format
	if len(args) > 0 {
		msg = fmt.Sprintf(format, args...)
	}
	msg = strings.ReplaceAll(msg, "\r\n", "\n")
	msg = strings.TrimRight(msg, "\r\n")
	comp := strings.TrimSpace(component)
	if comp == "" {
		comp = "app"
	}
	lvlStr := levelName(lvl)

	l.mu.Lock()
	defer l.mu.Unlock()

	if lvl < l.minLevel {
		return
	}

	l.seq++
	entry := Entry{
		Seq:       l.seq,
		TimeMs:    now.UnixMilli(),
		Level:     lvlStr,
		Component: comp,
		Message:   msg,
	}

	if l.count < l.ringCap {
		idx := (l.head + l.count) % l.ringCap
		l.ring[idx] = entry
		l.count++
	} else {
		l.ring[l.head] = entry
		l.head = (l.head + 1) % l.ringCap
	}

	line := fmt.Sprintf("%s [%s] [%s] %s\n", now.Format("2006-01-02 15:04:05.000"), lvlStr, comp, msg)
	if l.alsoStdout && l.stdout != nil {
		_, _ = io.WriteString(l.stdout, line)
	}
	if l.file != nil {
		l.writeFileLineLocked(line)
	}
}

func (l *Logger) writeFileLineLocked(line string) {
	n, _ := io.WriteString(l.file, line)
	l.fileSize += int64(n)
	if l.maxFileBytes > 0 && l.fileSize >= l.maxFileBytes {
		_ = l.rotateLocked()
	}
}

func (l *Logger) rotateLocked() error {
	if l.file == nil || l.filePath == "" {
		return nil
	}
	_ = l.file.Close()
	l.file = nil
	l.fileSize = 0

	backup2 := l.filePath + ".2"
	backup1 := l.filePath + ".1"
	_ = os.Remove(backup2)
	if _, err := os.Stat(backup1); err == nil {
		_ = os.Rename(backup1, backup2)
	}
	if _, err := os.Stat(l.filePath); err == nil {
		_ = os.Rename(l.filePath, backup1)
	}
	return l.openFileLocked(false)
}

func (l *Logger) Query(filter QueryFilter) ([]Entry, uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()

	limit := filter.Limit
	if limit <= 0 {
		limit = defaultQueryLimit
	}
	if limit > maxQueryLimit {
		limit = maxQueryLimit
	}

	rawLevel := strings.ToUpper(strings.TrimSpace(filter.Level))
	onlyError := rawLevel == "ONLY_ERROR"
	minLvl := LevelDebug
	if rawLevel != "" && rawLevel != "ALL" {
		minLvl = ParseLevel(rawLevel)
	}

	compFilter := strings.ToLower(strings.TrimSpace(filter.Component))
	if compFilter == "all" {
		compFilter = ""
	}
	kwFilter := strings.ToLower(strings.TrimSpace(filter.Keyword))

	matched := make([]Entry, 0, min(limit, l.count))
	for i := 0; i < l.count; i++ {
		e := l.ring[(l.head+i)%l.ringCap]
		if e.Seq <= filter.AfterSeq {
			continue
		}
		eLvl := ParseLevel(e.Level)
		if onlyError {
			if eLvl != LevelError {
				continue
			}
		} else if eLvl < minLvl {
			continue
		}
		if compFilter != "" && strings.ToLower(e.Component) != compFilter {
			continue
		}
		if kwFilter != "" {
			if !strings.Contains(strings.ToLower(e.Message), kwFilter) &&
				!strings.Contains(strings.ToLower(e.Component), kwFilter) {
				continue
			}
		}
		matched = append(matched, e)
	}

	if len(matched) > limit {
		matched = matched[len(matched)-limit:]
	}
	return matched, l.seq
}

var (
	reURLQuerySecret = regexp.MustCompile(`(?i)([?&])(api_key|apikey|password|passwd|pass|token|access_token|secret|cookie|pin|_sig|st|sign|kps|q|query|title|filename|folder_hint|path)=([^&\s"'\)]+)`)
	reURLUserInfo    = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+):([^/\s@]+)@`)
	reBearerToken    = regexp.MustCompile(`(?i)(bearer\s+)([A-Za-z0-9._\-]+)`)
)

func RedactURL(raw string) string {
	if raw == "" {
		return ""
	}
	out := reURLUserInfo.ReplaceAllString(raw, "$1:***@")
	out = reURLQuerySecret.ReplaceAllString(out, "$1$2=***")
	out = reBearerToken.ReplaceAllString(out, "$1***")
	return out
}

// RedactQuery masks sensitive or user-identifying parameters in a raw URL query string.
func RedactQuery(rawQuery string) string {
	trimmed := strings.TrimPrefix(strings.TrimSpace(rawQuery), "?")
	if trimmed == "" {
		return ""
	}
	return strings.TrimPrefix(RedactURL("?"+trimmed), "?")
}
