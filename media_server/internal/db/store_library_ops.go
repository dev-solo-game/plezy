package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func WorkWatchStateKey(item MediaItem, show *MediaItem) string {
	switch item.Kind {
	case KindMovie:
		if item.WorkKey != nil && *item.WorkKey != "" {
			return "movie:" + *item.WorkKey
		}
	case KindEpisode:
		if show != nil && show.WorkKey != nil && *show.WorkKey != "" && item.EpisodeNumber != nil {
			sNum := 1
			if item.SeasonNumber != nil {
				sNum = *item.SeasonNumber
			}
			return fmt.Sprintf("episode:%s:s%d:e%d", *show.WorkKey, sNum, *item.EpisodeNumber)
		}
	case KindShow:
		if item.WorkKey != nil && *item.WorkKey != "" {
			return "show:" + *item.WorkKey
		}
	}
	return ""
}

func (s *Store) persistWatchStateLocked(tx *sql.Tx, itemID int64, ws WatchState) error {
	_, err := tx.Exec(`
		INSERT INTO watch_states(
			item_id, work_key, last_file_id, position_ms, duration_ms, watched, play_count,
			last_played_at, favorite, hidden_from_continue, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(item_id) DO UPDATE SET
			work_key = COALESCE(NULLIF(excluded.work_key, ''), watch_states.work_key),
			last_file_id = COALESCE(excluded.last_file_id, watch_states.last_file_id),
			position_ms = excluded.position_ms,
			duration_ms = COALESCE(excluded.duration_ms, watch_states.duration_ms),
			watched = excluded.watched,
			play_count = excluded.play_count,
			last_played_at = COALESCE(excluded.last_played_at, watch_states.last_played_at),
			favorite = excluded.favorite,
			hidden_from_continue = excluded.hidden_from_continue,
			updated_at = excluded.updated_at`,
		itemID, ws.WorkKey, ws.LastFileID, ws.PositionMs, ws.DurationMs, boolToInt(ws.Watched), ws.PlayCount,
		ws.LastPlayedAt, boolToInt(ws.Favorite), boolToInt(ws.HiddenFromContinue), ws.UpdatedAt,
	)
	if err != nil {
		return err
	}
	if ws.WorkKey != "" {
		_, err = tx.Exec(`
			INSERT INTO work_watch_states(
				state_key, position_ms, duration_ms, watched, play_count,
				last_played_at, favorite, hidden_from_continue, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(state_key) DO UPDATE SET
				position_ms = excluded.position_ms,
				duration_ms = COALESCE(excluded.duration_ms, work_watch_states.duration_ms),
				watched = excluded.watched,
				play_count = excluded.play_count,
				last_played_at = COALESCE(excluded.last_played_at, work_watch_states.last_played_at),
				favorite = excluded.favorite,
				hidden_from_continue = excluded.hidden_from_continue,
				updated_at = excluded.updated_at`,
			ws.WorkKey, ws.PositionMs, ws.DurationMs, boolToInt(ws.Watched), ws.PlayCount,
			ws.LastPlayedAt, boolToInt(ws.Favorite), boolToInt(ws.HiddenFromContinue), ws.UpdatedAt,
		)
	}
	return err
}

func (s *Store) loadCurrentWatchState(itemID int64) WatchState {
	var ws WatchState
	var workKey sql.NullString
	var lastFile, dur, lastPlayed sql.NullInt64
	var watched, fav, hidden int
	err := s.db.QueryRow(`
		SELECT item_id, work_key, last_file_id, position_ms, duration_ms, watched, play_count,
			last_played_at, favorite, hidden_from_continue, updated_at
		FROM watch_states WHERE item_id = ?`, itemID,
	).Scan(
		&ws.ItemID, &workKey, &lastFile, &ws.PositionMs, &dur, &watched, &ws.PlayCount,
		&lastPlayed, &fav, &hidden, &ws.UpdatedAt,
	)
	if err != nil {
		return WatchState{ItemID: itemID}
	}
	ws.WorkKey = workKey.String
	ws.LastFileID = nullInt64Ptr(lastFile)
	ws.DurationMs = nullInt64Ptr(dur)
	ws.Watched = watched != 0
	ws.LastPlayedAt = nullInt64Ptr(lastPlayed)
	ws.Favorite = fav != 0
	ws.HiddenFromContinue = hidden != 0
	return ws
}

func (s *Store) resolveStateKeyForItem(itemID int64) string {
	item, err := s.GetMediaItem(itemID)
	if err != nil {
		return ""
	}
	var show *MediaItem
	if item.ShowID != nil {
		if sh, err := s.GetMediaItem(*item.ShowID); err == nil {
			show = &sh
		}
	}
	return WorkWatchStateKey(item, show)
}

func (s *Store) UpdateProgress(itemID int64, fileID *int64, positionMs int64, durationMs *int64, threshold float64) (WatchState, error) {
	item, err := s.GetMediaItem(itemID)
	if err != nil {
		return WatchState{}, err
	}
	if positionMs < 0 {
		positionMs = 0
	}
	if threshold <= 0 || threshold > 0.99 {
		threshold = DefaultWatchedThreshold
	}

	ws := s.loadCurrentWatchState(itemID)
	ws.WorkKey = s.resolveStateKeyForItem(itemID)
	if fileID != nil && *fileID > 0 {
		ws.LastFileID = fileID
	}
	if durationMs != nil && *durationMs > 0 {
		ws.DurationMs = durationMs
	} else if ws.DurationMs == nil && item.RuntimeMs != nil && *item.RuntimeMs > 0 {
		ws.DurationMs = item.RuntimeMs
	}

	now := s.NowMs()
	ws.PositionMs = positionMs
	ws.LastPlayedAt = &now
	ws.HiddenFromContinue = false
	ws.UpdatedAt = now

	if ws.DurationMs != nil && *ws.DurationMs > 0 && float64(positionMs) >= float64(*ws.DurationMs)*threshold {
		if !ws.Watched {
			ws.PlayCount++
		}
		ws.Watched = true
		ws.PositionMs = 0
	}

	tx, err := s.db.Begin()
	if err != nil {
		return WatchState{}, err
	}
	defer func() { _ = tx.Rollback() }()
	if err := s.persistWatchStateLocked(tx, itemID, ws); err != nil {
		return WatchState{}, err
	}
	if err := tx.Commit(); err != nil {
		return WatchState{}, err
	}
	return ws, nil
}

func (s *Store) SetWatched(itemID int64, watched bool) (WatchState, error) {
	item, err := s.GetMediaItem(itemID)
	if err != nil {
		return WatchState{}, err
	}
	now := s.NowMs()
	tx, err := s.db.Begin()
	if err != nil {
		return WatchState{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if item.Kind == KindShow || item.Kind == KindSeason {
		var eps []MediaItem
		if item.Kind == KindShow {
			eps, _ = s.GetEpisodesByShow(item.ID, nil)
		} else if item.ParentID != nil {
			eps, _ = s.GetEpisodesByShow(*item.ParentID, item.SeasonNumber)
		}
		for _, ep := range eps {
			ews := s.loadCurrentWatchState(ep.ID)
			ews.WorkKey = s.resolveStateKeyForItem(ep.ID)
			ews.Watched = watched
			ews.PositionMs = 0
			if watched && ews.PlayCount == 0 {
				ews.PlayCount = 1
			}
			ews.UpdatedAt = now
			if err := s.persistWatchStateLocked(tx, ep.ID, ews); err != nil {
				return WatchState{}, err
			}
		}
		if err := tx.Commit(); err != nil {
			return WatchState{}, err
		}
		return s.loadCurrentWatchState(itemID), nil
	}

	ws := s.loadCurrentWatchState(itemID)
	ws.WorkKey = s.resolveStateKeyForItem(itemID)
	ws.Watched = watched
	ws.PositionMs = 0
	if watched && ws.PlayCount == 0 {
		ws.PlayCount = 1
	}
	ws.UpdatedAt = now
	if err := s.persistWatchStateLocked(tx, itemID, ws); err != nil {
		return WatchState{}, err
	}
	if err := tx.Commit(); err != nil {
		return WatchState{}, err
	}
	return ws, nil
}

func (s *Store) SetFavorite(itemID int64, favorite bool) (WatchState, error) {
	if _, err := s.GetMediaItem(itemID); err != nil {
		return WatchState{}, err
	}
	ws := s.loadCurrentWatchState(itemID)
	ws.WorkKey = s.resolveStateKeyForItem(itemID)
	ws.Favorite = favorite
	ws.UpdatedAt = s.NowMs()

	tx, err := s.db.Begin()
	if err != nil {
		return WatchState{}, err
	}
	defer func() { _ = tx.Rollback() }()
	if err := s.persistWatchStateLocked(tx, itemID, ws); err != nil {
		return WatchState{}, err
	}
	if err := tx.Commit(); err != nil {
		return WatchState{}, err
	}
	return ws, nil
}

func (s *Store) SetHiddenFromContinue(itemID int64, hidden bool) error {
	if _, err := s.GetMediaItem(itemID); err != nil {
		return err
	}
	ws := s.loadCurrentWatchState(itemID)
	ws.WorkKey = s.resolveStateKeyForItem(itemID)
	ws.HiddenFromContinue = hidden
	ws.UpdatedAt = s.NowMs()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := s.persistWatchStateLocked(tx, itemID, ws); err != nil {
		return err
	}
	return tx.Commit()
}

// RestoreWatchStateForItem projects persisted work_watch_states onto itemID when matched.
func (s *Store) RestoreWatchStateForItem(itemID int64, stateKey string) {
	if stateKey == "" {
		return
	}
	var posMs int64
	var dur, lastPlayed sql.NullInt64
	var watched, playCount, fav, hidden int
	var updatedAt int64
	err := s.db.QueryRow(`
		SELECT position_ms, duration_ms, watched, play_count, last_played_at, favorite, hidden_from_continue, updated_at
		FROM work_watch_states WHERE state_key = ?`, stateKey,
	).Scan(&posMs, &dur, &watched, &playCount, &lastPlayed, &fav, &hidden, &updatedAt)
	if err != nil {
		return
	}
	_, _ = s.db.Exec(`
		INSERT INTO watch_states(
			item_id, work_key, position_ms, duration_ms, watched, play_count,
			last_played_at, favorite, hidden_from_continue, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(item_id) DO UPDATE SET
			work_key = excluded.work_key,
			position_ms = CASE WHEN excluded.updated_at > watch_states.updated_at THEN excluded.position_ms ELSE watch_states.position_ms END,
			duration_ms = COALESCE(watch_states.duration_ms, excluded.duration_ms),
			watched = CASE WHEN excluded.updated_at > watch_states.updated_at THEN excluded.watched ELSE watch_states.watched END,
			play_count = MAX(watch_states.play_count, excluded.play_count),
			last_played_at = COALESCE(watch_states.last_played_at, excluded.last_played_at),
			favorite = MAX(watch_states.favorite, excluded.favorite),
			hidden_from_continue = CASE WHEN excluded.updated_at > watch_states.updated_at THEN excluded.hidden_from_continue ELSE watch_states.hidden_from_continue END,
			updated_at = MAX(watch_states.updated_at, excluded.updated_at)`,
		itemID, stateKey, posMs, dur, watched, playCount, lastPlayed, fav, hidden, updatedAt,
	)
}

func (s *Store) UpsertWorkPrefs(wp WorkPrefs) (WorkPrefs, error) {
	wp.WorkKey = strings.TrimSpace(wp.WorkKey)
	if wp.WorkKey == "" {
		return WorkPrefs{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}
	if wp.PlaybackSpeed <= 0 {
		wp.PlaybackSpeed = 1.0
	}
	wp.UpdatedAt = s.NowMs()
	_, err := s.db.Exec(`
		INSERT INTO work_prefs(
			work_key, intro_enabled, intro_start_ms, intro_end_ms,
			credits_enabled, credits_from_end_ms, keep_easter_egg_ms,
			preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(work_key) DO UPDATE SET
			intro_enabled = excluded.intro_enabled,
			intro_start_ms = excluded.intro_start_ms,
			intro_end_ms = excluded.intro_end_ms,
			credits_enabled = excluded.credits_enabled,
			credits_from_end_ms = excluded.credits_from_end_ms,
			keep_easter_egg_ms = excluded.keep_easter_egg_ms,
			preferred_audio_lang = excluded.preferred_audio_lang,
			preferred_sub_lang = excluded.preferred_sub_lang,
			playback_speed = excluded.playback_speed,
			updated_at = excluded.updated_at`,
		wp.WorkKey, boolToInt(wp.IntroEnabled), wp.IntroStartMs, wp.IntroEndMs,
		boolToInt(wp.CreditsEnabled), wp.CreditsFromEndMs, wp.KeepEasterEggMs,
		wp.PreferredAudioLang, wp.PreferredSubLang, wp.PlaybackSpeed, wp.UpdatedAt,
	)
	if err != nil {
		return WorkPrefs{}, err
	}
	return wp, nil
}

func (s *Store) CreateList(kind, title string, summary, posterSource, tmdbID *string) (MediaList, error) {
	if kind != ListCollection && kind != ListPlaylist {
		return MediaList{}, fmt.Errorf("%w: invalid list kind", ErrInvalidInput)
	}
	title = strings.TrimSpace(title)
	if title == "" {
		return MediaList{}, fmt.Errorf("%w: list title required", ErrInvalidInput)
	}
	now := s.NowMs()
	res, err := s.db.Exec(`
		INSERT INTO lists(kind, title, summary, poster_source, tmdb_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		kind, title, summary, posterSource, tmdbID, now, now,
	)
	if err != nil {
		return MediaList{}, err
	}
	id, _ := res.LastInsertId()
	return s.GetMediaListDetail(id)
}

func (s *Store) UpdateList(id int64, title string, summary, posterSource *string) (MediaList, error) {
	existing, err := s.GetMediaListDetail(id)
	if err != nil {
		return MediaList{}, err
	}
	if t := strings.TrimSpace(title); t != "" {
		existing.Title = t
	}
	if summary != nil {
		existing.Summary = summary
	}
	if posterSource != nil {
		existing.PosterSource = posterSource
	}
	_, err = s.db.Exec(`
		UPDATE lists SET title = ?, summary = ?, poster_source = ?, updated_at = ? WHERE id = ?`,
		existing.Title, existing.Summary, existing.PosterSource, s.NowMs(), id,
	)
	if err != nil {
		return MediaList{}, err
	}
	return s.GetMediaListDetail(id)
}

func (s *Store) DeleteList(id int64) error {
	res, err := s.db.Exec(`DELETE FROM lists WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) AddItemsToList(listID int64, itemIDs []int64) error {
	if _, err := s.GetMediaListDetail(listID); err != nil {
		return err
	}
	var maxOrder int
	_ = s.db.QueryRow(`SELECT COALESCE(MAX(sort_order), -1) FROM list_items WHERE list_id = ?`, listID).Scan(&maxOrder)
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for _, itemID := range itemIDs {
		maxOrder++
		_, _ = tx.Exec(`INSERT OR IGNORE INTO list_items(list_id, item_id, sort_order) VALUES (?, ?, ?)`, listID, itemID, maxOrder)
	}
	_, _ = tx.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, s.NowMs(), listID)
	return tx.Commit()
}

func (s *Store) RemoveItemFromList(listID, itemID int64) error {
	_, err := s.db.Exec(`DELETE FROM list_items WHERE list_id = ? AND item_id = ?`, listID, itemID)
	if err == nil {
		_, _ = s.db.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, s.NowMs(), listID)
	}
	return err
}

func (s *Store) ReorderListItems(listID int64, orderedItemIDs []int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for idx, itemID := range orderedItemIDs {
		if _, err := tx.Exec(`UPDATE list_items SET sort_order = ? WHERE list_id = ? AND item_id = ?`, idx, listID, itemID); err != nil {
			return err
		}
	}
	_, _ = tx.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, s.NowMs(), listID)
	return tx.Commit()
}

// UpsertTmdbCollection ensures a collection exists for tmdbCollectionID and links itemID.
func (s *Store) UpsertTmdbCollection(tmdbCollID, title string, poster *string, itemID int64) {
	tmdbCollID = strings.TrimSpace(tmdbCollID)
	title = strings.TrimSpace(title)
	if tmdbCollID == "" || title == "" {
		return
	}
	now := s.NowMs()
	var listID int64
	err := s.db.QueryRow(`SELECT id FROM lists WHERE kind = 'collection' AND tmdb_id = ?`, tmdbCollID).Scan(&listID)
	if errors.Is(err, sql.ErrNoRows) {
		res, insErr := s.db.Exec(`
			INSERT INTO lists(kind, title, poster_source, tmdb_id, created_at, updated_at)
			VALUES ('collection', ?, ?, ?, ?, ?)`,
			title, poster, tmdbCollID, now, now,
		)
		if insErr != nil {
			return
		}
		listID, _ = res.LastInsertId()
	} else if err == nil {
		if poster != nil {
			_, _ = s.db.Exec(`UPDATE lists SET title = ?, poster_source = COALESCE(poster_source, ?), updated_at = ? WHERE id = ?`, title, *poster, now, listID)
		}
	} else {
		return
	}
	var maxOrder int
	_ = s.db.QueryRow(`SELECT COALESCE(MAX(sort_order), -1) FROM list_items WHERE list_id = ?`, listID).Scan(&maxOrder)
	_, _ = s.db.Exec(`INSERT OR IGNORE INTO list_items(list_id, item_id, sort_order) VALUES (?, ?, ?)`, listID, itemID, maxOrder+1)
}

func (s *Store) SaveFileProbe(fileID int64, durationMs *int64, bitrateKbps *int, container, videoCodec *string, width, height *int, hdrFormat *string, streams []ProbedStream) error {
	raw, err := json.Marshal(streams)
	if err != nil {
		return err
	}
	now := s.NowMs()
	_, err = s.db.Exec(`
		UPDATE media_files
		SET duration_ms = ?, bitrate_kbps = ?, container = ?, video_codec = ?,
			width = ?, height = ?, hdr_format = ?, streams_json = ?, probed_at = ?
		WHERE id = ?`,
		durationMs, bitrateKbps, container, videoCodec, width, height, hdrFormat, string(raw), now, fileID,
	)
	return err
}

type ManualItemUpdate struct {
	Title         *string  `json:"title,omitempty"`
	OriginalTitle *string  `json:"original_title,omitempty"`
	Year          *int     `json:"year,omitempty"`
	LibraryType   *string  `json:"library_type,omitempty"`
	Summary       *string  `json:"summary,omitempty"`
	Tagline       *string  `json:"tagline,omitempty"`
	Studio        *string  `json:"studio,omitempty"`
	Rating        *float64 `json:"rating,omitempty"`
	PosterSource  *string  `json:"poster_source,omitempty"`
	BackdropSource *string `json:"backdrop_source,omitempty"`
	Locked        *bool    `json:"locked,omitempty"`
}

func (s *Store) UpdateMediaItemManual(id int64, upd ManualItemUpdate) (MediaItem, error) {
	item, err := s.GetMediaItem(id)
	if err != nil {
		return MediaItem{}, err
	}
	if upd.Title != nil && strings.TrimSpace(*upd.Title) != "" {
		item.Title = strings.TrimSpace(*upd.Title)
		item.SortTitle = SortTitleFor(item.Title)
	}
	if upd.OriginalTitle != nil {
		item.OriginalTitle = nonEmptyStringPtr(*upd.OriginalTitle)
	}
	if upd.Year != nil {
		if *upd.Year <= 0 {
			item.Year = nil
		} else {
			item.Year = upd.Year
		}
	}
	if upd.LibraryType != nil {
		lt := strings.TrimSpace(*upd.LibraryType)
		switch lt {
		case ShelfMovie, ShelfShow, ShelfAnime, ShelfVariety, ShelfDocumentary, ShelfPending:
			item.LibraryType = lt
		default:
			return MediaItem{}, fmt.Errorf("%w: invalid library_type", ErrInvalidInput)
		}
	}
	if upd.Summary != nil {
		item.Summary = nonEmptyStringPtr(*upd.Summary)
	}
	if upd.Tagline != nil {
		item.Tagline = nonEmptyStringPtr(*upd.Tagline)
	}
	if upd.Studio != nil {
		item.Studio = nonEmptyStringPtr(*upd.Studio)
	}
	if upd.Rating != nil {
		if *upd.Rating <= 0 {
			item.Rating = nil
		} else {
			item.Rating = upd.Rating
		}
	}
	if upd.PosterSource != nil {
		item.PosterSource = nonEmptyStringPtr(*upd.PosterSource)
	}
	if upd.BackdropSource != nil {
		item.BackdropSource = nonEmptyStringPtr(*upd.BackdropSource)
	}
	if upd.Locked != nil {
		item.Locked = *upd.Locked
	}
	now := s.NowMs()
	_, err = s.db.Exec(`
		UPDATE media_items
		SET title = ?, sort_title = ?, original_title = ?, year = ?, library_type = ?,
			summary = ?, tagline = ?, studio = ?, rating = ?, poster_source = ?, backdrop_source = ?,
			locked = ?, updated_at = ?
		WHERE id = ?`,
		item.Title, item.SortTitle, item.OriginalTitle, item.Year, item.LibraryType,
		item.Summary, item.Tagline, item.Studio, item.Rating, item.PosterSource, item.BackdropSource,
		boolToInt(item.Locked), now, id,
	)
	if err != nil {
		return MediaItem{}, err
	}
	if upd.LibraryType != nil && item.Kind == KindShow {
		_, _ = s.db.Exec(`UPDATE media_items SET library_type = ?, updated_at = ? WHERE show_id = ? OR parent_id = ?`, item.LibraryType, now, id, id)
	}
	return s.GetMediaItem(id)
}

func nonEmptyStringPtr(s string) *string {
	t := strings.TrimSpace(s)
	if t == "" {
		return nil
	}
	return &t
}
