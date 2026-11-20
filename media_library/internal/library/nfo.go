package library

import (
	"encoding/xml"
	"strconv"
	"strings"

	"plezy/media_library/internal/metadata"
)

type nfoSet struct {
	Name  string `xml:"name"`
	Inner string `xml:",chardata"`
}

type nfoUniqueID struct {
	Type  string `xml:"type,attr"`
	Value string `xml:",chardata"`
}

type nfoActor struct {
	Name  string `xml:"name"`
	Role  string `xml:"role"`
	Thumb string `xml:"thumb"`
}

type nfoRatingItem struct {
	Value string `xml:"value"`
}

type nfoRatings struct {
	Rating []nfoRatingItem `xml:"rating"`
}

type nfoDoc struct {
	XMLName       xml.Name
	Title         string        `xml:"title"`
	OriginalTitle string        `xml:"originaltitle"`
	Year          string        `xml:"year"`
	Premiered     string        `xml:"premiered"`
	ReleaseDate   string        `xml:"releasedate"`
	Aired         string        `xml:"aired"`
	Plot          string        `xml:"plot"`
	Outline       string        `xml:"outline"`
	Tagline       string        `xml:"tagline"`
	Runtime       string        `xml:"runtime"`
	Mpaa          string        `xml:"mpaa"`
	Studio        string        `xml:"studio"`
	Rating        string        `xml:"rating"`
	Ratings       nfoRatings    `xml:"ratings"`
	Genres        []string      `xml:"genre"`
	Directors     []string      `xml:"director"`
	Credits       []string      `xml:"credits"`
	Writers       []string      `xml:"writer"`
	Actors        []nfoActor    `xml:"actor"`
	UniqueIDs     []nfoUniqueID `xml:"uniqueid"`
	TmdbID        string        `xml:"tmdbid"`
	ImdbID        string        `xml:"imdbid"`
	TvdbID        string        `xml:"tvdbid"`
	BareID        string        `xml:"id"`
	Set           nfoSet        `xml:"set"`
	Episode       string        `xml:"episode"`
}

func trimNfoXML(content string) string {
	end := strings.LastIndexByte(content, '>')
	if end < 0 {
		return ""
	}
	return content[:end+1]
}

func ReadTitleNFO(content, expectedRoot string) *metadata.Work {
	trimmed := trimNfoXML(content)
	if trimmed == "" {
		return nil
	}
	var doc nfoDoc
	if err := xml.Unmarshal([]byte(trimmed), &doc); err != nil {
		return nil
	}
	rootName := strings.ToLower(doc.XMLName.Local)
	if rootName != "movie" && rootName != "tvshow" {
		return nil
	}
	if expectedRoot != "" && rootName != expectedRoot {
		return nil
	}
	title := strings.TrimSpace(doc.Title)
	if title == "" {
		return nil
	}

	ids := make(map[string]string)
	for _, uid := range doc.UniqueIDs {
		k := strings.ToLower(strings.TrimSpace(uid.Type))
		v := strings.TrimSpace(uid.Value)
		if k != "" && v != "" {
			ids[k] = v
		}
	}
	if v := strings.TrimSpace(doc.TmdbID); v != "" && ids["tmdb"] == "" {
		ids["tmdb"] = v
	}
	if v := strings.TrimSpace(doc.ImdbID); v != "" && ids["imdb"] == "" {
		ids["imdb"] = v
	}
	if v := strings.TrimSpace(doc.TvdbID); v != "" && ids["tvdb"] == "" {
		ids["tvdb"] = v
	}
	if v := strings.TrimSpace(doc.BareID); strings.HasPrefix(v, "tt") && ids["imdb"] == "" {
		ids["imdb"] = v
	}

	premiered := firstNonEmpty(doc.Premiered, doc.ReleaseDate, doc.Aired)
	var yearPtr *int
	if y, err := strconv.Atoi(strings.TrimSpace(doc.Year)); err == nil && y > 0 {
		yearPtr = &y
	} else if len(premiered) >= 4 {
		if y, err := strconv.Atoi(premiered[:4]); err == nil && y > 0 {
			yearPtr = &y
		}
	}
	var runtimeMs *int64
	if rt, err := strconv.Atoi(strings.TrimSpace(doc.Runtime)); err == nil && rt > 0 {
		v := int64(rt) * 60000
		runtimeMs = &v
	}

	genres := make([]string, 0, len(doc.Genres))
	for _, g := range doc.Genres {
		if t := strings.TrimSpace(g); t != "" {
			genres = append(genres, t)
		}
	}
	credits := make([]metadata.Credit, 0)
	for _, d := range doc.Directors {
		if t := strings.TrimSpace(d); t != "" {
			credits = append(credits, metadata.Credit{Name: t, Job: "director"})
		}
	}
	for _, w := range append(doc.Credits, doc.Writers...) {
		if t := strings.TrimSpace(w); t != "" {
			credits = append(credits, metadata.Credit{Name: t, Job: "writer"})
		}
	}
	for _, a := range doc.Actors {
		if name := strings.TrimSpace(a.Name); name != "" {
			credits = append(credits, metadata.Credit{
				Name:      name,
				Job:       "actor",
				Character: nonEmptyPtr(a.Role),
				PhotoPath: nonEmptyPtr(a.Thumb),
			})
		}
	}

	collTitle := firstNonEmpty(doc.Set.Name, doc.Set.Inner)
	kind := "movie"
	if rootName == "tvshow" {
		kind = "show"
	}

	return &metadata.Work{
		Source:          "nfo",
		Kind:            kind,
		Title:           title,
		OriginalTitle:   nonEmptyPtr(doc.OriginalTitle),
		Year:            yearPtr,
		ReleaseDate:     nonEmptyPtr(premiered),
		Summary:         nonEmptyPtr(firstNonEmpty(doc.Plot, doc.Outline)),
		Tagline:         nonEmptyPtr(doc.Tagline),
		Rating:          nfoRating(doc),
		RuntimeMs:       runtimeMs,
		ContentRating:   nonEmptyPtr(doc.Mpaa),
		Studio:          nonEmptyPtr(doc.Studio),
		Genres:          genres,
		Credits:         credits,
		TmdbID:          nonEmptyPtr(ids["tmdb"]),
		ImdbID:          nonEmptyPtr(ids["imdb"]),
		TvdbID:          nonEmptyPtr(ids["tvdb"]),
		BangumiID:       nonEmptyPtr(ids["bangumi"]),
		DoubanID:        nonEmptyPtr(ids["douban"]),
		AniListID:       nonEmptyPtr(ids["anilist"]),
		CollectionTitle: nonEmptyPtr(collTitle),
	}
}

func ReadEpisodeNFO(content string) *metadata.Episode {
	trimmed := trimNfoXML(content)
	if trimmed == "" {
		return nil
	}
	var doc nfoDoc
	if err := xml.Unmarshal([]byte(trimmed), &doc); err != nil {
		return nil
	}
	if strings.ToLower(doc.XMLName.Local) != "episodedetails" {
		return nil
	}
	num, err := strconv.Atoi(strings.TrimSpace(doc.Episode))
	if err != nil {
		return nil
	}
	var runtimeMs *int64
	if rt, err := strconv.Atoi(strings.TrimSpace(doc.Runtime)); err == nil && rt > 0 {
		v := int64(rt) * 60000
		runtimeMs = &v
	}
	return &metadata.Episode{
		Number:    num,
		Title:     nonEmptyPtr(doc.Title),
		Summary:   nonEmptyPtr(doc.Plot),
		AirDate:   nonEmptyPtr(doc.Aired),
		RuntimeMs: runtimeMs,
		Rating:    nfoRating(doc),
	}
}

func nfoRating(doc nfoDoc) *float64 {
	if v, err := strconv.ParseFloat(strings.TrimSpace(doc.Rating), 64); err == nil && v > 0 {
		return &v
	}
	for _, r := range doc.Ratings.Rating {
		if v, err := strconv.ParseFloat(strings.TrimSpace(r.Value), 64); err == nil && v > 0 {
			return &v
		}
	}
	return nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if t := strings.TrimSpace(v); t != "" {
			return t
		}
	}
	return ""
}

func nonEmptyPtr(s string) *string {
	t := strings.TrimSpace(s)
	if t == "" {
		return nil
	}
	return &t
}
