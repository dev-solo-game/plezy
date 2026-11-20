package api

import (
	"bytes"
	"compress/gzip"
	"io"
	"testing"
)

func TestGzipStaticCached(t *testing.T) {
	data := bytes.Repeat([]byte("console.log('ttplay');\n"), 500)
	gz := gzipStaticCached("assets/test.js", 1, data)
	if gz == nil || len(gz) >= len(data) {
		t.Fatalf("expected compressed output, got %d bytes for %d input", len(gz), len(data))
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	plain, err := io.ReadAll(zr)
	if err != nil || !bytes.Equal(plain, data) {
		t.Fatalf("round trip mismatch err=%v", err)
	}
	if again := gzipStaticCached("assets/test.js", 1, data); &again[0] != &gz[0] {
		t.Fatalf("expected cached slice to be reused")
	}
	changed := append(bytes.Repeat([]byte("x"), 10), data...)
	if fresh := gzipStaticCached("assets/test.js", 2, changed); fresh == nil || bytes.Equal(fresh, gz) {
		t.Fatalf("expected recompression after file change")
	}
	if !isCompressibleStatic("application/javascript; charset=utf-8") || isCompressibleStatic("image/png") {
		t.Fatalf("unexpected compressible classification")
	}
}
