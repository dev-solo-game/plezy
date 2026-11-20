package feed

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strconv"
	"strings"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/pathutil"
	"plezy/media_library/internal/userdata"
)

var (
	ErrUnauthorized = account.ErrUnauthorized
	ErrForbidden    = account.ErrForbidden
	ErrNotFound     = db.ErrNotFound
	ErrInvalidInput = db.ErrInvalidInput
)

type Service struct {
	store    *db.Store
	userData *userdata.Service
}

func NewService(store *db.Store, ud *userdata.Service) *Service {
	return &Service{
		store:    store,
		userData: ud,
	}
}

type ItemSummaryView struct {
	ID               int64    `json:"id"`
	WorkKey          string   `json:"work_key,omitempty"`
	Kind             string   `json:"kind"`
	LibraryType      string   `json:"library_type"`
	ParentID         *int64   `json:"parent_id,omitempty"`
	ShowID           *int64   `json:"show_id,omitempty"`
	Title            string   `json:"title"`
	SortTitle        string   `json:"sort_title,omitempty"`
	OriginalTitle    string   `json:"original_title,omitempty"`
	Year             *int     `json:"year,omitempty"`
	ReleaseDate      string   `json:"release_date,omitempty"`
	Summary          string   `json:"summary,omitempty"`
	ContentRating    string   `json:"content_rating,omitempty"`
	Rating           *float64 `json:"rating,omitempty"`
	RuntimeMs        *int64   `json:"runtime_ms,omitempty"`
	SeasonNumber     *int     `json:"season_number,omitempty"`
	EpisodeNumber    *int     `json:"episode_number,omitempty"`
	PosterSource     string   `json:"poster_source,omitempty"`
	PosterURL        string   `json:"poster_url,omitempty"`
	LocalPosterURL   string   `json:"local_poster_url,omitempty"`
	BackdropSource   string   `json:"backdrop_source,omitempty"`
	BackdropURL      string   `json:"backdrop_url,omitempty"`
	LocalBackdropURL string   `json:"local_backdrop_url,omitempty"`
	LogoSource       string   `json:"logo_source,omitempty"`
	LogoURL          string   `json:"logo_url,omitempty"`
	LocalLogoURL     string   `json:"local_logo_url,omitempty"`
	TmdbID           string   `json:"tmdb_id,omitempty"`
	ImdbID           string   `json:"imdb_id,omitempty"`
	Locked           bool     `json:"locked"`
	FileCount        int      `json:"file_count"`
	ChildCount       int      `json:"child_count"`
	Watched          bool     `json:"watched"`
	PositionMs       int64    `json:"position_ms"`
	IsFavorite       bool     `json:"is_favorite"`
	AddedAt          int64    `json:"added_at"`
	SourceAddedAt    *int64   `json:"source_added_at,omitempty"`
	UpdatedAt        int64    `json:"updated_at"`
}

type CreditView struct {
	PersonID    int64  `json:"person_id"`
	Name        string `json:"name"`
	Job         string `json:"job"`
	Character   string `json:"character,omitempty"`
	PhotoSource string `json:"photo_source,omitempty"`
	PhotoURL    string `json:"photo_url,omitempty"`
}

type SubtitleFileView struct {
	ID       int64  `json:"id"`
	SourceID string `json:"source_id"`
	Path     string `json:"path"`
	RemoteID string `json:"remote_id,omitempty"`
	Language string `json:"language,omitempty"`
	Size     *int64 `json:"size,omitempty"`
}

type MediaFileView struct {
	ID           int64              `json:"id"`
	SourceID     string             `json:"source_id"`
	SourceKind   string             `json:"source_kind"`
	SourceName   string             `json:"source_name"`
	Path         string             `json:"path"`
	RemoteID     string             `json:"remote_id,omitempty"`
	Size         *int64             `json:"size,omitempty"`
	MtimeS       *int64             `json:"mtime_s,omitempty"`
	VersionLabel string             `json:"version_label,omitempty"`
	DurationMs   *int64             `json:"duration_ms,omitempty"`
	BitrateKbps  *int               `json:"bitrate_kbps,omitempty"`
	Container    string             `json:"container,omitempty"`
	VideoCodec   string             `json:"video_codec,omitempty"`
	Width        *int               `json:"width,omitempty"`
	Height       *int               `json:"height,omitempty"`
	HdrFormat    string             `json:"hdr_format,omitempty"`
	Streams      []db.ProbedStream  `json:"streams,omitempty"`
	Subtitles    []SubtitleFileView `json:"subtitles,omitempty"`
	AddedAt      int64              `json:"added_at"`
	UpdatedAt    int64              `json:"updated_at"`
}

type ItemDetailView struct {
	ItemSummaryView
	Aliases   []string                    `json:"aliases,omitempty"`
	Tagline   string                      `json:"tagline,omitempty"`
	Studio    string                      `json:"studio,omitempty"`
	Genres    []string                    `json:"genres"`
	Credits   []CreditView                `json:"credits"`
	Files     []MediaFileView             `json:"files"`
	Children  []ItemSummaryView           `json:"children,omitempty"`
	Progress  *userdata.WatchProgressView `json:"progress,omitempty"`
	WorkPrefs *userdata.WorkPrefsView     `json:"work_prefs,omitempty"`
}

type SnapshotRequest struct {
	Kind        string
	LibraryType string
	SourceID    string
	ParentID    *int64
	Query       string
	Sort        string
	Page        int
	PageSize    int
}

type SnapshotResponse struct {
	SnapshotSeq int64             `json:"snapshot_seq"`
	Items       []ItemSummaryView `json:"items"`
	Total       int               `json:"total"`
	Page        int               `json:"page"`
	PageSize    int               `json:"page_size"`
	HasMore     bool              `json:"has_more"`
}

type ChangeEvent struct {
	Seq       int64  `json:"seq"`
	Entity    string `json:"entity"`
	EntityID  string `json:"entity_id"`
	Op        string `json:"op"`
	ChangedAt int64  `json:"changed_at"`
	Data      any    `json:"data,omitempty"`
}

type ChangesResponse struct {
	ResetRequired  bool          `json:"reset_required"`
	LatestSeq      int64         `json:"latest_seq"`
	MinRetainedSeq int64         `json:"min_retained_seq"`
	NextSinceSeq   int64         `json:"next_since_seq"`
	HasMore        bool          `json:"has_more"`
	Changes        []ChangeEvent `json:"changes"`
}

func (s *Service) GetSnapshot(p *account.Principal, req SnapshotRequest) (SnapshotResponse, error) {
	if p == nil {
		return SnapshotResponse{}, ErrUnauthorized
	}
	if req.Page <= 0 {
		req.Page = 1
	}
	if req.PageSize <= 0 {
		req.PageSize = 50
	}
	if req.PageSize > 200 {
		req.PageSize = 200
	}

	var snapshotSeq int64
	if err := s.store.ReadDB().QueryRow(`SELECT next_change_seq FROM households WHERE id = ?`, p.HouseholdID).Scan(&snapshotSeq); err != nil {
		return SnapshotResponse{}, err
	}

	var conds []string
	var args []any
	conds = append(conds, "mi.household_id = ?")
	args = append(args, p.HouseholdID)

	if req.ParentID != nil {
		conds = append(conds, "mi.parent_id = ?")
		args = append(args, *req.ParentID)
	} else {
		conds = append(conds, "mi.parent_id IS NULL")
	}

	if k := strings.ToLower(strings.TrimSpace(req.Kind)); k != "" {
		conds = append(conds, "mi.kind = ?")
		args = append(args, k)
	}
	if lt := strings.ToLower(strings.TrimSpace(req.LibraryType)); lt != "" {
		conds = append(conds, "mi.library_type = ?")
		args = append(args, lt)
	}
	if q := strings.TrimSpace(req.Query); q != "" {
		pat := "%" + q + "%"
		conds = append(conds, "(mi.title LIKE ? OR COALESCE(mi.original_title, '') LIKE ? OR COALESCE(mi.aliases, '') LIKE ?)")
		args = append(args, pat, pat, pat)
	}

	// Ensure item has at least one active video file in an active source (optionally matching req.SourceID).
	if srcID := strings.TrimSpace(req.SourceID); srcID != "" {
		conds = append(conds, `EXISTS (
			SELECT 1 FROM media_files mf
			JOIN sources src ON src.id = mf.source_id
			LEFT JOIN media_items child ON child.id = mf.item_id
			WHERE mf.household_id = mi.household_id
			  AND mf.state = 'active' AND mf.role = 'video'
			  AND src.status = 'active' AND mf.source_id = ?
			  AND (mf.item_id = mi.id OR child.parent_id = mi.id OR child.show_id = mi.id)
		)`)
		args = append(args, srcID)
	} else {
		conds = append(conds, `EXISTS (
			SELECT 1 FROM media_files mf
			JOIN sources src ON src.id = mf.source_id
			LEFT JOIN media_items child ON child.id = mf.item_id
			WHERE mf.household_id = mi.household_id
			  AND mf.state = 'active' AND mf.role = 'video'
			  AND src.status = 'active'
			  AND (mf.item_id = mi.id OR child.parent_id = mi.id OR child.show_id = mi.id)
		)`)
	}

	whereSQL := strings.Join(conds, " AND ")
	var total int
	if err := s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items mi WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return SnapshotResponse{}, err
	}

	orderSQL := "COALESCE(mi.source_added_at, mi.added_at) DESC, mi.id DESC"
	switch strings.ToLower(strings.TrimSpace(req.Sort)) {
	case "title":
		orderSQL = "mi.sort_title ASC, mi.id ASC"
	case "year":
		orderSQL = "COALESCE(mi.year, 0) DESC, mi.id DESC"
	case "rating":
		orderSQL = "COALESCE(mi.rating, 0) DESC, mi.id DESC"
	case "updated":
		orderSQL = "mi.updated_at DESC, mi.id DESC"
	}

	offset := (req.Page - 1) * req.PageSize
	qArgs := append(append([]any{}, args...), req.PageSize, offset)
	rows, err := s.store.ReadDB().Query(`
		SELECT mi.id, COALESCE(mi.work_key, ''), mi.kind, mi.library_type,
		       mi.parent_id, mi.show_id, mi.title, COALESCE(mi.sort_title, ''),
		       COALESCE(mi.original_title, ''), mi.year, COALESCE(mi.release_date, ''),
		       COALESCE(mi.summary, ''), COALESCE(mi.content_rating, ''), mi.rating, mi.runtime_ms,
		       mi.season_number, mi.episode_number,
		       COALESCE(mi.poster_source, ''), COALESCE(mi.backdrop_source, ''), COALESCE(mi.logo_source, ''),
		       COALESCE(mi.tmdb_id, ''), COALESCE(mi.imdb_id, ''), mi.locked,
		       mi.added_at, mi.source_added_at, mi.updated_at
		FROM media_items mi
		WHERE `+whereSQL+`
		ORDER BY `+orderSQL+`
		LIMIT ? OFFSET ?`,
		qArgs...,
	)
	if err != nil {
		return SnapshotResponse{}, err
	}
	defer rows.Close()

	items := make([]ItemSummaryView, 0)
	for rows.Next() {
		item, err := scanItemSummary(rows)
		if err != nil {
			return SnapshotResponse{}, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return SnapshotResponse{}, err
	}

	for i := range items {
		s.hydrateItemSummary(p.HouseholdID, p.MemberID, &items[i])
	}

	return SnapshotResponse{
		SnapshotSeq: snapshotSeq,
		Items:       items,
		Total:       total,
		Page:        req.Page,
		PageSize:    req.PageSize,
		HasMore:     offset+len(items) < total,
	}, nil
}

func (s *Service) GetChanges(p *account.Principal, sinceSeq int64, limit int) (ChangesResponse, error) {
	if p == nil {
		return ChangesResponse{}, ErrUnauthorized
	}
	if limit <= 0 {
		limit = 200
	}
	if limit > 1000 {
		limit = 1000
	}

	var latestSeq, minRetainedSeq int64
	if err := s.store.ReadDB().QueryRow(`
		SELECT next_change_seq, min_retained_seq
		FROM households WHERE id = ?`,
		p.HouseholdID,
	).Scan(&latestSeq, &minRetainedSeq); err != nil {
		return ChangesResponse{}, err
	}

	if sinceSeq < 0 || sinceSeq < minRetainedSeq || sinceSeq > latestSeq {
		return ChangesResponse{
			ResetRequired:  true,
			LatestSeq:      latestSeq,
			MinRetainedSeq: minRetainedSeq,
			NextSinceSeq:   latestSeq,
			HasMore:        false,
			Changes:        []ChangeEvent{},
		}, nil
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT seq, entity, entity_id, op, created_at
		FROM change_log
		WHERE household_id = ? AND seq > ? AND (member_id IS NULL OR member_id = ?)
		ORDER BY seq ASC
		LIMIT ?`,
		p.HouseholdID, sinceSeq, p.MemberID, limit+1,
	)
	if err != nil {
		return ChangesResponse{}, err
	}
	defer rows.Close()

	rawEvents := make([]ChangeEvent, 0)
	for rows.Next() {
		var ev ChangeEvent
		if err := rows.Scan(&ev.Seq, &ev.Entity, &ev.EntityID, &ev.Op, &ev.ChangedAt); err != nil {
			return ChangesResponse{}, err
		}
		rawEvents = append(rawEvents, ev)
	}
	if err := rows.Err(); err != nil {
		return ChangesResponse{}, err
	}

	hasMore := false
	if len(rawEvents) > limit {
		hasMore = true
		rawEvents = rawEvents[:limit]
	}

	nextSince := sinceSeq
	for i := range rawEvents {
		nextSince = rawEvents[i].Seq
		if rawEvents[i].Op == "upsert" {
			s.hydrateChangeEvent(p, &rawEvents[i])
		}
	}

	return ChangesResponse{
		ResetRequired:  false,
		LatestSeq:      latestSeq,
		MinRetainedSeq: minRetainedSeq,
		NextSinceSeq:   nextSince,
		HasMore:        hasMore,
		Changes:        rawEvents,
	}, nil
}

func (s *Service) GetItemDetail(p *account.Principal, itemID int64) (ItemDetailView, error) {
	if p == nil {
		return ItemDetailView{}, ErrUnauthorized
	}

	var (
		det         ItemDetailView
		aliasesJSON string
	)
	row := s.store.ReadDB().QueryRow(`
		SELECT mi.id, COALESCE(mi.work_key, ''), mi.kind, mi.library_type,
		       mi.parent_id, mi.show_id, mi.title, COALESCE(mi.sort_title, ''),
		       COALESCE(mi.original_title, ''), mi.year, COALESCE(mi.release_date, ''),
		       COALESCE(mi.summary, ''), COALESCE(mi.content_rating, ''), mi.rating, mi.runtime_ms,
		       mi.season_number, mi.episode_number,
		       COALESCE(mi.poster_source, ''), COALESCE(mi.backdrop_source, ''), COALESCE(mi.logo_source, ''),
		       COALESCE(mi.tmdb_id, ''), COALESCE(mi.imdb_id, ''), mi.locked,
		       mi.added_at, mi.source_added_at, mi.updated_at,
		       COALESCE(mi.aliases, '[]'), COALESCE(mi.tagline, ''), COALESCE(mi.studio, '')
		FROM media_items mi
		WHERE mi.id = ? AND mi.household_id = ?`,
		itemID, p.HouseholdID,
	)

	var (
		parentID, showID, runtimeMs, srcAdded sql.NullInt64
		year, sNum, eNum                      sql.NullInt64
		rating                                sql.NullFloat64
		locked                                int
	)
	err := row.Scan(
		&det.ID, &det.WorkKey, &det.Kind, &det.LibraryType,
		&parentID, &showID, &det.Title, &det.SortTitle,
		&det.OriginalTitle, &year, &det.ReleaseDate,
		&det.Summary, &det.ContentRating, &rating, &runtimeMs,
		&sNum, &eNum,
		&det.PosterSource, &det.BackdropSource, &det.LogoSource,
		&det.TmdbID, &det.ImdbID, &locked,
		&det.AddedAt, &srcAdded, &det.UpdatedAt,
		&aliasesJSON, &det.Tagline, &det.Studio,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return ItemDetailView{}, ErrNotFound
	}
	if err != nil {
		return ItemDetailView{}, err
	}
	populateNulls(&det.ItemSummaryView, parentID, showID, year, rating, runtimeMs, sNum, eNum, srcAdded, locked)
	_ = json.Unmarshal([]byte(aliasesJSON), &det.Aliases)

	if det.WorkKey == "" && det.ShowID != nil {
		_ = s.store.ReadDB().QueryRow(`SELECT COALESCE(work_key, '') FROM media_items WHERE id = ? AND household_id = ?`, *det.ShowID, p.HouseholdID).Scan(&det.WorkKey)
	}

	s.hydrateItemSummary(p.HouseholdID, p.MemberID, &det.ItemSummaryView)

	// Genres (from item or parent show)
	genreTargetID := det.ID
	if det.ShowID != nil && (det.Kind == db.KindSeason || det.Kind == db.KindEpisode) {
		genreTargetID = *det.ShowID
	}
	det.Genres = s.loadItemGenres(genreTargetID)
	det.Credits = s.loadItemCredits(genreTargetID)
	det.Files = s.loadItemFiles(p.HouseholdID, det.ID)

	// Children (seasons for show, episodes for season)
	if det.Kind == db.KindShow || det.Kind == db.KindSeason {
		det.Children = s.loadChildItems(p.HouseholdID, p.MemberID, det.ID, det.WorkKey)
	}

	// UserData progress & work prefs
	if s.userData != nil && det.WorkKey != "" {
		progKey := det.WorkKey
		if det.Kind == db.KindEpisode && det.SeasonNumber != nil && det.EpisodeNumber != nil {
			progKey = fmt.Sprintf("%s:s%d:e%d", det.WorkKey, *det.SeasonNumber, *det.EpisodeNumber)
		}
		if pv, pErr := s.userData.GetProgressByKey(p.HouseholdID, p.MemberID, progKey); pErr == nil {
			det.Progress = &pv
		}
		if wp, wErr := s.userData.LoadWorkPrefs(p.HouseholdID, p.MemberID, det.WorkKey); wErr == nil {
			det.WorkPrefs = &wp
		}
	}

	return det, nil
}

func (s *Service) hydrateItemSummary(householdID, memberID string, item *ItemSummaryView) {
	item.PosterURL = resolveArtworkURL(item.PosterSource)
	item.BackdropURL = resolveArtworkURL(item.BackdropSource)
	item.LogoURL = resolveArtworkURL(item.LogoSource)

	if strings.HasPrefix(item.PosterSource, "sidecar:") {
		item.LocalPosterURL = item.PosterURL
	}
	if strings.HasPrefix(item.BackdropSource, "sidecar:") {
		item.LocalBackdropURL = item.BackdropURL
	}
	if strings.HasPrefix(item.LogoSource, "sidecar:") {
		item.LocalLogoURL = item.LogoURL
	}

	// Count active video files & check local sibling artwork sidecars (G10 dual image URLs).
	var sampleSourceID, sampleVideoPath string
	rows, err := s.store.ReadDB().Query(`
		SELECT mf.source_id, mf.path
		FROM media_files mf
		JOIN sources src ON src.id = mf.source_id
		LEFT JOIN media_items child ON child.id = mf.item_id
		WHERE mf.household_id = ? AND mf.state = 'active' AND mf.role = 'video'
		  AND src.status = 'active'
		  AND (mf.item_id = ? OR child.parent_id = ? OR child.show_id = ?)
		ORDER BY mf.id ASC`,
		householdID, item.ID, item.ID, item.ID,
	)
	if err == nil {
		for rows.Next() {
			var sid, vp string
			if rows.Scan(&sid, &vp) == nil {
				item.FileCount++
				if sampleVideoPath == "" {
					sampleSourceID = sid
					sampleVideoPath = vp
				}
			}
		}
		_ = rows.Close()
	}

	if item.Kind == db.KindShow || item.Kind == db.KindSeason {
		_ = s.store.ReadDB().QueryRow(`
			SELECT COUNT(*) FROM media_items WHERE household_id = ? AND parent_id = ?`,
			householdID, item.ID,
		).Scan(&item.ChildCount)
	}

	if sampleVideoPath != "" && (item.LocalPosterURL == "" || item.LocalBackdropURL == "" || item.LocalLogoURL == "") {
		lp, lb, ll := s.findSiblingLocalArtworkURLs(householdID, sampleSourceID, sampleVideoPath, item.Kind)
		if item.LocalPosterURL == "" {
			item.LocalPosterURL = lp
		}
		if item.LocalBackdropURL == "" {
			item.LocalBackdropURL = lb
		}
		if item.LocalLogoURL == "" {
			item.LocalLogoURL = ll
		}
		if item.PosterURL == "" && item.LocalPosterURL != "" {
			item.PosterURL = item.LocalPosterURL
		}
		if item.BackdropURL == "" && item.LocalBackdropURL != "" {
			item.BackdropURL = item.LocalBackdropURL
		}
		if item.LogoURL == "" && item.LocalLogoURL != "" {
			item.LogoURL = item.LocalLogoURL
		}
	}

	// Member watch progress & favorite status
	wk := item.WorkKey
	if wk == "" && item.ShowID != nil {
		_ = s.store.ReadDB().QueryRow(`SELECT COALESCE(work_key, '') FROM media_items WHERE id = ? AND household_id = ?`, *item.ShowID, householdID).Scan(&wk)
	}
	if wk != "" && memberID != "" {
		var favCnt int
		_ = s.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM member_favorites WHERE member_id = ? AND work_key = ?`, memberID, wk).Scan(&favCnt)
		item.IsFavorite = favCnt > 0

		progKey := wk
		if item.Kind == db.KindEpisode && item.SeasonNumber != nil && item.EpisodeNumber != nil {
			progKey = fmt.Sprintf("%s:s%d:e%d", wk, *item.SeasonNumber, *item.EpisodeNumber)
		}
		var watched int
		var pos int64
		if err := s.store.ReadDB().QueryRow(`
			SELECT watched, position_ms FROM member_watch_progress
			WHERE member_id = ? AND progress_key = ?`,
			memberID, progKey,
		).Scan(&watched, &pos); err == nil {
			item.Watched = watched != 0
			item.PositionMs = pos
		}
	}
}

func (s *Service) findSiblingLocalArtworkURLs(householdID, sourceID, sampleVideoPath, itemKind string) (posterURL, backdropURL, logoURL string) {
	dir1 := pathutil.ParentPath(sampleVideoPath)
	dir2 := pathutil.ParentPath(dir1)
	rows, err := s.store.ReadDB().Query(`
		SELECT path, COALESCE(sidecar_sha256, '')
		FROM media_files
		WHERE household_id = ? AND source_id = ? AND role = 'artwork' AND state = 'active'
		  AND sidecar_sha256 IS NOT NULL AND sidecar_sha256 != ''`,
		householdID, sourceID,
	)
	if err != nil {
		return "", "", ""
	}
	defer rows.Close()

	for rows.Next() {
		var p, sha string
		if rows.Scan(&p, &sha) != nil || sha == "" {
			continue
		}
		pDir := pathutil.ParentPath(p)
		if pDir != dir1 && (itemKind != db.KindShow || pDir != dir2) {
			continue
		}
		baseLow := strings.ToLower(pathutil.BaseName(p))
		ext := path.Ext(baseLow)
		stem := strings.TrimSuffix(baseLow, ext)
		u := "/api/v1/sidecars/" + sha

		switch {
		case stem == "poster" || stem == "folder" || stem == "cover" || strings.HasSuffix(stem, "-poster"):
			if posterURL == "" {
				posterURL = u
			}
		case stem == "fanart" || stem == "backdrop" || strings.HasSuffix(stem, "-fanart") || strings.HasSuffix(stem, "-backdrop"):
			if backdropURL == "" {
				backdropURL = u
			}
		case stem == "clearlogo" || stem == "logo" || strings.HasSuffix(stem, "-clearlogo") || strings.HasSuffix(stem, "-logo"):
			if logoURL == "" {
				logoURL = u
			}
		}
	}
	return
}

func (s *Service) loadItemGenres(itemID int64) []string {
	rows, err := s.store.ReadDB().Query(`
		SELECT g.name
		FROM item_genres ig
		JOIN genres g ON g.id = ig.genre_id
		WHERE ig.item_id = ?
		ORDER BY g.name ASC`,
		itemID,
	)
	if err != nil {
		return []string{}
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var name string
		if rows.Scan(&name) == nil && name != "" {
			out = append(out, name)
		}
	}
	return out
}

func (s *Service) loadItemCredits(itemID int64) []CreditView {
	rows, err := s.store.ReadDB().Query(`
		SELECT p.id, p.name, ic.job, COALESCE(ic.character, ''), COALESCE(p.photo_source, '')
		FROM item_credits ic
		JOIN people p ON p.id = ic.person_id
		WHERE ic.item_id = ?
		ORDER BY ic.sort_order ASC, p.id ASC`,
		itemID,
	)
	if err != nil {
		return []CreditView{}
	}
	defer rows.Close()
	out := make([]CreditView, 0)
	for rows.Next() {
		var c CreditView
		if rows.Scan(&c.PersonID, &c.Name, &c.Job, &c.Character, &c.PhotoSource) == nil {
			c.PhotoURL = resolveArtworkURL(c.PhotoSource)
			out = append(out, c)
		}
	}
	return out
}

func (s *Service) loadItemFiles(householdID string, itemID int64) []MediaFileView {
	rows, err := s.store.ReadDB().Query(`
		SELECT mf.id, mf.source_id, src.kind, src.name, mf.path, COALESCE(mf.remote_id, ''),
		       mf.size, mf.mtime_s, COALESCE(mf.version_label, ''),
		       mf.duration_ms, mf.bitrate_kbps, COALESCE(mf.container, ''),
		       COALESCE(mf.video_codec, ''), mf.width, mf.height, COALESCE(mf.hdr_format, ''),
		       COALESCE(mf.streams_json, ''), mf.added_at, mf.updated_at
		FROM media_files mf
		JOIN sources src ON src.id = mf.source_id
		WHERE mf.household_id = ? AND mf.item_id = ? AND mf.role = 'video'
		  AND mf.state = 'active' AND src.status = 'active'
		ORDER BY mf.id ASC`,
		householdID, itemID,
	)
	if err != nil {
		return []MediaFileView{}
	}
	defer rows.Close()

	out := make([]MediaFileView, 0)
	for rows.Next() {
		var (
			f                  MediaFileView
			sz, mt, dur        sql.NullInt64
			br, w, h           sql.NullInt64
			streamsJSON        string
		)
		if err := rows.Scan(
			&f.ID, &f.SourceID, &f.SourceKind, &f.SourceName, &f.Path, &f.RemoteID,
			&sz, &mt, &f.VersionLabel,
			&dur, &br, &f.Container, &f.VideoCodec, &w, &h, &f.HdrFormat,
			&streamsJSON, &f.AddedAt, &f.UpdatedAt,
		); err != nil {
			continue
		}
		if sz.Valid {
			v := sz.Int64
			f.Size = &v
		}
		if mt.Valid {
			v := mt.Int64
			f.MtimeS = &v
		}
		if dur.Valid {
			v := dur.Int64
			f.DurationMs = &v
		}
		if br.Valid {
			v := int(br.Int64)
			f.BitrateKbps = &v
		}
		if w.Valid {
			v := int(w.Int64)
			f.Width = &v
		}
		if h.Valid {
			v := int(h.Int64)
			f.Height = &v
		}
		if streamsJSON != "" {
			_ = json.Unmarshal([]byte(streamsJSON), &f.Streams)
		}
		out = append(out, f)
	}

	for i := range out {
		out[i].Subtitles = s.loadVideoSubtitles(householdID, out[i].ID)
	}
	return out
}

func (s *Service) loadVideoSubtitles(householdID string, videoFileID int64) []SubtitleFileView {
	rows, err := s.store.ReadDB().Query(`
		SELECT id, source_id, path, COALESCE(remote_id, ''), COALESCE(language, ''), size
		FROM media_files
		WHERE household_id = ? AND owner_file_id = ? AND role = 'subtitle' AND state = 'active'
		ORDER BY path ASC`,
		householdID, videoFileID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var subs []SubtitleFileView
	for rows.Next() {
		var sf SubtitleFileView
		var sz sql.NullInt64
		if rows.Scan(&sf.ID, &sf.SourceID, &sf.Path, &sf.RemoteID, &sf.Language, &sz) == nil {
			if sz.Valid {
				v := sz.Int64
				sf.Size = &v
			}
			subs = append(subs, sf)
		}
	}
	return subs
}

func (s *Service) loadChildItems(householdID, memberID string, parentID int64, workKey string) []ItemSummaryView {
	rows, err := s.store.ReadDB().Query(`
		SELECT mi.id, COALESCE(mi.work_key, ''), mi.kind, mi.library_type,
		       mi.parent_id, mi.show_id, mi.title, COALESCE(mi.sort_title, ''),
		       COALESCE(mi.original_title, ''), mi.year, COALESCE(mi.release_date, ''),
		       COALESCE(mi.summary, ''), COALESCE(mi.content_rating, ''), mi.rating, mi.runtime_ms,
		       mi.season_number, mi.episode_number,
		       COALESCE(mi.poster_source, ''), COALESCE(mi.backdrop_source, ''), COALESCE(mi.logo_source, ''),
		       COALESCE(mi.tmdb_id, ''), COALESCE(mi.imdb_id, ''), mi.locked,
		       mi.added_at, mi.source_added_at, mi.updated_at
		FROM media_items mi
		WHERE mi.household_id = ? AND mi.parent_id = ?
		ORDER BY COALESCE(mi.season_number, 0) ASC, COALESCE(mi.episode_number, 0) ASC, mi.id ASC`,
		householdID, parentID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	out := make([]ItemSummaryView, 0)
	for rows.Next() {
		item, err := scanItemSummary(rows)
		if err == nil {
			if item.WorkKey == "" {
				item.WorkKey = workKey
			}
			out = append(out, item)
		}
	}
	for i := range out {
		s.hydrateItemSummary(householdID, memberID, &out[i])
	}
	return out
}

func (s *Service) hydrateChangeEvent(p *account.Principal, ev *ChangeEvent) {
	switch ev.Entity {
	case "item":
		itemID, err := strconv.ParseInt(ev.EntityID, 10, 64)
		if err != nil || itemID <= 0 {
			return
		}
		row := s.store.ReadDB().QueryRow(`
			SELECT mi.id, COALESCE(mi.work_key, ''), mi.kind, mi.library_type,
			       mi.parent_id, mi.show_id, mi.title, COALESCE(mi.sort_title, ''),
			       COALESCE(mi.original_title, ''), mi.year, COALESCE(mi.release_date, ''),
			       COALESCE(mi.summary, ''), COALESCE(mi.content_rating, ''), mi.rating, mi.runtime_ms,
			       mi.season_number, mi.episode_number,
			       COALESCE(mi.poster_source, ''), COALESCE(mi.backdrop_source, ''), COALESCE(mi.logo_source, ''),
			       COALESCE(mi.tmdb_id, ''), COALESCE(mi.imdb_id, ''), mi.locked,
			       mi.added_at, mi.source_added_at, mi.updated_at
			FROM media_items mi
			WHERE mi.id = ? AND mi.household_id = ?`,
			itemID, p.HouseholdID,
		)
		item, err := scanItemSummary(row)
		if err != nil {
			ev.Op = "delete"
			return
		}
		s.hydrateItemSummary(p.HouseholdID, p.MemberID, &item)
		if item.FileCount == 0 {
			ev.Op = "delete"
			return
		}
		ev.Data = item
	case "progress":
		if s.userData != nil {
			if pv, err := s.userData.GetProgressByKey(p.HouseholdID, p.MemberID, ev.EntityID); err == nil {
				ev.Data = pv
			} else {
				ev.Op = "delete"
			}
		}
	case "work_prefs":
		if s.userData != nil {
			if wp, err := s.userData.LoadWorkPrefs(p.HouseholdID, p.MemberID, ev.EntityID); err == nil {
				ev.Data = wp
			}
		}
	case "list":
		if s.userData != nil {
			if lv, err := s.userData.LoadListDetail(p.HouseholdID, p.MemberID, ev.EntityID); err == nil {
				ev.Data = lv
			} else {
				ev.Op = "delete"
			}
		}
	}
}

type summaryScanner interface {
	Scan(dest ...any) error
}

func scanItemSummary(r summaryScanner) (ItemSummaryView, error) {
	var (
		item                                  ItemSummaryView
		parentID, showID, runtimeMs, srcAdded sql.NullInt64
		year, sNum, eNum                      sql.NullInt64
		rating                                sql.NullFloat64
		locked                                int
	)
	err := r.Scan(
		&item.ID, &item.WorkKey, &item.Kind, &item.LibraryType,
		&parentID, &showID, &item.Title, &item.SortTitle,
		&item.OriginalTitle, &year, &item.ReleaseDate,
		&item.Summary, &item.ContentRating, &rating, &runtimeMs,
		&sNum, &eNum,
		&item.PosterSource, &item.BackdropSource, &item.LogoSource,
		&item.TmdbID, &item.ImdbID, &locked,
		&item.AddedAt, &srcAdded, &item.UpdatedAt,
	)
	if err != nil {
		return ItemSummaryView{}, err
	}
	populateNulls(&item, parentID, showID, year, rating, runtimeMs, sNum, eNum, srcAdded, locked)
	return item, nil
}

func populateNulls(
	item *ItemSummaryView,
	parentID, showID, year sql.NullInt64,
	rating sql.NullFloat64,
	runtimeMs, sNum, eNum, srcAdded sql.NullInt64,
	locked int,
) {
	item.Locked = locked != 0
	if parentID.Valid {
		v := parentID.Int64
		item.ParentID = &v
	}
	if showID.Valid {
		v := showID.Int64
		item.ShowID = &v
	}
	if year.Valid {
		v := int(year.Int64)
		item.Year = &v
	}
	if rating.Valid {
		v := rating.Float64
		item.Rating = &v
	}
	if runtimeMs.Valid {
		v := runtimeMs.Int64
		item.RuntimeMs = &v
	}
	if sNum.Valid {
		v := int(sNum.Int64)
		item.SeasonNumber = &v
	}
	if eNum.Valid {
		v := int(eNum.Int64)
		item.EpisodeNumber = &v
	}
	if srcAdded.Valid {
		v := srcAdded.Int64
		item.SourceAddedAt = &v
	}
}

func resolveArtworkURL(src string) string {
	s := strings.TrimSpace(src)
	if s == "" {
		return ""
	}
	if strings.HasPrefix(s, "sidecar:") {
		return "/api/v1/sidecars/" + strings.TrimPrefix(s, "sidecar:")
	}
	return "/api/v1/metadata/artwork?src=" + url.QueryEscape(s)
}
