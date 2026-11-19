import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  Database,
  ExternalLink,
  HardDrive,
  RefreshCw,
  Search,
  Trash2,
  X,
} from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { CustomSelect } from '../components/CustomSelect';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { CardListSkeleton, TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ImageCacheSummary, InspectTableInfo, InspectTablePage } from '../types';

export const MetadataManagePage: React.FC = () => {
  const { libraryVersion, toast } = useApp();
  const [selectedTable, setSelectedTable] = useState('meta_works_cache');
  const [searchInput, setSearchInput] = useState('');
  const [activeQuery, setActiveQuery] = useState('');
  const [limit, setLimit] = useState(30);
  const [offset, setOffset] = useState(0);
  const [jsonPreview, setJsonPreview] = useState<{ col: string; formatted: string } | null>(null);

  const {
    data: tablesData,
    showSkeleton: showTablesSkeleton,
    reload: reloadTables,
  } = useSWRQuery<{ tables: InspectTableInfo[]; image_cache: ImageCacheSummary }>(
    'meta:tables',
    () => api.listMetadataTables(),
    {
      deps: [libraryVersion],
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const queryKey = `meta:rows:${selectedTable}:${activeQuery}:${limit}:${offset}`;
  const {
    data: pageData,
    showSkeleton: showRowsSkeleton,
    isFetching: rowsFetching,
    isStaleData,
    reload: reloadRows,
  } = useSWRQuery<InspectTablePage>(
    queryKey,
    () => api.queryMetadataTable(selectedTable, activeQuery, limit, offset),
    {
      deps: [libraryVersion],
      keepPreviousData: true,
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const tables = tablesData?.tables || [];
  const imageCache = tablesData?.image_cache;
  const cacheTables = tables.filter((t) => t.group === 'cache');
  const libraryTables = tables.filter((t) => t.group === 'library');

  const activeInfo =
    pageData?.table || tables.find((t) => t.name === selectedTable) || null;

  useEffect(() => {
    if (!jsonPreview) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setJsonPreview(null);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [jsonPreview]);

  const handleSelectTable = (name: string) => {
    setSelectedTable(name);
    setSearchInput('');
    setActiveQuery('');
    setOffset(0);
  };

  const handleSearchSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setActiveQuery(searchInput.trim());
    setOffset(0);
  };

  const handleClearTable = async () => {
    if (!activeInfo?.clear_scope) return;
    if (!window.confirm(`确认清空「${activeInfo.label} (${activeInfo.name})」全部缓存记录？`)) {
      return;
    }
    try {
      const res = await api.clearMetaCache(activeInfo.clear_scope);
      toast(`已清理 ${res.deleted} 条缓存记录`, 'success');
      setOffset(0);
      await Promise.all([reloadTables(), reloadRows()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleDeleteRow = async (row: Record<string, unknown>) => {
    if (!activeInfo?.pk_cols?.length) return;
    const pk: Record<string, string> = {};
    for (const col of activeInfo.pk_cols) {
      pk[col] = row[col] === null || row[col] === undefined ? '' : String(row[col]);
    }
    try {
      await api.deleteMetadataCacheRow(activeInfo.name, pk);
      toast('已删除该条缓存', 'success');
      await Promise.all([reloadTables(), reloadRows()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const openJsonModal = (col: string, rawVal: unknown) => {
    const rawStr = typeof rawVal === 'string' ? rawVal : JSON.stringify(rawVal ?? '');
    let formatted = rawStr;
    try {
      formatted = JSON.stringify(JSON.parse(rawStr), null, 2);
    } catch {
      // Show raw text if string is not valid JSON
    }
    setJsonPreview({ col, formatted });
  };

  const totalRows = pageData?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(totalRows / limit));
  const currentPage = Math.floor(offset / limit) + 1;
  const jsonColSet = new Set(activeInfo?.json_cols || []);
  const timeColSet = new Set(activeInfo?.time_cols || []);
  const columns = activeInfo?.columns || [];
  const rows = pageData?.rows || [];

  const renderCellValue = (col: string, val: unknown) => {
    if (val === null || val === undefined || val === '') {
      return <span className="muted-sm">-</span>;
    }
    if (jsonColSet.has(col)) {
      const text = typeof val === 'string' ? val : JSON.stringify(val);
      return (
        <button
          type="button"
          className="btn btn-sm"
          style={{ padding: '3px 9px', fontSize: 11 }}
          onClick={() => openJsonModal(col, val)}
        >
          查看 JSON ({formatBytes(text.length)})
        </button>
      );
    }
    if (timeColSet.has(col)) {
      const num = Number(val);
      if (!Number.isFinite(num) || num <= 0) {
        return <span className="muted-sm">-</span>;
      }
      const expired = col === 'expires_at' && num < Date.now();
      return (
        <span className="muted-sm" style={{ whiteSpace: 'nowrap', color: expired ? 'var(--warning)' : undefined }}>
          {new Date(num).toLocaleString()}
          {expired ? ' (已过期)' : ''}
        </span>
      );
    }
    const str = String(val);
    if (str.length > 56) {
      return (
        <span title={str} style={{ display: 'inline-block', maxWidth: 260, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', verticalAlign: 'bottom' }}>
          {str}
        </span>
      );
    }
    return <span style={{ whiteSpace: 'nowrap' }}>{str}</span>;
  };

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">
          <Database size={20} style={{ color: 'var(--accent)' }} />
          元数据与源数据表管理
        </h2>
        {imageCache && (
          <div className="flex-row">
            <span className="tag accent">
              <HardDrive size={12} />
              本地图片磁盘缓存：{imageCache.files} 个文件 · {formatBytes(imageCache.bytes)}
            </span>
          </div>
        )}
      </div>

      {/* Table group selector */}
      {showTablesSkeleton && tables.length === 0 ? (
        <CardListSkeleton count={2} />
      ) : (
        <div className="card-box" style={{ padding: 16, marginBottom: 18, display: 'flex', flexDirection: 'column', gap: 14 }}>
          <div>
            <div className="muted-sm" style={{ marginBottom: 8, fontWeight: 600 }}>
              元数据缓存表（TMDB / Bangumi 缓存，支持单条删除与整表清空）
            </div>
            <div className="flex-row">
              {cacheTables.map((t) => (
                <button
                  key={t.name}
                  type="button"
                  className={`chip ${selectedTable === t.name ? 'active' : ''}`}
                  onClick={() => handleSelectTable(t.name)}
                >
                  <span>{t.label}</span>
                  <span className="muted-sm" style={{ fontSize: 11 }}>{t.name}</span>
                  <span className="tag" style={{ padding: '0 6px', fontSize: 11 }}>{t.row_count}</span>
                </button>
              ))}
            </div>
          </div>

          <div className="divider" style={{ margin: 0 }} />

          <div>
            <div className="muted-sm" style={{ marginBottom: 8, fontWeight: 600 }}>
              媒体库源数据表（SQLite 核心索引表，只读检索核验）
            </div>
            <div className="flex-row">
              {libraryTables.map((t) => (
                <button
                  key={t.name}
                  type="button"
                  className={`chip ${selectedTable === t.name ? 'active' : ''}`}
                  onClick={() => handleSelectTable(t.name)}
                >
                  <span>{t.label}</span>
                  <span className="muted-sm" style={{ fontSize: 11 }}>{t.name}</span>
                  <span className="tag" style={{ padding: '0 6px', fontSize: 11 }}>{t.row_count}</span>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Active table inspector */}
      <div className="card-box" style={{ padding: 0, overflow: 'hidden' }}>
        <div
          className="flex-row"
          style={{
            padding: '14px 16px',
            borderBottom: '1px solid var(--border-subtle)',
            justifyContent: 'space-between',
          }}
        >
          <div>
            <div className="flex-row" style={{ gap: 8 }}>
              <strong style={{ fontSize: 15 }}>{activeInfo?.label || selectedTable}</strong>
              <span className="tag accent" style={{ fontFamily: 'var(--font-mono)' }}>{selectedTable}</span>
              <span className="tag">共 {totalRows} 条</span>
            </div>
            {activeInfo?.description && (
              <div className="muted-sm" style={{ marginTop: 4 }}>{activeInfo.description}</div>
            )}
          </div>

          <div className="flex-row">
            <form className="flex-row" style={{ gap: 6 }} onSubmit={handleSearchSubmit}>
              <div className="search-pill" style={{ width: 230, padding: '5px 11px' }}>
                <Search size={14} className="muted" />
                <input
                  type="search"
                  placeholder="筛选当前表字段..."
                  value={searchInput}
                  onChange={(e) => {
                    setSearchInput(e.target.value);
                    if (!e.target.value.trim() && activeQuery) {
                      setActiveQuery('');
                      setOffset(0);
                    }
                  }}
                />
              </div>
              <button type="submit" className="btn btn-sm">
                搜索
              </button>
            </form>

            <CustomSelect
              compact
              value={String(limit)}
              style={{ width: 106 }}
              onChange={(v) => {
                setLimit(Number(v));
                setOffset(0);
              }}
              options={[
                { value: '20', label: '20 条/页' },
                { value: '30', label: '30 条/页' },
                { value: '50', label: '50 条/页' },
                { value: '100', label: '100 条/页' },
              ]}
            />

            <button
              type="button"
              className="btn btn-sm"
              onClick={() => void Promise.all([reloadTables(), reloadRows()])}
              disabled={rowsFetching}
              title="刷新数据"
            >
              <RefreshCw size={14} className={rowsFetching ? 'spin' : ''} />
              刷新
            </button>

            {activeInfo?.clear_scope && (
              <button
                type="button"
                className="btn btn-danger btn-sm"
                onClick={() => void handleClearTable()}
              >
                <Trash2 size={14} />
                清空本表缓存
              </button>
            )}
          </div>
        </div>

        {showRowsSkeleton && rows.length === 0 ? (
          <TableSkeleton rows={8} />
        ) : rows.length === 0 ? (
          <div className="muted" style={{ textAlign: 'center', padding: 48 }}>
            {activeQuery ? `未在 ${selectedTable} 中找到匹配「${activeQuery}」的记录` : `${selectedTable} 当前为空`}
          </div>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table className={`data-table ${isStaleData ? 'stale-dim' : ''}`}>
              <thead>
                <tr>
                  {columns.map((col) => (
                    <th key={col} style={{ fontFamily: 'var(--font-mono)', whiteSpace: 'nowrap' }}>
                      {col}
                    </th>
                  ))}
                  {(activeInfo?.deletable || selectedTable === 'media_items') && (
                    <th style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>操作</th>
                  )}
                </tr>
              </thead>
              <tbody>
                {rows.map((row, idx) => {
                  const detailId =
                    selectedTable === 'media_items'
                      ? row.kind === 'episode' && row.show_id
                        ? Number(row.show_id)
                        : row.kind === 'movie' || row.kind === 'show'
                        ? Number(row.id)
                        : 0
                      : 0;
                  return (
                    <tr key={idx}>
                      {columns.map((col) => (
                        <td key={col}>{renderCellValue(col, row[col])}</td>
                      ))}
                      {(activeInfo?.deletable || selectedTable === 'media_items') && (
                        <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                          {detailId > 0 && (
                            <Link to={`/item/${detailId}`} className="btn btn-sm" style={{ padding: '3px 8px', fontSize: 12 }}>
                              <ExternalLink size={12} />
                              详情
                            </Link>
                          )}
                          {activeInfo?.deletable && (
                            <button
                              type="button"
                              className="btn btn-danger btn-sm"
                              style={{ padding: '3px 8px', fontSize: 12 }}
                              onClick={() => void handleDeleteRow(row)}
                            >
                              删除
                            </button>
                          )}
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {/* Pagination footer */}
        <div
          className="flex-row"
          style={{
            padding: '12px 16px',
            borderTop: '1px solid var(--border-subtle)',
            justifyContent: 'space-between',
          }}
        >
          <span className="muted-sm">
            第 {currentPage} / {totalPages} 页 · 共 {totalRows} 条记录
          </span>
          <div className="flex-row" style={{ gap: 6 }}>
            <button
              type="button"
              className="btn btn-sm"
              disabled={offset === 0}
              onClick={() => setOffset(0)}
            >
              首页
            </button>
            <button
              type="button"
              className="btn btn-sm"
              disabled={offset === 0}
              onClick={() => setOffset((o) => Math.max(0, o - limit))}
            >
              <ChevronLeft size={14} />
              上一页
            </button>
            <button
              type="button"
              className="btn btn-sm"
              disabled={offset + limit >= totalRows}
              onClick={() => setOffset((o) => o + limit)}
            >
              下一页
              <ChevronRight size={14} />
            </button>
            <button
              type="button"
              className="btn btn-sm"
              disabled={offset + limit >= totalRows}
              onClick={() => setOffset(Math.max(0, (totalPages - 1) * limit))}
            >
              末页
            </button>
          </div>
        </div>
      </div>

      {/* JSON Preview Modal */}
      {jsonPreview && (
        <ModalBackdrop subModal onClose={() => setJsonPreview(null)}>
          <div className="modal-panel" style={{ maxWidth: 820 }}>
            <div className="modal-header">
              <div className="flex-row">
                <h3>字段内容预览</h3>
                <span className="tag accent" style={{ fontFamily: 'var(--font-mono)' }}>{jsonPreview.col}</span>
              </div>
              <div className="flex-row">
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() => {
                    void navigator.clipboard.writeText(jsonPreview.formatted);
                    toast('已复制 JSON 内容', 'success');
                  }}
                >
                  <Copy size={13} />
                  复制 JSON
                </button>
                <button type="button" className="btn btn-icon btn-sm" onClick={() => setJsonPreview(null)}>
                  <X size={16} />
                </button>
              </div>
            </div>
            <div className="modal-body" style={{ padding: 16 }}>
              <pre
                style={{
                  margin: 0,
                  padding: 14,
                  borderRadius: 10,
                  background: 'rgba(5, 7, 11, 0.85)',
                  border: '1px solid var(--border-subtle)',
                  fontFamily: 'var(--font-mono)',
                  fontSize: 12,
                  lineHeight: 1.55,
                  color: '#d8e4ff',
                  overflow: 'auto',
                  maxHeight: '66vh',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                }}
              >
                {jsonPreview.formatted}
              </pre>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
