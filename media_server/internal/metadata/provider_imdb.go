package metadata

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode"

	"plezy/media_server/internal/db"
)

var reExactImdbID = regexp.MustCompile(`(?i)^tt\d{5,12}$`)

func imdbSuggestionFirstChar(q string) string {
	for _, r := range strings.ToLower(strings.TrimSpace(q)) {
		if r >= 'a' && r <= 'z' {
			return string(r)
		}
		if unicode.IsDigit(r) {
			return string(r)
		}
	}
	return "x"
}

func imdbMatchesKind(rowType, kind string) bool {
	t := strings.ToLower(strings.TrimSpace(rowType))
	if t == "" {
		return true
	}
	if kind == "show" {
		return strings.Contains(t, "tv") || strings.Contains(t, "series")
	}
	return t == "movie" || t == "feature" || t == "tvmovie"
}

func (s *Service) fetchImdbSearch(ctx context.Context, cfg db.ServerSettings, kind, queryStr string) ([]Candidate, error) {
	trimmed := strings.TrimSpace(queryStr)
	if reExactImdbID.MatchString(trimmed) {
		w, err := s.fetchImdbWork(ctx, cfg, kind, strings.ToLower(trimmed))
		if err != nil {
			return nil, err
		}
		return []Candidate{{
			Source:        "imdb",
			ID:            w.ExternalID,
			Title:         w.Title,
			OriginalTitle: w.OriginalTitle,
			Year:          w.Year,
			Summary:       w.Summary,
			PosterPath:    w.PosterPath,
		}}, nil
	}

	headers := map[string]string{
		"User-Agent": "ttplay-media-server/1.0 (imdb metadata lookup)",
	}
	searchURL := strings.TrimRight(cfg.ImdbAPIBase, "/") + "/search/titles?query=" + url.QueryEscape(trimmed) + "&limit=10"
	raw, status, err := s.doUpstreamJSON(ctx, http.MethodGet, searchURL, cfg.MetadataProxy, headers, nil, "IMDb")

	var exactKind, fallbackAll []Candidate
	if err == nil && status != http.StatusNotFound && raw != nil {
		for _, row := range jsonObjs(raw, "titles") {
			id := jsonStr(row, "id")
			title := jsonStr(row, "primaryTitle")
			if id == "" || title == "" {
				continue
			}
			var poster string
			if img := jsonObj(row, "primaryImage"); img != nil {
				poster = jsonStr(img, "url")
			}
			c := Candidate{
				Source:        "imdb",
				ID:            id,
				Title:         title,
				OriginalTitle: nonEmptyStrPtr(jsonStr(row, "originalTitle")),
				Year:          jsonInt(row, "startYear"),
				Summary:       nonEmptyStrPtr(jsonStr(row, "plot")),
				PosterPath:    nonEmptyStrPtr(poster),
			}
			fallbackAll = append(fallbackAll, c)
			if imdbMatchesKind(jsonStr(row, "type"), kind) {
				exactKind = append(exactKind, c)
			}
		}
	}
	if len(exactKind) > 0 {
		return exactKind, nil
	}
	if len(fallbackAll) > 0 {
		return fallbackAll, nil
	}

	// Only fall back to IMDb's unauthenticated suggestion CDN when using the default base.
	if cfg.ImdbAPIBase == db.DefaultImdbAPIBase {
		fc := imdbSuggestionFirstChar(trimmed)
		suggURL := fmt.Sprintf("https://v3.sg.media-imdb.com/suggestion/%s/%s.json", fc, url.PathEscape(trimmed))
		suggRaw, sStatus, sErr := s.doUpstreamJSON(ctx, http.MethodGet, suggURL, cfg.MetadataProxy, headers, nil, "IMDbSuggest")
		if sErr == nil && sStatus == http.StatusOK && suggRaw != nil {
			for _, row := range jsonObjs(suggRaw, "d") {
				id := jsonStr(row, "id")
				if !strings.HasPrefix(id, "tt") {
					continue
				}
				title := jsonStr(row, "l")
				if title == "" {
					continue
				}
				var poster string
				if img := jsonObj(row, "i"); img != nil {
					poster = jsonStr(img, "imageUrl")
				}
				c := Candidate{
					Source:     "imdb",
					ID:         id,
					Title:      title,
					Year:       jsonInt(row, "y"),
					Summary:    nonEmptyStrPtr(jsonStr(row, "s")),
					PosterPath: nonEmptyStrPtr(poster),
				}
				fallbackAll = append(fallbackAll, c)
				if imdbMatchesKind(jsonStr(row, "qid"), kind) {
					exactKind = append(exactKind, c)
				}
			}
			if len(exactKind) > 0 {
				return exactKind, nil
			}
			if len(fallbackAll) > 0 {
				return fallbackAll, nil
			}
		}
	}

	if err != nil {
		return nil, err
	}
	return []Candidate{}, nil
}

func (s *Service) fetchImdbWork(ctx context.Context, cfg db.ServerSettings, kind, id string) (Work, error) {
	normID := strings.ToLower(strings.TrimSpace(id))
	headers := map[string]string{
		"User-Agent": "ttplay-media-server/1.0 (imdb metadata lookup)",
	}
	workURL := strings.TrimRight(cfg.ImdbAPIBase, "/") + "/titles/" + url.PathEscape(normID)
	raw, status, err := s.doUpstreamJSON(ctx, http.MethodGet, workURL, cfg.MetadataProxy, headers, nil, "IMDb")
	if err != nil {
		return Work{}, err
	}
	if status == http.StatusNotFound || raw == nil {
		return Work{}, fmt.Errorf("%w: IMDb title %s", ErrNotFound, normID)
	}

	extID := jsonStr(raw, "id")
	if extID == "" {
		extID = normID
	}
	title := jsonStr(raw, "primaryTitle")
	origTitle := jsonStr(raw, "originalTitle")
	if title == "" {
		title = origTitle
	}
	yr := jsonInt(raw, "startYear")
	var relDate *string
	if yr != nil && *yr > 1900 {
		sDate := fmt.Sprintf("%04d-01-01", *yr)
		relDate = &sDate
	}
	var scorePtr *float64
	if rObj := jsonObj(raw, "rating"); rObj != nil {
		if sc, ok := jsonFloat(rObj, "aggregateRating"); ok && sc > 0 {
			scorePtr = &sc
		}
	}
	var runtimeMs *int64
	if sec := jsonInt(raw, "runtimeSeconds"); sec != nil && *sec > 0 {
		v := int64(*sec) * 1000
		runtimeMs = &v
	}
	var poster string
	if img := jsonObj(raw, "primaryImage"); img != nil {
		poster = jsonStr(img, "url")
	}
	var credits []Credit
	for _, p := range jsonObjs(raw, "directors") {
		if n := jsonStr(p, "displayName"); n != "" {
			credits = append(credits, Credit{Name: n, Job: "director"})
		}
	}
	for _, p := range jsonObjs(raw, "writers") {
		if n := jsonStr(p, "displayName"); n != "" {
			credits = append(credits, Credit{Name: n, Job: "writer"})
		}
	}
	for i, p := range jsonObjs(raw, "stars") {
		if i >= 12 {
			break
		}
		if n := jsonStr(p, "displayName"); n != "" {
			credits = append(credits, Credit{Name: n, Job: "actor"})
		}
	}

	resolvedKind := kind
	if t := strings.ToLower(jsonStr(raw, "type")); strings.Contains(t, "series") {
		resolvedKind = "show"
	} else if t == "movie" {
		resolvedKind = "movie"
	}

	return Work{
		Source:        "imdb",
		Kind:          resolvedKind,
		ExternalID:    extID,
		ImdbID:        &extID,
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(origTitle),
		Year:          yr,
		ReleaseDate:   relDate,
		Summary:       nonEmptyStrPtr(jsonStr(raw, "plot")),
		Rating:        scorePtr,
		RuntimeMs:     runtimeMs,
		Genres:        extractJSONStringArray(raw, "genres"),
		PosterPath:    nonEmptyStrPtr(poster),
		Credits:       credits,
	}, nil
}
