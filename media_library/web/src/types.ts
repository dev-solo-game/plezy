export type AccentTheme = 'glacier' | 'neutral' | 'ember' | 'plum';
export type MetadataProvider = 'tmdb' | 'bangumi' | 'douban' | 'anilist' | 'imdb' | 'tvdb';

export interface BootstrapInfo {
  server_name: string;
  accent_theme: string;
  version: string;
  protocol_version: number;
  min_protocol_version: number;
  registration_mode: string;
}

export interface AdminPrincipal {
  admin_id: string;
  username: string;
  must_change_password: boolean;
  token_id: string;
  last_login_at?: number;
  last_login_ip?: string;
  expires_at: number;
}

export interface PlatformOverview {
  accounts_total: number;
  accounts_active: number;
  accounts_today: number;
  households_total: number;
  devices_total: number;
  devices_active_7d: number;
  sources_total: number;
  sources_by_kind: Record<string, number>;
  items_total: number;
  files_total: number;
  sidecar_bytes: number;
  db_bytes: number;
}

export interface CacheStats {
  works?: number;
  seasons?: number;
  people?: number;
  searches?: number;
  search?: number;
  image_files?: number;
  image_bytes?: number;
}

export interface HouseholdQueueStats {
  household_id: string;
  queued: number;
  processing: number;
  done: number;
  failed: number;
  last_error_code?: string;
}

export interface IdentifyQueueStats {
  paused: boolean;
  workers: number;
  queued: number;
  processing: number;
  done: number;
  failed: number;
  by_household: HouseholdQueueStats[];
}

export interface AccountSummary {
  account_id: string;
  username: string;
  email?: string;
  status: string;
  must_change_password?: boolean;
  created_at: number;
  updated_at?: number;
  registered_ip?: string;
  last_active_at?: number;
  delete_after?: number;
  household_id: string;
  household_name?: string;
  member_count: number;
  device_count: number;
  source_counts?: Record<string, number>;
  item_count: number;
  file_count: number;
  sidecar_bytes: number;
  quota_max_sources: number;
  quota_max_files: number;
  quota_max_sidecar_bytes: number;
}

export interface InviteCode {
  code: string;
  max_uses: number;
  used_count: number;
  expires_at?: number;
  note?: string;
  revoked: boolean;
  created_at: number;
}

export interface AuditLogRecord {
  id: number;
  actor_type: string;
  actor_id: string;
  household_id?: string;
  action: string;
  target_type?: string;
  target_id?: string;
  detail_json?: string;
  ip?: string;
  created_at: number;
}

export interface ServerSettings {
  server_name: string;
  accent_theme: string;
  registration_mode: string;
  min_protocol_version: number;
  tmdb_api_key_set: boolean;
  tmdb_api_key_masked: string;
  tmdb_api_base: string;
  tmdb_image_base: string;
  metadata_proxy: string;
  bangumi_enabled: boolean;
  bangumi_api_base: string;
  bangumi_token_set: boolean;
  douban_enabled: boolean;
  douban_api_base: string;
  douban_cookie_set: boolean;
  anilist_enabled: boolean;
  anilist_api_base: string;
  imdb_enabled: boolean;
  imdb_api_base: string;
  tvdb_enabled: boolean;
  tvdb_api_base: string;
  tvdb_api_key_set: boolean;
  tvdb_pin_set: boolean;
  allow_public_metadata: boolean;
  allow_fallback_metadata: boolean;
  custom_recognition_words: string;
  proxy_images: boolean;
  scraper_lang: string;
  prefer_nfo: boolean;
  source_add_policy_json?: string;
}

export interface InspectTableInfo {
  name: string;
  label: string;
  group: string;
  description: string;
  row_count: number;
  columns: string[];
  pk_cols?: string[];
  deletable: boolean;
}

export interface ImageCacheSummary {
  files: number;
  bytes: number;
}

export interface ServerLogEntry {
  seq: number;
  time_ms: number;
  level: string;
  component: string;
  message: string;
}
