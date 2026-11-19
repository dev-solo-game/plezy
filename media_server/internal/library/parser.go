package library

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

type ParsedName struct {
	Title        string `json:"title,omitempty"`
	Year         *int   `json:"year,omitempty"`
	Season       *int   `json:"season,omitempty"`
	Episode      *int   `json:"episode,omitempty"`
	EpisodeEnd   *int   `json:"episodeEnd,omitempty"`
	LooseEpisode *int   `json:"looseEpisode,omitempty"`
	IsSpecial    bool   `json:"isSpecial,omitempty"`
	Resolution   string `json:"resolution,omitempty"`
	Source       string `json:"source,omitempty"`
	VideoCodec   string `json:"videoCodec,omitempty"`
	HDR          string `json:"hdr,omitempty"`
	Edition      string `json:"edition,omitempty"`
	ReleaseGroup string `json:"releaseGroup,omitempty"`
	FansubStyle  bool   `json:"fansubStyle,omitempty"`
}

func (p ParsedName) HasEpisodeMarker() bool {
	return p.Episode != nil || p.Season != nil || p.IsSpecial
}

type ParsedFolder struct {
	Title          string
	Year           *int
	Season         *int
	IsSeasonFolder bool
}

var (
	reExtension      = regexp.MustCompile(`\.[A-Za-z0-9]{2,5}$`)
	reResolution     = regexp.MustCompile(`(2160|1440|1080|720|576|480)[pPiI]`)
	reFourK          = regexp.MustCompile(`(?i)(4k|uhd|8k)`)
	reDimensions     = regexp.MustCompile(`(3840|1920|1280)\s*[xX×]\s*(2160|1080|720)`)
	reSource         = regexp.MustCompile(`(?i)(Blu-?Ray|BDRip|BRRip|BDMV|UHD\s?BD|BD|REMUX|WEB-?DL|WEB-?Rip|WEB|HDTV|PDTV|DVDRip|DVD|HDRip|HDTC|HDCAM|TS|TC|CAM)`)
	reCodec          = regexp.MustCompile(`(?i)([xXhH][\s.]?26[45]|HEVC|AVC|AV1|VP9|XviD|DivX|MPEG-?2|10bit|8bit|Hi10P)`)
	reHDR            = regexp.MustCompile(`(?i)(HDR10\+|HDR10|HDR|DoVi|DV|Dolby[\s.]?Vision|HLG)`)
	reAudio          = regexp.MustCompile(`(?i)(DTS-?HD(?:[\s.]?MA)?|DTS-?X|DTS|TrueHD|Atmos|E-?AC-?3|AC-?3|DDP?[\s.]?[257]\.[01]|DD\+?|AAC(?:[\s.]?[257]\.[01])?|FLAC|LPCM|MP3|[257]\.[01])`)
	reEdition        = regexp.MustCompile(`(?i)(Director'?s[\s.]Cut|Extended(?:[\s.](?:Cut|Edition))?|Unrated|Uncut|Theatrical(?:[\s.]Cut)?|IMAX|Remastered|Criterion|Final[\s.]Cut|Special[\s.]Edition)|(导演剪辑版|導演剪輯版|加长版|加長版|未删减版|未刪減版|重制版|重製版|修复版|修復版)`)
	reMisc           = regexp.MustCompile(`(?i)(PROPER|REPACK|INTERNAL|LIMITED|COMPLETE|MULTI|DUAL|SUBBED|DUBBED|HC|NF|AMZN|DSNP|HMAX|ATVP)|(国语|國語|粤语|粵語|中字|双语|雙語|简体|簡體|繁体|繁體|中英|简繁|簡繁|内封|內封|外挂|外掛|字幕|国粤|國粵|蓝光|藍光|原盘|原盤|高清|超清|完结|完結|全集)`)
	reSeasonEpisode  = regexp.MustCompile(`[Ss](\d{1,2})[\s._-]*[Ee][Pp]?(\d{1,4})(?:[\s._-]*(?:-|[Ee][Pp]?)\s*[Ee]?[Pp]?(\d{1,4}))?`)
	reCrossFormat    = regexp.MustCompile(`(\d{1,2})[xX](\d{2,3})`)
	reSeasonWord     = regexp.MustCompile(`(?i)Season[\s._]*(\d{1,2})`)
	reSeasonOnly     = regexp.MustCompile(`[Ss](\d{1,2})`)
	reSeasonChinese  = regexp.MustCompile(`第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]`)
	reEpisodeChinese = regexp.MustCompile(`第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[集话話回期]`)
	reEpisodeWord    = regexp.MustCompile(`(?i)(?:Episode|Ep|E)[\s._-]*(\d{1,4})(?:\s*-\s*[Ee]?[Pp]?(\d{1,4}))?`)
	reSpecial        = regexp.MustCompile(`(?i)(OVA|OAD|ONA|SP|Specials?|NCOP|NCED|PV|CM)[\s._-]*(\d{1,3})?|(番外|特别篇|特別篇|剧场版|劇場版)`)
	reYear           = regexp.MustCompile(`(19\d{2}|20\d{2})`)
	reLeadingYear    = regexp.MustCompile(`^\s*[\[(【（]?((?:19|20)\d{2})[\])】）]?[\s._\-]+`)
	reLeadingCnEp    = regexp.MustCompile(`^第\s*[0-9零〇一二三四五六七八九十百两兩]+\s*[集话話回期季部]`)
	reBrackets       = regexp.MustCompile(`[\[【]([^\]】]*)[\]】]`)
	reLeadingBracket = regexp.MustCompile(`^\s*[\[【]([^\]】]*)[\]】]`)
	reBracketEp      = regexp.MustCompile(`(?i)^(\d{1,4})(?:[vV]\d)?(?:\s*END)?$`)
	reStarBanner     = regexp.MustCompile(`★[^★]*★`)
	reParen          = regexp.MustCompile(`[（(]\s*([^）)]*)\s*[）)]`)
	reChecksum       = regexp.MustCompile(`^[0-9A-Fa-f]{8}$`)
	reNonFansubTag   = regexp.MustCompile(`(?i)https?:|www\.|\.(?:com|net|org|tv|cc|cn|me|vip|la|xyz|top|info)(?:[^a-z0-9]|$)|电影|電影|影视|影視|影院|剧集|劇集|电视剧|電視劇|美剧|美劇|韩剧|韓劇|日剧|日劇|港剧|港劇|蓝光网|藍光網|bt之家|btbtt|dytt|ygdy|6v|piaohua|飘花|阳光|迅雷|网盘|網盤|夸克|阿里云|百度云|公众号|公眾號|首发|首發`)
	reFansubHint     = regexp.MustCompile(`(?i)字幕|组|組|社|屋|学园|學園|家族|汉化|漢化|工作室|raws|subs?(?:[^a-z0-9]|$)|vcb-studio|lolihouse|sakurato|lilith|ank|moe`)
	reTrailingGroup  = regexp.MustCompile(`-\s*([A-Za-z0-9][A-Za-z0-9@.]{1,24})\s*$`)
	reLooseDash      = regexp.MustCompile(`\s-\s*(\d{1,4})(?:[vV]\d)?(?:\s|$)`)
	reLooseTrailing  = regexp.MustCompile(`(?:^|\s)(\d{1,4})(?:[vV]\d)?\s*$`)

	reSeasonFolder   = regexp.MustCompile(`(?i)^\s*(?:Season|Series|S)[\s._-]*(\d{1,2})\s*$|^\s*第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]\s*$`)
	reSpecialsFolder = regexp.MustCompile(`(?i)^\s*(Specials?|SP|SPs|OVA|OAD|番外|特别篇|特別篇)\s*$`)

	reStandardMovie   = regexp.MustCompile(`^([^\[\]【】]+?)\s\(((?:19|20)\d{2})\)(?:-(\S+?))?(?:\s-\s(.+))?$`)
	reStandardEpisode = regexp.MustCompile(`^([^\[\]【】]+?)\s-\s[Ss](\d{1,2})[Ee](\d{1,4})(?:-?[Ee](\d{1,4}))?(?:-(\S+?))?(?:\s-\s(.+))?$`)
	reLeadingDigits   = regexp.MustCompile(`^\d{1,4}(?:\s|$)`)
)

func isASCIIAlnum(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

func isASCIILetter(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

func isASCIIDigit(r rune) bool {
	return r >= '0' && r <= '9'
}

func isCJK(r rune) bool {
	return (r >= 0x3400 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF)
}

type boundKind int

const (
	boundNone boundKind = iota
	boundAlnum
	boundDigit
	boundLetter
	boundAlnumLeftDigitRight
	boundDigitLeftAlnumRight
	boundLetterLeftAlnumDigitRight
)

func checkBounds(s string, start, end int, b boundKind) bool {
	prevRune := rune(0)
	hasPrev := start > 0
	if hasPrev {
		prevRune, _ = utf8.DecodeLastRuneInString(s[:start])
	}
	nextRune := rune(0)
	hasNext := end < len(s)
	if hasNext {
		nextRune, _ = utf8.DecodeRuneInString(s[end:])
	}

	switch b {
	case boundAlnum:
		return (!hasPrev || !isASCIIAlnum(prevRune)) && (!hasNext || !isASCIIAlnum(nextRune))
	case boundDigit:
		return (!hasPrev || !isASCIIDigit(prevRune)) && (!hasNext || !isASCIIDigit(nextRune))
	case boundLetter:
		return (!hasPrev || !isASCIILetter(prevRune)) && (!hasNext || !isASCIIDigit(nextRune))
	case boundAlnumLeftDigitRight:
		return (!hasPrev || !isASCIIAlnum(prevRune)) && (!hasNext || !isASCIIDigit(nextRune))
	case boundDigitLeftAlnumRight:
		return (!hasPrev || !isASCIIAlnum(prevRune)) && (!hasNext || (!isASCIIDigit(nextRune) && nextRune != 'x' && nextRune != 'X'))
	case boundLetterLeftAlnumDigitRight:
		return (!hasPrev || !isASCIILetter(prevRune)) && (!hasNext || !isASCIIAlnum(nextRune))
	default:
		return true
	}
}

func findFirstBoundMatch(s string, re *regexp.Regexp, b boundKind) []int {
	all := re.FindAllStringSubmatchIndex(s, -1)
	for _, idx := range all {
		if checkBounds(s, idx[0], idx[1], b) {
			return idx
		}
	}
	return nil
}

func findAllBoundMatches(s string, re *regexp.Regexp, b boundKind) [][]int {
	all := re.FindAllStringSubmatchIndex(s, -1)
	var out [][]int
	for _, idx := range all {
		if checkBounds(s, idx[0], idx[1], b) {
			out = append(out, idx)
		}
	}
	return out
}

func hasBoundMatch(s string, re *regexp.Regexp, b boundKind) bool {
	return findFirstBoundMatch(s, re, b) != nil
}

func stripBoundMatches(s string, re *regexp.Regexp, b boundKind) string {
	matches := findAllBoundMatches(s, re, b)
	if len(matches) == 0 {
		return s
	}
	var buf strings.Builder
	last := 0
	for _, m := range matches {
		buf.WriteString(s[last:m[0]])
		buf.WriteByte(' ')
		last = m[1]
	}
	buf.WriteString(s[last:])
	return buf.String()
}

func groupStr(s string, idx []int, group int) string {
	if idx == nil || group*2+1 >= len(idx) {
		return ""
	}
	a, b := idx[group*2], idx[group*2+1]
	if a < 0 || b < 0 || a > b || b > len(s) {
		return ""
	}
	return s[a:b]
}

// ParseFileName parses a media file name (extension ignored when present).
func ParseFileName(fileName string) ParsedName {
	name := strings.TrimSpace(reExtension.ReplaceAllString(fileName, ""))
	name = fullWidthToASCII(name)

	if std := parseStandard(name); std != nil {
		return *std
	}

	var leadingYear *int
	if m := reLeadingYear.FindStringSubmatchIndex(name); m != nil {
		rest := name[m[1]:]
		firstR, _ := utf8.DecodeRuneInString(rest)
		if isCJK(firstR) && !reLeadingCnEp.MatchString(rest) {
			y, _ := strconv.Atoi(groupStr(name, m, 1))
			leadingYear = &y
			name = rest
		}
	}

	var group string
	fansub := false
	rawBrackets := reBrackets.FindAllStringSubmatch(name, -1)
	bracketed := make([]string, 0, len(rawBrackets))
	for _, bm := range rawBrackets {
		bracketed = append(bracketed, strings.TrimSpace(bm[1]))
	}
	if lm := reLeadingBracket.FindStringSubmatchIndex(name); lm != nil {
		tag := strings.TrimSpace(groupStr(name, lm, 1))
		if _, numErr := strconv.Atoi(tag); tag != "" && !isDetailTag(tag) && numErr != nil {
			isPortal := reNonFansubTag.MatchString(tag)
			if !isPortal {
				group = tag
			}
			name = name[lm[1]:]
			fansub = isAnimeFansub(tag, bracketed, name)
		}
	}

	var bracketEpisode *int
	var bracketTitle string
	outside := strings.TrimSpace(reStarBanner.ReplaceAllString(reBrackets.ReplaceAllString(name, " "), " "))
	if fansub && len(bracketed) > 1 {
		titleInBrackets := strings.TrimSpace(stripDetails(outside)) == ""
		for _, tag := range bracketed[1:] {
			if tag == "" || reChecksum.MatchString(tag) {
				continue
			}
			if nm := reBracketEp.FindStringSubmatch(tag); nm != nil {
				if !hasBoundMatch(nm[1], reYear, boundAlnum) && bracketEpisode == nil {
					v, _ := strconv.Atoi(nm[1])
					bracketEpisode = &v
				}
				continue
			}
			if titleInBrackets && bracketTitle == "" && !isDetailTag(tag) {
				bracketTitle = tag
			}
		}
	}

	details := name
	work := bracketTitle
	if work == "" {
		work = reStarBanner.ReplaceAllString(reBrackets.ReplaceAllString(name, " "), " ")
	}
	work = reParen.ReplaceAllString(work, " $1 ")

	var season, episode, episodeEnd *int
	cut := len(work)
	mark := func(start int) {
		if start >= 0 && start < cut {
			cut = start
		}
	}

	if se := findFirstBoundMatch(work, reSeasonEpisode, boundAlnumLeftDigitRight); se != nil {
		sv, _ := strconv.Atoi(groupStr(work, se, 1))
		ev, _ := strconv.Atoi(groupStr(work, se, 2))
		season = &sv
		episode = &ev
		if endStr := groupStr(work, se, 3); endStr != "" {
			endV, _ := strconv.Atoi(endStr)
			episodeEnd = &endV
		}
		mark(se[0])
	} else if cross := findFirstBoundMatch(work, reCrossFormat, boundDigitLeftAlnumRight); cross != nil {
		if !hasBoundMatch(work[cross[0]:], reDimensions, boundDigit) {
			sv, _ := strconv.Atoi(groupStr(work, cross, 1))
			ev, _ := strconv.Atoi(groupStr(work, cross, 2))
			season = &sv
			episode = &ev
			mark(cross[0])
		}
	}

	if scn := reSeasonChinese.FindStringSubmatchIndex(work); scn != nil {
		if season == nil {
			if n, ok := parseChineseOrArabic(groupStr(work, scn, 1)); ok {
				season = &n
			}
		}
		mark(scn[0])
	}
	if sw := findFirstBoundMatch(work, reSeasonWord, boundLetter); sw != nil {
		if season == nil {
			sv, _ := strconv.Atoi(groupStr(work, sw, 1))
			season = &sv
		}
		mark(sw[0])
	}
	if ecn := reEpisodeChinese.FindStringSubmatchIndex(work); ecn != nil {
		if episode == nil {
			if n, ok := parseChineseOrArabic(groupStr(work, ecn, 1)); ok {
				episode = &n
			}
		}
		mark(ecn[0])
	}
	if episode == nil {
		if ew := findFirstBoundMatch(work, reEpisodeWord, boundLetterLeftAlnumDigitRight); ew != nil {
			ev, _ := strconv.Atoi(groupStr(work, ew, 1))
			episode = &ev
			if endStr := groupStr(work, ew, 2); endStr != "" {
				endV, _ := strconv.Atoi(endStr)
				episodeEnd = &endV
			}
			mark(ew[0])
		}
	}
	if season == nil {
		if so := findFirstBoundMatch(work, reSeasonOnly, boundAlnum); so != nil {
			sv, _ := strconv.Atoi(groupStr(work, so, 1))
			season = &sv
			mark(so[0])
		}
	}

	isSpecial := false
	var specialNumber *int
	for _, sp := range reSpecial.FindAllStringSubmatchIndex(work, -1) {
		isLatin := groupStr(work, sp, 1) != ""
		if isLatin && !checkBounds(work, sp[0], sp[1], boundAlnum) {
			continue
		}
		if episode == nil {
			label := strings.ToLower(groupStr(work, sp, 1))
			if label == "" {
				label = strings.ToLower(groupStr(work, sp, 3))
			}
			if label != "剧场版" && label != "劇場版" {
				isSpecial = true
				if numStr := groupStr(work, sp, 2); numStr != "" {
					if v, err := strconv.Atoi(numStr); err == nil {
						specialNumber = &v
					}
				}
			}
			mark(sp[0])
		}
		break
	}

	for _, pat := range []struct {
		re *regexp.Regexp
		b  boundKind
	}{
		{reResolution, boundAlnum},
		{reFourK, boundAlnum},
		{reDimensions, boundDigit},
		{reSource, boundAlnum},
		{reCodec, boundAlnum},
		{reHDR, boundAlnum},
		{reAudio, boundAlnum},
	} {
		if m := findFirstBoundMatch(work, pat.re, pat.b); m != nil {
			mark(m[0])
		}
	}
	if m := findEditionMatch(work); m != nil {
		mark(m[0])
	}
	if m := findMiscMatch(work); m != nil {
		mark(m[0])
	}

	var year *int
	allYears := findAllBoundMatches(work, reYear, boundAlnum)
	var beforeCutYears [][]int
	for _, ym := range allYears {
		if ym[0] <= cut {
			beforeCutYears = append(beforeCutYears, ym)
		}
	}
	if len(beforeCutYears) > 0 {
		chosen := beforeCutYears[len(beforeCutYears)-1]
		before := cleanTitle(work[:chosen[0]])
		if before != "" {
			yv, _ := strconv.Atoi(groupStr(work, chosen, 1))
			year = &yv
			if chosen[0] < cut {
				cut = chosen[0]
			}
		}
	}

	titlePart := work[:cut]
	loose := bracketEpisode
	if episode == nil && loose == nil && !isSpecial {
		if dm := reLooseDash.FindStringSubmatchIndex(work); dm != nil {
			lv, _ := strconv.Atoi(groupStr(work, dm, 1))
			loose = &lv
			if dm[0] < len(titlePart) {
				titlePart = titlePart[:dm[0]]
			}
		} else {
			rest := strings.TrimRight(separatorsToSpaces(titlePart), " \t")
			if tm := reLooseTrailing.FindStringSubmatchIndex(rest); tm != nil {
				digits := groupStr(rest, tm, 1)
				before := cleanTitle(rest[:tm[0]])
				yearLike := hasBoundMatch(digits, reYear, boundAlnum)
				zeroPadded := len(digits) >= 2 && strings.HasPrefix(digits, "0")
				accept := false
				if before == "" {
					accept = !yearLike
				} else {
					accept = zeroPadded
				}
				if accept {
					lv, _ := strconv.Atoi(digits)
					loose = &lv
					titlePart = rest[:tm[0]]
				}
			}
		}
	}
	if isSpecial && specialNumber != nil {
		episode = specialNumber
	}

	title := cleanTitle(titlePart)
	if group == "" {
		noBrackets := strings.TrimRight(reBrackets.ReplaceAllString(details, ""), " \t")
		if tm := reTrailingGroup.FindStringSubmatch(noBrackets); tm != nil {
			if cut < len(work) && !isDetailTag(tm[1]) {
				group = tm[1]
			}
		}
	}

	if episodeEnd != nil && (episode == nil || *episodeEnd <= *episode) {
		episodeEnd = nil
	}
	finalYear := year
	if finalYear == nil {
		finalYear = leadingYear
	}

	return ParsedName{
		Title:        title,
		Year:         finalYear,
		Season:       season,
		Episode:      episode,
		EpisodeEnd:   episodeEnd,
		LooseEpisode: loose,
		IsSpecial:    isSpecial,
		Resolution:   resolutionOf(details),
		Source:       canonicalSource(groupStr(details, findFirstBoundMatch(details, reSource, boundAlnum), 1)),
		VideoCodec:   canonicalCodec(groupStr(details, findFirstBoundMatch(details, reCodec, boundAlnum), 1)),
		HDR:          canonicalHDR(groupStr(details, findFirstBoundMatch(details, reHDR, boundAlnum), 1)),
		Edition:      canonicalEdition(details, findEditionMatch(details)),
		ReleaseGroup: group,
		FansubStyle:  fansub,
	}
}

func findEditionMatch(s string) []int {
	for _, m := range reEdition.FindAllStringSubmatchIndex(s, -1) {
		if groupStr(s, m, 1) != "" {
			if checkBounds(s, m[0], m[1], boundAlnum) {
				return m
			}
		} else {
			return m
		}
	}
	return nil
}

func findMiscMatch(s string) []int {
	for _, m := range reMisc.FindAllStringSubmatchIndex(s, -1) {
		if groupStr(s, m, 1) != "" {
			if checkBounds(s, m[0], m[1], boundAlnum) {
				return m
			}
		} else {
			return m
		}
	}
	return nil
}

func parseStandard(name string) *ParsedName {
	if ep := reStandardEpisode.FindStringSubmatch(name); ep != nil {
		rest := ep[6]
		sv, _ := strconv.Atoi(ep[2])
		ev, _ := strconv.Atoi(ep[3])
		var endPtr *int
		if ep[4] != "" {
			if endV, err := strconv.Atoi(ep[4]); err == nil && endV > ev {
				endPtr = &endV
			}
		}
		return &ParsedName{
			Title:      strings.TrimSpace(ep[1]),
			Season:     &sv,
			Episode:    &ev,
			EpisodeEnd: endPtr,
			IsSpecial:  sv == 0,
			Resolution: resolutionOf(rest),
			Source:     canonicalSource(groupStr(rest, findFirstBoundMatch(rest, reSource, boundAlnum), 1)),
			VideoCodec: canonicalCodec(groupStr(rest, findFirstBoundMatch(rest, reCodec, boundAlnum), 1)),
			HDR:        canonicalHDR(groupStr(rest, findFirstBoundMatch(rest, reHDR, boundAlnum), 1)),
			Edition:    canonicalEdition(rest, findEditionMatch(rest)),
		}
	}

	if mv := reStandardMovie.FindStringSubmatch(name); mv != nil {
		rest := mv[4]
		if reLeadingDigits.MatchString(rest) ||
			hasBoundMatch(rest, reSeasonEpisode, boundAlnumLeftDigitRight) ||
			reEpisodeChinese.MatchString(rest) ||
			hasBoundMatch(rest, reEpisodeWord, boundLetterLeftAlnumDigitRight) {
			return nil
		}
		yv, _ := strconv.Atoi(mv[2])
		return &ParsedName{
			Title:      strings.TrimSpace(mv[1]),
			Year:       &yv,
			Resolution: resolutionOf(rest),
			Source:     canonicalSource(groupStr(rest, findFirstBoundMatch(rest, reSource, boundAlnum), 1)),
			VideoCodec: canonicalCodec(groupStr(rest, findFirstBoundMatch(rest, reCodec, boundAlnum), 1)),
			HDR:        canonicalHDR(groupStr(rest, findFirstBoundMatch(rest, reHDR, boundAlnum), 1)),
			Edition:    canonicalEdition(rest, findEditionMatch(rest)),
		}
	}
	return nil
}

func ParseFolderName(folderName string) ParsedFolder {
	name := strings.TrimSpace(fullWidthToASCII(folderName))
	if sm := reSeasonFolder.FindStringSubmatch(name); sm != nil {
		raw := sm[1]
		if raw == "" {
			raw = sm[2]
		}
		if n, ok := parseChineseOrArabic(raw); ok {
			return ParsedFolder{Season: &n, IsSeasonFolder: true}
		}
	}
	if reSpecialsFolder.MatchString(name) {
		z := 0
		return ParsedFolder{Season: &z, IsSeasonFolder: true}
	}
	parsed := ParseFileName(name)
	return ParsedFolder{
		Title:  parsed.Title,
		Year:   parsed.Year,
		Season: parsed.Season,
	}
}

func isAnimeFansub(tag string, bracketed []string, restAfterLeading string) bool {
	if reNonFansubTag.MatchString(tag) {
		return false
	}
	return reFansubHint.MatchString(tag) ||
		len(bracketed) >= 2 ||
		strings.Contains(restAfterLeading, "★") ||
		reLooseDash.MatchString(restAfterLeading)
}

func isDetailTag(tag string) bool {
	return strings.TrimSpace(stripDetails(tag)) == "" || reChecksum.MatchString(strings.TrimSpace(tag))
}

var rePunctSpaces = regexp.MustCompile(`[\s._\-+&,/]+`)

func stripDetails(text string) string {
	out := text
	for _, pat := range []struct {
		re *regexp.Regexp
		b  boundKind
	}{
		{reResolution, boundAlnum},
		{reFourK, boundAlnum},
		{reDimensions, boundDigit},
		{reSource, boundAlnum},
		{reCodec, boundAlnum},
		{reHDR, boundAlnum},
		{reAudio, boundAlnum},
	} {
		out = stripBoundMatches(out, pat.re, pat.b)
	}
	out = reEdition.ReplaceAllString(out, " ")
	out = reMisc.ReplaceAllString(out, " ")
	return rePunctSpaces.ReplaceAllString(out, " ")
}

var (
	reSep         = regexp.MustCompile(`[._]+`)
	reBrackParens = regexp.MustCompile(`[\[\]【】()（）]`)
	reMultiSpace  = regexp.MustCompile(`\s+`)
	reDangleEdge  = regexp.MustCompile(`^[\s\-–—:：|~]+|[\s\-–—:：|~]+$`)
)

func separatorsToSpaces(text string) string {
	return reSep.ReplaceAllString(text, " ")
}

func cleanTitle(text string) string {
	out := separatorsToSpaces(text)
	out = reBrackParens.ReplaceAllString(out, " ")
	out = strings.TrimSpace(reMultiSpace.ReplaceAllString(out, " "))
	out = reDangleEdge.ReplaceAllString(out, "")
	return strings.TrimSpace(out)
}

func resolutionOf(text string) string {
	if m := findFirstBoundMatch(text, reResolution, boundAlnum); m != nil {
		return groupStr(text, m, 1) + "p"
	}
	if m := findFirstBoundMatch(text, reDimensions, boundDigit); m != nil {
		return groupStr(text, m, 2) + "p"
	}
	if m := findFirstBoundMatch(text, reFourK, boundAlnum); m != nil {
		alias := strings.ToLower(groupStr(text, m, 1))
		if alias == "4k" || alias == "uhd" {
			return "2160p"
		}
		return "4320p"
	}
	return ""
}

func canonicalSource(raw string) string {
	if raw == "" {
		return ""
	}
	key := strings.NewReplacer(" ", "", "-", "").Replace(strings.ToLower(raw))
	switch key {
	case "bluray", "bd", "bdrip", "brrip", "bdmv", "uhdbd":
		return "BluRay"
	case "remux":
		return "Remux"
	case "webdl", "web":
		return "WEB-DL"
	case "webrip":
		return "WEBRip"
	case "hdtv", "pdtv":
		return "HDTV"
	case "dvd", "dvdrip":
		return "DVD"
	default:
		return strings.ToUpper(raw)
	}
}

func canonicalCodec(raw string) string {
	if raw == "" {
		return ""
	}
	key := strings.NewReplacer(" ", "", ".", "").Replace(strings.ToLower(raw))
	switch key {
	case "x265", "h265", "hevc":
		return "HEVC"
	case "x264", "h264", "avc":
		return "H.264"
	case "av1":
		return "AV1"
	case "vp9":
		return "VP9"
	case "10bit", "8bit", "hi10p":
		return ""
	default:
		return strings.ToUpper(raw)
	}
}

func canonicalHDR(raw string) string {
	if raw == "" {
		return ""
	}
	key := strings.NewReplacer(" ", "", ".", "").Replace(strings.ToLower(raw))
	switch key {
	case "dovi", "dv", "dolbyvision":
		return "Dolby Vision"
	case "hdr10+":
		return "HDR10+"
	case "hlg":
		return "HLG"
	default:
		return "HDR"
	}
}

func canonicalEdition(s string, m []int) string {
	if m == nil {
		return ""
	}
	if cn := groupStr(s, m, 2); cn != "" {
		return cn
	}
	key := strings.ReplaceAll(strings.ToLower(groupStr(s, m, 1)), ".", " ")
	switch {
	case strings.HasPrefix(key, "director"):
		return "Director's Cut"
	case strings.HasPrefix(key, "extended"):
		return "Extended"
	case strings.HasPrefix(key, "theatrical"):
		return "Theatrical"
	case strings.HasPrefix(key, "final"):
		return "Final Cut"
	case strings.HasPrefix(key, "special"):
		return "Special Edition"
	case key == "imax":
		return "IMAX"
	case key == "":
		return ""
	default:
		return strings.ToUpper(key[:1]) + key[1:]
	}
}

func fullWidthToASCII(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for _, r := range text {
		if r >= 0xFF10 && r <= 0xFF5A {
			b.WriteRune(r - 0xFEE0)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

var chineseDigits = map[rune]int{
	'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '兩': 2,
	'三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
}

func parseChineseOrArabic(text string) (int, bool) {
	if n, err := strconv.Atoi(text); err == nil {
		return n, true
	}
	total := 0
	current := 0
	seen := false
	for _, r := range text {
		if d, ok := chineseDigits[r]; ok {
			current = d
			seen = true
		} else if r == '十' {
			if current == 0 {
				current = 1
			}
			total += current * 10
			current = 0
			seen = true
		} else if r == '百' {
			if current == 0 {
				current = 1
			}
			total += current * 100
			current = 0
			seen = true
		} else {
			return 0, false
		}
	}
	if !seen {
		return 0, false
	}
	return total + current, true
}

func FormatIntPtr(p *int) string {
	if p == nil {
		return ""
	}
	return fmt.Sprintf("%d", *p)
}
