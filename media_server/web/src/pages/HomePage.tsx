import React, { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { AlertCircle, ChevronRight, HardDrive, Info, Play, Plus, RefreshCw, Settings } from 'lucide-react';
import { api, artworkUrl, shelfLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { MediaCard } from '../components/MediaCard';
import { HomeSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { HomePayload } from '../types';

export const HomePage: React.FC = () => {
  const navigate = useNavigate();
  const { libraryVersion, setUnmatchedCount, toast } = useApp();
  const [heroIdx, setHeroIdx] = useState(0);

  const {
    data: home,
    showSkeleton,
    reload,
  } = useSWRQuery<HomePayload>('home', () => api.getHome().then((r) => r.home), {
    deps: [libraryVersion],
    onSuccess: (h) => setUnmatchedCount(h.unmatched_count || 0),
    onError: (err) => toast(err.message, 'error'),
  });

  useEffect(() => {
    const heroes = home?.hero || [];
    if (heroes.length <= 1) return;
    const t = window.setInterval(() => {
      setHeroIdx((i) => (i + 1) % heroes.length);
    }, 7000);
    return () => window.clearInterval(t);
  }, [home?.hero]);

  const handleHideContinue = async (itemId: number) => {
    try {
      await api.hideContinue(itemId);
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  if (showSkeleton) {
    return <HomeSkeleton />;
  }

  if (!home) {
    return null;
  }

  const heroes = home.hero || [];
  const activeHero = heroes[heroIdx % Math.max(1, heroes.length)];
  const hasAnyContent =
    heroes.length > 0 ||
    (home.continue_watching?.length || 0) > 0 ||
    (home.recent_all?.length || 0) > 0;

  return (
    <div>
      {home.mount_count === 0 && (
        <div className="glass-panel" style={{ padding: 28, marginBottom: 24 }}>
          <h2 style={{ margin: '0 0 8px' }}>开始构建你的私人统一媒体库</h2>
          <p className="muted" style={{ margin: '0 0 18px', maxWidth: 680 }}>
            当前尚未挂载任何存储源。你可以添加本地硬盘目录、NAS SMB/WebDAV 共享或夸克网盘（支持扫码登录与云端原画/转码），系统将自动索引、读取 NFO 与 TMDB/Bangumi 刮削入库。
          </p>
          <div className="flex-row">
            <Link to="/manage/mounts" className="btn btn-primary">
              <Plus size={16} />
              添加第一个存储挂载源
            </Link>
            <Link to="/settings" className="btn">
              <Settings size={16} />
              配置 TMDB 刮削与代理
            </Link>
          </div>
        </div>
      )}

      {home.mount_count > 0 && !hasAnyContent && (
        <div className="glass-panel" style={{ padding: 26, marginBottom: 24 }}>
          <div className="flex-row" style={{ justifyContent: 'space-between' }}>
            <div>
              <h3 style={{ margin: '0 0 6px' }}>已添加 {home.mount_count} 个挂载源，等待媒体入库</h3>
              <div className="muted-sm">如果目录刚加入或刮削未完成，可以手动触发扫描或前往待匹配中心处理。</div>
            </div>
            <div className="flex-row">
              <button
                type="button"
                className="btn btn-primary btn-sm"
                onClick={() => api.scanAll(false).then(() => toast('已启动全库扫描', 'success'))}
              >
                <RefreshCw size={14} />
                立即扫描全部挂载源
              </button>
              <Link to="/manage/unmatched" className="btn btn-sm">
                <AlertCircle size={14} />
                查看待匹配 ({home.unmatched_count})
              </Link>
              <Link to="/folders" className="btn btn-sm">
                <HardDrive size={14} />
                按目录浏览
              </Link>
            </div>
          </div>
        </div>
      )}

      {activeHero && (
        <section className="hero-banner">
          {artworkUrl(activeHero.backdrop_source || activeHero.poster_source, 'w1280') && (
            <img
              className="hero-bg"
              decoding="async"
              src={artworkUrl(activeHero.backdrop_source || activeHero.poster_source, 'w1280')}
              alt={activeHero.title}
            />
          )}
          <div className="hero-scrim" />
          <div className="hero-content">
            <div className="flex-row">
              <span className="tag accent">{shelfLabel(activeHero.library_type)}</span>
              {activeHero.year && <span className="tag">{activeHero.year}</span>}
              {activeHero.quality_badge && <span className="tag gold">{activeHero.quality_badge}</span>}
              {activeHero.hdr_badge && <span className="tag dv">{activeHero.hdr_badge}</span>}
              {activeHero.rating && activeHero.rating > 0 && (
                <span className="tag">★ {activeHero.rating.toFixed(1)}</span>
              )}
            </div>
            <h1 className="hero-title">{activeHero.title}</h1>
            {activeHero.tagline && (
              <div style={{ color: 'var(--accent)', fontSize: 14, fontWeight: 500 }}>{activeHero.tagline}</div>
            )}
            {activeHero.summary && <p className="hero-summary">{activeHero.summary}</p>}
            <div className="flex-row" style={{ marginTop: 6 }}>
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => navigate(`/play/${activeHero.id}`)}
              >
                <Play size={16} fill="currentColor" />
                立即播放
              </button>
              <button
                type="button"
                className="btn"
                onClick={() => navigate(`/item/${activeHero.id}`)}
              >
                <Info size={16} />
                查看详情
              </button>
            </div>
          </div>

          {heroes.length > 1 && (
            <div className="hero-dots">
              {heroes.map((h, i) => (
                <button
                  key={h.id}
                  type="button"
                  className={`hero-dot ${i === heroIdx % heroes.length ? 'active' : ''}`}
                  onClick={() => setHeroIdx(i)}
                  aria-label={h.title}
                />
              ))}
            </div>
          )}
        </section>
      )}

      {(home.continue_watching?.length || 0) > 0 && (
        <section>
          <div className="section-head">
            <h2 className="section-title">继续观看</h2>
          </div>
          <div className="h-scroll-row landscape">
            {home.continue_watching.map((item) => (
              <MediaCard
                key={item.id}
                item={item}
                landscape
                onUpdated={() => void reload()}
                onHideContinue={handleHideContinue}
              />
            ))}
          </div>
        </section>
      )}

      {(home.recent_all?.length || 0) > 0 && (
        <section>
          <div className="section-head">
            <h2 className="section-title">最近入库</h2>
            <Link to="/library/all" className="muted-sm flex-row" style={{ gap: 2 }}>
              查看全部 <ChevronRight size={14} />
            </Link>
          </div>
          <div className="h-scroll-row">
            {home.recent_all.map((item) => (
              <MediaCard key={item.id} item={item} onUpdated={() => void reload()} />
            ))}
          </div>
        </section>
      )}

      {(home.shelves || []).map((shelf) =>
        shelf.items && shelf.items.length > 0 ? (
          <section key={shelf.key}>
            <div className="section-head">
              <h2 className="section-title">
                {shelf.title}
                {home.counts?.[shelf.key] !== undefined && (
                  <span className="tag">{home.counts[shelf.key]}</span>
                )}
              </h2>
              <Link to={`/library/${shelf.key}`} className="muted-sm flex-row" style={{ gap: 2 }}>
                浏览全部 <ChevronRight size={14} />
              </Link>
            </div>
            <div className="h-scroll-row">
              {shelf.items.map((item) => (
                <MediaCard key={item.id} item={item} onUpdated={() => void reload()} />
              ))}
            </div>
          </section>
        ) : null
      )}
    </div>
  );
};
