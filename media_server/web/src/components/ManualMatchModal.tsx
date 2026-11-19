import React, { useState } from 'react';
import { Check, Loader2, Search, X } from 'lucide-react';
import { api, artworkUrl, providerLabel } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MetadataProvider, ScrapeCandidate } from '../types';
import { CustomSelect } from './CustomSelect';
import { ModalBackdrop } from './ModalBackdrop';

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
  const [provider, setProvider] = useState<'' | MetadataProvider>('');
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
      const res = await api.scrapeSearch(query.trim(), kind, provider, yr, true);
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
    <ModalBackdrop onClose={onClose}>
      <div className="modal-panel" style={{ maxWidth: 780 }}>
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
                placeholder="输入片名，或直接输入 tt1234567 / douban:36283066 / tmdb:230311 / 豆瓣或TMDB链接"
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
                <CustomSelect
                  compact
                  value={provider}
                  onChange={(v) => setProvider(v as '' | MetadataProvider)}
                  style={{ width: 152 }}
                  options={[
                    { value: '', label: '全部已启用源' },
                    { value: 'tmdb', label: 'TMDB' },
                    { value: 'douban', label: '豆瓣' },
                    { value: 'bangumi', label: 'Bangumi' },
                    { value: 'anilist', label: 'AniList' },
                    { value: 'imdb', label: 'IMDb' },
                    { value: 'tvdb', label: 'TheTvDb' },
                  ]}
                />
              </div>

              <div className="flex-row">
                <span className="muted-sm">归入分类：</span>
                <CustomSelect
                  compact
                  value={targetShelf}
                  onChange={setTargetShelf}
                  style={{ width: 136 }}
                  options={[
                    { value: '', label: '自动判断' },
                    { value: 'movie', label: '电影' },
                    { value: 'show', label: '剧集' },
                    { value: 'anime', label: '动漫' },
                    { value: 'variety', label: '综艺' },
                    { value: 'documentary', label: '纪录片' },
                  ]}
                />
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
                      <span className="tag accent">{providerLabel(c.source)} #{c.id}</span>
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
                点击“搜索”从已启用数据源按片名或外部 ID（如 tt... / douban:... / tmdb:...）精确查找条目
              </div>
            )}
          </div>
        </div>
      </div>
    </ModalBackdrop>
  );
};
