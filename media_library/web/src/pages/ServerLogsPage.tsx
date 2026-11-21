import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ArrowDown,
  Download,
  FileText,
  Loader2,
  Pause,
  Play,
  RefreshCw,
  ScrollText,
  Search,
  Trash2,
  X,
} from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { useApp } from '../contexts/AppContext';
import type { ServerLogEntry } from '../types';

function formatLogTime(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, l = 2) => String(n).padStart(l, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function levelBadgeStyle(level: string): React.CSSProperties {
  switch (level.toUpperCase()) {
    case 'ERROR':
      return {
        color: 'var(--danger)',
        background: 'rgba(255, 107, 114, 0.16)',
        border: '1px solid rgba(255, 107, 114, 0.34)',
      };
    case 'WARN':
      return {
        color: 'var(--warning)',
        background: 'rgba(245, 185, 66, 0.16)',
        border: '1px solid rgba(245, 185, 66, 0.34)',
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
  const [level, setLevel] = useState('INFO');
  const [component, setComponent] = useState('');
  const [keywordInput, setKeywordInput] = useState('');
  const [activeKeyword, setActiveKeyword] = useState('');
  const [live, setLive] = useState(true);
  const [loading, setLoading] = useState(true);

  const [entries, setEntries] = useState<ServerLogEntry[]>([]);
  const [filePath, setFilePath] = useState('');
  const [fileSize, setFileSize] = useState(0);

  const [clearModalOpen, setClearModalOpen] = useState(false);
  const [clearing, setClearing] = useState(false);

  const latestSeqRef = useRef(0);
  const terminalRef = useRef<HTMLDivElement | null>(null);

  const scrollToBottom = useCallback(() => {
    const el = terminalRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, []);

  const loadFull = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.getLogs({
        limit: 400,
        level,
        component: component.trim() || undefined,
        q: activeKeyword || undefined,
      });
      setEntries(res.entries || []);
      latestSeqRef.current = res.latest_seq || 0;
      setFilePath(res.log_file_path || '');
      setFileSize(res.file_size_bytes || 0);
      window.requestAnimationFrame(() => scrollToBottom());
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [activeKeyword, component, level, scrollToBottom, toast]);

  useEffect(() => {
    latestSeqRef.current = 0;
    void loadFull();
  }, [loadFull]);

  useEffect(() => {
    if (!live) return;
    let cancelled = false;
    const timer = window.setInterval(async () => {
      try {
        const res = await api.getLogs({
          after_seq: latestSeqRef.current,
          limit: 200,
          level,
          component: component.trim() || undefined,
          q: activeKeyword || undefined,
        });
        if (cancelled) return;
        latestSeqRef.current = Math.max(latestSeqRef.current, res.latest_seq || 0);
        if (res.log_file_path) setFilePath(res.log_file_path);
        setFileSize(res.file_size_bytes || 0);
        const incoming = res.entries || [];
        if (incoming.length > 0) {
          const el = terminalRef.current;
          const nearBottom = !el || el.scrollHeight - el.scrollTop - el.clientHeight < 72;
          setEntries((prev) => {
            const seen = new Set(prev.map((p) => p.seq));
            const merged = [...prev];
            for (const item of incoming) {
              if (!seen.has(item.seq)) merged.push(item);
            }
            return merged.slice(-800);
          });
          if (nearBottom) {
            window.requestAnimationFrame(() => scrollToBottom());
          }
        }
      } catch {
        // ignore transient poll errors
      }
    }, 3000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [activeKeyword, component, level, live, scrollToBottom]);

  const handleDownload = async () => {
    try {
      const blob = await api.downloadLogsBlob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'media-library.log';
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleClear = async (truncateFile: boolean) => {
    if (clearing) return;
    setClearing(true);
    try {
      await api.clearLogs(truncateFile);
      toast(truncateFile ? '已清空内存与磁盘日志文件' : '已清理内存日志缓冲区', 'success');
      setClearModalOpen(false);
      await loadFull();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setClearing(false);
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">系统运行日志</h1>
          <div className="flex-row" style={{ marginTop: 6, gap: 10 }}>
            <span className="tag">
              <FileText size={12} />
              文件大小：{formatBytes(fileSize)}
            </span>
            {filePath && (
              <span className="muted-sm" style={{ fontFamily: 'var(--font-mono)' }}>
                {filePath}
              </span>
            )}
          </div>
        </div>

        <div className="flex-row" style={{ gap: 8 }}>
          <button
            type="button"
            className={`btn btn-sm ${live ? 'btn-primary' : ''}`}
            onClick={() => setLive((v) => !v)}
          >
            {live ? (
              <>
                <Pause size={13} /> 实时追踪中
              </>
            ) : (
              <>
                <Play size={13} /> 开启实时追踪
              </>
            )}
          </button>
          <button type="button" className="btn btn-sm" onClick={() => void loadFull()} disabled={loading}>
            <RefreshCw size={13} className={loading ? 'spin' : ''} /> 刷新
          </button>
          <button type="button" className="btn btn-sm" onClick={() => void handleDownload()}>
            <Download size={13} /> 导出日志
          </button>
          <button type="button" className="btn btn-danger btn-sm" onClick={() => setClearModalOpen(true)}>
            <Trash2 size={13} /> 清理
          </button>
        </div>
      </div>

      {/* Filter Bar */}
      <div className="card-box" style={{ padding: 14 }}>
        <div className="flex-row" style={{ justifyContent: 'space-between', gap: 12 }}>
          <div className="flex-row" style={{ gap: 6 }}>
            <span className="muted-sm" style={{ marginRight: 4 }}>
              日志级别：
            </span>
            {['DEBUG', 'INFO', 'WARN', 'ERROR'].map((lv) => (
              <button
                key={lv}
                type="button"
                className={`chip ${level === lv ? 'active' : ''}`}
                onClick={() => setLevel(lv)}
              >
                {lv}
              </button>
            ))}
          </div>

          <div className="flex-row" style={{ gap: 8, flex: 1, justifyContent: 'flex-end' }}>
            <input
              className="input"
              style={{ width: 150, padding: '6px 10px', fontSize: 13 }}
              placeholder="模块名（如 identify）"
              value={component}
              onChange={(e) => setComponent(e.target.value)}
            />
            <form
              className="search-pill"
              style={{ maxWidth: 280, padding: '5px 12px' }}
              onSubmit={(e) => {
                e.preventDefault();
                setActiveKeyword(keywordInput.trim());
              }}
            >
              <Search size={14} className="muted" />
              <input
                type="search"
                style={{ fontSize: 13 }}
                placeholder="过滤关键字并回车..."
                value={keywordInput}
                onChange={(e) => setKeywordInput(e.target.value)}
              />
            </form>
          </div>
        </div>
      </div>

      {/* Log Terminal */}
      <div style={{ position: 'relative' }}>
        <div className="log-terminal" ref={terminalRef}>
          {entries.length === 0 ? (
            <div className="empty-state" style={{ height: '100%' }}>
              <ScrollText size={28} />
              <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>暂无匹配的运行日志</div>
              <div className="muted-sm">可尝试调低级别至 DEBUG 或清空过滤关键词</div>
            </div>
          ) : (
            entries.map((e) => (
              <div key={e.seq} className="log-line">
                <span className="muted-sm" style={{ fontVariantNumeric: 'tabular-nums' }}>
                  {formatLogTime(e.time_ms)}
                </span>
                <span>
                  <span className="log-level-pill" style={levelBadgeStyle(e.level)}>
                    {e.level}
                  </span>
                </span>
                <span
                  className="log-comp"
                  style={{
                    color: 'var(--text-secondary)',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                  title={e.component}
                >
                  [{e.component || 'server'}]
                </span>
                <span style={{ color: 'var(--text-primary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                  {e.message}
                </span>
              </div>
            ))
          )}
        </div>

        {entries.length > 10 && (
          <button
            type="button"
            className="btn btn-sm"
            style={{ position: 'absolute', right: 18, bottom: 16, backdropFilter: 'var(--blur-md)' }}
            onClick={scrollToBottom}
            title="滚动到最新日志"
          >
            <ArrowDown size={13} /> 最新
          </button>
        )}
      </div>

      {/* Clear Modal */}
      {clearModalOpen && (
        <ModalBackdrop onClose={() => !clearing && setClearModalOpen(false)}>
          <div className="modal-panel" style={{ maxWidth: 440 }}>
            <div className="modal-header">
              <h3>清理运行日志</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setClearModalOpen(false)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                请选择清理范围：仅清空内存实时流缓冲区，或同时截断磁盘上的历史日志文件。
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setClearModalOpen(false)} disabled={clearing}>
                取消
              </button>
              <button type="button" className="btn" disabled={clearing} onClick={() => void handleClear(false)}>
                {clearing && <Loader2 size={14} className="spin" />}
                仅清内存
              </button>
              <button type="button" className="btn btn-danger" disabled={clearing} onClick={() => void handleClear(true)}>
                {clearing ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
                清空内存与磁盘
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
