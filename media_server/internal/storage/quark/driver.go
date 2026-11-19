package quark

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/storage"
)

const (
	defaultAPIBase        = "https://drive-pc.quark.cn/1/clouddrive"
	defaultWebPlayAPIBase = "https://drive.quark.cn/1/clouddrive"
	quarkReferer          = "https://pan.quark.cn"
	defaultRootFolderID   = "0"
	defaultIntervalMs     = 1000
	minIntervalMs         = 200
	folderPageSize        = 100
	searchPageSize        = 100
	linkLifetime          = 30 * time.Minute
	variantLifetime       = 20 * time.Minute
)

var renditionOrder = []string{"4k", "2k", "super", "high", "normal", "low"}

type AccountInfo struct {
	MemberType string `json:"member_type"`
	UsedBytes  int64  `json:"used_bytes"`
	TotalBytes int64  `json:"total_bytes"`
}

type Driver struct {
	mode            Mode
	rootFolderID    string
	apiBase         *url.URL
	playAPIBase     *url.URL
	wsg             *Wsg
	pcSession       PcSession
	cookieMu        sync.RWMutex
	webCookie       string
	onCookieChanged func(string)

	apiClient    *http.Client
	streamClient *http.Client

	throttleMu  sync.Mutex
	minInterval time.Duration
	lastCall    time.Time

	cacheMu     sync.RWMutex
	folderIDs   map[string]string
	links       map[string]cachedLink
	rawLinks    map[string]cachedLink
	variants    map[string]cachedVariants
	account     *AccountInfo
	accountExp  time.Time
}

type cachedLink struct {
	link      storage.DirectLink
	expiresAt time.Time
}

type cachedVariants struct {
	list      []storage.StreamVariant
	expiresAt time.Time
}

type DriverOptions struct {
	Mode            Mode
	Secret          string
	RootFolderID    string
	RequestInterval time.Duration
	APIBase         string
	PlayAPIBase     string
	OnSecretUpdate  func(key, val string)
	FallbackDevice  *PcDevice
}

func NewDriver(cfg storage.MountConfig, onSecretUpdate func(key, val string)) (*Driver, error) {
	return NewDriverWithDevice(cfg, onSecretUpdate, nil)
}

func NewDriverWithDevice(cfg storage.MountConfig, onSecretUpdate func(key, val string), provider func() PcDevice) (*Driver, error) {
	secret := cfg.Secrets["cookie"]
	if strings.TrimSpace(secret) == "" {
		return nil, storage.NewError(storage.ErrKindUnauthorized, "Quark mount has no credentials")
	}
	mode := ParseMode(storage.CfgString(cfg.Config, "quarkMode"))
	// Auto-detect JSON PC session if mode wasn't explicitly saved.
	if storage.CfgString(cfg.Config, "quarkMode") == "" && strings.HasPrefix(strings.TrimSpace(secret), "{") {
		mode = ModePC
	}
	rootID := storage.CfgString(cfg.Config, "rootFolderId")
	if rootID == "" {
		rootID = defaultRootFolderID
	}
	intervalMs := storage.CfgInt(cfg.Config, "requestIntervalMs", defaultIntervalMs)
	if intervalMs < minIntervalMs {
		intervalMs = minIntervalMs
	}
	var fallback *PcDevice
	if mode == ModePC && provider != nil {
		dev := provider()
		fallback = &dev
	}
	return NewDriverWithOptions(DriverOptions{
		Mode:            mode,
		Secret:          secret,
		RootFolderID:    rootID,
		RequestInterval: time.Duration(intervalMs) * time.Millisecond,
		OnSecretUpdate:  onSecretUpdate,
		FallbackDevice:  fallback,
	})
}

func NewDriverWithOptions(opts DriverOptions) (*Driver, error) {
	if strings.TrimSpace(opts.Secret) == "" {
		return nil, storage.NewError(storage.ErrKindUnauthorized, "Quark mount has no credentials")
	}
	rawAPI := strings.TrimSpace(opts.APIBase)
	if rawAPI == "" {
		rawAPI = defaultAPIBase
	}
	apiURL, err := url.Parse(strings.TrimRight(rawAPI, "/"))
	if err != nil {
		return nil, storage.NewError(storage.ErrKindOther, "invalid Quark apiBase", err)
	}
	rawPlay := strings.TrimSpace(opts.PlayAPIBase)
	if rawPlay == "" {
		if opts.Mode == ModePC {
			rawPlay = rawAPI
		} else if strings.TrimSpace(opts.APIBase) != "" {
			rawPlay = rawAPI
		} else {
			rawPlay = defaultWebPlayAPIBase
		}
	}
	playURL, err := url.Parse(strings.TrimRight(rawPlay, "/"))
	if err != nil {
		return nil, storage.NewError(storage.ErrKindOther, "invalid Quark playApiBase", err)
	}

	rootID := strings.TrimSpace(opts.RootFolderID)
	if rootID == "" {
		rootID = defaultRootFolderID
	}
	interval := opts.RequestInterval
	if interval <= 0 {
		interval = time.Duration(defaultIntervalMs) * time.Millisecond
	}

	tr := http.DefaultTransport.(*http.Transport).Clone()
	d := &Driver{
		mode:         opts.Mode,
		rootFolderID: rootID,
		apiBase:      apiURL,
		playAPIBase:  playURL,
		wsg:          NewWsg(),
		apiClient: &http.Client{
			Transport: tr,
			Timeout:   30 * time.Second,
		},
		streamClient: &http.Client{
			Transport: tr,
		},
		minInterval: interval,
		folderIDs:   map[string]string{storage.RootPath: rootID},
		links:       make(map[string]cachedLink),
		rawLinks:    make(map[string]cachedLink),
		variants:    make(map[string]cachedVariants),
	}
	if opts.OnSecretUpdate != nil {
		d.onCookieChanged = func(newCookie string) {
			opts.OnSecretUpdate("cookie", newCookie)
		}
	}
	if opts.Mode == ModePC {
		d.pcSession = ParsePcSessionWithFallback(opts.Secret, opts.FallbackDevice)
		if !d.pcSession.IsValid() {
			return nil, storage.NewError(storage.ErrKindUnauthorized, "invalid Quark PC session")
		}
	} else {
		d.webCookie = strings.TrimSpace(opts.Secret)
	}
	return d, nil
}

func (d *Driver) Kind() string               { return "quark" }
func (d *Driver) SupportsIncremental() bool  { return true }
func (d *Driver) RootFolderID() string       { return d.rootFolderID }

func (d *Driver) userAgent() string {
	if d.mode == ModePC {
		return pcUserAgent
	}
	return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
}

func (d *Driver) waitThrottle(ctx context.Context) error {
	d.throttleMu.Lock()
	now := time.Now()
	next := d.lastCall.Add(d.minInterval)
	if next.After(now) {
		wait := next.Sub(now)
		d.lastCall = next
		d.throttleMu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
			return nil
		}
	}
	d.lastCall = now
	d.throttleMu.Unlock()
	return nil
}

func (d *Driver) apiCall(
	ctx context.Context,
	method string,
	apiPath string,
	query map[string]string,
	body map[string]any,
	baseOverride *url.URL,
	wsgBody bool,
	explicitCookie string,
) (map[string]any, []string, error) {
	if err := d.waitThrottle(ctx); err != nil {
		return nil, nil, err
	}

	base := d.apiBase
	if baseOverride != nil {
		base = baseOverride
	}
	u := *base
	u.Path = strings.TrimRight(base.Path, "/") + apiPath

	q := url.Values{}
	if d.mode == ModePC {
		common, err := d.pcSession.CommonQuery(d.wsg)
		if err != nil {
			return nil, nil, err
		}
		for k, v := range common {
			q.Set(k, v)
		}
	} else {
		q.Set("pr", "ucpro")
		q.Set("fr", "pc")
	}
	for k, v := range query {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()

	var bodyReader io.Reader
	var contentEncoding string
	if body != nil {
		jsonBytes, err := json.Marshal(body)
		if err != nil {
			return nil, nil, err
		}
		if d.mode == ModePC && wsgBody {
			enc, err := d.wsg.Encode(string(jsonBytes))
			if err != nil {
				return nil, nil, err
			}
			bodyReader = strings.NewReader(enc)
			contentEncoding = "wg"
		} else {
			bodyReader = bytes.NewReader(jsonBytes)
		}
	}

	req, err := http.NewRequestWithContext(ctx, method, u.String(), bodyReader)
	if err != nil {
		return nil, nil, storage.NewError(storage.ErrKindOther, "invalid Quark request", err)
	}
	req.Header.Set("User-Agent", d.userAgent())
	req.Header.Set("Referer", quarkReferer)
	req.Header.Set("Accept", "application/json, text/plain, */*")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		if contentEncoding != "" {
			req.Header.Set("x-u-content-encoding", contentEncoding)
		}
	}

	if d.mode == ModePC {
		bh, err := d.pcSession.BusinessHeaders(d.wsg, time.Now())
		if err != nil {
			return nil, nil, err
		}
		for k, v := range bh {
			req.Header.Set(k, v)
		}
		if explicitCookie != "" {
			req.Header.Set("Cookie", explicitCookie)
		}
	} else {
		d.cookieMu.RLock()
		ck := d.webCookie
		d.cookieMu.RUnlock()
		req.Header.Set("Cookie", ck)
	}

	resp, err := d.apiClient.Do(req)
	if err != nil {
		return nil, nil, storage.NewError(storage.ErrKindNetwork, "cannot reach Quark", err)
	}
	defer resp.Body.Close()

	setCookies := resp.Header.Values("Set-Cookie")
	if d.mode == ModeWeb && len(setCookies) > 0 {
		d.absorbWebCookies(setCookies)
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		return nil, setCookies, storage.NewError(storage.ErrKindNetwork, "read Quark response failed", err)
	}

	var parsed map[string]any
	_ = json.Unmarshal(raw, &parsed)

	codeVal, hasCode := asInt(parsed["code"])
	statusVal, hasStatus := asInt(parsed["status"])
	failed := resp.StatusCode >= 400 || parsed == nil || (hasCode && codeVal != 0) || (hasStatus && statusVal >= 400)
	if !failed {
		return parsed, setCookies, nil
	}

	msg := strVal(parsed["message"])
	if msg == "" {
		msg = fmt.Sprintf("HTTP %d", resp.StatusCode)
	}
	eff := resp.StatusCode
	if hasStatus && statusVal >= 400 {
		eff = statusVal
	}
	kind := storage.ErrKindOther
	lowerMsg := strings.ToLower(msg)
	if eff == http.StatusUnauthorized || strings.Contains(lowerMsg, "require login") {
		kind = storage.ErrKindUnauthorized
	} else if eff == http.StatusTooManyRequests {
		kind = storage.ErrKindRateLimited
	} else if eff == http.StatusNotFound {
		kind = storage.ErrKindNotFound
	}
	return nil, setCookies, storage.NewError(kind, "Quark: "+msg)
}

func (d *Driver) absorbWebCookies(setCookies []string) {
	d.cookieMu.Lock()
	updated := d.webCookie
	changed := false
	for _, raw := range setCookies {
		k, v, ok := parseSetCookiePair(raw)
		if !ok {
			continue
		}
		if k != "__puus" && k != "__pus" {
			continue
		}
		next := replaceCookie(updated, k, v)
		if next != updated {
			updated = next
			changed = true
		}
	}
	if changed {
		d.webCookie = updated
	}
	d.cookieMu.Unlock()
	if changed && d.onCookieChanged != nil {
		d.onCookieChanged(updated)
	}
}

func replaceCookie(header, name, val string) string {
	parts := strings.Split(header, ";")
	out := make([]string, 0, len(parts)+1)
	found := false
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if strings.HasPrefix(p, name+"=") {
			out = append(out, name+"="+val)
			found = true
		} else {
			out = append(out, p)
		}
	}
	if !found {
		out = append(out, name+"="+val)
	}
	return strings.Join(out, "; ")
}

func extractCookieParam(header, name string) string {
	for _, p := range strings.Split(header, ";") {
		k, v, ok := parseSetCookiePair(p)
		if ok && k == name {
			return v
		}
	}
	return ""
}

func (d *Driver) Check(ctx context.Context) error {
	if d.mode == ModePC {
		_, _, err := d.apiCall(ctx, http.MethodGet, "/file/sort", map[string]string{
			"pdir_fid": d.rootFolderID,
			"_size":    "1",
			"_page":    "1",
		}, nil, nil, false, "")
		return err
	}
	_, _, err := d.apiCall(ctx, http.MethodGet, "/config", nil, nil, nil, false, "")
	return err
}

func (d *Driver) AccountInfo(ctx context.Context) (AccountInfo, error) {
	d.cacheMu.RLock()
	if d.account != nil && time.Now().Before(d.accountExp) {
		acc := *d.account
		d.cacheMu.RUnlock()
		return acc, nil
	}
	d.cacheMu.RUnlock()

	res, _, err := d.apiCall(ctx, http.MethodGet, "/member", nil, nil, nil, false, "")
	if err != nil {
		return AccountInfo{}, err
	}
	data, _ := res["data"].(map[string]any)
	if data == nil {
		return AccountInfo{}, storage.NewError(storage.ErrKindOther, "Quark: invalid member response")
	}
	acc := AccountInfo{
		MemberType: strings.TrimSpace(strVal(data["member_type"])),
		UsedBytes:  asInt64(data["use_capacity"]),
		TotalBytes: asInt64(data["total_capacity"]),
	}
	d.cacheMu.Lock()
	d.account = &acc
	d.accountExp = time.Now().Add(2 * time.Minute)
	d.cacheMu.Unlock()
	return acc, nil
}

func (d *Driver) List(ctx context.Context, mountPath string, parent *storage.Entry) ([]storage.Entry, error) {
	norm := storage.NormalizePath(mountPath)
	folderID := ""
	if parent != nil && parent.ID != "" {
		folderID = parent.ID
	} else {
		var err error
		folderID, err = d.resolveFolderID(ctx, norm)
		if err != nil {
			return nil, err
		}
	}
	return d.listFolder(ctx, norm, folderID)
}

func (d *Driver) resolveFolderID(ctx context.Context, norm string) (string, error) {
	d.cacheMu.RLock()
	if id, ok := d.folderIDs[norm]; ok {
		d.cacheMu.RUnlock()
		return id, nil
	}
	segs := storage.PathSegments(norm)
	depth := len(segs) - 1
	for depth > 0 {
		ancestor := "/" + strings.Join(segs[:depth], "/")
		if _, ok := d.folderIDs[ancestor]; ok {
			break
		}
		depth--
	}
	d.cacheMu.RUnlock()

	for i := depth; i < len(segs); i++ {
		parentPath := storage.RootPath
		if i > 0 {
			parentPath = "/" + strings.Join(segs[:i], "/")
		}
		d.cacheMu.RLock()
		pid := d.folderIDs[parentPath]
		d.cacheMu.RUnlock()
		if _, err := d.listFolder(ctx, parentPath, pid); err != nil {
			return "", err
		}
		childPath := "/" + strings.Join(segs[:i+1], "/")
		d.cacheMu.RLock()
		_, ok := d.folderIDs[childPath]
		d.cacheMu.RUnlock()
		if !ok {
			return "", storage.NewError(storage.ErrKindNotFound, "not found: "+childPath)
		}
	}

	d.cacheMu.RLock()
	id := d.folderIDs[norm]
	d.cacheMu.RUnlock()
	return id, nil
}

func (d *Driver) listFolder(ctx context.Context, dirPath, folderID string) ([]storage.Entry, error) {
	out := make([]storage.Entry, 0)
	for page := 1; ; page++ {
		res, _, err := d.apiCall(ctx, http.MethodGet, "/file/sort", map[string]string{
			"pdir_fid":     folderID,
			"_size":        strconv.Itoa(folderPageSize),
			"_page":        strconv.Itoa(page),
			"_fetch_total": "1",
			"_sort":        "file_type:asc,file_name:asc",
		}, nil, nil, false, "")
		if err != nil {
			return nil, err
		}
		rows := extractRows(res)
		for _, r := range rows {
			e, ok := entryFromRow(dirPath, r)
			if !ok {
				continue
			}
			out = append(out, e)
			if e.IsDir && e.ID != "" {
				d.cacheMu.Lock()
				d.folderIDs[e.Path] = e.ID
				d.cacheMu.Unlock()
			}
		}
		meta, _ := res["metadata"].(map[string]any)
		total, hasTotal := asInt(meta["_total"])
		if len(rows) < folderPageSize || (hasTotal && page*folderPageSize >= total) {
			break
		}
	}
	return out, nil
}

func (d *Driver) Stat(ctx context.Context, mountPath string) (storage.Entry, error) {
	norm := storage.NormalizePath(mountPath)
	if norm == storage.RootPath {
		return storage.Entry{Path: storage.RootPath, Name: "", IsDir: true, ID: d.rootFolderID}, nil
	}
	siblings, err := d.List(ctx, storage.ParentPath(norm), nil)
	if err != nil {
		return storage.Entry{}, err
	}
	for _, e := range siblings {
		if e.Path == norm {
			return e, nil
		}
	}
	return storage.Entry{}, storage.NewError(storage.ErrKindNotFound, "not found: "+norm)
}

func (d *Driver) SearchUpdatedPage(ctx context.Context, page, size int) ([]storage.IncrementalUpdate, error) {
	if size <= 0 {
		size = searchPageSize
	}
	res, _, err := d.apiCall(ctx, http.MethodGet, "/file/search", map[string]string{
		"q":     "",
		"cat":   "video",
		"_sort": "updated_at:desc",
		"_page": strconv.Itoa(page),
		"_size": strconv.Itoa(size),
	}, nil, nil, false, "")
	if err != nil {
		return nil, err
	}
	rows := extractRows(res)
	out := make([]storage.IncrementalUpdate, 0, len(rows))
	for _, r := range rows {
		e, ok := entryFromRow(storage.RootPath, r)
		if !ok {
			continue
		}
		updatedAt := asInt64(r["updated_at"])
		if updatedAt <= 0 {
			continue
		}
		out = append(out, storage.IncrementalUpdate{
			Entry:     e,
			ParentID:  strVal(r["pdir_fid"]),
			UpdatedAt: updatedAt,
		})
	}
	return out, nil
}

func (d *Driver) FolderAncestry(ctx context.Context, folderID string) ([]struct{ ID, Name string }, error) {
	if folderID == "" || folderID == defaultRootFolderID {
		return nil, nil
	}
	res, _, err := d.apiCall(ctx, http.MethodGet, "/file/sort", map[string]string{
		"pdir_fid":         folderID,
		"_size":            "1",
		"_page":            "1",
		"_fetch_full_path": "1",
	}, nil, nil, false, "")
	if err != nil {
		return nil, err
	}
	data, _ := res["data"].(map[string]any)
	rawPath, _ := data["full_path"].([]any)
	var ancestry []struct{ ID, Name string }
	for _, item := range rawPath {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		fid := strVal(m["fid"])
		if fid == "" || fid == defaultRootFolderID {
			continue
		}
		name := strVal(m["file_name"])
		if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
			return nil, storage.NewError(storage.ErrKindOther, "Quark: invalid folder ancestry entry")
		}
		ancestry = append(ancestry, struct{ ID, Name string }{ID: fid, Name: name})
	}
	return ancestry, nil
}

func extractRows(res map[string]any) []map[string]any {
	data, _ := res["data"].(map[string]any)
	rawList, _ := data["list"].([]any)
	out := make([]map[string]any, 0, len(rawList))
	for _, item := range rawList {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func entryFromRow(parentPath string, row map[string]any) (storage.Entry, bool) {
	fid := strVal(row["fid"])
	name := strVal(row["file_name"])
	if fid == "" || name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return storage.Entry{}, false
	}
	isFile := false
	if dirVal, ok := row["dir"].(bool); ok {
		isFile = !dirVal
	} else if fileVal, ok := row["file"].(bool); ok {
		isFile = fileVal
	}
	e := storage.Entry{
		Path:  storage.JoinPath(parentPath, name),
		Name:  name,
		IsDir: !isFile,
		ID:    fid,
	}
	if isFile {
		if sz := asInt64(row["size"]); sz >= 0 {
			e.Size = &sz
		}
		if md5 := strVal(row["md5"]); md5 != "" {
			e.Hash = md5
		}
	}
	if ca := asInt64(row["created_at"]); ca > 0 {
		e.CreatedAt = &ca
	}
	if ua := asInt64(row["updated_at"]); ua > 0 {
		e.ModifiedAt = &ua
	}
	return e, true
}

func (d *Driver) cdnHeaders(videoAuth string) (map[string]string, error) {
	if d.mode == ModePC {
		kuus, err := d.pcSession.KuusCookie(d.wsg, time.Now())
		if err != nil {
			return nil, err
		}
		ck := kuus
		if videoAuth != "" {
			ck = kuus + "; Video-Auth=" + videoAuth
		}
		return map[string]string{
			"Cookie":     ck,
			"Referer":    quarkReferer + "/",
			"User-Agent": d.userAgent(),
		}, nil
	}
	d.cookieMu.RLock()
	ck := d.webCookie
	d.cookieMu.RUnlock()
	if videoAuth != "" {
		ck = replaceCookie(ck, "Video-Auth", videoAuth)
	}
	return map[string]string{
		"Cookie":     ck,
		"Referer":    quarkReferer + "/",
		"User-Agent": d.userAgent(),
	}, nil
}

func (d *Driver) refreshLinkHeaders(cached map[string]string) (map[string]string, error) {
	va := extractCookieParam(cached["Cookie"], "Video-Auth")
	return d.cdnHeaders(va)
}

func (d *Driver) ResolveDirectLink(ctx context.Context, entry storage.Entry, forceRefresh bool) (storage.DirectLink, error) {
	fid := entry.ID
	if fid == "" {
		st, err := d.Stat(ctx, entry.Path)
		if err != nil {
			return storage.DirectLink{}, err
		}
		fid = st.ID
	}
	if fid == "" {
		return storage.DirectLink{}, storage.NewError(storage.ErrKindNotFound, "missing fid for "+entry.Path)
	}

	now := time.Now()
	if !forceRefresh {
		d.cacheMu.RLock()
		cl, ok := d.links[fid]
		raw, hasRaw := d.rawLinks[fid]
		d.cacheMu.RUnlock()
		if ok && cl.expiresAt.After(now) {
			hdrs, err := d.refreshLinkHeaders(cl.link.Headers)
			if err != nil {
				return storage.DirectLink{}, err
			}
			out := cl.link
			out.Headers = hdrs
			return out, nil
		}
		if d.mode == ModePC && hasRaw && raw.expiresAt.After(now) {
			hdrs, err := d.refreshLinkHeaders(raw.link.Headers)
			if err != nil {
				return storage.DirectLink{}, err
			}
			out := raw.link
			out.Headers = hdrs
			return out, nil
		}
	} else {
		d.cacheMu.Lock()
		delete(d.links, fid)
		delete(d.rawLinks, fid)
		d.cacheMu.Unlock()
	}

	link, err := d.fetchDownloadLink(ctx, fid)
	if err == nil {
		exp := time.Now().Add(linkLifetime)
		link.ExpiresAt = exp.UnixMilli()
		d.cacheMu.Lock()
		d.links[fid] = cachedLink{link: link, expiresAt: exp}
		d.cacheMu.Unlock()
		return link, nil
	}

	if d.mode == ModePC && !storage.IsKind(err, storage.ErrKindUnauthorized) && !storage.IsKind(err, storage.ErrKindRateLimited) {
		if _, vErr := d.loadVariants(ctx, fid, true); vErr == nil {
			d.cacheMu.RLock()
			raw, ok := d.rawLinks[fid]
			d.cacheMu.RUnlock()
			if ok {
				return raw.link, nil
			}
		}
	}
	return storage.DirectLink{}, err
}

func (d *Driver) fetchDownloadLink(ctx context.Context, fid string) (storage.DirectLink, error) {
	var kuus string
	var err error
	if d.mode == ModePC {
		kuus, err = d.pcSession.KuusCookie(d.wsg, time.Now())
		if err != nil {
			return storage.DirectLink{}, err
		}
	}
	res, setCookies, err := d.apiCall(ctx, http.MethodPost, "/file/download", nil, map[string]any{
		"fids": []string{fid},
	}, nil, d.mode == ModePC, kuus)
	if err != nil {
		return storage.DirectLink{}, err
	}
	data, _ := res["data"].([]any)
	var dlURL string
	if len(data) > 0 {
		if first, ok := data[0].(map[string]any); ok {
			dlURL = strVal(first["download_url"])
		}
	}
	if dlURL == "" {
		return storage.DirectLink{}, storage.NewError(storage.ErrKindOther, "Quark returned no download link")
	}
	var va string
	for _, sc := range setCookies {
		if k, v, ok := parseSetCookiePair(sc); ok && k == "Video-Auth" {
			va = v
			break
		}
	}
	hdrs, err := d.cdnHeaders(va)
	if err != nil {
		return storage.DirectLink{}, err
	}
	return storage.DirectLink{
		URL:     dlURL,
		Headers: hdrs,
	}, nil
}

func (d *Driver) StreamVariants(ctx context.Context, entry storage.Entry, forceRefresh bool) ([]storage.StreamVariant, error) {
	fid := entry.ID
	if fid == "" {
		st, err := d.Stat(ctx, entry.Path)
		if err != nil {
			return nil, err
		}
		fid = st.ID
	}
	if fid == "" {
		return nil, storage.NewError(storage.ErrKindNotFound, "missing fid for "+entry.Path)
	}
	return d.loadVariants(ctx, fid, forceRefresh)
}

func rankRendition(id string) int {
	for i, r := range renditionOrder {
		if r == id {
			return i
		}
	}
	return len(renditionOrder)
}

func (d *Driver) loadVariants(ctx context.Context, fid string, forceRefresh bool) ([]storage.StreamVariant, error) {
	if !forceRefresh {
		d.cacheMu.RLock()
		cv, ok := d.variants[fid]
		d.cacheMu.RUnlock()
		if ok && cv.expiresAt.After(time.Now()) {
			return cv.list, nil
		}
	}

	var rows []any
	var va string
	if d.mode == ModePC {
		kuus, err := d.pcSession.KuusCookie(d.wsg, time.Now())
		if err != nil {
			return nil, err
		}
		res, setCookies, err := d.apiCall(ctx, http.MethodPost, "/batch/file/play/info", nil, map[string]any{
			"fids":                              []string{fid},
			"resolutions":                       "normal,low,high,super,2k,4k",
			"supports":                          "m3u8,fmp4,apollo,dolby_vision,dolby_low",
			"fetch_credits_setting":             1,
			"fetch_play_video_resolution_setting": 1,
			"fetch_play_audio_type_setting":     1,
			"support_resolution_free_limit_ab":  1,
			"fetch_pdir":                        1,
			"support_right":                     "trial_1080P_zhizhen_pc",
		}, d.playAPIBase, true, kuus)
		if err != nil {
			return nil, err
		}
		for _, sc := range setCookies {
			if k, v, ok := parseSetCookiePair(sc); ok && k == "Video-Auth" {
				va = v
			}
		}
		data, _ := res["data"].(map[string]any)
		if item, ok := data[fid].(map[string]any); ok {
			rows, _ = item["video_list"].([]any)
		} else if data != nil {
			for _, anyV := range data {
				if item, ok := anyV.(map[string]any); ok {
					rows, _ = item["video_list"].([]any)
					break
				}
			}
		}
	} else {
		res, setCookies, err := d.apiCall(ctx, http.MethodPost, "/file/v2/play", nil, map[string]any{
			"fid":         fid,
			"resolutions": "low,normal,high,super,2k,4k",
			"supports":    "m3u8,fmp4,apollo,dolby_vision,dolby_low",
		}, d.playAPIBase, false, "")
		if err != nil {
			return nil, err
		}
		for _, sc := range setCookies {
			if k, v, ok := parseSetCookiePair(sc); ok && k == "Video-Auth" {
				va = v
			}
		}
		data, _ := res["data"].(map[string]any)
		rows, _ = data["video_list"].([]any)
	}

	headers, err := d.cdnHeaders(va)
	if err != nil {
		return nil, err
	}

	exp := time.Now().Add(variantLifetime)
	seen := make(map[string]bool)
	variants := make([]storage.StreamVariant, 0, len(rows))
	var bestRaw *cachedLink
	bestRank := len(renditionOrder) + 1

	for _, rAny := range rows {
		row, ok := rAny.(map[string]any)
		if !ok {
			continue
		}
		if acc, ok := row["accessable"].(bool); ok && !acc {
			continue
		}
		resID := strVal(row["resolution"])
		vInfo, _ := row["video_info"].(map[string]any)
		linkURL := strVal(vInfo["url"])
		if resID == "" || linkURL == "" || seen[resID] {
			continue
		}
		seen[resID] = true
		u, uErr := url.Parse(linkURL)
		if uErr != nil || u.Scheme == "" {
			continue
		}
		formatStr := strings.ToLower(strVal(vInfo["format"]))
		isHLS := strings.HasSuffix(strings.ToLower(u.Path), ".m3u8") || strings.Contains(formatStr, "m3u8")
		w, _ := asInt(vInfo["width"])
		h, _ := asInt(vInfo["height"])

		variants = append(variants, storage.StreamVariant{
			ID:      resID,
			URL:     linkURL,
			Headers: headers,
			Width:   w,
			Height:  h,
			IsHLS:   isHLS,
		})
		if !isHLS && strVal(row["trans_status"]) == "raw" {
			rk := rankRendition(resID)
			if rk < bestRank {
				bestRank = rk
				bestRaw = &cachedLink{
					link:      storage.DirectLink{URL: linkURL, Headers: headers, ExpiresAt: exp.UnixMilli()},
					expiresAt: exp,
				}
			}
		}
	}

	sort.Slice(variants, func(i, j int) bool {
		return rankRendition(variants[i].ID) < rankRendition(variants[j].ID)
	})

	d.cacheMu.Lock()
	d.variants[fid] = cachedVariants{list: variants, expiresAt: exp}
	if bestRaw != nil {
		d.rawLinks[fid] = *bestRaw
	} else {
		delete(d.rawLinks, fid)
	}
	d.cacheMu.Unlock()
	return variants, nil
}

func (d *Driver) FetchVariantURL(ctx context.Context, targetURL string, headers map[string]string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return d.streamClient.Do(req)
}

func (d *Driver) OpenRange(ctx context.Context, entry storage.Entry, start int64, end *int64, forceRefresh bool) (storage.RangeResult, error) {
	if entry.IsDir {
		return storage.RangeResult{}, storage.NewError(storage.ErrKindUnsupported, "cannot stream a directory")
	}

	var totalSize int64 = -1
	if entry.Size != nil {
		totalSize = *entry.Size
	}

	for attempt := 0; attempt < 2; attempt++ {
		dl, err := d.ResolveDirectLink(ctx, entry, forceRefresh || attempt > 0)
		if err != nil {
			return storage.RangeResult{}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, dl.URL, nil)
		if err != nil {
			return storage.RangeResult{}, storage.NewError(storage.ErrKindOther, "invalid Quark download URL", err)
		}
		for k, v := range dl.Headers {
			req.Header.Set(k, v)
		}
		if end != nil {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, *end))
		} else if start > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", start))
		}

		resp, err := d.streamClient.Do(req)
		if err != nil {
			return storage.RangeResult{}, storage.NewError(storage.ErrKindNetwork, "Quark CDN stream failed", err)
		}

		if (resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusPreconditionFailed) && attempt == 0 {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			continue
		}

		switch resp.StatusCode {
		case http.StatusPartialContent:
			rStart, rEnd, rTotal := parseContentRange(resp.Header.Get("Content-Range"))
			if rTotal > 0 {
				totalSize = rTotal
			}
			if rEnd < 0 && totalSize > 0 {
				rEnd = totalSize - 1
			}
			return storage.RangeResult{
				Body:      resp.Body,
				TotalSize: totalSize,
				Start:     rStart,
				End:       rEnd,
			}, nil
		case http.StatusOK:
			if resp.ContentLength >= 0 {
				totalSize = resp.ContentLength
			}
			effectiveEnd := int64(-1)
			if totalSize > 0 {
				effectiveEnd = totalSize - 1
			}
			if start > 0 {
				if _, err := io.CopyN(io.Discard, resp.Body, start); err != nil && !errors.Is(err, io.EOF) {
					_ = resp.Body.Close()
					return storage.RangeResult{}, storage.NewError(storage.ErrKindNetwork, "skip to requested range start failed", err)
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
			return storage.RangeResult{
				Body:      body,
				TotalSize: totalSize,
				Start:     start,
				End:       effectiveEnd,
			}, nil
		case http.StatusNotFound:
			_ = resp.Body.Close()
			return storage.RangeResult{}, storage.NewError(storage.ErrKindNotFound, "file not found on Quark CDN")
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusPreconditionFailed:
			_ = resp.Body.Close()
			return storage.RangeResult{}, storage.NewError(storage.ErrKindUnauthorized, fmt.Sprintf("Quark CDN rejected request (HTTP %d)", resp.StatusCode))
		default:
			_ = resp.Body.Close()
			return storage.RangeResult{}, storage.NewError(storage.ErrKindOther, fmt.Sprintf("Quark CDN answered HTTP %d", resp.StatusCode))
		}
	}
	return storage.RangeResult{}, storage.NewError(storage.ErrKindUnauthorized, "Quark CDN failed after link refresh")
}

func (d *Driver) Close() error {
	d.apiClient.CloseIdleConnections()
	d.streamClient.CloseIdleConnections()
	return nil
}

func asInt64(v any) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int:
		return int64(x)
	case float64:
		return int64(x)
	case json.Number:
		i, _ := x.Int64()
		return i
	case string:
		i, _ := strconv.ParseInt(strings.TrimSpace(x), 10, 64)
		return i
	default:
		return 0
	}
}

func parseContentRange(h string) (start, end, total int64) {
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
