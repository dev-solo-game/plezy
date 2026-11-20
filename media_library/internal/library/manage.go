package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"strconv"
	"strings"

	"github.com/google/uuid"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/pathutil"
)

var ErrForbidden = errors.New("forbidden")

type UnmatchedFileView struct {
	ID           int64       `json:"id"`
	SourceID     string      `json:"source_id"`
	SourceName   string      `json:"source_name"`
	Path         string      `json:"path"`
	GroupKey     string      `json:"group_key"`
	Size         *int64      `json:"size,omitempty"`
	MtimeS       *int64      `json:"mtime_s,omitempty"`
	MatchState   string      `json:"match_state"`
	MatchLocked  bool        `json:"match_locked"`
	VersionLabel string      `json:"version_label,omitempty"`
	Parsed       *ParsedName `json:"parsed,omitempty"`
	AddedAt      int64       `json:"added_at"`
	UpdatedAt    int64       `json:"updated_at"`
}

type UnmatchedPage struct {
	Items    []UnmatchedFileView `json:"items"`
	Total    int                 `json:"total"`
	Page     int                 `json:"page"`
	PageSize int                 `json:"page_size"`
}

type IgnoreUnmatchedRequest struct {
	SourceID   string  `json:"source_id,omitempty"`
	PathPrefix string  `json:"path_prefix,omitempty"`
	FileIDs    []int64 `json:"file_ids,omitempty"`
}

type MatchRule struct {
	ID             string `json:"id"`
	HouseholdID    string `json:"household_id"`
	SourceID       string `json:"source_id"`
	PathPrefix     string `json:"path_prefix"`
	Action         string `json:"action"`
	TargetProvider string `json:"target_provider,omitempty"`
	TargetKind     string `json:"target_kind,omitempty"`
	TargetExtID    string `json:"target_ext_id,omitempty"`
	SeasonOffset   int    `json:"season_offset"`
	CreatedBy      string `json:"created_by"`
	CreatedAt      int64  `json:"created_at"`
	UpdatedAt      int64  `json:"updated_at"`
}

type UpsertMatchRuleRequest struct {
	SourceID       string `json:"source_id"`
	PathPrefix     string `json:"path_prefix"`
	Action         string `json:"action"` // bind | ignore
	TargetProvider string `json:"target_provider,omitempty"`
	TargetKind     string `json:"target_kind,omitempty"`
	TargetExtID    string `json:"target_ext_id,omitempty"`
	SeasonOffset   int    `json:"season_offset,omitempty"`
}

type ManualMatchRequest struct {
	FileIDs      []int64 `json:"file_ids,omitempty"`
	ItemID       *int64  `json:"item_id,omitempty"`
	SourceID     string  `json:"source_id,omitempty"`
	PathPrefix   string  `json:"path_prefix,omitempty"`
	Provider     string  `json:"provider"`
	Kind         string  `json:"kind"`
	ExternalID   string  `json:"external_id"`
	SeasonOffset int     `json:"season_offset,omitempty"`
	Lock         *bool   `json:"lock,omitempty"`
	CreateRule   *bool   `json:"create_rule,omitempty"`
}

type ManualMatchResult struct {
	ItemID       int64    `json:"item_id"`
	WorkKey      string   `json:"work_key"`
	Kind         string   `json:"kind"`
	Title        string   `json:"title"`
	MatchedFiles int      `json:"matched_files"`
	RuleIDs      []string `json:"rule_ids,omitempty"`
}

type EditItemRequest struct {
	Title          *string  `json:"title,omitempty"`
	SortTitle      *string  `json:"sort_title,omitempty"`
	OriginalTitle  *string  `json:"original_title,omitempty"`
	Year           *int     `json:"year,omitempty"`
	ReleaseDate    *string  `json:"release_date,omitempty"`
	Summary        *string  `json:"summary,omitempty"`
	Tagline        *string  `json:"tagline,omitempty"`
	ContentRating  *string  `json:"content_rating,omitempty"`
	Studio         *string  `json:"studio,omitempty"`
	Rating         *float64 `json:"rating,omitempty"`
	LibraryType    *string  `json:"library_type,omitempty"`
	PosterSource   *string  `json:"poster_source,omitempty"`
	BackdropSource *string  `json:"backdrop_source,omitempty"`
	LogoSource     *string  `json:"logo_source,omitempty"`
	Locked         *bool    `json:"locked,omitempty"`
}

type RescrapeRequest struct {
	Unlock     bool `json:"unlock,omitempty"`
	Reidentify bool `json:"reidentify,omitempty"`
}

func (sc *Scraper) ListUnmatchedFiles(
	householdID string,
	allowedSourceIDs []string,
	sourceIDFilter, stateFilter string,
	page, pageSize int,
) (UnmatchedPage, error) {
	if page <= 0 {
		page = 1
	}
	if pageSize <= 0 {
		pageSize = 50
	}
	if pageSize > 200 {
		pageSize = 200
	}
	empty := UnmatchedPage{Items: []UnmatchedFileView{}, Page: page, PageSize: pageSize}

	if allowedSourceIDs != nil {
		if len(allowedSourceIDs) == 0 {
			return empty, nil
		}
		if sourceIDFilter != "" && !containsString(allowedSourceIDs, sourceIDFilter) {
			return empty, ErrForbidden
		}
	}

	var conds []string
	var args []any
	conds = append(conds, "mf.household_id = ?", "s.status = 'active'", "mf.state = 'active'", "mf.role = 'video'")
	args = append(args, householdID)

	switch strings.ToLower(strings.TrimSpace(stateFilter)) {
	case "", db.MatchUnmatched:
		conds = append(conds, "mf.match_state = 'unmatched'")
	case db.MatchPending:
		conds = append(conds, "mf.match_state = 'pending'")
	case db.MatchIgnored:
		conds = append(conds, "mf.match_state = 'ignored'")
	case "all":
		conds = append(conds, "mf.match_state IN ('unmatched', 'pending', 'ignored')")
	default:
		return empty, fmt.Errorf("%w: invalid match state filter %q", db.ErrInvalidInput, stateFilter)
	}

	if sourceIDFilter != "" {
		conds = append(conds, "mf.source_id = ?")
		args = append(args, sourceIDFilter)
	} else if allowedSourceIDs != nil {
		ph, inArgs := inClause(allowedSourceIDs)
		conds = append(conds, "mf.source_id IN ("+ph+")")
		args = append(args, inArgs...)
	}

	whereSQL := strings.Join(conds, " AND ")
	var total int
	if err := sc.store.ReadDB().QueryRow(
		`SELECT COUNT(*) FROM media_files mf JOIN sources s ON s.id = mf.source_id WHERE `+whereSQL,
		args...,
	).Scan(&total); err != nil {
		return empty, err
	}

	offset := (page - 1) * pageSize
	qArgs := append(append([]any{}, args...), pageSize, offset)
	rows, err := sc.store.ReadDB().Query(`
		SELECT mf.id, mf.source_id, s.name, mf.path, mf.size, mf.mtime_s,
		       mf.match_state, mf.match_locked, mf.version_label, mf.parsed_json,
		       mf.added_at, mf.updated_at
		FROM media_files mf
		JOIN sources s ON s.id = mf.source_id
		WHERE `+whereSQL+`
		ORDER BY mf.updated_at DESC, mf.id DESC
		LIMIT ? OFFSET ?`,
		qArgs...,
	)
	if err != nil {
		return empty, err
	}
	defer rows.Close()

	items := make([]UnmatchedFileView, 0)
	for rows.Next() {
		var (
			v                     UnmatchedFileView
			sz, mt                sql.NullInt64
			locked                int
			vLabel, parsedJSONStr sql.NullString
		)
		if err := rows.Scan(
			&v.ID, &v.SourceID, &v.SourceName, &v.Path, &sz, &mt,
			&v.MatchState, &locked, &vLabel, &parsedJSONStr,
			&v.AddedAt, &v.UpdatedAt,
		); err != nil {
			return empty, err
		}
		v.MatchLocked = locked != 0
		if sz.Valid {
			val := sz.Int64
			v.Size = &val
		}
		if mt.Valid {
			val := mt.Int64
			v.MtimeS = &val
		}
		if vLabel.Valid {
			v.VersionLabel = vLabel.String
		}
		if parsedJSONStr.Valid && parsedJSONStr.String != "" {
			var p ParsedName
			if json.Unmarshal([]byte(parsedJSONStr.String), &p) == nil {
				v.Parsed = &p
			}
		}
		_, _, gk := ParseAndGroup(v.SourceID, v.Path)
		v.GroupKey = gk
		items = append(items, v)
	}
	if err := rows.Err(); err != nil {
		return empty, err
	}
	return UnmatchedPage{
		Items:    items,
		Total:    total,
		Page:     page,
		PageSize: pageSize,
	}, nil
}

func (sc *Scraper) IgnoreUnmatchedFiles(householdID, memberID string, allowedSourceIDs []string, req IgnoreUnmatchedRequest) (int64, error) {
	if len(req.FileIDs) == 0 && (strings.TrimSpace(req.SourceID) == "" || strings.TrimSpace(req.PathPrefix) == "") {
		return 0, fmt.Errorf("%w: file_ids or (source_id, path_prefix) is required", db.ErrInvalidInput)
	}
	if req.SourceID != "" && allowedSourceIDs != nil && !containsString(allowedSourceIDs, req.SourceID) {
		return 0, ErrForbidden
	}

	nowMs := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	var updated int64
	if len(req.FileIDs) > 0 {
		for _, fid := range req.FileIDs {
			var srcID string
			err := tx.QueryRow(`SELECT source_id FROM media_files WHERE id = ? AND household_id = ?`, fid, householdID).Scan(&srcID)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			if err != nil {
				return 0, err
			}
			if allowedSourceIDs != nil && !containsString(allowedSourceIDs, srcID) {
				return 0, ErrForbidden
			}
			res, err := tx.Exec(`
				UPDATE media_files SET match_state = 'ignored', updated_at = ?
				WHERE id = ? AND household_id = ? AND role = 'video'`,
				nowMs, fid, householdID,
			)
			if err != nil {
				return 0, err
			}
			n, _ := res.RowsAffected()
			updated += n
		}
	}

	if strings.TrimSpace(req.SourceID) != "" && strings.TrimSpace(req.PathPrefix) != "" {
		normPrefix := pathutil.NormalizePath(req.PathPrefix)
		if normPrefix == "" {
			return 0, fmt.Errorf("%w: invalid path_prefix", db.ErrInvalidInput)
		}
		if err := ensureSourceOwnedTx(tx, householdID, req.SourceID); err != nil {
			return 0, err
		}
		ruleID := uuid.NewString()
		if _, err := tx.Exec(`
			INSERT INTO match_rules(id, household_id, source_id, path_prefix, action, season_offset, created_by, created_at, updated_at)
			VALUES (?, ?, ?, ?, 'ignore', 0, ?, ?, ?)
			ON CONFLICT(source_id, path_prefix) DO UPDATE SET
				action = 'ignore',
				target_provider = NULL,
				target_kind = NULL,
				target_ext_id = NULL,
				season_offset = 0,
				updated_at = excluded.updated_at`,
			ruleID, householdID, req.SourceID, normPrefix, memberID, nowMs, nowMs,
		); err != nil {
			return 0, err
		}

		res, err := updateMatchingFilesStateByPrefixTx(tx, householdID, req.SourceID, normPrefix, db.MatchIgnored, nowMs)
		if err != nil {
			return 0, err
		}
		updated += res
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return updated, nil
}

func (sc *Scraper) ListMatchRules(householdID string, allowedSourceIDs []string, sourceID string) ([]MatchRule, error) {
	if allowedSourceIDs != nil {
		if len(allowedSourceIDs) == 0 {
			return []MatchRule{}, nil
		}
		if sourceID != "" && !containsString(allowedSourceIDs, sourceID) {
			return nil, ErrForbidden
		}
	}
	var conds []string
	var args []any
	conds = append(conds, "household_id = ?")
	args = append(args, householdID)
	if sourceID != "" {
		conds = append(conds, "source_id = ?")
		args = append(args, sourceID)
	} else if allowedSourceIDs != nil {
		ph, inArgs := inClause(allowedSourceIDs)
		conds = append(conds, "source_id IN ("+ph+")")
		args = append(args, inArgs...)
	}

	rows, err := sc.store.ReadDB().Query(`
		SELECT id, household_id, source_id, path_prefix, action,
		       COALESCE(target_provider, ''), COALESCE(target_kind, ''),
		       COALESCE(target_ext_id, ''), season_offset, created_by, created_at, updated_at
		FROM match_rules
		WHERE `+strings.Join(conds, " AND ")+`
		ORDER BY LENGTH(path_prefix) DESC, updated_at DESC`,
		args...,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]MatchRule, 0)
	for rows.Next() {
		var r MatchRule
		if err := rows.Scan(
			&r.ID, &r.HouseholdID, &r.SourceID, &r.PathPrefix, &r.Action,
			&r.TargetProvider, &r.TargetKind, &r.TargetExtID,
			&r.SeasonOffset, &r.CreatedBy, &r.CreatedAt, &r.UpdatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (sc *Scraper) UpsertMatchRule(householdID, memberID string, allowedSourceIDs []string, req UpsertMatchRuleRequest) (MatchRule, error) {
	srcID := strings.TrimSpace(req.SourceID)
	if srcID == "" {
		return MatchRule{}, fmt.Errorf("%w: source_id is required", db.ErrInvalidInput)
	}
	if allowedSourceIDs != nil && !containsString(allowedSourceIDs, srcID) {
		return MatchRule{}, ErrForbidden
	}
	normPrefix := pathutil.NormalizePath(req.PathPrefix)
	if normPrefix == "" {
		return MatchRule{}, fmt.Errorf("%w: invalid path_prefix", db.ErrInvalidInput)
	}
	action := strings.ToLower(strings.TrimSpace(req.Action))
	if action != "bind" && action != "ignore" {
		return MatchRule{}, fmt.Errorf("%w: action must be bind or ignore", db.ErrInvalidInput)
	}

	var prov, kind, extID *string
	if action == "bind" {
		p := strings.ToLower(strings.TrimSpace(req.TargetProvider))
		k := strings.ToLower(strings.TrimSpace(req.TargetKind))
		id := strings.TrimSpace(req.TargetExtID)
		if k == "tv" || k == "series" {
			k = db.KindShow
		}
		if p == "" || (k != db.KindMovie && k != db.KindShow) || id == "" {
			return MatchRule{}, fmt.Errorf("%w: target_provider, target_kind, and target_ext_id are required for bind rules", db.ErrInvalidInput)
		}
		prov, kind, extID = &p, &k, &id
	}

	nowMs := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return MatchRule{}, err
	}
	defer func() { _ = tx.Rollback() }()

	if err := ensureSourceOwnedTx(tx, householdID, srcID); err != nil {
		return MatchRule{}, err
	}

	newID := uuid.NewString()
	if _, err := tx.Exec(`
		INSERT INTO match_rules(
			id, household_id, source_id, path_prefix, action,
			target_provider, target_kind, target_ext_id, season_offset,
			created_by, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_id, path_prefix) DO UPDATE SET
			action          = excluded.action,
			target_provider = excluded.target_provider,
			target_kind     = excluded.target_kind,
			target_ext_id   = excluded.target_ext_id,
			season_offset   = excluded.season_offset,
			created_by      = excluded.created_by,
			updated_at      = excluded.updated_at`,
		newID, householdID, srcID, normPrefix, action,
		prov, kind, extID, req.SeasonOffset, memberID, nowMs, nowMs,
	); err != nil {
		return MatchRule{}, err
	}

	var out MatchRule
	if err := tx.QueryRow(`
		SELECT id, household_id, source_id, path_prefix, action,
		       COALESCE(target_provider, ''), COALESCE(target_kind, ''),
		       COALESCE(target_ext_id, ''), season_offset, created_by, created_at, updated_at
		FROM match_rules
		WHERE source_id = ? AND path_prefix = ?`,
		srcID, normPrefix,
	).Scan(
		&out.ID, &out.HouseholdID, &out.SourceID, &out.PathPrefix, &out.Action,
		&out.TargetProvider, &out.TargetKind, &out.TargetExtID,
		&out.SeasonOffset, &out.CreatedBy, &out.CreatedAt, &out.UpdatedAt,
	); err != nil {
		return MatchRule{}, err
	}

	// Re-enqueue affected groups immediately so rule takes effect on matching files.
	if err := enqueueRuleAffectedGroupsTx(tx, householdID, srcID, normPrefix, nowMs); err != nil {
		return MatchRule{}, err
	}

	if err := tx.Commit(); err != nil {
		return MatchRule{}, err
	}
	return out, nil
}

func (sc *Scraper) DeleteMatchRule(householdID string, allowedSourceIDs []string, ruleID string) error {
	var srcID string
	err := sc.store.ReadDB().QueryRow(`
		SELECT source_id FROM match_rules WHERE id = ? AND household_id = ?`,
		ruleID, householdID,
	).Scan(&srcID)
	if errors.Is(err, sql.ErrNoRows) {
		return db.ErrNotFound
	}
	if err != nil {
		return err
	}
	if allowedSourceIDs != nil && !containsString(allowedSourceIDs, srcID) {
		return ErrForbidden
	}
	res, err := sc.store.DB().Exec(`DELETE FROM match_rules WHERE id = ? AND household_id = ?`, ruleID, householdID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return db.ErrNotFound
	}
	return nil
}

func (sc *Scraper) ApplyManualMatch(
	ctx context.Context,
	householdID, memberID string,
	allowedSourceIDs []string,
	req ManualMatchRequest,
) (ManualMatchResult, error) {
	prov := strings.ToLower(strings.TrimSpace(req.Provider))
	kind := strings.ToLower(strings.TrimSpace(req.Kind))
	if kind == "tv" || kind == "series" {
		kind = db.KindShow
	}
	extID := strings.TrimSpace(req.ExternalID)
	if prov == "" || (kind != db.KindMovie && kind != db.KindShow) || extID == "" {
		return ManualMatchResult{}, fmt.Errorf("%w: provider, kind (movie|show), and external_id are required", db.ErrInvalidInput)
	}
	if len(req.FileIDs) == 0 && req.ItemID == nil && (strings.TrimSpace(req.SourceID) == "" || strings.TrimSpace(req.PathPrefix) == "") {
		return ManualMatchResult{}, fmt.Errorf("%w: file_ids, item_id, or (source_id, path_prefix) is required", db.ErrInvalidInput)
	}

	// Phase A: resolve target files before upstream calls.
	files, err := sc.resolveManualMatchTargets(householdID, allowedSourceIDs, req)
	if err != nil {
		return ManualMatchResult{}, err
	}
	if len(files) == 0 {
		return ManualMatchResult{}, db.ErrNotFound
	}

	lang := sc.loadHouseholdLang(householdID)

	// Phase B: fetch upstream metadata outside write TX.
	work, err := sc.meta.GetWork(ctx, prov, kind, extID, lang, false)
	if err != nil {
		return ManualMatchResult{}, err
	}
	workKey := BuildWorkKey(kind, work)
	if workKey == "" {
		workKey = fmt.Sprintf("%s:%s:%s", prov, kind, extID)
	}
	sc.RecordWorkIDLinks(kind, workKey, work, "", 0)

	// Load sidecars from the first file's group/folder for artwork fallback & episode NFO.
	var (
		localShowPoster, localShowBackdrop, localShowLogo string
		seasonPosters                                     = make(map[int]string)
		thumbByDirStem                                    = make(map[string]string)
		sidecars                                          []groupSidecarFile
	)
	if len(files) > 0 {
		_, mode, tgt := ParseAndGroup(files[0].SourceID, files[0].Path)
		if scList, sErr := sc.loadGroupSidecars(householdID, files[0].SourceID, mode, tgt); sErr == nil {
			sidecars = scList
			localShowPoster, localShowBackdrop, localShowLogo, seasonPosters, thumbByDirStem = extractSidecarArtwork(mode, tgt, scList)
		}
	}

	_, firstMode, firstTarget := ParseAndGroup(files[0].SourceID, files[0].Path)
	assignments := sc.buildGroupAssignments(ctx, householdID, kind, firstMode, firstTarget, files, sidecars, thumbByDirStem, 0, req.SeasonOffset)

	seasonsMap := make(map[int]metadata.Season)
	if kind == db.KindShow {
		needed := make(map[int]bool)
		for _, a := range assignments {
			needed[a.seasonNum] = true
		}
		for sNum := range needed {
			if sData, sErr := sc.meta.GetSeason(ctx, work.Source, work.ExternalID, sNum, lang, false); sErr == nil {
				seasonsMap[sNum] = sData
			}
		}
	}

	folderHint := sc.loadSourceFolderHint(householdID, files[0].SourceID, files[0].Path)
	shelf := determineShelf(kind, folderHint, work, work.Source == "bangumi" || work.Source == "anilist")

	lockFiles := true
	if req.Lock != nil {
		lockFiles = *req.Lock
	}
	createRule := true
	if req.CreateRule != nil {
		createRule = *req.CreateRule
	}

	// Phase C: short atomic write TX.
	nowMs := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return ManualMatchResult{}, err
	}
	defer func() { _ = tx.Rollback() }()

	rootID, err := sc.persistGroupMatchTx(tx, persistGroupParams{
		HouseholdID:       householdID,
		Kind:              kind,
		WorkKey:           workKey,
		Shelf:             shelf,
		Work:              work,
		Seasons:           seasonsMap,
		LocalShowPoster:   localShowPoster,
		LocalShowBackdrop: localShowBackdrop,
		LocalShowLogo:     localShowLogo,
		SeasonPosters:     seasonPosters,
		Assignments:       assignments,
		LockFiles:         lockFiles,
		ForceUnlockItem:   false,
		NowMs:             nowMs,
	})
	if err != nil {
		return ManualMatchResult{}, err
	}

	var ruleIDs []string
	if createRule {
		type ruleTarget struct {
			srcID  string
			prefix string
		}
		seenPrefixes := make(map[string]bool)
		var ruleTargets []ruleTarget

		if strings.TrimSpace(req.SourceID) != "" && strings.TrimSpace(req.PathPrefix) != "" {
			if normP := pathutil.NormalizePath(req.PathPrefix); normP != "" {
				ruleTargets = append(ruleTargets, ruleTarget{srcID: req.SourceID, prefix: normP})
			}
		} else {
			for _, f := range files {
				_, mode, tgt := ParseAndGroup(f.SourceID, f.Path)
				pref := tgt
				if mode == "file" {
					pref = f.Path
				}
				k := f.SourceID + "|" + pref
				if !seenPrefixes[k] {
					seenPrefixes[k] = true
					ruleTargets = append(ruleTargets, ruleTarget{srcID: f.SourceID, prefix: pref})
				}
			}
		}

		for _, rt := range ruleTargets {
			rid := uuid.NewString()
			if _, err := tx.Exec(`
				INSERT INTO match_rules(
					id, household_id, source_id, path_prefix, action,
					target_provider, target_kind, target_ext_id, season_offset,
					created_by, created_at, updated_at
				) VALUES (?, ?, ?, ?, 'bind', ?, ?, ?, ?, ?, ?, ?)
				ON CONFLICT(source_id, path_prefix) DO UPDATE SET
					action          = 'bind',
					target_provider = excluded.target_provider,
					target_kind     = excluded.target_kind,
					target_ext_id   = excluded.target_ext_id,
					season_offset   = excluded.season_offset,
					created_by      = excluded.created_by,
					updated_at      = excluded.updated_at`,
				rid, householdID, rt.srcID, rt.prefix,
				prov, kind, extID, req.SeasonOffset,
				memberID, nowMs, nowMs,
			); err != nil {
				return ManualMatchResult{}, err
			}
			var storedID string
			if tx.QueryRow(`SELECT id FROM match_rules WHERE source_id = ? AND path_prefix = ?`, rt.srcID, rt.prefix).Scan(&storedID) == nil {
				ruleIDs = append(ruleIDs, storedID)
			}
		}
	}

	if err := tx.Commit(); err != nil {
		return ManualMatchResult{}, err
	}

	return ManualMatchResult{
		ItemID:       rootID,
		WorkKey:      workKey,
		Kind:         kind,
		Title:        work.Title,
		MatchedFiles: len(files),
		RuleIDs:      ruleIDs,
	}, nil
}

func (sc *Scraper) EditMediaItem(householdID string, allowedSourceIDs []string, itemID int64, req EditItemRequest) error {
	if err := sc.checkItemVisibility(householdID, allowedSourceIDs, itemID); err != nil {
		return err
	}

	var sets []string
	var args []any

	if req.Title != nil {
		t := strings.TrimSpace(*req.Title)
		if t == "" {
			return fmt.Errorf("%w: title cannot be empty", db.ErrInvalidInput)
		}
		sets = append(sets, "title = ?")
		args = append(args, t)
		if req.SortTitle == nil {
			sets = append(sets, "sort_title = ?")
			args = append(args, buildSortTitle(t))
		}
	}
	if req.SortTitle != nil {
		sets = append(sets, "sort_title = ?")
		args = append(args, strings.TrimSpace(*req.SortTitle))
	}
	if req.OriginalTitle != nil {
		sets = append(sets, "original_title = ?")
		args = append(args, nullableTrimmedStr(*req.OriginalTitle))
	}
	if req.Year != nil {
		sets = append(sets, "year = ?")
		args = append(args, *req.Year)
	}
	if req.ReleaseDate != nil {
		sets = append(sets, "release_date = ?")
		args = append(args, nullableTrimmedStr(*req.ReleaseDate))
	}
	if req.Summary != nil {
		sets = append(sets, "summary = ?")
		args = append(args, nullableTrimmedStr(*req.Summary))
	}
	if req.Tagline != nil {
		sets = append(sets, "tagline = ?")
		args = append(args, nullableTrimmedStr(*req.Tagline))
	}
	if req.ContentRating != nil {
		sets = append(sets, "content_rating = ?")
		args = append(args, nullableTrimmedStr(*req.ContentRating))
	}
	if req.Studio != nil {
		sets = append(sets, "studio = ?")
		args = append(args, nullableTrimmedStr(*req.Studio))
	}
	if req.Rating != nil {
		sets = append(sets, "rating = ?")
		args = append(args, *req.Rating)
	}
	if req.LibraryType != nil {
		lt := strings.ToLower(strings.TrimSpace(*req.LibraryType))
		if lt == "" {
			return fmt.Errorf("%w: invalid library_type", db.ErrInvalidInput)
		}
		sets = append(sets, "library_type = ?")
		args = append(args, lt)
	}
	if req.PosterSource != nil {
		sets = append(sets, "poster_source = ?")
		args = append(args, nullableTrimmedStr(*req.PosterSource))
	}
	if req.BackdropSource != nil {
		sets = append(sets, "backdrop_source = ?")
		args = append(args, nullableTrimmedStr(*req.BackdropSource))
	}
	if req.LogoSource != nil {
		sets = append(sets, "logo_source = ?")
		args = append(args, nullableTrimmedStr(*req.LogoSource))
	}

	hasFieldEdits := len(sets) > 0
	if req.Locked != nil {
		lockInt := 0
		if *req.Locked {
			lockInt = 1
		}
		sets = append(sets, "locked = ?")
		args = append(args, lockInt)
	} else if hasFieldEdits {
		sets = append(sets, "locked = 1")
	}

	if len(sets) == 0 {
		return fmt.Errorf("%w: no fields to update", db.ErrInvalidInput)
	}

	nowMs := sc.store.NowMs()
	sets = append(sets, "updated_at = ?")
	args = append(args, nowMs, itemID, householdID)

	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(
		fmt.Sprintf(`UPDATE media_items SET %s WHERE id = ? AND household_id = ?`, strings.Join(sets, ", ")),
		args...,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return db.ErrNotFound
	}
	if _, err := db.AppendChangeTx(tx, householdID, nil, "item", strconv.FormatInt(itemID, 10), "upsert", nowMs); err != nil {
		return err
	}
	return tx.Commit()
}

func (sc *Scraper) RescrapeMediaItem(ctx context.Context, householdID string, allowedSourceIDs []string, itemID int64, req RescrapeRequest) error {
	if err := sc.checkItemVisibility(householdID, allowedSourceIDs, itemID); err != nil {
		return err
	}

	// Resolve root item (show or movie).
	var (
		rootID   int64
		itemKind string
		showID   sql.NullInt64
	)
	err := sc.store.ReadDB().QueryRow(`
		SELECT id, kind, show_id FROM media_items WHERE id = ? AND household_id = ?`,
		itemID, householdID,
	).Scan(&rootID, &itemKind, &showID)
	if errors.Is(err, sql.ErrNoRows) {
		return db.ErrNotFound
	}
	if err != nil {
		return err
	}
	if showID.Valid && showID.Int64 > 0 {
		rootID = showID.Int64
	}

	files, err := sc.loadItemVideoFiles(householdID, rootID)
	if err != nil {
		return err
	}

	lang := sc.loadHouseholdLang(householdID)
	prov, pKind, extID, wk, foundTarget := sc.loadItemExternalTarget(householdID, rootID)
	if !foundTarget && !req.Reidentify {
		return fmt.Errorf("%w: item has no external metadata target", db.ErrInvalidInput)
	}

	var (
		work          metadata.Work
		workKey       string
		impliedSeason int
		isAnime       bool
	)

	if req.Reidentify && len(files) > 0 {
		_, mode, tgt := ParseAndGroup(files[0].SourceID, files[0].Path)
		sidecars, _ := sc.loadGroupSidecars(householdID, files[0].SourceID, mode, tgt)
		titleNFO, nfoWork := sc.readGroupTitleNFO(ctx, householdID, mode, tgt, files[0].Path, sidecars)
		folderHint := sc.loadSourceFolderHint(householdID, files[0].SourceID, files[0].Path)
		idReq, _ := sc.buildIdentifyRequest(mode, tgt, files[0], folderHint, titleNFO, lang)
		idReq.Refresh = true
		res, idErr := sc.IdentifyPublic(ctx, idReq)
		if idErr != nil {
			return idErr
		}
		if !res.Matched || res.Work == nil {
			return fmt.Errorf("%w: could not re-identify item", db.ErrNotFound)
		}
		pKind = res.Kind
		work = *res.Work
		workKey = res.WorkKey
		impliedSeason = res.ImpliedSeason
		isAnime = idReq.IsAnime
		if nfoWork != nil {
			mergeNFOIntoWork(&work, nfoWork)
		}
	} else {
		if prov == "" || extID == "" {
			return fmt.Errorf("%w: item has no external provider id", db.ErrInvalidInput)
		}
		w, gErr := sc.meta.GetWork(ctx, prov, pKind, extID, lang, true)
		if gErr != nil {
			return gErr
		}
		work = w
		workKey = wk
		if workKey == "" {
			workKey = BuildWorkKey(pKind, work)
		}
		sc.RecordWorkIDLinks(pKind, workKey, work, "", 0)
	}

	var (
		localShowPoster, localShowBackdrop, localShowLogo string
		seasonPosters                                     = make(map[int]string)
		thumbByDirStem                                    = make(map[string]string)
		sidecars                                          []groupSidecarFile
		assignments                                       []groupEpisodeAssignment
		folderHint                                        string
	)
	if len(files) > 0 {
		_, mode, tgt := ParseAndGroup(files[0].SourceID, files[0].Path)
		folderHint = sc.loadSourceFolderHint(householdID, files[0].SourceID, files[0].Path)
		if scList, sErr := sc.loadGroupSidecars(householdID, files[0].SourceID, mode, tgt); sErr == nil {
			sidecars = scList
			localShowPoster, localShowBackdrop, localShowLogo, seasonPosters, thumbByDirStem = extractSidecarArtwork(mode, tgt, scList)
		}
		assignments = sc.buildGroupAssignments(ctx, householdID, pKind, mode, tgt, files, sidecars, thumbByDirStem, impliedSeason, 0)
	}

	seasonsMap := make(map[int]metadata.Season)
	if pKind == db.KindShow && work.Source != "" && work.ExternalID != "" {
		needed := make(map[int]bool)
		for _, a := range assignments {
			needed[a.seasonNum] = true
		}
		if len(needed) == 0 {
			needed[1] = true
		}
		for sNum := range needed {
			if sData, sErr := sc.meta.GetSeason(ctx, work.Source, work.ExternalID, sNum, lang, true); sErr == nil {
				seasonsMap[sNum] = sData
			}
		}
	}

	shelf := determineShelf(pKind, folderHint, work, isAnime || work.Source == "bangumi" || work.Source == "anilist")

	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	_, err = sc.persistGroupMatchTx(tx, persistGroupParams{
		HouseholdID:       householdID,
		Kind:              pKind,
		WorkKey:           workKey,
		Shelf:             shelf,
		Work:              work,
		Seasons:           seasonsMap,
		LocalShowPoster:   localShowPoster,
		LocalShowBackdrop: localShowBackdrop,
		LocalShowLogo:     localShowLogo,
		SeasonPosters:     seasonPosters,
		Assignments:       assignments,
		LockFiles:         false,
		ForceUnlockItem:   req.Unlock,
		NowMs:             sc.store.NowMs(),
	})
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (sc *Scraper) resolveManualMatchTargets(householdID string, allowedSourceIDs []string, req ManualMatchRequest) ([]groupVideoFile, error) {
	seen := make(map[int64]bool)
	var out []groupVideoFile
	appendFile := func(f groupVideoFile) error {
		if allowedSourceIDs != nil && !containsString(allowedSourceIDs, f.SourceID) {
			return ErrForbidden
		}
		if !seen[f.ID] {
			seen[f.ID] = true
			out = append(out, f)
		}
		return nil
	}

	if len(req.FileIDs) > 0 {
		ph, inArgs := inClauseInt64(req.FileIDs)
		args := append([]any{householdID}, inArgs...)
		rows, err := sc.store.ReadDB().Query(`
			SELECT id, household_id, source_id, path, item_id, match_state, match_locked,
			       parsed_json, client_hints_json, mtime_s, ctime_s, added_at
			FROM media_files
			WHERE household_id = ? AND role = 'video' AND state = 'active' AND id IN (`+ph+`)`,
			args...,
		)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var f groupVideoFile
			var locked int
			if err := rows.Scan(&f.ID, &f.HouseholdID, &f.SourceID, &f.Path, &f.ItemID, &f.MatchState, &locked, &f.ParsedJSON, &f.ClientHintsJSON, &f.MtimeS, &f.CtimeS, &f.AddedAt); err != nil {
				return nil, err
			}
			f.MatchLocked = locked != 0
			if err := appendFile(f); err != nil {
				return nil, err
			}
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}

	if req.ItemID != nil {
		if err := sc.checkItemVisibility(householdID, allowedSourceIDs, *req.ItemID); err != nil {
			return nil, err
		}
		list, err := sc.loadItemVideoFiles(householdID, *req.ItemID)
		if err != nil {
			return nil, err
		}
		for _, f := range list {
			if err := appendFile(f); err != nil {
				return nil, err
			}
		}
	}

	if strings.TrimSpace(req.SourceID) != "" && strings.TrimSpace(req.PathPrefix) != "" {
		if allowedSourceIDs != nil && !containsString(allowedSourceIDs, req.SourceID) {
			return nil, ErrForbidden
		}
		normPrefix := pathutil.NormalizePath(req.PathPrefix)
		if normPrefix == "" {
			return nil, fmt.Errorf("%w: invalid path_prefix", db.ErrInvalidInput)
		}
		likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
		pat := "/%"
		if normPrefix != pathutil.RootPath {
			pat = likeEsc.Replace(normPrefix) + "/%"
		}
		rows, err := sc.store.ReadDB().Query(`
			SELECT id, household_id, source_id, path, item_id, match_state, match_locked,
			       parsed_json, client_hints_json, mtime_s, ctime_s, added_at
			FROM media_files
			WHERE household_id = ? AND source_id = ? AND role = 'video' AND state = 'active'
			  AND (path = ? OR path LIKE ? ESCAPE '\')`,
			householdID, req.SourceID, normPrefix, pat,
		)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var f groupVideoFile
			var locked int
			if err := rows.Scan(&f.ID, &f.HouseholdID, &f.SourceID, &f.Path, &f.ItemID, &f.MatchState, &locked, &f.ParsedJSON, &f.ClientHintsJSON, &f.MtimeS, &f.CtimeS, &f.AddedAt); err != nil {
				return nil, err
			}
			f.MatchLocked = locked != 0
			if err := appendFile(f); err != nil {
				return nil, err
			}
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}

	return out, nil
}

func (sc *Scraper) loadItemVideoFiles(householdID string, itemID int64) ([]groupVideoFile, error) {
	rows, err := sc.store.ReadDB().Query(`
		SELECT mf.id, mf.household_id, mf.source_id, mf.path, mf.item_id, mf.match_state, mf.match_locked,
		       mf.parsed_json, mf.client_hints_json, mf.mtime_s, mf.ctime_s, mf.added_at
		FROM media_files mf
		JOIN media_items mi ON mi.id = mf.item_id
		WHERE mf.household_id = ? AND mf.role = 'video' AND mf.state = 'active'
		  AND (mi.id = ? OR mi.parent_id = ? OR mi.show_id = ?)
		ORDER BY mf.path ASC`,
		householdID, itemID, itemID, itemID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []groupVideoFile
	for rows.Next() {
		var f groupVideoFile
		var locked int
		if err := rows.Scan(&f.ID, &f.HouseholdID, &f.SourceID, &f.Path, &f.ItemID, &f.MatchState, &locked, &f.ParsedJSON, &f.ClientHintsJSON, &f.MtimeS, &f.CtimeS, &f.AddedAt); err != nil {
			return nil, err
		}
		f.MatchLocked = locked != 0
		out = append(out, f)
	}
	return out, rows.Err()
}

func (sc *Scraper) checkItemVisibility(householdID string, allowedSourceIDs []string, itemID int64) error {
	var exists int
	if err := sc.store.ReadDB().QueryRow(`SELECT COUNT(*) FROM media_items WHERE id = ? AND household_id = ?`, itemID, householdID).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return db.ErrNotFound
	}
	if allowedSourceIDs == nil {
		return nil
	}
	if len(allowedSourceIDs) == 0 {
		return ErrForbidden
	}
	ph, inArgs := inClause(allowedSourceIDs)
	args := append([]any{householdID, itemID, itemID, itemID}, inArgs...)
	var visCount int
	if err := sc.store.ReadDB().QueryRow(`
		SELECT COUNT(*)
		FROM media_files mf
		JOIN media_items mi ON mi.id = mf.item_id
		WHERE mf.household_id = ? AND mf.state != 'tombstoned'
		  AND (mi.id = ? OR mi.parent_id = ? OR mi.show_id = ?)
		  AND mf.source_id IN (`+ph+`)`,
		args...,
	).Scan(&visCount); err != nil {
		return err
	}
	if visCount == 0 {
		return ErrForbidden
	}
	return nil
}

func ensureSourceOwnedTx(tx *sql.Tx, householdID, sourceID string) error {
	var cnt int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM sources WHERE id = ? AND household_id = ? AND status = 'active'`, sourceID, householdID).Scan(&cnt); err != nil {
		return err
	}
	if cnt == 0 {
		return db.ErrNotFound
	}
	return nil
}

func updateMatchingFilesStateByPrefixTx(tx *sql.Tx, householdID, sourceID, normPrefix, matchState string, nowMs int64) (int64, error) {
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	pat := "/%"
	if normPrefix != pathutil.RootPath {
		pat = likeEsc.Replace(normPrefix) + "/%"
	}
	res, err := tx.Exec(`
		UPDATE media_files
		SET match_state = ?, updated_at = ?
		WHERE household_id = ? AND source_id = ? AND role = 'video' AND state = 'active' AND match_locked = 0
		  AND (path = ? OR path LIKE ? ESCAPE '\')`,
		matchState, nowMs, householdID, sourceID, normPrefix, pat,
	)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func enqueueRuleAffectedGroupsTx(tx *sql.Tx, householdID, sourceID, normPrefix string, nowMs int64) error {
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	pat := "/%"
	if normPrefix != pathutil.RootPath {
		pat = likeEsc.Replace(normPrefix) + "/%"
	}
	rows, err := tx.Query(`
		SELECT path FROM media_files
		WHERE household_id = ? AND source_id = ? AND role = 'video' AND state = 'active' AND match_locked = 0
		  AND (path = ? OR path LIKE ? ESCAPE '\')`,
		householdID, sourceID, normPrefix, pat,
	)
	if err != nil {
		return err
	}
	var paths []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil {
			paths = append(paths, p)
		}
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	groups := make(map[string]bool)
	for _, vp := range paths {
		_, _, gk := ParseAndGroup(sourceID, vp)
		if gk != "" {
			groups[gk] = true
		}
	}
	for gk := range groups {
		if _, err := tx.Exec(`
			INSERT INTO identify_queue(
				household_id, group_key, reason, status, not_before, attempts, last_error_code, created_at, updated_at
			) VALUES (?, ?, 'changed', 'queued', ?, 0, '', ?, ?)
			ON CONFLICT(household_id, group_key) DO UPDATE SET
				status = 'queued',
				reason = 'changed',
				not_before = excluded.not_before,
				attempts = 0,
				last_error_code = '',
				updated_at = excluded.updated_at`,
			householdID, gk, nowMs, nowMs, nowMs,
		); err != nil {
			return err
		}
	}
	return nil
}

func containsString(list []string, target string) bool {
	for _, item := range list {
		if item == target {
			return true
		}
	}
	return false
}

func inClause(list []string) (string, []any) {
	ph := make([]string, len(list))
	args := make([]any, len(list))
	for i, s := range list {
		ph[i] = "?"
		args[i] = s
	}
	return strings.Join(ph, ","), args
}

func inClauseInt64(list []int64) (string, []any) {
	ph := make([]string, len(list))
	args := make([]any, len(list))
	for i, v := range list {
		ph[i] = "?"
		args[i] = v
	}
	return strings.Join(ph, ","), args
}

func nullableTrimmedStr(s string) *string {
	t := strings.TrimSpace(s)
	if t == "" {
		return nil
	}
	return &t
}

var _ = path.Base
