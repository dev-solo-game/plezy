package api

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"plezy/media_server/internal/auth"
	"plezy/media_server/internal/db"
	"plezy/media_server/internal/storage"
	"plezy/media_server/internal/stream"
)

type playbackVariantInfo struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Width     int    `json:"width,omitempty"`
	Height    int    `json:"height,omitempty"`
	IsHLS     bool   `json:"is_hls"`
	StreamURL string `json:"stream_url"`
}

type playbackVersionInfo struct {
	File              db.MediaFile          `json:"file"`
	StreamURL         string                `json:"stream_url"`
	StreamToken       string                `json:"stream_token"`
	BrowserCompatible bool                  `json:"browser_compatible"`
	CompatWarning     string                `json:"compat_warning,omitempty"`
	Variants          []playbackVariantInfo `json:"variants,omitempty"`
	DirectLink        *storage.DirectLink   `json:"direct_link,omitempty"`
}

type playbackSubtitleInfo struct {
	ID       int64  `json:"id"`
	FileName string `json:"file_name"`
	Language string `json:"language,omitempty"`
	Ext      string `json:"ext"`
	VttURL   string `json:"vtt_url"`
	RawURL   string `json:"raw_url"`
}

func variantDisplayLabel(id string) string {
	switch id {
	case "4k":
		return "4K"
	case "2k":
		return "2K"
	case "super":
		return "超清"
	case "high":
		return "高清"
	case "normal":
		return "标清"
	case "low":
		return "流畅"
	default:
		return strings.ToUpper(id)
	}
}

func evaluateBrowserCompatibility(f db.MediaFile) (bool, string) {
	ext := strings.ToLower(storage.ExtLower(f.Path))
	container := ext
	if f.Container != nil && *f.Container != "" {
		container = strings.ToLower(*f.Container)
	}
	switch container {
	case "avi", "wmv", "rmvb", "rm", "flv", "ts", "mts", "m2ts":
		return false, "容器格式 (" + strings.ToUpper(container) + ") 浏览器通常无法直接原生解码，建议使用夸克云转码或呼起本地播放器"
	}

	var hasAudio bool
	var hasBrowserAudio bool
	var audioCodecs []string
	for _, st := range f.Streams {
		if st.Kind != "audio" {
			continue
		}
		hasAudio = true
		c := strings.ToLower(st.Codec)
		audioCodecs = append(audioCodecs, strings.ToUpper(c))
		switch c {
		case "aac", "mp3", "opus", "flac", "vorbis", "pcm":
			hasBrowserAudio = true
		}
	}
	if hasAudio && !hasBrowserAudio {
		return false, "音轨编码 (" + strings.Join(audioCodecs, "/") + ") 浏览器原生不支持可能无声，建议使用夸克云转码或呼起本地播放器"
	}
	if f.VideoCodec != nil && (*f.VideoCodec == "mpeg2video" || *f.VideoCodec == "mpeg4") {
		return false, "视频编码 (" + strings.ToUpper(*f.VideoCodec) + ") 浏览器支持受限，建议使用外部播放器"
	}
	return true, ""
}

func (s *Server) buildOriginBase(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	if r.Host != "" {
		return scheme + "://" + r.Host
	}
	return ""
}

func (s *Server) buildPlaybackForFileList(
	r *http.Request,
	files []db.MediaFile,
	subtitles []db.MediaFile,
	selectedFileID int64,
	includeDirect bool,
) ([]playbackVersionInfo, []playbackSubtitleInfo, string) {
	versions := make([]playbackVersionInfo, 0, len(files))
	origin := s.buildOriginBase(r)

	for idx, f := range files {
		if f.ProbedAt == nil {
			pCtx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
			if probed, err := s.Coordinator.Scanner.ProbeFileByID(pCtx, f.ID); err == nil {
				f = probed
			}
			cancel()
		}

		tok := s.Auth.SignStreamToken("file", strconv.FormatInt(f.ID, 10), auth.DefaultStreamTTL)
		relStream := fmt.Sprintf("/api/v1/stream/file/%d?token=%s", f.ID, url.QueryEscape(tok))
		compat, warn := evaluateBrowserCompatibility(f)

		ver := playbackVersionInfo{
			File:              f,
			StreamURL:         relStream,
			StreamToken:       tok,
			BrowserCompatible: compat,
			CompatWarning:     warn,
		}

		shouldInspectRemote := f.ID == selectedFileID || (selectedFileID == 0 && idx == 0)
		if shouldInspectRemote {
			if m, err := s.Store.GetMount(f.MountID); err == nil {
				if drv, err := s.Storage.DriverFor(storage.MountConfig{
					ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets,
				}); err == nil {
					entry := storage.Entry{Path: f.Path, Name: storage.BaseName(f.Path), Size: f.Size}
					if f.RemoteID != nil {
						entry.ID = *f.RemoteID
					}
					if vs, ok := drv.(storage.VariantSource); ok {
						vCtx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
						if rawVariants, err := vs.StreamVariants(vCtx, entry, false); err == nil {
							for _, rv := range rawVariants {
								ext := "mp4"
								if rv.IsHLS {
									ext = "m3u8"
								}
								vURL := fmt.Sprintf("/api/v1/stream/variant/%d/%s/play.%s?token=%s",
									f.ID, url.PathEscape(rv.ID), ext, url.QueryEscape(tok))
								ver.Variants = append(ver.Variants, playbackVariantInfo{
									ID:        rv.ID,
									Label:     variantDisplayLabel(rv.ID),
									Width:     rv.Width,
									Height:    rv.Height,
									IsHLS:     rv.IsHLS,
									StreamURL: vURL,
								})
							}
						}
						cancel()
					}
					if includeDirect {
						if ds, ok := drv.(storage.DirectLinkSource); ok {
							dCtx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
							if dl, err := ds.ResolveDirectLink(dCtx, entry, false); err == nil {
								ver.DirectLink = &dl
							}
							cancel()
						}
					}
				}
			}
		}

		versions = append(versions, ver)
	}

	subs := make([]playbackSubtitleInfo, 0, len(subtitles))
	for _, sub := range subtitles {
		sTok := s.Auth.SignStreamToken("sub", strconv.FormatInt(sub.ID, 10), auth.DefaultStreamTTL)
		lang := ""
		if sub.Language != nil {
			lang = *sub.Language
		}
		subs = append(subs, playbackSubtitleInfo{
			ID:       sub.ID,
			FileName: storage.BaseName(sub.Path),
			Language: lang,
			Ext:      storage.ExtLower(sub.Path),
			VttURL:   fmt.Sprintf("/api/v1/subtitles/%d?format=vtt&token=%s", sub.ID, url.QueryEscape(sTok)),
			RawURL:   fmt.Sprintf("/api/v1/subtitles/%d?format=raw&token=%s", sub.ID, url.QueryEscape(sTok)),
		})
	}

	return versions, subs, origin
}

func externalPlayersForURL(fullStreamURL string) map[string]string {
	if fullStreamURL == "" {
		return map[string]string{}
	}
	return map[string]string{
		"direct":    fullStreamURL,
		"potplayer": "potplayer://" + fullStreamURL,
		"vlc":       "vlc://" + fullStreamURL,
		"iina":      "iina://weblink?url=" + url.QueryEscape(fullStreamURL),
		"mpv":       "mpv://play/" + fullStreamURL,
	}
}

func (s *Server) handlePlaybackInfoItem(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	itemID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid item id")
		return
	}
	item, err := s.Store.GetMediaItem(itemID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if item.Kind == db.KindShow {
		ep, err := s.Store.FindOnDeckEpisode(item.ID)
		if err != nil || ep == nil {
			writeErr(w, r, http.StatusNotFound, "no playable episodes in show")
			return
		}
		item = *ep
	}

	detail, err := s.Store.GetItemDetail(item.ID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if len(detail.Files) == 0 {
		writeErr(w, r, http.StatusNotFound, "no video files found for item")
		return
	}

	selectedFileID, _ := strconv.ParseInt(r.URL.Query().Get("file_id"), 10, 64)
	if selectedFileID == 0 && detail.Item.WatchState != nil && detail.Item.WatchState.LastFileID != nil {
		selectedFileID = *detail.Item.WatchState.LastFileID
	}
	if selectedFileID == 0 {
		selectedFileID = detail.Files[0].ID
	}

	includeDirect := r.URL.Query().Get("include_direct") == "1"
	versions, subs, origin := s.buildPlaybackForFileList(r, detail.Files, detail.Subtitles, selectedFileID, includeDirect)

	var activeURL string
	for _, v := range versions {
		if v.File.ID == selectedFileID {
			activeURL = origin + v.StreamURL
			break
		}
	}
	if activeURL == "" && len(versions) > 0 {
		activeURL = origin + versions[0].StreamURL
	}

	resumeMs := int64(0)
	if detail.Item.WatchState != nil && !detail.Item.WatchState.Watched {
		resumeMs = detail.Item.WatchState.PositionMs
	}
	cfg := s.Store.GetServerSettings()

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                       0,
		"item":                       detail.Item,
		"show":                       detail.Show,
		"selected_file_id":           selectedFileID,
		"resume_position_ms":         resumeMs,
		"work_prefs":                 detail.WorkPrefs,
		"next_episode":               detail.NextEpisode,
		"prev_episode":               detail.PrevEpisode,
		"versions":                   versions,
		"subtitles":                  subs,
		"web_prefer_cloud_transcode": cfg.WebPreferCloudTranscode,
		"external_players":           externalPlayersForURL(activeURL),
	})
}

func (s *Server) handlePlaybackInfoFile(w http.ResponseWriter, r *http.Request, _ *db.AdminAccount, _ *db.SessionRecord) {
	fileID, err := strconv.ParseInt(r.PathValue("file_id"), 10, 64)
	if err != nil {
		writeErr(w, r, http.StatusBadRequest, "invalid file id")
		return
	}
	f, err := s.Store.GetMediaFile(fileID)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if f.ItemID != nil {
		// Delegate seamlessly if file already belongs to an item
		r2 := r.Clone(r.Context())
		r2.SetPathValue("id", strconv.FormatInt(*f.ItemID, 10))
		q := r2.URL.Query()
		q.Set("file_id", strconv.FormatInt(fileID, 10))
		r2.URL.RawQuery = q.Encode()
		s.handlePlaybackInfoItem(w, r2, nil, nil)
		return
	}

	includeDirect := r.URL.Query().Get("include_direct") == "1"
	versions, subs, origin := s.buildPlaybackForFileList(r, []db.MediaFile{f}, nil, f.ID, includeDirect)
	activeURL := ""
	if len(versions) > 0 {
		activeURL = origin + versions[0].StreamURL
	}
	cfg := s.Store.GetServerSettings()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                       0,
		"selected_file_id":           f.ID,
		"resume_position_ms":         0,
		"versions":                   versions,
		"subtitles":                  subs,
		"web_prefer_cloud_transcode": cfg.WebPreferCloudTranscode,
		"external_players":           externalPlayersForURL(activeURL),
	})
}

func (s *Server) authorizeStream(r *http.Request, scope, resourceID string) bool {
	if _, _, err := s.authenticateRequest(r); err == nil {
		return true
	}
	tok := strings.TrimSpace(r.URL.Query().Get("token"))
	if tok == "" {
		return false
	}
	return s.Auth.VerifyStreamToken(tok, scope, resourceID) == nil
}

func (s *Server) driverAndEntryForFile(f db.MediaFile) (storage.Driver, storage.Entry, error) {
	m, err := s.Store.GetMount(f.MountID)
	if err != nil {
		return nil, storage.Entry{}, err
	}
	drv, err := s.Storage.DriverFor(storage.MountConfig{
		ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets,
	})
	if err != nil {
		return nil, storage.Entry{}, err
	}
	entry := storage.Entry{
		Path: f.Path,
		Name: storage.BaseName(f.Path),
		Size: f.Size,
	}
	if f.RemoteID != nil {
		entry.ID = *f.RemoteID
	}
	return drv, entry, nil
}

func (s *Server) handleStreamFile(w http.ResponseWriter, r *http.Request) {
	fileIDStr := r.PathValue("file_id")
	fileID, err := strconv.ParseInt(fileIDStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid file id", http.StatusBadRequest)
		return
	}
	if !s.authorizeStream(r, "file", fileIDStr) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	f, err := s.Store.GetMediaFile(fileID)
	if err != nil {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}
	drv, entry, err := s.driverAndEntryForFile(f)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	stream.ServeDriverRange(w, r, drv, entry)
}

func (s *Server) handleStreamVariant(w http.ResponseWriter, r *http.Request) {
	fileIDStr := r.PathValue("file_id")
	variantID := r.PathValue("variant_id")
	fileID, err := strconv.ParseInt(fileIDStr, 10, 64)
	if err != nil || variantID == "" {
		http.Error(w, "invalid variant request", http.StatusBadRequest)
		return
	}
	if !s.authorizeStream(r, "file", fileIDStr) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	f, err := s.Store.GetMediaFile(fileID)
	if err != nil {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}
	drv, entry, err := s.driverAndEntryForFile(f)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	vs, ok := drv.(storage.VariantSource)
	if !ok {
		http.Error(w, "storage does not offer stream variants", http.StatusBadRequest)
		return
	}
	tok := strings.TrimSpace(r.URL.Query().Get("token"))
	s.HLS.ServeVariant(w, r, f.MountID, vs, entry, variantID, tok)
}

func (s *Server) handleStreamHLSSeg(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mountID := q.Get("mount")
	fid := q.Get("fid")
	if mountID == "" || fid == "" {
		http.Error(w, "missing mount or fid", http.StatusBadRequest)
		return
	}
	// Segment access is guarded both by the per-URL HMAC signature inside HLSProxy.ServeSegment
	// and optionally a valid session or token.
	m, err := s.Store.GetMount(mountID)
	if err != nil {
		http.Error(w, "mount not found", http.StatusNotFound)
		return
	}
	drv, err := s.Storage.DriverFor(storage.MountConfig{
		ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	vs, ok := drv.(storage.VariantSource)
	if !ok {
		http.Error(w, "mount does not support variants", http.StatusBadRequest)
		return
	}
	entry := storage.Entry{ID: fid, Path: "/" + fid, Name: fid}
	s.HLS.ServeSegment(w, r, vs, entry, q.Get("token"))
}

func (s *Server) handleSubtitle(w http.ResponseWriter, r *http.Request) {
	fileIDStr := r.PathValue("file_id")
	fileID, err := strconv.ParseInt(fileIDStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid subtitle id", http.StatusBadRequest)
		return
	}
	if !s.authorizeStream(r, "sub", fileIDStr) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	f, err := s.Store.GetMediaFile(fileID)
	if err != nil || f.Role != db.FileRoleSubtitle {
		http.Error(w, "subtitle not found", http.StatusNotFound)
		return
	}
	drv, entry, err := s.driverAndEntryForFile(f)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	format := r.URL.Query().Get("format")
	if format == "" {
		format = "vtt"
	}
	stream.ServeSubtitle(w, r, drv, entry, format)
}

func (s *Server) handleLocalArtwork(w http.ResponseWriter, r *http.Request) {
	if !s.authenticateArtworkRequest(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	mountID := r.PathValue("mount_id")
	rawPath := strings.TrimSpace(r.URL.Query().Get("path"))
	if rawPath == "" {
		http.Error(w, "path is required", http.StatusBadRequest)
		return
	}
	norm := storage.NormalizePath(rawPath)
	ext := storage.ExtLower(norm)
	if ext != "jpg" && ext != "jpeg" && ext != "png" && ext != "webp" {
		http.Error(w, "unsupported image format", http.StatusForbidden)
		return
	}
	if data, ok := s.readLocalArtworkCache(mountID, norm); ok {
		w.Header().Set("Content-Type", stream.ContentTypeForExt(ext))
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
		return
	}
	m, err := s.Store.GetMount(mountID)
	if err != nil {
		http.Error(w, "mount not found", http.StatusNotFound)
		return
	}
	drv, err := s.Storage.DriverFor(storage.MountConfig{
		ID: m.ID, Kind: m.Kind, Config: m.Config, Secrets: m.Secrets,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	rr, err := drv.OpenRange(r.Context(), storage.Entry{Path: norm, Name: storage.BaseName(norm)}, 0, nil, false)
	if err != nil {
		http.Error(w, "artwork not found", http.StatusNotFound)
		return
	}
	defer rr.Body.Close()

	data, err := io.ReadAll(io.LimitReader(rr.Body, 15*1024*1024))
	if err != nil {
		http.Error(w, "failed to read artwork", http.StatusBadGateway)
		return
	}
	if m.Kind != "local" && len(data) > 0 {
		s.writeLocalArtworkCache(mountID, norm, data)
	}
	w.Header().Set("Content-Type", stream.ContentTypeForExt(ext))
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) handleRemoteArtwork(w http.ResponseWriter, r *http.Request) {
	if !s.authenticateArtworkRequest(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.serveRemoteArtwork(w, r)
}

func (s *Server) serveRemoteArtwork(w http.ResponseWriter, r *http.Request) {
	src := strings.TrimSpace(r.URL.Query().Get("src"))
	size := strings.TrimSpace(r.URL.Query().Get("size"))
	cfg := s.Store.GetServerSettings()

	if !cfg.ProxyImages {
		resolved, err := s.Meta.ResolveRemoteImageURL(src, size)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		http.Redirect(w, r, resolved, http.StatusFound)
		return
	}

	img, err := s.Meta.FetchRemoteImage(r.Context(), src, size)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", img.ContentType)
	w.Header().Set("Cache-Control", "public, max-age=2592000")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(img.Data)
}
