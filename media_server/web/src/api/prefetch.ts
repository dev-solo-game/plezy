import { api } from './client';
import { prefetchQuery } from './queryCache';
import type { ExternalServerRecord, ItemDetail, MountRecord, ServerSettings, SessionRecord, SystemOverview, UnmatchedEntry } from '../types';

export interface LibraryBrowseParams {
  shelf?: string;
  favorite?: string;
  mount_id?: string;
  genre_id?: string;
  year?: string;
  quality?: string;
  watched?: string;
  letter?: string;
  sort?: string;
  order?: string;
  offset?: number;
  limit?: number;
}

export function libraryQueryKey(params: LibraryBrowseParams): string {
  const ordered: Record<string, unknown> = {};
  for (const k of Object.keys(params).sort()) {
    const val = params[k as keyof LibraryBrowseParams];
    if (val !== undefined && val !== '' && val !== null) {
      ordered[k] = val;
    }
  }
  return `lib:${JSON.stringify(ordered)}`;
}

export function prefetchHome(): void {
  prefetchQuery('home', () => api.getHome().then((r) => r.home), 15000);
}

export function prefetchShelf(shelf: string, favoritesOnly = false): void {
  const shelfFilter = favoritesOnly || shelf === 'all' ? '' : shelf;
  const key = libraryQueryKey({
    shelf: shelfFilter,
    favorite: favoritesOnly ? '1' : undefined,
    sort: 'added_at',
    order: 'desc',
    offset: 0,
    limit: 48,
  });
  prefetchQuery(
    key,
    () =>
      api.getLibraryItems({
        shelf: shelfFilter,
        favorite: favoritesOnly ? '1' : undefined,
        sort: 'added_at',
        order: 'desc',
        offset: 0,
        limit: 48,
      }),
    15000
  );
  prefetchQuery(`facets:${shelfFilter}`, () => api.getLibraryFacets(shelfFilter).then((r) => r.facets), 30000);
}

export function prefetchItemDetail(itemId: number): void {
  if (!itemId) return;
  prefetchQuery<ItemDetail>(`item:${itemId}`, () => api.getItemDetail(itemId).then((r) => r.detail), 15000);
}

export function prefetchMounts(): void {
  prefetchQuery<MountRecord[]>('mounts', () => api.listMounts().then((r) => r.mounts || []), 12000);
}

export function prefetchUnmatched(): void {
  prefetchQuery<{ items: UnmatchedEntry[]; total: number }>(
    'unmatched',
    () => api.listUnmatched(100, 0),
    12000
  );
}

export function prefetchLists(kind: 'all' | 'collection' | 'playlist' = 'all'): void {
  prefetchQuery(
    `lists:${kind}`,
    () => api.listLists(kind === 'all' ? undefined : kind).then((r) => r.lists || []),
    15000
  );
}

export interface SettingsBundle {
  settings: ServerSettings;
  cache_stats: { works: number; seasons: number; people: number; searches: number };
  overview: SystemOverview;
  sessions: SessionRecord[];
}

export function prefetchSettings(): void {
  prefetchQuery<SettingsBundle>(
    'settings:bundle',
    async () => {
      const [sRes, oRes, sesRes] = await Promise.all([
        api.getSettings(),
        api.systemOverview(),
        api.listSessions(),
      ]);
      return {
        settings: sRes.settings,
        cache_stats: sRes.cache_stats,
        overview: oRes.overview,
        sessions: sesRes.sessions || [],
      };
    },
    15000
  );
}

export function prefetchMetadataTables(): void {
  prefetchQuery('meta:tables', () => api.listMetadataTables(), 12000);
  prefetchQuery(
    'meta:rows:meta_works_cache::30:0',
    () => api.queryMetadataTable('meta_works_cache', '', 30, 0),
    12000
  );
}

export function prefetchExternalServers(): void {
  prefetchQuery<ExternalServerRecord[]>(
    'ext:servers',
    () => api.listExternalServers().then((r) => r.servers || []),
    12000
  );
}

export function prefetchExtHome(serverId: string): void {
  if (!serverId) return;
  prefetchQuery(`ext:${serverId}:home`, () => api.extGetHome(serverId), 15000);
}

export function prefetchExtItemDetail(serverId: string, itemId: string): void {
  if (!serverId || !itemId) return;
  prefetchQuery(`ext:${serverId}:item:${itemId}`, () => api.extGetItemDetail(serverId, itemId), 15000);
}
