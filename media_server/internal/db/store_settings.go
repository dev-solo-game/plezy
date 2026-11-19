package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const (
	DefaultServerName        = "TTPlay 媒体库"
	DefaultTmdbAPIBase       = "https://api.tmdb.org/3"
	DefaultTmdbImageBase     = "https://image.tmdb.org/t/p"
	DefaultBangumiAPIBase    = "https://api.bgm.tv"
	DefaultScraperLang       = "zh-CN"
	DefaultWatchedThreshold  = 0.9
	DefaultScanIntervalMin   = 60
	DefaultAccentTheme       = "glacier"
)

var schemeRegex = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*://`)

func NormalizeTmdbBase(raw, fallback, defaultPath string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return fallback
	}
	if !schemeRegex.MatchString(text) {
		text = "https://" + text
	}
	text = strings.TrimRight(text, "/")
	u, err := url.Parse(text)
	if err != nil || u.Host == "" {
		return fallback
	}
	if u.Path == "" {
		return text + defaultPath
	}
	return text
}

func NormalizeBangumiBase(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return DefaultBangumiAPIBase
	}
	if !schemeRegex.MatchString(text) {
		text = "https://" + text
	}
	text = strings.TrimRight(text, "/")
	u, err := url.Parse(text)
	if err != nil || u.Host == "" {
		return DefaultBangumiAPIBase
	}
	return text
}

func ParseProxyURL(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil
	}
	if !strings.Contains(trimmed, "://") {
		trimmed = "http://" + trimmed
	}
	trimmed = strings.TrimRight(trimmed, "/")
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("invalid proxy host")
	}
	return u, nil
}

func MaskSecret(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if len(trimmed) <= 4 {
		return "****"
	}
	return "****" + trimmed[len(trimmed)-4:]
}

func (s *Store) GetSetting(key, fallback string) string {
	var raw string
	err := s.db.QueryRow(`SELECT value FROM server_settings WHERE key = ?`, key).Scan(&raw)
	if err != nil {
		return fallback
	}
	return raw
}

func (s *Store) SetSetting(key, val string) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO server_settings(key, value) VALUES (?, ?)`, key, val)
	return err
}

func (s *Store) GetSettingBool(key string, fallback bool) bool {
	raw := strings.TrimSpace(strings.ToLower(s.GetSetting(key, "")))
	switch raw {
	case "1", "true", "yes":
		return true
	case "0", "false", "no":
		return false
	default:
		return fallback
	}
}

func (s *Store) SetSettingBool(key string, val bool) error {
	str := "false"
	if val {
		str = "true"
	}
	return s.SetSetting(key, str)
}

func (s *Store) GetServerSettings() ServerSettings {
	tmdbKey := ""
	if enc := s.GetSetting("tmdb_api_key_enc", ""); enc != "" {
		if plain, err := s.vault.Open(enc); err == nil {
			tmdbKey = strings.TrimSpace(plain)
		}
	} else {
		tmdbKey = strings.TrimSpace(s.GetSetting("tmdb_api_key", ""))
	}

	threshold := DefaultWatchedThreshold
	if raw := strings.TrimSpace(s.GetSetting("watched_threshold", "")); raw != "" {
		if f, err := strconv.ParseFloat(raw, 64); err == nil && f >= 0.5 && f <= 0.99 {
			threshold = f
		}
	}

	scanInterval := DefaultScanIntervalMin
	if raw := strings.TrimSpace(s.GetSetting("scan_interval_min", "")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 0 {
			scanInterval = v
		}
	}

	lang := strings.TrimSpace(s.GetSetting("scraper_lang", DefaultScraperLang))
	if lang == "" {
		lang = DefaultScraperLang
	}

	accent := strings.TrimSpace(s.GetSetting("accent_theme", DefaultAccentTheme))
	switch accent {
	case "glacier", "neutral", "ember", "plum":
	default:
		accent = DefaultAccentTheme
	}

	name := strings.TrimSpace(s.GetSetting("server_name", DefaultServerName))
	if name == "" {
		name = DefaultServerName
	}

	return ServerSettings{
		ServerName:              name,
		TmdbAPIKeySet:           tmdbKey != "",
		TmdbAPIKeyMasked:        MaskSecret(tmdbKey),
		TmdbAPIKey:              tmdbKey,
		TmdbAPIBase:             NormalizeTmdbBase(s.GetSetting("tmdb_api_base", DefaultTmdbAPIBase), DefaultTmdbAPIBase, "/3"),
		TmdbImageBase:           NormalizeTmdbBase(s.GetSetting("tmdb_image_base", DefaultTmdbImageBase), DefaultTmdbImageBase, "/t/p"),
		MetadataProxy:           strings.TrimSpace(s.GetSetting("metadata_proxy", "")),
		BangumiEnabled:          s.GetSettingBool("bangumi_enabled", true),
		BangumiAPIBase:          NormalizeBangumiBase(s.GetSetting("bangumi_api_base", DefaultBangumiAPIBase)),
		ProxyImages:             s.GetSettingBool("proxy_images", true),
		ScraperLang:             lang,
		PreferNfo:               s.GetSettingBool("prefer_nfo", true),
		WatchedThreshold:        threshold,
		ScanIntervalMin:         scanInterval,
		WatchLocalFS:            s.GetSettingBool("watch_local_fs", true),
		WebPreferCloudTranscode: s.GetSettingBool("web_prefer_cloud_transcode", true),
		AccentTheme:             accent,
	}
}

func (s *Store) UpdateServerSettings(req ServerSettingsUpdate) (ServerSettings, error) {
	if req.ServerName != nil {
		name := strings.TrimSpace(*req.ServerName)
		if name == "" {
			return ServerSettings{}, fmt.Errorf("%w: server_name cannot be empty", ErrInvalidInput)
		}
		if err := s.SetSetting("server_name", name); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ClearTmdbAPIKey {
		_ = s.SetSetting("tmdb_api_key_enc", "")
		_ = s.SetSetting("tmdb_api_key", "")
	} else if req.TmdbAPIKey != nil {
		key := strings.TrimSpace(*req.TmdbAPIKey)
		if key != "" {
			sealed, err := s.vault.Seal(key)
			if err != nil {
				return ServerSettings{}, err
			}
			if err := s.SetSetting("tmdb_api_key_enc", sealed); err != nil {
				return ServerSettings{}, err
			}
			_ = s.SetSetting("tmdb_api_key", "")
		}
	}
	if req.TmdbAPIBase != nil {
		if err := s.SetSetting("tmdb_api_base", NormalizeTmdbBase(*req.TmdbAPIBase, DefaultTmdbAPIBase, "/3")); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.TmdbImageBase != nil {
		if err := s.SetSetting("tmdb_image_base", NormalizeTmdbBase(*req.TmdbImageBase, DefaultTmdbImageBase, "/t/p")); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.MetadataProxy != nil {
		proxy := strings.TrimSpace(*req.MetadataProxy)
		if proxy != "" {
			if _, err := ParseProxyURL(proxy); err != nil {
				return ServerSettings{}, fmt.Errorf("%w: invalid metadata_proxy: %v", ErrInvalidInput, err)
			}
		}
		if err := s.SetSetting("metadata_proxy", proxy); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.BangumiEnabled != nil {
		if err := s.SetSettingBool("bangumi_enabled", *req.BangumiEnabled); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.BangumiAPIBase != nil {
		if err := s.SetSetting("bangumi_api_base", NormalizeBangumiBase(*req.BangumiAPIBase)); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ProxyImages != nil {
		if err := s.SetSettingBool("proxy_images", *req.ProxyImages); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ScraperLang != nil {
		lang := strings.TrimSpace(*req.ScraperLang)
		if lang != "" {
			if err := s.SetSetting("scraper_lang", lang); err != nil {
				return ServerSettings{}, err
			}
		}
	}
	if req.PreferNfo != nil {
		if err := s.SetSettingBool("prefer_nfo", *req.PreferNfo); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.WatchedThreshold != nil {
		v := *req.WatchedThreshold
		if v < 0.5 || v > 0.99 {
			return ServerSettings{}, fmt.Errorf("%w: watched_threshold must be between 0.50 and 0.99", ErrInvalidInput)
		}
		if err := s.SetSetting("watched_threshold", strconv.FormatFloat(v, 'f', 2, 64)); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ScanIntervalMin != nil {
		v := *req.ScanIntervalMin
		if v < 0 {
			v = 0
		}
		if err := s.SetSetting("scan_interval_min", strconv.Itoa(v)); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.WatchLocalFS != nil {
		if err := s.SetSettingBool("watch_local_fs", *req.WatchLocalFS); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.WebPreferCloudTranscode != nil {
		if err := s.SetSettingBool("web_prefer_cloud_transcode", *req.WebPreferCloudTranscode); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.AccentTheme != nil {
		t := strings.TrimSpace(*req.AccentTheme)
		switch t {
		case "glacier", "neutral", "ember", "plum":
			if err := s.SetSetting("accent_theme", t); err != nil {
				return ServerSettings{}, err
			}
		default:
			return ServerSettings{}, fmt.Errorf("%w: invalid accent_theme", ErrInvalidInput)
		}
	}
	return s.GetServerSettings(), nil
}

// SeedDefaultSettingsIfAbsent applies initial startup flags without overwriting
// explicitly saved user settings.
func (s *Store) SeedDefaultSettingsIfAbsent(tmdbKey, tmdbAPIBase, tmdbImageBase, metadataProxy string, bangumiEnabled *bool) error {
	if strings.TrimSpace(tmdbKey) != "" && s.GetSetting("tmdb_api_key_enc", "") == "" {
		sealed, err := s.vault.Seal(strings.TrimSpace(tmdbKey))
		if err != nil {
			return err
		}
		if err := s.SetSetting("tmdb_api_key_enc", sealed); err != nil {
			return err
		}
	}
	if strings.TrimSpace(tmdbAPIBase) != "" && s.GetSetting("tmdb_api_base", "") == "" {
		_ = s.SetSetting("tmdb_api_base", NormalizeTmdbBase(tmdbAPIBase, DefaultTmdbAPIBase, "/3"))
	}
	if strings.TrimSpace(tmdbImageBase) != "" && s.GetSetting("tmdb_image_base", "") == "" {
		_ = s.SetSetting("tmdb_image_base", NormalizeTmdbBase(tmdbImageBase, DefaultTmdbImageBase, "/t/p"))
	}
	if strings.TrimSpace(metadataProxy) != "" && s.GetSetting("metadata_proxy", "") == "" {
		_ = s.SetSetting("metadata_proxy", strings.TrimSpace(metadataProxy))
	}
	if bangumiEnabled != nil {
		var existing string
		err := s.db.QueryRow(`SELECT value FROM server_settings WHERE key = 'bangumi_enabled'`).Scan(&existing)
		if err == sql.ErrNoRows {
			_ = s.SetSettingBool("bangumi_enabled", *bangumiEnabled)
		}
	}
	return nil
}

type quarkDeviceJSON struct {
	Utdid   string `json:"utdid"`
	Machine string `json:"machine"`
}

func (s *Store) AdoptQuarkPcDeviceIfAbsent(utdid, machine string) {
	utdid = strings.TrimSpace(utdid)
	machine = strings.TrimSpace(machine)
	if utdid == "" || machine == "" {
		return
	}
	raw, err := json.Marshal(quarkDeviceJSON{Utdid: utdid, Machine: machine})
	if err != nil {
		return
	}
	_, _ = s.db.Exec(`INSERT OR IGNORE INTO server_settings(key, value) VALUES ('quark_pc_device', ?)`, string(raw))
}

func (s *Store) GetOrCreateQuarkPcDevice(generate func() (string, string)) (string, string) {
	readStored := func() (string, string, bool) {
		raw := strings.TrimSpace(s.GetSetting("quark_pc_device", ""))
		if raw == "" {
			return "", "", false
		}
		var d quarkDeviceJSON
		if json.Unmarshal([]byte(raw), &d) == nil && strings.TrimSpace(d.Utdid) != "" && strings.TrimSpace(d.Machine) != "" {
			return strings.TrimSpace(d.Utdid), strings.TrimSpace(d.Machine), true
		}
		return "", "", false
	}

	if ut, mach, ok := readStored(); ok {
		return ut, mach
	}

	// Adopt an existing Quark mount's PC device identity if one already exists.
	if mounts, err := s.ListMounts(); err == nil {
		for _, m := range mounts {
			if m.Kind != "quark" {
				continue
			}
			sec := strings.TrimSpace(m.Secrets["cookie"])
			if !strings.HasPrefix(sec, "{") {
				continue
			}
			var raw map[string]any
			if json.Unmarshal([]byte(sec), &raw) == nil {
				ut, _ := raw["utdid"].(string)
				mach, _ := raw["machine"].(string)
				if strings.TrimSpace(ut) != "" && strings.TrimSpace(mach) != "" {
					s.AdoptQuarkPcDeviceIfAbsent(ut, mach)
					if storedUt, storedMach, ok := readStored(); ok {
						return storedUt, storedMach
					}
				}
			}
		}
	}

	ut, mach := generate()
	s.AdoptQuarkPcDeviceIfAbsent(ut, mach)
	if storedUt, storedMach, ok := readStored(); ok {
		return storedUt, storedMach
	}
	return ut, mach
}
