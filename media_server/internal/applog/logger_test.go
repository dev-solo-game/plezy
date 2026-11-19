package applog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactURLMasksSecretsAndUserInfo(t *testing.T) {
	in := `Get "https://api.themoviedb.org/3/search/movie?api_key=my_secret_key_123&query=Dune": proxy socks5://alice:superpass@127.0.0.1:7890 failed; Authorization: Bearer eyJhbGciOi.payload.sig`
	out := RedactURL(in)
	if strings.Contains(out, "my_secret_key_123") {
		t.Fatalf("expected api_key to be redacted, got %s", out)
	}
	if strings.Contains(out, "superpass") {
		t.Fatalf("expected proxy password to be redacted, got %s", out)
	}
	if strings.Contains(out, "eyJhbGciOi") {
		t.Fatalf("expected bearer token to be redacted, got %s", out)
	}
	if !strings.Contains(out, "api_key=***") || !strings.Contains(out, "alice:***@127.0.0.1:7890") || !strings.Contains(out, "Bearer ***") {
		t.Fatalf("unexpected redacted format: %s", out)
	}
}

func TestLoggerRingFilterFileAndRotation(t *testing.T) {
	dir := t.TempDir()
	lg := NewLogger(4, 180)
	if err := lg.Init(dir, "debug", false); err != nil {
		t.Fatalf("Init failed: %v", err)
	}
	defer lg.Close()

	lg.Debugf("scraper", "debug line 1")
	lg.Infof("scraper", "match ok Dune")
	lg.Warnf("metadata", "slow upstream timeout")
	lg.Errorf("scraper", "boom item #7")
	lg.Infof("scanner", "scan finished 10 files")

	// Ring capacity is 4, so the oldest entry (seq=1) was evicted.
	all, latest := lg.Query(QueryFilter{Level: "DEBUG"})
	if latest != 5 || len(all) != 4 {
		t.Fatalf("expected latest=5 and len=4, got latest=%d len=%d", latest, len(all))
	}
	if all[0].Seq != 2 {
		t.Fatalf("expected oldest remaining seq=2, got %d", all[0].Seq)
	}

	// Filter by after_seq, component, level, and keyword
	filtered, _ := lg.Query(QueryFilter{AfterSeq: 2, Level: "WARN", Component: "scraper", Keyword: "boom"})
	if len(filtered) != 1 || filtered[0].Level != "ERROR" || !strings.Contains(filtered[0].Message, "#7") {
		t.Fatalf("unexpected filtered result: %+v", filtered)
	}

	// Rotation should have produced server.log.1
	logPath, size := lg.FileInfo()
	if logPath != filepath.Join(dir, "server.log") {
		t.Fatalf("unexpected log path: %s", logPath)
	}
	if _, err := os.Stat(logPath + ".1"); err != nil {
		t.Fatalf("expected rotated log .1 to exist (current size=%d): %v", size, err)
	}

	if err := lg.Clear(true); err != nil {
		t.Fatalf("Clear failed: %v", err)
	}
	afterClear, _ := lg.Query(QueryFilter{})
	if len(afterClear) != 0 {
		t.Fatalf("expected empty ring after Clear, got %d", len(afterClear))
	}
	_, newSize := lg.FileInfo()
	if newSize != 0 {
		t.Fatalf("expected truncated file size 0 after Clear(true), got %d", newSize)
	}
}
