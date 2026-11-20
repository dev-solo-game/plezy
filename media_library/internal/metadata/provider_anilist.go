package metadata

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"plezy/media_library/internal/db"
)

var reAniListHTMLTag = regexp.MustCompile(`<[^>]+>`)

func stripHTMLTags(s string) string {
	clean := reAniListHTMLTag.ReplaceAllString(s, " ")
	clean = strings.ReplaceAll(clean, "\u00a0", " ")
	return strings.TrimSpace(strings.Join(strings.Fields(clean), " "))
}

const aniListSearchGQL = `query ($search: String, $formats: [MediaFormat]) {
  Page(page: 1, perPage: 10) {
    media(search: $search, type: ANIME, format_in: $formats, sort: SEARCH_MATCH) {
      id
      format
      title {
        romaji
        english
        native
      }
      synonyms
      seasonYear
      startDate {
        year
        month
        day
      }
      description(asHtml: false)
      coverImage {
        extraLarge
        large
      }
    }
  }
}`

const aniListWorkGQL = `query ($id: Int) {
  Media(id: $id, type: ANIME) {
    id
    format
    status
    title {
      romaji
      english
      native
    }
    synonyms
    seasonYear
    startDate {
      year
      month
      day
    }
    duration
    averageScore
    genres
    description(asHtml: false)
    coverImage {
      extraLarge
      large
    }
    bannerImage
    studios(isMain: true) {
      nodes {
        name
      }
    }
    staff(page: 1, perPage: 6) {
      edges {
        role
        node {
          name {
            full
            native
          }
        }
      }
    }
  }
}`

func aniListPreferredTitles(titleObj map[string]any) (title string, orig string) {
	native := jsonStr(titleObj, "native")
	eng := jsonStr(titleObj, "english")
	romaji := jsonStr(titleObj, "romaji")
	title = native
	if title == "" {
		title = eng
	}
	if title == "" {
		title = romaji
	}
	orig = romaji
	if orig == "" || orig == title {
		orig = eng
	}
	if orig == title {
		orig = ""
	}
	return title, orig
}

func aniListDateAndYear(m map[string]any) (*int, *string) {
	sd := jsonObj(m, "startDate")
	y := jsonInt(sd, "year")
	if y == nil {
		y = jsonInt(m, "seasonYear")
	}
	var rel *string
	if y != nil && *y > 1900 {
		mo := jsonInt(sd, "month")
		dy := jsonInt(sd, "day")
		if mo != nil && dy != nil && *mo > 0 && *dy > 0 {
			formatted := fmt.Sprintf("%04d-%02d-%02d", *y, *mo, *dy)
			rel = &formatted
		} else {
			formatted := fmt.Sprintf("%04d-01-01", *y)
			rel = &formatted
		}
	}
	return y, rel
}

func (s *Service) aniListRequest(ctx context.Context, cfg db.ServerSettings, query string, vars map[string]any) (map[string]any, error) {
	body := map[string]any{
		"query":     query,
		"variables": vars,
	}
	headers := map[string]string{
		"User-Agent": "ttplay-media-server/1.0 (anilist lookup)",
	}
	raw, status, err := s.doUpstreamJSON(ctx, http.MethodPost, cfg.AniListAPIBase, cfg.MetadataProxy, headers, body, "AniList")
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotFound || raw == nil {
		return nil, ErrNotFound
	}
	return jsonObj(raw, "data"), nil
}

func (s *Service) fetchAniListSearch(ctx context.Context, cfg db.ServerSettings, kind, queryStr string) ([]Candidate, error) {
	formats := []string{"TV", "TV_SHORT", "ONA", "OVA", "SPECIAL"}
	if kind == "movie" {
		formats = []string{"MOVIE", "OVA", "SPECIAL"}
	}
	data, err := s.aniListRequest(ctx, cfg, aniListSearchGQL, map[string]any{
		"search":  queryStr,
		"formats": formats,
	})
	if err != nil {
		return nil, err
	}
	page := jsonObj(data, "Page")
	out := make([]Candidate, 0)
	for _, row := range jsonObjs(page, "media") {
		id := jsonStr(row, "id")
		if id == "" {
			continue
		}
		title, orig := aniListPreferredTitles(jsonObj(row, "title"))
		if title == "" {
			continue
		}
		yr, _ := aniListDateAndYear(row)
		cov := jsonObj(row, "coverImage")
		poster := jsonStr(cov, "extraLarge")
		if poster == "" {
			poster = jsonStr(cov, "large")
		}
		out = append(out, Candidate{
			Source:        "anilist",
			ID:            id,
			Title:         title,
			OriginalTitle: nonEmptyStrPtr(orig),
			Year:          yr,
			Summary:       nonEmptyStrPtr(stripHTMLTags(jsonStr(row, "description"))),
			PosterPath:    nonEmptyStrPtr(poster),
		})
	}
	return out, nil
}

func (s *Service) fetchAniListWork(ctx context.Context, cfg db.ServerSettings, kind, id string) (Work, error) {
	numID, err := strconv.Atoi(strings.TrimSpace(id))
	if err != nil || numID <= 0 {
		return Work{}, fmt.Errorf("%w: invalid anilist id %q", ErrInvalidInput, id)
	}
	data, err := s.aniListRequest(ctx, cfg, aniListWorkGQL, map[string]any{"id": numID})
	if err != nil {
		return Work{}, err
	}
	m := jsonObj(data, "Media")
	if m == nil {
		return Work{}, fmt.Errorf("%w: AniList media %s", ErrNotFound, id)
	}
	extID := jsonStr(m, "id")
	if extID == "" {
		extID = strconv.Itoa(numID)
	}
	titleObj := jsonObj(m, "title")
	title, orig := aniListPreferredTitles(titleObj)

	seenAlias := make(map[string]bool)
	var aliases []string
	addAlias := func(a string) {
		t := strings.TrimSpace(a)
		if t == "" || strings.EqualFold(t, title) {
			return
		}
		low := strings.ToLower(t)
		if !seenAlias[low] {
			seenAlias[low] = true
			aliases = append(aliases, t)
		}
	}
	addAlias(jsonStr(titleObj, "romaji"))
	addAlias(jsonStr(titleObj, "english"))
	addAlias(jsonStr(titleObj, "native"))
	for _, syn := range extractJSONStringArray(m, "synonyms") {
		addAlias(syn)
	}

	yr, relDate := aniListDateAndYear(m)
	var scorePtr *float64
	if sc, ok := jsonFloat(m, "averageScore"); ok && sc > 0 {
		v := sc / 10.0
		scorePtr = &v
	}
	var runtimeMs *int64
	if dur := jsonInt(m, "duration"); dur != nil && *dur > 0 {
		v := int64(*dur) * 60000
		runtimeMs = &v
	}
	cov := jsonObj(m, "coverImage")
	poster := jsonStr(cov, "extraLarge")
	if poster == "" {
		poster = jsonStr(cov, "large")
	}
	var studio *string
	if stObj := jsonObj(m, "studios"); stObj != nil {
		if nodes := jsonObjs(stObj, "nodes"); len(nodes) > 0 {
			studio = nonEmptyStrPtr(jsonStr(nodes[0], "name"))
		}
	}
	var credits []Credit
	if staffObj := jsonObj(m, "staff"); staffObj != nil {
		for _, edge := range jsonObjs(staffObj, "edges") {
			role := strings.ToLower(jsonStr(edge, "role"))
			job := "director"
			if strings.Contains(role, "script") || strings.Contains(role, "series composition") || strings.Contains(role, "creator") {
				job = "writer"
			} else if !strings.Contains(role, "director") {
				continue
			}
			node := jsonObj(edge, "node")
			nameObj := jsonObj(node, "name")
			name := jsonStr(nameObj, "native")
			if name == "" {
				name = jsonStr(nameObj, "full")
			}
			if name != "" {
				credits = append(credits, Credit{Name: name, Job: job})
			}
		}
	}
	cat := db.ShelfAnime
	return Work{
		Source:        "anilist",
		Kind:          kind,
		ExternalID:    extID,
		AniListID:     &extID,
		Title:         title,
		OriginalTitle: nonEmptyStrPtr(orig),
		Aliases:       aliases,
		Year:          yr,
		ReleaseDate:   relDate,
		Summary:       nonEmptyStrPtr(stripHTMLTags(jsonStr(m, "description"))),
		Rating:        scorePtr,
		RuntimeMs:     runtimeMs,
		Studio:        studio,
		Genres:        extractJSONStringArray(m, "genres"),
		PosterPath:    nonEmptyStrPtr(poster),
		BackdropPath:  nonEmptyStrPtr(jsonStr(m, "bannerImage")),
		Credits:       credits,
		Category:      &cat,
		Status:        jsonStr(m, "status"),
	}, nil
}
