package db

import (
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
)

type InspectTableInfo struct {
	Name        string   `json:"name"`
	Label       string   `json:"label"`
	Group       string   `json:"group"` // cache | library
	Description string   `json:"description"`
	RowCount    int64    `json:"row_count"`
	Columns     []string `json:"columns"`
	JSONCols    []string `json:"json_cols,omitempty"`
	TimeCols    []string `json:"time_cols,omitempty"`
	PKCols      []string `json:"pk_cols,omitempty"`
	ClearScope  string   `json:"clear_scope,omitempty"`
	Deletable   bool     `json:"deletable"`
}

type ImageCacheSummary struct {
	Files int64 `json:"files"`
	Bytes int64 `json:"bytes"`
}

type InspectTablePage struct {
	Table  InspectTableInfo `json:"table"`
	Total  int64            `json:"total"`
	Offset int              `json:"offset"`
	Limit  int              `json:"limit"`
	Rows   []map[string]any `json:"rows"`
}

type inspectTableSpec struct {
	Name        string
	Label       string
	Group       string
	Description string
	Columns     []string
	SearchCols  []string
	JSONCols    []string
	TimeCols    []string
	OrderBy     string
	ClearScope  string
	PKCols      []string
}

var inspectableTables = []inspectTableSpec{
	{
		Name:        "meta_works_cache",
		Label:       "作品元数据缓存",
		Group:       "cache",
		Description: "TMDB / Bangumi 刮削缓存的电影与剧集详情数据",
		Columns:     []string{"provider", "kind", "external_id", "lang", "status", "release_date", "fetched_at", "expires_at", "payload_json"},
		SearchCols:  []string{"provider", "kind", "external_id", "payload_json"},
		JSONCols:    []string{"payload_json"},
		TimeCols:    []string{"fetched_at", "expires_at"},
		OrderBy:     "fetched_at DESC",
		ClearScope:  "works",
		PKCols:      []string{"provider", "kind", "external_id", "lang"},
	},
	{
		Name:        "meta_seasons_cache",
		Label:       "分季元数据缓存",
		Group:       "cache",
		Description: "剧集/番剧的分季与单集列表缓存数据",
		Columns:     []string{"provider", "external_id", "season_number", "lang", "fetched_at", "expires_at", "payload_json"},
		SearchCols:  []string{"external_id", "payload_json"},
		JSONCols:    []string{"payload_json"},
		TimeCols:    []string{"fetched_at", "expires_at"},
		OrderBy:     "fetched_at DESC",
		ClearScope:  "seasons",
		PKCols:      []string{"provider", "external_id", "season_number", "lang"},
	},
	{
		Name:        "meta_people_cache",
		Label:       "演职员缓存",
		Group:       "cache",
		Description: "演员、导演等人物头像与简介缓存数据",
		Columns:     []string{"provider", "person_id", "name", "profile_path", "fetched_at", "expires_at", "extra_json"},
		SearchCols:  []string{"name", "person_id"},
		JSONCols:    []string{"extra_json"},
		TimeCols:    []string{"fetched_at", "expires_at"},
		OrderBy:     "fetched_at DESC",
		ClearScope:  "people",
		PKCols:      []string{"provider", "person_id"},
	},
	{
		Name:        "meta_search_cache",
		Label:       "刮削搜索缓存",
		Group:       "cache",
		Description: "关键词刮削候选检索结果缓存（24小时有效期）",
		Columns:     []string{"cache_key", "provider", "kind", "query", "year", "lang", "fetched_at", "expires_at", "payload_json"},
		SearchCols:  []string{"query", "cache_key", "payload_json"},
		JSONCols:    []string{"payload_json"},
		TimeCols:    []string{"fetched_at", "expires_at"},
		OrderBy:     "fetched_at DESC",
		ClearScope:  "search",
		PKCols:      []string{"cache_key"},
	},
	{
		Name:        "media_items",
		Label:       "媒体条目表",
		Group:       "library",
		Description: "已入库的电影、剧集、分季、单集及待匹配项主表",
		Columns:     []string{"id", "kind", "library_type", "title", "original_title", "year", "release_date", "rating", "parent_id", "show_id", "season_number", "episode_number", "tmdb_id", "bangumi_id", "metadata_source", "work_key", "locked", "poster_source", "backdrop_source", "added_at", "updated_at", "scraped_at"},
		SearchCols:  []string{"title", "original_title", "work_key", "tmdb_id", "bangumi_id"},
		TimeCols:    []string{"added_at", "updated_at", "scraped_at"},
		OrderBy:     "id DESC",
	},
	{
		Name:        "media_files",
		Label:       "媒体文件表",
		Group:       "library",
		Description: "扫描到的视频、字幕与 NFO 物理/网盘文件索引及探测轨道",
		Columns:     []string{"id", "mount_id", "role", "path", "remote_id", "item_id", "match_state", "match_locked", "container", "video_codec", "width", "height", "hdr_format", "duration_ms", "bitrate_kbps", "size", "version_label", "language", "parsed_json", "streams_json", "probed_at", "added_at"},
		SearchCols:  []string{"path", "remote_id", "video_codec", "container"},
		JSONCols:    []string{"parsed_json", "streams_json"},
		TimeCols:    []string{"probed_at", "added_at"},
		OrderBy:     "id DESC",
	},
	{
		Name:        "people",
		Label:       "演职员主表",
		Group:       "library",
		Description: "已关联到媒体库作品的演职员实体数据",
		Columns:     []string{"id", "name", "provider", "external_id", "department", "birthday", "place_of_birth", "photo_source", "biography"},
		SearchCols:  []string{"name", "external_id"},
		OrderBy:     "id DESC",
	},
	{
		Name:        "genres",
		Label:       "流派标签表",
		Group:       "library",
		Description: "媒体作品分类与流派标签字典",
		Columns:     []string{"id", "name"},
		SearchCols:  []string{"name"},
		OrderBy:     "id ASC",
	},
	{
		Name:        "lists",
		Label:       "合集与播单表",
		Group:       "library",
		Description: "TMDB 自动系列合集与自定义播放列表",
		Columns:     []string{"id", "kind", "title", "tmdb_id", "summary", "poster_source", "created_at", "updated_at"},
		SearchCols:  []string{"title", "tmdb_id"},
		TimeCols:    []string{"created_at", "updated_at"},
		OrderBy:     "id DESC",
	},
	{
		Name:        "watch_states",
		Label:       "观看进度与收藏",
		Group:       "library",
		Description: "播放断点、观看次数、完播状态与收藏标记",
		Columns:     []string{"item_id", "work_key", "last_file_id", "position_ms", "duration_ms", "watched", "play_count", "favorite", "hidden_from_continue", "last_played_at", "updated_at"},
		SearchCols:  []string{"work_key"},
		TimeCols:    []string{"last_played_at", "updated_at"},
		OrderBy:     "updated_at DESC",
	},
	{
		Name:        "work_prefs",
		Label:       "片头片尾跳过偏好",
		Group:       "library",
		Description: "按作品保存的片头/片尾跳过时间段、彩蛋保留与默认倍速",
		Columns:     []string{"work_key", "intro_enabled", "intro_start_ms", "intro_end_ms", "credits_enabled", "credits_from_end_ms", "keep_easter_egg_ms", "preferred_audio_lang", "preferred_sub_lang", "playback_speed", "updated_at"},
		SearchCols:  []string{"work_key"},
		TimeCols:    []string{"updated_at"},
		OrderBy:     "updated_at DESC",
	},
	{
		Name:        "mount_scan_states",
		Label:       "挂载扫描状态",
		Group:       "library",
		Description: "各存储挂载源扫描断点、夸克增量水位线及错误信息",
		Columns:     []string{"mount_id", "scan_id", "status", "quark_checkpoint", "started_at", "finished_at", "last_error", "pending_json"},
		SearchCols:  []string{"mount_id", "status", "last_error"},
		JSONCols:    []string{"pending_json"},
		TimeCols:    []string{"started_at", "finished_at"},
		OrderBy:     "mount_id ASC",
	},
	{
		Name:        "external_servers",
		Label:       "外部媒体服务器",
		Group:       "library",
		Description: "已连接的独立 Emby / Jellyfin 媒体服务器配置（密钥字段已隐藏）",
		Columns:     []string{"id", "name", "kind", "base_url", "auth_mode", "username", "user_id", "server_id", "server_version", "allow_insecure_tls", "enabled", "created_at", "updated_at"},
		SearchCols:  []string{"id", "name", "kind", "base_url", "username"},
		TimeCols:    []string{"created_at", "updated_at"},
		OrderBy:     "created_at ASC",
	},
}

func findInspectSpec(tableName string) (inspectTableSpec, bool) {
	clean := strings.TrimSpace(tableName)
	for _, spec := range inspectableTables {
		if spec.Name == clean {
			return spec, true
		}
	}
	return inspectTableSpec{}, false
}

func (s *Store) toInspectTableInfo(spec inspectTableSpec, count int64) InspectTableInfo {
	return InspectTableInfo{
		Name:        spec.Name,
		Label:       spec.Label,
		Group:       spec.Group,
		Description: spec.Description,
		RowCount:    count,
		Columns:     spec.Columns,
		JSONCols:    spec.JSONCols,
		TimeCols:    spec.TimeCols,
		PKCols:      spec.PKCols,
		ClearScope:  spec.ClearScope,
		Deletable:   spec.Group == "cache" && len(spec.PKCols) > 0,
	}
}

func (s *Store) ListInspectableTables() ([]InspectTableInfo, ImageCacheSummary, error) {
	out := make([]InspectTableInfo, 0, len(inspectableTables))
	for _, spec := range inspectableTables {
		var cnt int64
		_ = s.db.QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM %s`, spec.Name)).Scan(&cnt)
		out = append(out, s.toInspectTableInfo(spec, cnt))
	}

	var imgSum ImageCacheSummary
	cacheDir := filepath.Join(s.dataDir, "image_cache")
	_ = filepath.WalkDir(cacheDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		imgSum.Files++
		if info, sErr := d.Info(); sErr == nil {
			imgSum.Bytes += info.Size()
		}
		return nil
	})
	return out, imgSum, nil
}

func (s *Store) QueryInspectableTable(tableName, q string, limit, offset int) (InspectTablePage, error) {
	spec, ok := findInspectSpec(tableName)
	if !ok {
		return InspectTablePage{}, fmt.Errorf("%w: unknown or restricted table %q", ErrInvalidInput, tableName)
	}
	if limit <= 0 {
		limit = 30
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	whereSQL := ""
	args := make([]any, 0, len(spec.SearchCols)+2)
	trimmedQ := strings.TrimSpace(q)
	if trimmedQ != "" && len(spec.SearchCols) > 0 {
		pat := likeEscapePattern(trimmedQ)
		clauses := make([]string, 0, len(spec.SearchCols))
		for _, col := range spec.SearchCols {
			clauses = append(clauses, fmt.Sprintf(`COALESCE(CAST(%s AS TEXT), '') LIKE ? ESCAPE '\'`, col))
			args = append(args, pat)
		}
		whereSQL = "WHERE (" + strings.Join(clauses, " OR ") + ")"
	}

	var total int64
	if err := s.db.QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM %s %s`, spec.Name, whereSQL), args...).Scan(&total); err != nil {
		return InspectTablePage{}, err
	}

	queryArgs := append(append([]any{}, args...), limit, offset)
	sqlStr := fmt.Sprintf(
		`SELECT %s FROM %s %s ORDER BY %s LIMIT ? OFFSET ?`,
		strings.Join(spec.Columns, ", "),
		spec.Name,
		whereSQL,
		spec.OrderBy,
	)
	rows, err := s.db.Query(sqlStr, queryArgs...)
	if err != nil {
		return InspectTablePage{}, err
	}
	defer rows.Close()

	resultRows := make([]map[string]any, 0)
	for rows.Next() {
		vals := make([]any, len(spec.Columns))
		ptrs := make([]any, len(spec.Columns))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			continue
		}
		rowMap := make(map[string]any, len(spec.Columns))
		for i, col := range spec.Columns {
			if b, isBytes := vals[i].([]byte); isBytes {
				rowMap[col] = string(b)
			} else {
				rowMap[col] = vals[i]
			}
		}
		resultRows = append(resultRows, rowMap)
	}

	return InspectTablePage{
		Table:  s.toInspectTableInfo(spec, total),
		Total:  total,
		Offset: offset,
		Limit:  limit,
		Rows:   resultRows,
	}, nil
}

func (s *Store) DeleteMetaCacheRow(tableName string, pk map[string]string) (int64, error) {
	spec, ok := findInspectSpec(tableName)
	if !ok || spec.Group != "cache" || len(spec.PKCols) == 0 {
		return 0, fmt.Errorf("%w: table %q does not support single-row deletion", ErrInvalidInput, tableName)
	}
	clauses := make([]string, 0, len(spec.PKCols))
	args := make([]any, 0, len(spec.PKCols))
	for _, col := range spec.PKCols {
		v, exists := pk[col]
		if !exists {
			return 0, fmt.Errorf("%w: missing primary key field %s", ErrInvalidInput, col)
		}
		clauses = append(clauses, fmt.Sprintf(`CAST(%s AS TEXT) = ?`, col))
		args = append(args, v)
	}
	res, err := s.db.Exec(fmt.Sprintf(`DELETE FROM %s WHERE %s`, spec.Name, strings.Join(clauses, " AND ")), args...)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}
