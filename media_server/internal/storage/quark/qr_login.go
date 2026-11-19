package quark

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"plezy/media_server/internal/storage"
)

type Mode string

const (
	ModePC  Mode = "pc"
	ModeWeb Mode = "web"
)

func ParseMode(raw string) Mode {
	if strings.EqualFold(strings.TrimSpace(raw), "pc") {
		return ModePC
	}
	return ModeWeb
}

type QrStartResult struct {
	SessionID string `json:"session_id"`
	Mode      string `json:"mode"`
	QRContent string `json:"qr_content"`
	ExpiresAt int64  `json:"expires_at_ms"`
}

type QrPollResult struct {
	Status  string `json:"status"` // waiting | expired | confirmed
	Secret  string `json:"secret,omitempty"`
	Message string `json:"message,omitempty"`
}

type qrTicket struct {
	ID        string
	Mode      Mode
	Token     string
	QRContent string
	Cookies   map[string]string
	Device    PcDevice
	ExpiresAt time.Time
}

type QrManager struct {
	mu           sync.Mutex
	tickets      map[string]*qrTicket
	client       *http.Client
	wsg          *Wsg
	pcGateway    string
	webCasBase   string
	webPanBase   string
	cookieSuffix string
}

func NewQrManager() *QrManager {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	return &QrManager{
		tickets: make(map[string]*qrTicket),
		client: &http.Client{
			Transport: tr,
			Timeout:   25 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		wsg:          NewWsg(),
		pcGateway:    "https://access-open.quark.cn/wsg_access",
		webCasBase:   "https://uop.quark.cn",
		webPanBase:   "https://pan.quark.cn",
		cookieSuffix: "quark.cn",
	}
}

func (m *QrManager) Start(ctx context.Context, modeRaw string) (QrStartResult, error) {
	m.pruneExpired()
	mode := ParseMode(modeRaw)
	var t *qrTicket
	var err error
	if mode == ModePC {
		t, err = m.startPC(ctx)
	} else {
		t, err = m.startWeb(ctx)
	}
	if err != nil {
		return QrStartResult{}, err
	}
	t.ID = uuid.NewString()
	t.ExpiresAt = time.Now().Add(5 * time.Minute)
	m.mu.Lock()
	m.tickets[t.ID] = t
	m.mu.Unlock()

	return QrStartResult{
		SessionID: t.ID,
		Mode:      string(t.Mode),
		QRContent: t.QRContent,
		ExpiresAt: t.ExpiresAt.UnixMilli(),
	}, nil
}

func (m *QrManager) Poll(ctx context.Context, sessionID string) (QrPollResult, error) {
	m.mu.Lock()
	t, ok := m.tickets[sessionID]
	m.mu.Unlock()
	if !ok {
		return QrPollResult{Status: "expired"}, nil
	}
	if time.Now().After(t.ExpiresAt) {
		m.mu.Lock()
		delete(m.tickets, sessionID)
		m.mu.Unlock()
		return QrPollResult{Status: "expired"}, nil
	}

	var res QrPollResult
	var err error
	if t.Mode == ModePC {
		res, err = m.pollPC(ctx, t)
	} else {
		res, err = m.pollWeb(ctx, t)
	}
	if err != nil {
		return QrPollResult{}, err
	}
	if res.Status == "confirmed" || res.Status == "expired" {
		m.mu.Lock()
		delete(m.tickets, sessionID)
		m.mu.Unlock()
	}
	return res, nil
}

func (m *QrManager) pruneExpired() {
	now := time.Now()
	m.mu.Lock()
	for id, t := range m.tickets {
		if now.After(t.ExpiresAt) {
			delete(m.tickets, id)
		}
	}
	m.mu.Unlock()
}

// ─── Quark PC QR Login ────────────────────────────────────────────────────

const (
	pcClientID      = "640"
	pcApiVersion    = "1.2"
	pcClientVersion = "7.5.0.825"
	pcUserAgent     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/7.5.0.825 QuarkCloudDrivePC/7.5.0.825"
)

func (m *QrManager) makeClientInfo(dev PcDevice) string {
	return strings.Join([]string{
		"app_name:qk_clouddrive",
		"bssid:",
		"client_identity:" + pcClientID,
		"idfa:",
		"imei:",
		"imsi:",
		"ip:",
		"mac:",
		"machine:" + dev.Machine,
		"net_id:",
		"net_type:",
		"os:Windows",
		"port:9001",
		"sn:",
		"ssid:",
		"utdid:" + dev.Utdid,
		"version:" + pcClientVersion,
	}, "`")
}

func (m *QrManager) gatewayCall(ctx context.Context, dev PcDevice, method string, extra map[string]string) (map[string]any, error) {
	fields := map[string]string{
		"client_id":   pcClientID,
		"client_info": m.makeClientInfo(dev),
		"method":      method,
		"request_id":  uuid.NewString(),
		"v":           pcApiVersion,
	}
	for k, v := range extra {
		fields[k] = v
	}
	fields["sign"] = m.wsg.Sign(fields)

	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, url.QueryEscape(k)+"="+url.QueryEscape(fields[k]))
	}
	encodedBody, err := m.wsg.Encode(strings.Join(parts, "&"))
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.pcGateway, strings.NewReader(encodedBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("User-Agent", pcUserAgent)

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, storage.NewError(storage.ErrKindNetwork, "cannot reach Quark gateway", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
	if err != nil {
		return nil, storage.NewError(storage.ErrKindNetwork, "read Quark gateway failed", err)
	}
	text := strings.TrimSpace(string(raw))
	payload := text
	if !strings.HasPrefix(text, "{") {
		decoded, decErr := m.wsg.DecodeText(text)
		if decErr != nil {
			return nil, storage.NewError(storage.ErrKindOther, "unreadable Quark login response", decErr)
		}
		payload = decoded
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(payload), &out); err != nil {
		return nil, storage.NewError(storage.ErrKindOther, "invalid Quark login JSON", err)
	}
	return out, nil
}

func (m *QrManager) startPC(ctx context.Context) (*qrTicket, error) {
	dev := GeneratePcDevice()
	res, err := m.gatewayCall(ctx, dev, "cas.getTokenForQrcodeLogin", nil)
	if err != nil {
		return nil, err
	}
	status, _ := asInt(res["status"])
	data, _ := res["data"].(map[string]any)
	token := strVal(data["token"])
	if status != 20000 || token == "" {
		return nil, storage.NewError(storage.ErrKindOther, fmt.Sprintf("Quark PC QR start failed: %v", res["message"]))
	}
	tid := strVal(data["__trace_id__"])
	if tid == "" {
		tid = uuid.NewString()
	}
	const bizOpts = "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
	qrURL := fmt.Sprintf(
		"https://su.quark.cn/1_uNQL3?uc_param_str=&token=%s&tid=%s&client_id=%s&uc_biz_str=%s&platform=win",
		url.QueryEscape(token), url.QueryEscape(tid), pcClientID, url.QueryEscape(bizOpts),
	)
	return &qrTicket{
		Mode:      ModePC,
		Token:     token,
		QRContent: qrURL,
		Device:    dev,
	}, nil
}

func (m *QrManager) pollPC(ctx context.Context, t *qrTicket) (QrPollResult, error) {
	res, err := m.gatewayCall(ctx, t.Device, "cas.getServiceTicketByQrcodeToken", map[string]string{
		"token": t.Token,
	})
	if err != nil {
		return QrPollResult{}, err
	}
	status, _ := asInt(res["status"])
	if status == 55402 {
		return QrPollResult{Status: "expired"}, nil
	}
	data, _ := res["data"].(map[string]any)
	st := strVal(data["service_ticket"])
	if status == 20000 && st != "" {
		userRes, err := m.gatewayCall(ctx, t.Device, "cas.getUserBasicInfoByServiceTicket", map[string]string{
			"service_ticket": st,
		})
		if err != nil {
			return QrPollResult{}, err
		}
		uStatus, _ := asInt(userRes["status"])
		uData, _ := userRes["data"].(map[string]any)
		if (uStatus != 20000 && uStatus != 20002) || uData == nil {
			return QrPollResult{}, storage.NewError(storage.ErrKindOther, fmt.Sprintf("Quark PC user fetch failed: %v", userRes["message"]))
		}
		refreshedTicket := strVal(uData["service_ticket"])
		uid := strVal(uData["uid_string"])
		if uid == "" {
			uid = strVal(uData["uid"])
		}
		nick := strVal(uData["nickname"])
		if refreshedTicket == "" || uid == "" {
			return QrPollResult{}, storage.NewError(storage.ErrKindOther, "Quark PC login returned empty session")
		}
		sess := PcSession{
			Ticket:   refreshedTicket,
			UID:      uid,
			Nickname: nick,
			Device:   t.Device,
		}
		return QrPollResult{
			Status: "confirmed",
			Secret: sess.Serialize(),
		}, nil
	}
	return QrPollResult{Status: "waiting"}, nil
}

// ─── Quark Web QR Login ───────────────────────────────────────────────────

const (
	webClientID   = "532"
	webApiVersion = "1.2"
	webQrUA       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

func (m *QrManager) webSend(ctx context.Context, t *qrTicket, rawURL string) (*http.Response, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", webQrUA)
	req.Header.Set("Referer", m.webPanBase+"/")
	req.Header.Set("Origin", m.webPanBase)
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	if len(t.Cookies) > 0 && strings.HasSuffix(strings.ToLower(u.Hostname()), m.cookieSuffix) {
		req.Header.Set("Cookie", formatCookieMap(t.Cookies))
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return nil, storage.NewError(storage.ErrKindNetwork, "cannot reach Quark web login", err)
	}
	for _, rawSet := range resp.Header.Values("Set-Cookie") {
		if k, v, ok := parseSetCookiePair(rawSet); ok {
			t.Cookies[k] = v
		}
	}
	return resp, nil
}

func (m *QrManager) webGetJSON(ctx context.Context, t *qrTicket, rawURL string) (map[string]any, error) {
	curr := rawURL
	for hop := 0; hop < 5; hop++ {
		resp, err := m.webSend(ctx, t, curr)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			loc := resp.Header.Get("Location")
			_ = resp.Body.Close()
			if loc == "" {
				break
			}
			u, _ := url.Parse(curr)
			next, err := u.Parse(loc)
			if err != nil {
				break
			}
			curr = next.String()
			continue
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
		_ = resp.Body.Close()
		if err != nil {
			return nil, storage.NewError(storage.ErrKindNetwork, "read Quark web login failed", err)
		}
		var out map[string]any
		if err := json.Unmarshal(raw, &out); err != nil {
			return nil, storage.NewError(storage.ErrKindOther, "unreadable Quark web login JSON", err)
		}
		return out, nil
	}
	return nil, storage.NewError(storage.ErrKindOther, "too many redirects in Quark login")
}

func (m *QrManager) startWeb(ctx context.Context) (*qrTicket, error) {
	t := &qrTicket{
		Mode:    ModeWeb,
		Cookies: make(map[string]string),
	}
	u := fmt.Sprintf("%s/cas/ajax/getTokenForQrcodeLogin?client_id=%s&v=%s&request_id=%s",
		m.webCasBase, webClientID, webApiVersion, url.QueryEscape(uuid.NewString()))
	res, err := m.webGetJSON(ctx, t, u)
	if err != nil {
		return nil, err
	}
	status, _ := asInt(res["status"])
	data, _ := res["data"].(map[string]any)
	members, _ := data["members"].(map[string]any)
	token := strVal(members["token"])
	if status != 2000000 || token == "" {
		return nil, storage.NewError(storage.ErrKindOther, fmt.Sprintf("Quark Web QR start failed: %v", res["message"]))
	}
	const bizOpts = "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
	qrURL := fmt.Sprintf(
		"https://su.quark.cn/4_eMHBJ?token=%s&client_id=%s&ssb=weblogin&uc_param_str=&uc_biz_str=%s",
		url.QueryEscape(token), webClientID, url.QueryEscape(bizOpts),
	)
	t.Token = token
	t.QRContent = qrURL
	return t, nil
}

func (m *QrManager) pollWeb(ctx context.Context, t *qrTicket) (QrPollResult, error) {
	u := fmt.Sprintf("%s/cas/ajax/getServiceTicketByQrcodeToken?client_id=%s&v=%s&token=%s&request_id=%s",
		m.webCasBase, webClientID, webApiVersion, url.QueryEscape(t.Token), url.QueryEscape(uuid.NewString()))
	res, err := m.webGetJSON(ctx, t, u)
	if err != nil {
		return QrPollResult{}, err
	}
	status, _ := asInt(res["status"])
	if status == 2000000 {
		data, _ := res["data"].(map[string]any)
		members, _ := data["members"].(map[string]any)
		st := strVal(members["service_ticket"])
		if st == "" {
			return QrPollResult{}, storage.NewError(storage.ErrKindOther, "Quark Web login missing service_ticket")
		}
		cookie, err := m.exchangeWebTicket(ctx, t, st)
		if err != nil {
			return QrPollResult{}, err
		}
		return QrPollResult{Status: "confirmed", Secret: cookie}, nil
	}
	if status == 50004002 || status == 50004003 || status == 50004004 {
		return QrPollResult{Status: "expired"}, nil
	}
	return QrPollResult{Status: "waiting"}, nil
}

func (m *QrManager) exchangeWebTicket(ctx context.Context, t *qrTicket, serviceTicket string) (string, error) {
	curr := fmt.Sprintf("%s/account/info?st=%s&lw=scan", m.webPanBase, url.QueryEscape(serviceTicket))
	for hop := 0; hop <= 5; hop++ {
		resp, err := m.webSend(ctx, t, curr)
		if err != nil {
			return "", err
		}
		loc := resp.Header.Get("Location")
		isRedir := resp.StatusCode >= 300 && resp.StatusCode < 400
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		if !isRedir || loc == "" {
			break
		}
		base, _ := url.Parse(curr)
		next, err := base.Parse(loc)
		if err != nil || !strings.HasSuffix(strings.ToLower(next.Hostname()), m.cookieSuffix) {
			break
		}
		curr = next.String()
	}
	if t.Cookies["__pus"] == "" {
		return "", storage.NewError(storage.ErrKindUnauthorized, "Quark confirmed login without __pus cookie")
	}
	return formatCookieMap(t.Cookies), nil
}

func parseSetCookiePair(raw string) (string, string, bool) {
	first := strings.SplitN(raw, ";", 2)[0]
	eq := strings.IndexByte(first, '=')
	if eq <= 0 {
		return "", "", false
	}
	k := strings.TrimSpace(first[:eq])
	v := strings.TrimSpace(first[eq+1:])
	if k == "" || v == "" {
		return "", "", false
	}
	return k, v, true
}

func formatCookieMap(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+"="+m[k])
	}
	return strings.Join(parts, "; ")
}

func asInt(v any) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	default:
		return 0, false
	}
}
