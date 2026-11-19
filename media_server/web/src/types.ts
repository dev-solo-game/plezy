export type ShelfKey = 'movie' | 'show' | 'anime' | 'variety' | 'documentary' | 'pending' | 'all';
export type MountKind = 'local' | 'smb' | 'webdav' | 'quark';
export type AccentTheme = 'glacier' | 'neutral' | 'ember' | 'plum';

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
  source: 'tmdb' | 'bangumi';
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
  current_path: string;
  error?: string;
}

export interface ScrapeProgressEvent {
  done: number;
  total: number;
  title: string;
  status: string;
}
