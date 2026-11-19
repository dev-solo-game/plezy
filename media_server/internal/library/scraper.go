package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"
	"sync"
	"unicode"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/metadata"
	"plezy/media_server/internal/storage"
)

const acceptMatchScore = 0.72

type ScrapeSummary struct {
	Matched             int    `json:"matched"`
	Unmatched           int    `json:"unmatched"`
	Merged              int    `json:"merged"`
	Skipped             int    `json:"skipped"`
	StoppedBy           string `json:"stopped_by,omitempty"`
	StoppedByMissingKey bool   `json:"stopped_by_missing_key,omitempty"`
}

type Scraper struct {
	store   *db.Store
	meta    *metadata.Service
	storage *storage.Manager
	hub     *events.Hub

	runMu   sync.Mutex
	running bool
}

func NewScraper(store *db.Store, meta *metadata.Service, st *storage.Manager, hub *events.Hub) *Scraper {
	return &Scraper{
		store:   store,
		meta:    meta,
		storage: st,
		hub:     hub,
	}
}

func (sc *Scraper) IsRunning() bool {
	sc.runMu.Lock()
	defer sc.runMu.Unlock()
	return sc.running
}

func (sc *Scraper) publishProgress(done, total int, title string, status string) {
	if sc.hub == nil {
		return
	}
	sc.hub.Publish("scrape_progress", map[string]any{
		"done":   done,
		"total":  total,
		"title":  title,
		"status": status,
	})
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

	if retryUnmatched {
		_, _ = sc.store.DB().Exec(`UPDATE media_items SET scraped_at = NULL WHERE metadata_source IS NULL AND locked = 0`)
		_, _ = sc.store.DB().Exec(`UPDATE media_files SET match_state = 'pending' WHERE role = 'video' AND match_state = 'unmatched' AND match_locked = 0`)
	}

	var rows *sql.Rows
	var err error
	if refreshAll {
		rows, err = sc.store.DB().Query(`SELECT id FROM media_items WHERE kind IN ('movie', 'show') AND locked = 0 ORDER BY id ASC`)
	} else {
		rows, err = sc.store.DB().Query(`
			SELECT id FROM media_items
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
		return ScrapeSummary{}, err
	}
	var queue []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			queue = append(queue, id)
		}
	}
	rows.Close()

	var sum ScrapeSummary
	for i, itemID := range queue {
		if ctx.Err() != nil {
			break
		}
		item, err := sc.store.GetMediaItem(itemID)
		if err != nil {
			sum.Skipped++
			continue
		}
		sc.publishProgress(i, len(queue), item.Title, "running")

		outcome, sErr := sc.scrapeOne(ctx, item, refreshAll)
		if sErr != nil {
			if errors.Is(sErr, metadata.ErrNotConfigured) {
				sum.StoppedBy = sErr.Error()
				sum.StoppedByMissingKey = true
				break
			}
			sum.Skipped++
			continue
		}
		switch outcome {
		case "matched":
			sum.Matched++
		case "merged":
			sum.Merged++
		case "unmatched":
			sum.Unmatched++
		default:
			sum.Skipped++
		}
	}

	sc.publishProgress(len(queue), len(queue), "", "completed")
	if sc.hub != nil && (sum.Matched > 0 || sum.Merged > 0) {
		sc.hub.Publish("library_changed", map[string]any{"source": "scraper"})
	}
	return sum, nil
}

func (sc *Scraper) scrapeOne(ctx context.Context, item db.MediaItem, forceRefresh bool) (string, error) {
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
		extID := ""
		if prov == "tmdb" && item.TmdbID != nil {
			extID = *item.TmdbID
		} else if prov == "bangumi" && item.BangumiID != nil {
			extID = *item.BangumiID
		}
		if extID == "" {
			return "skipped", nil
		}
		if forceRefresh {
			work, err := sc.meta.GetWork(ctx, prov, item.Kind, extID, cfg.ScraperLang, true)
			if err != nil {
				return "skipped", err
			}
			if err := sc.applyWork(ctx, item.ID, work, false, ""); err != nil {
				return "skipped", err
			}
		}
		if item.Kind == db.KindShow {
			_ = sc.fillSeasons(ctx, item.ID, prov, extID, item.Title, cfg.ScraperLang, forceRefresh)
		}
		_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, false)
		return "matched", nil
	}

	// 1. Try NFO
	if cfg.PreferNfo {
		if outcome, ok := sc.tryScrapeFromNfo(ctx, item); ok {
			return outcome, nil
		}
	}

	// 2. Online providers
	providers := sc.providersFor(item, cfg)
	if len(providers) == 0 {
		return "skipped", metadata.ErrNotConfigured
	}

	isShow := item.Kind == db.KindShow
	bestProv, bestCand, err := sc.findBestMatch(ctx, providers, item, isShow, cfg.ScraperLang)
	if err != nil {
		return "skipped", err
	}
	if bestCand == nil && sc.canChangeKind(item) {
		bestProv, bestCand, err = sc.findBestMatch(ctx, providers, item, !isShow, cfg.ScraperLang)
		if err != nil {
			return "skipped", err
		}
		if bestCand != nil {
			changed, cErr := sc.changeKind(item)
			if cErr == nil {
				item = changed
				isShow = item.Kind == db.KindShow
			}
		}
	}
	if bestCand == nil {
		_, _ = sc.store.DB().Exec(`UPDATE media_items SET scraped_at = ? WHERE id = ?`, sc.store.NowMs(), item.ID)
		_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchUnmatched, false)
		return "unmatched", nil
	}

	return sc.applyCandidate(ctx, item, bestProv, *bestCand, cfg.ScraperLang, false, "")
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
	_, err = sc.applyCandidate(ctx, item, provider, cand, cfg.ScraperLang, true, libraryType)
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
) (string, error) {
	targetID := sc.findExistingByExternalID(item.ID, item.Kind, provider, cand.ID)
	if targetID > 0 {
		if err := sc.mergeItems(item, targetID); err != nil {
			return "skipped", err
		}
		if locked {
			work, err := sc.meta.GetWork(ctx, provider, item.Kind, cand.ID, lang, false)
			if err == nil {
				_ = sc.applyWork(ctx, targetID, work, true, overrideShelf)
				if item.Kind == db.KindShow {
					_ = sc.fillSeasons(ctx, targetID, provider, cand.ID, work.Title, lang, false)
				}
			}
			_ = sc.setFilesMatchState(targetID, item.Kind, db.MatchMatched, true)
		}
		return "merged", nil
	}

	work, err := sc.meta.GetWork(ctx, provider, item.Kind, cand.ID, lang, false)
	if err != nil {
		return "skipped", err
	}
	if err := sc.applyWork(ctx, item.ID, work, locked, overrideShelf); err != nil {
		return "skipped", err
	}
	if item.Kind == db.KindShow {
		_ = sc.fillSeasons(ctx, item.ID, provider, cand.ID, work.Title, lang, false)
	}
	_ = sc.setFilesMatchState(item.ID, item.Kind, db.MatchMatched, locked)
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
			tmdb_id = ?,
			imdb_id = ?,
			tvdb_id = ?,
			bangumi_id = ?,
			metadata_source = ?,
			locked = ?,
			scraped_at = ?,
			updated_at = ?
		WHERE id = ?`,
		workKeyPtr, shelf, title, db.SortTitleFor(title), work.OriginalTitle, aliasPtr,
		year, work.ReleaseDate, work.Summary, work.Tagline, work.ContentRating, work.Studio,
		work.Rating, work.RuntimeMs, poster, backdrop, work.LogoPath,
		work.TmdbID, work.ImdbID, work.TvdbID, work.BangumiID, work.Source,
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
	return tx.Commit()
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

func (sc *Scraper) providersFor(item db.MediaItem, cfg db.ServerSettings) []string {
	var general []string
	if cfg.TmdbAPIKey != "" {
		general = append(general, "tmdb")
	}
	if !cfg.BangumiEnabled || !sc.looksLikeAnime(item) {
		return general
	}
	if item.Kind == db.KindShow {
		return append([]string{"bangumi"}, general...)
	}
	return append(general, "bangumi")
}

func (sc *Scraper) findBestMatch(ctx context.Context, providers []string, item db.MediaItem, isShow bool, lang string) (string, *metadata.Candidate, error) {
	kind := "movie"
	if isShow {
		kind = "show"
	}
	titles := []string{item.Title}
	if folderTitle := sc.folderTitleHint(item); folderTitle != "" && !strings.EqualFold(folderTitle, item.Title) {
		titles = append(titles, folderTitle)
	}

	for _, prov := range providers {
		for _, queryTitle := range titles {
			yearVal := 0
			if item.Year != nil {
				yearVal = *item.Year
			}
			cands, err := sc.meta.Search(ctx, prov, kind, queryTitle, yearVal, lang, false)
			if err != nil {
				if prov == "bangumi" && len(providers) > 1 {
					break
				}
				return "", nil, err
			}
			if len(cands) == 0 && yearVal > 0 {
				cands, err = sc.meta.Search(ctx, prov, kind, queryTitle, 0, lang, false)
				if err != nil {
					if prov == "bangumi" && len(providers) > 1 {
						break
					}
					return "", nil, err
				}
			}
			var best *metadata.Candidate
			bestScore := 0.0
			for rank, c := range cands {
				score := matchCandidateScore(queryTitle, item.Year, c) - float64(rank)*0.001
				if score > bestScore {
					copyC := c
					best = &copyC
					bestScore = score
				}
			}
			if best != nil && bestScore >= acceptMatchScore {
				return prov, best, nil
			}
		}
	}
	return "", nil, nil
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

func matchCandidateScore(title string, year *int, cand metadata.Candidate) float64 {
	wanted := normalizeForScore(title)
	sim := 0.0
	names := []string{cand.Title}
	if cand.OriginalTitle != nil {
		names = append(names, *cand.OriginalTitle)
	}
	for _, n := range names {
		other := normalizeForScore(n)
		if other == "" {
			continue
		}
		s := 0.0
		if other == wanted {
			s = 1.0
		} else {
			s = diceSimilarity(wanted, other)
		}
		if s > sim {
			sim = s
		}
	}
	if year != nil && cand.Year != nil {
		gap := int(math.Abs(float64(*year - *cand.Year)))
		if gap == 0 {
			sim += 0.15
		} else if gap == 1 {
			sim += 0.05
		} else {
			sim -= 0.35
		}
	}
	return sim
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
