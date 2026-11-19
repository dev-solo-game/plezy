package api

import (
	"database/sql"
	"net/http"
	"strings"

	"plezy/media_server/internal/db"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/storage/quark"
)

func (s *Server) handleListMounts(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	mounts, err := s.Store.ListMounts()
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	for i := range mounts {
		if mounts[i].ScanState != nil && s.Store.IsMountScanning(mounts[i].ID) {
			mounts[i].ScanState.Status = "running"
		}
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "mounts": mounts})
}

func (s *Server) handleCreateMount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		Name     string            `json:"name"`
		Kind     string            `json:"kind"`
		Config   map[string]any    `json:"config"`
		Secrets  map[string]string `json:"secrets"`
		Enabled  *bool             `json:"enabled"`
		AutoScan *bool             `json:"auto_scan"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	if err := s.Storage.TestMount(r.Context(), storage.MountConfig{
		ID:      "test",
		Kind:    req.Kind,
		Config:  req.Config,
		Secrets: req.Secrets,
	}); err != nil {
		writeMappedError(w, r, err)
		return
	}
	m, err := s.Store.CreateMount(req.Name, req.Kind, req.Config, req.Secrets, enabled)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if strings.EqualFold(req.Kind, "quark") && req.Secrets["cookie"] != "" {
		sess := quark.ParsePcSession(req.Secrets["cookie"])
		if strings.TrimSpace(sess.Device.Utdid) != "" && strings.TrimSpace(sess.Device.Machine) != "" && strings.HasPrefix(strings.TrimSpace(req.Secrets["cookie"]), "{") {
			s.Store.AdoptQuarkPcDeviceIfAbsent(sess.Device.Utdid, sess.Device.Machine)
		}
	}
	s.Coordinator.RefreshWatchers()
	if req.AutoScan == nil || *req.AutoScan {
		s.Coordinator.TriggerMountScanAsync(m.ID, false)
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "mount": m})
}

func (s *Server) handleUpdateMount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	var req struct {
		Name    string            `json:"name"`
		Config  map[string]any    `json:"config"`
		Secrets map[string]string `json:"secrets"`
		Enabled *bool             `json:"enabled"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	existing, err := s.Store.GetMount(id)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	mergedCfg := existing.Config
	if req.Config != nil {
		mergedCfg = req.Config
	}
	mergedSecrets := make(map[string]string, len(existing.Secrets))
	for k, v := range existing.Secrets {
		mergedSecrets[k] = v
	}
	for k, v := range req.Secrets {
		if strings.TrimSpace(v) != "" {
			mergedSecrets[k] = v
		}
	}
	if err := s.Storage.TestMount(r.Context(), storage.MountConfig{
		ID:      id,
		Kind:    existing.Kind,
		Config:  mergedCfg,
		Secrets: mergedSecrets,
	}); err != nil {
		writeMappedError(w, r, err)
		return
	}
	var secPtr *map[string]string
	if len(req.Secrets) > 0 {
		secPtr = &req.Secrets
	}
	updated, err := s.Store.UpdateMount(id, req.Name, req.Config, secPtr, req.Enabled)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	s.Storage.Invalidate(id)
	s.Coordinator.RefreshWatchers()
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "mount": updated})
}

func (s *Server) handleDeleteMount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	s.Coordinator.Scanner.CancelMount(id)
	if err := s.Store.DeleteMount(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	s.Storage.Invalidate(id)
	// Clean orphan items no longer backed by any file
	_, _ = s.Store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind IN ('movie', 'episode')
		  AND NOT EXISTS (SELECT 1 FROM media_files mf WHERE mf.item_id = media_items.id AND mf.role = 'video')`)
	_, _ = s.Store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind = 'season' AND NOT EXISTS (SELECT 1 FROM media_items c WHERE c.parent_id = media_items.id)`)
	_, _ = s.Store.DB().Exec(`
		DELETE FROM media_items
		WHERE kind = 'show' AND NOT EXISTS (SELECT 1 FROM media_items c WHERE c.show_id = media_items.id)`)

	s.Coordinator.RefreshWatchers()
	s.Hub.Publish("library_changed", map[string]any{"deleted_mount_id": id})
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "status": "deleted"})
}

func (s *Server) handleTestMount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		ID      string            `json:"id"`
		Kind    string            `json:"kind"`
		Config  map[string]any    `json:"config"`
		Secrets map[string]string `json:"secrets"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	secrets := make(map[string]string)
	for k, v := range req.Secrets {
		secrets[k] = v
	}
	if req.ID != "" {
		if existing, err := s.Store.GetMount(req.ID); err == nil {
			for k, v := range existing.Secrets {
				if strings.TrimSpace(secrets[k]) == "" {
					secrets[k] = v
				}
			}
			if req.Kind == "" {
				req.Kind = existing.Kind
			}
		}
	}
	if err := s.Storage.TestMount(r.Context(), storage.MountConfig{
		ID:      "probe",
		Kind:    req.Kind,
		Config:  req.Config,
		Secrets: secrets,
	}); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "ok": true})
}

func (s *Server) handleQuarkAccount(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	m, err := s.Store.GetMount(id)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if m.Kind != "quark" {
		writeErr(w, r, http.StatusBadRequest, "mount is not quark")
		return
	}
	drv, err := s.Storage.DriverFor(storage.MountConfig{ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	qd, ok := drv.(*quark.Driver)
	if !ok {
		writeErr(w, r, http.StatusInternalServerError, "unexpected driver type")
		return
	}
	info, err := qd.AccountInfo(r.Context())
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "account": info})
}

func (s *Server) handleMountBrowsePreview(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		ID       string            `json:"id"`
		Kind     string            `json:"kind"`
		Config   map[string]any    `json:"config"`
		Secrets  map[string]string `json:"secrets"`
		Path     string            `json:"path"`
		ParentID string            `json:"parent_id"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	kind := strings.TrimSpace(req.Kind)
	cfgMap := req.Config
	secrets := make(map[string]string, len(req.Secrets))
	for k, v := range req.Secrets {
		secrets[k] = v
	}
	if strings.TrimSpace(req.ID) != "" {
		if existing, err := s.Store.GetMount(strings.TrimSpace(req.ID)); err == nil {
			if kind == "" {
				kind = existing.Kind
			}
			if cfgMap == nil {
				cfgMap = existing.Config
			}
			for k, v := range existing.Secrets {
				if strings.TrimSpace(secrets[k]) == "" {
					secrets[k] = v
				}
			}
		}
	}

	previewCfg := make(map[string]any, len(cfgMap))
	for k, v := range cfgMap {
		if k == "includePaths" || k == "excludePaths" {
			continue
		}
		previewCfg[k] = v
	}
	if strings.EqualFold(kind, "quark") {
		if strings.TrimSpace(storage.CfgString(previewCfg, "rootFolderId")) == "" {
			previewCfg["rootFolderId"] = "0"
		}
	}

	drv, err := s.Storage.PreviewDriver(storage.MountConfig{
		ID:      "preview",
		Kind:    kind,
		Config:  previewCfg,
		Secrets: secrets,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	dirPath := storage.NormalizePath(req.Path)
	var parent *storage.Entry
	if pid := strings.TrimSpace(req.ParentID); pid != "" {
		parent = &storage.Entry{
			Path:  dirPath,
			Name:  storage.BaseName(dirPath),
			IsDir: true,
			ID:    pid,
		}
	}

	entries, err := drv.List(r.Context(), dirPath, parent)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	dirs := make([]storage.Entry, 0)
	fileCount := 0
	for _, e := range entries {
		if e.IsDir {
			dirs = append(dirs, storage.Entry{
				Path:  e.Path,
				Name:  e.Name,
				IsDir: true,
				ID:    e.ID,
			})
		} else {
			fileCount++
		}
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"path":       dirPath,
		"parent":     storage.ParentPath(dirPath),
		"dirs":       dirs,
		"file_count": fileCount,
	})
}

func (s *Server) handleQuarkAccountPreview(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		ID     string `json:"id"`
		Mode   string `json:"mode"`
		Secret string `json:"secret"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, r, http.StatusBadRequest, err.Error())
		return
	}
	mode := strings.TrimSpace(req.Mode)
	secret := strings.TrimSpace(req.Secret)
	if strings.TrimSpace(req.ID) != "" {
		if existing, err := s.Store.GetMount(strings.TrimSpace(req.ID)); err == nil && existing.Kind == "quark" {
			if secret == "" {
				secret = existing.Secrets["cookie"]
			}
			if mode == "" {
				mode = storage.CfgString(existing.Config, "quarkMode")
			}
		}
	}
	if secret == "" {
		writeErr(w, r, http.StatusBadRequest, "quark credentials are required")
		return
	}
	if mode == "" {
		if strings.HasPrefix(secret, "{") {
			mode = "pc"
		} else {
			mode = "web"
		}
	}

	var nickname string
	if quark.ParseMode(mode) == quark.ModePC {
		nickname = quark.ParsePcSession(secret).Nickname
	}

	drv, err := s.Storage.PreviewDriver(storage.MountConfig{
		ID:      "preview-quark",
		Kind:    "quark",
		Config:  map[string]any{"quarkMode": mode, "rootFolderId": "0"},
		Secrets: map[string]string{"cookie": secret},
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	qd, ok := drv.(*quark.Driver)
	if !ok {
		writeErr(w, r, http.StatusInternalServerError, "unexpected driver type")
		return
	}
	info, err := qd.AccountInfo(r.Context())
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"account": map[string]any{
			"nickname":    nickname,
			"member_type": info.MemberType,
			"used_bytes":  info.UsedBytes,
			"total_bytes": info.TotalBytes,
		},
	})
}

func (s *Server) handleHostFSBrowse(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	p := r.URL.Query().Get("path")
	res, err := storage.BrowseHostDirectories(p, s.Storage.AllowedLocalRoots())
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"current": res.Current,
		"parent":  res.Parent,
		"dirs":    res.Dirs,
	})
}

func (s *Server) handleMountBrowse(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	id := r.PathValue("id")
	m, err := s.Store.GetMount(id)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	drv, err := s.Storage.DriverFor(storage.MountConfig{ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	dirPath := storage.NormalizePath(r.URL.Query().Get("path"))
	entries, err := drv.List(r.Context(), dirPath, nil)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	// Enrich entries with indexed file_id / item_id / poster when available for direct folder playback.
	type fileMeta struct {
		fileID      int64
		itemID      *int64
		title       string
		poster      string
		libraryType string
	}
	indexed := make(map[string]fileMeta)
	prefix := "/"
	if dirPath != "/" {
		prefix = dirPath + "/"
	}
	rows, qErr := s.Store.DB().Query(`
		SELECT mf.path, mf.id, mf.item_id, COALESCE(mi.title, ''), COALESCE(mi.poster_source, ''), COALESCE(mi.library_type, '')
		FROM media_files mf
		LEFT JOIN media_items mi ON mi.id = mf.item_id
		WHERE mf.mount_id = ? AND mf.role = 'video' AND mf.path LIKE ?`,
		m.ID, prefix+"%",
	)
	if qErr == nil {
		for rows.Next() {
			var p, t, ps, lt string
			var fid int64
			var iid sql.NullInt64
			if rows.Scan(&p, &fid, &iid, &t, &ps, &lt) == nil {
				var ip *int64
				if iid.Valid {
					v := iid.Int64
					ip = &v
				}
				indexed[p] = fileMeta{fileID: fid, itemID: ip, title: t, poster: ps, libraryType: lt}
			}
		}
		rows.Close()
	}

	type browseEntry struct {
		storage.Entry
		FileID      *int64 `json:"file_id,omitempty"`
		ItemID      *int64 `json:"item_id,omitempty"`
		Title       string `json:"title,omitempty"`
		Poster      string `json:"poster_source,omitempty"`
		LibraryType string `json:"library_type,omitempty"`
		IsVideo     bool   `json:"is_video,omitempty"`
	}
	out := make([]browseEntry, 0, len(entries))
	for _, e := range entries {
		be := browseEntry{Entry: e}
		if !e.IsDir {
			if meta, ok := indexed[e.Path]; ok {
				fid := meta.fileID
				be.FileID = &fid
				be.ItemID = meta.itemID
				be.Title = meta.title
				be.Poster = meta.poster
				be.LibraryType = meta.libraryType
				be.IsVideo = true
			}
		}
		out = append(out, be)
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"mount_id":   m.ID,
		"mount_name": m.Name,
		"path":       dirPath,
		"parent":     storage.ParentPath(dirPath),
		"entries":    out,
	})
}

func (s *Server) handleQuarkQrStart(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	var req struct {
		Mode string `json:"mode"`
	}
	if r.Body != nil {
		_ = decodeJSON(w, r, &req)
	}
	res, err := s.QuarkQR.Start(r.Context(), req.Mode)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"session_id": res.SessionID,
		"mode":       res.Mode,
		"qr_content": res.QRContent,
		"expires_at": res.ExpiresAt,
	})
}

func (s *Server) handleQuarkQrPoll(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	sid := strings.TrimSpace(r.URL.Query().Get("session_id"))
	if sid == "" {
		writeErr(w, r, http.StatusBadRequest, "session_id is required")
		return
	}
	res, err := s.QuarkQR.Poll(r.Context(), sid)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"status":  res.Status,
		"secret":  res.Secret,
		"message": res.Message,
	})
}
