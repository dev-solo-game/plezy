package metadata

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"plezy/media_library/internal/db"
)

func (s *Service) tvdbLoginToken(ctx context.Context, cfg db.ServerSettings, forceRefresh bool) (string, error) {
	if strings.TrimSpace(cfg.TvdbAPIKey) == "" {
		return "", fmt.Errorf("%w: thetvdb api key is not configured", ErrNotConfigured)
	}
	cacheKey := cfg.TvdbAPIBase + "|" + cfg.TvdbAPIKey + "|" + cfg.TvdbPin

	s.tvdbMu.Lock()
	if !forceRefresh && s.tvdbToken != "" && s.tvdbTokenKey == cacheKey && time.Now().Before(s.tvdbTokenExp) {
		tok := s.tvdbToken
		s.tvdbMu.Unlock()
		return tok, nil
	}
	s.tvdbMu.Unlock()

	loginURL := strings.TrimRight(cfg.TvdbAPIBase, "/") + "/login"
	body := map[string]any{"apikey": cfg.TvdbAPIKey}
	if strings.TrimSpace(cfg.TvdbPin) != "" {
		body["pin"] = cfg.TvdbPin
	}
	raw, _, err := s.doUpstreamJSON(ctx, http.MethodPost, loginURL, cfg.MetadataProxy, nil, body, "TheTvDbLogin")
	if err != nil {
		return "", err
	}
	data := jsonObj(raw, "data")
	tok := jsonStr(data, "token")
	if tok == "" {
		return "", fmt.Errorf("%w: thetvdb login did not return token", ErrUpstream)
	}

	s.tvdbMu.Lock()
	s.tvdbToken = tok
	s.tvdbTokenKey = cacheKey
	s.tvdbTokenExp = time.Now().Add(20 * 24 * time.Hour)
	s.tvdbMu.Unlock()
	return tok, nil
}

func (s *Service) tvdbRequest(ctx context.Context, cfg db.ServerSettings, apiPath string, q url.Values) (map[string]any, int, error) {
	tok, err := s.tvdbLoginToken(ctx, cfg, false)
	if err != nil {
		return nil, 0, err
	}
	u, err := url.Parse(cfg.TvdbAPIBase)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: invalid TheTvDb base: %v", ErrUpstream, err)
	}
	u.Path = strings.TrimRight(u.Path, "/") + apiPath
	if len(q) > 0 {
		u.RawQuery = q.Encode()
	}
	headers := map[string]string{
		"Authorization": "Bearer " + tok,
	}
	raw, status, err := s.doUpstreamJSON(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, headers, nil, "TheTvDb")
	if status == http.StatusUnauthorized {
		tok, lErr := s.tvdbLoginToken(ctx, cfg, true)
		if lErr == nil {
			headers["Authorization"] = "Bearer " + tok
			return s.doUpstreamJSON(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, headers, nil, "TheTvDb")
		}
	}
	return raw, status, err
}

func tvdbLangKey(lang string) string {
	low := strings.ToLower(strings.TrimSpace(lang))
	if strings.HasPrefix(low, "zh") {
		return "zho"
	}
	if strings.HasPrefix(low, "ja") {
		return "jpn"
	}
	return "eng"
}

func tvdbTranslatedField(translations map[string]any, lang string) string {
	if translations == nil {
		return ""
	}
	for _, key := range []string{tvdbLangKey(lang), "zho", "zh", "chi"} {
		if strings.HasPrefix(strings.ToLower(lang), "zh") || key == tvdbLangKey(lang) {
			if v := jsonStr(translations, key); v != "" {
				return v
			}
		}
	}
	return ""
}

func (s *Service) fetchTvdbSearch(ctx context.Context, cfg db.ServerSettings, kind, queryStr string, year int, lang string) ([]Candidate, error) {
	q := url.Values{}
	q.Set("query", queryStr)
	q.Set("limit", "10")
	if kind == "show" {
		q.Set("type", "series")
	} else {
		q.Set("type", "movie")
	}
	if year > 0 {
		q.Set("year", strconv.Itoa(year))
	}
	raw, status, err := s.tvdbRequest(ctx, cfg, "/search", q)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return []Candidate{}, nil
	}
	out := make([]Candidate, 0)
	for _, row := range jsonObjs(raw, "data") {
		id := jsonStr(row, "tvdb_id")
		if id == "" {
			rawID := jsonStr(row, "id")
			id = strings.TrimPrefix(strings.TrimPrefix(rawID, "series-"), "movie-")
		}
		orig := jsonStr(row, "name")
		title := tvdbTranslatedField(jsonObj(row, "translations"), lang)
		if title == "" {
			title = orig
		}
		if id == "" || title == "" {
			continue
		}
		summary := tvdbTranslatedField(jsonObj(row, "overviews"), lang)
		if summary == "" {
			summary = jsonStr(row, "overview")
		}
		out = append(out, Candidate{
			Source:        "tvdb",
			ID:            id,
			Title:         title,
			OriginalTitle: nonEmptyStrPtr(orig),
			Year:          yearPtrOfDate(jsonStr(row, "year")),
			Summary:       nonEmptyStrPtr(summary),
			PosterPath:    nonEmptyStrPtr(jsonStr(row, "image_url")),
		})
	}
	return out, nil
}

func (s *Service) fetchTvdbWork(ctx context.Context, cfg db.ServerSettings, kind, id, lang string) (Work, error) {
	basePath := "/movies/" + url.PathEscape(id)
	if kind == "show" {
		basePath = "/series/" + url.PathEscape(id)
	}
	raw, status, err := s.tvdbRequest(ctx, cfg, basePath+"/extended", nil)
	if err != nil {
		return Work{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Work{}, fmt.Errorf("%w: TheTvDb %s %s", ErrNotFound, kind, id)
	}
	data := jsonObj(raw, "data")
	if data == nil {
		return Work{}, fmt.Errorf("%w: TheTvDb %s %s", ErrNotFound, kind, id)
	}

	extID := jsonStr(data, "id")
	if extID == "" {
		extID = id
	}
	origTitle := jsonStr(data, "name")
	title := origTitle
	summary := jsonStr(data, "overview")

	tKey := tvdbLangKey(lang)
	if tKey != "eng" {
		if trRaw, tSt, tErr := s.tvdbRequest(ctx, cfg, basePath+"/translations/"+tKey, nil); tErr == nil && tSt == http.StatusOK {
			if tr := jsonObj(trRaw, "data"); tr != nil {
				if tn := jsonStr(tr, "name"); tn != "" {
					title = tn
				}
				if ov := jsonStr(tr, "overview"); ov != "" {
					summary = ov
				}
			}
		}
	}

	var imdbID, tmdbID string
	for _, r := range jsonObjs(data, "remoteIds") {
		srcName := strings.ToLower(jsonStr(r, "sourceName"))
		rid := jsonStr(r, "id")
		if rid == "" {
			continue
		}
		if (srcName == "imdb" || strings.HasPrefix(rid, "tt")) && imdbID == "" {
			imdbID = rid
		} else if (srcName == "themoviedb" || srcName == "tmdb") && tmdbID == "" {
			tmdbID = rid
		}
	}

	var aliases []string
	for _, a := range jsonObjs(data, "aliases") {
		if name := jsonStr(a, "name"); name != "" {
			aliases = append(aliases, name)
		}
	}
	var genres []string
	for _, g := range jsonObjs(data, "genres") {
		if name := jsonStr(g, "name"); name != "" {
			genres = append(genres, name)
		}
	}

	firstAired := jsonStr(data, "firstAired")
	if firstAired == "" {
		firstAired = jsonStr(data, "first_release_date")
	}
	yr := yearPtrOfDate(firstAired)
	if yr == nil {
		yr = jsonInt(data, "year")
	}

	var runtimeMs *int64
	if rt := jsonInt(data, "averageRuntime"); rt != nil && *rt > 0 {
		v := int64(*rt) * 60000
		runtimeMs = &v
	}

	poster := jsonStr(data, "image")
	var backdrop string
	for _, aw := range jsonObjs(data, "artworks") {
		if tp := jsonInt(aw, "type"); tp != nil && (*tp == 3 || *tp == 15) {
			if u := jsonStr(aw, "image"); u != "" {
				backdrop = u
				break
			}
		}
	}

	return Work{
		Source:        "tvdb",
		Kind:          kind,
		ExternalID:    extID,
		TvdbID:        &extID,
		TmdbID:        nonEmptyStrPtr(tmdbID),
		ImdbID:        nonEmptyStrPtr(imdbID),
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(origTitle),
		Aliases:       aliases,
		Year:          yr,
		ReleaseDate:   nonEmptyStrPtr(firstAired),
		Summary:       nonEmptyStrPtr(summary),
		RuntimeMs:     runtimeMs,
		Genres:        genres,
		PosterPath:    nonEmptyStrPtr(poster),
		BackdropPath:  nonEmptyStrPtr(backdrop),
	}, nil
}

func (s *Service) fetchTvdbSeason(ctx context.Context, cfg db.ServerSettings, showID string, seasonNumber int, lang string) (Season, error) {
	q := url.Values{}
	q.Set("season", strconv.Itoa(seasonNumber))
	tKey := tvdbLangKey(lang)
	epPath := fmt.Sprintf("/series/%s/episodes/default", url.PathEscape(showID))
	var raw map[string]any
	var status int
	var err error
	if tKey != "eng" {
		raw, status, err = s.tvdbRequest(ctx, cfg, epPath+"/"+tKey, q)
		if err != nil || status == http.StatusNotFound || raw == nil {
			raw, status, err = s.tvdbRequest(ctx, cfg, epPath, q)
		}
	} else {
		raw, status, err = s.tvdbRequest(ctx, cfg, epPath, q)
	}
	if err != nil {
		return Season{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Season{}, fmt.Errorf("%w: TheTvDb series %s season %d", ErrNotFound, showID, seasonNumber)
	}
	data := jsonObj(raw, "data")
	var episodes []Episode
	for _, row := range jsonObjs(data, "episodes") {
		sNum := jsonInt(row, "seasonNumber")
		if sNum != nil && *sNum != seasonNumber {
			continue
		}
		epNum := jsonInt(row, "number")
		if epNum == nil || *epNum <= 0 {
			continue
		}
		var runtimeMs *int64
		if rt := jsonInt(row, "runtime"); rt != nil && *rt > 0 {
			v := int64(*rt) * 60000
			runtimeMs = &v
		}
		episodes = append(episodes, Episode{
			Number:    *epNum,
			Title:     nonEmptyStrPtr(jsonStr(row, "name")),
			Summary:   nonEmptyStrPtr(jsonStr(row, "overview")),
			AirDate:   nonEmptyStrPtr(jsonStr(row, "aired")),
			RuntimeMs: runtimeMs,
			StillPath: nonEmptyStrPtr(jsonStr(row, "image")),
		})
	}
	if len(episodes) == 0 {
		return Season{}, fmt.Errorf("%w: TheTvDb series %s season %d empty", ErrNotFound, showID, seasonNumber)
	}
	return Season{Number: seasonNumber, Episodes: episodes}, nil
}
