package metadata

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/db"
)

const (
	doubanFrodoAPIKey = "0dad551ec0f84ed02907ff5c42e8ec70"
	doubanFrodoSecret = "bf7dddc7c9cfe6f7"
	doubanMobileUA    = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49"
	doubanDesktopUA   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

var (
	reDoubanYear4      = regexp.MustCompile(`\b(19\d{2}|20\d{2})\b`)
	reDoubanImdbID     = regexp.MustCompile(`tt\d{5,12}`)
	reDoubanDuration   = regexp.MustCompile(`(\d{1,4})\s*(?:分钟|min|m\b)`)
	reDoubanDatePrefix = regexp.MustCompile(`(\d{4}-\d{2}-\d{2})`)
)

func doubanHeaders(cfg db.ServerSettings, referer string) map[string]string {
	ua := doubanMobileUA
	if strings.Contains(referer, "movie.douban.com") {
		ua = doubanDesktopUA
	}
	h := map[string]string{
		"User-Agent": ua,
		"Referer":    referer,
		"Accept":     "application/json, text/plain, */*",
	}
	if strings.TrimSpace(cfg.DoubanCookie) != "" {
		h["Cookie"] = strings.TrimSpace(cfg.DoubanCookie)
	}
	return h
}

// signDoubanFrodo computes the HMAC-SHA1 _sig parameter required by frodo.douban.com endpoints.
func signDoubanFrodo(method, apiPath string, ts int64) string {
	raw := strings.ToUpper(method) + "&" + url.QueryEscape(apiPath) + "&" + strconv.FormatInt(ts, 10)
	mac := hmac.New(sha1.New, []byte(doubanFrodoSecret))
	_, _ = mac.Write([]byte(raw))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func isFrodoBase(base string) bool {
	return strings.Contains(strings.ToLower(base), "frodo.douban.com")
}

func (s *Service) doubanAPIRequest(ctx context.Context, cfg db.ServerSettings, apiBase, apiPath string, q url.Values, referer string) (map[string]any, int, error) {
	u, err := url.Parse(apiBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: invalid Douban API base: %v", ErrUpstream, err)
	}
	fullPath := strings.TrimRight(u.Path, "/") + apiPath
	u.Path = fullPath
	params := url.Values{}
	for k, vals := range q {
		for _, v := range vals {
			params.Add(k, v)
		}
	}
	if isFrodoBase(apiBase) {
		ts := time.Now().Unix()
		params.Set("apikey", doubanFrodoAPIKey)
		params.Set("_ts", strconv.FormatInt(ts, 10))
		params.Set("_sig", signDoubanFrodo(http.MethodGet, fullPath, ts))
	}
	u.RawQuery = params.Encode()
	return s.doUpstreamJSON(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, doubanHeaders(cfg, referer), nil, "Douban")
}

func extractDoubanImageURL(row map[string]any) string {
	if pic := jsonObj(row, "pic"); pic != nil {
		for _, k := range []string{"large", "normal"} {
			if u := jsonStr(pic, k); u != "" {
				return u
			}
		}
	}
	for _, k := range []string{"cover_url", "img"} {
		if u := jsonStr(row, k); u != "" {
			return u
		}
	}
	if cov := jsonObj(row, "cover"); cov != nil {
		if u := jsonStr(cov, "url"); u != "" {
			return u
		}
	}
	return ""
}

func parseDoubanCandidateObj(row map[string]any) (Candidate, string, bool) {
	target := row
	targetType := strings.ToLower(jsonStr(row, "target_type"))
	if sub := jsonObj(row, "target"); sub != nil {
		target = sub
	}
	if targetType == "" {
		targetType = strings.ToLower(jsonStr(target, "type"))
	}
	if targetType != "" && targetType != "movie" && targetType != "tv" && targetType != "show" && targetType != "drama" {
		return Candidate{}, targetType, false
	}
	id := jsonStr(target, "id")
	title := jsonStr(target, "title")
	if id == "" || title == "" {
		return Candidate{}, targetType, false
	}
	subtitle := jsonStr(target, "card_subtitle")
	if subtitle == "" {
		subtitle = jsonStr(target, "sub_title")
	}
	var yr *int
	if yStr := jsonStr(target, "year"); yStr != "" {
		yr = yearPtrOfDate(yStr)
	}
	if yr == nil && subtitle != "" {
		if m := reDoubanYear4.FindStringSubmatch(subtitle); m != nil {
			yr = yearPtrOfDate(m[1])
		}
	}
	return Candidate{
		Source:        "douban",
		ID:            id,
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(jsonStr(target, "original_title")),
		Year:          yr,
		Summary:       nonEmptyStrPtr(subtitle),
		PosterPath:    nonEmptyStrPtr(extractDoubanImageURL(target)),
	}, targetType, true
}

func collectDoubanSearchCandidates(raw map[string]any, kind string) []Candidate {
	var items []map[string]any
	if subjObj := jsonObj(raw, "subjects"); subjObj != nil {
		items = jsonObjs(subjObj, "items")
	}
	if len(items) == 0 {
		items = jsonObjs(raw, "items")
	}
	if len(items) == 0 {
		items = jsonObjs(raw, "subjects")
	}

	var exactKind, fallbackAll []Candidate
	seen := make(map[string]bool)
	for _, row := range items {
		cand, tType, ok := parseDoubanCandidateObj(row)
		if !ok || seen[cand.ID] {
			continue
		}
		seen[cand.ID] = true
		fallbackAll = append(fallbackAll, cand)
		wantTV := kind == "show"
		isTV := tType == "tv" || tType == "show" || tType == "drama"
		isMovie := tType == "movie"
		if tType == "" || (wantTV && isTV) || (!wantTV && isMovie) {
			exactKind = append(exactKind, cand)
		}
	}
	if len(exactKind) > 0 {
		return exactKind
	}
	return fallbackAll
}

func (s *Service) fetchDoubanSearch(ctx context.Context, cfg db.ServerSettings, kind, queryStr string) ([]Candidate, error) {
	q := url.Values{}
	q.Set("q", queryStr)
	q.Set("count", "10")

	searchPath := "/search/subjects"
	if isFrodoBase(cfg.DoubanAPIBase) {
		searchPath = "/search/weixin"
	}
	raw, status, err := s.doubanAPIRequest(ctx, cfg, cfg.DoubanAPIBase, searchPath, q, "https://m.douban.com/search/")
	var out []Candidate
	if err == nil && status != http.StatusNotFound && raw != nil {
		out = collectDoubanSearchCandidates(raw, kind)
	}

	if len(out) > 0 {
		return out, nil
	}

	// Only attempt public Douban suggest fallback when using the default live Douban base
	// so offline tests pointing DoubanAPIBase at httptest servers remain strictly isolated.
	if cfg.DoubanAPIBase == db.DefaultDoubanAPIBase {
		suggestURL := "https://movie.douban.com/j/subject_suggest?q=" + url.QueryEscape(queryStr)
		if anyParsed, sStatus, sErr := s.doUpstreamJSONAny(ctx, http.MethodGet, suggestURL, cfg.MetadataProxy, doubanHeaders(cfg, "https://movie.douban.com/"), nil, "DoubanSuggest"); sErr == nil && sStatus == http.StatusOK {
			if arr, ok := anyParsed.([]any); ok {
				for _, elem := range arr {
					m, ok := elem.(map[string]any)
					if !ok {
						continue
					}
					tType := strings.ToLower(jsonStr(m, "type"))
					if tType != "" && tType != "movie" && tType != "tv" {
						continue
					}
					id := jsonStr(m, "id")
					title := jsonStr(m, "title")
					if id == "" || title == "" {
						continue
					}
					out = append(out, Candidate{
						Source:        "douban",
						ID:            id,
						Title:         title,
						OriginalTitle: nonEmptyStrPtr(jsonStr(m, "sub_title")),
						Year:          yearPtrOfDate(jsonStr(m, "year")),
						PosterPath:    nonEmptyStrPtr(jsonStr(m, "img")),
					})
				}
				if len(out) > 0 {
					return out, nil
				}
			}
		}

		// Secondary fallback: Frodo weixin search with signature
		frodoRaw, fStatus, fErr := s.doubanAPIRequest(ctx, cfg, "https://frodo.douban.com/api/v2", "/search/weixin", q, "https://m.douban.com/")
		if fErr == nil && fStatus != http.StatusNotFound && frodoRaw != nil {
			out = collectDoubanSearchCandidates(frodoRaw, kind)
			if len(out) > 0 {
				return out, nil
			}
		}
	}

	if err != nil {
		return nil, err
	}
	return []Candidate{}, nil
}

func extractJSONStringArray(m map[string]any, key string) []string {
	if m == nil {
		return nil
	}
	raw, ok := m[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, elem := range raw {
		switch x := elem.(type) {
		case string:
			if t := strings.TrimSpace(x); t != "" {
				out = append(out, t)
			}
		case map[string]any:
			if t := jsonStr(x, "name"); t != "" {
				out = append(out, t)
			}
		}
	}
	return out
}

func (s *Service) scrapeDoubanWebImdb(ctx context.Context, cfg db.ServerSettings, subjectID string) string {
	subCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	pageURL := fmt.Sprintf("https://movie.douban.com/subject/%s/", url.PathEscape(subjectID))
	rawBytes, status, err := s.doUpstreamBytes(subCtx, http.MethodGet, pageURL, cfg.MetadataProxy, doubanHeaders(cfg, "https://movie.douban.com/"), nil, "DoubanWeb")
	if err != nil || status != http.StatusOK || len(rawBytes) == 0 {
		return ""
	}
	html := string(rawBytes)
	if idx := strings.Index(html, "IMDb:"); idx >= 0 {
		window := html[idx:]
		if len(window) > 128 {
			window = window[:128]
		}
		if m := reDoubanImdbID.FindString(window); m != "" {
			return m
		}
	}
	return ""
}

// FetchDoubanWebImdbID best-effort scrapes the IMDb ID (tt...) from a Douban subject's
// web page. Intended to be invoked only once for a confirmed winning candidate.
func (s *Service) FetchDoubanWebImdbID(ctx context.Context, subjectID string) string {
	cfg := s.store.GetServerSettings()
	if cfg.DoubanAPIBase != db.DefaultDoubanAPIBase || strings.TrimSpace(subjectID) == "" {
		return ""
	}
	return s.scrapeDoubanWebImdb(ctx, cfg, subjectID)
}

func (s *Service) fetchDoubanWork(ctx context.Context, cfg db.ServerSettings, kind, id string) (Work, error) {
	paths := []string{"/movie/" + url.PathEscape(id), "/tv/" + url.PathEscape(id)}
	if kind == "show" {
		paths = []string{"/tv/" + url.PathEscape(id), "/movie/" + url.PathEscape(id)}
	}
	referer := fmt.Sprintf("https://m.douban.com/movie/subject/%s/", url.PathEscape(id))

	var raw map[string]any
	var lastStatus int
	var lastErr error
	for _, apiPath := range paths {
		r, status, err := s.doubanAPIRequest(ctx, cfg, cfg.DoubanAPIBase, apiPath, nil, referer)
		lastErr = err
		lastStatus = status
		if err == nil && status != http.StatusNotFound && r != nil {
			raw = r
			break
		}
		if err != nil && status != http.StatusNotFound {
			break
		}
	}
	if lastErr != nil && raw == nil {
		return Work{}, lastErr
	}
	if raw == nil || lastStatus == http.StatusNotFound {
		return Work{}, fmt.Errorf("%w: Douban subject %s", ErrNotFound, id)
	}

	subjectID := jsonStr(raw, "id")
	if subjectID == "" {
		subjectID = id
	}
	title := jsonStr(raw, "title")
	origTitle := jsonStr(raw, "original_title")
	if title == "" {
		title = origTitle
	}
	akas := extractJSONStringArray(raw, "aka")
	genres := extractJSONStringArray(raw, "genres")

	var relDate string
	for _, pd := range extractJSONStringArray(raw, "pubdate") {
		if m := reDoubanDatePrefix.FindStringSubmatch(pd); m != nil {
			relDate = m[1]
			break
		}
	}
	year := yearPtrOfDate(jsonStr(raw, "year"))
	if year == nil && relDate != "" {
		year = yearPtrOfDate(relDate)
	}

	var scorePtr *float64
	if rObj := jsonObj(raw, "rating"); rObj != nil {
		if v, ok := jsonFloat(rObj, "value"); ok && v > 0 {
			scorePtr = &v
		}
	}
	if scorePtr == nil {
		if v, ok := jsonFloat(raw, "rate"); ok && v > 0 {
			scorePtr = &v
		}
	}

	var runtimeMs *int64
	for _, d := range extractJSONStringArray(raw, "durations") {
		if m := reDoubanDuration.FindStringSubmatch(d); m != nil {
			if mins, err := strconv.Atoi(m[1]); err == nil && mins > 0 {
				v := int64(mins) * 60000
				runtimeMs = &v
				break
			}
		}
	}

	imdbID := ""
	if rawImdb := jsonStr(raw, "imdb"); rawImdb != "" {
		imdbID = reDoubanImdbID.FindString(rawImdb)
	}
	if imdbID == "" {
		if rawImdb := jsonStr(raw, "imdb_id"); rawImdb != "" {
			imdbID = reDoubanImdbID.FindString(rawImdb)
		}
	}

	var credits []Credit
	for _, d := range jsonObjs(raw, "directors") {
		if name := jsonStr(d, "name"); name != "" {
			credits = append(credits, Credit{Name: name, Job: "director"})
		}
	}
	for i, a := range jsonObjs(raw, "actors") {
		if i >= 12 {
			break
		}
		if name := jsonStr(a, "name"); name != "" {
			credits = append(credits, Credit{Name: name, Job: "actor"})
		}
	}

	var categoryPtr *string
	for _, g := range genres {
		if g == "动画" {
			c := db.ShelfAnime
			categoryPtr = &c
			break
		}
		if g == "真人秀" || g == "脱口秀" {
			c := db.ShelfVariety
			categoryPtr = &c
			break
		}
		if g == "纪录片" {
			c := db.ShelfDocumentary
			categoryPtr = &c
			break
		}
	}

	return Work{
		Source:        "douban",
		Kind:          kind,
		ExternalID:    subjectID,
		DoubanID:      &subjectID,
		ImdbID:        nonEmptyStrPtr(imdbID),
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(origTitle),
		Aliases:       akas,
		Year:          year,
		ReleaseDate:   nonEmptyStrPtr(relDate),
		Summary:       nonEmptyStrPtr(jsonStr(raw, "intro")),
		Rating:        scorePtr,
		RuntimeMs:     runtimeMs,
		Genres:        genres,
		PosterPath:    nonEmptyStrPtr(extractDoubanImageURL(raw)),
		Credits:       credits,
		Category:      categoryPtr,
	}, nil
}
