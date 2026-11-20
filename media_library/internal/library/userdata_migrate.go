package library

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"plezy/media_library/internal/db"
)

type watchProgressRow struct {
	MemberID           string
	ProgressKey        string
	WorkKey            sql.NullString
	SeasonNumber       int
	EpisodeNumber      int
	LastFileID         sql.NullInt64
	PositionMs         int64
	DurationMs         sql.NullInt64
	Watched            int
	PlayCount          int
	LastPlayedAt       sql.NullInt64
	HiddenFromContinue int
	UpdatedAt          int64
}

// BuildWorkProgressKey builds the canonical member_watch_progress.progress_key.
// Movie / work-level uses "<work_key>"; episode uses "<work_key>:s<season>:e<episode>".
func BuildWorkProgressKey(workKey string, seasonNum, episodeNum int) string {
	if seasonNum >= 0 || episodeNum >= 0 {
		if seasonNum < 0 {
			seasonNum = 0
		}
		if episodeNum < 0 {
			episodeNum = 0
		}
		return fmt.Sprintf("%s:s%d:e%d", workKey, seasonNum, episodeNum)
	}
	return workKey
}

// MigrateWorkUserDataTx moves and merges all member-scoped and household-scoped
// user data tied to fromWorkKey over to toWorkKey within an existing transaction (G2).
func MigrateWorkUserDataTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	fromWorkKey = strings.TrimSpace(fromWorkKey)
	toWorkKey = strings.TrimSpace(toWorkKey)
	if householdID == "" || fromWorkKey == "" || toWorkKey == "" || fromWorkKey == toWorkKey {
		return nil
	}

	if err := migrateWatchProgressByWorkTx(tx, householdID, fromWorkKey, toWorkKey, nowMs); err != nil {
		return err
	}
	if err := migrateFavoritesByWorkTx(tx, householdID, fromWorkKey, toWorkKey, nowMs); err != nil {
		return err
	}
	if err := migrateHouseholdWorkPrefsTx(tx, householdID, fromWorkKey, toWorkKey, nowMs); err != nil {
		return err
	}
	if err := migrateMemberWorkPrefsTx(tx, householdID, fromWorkKey, toWorkKey, nowMs); err != nil {
		return err
	}
	return migrateListEntriesByWorkTx(tx, householdID, fromWorkKey, toWorkKey, nowMs)
}

// MigrateFileWatchProgressTx promotes unmatched file-keyed progress ("file:<id>")
// to canonical work-keyed progress when a file is matched (G3).
func MigrateFileWatchProgressTx(tx *sql.Tx, householdID string, fileID int64, toWorkKey string, seasonNum, episodeNum int, nowMs int64) error {
	toWorkKey = strings.TrimSpace(toWorkKey)
	if householdID == "" || fileID <= 0 || toWorkKey == "" {
		return nil
	}
	fileKey := fmt.Sprintf("file:%d", fileID)
	targetKey := BuildWorkProgressKey(toWorkKey, seasonNum, episodeNum)

	rows, err := tx.Query(`
		SELECT member_id, progress_key, work_key, season_number, episode_number,
		       last_file_id, position_ms, duration_ms, watched, play_count,
		       last_played_at, hidden_from_continue, updated_at
		FROM member_watch_progress
		WHERE household_id = ? AND progress_key = ?`,
		householdID, fileKey,
	)
	if err != nil {
		return err
	}
	srcRows, err := scanWatchProgressRows(rows)
	if err != nil {
		return err
	}

	for _, src := range srcRows {
		src.WorkKey = sql.NullString{String: toWorkKey, Valid: true}
		src.SeasonNumber = seasonNum
		src.EpisodeNumber = episodeNum
		if !src.LastFileID.Valid {
			src.LastFileID = sql.NullInt64{Int64: fileID, Valid: true}
		}
		if err := moveProgressRowTx(tx, householdID, src, targetKey, nowMs); err != nil {
			return err
		}
	}
	return nil
}

func scanWatchProgressRows(rows *sql.Rows) ([]watchProgressRow, error) {
	var out []watchProgressRow
	for rows.Next() {
		var r watchProgressRow
		if err := rows.Scan(
			&r.MemberID, &r.ProgressKey, &r.WorkKey, &r.SeasonNumber, &r.EpisodeNumber,
			&r.LastFileID, &r.PositionMs, &r.DurationMs, &r.Watched, &r.PlayCount,
			&r.LastPlayedAt, &r.HiddenFromContinue, &r.UpdatedAt,
		); err != nil {
			_ = rows.Close()
			return nil, err
		}
		out = append(out, r)
	}
	_ = rows.Close()
	return out, rows.Err()
}

func migrateWatchProgressByWorkTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	rows, err := tx.Query(`
		SELECT member_id, progress_key, work_key, season_number, episode_number,
		       last_file_id, position_ms, duration_ms, watched, play_count,
		       last_played_at, hidden_from_continue, updated_at
		FROM member_watch_progress
		WHERE household_id = ? AND work_key = ?`,
		householdID, fromWorkKey,
	)
	if err != nil {
		return err
	}
	srcRows, err := scanWatchProgressRows(rows)
	if err != nil {
		return err
	}

	for _, src := range srcRows {
		var newKey string
		if src.ProgressKey == fromWorkKey {
			newKey = toWorkKey
		} else if strings.HasPrefix(src.ProgressKey, fromWorkKey+":") {
			newKey = toWorkKey + strings.TrimPrefix(src.ProgressKey, fromWorkKey)
		} else {
			newKey = BuildWorkProgressKey(toWorkKey, src.SeasonNumber, src.EpisodeNumber)
		}
		src.WorkKey = sql.NullString{String: toWorkKey, Valid: true}
		if err := moveProgressRowTx(tx, householdID, src, newKey, nowMs); err != nil {
			return err
		}
	}
	return nil
}

func moveProgressRowTx(tx *sql.Tx, householdID string, src watchProgressRow, targetKey string, nowMs int64) error {
	var tgt watchProgressRow
	err := tx.QueryRow(`
		SELECT member_id, progress_key, work_key, season_number, episode_number,
		       last_file_id, position_ms, duration_ms, watched, play_count,
		       last_played_at, hidden_from_continue, updated_at
		FROM member_watch_progress
		WHERE member_id = ? AND progress_key = ?`,
		src.MemberID, targetKey,
	).Scan(
		&tgt.MemberID, &tgt.ProgressKey, &tgt.WorkKey, &tgt.SeasonNumber, &tgt.EpisodeNumber,
		&tgt.LastFileID, &tgt.PositionMs, &tgt.DurationMs, &tgt.Watched, &tgt.PlayCount,
		&tgt.LastPlayedAt, &tgt.HiddenFromContinue, &tgt.UpdatedAt,
	)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	merged := src
	merged.ProgressKey = targetKey
	if err == nil {
		if tgt.Watched > merged.Watched {
			merged.Watched = tgt.Watched
		}
		if tgt.PlayCount > merged.PlayCount {
			merged.PlayCount = tgt.PlayCount
		}
		if !merged.DurationMs.Valid && tgt.DurationMs.Valid {
			merged.DurationMs = tgt.DurationMs
		}
		if tgt.LastPlayedAt.Valid && (!merged.LastPlayedAt.Valid || tgt.LastPlayedAt.Int64 > merged.LastPlayedAt.Int64) {
			merged.LastPlayedAt = tgt.LastPlayedAt
		}
		if tgt.UpdatedAt > merged.UpdatedAt || (tgt.UpdatedAt == merged.UpdatedAt && tgt.PositionMs > merged.PositionMs) {
			merged.PositionMs = tgt.PositionMs
			if tgt.LastFileID.Valid {
				merged.LastFileID = tgt.LastFileID
			}
			merged.HiddenFromContinue = tgt.HiddenFromContinue
		}
	}

	if _, err := tx.Exec(`DELETE FROM member_watch_progress WHERE member_id = ? AND progress_key = ?`, src.MemberID, src.ProgressKey); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		INSERT INTO member_watch_progress(
			household_id, member_id, progress_key, work_key, season_number, episode_number,
			last_file_id, position_ms, duration_ms, watched, play_count,
			last_played_at, hidden_from_continue, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(member_id, progress_key) DO UPDATE SET
			work_key             = excluded.work_key,
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
		householdID, merged.MemberID, targetKey, merged.WorkKey, merged.SeasonNumber, merged.EpisodeNumber,
		merged.LastFileID, merged.PositionMs, merged.DurationMs, merged.Watched, merged.PlayCount,
		merged.LastPlayedAt, merged.HiddenFromContinue, nowMs,
	); err != nil {
		return err
	}

	mid := src.MemberID
	_, err = db.AppendChangeTx(tx, householdID, &mid, "progress", targetKey, "upsert", nowMs)
	return err
}

func migrateFavoritesByWorkTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	rows, err := tx.Query(`
		SELECT member_id, created_at
		FROM member_favorites
		WHERE household_id = ? AND work_key = ?`,
		householdID, fromWorkKey,
	)
	if err != nil {
		return err
	}
	type favRow struct {
		memberID  string
		createdAt int64
	}
	var list []favRow
	for rows.Next() {
		var r favRow
		if err := rows.Scan(&r.memberID, &r.createdAt); err != nil {
			_ = rows.Close()
			return err
		}
		list = append(list, r)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, r := range list {
		if _, err := tx.Exec(`DELETE FROM member_favorites WHERE member_id = ? AND work_key = ?`, r.memberID, fromWorkKey); err != nil {
			return err
		}
		if _, err := tx.Exec(`
			INSERT INTO member_favorites(household_id, member_id, work_key, created_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(member_id, work_key) DO UPDATE SET
				created_at = MIN(member_favorites.created_at, excluded.created_at)`,
			householdID, r.memberID, toWorkKey, r.createdAt,
		); err != nil {
			return err
		}
		mid := r.memberID
		if _, err := db.AppendChangeTx(tx, householdID, &mid, "favorite", toWorkKey, "upsert", nowMs); err != nil {
			return err
		}
	}
	return nil
}

func migrateHouseholdWorkPrefsTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	type hhPref struct {
		introEnabled, introStart, introEnd         int
		creditsEnabled, creditsFromEnd, easterEgg  int
		updatedAt                                  int64
	}
	load := func(wk string) (hhPref, bool, error) {
		var p hhPref
		err := tx.QueryRow(`
			SELECT intro_enabled, intro_start_ms, intro_end_ms,
			       credits_enabled, credits_from_end_ms, keep_easter_egg_ms, updated_at
			FROM household_work_prefs
			WHERE household_id = ? AND work_key = ?`,
			householdID, wk,
		).Scan(&p.introEnabled, &p.introStart, &p.introEnd, &p.creditsEnabled, &p.creditsFromEnd, &p.easterEgg, &p.updatedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return hhPref{}, false, nil
		}
		return p, err == nil, err
	}

	src, ok, err := load(fromWorkKey)
	if err != nil || !ok {
		return err
	}
	tgt, hasTgt, err := load(toWorkKey)
	if err != nil {
		return err
	}

	if _, err := tx.Exec(`DELETE FROM household_work_prefs WHERE household_id = ? AND work_key = ?`, householdID, fromWorkKey); err != nil {
		return err
	}
	if !hasTgt || src.updatedAt >= tgt.updatedAt {
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
			householdID, toWorkKey, src.introEnabled, src.introStart, src.introEnd,
			src.creditsEnabled, src.creditsFromEnd, src.easterEgg, nowMs,
		); err != nil {
			return err
		}
	}
	_, err = db.AppendChangeTx(tx, householdID, nil, "work_prefs", toWorkKey, "upsert", nowMs)
	return err
}

func migrateMemberWorkPrefsTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	type memPref struct {
		memberID  string
		audio     sql.NullString
		sub       sql.NullString
		speed     float64
		updatedAt int64
	}
	rows, err := tx.Query(`
		SELECT member_id, preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
		FROM member_work_prefs
		WHERE household_id = ? AND work_key = ?`,
		householdID, fromWorkKey,
	)
	if err != nil {
		return err
	}
	var srcs []memPref
	for rows.Next() {
		var p memPref
		if err := rows.Scan(&p.memberID, &p.audio, &p.sub, &p.speed, &p.updatedAt); err != nil {
			_ = rows.Close()
			return err
		}
		srcs = append(srcs, p)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, src := range srcs {
		var tgtAudio, tgtSub sql.NullString
		var tgtSpeed float64
		var tgtUpdated int64
		err := tx.QueryRow(`
			SELECT preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
			FROM member_work_prefs
			WHERE member_id = ? AND work_key = ?`,
			src.memberID, toWorkKey,
		).Scan(&tgtAudio, &tgtSub, &tgtSpeed, &tgtUpdated)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}

		if _, err := tx.Exec(`DELETE FROM member_work_prefs WHERE member_id = ? AND work_key = ?`, src.memberID, fromWorkKey); err != nil {
			return err
		}

		merged := src
		if err == nil && tgtUpdated > src.updatedAt {
			merged.audio = tgtAudio
			merged.sub = tgtSub
			merged.speed = tgtSpeed
		} else if err == nil {
			if (!merged.audio.Valid || merged.audio.String == "") && tgtAudio.Valid {
				merged.audio = tgtAudio
			}
			if (!merged.sub.Valid || merged.sub.String == "") && tgtSub.Valid {
				merged.sub = tgtSub
			}
		}

		if _, err := tx.Exec(`
			INSERT INTO member_work_prefs(
				household_id, member_id, work_key, preferred_audio_lang, preferred_sub_lang, playback_speed, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(member_id, work_key) DO UPDATE SET
				preferred_audio_lang = excluded.preferred_audio_lang,
				preferred_sub_lang   = excluded.preferred_sub_lang,
				playback_speed       = excluded.playback_speed,
				updated_at           = excluded.updated_at`,
			householdID, src.memberID, toWorkKey, merged.audio, merged.sub, merged.speed, nowMs,
		); err != nil {
			return err
		}
		mid := src.memberID
		if _, err := db.AppendChangeTx(tx, householdID, &mid, "work_prefs", toWorkKey, "upsert", nowMs); err != nil {
			return err
		}
	}
	return nil
}

func migrateListEntriesByWorkTx(tx *sql.Tx, householdID, fromWorkKey, toWorkKey string, nowMs int64) error {
	rows, err := tx.Query(`
		SELECT le.list_id, l.member_id, le.entry_key, le.season_number, le.episode_number, le.sort_order, le.added_at
		FROM list_entries le
		JOIN lists l ON l.id = le.list_id
		WHERE l.household_id = ? AND le.work_key = ?`,
		householdID, fromWorkKey,
	)
	if err != nil {
		return err
	}
	type entryRow struct {
		listID        string
		memberID      sql.NullString
		entryKey      string
		seasonNumber  int
		episodeNumber int
		sortOrder     int
		addedAt       int64
	}
	var entries []entryRow
	for rows.Next() {
		var r entryRow
		if err := rows.Scan(&r.listID, &r.memberID, &r.entryKey, &r.seasonNumber, &r.episodeNumber, &r.sortOrder, &r.addedAt); err != nil {
			_ = rows.Close()
			return err
		}
		entries = append(entries, r)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	touchedLists := make(map[string]*string)
	for _, e := range entries {
		var newKey string
		if e.entryKey == fromWorkKey {
			newKey = toWorkKey
		} else if strings.HasPrefix(e.entryKey, fromWorkKey+":") {
			newKey = toWorkKey + strings.TrimPrefix(e.entryKey, fromWorkKey)
		} else {
			newKey = BuildWorkProgressKey(toWorkKey, e.seasonNumber, e.episodeNumber)
		}

		if _, err := tx.Exec(`DELETE FROM list_entries WHERE list_id = ? AND entry_key = ?`, e.listID, e.entryKey); err != nil {
			return err
		}
		if _, err := tx.Exec(`
			INSERT INTO list_entries(list_id, entry_key, work_key, season_number, episode_number, sort_order, added_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(list_id, entry_key) DO UPDATE SET
				added_at = MIN(list_entries.added_at, excluded.added_at)`,
			e.listID, newKey, toWorkKey, e.seasonNumber, e.episodeNumber, e.sortOrder, e.addedAt,
		); err != nil {
			return err
		}

		var midPtr *string
		if e.memberID.Valid && e.memberID.String != "" {
			v := e.memberID.String
			midPtr = &v
		}
		touchedLists[e.listID] = midPtr
	}

	for listID, midPtr := range touchedLists {
		if _, err := tx.Exec(`UPDATE lists SET updated_at = ? WHERE id = ?`, nowMs, listID); err != nil {
			return err
		}
		if _, err := db.AppendChangeTx(tx, householdID, midPtr, "list", listID, "upsert", nowMs); err != nil {
			return err
		}
	}
	return nil
}
