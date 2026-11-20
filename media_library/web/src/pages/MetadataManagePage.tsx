import React, { useCallback, useEffect, useState } from 'react';
import { RefreshCw, Search, Trash2 } from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { ImageCacheSummary, InspectTableInfo } from '../types';

export const MetadataManagePage: React.FC = () => {
  const { toast } = useApp();
  const [tables, setTables] = useState<InspectTableInfo[]>([]);
  const [imgCache, setImgCache] = useState<ImageCacheSummary>({ files: 0, bytes: 0 });
  const [selected, setSelected] = useState('');
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [total, setTotal] = useState(0);

  const loadRows = useCallback(async (table: string, query: string) => {
    if (!table) return;
    try {
      const res = await api.queryMetadataTable(table, query, 50, 0);
      setRows(res.rows || []);
      setTotal(res.total || 0);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [toast]);

  const loadTables = useCallback(async () => {
    try {
      const res = await api.listMetadataTables();
      setTables(res.tables || []);
      setImgCache(res.image_cache || { files: 0, bytes: 0 });
      const target = selected && res.tables.some((t) => t.name === selected)
        ? selected
        : res.tables[0]?.name || '';
      setSelected(target);
      if (target) {
        await loadRows(target, q);
      }
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [loadRows, q, selected, toast]);

  useEffect(() => {
    void loadTables();
  }, [loadTables]);

  const activeTable = tables.find((t) => t.name === selected);

  const clearAll = async () => {
    if (!window.confirm('确认清空全部公共元数据缓存？')) return;
    try {
      const res = await api.clearMetaCache('all');
      toast(`已清理 ${res.deleted} 条缓存记录`, 'success');
      await loadTables();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

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
      toast('已删除缓存行', 'success');
      await loadRows(activeTable.name, q);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18, maxWidth: 1180 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 22 }}>公共元数据缓存管理</h1>
          <p className="muted" style={{ margin: '4px 0 0', fontSize: 13 }}>
            图片缓存：{imgCache.files} 个文件（{formatBytes(imgCache.bytes)}）
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button type="button" className="btn" onClick={() => void loadTables()}>
            <RefreshCw size={14} /> 刷新
          </button>
          <button type="button" className="btn" style={{ color: 'var(--danger)' }} onClick={() => void clearAll()}>
            <Trash2 size={14} /> 清空全部缓存
          </button>
        </div>
      </div>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {tables.map((t) => (
          <button
            key={t.name}
            type="button"
            className={`btn ${selected === t.name ? 'btn-primary' : ''}`}
            onClick={() => {
              setSelected(t.name);
              void loadRows(t.name, q);
            }}
          >
            {t.label} ({t.row_count})
          </button>
        ))}
      </div>

      <div style={{ display: 'flex', gap: 8, maxWidth: 480 }}>
        <input
          className="input"
          placeholder="搜索表内记录..."
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && void loadRows(selected, q)}
          style={{ flex: 1 }}
        />
        <button type="button" className="btn" onClick={() => void loadRows(selected, q)}>
          <Search size={14} /> 搜索
        </button>
      </div>

      <div className="panel" style={{ padding: 16 }}>
        <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
          共 {total} 条记录（展示前 {rows.length} 条）
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {rows.map((row, idx) => {
            const summary = Object.entries(row)
              .filter(([k, v]) => k !== 'payload_json' && v !== null && v !== undefined && String(v) !== '')
              .slice(0, 6)
              .map(([k, v]) => `${k}=${String(v)}`)
              .join(' · ');
            return (
              <div
                key={idx}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: 10,
                  padding: '8px 10px',
                  borderBottom: '1px solid var(--border-subtle)',
                  fontSize: 13,
                }}
              >
                <span style={{ fontFamily: 'var(--font-mono)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {summary}
                </span>
                {activeTable?.deletable && (
                  <button type="button" className="btn" onClick={() => void deleteRow(row)}>
                    <Trash2 size={13} />
                  </button>
                )}
              </div>
            );
          })}
          {rows.length === 0 && <div className="muted" style={{ padding: 16, textAlign: 'center' }}>暂无缓存记录</div>}
        </div>
      </div>
    </div>
  );
};
