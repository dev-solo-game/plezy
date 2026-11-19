import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { ArrowDownUp, Grid3X3, LayoutGrid, Rows3 } from 'lucide-react';
import { api, shelfLabel } from '../api/client';
import { MediaCard } from '../components/MediaCard';
import { useApp } from '../contexts/AppContext';
import type { LibraryFacets, MediaItem } from '../types';

export const LibraryBrowsePage: React.FC<{ favoritesOnly?: boolean }> = ({ favoritesOnly = false }) => {
  const { shelf = 'all' } = useParams();
  const { libraryVersion, toast } = useApp();

  const [items, setItems] = useState<MediaItem[]>([]);
  const [total, setTotal] = useState(0);
  const [facets, setFacets] = useState<LibraryFacets | null>(null);
  const [loading, setLoading] = useState(true);

  const [mountId, setMountId] = useState('');
  const [genreId, setGenreId] = useState('');
  const [year, setYear] = useState('');
  const [quality, setQuality] = useState('');
  const [watched, setWatched] = useState<'' | '0' | '1'>('');
  const [letter, setLetter] = useState('');
  const [sort, setSort] = useState('added_at');
  const [order, setOrder] = useState<'asc' | 'desc'>('desc');
  const [density, setDensity] = useState<'compact' | 'normal' | 'comfortable'>('normal');
  const [offset, setOffset] = useState(0);
  const limit = 48;

  useEffect(() => {
    setOffset(0);
    setGenreId('');
    setYear('');
    setLetter('');
    api
      .getLibraryFacets(favoritesOnly || shelf === 'all' ? '' : shelf)
      .then((res) => setFacets(res.facets))
      .catch(() => {});
  }, [shelf, favoritesOnly, libraryVersion]);

  const loadItems = useCallback(
    async (nextOffset: number, append: boolean) => {
      if (!append) setLoading(true);
      try {
        const res = await api.getLibraryItems({
          shelf: favoritesOnly || shelf === 'all' ? '' : shelf,
          favorite: favoritesOnly ? '1' : undefined,
          mount_id: mountId,
          genre_id: genreId,
          year,
          quality,
          watched,
          letter,
          sort,
          order,
          offset: nextOffset,
          limit,
        });
        setTotal(res.total);
        setItems((prev) => (append ? [...prev, ...(res.items || [])] : res.items || []));
      } catch (err) {
        toast((err as Error).message, 'error');
      } finally {
        setLoading(false);
      }
    },
    [favoritesOnly, shelf, mountId, genreId, year, quality, watched, letter, sort, order, toast]
  );

  useEffect(() => {
    void loadItems(0, false);
    setOffset(0);
  }, [loadItems, libraryVersion]);

  const azList = facets?.letters && facets.letters.length > 0 ? facets.letters : 'ABCDEFGHIJKLMNOPQRSTUVWXYZ#'.split('');

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">
          {favoritesOnly ? '我的收藏' : shelfLabel(shelf)}
          <span className="tag">{total}</span>
        </h2>

        <div className="flex-row">
          <select className="select" style={{ width: 130, padding: '6px 10px', fontSize: 13 }} value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="added_at">入库时间</option>
            <option value="title">标题</option>
            <option value="year">年份</option>
            <option value="release_date">上映日期</option>
            <option value="rating">评分</option>
            <option value="last_played">最近播放</option>
          </select>

          <button
            type="button"
            className="btn btn-sm"
            onClick={() => setOrder((o) => (o === 'desc' ? 'asc' : 'desc'))}
            title="切换升序/降序"
          >
            <ArrowDownUp size={14} />
            {order === 'desc' ? '降序' : '升序'}
          </button>

          <div className="flex-row" style={{ gap: 4 }}>
            <button type="button" className={`btn btn-icon btn-sm ${density === 'compact' ? 'btn-primary' : ''}`} onClick={() => setDensity('compact')} title="紧凑网格">
              <Grid3X3 size={14} />
            </button>
            <button type="button" className={`btn btn-icon btn-sm ${density === 'normal' ? 'btn-primary' : ''}`} onClick={() => setDensity('normal')} title="标准网格">
              <LayoutGrid size={14} />
            </button>
            <button type="button" className={`btn btn-icon btn-sm ${density === 'comfortable' ? 'btn-primary' : ''}`} onClick={() => setDensity('comfortable')} title="大海报网格">
              <Rows3 size={14} />
            </button>
          </div>
        </div>
      </div>

      {/* Filter Toolbar */}
      <div className="card-box" style={{ padding: 14, marginBottom: 20, display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
        <select className="select" style={{ width: 150, padding: '6px 10px', fontSize: 13 }} value={mountId} onChange={(e) => setMountId(e.target.value)}>
          <option value="">全部挂载源</option>
          {(facets?.mounts || []).map((m) => (
            <option key={m.id} value={m.id}>
              {m.name}
            </option>
          ))}
        </select>

        <select className="select" style={{ width: 140, padding: '6px 10px', fontSize: 13 }} value={genreId} onChange={(e) => setGenreId(e.target.value)}>
          <option value="">全部流派</option>
          {(facets?.genres || []).map((g) => (
            <option key={g.id} value={String(g.id)}>
              {g.name} ({g.count})
            </option>
          ))}
        </select>

        <select className="select" style={{ width: 112, padding: '6px 10px', fontSize: 13 }} value={year} onChange={(e) => setYear(e.target.value)}>
          <option value="">全部年份</option>
          {(facets?.years || []).map((y) => (
            <option key={y} value={String(y)}>
              {y}
            </option>
          ))}
        </select>

        <div className="flex-row" style={{ gap: 6 }}>
          {(
            [
              ['', '全部画质'],
              ['4k', '4K'],
              ['1080p', '1080p'],
              ['hdr', 'HDR'],
              ['dv', '杜比视界'],
            ] as const
          ).map(([q, label]) => (
            <button key={q} type="button" className={`chip ${quality === q ? 'active' : ''}`} onClick={() => setQuality(q)}>
              {label}
            </button>
          ))}
        </div>

        <div className="flex-row" style={{ gap: 6, marginLeft: 'auto' }}>
          {(
            [
              ['', '全部状态'],
              ['0', '未看'],
              ['1', '已看'],
            ] as const
          ).map(([w, label]) => (
            <button key={w} type="button" className={`chip ${watched === w ? 'active' : ''}`} onClick={() => setWatched(w)}>
              {label}
            </button>
          ))}
          {letter && (
            <button type="button" className="chip active" onClick={() => setLetter('')}>
              索引：{letter} ×
            </button>
          )}
        </div>
      </div>

      <div className="browse-with-az">
        <div className="browse-main">
          {loading ? (
            <div className="muted">加载片库中...</div>
          ) : items.length === 0 ? (
            <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
              当前筛选条件下没有找到媒体内容
            </div>
          ) : (
            <>
              <div className={`poster-grid ${density === 'normal' ? '' : density}`}>
                {items.map((item) => (
                  <MediaCard key={item.id} item={item} onUpdated={() => void loadItems(0, false)} />
                ))}
              </div>

              {items.length < total && (
                <div style={{ textAlign: 'center', marginTop: 26 }}>
                  <button
                    type="button"
                    className="btn"
                    onClick={() => {
                      const next = offset + limit;
                      setOffset(next);
                      void loadItems(next, true);
                    }}
                  >
                    加载更多（已显示 {items.length} / {total}）
                  </button>
                </div>
              )}
            </>
          )}
        </div>

        <div className="az-bar" title="按标题首字母筛选">
          {azList.map((ch) => (
            <button
              key={ch}
              type="button"
              className={`az-btn ${letter === ch ? 'active' : ''}`}
              onClick={() => setLetter((prev) => (prev === ch ? '' : ch))}
            >
              {ch}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
};
