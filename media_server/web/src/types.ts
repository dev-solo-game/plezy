export type ShelfKey = 'movie' | 'show' | 'anime' | 'variety' | 'documentary' | 'pending' | 'all';
export type MountKind = 'local' | 'smb' | 'webdav' | 'quark';
export type AccentTheme = 'glacier' | 'neutral' | 'ember' | 'plum';
export type MetadataProvider = 'tmdb' | 'douban' | 'bangumi' | 'anilist' | 'imdb' | 'tvdb';

export interface BootstrapInfo {
  initialized: boolean;
  server_name: string;
  accent_theme: AccentTheme;
  version: string;
}

export interface SessionRecord {
  token_id: string;
  device_name: string;
  platform: string;
  ip: string;
  created_at: number;
  last_used_at: number;
  expires_at: number;
  current?: boolean;
}

export interface CacheStats {
  works: number;
  seasons: number;
  people: number;
  searches: number;
}

export interface ServerSettings {
  server_name: string;
  tmdb_api_key_set: boolean;
  tmdb_api_key_masked: string;
  tmdb_api_base: string;
  tmdb_image_base: string;
  metadata_proxy: string;
  bangumi_enabled: boolean;
  bangumi_api_base: string;
  bangumi_token_set: boolean;
  bangumi_token_masked: string;
  douban_enabled: boolean;
  douban_api_base: string;
  douban_cookie_set: boolean;
  douban_cookie_masked: string;
  anilist_enabled: boolean;
  anilist_api_base: string;
  imdb_enabled: boolean;
  imdb_api_base: string;
  tvdb_enabled: boolean;
  tvdb_api_base: string;
  tvdb_api_key_set: boolean;
  tvdb_api_key_masked: string;
  tvdb_pin_set: boolean;
  tvdb_pin_masked: string;
  allow_fallback_metadata: boolean;
  custom_recognition_words: string;
  proxy_images: boolean;
  scraper_lang: string;
  prefer_nfo: boolean;
  watched_threshold: number;
  scan_interval_min: number;
  watch_local_fs: boolean;
  web_prefer_cloud_transcode: boolean;
  accent_theme: AccentTheme;
}

export interface ServerSettingsUpdate {
  server_name?: string;
  tmdb_api_key?: string;
  clear_tmdb_api_key?: boolean;
  tmdb_api_base?: string;
  tmdb_image_base?: string;
  metadata_proxy?: string;
  bangumi_enabled?: boolean;
  bangumi_api_base?: string;
  bangumi_token?: string;
  clear_bangumi_token?: boolean;
  douban_enabled?: boolean;
  douban_api_base?: string;
  douban_cookie?: string;
  clear_douban_cookie?: boolean;
  anilist_enabled?: boolean;
  anilist_api_base?: string;
  imdb_enabled?: boolean;
  imdb_api_base?: string;
  tvdb_enabled?: boolean;
  tvdb_api_base?: string;
  tvdb_api_key?: string;
  clear_tvdb_api_key?: boolean;
  tvdb_pin?: string;
  clear_tvdb_pin?: boolean;
  allow_fallback_metadata?: boolean;
  custom_recognition_words?: string;
  proxy_images?: boolean;
  scraper_lang?: string;
  prefer_nfo?: boolean;
  watched_threshold?: number;
  scan_interval_min?: number;
  watch_local_fs?: boolean;
  web_prefer_cloud_transcode?: boolean;
  accent_theme?: AccentTheme;
}

export interface SystemOverview {
  movies: number;
  shows: number;
  episodes: number;
  files: number;
  collections: number;
  playlists: number;
  unmatched: number;
  mounts: number;
  people: number;
  genres: number;
  db_bytes: number;
}

export interface MountScanState {
  mount_id: string;
  scan_id: number;
  status: string;
  quark_checkpoint?: string;
  started_at?: number;
  finished_at?: number;
  last_error?: string;
}

export interface MountRecord {
  id: string;
  name: string;
  kind: MountKind;
  config: Record<string, unknown>;
  has_secret: boolean;
  enabled: boolean;
  created_at: number;
  updated_at: number;
  scan_state?: MountScanState;
  video_count: number;
  total_file_bytes: number;
  matched_item_count: number;
}

export interface HostDirEntry {
  name: string;
  path: string;
}

export interface MountBrowseEntry {
  path: string;
  name: string;
  is_dir: boolean;
  size: number;
  modified_at_ms: number;
  id: string;
  file_id?: number;
  item_id?: number;
  title?: string;
  poster_source?: string;
  library_type?: string;
  is_video?: boolean;
}

export interface WatchState {
  item_id: number;
  work_key?: string;
  last_file_id?: number;
  position_ms: number;
  duration_ms?: number;
  watched: boolean;
  play_count: number;
  last_played_at?: number;
  favorite: boolean;
  hidden_from_continue: boolean;
  updated_at: number;
}

export interface WorkPrefs {
  work_key: string;
  intro_enabled: boolean;
  intro_start_ms: number;
  intro_end_ms: number;
  credits_enabled: boolean;
  credits_from_end_ms: number;
  keep_easter_egg_ms: number;
  preferred_audio_lang?: string;
  preferred_sub_lang?: string;
  playback_speed: number;
  updated_at?: number;
}

export interface ProbedStream {
  kind: 'video' | 'audio' | 'subtitle';
  index: number;
  codec?: string;
  language?: string;
  title?: string;
  default?: boolean;
  forced?: boolean;
  width?: number;
  height?: number;
  frame_rate?: number;
  hdr?: string;
  channels?: number;
  sample_rate?: number;
  bit_depth?: number;
}

export interface MediaFile {
  id: number;
  mount_id: string;
  mount_name?: string;
  mount_kind?: string;
  path: string;
  file_name?: string;
  remote_id?: string;
  role: string;
  item_id?: number;
  owner_file_id?: number;
  size?: number;
  modified_at?: number;
  match_state: string;
  match_locked: boolean;
  version_label?: string;
  language?: string;
  duration_ms?: number;
  bitrate_kbps?: number;
  container?: string;
  video_codec?: string;
  width?: number;
  height?: number;
  hdr_format?: string;
  streams?: ProbedStream[];
}

export interface MediaItem {
  id: number;
  work_key?: string;
  kind: 'movie' | 'show' | 'season' | 'episode';
  library_type: string;
  parent_id?: number;
  show_id?: number;
  title: string;
  sort_title: string;
  original_title?: string;
  aliases?: string;
  year?: number;
  release_date?: string;
  summary?: string;
  tagline?: string;
  content_rating?: string;
  studio?: string;
  rating?: number;
  runtime_ms?: number;
  season_number?: number;
  episode_number?: number;
  absolute_number?: number;
  poster_source?: string;
  backdrop_source?: string;
  logo_source?: string;
  tmdb_id?: string;
  imdb_id?: string;
  tvdb_id?: string;
  bangumi_id?: string;
  douban_id?: string;
  anilist_id?: string;
  metadata_source?: string;
  locked: boolean;
  added_at: number;
  updated_at: number;
  scraped_at?: number;
  watch_state?: WatchState;
  show_title?: string;
  show_poster?: string;
  show_backdrop?: string;
  episode_count?: number;
  watched_episode_count?: number;
  quality_badge?: string;
  hdr_badge?: string;
  source_kinds?: MountKind[];
}

export interface Genre {
  id: number;
  name: string;
  count?: number;
}

export interface Person {
  id: number;
  name: string;
  provider?: string;
  external_id?: string;
  photo_source?: string;
  biography?: string;
  birthday?: string;
  department?: string;
  place_of_birth?: string;
}

export interface Credit {
  person: Person;
  job: 'actor' | 'director' | 'writer';
  character?: string;
  sort_order: number;
}

export interface MediaList {
  id: number;
  kind: 'collection' | 'playlist';
  title: string;
  summary?: string;
  poster_source?: string;
  tmdb_id?: string;
  item_count: number;
  items?: MediaItem[];
  created_at: number;
  updated_at: number;
}

export interface ItemDetail {
  item: MediaItem;
  parent?: MediaItem;
  show?: MediaItem;
  files: MediaFile[];
  subtitles: MediaFile[];
  seasons?: MediaItem[];
  episodes?: MediaItem[];
  genres: Genre[];
  credits: Credit[];
  collections?: MediaList[];
  similar?: MediaItem[];
  on_deck_episode?: MediaItem;
  work_prefs?: WorkPrefs;
  next_episode?: MediaItem;
  prev_episode?: MediaItem;
}

export interface HomeShelf {
  key: string;
  title: string;
  items: MediaItem[];
}

export interface HomePayload {
  hero: MediaItem[];
  continue_watching: MediaItem[];
  recent_all: MediaItem[];
  shelves: HomeShelf[];
  counts: Record<string, number>;
  unmatched_count: number;
  mount_count: number;
}

export interface LibraryFacets {
  genres: Genre[];
  years: number[];
  mounts: Array<{ id: string; name: string; kind: MountKind }>;
  letters: string[];
}

export interface UnmatchedEntry {
  item: MediaItem;
  sample_file: MediaFile;
  file_count: number;
  guessed_kind: string;
  guessed_year?: number;
}

export interface ScrapeCandidate {
  source: MetadataProvider | string;
  id: string;
  title: string;
  original_title?: string;
  year?: number;
  summary?: string;
  poster_path?: string;
}

export interface PlaybackVariant {
  id: string;
  label: string;
  width?: number;
  height?: number;
  is_hls: boolean;
  stream_url: string;
}

export interface PlaybackVersion {
  file: MediaFile;
  stream_url: string;
  stream_token: string;
  browser_compatible: boolean;
  compat_warning?: string;
  variants?: PlaybackVariant[];
}

export interface PlaybackSubtitle {
  id: number;
  file_name: string;
  language?: string;
  ext: string;
  vtt_url: string;
  raw_url: string;
}

export interface PlaybackInfo {
  item?: MediaItem;
  show?: MediaItem;
  selected_file_id: number;
  resume_position_ms: number;
  work_prefs?: WorkPrefs;
  next_episode?: MediaItem;
  prev_episode?: MediaItem;
  versions: PlaybackVersion[];
  subtitles: PlaybackSubtitle[];
  web_prefer_cloud_transcode: boolean;
  external_players: Record<string, string>;
}

export interface ScanProgressEvent {
  mount_id: string;
  mount_name: string;
  status: string;
  directories_done: number;
  files_seen: number;
  videos_found?: number;
  current_path: string;
  error?: string;
  updated_at?: number;
}

export interface ScrapeProgressEvent {
  status: string;
  done: number;
  total: number;
  matched?: number;
  unmatched?: number;
  merged?: number;
  skipped?: number;
  title?: string;
  message?: string;
  updated_at?: number;
}

export interface TaskStatusSnapshot {
  scans: ScanProgressEvent[];
  scrape: ScrapeProgressEvent;
  pending_scrape: number;
  unmatched_count: number;
}

export interface InspectTableInfo {
  name: string;
  label: string;
  group: 'cache' | 'library';
  description: string;
  row_count: number;
  columns: string[];
  json_cols?: string[];
  time_cols?: string[];
  pk_cols?: string[];
  clear_scope?: 'works' | 'seasons' | 'people' | 'search';
  deletable: boolean;
}

export interface ImageCacheSummary {
  files: number;
  bytes: number;
}

export interface InspectTablePage {
  table: InspectTableInfo;
  total: number;
  offset: number;
  limit: number;
  rows: Array<Record<string, unknown>>;
}

export type ExternalServerKind = 'emby' | 'jellyfin';
export type ExternalServerAuthMode = 'password' | 'apikey';

export interface ExternalServerRecord {
  id: string;
  name: string;
  kind: ExternalServerKind;
  base_url: string;
  auth_mode: ExternalServerAuthMode;
  username: string;
  user_id: string;
  device_id: string;
  server_id: string;
  server_version: string;
  allow_insecure_tls: boolean;
  has_token: boolean;
  enabled: boolean;
  created_at: number;
  updated_at: number;
}

export interface ExternalServerTestResult {
  ok: boolean;
  server_name: string;
  server_id: string;
  version: string;
  product_name?: string;
  detected_kind?: string;
  effective_base_url: string;
  user_id: string;
  username: string;
  latency_ms: number;
}

export interface ExtView {
  id: string;
  name: string;
  collection_type?: string;
  image_url?: string;
}

export interface ExtItem {
  id: string;
  kind: 'movie' | 'show' | 'season' | 'episode' | 'boxset' | 'playlist' | 'video';
  raw_type?: string;
  title: string;
  original_title?: string;
  year?: number;
  premiere_date?: string;
  overview?: string;
  rating?: number;
  official_rating?: string;
  runtime_ms?: number;
  season_number?: number;
  episode_number?: number;
  series_id?: string;
  series_name?: string;
  season_id?: string;
  poster_url?: string;
  backdrop_url?: string;
  thumb_url?: string;
  watched: boolean;
  favorite: boolean;
  position_ms?: number;
  unplayed_count?: number;
  child_count?: number;
  quality_badge?: string;
  hdr_badge?: string;
  genres?: string[];
  tagline?: string;
  studios?: string[];
}

export interface ExtMediaStream {
  index: number;
  type: string; // Video | Audio | Subtitle
  codec?: string;
  language?: string;
  display_title?: string;
  title?: string;
  is_default?: boolean;
  is_forced?: boolean;
  is_external?: boolean;
  is_text_subtitle?: boolean;
  delivery_url?: string;
  width?: number;
  height?: number;
  video_range?: string;
  channels?: number;
  bit_rate?: number;
}

export interface ExtMediaSource {
  id: string;
  name?: string;
  container?: string;
  path?: string;
  size?: number;
  bitrate?: number;
  runtime_ms?: number;
  supports_direct_play: boolean;
  supports_direct_stream: boolean;
  supports_transcoding: boolean;
  transcoding_url?: string;
  direct_stream_url?: string;
  video_codec?: string;
  width?: number;
  height?: number;
  hdr_format?: string;
  browser_compatible: boolean;
  compat_warning?: string;
  streams?: ExtMediaStream[];
}

export interface ExtPerson {
  id?: string;
  name: string;
  role?: string;
  type?: string;
  photo_url?: string;
}

export interface ExtItemDetail {
  item: ExtItem;
  show?: ExtItem;
  seasons?: ExtItem[];
  episodes?: ExtItem[];
  on_deck_episode?: ExtItem;
  children?: ExtItem[];
  media_sources?: ExtMediaSource[];
  people?: ExtPerson[];
  similar?: ExtItem[];
}

export interface ExtLatestGroup {
  view: ExtView;
  items: ExtItem[];
}

export interface ExtHomePayload {
  views: ExtView[];
  resume: ExtItem[];
  latest_by_view: ExtLatestGroup[];
}

export interface ExtSearchResult {
  movies: ExtItem[];
  shows: ExtItem[];
  episodes: ExtItem[];
  collections: ExtItem[];
}

export interface ExtPlaybackVersion {
  source_id: string;
  label: string;
  container?: string;
  video_codec?: string;
  width?: number;
  height?: number;
  hdr_format?: string;
  size?: number;
  bitrate?: number;
  browser_compatible: boolean;
  compat_warning?: string;
  stream_url: string;
  stream_token: string;
  variants: PlaybackVariant[];
  streams?: ExtMediaStream[];
}

export interface ExtPlaybackSubtitle {
  index: number;
  file_name: string;
  language?: string;
  ext: string;
  vtt_url: string;
}

export interface ExtPlaybackInfo {
  server: ExternalServerRecord;
  item: ExtItem;
  show?: ExtItem;
  episodes?: ExtItem[];
  prev_episode?: ExtItem;
  next_episode?: ExtItem;
  play_session_id?: string;
  selected_source_id: string;
  resume_position_ms: number;
  versions: ExtPlaybackVersion[];
  subtitles: ExtPlaybackSubtitle[];
  external_players: Record<string, string>;
}

export interface ServerLogEntry {
  seq: number;
  time_ms: number;
  level: 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | string;
  component: string;
  message: string;
}

export interface ServerLogsResponse {
  entries: ServerLogEntry[];
  latest_seq: number;
  log_file_path: string;
  file_size_bytes: number;
}
