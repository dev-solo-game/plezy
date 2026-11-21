import type {
  AccountSummary,
  AdminPrincipal,
  AuditLogRecord,
  BootstrapInfo,
  CacheStats,
  IdentifyQueueStats,
  ImageCacheSummary,
  InspectTableInfo,
  InviteCode,
  MetadataProvider,
  PlatformOverview,
  ServerLogEntry,
  ServerSettings,
} from '../types';

const TOKEN_STORAGE_KEY = 'media_library_admin_token';

export function getAdminToken(): string {
  return localStorage.getItem(TOKEN_STORAGE_KEY) || '';
}

export function setAdminToken(tok: string): void {
  if (tok) {
    localStorage.setItem(TOKEN_STORAGE_KEY, tok);
  } else {
    localStorage.removeItem(TOKEN_STORAGE_KEY);
  }
}

export function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export function formatDateTime(ms?: number): string {
  if (!ms || ms <= 0) return '-';
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export class ApiError extends Error {
  status: number;
  errorCode: string;
  constructor(status: number, errorCode: string, message: string) {
    super(message);
    this.status = status;
    this.errorCode = errorCode;
  }
}

async function request<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const token = getAdminToken();
  const headers: Record<string, string> = {
    Accept: 'application/json',
    ...(opts.headers as Record<string, string> | undefined),
  };
  if (opts.body && !headers['Content-Type']) {
    headers['Content-Type'] = 'application/json';
  }
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const resp = await fetch(path, { ...opts, headers });
  const text = await resp.text();
  let json: Record<string, unknown> = {};
  try {
    json = text ? (JSON.parse(text) as Record<string, unknown>) : {};
  } catch {
    json = { message: text || `HTTP ${resp.status}` };
  }
  if (!resp.ok) {
    const code = typeof json.error === 'string' ? json.error : `http_${resp.status}`;
    const msg = typeof json.message === 'string' && json.message ? json.message : `请求失败 (${resp.status})`;
    throw new ApiError(resp.status, code, msg);
  }
  return json as T;
}

export const api = {
  bootstrap: () => request<BootstrapInfo>('/api/v1/public/bootstrap'),

  login: (username: string, password: string) =>
    request<{ access_token: string; admin: AdminPrincipal }>('/api/admin/auth/login', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),

  logout: () => request<{ code: number }>('/api/admin/auth/logout', { method: 'POST' }),

  me: () => request<{ admin: AdminPrincipal }>('/api/admin/auth/me'),

  changePassword: (old_password: string, new_password: string, new_username?: string) =>
    request<{ code: number }>('/api/admin/auth/change-password', {
      method: 'POST',
      body: JSON.stringify({ old_password, new_password, new_username: new_username || undefined }),
    }),

  overview: () =>
    request<{ overview: PlatformOverview; cache_stats?: CacheStats; identify_queue?: IdentifyQueueStats }>(
      '/api/admin/overview'
    ),

  listAccounts: (params: { q?: string; status?: string; limit?: number; offset?: number } = {}) => {
    const sp = new URLSearchParams();
    if (params.q) sp.set('q', params.q);
    if (params.status) sp.set('status', params.status);
    if (params.limit) sp.set('limit', String(params.limit));
    if (params.offset) sp.set('offset', String(params.offset));
    const qs = sp.toString();
    return request<{ accounts: AccountSummary[]; total: number }>(`/api/admin/accounts${qs ? `?${qs}` : ''}`);
  },

  createAccount: (payload: { username: string; password: string; email?: string; household_name?: string }) =>
    request<{ account: AccountSummary }>('/api/admin/accounts', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  setAccountStatus: (id: string, status: 'active' | 'disabled') =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}/status`, {
      method: 'POST',
      body: JSON.stringify({ status }),
    }),

  resetAccountPassword: (id: string, new_password: string) =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}/reset-password`, {
      method: 'POST',
      body: JSON.stringify({ new_password }),
    }),

  forceLogoutAccount: (id: string) =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}/force-logout`, {
      method: 'POST',
    }),

  scheduleDeleteAccount: (id: string) =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}`, { method: 'DELETE' }),

  restoreAccount: (id: string) =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}/restore`, { method: 'POST' }),

  updateQuotas: (id: string, payload: { max_sources?: number; max_files?: number; max_sidecar_bytes?: number }) =>
    request<{ code: number }>(`/api/admin/accounts/${encodeURIComponent(id)}/quotas`, {
      method: 'PATCH',
      body: JSON.stringify(payload),
    }),

  listInvites: () => request<{ invites: InviteCode[] }>('/api/admin/invites'),

  createInvite: (payload: { max_uses?: number; expires_at?: number; note?: string }) =>
    request<{ invite: InviteCode }>('/api/admin/invites', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  revokeInvite: (code: string) =>
    request<{ code: number }>(`/api/admin/invites/${encodeURIComponent(code)}`, { method: 'DELETE' }),

  getSettings: () => request<{ settings: ServerSettings }>('/api/admin/settings'),

  updateSettings: (patch: Record<string, unknown>) =>
    request<{ settings: ServerSettings }>('/api/admin/settings', {
      method: 'PATCH',
      body: JSON.stringify(patch),
    }),

  testTmdb: (payload: { tmdb_api_key?: string; tmdb_api_base?: string; metadata_proxy?: string }) =>
    request<{ ok: boolean; latency_ms: number }>('/api/admin/settings/test-tmdb', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  testProvider: (payload: {
    provider: MetadataProvider;
    api_key?: string;
    pin?: string;
    token?: string;
    cookie?: string;
    api_base?: string;
    metadata_proxy?: string;
  }) =>
    request<{ ok: boolean; latency_ms: number; message?: string }>('/api/admin/settings/test-provider', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  clearMetaCache: (scope = 'all') =>
    request<{ deleted: number; cache_stats: CacheStats }>('/api/admin/settings/clear-cache', {
      method: 'POST',
      body: JSON.stringify({ scope }),
    }),

  listMetadataTables: () =>
    request<{ tables: InspectTableInfo[]; image_cache: ImageCacheSummary }>('/api/admin/metadata/tables'),

  queryMetadataTable: (table: string, q = '', limit = 50, offset = 0) => {
    const sp = new URLSearchParams({ limit: String(limit), offset: String(offset) });
    if (q) sp.set('q', q);
    return request<{ table: InspectTableInfo; total: number; rows: Record<string, unknown>[] }>(
      `/api/admin/metadata/tables/${encodeURIComponent(table)}?${sp.toString()}`
    );
  },

  deleteMetadataRow: (table: string, pk: Record<string, string>) =>
    request<{ deleted: number }>(`/api/admin/metadata/tables/${encodeURIComponent(table)}/row`, {
      method: 'DELETE',
      body: JSON.stringify({ pk }),
    }),

  identifyStatus: () => request<{ status: IdentifyQueueStats }>('/api/admin/identify/status'),
  identifyPause: () => request<{ paused: boolean }>('/api/admin/identify/pause', { method: 'POST' }),
  identifyResume: () => request<{ paused: boolean }>('/api/admin/identify/resume', { method: 'POST' }),
  identifyRetryFailed: (household_id?: string) =>
    request<{ retried: number }>('/api/admin/identify/retry-failed', {
      method: 'POST',
      body: JSON.stringify({ household_id: household_id || undefined }),
    }),

  getLogs: (params: { after_seq?: number; limit?: number; level?: string; component?: string; q?: string } = {}) => {
    const sp = new URLSearchParams();
    if (params.after_seq) sp.set('after_seq', String(params.after_seq));
    if (params.limit) sp.set('limit', String(params.limit));
    if (params.level) sp.set('level', params.level);
    if (params.component) sp.set('component', params.component);
    if (params.q) sp.set('q', params.q);
    return request<{ entries: ServerLogEntry[]; latest_seq: number; log_file_path: string; file_size_bytes: number }>(
      `/api/admin/logs?${sp.toString()}`
    );
  },

  clearLogs: (truncate_file = false) =>
    request<{ ok: boolean }>('/api/admin/logs/clear', {
      method: 'POST',
      body: JSON.stringify({ truncate_file }),
    }),

  downloadLogsBlob: async () => {
    const token = getAdminToken();
    const resp = await fetch('/api/admin/logs/download', {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
    if (!resp.ok) throw new Error(`下载失败 (${resp.status})`);
    return resp.blob();
  },

  listAuditLogs: (params: { actor_type?: string; action?: string; limit?: number; offset?: number } = {}) => {
    const sp = new URLSearchParams();
    if (params.actor_type) sp.set('actor_type', params.actor_type);
    if (params.action) sp.set('action', params.action);
    if (params.limit) sp.set('limit', String(params.limit));
    if (params.offset) sp.set('offset', String(params.offset));
    return request<{ logs: AuditLogRecord[]; total: number }>(`/api/admin/audit-logs?${sp.toString()}`);
  },
};
