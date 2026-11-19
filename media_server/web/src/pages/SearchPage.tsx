import React, { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Search, User } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { ExtMediaCard } from '../components/ExtMediaCard';
import { MediaCard } from '../components/MediaCard';
import { GridSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ExtSearchResult, MediaItem, Person } from '../types';

interface SearchResults {
  movies: MediaItem[];
  shows: MediaItem[];
  episodes: MediaItem[];
  people: Person[];
}

export const SearchPage: React.FC = () => {
  const [params, setParams] = useSearchParams();
  const { externalServers, toast } = useApp();
  const keyword = (params.get('q') || '').trim();
  const enabledExtServers = externalServers.filter((s) => s.enabled);
  const rawScope = (params.get('scope') || 'local').trim();
  const scope =
    rawScope === 'local' || enabledExtServers.some((s) => s.id === rawScope) ? rawScope : 'local';
  const [q, setQ] = useState(keyword);

  useEffect(() => {
    setQ(keyword);
  }, [keyword]);

  const { data: results, showSkeleton } = useSWRQuery<SearchResults>(
    keyword && scope === 'local' ? `search:${keyword}` : null,
    () => api.search(keyword).then((r) => r.results),
    {
      keepPreviousData: Boolean(keyword),
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const {
    data: extResults,
    showSkeleton: extShowSkeleton,
    reload: reloadExtSearch,
  } = useSWRQuery<ExtSearchResult>(
    keyword && scope !== 'local' ? `extsearch:${scope}:${keyword}` : null,
    () => api.extSearch(scope, keyword).then((r) => r.results),
    {
      keepPreviousData: Boolean(keyword),
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const next: Record<string, string> = {};
    if (q.trim()) next.q = q.trim();
    if (scope !== 'local') next.scope = scope;
    setParams(next);
  };

  const switchScope = (nextScope: string) => {
    const next: Record<string, string> = {};
    if (keyword) next.q = keyword;
    if (nextScope !== 'local') next.scope = nextScope;
    setParams(next);
  };

  const movies = results?.movies || [];
  const shows = results?.shows || [];
  const episodes = results?.episodes || [];
  const people = results?.people || [];
  const hasAny = movies.length + shows.length + episodes.length + people.length > 0;

  const extMovies = extResults?.movies || [];
  const extShows = extResults?.shows || [];
  const extEpisodes = extResults?.episodes || [];
  const extCollections = extResults?.collections || [];
  const hasExtAny = extMovies.length + extShows.length + extEpisodes.length + extCollections.length > 0;

  return (
    <div>
      <form className="card-box flex-row" style={{ padding: 14, marginBottom: 14 }} onSubmit={onSubmit}>
        <Search size={18} className="muted" />
        <input
          className="input"
          style={{ flex: 1 }}
          placeholder="输入关键词搜索电影、剧集、单集或演职员..."
          value={q}
          onChange={(e) => setQ(e.target.value)}
          autoFocus
        />
        <button type="submit" className="btn btn-primary">
          搜索
        </button>
      </form>

      {enabledExtServers.length > 0 && (
        <div className="flex-row" style={{ marginBottom: 20, gap: 8 }}>
          <span className="muted-sm">搜索范围：</span>
          <button
            type="button"
            className={`chip ${scope === 'local' ? 'active' : ''}`}
            onClick={() => switchScope('local')}
          >
            本地媒体库
          </button>
          {enabledExtServers.map((srv) => (
            <button
              key={srv.id}
              type="button"
              className={`chip ${scope === srv.id ? 'active' : ''}`}
              onClick={() => switchScope(srv.id)}
            >
              <span className={`ext-kind-dot ${srv.kind}`} style={{ width: 16, height: 16, fontSize: 9 }}>
                {srv.kind === 'emby' ? 'E' : 'J'}
              </span>
              <span>{srv.name}</span>
            </button>
          ))}
        </div>
      )}

      {!keyword ? (
        <div className="muted">输入标题、原名、剧集或演员姓名开始搜索。</div>
      ) : scope !== 'local' ? (
        extShowSkeleton ? (
          <GridSkeleton count={8} />
        ) : !hasExtAny ? (
          <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
            未找到与「{keyword}」相关的内容
          </div>
        ) : (
          <>
            {extMovies.length > 0 && (
              <section>
                <div className="section-head">
                  <h2 className="section-title">电影 ({extMovies.length})</h2>
                </div>
                <div className="poster-grid">
                  {extMovies.map((m) => (
                    <ExtMediaCard key={m.id} serverId={scope} item={m} onUpdated={() => void reloadExtSearch()} />
                  ))}
                </div>
              </section>
            )}

            {extShows.length > 0 && (
              <section>
                <div className="section-head">
                  <h2 className="section-title">剧集 / 动漫 ({extShows.length})</h2>
                </div>
                <div className="poster-grid">
                  {extShows.map((s) => (
                    <ExtMediaCard key={s.id} serverId={scope} item={s} onUpdated={() => void reloadExtSearch()} />
                  ))}
                </div>
              </section>
            )}

            {extEpisodes.length > 0 && (
              <section>
                <div className="section-head">
                  <h2 className="section-title">单集 ({extEpisodes.length})</h2>
                </div>
                <div className="poster-grid">
                  {extEpisodes.map((ep) => (
                    <ExtMediaCard key={ep.id} serverId={scope} item={ep} landscape onUpdated={() => void reloadExtSearch()} />
                  ))}
                </div>
              </section>
            )}

            {extCollections.length > 0 && (
              <section>
                <div className="section-head">
                  <h2 className="section-title">合集 ({extCollections.length})</h2>
                </div>
                <div className="poster-grid">
                  {extCollections.map((c) => (
                    <ExtMediaCard key={c.id} serverId={scope} item={c} onUpdated={() => void reloadExtSearch()} />
                  ))}
                </div>
              </section>
            )}
          </>
        )
      ) : showSkeleton ? (
        <GridSkeleton count={8} />
      ) : !hasAny ? (
        <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
          未找到与「{keyword}」相关的内容
        </div>
      ) : (
        <>
          {movies.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">电影 ({movies.length})</h2>
              </div>
              <div className="poster-grid">
                {movies.map((m) => (
                  <MediaCard key={m.id} item={m} />
                ))}
              </div>
            </section>
          )}

          {shows.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">剧集 / 动漫 / 综艺 ({shows.length})</h2>
              </div>
              <div className="poster-grid">
                {shows.map((s) => (
                  <MediaCard key={s.id} item={s} />
                ))}
              </div>
            </section>
          )}

          {episodes.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">单集 ({episodes.length})</h2>
              </div>
              <div className="poster-grid">
                {episodes.map((ep) => (
                  <MediaCard key={ep.id} item={ep} landscape />
                ))}
              </div>
            </section>
          )}

          {people.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">演职员 ({people.length})</h2>
              </div>
              <div className="flex-row" style={{ gap: 16 }}>
                {people.map((p) => {
                  const photo = artworkUrl(p.photo_source, 'w185');
                  return (
                    <Link
                      key={p.id}
                      to={`/person/${p.id}`}
                      className="card-box"
                      style={{ width: 140, padding: 12, textAlign: 'center' }}
                    >
                      {photo ? (
                        <img
                          src={photo}
                          alt={p.name}
                          loading="lazy"
                          decoding="async"
                          style={{ width: 84, height: 84, borderRadius: '50%', objectFit: 'cover', marginBottom: 8 }}
                        />
                      ) : (
                        <div
                          style={{
                            width: 84,
                            height: 84,
                            borderRadius: '50%',
                            background: 'var(--bg-card)',
                            display: 'inline-flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            marginBottom: 8,
                          }}
                        >
                          <User size={28} className="muted" />
                        </div>
                      )}
                      <div style={{ fontWeight: 600, fontSize: 13 }}>{p.name}</div>
                    </Link>
                  );
                })}
              </div>
            </section>
          )}
        </>
      )}
    </div>
  );
};
