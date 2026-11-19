import type {
  BootstrapInfo,
  CacheStats,
  ExternalServerAuthMode,
  ExternalServerKind,
  ExternalServerRecord,
  ExternalServerTestResult,
  ExtHomePayload,
  ExtItem,
  ExtItemDetail,
  ExtPlaybackInfo,
  ExtSearchResult,
  HomePayload,
  HostDirEntry,
  ImageCacheSummary,
  InspectTableInfo,
  InspectTablePage,
  ItemDetail,
  LibraryFacets,
  MediaItem,
  MediaList,
  MetadataProvider,
  MountBrowseEntry,
  MountKind,
  MountRecord,
  Person,
  PlaybackInfo,
  ScrapeCandidate,
  ServerLogsResponse,
  ServerSettings,
  ServerSettingsUpdate,
  SessionRecord,
  SystemOverview,
  TaskStatusSnapshot,
  UnmatchedEntry,
  WorkPrefs,
} from '../types';

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    credentials: 'include',
    ...init,
    headers: {
      ...(init?.body instanceof FormData ? {} : { 'Content-Type': 'application/json' }),
      ...(init?.headers ?? {}),
    },
  });
  const text = await res.text();
  let data: Record<string, unknown> = {};
  if (text) {
    try {
      data = JSON.parse(text) as Record<string, unknown>;
    } catch {
      if (!res.ok) throw new ApiError(res.status, text);
    }
  }
  if (!res.ok) {
    const msg = typeof data.message === 'string' && data.message ? data.message : `HTTP ${res.status}`;
    throw new ApiError(res.status, msg);
  }
  return data as T;
}

export function artworkUrl(source?: string | null, size: 'w185' | 'w500' | 'w780' | 'w1280' | 'original' = 'w500'): string {
  if (!source) return '';
  if (source.startsWith('mount:')) {
    const rest = source.slice('mount:'.length);
    const sep = rest.indexOf(':');
    if (sep <= 0) return '';
    const mountId = rest.slice(0, sep);
    const p = rest.slice(sep + 1);
    return `/api/v1/artwork/local/${encodeURIComponent(mountId)}?path=${encodeURIComponent(p)}`;
  }
  return `/api/v1/artwork/remote?src=${encodeURIComponent(source)}&size=${encodeURIComponent(size)}`;
}

export function formatBytes(bytes?: number | null): string {
  if (!bytes || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v >= 10 || i === 0 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

export function formatDurationMs(ms?: number | null): string {
  if (!ms || ms <= 0) return '0:00';
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function shelfLabel(shelf?: string): string {
  switch (shelf) {
    case 'movie':
      return '电影';
    case 'show':
      return '剧集';
    case 'anime':
      return '动漫';
    case 'variety':
      return '综艺';
    case 'documentary':
      return '纪录片';
    case 'pending':
      return '待匹配';
    case 'all':
      return '全部媒体';
    default:
      return shelf || '媒体库';
  }
}

export function mountKindLabel(kind?: string): string {
  switch (kind) {
    case 'local':
      return '本地目录';
    case 'smb':
      return 'SMB 共享';
    case 'webdav':
      return 'WebDAV';
    case 'quark':
      return '夸克网盘';
    default:
      return kind || '-';
  }
}

export function extServerKindLabel(kind?: string): string {
  switch (kind) {
    case 'emby':
      return 'Emby';
    case 'jellyfin':
      return 'Jellyfin';
    default:
      return kind || '媒体服务器';
  }
}

export function providerLabel(source?: string): string {
  switch ((source || '').toLowerCase()) {
    case 'tmdb':
      return 'TMDB';
    case 'douban':
      return '豆瓣';
    case 'bangumi':
      return 'Bangumi';
    case 'anilist':
      return 'AniList';
    case 'imdb':
      return 'IMDb';
    case 'tvdb':
      return 'TheTvDb';
    default:
      return (source || '-').toUpperCase();
  }
}

export const api = {
  bootstrap: () => req<BootstrapInfo>('/api/v1/public/bootstrap'),

  setup: (body: {
    username: string;
    password: string;
    server_name: string;
    tmdb_api_key: string;
    metadata_proxy: string;
    device_name: string;
  }) => req<{ username: string; expires_at: number }>('/api/v1/auth/setup', { method: 'POST', body: JSON.stringify(body) }),

  login: (body: { username: string; password: string; device_name: string; platform: string }) =>
    req<{ username: string; expires_at: number }>('/api/v1/auth/login', { method: 'POST', body: JSON.stringify(body) }),

  logout: () => req<{ status: string }>('/api/v1/auth/logout', { method: 'POST' }),

  me: () => req<{ username: string; token_id: string }>('/api/v1/auth/me'),

  changePassword: (body: { old_password: string; new_password: string; new_username?: string }) =>
    req<{ status: string; username: string }>('/api/v1/auth/password', { method: 'POST', body: JSON.stringify(body) }),

  listSessions: () => req<{ sessions: SessionRecord[] }>('/api/v1/auth/sessions'),

  revokeSession: (tokenId: string) =>
    req<{ status: string }>(`/api/v1/auth/sessions/${encodeURIComponent(tokenId)}`, { method: 'DELETE' }),

  getSettings: () => req<{ settings: ServerSettings; cache_stats: CacheStats }>('/api/v1/settings'),

  updateSettings: (body: ServerSettingsUpdate) =>
    req<{ settings: ServerSettings; cache_stats: CacheStats }>('/api/v1/settings', {
      method: 'PUT',
      body: JSON.stringify(body),
    }),

  testTmdb: (body: { tmdb_api_key?: string; tmdb_api_base?: string; metadata_proxy?: string }) =>
    req<{ ok: boolean; latency_ms: number }>('/api/v1/settings/test-tmdb', {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  testProvider: (body: {
    provider: MetadataProvider;
    api_key?: string;
    pin?: string;
    token?: string;
    cookie?: string;
    api_base?: string;
    metadata_proxy?: string;
  }) =>
    req<{ ok: boolean; latency_ms: number; message?: string }>('/api/v1/settings/test-provider', {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  clearMetaCache: (scope: 'all' | 'works' | 'seasons' | 'people' | 'search') =>
    req<{ deleted: number; cache_stats: CacheStats }>('/api/v1/settings/clear-cache', {
      method: 'POST',
      body: JSON.stringify({ scope }),
    }),

  listMetadataTables: () =>
    req<{ tables: InspectTableInfo[]; image_cache: ImageCacheSummary }>('/api/v1/metadata/tables'),

  queryMetadataTable: (table: string, q = '', limit = 30, offset = 0) => {
    const p = new URLSearchParams({ limit: String(limit), offset: String(offset) });
    if (q.trim()) p.set('q', q.trim());
    return req<InspectTablePage>(`/api/v1/metadata/tables/${encodeURIComponent(table)}?${p.toString()}`);
  },

  deleteMetadataCacheRow: (table: string, pk: Record<string, string>) =>
    req<{ deleted: number }>(`/api/v1/metadata/tables/${encodeURIComponent(table)}/row`, {
      method: 'DELETE',
      body: JSON.stringify({ pk }),
    }),

  systemOverview: () => req<{ overview: SystemOverview; cache_stats: CacheStats }>('/api/v1/system/overview'),

  listMounts: () => req<{ mounts: MountRecord[] }>('/api/v1/mounts'),

  createMount: (body: {
    name: string;
    kind: MountKind;
    config: Record<string, unknown>;
    secrets?: Record<string, string>;
    enabled?: boolean;
    auto_scan?: boolean;
  }) => req<{ mount: MountRecord }>('/api/v1/mounts', { method: 'POST', body: JSON.stringify(body) }),

  updateMount: (
    id: string,
    body: {
      name?: string;
      config?: Record<string, unknown>;
      secrets?: Record<string, string>;
      enabled?: boolean;
    }
  ) => req<{ mount: MountRecord }>(`/api/v1/mounts/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(body) }),

  deleteMount: (id: string) =>
    req<{ status: string }>(`/api/v1/mounts/${encodeURIComponent(id)}`, { method: 'DELETE' }),

  testMount: (body: { id?: string; kind: MountKind; config: Record<string, unknown>; secrets?: Record<string, string> }) =>
    req<{ ok: boolean }>('/api/v1/mounts/test', { method: 'POST', body: JSON.stringify(body) }),

  quarkAccount: (id: string) =>
    req<{ account: { member_type: string; used_bytes: number; total_bytes: number } }>(
      `/api/v1/mounts/${encodeURIComponent(id)}/quark-account`
    ),

  quarkAccountPreview: (body: { id?: string; mode?: string; secret?: string }) =>
    req<{ account: { nickname?: string; member_type: string; used_bytes: number; total_bytes: number } }>(
      '/api/v1/quark/account-preview',
      { method: 'POST', body: JSON.stringify(body) }
    ),

  browseHostFS: (path?: string) =>
    req<{ current: string; parent: string; dirs: HostDirEntry[] }>(
      `/api/v1/fs/browse${path ? `?path=${encodeURIComponent(path)}` : ''}`
    ),

  browseMountPreview: (body: {
    id?: string;
    kind: MountKind;
    config: Record<string, unknown>;
    secrets?: Record<string, string>;
    path?: string;
    parent_id?: string;
  }) =>
    req<{
      path: string;
      parent: string;
      dirs: Array<{ path: string; name: string; is_dir: boolean; id?: string }>;
      file_count: number;
    }>('/api/v1/mounts/browse-preview', { method: 'POST', body: JSON.stringify(body) }),

  browseMount: (mountId: string, path?: string) =>
    req<{
      mount_id: string;
      mount_name: string;
      path: string;
      parent: string;
      entries: MountBrowseEntry[];
    }>(`/api/v1/mounts/${encodeURIComponent(mountId)}/browse${path ? `?path=${encodeURIComponent(path)}` : ''}`),

  quarkQrStart: (mode: 'pc' | 'web') =>
    req<{ session_id: string; mode: string; qr_content: string; expires_at: number }>('/api/v1/quark/qr/start', {
      method: 'POST',
      body: JSON.stringify({ mode }),
    }),

  quarkQrPoll: (sessionId: string) =>
    req<{ status: 'waiting' | 'expired' | 'confirmed'; secret?: string; message?: string }>(
      `/api/v1/quark/qr/poll?session_id=${encodeURIComponent(sessionId)}`
    ),

  scanAll: (full = false) =>
    req<{ status: string }>(`/api/v1/tasks/scan-all?full=${full ? '1' : '0'}`, { method: 'POST' }),

  scanMount: (id: string, full = false) =>
    req<{ status: string }>(`/api/v1/mounts/${encodeURIComponent(id)}/scan?full=${full ? '1' : '0'}`, { method: 'POST' }),

  cancelScan: (id: string) =>
    req<{ status: string }>(`/api/v1/mounts/${encodeURIComponent(id)}/cancel-scan`, { method: 'POST' }),

  scrapeAll: (retryUnmatched = false, refreshAll = false) =>
    req<{ status: string }>(
      `/api/v1/tasks/scrape?retry_unmatched=${retryUnmatched ? '1' : '0'}&refresh_all=${refreshAll ? '1' : '0'}`,
      { method: 'POST' }
    ),

  getTaskStatus: () => req<{ status: TaskStatusSnapshot }>('/api/v1/tasks/status'),

  listUnmatched: (limit = 50, offset = 0) =>
    req<{ items: UnmatchedEntry[]; total: number }>(`/api/v1/library/unmatched?limit=${limit}&offset=${offset}`),

  scrapeSearch: (q: string, kind: 'movie' | 'show', provider: '' | MetadataProvider, year?: number, refresh = true) => {
    const p = new URLSearchParams({ q, kind });
    if (provider) p.set('provider', provider);
    if (year) p.set('year', String(year));
    if (refresh) p.set('refresh', '1');
    return req<{ results: ScrapeCandidate[] }>(`/api/v1/scrape/search?${p.toString()}`);
  },

  manualMatch: (
    itemId: number,
    body: { provider: MetadataProvider | string; external_id: string; as_show: boolean; library_type?: string }
  ) => req<{ item: MediaItem }>(`/api/v1/items/${itemId}/match`, { method: 'POST', body: JSON.stringify(body) }),

  unmatchItem: (itemId: number) => req<{ status: string }>(`/api/v1/items/${itemId}/unmatch`, { method: 'POST' }),

  updateMetadata: (
    itemId: number,
    body: {
      title?: string;
      original_title?: string;
      year?: number | null;
      library_type?: string;
      summary?: string;
      tagline?: string;
      studio?: string;
      rating?: number | null;
      poster_source?: string;
      backdrop_source?: string;
      locked?: boolean;
    }
  ) => req<{ item: MediaItem }>(`/api/v1/items/${itemId}/metadata`, { method: 'PUT', body: JSON.stringify(body) }),

  refreshItem: (itemId: number) => req<{ item: MediaItem }>(`/api/v1/items/${itemId}/refresh`, { method: 'POST' }),

  getHome: () => req<{ home: HomePayload }>('/api/v1/home'),

  getLibraryItems: (params: Record<string, string | number | boolean | undefined>) => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== '' && v !== null) p.set(k, String(v));
    }
    return req<{ items: MediaItem[]; total: number; offset: number; limit: number }>(`/api/v1/library/items?${p.toString()}`);
  },

  getLibraryFacets: (shelf = '') =>
    req<{ facets: LibraryFacets }>(`/api/v1/library/facets${shelf ? `?shelf=${encodeURIComponent(shelf)}` : ''}`),

  getItemDetail: (id: number) => req<{ detail: ItemDetail }>(`/api/v1/items/${id}`),

  search: (q: string, limit = 24) =>
    req<{
      results: {
        movies: MediaItem[];
        shows: MediaItem[];
        episodes: MediaItem[];
        people: Person[];
      };
    }>(`/api/v1/search?q=${encodeURIComponent(q)}&limit=${limit}`),

  getPerson: (id: number) => req<{ detail: { person: Person; items: MediaItem[] } }>(`/api/v1/people/${id}`),

  setFavorite: (itemId: number, favorite: boolean) =>
    req<{ status: string }>(`/api/v1/items/${itemId}/favorite`, { method: 'POST', body: JSON.stringify({ favorite }) }),

  setWatched: (itemId: number, watched: boolean) =>
    req<{ status: string }>(`/api/v1/items/${itemId}/watched`, { method: 'POST', body: JSON.stringify({ watched }) }),

  hideContinue: (itemId: number) => req<{ status: string }>(`/api/v1/items/${itemId}/hide-continue`, { method: 'POST' }),

  reportProgress: (body: { item_id: number; file_id?: number; position_ms: number; duration_ms?: number }, keepalive = false) =>
    fetch('/api/v1/playback/progress', {
      method: 'POST',
      credentials: 'include',
      keepalive,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(async (r) => {
      if (!r.ok) throw new ApiError(r.status, 'failed to save progress');
      return r.json();
    }),

  saveWorkPrefs: (body: WorkPrefs) =>
    req<{ work_prefs: WorkPrefs }>('/api/v1/work-prefs', { method: 'PUT', body: JSON.stringify(body) }),

  listLists: (kind?: 'collection' | 'playlist') =>
    req<{ lists: MediaList[] }>(`/api/v1/lists${kind ? `?kind=${kind}` : ''}`),

  createList: (body: { kind: 'collection' | 'playlist'; title: string; summary?: string; poster_source?: string; item_ids?: number[] }) =>
    req<{ list: MediaList }>('/api/v1/lists', { method: 'POST', body: JSON.stringify(body) }),

  getList: (id: number) => req<{ list: MediaList }>(`/api/v1/lists/${id}`),

  updateList: (id: number, body: { title: string; summary?: string; poster_source?: string }) =>
    req<{ list: MediaList }>(`/api/v1/lists/${id}`, { method: 'PUT', body: JSON.stringify(body) }),

  deleteList: (id: number) => req<{ status: string }>(`/api/v1/lists/${id}`, { method: 'DELETE' }),

  addListItems: (id: number, itemIds: number[]) =>
    req<{ status: string }>(`/api/v1/lists/${id}/items`, { method: 'POST', body: JSON.stringify({ item_ids: itemIds }) }),

  removeListItem: (id: number, itemId: number) =>
    req<{ status: string }>(`/api/v1/lists/${id}/items/${itemId}`, { method: 'DELETE' }),

  reorderList: (id: number, itemIds: number[]) =>
    req<{ status: string }>(`/api/v1/lists/${id}/reorder`, { method: 'PUT', body: JSON.stringify({ item_ids: itemIds }) }),

  getPlaybackInfoItem: (itemId: number, fileId?: number) =>
    req<PlaybackInfo>(
      `/api/v1/playback/info/${itemId}${fileId ? `?file_id=${encodeURIComponent(String(fileId))}` : ''}`
    ),

  getPlaybackInfoFile: (fileId: number) => req<PlaybackInfo>(`/api/v1/playback/file/${fileId}`),

  // External Emby / Jellyfin servers
  listExternalServers: () => req<{ servers: ExternalServerRecord[] }>('/api/v1/ext-servers'),

  testExternalServer: (body: {
    id?: string;
    kind: ExternalServerKind;
    base_url: string;
    auth_mode: ExternalServerAuthMode;
    username?: string;
    password?: string;
    api_key?: string;
    user_id?: string;
    allow_insecure_tls?: boolean;
  }) => req<ExternalServerTestResult>('/api/v1/ext-servers/test', { method: 'POST', body: JSON.stringify(body) }),

  createExternalServer: (body: {
    name?: string;
    kind: ExternalServerKind;
    base_url: string;
    auth_mode: ExternalServerAuthMode;
    username?: string;
    password?: string;
    api_key?: string;
    user_id?: string;
    allow_insecure_tls?: boolean;
    enabled?: boolean;
  }) => req<{ server: ExternalServerRecord }>('/api/v1/ext-servers', { method: 'POST', body: JSON.stringify(body) }),

  updateExternalServer: (
    id: string,
    body: {
      name?: string;
      kind?: ExternalServerKind;
      base_url?: string;
      auth_mode?: ExternalServerAuthMode;
      username?: string;
      password?: string;
      api_key?: string;
      user_id?: string;
      allow_insecure_tls?: boolean;
      enabled?: boolean;
    }
  ) =>
    req<{ server: ExternalServerRecord }>(`/api/v1/ext-servers/${encodeURIComponent(id)}`, {
      method: 'PUT',
      body: JSON.stringify(body),
    }),

  deleteExternalServer: (id: string) =>
    req<{ status: string }>(`/api/v1/ext-servers/${encodeURIComponent(id)}`, { method: 'DELETE' }),

  extGetHome: (serverId: string) =>
    req<{ server: ExternalServerRecord; home: ExtHomePayload }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/home`
    ),

  extGetItems: (serverId: string, params: Record<string, string | number | boolean | undefined>) => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== '' && v !== null) p.set(k, String(v));
    }
    return req<{ server: ExternalServerRecord; items: ExtItem[]; total: number; offset: number; limit: number }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/items?${p.toString()}`
    );
  },

  extGetItemDetail: (serverId: string, itemId: string) =>
    req<{ server: ExternalServerRecord; detail: ExtItemDetail }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/items/${encodeURIComponent(itemId)}`
    ),

  extSearch: (serverId: string, q: string) =>
    req<{ server: ExternalServerRecord; results: ExtSearchResult }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/search?q=${encodeURIComponent(q)}`
    ),

  extSetFavorite: (serverId: string, itemId: string, favorite: boolean) =>
    req<{ favorite: boolean }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/items/${encodeURIComponent(itemId)}/favorite`,
      { method: 'POST', body: JSON.stringify({ favorite }) }
    ),

  extSetWatched: (serverId: string, itemId: string, watched: boolean) =>
    req<{ watched: boolean }>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/items/${encodeURIComponent(itemId)}/watched`,
      { method: 'POST', body: JSON.stringify({ watched }) }
    ),

  extReportPlayback: (
    serverId: string,
    body: {
      state: 'start' | 'progress' | 'stop';
      item_id: string;
      media_source_id?: string;
      play_session_id?: string;
      position_ms: number;
      is_paused: boolean;
      play_method?: string;
    },
    keepalive = false
  ) =>
    fetch(`/api/v1/ext/${encodeURIComponent(serverId)}/playback/report`, {
      method: 'POST',
      credentials: 'include',
      keepalive,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(async (r) => {
      if (!r.ok) throw new ApiError(r.status, 'failed to report external playback');
      return r.json();
    }),

  extGetPlaybackInfo: (serverId: string, itemId: string, sourceId?: string) =>
    req<ExtPlaybackInfo>(
      `/api/v1/ext/${encodeURIComponent(serverId)}/playback/${encodeURIComponent(itemId)}${
        sourceId ? `?source_id=${encodeURIComponent(sourceId)}` : ''
      }`
    ),

  getSystemLogs: (params?: {
    after_seq?: number;
    limit?: number;
    level?: string;
    component?: string;
    q?: string;
  }) => {
    const p = new URLSearchParams();
    if (params?.after_seq) p.set('after_seq', String(params.after_seq));
    if (params?.limit) p.set('limit', String(params.limit));
    if (params?.level) p.set('level', params.level);
    if (params?.component) p.set('component', params.component);
    if (params?.q) p.set('q', params.q);
    const qs = p.toString();
    return req<ServerLogsResponse>(`/api/v1/system/logs${qs ? `?${qs}` : ''}`);
  },

  clearSystemLogs: (truncateFile = false) =>
    req<{ ok: boolean }>('/api/v1/system/logs/clear', {
      method: 'POST',
      body: JSON.stringify({ truncate_file: truncateFile }),
    }),

  systemLogsDownloadUrl: () => '/api/v1/system/logs/download',
};
