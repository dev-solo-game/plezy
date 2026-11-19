import React, { useState } from 'react';
import { Check, Loader2, Search, X } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { ScrapeCandidate } from '../types';

interface ManualMatchModalProps {
  itemId: number;
  initialTitle: string;
  initialKind?: 'movie' | 'show';
  initialYear?: number;
  initialShelf?: string;
  onClose: () => void;
  onMatched: () => void;
}

export const ManualMatchModal: React.FC<ManualMatchModalProps> = ({
  itemId,
  initialTitle,
  initialKind = 'movie',
  initialYear,
  initialShelf = '',
  onClose,
  onMatched,
}) => {
  const { toast } = useApp();
  const [query, setQuery] = useState(initialTitle);
  const [kind, setKind] = useState<'movie' | 'show'>(initialKind);
  const [provider, setProvider] = useState<'' | 'tmdb' | 'bangumi'>('');
  const [year, setYear] = useState(initialYear ? String(initialYear) : '');
  const [targetShelf, setTargetShelf] = useState(initialShelf === 'pending' ? '' : initialShelf);
  const [results, setResults] = useState<ScrapeCandidate[]>([]);
  const [searching, setSearching] = useState(false);
  const [applyingId, setApplyingId] = useState('');

  const handleSearch = async (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!query.trim()) return;
    setSearching(true);
    try {
      const yr = Number(year) || undefined;
      const res = await api.scrapeSearch(query.trim(), kind, provider, yr);
      setResults(res.results || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSearching(false);
    }
  };

  const applyCandidate = async (c: ScrapeCandidate) => {
    setApplyingId(`${c.source}:${c.id}`);
    try {
      await api.manualMatch(itemId, {
        provider: c.source,
        external_id: c.id,
        as_show: kind === 'show',
        library_type: targetShelf,
      });
      toast(`已匹配为《${c.title}》`, 'success');
      onMatched();
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setApplyingId('');
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-panel" style={{ maxWidth: 780 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h3>手工搜索匹配元数据</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body">
          <form onSubmit={handleSearch} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div className="flex-row">
              <input
                className="input"
                style={{ flex: 1 }}
                placeholder="输入电影/剧集/番剧名称"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
              <input
                className="input"
                style={{ width: 92 }}
                placeholder="年份"
                value={year}
                onChange={(e) => setYear(e.target.value)}
              />
              <button type="submit" className="btn btn-primary" disabled={searching}>
                {searching ? <Loader2 size={15} className="spin" /> : <Search size={15} />}
                搜索
              </button>
            </div>

            <div className="flex-row" style={{ justifyContent: 'space-between' }}>
              <div className="flex-row">
                <button
                  type="button"
                  className={`chip ${kind === 'movie' ? 'active' : ''}`}
                  onClick={() => setKind('movie')}
                >
                  电影
                </button>
                <button
                  type="button"
                  className={`chip ${kind === 'show' ? 'active' : ''}`}
                  onClick={() => setKind('show')}
                >
                  剧集 / 番剧
                </button>
                <span className="muted-sm">|</span>
                <select
                  className="select"
                  style={{ width: 130, padding: '5px 10px', fontSize: 12 }}
                  value={provider}
                  onChange={(e) => setProvider(e.target.value as '' | 'tmdb' | 'bangumi')}
                >
                  <option value="">全部刮削源</option>
                  <option value="tmdb">TMDB</option>
                  <option value="bangumi">Bangumi</option>
                </select>
              </div>

              <div className="flex-row">
                <span className="muted-sm">归入分类：</span>
                <select
                  className="select"
                  style={{ width: 130, padding: '5px 10px', fontSize: 12 }}
                  value={targetShelf}
                  onChange={(e) => setTargetShelf(e.target.value)}
                >
                  <option value="">自动判断</option>
                  <option value="movie">电影</option>
                  <option value="show">剧集</option>
                  <option value="anime">动漫</option>
                  <option value="variety">综艺</option>
                  <option value="documentary">纪录片</option>
                </select>
              </div>
            </div>
          </form>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10, maxHeight: 420, overflowY: 'auto' }}>
            {results.map((c) => {
              const key = `${c.source}:${c.id}`;
              const poster = artworkUrl(c.poster_path, 'w185');
              return (
                <div
                  key={key}
                  className="card-box"
                  style={{ padding: 12, display: 'flex', gap: 14, alignItems: 'center' }}
                >
                  {poster ? (
                    <img
                      src={poster}
                      alt={c.title}
                      style={{ width: 58, height: 84, objectFit: 'cover', borderRadius: 8, flexShrink: 0 }}
                    />
                  ) : (
                    <div
                      style={{
                        width: 58,
                        height: 84,
                        borderRadius: 8,
                        background: 'var(--bg-card)',
                        flexShrink: 0,
                      }}
                    />
                  )}
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div className="flex-row">
                      <strong>{c.title}</strong>
                      {c.year && <span className="tag">{c.year}</span>}
                      <span className="tag accent">{c.source.toUpperCase()} #{c.id}</span>
                    </div>
                    {c.original_title && c.original_title !== c.title && (
                      <div className="muted-sm" style={{ marginTop: 2 }}>
                        {c.original_title}
                      </div>
                    )}
                    {c.summary && (
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
                        {c.summary}
                      </div>
                    )}
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    disabled={Boolean(applyingId)}
                    onClick={() => void applyCandidate(c)}
                  >
                    {applyingId === key ? <Loader2 size={14} className="spin" /> : <Check size={14} />}
                    应用此匹配
                  </button>
                </div>
              );
            })}
            {!searching && results.length === 0 && (
              <div className="muted-sm" style={{ textAlign: 'center', padding: '26px 0' }}>
                点击“搜索”从 TMDB 或 Bangumi 查找正确条目
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
