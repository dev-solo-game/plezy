package stream

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"

	"plezy/media_server/internal/storage"
)

func TestServeDriverRange200_206_416_AndHead(t *testing.T) {
	dir := t.TempDir()
	content := []byte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	if err := os.WriteFile(filepath.Join(dir, "video.mp4"), content, 0o644); err != nil {
		t.Fatal(err)
	}
	drv, err := storage.NewLocalDriver(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer drv.Close()
	entry, err := drv.Stat(context.Background(), "/video.mp4")
	if err != nil {
		t.Fatal(err)
	}

	// 200 full GET
	rec := httptest.NewRecorder()
	ServeDriverRange(rec, httptest.NewRequest(http.MethodGet, "/file/1", nil), drv, entry)
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), content) {
		t.Fatalf("200 mismatch: code=%d body=%q", rec.Code, rec.Body.String())
	}

	// 206 partial GET
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/1", nil)
	req.Header.Set("Range", "bytes=10-19")
	ServeDriverRange(rec, req, drv, entry)
	if rec.Code != http.StatusPartialContent || rec.Body.String() != "ABCDEFGHIJ" {
		t.Fatalf("206 mismatch: code=%d body=%q", rec.Code, rec.Body.String())
	}
	if cr := rec.Header().Get("Content-Range"); cr != "bytes 10-19/36" {
		t.Fatalf("unexpected Content-Range: %q", cr)
	}

	// Suffix range
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/file/1", nil)
	req.Header.Set("Range", "bytes=-4")
	ServeDriverRange(rec, req, drv, entry)
	if rec.Code != http.StatusPartialContent || rec.Body.String() != "WXYZ" {
		t.Fatalf("suffix range mismatch: code=%d body=%q", rec.Code, rec.Body.String())
	}

	// 416 unsatisfiable range
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/file/1", nil)
	req.Header.Set("Range", "bytes=999-1000")
	ServeDriverRange(rec, req, drv, entry)
	if rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("expected 416, got %d", rec.Code)
	}

	// HEAD
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodHead, "/file/1", nil)
	req.Header.Set("Range", "bytes=0-9")
	ServeDriverRange(rec, req, drv, entry)
	if rec.Code != http.StatusPartialContent || rec.Body.Len() != 0 || rec.Header().Get("Content-Length") != "10" {
		t.Fatalf("HEAD mismatch: code=%d len=%d cl=%s", rec.Code, rec.Body.Len(), rec.Header().Get("Content-Length"))
	}
}

type mockVariantSource struct {
	variants []storage.StreamVariant
	srv      *httptest.Server
}

func (m *mockVariantSource) StreamVariants(ctx context.Context, entry storage.Entry, forceRefresh bool) ([]storage.StreamVariant, error) {
	return m.variants, nil
}

func (m *mockVariantSource) FetchVariantURL(ctx context.Context, targetURL string, headers map[string]string) (*http.Response, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return http.DefaultClient.Do(req)
}

func TestHLSPlaylistRewriteAndSignedSegmentProxy(t *testing.T) {
	var gotUpstreamCookie string
	cdnSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUpstreamCookie = r.Header.Get("Cookie")
		switch r.URL.Path {
		case "/hls/master.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nseg001.ts?auth=abc\n")
		case "/hls/seg001.ts":
			w.Header().Set("Content-Type", "video/mp2t")
			_, _ = io.WriteString(w, "TS_PACKET_DATA")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer cdnSrv.Close()

	proxy := NewHLSProxy([]byte("01234567890123456789012345678901"))
	vs := &mockVariantSource{
		srv: cdnSrv,
		variants: []storage.StreamVariant{
			{
				ID:      "4k",
				URL:     cdnSrv.URL + "/hls/master.m3u8",
				Headers: map[string]string{"Cookie": "Video-Auth=secret_va"},
				IsHLS:   true,
			},
		},
	}
	entry := storage.Entry{ID: "fid1", Path: "/demo.mkv", Name: "demo.mkv"}

	rec := httptest.NewRecorder()
	proxy.ServeVariant(rec, httptest.NewRequest(http.MethodGet, "/variant", nil), "m1", vs, entry, "4k", "st1")
	if rec.Code != http.StatusOK {
		t.Fatalf("variant failed: %d %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, `#EXT-X-MAP:URI="/api/v1/stream/hls-seg?`) {
		t.Fatalf("EXT-X-MAP URI not rewritten: %s", body)
	}

	// Extract segment proxy URL and fetch it
	var segURL string
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "/api/v1/stream/hls-seg?") {
			segURL = line
			break
		}
	}
	if segURL == "" {
		t.Fatalf("segment line missing in rewritten m3u8: %s", body)
	}
	segRec := httptest.NewRecorder()
	proxy.ServeSegment(segRec, httptest.NewRequest(http.MethodGet, segURL, nil), vs, entry, "st1")
	if segRec.Code != http.StatusOK || segRec.Body.String() != "TS_PACKET_DATA" {
		t.Fatalf("segment proxy failed: code=%d body=%q", segRec.Code, segRec.Body.String())
	}
	if gotUpstreamCookie != "Video-Auth=secret_va" {
		t.Fatalf("upstream did not receive Quark cookie: %q", gotUpstreamCookie)
	}

	// Tampered signature must be rejected (anti-SSRF)
	tampered := strings.Replace(segURL, "sig=", "sig=tamper", 1)
	tamperRec := httptest.NewRecorder()
	proxy.ServeSegment(tamperRec, httptest.NewRequest(http.MethodGet, tampered, nil), vs, entry, "st1")
	if tamperRec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for tampered segment URL, got %d", tamperRec.Code)
	}
}

func TestSubtitleEncodingAndVTTConversion(t *testing.T) {
	gbkBytes, err := simplifiedchinese.GB18030.NewEncoder().Bytes([]byte("1\n00:00:01,500 --> 00:00:04,000\n你好世界\n"))
	if err != nil {
		t.Fatal(err)
	}
	utf8Text := DecodeSubtitleToUTF8(gbkBytes)
	vtt := ConvertSubtitleToVTT(utf8Text, "srt")
	if !strings.HasPrefix(vtt, "WEBVTT") || !strings.Contains(vtt, "00:00:01.500 --> 00:00:04.000") || !strings.Contains(vtt, "你好世界") {
		t.Fatalf("unexpected srt->vtt result: %s", vtt)
	}

	assSample := `[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:05.12,0:00:08.00,Default,,0,0,0,,{\pos(320,240)}第一行\N第二行`
	assVtt := ConvertSubtitleToVTT(assSample, "ass")
	if !strings.Contains(assVtt, "00:00:05.120 --> 00:00:08.000\n第一行\n第二行") {
		t.Fatalf("unexpected ass->vtt result: %s", assVtt)
	}
}
