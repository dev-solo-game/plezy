package stream

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/storage"
)

const hlsSegTTL = 4 * time.Hour

var reHLSAttrURI = regexp.MustCompile(`URI="([^"]+)"`)

type HLSProxy struct {
	signingKey []byte
	nowFn      func() time.Time
}

func NewHLSProxy(signingKey []byte) *HLSProxy {
	k := make([]byte, len(signingKey))
	copy(k, signingKey)
	return &HLSProxy{
		signingKey: k,
		nowFn:      time.Now,
	}
}

func (p *HLSProxy) SetNowFunc(fn func() time.Time) {
	if fn != nil {
		p.nowFn = fn
	}
}

func (p *HLSProxy) signTarget(mountID, fid, variantID, targetURL string, expMs int64) string {
	msg := fmt.Sprintf("%s\x00%s\x00%s\x00%s\x00%d", mountID, fid, variantID, targetURL, expMs)
	mac := hmac.New(sha256.New, p.signingKey)
	_, _ = mac.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (p *HLSProxy) verifyTarget(mountID, fid, variantID, targetURL string, expMs int64, sig string) bool {
	if p.nowFn().UnixMilli() > expMs {
		return false
	}
	gotSig, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return false
	}
	msg := fmt.Sprintf("%s\x00%s\x00%s\x00%s\x00%d", mountID, fid, variantID, targetURL, expMs)
	mac := hmac.New(sha256.New, p.signingKey)
	_, _ = mac.Write([]byte(msg))
	return hmac.Equal(gotSig, mac.Sum(nil))
}

func (p *HLSProxy) makeProxyURL(mountID, fid, variantID, absURL, streamToken string) string {
	expMs := p.nowFn().Add(hlsSegTTL).UnixMilli()
	uB64 := base64.RawURLEncoding.EncodeToString([]byte(absURL))
	sig := p.signTarget(mountID, fid, variantID, absURL, expMs)
	q := url.Values{}
	q.Set("mount", mountID)
	q.Set("fid", fid)
	q.Set("vid", variantID)
	q.Set("u", uB64)
	q.Set("exp", strconv.FormatInt(expMs, 10))
	q.Set("sig", sig)
	if streamToken != "" {
		q.Set("token", streamToken)
	}
	return "/api/v1/stream/hls-seg?" + q.Encode()
}

// RewritePlaylist resolves every relative or absolute segment/playlist/key URI in an
// m3u8 document against baseURL and rewrites them to signed proxy endpoints.
func (p *HLSProxy) RewritePlaylist(playlistText, baseURL, mountID, fid, variantID, streamToken string) (string, error) {
	base, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	lines := strings.Split(strings.ReplaceAll(playlistText, "\r\n", "\n"), "\n")
	out := make([]string, 0, len(lines))

	resolve := func(raw string) string {
		ref, err := url.Parse(strings.TrimSpace(raw))
		if err != nil {
			return raw
		}
		return base.ResolveReference(ref).String()
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			if strings.Contains(trimmed, `URI="`) {
				rewritten := reHLSAttrURI.ReplaceAllStringFunc(line, func(match string) string {
					sub := reHLSAttrURI.FindStringSubmatch(match)
					if len(sub) < 2 {
						return match
					}
					abs := resolve(sub[1])
					return `URI="` + p.makeProxyURL(mountID, fid, variantID, abs, streamToken) + `"`
				})
				out = append(out, rewritten)
			} else {
				out = append(out, line)
			}
			continue
		}
		abs := resolve(trimmed)
		out = append(out, p.makeProxyURL(mountID, fid, variantID, abs, streamToken))
	}
	return strings.Join(out, "\n"), nil
}

// ServeVariant serves either an m3u8 playlist (rewritten) or a direct fmp4/mp4 variant stream.
func (p *HLSProxy) ServeVariant(
	w http.ResponseWriter,
	r *http.Request,
	mountID string,
	vs storage.VariantSource,
	entry storage.Entry,
	variantID string,
	streamToken string,
) {
	ctx := r.Context()
	fid := entry.ID
	var chosen *storage.StreamVariant
	var resp *http.Response

	for attempt := 0; attempt < 2; attempt++ {
		variants, err := vs.StreamVariants(ctx, entry, attempt > 0)
		if err != nil {
			writeStorageHTTPError(w, err)
			return
		}
		chosen = nil
		for i := range variants {
			if variants[i].ID == variantID {
				chosen = &variants[i]
				break
			}
		}
		if chosen == nil && len(variants) > 0 {
			chosen = &variants[0]
		}
		if chosen == nil {
			http.Error(w, "stream variant not available", http.StatusNotFound)
			return
		}
		if !chosen.IsHLS {
			p.proxyUpstreamStream(w, r, vs, chosen.URL, chosen.Headers)
			return
		}
		upResp, err := vs.FetchVariantURL(ctx, chosen.URL, chosen.Headers)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		if (upResp.StatusCode == http.StatusUnauthorized || upResp.StatusCode == http.StatusForbidden || upResp.StatusCode == http.StatusPreconditionFailed) && attempt == 0 {
			_, _ = io.Copy(io.Discard, upResp.Body)
			_ = upResp.Body.Close()
			continue
		}
		resp = upResp
		break
	}

	if resp == nil {
		http.Error(w, "failed to load variant playlist", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream returned HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
	if err != nil {
		http.Error(w, "read upstream playlist failed", http.StatusBadGateway)
		return
	}

	finalBase := chosen.URL
	if resp.Request != nil && resp.Request.URL != nil {
		finalBase = resp.Request.URL.String()
	}
	rewritten, err := p.RewritePlaylist(string(raw), finalBase, mountID, fid, variantID, streamToken)
	if err != nil {
		http.Error(w, "rewrite playlist failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, rewritten)
}

// ServeSegment validates the HMAC signature and proxies a signed HLS segment or nested playlist.
func (p *HLSProxy) ServeSegment(
	w http.ResponseWriter,
	r *http.Request,
	vs storage.VariantSource,
	entry storage.Entry,
	streamToken string,
) {
	q := r.URL.Query()
	mountID := q.Get("mount")
	fid := q.Get("fid")
	variantID := q.Get("vid")
	uB64 := q.Get("u")
	expStr := q.Get("exp")
	sig := q.Get("sig")

	expMs, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil || uB64 == "" || sig == "" {
		http.Error(w, "invalid segment signature parameters", http.StatusBadRequest)
		return
	}
	rawURLBytes, err := base64.RawURLEncoding.DecodeString(uB64)
	if err != nil {
		http.Error(w, "invalid segment url encoding", http.StatusBadRequest)
		return
	}
	targetURL := string(rawURLBytes)
	if !p.verifyTarget(mountID, fid, variantID, targetURL, expMs, sig) {
		http.Error(w, "expired or invalid segment signature", http.StatusForbidden)
		return
	}

	variants, err := vs.StreamVariants(r.Context(), entry, false)
	if err != nil {
		writeStorageHTTPError(w, err)
		return
	}
	var hdrs map[string]string
	for _, v := range variants {
		if v.ID == variantID {
			hdrs = v.Headers
			break
		}
	}
	if hdrs == nil && len(variants) > 0 {
		hdrs = variants[0].Headers
	}

	reqHdrs := make(map[string]string, len(hdrs)+1)
	for k, v := range hdrs {
		reqHdrs[k] = v
	}
	if rng := r.Header.Get("Range"); rng != "" {
		reqHdrs["Range"] = rng
	}

	resp, err := vs.FetchVariantURL(r.Context(), targetURL, reqHdrs)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream segment HTTP %d", resp.StatusCode), resp.StatusCode)
		return
	}

	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if strings.Contains(ct, "mpegurl") || strings.Contains(strings.ToLower(targetURL), ".m3u8") {
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
		if err != nil {
			http.Error(w, "read sub-playlist failed", http.StatusBadGateway)
			return
		}
		finalBase := targetURL
		if resp.Request != nil && resp.Request.URL != nil {
			finalBase = resp.Request.URL.String()
		}
		rewritten, err := p.RewritePlaylist(string(raw), finalBase, mountID, fid, variantID, streamToken)
		if err != nil {
			http.Error(w, "rewrite sub-playlist failed", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, rewritten)
		return
	}

	if origCT := resp.Header.Get("Content-Type"); origCT != "" {
		w.Header().Set("Content-Type", origCT)
	} else {
		w.Header().Set("Content-Type", "video/mp2t")
	}
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}
	if cr := resp.Header.Get("Content-Range"); cr != "" {
		w.Header().Set("Content-Range", cr)
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (p *HLSProxy) proxyUpstreamStream(w http.ResponseWriter, r *http.Request, vs storage.VariantSource, targetURL string, headers map[string]string) {
	reqHdrs := make(map[string]string, len(headers)+1)
	for k, v := range headers {
		reqHdrs[k] = v
	}
	if rng := r.Header.Get("Range"); rng != "" {
		reqHdrs["Range"] = rng
	}
	resp, err := vs.FetchVariantURL(r.Context(), targetURL, reqHdrs)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "video/mp4")
	}
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}
	if cr := resp.Header.Get("Content-Range"); cr != "" {
		w.Header().Set("Content-Range", cr)
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}
