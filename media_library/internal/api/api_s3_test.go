package api

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/ingest"
	"plezy/media_library/internal/source"
)

func doGzipJSONReq(srv *Server, method, path, token, remoteAddr string, body any) *httptest.ResponseRecorder {
	raw, _ := json.Marshal(body)
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	_, _ = gz.Write(raw)
	_ = gz.Close()

	req := httptest.NewRequest(method, path, &buf)
	if remoteAddr != "" {
		req.RemoteAddr = remoteAddr
	} else {
		req.RemoteAddr = "127.0.0.1:45678"
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Encoding", "gzip")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	srv.Mux.ServeHTTP(rec, req)
	return rec
}

func doRawReq(srv *Server, method, path, token, contentType string, data []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, bytes.NewReader(data))
	req.RemoteAddr = "127.0.0.1:45678"
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	srv.Mux.ServeHTTP(rec, req)
	return rec
}

func TestS3ConcurrentGzipBatchIdempotencyAndWatermark(t *testing.T) {
	srv, store, advance := newTestAPIServer(t, "")
	pcTok, hhID, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_dual", db.DeviceClassDesktop, "10.7.0.1:1000", true)
	phoneTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_dual", db.DeviceClassPhone, "10.7.0.2:1000", false)

	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "quark", "name": "Quark S3", "identity_key": "qk_s3", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/Movies"}, {"path": "/TV"}},
	})
	if srcRes.Code != http.StatusOK {
		t.Fatal(srcRes.Body.String())
	}
	var src struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &src)

	// Start concurrent full scans on PC and Phone
	sPCRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", pcTok, "", nil, map[string]any{
		"type": "full",
	})
	if sPCRes.Code != http.StatusOK {
		t.Fatalf("PC CreateSession failed: %d %s", sPCRes.Code, sPCRes.Body.String())
	}
	var sPC struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(sPCRes.Body.Bytes(), &sPC)

	advance(2 * time.Second)
	sPhoneRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", phoneTok, "", nil, map[string]any{
		"type": "full",
	})
	if sPhoneRes.Code != http.StatusOK {
		t.Fatalf("Phone concurrent CreateSession failed: %d %s", sPhoneRes.Code, sPhoneRes.Body.String())
	}
	var sPhone struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(sPhoneRes.Body.Bytes(), &sPhone)

	advance(2 * time.Second)
	batchPayload := map[string]any{
		"batch_no": 1,
		"upserts": []map[string]any{
			{"path": "/Movies/Dune (2021).mkv", "remote_id": "qk_dune", "size": 1024, "mtime_s": 500},
			{"path": "/Movies/Dune (2021).srt", "remote_id": "qk_dune_sub", "size": 50, "mtime_s": 500},
		},
	}
	b1 := doGzipJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sPC.Session.ID+"/batches", pcTok, "", batchPayload)
	if b1.Code != http.StatusOK {
		t.Fatalf("gzip batch failed: %d %s", b1.Code, b1.Body.String())
	}
	var b1Parsed struct {
		Receipt ingest.BatchReceipt `json:"receipt"`
	}
	_ = json.Unmarshal(b1.Body.Bytes(), &b1Parsed)
	if b1Parsed.Receipt.Added != 2 {
		t.Fatalf("expected 2 added files, got %+v", b1Parsed.Receipt)
	}

	var chCntBefore int
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = ?`, hhID).Scan(&chCntBefore)

	// Idempotent batch retry
	b1Retry := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sPC.Session.ID+"/batches", pcTok, "", nil, batchPayload)
	if b1Retry.Code != http.StatusOK {
		t.Fatal(b1Retry.Body.String())
	}
	var chCntAfter int
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE household_id = ?`, hhID).Scan(&chCntAfter)
	if chCntAfter != chCntBefore {
		t.Fatalf("idempotent batch retry wrote extra change_log rows (%d -> %d)", chCntBefore, chCntAfter)
	}

	// Phone reports unchanged Dune in its own session -> unchanged++
	bPhone := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sPhone.Session.ID+"/batches", phoneTok, "", nil, map[string]any{
		"batch_no": 1,
		"upserts": []map[string]any{
			{"path": "/Movies/Dune (2021).mkv", "remote_id": "qk_dune", "size": 1024, "mtime_s": 500},
		},
	})
	if bPhone.Code != http.StatusOK || !strings.Contains(bPhone.Body.String(), `"unchanged":1`) {
		t.Fatalf("expected unchanged=1 on phone batch, got %d %s", bPhone.Code, bPhone.Body.String())
	}

	// Phone completes with new_watermark=500 -> Dune & sub remain active since seen at T >= sPhone.StartedAt
	advance(2 * time.Second)
	cPhone := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sPhone.Session.ID+"/complete", phoneTok, "", nil, map[string]any{
		"complete": true, "new_watermark": 500,
	})
	if cPhone.Code != http.StatusOK || !strings.Contains(cPhone.Body.String(), `"missing_count":0`) {
		t.Fatalf("phone complete unexpected: %d %s", cPhone.Code, cPhone.Body.String())
	}

	// PC completes with older watermark 200 -> monotonic 500 preserved
	cPC := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sPC.Session.ID+"/complete", pcTok, "", nil, map[string]any{
		"complete": true, "new_watermark": 200,
	})
	if cPC.Code != http.StatusOK || !strings.Contains(cPC.Body.String(), `"new_watermark":500`) {
		t.Fatalf("PC complete should keep watermark=500, got %d %s", cPC.Code, cPC.Body.String())
	}

	// Session list endpoint
	listSess := doJSONReq(srv, http.MethodGet, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", pcTok, "", nil, nil)
	if listSess.Code != http.StatusOK || !strings.Contains(listSess.Body.String(), sPC.Session.ID) {
		t.Fatalf("list sessions unexpected: %d %s", listSess.Code, listSess.Body.String())
	}
}

func TestS3DeviceScanConstraintsAndProgress(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")
	pcTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_dev", db.DeviceClassDesktop, "10.8.0.1:1000", true)
	tvTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_dev", db.DeviceClassTV, "10.8.0.2:1000", false)
	webTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_dev", db.DeviceClassWeb, "10.8.0.3:1000", false)

	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "quark", "name": "Quark TV", "identity_key": "qk_tv_dev", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/TV"}},
	})
	var src struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &src)

	if r := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", tvTok, "", nil, map[string]any{"type": "full"}); r.Code != http.StatusForbidden || !strings.Contains(r.Body.String(), "full_scan_not_allowed_on_device") {
		t.Fatalf("expected 403 full_scan_not_allowed_on_device for TV full scan, got %d %s", r.Code, r.Body.String())
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", webTok, "", nil, map[string]any{"type": "incremental"}); r.Code != http.StatusForbidden || !strings.Contains(r.Body.String(), "scan_not_allowed_on_device") {
		t.Fatalf("expected 403 scan_not_allowed_on_device for Web, got %d %s", r.Code, r.Body.String())
	}

	tvFolder := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", tvTok, "", nil, map[string]any{
		"type": "folder", "folder_id": src.Source.Folders[0].ID,
	})
	if tvFolder.Code != http.StatusOK {
		t.Fatalf("TV folder scan failed: %d %s", tvFolder.Code, tvFolder.Body.String())
	}
	var tvSess struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(tvFolder.Body.Bytes(), &tvSess)

	prog := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+tvSess.Session.ID+"/progress", tvTok, "", nil, map[string]any{
		"progress_pct": 55, "files_reported": 12,
	})
	if prog.Code != http.StatusOK || !strings.Contains(prog.Body.String(), `"progress_pct":55`) {
		t.Fatalf("progress update failed: %d %s", prog.Code, prog.Body.String())
	}
	if tvInc := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", tvTok, "", nil, map[string]any{"type": "incremental"}); tvInc.Code != http.StatusOK {
		t.Fatalf("TV incremental scan failed: %d %s", tvInc.Code, tvInc.Body.String())
	}
}

func TestS3SidecarUploadValidationAndMediaSpec(t *testing.T) {
	srv, store, _ := newTestAPIServer(t, "")
	pcTok, hhID, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_sidecar", db.DeviceClassDesktop, "10.9.0.1:1000", true)

	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", pcTok, "", nil, map[string]any{
		"kind": "quark", "name": "Movies", "identity_key": "qk_side", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/Movies"}},
	})
	var src struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &src)

	nfoData := []byte(`<movie><title>Inception</title><tmdbid>27205</tmdbid></movie>`)
	sum := sha256.Sum256(nfoData)
	nfoHex := hex.EncodeToString(sum[:])

	sessRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", pcTok, "", nil, map[string]any{"type": "full"})
	var sess struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(sessRes.Body.Bytes(), &sess)

	b := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+sess.Session.ID+"/batches", pcTok, "", nil, map[string]any{
		"batch_no": 1,
		"upserts": []map[string]any{
			{"path": "/Movies/Inception (2010)/Inception (2010).mkv", "remote_id": "v1", "size": 5000, "mtime_s": 100},
			{"path": "/Movies/Inception (2010)/movie.nfo", "remote_id": "n1", "size": len(nfoData), "mtime_s": 100, "sidecar_hash": nfoHex},
		},
	})
	var br struct {
		Receipt ingest.BatchReceipt `json:"receipt"`
	}
	_ = json.Unmarshal(b.Body.Bytes(), &br)
	if len(br.Receipt.MissingSidecars) != 1 || br.Receipt.MissingSidecars[0] != nfoHex {
		t.Fatalf("expected missing sidecar %s, got %+v", nfoHex, br.Receipt.MissingSidecars)
	}
	videoFileID := br.Receipt.FileIDs["/Movies/Inception (2010)/Inception (2010).mkv"]

	// HEAD -> 404 before upload
	if h := doRawReq(srv, http.MethodHead, "/api/v1/sidecars/"+nfoHex, pcTok, "", nil); h.Code != http.StatusNotFound {
		t.Fatalf("expected 404 before sidecar upload, got %d", h.Code)
	}
	// Wrong SHA -> 400
	if pBad := doRawReq(srv, http.MethodPut, "/api/v1/sidecars/"+nfoHex+"?kind=nfo", pcTok, "text/xml", []byte("<wrong/>")); pBad.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on sha256 mismatch, got %d", pBad.Code)
	}
	// Oversize NFO (>64KB) -> 400
	oversize := bytes.Repeat([]byte("A"), ingest.MaxNfoSidecarBytes+10)
	overSum := sha256.Sum256(oversize)
	overHex := hex.EncodeToString(overSum[:])
	if pBig := doRawReq(srv, http.MethodPut, "/api/v1/sidecars/"+overHex+"?kind=nfo", pcTok, "text/xml", oversize); pBig.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on oversize NFO, got %d %s", pBig.Code, pBig.Body.String())
	}

	// Valid PUT -> 200, then HEAD -> 200
	if pOK := doRawReq(srv, http.MethodPut, "/api/v1/sidecars/"+nfoHex+"?kind=nfo", pcTok, "text/xml", nfoData); pOK.Code != http.StatusOK {
		t.Fatalf("PUT sidecar failed: %d %s", pOK.Code, pOK.Body.String())
	}
	if hOK := doRawReq(srv, http.MethodHead, "/api/v1/sidecars/"+nfoHex, pcTok, "", nil); hOK.Code != http.StatusOK {
		t.Fatalf("expected 200 after sidecar upload, got %d", hOK.Code)
	}

	// POST /api/v1/files/{id}/media-spec -> 200 + probed_at set
	specRes := doJSONReq(srv, http.MethodPost, fmt.Sprintf("/api/v1/files/%d/media-spec", videoFileID), pcTok, "", nil, map[string]any{
		"duration_ms": 8880000,
		"video_codec": "hevc",
		"width":       3840,
		"height":      2160,
		"hdr_format":  "Dolby Vision",
		"streams": []map[string]any{
			{"kind": "video", "index": 0, "codec": "hevc"},
			{"kind": "audio", "index": 1, "codec": "truehd", "language": "eng"},
		},
	})
	if specRes.Code != http.StatusOK {
		t.Fatalf("media-spec failed: %d %s", specRes.Code, specRes.Body.String())
	}
	var probedAt int64
	var vCodec string
	if err := store.ReadDB().QueryRow(`SELECT COALESCE(probed_at, 0), COALESCE(video_codec, '') FROM media_files WHERE id = ? AND household_id = ?`, videoFileID, hhID).Scan(&probedAt, &vCodec); err != nil {
		t.Fatal(err)
	}
	if probedAt == 0 || vCodec != "hevc" {
		t.Fatalf("expected probed_at & video_codec updated, got probed=%d codec=%q", probedAt, vCodec)
	}
}

func TestS3BulkDeletionProtectionTenantWrongDeviceRBACAndAuditPrivacy(t *testing.T) {
	srv, store, advance := newTestAPIServer(t, "")
	admTok := mustReadyAdminToken(t, srv)

	phoneA, hhA, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_bulk_a", db.DeviceClassPhone, "10.10.0.1:1000", true)
	pcA, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_bulk_a", db.DeviceClassDesktop, "10.10.0.2:1000", false)
	phoneB, _, _, _ := mustRegisterAndLoginDevice(t, srv, "s3_bulk_b", db.DeviceClassPhone, "10.10.0.9:1000", true)

	srcRes := doJSONReq(srv, http.MethodPost, "/api/v1/sources", phoneA, "", nil, map[string]any{
		"kind": "webdav", "name": "SecretNASLabel", "identity_key": "wd_s3", "ciphertext": "enc",
		"folders": []map[string]any{{"path": "/Films"}},
	})
	var src struct {
		Source source.SourceView `json:"source"`
	}
	_ = json.Unmarshal(srcRes.Body.Bytes(), &src)

	// Seed 105 files in /Films
	s1Res := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", phoneA, "", nil, map[string]any{"type": "full"})
	var s1 struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(s1Res.Body.Bytes(), &s1)

	var upserts []map[string]any
	for i := 1; i <= 105; i++ {
		upserts = append(upserts, map[string]any{
			"path": fmt.Sprintf("/Films/SecretFilmName_%03d (2024).mkv", i), "size": 100, "mtime_s": 10,
		})
	}
	if r := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s1.Session.ID+"/batches", phoneA, "", nil, map[string]any{
		"batch_no": 1, "upserts": upserts,
	}); r.Code != http.StatusOK {
		t.Fatalf("seed 105 files failed: %d %s", r.Code, r.Body.String())
	}
	_ = doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s1.Session.ID+"/complete", phoneA, "", nil, map[string]any{"complete": true})

	// Second full scan reports only 1 file -> triggers pending_deletions!
	advance(5 * time.Second)
	s2Res := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", phoneA, "", nil, map[string]any{"type": "full"})
	var s2 struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(s2Res.Body.Bytes(), &s2)

	// Wrong device (PC submitting to Phone's session) -> 403
	if wd := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s2.Session.ID+"/batches", pcA, "", nil, map[string]any{
		"batch_no": 1, "upserts": upserts[:1],
	}); wd.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for wrong device submitting batch, got %d %s", wd.Code, wd.Body.String())
	}

	// Household B accessing Household A's session -> 404
	if cross := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s2.Session.ID+"/batches", phoneB, "", nil, map[string]any{
		"batch_no": 1,
	}); cross.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household batch submit, got %d %s", cross.Code, cross.Body.String())
	}

	// Child role lacking PermUploadFacts -> 403
	childCreate := doJSONReq(srv, http.MethodPost, "/api/v1/household/members", phoneA, "", nil, map[string]any{
		"nickname": "Kiddo", "role": account.RoleChild, "login_username": "kiddo_s3", "login_password": "Password123!",
	})
	if childCreate.Code != http.StatusOK {
		t.Fatal(childCreate.Body.String())
	}
	childTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "kiddo_s3", db.DeviceClassPhone, "10.10.0.4:1000", false)
	if chScan := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", childTok, "", nil, map[string]any{"type": "incremental"}); chScan.Code != http.StatusForbidden {
		t.Fatalf("expected 403 child missing PermUploadFacts, got %d %s", chScan.Code, chScan.Body.String())
	}

	// Phone completes s2 with 1 file -> creates pending deletion
	_ = doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s2.Session.ID+"/batches", phoneA, "", nil, map[string]any{
		"batch_no": 1, "upserts": upserts[:1],
	})
	c2 := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s2.Session.ID+"/complete", phoneA, "", nil, map[string]any{"complete": true})
	var c2Res struct {
		PendingDeletionID string `json:"pending_deletion_id"`
	}
	_ = json.Unmarshal(c2.Body.Bytes(), &c2Res)
	if c2Res.PendingDeletionID == "" {
		t.Fatalf("expected pending_deletion_id, got %s", c2.Body.String())
	}

	pds := doJSONReq(srv, http.MethodGet, "/api/v1/pending-deletions", phoneA, "", nil, nil)
	if pds.Code != http.StatusOK || !strings.Contains(pds.Body.String(), c2Res.PendingDeletionID) {
		t.Fatalf("list pending deletions unexpected: %d %s", pds.Code, pds.Body.String())
	}
	// Cross-household confirm -> 404
	if cr := doJSONReq(srv, http.MethodPost, "/api/v1/pending-deletions/"+c2Res.PendingDeletionID+"/confirm", phoneB, "", nil, nil); cr.Code != http.StatusNotFound {
		t.Fatalf("expected 404 cross-household pending deletion confirm, got %d", cr.Code)
	}
	// Dismiss leaves all 105 files active
	if dis := doJSONReq(srv, http.MethodPost, "/api/v1/pending-deletions/"+c2Res.PendingDeletionID+"/dismiss", phoneA, "", nil, nil); dis.Code != http.StatusOK {
		t.Fatalf("dismiss failed: %d %s", dis.Code, dis.Body.String())
	}
	var activeCnt int
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = ? AND state = 'active'`, hhA).Scan(&activeCnt)
	if activeCnt != 105 {
		t.Fatalf("expected all 105 files still active after dismiss, got %d", activeCnt)
	}

	// Soft-delete source while another scan is active -> subsequent batch returns 410 source_deleted
	s3Res := doJSONReq(srv, http.MethodPost, "/api/v1/sources/"+src.Source.ID+"/scan-sessions", phoneA, "", nil, map[string]any{"type": "incremental"})
	var s3 struct {
		Session ingest.ScanSessionView `json:"session"`
	}
	_ = json.Unmarshal(s3Res.Body.Bytes(), &s3)
	_ = doJSONReq(srv, http.MethodDelete, "/api/v1/sources/"+src.Source.ID, phoneA, "", nil, nil)
	if postDel := doJSONReq(srv, http.MethodPost, "/api/v1/scan-sessions/"+s3.Session.ID+"/batches", phoneA, "", nil, map[string]any{
		"batch_no": 1, "upserts": []map[string]any{{"path": "/Films/ShouldReject.mkv", "size": 10, "mtime_s": 1}},
	}); postDel.Code != http.StatusGone || !strings.Contains(postDel.Body.String(), "source_deleted") {
		t.Fatalf("expected 410 source_deleted mid-scan, got %d %s", postDel.Code, postDel.Body.String())
	}

	// D8 admin audit logs must contain scan actions with ZERO private file names / source labels
	audit := doJSONReq(srv, http.MethodGet, "/api/admin/audit-logs", admTok, "", nil, nil)
	if audit.Code != http.StatusOK {
		t.Fatal(audit.Body.String())
	}
	auditBody := audit.Body.String()
	if !strings.Contains(auditBody, "scan.session_started") || !strings.Contains(auditBody, "source.pending_deletion_dismissed") {
		t.Fatalf("expected scan audit events in %s", auditBody)
	}
	if strings.Contains(auditBody, "SecretNASLabel") || strings.Contains(auditBody, "SecretFilmName") {
		t.Fatalf("D8 privacy leak in audit logs: %s", auditBody)
	}
}
