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
	Group       string   `json:"group"` // cache | link
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

// Per D8, platform admins can inspect only public metadata tables; no tenant or
// user media/source tables are ever exposed here.
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
		Name:        "work_id_links",
		Label:       "作品外部ID映射",
		Group:       "link",
		Description: "跨数据源外部 ID 到规范 work_key 的公共映射关系",
		Columns:     []string{"kind", "provider", "external_id", "canonical_key", "implied_season", "updated_at"},
		SearchCols:  []string{"provider", "external_id", "canonical_key"},
		TimeCols:    []string{"updated_at"},
		OrderBy:     "updated_at DESC",
		PKCols:      []string{"kind", "provider", "external_id"},
	},
}

func likeEscapePattern(q string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return "%" + r.Replace(strings.TrimSpace(q)) + "%"
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
		_ = s.ReadDB().QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM %s`, spec.Name)).Scan(&cnt)
		out = append(out, s.toInspectTableInfo(spec, cnt))
	}

	var imgSum ImageCacheSummary
	cacheDir := filepath.Join(s.dataDir, "artwork_cache")
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
	if err := s.ReadDB().QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM %s %s`, spec.Name, whereSQL), args...).Scan(&total); err != nil {
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
	rows, err := s.ReadDB().Query(sqlStr, queryArgs...)
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
