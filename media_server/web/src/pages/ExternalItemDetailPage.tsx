import React, { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Check, ExternalLink, Heart, Play, User } from 'lucide-react';
import { api, extServerKindLabel, formatBytes, formatDurationMs } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { ExtMediaCard } from '../components/ExtMediaCard';
import { DetailSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ExtMediaSource } from '../types';

function extItemKindLabel(kind?: string): string {
  switch (kind) {
    case 'movie':
      return '电影';
    case 'show':
      return '剧集';
    case 'season':
      return '分季';
    case 'episode':
      return '单集';
    case 'boxset':
      return '合集';
    case 'playlist':
      return '播放列表';
    default:
      return '视频';
  }
}

export const ExternalItemDetailPage: React.FC = () => {
  const { serverId = '', itemId = '' } = useParams();
  const navigate = useNavigate();
  const { toast } = useApp();

  const [selectedSourceId, setSelectedSourceId] = useState('');
  const [selectedSeasonId, setSelectedSeasonId] = useState('');
  const [externalLinks, setExternalLinks] = useState<Record<string, string> | null>(null);

  const { data, showSkeleton, reload } = useSWRQuery(
    serverId && itemId ? `ext:${serverId}:item:${itemId}` : null,
    () => api.extGetItemDetail(serverId, itemId),
    {
      onError: (err) => toast(err.message, 'error'),
    }
  );

  useEffect(() => {
    setExternalLinks(null);
    setSelectedSourceId('');
    setSelectedSeasonId('');
  }, [serverId, itemId]);

  const detail = data?.detail;
  const server = data?.server;

  useEffect(() => {
    if (!detail) return;
    if (detail.media_sources?.length && !detail.media_sources.some((m) => m.id === selectedSourceId)) {
      setSelectedSourceId(detail.media_sources[0].id);
    }
    if (detail.seasons?.length && !detail.seasons.some((s) => s.id === selectedSeasonId)) {
      setSelectedSeasonId(detail.on_deck_episode?.season_id || detail.seasons[0].id);
    }
  }, [detail, selectedSourceId, selectedSeasonId]);

  if (showSkeleton) return <DetailSkeleton />;
  if (!detail) return null;

  const { item } = detail;
  const isShow = item.kind === 'show';
  const playTargetId = isShow && detail.on_deck_episode ? detail.on_deck_episode.id : item.id;
  const activeSource: ExtMediaSource | undefined =
    detail.media_sources?.find((m) => m.id === selectedSourceId) || detail.media_sources?.[0];

  const backdrop = item.backdrop_url || item.poster_url || '';
  const poster = item.poster_url || item.backdrop_url || '';
  const isFav = item.favorite;
  const isWatched = item.watched;
  const resumeMs = !isWatched ? item.position_ms || 0 : 0;

  const filteredEpisodes = (detail.episodes || []).filter(
    (ep) => !selectedSeasonId || !ep.season_id || ep.season_id === selectedSeasonId
  );

  const handleToggleFav = async () => {
    try {
      await api.extSetFavorite(serverId, item.id, !isFav);
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleToggleWatched = async () => {
    try {
      await api.extSetWatched(serverId, item.id, !isWatched);
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const loadExternalPlayers = async () => {
    try {
      const pb = await api.extGetPlaybackInfo(serverId, playTargetId, activeSource?.id);
      setExternalLinks(pb.external_players || {});
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const canPlay =
    item.kind === 'movie' ||
    item.kind === 'episode' ||
    item.kind === 'video' ||
    (isShow && Boolean(detail.on_deck_episode || (detail.episodes && detail.episodes.length > 0)));

  return (
    <div>
      <div className="flex-row" style={{ marginBottom: 12, gap: 8 }}>
        <Link to={`/ext/${encodeURIComponent(serverId)}`} className="btn btn-sm">
          <ArrowLeft size={14} />
          {server?.name || '返回服务器'}
        </Link>
        {detail.show && (
          <Link to={`/ext/${encodeURIComponent(serverId)}/item/${encodeURIComponent(detail.show.id)}`} className="btn btn-sm">
            {detail.show.title}
          </Link>
        )}
      </div>

      <section className="detail-hero">
        {backdrop && <img className="detail-backdrop" decoding="async" src={backdrop} alt={item.title} />}
        <div className="detail-scrim" />

        <div className="detail-inner">
          {poster ? (
            <img className="detail-poster" decoding="async" src={poster} alt={item.title} />
          ) : (
            <div className="detail-poster media-fallback">{item.title}</div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div className="flex-row">
              {server && <span className={`tag ${server.kind}`}>{extServerKindLabel(server.kind)}</span>}
              <span className="tag accent">{extItemKindLabel(item.kind)}</span>
              {item.year ? <span className="tag">{item.year}</span> : null}
              {item.rating && item.rating > 0 ? <span className="tag gold">★ {item.rating.toFixed(1)}</span> : null}
              {item.runtime_ms && item.runtime_ms > 0 ? <span className="tag">{formatDurationMs(item.runtime_ms)}</span> : null}
              {item.official_rating && <span className="tag">{item.official_rating}</span>}
            </div>

            <div>
              <h1 style={{ margin: 0, fontSize: 'clamp(24px, 3vw, 36px)' }}>{item.title}</h1>
              {item.original_title && item.original_title !== item.title && (
                <div className="muted" style={{ marginTop: 4 }}>{item.original_title}</div>
              )}
              {item.tagline && (
                <div style={{ marginTop: 6, color: 'var(--accent)', fontSize: 14 }}>{item.tagline}</div>
              )}
            </div>

            {(item.genres?.length || 0) > 0 && (
              <div className="flex-row">
                {item.genres!.map((g) => (
                  <span key={g} className="tag">
                    {g}
                  </span>
                ))}
                {(item.studios?.length || 0) > 0 && (
                  <span className="muted-sm">出品：{item.studios!.join(' / ')}</span>
                )}
              </div>
            )}

            {item.overview && (
              <p className="muted" style={{ margin: 0, lineHeight: 1.7, maxWidth: 780 }}>
                {item.overview}
              </p>
            )}

            <div className="flex-row" style={{ marginTop: 6 }}>
              {canPlay && (
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() =>
                    navigate(
                      `/play/ext/${encodeURIComponent(serverId)}/${encodeURIComponent(playTargetId)}${
                        activeSource && !isShow ? `?source_id=${encodeURIComponent(activeSource.id)}` : ''
                      }`
                    )
                  }
                >
                  <Play size={16} fill="currentColor" />
                  {resumeMs > 5000
                    ? `继续播放 (${formatDurationMs(resumeMs)})`
                    : isShow && detail.on_deck_episode
                    ? `播放 S${detail.on_deck_episode.season_number || 1}E${detail.on_deck_episode.episode_number || 1}`
                    : '立即播放'}
                </button>
              )}

              <button type="button" className="btn" onClick={() => void handleToggleWatched()}>
                <Check size={15} />
                {isWatched ? '标为未看' : '标为已看'}
              </button>

              <button
                type="button"
                className="btn"
                style={{ color: isFav ? '#ff6b8b' : undefined }}
                onClick={() => void handleToggleFav()}
              >
                <Heart size={15} fill={isFav ? 'currentColor' : 'none'} />
                {isFav ? '已收藏' : '收藏'}
              </button>

              {canPlay && (
                <button type="button" className="btn btn-sm" onClick={() => void loadExternalPlayers()}>
                  <ExternalLink size={14} />
                  外部播放器 / 代理直链
                </button>
              )}
            </div>

            {externalLinks && (
              <div className="card-box flex-row" style={{ padding: 10 }}>
                {(['potplayer', 'vlc', 'iina', 'mpv'] as const).map(
                  (p) =>
                    externalLinks[p] && (
                      <a key={p} href={externalLinks[p]} className="btn btn-sm">
                        在 {p.toUpperCase()} 中打开
                      </a>
                    )
                )}
                {externalLinks.direct && (
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => {
                      void navigator.clipboard.writeText(externalLinks.direct);
                      toast('已复制 12 小时代理签名直链', 'success');
                    }}
                  >
                    复制流直链
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </section>

      {/* Media Sources & Streams */}
      {(detail.media_sources?.length || 0) > 0 && (
        <section className="card-box" style={{ marginBottom: 24 }}>
          <div className="section-head" style={{ marginTop: 0 }}>
            <h3 className="section-title" style={{ fontSize: 16 }}>
              片源版本与轨道信息 ({detail.media_sources!.length} 个版本)
            </h3>
          </div>

          <div className="flex-row" style={{ marginBottom: 12 }}>
            {detail.media_sources!.map((ms, idx) => (
              <button
                key={ms.id}
                type="button"
                className={`chip ${activeSource?.id === ms.id ? 'active' : ''}`}
                onClick={() => setSelectedSourceId(ms.id)}
              >
                <span>{ms.name || `版本 #${idx + 1}`}</span>
                {ms.width ? <span>{ms.width >= 3800 ? '4K' : `${ms.height}p`}</span> : null}
                {ms.size ? <span>{formatBytes(ms.size)}</span> : null}
              </button>
            ))}
          </div>

          {activeSource && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {activeSource.path && (
                <div className="muted-sm" style={{ fontFamily: 'var(--font-mono)', wordBreak: 'break-all' }}>
                  {activeSource.path}
                </div>
              )}
              <div className="flex-row">
                {activeSource.container && <span className="tag">{activeSource.container.toUpperCase()}</span>}
                {activeSource.video_codec && <span className="tag accent">{activeSource.video_codec.toUpperCase()}</span>}
                {activeSource.width && activeSource.height ? (
                  <span className="tag">
                    {activeSource.width}×{activeSource.height}
                  </span>
                ) : null}
                {activeSource.hdr_format && <span className="tag dv">{activeSource.hdr_format}</span>}
                {activeSource.bitrate ? <span className="tag">{Math.round(activeSource.bitrate / 1000)} kbps</span> : null}
              </div>

              {(activeSource.streams?.length || 0) > 0 && (
                <div className="grid-2" style={{ marginTop: 4 }}>
                  {activeSource.streams!.map((st) => (
                    <div
                      key={`${st.type}-${st.index}`}
                      style={{
                        padding: '8px 12px',
                        borderRadius: 8,
                        background: 'rgba(255,255,255,0.03)',
                        border: '1px solid var(--border-subtle)',
                        fontSize: 12,
                      }}
                    >
                      <strong>
                        {st.type === 'Video' ? '视频轨' : st.type === 'Audio' ? '音频轨' : '字幕轨'} #{st.index}
                      </strong>{' '}
                      · {st.display_title || `${st.codec || '-'} ${st.language ? `[${st.language}]` : ''}`}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </section>
      )}

      {/* Seasons & Episodes */}
      {isShow && ((detail.seasons?.length || 0) > 0 || (detail.episodes?.length || 0) > 0) && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">分季与剧集</h2>
            {(detail.seasons?.length || 0) > 0 && (
              <div className="flex-row">
                {detail.seasons!.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    className={`chip ${selectedSeasonId === s.id ? 'active' : ''}`}
                    onClick={() => setSelectedSeasonId(s.id)}
                  >
                    {s.title || `第 ${s.episode_number || s.season_number || 1} 季`}
                  </button>
                ))}
              </div>
            )}
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {filteredEpisodes.map((ep) => {
              const epImg = ep.thumb_url || ep.backdrop_url || ep.poster_url || '';
              return (
                <div
                  key={ep.id}
                  className="card-box flex-row"
                  style={{ padding: 12, justifyContent: 'space-between', cursor: 'pointer' }}
                  onClick={() => navigate(`/play/ext/${encodeURIComponent(serverId)}/${encodeURIComponent(ep.id)}`)}
                >
                  <div className="flex-row" style={{ gap: 14, flex: 1, minWidth: 0 }}>
                    {epImg ? (
                      <img
                        src={epImg}
                        alt={ep.title}
                        loading="lazy"
                        decoding="async"
                        style={{ width: 128, height: 72, objectFit: 'cover', borderRadius: 8, flexShrink: 0 }}
                      />
                    ) : (
                      <div
                        style={{
                          width: 128,
                          height: 72,
                          borderRadius: 8,
                          background: 'var(--bg-card)',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          flexShrink: 0,
                        }}
                      >
                        E{ep.episode_number || '-'}
                      </div>
                    )}
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontWeight: 600 }}>
                        S{String(ep.season_number || 1).padStart(2, '0')}E
                        {String(ep.episode_number || 1).padStart(2, '0')} · {ep.title}
                      </div>
                      {ep.overview && (
                        <div className="muted-sm" style={{ marginTop: 4, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 680 }}>
                          {ep.overview}
                        </div>
                      )}
                      <div className="muted-sm" style={{ marginTop: 4 }}>
                        {ep.runtime_ms ? formatDurationMs(ep.runtime_ms) : ''}
                        {ep.watched ? ' · 已看完' : ep.position_ms ? ` · 上次看到 ${formatDurationMs(ep.position_ms)}` : ''}
                      </div>
                    </div>
                  </div>
                  <button type="button" className="btn btn-primary btn-sm">
                    <Play size={13} fill="currentColor" />
                    播放
                  </button>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {/* BoxSet / Playlist Children */}
      {(detail.children?.length || 0) > 0 && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">包含作品 ({detail.children!.length})</h2>
          </div>
          <div className="poster-grid">
            {detail.children!.map((c) => (
              <ExtMediaCard key={c.id} serverId={serverId} item={c} onUpdated={() => void reload()} />
            ))}
          </div>
        </section>
      )}

      {/* Cast & Crew */}
      {(detail.people?.length || 0) > 0 && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">演职员阵容</h2>
          </div>
          <div className="h-scroll-row" style={{ gridAutoColumns: '126px' }}>
            {detail.people!.slice(0, 24).map((p, idx) => (
              <div
                key={`${p.id || p.name}-${idx}`}
                className="card-box"
                style={{ padding: 10, textAlign: 'center' }}
              >
                {p.photo_url ? (
                  <img
                    src={p.photo_url}
                    alt={p.name}
                    loading="lazy"
                    decoding="async"
                    style={{ width: 82, height: 82, borderRadius: '50%', objectFit: 'cover', margin: '0 auto 8px' }}
                  />
                ) : (
                  <div
                    style={{
                      width: 82,
                      height: 82,
                      borderRadius: '50%',
                      background: 'var(--bg-card)',
                      display: 'inline-flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      marginBottom: 8,
                    }}
                  >
                    <User size={24} className="muted" />
                  </div>
                )}
                <div style={{ fontSize: 13, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {p.name}
                </div>
                {p.role && (
                  <div className="muted-sm" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {p.role}
                  </div>
                )}
              </div>
            ))}
          </div>
        </section>
      )}

      {/* Similar Works */}
      {(detail.similar?.length || 0) > 0 && (
        <section>
          <div className="section-head">
            <h2 className="section-title">相似推荐</h2>
          </div>
          <div className="h-scroll-row">
            {detail.similar!.map((s) => (
              <ExtMediaCard key={s.id} serverId={serverId} item={s} onUpdated={() => void reload()} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
};
