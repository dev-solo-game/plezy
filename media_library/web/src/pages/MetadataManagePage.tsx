import React, { useCallback, useEffect, useState } from 'react';
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  Database,
  HardDrive,
  Loader2,
  RefreshCw,
  Search,
  Trash2,
  X,
} from 'lucide-react';
import { api, formatBytes, formatDateTime } from '../api/client';
import { CustomSelect } from '../components/CustomSelect';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ImageCacheSummary, InspectTableInfo } from '../types';

const PAGE_SIZE_OPTIONS = [
  { value: 20, label: '20 条 / 页' },
  { value: 50, label: '50 条 / 页' },
  { value: 100, label: '100 条 / 页' },
];

export const MetadataManagePage: React.FC = () => {
  const { toast } = useApp();
  const [tables, setTables] = useState<InspectTableInfo[]>([]);
  const [imgCache, setImgCache] = useState<ImageCacheSummary>({ files: 0, bytes: 0 });
  const [selected, setSelected] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [activeQuery, setActiveQuery] = useState('');
  const [limit, setLimit] = useState(30);
  const [offset, setOffset] = useState(0);
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);

  const [jsonModal, setJsonModal] = useState<{ title: string; content: string } | null>(null);
  const [clearModalOpen, setClearModalOpen] = useState(false);
  const [clearing, setClearing] = useState(false);

  const loadRows = useCallback(
    async (table: string, query: string, pageLimit: number, pageOffset: number) => {
      if (!table) return;
      setLoading(true);
      try {
        const res = await api.queryMetadataTable(table, query, pageLimit, pageOffset);
        setRows(res.rows || []);
        setTotal(res.total || 0);
      } catch (err) {
        toast((err as Error).message, 'error');
      } finally {
        setLoading(false);
      }
    },
    [toast]
  );

  const loadTables = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listMetadataTables();
      setTables(res.tables || []);
      setImgCache(res.image_cache || { files: 0, bytes: 0 });
      const target =
        selected && res.tables.some((t) => t.name === selected)
          ? selected
          : res.tables[0]?.name || '';
      setSelected(target);
      if (target) {
        await loadRows(target, activeQuery, limit, offset);
      } else {
        setLoading(false);
      }
    } catch (err) {
      toast((err as Error).message, 'error');
      setLoading(false);
    }
  }, [activeQuery, limit, loadRows, offset, selected, toast]);

  useEffect(() => {
    void loadTables();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleSelectTable = (name: string) => {
    setSelected(name);
    setSearchInput('');
    setActiveQuery('');
    setOffset(0);
    void loadRows(name, '', limit, 0);
  };

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = searchInput.trim();
    setActiveQuery(trimmed);
    setOffset(0);
    void loadRows(selected, trimmed, limit, 0);
  };

  const handlePageSize = (nextLimit: number) => {
    setLimit(nextLimit);
    setOffset(0);
    void loadRows(selected, activeQuery, nextLimit, 0);
  };

  const handleClearAll = async () => {
    if (clearing) return;
    setClearing(true);
    try {
      const res = await api.clearMetaCache('all');
      toast(`已清理 ${res.deleted} 条公共元数据缓存记录`, 'success');
      setClearModalOpen(false);
      setOffset(0);
      await loadTables();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setClearing(false);
    }
  };

  const activeTable = tables.find((t) => t.name === selected) || null;

  const deleteRow = async (row: Record<string, unknown>) => {
    if (!activeTable || !activeTable.pk_cols?.length) return;
    const pk: Record<string, string> = {};
    for (const col of activeTable.pk_cols) {
      if (row[col] !== undefined && row[col] !== null) {
        pk[col] = String(row[col]);
      }
    }
    try {
      await api.deleteMetadataRow(activeTable.name, pk);
      toast('已删除该条缓存记录', 'success');
      await loadTables();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const openJson = (col: string, raw: unknown) => {
    const str = typeof raw === 'string' ? raw : JSON.stringify(raw ?? '');
    let formatted = str;
    try {
      formatted = JSON.stringify(JSON.parse(str), null, 2);
    } catch {
      // keep raw
    }
    setJsonModal({ title: `${activeTable?.label || selected} · ${col}`, content: formatted });
  };

  const visibleCols = (activeTable?.columns || (rows[0] ? Object.keys(rows[0]) : [])).slice(0, 7);
  const totalPages = Math.max(1, Math.ceil(total / limit));
  const currentPage = Math.floor(offset / limit) + 1;

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">公共元数据缓存管理</h1>
          <p className="page-subtitle">
            查看与维护服务端跨用户共享的 TMDB / 辅助数据源缓存表与本地代理海报缓存。
          </p>
        </div>

        <div className="flex-row" style={{ gap: 8 }}>
          <span className="tag accent" style={{ padding: '6px 12px', fontSize: 12 }}>
            <HardDrive size={13} />
            海报缓存：{imgCache.files} 张 · {formatBytes(imgCache.bytes)}
          </span>
          <button type="button" className="btn" onClick={() => void loadTables()} disabled={loading}>
            <RefreshCw size={15} className={loading ? 'spin' : ''} />
            刷新
          </button>
          <button type="button" className="btn btn-danger" onClick={() => setClearModalOpen(true)}>
            <Trash2 size={15} />
            清空全部缓存
          </button>
        </div>
      </div>

      {/* Table Selector Cards */}
      <div className="meta-table-grid">
        {tables.map((t) => (
          <button
            key={t.name}
            type="button"
            className={`meta-table-card ${selected === t.name ? 'active' : ''}`}
            onClick={() => handleSelectTable(t.name)}
          >
            <div className="flex-row" style={{ justifyContent: 'space-between', width: '100%' }}>
              <span style={{ fontWeight: 600, fontSize: 13.5 }}>{t.label}</span>
              <span className={`tag ${selected === t.name ? 'accent' : ''}`}>{(t.row_count ?? 0).toLocaleString()}</span>
            </div>
            <div className="muted-sm" style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
              {t.name}
            </div>
            {t.description && (
              <div className="muted-sm" style={{ lineHeight: 1.4 }}>
                {t.description}
              </div>
            )}
          </button>
        ))}
      </div>

      {/* Search & Pagination Toolbar + Table */}
      <div className="card-box" style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div className="flex-row" style={{ justifyContent: 'space-between', gap: 12 }}>
          <form className="search-pill" style={{ maxWidth: 420 }} onSubmit={handleSearch}>
            <Search size={15} className="muted" />
            <input
              type="search"
              placeholder={`在「${activeTable?.label || '当前表'}」中检索标题、ID 或关键字...`}
              value={searchInput}
              onChange={(e) => setSearchInput(e.target.value)}
            />
          </form>

          <div className="flex-row" style={{ gap: 8 }}>
            <span className="muted-sm">共 {(total ?? 0).toLocaleString()} 条</span>
            <CustomSelect
              compact
              value={limit === 30 ? 50 : limit}
              onChange={handlePageSize}
              options={PAGE_SIZE_OPTIONS}
              style={{ width: 116 }}
            />
          </div>
        </div>

        {loading && rows.length === 0 ? (
          <TableSkeleton rows={6} />
        ) : rows.length === 0 ? (
          <div className="empty-state">
            <Database size={28} />
            <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>当前缓存表暂无匹配记录</div>
            <div className="muted-sm">客户端触发识别或搜索后，公共元数据将自动沉淀到此缓存表</div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  {visibleCols.map((col) => (
                    <th key={col}>{col}</th>
                  ))}
                  {activeTable?.deletable && <th style={{ textAlign: 'right' }}>操作</th>}
                </tr>
              </thead>
              <tbody>
                {rows.map((row, idx) => (
                  <tr key={idx}>
                    {visibleCols.map((col) => {
                      const val = row[col];
                      if (val === null || val === undefined || val === '') {
                        return (
                          <td key={col}>
                            <span className="muted-sm">-</span>
                          </td>
                        );
                      }
                      if (col.endsWith('_json') || col === 'payload_json' || col === 'data_json') {
                        return (
                          <td key={col}>
                            <button
                              type="button"
                              className="code-pill"
                              style={{ fontSize: 11.5, padding: '2px 8px' }}
                              onClick={() => openJson(col, val)}
                            >
                              查看 JSON
                            </button>
                          </td>
                        );
                      }
                      if ((col.endsWith('_at') || col.endsWith('_ms')) && typeof val === 'number' && val > 1000000000000) {
                        return <td key={col}>{formatDateTime(val)}</td>;
                      }
                      const text = String(val);
                      return (
                        <td
                          key={col}
                          title={text}
                          style={{
                            maxWidth: 260,
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            whiteSpace: 'nowrap',
                          }}
                        >
                          {text}
                        </td>
                      );
                    })}
                    {activeTable?.deletable && (
                      <td style={{ textAlign: 'right' }}>
                        <button
                          type="button"
                          className="btn btn-danger btn-sm"
                          title="删除该条缓存"
                          onClick={() => void deleteRow(row)}
                        >
                          <Trash2 size={13} />
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {/* Pagination */}
        {total > limit && (
          <div className="flex-row" style={{ justifyContent: 'space-between', paddingTop: 4 }}>
            <span className="muted-sm">
              第 {currentPage} / {totalPages} 页
            </span>
            <div className="flex-row" style={{ gap: 6 }}>
              <button
                type="button"
                className="btn btn-sm"
                disabled={offset <= 0 || loading}
                onClick={() => {
                  const next = Math.max(0, offset - limit);
                  setOffset(next);
                  void loadRows(selected, activeQuery, limit, next);
                }}
              >
                <ChevronLeft size={14} /> 上一页
              </button>
              <button
                type="button"
                className="btn btn-sm"
                disabled={offset + limit >= total || loading}
                onClick={() => {
                  const next = offset + limit;
                  setOffset(next);
                  void loadRows(selected, activeQuery, limit, next);
                }}
              >
                下一页 <ChevronRight size={14} />
              </button>
            </div>
          </div>
        )}
      </div>

      {/* JSON Preview Modal */}
      {jsonModal && (
        <ModalBackdrop onClose={() => setJsonModal(null)}>
          <div className="modal-panel" style={{ maxWidth: 740 }}>
            <div className="modal-header">
              <h3>{jsonModal.title}</h3>
              <div className="flex-row" style={{ gap: 6 }}>
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() =>
                    void navigator.clipboard
                      .writeText(jsonModal.content)
                      .then(() => toast('已复制 JSON 内容', 'success'))
                  }
                >
                  <Copy size={13} /> 复制
                </button>
                <button type="button" className="btn btn-icon btn-sm" onClick={() => setJsonModal(null)}>
                  <X size={15} />
                </button>
              </div>
            </div>
            <div className="modal-body">
              <pre className="json-pre">{jsonModal.content}</pre>
            </div>
          </div>
        </ModalBackdrop>
      )}

      {/* Clear All Confirm Modal */}
      {clearModalOpen && (
        <ModalBackdrop onClose={() => !clearing && setClearModalOpen(false)}>
          <div className="modal-panel" style={{ maxWidth: 440 }}>
            <div className="modal-header">
              <h3>确认清空公共元数据缓存</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setClearModalOpen(false)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                该操作将清空作品、季集、演职员与搜索公共缓存（不影响任何用户的片库文件与观看进度），后续识别请求会重新从 TMDB / 辅助数据源拉取最新资料。
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setClearModalOpen(false)} disabled={clearing}>
                取消
              </button>
              <button type="button" className="btn btn-danger" disabled={clearing} onClick={() => void handleClearAll()}>
                {clearing ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
                确认清空
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
