import React, { useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { Check, Eye, EyeOff, Film, Heart, Play } from 'lucide-react';
import { api, formatDurationMs } from '../api/client';
import { prefetchExtItemDetail } from '../api/prefetch';
import { useApp } from '../contexts/AppContext';
import type { ExtItem } from '../types';

interface ExtMediaCardProps {
  serverId: string;
  item: ExtItem;
  landscape?: boolean;
  onUpdated?: () => void;
}

export const ExtMediaCard: React.FC<ExtMediaCardProps> = ({
  serverId,
  item,
  landscape,
  onUpdated,
}) => {
  const navigate = useNavigate();
  const { toast } = useApp();

  const isEpisode = item.kind === 'episode';
  const imgUrl = landscape
    ? item.thumb_url || item.backdrop_url || item.poster_url || ''
    : item.poster_url || item.backdrop_url || item.thumb_url || '';

  const isWatched = item.watched;
  const isFav = item.favorite;
  const pos = item.position_ms || 0;
  const dur = item.runtime_ms || 0;
  const progressPct = !isWatched && dur > 0 && pos > 0 ? Math.min(100, Math.round((pos / dur) * 100)) : 0;

  const topRightBadge = item.hdr_badge || item.quality_badge || '';
  const topRightClass = topRightBadge === 'DV' ? 'dv' : topRightBadge === '4K' ? 'k4' : '';

  const targetDetailId = isEpisode && item.series_id ? item.series_id : item.id;
  const hoverTimerRef = useRef<number | null>(null);

  useEffect(() => {
    return () => {
      if (hoverTimerRef.current !== null) {
        window.clearTimeout(hoverTimerRef.current);
      }
    };
  }, []);

  const schedulePrefetch = () => {
    if (hoverTimerRef.current !== null) return;
    hoverTimerRef.current = window.setTimeout(() => {
      hoverTimerRef.current = null;
      prefetchExtItemDetail(serverId, targetDetailId);
    }, 80);
  };

  const cancelPrefetch = () => {
    if (hoverTimerRef.current !== null) {
      window.clearTimeout(hoverTimerRef.current);
      hoverTimerRef.current = null;
    }
  };

  const displayTitle = isEpisode && item.series_name ? item.series_name : item.title;
  const subtitleLeft = isEpisode
    ? `S${String(item.season_number || 1).padStart(2, '0')}E${String(item.episode_number || 1).padStart(2, '0')} · ${item.title}`
    : item.kind === 'boxset' || item.kind === 'playlist'
    ? item.child_count
      ? `${item.child_count} 部作品`
      : '合集'
    : item.year
    ? String(item.year)
    : '';

  const handlePlay = (e: React.MouseEvent) => {
    e.stopPropagation();
    navigate(`/play/ext/${encodeURIComponent(serverId)}/${encodeURIComponent(item.id)}`);
  };

  const handleToggleWatched = async (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await api.extSetWatched(serverId, item.id, !isWatched);
      onUpdated?.();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleToggleFav = async (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await api.extSetFavorite(serverId, item.id, !isFav);
      onUpdated?.();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const goDetail = () => {
    navigate(`/ext/${encodeURIComponent(serverId)}/item/${encodeURIComponent(targetDetailId)}`);
  };

  return (
    <div
      className={`media-card ${landscape ? 'landscape' : ''}`}
      onClick={goDetail}
      onMouseEnter={schedulePrefetch}
      onMouseLeave={cancelPrefetch}
      onFocus={() => prefetchExtItemDetail(serverId, targetDetailId)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter') goDetail();
      }}
    >
      <div className="media-thumb">
        {imgUrl ? (
          <img src={imgUrl} alt={displayTitle} loading="lazy" decoding="async" />
        ) : (
          <div className="media-fallback">
            <Film size={26} />
            <span>{displayTitle}</span>
          </div>
        )}

        {isWatched && (
          <span className="badge-top-left" title="已观看">
            <Check size={13} strokeWidth={3} />
          </span>
        )}

        {topRightBadge && <span className={`badge-top-right ${topRightClass}`}>{topRightBadge}</span>}

        <div className="card-hover-actions">
          <button
            type="button"
            className="btn btn-icon btn-sm"
            style={{ background: 'rgba(15,17,24,0.85)' }}
            onClick={handleToggleWatched}
            title={isWatched ? '标为未看' : '标为已看'}
          >
            {isWatched ? <EyeOff size={14} /> : <Eye size={14} />}
          </button>
          <button type="button" className="card-play-circle" onClick={handlePlay} title="立即播放">
            <Play size={18} fill="currentColor" style={{ marginLeft: 2 }} />
          </button>
          <button
            type="button"
            className="btn btn-icon btn-sm"
            style={{ background: 'rgba(15,17,24,0.85)', color: isFav ? '#ff6b8b' : undefined }}
            onClick={handleToggleFav}
            title={isFav ? '取消收藏' : '加入收藏'}
          >
            <Heart size={14} fill={isFav ? 'currentColor' : 'none'} />
          </button>
        </div>

        {progressPct > 0 && (
          <div className="card-progress-bar">
            <div className="card-progress-fill" style={{ width: `${progressPct}%` }} />
          </div>
        )}
      </div>

      <div className="media-title" title={displayTitle}>
        {displayTitle}
      </div>
      <div className="media-sub">
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitleLeft}</span>
        {pos > 0 && dur > pos && !isWatched ? (
          <span>余 {formatDurationMs(dur - pos)}</span>
        ) : item.rating ? (
          <span>★ {item.rating.toFixed(1)}</span>
        ) : null}
      </div>
    </div>
  );
};
