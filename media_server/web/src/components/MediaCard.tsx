import React from 'react';
import { useNavigate } from 'react-router-dom';
import { Check, Eye, EyeOff, Film, Heart, Play, X } from 'lucide-react';
import { api, artworkUrl, formatDurationMs, mountKindLabel } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MediaItem } from '../types';

interface MediaCardProps {
  item: MediaItem;
  landscape?: boolean;
  onUpdated?: () => void;
  onHideContinue?: (itemId: number) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, landscape, onUpdated, onHideContinue }) => {
  const navigate = useNavigate();
  const { toast } = useApp();

  const isEpisode = item.kind === 'episode';
  const imgSource = landscape
    ? item.backdrop_source || item.show_backdrop || item.poster_source || item.show_poster
    : item.poster_source || item.show_poster || item.backdrop_source;
  const imgUrl = artworkUrl(imgSource, landscape ? 'w780' : 'w500');

  const ws = item.watch_state;
  const isWatched = Boolean(ws?.watched);
  const isFav = Boolean(ws?.favorite);
  const pos = ws?.position_ms || 0;
  const dur = ws?.duration_ms || item.runtime_ms || 0;
  const progressPct = !isWatched && dur > 0 && pos > 0 ? Math.min(100, Math.round((pos / dur) * 100)) : 0;

  const topRightBadge = item.hdr_badge || item.quality_badge || '';
  const topRightClass =
    topRightBadge === 'DV' ? 'dv' : topRightBadge === '4K' ? 'k4' : '';

  const targetDetailId = isEpisode && item.show_id ? item.show_id : item.id;

  const displayTitle = isEpisode && item.show_title ? item.show_title : item.title;
  const subtitleLeft = isEpisode
    ? `S${String(item.season_number || 1).padStart(2, '0')}E${String(item.episode_number || 1).padStart(2, '0')} · ${item.title}`
    : item.year
    ? String(item.year)
    : item.source_kinds?.map((k) => mountKindLabel(k)).join(' / ') || '';

  const handlePlay = (e: React.MouseEvent) => {
    e.stopPropagation();
    navigate(`/play/${item.id}`);
  };

  const handleToggleWatched = async (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await api.setWatched(item.id, !isWatched);
      onUpdated?.();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleToggleFav = async (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      await api.setFavorite(item.id, !isFav);
      onUpdated?.();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div
      className={`media-card ${landscape ? 'landscape' : ''}`}
      onClick={() => navigate(`/item/${targetDetailId}`)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter') navigate(`/item/${targetDetailId}`);
      }}
    >
      <div className="media-thumb">
        {imgUrl ? (
          <img src={imgUrl} alt={displayTitle} loading="lazy" />
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

        {topRightBadge && (
          <span className={`badge-top-right ${topRightClass}`}>{topRightBadge}</span>
        )}

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
          {onHideContinue && (
            <button
              type="button"
              className="btn btn-icon btn-sm"
              style={{ background: 'rgba(15,17,24,0.85)' }}
              onClick={(e) => {
                e.stopPropagation();
                onHideContinue(item.id);
              }}
              title="从继续观看中移除"
            >
              <X size={14} />
            </button>
          )}
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
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {subtitleLeft}
        </span>
        {landscape && dur > 0 && pos > 0 ? (
          <span>{formatDurationMs(dur - pos)} 剩余</span>
        ) : item.rating && item.rating > 0 ? (
          <span style={{ color: '#f6c453', flexShrink: 0 }}>★ {item.rating.toFixed(1)}</span>
        ) : null}
      </div>
    </div>
  );
};
