package storage

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const propfindRequestBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>`

type WebDavDriver struct {
	primaryURL   *url.URL
	fallbackURL  *url.URL
	username     string
	password     string
	client       *http.Client
	authMu       sync.Mutex
	preferDigest bool
	digestParams map[string]string
	digestNC     atomic.Uint64
}

func NewWebDavDriver(cfg MountConfig) (*WebDavDriver, error) {
	rawBase := CfgString(cfg.Config, "baseUrl")
	primary, err := parseHTTPURL(rawBase)
	if err != nil {
		return nil, NewError(ErrKindOther, "WebDAV mount requires a valid http(s) baseUrl", err)
	}
	var fallback *url.URL
	if rawFB := CfgString(cfg.Config, "fallbackUrl"); rawFB != "" {
		if fb, err := parseHTTPURL(rawFB); err == nil {
			fallback = fb
		}
	}

	insecureTLS := CfgBool(cfg.Config, "allowInsecureTls", false)
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if insecureTLS {
		tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	}
	client := &http.Client{
		Transport: tr,
		Timeout:   60 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			// Handle redirects explicitly for credential isolation on cross-host hops.
			return http.ErrUseLastResponse
		},
	}

	return &WebDavDriver{
		primaryURL:  primary,
		fallbackURL: fallback,
		username:    CfgString(cfg.Config, "username"),
		password:    cfg.Secrets["password"],
		client:      client,
	}, nil
}

func parseHTTPURL(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return nil, err
	}
	scheme := strings.ToLower(u.Scheme)
	if (scheme != "http" && scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("invalid http(s) url %q", raw)
	}
	return u, nil
}

func (d *WebDavDriver) Kind() string {
	return "webdav"
}

func (d *WebDavDriver) urlFor(base *url.URL, mountPath string, isDir bool) *url.URL {
	baseSegs := splitNonEmpty(base.Path)
	relSegs := PathSegments(mountPath)
	all := append(append([]string{}, baseSegs...), relSegs...)
	encoded := make([]string, len(all))
	for i, s := range all {
		encoded[i] = url.PathEscape(s)
	}
	escapedPath := "/" + strings.Join(encoded, "/")
	if isDir && escapedPath != "/" {
		escapedPath += "/"
	}
	copyU := *base
	copyU.Path = "/" + strings.Join(all, "/")
	if isDir && copyU.Path != "/" {
		copyU.Path += "/"
	}
	copyU.RawPath = escapedPath
	return &copyU
}

func splitNonEmpty(p string) []string {
	var out []string
	for _, s := range strings.Split(p, "/") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func (d *WebDavDriver) doAuthRequest(ctx context.Context, method string, target *url.URL, headers map[string]string, bodyBytes []byte) (*http.Response, error) {
	curr := target
	var lastResp *http.Response
	for hop := 0; hop < 8; hop++ {
		var bodyReader io.Reader
		if bodyBytes != nil {
			bodyReader = bytes.NewReader(bodyBytes)
		}
		req, err := http.NewRequestWithContext(ctx, method, curr.String(), bodyReader)
		if err != nil {
			return nil, NewError(ErrKindOther, "invalid WebDAV request", err)
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		sameOrigin := strings.EqualFold(curr.Host, target.Host)
		if sameOrigin && d.username != "" {
			d.applyAuthHeader(req, method, curr.RequestURI())
		}
		resp, err := d.client.Do(req)
		if err != nil {
			return nil, NewError(ErrKindNetwork, "WebDAV request failed", err)
		}

		if resp.StatusCode == http.StatusUnauthorized && sameOrigin && d.username != "" {
			wwwAuth := resp.Header.Get("WWW-Authenticate")
			_ = resp.Body.Close()
			if d.updateAuthChallenge(wwwAuth) {
				var retryBody io.Reader
				if bodyBytes != nil {
					retryBody = bytes.NewReader(bodyBytes)
				}
				retryReq, err := http.NewRequestWithContext(ctx, method, curr.String(), retryBody)
				if err != nil {
					return nil, NewError(ErrKindOther, "invalid WebDAV retry request", err)
				}
				for k, v := range headers {
					retryReq.Header.Set(k, v)
				}
				d.applyAuthHeader(retryReq, method, curr.RequestURI())
				resp, err = d.client.Do(retryReq)
				if err != nil {
					return nil, NewError(ErrKindNetwork, "WebDAV request failed", err)
				}
			} else {
				return nil, NewError(ErrKindUnauthorized, "WebDAV server rejected credentials")
			}
		}

		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			loc := resp.Header.Get("Location")
			if loc == "" {
				return resp, nil
			}
			nextURL, err := curr.Parse(loc)
			if err != nil {
				return resp, nil
			}
			_ = resp.Body.Close()
			curr = nextURL
			// Only preserve method on 307/308 or PROPFIND; standard GET stays GET.
			if resp.StatusCode != http.StatusTemporaryRedirect && resp.StatusCode != http.StatusPermanentRedirect && method != "PROPFIND" {
				method = http.MethodGet
				bodyBytes = nil
			}
			lastResp = nil
			continue
		}
		return resp, nil
	}
	if lastResp != nil {
		_ = lastResp.Body.Close()
	}
	return nil, NewError(ErrKindNetwork, "too many WebDAV redirects")
}

func (d *WebDavDriver) applyAuthHeader(req *http.Request, method, uri string) {
	d.authMu.Lock()
	useDigest := d.preferDigest && len(d.digestParams) > 0
	var params map[string]string
	if useDigest {
		params = make(map[string]string, len(d.digestParams))
		for k, v := range d.digestParams {
			params[k] = v
		}
	}
	d.authMu.Unlock()

	if !useDigest {
		req.SetBasicAuth(d.username, d.password)
		return
	}

	realm := params["realm"]
	nonce := params["nonce"]
	qop := params["qop"]
	opaque := params["opaque"]
	algo := strings.ToUpper(params["algorithm"])

	ha1 := md5Hex(fmt.Sprintf("%s:%s:%s", d.username, realm, d.password))
	if algo == "MD5-SESS" {
		// Standard fallback handled below if qop present
	}
	ha2 := md5Hex(fmt.Sprintf("%s:%s", method, uri))

	var authLine string
	if strings.Contains(strings.ToLower(qop), "auth") {
		nc := fmt.Sprintf("%08x", d.digestNC.Add(1))
		cnonceBytes := make([]byte, 8)
		_, _ = rand.Read(cnonceBytes)
		cnonce := hex.EncodeToString(cnonceBytes)
		respDigest := md5Hex(fmt.Sprintf("%s:%s:%s:%s:auth:%s", ha1, nonce, nc, cnonce, ha2))
		authLine = fmt.Sprintf(
			`Digest username="%s", realm="%s", nonce="%s", uri="%s", qop=auth, nc=%s, cnonce="%s", response="%s"`,
			d.username, realm, nonce, uri, nc, cnonce, respDigest,
		)
	} else {
		respDigest := md5Hex(fmt.Sprintf("%s:%s:%s", ha1, nonce, ha2))
		authLine = fmt.Sprintf(
			`Digest username="%s", realm="%s", nonce="%s", uri="%s", response="%s"`,
			d.username, realm, nonce, uri, respDigest,
		)
	}
	if opaque != "" {
		authLine += fmt.Sprintf(`, opaque="%s"`, opaque)
	}
	req.Header.Set("Authorization", authLine)
}

func (d *WebDavDriver) updateAuthChallenge(wwwAuth string) bool {
	trimmed := strings.TrimSpace(wwwAuth)
	if len(trimmed) < 6 || !strings.EqualFold(trimmed[:6], "Digest") {
		return false
	}
	params := parseDigestHeader(trimmed[6:])
	if params["nonce"] == "" {
		return false
	}
	d.authMu.Lock()
	d.preferDigest = true
	d.digestParams = params
	d.authMu.Unlock()
	return true
}

func parseDigestHeader(rest string) map[string]string {
	out := make(map[string]string)
	for _, part := range strings.Split(rest, ",") {
		eq := strings.IndexByte(part, '=')
		if eq <= 0 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(part[:eq]))
		v := strings.TrimSpace(part[eq+1:])
		v = strings.Trim(v, `"`)
		out[k] = v
	}
	return out
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s)) //nolint:gosec
	return hex.EncodeToString(sum[:])
}

func (d *WebDavDriver) withFallback(ctx context.Context, fn func(base *url.URL) (*http.Response, error)) (*http.Response, *url.URL, error) {
	resp, err := fn(d.primaryURL)
	if err == nil {
		return resp, d.primaryURL, nil
	}
	if d.fallbackURL != nil && IsKind(err, ErrKindNetwork) {
		resp2, err2 := fn(d.fallbackURL)
		if err2 == nil {
			return resp2, d.fallbackURL, nil
		}
	}
	return nil, d.primaryURL, err
}

func (d *WebDavDriver) Check(ctx context.Context) error {
	_, err := d.propfind(ctx, RootPath, 0, true)
	return err
}

func (d *WebDavDriver) List(ctx context.Context, mountPath string, parent *Entry) ([]Entry, error) {
	norm := NormalizePath(mountPath)
	depth := len(PathSegments(norm))
	entries, err := d.propfind(ctx, norm, 1, true)
	if err != nil {
		return nil, err
	}
	out := make([]Entry, 0, len(entries))
	for _, e := range entries {
		if len(PathSegments(e.Path)) == depth+1 {
			out = append(out, e)
		}
	}
	return out, nil
}

func (d *WebDavDriver) Stat(ctx context.Context, mountPath string) (Entry, error) {
	norm := NormalizePath(mountPath)
	if norm == RootPath {
		return Entry{Path: RootPath, Name: "", IsDir: true}, nil
	}
	entries, err := d.propfind(ctx, norm, 0, false)
	if err != nil {
		return Entry{}, err
	}
	for _, e := range entries {
		if e.Path == norm {
			return e, nil
		}
	}
	return Entry{}, NewError(ErrKindNotFound, "not found: "+norm)
}

func (d *WebDavDriver) propfind(ctx context.Context, mountPath string, depth int, isDir bool) ([]Entry, error) {
	headers := map[string]string{
		"Depth":        strconv.Itoa(depth),
		"Content-Type": "application/xml; charset=utf-8",
	}
	resp, usedBase, err := d.withFallback(ctx, func(base *url.URL) (*http.Response, error) {
		u := d.urlFor(base, mountPath, isDir)
		return d.doAuthRequest(ctx, "PROPFIND", u, headers, []byte(propfindRequestBody))
	})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusMultiStatus, http.StatusOK:
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024))
		if err != nil {
			return nil, NewError(ErrKindNetwork, "read WebDAV response failed", err)
		}
		return parseMultiStatusXML(raw, splitNonEmpty(usedBase.Path))
	case http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		if !isDir {
			return d.propfind(ctx, mountPath, depth, true)
		}
		return nil, NewError(ErrKindOther, fmt.Sprintf("WebDAV answered HTTP %d", resp.StatusCode))
	case http.StatusUnauthorized, http.StatusForbidden:
		return nil, NewError(ErrKindUnauthorized, "WebDAV server rejected credentials")
	case http.StatusNotFound:
		return nil, NewError(ErrKindNotFound, "not found: "+mountPath)
	case http.StatusTooManyRequests:
		return nil, NewError(ErrKindRateLimited, "WebDAV rate limiting")
	default:
		return nil, NewError(ErrKindOther, fmt.Sprintf("WebDAV answered HTTP %d", resp.StatusCode))
	}
}

func (d *WebDavDriver) OpenRange(ctx context.Context, entry Entry, start int64, end *int64, forceRefresh bool) (RangeResult, error) {
	if entry.IsDir {
		return RangeResult{}, NewError(ErrKindUnsupported, "cannot stream a directory")
	}
	totalSize := int64(-1)
	if entry.Size != nil {
		totalSize = *entry.Size
	}
	if totalSize < 0 {
		st, err := d.Stat(ctx, entry.Path)
		if err != nil {
			return RangeResult{}, err
		}
		if st.Size != nil {
			totalSize = *st.Size
		}
	}

	headers := make(map[string]string)
	if end != nil {
		headers["Range"] = fmt.Sprintf("bytes=%d-%d", start, *end)
	} else if start > 0 {
		headers["Range"] = fmt.Sprintf("bytes=%d-", start)
	}

	// Streaming GET uses a dedicated client without the 60s full-body Timeout so
	// large video reads do not get aborted mid-playback.
	streamClient := &http.Client{
		Transport: d.client.Transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	doStream := func(base *url.URL) (*http.Response, error) {
		origClient := d.client
		// Build request via streamClient while preserving auth negotiation
		curr := d.urlFor(base, entry.Path, false)
		for hop := 0; hop < 8; hop++ {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, curr.String(), nil)
			if err != nil {
				return nil, NewError(ErrKindOther, "invalid WebDAV stream request", err)
			}
			for k, v := range headers {
				req.Header.Set(k, v)
			}
			sameOrigin := strings.EqualFold(curr.Host, base.Host)
			if sameOrigin && d.username != "" {
				d.applyAuthHeader(req, http.MethodGet, curr.RequestURI())
			}
			resp, err := streamClient.Do(req)
			if err != nil {
				return nil, NewError(ErrKindNetwork, "WebDAV stream failed", err)
			}
			if resp.StatusCode == http.StatusUnauthorized && sameOrigin && d.username != "" {
				wwwAuth := resp.Header.Get("WWW-Authenticate")
				_ = resp.Body.Close()
				if d.updateAuthChallenge(wwwAuth) {
					retryReq, _ := http.NewRequestWithContext(ctx, http.MethodGet, curr.String(), nil)
					for k, v := range headers {
						retryReq.Header.Set(k, v)
					}
					d.applyAuthHeader(retryReq, http.MethodGet, curr.RequestURI())
					resp, err = streamClient.Do(retryReq)
					if err != nil {
						return nil, NewError(ErrKindNetwork, "WebDAV stream failed", err)
					}
				} else {
					_ = origClient
					return nil, NewError(ErrKindUnauthorized, "WebDAV rejected credentials")
				}
			}
			if resp.StatusCode >= 300 && resp.StatusCode < 400 {
				loc := resp.Header.Get("Location")
				if loc == "" {
					return resp, nil
				}
				nextU, err := curr.Parse(loc)
				if err != nil {
					return resp, nil
				}
				_ = resp.Body.Close()
				curr = nextU
				continue
			}
			return resp, nil
		}
		return nil, NewError(ErrKindNetwork, "too many WebDAV redirects")
	}

	resp, _, err := d.withFallback(ctx, doStream)
	if err != nil {
		return RangeResult{}, err
	}

	switch resp.StatusCode {
	case http.StatusPartialContent:
		rStart, rEnd, rTotal := parseContentRangeHeader(resp.Header.Get("Content-Range"))
		if rTotal > 0 {
			totalSize = rTotal
		}
		if rEnd < 0 && totalSize > 0 {
			rEnd = totalSize - 1
		}
		return RangeResult{
			Body:      resp.Body,
			TotalSize: totalSize,
			Start:     rStart,
			End:       rEnd,
		}, nil
	case http.StatusOK:
		if cl := resp.ContentLength; cl >= 0 {
			totalSize = cl
		}
		effectiveEnd := int64(-1)
		if totalSize > 0 {
			effectiveEnd = totalSize - 1
		}
		// Some servers ignore Range on GET and return 200 OK from byte 0.
		if start > 0 {
			if _, err := io.CopyN(io.Discard, resp.Body, start); err != nil && !errors.Is(err, io.EOF) {
				_ = resp.Body.Close()
				return RangeResult{}, NewError(ErrKindNetwork, "skip to requested range start failed", err)
			}
		}
		var body io.ReadCloser = resp.Body
		if end != nil {
			effectiveEnd = *end
			if totalSize > 0 && effectiveEnd >= totalSize {
				effectiveEnd = totalSize - 1
			}
			limit := effectiveEnd - start + 1
			if limit < 0 {
				limit = 0
			}
			body = struct {
				io.Reader
				io.Closer
			}{
				Reader: io.LimitReader(resp.Body, limit),
				Closer: resp.Body,
			}
		}
		return RangeResult{
			Body:      body,
			TotalSize: totalSize,
			Start:     start,
			End:       effectiveEnd,
		}, nil
	case http.StatusNotFound:
		_ = resp.Body.Close()
		return RangeResult{}, NewError(ErrKindNotFound, "not found: "+entry.Path)
	case http.StatusUnauthorized, http.StatusForbidden:
		_ = resp.Body.Close()
		return RangeResult{}, NewError(ErrKindUnauthorized, "WebDAV rejected credentials")
	default:
		_ = resp.Body.Close()
		return RangeResult{}, NewError(ErrKindOther, fmt.Sprintf("WebDAV answered HTTP %d", resp.StatusCode))
	}
}

func parseContentRangeHeader(h string) (start, end, total int64) {
	start, end, total = 0, -1, -1
	h = strings.TrimSpace(h)
	if !strings.HasPrefix(strings.ToLower(h), "bytes ") {
		return
	}
	rest := strings.TrimSpace(h[6:])
	slash := strings.IndexByte(rest, '/')
	if slash < 0 {
		return
	}
	rangePart := rest[:slash]
	totalPart := rest[slash+1:]
	if totalPart != "*" {
		if t, err := strconv.ParseInt(totalPart, 10, 64); err == nil {
			total = t
		}
	}
	dash := strings.IndexByte(rangePart, '-')
	if dash >= 0 {
		if s, err := strconv.ParseInt(rangePart[:dash], 10, 64); err == nil {
			start = s
		}
		if e, err := strconv.ParseInt(rangePart[dash+1:], 10, 64); err == nil {
			end = e
		}
	}
	return
}

func (d *WebDavDriver) Close() error {
	d.client.CloseIdleConnections()
	return nil
}

// ─── WebDAV MultiStatus XML Parser ─────────────────────────────────────────

type davMultistatus struct {
	Responses []davResponse `xml:"response"`
}

type davResponse struct {
	Href      string        `xml:"href"`
	Propstats []davPropstat `xml:"propstat"`
}

type davPropstat struct {
	Status string  `xml:"status"`
	Prop   davProp `xml:"prop"`
}

type davProp struct {
	ResourceType     davResourceType `xml:"resourcetype"`
	GetContentLength string          `xml:"getcontentlength"`
	GetLastModified  string          `xml:"getlastmodified"`
}

type davResourceType struct {
	Collection *struct{} `xml:"collection"`
}

func parseMultiStatusXML(raw []byte, baseSegs []string) ([]Entry, error) {
	var ms davMultistatus
	if err := xml.Unmarshal(raw, &ms); err != nil {
		return nil, NewError(ErrKindOther, "malformed WebDAV XML", err)
	}
	entries := make([]Entry, 0, len(ms.Responses))
	for _, resp := range ms.Responses {
		p, ok := pathFromDavHref(resp.Href, baseSegs)
		if !ok {
			continue
		}
		var chosenProp *davProp
		for i := range resp.Propstats {
			st := resp.Propstats[i].Status
			if st == "" || strings.Contains(st, " 200") {
				chosenProp = &resp.Propstats[i].Prop
				break
			}
		}
		isDir := strings.HasSuffix(strings.TrimSpace(resp.Href), "/")
		var szPtr *int64
		var modPtr *int64
		if chosenProp != nil {
			if chosenProp.ResourceType.Collection != nil {
				isDir = true
			}
			if !isDir {
				if n, err := strconv.ParseInt(strings.TrimSpace(chosenProp.GetContentLength), 10, 64); err == nil && n >= 0 {
					szPtr = &n
				}
			}
			if rawDate := strings.TrimSpace(chosenProp.GetLastModified); rawDate != "" {
				if t, err := http.ParseTime(rawDate); err == nil {
					ms := t.UnixMilli()
					modPtr = &ms
				} else if t, err := time.Parse(time.RFC3339, rawDate); err == nil {
					ms := t.UnixMilli()
					modPtr = &ms
				}
			}
		}
		entries = append(entries, Entry{
			Path:       p,
			Name:       BaseName(p),
			IsDir:      isDir,
			Size:       szPtr,
			ModifiedAt: modPtr,
		})
	}
	return entries, nil
}

func pathFromDavHref(href string, baseSegs []string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(href))
	if err != nil {
		return "", false
	}
	segs := splitNonEmpty(u.Path)
	if len(segs) < len(baseSegs) {
		return "", false
	}
	for i := 0; i < len(baseSegs); i++ {
		if segs[i] != baseSegs[i] {
			return "", false
		}
	}
	rel := segs[len(baseSegs):]
	for _, s := range rel {
		if s == "." || s == ".." || strings.ContainsAny(s, `/\`) {
			return "", false
		}
	}
	if len(rel) == 0 {
		return RootPath, true
	}
	return "/" + strings.Join(rel, "/"), true
}
