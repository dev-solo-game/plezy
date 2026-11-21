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
	DefaultServerName                 = "媒体库"
	DefaultTmdbAPIBase                = "https://api.tmdb.org/3"
	DefaultTmdbImageBase              = "https://image.tmdb.org/t/p"
	DefaultBangumiAPIBase             = "https://api.bgm.tv"
	DefaultDoubanAPIBase              = "https://m.douban.com/rexxar/api/v2"
	DefaultAniListAPIBase             = "https://graphql.anilist.co"
	DefaultImdbAPIBase                = "https://api.imdbapi.dev"
	DefaultTvdbAPIBase                = "https://api4.thetvdb.com/v4"
	DefaultScraperLang                = "zh-CN"
	DefaultWatchedThreshold           = 0.9
	DefaultAccentTheme                = "glacier"
	DefaultRegistrationMode           = RegistrationModeOpen
	DefaultSourceAddPolicyJSON        = `{"desktop":["quark","webdav","smb","emby","jellyfin"],"phone":["quark","webdav","smb","emby","jellyfin"],"tablet":["quark","webdav","smb","emby","jellyfin"],"tv":[],"web":[]}`
	DefaultFullScanAllowedDevicesJSON = `["desktop","phone","tablet"]`
	DefaultMinProtocolVersion         = 1
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

func NormalizeBaseURL(raw, fallback string) string {
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
	return text
}

func NormalizeBangumiBase(raw string) string {
	return NormalizeBaseURL(raw, DefaultBangumiAPIBase)
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

func (s *Store) settingsKV() map[string]string {
	s.settingsMu.RLock()
	kv := s.settingsCache
	s.settingsMu.RUnlock()
	if kv != nil {
		return kv
	}
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	if s.settingsCache != nil {
		return s.settingsCache
	}
	loaded := make(map[string]string)
	rows, err := s.ReadDB().Query(`SELECT key, value FROM server_settings`)
	if err != nil {
		return loaded
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		if rows.Scan(&k, &v) == nil {
			loaded[k] = v
		}
	}
	if rows.Err() != nil {
		return loaded
	}
	s.settingsCache = loaded
	return loaded
}

func (s *Store) invalidateSettingsCache() {
	s.settingsMu.Lock()
	s.settingsCache = nil
	s.settingsSnapshot = nil
	s.settingsGen++
	s.settingsMu.Unlock()
}

func (s *Store) GetSetting(key, fallback string) string {
	if raw, ok := s.settingsKV()[key]; ok {
		return raw
	}
	return fallback
}

func (s *Store) SetSetting(key, val string) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO server_settings(key, value) VALUES (?, ?)`, key, val)
	s.invalidateSettingsCache()
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

func (s *Store) getSecretSetting(encKey, legacyPlainKey string) string {
	if enc := s.GetSetting(encKey, ""); enc != "" {
		if plain, err := s.vault.Open(enc); err == nil {
			return strings.TrimSpace(plain)
		}
	}
	if legacyPlainKey != "" {
		return strings.TrimSpace(s.GetSetting(legacyPlainKey, ""))
	}
	return ""
}

func (s *Store) setSecretSetting(encKey, legacyPlainKey string, val *string, clear bool) error {
	if clear {
		if err := s.SetSetting(encKey, ""); err != nil {
			return err
		}
		if legacyPlainKey != "" {
			_ = s.SetSetting(legacyPlainKey, "")
		}
		return nil
	}
	if val == nil {
		return nil
	}
	secret := strings.TrimSpace(*val)
	if secret == "" {
		return nil
	}
	sealed, err := s.vault.Seal(secret)
	if err != nil {
		return err
	}
	if err := s.SetSetting(encKey, sealed); err != nil {
		return err
	}
	if legacyPlainKey != "" {
		_ = s.SetSetting(legacyPlainKey, "")
	}
	return nil
}

func (s *Store) GetServerSettings() ServerSettings {
	s.settingsMu.RLock()
	snap := s.settingsSnapshot
	gen := s.settingsGen
	s.settingsMu.RUnlock()
	if snap != nil {
		return *snap
	}
	cfg := s.buildServerSettings()
	s.settingsMu.Lock()
	if s.settingsGen == gen && s.settingsCache != nil {
		s.settingsSnapshot = &cfg
	}
	s.settingsMu.Unlock()
	return cfg
}

func (s *Store) buildServerSettings() ServerSettings {
	tmdbKey := s.getSecretSetting("tmdb_api_key_enc", "tmdb_api_key")
	bangumiToken := s.getSecretSetting("bangumi_token_enc", "")
	doubanCookie := s.getSecretSetting("douban_cookie_enc", "")
	tvdbKey := s.getSecretSetting("tvdb_api_key_enc", "")
	tvdbPin := s.getSecretSetting("tvdb_pin_enc", "")

	threshold := DefaultWatchedThreshold
	if raw := strings.TrimSpace(s.GetSetting("watched_threshold", "")); raw != "" {
		if f, err := strconv.ParseFloat(raw, 64); err == nil && f >= 0.5 && f <= 0.99 {
			threshold = f
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

	regMode := strings.TrimSpace(s.GetSetting("registration_mode", DefaultRegistrationMode))
	switch regMode {
	case RegistrationModeOpen, RegistrationModeInvite, RegistrationModeClosed:
	default:
		regMode = DefaultRegistrationMode
	}

	sourcePolicy := strings.TrimSpace(s.GetSetting("source_add_policy_json", DefaultSourceAddPolicyJSON))
	if sourcePolicy == "" || !json.Valid([]byte(sourcePolicy)) {
		sourcePolicy = DefaultSourceAddPolicyJSON
	}

	scanDevices := strings.TrimSpace(s.GetSetting("full_scan_allowed_devices_json", DefaultFullScanAllowedDevicesJSON))
	if scanDevices == "" || !json.Valid([]byte(scanDevices)) {
		scanDevices = DefaultFullScanAllowedDevicesJSON
	}

	minProto := DefaultMinProtocolVersion
	if raw := strings.TrimSpace(s.GetSetting("min_protocol_version", "")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 1 {
			minProto = v
		}
	}

	return ServerSettings{
		ServerName:                 name,
		TmdbAPIKeySet:              tmdbKey != "",
		TmdbAPIKeyMasked:           MaskSecret(tmdbKey),
		TmdbAPIKey:                 tmdbKey,
		TmdbAPIBase:                NormalizeTmdbBase(s.GetSetting("tmdb_api_base", DefaultTmdbAPIBase), DefaultTmdbAPIBase, "/3"),
		TmdbImageBase:              NormalizeTmdbBase(s.GetSetting("tmdb_image_base", DefaultTmdbImageBase), DefaultTmdbImageBase, "/t/p"),
		MetadataProxy:              strings.TrimSpace(s.GetSetting("metadata_proxy", "")),
		BangumiEnabled:             s.GetSettingBool("bangumi_enabled", true),
		BangumiAPIBase:             NormalizeBangumiBase(s.GetSetting("bangumi_api_base", DefaultBangumiAPIBase)),
		BangumiTokenSet:            bangumiToken != "",
		BangumiTokenMasked:         MaskSecret(bangumiToken),
		BangumiToken:               bangumiToken,
		DoubanEnabled:              s.GetSettingBool("douban_enabled", true),
		DoubanAPIBase:              NormalizeBaseURL(s.GetSetting("douban_api_base", DefaultDoubanAPIBase), DefaultDoubanAPIBase),
		DoubanCookieSet:            doubanCookie != "",
		DoubanCookieMasked:         MaskSecret(doubanCookie),
		DoubanCookie:               doubanCookie,
		AniListEnabled:             s.GetSettingBool("anilist_enabled", true),
		AniListAPIBase:             NormalizeBaseURL(s.GetSetting("anilist_api_base", DefaultAniListAPIBase), DefaultAniListAPIBase),
		ImdbEnabled:                s.GetSettingBool("imdb_enabled", true),
		ImdbAPIBase:                NormalizeBaseURL(s.GetSetting("imdb_api_base", DefaultImdbAPIBase), DefaultImdbAPIBase),
		TvdbEnabled:                s.GetSettingBool("tvdb_enabled", false),
		TvdbAPIBase:                NormalizeBaseURL(s.GetSetting("tvdb_api_base", DefaultTvdbAPIBase), DefaultTvdbAPIBase),
		TvdbAPIKeySet:              tvdbKey != "",
		TvdbAPIKeyMasked:           MaskSecret(tvdbKey),
		TvdbAPIKey:                 tvdbKey,
		TvdbPinSet:                 tvdbPin != "",
		TvdbPinMasked:              MaskSecret(tvdbPin),
		TvdbPin:                    tvdbPin,
		AllowPublicMetadata:        s.GetSettingBool("allow_public_metadata", true),
		AllowFallbackMetadata:      s.GetSettingBool("allow_fallback_metadata", true),
		CustomRecognitionWords:     s.GetSetting("custom_recognition_words", ""),
		ProxyImages:                s.GetSettingBool("proxy_images", true),
		ScraperLang:                lang,
		PreferNfo:                  s.GetSettingBool("prefer_nfo", true),
		WatchedThreshold:           threshold,
		AccentTheme:                accent,
		RegistrationMode:           regMode,
		SourceAddPolicyJSON:        sourcePolicy,
		FullScanAllowedDevicesJSON: scanDevices,
		MinProtocolVersion:         minProto,
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
	if err := s.setSecretSetting("tmdb_api_key_enc", "tmdb_api_key", req.TmdbAPIKey, req.ClearTmdbAPIKey); err != nil {
		return ServerSettings{}, err
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
	if err := s.setSecretSetting("bangumi_token_enc", "", req.BangumiToken, req.ClearBangumiToken); err != nil {
		return ServerSettings{}, err
	}
	if req.DoubanEnabled != nil {
		if err := s.SetSettingBool("douban_enabled", *req.DoubanEnabled); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.DoubanAPIBase != nil {
		if err := s.SetSetting("douban_api_base", NormalizeBaseURL(*req.DoubanAPIBase, DefaultDoubanAPIBase)); err != nil {
			return ServerSettings{}, err
		}
	}
	if err := s.setSecretSetting("douban_cookie_enc", "", req.DoubanCookie, req.ClearDoubanCookie); err != nil {
		return ServerSettings{}, err
	}
	if req.AniListEnabled != nil {
		if err := s.SetSettingBool("anilist_enabled", *req.AniListEnabled); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.AniListAPIBase != nil {
		if err := s.SetSetting("anilist_api_base", NormalizeBaseURL(*req.AniListAPIBase, DefaultAniListAPIBase)); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ImdbEnabled != nil {
		if err := s.SetSettingBool("imdb_enabled", *req.ImdbEnabled); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.ImdbAPIBase != nil {
		if err := s.SetSetting("imdb_api_base", NormalizeBaseURL(*req.ImdbAPIBase, DefaultImdbAPIBase)); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.TvdbEnabled != nil {
		if err := s.SetSettingBool("tvdb_enabled", *req.TvdbEnabled); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.TvdbAPIBase != nil {
		if err := s.SetSetting("tvdb_api_base", NormalizeBaseURL(*req.TvdbAPIBase, DefaultTvdbAPIBase)); err != nil {
			return ServerSettings{}, err
		}
	}
	if err := s.setSecretSetting("tvdb_api_key_enc", "", req.TvdbAPIKey, req.ClearTvdbAPIKey); err != nil {
		return ServerSettings{}, err
	}
	if err := s.setSecretSetting("tvdb_pin_enc", "", req.TvdbPin, req.ClearTvdbPin); err != nil {
		return ServerSettings{}, err
	}
	if req.AllowPublicMetadata != nil {
		if err := s.SetSettingBool("allow_public_metadata", *req.AllowPublicMetadata); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.AllowFallbackMetadata != nil {
		if err := s.SetSettingBool("allow_fallback_metadata", *req.AllowFallbackMetadata); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.CustomRecognitionWords != nil {
		if err := s.SetSetting("custom_recognition_words", *req.CustomRecognitionWords); err != nil {
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
	if req.RegistrationMode != nil {
		mode := strings.TrimSpace(*req.RegistrationMode)
		switch mode {
		case RegistrationModeOpen, RegistrationModeInvite, RegistrationModeClosed:
			if err := s.SetSetting("registration_mode", mode); err != nil {
				return ServerSettings{}, err
			}
		default:
			return ServerSettings{}, fmt.Errorf("%w: invalid registration_mode", ErrInvalidInput)
		}
	}
	if req.SourceAddPolicyJSON != nil {
		raw := strings.TrimSpace(*req.SourceAddPolicyJSON)
		var decoded map[string][]string
		if err := json.Unmarshal([]byte(raw), &decoded); err != nil || decoded == nil {
			return ServerSettings{}, fmt.Errorf("%w: invalid source_add_policy_json", ErrInvalidInput)
		}
		if err := s.SetSetting("source_add_policy_json", raw); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.FullScanAllowedDevicesJSON != nil {
		raw := strings.TrimSpace(*req.FullScanAllowedDevicesJSON)
		var decoded []string
		if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
			return ServerSettings{}, fmt.Errorf("%w: invalid full_scan_allowed_devices_json", ErrInvalidInput)
		}
		if err := s.SetSetting("full_scan_allowed_devices_json", raw); err != nil {
			return ServerSettings{}, err
		}
	}
	if req.MinProtocolVersion != nil {
		if *req.MinProtocolVersion < 1 {
			return ServerSettings{}, fmt.Errorf("%w: min_protocol_version must be >= 1", ErrInvalidInput)
		}
		if err := s.SetSetting("min_protocol_version", strconv.Itoa(*req.MinProtocolVersion)); err != nil {
			return ServerSettings{}, err
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

// SeedPublicMetadataIfAbsent applies the initial allow_public_metadata flag when no
// explicit row exists yet in server_settings.
func (s *Store) SeedPublicMetadataIfAbsent(allow *bool) error {
	if allow == nil {
		return nil
	}
	var existing string
	err := s.db.QueryRow(`SELECT value FROM server_settings WHERE key = 'allow_public_metadata'`).Scan(&existing)
	if err == sql.ErrNoRows {
		return s.SetSettingBool("allow_public_metadata", *allow)
	}
	return nil
}
