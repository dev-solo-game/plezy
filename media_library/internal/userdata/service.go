package userdata

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/library"
)

var (
	ErrUnauthorized = account.ErrUnauthorized
	ErrForbidden    = account.ErrForbidden
	ErrNotFound     = db.ErrNotFound
	ErrInvalidInput = db.ErrInvalidInput
)

type Service struct {
	store *db.Store
	hub   *events.Hub
	nowFn func() time.Time
}

func NewService(store *db.Store, hub *events.Hub) *Service {
	return &Service{
		store: store,
		hub:   hub,
		nowFn: time.Now,
	}
}

func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
	}
}

type WatchProgressView struct {
	ProgressKey        string `json:"progress_key"`
	WorkKey            string `json:"work_key,omitempty"`
	SeasonNumber       int    `json:"season_number"`
	EpisodeNumber      int    `json:"episode_number"`
	LastFileID         *int64 `json:"last_file_id,omitempty"`
	PositionMs         int64  `json:"position_ms"`
	DurationMs         *int64 `json:"duration_ms,omitempty"`
	Watched            bool   `json:"watched"`
	PlayCount          int    `json:"play_count"`
	LastPlayedAt       *int64 `json:"last_played_at,omitempty"`
	HiddenFromContinue bool   `json:"hidden_from_continue"`
	UpdatedAt          int64  `json:"updated_at"`
}

type UpsertProgressRequest struct {
	ProgressKey        string `json:"progress_key,omitempty"`
	WorkKey            string `json:"work_key,omitempty"`
	SeasonNumber       *int   `json:"season_number,omitempty"`
	EpisodeNumber      *int   `json:"episode_number,omitempty"`
	FileID             *int64 `json:"file_id,omitempty"`
	PositionMs         int64  `json:"position_ms"`
	DurationMs         *int64 `json:"duration_ms,omitempty"`
	Watched            *bool  `json:"watched,omitempty"`
	PlayCount          *int   `json:"play_count,omitempty"`
	HiddenFromContinue *bool  `json:"hidden_from_continue,omitempty"`
}

type FavoriteView struct {
	WorkKey   string `json:"work_key"`
	CreatedAt int64  `json:"created_at"`
}

type WorkPrefsView struct {
	WorkKey            string  `json:"work_key"`
	IntroEnabled       bool    `json:"intro_enabled"`
	IntroStartMs       int64   `json:"intro_start_ms"`
	IntroEndMs         int64   `json:"intro_end_ms"`
	CreditsEnabled     bool    `json:"credits_enabled"`
	CreditsFromEndMs   int64   `json:"credits_from_end_ms"`
	KeepEasterEggMs    int64   `json:"keep_easter_egg_ms"`
	PreferredAudioLang string  `json:"preferred_audio_lang,omitempty"`
	PreferredSubLang   string  `json:"preferred_sub_lang,omitempty"`
	PlaybackSpeed      float64 `json:"playback_speed"`
	HouseholdUpdatedAt int64   `json:"household_updated_at,omitempty"`
	MemberUpdatedAt    int64   `json:"member_updated_at,omitempty"`
}

type HouseholdWorkPrefsInput struct {
	IntroEnabled     *bool  `json:"intro_enabled,omitempty"`
	IntroStartMs     *int64 `json:"intro_start_ms,omitempty"`
	IntroEndMs       *int64 `json:"intro_end_ms,omitempty"`
	CreditsEnabled   *bool  `json:"credits_enabled,omitempty"`
	CreditsFromEndMs *int64 `json:"credits_from_end_ms,omitempty"`
	KeepEasterEggMs  *int64 `json:"keep_easter_egg_ms,omitempty"`
}

type MemberWorkPrefsInput struct {
	PreferredAudioLang *string  `json:"preferred_audio_lang,omitempty"`
	PreferredSubLang   *string  `json:"preferred_sub_lang,omitempty"`
	PlaybackSpeed      *float64 `json:"playback_speed,omitempty"`
}

type ListView struct {
	ID           string `json:"id"`
	HouseholdID  string `json:"household_id"`
	MemberID     string `json:"member_id,omitempty"`
	Kind         string `json:"kind"`
	Title        string `json:"title"`
	Summary      string `json:"summary,omitempty"`
	PosterSource string `json:"poster_source,omitempty"`
	TmdbID       string `json:"tmdb_id,omitempty"`
	EntryCount   int    `json:"entry_count"`
	CreatedAt    int64  `json:"created_at"`
	UpdatedAt    int64  `json:"updated_at"`
}

type ListEntryView struct {
	ListID        string `json:"list_id"`
	EntryKey      string `json:"entry_key"`
	WorkKey       string `json:"work_key"`
	SeasonNumber  int    `json:"season_number"`
	EpisodeNumber int    `json:"episode_number"`
	SortOrder     int    `json:"sort_order"`
	AddedAt       int64  `json:"added_at"`
}

type ListDetailView struct {
	ListView
	Entries []ListEntryView `json:"entries"`
}

type CreateListRequest struct {
	Kind         string `json:"kind"` // collection | watchlist | custom
	Title        string `json:"title"`
	Summary      string `json:"summary,omitempty"`
	PosterSource string `json:"poster_source,omitempty"`
	TmdbID       string `json:"tmdb_id,omitempty"`
	Shared       bool   `json:"shared,omitempty"`
}

type UpdateListRequest struct {
	Title        *string `json:"title,omitempty"`
	Summary      *string `json:"summary,omitempty"`
	PosterSource *string `json:"poster_source,omitempty"`
}

type AddListEntryRequest struct {
	WorkKey       string `json:"work_key"`
	SeasonNumber  *int   `json:"season_number,omitempty"`
	EpisodeNumber *int   `json:"episode_number,omitempty"`
	SortOrder     *int   `json:"sort_order,omitempty"`
}

func (s *Service) UpsertProgress(p *account.Principal, req UpsertProgressRequest) (WatchProgressView, error) {
	if p == nil {
		return WatchProgressView{}, ErrUnauthorized
	}
	if req.PositionMs < 0 {
		return WatchProgressView{}, fmt.Errorf("%w: position_ms must be >= 0", ErrInvalidInput)
	}

	workKey := strings.TrimSpace(req.WorkKey)
	sNum := -1
	eNum := -1
	if req.SeasonNumber != nil {
		sNum = *req.SeasonNumber
	}
	if req.EpisodeNumber != nil {
		eNum = *req.EpisodeNumber
	}

	var progressKey string
	var workKeySQL sql.NullString
	if workKey != "" {
		progressKey = library.BuildWorkProgressKey(workKey, sNum, eNum)
		workKeySQL = sql.NullString{String: workKey, Valid: true}
	} else if req.FileID != nil && *req.FileID > 0 {
		// G3 unmatched file-keyed progress
		var cnt int
		if err := s.store.ReadDB().QueryRow(`
			SELECT COUNT(*) FROM media_files
			WHERE id = ? AND household_id = ? AND state != 'tombstoned'`,
			*req.FileID, p.HouseholdID,
		).Scan(&cnt); err != nil {
			return WatchProgressView{}, err
		}
		if cnt == 0 {
			return WatchProgressView{}, ErrNotFound
		}
		progressKey = fmt.Sprintf("file:%d", *req.FileID)
	} else if strings.TrimSpace(req.ProgressKey) != "" {
		progressKey = strings.TrimSpace(req.ProgressKey)
		if !strings.HasPrefix(progressKey, "file:") {
			baseWK := progressKey
			if idx := strings.Index(progressKey, ":s"); idx > 0 {
				baseWK = progressKey[:idx]
			}
			workKeySQL = sql.NullString{String: baseWK, Valid: true}
		}
	} else {
		return WatchProgressView{}, fmt.Errorf("%w: work_key or file_id is required", ErrInvalidInput)
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return WatchProgressView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	var (
		prevWatched, prevPlayCount, prevHidden int
		prevFileID, prevDur                    sql.NullInt64
		exists                                 bool
	)
	qErr := tx.QueryRow(`
		SELECT watched, play_count, hidden_from_continue, last_file_id, duration_ms
		FROM member_watch_progress
		WHERE member_id = ? AND progress_key = ?`,
		p.MemberID, progressKey,
	).Scan(&prevWatched, &prevPlayCount, &prevHidden, &prevFileID, &prevDur)
	if qErr == nil {
		exists = true
	} else if !errors.Is(qErr, sql.ErrNoRows) {
		return WatchProgressView{}, qErr
	}

	watchedInt := prevWatched
	if req.Watched != nil {
		if *req.Watched {
			watchedInt = 1
		} else {
			watchedInt = 0
		}
	}
	playCount := prevPlayCount
	if req.PlayCount != nil && *req.PlayCount >= 0 {
		playCount = *req.PlayCount
	} else if watchedInt == 1 && (!exists || prevWatched == 0) {
		playCount = prevPlayCount + 1
	}

	hiddenInt := prevHidden
	if req.HiddenFromContinue != nil {
		if *req.HiddenFromContinue {
			hiddenInt = 1
		} else {
			hiddenInt = 0
		}
	} else if req.PositionMs > 0 && watchedInt == 0 {
		hiddenInt = 0
	}

	lastFileID := prevFileID
	if req.FileID != nil && *req.FileID > 0 {
		lastFileID = sql.NullInt64{Int64: *req.FileID, Valid: true}
	}
	dur := prevDur
	if req.DurationMs != nil && *req.DurationMs > 0 {
		dur = sql.NullInt64{Int64: *req.DurationMs, Valid: true}
	}

	if _, err := tx.Exec(`
		INSERT INTO member_watch_progress(
			household_id, member_id, progress_key, work_key, season_number, episode_number,
			last_file_id, position_ms, duration_ms, watched, play_count,
			last_played_at, hidden_from_continue, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(member_id, progress_key) DO UPDATE SET
			work_key             = COALESCE(excluded.work_key, member_watch_progress.work_key),
			season_number        = excluded.season_number,
			episode_number       = excluded.episode_number,
			last_file_id         = excluded.last_file_id,
			position_ms          = excluded.position_ms,
			duration_ms          = excluded.duration_ms,
			watched              = excluded.watched,
			play_count           = excluded.play_count,
			last_played_at       = excluded.last_played_at,
			hidden_from_continue = excluded.hidden_from_continue,
			updated_at           = excluded.updated_at`,
		p.HouseholdID, p.MemberID, progressKey, workKeySQL, sNum, eNum,
		lastFileID, req.PositionMs, dur, watchedInt, playCount,
		nowMs, hiddenInt, nowMs,
	); err != nil {
		return WatchProgressView{}, err
	}

	mid := p.MemberID
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "progress", progressKey, "upsert", nowMs); err != nil {
		return WatchProgressView{}, err
	}
	if err := tx.Commit(); err != nil {
		return WatchProgressView{}, err
	}

	if s.hub != nil {
		s.hub.PublishToMember(p.HouseholdID, p.MemberID, "userdata.changed", map[string]any{
			"entity":       "progress",
			"progress_key": progressKey,
		})
	}
	return s.GetProgressByKey(p.HouseholdID, p.MemberID, progressKey)
}

func (s *Service) GetProgressByKey(householdID, memberID, progressKey string) (WatchProgressView, error) {
	row := s.store.ReadDB().QueryRow(`
		SELECT progress_key, COALESCE(work_key, ''), season_number, episode_number,
		       last_file_id, position_ms, duration_ms, watched, play_count,
		       last_played_at, hidden_from_continue, updated_at
		FROM member_watch_progress
		WHERE household_id = ? AND member_id = ? AND progress_key = ?`,
		householdID, memberID, progressKey,
	)
	return scanProgressView(row)
}

func (s *Service) ListProgress(p *account.Principal, workKey string, limit, offset int) ([]WatchProgressView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	if offset < 0 {
		offset = 0
	}

	var (
		rows *sql.Rows
		err  error
	)
	if strings.TrimSpace(workKey) != "" {
		rows, err = s.store.ReadDB().Query(`
			SELECT progress_key, COALESCE(work_key, ''), season_number, episode_number,
			       last_file_id, position_ms, duration_ms, watched, play_count,
			       last_played_at, hidden_from_continue, updated_at
			FROM member_watch_progress
			WHERE household_id = ? AND member_id = ? AND work_key = ?
			ORDER BY season_number ASC, episode_number ASC, updated_at DESC
			LIMIT ? OFFSET ?`,
			p.HouseholdID, p.MemberID, strings.TrimSpace(workKey), limit, offset,
		)
	} else {
		rows, err = s.store.ReadDB().Query(`
			SELECT progress_key, COALESCE(work_key, ''), season_number, episode_number,
			       last_file_id, position_ms, duration_ms, watched, play_count,
			       last_played_at, hidden_from_continue, updated_at
			FROM member_watch_progress
			WHERE household_id = ? AND member_id = ?
			ORDER BY updated_at DESC
			LIMIT ? OFFSET ?`,
			p.HouseholdID, p.MemberID, limit, offset,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]WatchProgressView, 0)
	for rows.Next() {
		v, err := scanProgressView(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *Service) ListContinueWatching(p *account.Principal, limit int) ([]WatchProgressView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	if limit <= 0 {
		limit = 30
	}
	if limit > 100 {
		limit = 100
	}
	rows, err := s.store.ReadDB().Query(`
		SELECT progress_key, COALESCE(work_key, ''), season_number, episode_number,
		       last_file_id, position_ms, duration_ms, watched, play_count,
		       last_played_at, hidden_from_continue, updated_at
		FROM member_watch_progress
		WHERE household_id = ? AND member_id = ?
		  AND watched = 0 AND hidden_from_continue = 0 AND position_ms > 0
		ORDER BY COALESCE(last_played_at, updated_at) DESC
		LIMIT ?`,
		p.HouseholdID, p.MemberID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]WatchProgressView, 0)
	for rows.Next() {
		v, err := scanProgressView(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *Service) HideFromContinue(p *account.Principal, progressKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	key := strings.TrimSpace(progressKey)
	if key == "" {
		return ErrInvalidInput
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE member_watch_progress
		SET hidden_from_continue = 1, updated_at = ?
		WHERE household_id = ? AND member_id = ? AND progress_key = ?`,
		nowMs, p.HouseholdID, p.MemberID, key,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	mid := p.MemberID
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "progress", key, "upsert", nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) DeleteProgress(p *account.Principal, progressKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	key := strings.TrimSpace(progressKey)
	if key == "" {
		return ErrInvalidInput
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		DELETE FROM member_watch_progress
		WHERE household_id = ? AND member_id = ? AND progress_key = ?`,
		p.HouseholdID, p.MemberID, key,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	mid := p.MemberID
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "progress", key, "delete", nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) ListFavorites(p *account.Principal) ([]FavoriteView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	rows, err := s.store.ReadDB().Query(`
		SELECT work_key, created_at
		FROM member_favorites
		WHERE household_id = ? AND member_id = ?
		ORDER BY created_at DESC`,
		p.HouseholdID, p.MemberID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]FavoriteView, 0)
	for rows.Next() {
		var f FavoriteView
		if err := rows.Scan(&f.WorkKey, &f.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (s *Service) AddFavorite(p *account.Principal, workKey string) (FavoriteView, error) {
	if p == nil {
		return FavoriteView{}, ErrUnauthorized
	}
	wk := strings.TrimSpace(workKey)
	if wk == "" {
		return FavoriteView{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return FavoriteView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO member_favorites(household_id, member_id, work_key, created_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(member_id, work_key) DO NOTHING`,
		p.HouseholdID, p.MemberID, wk, nowMs,
	); err != nil {
		return FavoriteView{}, err
	}
	var createdAt int64
	if err := tx.QueryRow(`SELECT created_at FROM member_favorites WHERE member_id = ? AND work_key = ?`, p.MemberID, wk).Scan(&createdAt); err != nil {
		return FavoriteView{}, err
	}
	mid := p.MemberID
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "favorite", wk, "upsert", nowMs); err != nil {
		return FavoriteView{}, err
	}
	if err := tx.Commit(); err != nil {
		return FavoriteView{}, err
	}
	if s.hub != nil {
		s.hub.PublishToMember(p.HouseholdID, p.MemberID, "userdata.changed", map[string]any{
			"entity":   "favorite",
			"work_key": wk,
		})
	}
	return FavoriteView{WorkKey: wk, CreatedAt: createdAt}, nil
}

func (s *Service) RemoveFavorite(p *account.Principal, workKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	wk := strings.TrimSpace(workKey)
	if wk == "" {
		return ErrInvalidInput
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`DELETE FROM member_favorites WHERE household_id = ? AND member_id = ? AND work_key = ?`, p.HouseholdID, p.MemberID, wk)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n > 0 {
		mid := p.MemberID
		if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "favorite", wk, "delete", nowMs); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Service) GetWorkPrefs(p *account.Principal, workKey string) (WorkPrefsView, error) {
	if p == nil {
		return WorkPrefsView{}, ErrUnauthorized
	}
	return s.LoadWorkPrefs(p.HouseholdID, p.MemberID, workKey)
}

func (s *Service) LoadWorkPrefs(householdID, memberID, workKey string) (WorkPrefsView, error) {
	wk := strings.TrimSpace(workKey)
	if wk == "" {
		return WorkPrefsView{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}
	out := WorkPrefsView{
		WorkKey:       wk,
		PlaybackSpeed: 1.0,
	}

	var introEn, credEn int
	_ = s.store.ReadDB().QueryRow(`
		SELECT intro_enabled, intro_start_ms, intro_end_ms,
		       credits_enabled, credits_from_end_ms, keep_easter_egg_ms, updated_at
		FROM household_work_prefs
		WHERE household_id = ? AND work_key = ?`,
		householdID, wk,
	).Scan(&introEn, &out.IntroStartMs, &out.IntroEndMs, &credEn, &out.CreditsFromEndMs, &out.KeepEasterEggMs, &out.HouseholdUpdatedAt)
	out.IntroEnabled = introEn != 0
	out.CreditsEnabled = credEn != 0

	if memberID != "" {
		var audio, sub sql.NullString
		var speed float64
		var mUpdated int64
		if err := s.store.ReadDB().QueryRow(`
			SELECT preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
			FROM member_work_prefs
			WHERE household_id = ? AND member_id = ? AND work_key = ?`,
			householdID, memberID, wk,
		).Scan(&audio, &sub, &speed, &mUpdated); err == nil {
			out.PreferredAudioLang = audio.String
			out.PreferredSubLang = sub.String
			if speed > 0 {
				out.PlaybackSpeed = speed
			}
			out.MemberUpdatedAt = mUpdated
		}
	}
	return out, nil
}

func (s *Service) UpsertHouseholdWorkPrefs(p *account.Principal, workKey string, req HouseholdWorkPrefsInput) (WorkPrefsView, error) {
	if p == nil {
		return WorkPrefsView{}, ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) && !p.HasPerm(account.PermManageSources) {
		return WorkPrefsView{}, ErrForbidden
	}
	wk := strings.TrimSpace(workKey)
	if wk == "" {
		return WorkPrefsView{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}

	cur, err := s.LoadWorkPrefs(p.HouseholdID, p.MemberID, wk)
	if err != nil {
		return WorkPrefsView{}, err
	}
	if req.IntroEnabled != nil {
		cur.IntroEnabled = *req.IntroEnabled
	}
	if req.IntroStartMs != nil && *req.IntroStartMs >= 0 {
		cur.IntroStartMs = *req.IntroStartMs
	}
	if req.IntroEndMs != nil && *req.IntroEndMs >= 0 {
		cur.IntroEndMs = *req.IntroEndMs
	}
	if req.CreditsEnabled != nil {
		cur.CreditsEnabled = *req.CreditsEnabled
	}
	if req.CreditsFromEndMs != nil && *req.CreditsFromEndMs >= 0 {
		cur.CreditsFromEndMs = *req.CreditsFromEndMs
	}
	if req.KeepEasterEggMs != nil && *req.KeepEasterEggMs >= 0 {
		cur.KeepEasterEggMs = *req.KeepEasterEggMs
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return WorkPrefsView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO household_work_prefs(
			household_id, work_key, intro_enabled, intro_start_ms, intro_end_ms,
			credits_enabled, credits_from_end_ms, keep_easter_egg_ms, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(household_id, work_key) DO UPDATE SET
			intro_enabled       = excluded.intro_enabled,
			intro_start_ms      = excluded.intro_start_ms,
			intro_end_ms        = excluded.intro_end_ms,
			credits_enabled     = excluded.credits_enabled,
			credits_from_end_ms = excluded.credits_from_end_ms,
			keep_easter_egg_ms  = excluded.keep_easter_egg_ms,
			updated_at          = excluded.updated_at`,
		p.HouseholdID, wk, boolToInt(cur.IntroEnabled), cur.IntroStartMs, cur.IntroEndMs,
		boolToInt(cur.CreditsEnabled), cur.CreditsFromEndMs, cur.KeepEasterEggMs, nowMs,
	); err != nil {
		return WorkPrefsView{}, err
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "work_prefs", wk, "upsert", nowMs); err != nil {
		return WorkPrefsView{}, err
	}
	if err := tx.Commit(); err != nil {
		return WorkPrefsView{}, err
	}
	return s.LoadWorkPrefs(p.HouseholdID, p.MemberID, wk)
}

func (s *Service) UpsertMemberWorkPrefs(p *account.Principal, workKey string, req MemberWorkPrefsInput) (WorkPrefsView, error) {
	if p == nil {
		return WorkPrefsView{}, ErrUnauthorized
	}
	wk := strings.TrimSpace(workKey)
	if wk == "" {
		return WorkPrefsView{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}

	cur, err := s.LoadWorkPrefs(p.HouseholdID, p.MemberID, wk)
	if err != nil {
		return WorkPrefsView{}, err
	}
	if req.PreferredAudioLang != nil {
		cur.PreferredAudioLang = strings.TrimSpace(*req.PreferredAudioLang)
	}
	if req.PreferredSubLang != nil {
		cur.PreferredSubLang = strings.TrimSpace(*req.PreferredSubLang)
	}
	if req.PlaybackSpeed != nil {
		if *req.PlaybackSpeed < 0.25 || *req.PlaybackSpeed > 4.0 {
			return WorkPrefsView{}, fmt.Errorf("%w: playback_speed must be between 0.25 and 4.0", ErrInvalidInput)
		}
		cur.PlaybackSpeed = *req.PlaybackSpeed
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return WorkPrefsView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO member_work_prefs(
			household_id, member_id, work_key, preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(member_id, work_key) DO UPDATE SET
			preferred_audio_lang = excluded.preferred_audio_lang,
			preferred_sub_lang   = excluded.preferred_sub_lang,
			playback_speed       = excluded.playback_speed,
			updated_at           = excluded.updated_at`,
		p.HouseholdID, p.MemberID, wk, nullableStr(cur.PreferredAudioLang), nullableStr(cur.PreferredSubLang), cur.PlaybackSpeed, nowMs,
	); err != nil {
		return WorkPrefsView{}, err
	}
	mid := p.MemberID
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, &mid, "work_prefs", wk, "upsert", nowMs); err != nil {
		return WorkPrefsView{}, err
	}
	if err := tx.Commit(); err != nil {
		return WorkPrefsView{}, err
	}
	return s.LoadWorkPrefs(p.HouseholdID, p.MemberID, wk)
}

func (s *Service) ListLists(p *account.Principal, kind string) ([]ListView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}
	var conds []string
	var args []any
	conds = append(conds, "l.household_id = ?", "(l.member_id IS NULL OR l.member_id = ?)")
	args = append(args, p.HouseholdID, p.MemberID)
	if k := strings.TrimSpace(kind); k != "" {
		conds = append(conds, "l.kind = ?")
		args = append(args, k)
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT l.id, l.household_id, COALESCE(l.member_id, ''), l.kind, l.title,
		       COALESCE(l.summary, ''), COALESCE(l.poster_source, ''), COALESCE(l.tmdb_id, ''),
		       (SELECT COUNT(*) FROM list_entries le WHERE le.list_id = l.id),
		       l.created_at, l.updated_at
		FROM lists l
		WHERE `+strings.Join(conds, " AND ")+`
		ORDER BY l.updated_at DESC`,
		args...,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]ListView, 0)
	for rows.Next() {
		var lv ListView
		if err := rows.Scan(
			&lv.ID, &lv.HouseholdID, &lv.MemberID, &lv.Kind, &lv.Title,
			&lv.Summary, &lv.PosterSource, &lv.TmdbID, &lv.EntryCount,
			&lv.CreatedAt, &lv.UpdatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, lv)
	}
	return out, rows.Err()
}

func (s *Service) CreateList(p *account.Principal, req CreateListRequest) (ListView, error) {
	if p == nil {
		return ListView{}, ErrUnauthorized
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		return ListView{}, fmt.Errorf("%w: title is required", ErrInvalidInput)
	}
	kind := strings.ToLower(strings.TrimSpace(req.Kind))
	if kind == "" {
		kind = "custom"
	}
	var memPtr *string
	if !req.Shared {
		mid := p.MemberID
		memPtr = &mid
	} else if !p.HasPerm(account.PermManageSources) && !p.HasPerm(account.PermUploadFacts) {
		return ListView{}, ErrForbidden
	}

	listID := uuid.NewString()
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return ListView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO lists(id, household_id, member_id, kind, title, summary, poster_source, tmdb_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		listID, p.HouseholdID, memPtr, kind, title,
		nullableStr(req.Summary), nullableStr(req.PosterSource), nullableStr(req.TmdbID),
		nowMs, nowMs,
	); err != nil {
		return ListView{}, err
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "list", listID, "upsert", nowMs); err != nil {
		return ListView{}, err
	}
	if err := tx.Commit(); err != nil {
		return ListView{}, err
	}

	det, err := s.GetList(p, listID)
	if err != nil {
		return ListView{}, err
	}
	return det.ListView, nil
}

func (s *Service) GetList(p *account.Principal, listID string) (ListDetailView, error) {
	if p == nil {
		return ListDetailView{}, ErrUnauthorized
	}
	return s.LoadListDetail(p.HouseholdID, p.MemberID, listID)
}

func (s *Service) LoadListDetail(householdID, memberID, listID string) (ListDetailView, error) {
	var det ListDetailView
	err := s.store.ReadDB().QueryRow(`
		SELECT l.id, l.household_id, COALESCE(l.member_id, ''), l.kind, l.title,
		       COALESCE(l.summary, ''), COALESCE(l.poster_source, ''), COALESCE(l.tmdb_id, ''),
		       l.created_at, l.updated_at
		FROM lists l
		WHERE l.id = ? AND l.household_id = ?`,
		listID, householdID,
	).Scan(
		&det.ID, &det.HouseholdID, &det.MemberID, &det.Kind, &det.Title,
		&det.Summary, &det.PosterSource, &det.TmdbID,
		&det.CreatedAt, &det.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return ListDetailView{}, ErrNotFound
	}
	if err != nil {
		return ListDetailView{}, err
	}
	if det.MemberID != "" && memberID != "" && det.MemberID != memberID {
		return ListDetailView{}, ErrNotFound
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT list_id, entry_key, work_key, season_number, episode_number, sort_order, added_at
		FROM list_entries
		WHERE list_id = ?
		ORDER BY sort_order ASC, added_at ASC`,
		listID,
	)
	if err != nil {
		return ListDetailView{}, err
	}
	defer rows.Close()

	det.Entries = make([]ListEntryView, 0)
	for rows.Next() {
		var e ListEntryView
		if err := rows.Scan(&e.ListID, &e.EntryKey, &e.WorkKey, &e.SeasonNumber, &e.EpisodeNumber, &e.SortOrder, &e.AddedAt); err != nil {
			return ListDetailView{}, err
		}
		det.Entries = append(det.Entries, e)
	}
	det.EntryCount = len(det.Entries)
	return det, rows.Err()
}

func (s *Service) UpdateList(p *account.Principal, listID string, req UpdateListRequest) (ListView, error) {
	if p == nil {
		return ListView{}, ErrUnauthorized
	}
	det, err := s.GetList(p, listID)
	if err != nil {
		return ListView{}, err
	}
	if det.MemberID == "" && !p.HasPerm(account.PermManageSources) && !p.HasPerm(account.PermUploadFacts) {
		return ListView{}, ErrForbidden
	}

	title := det.Title
	if req.Title != nil {
		title = strings.TrimSpace(*req.Title)
		if title == "" {
			return ListView{}, fmt.Errorf("%w: title cannot be empty", ErrInvalidInput)
		}
	}
	summary := det.Summary
	if req.Summary != nil {
		summary = strings.TrimSpace(*req.Summary)
	}
	poster := det.PosterSource
	if req.PosterSource != nil {
		poster = strings.TrimSpace(*req.PosterSource)
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return ListView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		UPDATE lists SET title = ?, summary = ?, poster_source = ?, updated_at = ?
		WHERE id = ? AND household_id = ?`,
		title, nullableStr(summary), nullableStr(poster), nowMs, listID, p.HouseholdID,
	); err != nil {
		return ListView{}, err
	}
	var memPtr *string
	if det.MemberID != "" {
		v := det.MemberID
		memPtr = &v
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "list", listID, "upsert", nowMs); err != nil {
		return ListView{}, err
	}
	if err := tx.Commit(); err != nil {
		return ListView{}, err
	}

	updated, err := s.GetList(p, listID)
	if err != nil {
		return ListView{}, err
	}
	return updated.ListView, nil
}

func (s *Service) DeleteList(p *account.Principal, listID string) error {
	if p == nil {
		return ErrUnauthorized
	}
	det, err := s.GetList(p, listID)
	if err != nil {
		return err
	}
	if det.MemberID == "" && !p.HasPerm(account.PermManageSources) {
		return ErrForbidden
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM lists WHERE id = ? AND household_id = ?`, listID, p.HouseholdID); err != nil {
		return err
	}
	var memPtr *string
	if det.MemberID != "" {
		v := det.MemberID
		memPtr = &v
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "list", listID, "delete", nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) AddListEntry(p *account.Principal, listID string, req AddListEntryRequest) (ListEntryView, error) {
	if p == nil {
		return ListEntryView{}, ErrUnauthorized
	}
	wk := strings.TrimSpace(req.WorkKey)
	if wk == "" {
		return ListEntryView{}, fmt.Errorf("%w: work_key is required", ErrInvalidInput)
	}
	det, err := s.GetList(p, listID)
	if err != nil {
		return ListEntryView{}, err
	}
	if det.MemberID == "" && !p.HasPerm(account.PermManageSources) && !p.HasPerm(account.PermUploadFacts) {
		return ListEntryView{}, ErrForbidden
	}

	sNum := -1
	eNum := -1
	if req.SeasonNumber != nil {
		sNum = *req.SeasonNumber
	}
	if req.EpisodeNumber != nil {
		eNum = *req.EpisodeNumber
	}
	entryKey := library.BuildWorkProgressKey(wk, sNum, eNum)
	sortOrder := det.EntryCount
	if req.SortOrder != nil {
		sortOrder = *req.SortOrder
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return ListEntryView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO list_entries(list_id, entry_key, work_key, season_number, episode_number, sort_order, added_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(list_id, entry_key) DO UPDATE SET
			sort_order = excluded.sort_order`,
		listID, entryKey, wk, sNum, eNum, sortOrder, nowMs,
	); err != nil {
		return ListEntryView{}, err
	}
	if _, err := tx.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, nowMs, listID); err != nil {
		return ListEntryView{}, err
	}
	var memPtr *string
	if det.MemberID != "" {
		v := det.MemberID
		memPtr = &v
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "list", listID, "upsert", nowMs); err != nil {
		return ListEntryView{}, err
	}
	if err := tx.Commit(); err != nil {
		return ListEntryView{}, err
	}

	return ListEntryView{
		ListID:        listID,
		EntryKey:      entryKey,
		WorkKey:       wk,
		SeasonNumber:  sNum,
		EpisodeNumber: eNum,
		SortOrder:     sortOrder,
		AddedAt:       nowMs,
	}, nil
}

func (s *Service) RemoveListEntry(p *account.Principal, listID, entryKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	det, err := s.GetList(p, listID)
	if err != nil {
		return err
	}
	if det.MemberID == "" && !p.HasPerm(account.PermManageSources) && !p.HasPerm(account.PermUploadFacts) {
		return ErrForbidden
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`DELETE FROM list_entries WHERE list_id = ? AND entry_key = ?`, listID, strings.TrimSpace(entryKey))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, nowMs, listID); err != nil {
		return err
	}
	var memPtr *string
	if det.MemberID != "" {
		v := det.MemberID
		memPtr = &v
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "list", listID, "upsert", nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) MigrateWorkData(p *account.Principal, fromWorkKey, toWorkKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	fromWK := strings.TrimSpace(fromWorkKey)
	toWK := strings.TrimSpace(toWorkKey)
	if fromWK == "" || toWK == "" {
		return fmt.Errorf("%w: from_work_key and to_work_key are required", ErrInvalidInput)
	}
	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if err := library.MigrateWorkUserDataTx(tx, p.HouseholdID, fromWK, toWK, nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanProgressView(r rowScanner) (WatchProgressView, error) {
	var (
		v                WatchProgressView
		fileID, dur, lpa sql.NullInt64
		watched, hidden  int
	)
	if err := r.Scan(
		&v.ProgressKey, &v.WorkKey, &v.SeasonNumber, &v.EpisodeNumber,
		&fileID, &v.PositionMs, &dur, &watched, &v.PlayCount,
		&lpa, &hidden, &v.UpdatedAt,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return WatchProgressView{}, ErrNotFound
		}
		return WatchProgressView{}, err
	}
	v.Watched = watched != 0
	v.HiddenFromContinue = hidden != 0
	if fileID.Valid {
		val := fileID.Int64
		v.LastFileID = &val
	}
	if dur.Valid {
		val := dur.Int64
		v.DurationMs = &val
	}
	if lpa.Valid {
		val := lpa.Int64
		v.LastPlayedAt = &val
	}
	return v, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func nullableStr(s string) *string {
	t := strings.TrimSpace(s)
	if t == "" {
		return nil
	}
	return &t
}
