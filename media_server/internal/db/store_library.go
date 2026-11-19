package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

func nullStrPtr(ns sql.NullString) *string {
	if !ns.Valid || ns.String == "" {
		return nil
	}
	v := ns.String
	return &v
}

func nullIntPtr(ni sql.NullInt64) *int {
	if !ni.Valid {
		return nil
	}
	v := int(ni.Int64)
	return &v
}

func nullInt64Ptr(ni sql.NullInt64) *int64 {
	if !ni.Valid {
		return nil
	}
	v := ni.Int64
	return &v
}

func nullFloatPtr(nf sql.NullFloat64) *float64 {
	if !nf.Valid {
		return nil
	}
	v := nf.Float64
	return &v
}

func likeEscapePattern(q string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return "%" + r.Replace(strings.TrimSpace(q)) + "%"
}

// itemVideoFilesSubquery yields the video files that belong to the outer row `mi`
// (the item itself, every episode of a show, or every episode of a season).
//
// It is written as three UNION ALL branches instead of a single
// `target.id = mi.id OR target.show_id = mi.id OR target.parent_id = mi.id`
// predicate so each branch can use its own index (media_files.item_id,
// media_items.show_id, media_items.parent_id). The OR form forced SQLite to scan
// every video file for every candidate row, which made list/home queries
// O(items × files).
const itemVideoFilesSubquery = `(
			SELECT f.width AS width, f.hdr_format AS hdr_format, f.mount_id AS mount_id
			FROM media_files f
			WHERE f.item_id = mi.id AND f.role = 'video'
			UNION ALL
			SELECT f.width, f.hdr_format, f.mount_id
			FROM media_items t JOIN media_files f ON f.item_id = t.id
			WHERE mi.kind = 'show' AND t.show_id = mi.id AND f.role = 'video'
			UNION ALL
			SELECT f.width, f.hdr_format, f.mount_id
			FROM media_items t JOIN media_files f ON f.item_id = t.id
			WHERE mi.kind = 'season' AND t.parent_id = mi.id AND f.role = 'video'
		)`

const mediaItemBaseSelect = `
	SELECT
		mi.id, mi.work_key, mi.kind, mi.library_type, mi.parent_id, mi.show_id,
		mi.title, mi.sort_title, mi.original_title, mi.aliases, mi.year, mi.release_date,
		mi.summary, mi.tagline, mi.content_rating, mi.studio, mi.rating, mi.runtime_ms,
		mi.season_number, mi.episode_number, mi.absolute_number,
		mi.poster_source, mi.backdrop_source, mi.logo_source,
		mi.tmdb_id, mi.imdb_id, mi.tvdb_id, mi.bangumi_id, mi.douban_id, mi.anilist_id, mi.metadata_source,
		mi.locked, mi.added_at, mi.source_added_at, mi.updated_at, mi.scraped_at,
		ws.last_file_id, ws.position_ms, ws.duration_ms, ws.watched, ws.play_count,
		ws.last_played_at, ws.favorite, ws.hidden_from_continue, ws.updated_at,
		sh.title, sh.poster_source, sh.backdrop_source,
		CASE
			WHEN mi.kind = 'show' THEN (SELECT COUNT(*) FROM media_items e WHERE e.kind = 'episode' AND e.show_id = mi.id)
			WHEN mi.kind = 'season' THEN (SELECT COUNT(*) FROM media_items e WHERE e.kind = 'episode' AND e.parent_id = mi.id)
			ELSE 0
		END AS episode_count,
		CASE
			WHEN mi.kind = 'show' THEN (SELECT COUNT(*) FROM media_items e JOIN watch_states ews ON ews.item_id = e.id WHERE e.kind = 'episode' AND e.show_id = mi.id AND ews.watched = 1)
			WHEN mi.kind = 'season' THEN (SELECT COUNT(*) FROM media_items e JOIN watch_states ews ON ews.item_id = e.id WHERE e.kind = 'episode' AND e.parent_id = mi.id AND ews.watched = 1)
			ELSE 0
		END AS watched_ep_count,
		COALESCE((
			SELECT MAX(COALESCE(vf.width, 0)) FROM ` + itemVideoFilesSubquery + ` vf
		), 0) AS max_width,
		COALESCE((
			SELECT GROUP_CONCAT(DISTINCT vf.hdr_format) FROM ` + itemVideoFilesSubquery + ` vf
			WHERE vf.hdr_format IS NOT NULL AND vf.hdr_format != ''
		), '') AS hdr_formats,
		COALESCE((
			SELECT GROUP_CONCAT(DISTINCT m.kind) FROM ` + itemVideoFilesSubquery + ` vf
			JOIN mounts m ON m.id = vf.mount_id
		), '') AS source_kinds
	FROM media_items mi
	LEFT JOIN watch_states ws ON ws.item_id = mi.id
	LEFT JOIN media_items sh ON sh.id = mi.show_id`

func scanMediaItem(scanner interface{ Scan(dest ...any) error }) (MediaItem, error) {
	var item MediaItem
	var workKey, origTitle, aliases, relDate, summary, tagline, contentRating, studio sql.NullString
	var poster, backdrop, logo, tmdbID, imdbID, tvdbID, bangumiID, doubanID, anilistID, metaSource sql.NullString
	var parentID, showID, year, runtimeMs, seasonNum, epNum, absNum, srcAdded, scrapedAt sql.NullInt64
	var rating sql.NullFloat64
	var lockedInt int

	var wsLastFile, wsPos, wsDur, wsPlayCount, wsLastPlayed, wsUpdated sql.NullInt64
	var wsWatched, wsFav, wsHidden sql.NullInt64
	var showTitle, showPoster, showBackdrop sql.NullString
	var epCount, watchedEpCount int
	var maxWidth int
	var hdrFormats, sourceKinds sql.NullString

	err := scanner.Scan(
		&item.ID, &workKey, &item.Kind, &item.LibraryType, &parentID, &showID,
		&item.Title, &item.SortTitle, &origTitle, &aliases, &year, &relDate,
		&summary, &tagline, &contentRating, &studio, &rating, &runtimeMs,
		&seasonNum, &epNum, &absNum,
		&poster, &backdrop, &logo,
		&tmdbID, &imdbID, &tvdbID, &bangumiID, &doubanID, &anilistID, &metaSource,
		&lockedInt, &item.AddedAt, &srcAdded, &item.UpdatedAt, &scrapedAt,
		&wsLastFile, &wsPos, &wsDur, &wsWatched, &wsPlayCount,
		&wsLastPlayed, &wsFav, &wsHidden, &wsUpdated,
		&showTitle, &showPoster, &showBackdrop,
		&epCount, &watchedEpCount, &maxWidth, &hdrFormats, &sourceKinds,
	)
	if err != nil {
		return MediaItem{}, err
	}
	item.WorkKey = nullStrPtr(workKey)
	item.ParentID = nullInt64Ptr(parentID)
	item.ShowID = nullInt64Ptr(showID)
	item.OriginalTitle = nullStrPtr(origTitle)
	item.Aliases = nullStrPtr(aliases)
	item.Year = nullIntPtr(year)
	item.ReleaseDate = nullStrPtr(relDate)
	item.Summary = nullStrPtr(summary)
	item.Tagline = nullStrPtr(tagline)
	item.ContentRating = nullStrPtr(contentRating)
	item.Studio = nullStrPtr(studio)
	item.Rating = nullFloatPtr(rating)
	item.RuntimeMs = nullInt64Ptr(runtimeMs)
	item.SeasonNumber = nullIntPtr(seasonNum)
	item.EpisodeNumber = nullIntPtr(epNum)
	item.AbsoluteNumber = nullIntPtr(absNum)
	item.PosterSource = nullStrPtr(poster)
	item.BackdropSource = nullStrPtr(backdrop)
	item.LogoSource = nullStrPtr(logo)
	item.TmdbID = nullStrPtr(tmdbID)
	item.ImdbID = nullStrPtr(imdbID)
	item.TvdbID = nullStrPtr(tvdbID)
	item.BangumiID = nullStrPtr(bangumiID)
	item.DoubanID = nullStrPtr(doubanID)
	item.AniListID = nullStrPtr(anilistID)
	item.MetadataSource = nullStrPtr(metaSource)
	item.Locked = lockedInt != 0
	item.SourceAddedAt = nullInt64Ptr(srcAdded)
	item.ScrapedAt = nullInt64Ptr(scrapedAt)
	item.ShowTitle = nullStrPtr(showTitle)
	item.ShowPoster = nullStrPtr(showPoster)
	item.ShowBackdrop = nullStrPtr(showBackdrop)
	item.EpisodeCount = epCount
	item.WatchedEpCount = watchedEpCount

	if wsUpdated.Valid {
		item.WatchState = &WatchState{
			ItemID:             item.ID,
			LastFileID:         nullInt64Ptr(wsLastFile),
			PositionMs:         wsPos.Int64,
			DurationMs:         nullInt64Ptr(wsDur),
			Watched:            wsWatched.Int64 != 0,
			PlayCount:          int(wsPlayCount.Int64),
			LastPlayedAt:       nullInt64Ptr(wsLastPlayed),
			Favorite:           wsFav.Int64 != 0,
			HiddenFromContinue: wsHidden.Int64 != 0,
			UpdatedAt:          wsUpdated.Int64,
		}
	}

	if maxWidth >= 3800 {
		item.QualityBadge = "4K"
	} else if maxWidth >= 1900 {
		item.QualityBadge = "1080P"
	} else if maxWidth >= 1200 {
		item.QualityBadge = "720P"
	}

	hdrLower := strings.ToLower(hdrFormats.String)
	switch {
	case strings.Contains(hdrLower, "dolbyvision"):
		item.HdrBadge = "DoVi"
	case strings.Contains(hdrLower, "hdr10+"):
		item.HdrBadge = "HDR10+"
	case strings.Contains(hdrLower, "hdr10"):
		item.HdrBadge = "HDR10"
	case strings.Contains(hdrLower, "hlg"):
		item.HdrBadge = "HLG"
	}

	if sourceKinds.Valid && sourceKinds.String != "" {
		for _, k := range strings.Split(sourceKinds.String, ",") {
			if k = strings.TrimSpace(k); k != "" {
				item.SourceKinds = append(item.SourceKinds, k)
			}
		}
	}
	return item, nil
}

func scanMediaFile(scanner interface{ Scan(dest ...any) error }) (MediaFile, error) {
	var f MediaFile
	var mountName, mountKind, remoteID, parsedJSON, versionLabel, lang sql.NullString
	var container, videoCodec, hdrFormat, streamsJSON sql.NullString
	var itemID, ownerFileID, size, modifiedAt, sourceCreatedAt, durationMs, probedAt sql.NullInt64
	var bitrate, width, height sql.NullInt64
	var matchLockedInt int

	err := scanner.Scan(
		&f.ID, &f.MountID, &mountName, &mountKind, &f.Path, &remoteID, &f.Role,
		&itemID, &ownerFileID, &size, &modifiedAt, &sourceCreatedAt,
		&f.MatchState, &matchLockedInt, &parsedJSON, &versionLabel, &lang,
		&durationMs, &bitrate, &container, &videoCodec, &width, &height, &hdrFormat,
		&streamsJSON, &probedAt, &f.SeenInScan, &f.AddedAt,
	)
	if err != nil {
		return MediaFile{}, err
	}
	f.MountName = mountName.String
	f.MountKind = mountKind.String
	if idx := strings.LastIndex(f.Path, "/"); idx >= 0 {
		f.FileName = f.Path[idx+1:]
	} else {
		f.FileName = f.Path
	}
	f.RemoteID = nullStrPtr(remoteID)
	f.ItemID = nullInt64Ptr(itemID)
	f.OwnerFileID = nullInt64Ptr(ownerFileID)
	f.Size = nullInt64Ptr(size)
	f.ModifiedAt = nullInt64Ptr(modifiedAt)
	f.SourceCreatedAt = nullInt64Ptr(sourceCreatedAt)
	f.MatchLocked = matchLockedInt != 0
	f.ParsedJSON = nullStrPtr(parsedJSON)
	f.VersionLabel = nullStrPtr(versionLabel)
	f.Language = nullStrPtr(lang)
	f.DurationMs = nullInt64Ptr(durationMs)
	f.BitrateKbps = nullIntPtr(bitrate)
	f.Container = nullStrPtr(container)
	f.VideoCodec = nullStrPtr(videoCodec)
	f.Width = nullIntPtr(width)
	f.Height = nullIntPtr(height)
	f.HdrFormat = nullStrPtr(hdrFormat)
	f.StreamsJSON = nullStrPtr(streamsJSON)
	f.ProbedAt = nullInt64Ptr(probedAt)
	if f.StreamsJSON != nil && *f.StreamsJSON != "" {
		var parsed []ProbedStream
		if json.Unmarshal([]byte(*f.StreamsJSON), &parsed) == nil {
			f.Streams = parsed
		}
	}
	return f, nil
}

const mediaFileSelectCols = `
	SELECT mf.id, mf.mount_id, COALESCE(m.name, ''), COALESCE(m.kind, ''), mf.path, mf.remote_id, mf.role,
		mf.item_id, mf.owner_file_id, mf.size, mf.modified_at, mf.source_created_at,
		mf.match_state, mf.match_locked, mf.parsed_json, mf.version_label, mf.language,
		mf.duration_ms, mf.bitrate_kbps, mf.container, mf.video_codec, mf.width, mf.height, mf.hdr_format,
		mf.streams_json, mf.probed_at, mf.seen_in_scan, mf.added_at
	FROM media_files mf
	LEFT JOIN mounts m ON m.id = mf.mount_id`

func (s *Store) GetMediaItem(id int64) (MediaItem, error) {
	row := s.ReadDB().QueryRow(mediaItemBaseSelect+` WHERE mi.id = ?`, id)
	item, err := scanMediaItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaItem{}, ErrNotFound
	}
	return item, err
}

func (s *Store) GetMediaFile(id int64) (MediaFile, error) {
	row := s.ReadDB().QueryRow(mediaFileSelectCols+` WHERE mf.id = ?`, id)
	f, err := scanMediaFile(row)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaFile{}, ErrNotFound
	}
	return f, err
}

func (s *Store) GetFilesForItem(itemID int64) ([]MediaFile, error) {
	rows, err := s.ReadDB().Query(mediaFileSelectCols+`
		WHERE mf.item_id = ? AND mf.role = 'video'
		ORDER BY CASE COALESCE(m.kind, '')
			WHEN 'local' THEN 0
			WHEN 'smb' THEN 1
			WHEN 'webdav' THEN 2
			WHEN 'quark' THEN 3
			ELSE 4
		END, COALESCE(mf.width, 0) DESC, mf.id ASC`,
		itemID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MediaFile, 0)
	for rows.Next() {
		f, err := scanMediaFile(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (s *Store) GetSubtitlesForItem(itemID int64) ([]MediaFile, error) {
	rows, err := s.ReadDB().Query(mediaFileSelectCols+`
		WHERE mf.role = 'subtitle' AND mf.owner_file_id IN (
			SELECT vf.id FROM media_files vf WHERE vf.item_id = ? AND vf.role = 'video'
		)
		ORDER BY mf.language ASC, mf.path ASC`,
		itemID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MediaFile, 0)
	for rows.Next() {
		f, err := scanMediaFile(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (s *Store) QueryLibrary(q LibraryQuery) (LibraryPage, error) {
	where := make([]string, 0)
	args := make([]any, 0)

	if q.LibraryType != "" && q.LibraryType != "all" {
		where = append(where, `mi.library_type = ?`)
		args = append(args, q.LibraryType)
	} else {
		where = append(where, `mi.library_type != 'pending'`)
	}

	if q.Kind != "" {
		where = append(where, `mi.kind = ?`)
		args = append(args, q.Kind)
	} else {
		where = append(where, `mi.kind IN ('movie', 'show')`)
	}

	// Video-file filters reuse itemVideoFilesSubquery so they stay index-driven.
	videoFileExists := func(cond string) string {
		return `EXISTS (SELECT 1 FROM ` + itemVideoFilesSubquery + ` vf WHERE ` + cond + `)`
	}
	if q.MountID != "" {
		where = append(where, videoFileExists(`vf.mount_id = ?`))
		args = append(args, q.MountID)
	}
	if q.GenreID > 0 {
		where = append(where, `EXISTS (SELECT 1 FROM item_genres ig WHERE ig.item_id = mi.id AND ig.genre_id = ?)`)
		args = append(args, q.GenreID)
	}
	if q.Year > 0 {
		where = append(where, `mi.year = ?`)
		args = append(args, q.Year)
	}
	switch strings.ToLower(strings.TrimSpace(q.Quality)) {
	case "4k":
		where = append(where, videoFileExists(`COALESCE(vf.width, 0) >= 3800`))
	case "1080p":
		where = append(where, videoFileExists(`COALESCE(vf.width, 0) >= 1900 AND COALESCE(vf.width, 0) < 3800`))
	case "hdr":
		where = append(where, videoFileExists(`vf.hdr_format IS NOT NULL AND vf.hdr_format != ''`))
	case "dv":
		where = append(where, videoFileExists(`LOWER(COALESCE(vf.hdr_format, '')) = 'dolbyvision'`))
	}
	if q.Watched != nil {
		watchedExpr := `(CASE WHEN mi.kind = 'show' THEN (
			(SELECT COUNT(*) FROM media_items e WHERE e.kind = 'episode' AND e.show_id = mi.id) > 0 AND
			(SELECT COUNT(*) FROM media_items e WHERE e.kind = 'episode' AND e.show_id = mi.id) =
			(SELECT COUNT(*) FROM media_items e JOIN watch_states ews ON ews.item_id = e.id WHERE e.kind = 'episode' AND e.show_id = mi.id AND ews.watched = 1)
		) ELSE COALESCE(ws.watched, 0) = 1 END)`
		if *q.Watched {
			where = append(where, watchedExpr)
		} else {
			where = append(where, `NOT `+watchedExpr)
		}
	}
	if q.Favorite {
		where = append(where, `COALESCE(ws.favorite, 0) = 1`)
	}
	if letter := strings.ToUpper(strings.TrimSpace(q.Letter)); letter != "" {
		if letter == "#" {
			where = append(where, `UPPER(SUBSTR(mi.sort_title, 1, 1)) NOT BETWEEN 'A' AND 'Z'`)
		} else if len(letter) == 1 && letter[0] >= 'A' && letter[0] <= 'Z' {
			where = append(where, `UPPER(SUBSTR(mi.sort_title, 1, 1)) = ?`)
			args = append(args, letter)
		}
	}
	if sText := strings.TrimSpace(q.Search); sText != "" {
		pat := likeEscapePattern(sText)
		where = append(where, `(mi.title LIKE ? ESCAPE '\' OR COALESCE(mi.original_title,'') LIKE ? ESCAPE '\' OR COALESCE(mi.aliases,'') LIKE ? ESCAPE '\')`)
		args = append(args, pat, pat, pat)
	}

	whereClause := ""
	if len(where) > 0 {
		whereClause = " WHERE " + strings.Join(where, " AND ")
	}

	var total int
	if err := s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items mi LEFT JOIN watch_states ws ON ws.item_id = mi.id`+whereClause, args...).Scan(&total); err != nil {
		return LibraryPage{}, err
	}

	dir := "ASC"
	if strings.EqualFold(q.Order, "desc") {
		dir = "DESC"
	}
	var orderBy string
	switch q.Sort {
	case "title":
		orderBy = fmt.Sprintf(`mi.sort_title %s, mi.id %s`, dir, dir)
	case "year":
		orderBy = fmt.Sprintf(`COALESCE(mi.year, 0) %s, mi.sort_title ASC`, dir)
	case "release_date":
		orderBy = fmt.Sprintf(`COALESCE(mi.release_date, '') %s, mi.sort_title ASC`, dir)
	case "rating":
		orderBy = fmt.Sprintf(`COALESCE(mi.rating, 0) %s, mi.sort_title ASC`, dir)
	case "last_played":
		orderBy = fmt.Sprintf(`COALESCE(ws.last_played_at, 0) %s, mi.sort_title ASC`, dir)
	default: // added_at
		if q.Order == "" {
			dir = "DESC"
		}
		orderBy = fmt.Sprintf(`COALESCE(mi.source_added_at, mi.added_at) %s, mi.id %s`, dir, dir)
	}

	limit := q.Limit
	if limit <= 0 || limit > 200 {
		limit = 60
	}
	offset := q.Offset
	if offset < 0 {
		offset = 0
	}

	querySQL := mediaItemBaseSelect + whereClause + ` ORDER BY ` + orderBy + ` LIMIT ? OFFSET ?`
	queryArgs := append(append([]any{}, args...), limit, offset)
	rows, err := s.ReadDB().Query(querySQL, queryArgs...)
	if err != nil {
		return LibraryPage{}, err
	}
	defer rows.Close()

	items := make([]MediaItem, 0)
	for rows.Next() {
		item, err := scanMediaItem(rows)
		if err != nil {
			return LibraryPage{}, err
		}
		items = append(items, item)
	}
	return LibraryPage{
		Items:  items,
		Total:  total,
		Offset: offset,
		Limit:  limit,
	}, rows.Err()
}

func (s *Store) GetLibraryFacets(libraryType string) (LibraryFacets, error) {
	facets := LibraryFacets{
		Genres:  make([]Genre, 0),
		Years:   make([]int, 0),
		Mounts:  make([]MountOption, 0),
		Letters: make([]string, 0),
	}

	shelfFilter := `mi.library_type != 'pending'`
	args := []any{}
	if libraryType != "" && libraryType != "all" {
		shelfFilter = `mi.library_type = ?`
		args = append(args, libraryType)
	}

	gRows, err := s.ReadDB().Query(`
		SELECT g.id, g.name, COUNT(DISTINCT mi.id) AS cnt
		FROM genres g
		JOIN item_genres ig ON ig.genre_id = g.id
		JOIN media_items mi ON mi.id = ig.item_id
		WHERE mi.kind IN ('movie', 'show') AND `+shelfFilter+`
		GROUP BY g.id, g.name
		ORDER BY cnt DESC, g.name ASC`,
		args...,
	)
	if err != nil {
		return facets, err
	}
	for gRows.Next() {
		var g Genre
		if err := gRows.Scan(&g.ID, &g.Name, &g.Count); err == nil {
			facets.Genres = append(facets.Genres, g)
		}
	}
	gRows.Close()

	yRows, err := s.ReadDB().Query(`
		SELECT DISTINCT mi.year
		FROM media_items mi
		WHERE mi.kind IN ('movie', 'show') AND mi.year IS NOT NULL AND `+shelfFilter+`
		ORDER BY mi.year DESC`,
		args...,
	)
	if err != nil {
		return facets, err
	}
	for yRows.Next() {
		var y int
		if err := yRows.Scan(&y); err == nil {
			facets.Years = append(facets.Years, y)
		}
	}
	yRows.Close()

	mRows, err := s.ReadDB().Query(`SELECT id, name, kind FROM mounts ORDER BY created_at ASC`)
	if err == nil {
		for mRows.Next() {
			var mo MountOption
			if err := mRows.Scan(&mo.ID, &mo.Name, &mo.Kind); err == nil {
				facets.Mounts = append(facets.Mounts, mo)
			}
		}
		mRows.Close()
	}

	lRows, err := s.ReadDB().Query(`
		SELECT DISTINCT CASE
			WHEN UPPER(SUBSTR(mi.sort_title, 1, 1)) BETWEEN 'A' AND 'Z' THEN UPPER(SUBSTR(mi.sort_title, 1, 1))
			ELSE '#'
		END AS l
		FROM media_items mi
		WHERE mi.kind IN ('movie', 'show') AND `+shelfFilter+`
		ORDER BY l ASC`,
		args...,
	)
	if err == nil {
		for lRows.Next() {
			var l string
			if err := lRows.Scan(&l); err == nil && l != "" {
				facets.Letters = append(facets.Letters, l)
			}
		}
		lRows.Close()
	}

	return facets, nil
}

func (s *Store) GetHomeData() (HomePayload, error) {
	out := HomePayload{
		Hero:             make([]MediaItem, 0),
		ContinueWatching: make([]MediaItem, 0),
		RecentAll:        make([]MediaItem, 0),
		Shelves:          make([]HomeShelf, 0),
		Counts:           make(map[string]int64),
	}

	// Counts per shelf
	cRows, err := s.ReadDB().Query(`
		SELECT library_type, COUNT(*)
		FROM media_items
		WHERE kind IN ('movie', 'show')
		GROUP BY library_type`,
	)
	if err != nil {
		return out, err
	}
	for cRows.Next() {
		var lt string
		var cnt int64
		if err := cRows.Scan(&lt, &cnt); err == nil {
			out.Counts[lt] = cnt
		}
	}
	cRows.Close()
	out.UnmatchedCount = out.Counts[ShelfPending]
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM mounts`).Scan(&out.MountCount)

	// Hero: latest matched items with backdrop
	hRows, err := s.ReadDB().Query(mediaItemBaseSelect + `
		WHERE mi.kind IN ('movie', 'show')
		  AND mi.library_type != 'pending'
		  AND COALESCE(mi.backdrop_source, '') != ''
		ORDER BY COALESCE(mi.rating, 0) DESC, COALESCE(mi.source_added_at, mi.added_at) DESC
		LIMIT 6`,
	)
	if err == nil {
		for hRows.Next() {
			if item, err := scanMediaItem(hRows); err == nil {
				out.Hero = append(out.Hero, item)
			}
		}
		hRows.Close()
	}

	// Continue watching: in-progress movies and episodes, plus next-up episodes for recently watched shows.
	cwRows, err := s.ReadDB().Query(mediaItemBaseSelect + `
		LEFT JOIN watch_states sws ON sws.item_id = mi.show_id
		WHERE mi.kind IN ('movie', 'episode')
		  AND ws.position_ms > 0
		  AND COALESCE(ws.watched, 0) = 0
		  AND COALESCE(ws.hidden_from_continue, 0) = 0
		  AND COALESCE(sws.hidden_from_continue, 0) = 0
		ORDER BY COALESCE(ws.last_played_at, ws.updated_at) DESC
		LIMIT 20`,
	)
	seenShows := make(map[int64]bool)
	if err == nil {
		for cwRows.Next() {
			if item, err := scanMediaItem(cwRows); err == nil {
				out.ContinueWatching = append(out.ContinueWatching, item)
				if item.ShowID != nil {
					seenShows[*item.ShowID] = true
				}
			}
		}
		cwRows.Close()
	}

	// Also surface next-up episode for shows recently finished an episode
	nextUpRows, err := s.ReadDB().Query(`
		SELECT mi.show_id, MAX(COALESCE(ws.last_played_at, ws.updated_at)) AS lp
		FROM media_items mi
		JOIN watch_states ws ON ws.item_id = mi.id
		LEFT JOIN watch_states sws ON sws.item_id = mi.show_id
		WHERE mi.kind = 'episode' AND mi.show_id IS NOT NULL
		  AND COALESCE(ws.watched, 0) = 1
		  AND COALESCE(sws.hidden_from_continue, 0) = 0
		GROUP BY mi.show_id
		ORDER BY lp DESC
		LIMIT 12`,
	)
	if err == nil {
		type candidateShow struct{ id int64 }
		var cand []candidateShow
		for nextUpRows.Next() {
			var sid, lp int64
			if nextUpRows.Scan(&sid, &lp) == nil && !seenShows[sid] {
				cand = append(cand, candidateShow{id: sid})
			}
		}
		nextUpRows.Close()
		for _, c := range cand {
			if len(out.ContinueWatching) >= 20 {
				break
			}
			if ep, err := s.FindOnDeckEpisode(c.id); err == nil && ep != nil {
				if ep.WatchState == nil || !ep.WatchState.Watched {
					out.ContinueWatching = append(out.ContinueWatching, *ep)
				}
			}
		}
	}

	// Recent all
	recentPage, err := s.QueryLibrary(LibraryQuery{Sort: "added_at", Order: "desc", Limit: 16})
	if err == nil {
		out.RecentAll = recentPage.Items
	}

	shelfTitles := map[string]string{
		ShelfMovie:       "最新电影",
		ShelfShow:        "最新剧集",
		ShelfAnime:       "最新动漫",
		ShelfVariety:     "最新综艺",
		ShelfDocumentary: "最新纪录片",
	}
	for _, shelf := range AllShelves {
		page, err := s.QueryLibrary(LibraryQuery{
			LibraryType: shelf,
			Sort:        "added_at",
			Order:       "desc",
			Limit:       14,
		})
		if err == nil && len(page.Items) > 0 {
			out.Shelves = append(out.Shelves, HomeShelf{
				Key:   shelf,
				Title: shelfTitles[shelf],
				Items: page.Items,
			})
		}
	}

	return out, nil
}

func (s *Store) FindOnDeckEpisode(showID int64) (*MediaItem, error) {
	// 1. Most recently partially watched episode
	row := s.ReadDB().QueryRow(mediaItemBaseSelect+`
		WHERE mi.kind = 'episode' AND mi.show_id = ?
		  AND COALESCE(ws.position_ms, 0) > 0 AND COALESCE(ws.watched, 0) = 0
		ORDER BY COALESCE(ws.last_played_at, ws.updated_at) DESC
		LIMIT 1`, showID)
	if ep, err := scanMediaItem(row); err == nil {
		return &ep, nil
	}

	// 2. First unwatched regular (season > 0) episode
	row = s.ReadDB().QueryRow(mediaItemBaseSelect+`
		WHERE mi.kind = 'episode' AND mi.show_id = ?
		  AND COALESCE(ws.watched, 0) = 0
		ORDER BY CASE WHEN COALESCE(mi.season_number, 1) > 0 THEN 0 ELSE 1 END,
			COALESCE(mi.season_number, 1) ASC, COALESCE(mi.episode_number, 0) ASC, mi.id ASC
		LIMIT 1`, showID)
	if ep, err := scanMediaItem(row); err == nil {
		return &ep, nil
	}

	// 3. Fallback to first episode
	row = s.ReadDB().QueryRow(mediaItemBaseSelect+`
		WHERE mi.kind = 'episode' AND mi.show_id = ?
		ORDER BY CASE WHEN COALESCE(mi.season_number, 1) > 0 THEN 0 ELSE 1 END,
			COALESCE(mi.season_number, 1) ASC, COALESCE(mi.episode_number, 0) ASC, mi.id ASC
		LIMIT 1`, showID)
	if ep, err := scanMediaItem(row); err == nil {
		return &ep, nil
	}
	return nil, nil
}

func (s *Store) GetItemDetail(id int64) (ItemDetail, error) {
	item, err := s.GetMediaItem(id)
	if err != nil {
		return ItemDetail{}, err
	}
	detail := ItemDetail{
		Item:        item,
		Files:       make([]MediaFile, 0),
		Subtitles:   make([]MediaFile, 0),
		Seasons:     make([]MediaItem, 0),
		Episodes:    make([]MediaItem, 0),
		Genres:      make([]Genre, 0),
		Credits:     make([]Credit, 0),
		Collections: make([]MediaList, 0),
		Similar:     make([]MediaItem, 0),
	}

	if item.ParentID != nil {
		if p, err := s.GetMediaItem(*item.ParentID); err == nil {
			detail.Parent = &p
		}
	}
	if item.ShowID != nil {
		if sh, err := s.GetMediaItem(*item.ShowID); err == nil {
			detail.Show = &sh
		}
	}

	if item.Kind == KindMovie || item.Kind == KindEpisode {
		if files, err := s.GetFilesForItem(item.ID); err == nil {
			detail.Files = files
		}
		if subs, err := s.GetSubtitlesForItem(item.ID); err == nil {
			detail.Subtitles = subs
		}
	}

	if item.Kind == KindShow {
		sRows, err := s.ReadDB().Query(mediaItemBaseSelect+`
			WHERE mi.kind = 'season' AND mi.parent_id = ?
			ORDER BY CASE WHEN COALESCE(mi.season_number, 1) > 0 THEN 0 ELSE 1 END, COALESCE(mi.season_number, 0) ASC`,
			item.ID,
		)
		if err == nil {
			for sRows.Next() {
				if se, err := scanMediaItem(sRows); err == nil {
					detail.Seasons = append(detail.Seasons, se)
				}
			}
			sRows.Close()
		}
		detail.Episodes, _ = s.GetEpisodesByShow(item.ID, nil)
		detail.OnDeckEpisode, _ = s.FindOnDeckEpisode(item.ID)
	} else if item.Kind == KindSeason {
		sNum := 1
		if item.SeasonNumber != nil {
			sNum = *item.SeasonNumber
		}
		showID := item.ParentID
		if showID != nil {
			detail.Episodes, _ = s.GetEpisodesByShow(*showID, &sNum)
		}
	} else if item.Kind == KindEpisode && item.ShowID != nil {
		eps, err := s.GetEpisodesByShow(*item.ShowID, nil)
		if err == nil {
			for i, ep := range eps {
				if ep.ID == item.ID {
					if i > 0 {
						prev := eps[i-1]
						detail.PrevEpisode = &prev
					}
					if i+1 < len(eps) {
						next := eps[i+1]
						detail.NextEpisode = &next
					}
					break
				}
			}
		}
	}

	// Genres & Credits come from the root show for episodes/seasons
	metaTargetID := item.ID
	if item.ShowID != nil {
		metaTargetID = *item.ShowID
	}
	gRows, err := s.ReadDB().Query(`
		SELECT g.id, g.name FROM genres g
		JOIN item_genres ig ON ig.genre_id = g.id
		WHERE ig.item_id = ? ORDER BY g.name ASC`, metaTargetID)
	if err == nil {
		for gRows.Next() {
			var g Genre
			if gRows.Scan(&g.ID, &g.Name) == nil {
				detail.Genres = append(detail.Genres, g)
			}
		}
		gRows.Close()
	}

	cRows, err := s.ReadDB().Query(`
		SELECT p.id, p.name, p.provider, p.external_id, p.photo_source, p.biography, p.birthday, p.department, p.place_of_birth,
			ic.job, ic.character, ic.sort_order
		FROM item_credits ic
		JOIN people p ON p.id = ic.person_id
		WHERE ic.item_id = ?
		ORDER BY CASE ic.job WHEN 'director' THEN 0 WHEN 'writer' THEN 1 ELSE 2 END, ic.sort_order ASC, p.id ASC`,
		metaTargetID,
	)
	if err == nil {
		for cRows.Next() {
			var p Person
			var c Credit
			var extID, photo, bio, bday, dept, pob, char sql.NullString
			if cRows.Scan(&p.ID, &p.Name, &p.Provider, &extID, &photo, &bio, &bday, &dept, &pob, &c.Job, &char, &c.SortOrder) == nil {
				p.ExternalID = nullStrPtr(extID)
				p.PhotoSource = nullStrPtr(photo)
				p.Biography = nullStrPtr(bio)
				p.Birthday = nullStrPtr(bday)
				p.Department = nullStrPtr(dept)
				p.PlaceOfBirth = nullStrPtr(pob)
				c.Person = p
				c.Character = nullStrPtr(char)
				detail.Credits = append(detail.Credits, c)
			}
		}
		cRows.Close()
	}

	// Collections containing this item (or its root show)
	lRows, err := s.ReadDB().Query(`
		SELECT l.id, l.kind, l.title, l.summary, l.poster_source, l.tmdb_id, l.created_at, l.updated_at,
			(SELECT COUNT(*) FROM list_items li2 WHERE li2.list_id = l.id)
		FROM lists l
		JOIN list_items li ON li.list_id = l.id
		WHERE li.item_id = ?
		ORDER BY l.kind ASC, l.title ASC`,
		metaTargetID,
	)
	if err == nil {
		for lRows.Next() {
			var lst MediaList
			var sum, poster, tid sql.NullString
			if lRows.Scan(&lst.ID, &lst.Kind, &lst.Title, &sum, &poster, &tid, &lst.CreatedAt, &lst.UpdatedAt, &lst.ItemCount) == nil {
				lst.Summary = nullStrPtr(sum)
				lst.PosterSource = nullStrPtr(poster)
				lst.TmdbID = nullStrPtr(tid)
				detail.Collections = append(detail.Collections, lst)
			}
		}
		lRows.Close()
	}

	// Similar items by shared genre on the same shelf
	if len(detail.Genres) > 0 {
		simRows, err := s.ReadDB().Query(mediaItemBaseSelect+`
			WHERE mi.id != ? AND mi.kind IN ('movie', 'show') AND mi.library_type = ?
			  AND EXISTS (
				SELECT 1 FROM item_genres ig1
				JOIN item_genres ig2 ON ig2.genre_id = ig1.genre_id
				WHERE ig1.item_id = ? AND ig2.item_id = mi.id
			  )
			ORDER BY COALESCE(mi.rating, 0) DESC, mi.added_at DESC
			LIMIT 12`,
			metaTargetID, item.LibraryType, metaTargetID,
		)
		if err == nil {
			for simRows.Next() {
				if sim, err := scanMediaItem(simRows); err == nil {
					detail.Similar = append(detail.Similar, sim)
				}
			}
			simRows.Close()
		}
	}

	// WorkPrefs
	workKey := item.WorkKey
	if detail.Show != nil && detail.Show.WorkKey != nil {
		workKey = detail.Show.WorkKey
	}
	if workKey != nil && *workKey != "" {
		if prefs, err := s.GetWorkPrefs(*workKey); err == nil {
			detail.WorkPrefs = &prefs
		}
	}

	return detail, nil
}

func (s *Store) GetEpisodesByShow(showID int64, seasonNumber *int) ([]MediaItem, error) {
	query := mediaItemBaseSelect + ` WHERE mi.kind = 'episode' AND mi.show_id = ?`
	args := []any{showID}
	if seasonNumber != nil {
		query += ` AND COALESCE(mi.season_number, 1) = ?`
		args = append(args, *seasonNumber)
	}
	query += ` ORDER BY CASE WHEN COALESCE(mi.season_number, 1) > 0 THEN 0 ELSE 1 END,
		COALESCE(mi.season_number, 1) ASC, COALESCE(mi.episode_number, 0) ASC, mi.id ASC`

	rows, err := s.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MediaItem, 0)
	for rows.Next() {
		ep, err := scanMediaItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, ep)
	}
	return out, rows.Err()
}

func (s *Store) QueryUnmatched(limit, offset int) ([]UnmatchedEntry, int, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	var total int
	if err := s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind IN ('movie', 'show') AND library_type = 'pending'`).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		WHERE mi.kind IN ('movie', 'show') AND mi.library_type = 'pending'
		ORDER BY mi.added_at DESC
		LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	items := make([]MediaItem, 0)
	for rows.Next() {
		item, err := scanMediaItem(rows)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, item)
	}
	rows.Close()

	out := make([]UnmatchedEntry, 0, len(items))
	for _, item := range items {
		var sample MediaFile
		var fileCount int
		if item.Kind == KindShow {
			_ = s.ReadDB().QueryRow(`
				SELECT COUNT(*) FROM media_files mf
				JOIN media_items ep ON ep.id = mf.item_id
				WHERE ep.show_id = ? AND mf.role = 'video'`, item.ID).Scan(&fileCount)
			row := s.ReadDB().QueryRow(mediaFileSelectCols+`
				JOIN media_items ep ON ep.id = mf.item_id
				WHERE ep.show_id = ? AND mf.role = 'video'
				ORDER BY mf.id ASC LIMIT 1`, item.ID)
			sample, _ = scanMediaFile(row)
		} else {
			_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files WHERE item_id = ? AND role = 'video'`, item.ID).Scan(&fileCount)
			row := s.ReadDB().QueryRow(mediaFileSelectCols+` WHERE mf.item_id = ? AND mf.role = 'video' ORDER BY mf.id ASC LIMIT 1`, item.ID)
			sample, _ = scanMediaFile(row)
		}
		out = append(out, UnmatchedEntry{
			Item:        item,
			SampleFile:  sample,
			FileCount:   fileCount,
			GuessedKind: item.Kind,
			GuessedYear: item.Year,
		})
	}
	return out, total, nil
}

type SearchResults struct {
	Movies   []MediaItem `json:"movies"`
	Shows    []MediaItem `json:"shows"`
	Episodes []MediaItem `json:"episodes"`
	People   []Person    `json:"people"`
}

func (s *Store) SearchAll(query string, limit int) (SearchResults, error) {
	res := SearchResults{
		Movies:   make([]MediaItem, 0),
		Shows:    make([]MediaItem, 0),
		Episodes: make([]MediaItem, 0),
		People:   make([]Person, 0),
	}
	q := strings.TrimSpace(query)
	if q == "" {
		return res, nil
	}
	if limit <= 0 || limit > 60 {
		limit = 24
	}
	pat := likeEscapePattern(q)

	mRows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		WHERE mi.kind = 'movie' AND (
			mi.title LIKE ? ESCAPE '\' OR COALESCE(mi.original_title,'') LIKE ? ESCAPE '\' OR COALESCE(mi.aliases,'') LIKE ? ESCAPE '\'
		)
		ORDER BY COALESCE(mi.rating, 0) DESC, mi.sort_title ASC LIMIT ?`, pat, pat, pat, limit)
	if err == nil {
		for mRows.Next() {
			if item, err := scanMediaItem(mRows); err == nil {
				res.Movies = append(res.Movies, item)
			}
		}
		mRows.Close()
	}

	sRows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		WHERE mi.kind = 'show' AND (
			mi.title LIKE ? ESCAPE '\' OR COALESCE(mi.original_title,'') LIKE ? ESCAPE '\' OR COALESCE(mi.aliases,'') LIKE ? ESCAPE '\'
		)
		ORDER BY COALESCE(mi.rating, 0) DESC, mi.sort_title ASC LIMIT ?`, pat, pat, pat, limit)
	if err == nil {
		for sRows.Next() {
			if item, err := scanMediaItem(sRows); err == nil {
				res.Shows = append(res.Shows, item)
			}
		}
		sRows.Close()
	}

	eRows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		WHERE mi.kind = 'episode' AND (
			mi.title LIKE ? ESCAPE '\' OR COALESCE(mi.summary,'') LIKE ? ESCAPE '\'
		)
		ORDER BY mi.id DESC LIMIT ?`, pat, pat, limit)
	if err == nil {
		for eRows.Next() {
			if item, err := scanMediaItem(eRows); err == nil {
				res.Episodes = append(res.Episodes, item)
			}
		}
		eRows.Close()
	}

	pRows, err := s.ReadDB().Query(`
		SELECT id, name, provider, external_id, photo_source, biography, birthday, department, place_of_birth
		FROM people
		WHERE name LIKE ? ESCAPE '\'
		ORDER BY CASE WHEN photo_source IS NOT NULL AND photo_source != '' THEN 0 ELSE 1 END, id ASC
		LIMIT ?`, pat, limit)
	if err == nil {
		for pRows.Next() {
			var p Person
			var ext, photo, bio, bday, dept, pob sql.NullString
			if pRows.Scan(&p.ID, &p.Name, &p.Provider, &ext, &photo, &bio, &bday, &dept, &pob) == nil {
				p.ExternalID = nullStrPtr(ext)
				p.PhotoSource = nullStrPtr(photo)
				p.Biography = nullStrPtr(bio)
				p.Birthday = nullStrPtr(bday)
				p.Department = nullStrPtr(dept)
				p.PlaceOfBirth = nullStrPtr(pob)
				res.People = append(res.People, p)
			}
		}
		pRows.Close()
	}

	return res, nil
}

type PersonDetail struct {
	Person Person      `json:"person"`
	Items  []MediaItem `json:"items"`
}

func (s *Store) GetPersonDetail(personID int64) (PersonDetail, error) {
	var p Person
	var ext, photo, bio, bday, dept, pob sql.NullString
	err := s.ReadDB().QueryRow(`
		SELECT id, name, provider, external_id, photo_source, biography, birthday, department, place_of_birth
		FROM people WHERE id = ?`, personID,
	).Scan(&p.ID, &p.Name, &p.Provider, &ext, &photo, &bio, &bday, &dept, &pob)
	if errors.Is(err, sql.ErrNoRows) {
		return PersonDetail{}, ErrNotFound
	}
	if err != nil {
		return PersonDetail{}, err
	}
	p.ExternalID = nullStrPtr(ext)
	p.PhotoSource = nullStrPtr(photo)
	p.Biography = nullStrPtr(bio)
	p.Birthday = nullStrPtr(bday)
	p.Department = nullStrPtr(dept)
	p.PlaceOfBirth = nullStrPtr(pob)

	items := make([]MediaItem, 0)
	rows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		WHERE mi.kind IN ('movie', 'show')
		  AND EXISTS (SELECT 1 FROM item_credits ic WHERE ic.item_id = mi.id AND ic.person_id = ?)
		ORDER BY COALESCE(mi.year, 0) DESC, mi.sort_title ASC`, personID)
	if err == nil {
		for rows.Next() {
			if item, err := scanMediaItem(rows); err == nil {
				items = append(items, item)
			}
		}
		rows.Close()
	}
	return PersonDetail{Person: p, Items: items}, nil
}

func (s *Store) GetWorkPrefs(workKey string) (WorkPrefs, error) {
	var wp WorkPrefs
	var introEn, credEn int
	var audioLang, subLang sql.NullString
	err := s.ReadDB().QueryRow(`
		SELECT work_key, intro_enabled, intro_start_ms, intro_end_ms,
			credits_enabled, credits_from_end_ms, keep_easter_egg_ms,
			preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
		FROM work_prefs WHERE work_key = ?`, workKey,
	).Scan(
		&wp.WorkKey, &introEn, &wp.IntroStartMs, &wp.IntroEndMs,
		&credEn, &wp.CreditsFromEndMs, &wp.KeepEasterEggMs,
		&audioLang, &subLang, &wp.PlaybackSpeed, &wp.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return WorkPrefs{WorkKey: workKey, PlaybackSpeed: 1.0}, nil
	}
	if err != nil {
		return WorkPrefs{}, err
	}
	wp.IntroEnabled = introEn != 0
	wp.CreditsEnabled = credEn != 0
	wp.PreferredAudioLang = audioLang.String
	wp.PreferredSubLang = subLang.String
	if wp.PlaybackSpeed <= 0 {
		wp.PlaybackSpeed = 1.0
	}
	return wp, nil
}

func (s *Store) ListMediaLists(kind string) ([]MediaList, error) {
	query := `
		SELECT l.id, l.kind, l.title, l.summary, l.poster_source, l.tmdb_id, l.created_at, l.updated_at,
			(SELECT COUNT(*) FROM list_items li WHERE li.list_id = l.id)
		FROM lists l`
	args := []any{}
	if kind != "" {
		query += ` WHERE l.kind = ?`
		args = append(args, kind)
	}
	query += ` ORDER BY l.updated_at DESC, l.id DESC`
	rows, err := s.ReadDB().Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]MediaList, 0)
	for rows.Next() {
		var lst MediaList
		var sum, poster, tid sql.NullString
		if err := rows.Scan(&lst.ID, &lst.Kind, &lst.Title, &sum, &poster, &tid, &lst.CreatedAt, &lst.UpdatedAt, &lst.ItemCount); err != nil {
			return nil, err
		}
		lst.Summary = nullStrPtr(sum)
		lst.PosterSource = nullStrPtr(poster)
		lst.TmdbID = nullStrPtr(tid)
		out = append(out, lst)
	}
	return out, rows.Err()
}

func (s *Store) GetMediaListDetail(listID int64) (MediaList, error) {
	var lst MediaList
	var sum, poster, tid sql.NullString
	err := s.ReadDB().QueryRow(`
		SELECT l.id, l.kind, l.title, l.summary, l.poster_source, l.tmdb_id, l.created_at, l.updated_at,
			(SELECT COUNT(*) FROM list_items li WHERE li.list_id = l.id)
		FROM lists l WHERE l.id = ?`, listID,
	).Scan(&lst.ID, &lst.Kind, &lst.Title, &sum, &poster, &tid, &lst.CreatedAt, &lst.UpdatedAt, &lst.ItemCount)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaList{}, ErrNotFound
	}
	if err != nil {
		return MediaList{}, err
	}
	lst.Summary = nullStrPtr(sum)
	lst.PosterSource = nullStrPtr(poster)
	lst.TmdbID = nullStrPtr(tid)
	lst.Items = make([]MediaItem, 0)

	rows, err := s.ReadDB().Query(mediaItemBaseSelect+`
		JOIN list_items li ON li.item_id = mi.id
		WHERE li.list_id = ?
		ORDER BY li.sort_order ASC, mi.year ASC, mi.sort_title ASC`, listID)
	if err == nil {
		for rows.Next() {
			if item, err := scanMediaItem(rows); err == nil {
				lst.Items = append(lst.Items, item)
			}
		}
		rows.Close()
	}
	return lst, nil
}

func (s *Store) GetSystemOverview() SystemOverview {
	var ov SystemOverview
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind = 'movie'`).Scan(&ov.Movies)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind = 'show'`).Scan(&ov.Shows)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind = 'episode'`).Scan(&ov.Episodes)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_files`).Scan(&ov.Files)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM lists WHERE kind = 'collection'`).Scan(&ov.Collections)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM lists WHERE kind = 'playlist'`).Scan(&ov.Playlists)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE kind IN ('movie', 'show') AND library_type = 'pending'`).Scan(&ov.Unmatched)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM mounts`).Scan(&ov.Mounts)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM people`).Scan(&ov.People)
	_ = s.ReadDB().QueryRow(`SELECT COUNT(*) FROM genres`).Scan(&ov.Genres)
	_ = s.ReadDB().QueryRow(`SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()`).Scan(&ov.DBBytes)
	return ov
}

// LookupFileByMountPath checks if a mount+path exists and returns its id/item_id/match_state.
func (s *Store) ListFilesByMount(mountID string) ([]MediaFile, error) {
	rows, err := s.ReadDB().Query(mediaFileSelectCols+` WHERE mf.mount_id = ? ORDER BY mf.path ASC`, mountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MediaFile, 0)
	for rows.Next() {
		f, err := scanMediaFile(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}
