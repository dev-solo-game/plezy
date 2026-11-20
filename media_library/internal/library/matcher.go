package library

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/pathutil"
)

const acceptMatchScore = 0.72

// SidecarReader reads uploaded text sidecar files (such as .nfo) for a household.
type SidecarReader interface {
	ReadText(ctx context.Context, householdID, sha256 string) (string, error)
}

type Scraper struct {
	store    *db.Store
	meta     *metadata.Service
	sidecars SidecarReader
}

func NewScraper(store *db.Store, meta *metadata.Service) *Scraper {
	return &Scraper{
		store: store,
		meta:  meta,
	}
}

func (sc *Scraper) SetSidecarReader(r SidecarReader) {
	sc.sidecars = r
}

var (
	reTrailingCnSeason = regexp.MustCompile(`^(.*?)[\s._\-:：]*第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]\s*$`)
	reTrailingEnSeason = regexp.MustCompile(`(?i)^(.*?)[\s._\-:：]+(?:Season[\s._]*(\d{1,2})|S(\d{1,2}))\s*$`)
	reTrailingArabSeq  = regexp.MustCompile(`^(.*?)([\s._\-:：]*)([2-9])\s*$`)
	reTrailingRomanSeq = regexp.MustCompile(`(?i)^(.*?)[\s._\-:：]+(II|III|IV|V|VI|VII|VIII|IX)\s*$`)
	reTrailingUniRoman = regexp.MustCompile(`^(.*?)[\s._\-:：]*(Ⅱ|Ⅲ|Ⅳ|Ⅴ|Ⅵ|Ⅶ|Ⅷ|Ⅸ)\s*$`)
)

func parseTrailingSeasonTitle(title string) (string, int) {
	trimmed := strings.TrimSpace(title)
	if trimmed == "" {
		return "", 0
	}
	var rawBase string
	seasonNum := 0
	if m := reTrailingCnSeason.FindStringSubmatch(trimmed); m != nil {
		if n, ok := parseChineseOrArabic(m[2]); ok && n > 0 {
			rawBase = m[1]
			seasonNum = n
		}
	} else if m := reTrailingEnSeason.FindStringSubmatch(trimmed); m != nil {
		rawNum := m[2]
		if rawNum == "" {
			rawNum = m[3]
		}
		if n, err := strconv.Atoi(rawNum); err == nil && n > 0 {
			rawBase = m[1]
			seasonNum = n
		}
	}
	if seasonNum <= 0 {
		return "", 0
	}
	base := strings.TrimSpace(reDangleEdge.ReplaceAllString(rawBase, ""))
	if base == "" || strings.EqualFold(base, trimmed) {
		return "", 0
	}
	return base, seasonNum
}

var sequelRomanMap = map[string]int{
	"II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9,
	"Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5, "Ⅵ": 6, "Ⅶ": 7, "Ⅷ": 8, "Ⅸ": 9,
}

func validateSequelBase(rawBase, orig string, seq int) (string, int) {
	base := strings.TrimSpace(reDangleEdge.ReplaceAllString(rawBase, ""))
	if base == "" || strings.EqualFold(base, orig) {
		return "", 0
	}
	cjk := 0
	for _, r := range base {
		if isCJK(r) {
			cjk++
		}
	}
	norm := normalizeForScore(base)
	if cjk >= 2 || len([]rune(norm)) >= 4 {
		return base, seq
	}
	return "", 0
}

func parseTrailingSequelNumber(title string) (string, int) {
	trimmed := strings.TrimSpace(title)
	if trimmed == "" {
		return "", 0
	}
	if _, sn := parseTrailingSeasonTitle(trimmed); sn > 0 {
		return "", 0
	}
	if m := reTrailingArabSeq.FindStringSubmatch(trimmed); m != nil {
		rawBase, sep, digit := m[1], m[2], m[3]
		if sep == "" && rawBase != "" {
			lastR, _ := utf8.DecodeLastRuneInString(rawBase)
			if isASCIIDigit(lastR) {
				return "", 0
			}
		}
		if seq, err := strconv.Atoi(digit); err == nil && seq >= 2 && seq <= 9 {
			return validateSequelBase(rawBase, trimmed, seq)
		}
	}
	if m := reTrailingRomanSeq.FindStringSubmatch(trimmed); m != nil {
		if seq, ok := sequelRomanMap[strings.ToUpper(m[2])]; ok {
			return validateSequelBase(m[1], trimmed, seq)
		}
	}
	if m := reTrailingUniRoman.FindStringSubmatch(trimmed); m != nil {
		if seq, ok := sequelRomanMap[m[2]]; ok {
			return validateSequelBase(m[1], trimmed, seq)
		}
	}
	return "", 0
}

func isSubstantialQueryForUniqueFallback(query string) bool {
	cjk := 0
	for _, r := range query {
		if isCJK(r) {
			cjk++
		}
	}
	normRunes := len([]rune(normalizeForScore(query)))
	return cjk >= 3 || normRunes >= 5
}

// BuildWorkKey builds the canonical G1 work_key using priority order:
// TMDB -> IMDb -> TVDB -> Bangumi -> Douban -> AniList.
func BuildWorkKey(kind string, work metadata.Work) string {
	k := strings.ToLower(strings.TrimSpace(kind))
	if k == "" {
		k = strings.ToLower(strings.TrimSpace(work.Kind))
	}
	if k != db.KindShow {
		k = db.KindMovie
	}
	if work.TmdbID != nil && *work.TmdbID != "" {
		return fmt.Sprintf("tmdb:%s:%s", k, *work.TmdbID)
	}
	if work.ImdbID != nil && *work.ImdbID != "" {
		return fmt.Sprintf("imdb:%s:%s", k, *work.ImdbID)
	}
	if work.TvdbID != nil && *work.TvdbID != "" {
		return fmt.Sprintf("tvdb:%s:%s", k, *work.TvdbID)
	}
	if work.BangumiID != nil && *work.BangumiID != "" {
		return fmt.Sprintf("bangumi:%s:%s", k, *work.BangumiID)
	}
	if work.DoubanID != nil && *work.DoubanID != "" {
		return fmt.Sprintf("douban:%s:%s", k, *work.DoubanID)
	}
	if work.AniListID != nil && *work.AniListID != "" {
		return fmt.Sprintf("anilist:%s:%s", k, *work.AniListID)
	}
	if work.Source != "" && work.ExternalID != "" {
		return fmt.Sprintf("%s:%s:%s", strings.ToLower(strings.TrimSpace(work.Source)), k, strings.TrimSpace(work.ExternalID))
	}
	return ""
}

func supplementTmdbWork(tmdbWork *metadata.Work, aux *metadata.Work) {
	if aux == nil || tmdbWork == nil {
		return
	}
	if (tmdbWork.ImdbID == nil || *tmdbWork.ImdbID == "") && aux.ImdbID != nil && *aux.ImdbID != "" {
		v := *aux.ImdbID
		tmdbWork.ImdbID = &v
	}
	if (tmdbWork.TvdbID == nil || *tmdbWork.TvdbID == "") && aux.TvdbID != nil && *aux.TvdbID != "" {
		v := *aux.TvdbID
		tmdbWork.TvdbID = &v
	}
	if (tmdbWork.BangumiID == nil || *tmdbWork.BangumiID == "") && aux.BangumiID != nil && *aux.BangumiID != "" {
		v := *aux.BangumiID
		tmdbWork.BangumiID = &v
	}
	if (tmdbWork.DoubanID == nil || *tmdbWork.DoubanID == "") && aux.DoubanID != nil && *aux.DoubanID != "" {
		v := *aux.DoubanID
		tmdbWork.DoubanID = &v
	}
	if (tmdbWork.AniListID == nil || *tmdbWork.AniListID == "") && aux.AniListID != nil && *aux.AniListID != "" {
		v := *aux.AniListID
		tmdbWork.AniListID = &v
	}
	if (tmdbWork.Summary == nil || strings.TrimSpace(*tmdbWork.Summary) == "") && aux.Summary != nil && strings.TrimSpace(*aux.Summary) != "" {
		v := *aux.Summary
		tmdbWork.Summary = &v
	}
	if (tmdbWork.PosterPath == nil || strings.TrimSpace(*tmdbWork.PosterPath) == "") && aux.PosterPath != nil && strings.TrimSpace(*aux.PosterPath) != "" {
		v := *aux.PosterPath
		tmdbWork.PosterPath = &v
	}
	if (tmdbWork.BackdropPath == nil || strings.TrimSpace(*tmdbWork.BackdropPath) == "") && aux.BackdropPath != nil && strings.TrimSpace(*aux.BackdropPath) != "" {
		v := *aux.BackdropPath
		tmdbWork.BackdropPath = &v
	}
	if strings.TrimSpace(aux.Title) != "" {
		tmdbWork.Aliases = append(tmdbWork.Aliases, aux.Title)
	}
	if aux.OriginalTitle != nil && strings.TrimSpace(*aux.OriginalTitle) != "" {
		tmdbWork.Aliases = append(tmdbWork.Aliases, *aux.OriginalTitle)
	}
	tmdbWork.Aliases = append(tmdbWork.Aliases, aux.Aliases...)
}

func (sc *Scraper) lookupAuxCandidateWork(
	ctx context.Context,
	auxProv string,
	item db.MediaItem,
	rawTitles []string,
	lang string,
	forceSearch bool,
) (*bestMatchResult, string, metadata.Work, bool) {
	return sc.lookupAuxCandidateWorkWithKindPolicy(ctx, auxProv, item, rawTitles, lang, forceSearch, item.Kind == db.KindMovie)
}

func (sc *Scraper) lookupAuxCandidateWorkWithKindPolicy(
	ctx context.Context,
	auxProv string,
	item db.MediaItem,
	rawTitles []string,
	lang string,
	forceSearch bool,
	allowKindChange bool,
) (*bestMatchResult, string, metadata.Work, bool) {
	auxCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()

	auxMatch, auxKind, aErr := sc.matchOnProviderWithKindPolicy(auxCtx, auxProv, item, rawTitles, nil, lang, forceSearch, allowKindChange)
	if aErr != nil {
		applog.Warnf("scraper", "辅助源查询出错 #%d [%s]: %s", item.ID, auxProv, applog.RedactURL(aErr.Error()))
		return nil, "", metadata.Work{}, false
	}
	if auxMatch == nil {
		return nil, "", metadata.Work{}, false
	}
	auxWorkKind := auxKind
	if auxWorkKind == "" {
		auxWorkKind = item.Kind
	}
	auxWork, wErr := sc.meta.GetWork(auxCtx, auxProv, auxWorkKind, auxMatch.Candidate.ID, lang, forceSearch)
	if wErr != nil {
		applog.Warnf("scraper", "辅助源拉取详情失败 #%d [%s:%s]: %s", item.ID, auxProv, auxMatch.Candidate.ID, applog.RedactURL(wErr.Error()))
		return nil, "", metadata.Work{}, false
	}
	// Fetch Douban web HTML IMDb ID at most once for a confirmed winning Douban match.
	if auxProv == "douban" && (auxWork.ImdbID == nil || *auxWork.ImdbID == "") {
		if webImdb := sc.meta.FetchDoubanWebImdbID(auxCtx, auxWork.ExternalID); webImdb != "" {
			auxWork.ImdbID = &webImdb
		}
	}
	return auxMatch, auxWorkKind, auxWork, true
}

func (sc *Scraper) fetchEmbeddedAuxWork(ctx context.Context, kind string, emb EmbeddedIDs, lang string, refresh bool) *metadata.Work {
	tryFetch := func(prov, id string) *metadata.Work {
		if id == "" {
			return nil
		}
		if w, err := sc.meta.GetWork(ctx, prov, kind, id, lang, refresh); err == nil {
			return &w
		}
		return nil
	}
	if w := tryFetch("douban", emb.DoubanID); w != nil {
		return w
	}
	if w := tryFetch("bangumi", emb.BangumiID); w != nil {
		return w
	}
	if w := tryFetch("anilist", emb.AniListID); w != nil {
		return w
	}
	return nil
}

func collectAuxBridgeTitles(aux metadata.Work, alreadyTried []string) []string {
	triedSet := make(map[string]bool, len(alreadyTried))
	for _, t := range alreadyTried {
		norm := normalizeForScore(t)
		if norm != "" {
			triedSet[norm] = true
		}
	}
	var out []string
	seen := make(map[string]bool)
	add := func(s string) {
		t := strings.TrimSpace(s)
		if t == "" {
			return
		}
		norm := normalizeForScore(t)
		if norm == "" || triedSet[norm] || seen[norm] {
			return
		}
		seen[norm] = true
		out = append(out, t)
	}
	add(aux.Title)
	if aux.OriginalTitle != nil {
		add(*aux.OriginalTitle)
	}
	addedAliases := 0
	for _, a := range aux.Aliases {
		if addedAliases >= 4 {
			break
		}
		before := len(out)
		add(a)
		if len(out) > before {
			addedAliases++
		}
	}
	return out
}

func auxiliaryProvidersOrder(isAnime bool, cfg db.ServerSettings) []string {
	var order []string
	if isAnime {
		order = []string{"bangumi", "anilist", "douban", "tvdb", "imdb"}
	} else {
		order = []string{"douban", "imdb", "tvdb", "bangumi", "anilist"}
	}
	var out []string
	for _, p := range order {
		switch p {
		case "bangumi":
			if cfg.BangumiEnabled {
				out = append(out, p)
			}
		case "douban":
			if cfg.DoubanEnabled {
				out = append(out, p)
			}
		case "anilist":
			if cfg.AniListEnabled {
				out = append(out, p)
			}
		case "imdb":
			if cfg.ImdbEnabled {
				out = append(out, p)
			}
		case "tvdb":
			if cfg.TvdbEnabled && cfg.TvdbAPIKey != "" {
				out = append(out, p)
			}
		}
	}
	return out
}

func collectTitlesWithFolderHint(title, samplePath, customRules string) []string {
	var rawTitles []string
	addRaw := func(t string) {
		trimmed := strings.TrimSpace(t)
		if trimmed == "" {
			return
		}
		for _, ex := range rawTitles {
			if strings.EqualFold(ex, trimmed) {
				return
			}
		}
		rawTitles = append(rawTitles, trimmed)
	}
	if custom := ApplyCustomRecognitionWords(title, customRules); custom != "" {
		addRaw(custom)
	}
	addRaw(title)
	if folderTitle := folderTitleHintFromPath(samplePath); folderTitle != "" {
		if customFolder := ApplyCustomRecognitionWords(folderTitle, customRules); customFolder != "" {
			addRaw(customFolder)
		}
		addRaw(folderTitle)
	}
	return rawTitles
}

func buildQueryVariantsForTitles(rawTitles []string, isShow, allowSequelProbe bool) []queryVariant {
	var variants []queryVariant
	seenVar := make(map[string]bool)
	addVariant := func(q string, impliedSeason int, isSequel bool) {
		trimmed := strings.TrimSpace(q)
		if trimmed == "" {
			return
		}
		key := fmt.Sprintf("%s|%d|%v", strings.ToLower(trimmed), impliedSeason, isSequel)
		if seenVar[key] {
			return
		}
		seenVar[key] = true
		variants = append(variants, queryVariant{
			Query:         trimmed,
			ImpliedSeason: impliedSeason,
			IsSequelProbe: isSequel,
		})
	}

	for _, t := range rawTitles {
		addVariant(t, 0, false)
	}
	if isShow {
		seasonMatched := make(map[string]bool)
		for _, t := range rawTitles {
			if base, sNum := parseTrailingSeasonTitle(t); base != "" {
				seasonMatched[strings.ToLower(t)] = true
				addVariant(base, sNum, false)
			}
		}
		if allowSequelProbe {
			for _, t := range rawTitles {
				if seasonMatched[strings.ToLower(t)] {
					continue
				}
				if base, seqNum := parseTrailingSequelNumber(t); base != "" {
					addVariant(base, seqNum, true)
				}
			}
		}
	}
	return variants
}

type bestMatchResult struct {
	Provider      string
	Candidate     metadata.Candidate
	ImpliedSeason int
}

type queryVariant struct {
	Query         string
	ImpliedSeason int
	IsSequelProbe bool
}

func (sc *Scraper) matchOnProvider(
	ctx context.Context,
	prov string,
	item db.MediaItem,
	rawTitles []string,
	overrideYear *int,
	lang string,
	forceRefresh bool,
) (*bestMatchResult, string, error) {
	return sc.matchOnProviderWithKindPolicy(ctx, prov, item, rawTitles, overrideYear, lang, forceRefresh, item.Kind == db.KindMovie)
}

func (sc *Scraper) matchOnProviderWithKindPolicy(
	ctx context.Context,
	prov string,
	item db.MediaItem,
	rawTitles []string,
	overrideYear *int,
	lang string,
	forceRefresh bool,
	allowKindChange bool,
) (*bestMatchResult, string, error) {
	isShow := item.Kind == db.KindShow
	variants := buildQueryVariantsForTitles(rawTitles, isShow, isShow)
	res, err := sc.searchBestOnSingleProvider(ctx, prov, item, overrideYear, isShow, variants, lang, forceRefresh)
	if err != nil {
		return nil, "", err
	}
	if res != nil {
		return res, item.Kind, nil
	}
	if allowKindChange {
		altIsShow := !isShow
		altKind := db.KindMovie
		if altIsShow {
			altKind = db.KindShow
		}
		applog.Debugf("scraper", "主类型(%s)未命中，尝试切换类型(is_show=%v)搜索 [%s] #%d", item.Kind, altIsShow, prov, item.ID)
		altVariants := buildQueryVariantsForTitles(rawTitles, altIsShow, false)
		res, err = sc.searchBestOnSingleProvider(ctx, prov, item, overrideYear, altIsShow, altVariants, lang, forceRefresh)
		if err != nil {
			return nil, "", err
		}
		if res != nil {
			return res, altKind, nil
		}
	}
	return nil, "", nil
}

func (sc *Scraper) findBestMatch(
	ctx context.Context,
	providers []string,
	item db.MediaItem,
	samplePath string,
	isShow bool,
	allowSequelProbe bool,
	lang string,
	forceRefresh bool,
) (*bestMatchResult, error) {
	cfg := sc.store.GetServerSettings()
	rawTitles := collectTitlesWithFolderHint(item.Title, samplePath, cfg.CustomRecognitionWords)
	variants := buildQueryVariantsForTitles(rawTitles, isShow, allowSequelProbe)
	for _, prov := range providers {
		res, err := sc.searchBestOnSingleProvider(ctx, prov, item, nil, isShow, variants, lang, forceRefresh)
		if err != nil {
			if prov != "tmdb" && len(providers) > 1 {
				continue
			}
			return nil, err
		}
		if res != nil {
			return res, nil
		}
	}
	return nil, nil
}

func (sc *Scraper) searchBestOnSingleProvider(
	ctx context.Context,
	prov string,
	item db.MediaItem,
	overrideYear *int,
	isShow bool,
	variants []queryVariant,
	lang string,
	forceRefresh bool,
) (*bestMatchResult, error) {
	kind := "movie"
	if isShow {
		kind = "show"
	}
	targetYear := item.Year
	if targetYear == nil {
		targetYear = overrideYear
	}

	for _, v := range variants {
		if v.ImpliedSeason >= 2 || v.IsSequelProbe {
			if prov != "tmdb" {
				continue
			}
			matched, err := sc.matchMultiSeasonOrSequel(ctx, prov, item, v, lang, forceRefresh)
			if err != nil {
				return nil, err
			}
			if matched != nil {
				return matched, nil
			}
			continue
		}

		yearVal := 0
		if targetYear != nil {
			yearVal = *targetYear
		}
		supportsYearFilter := providerSupportsYearFilter(prov)
		usedYearFilter := yearVal > 0 && supportsYearFilter
		cands, err := sc.meta.Search(ctx, prov, kind, v.Query, yearVal, lang, forceRefresh)
		if err != nil {
			applog.Warnf("scraper", "搜索出错 #%d [%s/%s] year=%d: %s", item.ID, prov, kind, yearVal, applog.RedactURL(err.Error()))
			return nil, err
		}
		if len(cands) == 0 && usedYearFilter {
			usedYearFilter = false
			cands, err = sc.meta.Search(ctx, prov, kind, v.Query, 0, lang, forceRefresh)
			if err != nil {
				applog.Warnf("scraper", "无年份兜底搜索出错 #%d [%s/%s]: %s", item.ID, prov, kind, applog.RedactURL(err.Error()))
				return nil, err
			}
		}
		if len(cands) == 0 {
			applog.Debugf("scraper", "搜索无候选 #%d [%s/%s] year=%d", item.ID, prov, kind, yearVal)
			continue
		}

		// Pass 1: Surface title + year score
		var best *metadata.Candidate
		bestScore := -1e9
		for rank, c := range cands {
			score := matchCandidateScore(v.Query, targetYear, c) - float64(rank)*0.001
			if score > bestScore {
				copyC := c
				best = &copyC
				bestScore = score
			}
		}
		if best != nil && bestScore >= acceptMatchScore {
			applog.Debugf("scraper", "命中最佳候选 #%d [%s/%s] -> [%s:%s] score=%.2f", item.ID, prov, kind, prov, best.ID, bestScore)
			return &bestMatchResult{Provider: prov, Candidate: *best, ImpliedSeason: v.ImpliedSeason}, nil
		}

		// Pass 2: Work Aliases re-scoring via GetWork (top up to 3 candidates)
		type rankedCand struct {
			rank int
			cand metadata.Candidate
		}
		var inspectList []rankedCand
		picked := make(map[int]bool)
		for rank, c := range cands {
			if len(inspectList) >= 3 {
				break
			}
			if targetYear == nil || c.Year == nil || int(math.Abs(float64(*targetYear-*c.Year))) <= 1 {
				inspectList = append(inspectList, rankedCand{rank: rank, cand: c})
				picked[rank] = true
			}
		}
		for rank, c := range cands {
			if len(inspectList) >= 3 {
				break
			}
			if !picked[rank] {
				inspectList = append(inspectList, rankedCand{rank: rank, cand: c})
			}
		}

		var bestAliasCand *metadata.Candidate
		bestAliasScore := -1e9
		for _, rc := range inspectList {
			work, wErr := sc.meta.GetWork(ctx, prov, kind, rc.cand.ID, lang, forceRefresh)
			if wErr != nil {
				if errors.Is(wErr, metadata.ErrTmdbUpstream) {
					return nil, wErr
				}
				continue
			}
			if len(work.Aliases) == 0 {
				continue
			}
			aScore, _, _ := matchCandidateScoreWithAliases(v.Query, targetYear, rc.cand, work.Aliases)
			aScore -= float64(rc.rank) * 0.001
			if aScore > bestAliasScore {
				copyC := rc.cand
				bestAliasCand = &copyC
				bestAliasScore = aScore
			}
		}
		if bestAliasCand != nil && bestAliasScore >= acceptMatchScore {
			applog.Debugf("scraper", "命中候选别名 #%d [%s/%s] -> [%s:%s] score=%.2f", item.ID, prov, kind, prov, bestAliasCand.ID, bestAliasScore)
			return &bestMatchResult{Provider: prov, Candidate: *bestAliasCand, ImpliedSeason: v.ImpliedSeason}, nil
		}

		// Pass 3: Safe same-year unique candidate fallback
		if usedYearFilter && targetYear != nil && len(cands) == 1 && isSubstantialQueryForUniqueFallback(v.Query) {
			sole := cands[0]
			if sole.Year != nil && int(math.Abs(float64(*targetYear-*sole.Year))) <= 1 {
				applog.Debugf("scraper", "唯一同年候选保底命中 #%d [%s/%s] -> [%s:%s]", item.ID, prov, kind, prov, sole.ID)
				return &bestMatchResult{Provider: prov, Candidate: sole, ImpliedSeason: v.ImpliedSeason}, nil
			}
		}

		if best != nil {
			applog.Debugf("scraper", "候选得分未达标 #%d [%s/%s] count=%d top=%.2f best=%s", item.ID, prov, kind, len(cands), bestScore, best.ID)
		}
	}
	return nil, nil
}

func (sc *Scraper) matchMultiSeasonOrSequel(
	ctx context.Context,
	prov string,
	item db.MediaItem,
	v queryVariant,
	lang string,
	forceRefresh bool,
) (*bestMatchResult, error) {
	cands, err := sc.meta.Search(ctx, prov, "show", v.Query, 0, lang, forceRefresh)
	if err != nil {
		applog.Warnf("scraper", "续季搜索出错 #%d [%s/show]: %s", item.ID, prov, applog.RedactURL(err.Error()))
		return nil, err
	}
	if len(cands) == 0 {
		return nil, nil
	}

	reqSim := acceptMatchScore
	if v.IsSequelProbe {
		reqSim = 0.95
	}
	wantedNorm := normalizeForScore(v.Query)

	checked := 0
	for _, c := range cands {
		if checked >= 5 {
			break
		}
		if item.Year != nil && c.Year != nil && *c.Year > *item.Year+1 {
			continue
		}
		checked++

		names := []string{c.Title}
		if c.OriginalTitle != nil {
			names = append(names, *c.OriginalTitle)
		}
		rawSim, _ := titleSimilarity(wantedNorm, names)
		if rawSim < reqSim {
			work, wErr := sc.meta.GetWork(ctx, prov, "show", c.ID, lang, forceRefresh)
			if wErr != nil {
				if errors.Is(wErr, metadata.ErrTmdbUpstream) {
					return nil, wErr
				}
			} else if len(work.Aliases) > 0 {
				rawSim, _ = titleSimilarity(wantedNorm, append(names, work.Aliases...))
			}
		}
		if rawSim < reqSim {
			continue
		}

		ok, seasonYear, sErr := sc.verifyShowHasSeason(ctx, prov, c.ID, v.ImpliedSeason, item.Year, lang, forceRefresh)
		if sErr != nil {
			if errors.Is(sErr, metadata.ErrTmdbUpstream) {
				return nil, sErr
			}
			applog.Warnf("scraper", "校验主剧第 %d 季失败 #%d [%s:%s]: %s", v.ImpliedSeason, item.ID, prov, c.ID, applog.RedactURL(sErr.Error()))
			continue
		}
		if !ok {
			continue
		}
		applog.Debugf("scraper", "续季匹配成功 #%d [%s:%s] season=%d year=%d", item.ID, prov, c.ID, v.ImpliedSeason, seasonYear)
		return &bestMatchResult{Provider: prov, Candidate: c, ImpliedSeason: v.ImpliedSeason}, nil
	}
	return nil, nil
}

func extractYearPrefix(dateStr *string) int {
	if dateStr == nil {
		return 0
	}
	t := strings.TrimSpace(*dateStr)
	if len(t) < 4 {
		return 0
	}
	y, err := strconv.Atoi(t[:4])
	if err != nil || y < 1900 || y > 2100 {
		return 0
	}
	return y
}

func (sc *Scraper) verifyShowHasSeason(ctx context.Context, prov, showID string, seasonNum int, expectedYear *int, lang string, forceRefresh bool) (bool, int, error) {
	season, err := sc.meta.GetSeason(ctx, prov, showID, seasonNum, lang, forceRefresh)
	if err != nil {
		if errors.Is(err, metadata.ErrNotFound) {
			return false, 0, nil
		}
		return false, 0, err
	}
	seasonYear := extractYearPrefix(season.AirDate)
	if seasonYear == 0 {
		for _, ep := range season.Episodes {
			if y := extractYearPrefix(ep.AirDate); y > 0 {
				seasonYear = y
				break
			}
		}
	}
	if expectedYear != nil && seasonYear > 0 {
		if int(math.Abs(float64(*expectedYear-seasonYear))) > 2 {
			return false, seasonYear, nil
		}
	}
	return true, seasonYear, nil
}

func providerSupportsYearFilter(prov string) bool {
	return prov == "tmdb" || prov == "tvdb"
}

var genericCategoryFolders = map[string]bool{
	"电影": true, "電影": true,
	"电视剧": true, "電視劇": true,
	"电影电视剧": true, "電影電視劇": true,
	"剧集": true, "劇集": true,
	"连续剧": true, "連續劇": true,
	"动漫": true, "動漫": true,
	"动画": true, "動畫": true,
	"番剧": true, "番劇": true,
	"国漫": true, "國漫": true,
	"日漫": true, "美漫": true,
	"综艺": true, "綜藝": true,
	"纪录片": true, "紀錄片": true,
	"影视": true, "影視": true,
	"视频": true, "視頻": true,
	"合集": true, "资源": true, "資源": true,
	"下载": true, "下載": true,
	"外语电影": true, "外語電影": true,
	"华语电影": true, "華語電影": true,
	"国产剧": true, "國產劇": true,
	"美剧": true, "美劇": true,
	"韩剧": true, "韓劇": true,
	"日剧": true, "日劇": true,
	"港剧": true, "港劇": true,
	"台剧": true, "台劇": true,
	"英剧": true, "英劇": true,
	"短剧": true, "短劇": true,
	"网剧": true, "網劇": true,
	"movie": true, "movies": true, "film": true, "films": true,
	"tv": true, "tv shows": true, "tv show": true, "shows": true, "series": true,
	"anime": true, "documentary": true, "documentaries": true, "variety": true,
	"video": true, "videos": true, "media": true, "download": true, "downloads": true,
	"4k": true, "1080p": true, "remux": true, "hdr": true,
}

func isGenericCategoryFolder(name string) bool {
	low := strings.ToLower(strings.TrimSpace(name))
	if low == "" {
		return true
	}
	return genericCategoryFolders[low]
}

func folderTitleHintFromPath(filePath string) string {
	if strings.TrimSpace(filePath) == "" {
		return ""
	}
	segs := pathutil.PathSegments(pathutil.ParentPath(filePath))
	for i := len(segs) - 1; i >= 0 && i >= len(segs)-2; i-- {
		pf := ParseFolderName(segs[i])
		if pf.IsSeasonFolder || pf.Title == "" || isGenericCategoryFolder(pf.Title) {
			continue
		}
		return pf.Title
	}
	return ""
}

func isASCIIAlphaLower(r rune) bool {
	return r >= 'a' && r <= 'z'
}

// cjkAbbrevSkeletonSimilarity matches cloud-drive censorship abbreviations embedded inside
// a Chinese title (e.g. "我的sj大电影" -> "我的世界大电影") while strictly refusing pure-CJK,
// pure-ASCII, out-of-order anchors, or ASCII-gap false positives.
func cjkAbbrevSkeletonSimilarity(wantedNorm, other string) float64 {
	type abbrevSeg struct {
		ascii bool
		runes []rune
	}
	wRunes := []rune(wantedNorm)
	oRunes := []rune(other)
	if len(wRunes) == 0 || len(oRunes) == 0 {
		return 0
	}

	var segs []abbrevSeg
	cjkAnchors := 0
	literalAnchors := 0
	asciiSegs := 0

	for i := 0; i < len(wRunes); {
		isA := isASCIIAlphaLower(wRunes[i])
		j := i + 1
		for j < len(wRunes) && isASCIIAlphaLower(wRunes[j]) == isA {
			j++
		}
		part := wRunes[i:j]
		if isA {
			if len(part) < 1 || len(part) > 6 {
				return 0
			}
			asciiSegs++
		} else {
			for _, r := range part {
				if isCJK(r) {
					cjkAnchors++
				}
			}
			literalAnchors += len(part)
		}
		segs = append(segs, abbrevSeg{ascii: isA, runes: part})
		i = j
	}

	if asciiSegs == 0 || asciiSegs > 2 || cjkAnchors < 2 || literalAnchors < 3 {
		return 0
	}
	if float64(literalAnchors)/float64(len(oRunes)) < 0.55 {
		return 0
	}

	var matchAt func(si, oi int) bool
	matchAt = func(si, oi int) bool {
		if si == len(segs) {
			return oi == len(oRunes)
		}
		s := segs[si]
		if !s.ascii {
			if oi+len(s.runes) > len(oRunes) {
				return false
			}
			for k, r := range s.runes {
				if oRunes[oi+k] != r {
					return false
				}
			}
			return matchAt(si+1, oi+len(s.runes))
		}
		maxGap := len(s.runes)
		for g := 1; g <= maxGap && oi+g <= len(oRunes); g++ {
			if !isCJK(oRunes[oi+g-1]) {
				break
			}
			if matchAt(si+1, oi+g) {
				return true
			}
		}
		return false
	}

	if matchAt(0, 0) {
		return 0.78
	}
	return 0
}

func titleSimilarity(wantedNorm string, names []string) (float64, string) {
	if wantedNorm == "" {
		return 0, ""
	}
	bestSim := 0.0
	bestName := ""
	for _, n := range names {
		other := normalizeForScore(n)
		if other == "" {
			continue
		}
		s := 0.0
		if other == wantedNorm {
			s = 1.0
		} else {
			s = diceSimilarity(wantedNorm, other)
			if skel := cjkAbbrevSkeletonSimilarity(wantedNorm, other); skel > s {
				s = skel
			}
		}
		if s > bestSim {
			bestSim = s
			bestName = n
		}
	}
	return bestSim, bestName
}

func applyYearScore(sim float64, itemYear, candYear *int) float64 {
	if itemYear != nil && candYear != nil {
		gap := int(math.Abs(float64(*itemYear - *candYear)))
		if gap == 0 {
			return sim + 0.15
		} else if gap == 1 {
			return sim + 0.05
		}
		return sim - 0.35
	}
	return sim
}

func matchCandidateScore(title string, year *int, cand metadata.Candidate) float64 {
	names := []string{cand.Title}
	if cand.OriginalTitle != nil {
		names = append(names, *cand.OriginalTitle)
	}
	sim, _ := titleSimilarity(normalizeForScore(title), names)
	return applyYearScore(sim, year, cand.Year)
}

func matchCandidateScoreWithAliases(title string, year *int, cand metadata.Candidate, extraNames []string) (float64, float64, string) {
	names := make([]string, 0, 2+len(extraNames))
	names = append(names, cand.Title)
	if cand.OriginalTitle != nil {
		names = append(names, *cand.OriginalTitle)
	}
	names = append(names, extraNames...)
	rawSim, hitName := titleSimilarity(normalizeForScore(title), names)
	return applyYearScore(rawSim, year, cand.Year), rawSim, hitName
}

func normalizeForScore(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// diceSimilarity computes Sorensen-Dice bigram similarity over runes.
func diceSimilarity(a, b string) float64 {
	ra := []rune(a)
	rb := []rune(b)
	if len(ra) == 0 && len(rb) == 0 {
		return 1.0
	}
	if len(ra) < 2 || len(rb) < 2 {
		if a == b {
			return 1.0
		}
		return 0.0
	}
	counts := make(map[string]int, len(ra)-1)
	for i := 0; i < len(ra)-1; i++ {
		bg := string(ra[i : i+2])
		counts[bg]++
	}
	matches := 0
	for i := 0; i < len(rb)-1; i++ {
		bg := string(rb[i : i+2])
		if counts[bg] > 0 {
			counts[bg]--
			matches++
		}
	}
	return float64(2*matches) / float64((len(ra)-1)+(len(rb)-1))
}
