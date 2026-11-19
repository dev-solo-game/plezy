package storage

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalDriverAndHostBrowser(t *testing.T) {
	base := t.TempDir()
	allowed := filepath.Join(base, "media")
	outside := filepath.Join(base, "secret")
	if err := os.MkdirAll(filepath.Join(allowed, "Movies"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := []byte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	movieFile := filepath.Join(allowed, "Movies", "test.mp4")
	if err := os.WriteFile(movieFile, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "passwd.txt"), []byte("nope"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Allowed roots enforcement
	if _, err := NewLocalDriver(outside, []string{allowed}); !IsKind(err, ErrKindUnauthorized) {
		t.Fatalf("expected ErrKindUnauthorized for outside mount, got %v", err)
	}
	if _, err := BrowseHostDirectories(outside, []string{allowed}); !IsKind(err, ErrKindUnauthorized) {
		t.Fatalf("expected ErrKindUnauthorized browsing outside allowed roots, got %v", err)
	}

	drv, err := NewLocalDriver(allowed, []string{allowed})
	if err != nil {
		t.Fatalf("new local driver: %v", err)
	}
	defer drv.Close()

	ctx := context.Background()
	if err := drv.Check(ctx); err != nil {
		t.Fatalf("check failed: %v", err)
	}

	entries, err := drv.List(ctx, "/Movies", nil)
	if err != nil || len(entries) != 1 || entries[0].Name != "test.mp4" {
		t.Fatalf("unexpected list result: %+v err=%v", entries, err)
	}

	// Path traversal collapses to root and cannot reach outside files
	if _, err := drv.Stat(ctx, "/../../secret/passwd.txt"); !IsKind(err, ErrKindNotFound) {
		t.Fatalf("traversal must not escape mount root, got %v", err)
	}

	end := int64(15)
	rr, err := drv.OpenRange(ctx, entries[0], 10, &end, false)
	if err != nil {
		t.Fatalf("open range: %v", err)
	}
	defer rr.Body.Close()
	got, err := io.ReadAll(rr.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "ABCDEF" || rr.TotalSize != int64(len(payload)) {
		t.Fatalf("got %q total=%d want ABCDEF total=%d", string(got), rr.TotalSize, len(payload))
	}
}

func TestWebDavDriverListRangeAndRedirectCredentialIsolation(t *testing.T) {
	videoBytes := []byte("HELLO_WEBDAV_RANGE_STREAM_CONTENT")
	var cdnGotAuth string
	cdnSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cdnGotAuth = r.Header.Get("Authorization")
		rangeHdr := r.Header.Get("Range")
		if rangeHdr == "bytes=6-11" {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes 6-11/%d", len(videoBytes)))
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(videoBytes[6:12])
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(videoBytes)
	}))
	defer cdnSrv.Close()

	var davSrv *httptest.Server
	davSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != "alice" || pass != "s3cr3t" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.Method == "PROPFIND" {
			w.WriteHeader(http.StatusMultiStatus)
			_, _ = fmt.Fprintf(w, `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:status>HTTP/1.1 200 OK</D:status><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/movie.mkv</D:href>
    <D:propstat><D:status>HTTP/1.1 200 OK</D:status><D:prop><D:resourcetype/><D:getcontentlength>%d</D:getcontentlength></D:prop></D:propstat>
  </D:response>
</D:multistatus>`, len(videoBytes))
			return
		}
		if r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/movie.mkv") {
			http.Redirect(w, r, cdnSrv.URL+"/cdn/movie.mkv", http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer davSrv.Close()

	drv, err := NewWebDavDriver(MountConfig{
		ID:      "m1",
		Kind:    "webdav",
		Config:  map[string]any{"baseUrl": davSrv.URL + "/dav", "username": "alice"},
		Secrets: map[string]string{"password": "s3cr3t"},
	})
	if err != nil {
		t.Fatalf("new webdav driver: %v", err)
	}
	defer drv.Close()

	ctx := context.Background()
	if err := drv.Check(ctx); err != nil {
		t.Fatalf("check failed: %v", err)
	}
	list, err := drv.List(ctx, "/", nil)
	if err != nil || len(list) != 1 || list[0].Name != "movie.mkv" {
		t.Fatalf("unexpected webdav list: %+v err=%v", list, err)
	}

	end := int64(11)
	rr, err := drv.OpenRange(ctx, list[0], 6, &end, false)
	if err != nil {
		t.Fatalf("open range: %v", err)
	}
	defer rr.Body.Close()
	got, err := io.ReadAll(rr.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, []byte("WEBDAV")) {
		t.Fatalf("got %q want WEBDAV", string(got))
	}
	if cdnGotAuth != "" {
		t.Fatalf("Authorization header leaked across cross-host redirect: %q", cdnGotAuth)
	}
}

func TestPathFilters(t *testing.T) {
	inc, exc := PathFilterFromConfig(map[string]any{
		"includePaths": []any{"/Movies", "/Anime/2026"},
		"excludePaths": []any{"/Movies/Temp"},
	})
	if !CanTraverseDir("/", inc, exc) {
		t.Fatal("root must always be traversable")
	}
	if !CanTraverseDir("/Anime", inc, exc) {
		t.Fatal("ancestor of include path must be traversable")
	}
	if CanTraverseDir("/Movies/Temp", inc, exc) {
		t.Fatal("excluded folder must not be traversable")
	}
	if CanTraverseDir("/Other", inc, exc) {
		t.Fatal("unrelated folder should not be traversable")
	}
	if !IsFileAllowed("/Movies/Dune.mkv", inc, exc) {
		t.Fatal("file under include path should be allowed")
	}
	if IsFileAllowed("/Movies/Temp/sample.mkv", inc, exc) {
		t.Fatal("file under excluded path should not be allowed")
	}
}
