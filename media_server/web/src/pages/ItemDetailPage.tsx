import React, { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import {
  BookmarkPlus,
  Check,
  Edit3,
  ExternalLink,
  FastForward,
  Heart,
  Layers,
  Play,
  RefreshCw,
  Search,
  Unlink,
  User,
} from 'lucide-react';
import { api, artworkUrl, formatBytes, formatDurationMs, mountKindLabel, shelfLabel } from '../api/client';
import { ListPickerModal } from '../components/ListPickerModal';
import { ManualMatchModal } from '../components/ManualMatchModal';
import { MediaCard } from '../components/MediaCard';
import { MetadataEditModal } from '../components/MetadataEditModal';
import { WorkSkipModal } from '../components/WorkSkipModal';
import { useApp } from '../contexts/AppContext';
import type { ItemDetail, MediaFile } from '../types';

export const ItemDetailPage: React.FC = () => {
  const { id } = useParams();
  const navigate = useNavigate();
  const { libraryVersion, toast } = useApp();
  const itemId = Number(id);

  const [detail, setDetail] = useState<ItemDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedFileId, setSelectedFileId] = useState<number>(0);
  const [selectedSeasonId, setSelectedSeasonId] = useState<number>(0);
  const [externalLinks, setExternalLinks] = useState<Record<string, string> | null>(null);

  const [showMatch, setShowMatch] = useState(false);
  const [showEdit, setShowEdit] = useState(false);
  const [showSkip, setShowSkip] = useState(false);
  const [showListPicker, setShowListPicker] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.getItemDetail(itemId);
      setDetail(res.detail);
      if (res.detail.files?.length > 0) {
        setSelectedFileId(res.detail.files[0].id);
      }
      if (res.detail.seasons?.length) {
        const firstSeasonId =
          res.detail.on_deck_episode?.parent_id || res.detail.seasons[0].id;
        setSelectedSeasonId(firstSeasonId);
      }
      setExternalLinks(null);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [itemId, toast]);

  useEffect(() => {
    void load();
  }, [load, libraryVersion]);

  if (loading) return <div className="muted">加载详情中...</div>;
  if (!detail) return null;

  const { item } = detail;
  const isShow = item.kind === 'show';
  const playTargetId = isShow && detail.on_deck_episode ? detail.on_deck_episode.id : item.id;
  const activeFile: MediaFile | undefined =
    detail.files?.find((f) => f.id === selectedFileId) || detail.files?.[0];

  const backdrop = artworkUrl(item.backdrop_source || item.show_backdrop || item.poster_source, 'original');
  const poster = artworkUrl(item.poster_source || item.show_poster, 'w500');
  const isFav = Boolean(item.watch_state?.favorite);
  const isWatched = Boolean(item.watch_state?.watched);
  const resumeMs = !isWatched ? item.watch_state?.position_ms || 0 : 0;

  const filteredEpisodes = (detail.episodes || []).filter(
    (ep) => !selectedSeasonId || ep.parent_id === selectedSeasonId
  );

  const handleToggleFav = async () => {
    try {
      await api.setFavorite(item.id, !isFav);
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleToggleWatched = async () => {
    try {
      await api.setWatched(item.id, !isWatched);
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleRefresh = async () => {
    try {
      await api.refreshItem(item.id);
      toast('已重新刮削刷新', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleUnmatch = async () => {
    if (!window.confirm('确认解除匹配并退回待匹配队列？')) return;
    try {
      await api.unmatchItem(item.id);
      toast('已退回待匹配队列', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const loadExternalPlayers = async () => {
    try {
      const pb = await api.getPlaybackInfoItem(playTargetId, activeFile?.id);
      setExternalLinks(pb.external_players || {});
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div>
      <section className="detail-hero">
        {backdrop && <img className="detail-backdrop" src={backdrop} alt={item.title} />}
        <div className="detail-scrim" />

        <div className="detail-inner">
          {poster ? (
            <img className="detail-poster" src={poster} alt={item.title} />
          ) : (
            <div className="detail-poster media-fallback">{item.title}</div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div className="flex-row">
              <span className="tag accent">{shelfLabel(item.library_type)}</span>
              {item.year && <span className="tag">{item.year}</span>}
              {item.rating && item.rating > 0 && <span className="tag gold">★ {item.rating.toFixed(1)}</span>}
              {item.runtime_ms && item.runtime_ms > 0 && <span className="tag">{formatDurationMs(item.runtime_ms)}</span>}
              {item.content_rating && <span className="tag">{item.content_rating}</span>}
              {item.locked && <span className="tag hdr">已锁定元数据</span>}
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

            {detail.genres?.length > 0 && (
              <div className="flex-row">
                {detail.genres.map((g) => (
                  <span key={g.id} className="tag">
                    {g.name}
                  </span>
                ))}
                {item.studio && <span className="muted-sm">出品：{item.studio}</span>}
              </div>
            )}

            {item.summary && (
              <p className="muted" style={{ margin: 0, lineHeight: 1.7, maxWidth: 780 }}>
                {item.summary}
              </p>
            )}

            {/* Primary Actions */}
            <div className="flex-row" style={{ marginTop: 6 }}>
              {(detail.files?.length > 0 || (isShow && detail.on_deck_episode)) && (
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() =>
                    navigate(
                      `/play/${playTargetId}${activeFile && !isShow ? `?file_id=${activeFile.id}` : ''}`
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

              <button type="button" className="btn" onClick={() => setShowListPicker(true)}>
                <BookmarkPlus size={15} />
                加入播单
              </button>

              {item.work_key && (
                <button type="button" className="btn" onClick={() => setShowSkip(true)}>
                  <FastForward size={15} />
                  跳过片头/尾
                </button>
              )}
            </div>

            {/* Metadata & External Players Row */}
            <div className="flex-row">
              <button type="button" className="btn btn-sm" onClick={() => setShowMatch(true)}>
                <Search size={14} />
                手工匹配
              </button>
              <button type="button" className="btn btn-sm" onClick={() => setShowEdit(true)}>
                <Edit3 size={14} />
                编辑元数据
              </button>
              <button type="button" className="btn btn-sm" onClick={() => void handleRefresh()}>
                <RefreshCw size={14} />
                刷新刮削
              </button>
              <button type="button" className="btn btn-sm" onClick={() => void handleUnmatch()}>
                <Unlink size={14} />
                解除匹配
              </button>
              <button type="button" className="btn btn-sm" onClick={() => void loadExternalPlayers()}>
                <ExternalLink size={14} />
                外部播放器 / 签名直链
              </button>
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
                      toast('已复制 12 小时签名直链', 'success');
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

      {/* Multi-Version File Selector & Media Info */}
      {detail.files?.length > 0 && (
        <section className="card-box" style={{ marginBottom: 24 }}>
          <div className="section-head" style={{ marginTop: 0 }}>
            <h3 className="section-title" style={{ fontSize: 16 }}>
              文件版本与音视频轨道探测 ({detail.files.length} 个版本)
            </h3>
          </div>

          <div className="flex-row" style={{ marginBottom: 14 }}>
            {detail.files.map((f) => (
              <button
                key={f.id}
                type="button"
                className={`chip ${activeFile?.id === f.id ? 'active' : ''}`}
                onClick={() => setSelectedFileId(f.id)}
              >
                <span>{mountKindLabel(f.mount_kind)}</span>
                <span>{f.version_label || f.file_name || f.path}</span>
                {f.width ? <span>{f.width >= 3800 ? '4K' : `${f.height}p`}</span> : null}
                <span>{formatBytes(f.size)}</span>
              </button>
            ))}
          </div>

          {activeFile && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div className="muted-sm" style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                [{activeFile.mount_name || activeFile.mount_id}] {activeFile.path}
              </div>
              <div className="flex-row">
                {activeFile.container && <span className="tag">{activeFile.container.toUpperCase()}</span>}
                {activeFile.video_codec && <span className="tag accent">{activeFile.video_codec.toUpperCase()}</span>}
                {activeFile.width && activeFile.height && (
                  <span className="tag">
                    {activeFile.width}×{activeFile.height}
                  </span>
                )}
                {activeFile.hdr_format && <span className="tag dv">{activeFile.hdr_format}</span>}
                {activeFile.bitrate_kbps ? <span className="tag">{activeFile.bitrate_kbps} kbps</span> : null}
              </div>

              {(activeFile.streams?.length || 0) > 0 && (
                <div className="grid-2" style={{ marginTop: 6 }}>
                  {activeFile.streams!.map((st) => (
                    <div
                      key={`${st.kind}-${st.index}`}
                      style={{
                        padding: '8px 12px',
                        borderRadius: 8,
                        background: 'rgba(255,255,255,0.03)',
                        border: '1px solid var(--border-subtle)',
                        fontSize: 12,
                      }}
                    >
                      <strong>
                        {st.kind === 'video' ? '视频轨' : st.kind === 'audio' ? '音频轨' : '内封字幕'} #{st.index}
                      </strong>{' '}
                      · {st.codec || '-'} {st.language ? `[${st.language}]` : ''} {st.title || ''}{' '}
                      {st.channels ? `(${st.channels}ch)` : ''}
                    </div>
                  ))}
                </div>
              )}

              {detail.subtitles?.length > 0 && (
                <div className="flex-row" style={{ marginTop: 4 }}>
                  <span className="muted-sm">外挂字幕 ({detail.subtitles.length})：</span>
                  {detail.subtitles.map((sub) => (
                    <span key={sub.id} className="tag">
                      {sub.file_name || sub.path}
                    </span>
                  ))}
                </div>
              )}
            </div>
          )}
        </section>
      )}

      {/* Seasons & Episodes */}
      {isShow && (detail.seasons?.length || 0) > 0 && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">分季与剧集</h2>
            <div className="flex-row">
              {detail.seasons!.map((s) => (
                <button
                  key={s.id}
                  type="button"
                  className={`chip ${selectedSeasonId === s.id ? 'active' : ''}`}
                  onClick={() => setSelectedSeasonId(s.id)}
                >
                  {s.title || `第 ${s.season_number} 季`}
                </button>
              ))}
            </div>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {filteredEpisodes.map((ep) => {
              const epPoster = artworkUrl(ep.poster_source || ep.backdrop_source, 'w500');
              const epWatched = Boolean(ep.watch_state?.watched);
              const epPos = ep.watch_state?.position_ms || 0;
              return (
                <div
                  key={ep.id}
                  className="card-box flex-row"
                  style={{ padding: 12, justifyContent: 'space-between', cursor: 'pointer' }}
                  onClick={() => navigate(`/play/${ep.id}`)}
                >
                  <div className="flex-row" style={{ gap: 14, flex: 1, minWidth: 0 }}>
                    {epPoster ? (
                      <img
                        src={epPoster}
                        alt={ep.title}
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
                        <Play size={20} />
                      </div>
                    )}
                    <div style={{ minWidth: 0 }}>
                      <div className="flex-row">
                        <strong>
                          E{String(ep.episode_number || 1).padStart(2, '0')} · {ep.title}
                        </strong>
                        {epWatched && <span className="tag success">已看</span>}
                        {!epWatched && epPos > 0 && (
                          <span className="tag accent">已播至 {formatDurationMs(epPos)}</span>
                        )}
                      </div>
                      {ep.summary && (
                        <div
                          className="muted-sm"
                          style={{
                            marginTop: 4,
                            display: '-webkit-box',
                            WebkitLineClamp: 2,
                            WebkitBoxOrient: 'vertical',
                            overflow: 'hidden',
                          }}
                        >
                          {ep.summary}
                        </div>
                      )}
                    </div>
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      navigate(`/play/${ep.id}`);
                    }}
                  >
                    <Play size={14} fill="currentColor" />
                    播放
                  </button>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {/* Cast & Crew */}
      {detail.credits?.length > 0 && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">演职员表</h2>
          </div>
          <div className="h-scroll-row" style={{ gridAutoColumns: '126px' }}>
            {detail.credits.map((c, idx) => {
              const photo = artworkUrl(c.person.photo_source, 'w185');
              return (
                <Link
                  key={`${c.person.id}-${c.job}-${idx}`}
                  to={`/person/${c.person.id}`}
                  className="card-box"
                  style={{ padding: 10, textAlign: 'center' }}
                >
                  {photo ? (
                    <img
                      src={photo}
                      alt={c.person.name}
                      style={{ width: 72, height: 72, borderRadius: '50%', objectFit: 'cover', marginBottom: 8 }}
                    />
                  ) : (
                    <div
                      style={{
                        width: 72,
                        height: 72,
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
                  <div style={{ fontSize: 13, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {c.person.name}
                  </div>
                  <div className="muted-sm" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {c.character || (c.job === 'director' ? '导演' : c.job)}
                  </div>
                </Link>
              );
            })}
          </div>
        </section>
      )}

      {/* Collections */}
      {(detail.collections?.length || 0) > 0 && (
        <section style={{ marginBottom: 28 }}>
          <div className="section-head">
            <h2 className="section-title">所属合集 / 播单</h2>
          </div>
          <div className="flex-row">
            {detail.collections!.map((col) => (
              <Link key={col.id} to={`/lists/${col.id}`} className="chip">
                <Layers size={13} />
                <span>{col.title}</span>
              </Link>
            ))}
          </div>
        </section>
      )}

      {/* Similar */}
      {(detail.similar?.length || 0) > 0 && (
        <section>
          <div className="section-head">
            <h2 className="section-title">相似推荐</h2>
          </div>
          <div className="h-scroll-row">
            {detail.similar!.map((s) => (
              <MediaCard key={s.id} item={s} onUpdated={load} />
            ))}
          </div>
        </section>
      )}

      {showMatch && (
        <ManualMatchModal
          itemId={item.id}
          initialTitle={item.title}
          initialKind={item.kind === 'show' || item.kind === 'episode' ? 'show' : 'movie'}
          initialYear={item.year}
          initialShelf={item.library_type}
          onClose={() => setShowMatch(false)}
          onMatched={load}
        />
      )}

      {showEdit && (
        <MetadataEditModal item={item} onClose={() => setShowEdit(false)} onSaved={load} />
      )}

      {showSkip && item.work_key && (
        <WorkSkipModal
          workKey={item.work_key}
          initialPrefs={detail.work_prefs}
          onClose={() => setShowSkip(false)}
          onSaved={() => void load()}
        />
      )}

      {showListPicker && (
        <ListPickerModal itemId={item.id} onClose={() => setShowListPicker(false)} />
      )}
    </div>
  );
};
