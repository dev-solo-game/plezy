package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"plezy/media_server/internal/applog"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
)

const acceptMatchScore = 0.72

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

type ScrapeSummary struct {
	Matched             int    `json:"matched"`
	Unmatched           int    `json:"unmatched"`
	Merged              int    `json:"merged"`
	Skipped             int    `json:"skipped"`
	StoppedBy           string `json:"stopped_by,omitempty"`
	StoppedByMissingKey bool   `json:"stopped_by_missing_key,omitempty"`
}

type ScrapeSnapshot struct {
	Status    string `json:"status"` // idle | running | completed | warning
	Done      int    `json:"done"`
	Total     int    `json:"total"`
	Matched   int    `json:"matched"`
	Unmatched int    `json:"unmatched"`
	Merged    int    `json:"merged"`
	Skipped   int    `json:"skipped"`
	Title     string `json:"title,omitempty"`
	Message   string `json:"message,omitempty"`
	UpdatedAt int64  `json:"updated_at"`
}

type Scraper struct {
	store   *db.Store
	meta    *metadata.Service
	storage *storage.Manager
	hub     *events.Hub

	runMu    sync.Mutex
	running  bool
	statusMu sync.RWMutex
	live     ScrapeSnapshot
}

func NewScraper(store *db.Store, meta *metadata.Service, st *storage.Manager, hub *events.Hub) *Scraper {
	return &Scraper{
		store:   store,
		meta:    meta,
		storage: st,
		hub:     hub,
		live:    ScrapeSnapshot{Status: "idle"},
	}
}

func (sc *Scraper) IsRunning() bool {
	sc.runMu.Lock()
	defer sc.runMu.Unlock()
	return sc.running
}

func (sc *Scraper) CurrentStatus() ScrapeSnapshot {
	sc.statusMu.RLock()
	defer sc.statusMu.RUnlock()
	return sc.live
}

func (sc *Scraper) PendingScrapeCount() int64 {
	var n int64
	_ = sc.store.DB().QueryRow(`
		SELECT COUNT(*) FROM media_items
		WHERE kind IN ('movie', 'show')
		  AND locked = 0
		  AND (
			(metadata_source IS NULL AND scraped_at IS NULL)
			OR (metadata_source IS NOT NULL AND kind = 'show' AND EXISTS (
				SELECT 1 FROM media_items ep
				JOIN media_files mf ON mf.item_id = ep.id
				WHERE ep.show_id = media_items.id AND mf.role = 'video' AND mf.match_state = 'pending'
			))
		  )`).Scan(&n)
	return n
}

func (sc *Scraper) publishSnapshot(snap ScrapeSnapshot) {
	snap.UpdatedAt = time.Now().UnixMilli()
	sc.statusMu.Lock()
	sc.live = snap
	sc.statusMu.Unlock()
	if sc.hub != nil {
		sc.hub.Publish("scrape_progress", snap)
	}
}

func (sc *Scraper) scrapeQueueQuery(refreshAll bool) ([]struct {
	ID      int64
	MaxFile int64
}, error) {
	var rows *sql.Rows
	var err error
	if refreshAll {
		rows, err = sc.store.DB().Query(`
			SELECT id,
				COALESCE((SELECT MAX(mf.id) FROM media_files mf WHERE mf.role = 'video' AND (mf.item_id = media_items.id OR mf.item_id IN (SELECT ep.id FROM media_items ep WHERE ep.show_id = media_items.id))), 0)
			FROM media_items
			WHERE kind IN ('movie', 'show') AND locked = 0
			ORDER BY id ASC`)
	} else {
		rows, err = sc.store.DB().Query(`
			SELECT id,
				COALESCE((SELECT MAX(mf.id) FROM media_files mf WHERE mf.role = 'video' AND (mf.item_id = media_items.id OR mf.item_id IN (SELECT ep.id FROM media_items ep WHERE ep.show_id = media_items.id))), 0)
			FROM media_items
			WHERE kind IN ('movie', 'show')
			  AND locked = 0
			  AND (
				(metadata_source IS NULL AND scraped_at IS NULL)
				OR (metadata_source IS NOT NULL AND kind = 'show' AND EXISTS (
					SELECT 1 FROM media_items ep
					JOIN media_files mf ON mf.item_id = ep.id
					WHERE ep.show_id = media_items.id AND mf.role = 'video' AND mf.match_state = 'pending'
				))
			  )
			ORDER BY id ASC`)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var queue []struct {
		ID      int64
		MaxFile int64
	}
	for rows.Next() {
		var entry struct {
			ID      int64
			MaxFile int64
		}
		if rows.Scan(&entry.ID, &entry.MaxFile) == nil {
			queue = append(queue, entry)
		}
	}
	return queue, nil
}

func (sc *Scraper) ScrapePending(ctx context.Context, retryUnmatched bool, refreshAll bool) (ScrapeSummary, error) {
	sc.runMu.Lock()
	if sc.running {
		sc.runMu.Unlock()
		return ScrapeSummary{}, fmt.Errorf("%w: scrape already running", db.ErrConflict)
	}
	sc.running = true
	sc.runMu.Unlock()
	defer func() {
		sc.runMu.Lock()
		sc.running = false
		sc.runMu.Unlock()
	}()

	startedAt := time.Now()
	applog.Infof("scraper", "启动刮削任务: retry_unmatched=%v refresh_all=%v", retryUnmatched, refreshAll)

	if retryUnmatched {
		resItems, _ := sc.store.DB().Exec(`
			UPDATE media_items SET scraped_at = NULL, metadata_source = NULL
			WHERE kind IN ('movie', 'show') AND (library_type = 'pending' OR metadata_source IS NULL) AND locked = 0`)
		resFiles, _ := sc.store.DB().Exec(`
			UPDATE media_files SET match_state = 'pending'
			WHERE role = 'video' AND match_state = 'unmatched' AND match_locked = 0`)
		var nItems, nFiles int64
		if resItems != nil {
			nItems, _ = resItems.RowsAffected()
		}
		if resFiles != nil {
			nFiles, _ = resFiles.RowsAffected()
		}
		applog.Infof("scraper", "已重置待匹配状态: 条目=%d 视频文件=%d", nItems, nFiles)
		var lockedCnt int64
		_ = sc.store.DB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind IN ('movie','show') AND library_type = 'pending' AND locked = 1`).Scan(&lockedCnt)
		if lockedCnt > 0 {
			applog.Warnf("scraper", "注意: 有 %d 项待匹配条目因处于手动锁定(locked=1)未参与自动重置", lockedCnt)
		}
	}

	forceSearch := retryUnmatched || refreshAll
	var sum ScrapeSummary
	attemptedMaxFile := make(map[int64]int64)
	done := 0
	total := 0
	var lastErr error
	tmdbFailStreak := 0
	stoppedByTmdbOutage := false

	for {
		if ctx.Err() != nil || sum.StoppedByMissingKey || stoppedByTmdbOutage {
			break
		}
		rawQueue, err := sc.scrapeQueueQuery(refreshAll)
		if err != nil {
			applog.Errorf("scraper", "读取刮削队列失败: %v", err)
			return ScrapeSummary{}, err
		}
		var batch []struct {
			ID      int64
			MaxFile int64
		}
		for _, q := range rawQueue {
			if prevMax, seen := attemptedMaxFile[q.ID]; seen && q.MaxFile <= prevMax {
				continue
			}
			batch = append(batch, q)
		}
		if len(batch) == 0 {
			break
		}
		total += len(batch)
		applog.Infof("scraper", "加载刮削队列: 本批=%d 累计=%d", len(batch), total)

		for _, entry := range batch {
			if ctx.Err() != nil {
				break
			}
			attemptedMaxFile[entry.ID] = entry.MaxFile

			item, err := sc.store.GetMediaItem(entry.ID)
			if err != nil {
				done++
				sum.Skipped++
				continue
			}

			sc.publishSnapshot(ScrapeSnapshot{
				Status:    "running",
				Done:      done,
				Total:     total,
				Matched:   sum.Matched,
				Unmatched: sum.Unmatched,
				Merged:    sum.Merged,
				Skipped:   sum.Skipped,
				Title:     item.Title,
			})

			outcome, sErr := sc.scrapeOne(ctx, item, forceSearch, refreshAll)
			done++
			if sErr != nil {
				if errors.Is(sErr, metadata.ErrNotConfigured) {
					sum.StoppedBy = sErr.Error()
					sum.StoppedByMissingKey = true
					applog.Warnf("scraper", "暂停刮削: 未配置 TMDB API Key 且未命中 NFO")
					break
				}
				lastErr = sErr
				applog.Errorf("scraper", "条目 #%d %q 刮削失败: %s", item.ID, item.Title, applog.RedactURL(sErr.Error()))
				sum.Skipped++
				if errors.Is(sErr, metadata.ErrTmdbUpstream) {
					tmdbFailStreak++
					if tmdbFailStreak >= 2 {
						stoppedByTmdbOutage = true
						sum.StoppedBy = sErr.Error()
						applog.Errorf("scraper", "TMDB 连续请求失败 %d 次（网络不通或上游异常），提前中止本轮刮削", tmdbFailStreak)
						break
					}
				} else {
					tmdbFailStreak = 0
				}
				continue
			}
			tmdbFailStreak = 0
			switch outcome {
			case "matched":
				sum.Matched++
				if sc.hub != nil {
					sc.hub.Publish("library_changed", map[string]any{"source": "scraper", "item_id": item.ID})
				}
			case "merged":
				sum.Merged++
				if sc.hub != nil {
					sc.hub.Publish("library_changed", map[string]any{"source": "scraper"})
				}
			case "unmatched":
				sum.Unmatched++
			default:
				sum.Skipped++
			}
		}

		// Single pass when refreshing all or retrying unmatched explicitly; drain loop when scraping pending arrivals.
		if refreshAll || retryUnmatched {
			break
		}
	}

	elapsedMs := time.Since(startedAt).Milliseconds()
	applog.Infof("scraper", "刮削任务结束: 耗时=%dms 总计=%d 入库=%d 合并=%d 未匹配=%d 跳过=%d", elapsedMs, total, sum.Matched, sum.Merged, sum.Unmatched, sum.Skipped)

	if sum.StoppedByMissingKey {
		sc.publishSnapshot(ScrapeSnapshot{
			Status:    "warning",
			Done:      done,
			Total:     total,
			Matched:   sum.Matched,
			Unmatched: sum.Unmatched,
			Merged:    sum.Merged,
			Skipped:   sum.Skipped,
			Message:   "未配置 TMDB API Key 且未命中 NFO，请在系统设置中配置后再刮削",
		})
	} else if stoppedByTmdbOutage && lastErr != nil {
		sc.publishSnapshot(ScrapeSnapshot{
			Status:    "warning",
			Done:      done,
			Total:     total,
			Matched:   sum.Matched,
			Unmatched: sum.Unmatched,
			Merged:    sum.Merged,
			Skipped:   sum.Skipped,
			Message:   fmt.Sprintf("TMDB 网络不通，已中止刮削：%s", applog.RedactURL(lastErr.Error())),
		})
	} else if total > 0 && sum.Skipped > 0 && sum.Matched == 0 && sum.Merged == 0 && sum.Unmatched == 0 && lastErr != nil {
		sc.publishSnapshot(ScrapeSnapshot{
			Status:    "warning",
			Done:      done,
			Total:     total,
			Matched:   sum.Matched,
			Unmatched: sum.Unmatched,
			Merged:    sum.Merged,
			Skipped:   sum.Skipped,
			Message:   fmt.Sprintf("刮削失败：%s", applog.RedactURL(lastErr.Error())),
		})
	} else if total > 0 {
		sc.publishSnapshot(ScrapeSnapshot{
			Status:    "completed",
			Done:      done,
			Total:     total,
			Matched:   sum.Matched,
			Unmatched: sum.Unmatched,
			Merged:    sum.Merged,
			Skipped:   sum.Skipped,
			Message:   fmt.Sprintf("已完成 %d 项刮削：入库 %d 项，未匹配 %d 项", total, sum.Matched+sum.Merged, sum.Unmatched),
		})
	} else if retryUnmatched || refreshAll {
		sc.publishSnapshot(ScrapeSnapshot{
			Status:  "completed",
			Done:    0,
			Total:   0,
			Message: "当前没有可重试或待刮削的未锁定条目",
		})
	} else {
		sc.statusMu.Lock()
		sc.live = ScrapeSnapshot{Status: "idle", UpdatedAt: time.Now().UnixMilli()}
		sc.statusMu.Unlock()
	}

	return sum, nil
}

func extIDOfItem(item db.MediaItem, prov string) string {
	switch prov {
	case "tmdb":
		if item.TmdbID != nil {
			return *item.TmdbID
		}
	case "bangumi":
		if item.BangumiID != nil {
			return *item.BangumiID
		}
	case "douban":
		if item.DoubanID != nil {
			return *item.DoubanID
		}
	case "anilist":
		if item.AniListID != nil {
			return *item.AniListID
		}
	case "imdb":
		if item.ImdbID != nil {
			return *item.ImdbID
		}
	case "tvdb":
		if item.TvdbID != nil {
			return *item.TvdbID
		}
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
	if strings.TrimSpace(aux.Title) != "" {
		tmdbWork.Aliases = append(tmdbWork.Aliases, aux.Title)
	}
	if aux.OriginalTitle != nil && strings.TrimSpace(*aux.OriginalTitle) != "" {
		tmdbWork.Aliases = append(tmdbWork.Aliases, *aux.OriginalTitle)
	}
	tmdbWork.Aliases = append(tmdbWork.Aliases, aux.Aliases...)
}

func (sc *Scraper) scrapeOne(ctx context.Context, item db.MediaItem, forceSearch, forceWorkRefresh bool) (string, error) {
	if item.Locked {
		return "skipped", nil
	}
	cfg := sc.store.GetServerSettings()

	// If already matched and only refreshing or filling newly scanned episodes
	if item.MetadataSource != nil && *item.MetadataSource != "" {
		prov := *item.MetadataSource
		if prov == "nfo" {
			if item.Kind == db.KindShow {
				_ = sc.fillEpisodesFromNfo(ctx, item.ID)
			}
			_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, true)
			return "matched", nil
		}
		extID := extIDOfItem(item, prov)
		if extID == "" {
			return "skipped", nil
		}
		applog.Debugf("scraper", "增量补齐/刷新作品 #%d [%s:%s] %q", item.ID, prov, extID, item.Title)
		if forceWorkRefresh {
			work, err := sc.meta.GetWork(ctx, prov, item.Kind, extID, cfg.ScraperLang, true)
			if err != nil {
				return "skipped", err
			}
			if err := sc.applyWork(ctx, item.ID, work, false, ""); err != nil {
				return "skipped", err
			}
		}
		if item.Kind == db.KindShow {
			_ = sc.fillSeasons(ctx, item.ID, prov, extID, item.Title, cfg.ScraperLang, forceWorkRefresh)
		}
		_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, false)
		return "matched", nil
	}

	samplePath := ""
	if sv := sc.sampleVideoOf(item); sv != nil {
		samplePath = sv.Path
	}
	applog.Infof("scraper", "开始匹配 #%d [%s] title=%q year=%s file=%q force_search=%v", item.ID, item.Kind, item.Title, FormatIntPtr(item.Year), samplePath, forceSearch)

	// 1. Try NFO
	if cfg.PreferNfo {
		if outcome, ok := sc.tryScrapeFromNfo(ctx, item); ok {
			applog.Infof("scraper", "本地 NFO 匹配成功 #%d %q -> %s", item.ID, item.Title, outcome)
			return outcome, nil
		}
	}

	hasTmdb := cfg.TmdbAPIKey != ""
	auxProviders := sc.auxiliaryProvidersFor(item, cfg)
	if !hasTmdb && (len(auxProviders) == 0 || !cfg.AllowFallbackMetadata) {
		return "skipped", metadata.ErrNotConfigured
	}

	emb := ExtractEmbeddedExternalIDs(samplePath)
	rawTitles := sc.collectItemTitles(item, cfg.CustomRecognitionWords)
	if len(rawTitles) > 0 && rawTitles[0] != item.Title {
		applog.Infof("scraper", "  自定义识别词预处理 #%d: %q -> %q", item.ID, item.Title, rawTitles[0])
	}

	var bestStandalone *metadata.Work
	bestStandaloneImpliedSeason := 0

	if hasTmdb {
		// Embedded explicit ID shortcut -> TMDB
		if emb.TmdbID != "" {
			applog.Infof("scraper", "  命中路径内嵌 TMDB ID #%d -> tmdb:%s", item.ID, emb.TmdbID)
			return sc.applyCandidateWithSupplement(ctx, item, "tmdb", metadata.Candidate{Source: "tmdb", ID: emb.TmdbID}, cfg.ScraperLang, false, "", forceWorkRefresh, nil)
		}
		if emb.ImdbID != "" {
			if out, ok, err := sc.tryBridgeExternalIDToTMDB(ctx, &item, "imdb_id", emb.ImdbID, cfg.ScraperLang, forceSearch, forceWorkRefresh, nil); err != nil {
				return "skipped", err
			} else if ok {
				return out, nil
			}
		}
		if emb.TvdbID != "" {
			if out, ok, err := sc.tryBridgeExternalIDToTMDB(ctx, &item, "tvdb_id", emb.TvdbID, cfg.ScraperLang, forceSearch, forceWorkRefresh, nil); err != nil {
				return "skipped", err
			} else if ok {
				return out, nil
			}
		}

		// Tier 1: Direct TMDB Search (abort immediately on any TMDB network/upstream failure)
		matchRes, matchedKind, err := sc.matchOnProvider(ctx, "tmdb", item, rawTitles, nil, cfg.ScraperLang, forceSearch)
		if err != nil {
			applog.Errorf("scraper", "  TMDB 网络不通或请求失败 #%d %q -> 判定刮削失败: %s", item.ID, item.Title, applog.RedactURL(err.Error()))
			return "skipped", err
		}
		if matchRes != nil {
			if matchedKind != "" && matchedKind != item.Kind && sc.canChangeKind(item) {
				if changed, cErr := sc.changeKind(item); cErr == nil {
					item = changed
				}
			}
			if item.Kind == db.KindShow && matchRes.ImpliedSeason >= 2 {
				_ = sc.remapDefaultSeasonOne(item.ID, matchRes.ImpliedSeason)
			}
			return sc.applyCandidateWithSupplement(ctx, item, "tmdb", matchRes.Candidate, cfg.ScraperLang, false, "", forceWorkRefresh, nil)
		}

		// Tier 2: Auxiliary providers (Douban / IMDb / Bangumi / AniList / TheTvDb) -> Bridge back to TMDB
		if len(auxProviders) > 0 {
			applog.Debugf("scraper", "  TMDB 直搜未命中 #%d %q，进入辅助源跨源反查: %v", item.ID, item.Title, auxProviders)
		}
		for _, auxProv := range auxProviders {
			auxMatch, auxKind, aErr := sc.matchOnProvider(ctx, auxProv, item, rawTitles, nil, cfg.ScraperLang, forceSearch)
			if aErr != nil {
				applog.Warnf("scraper", "  辅助源查询出错 #%d [%s]: %s", item.ID, auxProv, applog.RedactURL(aErr.Error()))
				continue
			}
			if auxMatch == nil {
				continue
			}
			auxWorkKind := auxKind
			if auxWorkKind == "" {
				auxWorkKind = item.Kind
			}
			auxWork, wErr := sc.meta.GetWork(ctx, auxProv, auxWorkKind, auxMatch.Candidate.ID, cfg.ScraperLang, forceSearch)
			if wErr != nil {
				applog.Warnf("scraper", "  辅助源拉取详情失败 #%d [%s:%s]: %s", item.ID, auxProv, auxMatch.Candidate.ID, applog.RedactURL(wErr.Error()))
				continue
			}
			if bestStandalone == nil {
				wCopy := auxWork
				bestStandalone = &wCopy
				bestStandaloneImpliedSeason = auxMatch.ImpliedSeason
			}

			// Bridge 2A: direct TMDB ID from auxiliary provider (e.g. TheTvDb remoteIds)
			if auxWork.TmdbID != nil && *auxWork.TmdbID != "" {
				targetItem := item
				if auxWorkKind != targetItem.Kind && sc.canChangeKind(targetItem) {
					if changed, cErr := sc.changeKind(targetItem); cErr == nil {
						targetItem = changed
					}
				}
				applog.Infof("scraper", "  跨源直连 TMDB #%d [%s:%s -> tmdb:%s]", targetItem.ID, auxProv, auxWork.ExternalID, *auxWork.TmdbID)
				return sc.applyCandidateWithSupplement(ctx, targetItem, "tmdb", metadata.Candidate{Source: "tmdb", ID: *auxWork.TmdbID}, cfg.ScraperLang, false, "", forceWorkRefresh, &auxWork)
			}

			// Bridge 2B: IMDb / TvDb external ID -> TMDB /find
			if auxWork.ImdbID != nil && *auxWork.ImdbID != "" {
				targetItem := item
				if out, ok, bErr := sc.tryBridgeExternalIDToTMDB(ctx, &targetItem, "imdb_id", *auxWork.ImdbID, cfg.ScraperLang, forceSearch, forceWorkRefresh, &auxWork); bErr != nil {
					return "skipped", bErr
				} else if ok {
					return out, nil
				}
			}
			if auxWork.TvdbID != nil && *auxWork.TvdbID != "" {
				targetItem := item
				if out, ok, bErr := sc.tryBridgeExternalIDToTMDB(ctx, &targetItem, "tvdb_id", *auxWork.TvdbID, cfg.ScraperLang, forceSearch, forceWorkRefresh, &auxWork); bErr != nil {
					return "skipped", bErr
				} else if ok {
					return out, nil
				}
			}

			// Bridge 2C: Canonical title / original title / aliases -> re-search TMDB
			bridgeTitles := collectAuxBridgeTitles(auxWork, rawTitles)
			if len(bridgeTitles) > 0 {
				yearHint := item.Year
				if yearHint == nil {
					yearHint = auxWork.Year
				}
				bridgeMatch, bridgeKind, bErr := sc.matchOnProvider(ctx, "tmdb", item, bridgeTitles, yearHint, cfg.ScraperLang, forceSearch)
				if bErr != nil {
					applog.Errorf("scraper", "  TMDB 跨源片名反查失败 #%d %q -> 判定刮削失败: %s", item.ID, item.Title, applog.RedactURL(bErr.Error()))
					return "skipped", bErr
				}
				if bridgeMatch != nil {
					targetItem := item
					if bridgeKind != "" && bridgeKind != targetItem.Kind && sc.canChangeKind(targetItem) {
						if changed, cErr := sc.changeKind(targetItem); cErr == nil {
							targetItem = changed
						}
					}
					applog.Infof("scraper", "  跨源片名反查命中 TMDB #%d [%s:%s %q -> tmdb:%s %q]", targetItem.ID, auxProv, auxWork.ExternalID, auxWork.Title, bridgeMatch.Candidate.ID, bridgeMatch.Candidate.Title)
					if targetItem.Kind == db.KindShow && bridgeMatch.ImpliedSeason >= 2 {
						_ = sc.remapDefaultSeasonOne(targetItem.ID, bridgeMatch.ImpliedSeason)
					}
					return sc.applyCandidateWithSupplement(ctx, targetItem, "tmdb", bridgeMatch.Candidate, cfg.ScraperLang, false, "", forceWorkRefresh, &auxWork)
				}
			}
		}

		// Also try explicit embedded Douban / Bangumi / AniList ID if no text search matched
		if bestStandalone == nil && (emb.DoubanID != "" || emb.BangumiID != "" || emb.AniListID != "") {
			if embWork := sc.fetchEmbeddedAuxWork(ctx, item.Kind, emb, cfg.ScraperLang, forceSearch); embWork != nil {
				if embWork.ImdbID != nil && *embWork.ImdbID != "" {
					targetItem := item
					if out, ok, bErr := sc.tryBridgeExternalIDToTMDB(ctx, &targetItem, "imdb_id", *embWork.ImdbID, cfg.ScraperLang, forceSearch, forceWorkRefresh, embWork); bErr != nil {
						return "skipped", bErr
					} else if ok {
						return out, nil
					}
				}
				bestStandalone = embWork
			}
		}

		// Tier 3: Standalone Auxiliary Fallback when TMDB legitimately has no entry
		if bestStandalone != nil && cfg.AllowFallbackMetadata {
			if bestStandalone.Kind != item.Kind && sc.canChangeKind(item) {
				if changed, cErr := sc.changeKind(item); cErr == nil {
					item = changed
				}
			}
			if item.Kind == db.KindShow && bestStandaloneImpliedSeason >= 2 {
				_ = sc.remapDefaultSeasonOne(item.ID, bestStandaloneImpliedSeason)
			}
			applog.Infof("scraper", "  TMDB 未收录，使用辅助源独立入库 #%d -> [%s:%s] %q", item.ID, bestStandalone.Source, bestStandalone.ExternalID, bestStandalone.Title)
			return sc.applyStandaloneWork(ctx, item, *bestStandalone, cfg.ScraperLang, false, "", forceWorkRefresh)
		}
		if bestStandalone != nil && !cfg.AllowFallbackMetadata {
			applog.Infof("scraper", "  辅助源已找到 [%s:%s] %q 但 TMDB 未收录且已关闭独立兜底入库 #%d", bestStandalone.Source, bestStandalone.ExternalID, bestStandalone.Title, item.ID)
		}
	} else {
		// No TMDB Key configured; user explicitly relies on standalone auxiliary sources
		for _, auxProv := range auxProviders {
			auxMatch, auxKind, aErr := sc.matchOnProvider(ctx, auxProv, item, rawTitles, nil, cfg.ScraperLang, forceSearch)
			if aErr != nil {
				applog.Warnf("scraper", "  辅助源查询出错 #%d [%s]: %s", item.ID, auxProv, applog.RedactURL(aErr.Error()))
				continue
			}
			if auxMatch == nil {
				continue
			}
			if auxKind != "" && auxKind != item.Kind && sc.canChangeKind(item) {
				if changed, cErr := sc.changeKind(item); cErr == nil {
					item = changed
				}
			}
			if item.Kind == db.KindShow && auxMatch.ImpliedSeason >= 2 {
				_ = sc.remapDefaultSeasonOne(item.ID, auxMatch.ImpliedSeason)
			}
			return sc.applyCandidateWithSupplement(ctx, item, auxProv, auxMatch.Candidate, cfg.ScraperLang, false, "", forceWorkRefresh, nil)
		}
	}

	_, _ = sc.store.DB().Exec(`UPDATE media_items SET scraped_at = ? WHERE id = ?`, sc.store.NowMs(), item.ID)
	_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchUnmatched, false)
	applog.Warnf("scraper", "未能自动匹配 #%d [%s] title=%q year=%s file=%q -> 保持在待匹配中心", item.ID, item.Kind, item.Title, FormatIntPtr(item.Year), samplePath)
	return "unmatched", nil
}

func (sc *Scraper) tryBridgeExternalIDToTMDB(
	ctx context.Context,
	item *db.MediaItem,
	externalSource, externalID, lang string,
	forceSearch, forceWorkRefresh bool,
	supplement *metadata.Work,
) (string, bool, error) {
	cand, foundKind, err := sc.meta.FindByExternalID(ctx, externalSource, externalID, item.Kind, lang, forceSearch)
	if err != nil {
		return "", false, err
	}
	if cand == nil {
		return "", false, nil
	}
	if foundKind != "" && foundKind != item.Kind && sc.canChangeKind(*item) {
		if changed, cErr := sc.changeKind(*item); cErr == nil {
			*item = changed
		}
	}
	applog.Infof("scraper", "  外键反查桥接成功 #%d [%s=%s -> tmdb:%s %q]", item.ID, externalSource, externalID, cand.ID, cand.Title)
	out, aErr := sc.applyCandidateWithSupplement(ctx, *item, "tmdb", *cand, lang, false, "", forceWorkRefresh, supplement)
	return out, true, aErr
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

func (sc *Scraper) ApplyManualMatch(ctx context.Context, itemID int64, provider, externalID string, asShow bool, libraryType string) (db.MediaItem, error) {
	item, err := sc.store.GetMediaItem(itemID)
	if err != nil {
		return db.MediaItem{}, err
	}
	if (item.Kind == db.KindShow) != asShow && sc.canChangeKind(item) {
		changed, err := sc.changeKind(item)
		if err != nil {
			return db.MediaItem{}, err
		}
		item = changed
	}
	cfg := sc.store.GetServerSettings()
	cand := metadata.Candidate{Source: provider, ID: externalID}
	_, err = sc.applyCandidate(ctx, item, provider, cand, cfg.ScraperLang, true, libraryType, false)
	if err != nil {
		return db.MediaItem{}, err
	}
	if sc.hub != nil {
		sc.hub.Publish("library_changed", map[string]any{"item_id": itemID})
	}
	return sc.store.GetMediaItem(itemID)
}

func (sc *Scraper) UnmatchItem(itemID int64) error {
	item, err := sc.store.GetMediaItem(itemID)
	if err != nil {
		return err
	}
	now := sc.store.NowMs()
	_, err = sc.store.DB().Exec(`
		UPDATE media_items
		SET library_type = 'pending', work_key = NULL, tmdb_id = NULL, imdb_id = NULL, tvdb_id = NULL, bangumi_id = NULL,
			douban_id = NULL, anilist_id = NULL,
			metadata_source = NULL, poster_source = NULL, backdrop_source = NULL, logo_source = NULL,
			locked = 0, scraped_at = NULL, updated_at = ?
		WHERE id = ?`, now, itemID)
	if err != nil {
		return err
	}
	if item.Kind == db.KindShow {
		_, _ = sc.store.DB().Exec(`
			UPDATE media_items SET library_type = 'pending', metadata_source = NULL, scraped_at = NULL, updated_at = ?
			WHERE show_id = ? OR parent_id = ?`, now, itemID, itemID)
	}
	_, _ = sc.store.DB().Exec(`DELETE FROM item_genres WHERE item_id = ?`, itemID)
	_, _ = sc.store.DB().Exec(`DELETE FROM item_credits WHERE item_id = ?`, itemID)
	_ = sc.setFilesMatchState(itemID, item.Kind, db.MatchUnmatched, false)
	applog.Infof("scraper", "已解除匹配状态 #%d %q", itemID, item.Title)
	if sc.hub != nil {
		sc.hub.Publish("library_changed", map[string]any{"item_id": itemID})
	}
	return nil
}

func (sc *Scraper) applyCandidate(
	ctx context.Context,
	item db.MediaItem,
	provider string,
	cand metadata.Candidate,
	lang string,
	locked bool,
	overrideShelf string,
	forceWorkRefresh bool,
) (string, error) {
	return sc.applyCandidateWithSupplement(ctx, item, provider, cand, lang, locked, overrideShelf, forceWorkRefresh, nil)
}

func (sc *Scraper) applyCandidateWithSupplement(
	ctx context.Context,
	item db.MediaItem,
	provider string,
	cand metadata.Candidate,
	lang string,
	locked bool,
	overrideShelf string,
	forceWorkRefresh bool,
	supplement *metadata.Work,
) (string, error) {
	targetID := sc.findExistingByExternalID(item.ID, item.Kind, provider, cand.ID)
	if targetID > 0 {
		if err := sc.mergeItems(item, targetID); err != nil {
			return "skipped", err
		}
		if supplement != nil {
			sc.appendTitleAlias(targetID, supplement.Title)
			for _, a := range supplement.Aliases {
				sc.appendTitleAlias(targetID, a)
			}
		}
		if locked {
			work, err := sc.meta.GetWork(ctx, provider, item.Kind, cand.ID, lang, forceWorkRefresh)
			if err != nil {
				return "skipped", err
			}
			supplementTmdbWork(&work, supplement)
			_ = sc.applyWork(ctx, targetID, work, true, overrideShelf)
			if item.Kind == db.KindShow {
				_ = sc.fillSeasons(ctx, targetID, provider, cand.ID, work.Title, lang, forceWorkRefresh)
			}
		} else if item.Kind == db.KindShow {
			if targetItem, gErr := sc.store.GetMediaItem(targetID); gErr == nil {
				_ = sc.fillSeasons(ctx, targetID, provider, cand.ID, targetItem.Title, lang, forceWorkRefresh)
			}
		}
		_ = sc.setFilesMatchState(targetID, item.Kind, db.MatchMatched, locked)
		applog.Infof("scraper", "合并重复条目 #%d -> #%d [%s:%s]", item.ID, targetID, provider, cand.ID)
		return "merged", nil
	}

	work, err := sc.meta.GetWork(ctx, provider, item.Kind, cand.ID, lang, forceWorkRefresh)
	if err != nil {
		return "skipped", err
	}
	supplementTmdbWork(&work, supplement)
	if err := sc.applyWork(ctx, item.ID, work, locked, overrideShelf); err != nil {
		return "skipped", err
	}
	if item.Kind == db.KindShow {
		_ = sc.fillSeasons(ctx, item.ID, provider, cand.ID, work.Title, lang, forceWorkRefresh)
	}
	_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, locked)
	applog.Infof("scraper", "入库完成 #%d -> [%s:%s] %q locked=%v", item.ID, provider, cand.ID, work.Title, locked)
	return "matched", nil
}

func (sc *Scraper) applyStandaloneWork(
	ctx context.Context,
	item db.MediaItem,
	work metadata.Work,
	lang string,
	locked bool,
	overrideShelf string,
	forceWorkRefresh bool,
) (string, error) {
	targetID := sc.findExistingByExternalID(item.ID, item.Kind, work.Source, work.ExternalID)
	if targetID > 0 {
		if err := sc.mergeItems(item, targetID); err != nil {
			return "skipped", err
		}
		if locked {
			_ = sc.applyWork(ctx, targetID, work, true, overrideShelf)
		}
		if item.Kind == db.KindShow {
			_ = sc.fillSeasons(ctx, targetID, work.Source, work.ExternalID, work.Title, lang, forceWorkRefresh)
		}
		_ = sc.setFilesMatchState(targetID, item.Kind, db.MatchMatched, locked)
		applog.Infof("scraper", "合并重复条目 #%d -> #%d [%s:%s]", item.ID, targetID, work.Source, work.ExternalID)
		return "merged", nil
	}
	if err := sc.applyWork(ctx, item.ID, work, locked, overrideShelf); err != nil {
		return "skipped", err
	}
	if item.Kind == db.KindShow {
		_ = sc.fillSeasons(ctx, item.ID, work.Source, work.ExternalID, work.Title, lang, forceWorkRefresh)
	}
	_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, locked)
	applog.Infof("scraper", "独立辅助源入库完成 #%d -> [%s:%s] %q", item.ID, work.Source, work.ExternalID, work.Title)
	return "matched", nil
}

func (sc *Scraper) applyWork(ctx context.Context, itemID int64, work metadata.Work, locked bool, overrideShelf string) error {
	item, err := sc.store.GetMediaItem(itemID)
	if err != nil {
		return err
	}
	shelf := overrideShelf
	if shelf == "" {
		shelf = sc.determineShelf(item, work)
	}
	title := strings.TrimSpace(work.Title)
	if title == "" {
		title = item.Title
	}
	workKey := buildWorkKey(item.Kind, work)

	// Merge aliases
	aliasSet := make(map[string]bool)
	var aliases []string
	addAlias := func(a string) {
		t := strings.TrimSpace(a)
		if t == "" || strings.EqualFold(t, title) {
			return
		}
		low := strings.ToLower(t)
		if !aliasSet[low] {
			aliasSet[low] = true
			aliases = append(aliases, t)
		}
	}
	addAlias(item.Title)
	if item.Aliases != nil {
		for _, line := range strings.Split(*item.Aliases, "\n") {
			addAlias(line)
		}
	}
	for _, a := range work.Aliases {
		addAlias(a)
	}
	var aliasPtr *string
	if len(aliases) > 0 {
		joined := strings.Join(aliases, "\n")
		aliasPtr = &joined
	}

	poster := work.PosterPath
	backdrop := work.BackdropPath
	if localPoster, localBackdrop := sc.findLocalArtwork(item); localPoster != "" || localBackdrop != "" {
		if localPoster != "" {
			poster = &localPoster
		}
		if localBackdrop != "" {
			backdrop = &localBackdrop
		}
	}

	year := work.Year
	if year == nil {
		year = item.Year
	}

	now := sc.store.NowMs()
	lockInt := 0
	if locked || item.Locked {
		lockInt = 1
	}

	// Avoid UNIQUE work_key collision if another placeholder slipped through
	var workKeyPtr *string
	if workKey != "" {
		var clash int64
		if sc.store.DB().QueryRow(`SELECT id FROM media_items WHERE work_key = ? AND id != ?`, workKey, itemID).Scan(&clash) != nil {
			workKeyPtr = &workKey
		}
	}

	_, err = sc.store.DB().Exec(`
		UPDATE media_items SET
			work_key = COALESCE(?, work_key),
			library_type = ?,
			title = ?,
			sort_title = ?,
			original_title = ?,
			aliases = ?,
			year = ?,
			release_date = ?,
			summary = ?,
			tagline = ?,
			content_rating = ?,
			studio = ?,
			rating = ?,
			runtime_ms = COALESCE(?, runtime_ms),
			poster_source = COALESCE(?, poster_source),
			backdrop_source = COALESCE(?, backdrop_source),
			logo_source = COALESCE(?, logo_source),
			tmdb_id = COALESCE(?, tmdb_id),
			imdb_id = COALESCE(?, imdb_id),
			tvdb_id = COALESCE(?, tvdb_id),
			bangumi_id = COALESCE(?, bangumi_id),
			douban_id = COALESCE(?, douban_id),
			anilist_id = COALESCE(?, anilist_id),
			metadata_source = ?,
			locked = ?,
			scraped_at = ?,
			updated_at = ?
		WHERE id = ?`,
		workKeyPtr, shelf, title, db.SortTitleFor(title), work.OriginalTitle, aliasPtr,
		year, work.ReleaseDate, work.Summary, work.Tagline, work.ContentRating, work.Studio,
		work.Rating, work.RuntimeMs, poster, backdrop, work.LogoPath,
		work.TmdbID, work.ImdbID, work.TvdbID, work.BangumiID, work.DoubanID, work.AniListID, work.Source,
		lockInt, now, now, itemID,
	)
	if err != nil {
		return err
	}

	if item.Kind == db.KindShow {
		_, _ = sc.store.DB().Exec(`UPDATE media_items SET library_type = ?, updated_at = ? WHERE show_id = ? OR parent_id = ?`, shelf, now, itemID, itemID)
	}

	sc.saveGenres(itemID, work.Genres)
	sc.saveCredits(itemID, work.Credits)

	if item.Kind == db.KindMovie && workKeyPtr != nil {
		sc.store.RestoreWatchStateForItem(itemID, "movie:"+*workKeyPtr)
	} else if item.Kind == db.KindShow && workKeyPtr != nil {
		sc.store.RestoreWatchStateForItem(itemID, "show:"+*workKeyPtr)
	}

	if item.Kind == db.KindMovie && work.CollectionID != nil && work.CollectionTitle != nil {
		sc.store.UpsertTmdbCollection(*work.CollectionID, *work.CollectionTitle, poster, itemID)
	}
	_ = ctx
	return nil
}

func (sc *Scraper) fillSeasons(ctx context.Context, showID int64, provider, extShowID, showTitle, lang string, forceRefresh bool) error {
	rows, err := sc.store.DB().Query(`
		SELECT id, season_number FROM media_items
		WHERE kind = 'season' AND parent_id = ?`, showID)
	if err != nil {
		return err
	}
	type seasonRow struct {
		id  int64
		num int
	}
	var seasons []seasonRow
	for rows.Next() {
		var sr seasonRow
		var sn sql.NullInt64
		if rows.Scan(&sr.id, &sn) == nil && sn.Valid {
			sr.num = int(sn.Int64)
			seasons = append(seasons, sr)
		}
	}
	rows.Close()

	showItem, _ := sc.store.GetMediaItem(showID)
	now := sc.store.NowMs()

	for _, sr := range seasons {
		seasonData, err := sc.meta.GetSeason(ctx, provider, extShowID, sr.num, lang, forceRefresh)
		if err != nil && provider == "bangumi" && sr.num > 1 {
			cands, sErr := sc.meta.Search(ctx, "bangumi", "show", fmt.Sprintf("%s 第%d季", showTitle, sr.num), 0, lang, false)
			if sErr == nil && len(cands) > 0 {
				seasonData, err = sc.meta.GetSeason(ctx, "bangumi", cands[0].ID, 1, lang, forceRefresh)
			}
		}
		if err != nil {
			continue
		}
		if seasonData.Title != nil && *seasonData.Title != "" {
			_, _ = sc.store.DB().Exec(`
				UPDATE media_items SET title = ?, sort_title = ?, summary = COALESCE(?, summary),
					poster_source = COALESCE(?, poster_source), metadata_source = ?, scraped_at = ?, updated_at = ?
				WHERE id = ?`,
				*seasonData.Title, db.SortTitleFor(*seasonData.Title), seasonData.Summary,
				seasonData.PosterPath, provider, now, now, sr.id,
			)
		}

		epByNum := make(map[int]metadata.Episode, len(seasonData.Episodes))
		for _, ep := range seasonData.Episodes {
			epByNum[ep.Number] = ep
		}
		epRows, err := sc.store.DB().Query(`
			SELECT id, episode_number FROM media_items
			WHERE kind = 'episode' AND parent_id = ?`, sr.id)
		if err != nil {
			continue
		}
		type epRef struct {
			id  int64
			num int
		}
		var epRefs []epRef
		for epRows.Next() {
			var r epRef
			var en sql.NullInt64
			if epRows.Scan(&r.id, &en) == nil && en.Valid {
				r.num = int(en.Int64)
				epRefs = append(epRefs, r)
			}
		}
		epRows.Close()

		for _, r := range epRefs {
			if epMeta, ok := epByNum[r.num]; ok {
				epTitle := fmt.Sprintf("第 %d 集", r.num)
				if epMeta.Title != nil && strings.TrimSpace(*epMeta.Title) != "" {
					epTitle = strings.TrimSpace(*epMeta.Title)
				}
				_, _ = sc.store.DB().Exec(`
					UPDATE media_items SET
						title = ?, sort_title = ?, summary = COALESCE(?, summary),
						release_date = COALESCE(?, release_date),
						runtime_ms = COALESCE(?, runtime_ms),
						rating = COALESCE(?, rating),
						poster_source = COALESCE(?, poster_source),
						metadata_source = ?, scraped_at = ?, updated_at = ?
					WHERE id = ?`,
					epTitle, db.SortTitleFor(epTitle), epMeta.Summary, epMeta.AirDate,
					epMeta.RuntimeMs, epMeta.Rating, epMeta.StillPath, provider, now, now, r.id,
				)
				if showItem.WorkKey != nil && *showItem.WorkKey != "" {
					sc.store.RestoreWatchStateForItem(r.id, fmt.Sprintf("episode:%s:s%d:e%d", *showItem.WorkKey, sr.num, r.num))
				}
			}
		}
	}
	return nil
}

func (sc *Scraper) saveGenres(itemID int64, genres []string) {
	if len(genres) == 0 {
		return
	}
	_, _ = sc.store.DB().Exec(`DELETE FROM item_genres WHERE item_id = ?`, itemID)
	for _, g := range genres {
		name := strings.TrimSpace(g)
		if name == "" {
			continue
		}
		_, _ = sc.store.DB().Exec(`INSERT OR IGNORE INTO genres(name) VALUES (?)`, name)
		var gid int64
		if sc.store.DB().QueryRow(`SELECT id FROM genres WHERE name = ?`, name).Scan(&gid) == nil {
			_, _ = sc.store.DB().Exec(`INSERT OR IGNORE INTO item_genres(item_id, genre_id) VALUES (?, ?)`, itemID, gid)
		}
	}
}

func (sc *Scraper) saveCredits(itemID int64, credits []metadata.Credit) {
	if len(credits) == 0 {
		return
	}
	_, _ = sc.store.DB().Exec(`DELETE FROM item_credits WHERE item_id = ?`, itemID)
	for idx, c := range credits {
		name := strings.TrimSpace(c.Name)
		if name == "" {
			continue
		}
		var pid int64
		var err error
		if c.TmdbID != nil && *c.TmdbID != "" {
			err = sc.store.DB().QueryRow(`SELECT id FROM people WHERE provider = 'tmdb' AND external_id = ? LIMIT 1`, *c.TmdbID).Scan(&pid)
			if err != nil {
				res, insErr := sc.store.DB().Exec(`
					INSERT INTO people(name, provider, external_id, photo_source) VALUES (?, 'tmdb', ?, ?)`,
					name, *c.TmdbID, c.PhotoPath,
				)
				if insErr != nil {
					continue
				}
				pid, _ = res.LastInsertId()
			} else if c.PhotoPath != nil && *c.PhotoPath != "" {
				_, _ = sc.store.DB().Exec(`UPDATE people SET photo_source = COALESCE(NULLIF(photo_source,''), ?) WHERE id = ?`, *c.PhotoPath, pid)
			}
		} else {
			err = sc.store.DB().QueryRow(`SELECT id FROM people WHERE name = ? AND external_id IS NULL LIMIT 1`, name).Scan(&pid)
			if err != nil {
				res, insErr := sc.store.DB().Exec(`INSERT INTO people(name, provider, photo_source) VALUES (?, 'nfo', ?)`, name, c.PhotoPath)
				if insErr != nil {
					continue
				}
				pid, _ = res.LastInsertId()
			}
		}
		_, _ = sc.store.DB().Exec(`
			INSERT OR IGNORE INTO item_credits(item_id, person_id, job, character, sort_order)
			VALUES (?, ?, ?, ?, ?)`, itemID, pid, c.Job, c.Character, idx)
	}
}

func buildWorkKey(kind string, work metadata.Work) string {
	if work.TmdbID != nil && *work.TmdbID != "" {
		return fmt.Sprintf("tmdb:%s:%s", kind, *work.TmdbID)
	}
	if work.BangumiID != nil && *work.BangumiID != "" {
		return fmt.Sprintf("bangumi:%s:%s", kind, *work.BangumiID)
	}
	if work.DoubanID != nil && *work.DoubanID != "" {
		return fmt.Sprintf("douban:%s:%s", kind, *work.DoubanID)
	}
	if work.AniListID != nil && *work.AniListID != "" {
		return fmt.Sprintf("anilist:%s:%s", kind, *work.AniListID)
	}
	if work.ImdbID != nil && *work.ImdbID != "" {
		return fmt.Sprintf("imdb:%s:%s", kind, *work.ImdbID)
	}
	if work.TvdbID != nil && *work.TvdbID != "" {
		return fmt.Sprintf("tvdb:%s:%s", kind, *work.TvdbID)
	}
	return ""
}

func (sc *Scraper) findExistingByExternalID(excludeID int64, kind, provider, externalID string) int64 {
	var id int64
	var col string
	switch provider {
	case "tmdb":
		col = "tmdb_id"
	case "bangumi":
		col = "bangumi_id"
	case "douban":
		col = "douban_id"
	case "anilist":
		col = "anilist_id"
	case "imdb":
		col = "imdb_id"
	case "tvdb":
		col = "tvdb_id"
	default:
		return 0
	}
	err := sc.store.DB().QueryRow(
		fmt.Sprintf(`SELECT id FROM media_items WHERE kind = ? AND %s = ? AND id != ? LIMIT 1`, col),
		kind, externalID, excludeID,
	).Scan(&id)
	if err == nil {
		return id
	}
	return 0
}

func (sc *Scraper) mergeItems(from db.MediaItem, intoID int64) error {
	if from.Kind == db.KindMovie {
		_, _ = sc.store.DB().Exec(`UPDATE media_files SET item_id = ? WHERE item_id = ?`, intoID, from.ID)
		_, _ = sc.store.DB().Exec(`DELETE FROM media_items WHERE id = ?`, from.ID)
		sc.appendTitleAlias(intoID, from.Title)
		return nil
	}
	eps, err := sc.store.GetEpisodesByShow(from.ID, nil)
	if err != nil {
		return err
	}
	now := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for _, ep := range eps {
		sNum := 1
		if ep.SeasonNumber != nil {
			sNum = *ep.SeasonNumber
		}
		eNum := 1
		if ep.EpisodeNumber != nil {
			eNum = *ep.EpisodeNumber
		}
		seasonID, err := findOrCreateSeasonTx(tx, intoID, sNum, now, now)
		if err != nil {
			return err
		}
		targetEpID, err := findOrCreateEpisodeTx(tx, intoID, seasonID, sNum, eNum, now, now)
		if err != nil {
			return err
		}
		_, _ = tx.Exec(`UPDATE media_files SET item_id = ? WHERE item_id = ?`, targetEpID, ep.ID)
	}
	_, _ = tx.Exec(`DELETE FROM media_items WHERE id = ?`, from.ID)
	if err := tx.Commit(); err != nil {
		return err
	}
	sc.appendTitleAlias(intoID, from.Title)
	return nil
}

func (sc *Scraper) appendTitleAlias(itemID int64, extraTitle string) {
	extra := strings.TrimSpace(extraTitle)
	if extra == "" {
		return
	}
	target, err := sc.store.GetMediaItem(itemID)
	if err != nil {
		return
	}
	if strings.EqualFold(strings.TrimSpace(target.Title), extra) {
		return
	}
	var lines []string
	if target.Aliases != nil {
		for _, line := range strings.Split(*target.Aliases, "\n") {
			t := strings.TrimSpace(line)
			if t == "" {
				continue
			}
			if strings.EqualFold(t, extra) {
				return
			}
			lines = append(lines, t)
		}
	}
	lines = append(lines, extra)
	joined := strings.Join(lines, "\n")
	_, _ = sc.store.DB().Exec(`UPDATE media_items SET aliases = ?, updated_at = ? WHERE id = ?`, joined, sc.store.NowMs(), itemID)
}

func (sc *Scraper) remapDefaultSeasonOne(showID int64, targetSeason int) error {
	if targetSeason < 2 {
		return nil
	}
	rows, err := sc.store.DB().Query(`
		SELECT DISTINCT COALESCE(season_number, 1)
		FROM media_items
		WHERE kind = 'episode' AND show_id = ?`, showID)
	if err != nil {
		return err
	}
	var seasons []int
	for rows.Next() {
		var sn int
		if rows.Scan(&sn) == nil {
			seasons = append(seasons, sn)
		}
	}
	rows.Close()
	if len(seasons) != 1 || seasons[0] != 1 {
		return nil
	}

	now := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var existingTargetSeasonID int64
	err = tx.QueryRow(`
		SELECT id FROM media_items
		WHERE kind = 'season' AND parent_id = ? AND season_number = ? LIMIT 1`, showID, targetSeason).Scan(&existingTargetSeasonID)
	if err == nil && existingTargetSeasonID > 0 {
		_, err = tx.Exec(`
			UPDATE media_items SET parent_id = ?, season_number = ?, updated_at = ?
			WHERE kind = 'episode' AND show_id = ? AND season_number = 1`,
			existingTargetSeasonID, targetSeason, now, showID)
		if err != nil {
			return err
		}
		_, _ = tx.Exec(`DELETE FROM media_items WHERE kind = 'season' AND parent_id = ? AND season_number = 1`, showID)
	} else {
		newTitle := fmt.Sprintf("Season %d", targetSeason)
		_, err = tx.Exec(`
			UPDATE media_items SET season_number = ?, title = ?, sort_title = ?, updated_at = ?
			WHERE kind = 'season' AND parent_id = ? AND season_number = 1`,
			targetSeason, newTitle, db.SortTitleFor(newTitle), now, showID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(`
			UPDATE media_items SET season_number = ?, updated_at = ?
			WHERE kind = 'episode' AND show_id = ? AND season_number = 1`,
			targetSeason, now, showID)
		if err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	applog.Infof("scraper", "自动重映射剧集季号 #%d: Season 1 -> Season %d", showID, targetSeason)
	return nil
}

func (sc *Scraper) determineShelf(item db.MediaItem, work metadata.Work) string {
	if work.Category != nil {
		cat := *work.Category
		if cat != "" && cat != db.ShelfMovie && cat != db.ShelfShow {
			return cat
		}
	}
	if folderCat := sc.folderCategory(item); folderCat != "" {
		return folderCat
	}
	if item.Kind == db.KindShow {
		return db.ShelfShow
	}
	return db.ShelfMovie
}

func (sc *Scraper) sampleVideoOf(item db.MediaItem) *db.MediaFile {
	var row *sql.Row
	if item.Kind == db.KindShow {
		row = sc.store.DB().QueryRow(mediaFileColForSample+`
			JOIN media_items ep ON ep.id = mf.item_id
			WHERE ep.show_id = ? AND mf.role = 'video' LIMIT 1`, item.ID)
	} else {
		row = sc.store.DB().QueryRow(mediaFileColForSample+` WHERE mf.item_id = ? AND mf.role = 'video' LIMIT 1`, item.ID)
	}
	var mf db.MediaFile
	var parsed sql.NullString
	if row.Scan(&mf.ID, &mf.MountID, &mf.Path, &parsed) != nil {
		return nil
	}
	if parsed.Valid {
		mf.ParsedJSON = &parsed.String
	}
	return &mf
}

const mediaFileColForSample = `SELECT mf.id, mf.mount_id, mf.path, mf.parsed_json FROM media_files mf`

func (sc *Scraper) folderCategory(item db.MediaItem) string {
	v := sc.sampleVideoOf(item)
	if v == nil {
		return ""
	}
	segs := storage.PathSegments(storage.ParentPath(v.Path))
	keep := len(segs) - 1
	if keep > 0 && ParseFolderName(segs[len(segs)-1]).IsSeasonFolder {
		keep--
	}
	if keep <= 0 {
		return ""
	}
	above := strings.ToLower(strings.Join(segs[:keep], "/"))
	for _, kw := range []string{"动漫", "動漫", "动画", "動畫", "番剧", "番劇", "国漫", "國漫", "日漫", "美漫", "卡通", "anime", "bangumi", "cartoon"} {
		if strings.Contains(above, kw) {
			return db.ShelfAnime
		}
	}
	for _, kw := range []string{"综艺", "綜藝", "真人秀", "脱口秀", "脫口秀", "variety", "reality"} {
		if strings.Contains(above, kw) {
			return db.ShelfVariety
		}
	}
	for _, kw := range []string{"纪录", "紀錄", "documentar"} {
		if strings.Contains(above, kw) {
			return db.ShelfDocumentary
		}
	}
	return ""
}

func (sc *Scraper) looksLikeAnime(item db.MediaItem) bool {
	v := sc.sampleVideoOf(item)
	if v == nil {
		return false
	}
	parentLow := strings.ToLower(storage.ParentPath(v.Path))
	for _, kw := range []string{"动漫", "動漫", "动画", "動畫", "番剧", "番劇", "国漫", "國漫", "日漫", "美漫", "卡通", "anime", "bangumi", "cartoon"} {
		if strings.Contains(parentLow, kw) {
			return true
		}
	}
	if v.ParsedJSON != nil {
		var p map[string]any
		if json.Unmarshal([]byte(*v.ParsedJSON), &p) == nil {
			if fs, _ := p["fansubStyle"].(bool); fs {
				return true
			}
		}
	}
	return false
}

func (sc *Scraper) auxiliaryProvidersFor(item db.MediaItem, cfg db.ServerSettings) []string {
	var order []string
	if sc.looksLikeAnime(item) {
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

func (sc *Scraper) collectItemTitles(item db.MediaItem, customRules string) []string {
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
	if custom := ApplyCustomRecognitionWords(item.Title, customRules); custom != "" {
		addRaw(custom)
	}
	addRaw(item.Title)
	if folderTitle := sc.folderTitleHint(item); folderTitle != "" {
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
	isShow := item.Kind == db.KindShow
	variants := buildQueryVariantsForTitles(rawTitles, isShow, isShow)
	res, err := sc.searchBestOnSingleProvider(ctx, prov, item, overrideYear, isShow, variants, lang, forceRefresh)
	if err != nil {
		return nil, "", err
	}
	if res != nil {
		return res, item.Kind, nil
	}
	if sc.canChangeKind(item) {
		altIsShow := !isShow
		altKind := db.KindMovie
		if altIsShow {
			altKind = db.KindShow
		}
		applog.Debugf("scraper", "  主类型(%s)未命中，尝试切换类型(is_show=%v)搜索 [%s] #%d %q", item.Kind, altIsShow, prov, item.ID, item.Title)
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
	isShow bool,
	allowSequelProbe bool,
	lang string,
	forceRefresh bool,
) (*bestMatchResult, error) {
	cfg := sc.store.GetServerSettings()
	rawTitles := sc.collectItemTitles(item, cfg.CustomRecognitionWords)
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
		effectiveYear := yearVal
		usedYearFilter := yearVal > 0
		cands, err := sc.meta.Search(ctx, prov, kind, v.Query, yearVal, lang, forceRefresh)
		if err != nil {
			applog.Warnf("scraper", "  搜索出错 #%d [%s/%s] q=%q year=%d: %s", item.ID, prov, kind, v.Query, yearVal, applog.RedactURL(err.Error()))
			return nil, err
		}
		if len(cands) == 0 && yearVal > 0 {
			effectiveYear = 0
			usedYearFilter = false
			cands, err = sc.meta.Search(ctx, prov, kind, v.Query, 0, lang, forceRefresh)
			if err != nil {
				applog.Warnf("scraper", "  无年份兜底搜索出错 #%d [%s/%s] q=%q: %s", item.ID, prov, kind, v.Query, applog.RedactURL(err.Error()))
				return nil, err
			}
		}
		if len(cands) == 0 {
			applog.Infof("scraper", "  搜索无候选 #%d [%s/%s] q=%q year=%d", item.ID, prov, kind, v.Query, effectiveYear)
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
			applog.Infof("scraper", "  命中最佳候选 #%d [%s/%s] q=%q -> [%s:%s] %q (year=%s) 得分=%.2f >= %.2f", item.ID, prov, kind, v.Query, prov, best.ID, best.Title, FormatIntPtr(best.Year), bestScore, acceptMatchScore)
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
		bestAliasHit := ""
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
			aScore, _, hitName := matchCandidateScoreWithAliases(v.Query, targetYear, rc.cand, work.Aliases)
			aScore -= float64(rc.rank) * 0.001
			if aScore > bestAliasScore {
				copyC := rc.cand
				bestAliasCand = &copyC
				bestAliasScore = aScore
				bestAliasHit = hitName
			}
		}
		if bestAliasCand != nil && bestAliasScore >= acceptMatchScore {
			applog.Infof("scraper", "  命中候选别名 #%d [%s/%s] q=%q -> [%s:%s] %q (匹配别名=%q, 得分=%.2f >= %.2f)", item.ID, prov, kind, v.Query, prov, bestAliasCand.ID, bestAliasCand.Title, bestAliasHit, bestAliasScore, acceptMatchScore)
			return &bestMatchResult{Provider: prov, Candidate: *bestAliasCand, ImpliedSeason: v.ImpliedSeason}, nil
		}

		// Pass 3: Safe same-year unique candidate fallback
		if usedYearFilter && targetYear != nil && len(cands) == 1 && isSubstantialQueryForUniqueFallback(v.Query) {
			sole := cands[0]
			if sole.Year != nil && int(math.Abs(float64(*targetYear-*sole.Year))) <= 1 {
				applog.Infof("scraper", "  唯一同年候选保底命中 #%d [%s/%s] q=%q year=%d -> [%s:%s] %q (候选year=%d)", item.ID, prov, kind, v.Query, *targetYear, prov, sole.ID, sole.Title, *sole.Year)
				return &bestMatchResult{Provider: prov, Candidate: sole, ImpliedSeason: v.ImpliedSeason}, nil
			}
		}

		if best != nil {
			orig := ""
			if best.OriginalTitle != nil {
				orig = *best.OriginalTitle
			}
			applog.Warnf("scraper", "  候选得分未达标 #%d [%s/%s] q=%q -> 共 %d 个候选, 最高分=%.2f < %.2f (最佳: [%s:%s] %q orig=%q year=%s)", item.ID, prov, kind, v.Query, len(cands), bestScore, acceptMatchScore, prov, best.ID, best.Title, orig, FormatIntPtr(best.Year))
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
		applog.Warnf("scraper", "  续季搜索出错 #%d [%s/show] q=%q: %s", item.ID, prov, v.Query, applog.RedactURL(err.Error()))
		return nil, err
	}
	if len(cands) == 0 {
		applog.Infof("scraper", "  续季搜索无候选 #%d [%s/show] q=%q season=%d", item.ID, prov, v.Query, v.ImpliedSeason)
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
			applog.Warnf("scraper", "  校验主剧第 %d 季失败 #%d [%s:%s] %q: %s", v.ImpliedSeason, item.ID, prov, c.ID, c.Title, applog.RedactURL(sErr.Error()))
			continue
		}
		if !ok {
			if seasonYear > 0 && item.Year != nil {
				applog.Warnf("scraper", "  续季年份偏差过大 #%d: 主剧 [%s:%s] %q 第 %d 季年份=%d (本地=%d)", item.ID, prov, c.ID, c.Title, v.ImpliedSeason, seasonYear, *item.Year)
			} else {
				applog.Warnf("scraper", "  续季核验未通过 #%d: 命中主剧 [%s:%s] %q，但上游尚无第 %d 季数据，暂不归并以防混入第 1 季", item.ID, prov, c.ID, c.Title, v.ImpliedSeason)
			}
			continue
		}
		applog.Infof("scraper", "  续季匹配成功 #%d [%s/show] q=%q -> [%s:%s] %q 第 %d 季 (季年份=%d)", item.ID, prov, v.Query, prov, c.ID, c.Title, v.ImpliedSeason, seasonYear)
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

func (sc *Scraper) folderTitleHint(item db.MediaItem) string {
	v := sc.sampleVideoOf(item)
	if v == nil {
		return ""
	}
	segs := storage.PathSegments(storage.ParentPath(v.Path))
	for i := len(segs) - 1; i >= 0 && i >= len(segs)-2; i-- {
		pf := ParseFolderName(segs[i])
		if pf.IsSeasonFolder || pf.Title == "" {
			continue
		}
		return pf.Title
	}
	return ""
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

// diceSimilarity computes Sorensen-Dice bigram similarity over runes (matching string_similarity).
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

func (sc *Scraper) canChangeKind(item db.MediaItem) bool {
	if item.Kind == db.KindMovie {
		return true
	}
	if item.Kind != db.KindShow {
		return false
	}
	var epCnt int
	_ = sc.store.DB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind = 'episode' AND show_id = ?`, item.ID).Scan(&epCnt)
	return epCnt == 1
}

func (sc *Scraper) changeKind(item db.MediaItem) (db.MediaItem, error) {
	now := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return db.MediaItem{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if item.Kind == db.KindMovie {
		sNum, eNum := 1, 1
		seasonID, err := insertPlaceholderItemTx(tx, db.KindSeason, item.LibraryType, "Season 1", &item.ID, &item.ID, nil, &sNum, nil, now, now)
		if err != nil {
			return db.MediaItem{}, err
		}
		epID, err := insertPlaceholderItemTx(tx, db.KindEpisode, item.LibraryType, "第 1 集", &seasonID, &item.ID, nil, &sNum, &eNum, now, now)
		if err != nil {
			return db.MediaItem{}, err
		}
		_, _ = tx.Exec(`UPDATE media_files SET item_id = ? WHERE item_id = ?`, epID, item.ID)
		_, _ = tx.Exec(`UPDATE media_items SET kind = 'show', updated_at = ? WHERE id = ?`, now, item.ID)
	} else {
		_, _ = tx.Exec(`
			UPDATE media_files SET item_id = ?
			WHERE item_id IN (SELECT id FROM media_items WHERE kind = 'episode' AND show_id = ?)`,
			item.ID, item.ID,
		)
		_, _ = tx.Exec(`DELETE FROM media_items WHERE show_id = ?`, item.ID)
		_, _ = tx.Exec(`UPDATE media_items SET kind = 'movie', updated_at = ? WHERE id = ?`, now, item.ID)
	}
	if err := tx.Commit(); err != nil {
		return db.MediaItem{}, err
	}
	return sc.store.GetMediaItem(item.ID)
}

func (sc *Scraper) setFilesMatchState(itemID int64, kind, state string, locked bool) error {
	lockInt := 0
	if locked {
		lockInt = 1
	}
	if kind == db.KindShow {
		_, err := sc.store.DB().Exec(`
			UPDATE media_files SET match_state = ?, match_locked = CASE WHEN ? = 1 THEN 1 ELSE match_locked END
			WHERE role = 'video' AND item_id IN (SELECT id FROM media_items WHERE kind = 'episode' AND show_id = ?)`,
			state, lockInt, itemID,
		)
		return err
	}
	_, err := sc.store.DB().Exec(`
		UPDATE media_files SET match_state = ?, match_locked = CASE WHEN ? = 1 THEN 1 ELSE match_locked END
		WHERE role = 'video' AND item_id = ?`,
		state, lockInt, itemID,
	)
	return err
}

func (sc *Scraper) readMountText(ctx context.Context, mountID, filePath string) (string, error) {
	m, err := sc.store.GetMount(mountID)
	if err != nil {
		return "", err
	}
	drv, err := sc.storage.DriverFor(storage.MountConfig{
		ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets,
	})
	if err != nil {
		return "", err
	}
	rr, err := drv.OpenRange(ctx, storage.Entry{Path: filePath, Name: storage.BaseName(filePath)}, 0, nil, false)
	if err != nil {
		return "", err
	}
	defer rr.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(rr.Body, 2*1024*1024))
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func (sc *Scraper) tryScrapeFromNfo(ctx context.Context, item db.MediaItem) (string, bool) {
	v := sc.sampleVideoOf(item)
	if v == nil {
		return "", false
	}
	dir := storage.ParentPath(v.Path)
	if item.Kind == db.KindMovie {
		nfos := sc.filesInDir(v.MountID, dir, db.FileRoleNfo)
		if len(nfos) == 0 {
			return "", false
		}
		vStem := strings.ToLower(fileStem(storage.BaseName(v.Path)))
		var chosen string
		for _, n := range nfos {
			if strings.ToLower(fileStem(storage.BaseName(n.Path))) == vStem {
				chosen = n.Path
				break
			}
		}
		if chosen == "" {
			for _, n := range nfos {
				if strings.EqualFold(storage.BaseName(n.Path), "movie.nfo") {
					chosen = n.Path
					break
				}
			}
		}
		if chosen == "" {
			return "", false
		}
		raw, err := sc.readMountText(ctx, v.MountID, chosen)
		if err != nil {
			return "", false
		}
		work := ReadTitleNFO(raw, "movie")
		if work == nil {
			return "", false
		}
		if err := sc.applyWork(ctx, item.ID, *work, true, ""); err != nil {
			return "", false
		}
		_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, true)
		return "matched", true
	}

	if item.Kind == db.KindShow {
		showDir := dir
		if ParseFolderName(storage.BaseName(dir)).IsSeasonFolder {
			showDir = storage.ParentPath(dir)
		}
		nfos := sc.filesInDir(v.MountID, showDir, db.FileRoleNfo)
		var tvNfo string
		for _, n := range nfos {
			if strings.EqualFold(storage.BaseName(n.Path), "tvshow.nfo") {
				tvNfo = n.Path
				break
			}
		}
		if tvNfo == "" {
			return "", false
		}
		raw, err := sc.readMountText(ctx, v.MountID, tvNfo)
		if err != nil {
			return "", false
		}
		work := ReadTitleNFO(raw, "tvshow")
		if work == nil {
			return "", false
		}
		if err := sc.applyWork(ctx, item.ID, *work, true, ""); err != nil {
			return "", false
		}
		_ = sc.fillEpisodesFromNfo(ctx, item.ID)
		_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, true)
		return "matched", true
	}
	return "", false
}

func (sc *Scraper) fillEpisodesFromNfo(ctx context.Context, showID int64) error {
	eps, err := sc.store.GetEpisodesByShow(showID, nil)
	if err != nil {
		return err
	}
	now := sc.store.NowMs()
	for _, ep := range eps {
		files, err := sc.store.GetFilesForItem(ep.ID)
		if err != nil || len(files) == 0 {
			continue
		}
		v := files[0]
		dir := storage.ParentPath(v.Path)
		vStem := strings.ToLower(fileStem(storage.BaseName(v.Path)))
		for _, n := range sc.filesInDir(v.MountID, dir, db.FileRoleNfo) {
			if strings.ToLower(fileStem(storage.BaseName(n.Path))) == vStem {
				raw, err := sc.readMountText(ctx, v.MountID, n.Path)
				if err != nil {
					continue
				}
				if epMeta := ReadEpisodeNFO(raw); epMeta != nil {
					epTitle := ep.Title
					if epMeta.Title != nil && *epMeta.Title != "" {
						epTitle = *epMeta.Title
					}
					_, _ = sc.store.DB().Exec(`
						UPDATE media_items SET title = ?, sort_title = ?, summary = COALESCE(?, summary),
							release_date = COALESCE(?, release_date), runtime_ms = COALESCE(?, runtime_ms),
							rating = COALESCE(?, rating), metadata_source = 'nfo', scraped_at = ?, updated_at = ?
						WHERE id = ?`,
						epTitle, db.SortTitleFor(epTitle), epMeta.Summary, epMeta.AirDate,
						epMeta.RuntimeMs, epMeta.Rating, now, now, ep.ID,
					)
				}
				break
			}
		}
	}
	return nil
}

func (sc *Scraper) filesInDir(mountID, dir, role string) []db.MediaFile {
	prefix := "/"
	if dir != "/" {
		prefix = dir + "/"
	}
	rows, err := sc.store.DB().Query(`
		SELECT id, mount_id, path FROM media_files
		WHERE mount_id = ? AND role = ? AND path LIKE ?`,
		mountID, role, prefix+"%",
	)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []db.MediaFile
	for rows.Next() {
		var f db.MediaFile
		if rows.Scan(&f.ID, &f.MountID, &f.Path) == nil {
			if storage.ParentPath(f.Path) == dir {
				out = append(out, f)
			}
		}
	}
	return out
}

func (sc *Scraper) findLocalArtwork(item db.MediaItem) (poster string, backdrop string) {
	v := sc.sampleVideoOf(item)
	if v == nil {
		return "", ""
	}
	dir := storage.ParentPath(v.Path)
	if item.Kind == db.KindShow && ParseFolderName(storage.BaseName(dir)).IsSeasonFolder {
		dir = storage.ParentPath(dir)
	}
	arts := sc.filesInDir(v.MountID, dir, db.FileRoleArtwork)
	for _, a := range arts {
		stem := strings.ToLower(fileStem(storage.BaseName(a.Path)))
		if poster == "" && (stem == "poster" || stem == "folder" || stem == "cover" || stem == "movie") {
			poster = fmt.Sprintf("mount:%s:%s", a.MountID, a.Path)
		}
		if backdrop == "" && (stem == "fanart" || stem == "backdrop" || stem == "background") {
			backdrop = fmt.Sprintf("mount:%s:%s", a.MountID, a.Path)
		}
	}
	return poster, backdrop
}
