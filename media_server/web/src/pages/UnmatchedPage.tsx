import React, { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { CheckCircle2, Play, Search, Sparkles } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { ManualMatchModal } from '../components/ManualMatchModal';
import { useApp } from '../contexts/AppContext';
import type { UnmatchedEntry } from '../types';

export const UnmatchedPage: React.FC = () => {
  const navigate = useNavigate();
  const { libraryVersion, setUnmatchedCount, toast } = useApp();
  const [entries, setEntries] = useState<UnmatchedEntry[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [matchingEntry, setMatchingEntry] = useState<UnmatchedEntry | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listUnmatched(100, 0);
      setEntries(res.items || []);
      setTotal(res.total || 0);
      setUnmatchedCount(res.total || 0);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [setUnmatchedCount, toast]);

  useEffect(() => {
    void load();
  }, [load, libraryVersion]);

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">
          待匹配中心
          <span className="tag">{total}</span>
        </h2>
        <button
          type="button"
          className="btn btn-primary btn-sm"
          onClick={() => api.scrapeAll(true, false).then(() => toast('已启动批量重试自动刮削', 'success'))}
        >
          <Sparkles size={14} />
          重试全部自动刮削
        </button>
      </div>

      {loading ? (
        <div className="muted">加载中...</div>
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
                  <div className="muted-sm" style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
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
          onMatched={() => void load()}
        />
      )}
    </div>
  );
};
