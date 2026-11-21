package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/metadata"
	"plezy/media_library/internal/pathutil"
)

type groupVideoFile struct {
	ID              int64
	HouseholdID     string
	SourceID        string
	Path            string
	ItemID          sql.NullInt64
	MatchState      string
	MatchLocked     bool
	ParsedJSON      sql.NullString
	ClientHintsJSON sql.NullString
	MtimeS          sql.NullInt64
	CtimeS          sql.NullInt64
	AddedAt         int64
}

type groupSidecarFile struct {
	ID            int64
	Path          string
	Role          string
	OwnerFileID   sql.NullInt64
	SidecarSHA256 string
}

type matchRuleRow struct {
	ID             string
	PathPrefix     string
	Action         string
	TargetProvider string
	TargetKind     string
	TargetExtID    string
	SeasonOffset   int
}

type groupEpisodeAssignment struct {
	file       groupVideoFile
	seasonNum  int
	epNum      int
	epNFO      *metadata.Episode
	thumbSHA   string
	seasonDir  string
}

type persistGroupParams struct {
	HouseholdID       string
	Kind              string
	WorkKey           string
	Shelf             string
	Work              metadata.Work
	Seasons           map[int]metadata.Season
	LocalShowPoster   string
	LocalShowBackdrop string
	LocalShowLogo     string
	SeasonPosters     map[int]string
	Assignments       []groupEpisodeAssignment
	LockFiles         bool
	ForceUnlockItem   bool
	NowMs             int64
}

// IdentifyGroup scrapes metadata for one identify_queue group_key and persists
// the resulting movie/show/season/episode media_items and file links.
func (sc *Scraper) IdentifyGroup(ctx context.Context, householdID, groupKey string) error {
	if sc == nil || sc.store == nil || sc.meta == nil {
		return nil
	}
	sourceID, mode, targetPath, ok := ParseGroupKey(groupKey)
	if !ok {
		return nil
	}

	// Phase A: read file facts, folder hints, match_rules, and sidecars without holding any write lock.
	files, err := sc.loadGroupVideoFiles(householdID, groupKey, sourceID, mode, targetPath)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return nil
	}

	var hasUnlockedNeedingWork bool
	var pinnedItemID int64
	for _, f := range files {
		if !f.MatchLocked {
			hasUnlockedNeedingWork = true
		} else if pinnedItemID == 0 && f.ItemID.Valid {
			pinnedItemID = f.ItemID.Int64
		}
	}
	if !hasUnlockedNeedingWork {
		return nil
	}

	lang := sc.loadHouseholdLang(householdID)
	folderHint := sc.loadSourceFolderHint(householdID, sourceID, files[0].Path)

	rule, err := sc.findLongestMatchRule(householdID, sourceID, targetPath, files[0].Path)
	if err != nil {
		return err
	}
	if rule != nil && rule.Action == "ignore" {
		return sc.markGroupFilesState(householdID, files, db.MatchIgnored)
	}

	sidecars, err := sc.loadGroupSidecars(householdID, sourceID, mode, targetPath)
	if err != nil {
		return err
	}

	// Phase B: fetch upstream metadata outside DB transactions.
	var (
		resolvedKind  string
		resolvedWork  metadata.Work
		workKey       string
		impliedSeason int
		seasonOffset  int
		isAnime       bool
		nfoWork       *metadata.Work
		titleNFO      string
	)

	titleNFO, nfoWork = sc.readGroupTitleNFO(ctx, householdID, mode, targetPath, files[0].Path, sidecars)
	localShowPoster, localShowBackdrop, localShowLogo, seasonPosters, thumbByDirStem := extractSidecarArtwork(mode, targetPath, sidecars)

	if rule != nil && rule.Action == "bind" {
		seasonOffset = rule.SeasonOffset
		w, gErr := sc.meta.GetWork(ctx, rule.TargetProvider, rule.TargetKind, rule.TargetExtID, lang, false)
		if gErr != nil {
			return gErr
		}
		resolvedKind = rule.TargetKind
		resolvedWork = w
		workKey = BuildWorkKey(resolvedKind, resolvedWork)
		sc.RecordWorkIDLinks(resolvedKind, workKey, resolvedWork, "", 0)
	} else if pinnedItemID > 0 {
		prov, pKind, extID, wk, foundPinned := sc.loadItemExternalTarget(householdID, pinnedItemID)
		if foundPinned {
			if prov != "" && extID != "" {
				if w, gErr := sc.meta.GetWork(ctx, prov, pKind, extID, lang, false); gErr == nil {
					resolvedKind = pKind
					resolvedWork = w
					workKey = wk
				} else if !errors.Is(gErr, metadata.ErrNotFound) {
					return gErr
				}
			}
			if workKey == "" {
				wFallback, okFallback := sc.loadItemAsWork(householdID, pinnedItemID)
				if okFallback {
					resolvedKind = wFallback.Kind
					resolvedWork = wFallback
					workKey = wk
				}
			}
		}
	}

	if workKey == "" {
		req, guessKind := sc.buildIdentifyRequest(mode, targetPath, files[0], folderHint, titleNFO, lang)
		isAnime = req.IsAnime

		// Deterministic shortcut via work_id_links for explicit external IDs in filename/folder/NFO.
		emb := ExtractEmbeddedExternalIDs(req.Filename, req.FolderHint, req.Title)
		if nfoWork != nil {
			mergeNFOEmbeddedIDs(&emb, nfoWork)
		}
		mergeClientHintsEmbedded(&emb, files[0].ClientHintsJSON.String)

		if ck, impS, okLink := sc.resolveEmbeddedLink(guessKind, emb); okLink {
			if cProv, cKind, cExtID, okParse := parseWorkKeyParts(ck); okParse {
				if w, gErr := sc.meta.GetWork(ctx, cProv, cKind, cExtID, lang, false); gErr == nil {
					resolvedKind = cKind
					resolvedWork = w
					workKey = ck
					impliedSeason = impS
				}
			}
		}

		if workKey == "" {
			res, idErr := sc.IdentifyPublic(ctx, req)
			if idErr != nil {
				if errors.Is(idErr, metadata.ErrNotConfigured) && nfoWork != nil && strings.TrimSpace(nfoWork.Title) != "" {
					resolvedKind = guessKind
					resolvedWork = *nfoWork
					workKey = BuildWorkKey(resolvedKind, resolvedWork)
					if workKey == "" {
						workKey = fmt.Sprintf("nfo:%s:%s", resolvedKind, targetPath)
					}
				} else if errors.Is(idErr, metadata.ErrInvalidInput) {
					return sc.markGroupFilesState(householdID, files, db.MatchUnmatched)
				} else {
					return idErr
				}
			} else if !res.Matched || res.Work == nil {
				if nfoWork != nil && strings.TrimSpace(nfoWork.Title) != "" {
					resolvedKind = guessKind
					resolvedWork = *nfoWork
					workKey = BuildWorkKey(resolvedKind, resolvedWork)
					if workKey == "" {
						workKey = fmt.Sprintf("nfo:%s:%s", resolvedKind, targetPath)
					}
				} else {
					return sc.markGroupFilesState(householdID, files, db.MatchUnmatched)
				}
			} else {
				resolvedKind = res.Kind
				resolvedWork = *res.Work
				workKey = res.WorkKey
				impliedSeason = res.ImpliedSeason
			}
		}
	}

	if nfoWork != nil {
		mergeNFOIntoWork(&resolvedWork, nfoWork)
	}

	// Build assignments for files in this group (filter out locked files pointing elsewhere? No: only mutate unlocked files).
	var unlockedFiles []groupVideoFile
	for _, f := range files {
		if !f.MatchLocked {
			unlockedFiles = append(unlockedFiles, f)
		}
	}
	if len(unlockedFiles) == 0 {
		return nil
	}

	assignments := sc.buildGroupAssignments(ctx, householdID, resolvedKind, mode, targetPath, unlockedFiles, sidecars, thumbByDirStem, impliedSeason, seasonOffset)

	seasonsMap := make(map[int]metadata.Season)
	if resolvedKind == db.KindShow && resolvedWork.Source != "" && resolvedWork.ExternalID != "" && resolvedWork.Source != "nfo" {
		neededSeasons := make(map[int]bool)
		for _, a := range assignments {
			neededSeasons[a.seasonNum] = true
		}
		for sNum := range neededSeasons {
			seasonData, sErr := sc.meta.GetSeason(ctx, resolvedWork.Source, resolvedWork.ExternalID, sNum, lang, false)
			if sErr == nil {
				seasonsMap[sNum] = seasonData
			} else if !errors.Is(sErr, metadata.ErrNotFound) && !errors.Is(sErr, metadata.ErrInvalidInput) {
				applog.Debugf("scraper", "拉取分季元数据跳过 [%s:%s S%02d]: %v", resolvedWork.Source, resolvedWork.ExternalID, sNum, sErr)
			}
		}
	}

	shelf := determineShelf(resolvedKind, folderHint, resolvedWork, isAnime)

	// Phase C: short atomic write TX.
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	_, err = sc.persistGroupMatchTx(tx, persistGroupParams{
		HouseholdID:       householdID,
		Kind:              resolvedKind,
		WorkKey:           workKey,
		Shelf:             shelf,
		Work:              resolvedWork,
		Seasons:           seasonsMap,
		LocalShowPoster:   localShowPoster,
		LocalShowBackdrop: localShowBackdrop,
		LocalShowLogo:     localShowLogo,
		SeasonPosters:     seasonPosters,
		Assignments:       assignments,
		LockFiles:         false,
		ForceUnlockItem:   false,
		NowMs:             sc.store.NowMs(),
	})
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (sc *Scraper) loadGroupVideoFiles(householdID, groupKey, sourceID, mode, targetPath string) ([]groupVideoFile, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if mode == "file" {
		rows, err = sc.store.ReadDB().Query(`
			SELECT id, household_id, source_id, path, item_id, match_state, match_locked,
			       parsed_json, client_hints_json, mtime_s, ctime_s, added_at
			FROM media_files
			WHERE household_id = ? AND source_id = ? AND path = ? AND role = 'video' AND state = 'active'
			ORDER BY id ASC`,
			householdID, sourceID, targetPath,
		)
	} else {
		likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
		pat := likeEsc.Replace(targetPath) + "/%"
		if targetPath == pathutil.RootPath {
			pat = "/%"
		}
		rows, err = sc.store.ReadDB().Query(`
			SELECT id, household_id, source_id, path, item_id, match_state, match_locked,
			       parsed_json, client_hints_json, mtime_s, ctime_s, added_at
			FROM media_files
			WHERE household_id = ? AND source_id = ? AND path LIKE ? ESCAPE '\' AND role = 'video' AND state = 'active'
			ORDER BY path ASC`,
			householdID, sourceID, pat,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []groupVideoFile
	for rows.Next() {
		var (
			f      groupVideoFile
			locked int
		)
		if err := rows.Scan(
			&f.ID, &f.HouseholdID, &f.SourceID, &f.Path, &f.ItemID, &f.MatchState, &locked,
			&f.ParsedJSON, &f.ClientHintsJSON, &f.MtimeS, &f.CtimeS, &f.AddedAt,
		); err != nil {
			return nil, err
		}
		f.MatchLocked = locked != 0
		if mode == "dir" {
			_, _, gk := ParseAndGroup(sourceID, f.Path)
			if gk != groupKey {
				continue
			}
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (sc *Scraper) loadHouseholdLang(householdID string) string {
	var lang string
	err := sc.store.ReadDB().QueryRow(`SELECT COALESCE(display_lang, '') FROM households WHERE id = ?`, householdID).Scan(&lang)
	if err == nil && strings.TrimSpace(lang) != "" {
		return strings.TrimSpace(lang)
	}
	return sc.store.GetServerSettings().ScraperLang
}

func (sc *Scraper) loadSourceFolderHint(householdID, sourceID, filePath string) string {
	rows, err := sc.store.ReadDB().Query(`
		SELECT path, COALESCE(library_hint, '')
		FROM source_folders
		WHERE household_id = ? AND source_id = ?`,
		householdID, sourceID,
	)
	if err != nil {
		return ""
	}
	defer rows.Close()

	bestLen := -1
	bestHint := ""
	for rows.Next() {
		var fp, hint string
		if rows.Scan(&fp, &hint) != nil {
			continue
		}
		if pathHasPrefix(filePath, fp) && len(fp) > bestLen {
			bestLen = len(fp)
			bestHint = strings.ToLower(strings.TrimSpace(hint))
		}
	}
	return bestHint
}

func (sc *Scraper) findLongestMatchRule(householdID, sourceID, groupTarget, samplePath string) (*matchRuleRow, error) {
	rows, err := sc.store.ReadDB().Query(`
		SELECT id, path_prefix, action, COALESCE(target_provider, ''), COALESCE(target_kind, ''),
		       COALESCE(target_ext_id, ''), season_offset
		FROM match_rules
		WHERE household_id = ? AND source_id = ?`,
		householdID, sourceID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var best *matchRuleRow
	for rows.Next() {
		var r matchRuleRow
		if err := rows.Scan(&r.ID, &r.PathPrefix, &r.Action, &r.TargetProvider, &r.TargetKind, &r.TargetExtID, &r.SeasonOffset); err != nil {
			return nil, err
		}
		if pathHasPrefix(samplePath, r.PathPrefix) || (groupTarget != "" && pathHasPrefix(groupTarget, r.PathPrefix)) {
			if best == nil || len(r.PathPrefix) > len(best.PathPrefix) {
				cp := r
				best = &cp
			}
		}
	}
	return best, rows.Err()
}

func pathHasPrefix(target, prefix string) bool {
	if prefix == "" {
		return false
	}
	if prefix == pathutil.RootPath {
		return strings.HasPrefix(target, pathutil.RootPath)
	}
	return target == prefix || strings.HasPrefix(target, prefix+"/")
}

func (sc *Scraper) loadGroupSidecars(householdID, sourceID, mode, targetPath string) ([]groupSidecarFile, error) {
	baseDir := targetPath
	if mode == "file" {
		baseDir = pathutil.ParentPath(targetPath)
	}
	likeEsc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	pat := "/%"
	if baseDir != pathutil.RootPath {
		pat = likeEsc.Replace(baseDir) + "/%"
	}
	rows, err := sc.store.ReadDB().Query(`
		SELECT id, path, role, owner_file_id, COALESCE(sidecar_sha256, '')
		FROM media_files
		WHERE household_id = ? AND source_id = ? AND role IN ('nfo', 'artwork')
		  AND state = 'active' AND path LIKE ? ESCAPE '\'`,
		householdID, sourceID, pat,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []groupSidecarFile
	for rows.Next() {
		var s groupSidecarFile
		if err := rows.Scan(&s.ID, &s.Path, &s.Role, &s.OwnerFileID, &s.SidecarSHA256); err != nil {
			return nil, err
		}
		if mode == "file" && pathutil.ParentPath(s.Path) != baseDir {
			continue
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (sc *Scraper) readGroupTitleNFO(ctx context.Context, householdID, mode, targetPath, sampleVideoPath string, sidecars []groupSidecarFile) (string, *metadata.Work) {
	if sc.sidecars == nil {
		return "", nil
	}
	videoDir := pathutil.ParentPath(sampleVideoPath)
	videoStem := strings.ToLower(stripFileExt(pathutil.BaseName(sampleVideoPath)))

	var chosenSHA string
	bestPrio := -1
	for _, s := range sidecars {
		if s.Role != db.FileRoleNfo || s.SidecarSHA256 == "" {
			continue
		}
		dir := pathutil.ParentPath(s.Path)
		baseLow := strings.ToLower(pathutil.BaseName(s.Path))
		stemLow := stripFileExt(baseLow)
		prio := -1
		if mode == "dir" {
			if dir == targetPath {
				if baseLow == "tvshow.nfo" {
					prio = 100
				} else {
					prio = 50
				}
			}
		} else {
			if dir == videoDir {
				if stemLow == videoStem {
					prio = 100
				} else if baseLow == "movie.nfo" {
					prio = 90
				}
			}
		}
		if prio > bestPrio {
			bestPrio = prio
			chosenSHA = s.SidecarSHA256
		}
	}
	if chosenSHA == "" {
		return "", nil
	}
	txt, err := sc.sidecars.ReadText(ctx, householdID, chosenSHA)
	if err != nil || strings.TrimSpace(txt) == "" {
		return "", nil
	}
	return txt, ReadTitleNFO(txt, "")
}

func extractSidecarArtwork(mode, targetPath string, sidecars []groupSidecarFile) (poster, backdrop, logo string, seasonPosters map[int]string, thumbByDirStem map[string]string) {
	seasonPosters = make(map[int]string)
	thumbByDirStem = make(map[string]string)
	rootDir := targetPath
	if mode == "file" {
		rootDir = pathutil.ParentPath(targetPath)
	}

	for _, s := range sidecars {
		if s.Role != db.FileRoleArtwork || s.SidecarSHA256 == "" {
			continue
		}
		dir := pathutil.ParentPath(s.Path)
		baseLow := strings.ToLower(pathutil.BaseName(s.Path))
		stemLow := stripFileExt(baseLow)
		val := "sidecar:" + s.SidecarSHA256

		if strings.HasSuffix(stemLow, "-thumb") {
			targetStem := strings.TrimSuffix(stemLow, "-thumb")
			thumbByDirStem[dir+"/"+targetStem] = val
		} else if stemLow == "thumb" {
			thumbByDirStem[dir+"/*"] = val
		}

		if dir == rootDir {
			switch {
			case stemLow == "poster" || stemLow == "folder" || stemLow == "cover" || strings.HasSuffix(stemLow, "-poster"):
				if poster == "" || stemLow == "poster" {
					poster = val
				}
			case stemLow == "fanart" || stemLow == "backdrop" || strings.HasSuffix(stemLow, "-fanart") || strings.HasSuffix(stemLow, "-backdrop"):
				if backdrop == "" || stemLow == "fanart" || stemLow == "backdrop" {
					backdrop = val
				}
			case stemLow == "clearlogo" || stemLow == "logo" || strings.HasSuffix(stemLow, "-clearlogo") || strings.HasSuffix(stemLow, "-logo"):
				if logo == "" || stemLow == "clearlogo" {
					logo = val
				}
			}
			if mode == "dir" && strings.HasPrefix(stemLow, "season") && strings.HasSuffix(stemLow, "-poster") {
				mid := strings.TrimSuffix(strings.TrimPrefix(stemLow, "season"), "-poster")
				if mid == "-specials" || mid == "00" || mid == "0" {
					seasonPosters[0] = val
				} else if n, err := strconv.Atoi(strings.TrimLeft(mid, "0")); err == nil && n >= 0 {
					seasonPosters[n] = val
				}
			}
			continue
		}

		if mode == "dir" && pathutil.ParentPath(dir) == rootDir {
			pf := ParseFolderName(pathutil.BaseName(dir))
			if pf.IsSeasonFolder && pf.Season != nil && (stemLow == "poster" || stemLow == "folder" || stemLow == "cover") {
				seasonPosters[*pf.Season] = val
			}
		}
	}
	return
}

func (sc *Scraper) buildIdentifyRequest(mode, targetPath string, sample groupVideoFile, folderHint, titleNFO, lang string) (PublicIdentifyRequest, string) {
	base := pathutil.BaseName(sample.Path)
	parsedFile := ParseFileName(base)
	var parsedFolder ParsedFolder
	var folderName string
	if mode == "dir" {
		folderName = pathutil.BaseName(targetPath)
		parsedFolder = ParseFolderName(folderName)
	} else {
		pDir := pathutil.ParentPath(sample.Path)
		if pDir != pathutil.RootPath {
			folderName = pathutil.BaseName(pDir)
			parsedFolder = ParseFolderName(folderName)
		}
	}

	kind := db.KindMovie
	title := parsedFile.Title
	year := parsedFile.Year
	if mode == "dir" {
		kind = db.KindShow
		if strings.TrimSpace(parsedFolder.Title) != "" && !isGenericCategoryFolder(parsedFolder.Title) {
			title = parsedFolder.Title
		}
		if parsedFolder.Year != nil {
			year = parsedFolder.Year
		}
	} else if title == "" && strings.TrimSpace(parsedFolder.Title) != "" && !isGenericCategoryFolder(parsedFolder.Title) {
		title = parsedFolder.Title
		if year == nil {
			year = parsedFolder.Year
		}
	}

	// Merge client_hints_json if client supplied hints (e.g. Emby/Jellyfin).
	if sample.ClientHintsJSON.Valid && sample.ClientHintsJSON.String != "" {
		var hints map[string]any
		if json.Unmarshal([]byte(sample.ClientHintsJSON.String), &hints) == nil {
			if t, ok := hints["title"].(string); ok && strings.TrimSpace(t) != "" && title == "" {
				title = strings.TrimSpace(t)
			}
			if k, ok := hints["kind"].(string); ok {
				if k == db.KindShow {
					kind = db.KindShow
				} else if k == db.KindMovie {
					kind = db.KindMovie
				}
			}
			if year == nil {
				if yNum, ok := hints["year"].(float64); ok && int(yNum) > 1800 {
					y := int(yNum)
					year = &y
				}
			}
		}
	}

	allowChange := true
	switch folderHint {
	case db.ShelfMovie:
		kind = db.KindMovie
		allowChange = false
	case db.ShelfShow:
		kind = db.KindShow
		allowChange = false
	case db.ShelfAnime:
		if mode == "dir" {
			kind = db.KindShow
		}
	}

	isAnime := folderHint == db.ShelfAnime || parsedFile.FansubStyle || looksLikeAnimeHint(folderHint, targetPath, base)
	return PublicIdentifyRequest{
		Title:           title,
		Year:            year,
		Kind:            kind,
		Filename:        base,
		FolderHint:      folderName,
		Nfo:             titleNFO,
		IsAnime:         isAnime,
		AllowKindChange: &allowChange,
		Lang:            lang,
	}, kind
}

func (sc *Scraper) resolveEmbeddedLink(kind string, emb EmbeddedIDs) (string, int, bool) {
	checks := []struct {
		prov string
		id   string
	}{
		{"tmdb", emb.TmdbID},
		{"imdb", emb.ImdbID},
		{"tvdb", emb.TvdbID},
		{"douban", emb.DoubanID},
		{"bangumi", emb.BangumiID},
		{"anilist", emb.AniListID},
	}
	for _, c := range checks {
		if c.id == "" {
			continue
		}
		if ck, impS, ok := sc.ResolveWorkKey(kind, c.prov, c.id); ok {
			return ck, impS, true
		}
	}
	return "", 0, false
}

func mergeNFOEmbeddedIDs(emb *EmbeddedIDs, nfo *metadata.Work) {
	if emb.TmdbID == "" && nfo.TmdbID != nil {
		emb.TmdbID = strings.TrimSpace(*nfo.TmdbID)
	}
	if emb.ImdbID == "" && nfo.ImdbID != nil {
		emb.ImdbID = strings.ToLower(strings.TrimSpace(*nfo.ImdbID))
	}
	if emb.TvdbID == "" && nfo.TvdbID != nil {
		emb.TvdbID = strings.TrimSpace(*nfo.TvdbID)
	}
	if emb.DoubanID == "" && nfo.DoubanID != nil {
		emb.DoubanID = strings.TrimSpace(*nfo.DoubanID)
	}
	if emb.BangumiID == "" && nfo.BangumiID != nil {
		emb.BangumiID = strings.TrimSpace(*nfo.BangumiID)
	}
	if emb.AniListID == "" && nfo.AniListID != nil {
		emb.AniListID = strings.TrimSpace(*nfo.AniListID)
	}
}

func mergeClientHintsEmbedded(emb *EmbeddedIDs, rawJSON string) {
	if rawJSON == "" {
		return
	}
	var m map[string]any
	if json.Unmarshal([]byte(rawJSON), &m) != nil {
		return
	}
	readStr := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
				return strings.TrimSpace(v)
			}
		}
		if pids, ok := m["provider_ids"].(map[string]any); ok {
			for _, k := range keys {
				if v, ok := pids[k].(string); ok && strings.TrimSpace(v) != "" {
					return strings.TrimSpace(v)
				}
			}
		}
		return ""
	}
	if emb.TmdbID == "" {
		emb.TmdbID = readStr("tmdb_id", "tmdb", "Tmdb")
	}
	if emb.ImdbID == "" {
		emb.ImdbID = strings.ToLower(readStr("imdb_id", "imdb", "Imdb"))
	}
	if emb.TvdbID == "" {
		emb.TvdbID = readStr("tvdb_id", "tvdb", "Tvdb")
	}
	if emb.BangumiID == "" {
		emb.BangumiID = readStr("bangumi_id", "bangumi", "Bangumi")
	}
	if emb.DoubanID == "" {
		emb.DoubanID = readStr("douban_id", "douban", "Douban")
	}
	if emb.AniListID == "" {
		emb.AniListID = readStr("anilist_id", "anilist", "AniList")
	}
}

func mergeNFOIntoWork(w, nfo *metadata.Work) {
	if w.Title == "" && nfo.Title != "" {
		w.Title = nfo.Title
	}
	if w.Summary == nil && nfo.Summary != nil {
		w.Summary = nfo.Summary
	}
	if w.Year == nil && nfo.Year != nil {
		w.Year = nfo.Year
	}
	if w.Tagline == nil && nfo.Tagline != nil {
		w.Tagline = nfo.Tagline
	}
	if w.ContentRating == nil && nfo.ContentRating != nil {
		w.ContentRating = nfo.ContentRating
	}
	if w.Studio == nil && nfo.Studio != nil {
		w.Studio = nfo.Studio
	}
	if len(w.Genres) == 0 && len(nfo.Genres) > 0 {
		w.Genres = nfo.Genres
	}
}

func (sc *Scraper) buildGroupAssignments(
	ctx context.Context,
	householdID, kind, mode, targetPath string,
	files []groupVideoFile,
	sidecars []groupSidecarFile,
	thumbByDirStem map[string]string,
	impliedSeason, seasonOffset int,
) []groupEpisodeAssignment {
	nfoByDirStem := make(map[string]string)
	for _, s := range sidecars {
		if s.Role == db.FileRoleNfo && s.SidecarSHA256 != "" {
			dir := pathutil.ParentPath(s.Path)
			stem := strings.ToLower(stripFileExt(pathutil.BaseName(s.Path)))
			nfoByDirStem[dir+"/"+stem] = s.SidecarSHA256
		}
	}

	out := make([]groupEpisodeAssignment, 0, len(files))
	for _, f := range files {
		a := groupEpisodeAssignment{file: f, seasonNum: -1, epNum: -1}
		dir1 := pathutil.ParentPath(f.Path)
		stemLow := strings.ToLower(stripFileExt(pathutil.BaseName(f.Path)))
		if sha := thumbByDirStem[dir1+"/"+stemLow]; sha != "" {
			a.thumbSHA = sha
		} else if sha := thumbByDirStem[dir1+"/*"]; sha != "" {
			a.thumbSHA = sha
		}

		if kind == db.KindShow {
			parsed := ParseFileName(pathutil.BaseName(f.Path))
			var pf []ParsedFolder
			if dir1 != pathutil.RootPath && dir1 != targetPath {
				pf = append(pf, ParseFolderName(pathutil.BaseName(dir1)))
				a.seasonDir = dir1
			}
			var epNFO *metadata.Episode
			if sc.sidecars != nil {
				if nfoSHA := nfoByDirStem[dir1+"/"+stemLow]; nfoSHA != "" {
					if rawNFO, rErr := sc.sidecars.ReadText(ctx, householdID, nfoSHA); rErr == nil {
						epNFO = ReadEpisodeNFO(rawNFO)
						a.epNFO = epNFO
					}
				}
			}

			sNum := 1
			hasExplicitSeason := false
			if parsed.Season != nil {
				sNum = *parsed.Season
				hasExplicitSeason = sNum > 1
			} else if len(pf) > 0 && pf[0].IsSeasonFolder && pf[0].Season != nil {
				sNum = *pf[0].Season
				hasExplicitSeason = sNum > 1
			} else if parsed.IsSpecial {
				sNum = 0
			}
			if impliedSeason > 0 && !hasExplicitSeason && sNum != 0 {
				sNum = impliedSeason
			}
			if seasonOffset != 0 && (sNum > 0 || seasonOffset > 0) {
				sNum += seasonOffset
				if sNum < 0 {
					sNum = 0
				}
			}

			eNum := 0
			if parsed.Episode != nil {
				eNum = *parsed.Episode
			} else if parsed.LooseEpisode != nil {
				eNum = *parsed.LooseEpisode
			} else if epNFO != nil && epNFO.Number > 0 {
				eNum = epNFO.Number
			}

			a.seasonNum = sNum
			a.epNum = eNum
		}

		out = append(out, a)
	}
	return out
}

func (sc *Scraper) persistGroupMatchTx(tx *sql.Tx, p persistGroupParams) (int64, error) {
	nowMs := p.NowMs
	if nowMs <= 0 {
		nowMs = sc.store.NowMs()
	}

	earliestAdded := nowMs
	var latestSourceAdded sql.NullInt64
	for _, a := range p.Assignments {
		if a.file.AddedAt > 0 && a.file.AddedAt < earliestAdded {
			earliestAdded = a.file.AddedAt
		}
		var ts int64
		if a.file.MtimeS.Valid && a.file.MtimeS.Int64 > 0 {
			ts = a.file.MtimeS.Int64 * 1000
		} else if a.file.CtimeS.Valid && a.file.CtimeS.Int64 > 0 {
			ts = a.file.CtimeS.Int64 * 1000
		}
		if ts > 0 && (!latestSourceAdded.Valid || ts > latestSourceAdded.Int64) {
			latestSourceAdded = sql.NullInt64{Int64: ts, Valid: true}
		}
	}

	posterSrc := p.Work.PosterPath
	if (posterSrc == nil || *posterSrc == "") && p.LocalShowPoster != "" {
		v := p.LocalShowPoster
		posterSrc = &v
	}
	backdropSrc := p.Work.BackdropPath
	if (backdropSrc == nil || *backdropSrc == "") && p.LocalShowBackdrop != "" {
		v := p.LocalShowBackdrop
		backdropSrc = &v
	}
	logoSrc := p.Work.LogoPath
	if (logoSrc == nil || *logoSrc == "") && p.LocalShowLogo != "" {
		v := p.LocalShowLogo
		logoSrc = &v
	}

	aliasesJSON := "[]"
	if len(p.Work.Aliases) > 0 {
		if b, err := json.Marshal(p.Work.Aliases); err == nil {
			aliasesJSON = string(b)
		}
	}
	metaSrc := p.Work.Source
	if metaSrc == "" {
		metaSrc = "tmdb"
	}

	// Upsert root movie or show row (carries work_key).
	var (
		rootItemID int64
		rootLocked int
	)
	err := tx.QueryRow(`
		SELECT id, locked FROM media_items
		WHERE household_id = ? AND work_key = ?`,
		p.HouseholdID, p.WorkKey,
	).Scan(&rootItemID, &rootLocked)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}

	sortTitle := buildSortTitle(p.Work.Title)
	if errors.Is(err, sql.ErrNoRows) {
		res, err := tx.Exec(`
			INSERT INTO media_items(
				household_id, work_key, kind, library_type, parent_id, show_id,
				title, sort_title, original_title, aliases, year, release_date,
				summary, tagline, content_rating, studio, rating, runtime_ms,
				poster_source, backdrop_source, logo_source,
				tmdb_id, imdb_id, tvdb_id, bangumi_id, douban_id, anilist_id,
				metadata_source, locked, added_at, source_added_at, updated_at, scraped_at
			) VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)`,
			p.HouseholdID, p.WorkKey, p.Kind, p.Shelf,
			p.Work.Title, sortTitle, p.Work.OriginalTitle, aliasesJSON, p.Work.Year, p.Work.ReleaseDate,
			p.Work.Summary, p.Work.Tagline, p.Work.ContentRating, p.Work.Studio, p.Work.Rating, p.Work.RuntimeMs,
			posterSrc, backdropSrc, logoSrc,
			p.Work.TmdbID, p.Work.ImdbID, p.Work.TvdbID, p.Work.BangumiID, p.Work.DoubanID, p.Work.AniListID,
			metaSrc, earliestAdded, latestSourceAdded, nowMs, nowMs,
		)
		if err != nil {
			return 0, err
		}
		rootItemID, err = res.LastInsertId()
		if err != nil {
			return 0, err
		}
	} else {
		lockedVal := rootLocked
		if p.ForceUnlockItem {
			lockedVal = 0
		}
		if lockedVal == 0 {
			if _, err := tx.Exec(`
				UPDATE media_items SET
					kind = ?, library_type = ?, title = ?, sort_title = ?, original_title = ?,
					aliases = ?, year = ?, release_date = ?, summary = ?, tagline = ?,
					content_rating = ?, studio = ?, rating = ?, runtime_ms = ?,
					poster_source = COALESCE(?, poster_source),
					backdrop_source = COALESCE(?, backdrop_source),
					logo_source = COALESCE(?, logo_source),
					tmdb_id = ?, imdb_id = ?, tvdb_id = ?, bangumi_id = ?, douban_id = ?, anilist_id = ?,
					metadata_source = ?, locked = ?,
					source_added_at = COALESCE(MAX(source_added_at, ?), source_added_at, ?),
					updated_at = ?, scraped_at = ?
				WHERE id = ?`,
				p.Kind, p.Shelf, p.Work.Title, sortTitle, p.Work.OriginalTitle,
				aliasesJSON, p.Work.Year, p.Work.ReleaseDate, p.Work.Summary, p.Work.Tagline,
				p.Work.ContentRating, p.Work.Studio, p.Work.Rating, p.Work.RuntimeMs,
				posterSrc, backdropSrc, logoSrc,
				p.Work.TmdbID, p.Work.ImdbID, p.Work.TvdbID, p.Work.BangumiID, p.Work.DoubanID, p.Work.AniListID,
				metaSrc, lockedVal,
				latestSourceAdded, latestSourceAdded, nowMs, nowMs, rootItemID,
			); err != nil {
				return 0, err
			}
		} else {
			if _, err := tx.Exec(`
				UPDATE media_items
				SET source_added_at = COALESCE(MAX(source_added_at, ?), source_added_at, ?),
				    updated_at = ?
				WHERE id = ?`,
				latestSourceAdded, latestSourceAdded, nowMs, rootItemID,
			); err != nil {
				return 0, err
			}
		}
	}

	if rootLocked == 0 || p.ForceUnlockItem {
		if err := syncItemGenresTx(tx, rootItemID, p.Work.Genres); err != nil {
			return 0, err
		}
		if err := syncItemCreditsTx(tx, rootItemID, p.Work.Credits); err != nil {
			return 0, err
		}
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "item", strconv.FormatInt(rootItemID, 10), "upsert", nowMs); err != nil {
		return 0, err
	}

	// Track previous item IDs to run G2 migrations and orphan cleanup.
	oldWorkByFile := make(map[int64]string)
	oldItemSet := make(map[int64]bool)
	for _, a := range p.Assignments {
		if a.file.ItemID.Valid {
			oldID := a.file.ItemID.Int64
			oldItemSet[oldID] = true
			if oldWK := lookupItemWorkKeyTx(tx, a.file.HouseholdID, oldID); oldWK != "" {
				oldWorkByFile[a.file.ID] = oldWK
			}
		}
	}

	migratedFromWorks := make(map[string]bool)
	for _, a := range p.Assignments {
		targetItemID := rootItemID
		if p.Kind == db.KindShow {
			sID, sErr := sc.upsertSeasonItemTx(tx, p, rootItemID, a.seasonNum, nowMs)
			if sErr != nil {
				return 0, sErr
			}
			eID, eErr := sc.upsertEpisodeItemTx(tx, p, rootItemID, sID, a, nowMs)
			if eErr != nil {
				return 0, eErr
			}
			targetItemID = eID
		}

		if oldWK := oldWorkByFile[a.file.ID]; oldWK != "" && oldWK != p.WorkKey && !migratedFromWorks[oldWK] {
			migratedFromWorks[oldWK] = true
			if err := MigrateWorkUserDataTx(tx, p.HouseholdID, oldWK, p.WorkKey, nowMs); err != nil {
				return 0, err
			}
		}
		if err := MigrateFileWatchProgressTx(tx, p.HouseholdID, a.file.ID, p.WorkKey, a.seasonNum, a.epNum, nowMs); err != nil {
			return 0, err
		}

		lockSQL := "match_locked"
		if p.LockFiles {
			lockSQL = "1"
		}
		if _, err := tx.Exec(fmt.Sprintf(`
			UPDATE media_files
			SET item_id = ?, match_state = ?, match_locked = %s, updated_at = ?
			WHERE id = ? AND household_id = ?`, lockSQL),
			targetItemID, db.MatchMatched, nowMs, a.file.ID, p.HouseholdID,
		); err != nil {
			return 0, err
		}
	}

	if err := pruneOrphanItemsTx(tx, p.HouseholdID, oldItemSet, rootItemID, nowMs); err != nil {
		return 0, err
	}
	return rootItemID, nil
}

func (sc *Scraper) upsertSeasonItemTx(tx *sql.Tx, p persistGroupParams, showID int64, seasonNum int, nowMs int64) (int64, error) {
	var (
		seasonID int64
		locked   int
	)
	err := tx.QueryRow(`
		SELECT id, locked FROM media_items
		WHERE household_id = ? AND show_id = ? AND kind = ? AND season_number = ?`,
		p.HouseholdID, showID, db.KindSeason, seasonNum,
	).Scan(&seasonID, &locked)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}

	sMeta, hasMeta := p.Seasons[seasonNum]
	title := fmt.Sprintf("Season %d", seasonNum)
	if seasonNum == 0 {
		title = "Specials"
	}
	if hasMeta && sMeta.Title != nil && strings.TrimSpace(*sMeta.Title) != "" {
		title = strings.TrimSpace(*sMeta.Title)
	}
	var summary, releaseDate, poster *string
	if hasMeta {
		summary = sMeta.Summary
		releaseDate = sMeta.AirDate
		poster = sMeta.PosterPath
	}
	if (poster == nil || *poster == "") && p.SeasonPosters[seasonNum] != "" {
		v := p.SeasonPosters[seasonNum]
		poster = &v
	}

	if errors.Is(err, sql.ErrNoRows) {
		res, err := tx.Exec(`
			INSERT INTO media_items(
				household_id, work_key, kind, library_type, parent_id, show_id,
				title, sort_title, release_date, summary, season_number, poster_source,
				metadata_source, locked, added_at, updated_at, scraped_at
			) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
			p.HouseholdID, db.KindSeason, p.Shelf, showID, showID,
			title, fmt.Sprintf("%05d", seasonNum), releaseDate, summary, seasonNum, poster,
			p.Work.Source, nowMs, nowMs, nowMs,
		)
		if err != nil {
			return 0, err
		}
		seasonID, err = res.LastInsertId()
		if err != nil {
			return 0, err
		}
	} else if locked == 0 || p.ForceUnlockItem {
		if _, err := tx.Exec(`
			UPDATE media_items SET
				library_type = ?, title = ?, release_date = COALESCE(?, release_date),
				summary = COALESCE(?, summary), poster_source = COALESCE(?, poster_source),
				updated_at = ?, scraped_at = ?
			WHERE id = ?`,
			p.Shelf, title, releaseDate, summary, poster, nowMs, nowMs, seasonID,
		); err != nil {
			return 0, err
		}
	}

	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "item", strconv.FormatInt(seasonID, 10), "upsert", nowMs); err != nil {
		return 0, err
	}
	return seasonID, nil
}

func (sc *Scraper) upsertEpisodeItemTx(tx *sql.Tx, p persistGroupParams, showID, seasonID int64, a groupEpisodeAssignment, nowMs int64) (int64, error) {
	var (
		epID   int64
		locked int
	)
	err := tx.QueryRow(`
		SELECT id, locked FROM media_items
		WHERE household_id = ? AND show_id = ? AND kind = ? AND season_number = ? AND episode_number = ?`,
		p.HouseholdID, showID, db.KindEpisode, a.seasonNum, a.epNum,
	).Scan(&epID, &locked)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}

	title := fmt.Sprintf("Episode %d", a.epNum)
	var summary, airDate, still *string
	var runtimeMs *int64
	var rating *float64

	if sMeta, ok := p.Seasons[a.seasonNum]; ok {
		for _, ep := range sMeta.Episodes {
			if ep.Number == a.epNum {
				if ep.Title != nil && strings.TrimSpace(*ep.Title) != "" {
					title = strings.TrimSpace(*ep.Title)
				}
				summary = ep.Summary
				airDate = ep.AirDate
				still = ep.StillPath
				runtimeMs = ep.RuntimeMs
				rating = ep.Rating
				break
			}
		}
	}
	if a.epNFO != nil {
		if a.epNFO.Title != nil && strings.TrimSpace(*a.epNFO.Title) != "" && strings.HasPrefix(title, "Episode ") {
			title = strings.TrimSpace(*a.epNFO.Title)
		}
		if summary == nil {
			summary = a.epNFO.Summary
		}
		if airDate == nil {
			airDate = a.epNFO.AirDate
		}
		if runtimeMs == nil {
			runtimeMs = a.epNFO.RuntimeMs
		}
		if rating == nil {
			rating = a.epNFO.Rating
		}
	}
	if (still == nil || *still == "") && a.thumbSHA != "" {
		v := a.thumbSHA
		still = &v
	}

	if errors.Is(err, sql.ErrNoRows) {
		res, err := tx.Exec(`
			INSERT INTO media_items(
				household_id, work_key, kind, library_type, parent_id, show_id,
				title, sort_title, release_date, summary, rating, runtime_ms,
				season_number, episode_number, poster_source,
				metadata_source, locked, added_at, updated_at, scraped_at
			) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
			p.HouseholdID, db.KindEpisode, p.Shelf, seasonID, showID,
			title, fmt.Sprintf("%05d_%05d", a.seasonNum, a.epNum), airDate, summary, rating, runtimeMs,
			a.seasonNum, a.epNum, still, p.Work.Source, nowMs, nowMs, nowMs,
		)
		if err != nil {
			return 0, err
		}
		epID, err = res.LastInsertId()
		if err != nil {
			return 0, err
		}
	} else if locked == 0 || p.ForceUnlockItem {
		if _, err := tx.Exec(`
			UPDATE media_items SET
				library_type = ?, parent_id = ?, title = ?,
				release_date = COALESCE(?, release_date),
				summary = COALESCE(?, summary),
				rating = COALESCE(?, rating),
				runtime_ms = COALESCE(?, runtime_ms),
				poster_source = COALESCE(?, poster_source),
				updated_at = ?, scraped_at = ?
			WHERE id = ?`,
			p.Shelf, seasonID, title, airDate, summary, rating, runtimeMs, still, nowMs, nowMs, epID,
		); err != nil {
			return 0, err
		}
	}

	if _, err := db.AppendChangeTx(tx, p.HouseholdID, nil, "item", strconv.FormatInt(epID, 10), "upsert", nowMs); err != nil {
		return 0, err
	}
	return epID, nil
}

func syncItemGenresTx(tx *sql.Tx, itemID int64, genres []string) error {
	if _, err := tx.Exec(`DELETE FROM item_genres WHERE item_id = ?`, itemID); err != nil {
		return err
	}
	seen := make(map[string]bool)
	for _, raw := range genres {
		name := strings.TrimSpace(raw)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		if _, err := tx.Exec(`INSERT INTO genres(name) VALUES (?) ON CONFLICT(name) DO NOTHING`, name); err != nil {
			return err
		}
		var gid int64
		if err := tx.QueryRow(`SELECT id FROM genres WHERE name = ?`, name).Scan(&gid); err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT OR IGNORE INTO item_genres(item_id, genre_id) VALUES (?, ?)`, itemID, gid); err != nil {
			return err
		}
	}
	return nil
}

func syncItemCreditsTx(tx *sql.Tx, itemID int64, credits []metadata.Credit) error {
	if _, err := tx.Exec(`DELETE FROM item_credits WHERE item_id = ?`, itemID); err != nil {
		return err
	}
	seenPair := make(map[string]bool)
	for i, c := range credits {
		name := strings.TrimSpace(c.Name)
		job := strings.TrimSpace(c.Job)
		if name == "" || job == "" {
			continue
		}
		extID := ""
		if c.TmdbID != nil {
			extID = strings.TrimSpace(*c.TmdbID)
		}
		var personID int64
		var qErr error
		if extID != "" {
			qErr = tx.QueryRow(`SELECT id FROM people WHERE provider = 'tmdb' AND external_id = ? LIMIT 1`, extID).Scan(&personID)
		} else {
			qErr = tx.QueryRow(`SELECT id FROM people WHERE name = ? AND (external_id IS NULL OR external_id = '') LIMIT 1`, name).Scan(&personID)
		}
		if errors.Is(qErr, sql.ErrNoRows) {
			var extPtr *string
			if extID != "" {
				extPtr = &extID
			}
			res, err := tx.Exec(`
				INSERT INTO people(name, provider, external_id, photo_source)
				VALUES (?, 'tmdb', ?, ?)`,
				name, extPtr, c.PhotoPath,
			)
			if err != nil {
				return err
			}
			personID, err = res.LastInsertId()
			if err != nil {
				return err
			}
		} else if qErr != nil {
			return qErr
		} else if c.PhotoPath != nil && *c.PhotoPath != "" {
			if _, err := tx.Exec(`UPDATE people SET photo_source = COALESCE(photo_source, ?) WHERE id = ?`, c.PhotoPath, personID); err != nil {
				return err
			}
		}

		pk := fmt.Sprintf("%d|%s", personID, job)
		if seenPair[pk] {
			continue
		}
		seenPair[pk] = true
		if _, err := tx.Exec(`
			INSERT INTO item_credits(item_id, person_id, job, character, sort_order)
			VALUES (?, ?, ?, ?, ?)`,
			itemID, personID, job, c.Character, i,
		); err != nil {
			return err
		}
	}
	return nil
}

func lookupItemWorkKeyTx(tx *sql.Tx, householdID string, itemID int64) string {
	var (
		wk     sql.NullString
		showID sql.NullInt64
	)
	if err := tx.QueryRow(`SELECT work_key, show_id FROM media_items WHERE id = ? AND household_id = ?`, itemID, householdID).Scan(&wk, &showID); err != nil {
		return ""
	}
	if wk.Valid && wk.String != "" {
		return wk.String
	}
	if showID.Valid {
		var parentWK sql.NullString
		if err := tx.QueryRow(`SELECT work_key FROM media_items WHERE id = ? AND household_id = ?`, showID.Int64, householdID).Scan(&parentWK); err == nil && parentWK.Valid {
			return parentWK.String
		}
	}
	return ""
}

func pruneOrphanItemsTx(tx *sql.Tx, householdID string, oldItemIDs map[int64]bool, keepRootID int64, nowMs int64) error {
	candidates := make([]int64, 0, len(oldItemIDs))
	for id := range oldItemIDs {
		if id > 0 && id != keepRootID {
			candidates = append(candidates, id)
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i] > candidates[j] })

	for _, id := range candidates {
		var kind string
		var parentID, showID sql.NullInt64
		err := tx.QueryRow(`SELECT kind, parent_id, show_id FROM media_items WHERE id = ? AND household_id = ?`, id, householdID).Scan(&kind, &parentID, &showID)
		if err != nil {
			continue
		}
		var refs int
		_ = tx.QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = ? AND item_id = ? AND state != 'tombstoned'`, householdID, id).Scan(&refs)
		var childRefs int
		_ = tx.QueryRow(`SELECT COUNT(*) FROM media_items WHERE household_id = ? AND (parent_id = ? OR show_id = ?)`, householdID, id, id).Scan(&childRefs)
		if refs == 0 && childRefs == 0 {
			if _, err := tx.Exec(`DELETE FROM media_items WHERE id = ? AND household_id = ?`, id, householdID); err != nil {
				return err
			}
			_, _ = db.AppendChangeTx(tx, householdID, nil, "item", strconv.FormatInt(id, 10), "delete", nowMs)
			if parentID.Valid {
				_ = pruneEmptyShowAncestorsTx(tx, householdID, parentID.Int64, showID, keepRootID, nowMs)
			}
		}
	}
	return nil
}

func pruneEmptyShowAncestorsTx(tx *sql.Tx, householdID string, seasonID int64, showID sql.NullInt64, keepRootID int64, nowMs int64) error {
	for _, aid := range []int64{seasonID, showID.Int64} {
		if aid <= 0 || aid == keepRootID {
			continue
		}
		var refs, children int
		_ = tx.QueryRow(`SELECT COUNT(*) FROM media_files WHERE household_id = ? AND item_id = ? AND state != 'tombstoned'`, householdID, aid).Scan(&refs)
		_ = tx.QueryRow(`SELECT COUNT(*) FROM media_items WHERE household_id = ? AND (parent_id = ? OR show_id = ?)`, householdID, aid, aid).Scan(&children)
		if refs == 0 && children == 0 {
			if _, err := tx.Exec(`DELETE FROM media_items WHERE id = ? AND household_id = ?`, aid, householdID); err != nil {
				return err
			}
			_, _ = db.AppendChangeTx(tx, householdID, nil, "item", strconv.FormatInt(aid, 10), "delete", nowMs)
		}
	}
	return nil
}

// MarkGroupUnmatched transitions any unlocked video files in groupKey to match_state='unmatched'.
func (sc *Scraper) MarkGroupUnmatched(householdID, groupKey string) error {
	if sc == nil || sc.store == nil {
		return nil
	}
	sourceID, mode, targetPath, ok := ParseGroupKey(groupKey)
	if !ok {
		return nil
	}
	files, err := sc.loadGroupVideoFiles(householdID, groupKey, sourceID, mode, targetPath)
	if err != nil || len(files) == 0 {
		return err
	}
	return sc.markGroupFilesState(householdID, files, db.MatchUnmatched)
}

func (sc *Scraper) markGroupFilesState(householdID string, files []groupVideoFile, matchState string) error {
	nowMs := sc.store.NowMs()
	tx, err := sc.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for _, f := range files {
		if f.MatchLocked {
			continue
		}
		if _, err := tx.Exec(`UPDATE media_files SET match_state = ?, updated_at = ? WHERE id = ? AND household_id = ?`, matchState, nowMs, f.ID, householdID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (sc *Scraper) loadItemExternalTarget(householdID string, itemID int64) (prov, kind, extID, workKey string, ok bool) {
	var (
		wk, k, ms                      sql.NullString
		tmdb, imdb, tvdb, bgm, dbn, al sql.NullString
		showID                         sql.NullInt64
	)
	err := sc.store.ReadDB().QueryRow(`
		SELECT work_key, kind, show_id, metadata_source,
		       tmdb_id, imdb_id, tvdb_id, bangumi_id, douban_id, anilist_id
		FROM media_items WHERE id = ? AND household_id = ?`,
		itemID, householdID,
	).Scan(&wk, &k, &showID, &ms, &tmdb, &imdb, &tvdb, &bgm, &dbn, &al)
	if err != nil {
		return "", "", "", "", false
	}
	if showID.Valid && (!wk.Valid || wk.String == "") {
		return sc.loadItemExternalTarget(householdID, showID.Int64)
	}
	kind = k.String
	workKey = wk.String
	if tmdb.Valid && tmdb.String != "" {
		return "tmdb", kind, tmdb.String, workKey, true
	}
	if imdb.Valid && imdb.String != "" {
		return "imdb", kind, imdb.String, workKey, true
	}
	if tvdb.Valid && tvdb.String != "" {
		return "tvdb", kind, tvdb.String, workKey, true
	}
	if bgm.Valid && bgm.String != "" {
		return "bangumi", kind, bgm.String, workKey, true
	}
	if dbn.Valid && dbn.String != "" {
		return "douban", kind, dbn.String, workKey, true
	}
	if al.Valid && al.String != "" {
		return "anilist", kind, al.String, workKey, true
	}
	return ms.String, kind, "", workKey, workKey != ""
}

func (sc *Scraper) loadItemAsWork(householdID string, itemID int64) (metadata.Work, bool) {
	var (
		kind, title   string
		year          sql.NullInt64
		summary       sql.NullString
		poster, bdrop sql.NullString
		ms            sql.NullString
	)
	err := sc.store.ReadDB().QueryRow(`
		SELECT kind, title, year, summary, poster_source, backdrop_source, metadata_source
		FROM media_items WHERE id = ? AND household_id = ?`,
		itemID, householdID,
	).Scan(&kind, &title, &year, &summary, &poster, &bdrop, &ms)
	if err != nil {
		return metadata.Work{}, false
	}
	w := metadata.Work{Kind: kind, Title: title, Source: ms.String}
	if year.Valid {
		y := int(year.Int64)
		w.Year = &y
	}
	if summary.Valid {
		s := summary.String
		w.Summary = &s
	}
	if poster.Valid {
		p := poster.String
		w.PosterPath = &p
	}
	if bdrop.Valid {
		b := bdrop.String
		w.BackdropPath = &b
	}
	return w, true
}

func parseWorkKeyParts(wk string) (provider, kind, extID string, ok bool) {
	parts := strings.SplitN(wk, ":", 3)
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return "", "", "", false
	}
	return parts[0], parts[1], parts[2], true
}

func determineShelf(kind, folderHint string, work metadata.Work, isAnimeHint bool) string {
	switch folderHint {
	case db.ShelfAnime, db.ShelfVariety, db.ShelfDocumentary:
		return folderHint
	case db.ShelfMovie:
		if kind == db.KindMovie {
			return db.ShelfMovie
		}
	case db.ShelfShow:
		if kind == db.KindShow {
			return db.ShelfShow
		}
	}
	hasGenre := func(keys ...string) bool {
		for _, g := range work.Genres {
			gl := strings.ToLower(g)
			for _, k := range keys {
				if strings.Contains(gl, k) {
					return true
				}
			}
		}
		return false
	}
	if isAnimeHint || work.Source == "bangumi" || work.Source == "anilist" || work.BangumiID != nil || work.AniListID != nil {
		return db.ShelfAnime
	}
	if hasGenre("纪录", "documentary") {
		return db.ShelfDocumentary
	}
	if hasGenre("真人秀", "reality", "talk", "脱口秀") {
		return db.ShelfVariety
	}
	if kind == db.KindShow {
		if hasGenre("动画", "animation") {
			return db.ShelfAnime
		}
		return db.ShelfShow
	}
	return db.ShelfMovie
}

func stripFileExt(name string) string {
	ext := path.Ext(name)
	if ext == "" {
		return name
	}
	return strings.TrimSuffix(name, ext)
}

func buildSortTitle(title string) string {
	s := strings.TrimSpace(title)
	low := strings.ToLower(s)
	for _, art := range []string{"the ", "a ", "an "} {
		if strings.HasPrefix(low, art) && len(s) > len(art) {
			s = strings.TrimSpace(s[len(art):])
			break
		}
	}
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsSpace(r) {
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
