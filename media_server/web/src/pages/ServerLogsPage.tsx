import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import {
  ArrowDown,
  Download,
  FileText,
  Pause,
  Play,
  RefreshCw,
  ScrollText,
  Search,
  Trash2,
  X,
} from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { CustomSelect } from '../components/CustomSelect';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { useApp } from '../contexts/AppContext';
import type { ServerLogEntry } from '../types';

function formatLogTime(ms: number): string {
  const d = new Date(ms);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  const mmm = String(d.getMilliseconds()).padStart(3, '0');
  return `${hh}:${mm}:${ss}.${mmm}`;
}

function levelBadgeStyle(level: string): React.CSSProperties {
  switch (level.toUpperCase()) {
    case 'ERROR':
      return {
        color: 'var(--danger)',
        background: 'rgba(255, 107, 114, 0.16)',
        border: '1px solid rgba(255, 107, 114, 0.32)',
      };
    case 'WARN':
      return {
        color: 'var(--warning)',
        background: 'rgba(245, 185, 66, 0.16)',
        border: '1px solid rgba(245, 185, 66, 0.32)',
      };
    case 'INFO':
      return {
        color: 'var(--accent)',
        background: 'var(--accent-soft)',
        border: '1px solid var(--accent-border)',
      };
    default:
      return {
        color: 'var(--text-muted)',
        background: 'rgba(255, 255, 255, 0.06)',
        border: '1px solid rgba(255, 255, 255, 0.12)',
      };
  }
}

export const ServerLogsPage: React.FC = () => {
  const { toast } = useApp();
  const [searchParams, setSearchParams] = useSearchParams();
  const initialComp = searchParams.get('component') || '';

  const [component, setComponent] = useState<string>(initialComp === 'all' ? '' : initialComp);
  const [level, setLevel] = useState<string>('DEBUG');
  const [keywordInput, setKeywordInput] = useState('');
  const [activeKeyword, setActiveKeyword] = useState('');
  const [liveTail, setLiveTail] = useState(true);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const [entries, setEntries] = useState<ServerLogEntry[]>([]);
  const [logFilePath, setLogFilePath] = useState('');
  const [fileSizeBytes, setFileSizeBytes] = useState(0);
  const [clearModalOpen, setClearModalOpen] = useState(false);
  const [clearing, setClearing] = useState(false);

  const latestSeqRef = useRef(0);
  const listRef = useRef<HTMLDivElement | null>(null);
  const stickToBottomRef = useRef(true);

  const scrollToBottom = useCallback(() => {
    const el = listRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
    stickToBottomRef.current = true;
  }, []);

  const loadFull = useCallback(async () => {
    setRefreshing(true);
    try {
      const res = await api.getSystemLogs({
        limit: 500,
        level,
        component: component || undefined,
        q: activeKeyword || undefined,
      });
      setEntries(res.entries || []);
      latestSeqRef.current = res.latest_seq || 0;
      setLogFilePath(res.log_file_path || '');
      setFileSizeBytes(res.file_size_bytes || 0);
      window.requestAnimationFrame(() => scrollToBottom());
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [level, component, activeKeyword, toast, scrollToBottom]);

  useEffect(() => {
    latestSeqRef.current = 0;
    void loadFull();
  }, [loadFull]);

  useEffect(() => {
    if (!liveTail) return;
    let cancelled = false;
    const timer = window.setInterval(async () => {
      try {
        const res = await api.getSystemLogs({
          after_seq: latestSeqRef.current,
          limit: 300,
          level,
          component: component || undefined,
          q: activeKeyword || undefined,
        });
        if (cancelled) return;
        latestSeqRef.current = Math.max(latestSeqRef.current, res.latest_seq || 0);
        if (res.log_file_path) setLogFilePath(res.log_file_path);
        setFileSizeBytes(res.file_size_bytes || 0);
        const incoming = res.entries || [];
        if (incoming.length > 0) {
          const el = listRef.current;
          const wasNearBottom =
            !el || el.scrollHeight - el.scrollTop - el.clientHeight < 64 || stickToBottomRef.current;
          setEntries((prev) => {
            const seen = new Set(prev.map((p) => p.seq));
            const merged = [...prev];
            for (const item of incoming) {
              if (!seen.has(item.seq)) merged.push(item);
            }
            return merged.length > 1500 ? merged.slice(merged.length - 1500) : merged;
          });
          if (wasNearBottom) {
            window.requestAnimationFrame(() => scrollToBottom());
          }
        }
      } catch {
        // ignore transient polling error
      }
    }, 2000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [liveTail, level, component, activeKeyword, scrollToBottom]);

  const handleComponentChange = (val: string) => {
    setComponent(val);
    const next = new URLSearchParams(searchParams);
    if (val) {
      next.set('component', val);
    } else {
      next.delete('component');
    }
    setSearchParams(next, { replace: true });
  };

  const handleKeywordSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setActiveKeyword(keywordInput.trim());
  };

  const handleClear = async (truncateFile: boolean) => {
    setClearing(true);
    try {
      await api.clearSystemLogs(truncateFile);
      toast(truncateFile ? '已清空内存与磁盘日志文件' : '已清空当前视图日志缓冲', 'success');
      setClearModalOpen(false);
      latestSeqRef.current = 0;
      await loadFull();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setClearing(false);
    }
  };

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <div>
          <h2 className="section-title">
            <ScrollText size={20} style={{ color: 'var(--accent)' }} />
            服务端运行日志
            <span className="tag">{entries.length} 条</span>
          </h2>
          {logFilePath && (
            <div className="muted-sm" style={{ marginTop: 4, display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
              <FileText size={13} />
              <span>磁盘日志文件：</span>
              <code style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}>{logFilePath}</code>
              <span className="tag">{formatBytes(fileSizeBytes)}</span>
            </div>
          )}
        </div>

        <div className="flex-row">
          <button
            type="button"
            className={`btn btn-sm ${liveTail ? 'btn-primary' : ''}`}
            onClick={() => setLiveTail((v) => !v)}
            title="开启后每 2 秒自动拉取新增日志"
          >
            {liveTail ? <Pause size={14} /> : <Play size={14} />}
            {liveTail ? '实时跟随中' : '已暂停跟随'}
          </button>

          <button type="button" className="btn btn-sm" onClick={() => void loadFull()} disabled={refreshing}>
            <RefreshCw size={14} className={refreshing ? 'spin' : ''} />
            刷新
          </button>

          <a href={api.systemLogsDownloadUrl()} download="ttplay-server.log" className="btn btn-sm">
            <Download size={14} />
            下载日志
          </a>

          <button type="button" className="btn btn-danger btn-sm" onClick={() => setClearModalOpen(true)}>
            <Trash2 size={14} />
            清空日志
          </button>
        </div>
      </div>

      {/* Filters toolbar */}
      <div
        className="card-box flex-row"
        style={{ padding: 12, marginBottom: 14, justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}
      >
        <div className="flex-row" style={{ flexWrap: 'wrap', gap: 8 }}>
          <CustomSelect
            compact
            value={component}
            onChange={handleComponentChange}
            style={{ width: 175 }}
            options={[
              { value: '', label: '全部模块' },
              { value: 'scraper', label: '刮削匹配 (scraper)' },
              { value: 'metadata', label: '元数据请求 (metadata)' },
              { value: 'scanner', label: '目录扫描 (scanner)' },
              { value: 'api', label: 'HTTP 接口 (api)' },
              { value: 'system', label: '系统核心 (system)' },
            ]}
          />

          <CustomSelect
            compact
            value={level}
            onChange={setLevel}
            style={{ width: 170 }}
            options={[
              { value: 'DEBUG', label: '全部级别 (含 DEBUG)' },
              { value: 'INFO', label: 'INFO 及以上' },
              { value: 'WARN', label: 'WARN 及以上' },
              { value: 'ONLY_ERROR', label: '仅 ERROR' },
            ]}
          />
        </div>

        <form onSubmit={handleKeywordSubmit} className="flex-row" style={{ flex: 1, minWidth: 240, maxWidth: 420 }}>
          <div style={{ position: 'relative', flex: 1 }}>
            <input
              className="input"
              style={{ width: '100%', paddingLeft: 32, height: 34, fontSize: 13 }}
              placeholder="搜索片名、TMDB ID、候选得分、错误原因..."
              value={keywordInput}
              onChange={(e) => setKeywordInput(e.target.value)}
            />
            <Search
              size={14}
              className="muted"
              style={{ position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }}
            />
          </div>
          <button type="submit" className="btn btn-sm">
            过滤
          </button>
          {(activeKeyword || keywordInput) && (
            <button
              type="button"
              className="btn btn-sm"
              onClick={() => {
                setKeywordInput('');
                setActiveKeyword('');
              }}
            >
              清除
            </button>
          )}
        </form>
      </div>

      {/* Log lines container */}
      <div className="card-box" style={{ padding: 0, overflow: 'hidden', position: 'relative' }}>
        <div
          ref={listRef}
          onScroll={() => {
            const el = listRef.current;
            if (!el) return;
            stickToBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 64;
          }}
          style={{
            background: 'rgba(8, 10, 15, 0.72)',
            padding: '10px 14px',
            minHeight: 420,
            maxHeight: 'calc(100vh - 280px)',
            overflowY: 'auto',
            fontFamily: 'var(--font-mono)',
            fontSize: 12.5,
            lineHeight: 1.6,
          }}
        >
          {loading ? (
            <div className="muted-sm" style={{ padding: '32px 0', textAlign: 'center' }}>
              正在加载运行日志...
            </div>
          ) : entries.length === 0 ? (
            <div className="muted-sm" style={{ padding: '48px 0', textAlign: 'center' }}>
              当前过滤条件下暂无日志记录，触发一次扫描或刮削后将实时显示在这里。
            </div>
          ) : (
            entries.map((entry) => (
              <div
                key={entry.seq}
                style={{
                  display: 'flex',
                  alignItems: 'flex-start',
                  gap: 8,
                  padding: '3px 4px',
                  borderBottom: '1px solid rgba(255, 255, 255, 0.04)',
                }}
              >
                <span className="muted-sm" style={{ flexShrink: 0, userSelect: 'none', minWidth: 86 }}>
                  {formatLogTime(entry.time_ms)}
                </span>
                <span
                  style={{
                    ...levelBadgeStyle(entry.level),
                    flexShrink: 0,
                    fontSize: 10.5,
                    fontWeight: 700,
                    padding: '0 6px',
                    borderRadius: 5,
                    lineHeight: '19px',
                    minWidth: 48,
                    textAlign: 'center',
                    userSelect: 'none',
                  }}
                >
                  {entry.level}
                </span>
                <span
                  style={{
                    flexShrink: 0,
                    fontSize: 11,
                    color: 'var(--text-secondary)',
                    background: 'rgba(255, 255, 255, 0.06)',
                    padding: '0 6px',
                    borderRadius: 5,
                    lineHeight: '19px',
                    minWidth: 74,
                    textAlign: 'center',
                  }}
                >
                  {entry.component}
                </span>
                <span
                  style={{
                    color:
                      entry.level === 'ERROR'
                        ? 'var(--danger)'
                        : entry.level === 'WARN'
                        ? '#ffd98a'
                        : 'var(--text-primary)',
                    wordBreak: 'break-word',
                    whiteSpace: 'pre-wrap',
                    flex: 1,
                  }}
                >
                  {entry.message}
                </span>
              </div>
            ))
          )}
        </div>

        {entries.length > 15 && (
          <button
            type="button"
            className="btn btn-sm"
            onClick={scrollToBottom}
            title="滚动到最新一行"
            style={{
              position: 'absolute',
              right: 16,
              bottom: 14,
              background: 'var(--surface-glass-strong)',
              backdropFilter: 'var(--blur-md)',
              border: '1px solid var(--border-glass)',
            }}
          >
            <ArrowDown size={13} />
            最新
          </button>
        )}
      </div>

      {clearModalOpen && (
        <ModalBackdrop onClose={() => !clearing && setClearModalOpen(false)}>
          <div className="modal-panel" style={{ maxWidth: 460 }}>
            <div className="modal-header">
              <h3>清理服务端日志</h3>
              <button
                type="button"
                className="btn btn-icon btn-sm"
                disabled={clearing}
                onClick={() => setClearModalOpen(false)}
              >
                <X size={16} />
              </button>
            </div>
            <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div className="muted-sm">
                你可以只清空 Web 页面内存环形缓冲区，或者连同磁盘上的日志文件一并截断清理。
              </div>
              <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 8 }}>
                <button type="button" className="btn btn-sm" disabled={clearing} onClick={() => setClearModalOpen(false)}>
                  取消
                </button>
                <button type="button" className="btn btn-sm" disabled={clearing} onClick={() => void handleClear(false)}>
                  仅清内存视图
                </button>
                <button
                  type="button"
                  className="btn btn-danger btn-sm"
                  disabled={clearing}
                  onClick={() => void handleClear(true)}
                >
                  同时清空磁盘日志
                </button>
              </div>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
