package library

import (
	"regexp"
	"strings"

	"plezy/media_library/internal/applog"
)

type EmbeddedIDs struct {
	TmdbID    string
	ImdbID    string
	TvdbID    string
	DoubanID  string
	BangumiID string
	AniListID string
}

var (
	reEmbTmdb    = regexp.MustCompile(`(?i)[\[{(\s._-]tmdbid[-=: ]*(\d{1,10})[\]})\s._-]?|[\[{]tmdb[-=:](\d{1,10})[\]}]`)
	reEmbImdb    = regexp.MustCompile(`(?i)[\[{(\s._-](?:imdb(?:id)?[-=: ]*)?(tt\d{5,12})(?:[\]})]|\b)`)
	reEmbTvdb    = regexp.MustCompile(`(?i)[\[{(\s._-]tvdbid[-=: ]*(\d{1,10})[\]})\s._-]?|[\[{]tvdb[-=:](\d{1,10})[\]}]`)
	reEmbDouban  = regexp.MustCompile(`(?i)[\[{(\s._-]douban(?:id)?[-=: ]*(\d{5,12})[\]})\s._-]?`)
	reEmbBangumi = regexp.MustCompile(`(?i)[\[{(\s._-](?:bgm|bangumi)(?:id)?[-=: ]*(\d{1,10})[\]})\s._-]?`)
	reEmbAniList = regexp.MustCompile(`(?i)[\[{(\s._-]anilist(?:id)?[-=: ]*(\d{1,10})[\]})\s._-]?`)

	reManualImdbOnly    = regexp.MustCompile(`(?i)^(?:imdb\s*[:#]\s*)?(tt\d{5,12})$`)
	reManualPrefixed    = regexp.MustCompile(`(?i)^(tmdb|douban|bgm|bangumi|tvdb|anilist)\s*[:#]\s*(?:(movie|tv|show|series)\s*[:#]\s*)?(\d{1,12})$`)
	reURLTmdb           = regexp.MustCompile(`(?i)themoviedb\.org/(movie|tv)/(\d+)`)
	reURLDouban         = regexp.MustCompile(`(?i)douban\.com/(?:movie/)?subject/(\d+)`)
	reURLImdb           = regexp.MustCompile(`(?i)imdb\.com/title/(tt\d{5,12})`)
	reURLBangumi        = regexp.MustCompile(`(?i)(?:bgm\.tv|bangumi\.tv)/subject/(\d+)`)
	reURLAniList        = regexp.MustCompile(`(?i)anilist\.co/anime/(\d+)`)
	reURLTvdb           = regexp.MustCompile(`(?i)thetvdb\.com/(?:dereferrer/)?(series|movie)/(\d+)`)
)

// ApplyCustomRecognitionWords applies user-defined custom title replacement / noise-stripping rules.
// Supported line formats:
//   - "old => new" or "old -> new": case-insensitive literal replacement
//   - "re:<regex> => new": regex replacement
//   - "noise_word": case-insensitive literal removal
func ApplyCustomRecognitionWords(title, rulesText string) string {
	orig := strings.TrimSpace(title)
	if orig == "" || strings.TrimSpace(rulesText) == "" {
		return orig
	}
	cur := orig
	for _, rawLine := range strings.Split(rulesText, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
			continue
		}
		var lhs, rhs string
		if idx := strings.Index(line, "=>"); idx >= 0 {
			lhs = strings.TrimSpace(line[:idx])
			rhs = strings.TrimSpace(line[idx+2:])
		} else if idx := strings.Index(line, "->"); idx >= 0 {
			lhs = strings.TrimSpace(line[:idx])
			rhs = strings.TrimSpace(line[idx+2:])
		} else {
			lhs = line
			rhs = ""
		}
		if lhs == "" {
			continue
		}
		if strings.HasPrefix(strings.ToLower(lhs), "re:") {
			pat := strings.TrimSpace(lhs[3:])
			if pat == "" {
				continue
			}
			re, err := regexp.Compile(pat)
			if err != nil {
				applog.Debugf("scraper", "忽略无效的自定义识别词正则 %q: %v", pat, err)
				continue
			}
			cur = re.ReplaceAllString(cur, rhs)
		} else {
			re := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(lhs))
			cur = re.ReplaceAllString(cur, rhs)
		}
	}
	cur = strings.Join(strings.Fields(cur), " ")
	cur = strings.TrimSpace(reDangleEdge.ReplaceAllString(cur, ""))
	if cur == "" {
		return orig
	}
	return cur
}

func firstSubmatch(re *regexp.Regexp, text string) string {
	m := re.FindStringSubmatch(text)
	for i := 1; i < len(m); i++ {
		if m[i] != "" {
			return m[i]
		}
	}
	return ""
}

// ExtractEmbeddedExternalIDs inspects file or folder paths for embedded ID markers
// such as [tt1234567], {tmdb-12345}, {tvdb-67890}, or {douban-36283066}.
func ExtractEmbeddedExternalIDs(paths ...string) EmbeddedIDs {
	var out EmbeddedIDs
	for _, p := range paths {
		if strings.TrimSpace(p) == "" {
			continue
		}
		if out.TmdbID == "" {
			out.TmdbID = firstSubmatch(reEmbTmdb, p)
		}
		if out.ImdbID == "" {
			out.ImdbID = strings.ToLower(firstSubmatch(reEmbImdb, p))
		}
		if out.TvdbID == "" {
			out.TvdbID = firstSubmatch(reEmbTvdb, p)
		}
		if out.DoubanID == "" {
			out.DoubanID = firstSubmatch(reEmbDouban, p)
		}
		if out.BangumiID == "" {
			out.BangumiID = firstSubmatch(reEmbBangumi, p)
		}
		if out.AniListID == "" {
			out.AniListID = firstSubmatch(reEmbAniList, p)
		}
	}
	return out
}

// ParseManualDirectID recognizes explicit external IDs or pasted metadata URLs in manual search queries,
// returning (provider, externalID, kindHint, true).
func ParseManualDirectID(query string) (string, string, string, bool) {
	q := strings.TrimSpace(query)
	if q == "" {
		return "", "", "", false
	}
	if m := reManualImdbOnly.FindStringSubmatch(q); m != nil {
		return "imdb", strings.ToLower(m[1]), "", true
	}
	if m := reManualPrefixed.FindStringSubmatch(q); m != nil {
		prov := strings.ToLower(m[1])
		if prov == "bgm" {
			prov = "bangumi"
		}
		kindHint := ""
		switch strings.ToLower(m[2]) {
		case "movie":
			kindHint = "movie"
		case "tv", "show", "series":
			kindHint = "show"
		}
		return prov, m[3], kindHint, true
	}
	if m := reURLTmdb.FindStringSubmatch(q); m != nil {
		kindHint := "movie"
		if strings.EqualFold(m[1], "tv") {
			kindHint = "show"
		}
		return "tmdb", m[2], kindHint, true
	}
	if m := reURLDouban.FindStringSubmatch(q); m != nil {
		return "douban", m[1], "", true
	}
	if m := reURLImdb.FindStringSubmatch(q); m != nil {
		return "imdb", strings.ToLower(m[1]), "", true
	}
	if m := reURLBangumi.FindStringSubmatch(q); m != nil {
		return "bangumi", m[1], "", true
	}
	if m := reURLAniList.FindStringSubmatch(q); m != nil {
		return "anilist", m[1], "show", true
	}
	if m := reURLTvdb.FindStringSubmatch(q); m != nil {
		kindHint := "show"
		if strings.EqualFold(m[1], "movie") {
			kindHint = "movie"
		}
		return "tvdb", m[2], kindHint, true
	}
	return "", "", "", false
}
