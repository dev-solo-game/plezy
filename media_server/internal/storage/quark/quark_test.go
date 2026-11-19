package quark

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestWsgDeterministicCryptoAndSign(t *testing.T) {
	w := NewWsg()
	plain := `{"fid":"abc123","resolutions":"4k"}`
	enc, err := w.Encode(plain)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	dec, err := w.DecodeText(enc)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if dec != plain {
		t.Fatalf("got %q want %q", dec, plain)
	}

	sig1 := w.Sign(map[string]string{"b": "2", "a": "1"})
	sig2 := w.Sign(map[string]string{"a": "1", "b": "2"})
	if !strings.HasPrefix(sig1, "35e9") || len(sig1) != 44 || sig1 != sig2 {
		t.Fatalf("unexpected signature: sig1=%q sig2=%q", sig1, sig2)
	}

	if _, err := w.Decode("AAAA"); err == nil {
		t.Fatal("expected error for invalid WSG selector")
	}
}

func TestQuarkDriverListingVariantsRefreshAndCookieRotation(t *testing.T) {
	var linkVersion atomic.Int32
	var rotatedTo string
	videoData := []byte("QUARK_VIDEO_PAYLOAD_BYTES")

	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/1/clouddrive/config":
			http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "rotated_puus_value", Path: "/"})
			_, _ = w.Write([]byte(`{"code":0,"status":200,"data":{}}`))
		case "/1/clouddrive/member":
			_, _ = w.Write([]byte(`{"code":0,"data":{"member_type":"SUPER_VIP","use_capacity":1024,"total_capacity":65536}}`))
		case "/1/clouddrive/file/sort":
			pdir := r.URL.Query().Get("pdir_fid")
			if pdir == "0" {
				_, _ = w.Write([]byte(`{"code":0,"data":{"list":[
					{"fid":"dir1","file_name":"Movies","dir":true,"file":false,"updated_at":1700000000000}
				]},"metadata":{"_total":1}}`))
				return
			}
			_, _ = w.Write([]byte(`{"code":0,"data":{"list":[
				{"fid":"f1","file_name":"Demo.4K.mkv","dir":false,"file":true,"size":25,"updated_at":1700000005000}
			]},"metadata":{"_total":1}}`))
		case "/1/clouddrive/file/search":
			_, _ = w.Write([]byte(`{"code":0,"data":{"list":[
				{"fid":"f1","pdir_fid":"dir1","file_name":"Demo.4K.mkv","dir":false,"file":true,"size":25,"updated_at":1700000005000}
			]}}`))
		case "/1/clouddrive/file/download":
			v := linkVersion.Add(1)
			_, _ = fmt.Fprintf(w, `{"code":0,"data":[{"download_url":"%s/cdn/file?v=%d"}]}`, srv.URL, v)
		case "/1/clouddrive/file/v2/play":
			http.SetCookie(w, &http.Cookie{Name: "Video-Auth", Value: "va_token_123", Path: "/"})
			_, _ = fmt.Fprintf(w, `{"code":0,"data":{"video_list":[
				{"resolution":"high","accessable":true,"video_info":{"url":"%s/cdn/hls/high.m3u8","width":1920,"height":1080,"format":"m3u8"}},
				{"resolution":"4k","accessable":true,"video_info":{"url":"%s/cdn/hls/4k.m3u8","width":3840,"height":2160,"format":"m3u8"}}
			]}}`, srv.URL, srv.URL)
		case "/cdn/file":
			if r.URL.Query().Get("v") == "1" {
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-4/%d", len(videoData)))
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(videoData[:5])
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	drv, err := NewDriverWithOptions(DriverOptions{
		Mode:            ModeWeb,
		Secret:          "__pus=initial; __puus=old",
		RequestInterval: 10 * time.Millisecond,
		APIBase:         srv.URL + "/1/clouddrive",
		PlayAPIBase:     srv.URL + "/1/clouddrive",
		OnSecretUpdate: func(key, val string) {
			if key == "cookie" {
				rotatedTo = val
			}
		},
	})
	if err != nil {
		t.Fatalf("new quark driver: %v", err)
	}
	defer drv.Close()

	ctx := context.Background()
	if err := drv.Check(ctx); err != nil {
		t.Fatalf("check failed: %v", err)
	}
	if !strings.Contains(rotatedTo, "rotated_puus_value") {
		t.Fatalf("expected cookie rotation callback, got %q", rotatedTo)
	}

	acc, err := drv.AccountInfo(ctx)
	if err != nil || acc.MemberType != "SUPER_VIP" {
		t.Fatalf("unexpected account info: %+v err=%v", acc, err)
	}

	files, err := drv.List(ctx, "/Movies", nil)
	if err != nil || len(files) != 1 || files[0].ID != "f1" {
		t.Fatalf("unexpected list: %+v err=%v", files, err)
	}

	inc, err := drv.SearchUpdatedPage(ctx, 1, 10)
	if err != nil || len(inc) != 1 || inc[0].ParentID != "dir1" {
		t.Fatalf("unexpected incremental page: %+v err=%v", inc, err)
	}

	variants, err := drv.StreamVariants(ctx, files[0], false)
	if err != nil || len(variants) != 2 || variants[0].ID != "4k" || variants[1].ID != "high" {
		t.Fatalf("unexpected sorted variants: %+v err=%v", variants, err)
	}
	if !strings.Contains(variants[0].Headers["Cookie"], "Video-Auth=va_token_123") {
		t.Fatalf("missing Video-Auth in variant headers: %+v", variants[0].Headers)
	}

	// First download URL returns 412; driver should refresh once and succeed on v=2.
	end := int64(4)
	rr, err := drv.OpenRange(ctx, files[0], 0, &end, false)
	if err != nil {
		t.Fatalf("open range after retry: %v", err)
	}
	defer rr.Body.Close()
	got, _ := io.ReadAll(rr.Body)
	if string(got) != "QUARK" {
		t.Fatalf("got %q want QUARK", string(got))
	}
}

func TestQuarkPcQrLoginFlow(t *testing.T) {
	w := NewWsg()
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(wResp http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		plain, err := w.DecodeText(string(raw))
		if err != nil {
			t.Fatalf("decode gateway request: %v", err)
		}
		var reply map[string]any
		switch {
		case strings.Contains(plain, "method=cas.getTokenForQrcodeLogin"):
			reply = map[string]any{"status": 20000, "data": map[string]any{"token": "qr_tok_1", "__trace_id__": "tr1"}}
		case strings.Contains(plain, "method=cas.getServiceTicketByQrcodeToken"):
			reply = map[string]any{"status": 20000, "data": map[string]any{"service_ticket": "st_ok"}}
		case strings.Contains(plain, "method=cas.getUserBasicInfoByServiceTicket"):
			reply = map[string]any{"status": 20000, "data": map[string]any{
				"service_ticket": "final_ticket",
				"uid_string":     "uid999",
				"nickname":       "Tester",
			}}
		}
		jb, _ := json.Marshal(reply)
		enc, _ := w.Encode(string(jb))
		_, _ = wResp.Write([]byte(enc))
	}))
	defer srv.Close()

	qm := NewQrManager()
	qm.pcGateway = srv.URL

	ctx := context.Background()
	started, err := qm.Start(ctx, "pc")
	if err != nil {
		t.Fatalf("start qr: %v", err)
	}
	if !strings.Contains(started.QRContent, "uc_param_str=&token=qr_tok_1") {
		t.Fatalf("unexpected QR URL shape: %q", started.QRContent)
	}
	polled, err := qm.Poll(ctx, started.SessionID)
	if err != nil {
		t.Fatalf("poll qr: %v", err)
	}
	if polled.Status != "confirmed" || !strings.Contains(polled.Secret, `"token":"final_ticket"`) {
		t.Fatalf("unexpected poll result: %+v", polled)
	}
	sess := ParsePcSession(polled.Secret)
	if !sess.IsValid() || sess.UID != "uid999" || sess.Device.Utdid == "" {
		t.Fatalf("parsed session invalid: %+v", sess)
	}
}
