import React, { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { ArrowDownUp, Grid3X3, LayoutGrid, Rows3 } from 'lucide-react';
import { api, shelfLabel } from '../api/client';
import { libraryQueryKey } from '../api/prefetch';
import { useSWRQuery } from '../api/queryCache';
import { CustomSelect } from '../components/CustomSelect';
import { MediaCard } from '../components/MediaCard';
import { GridSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { LibraryFacets, MediaItem } from '../types';

export const LibraryBrowsePage: React.FC<{ favoritesOnly?: boolean }> = ({ favoritesOnly = false }) => {
  const { shelf = 'all' } = useParams();
  const { libraryVersion, toast } = useApp();

  const [mountId, setMountId] = useState('');
  const [genreId, setGenreId] = useState('');
  const [year, setYear] = useState('');
  const [quality, setQuality] = useState('');
  const [watched, setWatched] = useState<'' | '0' | '1'>('');
  const [letter, setLetter] = useState('');
  const [sort, setSort] = useState('added_at');
  const [order, setOrder] = useState<'asc' | 'desc'>('desc');
  const [density, setDensity] = useState<'compact' | 'normal' | 'comfortable'>('normal');
  const [extraItems, setExtraItems] = useState<MediaItem[]>([]);
  const [loadingMore, setLoadingMore] = useState(false);
  const limit = 48;

  const shelfFilter = favoritesOnly || shelf === 'all' ? '' : shelf;

  useEffect(() => {
    setGenreId('');
    setYear('');
    setLetter('');
    setExtraItems([]);
  }, [shelf, favoritesOnly]);

  const queryParams = {
    shelf: shelfFilter,
    favorite: favoritesOnly ? '1' : undefined,
    mount_id: mountId,
    genre_id: genreId,
    year,
    quality,
    watched,
    letter,
    sort,
    order,
    offset: 0,
    limit,
  };
  const browseKey = libraryQueryKey(queryParams);

  useEffect(() => {
    setExtraItems([]);
  }, [browseKey]);

  const { data: facets } = useSWRQuery<LibraryFacets>(
    `facets:${shelfFilter}`,
    () => api.getLibraryFacets(shelfFilter).then((r) => r.facets),
    { deps: [libraryVersion], keepPreviousData: true }
  );

  const {
    data: page,
    showSkeleton,
    isStaleData,
    reload,
  } = useSWRQuery(browseKey, () => api.getLibraryItems(queryParams), {
    deps: [libraryVersion],
    keepPreviousData: true,
    onError: (err) => toast(err.message, 'error'),
  });

  const items = [...(page?.items || []), ...extraItems];
  const total = page?.total ?? 0;

  const handleLoadMore = async () => {
    if (loadingMore) return;
    setLoadingMore(true);
    try {
      const nextOffset = items.length;
      const res = await api.getLibraryItems({
        ...queryParams,
        offset: nextOffset,
      });
      setExtraItems((prev) => [...prev, ...(res.items || [])]);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoadingMore(false);
    }
  };

  const azList = facets?.letters && facets.letters.length > 0 ? facets.letters : 'ABCDEFGHIJKLMNOPQRSTUVWXYZ#'.split('');

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">
          {favoritesOnly ? '我的收藏' : shelfLabel(shelf)}
          <span className="tag">{total}</span>
        </h2>

        <div className="flex-row">
          <CustomSelect
            compact
            value={sort}
            onChange={setSort}
            style={{ width: 136 }}
            options={[
              { value: 'added_at', label: '入库时间' },
              { value: 'title', label: '标题' },
              { value: 'year', label: '年份' },
              { value: 'release_date', label: '上映日期' },
              { value: 'rating', label: '评分' },
              { value: 'last_played', label: '最近播放' },
            ]}
          />

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
        <CustomSelect
          compact
          value={mountId}
          onChange={setMountId}
          style={{ width: 156 }}
          options={[
            { value: '', label: '全部挂载源' },
            ...(facets?.mounts || []).map((m) => ({ value: m.id, label: m.name })),
          ]}
        />

        <CustomSelect
          compact
          value={genreId}
          onChange={setGenreId}
          style={{ width: 148 }}
          options={[
            { value: '', label: '全部流派' },
            ...(facets?.genres || []).map((g) => ({ value: String(g.id), label: `${g.name} (${g.count})` })),
          ]}
        />

        <CustomSelect
          compact
          value={year}
          onChange={setYear}
          style={{ width: 118 }}
          options={[
            { value: '', label: '全部年份' },
            ...(facets?.years || []).map((y) => ({ value: String(y), label: String(y) })),
          ]}
        />

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
          {showSkeleton && items.length === 0 ? (
            <GridSkeleton />
          ) : items.length === 0 ? (
            <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
              当前筛选条件下没有找到媒体内容
            </div>
          ) : (
            <>
              <div className={`poster-grid ${density === 'normal' ? '' : density} ${isStaleData ? 'stale-dim' : ''}`}>
                {items.map((item) => (
                  <MediaCard key={item.id} item={item} onUpdated={() => void reload()} />
                ))}
              </div>

              {items.length < total && (
                <div style={{ textAlign: 'center', marginTop: 26 }}>
                  <button
                    type="button"
                    className="btn"
                    disabled={loadingMore}
                    onClick={() => void handleLoadMore()}
                  >
                    {loadingMore ? '获取中...' : `加载更多（已显示 ${items.length} / ${total}）`}
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
