import React, { useEffect, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { AlertTriangle, CheckCircle2, Info, Loader2, Play, ScrollText, Search, Sparkles } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { ManualMatchModal } from '../components/ManualMatchModal';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ScrapeProgressEvent, UnmatchedEntry } from '../types';

export const UnmatchedPage: React.FC = () => {
  const navigate = useNavigate();
  const { libraryVersion, scrapeProgress, setUnmatchedCount, toast } = useApp();
  const [matchingEntry, setMatchingEntry] = useState<UnmatchedEntry | null>(null);
  const [startingRetry, setStartingRetry] = useState(false);
  const [lastSummary, setLastSummary] = useState<ScrapeProgressEvent | null>(null);
  const retryTriggeredRef = useRef(false);

  const {
    data,
    showSkeleton,
    reload,
  } = useSWRQuery<{ items: UnmatchedEntry[]; total: number }>(
    'unmatched',
    () => api.listUnmatched(100, 0),
    {
      deps: [libraryVersion],
      onSuccess: (res) => setUnmatchedCount(res.total || 0),
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const entries = data?.items || [];
  const total = data?.total || 0;
  const isScraping = scrapeProgress?.status === 'running';

  useEffect(() => {
    if (!scrapeProgress || scrapeProgress.status === 'idle') return;
    setLastSummary(scrapeProgress);

    if (
      retryTriggeredRef.current &&
      (scrapeProgress.status === 'completed' || scrapeProgress.status === 'done' || scrapeProgress.status === 'warning')
    ) {
      retryTriggeredRef.current = false;
      const matchedTotal = (scrapeProgress.matched || 0) + (scrapeProgress.merged || 0);
      const unm = scrapeProgress.unmatched || 0;
      if (scrapeProgress.status === 'warning') {
        toast(scrapeProgress.message || '重试刮削遇到异常，请查看运行日志', 'error');
      } else if (scrapeProgress.total === 0) {
        toast(scrapeProgress.message || '当前没有可重试的未锁定条目', 'info');
      } else if (matchedTotal > 0) {
        toast(`重试完成：成功匹配 ${matchedTotal} 项，仍未匹配 ${unm} 项`, 'success');
      } else {
        toast(`重试完成：${scrapeProgress.total} 项仍未匹配，可查看运行日志排查原因`, 'info');
      }
      void reload();
    }
  }, [scrapeProgress, toast, reload]);

  const handleRetryAll = async () => {
    if (startingRetry || isScraping) return;
    setStartingRetry(true);
    retryTriggeredRef.current = true;
    try {
      await api.scrapeAll(true, false);
      toast('已强制刷新缓存并启动多源自动刮削...', 'info');
    } catch (err) {
      retryTriggeredRef.current = false;
      toast((err as Error).message, 'error');
    } finally {
      setStartingRetry(false);
    }
  };

  const activeBanner = isScraping ? scrapeProgress : lastSummary;

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">
          待匹配中心
          <span className="tag">{total}</span>
        </h2>
        <div className="flex-row" style={{ gap: 8 }}>
          <Link to="/manage/logs?component=scraper" className="btn btn-sm">
            <ScrollText size={14} />
            查看刮削日志
          </Link>
          <button
            type="button"
            className="btn btn-primary btn-sm"
            disabled={startingRetry || isScraping}
            onClick={() => void handleRetryAll()}
          >
            {startingRetry || isScraping ? (
              <Loader2 size={14} className="spin" />
            ) : (
              <Sparkles size={14} />
            )}
            {isScraping && scrapeProgress
              ? `正在重试刮削 (${scrapeProgress.done}/${scrapeProgress.total})`
              : '重试全部自动刮削'}
          </button>
        </div>
      </div>

      {activeBanner && activeBanner.status !== 'idle' && (
        <div
          className="card-box flex-row"
          style={{
            padding: '12px 14px',
            marginBottom: 14,
            justifyContent: 'space-between',
            flexWrap: 'wrap',
            gap: 10,
            borderColor:
              activeBanner.status === 'warning'
                ? 'rgba(245, 185, 66, 0.4)'
                : activeBanner.status === 'running'
                ? 'var(--accent-border)'
                : undefined,
          }}
        >
          <div className="flex-row" style={{ gap: 10, flex: 1, minWidth: 240 }}>
            {activeBanner.status === 'running' ? (
              <Loader2 size={16} className="spin" style={{ color: 'var(--accent)', flexShrink: 0 }} />
            ) : activeBanner.status === 'warning' ? (
              <AlertTriangle size={16} style={{ color: 'var(--warning)', flexShrink: 0 }} />
            ) : (
              <Info size={16} style={{ color: 'var(--accent)', flexShrink: 0 }} />
            )}
            <div style={{ fontSize: 13 }}>
              <div style={{ fontWeight: 600 }}>
                {activeBanner.status === 'running'
                  ? `正在刮削 ${activeBanner.done}/${activeBanner.total}${activeBanner.title ? `：${activeBanner.title}` : ''}`
                  : activeBanner.message ||
                    `本轮共检查 ${activeBanner.total} 项：入库 ${(activeBanner.matched || 0) + (activeBanner.merged || 0)} 项，未匹配 ${activeBanner.unmatched || 0} 项`}
              </div>
              {activeBanner.status !== 'running' && (activeBanner.unmatched || 0) > 0 && (
                <div className="muted-sm" style={{ marginTop: 2 }}>
                  部分条目的搜索结果或候选匹配得分低于阈值，已保留在下方以便手工匹配。
                </div>
              )}
            </div>
          </div>

          <Link to="/manage/logs?component=scraper" className="btn btn-sm">
            <ScrollText size={13} />
            查看运行日志定位原因
          </Link>
        </div>
      )}

      {showSkeleton ? (
        <CardListSkeleton />
      ) : entries.length === 0 ? (
        <div className="card-box" style={{ textAlign: 'center', padding: 48 }}>
          <CheckCircle2 size={36} style={{ color: 'var(--success)', marginBottom: 10 }} />
          <div style={{ fontWeight: 600 }}>太棒了，所有媒体文件均已成功刮削入库！</div>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {entries.map((entry) => (
            <div key={entry.item.id} className="card-box flex-row" style={{ padding: 14, justifyContent: 'space-between' }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="flex-row" style={{ marginBottom: 4 }}>
                  <strong>{entry.item.title}</strong>
                  <span className="tag">{entry.guessed_kind === 'show' ? '疑似剧集' : '疑似电影'}</span>
                  {entry.guessed_year && <span className="tag">{entry.guessed_year}</span>}
                  {entry.sample_file?.mount_kind && (
                    <span className="tag accent">{mountKindLabel(entry.sample_file.mount_kind)}</span>
                  )}
                  <span className="tag">{entry.file_count} 个文件</span>
                </div>
                {entry.sample_file?.path && (
                  <div className="muted-sm" style={{ fontFamily: 'var(--font-mono)', wordBreak: 'break-all' }}>
                    {entry.sample_file.path} ({formatBytes(entry.sample_file.size)})
                  </div>
                )}
              </div>

              <div className="flex-row">
                {entry.sample_file?.id && (
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => navigate(`/play/file/${entry.sample_file.id}`)}
                  >
                    <Play size={13} fill="currentColor" />
                    直接播放
                  </button>
                )}
                <button type="button" className="btn btn-primary btn-sm" onClick={() => setMatchingEntry(entry)}>
                  <Search size={13} />
                  手工匹配
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {matchingEntry && (
        <ManualMatchModal
          itemId={matchingEntry.item.id}
          initialTitle={matchingEntry.item.title}
          initialKind={matchingEntry.guessed_kind === 'show' ? 'show' : 'movie'}
          initialYear={matchingEntry.guessed_year}
          onClose={() => setMatchingEntry(null)}
          onMatched={() => void reload()}
        />
      )}
    </div>
  );
};
