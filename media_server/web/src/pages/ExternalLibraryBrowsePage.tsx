import React, { useEffect, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { ArrowDownUp, ArrowLeft, Grid3X3, LayoutGrid, Rows3 } from 'lucide-react';
import { api } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { CustomSelect } from '../components/CustomSelect';
import { ExtMediaCard } from '../components/ExtMediaCard';
import { GridSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';

export const ExternalLibraryBrowsePage: React.FC = () => {
  const { serverId = '', viewId = '' } = useParams();
  const [searchParams] = useSearchParams();
  const { toast } = useApp();

  const viewName = searchParams.get('name') || '媒体库';
  const collectionType = searchParams.get('type') || '';

  const [sort, setSort] = useState('added');
  const [order, setOrder] = useState<'asc' | 'desc'>('desc');
  const [filter, setFilter] = useState('');
  const [keyword, setKeyword] = useState('');
  const [appliedKeyword, setAppliedKeyword] = useState('');
  const [pageIdx, setPageIdx] = useState(0);
  const [density, setDensity] = useState<'compact' | 'normal' | 'comfortable'>('normal');
  const limit = 48;

  useEffect(() => {
    setPageIdx(0);
    setKeyword('');
    setAppliedKeyword('');
    setFilter('');
  }, [serverId, viewId]);

  const queryKey = `ext:${serverId}:lib:${viewId}:${sort}:${order}:${filter}:${appliedKeyword}:${pageIdx}`;

  const {
    data,
    showSkeleton,
    isStaleData,
    reload,
  } = useSWRQuery(
    serverId && viewId ? queryKey : null,
    () =>
      api.extGetItems(serverId, {
        parent_id: viewId,
        collection_type: collectionType,
        sort,
        order,
        filter,
        q: appliedKeyword,
        offset: pageIdx * limit,
        limit,
      }),
    {
      keepPreviousData: true,
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const items = data?.items || [];
  const total = data?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(total / limit));

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <div className="flex-row" style={{ gap: 10 }}>
          <Link to={`/ext/${encodeURIComponent(serverId)}`} className="btn btn-icon btn-sm" title="返回服务器主页">
            <ArrowLeft size={15} />
          </Link>
          <div>
            <h2 className="section-title" style={{ margin: 0 }}>
              {viewName}
              <span className="tag">{total}</span>
            </h2>
            {data?.server && (
              <div className="muted-sm" style={{ marginTop: 2 }}>
                {data.server.name}
              </div>
            )}
          </div>
        </div>

        <div className="flex-row" style={{ gap: 8 }}>
          <CustomSelect
            compact
            value={sort}
            onChange={(v) => {
              setSort(v);
              setPageIdx(0);
            }}
            style={{ width: 132 }}
            options={[
              { value: 'added', label: '最近添加' },
              { value: 'title', label: '名称排序' },
              { value: 'year', label: '发行年份' },
              { value: 'rating', label: '评分' },
            ]}
          />

          <button
            type="button"
            className="btn btn-sm"
            onClick={() => {
              setOrder((o) => (o === 'desc' ? 'asc' : 'desc'));
              setPageIdx(0);
            }}
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

      {/* Filter Bar */}
      <div className="filter-bar">
        <CustomSelect
          compact
          value={filter}
          onChange={(v) => {
            setFilter(v);
            setPageIdx(0);
          }}
          style={{ width: 130 }}
          options={[
            { value: '', label: '全部状态' },
            { value: 'unplayed', label: '仅看未看' },
            { value: 'played', label: '仅看已看' },
            { value: 'favorite', label: '仅看收藏' },
          ]}
        />

        <form
          className="flex-row"
          style={{ gap: 6, flex: 1, minWidth: 200 }}
          onSubmit={(e) => {
            e.preventDefault();
            setAppliedKeyword(keyword.trim());
            setPageIdx(0);
          }}
        >
          <input
            className="input"
            style={{ height: 34, fontSize: 13, maxWidth: 280 }}
            placeholder="在当前媒体库内筛选关键词..."
            value={keyword}
            onChange={(e) => setKeyword(e.target.value)}
          />
          <button type="submit" className="btn btn-sm">
            筛选
          </button>
          {appliedKeyword && (
            <button
              type="button"
              className="btn btn-sm"
              onClick={() => {
                setKeyword('');
                setAppliedKeyword('');
                setPageIdx(0);
              }}
            >
              清除
            </button>
          )}
        </form>
      </div>

      {showSkeleton ? (
        <GridSkeleton count={12} />
      ) : items.length === 0 ? (
        <div className="card-box muted" style={{ textAlign: 'center', padding: 52 }}>
          当前筛选条件下暂无内容
        </div>
      ) : (
        <div className={isStaleData ? 'stale-dim' : ''}>
          <div className={`poster-grid ${density === 'compact' ? 'compact' : density === 'comfortable' ? 'comfortable' : ''}`}>
            {items.map((item) => (
              <ExtMediaCard key={item.id} serverId={serverId} item={item} onUpdated={() => void reload()} />
            ))}
          </div>

          {totalPages > 1 && (
            <div className="flex-row" style={{ justifyContent: 'center', gap: 12, marginTop: 26 }}>
              <button
                type="button"
                className="btn btn-sm"
                disabled={pageIdx <= 0}
                onClick={() => setPageIdx((p) => Math.max(0, p - 1))}
              >
                上一页
              </button>
              <span className="muted-sm">
                第 {pageIdx + 1} / {totalPages} 页（共 {total} 项）
              </span>
              <button
                type="button"
                className="btn btn-sm"
                disabled={pageIdx + 1 >= totalPages}
                onClick={() => setPageIdx((p) => p + 1)}
              >
                下一页
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
};
