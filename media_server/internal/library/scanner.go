package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/events"
	"plezy/media_server/internal/storage"
)

var (
	videoExts = map[string]bool{
		"mkv": true, "mp4": true, "m4v": true, "mov": true, "avi": true,
		"wmv": true, "flv": true, "f4v": true, "webm": true, "ts": true,
		"m2ts": true, "mts": true, "mpg": true, "mpeg": true, "rmvb": true,
		"rm": true, "3gp": true, "ogv": true,
	}
	subtitleExts = map[string]bool{
		"srt": true, "ass": true, "ssa": true, "vtt": true, "sub": true, "sup": true, "smi": true,
	}
	imageExts = map[string]bool{
		"jpg": true, "jpeg": true, "png": true, "webp": true,
	}
	skippedFolders = map[string]bool{
		"@eadir": true, "#recycle": true, "$recycle.bin": true,
		"system volume information": true, "lost+found": true, ".trash": true,
		"bdmv": true, "certificate": true, "video_ts": true,
		"extras": true, "extra": true, "featurettes": true, "behind the scenes": true,
		"deleted scenes": true, "interviews": true, "trailers": true, "samples": true,
		"sample": true, "screens": true, "screenshots": true, "proof": true,
		"花絮": true, "特典": true, "预告": true, "預告": true, "样片": true, "樣片": true,
	}
)

func IsSampleName(baseName string) bool {
	low := strings.ToLower(baseName)
	for _, kw := range []string{"sample", "trailer", "teaser", "preview"} {
		idx := strings.Index(low, kw)
		for idx >= 0 {
			leftOk := idx == 0 || isSampleSep(low[idx-1])
			rightIdx := idx + len(kw)
			rightOk := rightIdx == len(low) || isSampleSep(low[rightIdx])
			if leftOk && rightOk {
				return true
			}
			next := strings.Index(low[idx+1:], kw)
			if next < 0 {
				break
			}
			idx = idx + 1 + next
		}
	}
	return false
}

func isSampleSep(b byte) bool {
	return b == ' ' || b == '.' || b == '_' || b == '-' || b == '[' || b == ']' || b == '(' || b == ')'
}

func IsVideoFile(name string) bool {
	ext := storage.ExtLower(name)
	if !videoExts[ext] {
		return false
	}
	return !IsSampleName(fileStem(name))
}

func fileStem(name string) string {
	idx := strings.LastIndexByte(name, '.')
	if idx <= 0 {
		return name
	}
	return name[:idx]
}

type ScanResult struct {
	Videos       int  `json:"videos"`
	Removed      int  `json:"removed"`
	Cancelled    bool `json:"cancelled"`
	HasChanges   bool `json:"has_changes"`
	IsFullScan   bool `json:"is_full_scan"`
	AddedPending bool `json:"added_pending"`
}

type queuedDir struct {
	Path string `json:"p"`
	ID   string `json:"i,omitempty"`
}

type Scanner struct {
	store   *db.Store
	storage *storage.Manager
	hub     *events.Hub

	cancelMu sync.Mutex
	cancels  map[string]context.CancelFunc
}

func NewScanner(store *db.Store, st *storage.Manager, hub *events.Hub) *Scanner {
	return &Scanner{
		store:   store,
		storage: st,
		hub:     hub,
		cancels: make(map[string]context.CancelFunc),
	}
}

func (s *Scanner) CancelMount(mountID string) {
	s.cancelMu.Lock()
	cancel, ok := s.cancels[mountID]
	s.cancelMu.Unlock()
	if ok && cancel != nil {
		cancel()
	}
}

func (s *Scanner) publishProgress(mountID, mountName, status string, dirsDone, filesSeen int, currentPath, errMsg string) {
	if s.hub == nil {
		return
	}
	s.hub.Publish("scan_progress", map[string]any{
		"mount_id":         mountID,
		"mount_name":       mountName,
		"status":           status,
		"directories_done": dirsDone,
		"files_seen":       filesSeen,
		"current_path":     currentPath,
		"error":            errMsg,
	})
}

func (s *Scanner) ScanMount(ctx context.Context, mountID string, fullRestart bool) (ScanResult, error) {
	m, err := s.store.GetMount(mountID)
	if err != nil {
		return ScanResult{}, err
	}
	if !s.store.TryAcquireScanLock(mountID) {
		return ScanResult{}, fmt.Errorf("%w: mount is already scanning", db.ErrConflict)
	}
	defer s.store.ReleaseScanLock(mountID)

	scanCtx, cancel := context.WithCancel(ctx)
	s.cancelMu.Lock()
	s.cancels[mountID] = cancel
	s.cancelMu.Unlock()
	defer func() {
		cancel()
		s.cancelMu.Lock()
		delete(s.cancels, mountID)
		s.cancelMu.Unlock()
	}()

	drv, err := s.storage.DriverFor(storage.MountConfig{
		ID:      m.ID,
		Kind:    m.Kind,
		Config:  m.Config,
		Secrets: m.Secrets,
	})
	if err != nil {
		return ScanResult{}, err
	}

	inc, isInc := drv.(storage.IncrementalSource)
	if !fullRestart && isInc && inc.SupportsIncremental() {
		st, _ := s.store.GetScanState(mountID)
		if _, ok := parseQuarkWatermark(st.QuarkCheckpoint, inc.RootFolderID()); ok {
			res, incErr := s.scanQuarkIncremental(scanCtx, m, drv, inc, st)
			if incErr == nil {
				return res, nil
			}
			if errors.Is(incErr, context.Canceled) {
				return ScanResult{Cancelled: true}, nil
			}
			// Fall back to full scan if incremental search asks for full scan
			if !strings.Contains(incErr.Error(), "full scan required") {
				return ScanResult{}, incErr
			}
		}
	}

	return s.scanFull(scanCtx, m, drv, inc, isInc, fullRestart)
}

func parseQuarkWatermark(cp *string, rootID string) (int64, bool) {
	if cp == nil || *cp == "" {
		return 0, false
	}
	prefix := rootID + ":"
	if !strings.HasPrefix(*cp, prefix) {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.TrimPrefix(*cp, prefix), 10, 64)
	if err != nil || v < 0 {
		return 0, false
	}
	return v, true
}

func (s *Scanner) scanFull(
	ctx context.Context,
	m db.MountRecord,
	drv storage.Driver,
	inc storage.IncrementalSource,
	isInc bool,
	restart bool,
) (ScanResult, error) {
	var watermark *int64
	if isInc && inc.SupportsIncremental() {
		if rows, err := inc.SearchUpdatedPage(ctx, 1, 1); err == nil {
			var wm int64
			for _, r := range rows {
				if !r.Entry.IsDir {
					wm = r.UpdatedAt
					break
				}
			}
			watermark = &wm
		}
	}

	if ctx.Err() != nil {
		return ScanResult{Cancelled: true}, nil
	}

	st, _ := s.store.GetScanState(m.ID)
	var queue []queuedDir
	scanID := st.ScanID

	if !restart && st.Status != "idle" && st.PendingJSON != nil {
		_ = json.Unmarshal([]byte(*st.PendingJSON), &queue)
	}
	if len(queue) == 0 {
		scanID++
		queue = []queuedDir{{Path: storage.RootPath}}
		now := s.store.NowMs()
		pj := encodeQueue(queue)
		st.ScanID = scanID
		st.Status = "running"
		st.PendingJSON = &pj
		st.StartedAt = &now
		st.LastError = nil
		if err := s.store.SaveScanState(st); err != nil {
			return ScanResult{}, err
		}
	} else {
		st.Status = "running"
		st.LastError = nil
		_ = s.store.SaveScanState(st)
	}

	includes, excludes := storage.PathFilterFromConfig(m.Config)
	dirsDone := 0
	filesSeen := 0
	videos := 0
	anyPending := false

	saveErrState := func(err error) {
		msg := err.Error()
		st.Status = "failed"
		st.LastError = &msg
		pj := encodeQueue(queue)
		st.PendingJSON = &pj
		_ = s.store.SaveScanState(st)
		s.publishProgress(m.ID, m.Name, "failed", dirsDone, filesSeen, "", msg)
	}

	for len(queue) > 0 {
		if ctx.Err() != nil {
			st.Status = "idle"
			pj := encodeQueue(queue)
			st.PendingJSON = &pj
			_ = s.store.SaveScanState(st)
			s.publishProgress(m.ID, m.Name, "cancelled", dirsDone, filesSeen, "", "")
			return ScanResult{Videos: videos, Cancelled: true}, nil
		}

		dir := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		s.publishProgress(m.ID, m.Name, "running", dirsDone, filesSeen, dir.Path, "")

		var parent *storage.Entry
		if dir.ID != "" {
			parent = &storage.Entry{Path: dir.Path, Name: storage.BaseName(dir.Path), IsDir: true, ID: dir.ID}
		}
		entries, err := drv.List(ctx, dir.Path, parent)
		if err != nil {
			if storage.IsKind(err, storage.ErrKindNotFound) && dir.Path != storage.RootPath {
				pj := encodeQueue(queue)
				st.PendingJSON = &pj
				_ = s.store.SaveScanState(st)
				continue
			}
			queue = append(queue, dir)
			saveErrState(err)
			return ScanResult{}, err
		}

		for _, e := range entries {
			if e.IsDir && !isSkippedFolder(e.Name) && storage.CanTraverseDir(e.Path, includes, excludes) {
				queue = append(queue, queuedDir{Path: e.Path, ID: e.ID})
			}
		}
		var allowedFiles []storage.Entry
		for _, e := range entries {
			if !e.IsDir && storage.IsFileAllowed(e.Path, includes, excludes) {
				allowedFiles = append(allowedFiles, e)
			}
		}
		recVideos, addedPend, err := s.recordDirectory(m.ID, dir.Path, allowedFiles, scanID)
		if err != nil {
			queue = append(queue, dir)
			saveErrState(err)
			return ScanResult{}, err
		}
		videos += recVideos
		if addedPend {
			anyPending = true
		}
		filesSeen += len(allowedFiles)
		dirsDone++

		pj := encodeQueue(queue)
		st.PendingJSON = &pj
		_ = s.store.SaveScanState(st)
	}

	removed, err := s.finalizeScan(m.ID, scanID)
	if err != nil {
		saveErrState(err)
		return ScanResult{}, err
	}

	now := s.store.NowMs()
	st.Status = "idle"
	st.PendingJSON = nil
	st.FinishedAt = &now
	st.LastError = nil
	if isInc && watermark != nil {
		cp := fmt.Sprintf("%s:%d", inc.RootFolderID(), *watermark)
		st.QuarkCheckpoint = &cp
	}
	_ = s.store.SaveScanState(st)

	s.publishProgress(m.ID, m.Name, "completed", dirsDone, filesSeen, "", "")
	if s.hub != nil && (videos > 0 || removed > 0 || anyPending) {
		s.hub.Publish("library_changed", map[string]any{"mount_id": m.ID})
	}
	return ScanResult{
		Videos:       videos,
		Removed:      removed,
		HasChanges:   videos > 0 || removed > 0 || anyPending,
		IsFullScan:   true,
		AddedPending: anyPending,
	}, nil
}

func (s *Scanner) scanQuarkIncremental(
	ctx context.Context,
	m db.MountRecord,
	drv storage.Driver,
	inc storage.IncrementalSource,
	st db.MountScanState,
) (ScanResult, error) {
	watermark, ok := parseQuarkWatermark(st.QuarkCheckpoint, inc.RootFolderID())
	if !ok {
		return ScanResult{}, errors.New("full scan required")
	}
	threshold := watermark - int64(time.Minute/time.Millisecond)
	includes, excludes := storage.PathFilterFromConfig(m.Config)

	knownByRemote := make(map[string]db.MediaFile)
	rows, err := s.store.DB().Query(`
		SELECT id, mount_id, path, remote_id, size, modified_at
		FROM media_files
		WHERE mount_id = ? AND remote_id IS NOT NULL AND COALESCE(modified_at, 0) >= ?`,
		m.ID, threshold,
	)
	if err == nil {
		for rows.Next() {
			var f db.MediaFile
			var rid sql.NullString
			var sz, mod sql.NullInt64
			if rows.Scan(&f.ID, &f.MountID, &f.Path, &rid, &sz, &mod) == nil && rid.Valid {
				f.RemoteID = &rid.String
				if sz.Valid {
					f.Size = &sz.Int64
				}
				if mod.Valid {
					f.ModifiedAt = &mod.Int64
				}
				knownByRemote[rid.String] = f
			}
		}
		rows.Close()
	}

	changed := make(map[string]storage.IncrementalUpdate)
	latest := watermark
	var prevTS int64
	for page := 1; ; page++ {
		if ctx.Err() != nil {
			return ScanResult{Cancelled: true}, ctx.Err()
		}
		items, err := inc.SearchUpdatedPage(ctx, page, 100)
		if err != nil {
			return ScanResult{}, err
		}
		var lastTS int64
		for _, row := range items {
			if row.Entry.IsDir {
				continue
			}
			if prevTS > 0 && row.UpdatedAt > prevTS {
				return ScanResult{}, errors.New("Quark incremental: unexpected sort order, full scan required")
			}
			prevTS = row.UpdatedAt
			lastTS = row.UpdatedAt
			if row.UpdatedAt > latest {
				latest = row.UpdatedAt
			}
			if row.UpdatedAt < threshold || !IsVideoFile(row.Entry.Name) {
				continue
			}
			if known, exists := knownByRemote[row.Entry.ID]; exists {
				sameSize := row.Entry.Size == nil || (known.Size != nil && *known.Size == *row.Entry.Size)
				sameMod := known.ModifiedAt != nil && *known.ModifiedAt == row.UpdatedAt
				if sameMod && sameSize && storage.BaseName(known.Path) == row.Entry.Name && storage.IsFileAllowed(known.Path, includes, excludes) {
					continue
				}
			}
			if _, seen := changed[row.Entry.ID]; !seen {
				changed[row.Entry.ID] = row
			}
		}
		s.publishProgress(m.ID, m.Name, "running", 0, len(changed), storage.RootPath, "")
		if len(items) < 100 || (lastTS > 0 && lastTS < threshold) {
			break
		}
		if page >= 50 {
			return ScanResult{}, errors.New("full scan required after 50 incremental pages")
		}
	}

	folderCache := map[string]string{inc.RootFolderID(): storage.RootPath}
	missingParent := make(map[string]bool)
	dirIDToPath := make(map[string]string)
	var movedOut []string

	for _, upd := range changed {
		if ctx.Err() != nil {
			return ScanResult{Cancelled: true}, ctx.Err()
		}
		parentPath, known := folderCache[upd.ParentID]
		if !known && !missingParent[upd.ParentID] {
			resolved, ok := resolveQuarkDirPath(ctx, inc, upd.ParentID)
			if !ok {
				missingParent[upd.ParentID] = true
			} else {
				folderCache[upd.ParentID] = resolved
				parentPath = resolved
				known = true
			}
		}
		if !known {
			movedOut = append(movedOut, upd.Entry.ID)
			continue
		}
		fullPath := storage.JoinPath(parentPath, upd.Entry.Name)
		if !storage.IsFileAllowed(fullPath, includes, excludes) {
			movedOut = append(movedOut, upd.Entry.ID)
			continue
		}
		dirIDToPath[upd.ParentID] = parentPath
	}

	listings := make(map[string][]storage.Entry)
	for fid, dPath := range dirIDToPath {
		if ctx.Err() != nil {
			return ScanResult{Cancelled: true}, ctx.Err()
		}
		entries, err := drv.List(ctx, dPath, &storage.Entry{Path: dPath, Name: storage.BaseName(dPath), IsDir: true, ID: fid})
		if err != nil {
			return ScanResult{}, err
		}
		var allowed []storage.Entry
		for _, e := range entries {
			if !e.IsDir && storage.IsFileAllowed(e.Path, includes, excludes) {
				allowed = append(allowed, e)
			}
		}
		listings[dPath] = allowed
		s.publishProgress(m.ID, m.Name, "running", len(listings), len(changed), dPath, "")
	}

	removed := 0
	for _, rid := range movedOut {
		res, err := s.store.DB().Exec(`DELETE FROM media_files WHERE mount_id = ? AND remote_id = ?`, m.ID, rid)
		if err == nil {
			n, _ := res.RowsAffected()
			removed += int(n)
		}
	}

	videos := 0
	anyPending := false
	scanID := st.ScanID
	if scanID <= 0 {
		scanID = 1
	}
	for dPath, files := range listings {
		v, pend, err := s.recordDirectory(m.ID, dPath, files, scanID)
		if err != nil {
			return ScanResult{}, err
		}
		videos += v
		if pend {
			anyPending = true
		}
	}
	if removed > 0 || len(listings) > 0 {
		_ = s.pruneEmptyItems()
	}

	now := s.store.NowMs()
	cp := fmt.Sprintf("%s:%d", inc.RootFolderID(), latest)
	st.Status = "idle"
	st.FinishedAt = &now
	st.LastError = nil
	st.QuarkCheckpoint = &cp
	_ = s.store.SaveScanState(st)

	s.publishProgress(m.ID, m.Name, "completed", len(listings), len(changed), "", "")
	if s.hub != nil && (videos > 0 || removed > 0 || anyPending) {
		s.hub.Publish("library_changed", map[string]any{"mount_id": m.ID})
	}
	return ScanResult{
		Videos:       videos,
		Removed:      removed,
		HasChanges:   len(listings) > 0 || removed > 0,
		IsFullScan:   false,
		AddedPending: anyPending,
	}, nil
}

func resolveQuarkDirPath(ctx context.Context, inc storage.IncrementalSource, folderID string) (string, bool) {
	anc, err := inc.FolderAncestry(ctx, folderID)
	if err != nil {
		return "", false
	}
	rootID := inc.RootFolderID()
	rootIdx := -1
	if rootID != "0" {
		for i, a := range anc {
			if a.ID == rootID {
				rootIdx = i
				break
			}
		}
		if rootIdx == -1 {
			return "", false
		}
	}
	p := storage.RootPath
	for _, a := range anc[rootIdx+1:] {
		if isSkippedFolder(a.Name) {
			return "", false
		}
		p = storage.JoinPath(p, a.Name)
	}
	return p, true
}

func isSkippedFolder(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	return skippedFolders[strings.ToLower(name)]
}

func encodeQueue(q []queuedDir) string {
	b, _ := json.Marshal(q)
	return string(b)
}

type existingFileState struct {
	ID         int64
	ItemID     *int64
	RemoteID   string
	MatchState string
}

func (s *Scanner) recordDirectory(mountID, dirPath string, files []storage.Entry, scanID int64) (int, bool, error) {
	var videos []storage.Entry
	var others []struct {
		entry storage.Entry
		role  string
	}
	for _, f := range files {
		ext := storage.ExtLower(f.Name)
		if videoExts[ext] {
			if !IsSampleName(fileStem(f.Name)) {
				videos = append(videos, f)
			}
		} else if ext == "nfo" {
			others = append(others, struct {
				entry storage.Entry
				role  string
			}{entry: f, role: db.FileRoleNfo})
		} else if imageExts[ext] {
			others = append(others, struct {
				entry storage.Entry
				role  string
			}{entry: f, role: db.FileRoleArtwork})
		}
	}
	if len(videos) == 0 && len(others) == 0 {
		return 0, false, nil
	}

	segs := storage.PathSegments(dirPath)
	var folders []ParsedFolder
	for i := len(segs) - 1; i >= 0 && len(folders) < 3; i-- {
		folders = append(folders, ParseFolderName(segs[i]))
	}

	parsedByPath := make(map[string]ParsedName, len(videos))
	numberedSiblings := 0
	for _, v := range videos {
		pn := ParseFileName(v.Name)
		parsedByPath[v.Path] = pn
		if pn.Episode != nil || pn.LooseEpisode != nil {
			numberedSiblings++
		}
	}

	now := s.store.NowMs()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return 0, false, err
	}
	defer func() { _ = tx.Rollback() }()

	videoIDs := make(map[string]int64, len(videos))
	anyPending := false

	for _, v := range videos {
		pn := parsedByPath[v.Path]
		cls := ClassifyVideo(pn, folders, numberedSiblings)
		parsedBytes, _ := json.Marshal(map[string]any{
			"title":        pn.Title,
			"year":         pn.Year,
			"season":       pn.Season,
			"episode":      pn.Episode,
			"episodeEnd":   pn.EpisodeEnd,
			"looseEpisode": pn.LooseEpisode,
			"fansubStyle":  pn.FansubStyle,
			"resolution":   pn.Resolution,
			"hdr":          pn.HDR,
			"key":          cls.Key(),
		})
		parsedStr := string(parsedBytes)

		prev := s.lookupExistingFileTx(tx, mountID, v.Path, v.ID)
		fid, err := s.upsertFileTx(tx, mountID, v, db.FileRoleVideo, scanID, nil, "", &parsedStr, cls.VersionLabel, pn, now)
		if err != nil {
			return 0, false, err
		}
		videoIDs[v.Path] = fid

		if prev == nil || prev.RemoteID != v.ID || prev.ItemID == nil {
			itemID, addedPend, err := s.fileVideoTx(tx, fid, prev, cls, v.CreatedAt, v.ModifiedAt, now)
			if err != nil {
				return 0, false, err
			}
			if addedPend {
				anyPending = true
			}
			_ = itemID
		}
	}

	for _, sub := range matchSubtitles(files) {
		var ownerPtr *int64
		if oid, ok := videoIDs[sub.Owner.Path]; ok {
			ownerPtr = &oid
		}
		if _, err := s.upsertFileTx(tx, mountID, sub.Subtitle, db.FileRoleSubtitle, scanID, ownerPtr, sub.Language, nil, "", ParsedName{}, now); err != nil {
			return 0, false, err
		}
	}

	for _, o := range others {
		if _, err := s.upsertFileTx(tx, mountID, o.entry, o.role, scanID, nil, "", nil, "", ParsedName{}, now); err != nil {
			return 0, false, err
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, false, err
	}
	return len(videos), anyPending, nil
}

func (s *Scanner) lookupExistingFileTx(tx *sql.Tx, mountID, path, remoteID string) *existingFileState {
	var st existingFileState
	var itemID sql.NullInt64
	var rid sql.NullString
	err := tx.QueryRow(`
		SELECT id, item_id, remote_id, match_state FROM media_files WHERE mount_id = ? AND path = ?`,
		mountID, path,
	).Scan(&st.ID, &itemID, &rid, &st.MatchState)
	if err != nil && remoteID != "" {
		err = tx.QueryRow(`
			SELECT id, item_id, remote_id, match_state FROM media_files WHERE mount_id = ? AND remote_id = ?`,
			mountID, remoteID,
		).Scan(&st.ID, &itemID, &rid, &st.MatchState)
	}
	if err != nil {
		return nil
	}
	if itemID.Valid {
		st.ItemID = &itemID.Int64
	}
	st.RemoteID = rid.String
	return &st
}

func (s *Scanner) upsertFileTx(
	tx *sql.Tx,
	mountID string,
	e storage.Entry,
	role string,
	scanID int64,
	ownerFileID *int64,
	language string,
	parsedJSON *string,
	versionLabel string,
	pn ParsedName,
	now int64,
) (int64, error) {
	var existingID int64
	err := tx.QueryRow(`SELECT id FROM media_files WHERE mount_id = ? AND path = ?`, mountID, e.Path).Scan(&existingID)
	if err != nil && e.ID != "" {
		err = tx.QueryRow(`SELECT id FROM media_files WHERE mount_id = ? AND remote_id = ?`, mountID, e.ID).Scan(&existingID)
	}

	var ridPtr *string
	if e.ID != "" {
		ridPtr = &e.ID
	}
	var langPtr *string
	if language != "" {
		langPtr = &language
	}
	var vlPtr *string
	if versionLabel != "" {
		vlPtr = &versionLabel
	}
	var widthHint, heightHint *int
	switch pn.Resolution {
	case "2160p":
		w, h := 3840, 2160
		widthHint, heightHint = &w, &h
	case "1080p":
		w, h := 1920, 1080
		widthHint, heightHint = &w, &h
	case "720p":
		w, h := 1280, 720
		widthHint, heightHint = &w, &h
	}
	var hdrHint *string
	if pn.HDR != "" {
		hdrHint = &pn.HDR
	}

	if err == nil {
		_, err = tx.Exec(`
			UPDATE media_files SET
				path = ?, remote_id = COALESCE(?, remote_id), role = ?,
				owner_file_id = COALESCE(?, owner_file_id),
				size = COALESCE(?, size), modified_at = COALESCE(?, modified_at),
				source_created_at = COALESCE(?, source_created_at),
				parsed_json = COALESCE(?, parsed_json),
				version_label = COALESCE(?, version_label),
				language = COALESCE(?, language),
				width = COALESCE(width, ?),
				height = COALESCE(height, ?),
				hdr_format = COALESCE(hdr_format, ?),
				seen_in_scan = ?
			WHERE id = ?`,
			e.Path, ridPtr, role, ownerFileID, e.Size, e.ModifiedAt, e.CreatedAt,
			parsedJSON, vlPtr, langPtr, widthHint, heightHint, hdrHint, scanID, existingID,
		)
		return existingID, err
	}

	res, err := tx.Exec(`
		INSERT INTO media_files(
			mount_id, path, remote_id, role, owner_file_id, size, modified_at, source_created_at,
			match_state, parsed_json, version_label, language, width, height, hdr_format, seen_in_scan, added_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?)`,
		mountID, e.Path, ridPtr, role, ownerFileID, e.Size, e.ModifiedAt, e.CreatedAt,
		parsedJSON, vlPtr, langPtr, widthHint, heightHint, hdrHint, scanID, now,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Scanner) fileVideoTx(
	tx *sql.Tx,
	fileID int64,
	prev *existingFileState,
	cls ClassifiedVideo,
	createdAt, modifiedAt *int64,
	now int64,
) (int64, bool, error) {
	if prev != nil && prev.ItemID != nil {
		return *prev.ItemID, false, nil
	}

	srcAdded := now
	if createdAt != nil && *createdAt > 0 {
		srcAdded = *createdAt
	} else if modifiedAt != nil && *modifiedAt > 0 {
		srcAdded = *modifiedAt
	}

	if !cls.IsKnown() {
		// Create an unmatched placeholder movie item under pending shelf.
		var rawPath string
		_ = tx.QueryRow(`SELECT path FROM media_files WHERE id = ?`, fileID).Scan(&rawPath)
		title := fileStem(storage.BaseName(rawPath))
		if title == "" {
			title = "未命名视频"
		}
		itemID, err := insertPlaceholderItemTx(tx, db.KindMovie, db.ShelfPending, title, nil, nil, nil, nil, nil, srcAdded, now)
		if err != nil {
			return 0, false, err
		}
		_, err = tx.Exec(`UPDATE media_files SET item_id = ?, match_state = 'unmatched' WHERE id = ?`, itemID, fileID)
		return itemID, false, err
	}

	if cls.Kind == db.KindMovie {
		itemID, err := findOrCreateMoviePlaceholderTx(tx, cls.Title, cls.Year, srcAdded, now)
		if err != nil {
			return 0, false, err
		}
		_, err = tx.Exec(`UPDATE media_files SET item_id = ?, match_state = 'pending' WHERE id = ?`, itemID, fileID)
		return itemID, true, err
	}

	// Episode: find or create show -> season -> episode
	showID, err := findOrCreateShowPlaceholderTx(tx, cls.Title, cls.Year, srcAdded, now)
	if err != nil {
		return 0, false, err
	}
	sNum := 1
	if cls.Season != nil {
		sNum = *cls.Season
	}
	eNum := 1
	if cls.Episode != nil {
		eNum = *cls.Episode
	}
	seasonID, err := findOrCreateSeasonTx(tx, showID, sNum, srcAdded, now)
	if err != nil {
		return 0, false, err
	}
	epID, err := findOrCreateEpisodeTx(tx, showID, seasonID, sNum, eNum, srcAdded, now)
	if err != nil {
		return 0, false, err
	}
	_, err = tx.Exec(`UPDATE media_files SET item_id = ?, match_state = 'pending' WHERE id = ?`, epID, fileID)
	return epID, true, err
}

func insertPlaceholderItemTx(
	tx *sql.Tx,
	kind, libraryType, title string,
	parentID, showID *int64,
	year, seasonNum, epNum *int,
	srcAdded, now int64,
) (int64, error) {
	res, err := tx.Exec(`
		INSERT INTO media_items(
			kind, library_type, parent_id, show_id, title, sort_title, year,
			season_number, episode_number, added_at, source_added_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		kind, libraryType, parentID, showID, title, db.SortTitleFor(title), year,
		seasonNum, epNum, now, srcAdded, now,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func findOrCreateMoviePlaceholderTx(tx *sql.Tx, title string, year *int, srcAdded, now int64) (int64, error) {
	var id int64
	var err error
	if year != nil {
		err = tx.QueryRow(`
			SELECT id FROM media_items
			WHERE kind = 'movie' AND LOWER(title) = LOWER(?) AND year = ?
			LIMIT 1`, title, *year).Scan(&id)
	} else {
		err = tx.QueryRow(`
			SELECT id FROM media_items
			WHERE kind = 'movie' AND LOWER(title) = LOWER(?) AND year IS NULL
			LIMIT 1`, title).Scan(&id)
	}
	if err == nil {
		return id, nil
	}
	return insertPlaceholderItemTx(tx, db.KindMovie, db.ShelfPending, title, nil, nil, year, nil, nil, srcAdded, now)
}

func findOrCreateShowPlaceholderTx(tx *sql.Tx, title string, year *int, srcAdded, now int64) (int64, error) {
	var id int64
	err := tx.QueryRow(`
		SELECT id FROM media_items
		WHERE kind = 'show' AND LOWER(title) = LOWER(?)
		LIMIT 1`, title).Scan(&id)
	if err == nil {
		return id, nil
	}
	return insertPlaceholderItemTx(tx, db.KindShow, db.ShelfPending, title, nil, nil, year, nil, nil, srcAdded, now)
}

func findOrCreateSeasonTx(tx *sql.Tx, showID int64, seasonNum int, srcAdded, now int64) (int64, error) {
	var id int64
	err := tx.QueryRow(`
		SELECT id FROM media_items
		WHERE kind = 'season' AND parent_id = ? AND season_number = ?
		LIMIT 1`, showID, seasonNum).Scan(&id)
	if err == nil {
		return id, nil
	}
	var libType string
	_ = tx.QueryRow(`SELECT library_type FROM media_items WHERE id = ?`, showID).Scan(&libType)
	if libType == "" {
		libType = db.ShelfPending
	}
	title := fmt.Sprintf("Season %d", seasonNum)
	if seasonNum == 0 {
		title = "Specials"
	}
	return insertPlaceholderItemTx(tx, db.KindSeason, libType, title, &showID, &showID, nil, &seasonNum, nil, srcAdded, now)
}

func findOrCreateEpisodeTx(tx *sql.Tx, showID, seasonID int64, seasonNum, epNum int, srcAdded, now int64) (int64, error) {
	var id int64
	err := tx.QueryRow(`
		SELECT id FROM media_items
		WHERE kind = 'episode' AND show_id = ? AND season_number = ? AND episode_number = ?
		LIMIT 1`, showID, seasonNum, epNum).Scan(&id)
	if err == nil {
		return id, nil
	}
	var libType string
	_ = tx.QueryRow(`SELECT library_type FROM media_items WHERE id = ?`, showID).Scan(&libType)
	if libType == "" {
		libType = db.ShelfPending
	}
	title := fmt.Sprintf("第 %d 集", epNum)
	return insertPlaceholderItemTx(tx, db.KindEpisode, libType, title, &seasonID, &showID, nil, &seasonNum, &epNum, srcAdded, now)
}

func (s *Scanner) finalizeScan(mountID string, scanID int64) (int, error) {
	res, err := s.store.DB().Exec(`DELETE FROM media_files WHERE mount_id = ? AND seen_in_scan < ?`, mountID, scanID)
	if err != nil {
		return 0, err
	}
	removed, _ := res.RowsAffected()
	_ = s.pruneEmptyItems()
	return int(removed), nil
}

func (s *Scanner) pruneEmptyItems() error {
	// Delete episodes/movies that have no video files left.
	_, err := s.store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind IN ('movie', 'episode')
		  AND NOT EXISTS (SELECT 1 FROM media_files mf WHERE mf.item_id = media_items.id AND mf.role = 'video')`)
	if err != nil {
		return err
	}
	// Delete seasons with no episodes.
	_, err = s.store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind = 'season'
		  AND NOT EXISTS (SELECT 1 FROM media_items c WHERE c.parent_id = media_items.id)`)
	if err != nil {
		return err
	}
	// Delete shows with no episodes.
	_, err = s.store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind = 'show'
		  AND NOT EXISTS (SELECT 1 FROM media_items c WHERE c.show_id = media_items.id)`)
	return err
}

// ─── Subtitle matching ────────────────────────────────────────────────────

type matchedSubtitle struct {
	Subtitle storage.Entry
	Owner    storage.Entry
	Language string
}

func matchSubtitles(files []storage.Entry) []matchedSubtitle {
	var videos, subs []storage.Entry
	for _, f := range files {
		ext := storage.ExtLower(f.Name)
		if IsVideoFile(f.Name) {
			videos = append(videos, f)
		} else if subtitleExts[ext] {
			subs = append(subs, f)
		}
	}
	if len(videos) == 0 || len(subs) == 0 {
		return nil
	}

	var out []matchedSubtitle
	for _, sub := range subs {
		subStem := fileStem(sub.Name)
		lowSub := strings.ToLower(subStem)

		var bestOwner *storage.Entry
		var bestScore int
		for i := range videos {
			v := &videos[i]
			vStem := strings.ToLower(fileStem(v.Name))
			if lowSub == vStem {
				bestOwner = v
				bestScore = len(vStem) + 100
				break
			}
			if strings.HasPrefix(lowSub, vStem+".") || strings.HasPrefix(lowSub, vStem+"-") || strings.HasPrefix(lowSub, vStem+"_") {
				if len(vStem) > bestScore {
					bestOwner = v
					bestScore = len(vStem)
				}
			}
		}
		if bestOwner == nil && len(videos) == 1 {
			bestOwner = &videos[0]
		}
		if bestOwner == nil {
			continue
		}
		lang := guessSubtitleLanguage(subStem, fileStem(bestOwner.Name))
		out = append(out, matchedSubtitle{
			Subtitle: sub,
			Owner:    *bestOwner,
			Language: lang,
		})
	}
	return out
}

func guessSubtitleLanguage(subStem, videoStem string) string {
	rest := subStem
	if strings.HasPrefix(strings.ToLower(subStem), strings.ToLower(videoStem)) {
		rest = subStem[len(videoStem):]
	}
	rest = strings.TrimLeft(rest, "._- ")
	if rest == "" {
		return ""
	}
	parts := strings.FieldsFunc(rest, func(r rune) bool { return r == '.' || r == '_' || r == '-' || r == ' ' })
	if len(parts) == 0 {
		return ""
	}
	return strings.ToLower(parts[len(parts)-1])
}

// ─── Background Container Probe ───────────────────────────────────────────

func (s *Scanner) ProbeFileByID(ctx context.Context, fileID int64) (db.MediaFile, error) {
	f, err := s.store.GetMediaFile(fileID)
	if err != nil {
		return db.MediaFile{}, err
	}
	if f.ProbedAt != nil && *f.ProbedAt > 0 {
		return f, nil
	}
	m, err := s.store.GetMount(f.MountID)
	if err != nil {
		return f, err
	}
	drv, err := s.storage.DriverFor(storage.MountConfig{
		ID:      m.ID,
		Kind:    m.Kind,
		Config:  m.Config,
		Secrets: m.Secrets,
	})
	if err != nil {
		return f, err
	}
	size := int64(0)
	if f.Size != nil {
		size = *f.Size
	}
	entry := storage.Entry{
		Path: f.Path,
		Name: path.Base(f.Path),
		Size: f.Size,
	}
	if f.RemoteID != nil {
		entry.ID = *f.RemoteID
	}
	if size <= 0 {
		if st, err := drv.Stat(ctx, f.Path); err == nil && st.Size != nil {
			size = *st.Size
			entry.Size = st.Size
		}
	}
	if size <= 0 {
		return f, nil
	}

	probed, err := ProbeMedia(storage.ExtLower(f.Path), size, func(start, length int64) ([]byte, error) {
		end := start + length - 1
		rr, err := drv.OpenRange(ctx, entry, start, &end, false)
		if err != nil {
			return nil, err
		}
		defer rr.Body.Close()
		return io.ReadAll(io.LimitReader(rr.Body, length))
	})
	if err != nil {
		return f, err
	}

	var vCodec, hdrPtr, contPtr *string
	var widthPtr, heightPtr *int
	if probed.Container != "" {
		contPtr = &probed.Container
	}
	if fv := probed.FirstVideo(); fv != nil {
		if fv.Codec != "" {
			vCodec = &fv.Codec
		}
		if fv.Width > 0 {
			widthPtr = &fv.Width
		}
		if fv.Height > 0 {
			heightPtr = &fv.Height
		}
		if fv.HDR != "" {
			hdrPtr = &fv.HDR
		}
	}
	_ = s.store.SaveFileProbe(f.ID, probed.DurationMs, probed.BitrateKbps, contPtr, vCodec, widthPtr, heightPtr, hdrPtr, probed.Streams)
	return s.store.GetMediaFile(f.ID)
}

func (s *Scanner) ProbePendingFiles(ctx context.Context, limit int) {
	if limit <= 0 {
		limit = 30
	}
	rows, err := s.store.DB().Query(`
		SELECT id FROM media_files
		WHERE role = 'video' AND probed_at IS NULL
		ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()

	for _, id := range ids {
		if ctx.Err() != nil {
			return
		}
		pCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
		_, _ = s.ProbeFileByID(pCtx, id)
		cancel()
	}
}
