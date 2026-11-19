import React, { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ChevronRight, Film, FolderKanban, Loader2, Search, Settings, X } from 'lucide-react';
import { api, extServerKindLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { ExtMediaCard } from '../components/ExtMediaCard';
import { HomeSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ExtSearchResult } from '../types';

export const ExternalServerHomePage: React.FC = () => {
  const { serverId = '' } = useParams();
  const { toast } = useApp();

  const [searchInput, setSearchInput] = useState('');
  const [activeQuery, setActiveQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<ExtSearchResult | null>(null);

  useEffect(() => {
    setSearchInput('');
    setActiveQuery('');
    setSearchResults(null);
  }, [serverId]);

  const {
    data,
    showSkeleton,
    reload,
  } = useSWRQuery(
    serverId ? `ext:${serverId}:home` : null,
    () => api.extGetHome(serverId),
    {
      keepPreviousData: true,
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const handleSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    const q = searchInput.trim();
    if (!q) {
      setActiveQuery('');
      setSearchResults(null);
      return;
    }
    setSearching(true);
    setActiveQuery(q);
    try {
      const res = await api.extSearch(serverId, q);
      setSearchResults(res.results);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSearching(false);
    }
  };

  const clearSearch = () => {
    setSearchInput('');
    setActiveQuery('');
    setSearchResults(null);
  };

  if (showSkeleton) return <HomeSkeleton />;

  const server = data?.server;
  const home = data?.home;

  const hasSearchAny = searchResults
    ? searchResults.movies.length +
        searchResults.shows.length +
        searchResults.episodes.length +
        searchResults.collections.length >
      0
    : false;

  return (
    <div>
      {/* Server Header Banner */}
      <div className="card-box flex-row" style={{ justifyContent: 'space-between', marginBottom: 22, gap: 14 }}>
        <div className="flex-row" style={{ gap: 10, minWidth: 0 }}>
          {server && <span className={`tag ${server.kind}`}>{extServerKindLabel(server.kind)}</span>}
          <h2 style={{ margin: 0, fontSize: 20, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {server?.name || '外部媒体服务器'}
          </h2>
          {server?.server_version && <span className="tag">v{server.server_version}</span>}
          {server?.username && <span className="muted-sm">用户：{server.username}</span>}
        </div>

        <div className="flex-row" style={{ gap: 8 }}>
          <form className="flex-row" style={{ gap: 6 }} onSubmit={(e) => void handleSearch(e)}>
            <div style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
              <Search size={14} className="muted" style={{ position: 'absolute', left: 10, pointerEvents: 'none' }} />
              <input
                className="input"
                style={{ paddingLeft: 30, width: 220, height: 34, fontSize: 13 }}
                placeholder={`在 ${server?.name || '此服务器'} 中搜索...`}
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
              />
            </div>
            <button type="submit" className="btn btn-sm" disabled={searching}>
              {searching ? <Loader2 size={13} className="spin" /> : '搜索'}
            </button>
            {activeQuery && (
              <button type="button" className="btn btn-sm" onClick={clearSearch} title="清空搜索">
                <X size={13} />
              </button>
            )}
          </form>

          <Link to="/manage/servers" className="btn btn-sm" title="管理外部服务器">
            <Settings size={14} />
            管理
          </Link>
        </div>
      </div>

      {/* Server-scoped Search Results */}
      {activeQuery && searchResults ? (
        <div>
          <div className="section-head">
            <h2 className="section-title">
              搜索结果「{activeQuery}」
            </h2>
            <button type="button" className="btn btn-sm" onClick={clearSearch}>
              返回服务器主页
            </button>
          </div>

          {!hasSearchAny ? (
            <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
              在「{server?.name}」中未找到与「{activeQuery}」匹配的作品
            </div>
          ) : (
            <>
              {searchResults.movies.length > 0 && (
                <section>
                  <div className="section-head">
                    <h3 className="section-title">电影 ({searchResults.movies.length})</h3>
                  </div>
                  <div className="poster-grid">
                    {searchResults.movies.map((m) => (
                      <ExtMediaCard key={m.id} serverId={serverId} item={m} onUpdated={() => void reload()} />
                    ))}
                  </div>
                </section>
              )}

              {searchResults.shows.length > 0 && (
                <section>
                  <div className="section-head">
                    <h3 className="section-title">剧集 / 动漫 ({searchResults.shows.length})</h3>
                  </div>
                  <div className="poster-grid">
                    {searchResults.shows.map((s) => (
                      <ExtMediaCard key={s.id} serverId={serverId} item={s} onUpdated={() => void reload()} />
                    ))}
                  </div>
                </section>
              )}

              {searchResults.episodes.length > 0 && (
                <section>
                  <div className="section-head">
                    <h3 className="section-title">单集 ({searchResults.episodes.length})</h3>
                  </div>
                  <div className="poster-grid">
                    {searchResults.episodes.map((ep) => (
                      <ExtMediaCard key={ep.id} serverId={serverId} item={ep} landscape onUpdated={() => void reload()} />
                    ))}
                  </div>
                </section>
              )}

              {searchResults.collections.length > 0 && (
                <section>
                  <div className="section-head">
                    <h3 className="section-title">合集 ({searchResults.collections.length})</h3>
                  </div>
                  <div className="poster-grid">
                    {searchResults.collections.map((col) => (
                      <ExtMediaCard key={col.id} serverId={serverId} item={col} onUpdated={() => void reload()} />
                    ))}
                  </div>
                </section>
              )}
            </>
          )}
        </div>
      ) : (
        <>
          {/* Media Views / Libraries */}
          {(home?.views?.length || 0) > 0 && (
            <section style={{ marginBottom: 28 }}>
              <div className="section-head" style={{ marginTop: 0 }}>
                <h2 className="section-title">
                  <FolderKanban size={18} style={{ color: 'var(--accent)' }} />
                  媒体库分类
                </h2>
              </div>
              <div className="ext-view-grid">
                {home!.views.map((v) => (
                  <Link
                    key={v.id}
                    to={`/ext/${encodeURIComponent(serverId)}/library/${encodeURIComponent(v.id)}?name=${encodeURIComponent(
                      v.name
                    )}&type=${encodeURIComponent(v.collection_type || '')}`}
                    className="ext-view-card"
                  >
                    {v.image_url && <img className="ext-view-bg" src={v.image_url} alt={v.name} loading="lazy" />}
                    <div className="ext-view-scrim" />
                    <div className="ext-view-content">
                      <strong style={{ fontSize: 16, color: '#fff' }}>{v.name}</strong>
                      <span className="muted-sm" style={{ fontSize: 11.5 }}>
                        {v.collection_type || 'media library'}
                      </span>
                    </div>
                  </Link>
                ))}
              </div>
            </section>
          )}

          {/* Continue Watching */}
          {(home?.resume?.length || 0) > 0 && (
            <section style={{ marginBottom: 28 }}>
              <div className="section-head">
                <h2 className="section-title">继续观看</h2>
              </div>
              <div className="h-scroll-row landscape">
                {home!.resume.map((item) => (
                  <ExtMediaCard
                    key={item.id}
                    serverId={serverId}
                    item={item}
                    landscape
                    onUpdated={() => void reload()}
                  />
                ))}
              </div>
            </section>
          )}

          {/* Latest by View */}
          {(home?.latest_by_view || []).map((grp) => (
            <section key={grp.view.id} style={{ marginBottom: 28 }}>
              <div className="section-head">
                <h2 className="section-title">最近添加 · {grp.view.name}</h2>
                <Link
                  to={`/ext/${encodeURIComponent(serverId)}/library/${encodeURIComponent(
                    grp.view.id
                  )}?name=${encodeURIComponent(grp.view.name)}&type=${encodeURIComponent(grp.view.collection_type || '')}`}
                  className="btn btn-sm"
                >
                  查看全部
                  <ChevronRight size={14} />
                </Link>
              </div>
              <div className="h-scroll-row">
                {grp.items.map((item) => (
                  <ExtMediaCard key={item.id} serverId={serverId} item={item} onUpdated={() => void reload()} />
                ))}
              </div>
            </section>
          ))}

          {(home?.views?.length || 0) === 0 && (home?.resume?.length || 0) === 0 && (
            <div className="card-box" style={{ textAlign: 'center', padding: 54 }}>
              <Film size={36} className="muted" style={{ marginBottom: 12 }} />
              <div className="muted">该外部媒体服务器当前账号下暂无可见媒体库。</div>
            </div>
          )}
        </>
      )}
    </div>
  );
};
