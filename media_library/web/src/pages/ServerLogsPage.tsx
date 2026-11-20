import React, { useCallback, useEffect, useState } from 'react';
import { Download, Pause, Play, RefreshCw, Trash2 } from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { ServerLogEntry } from '../types';

function formatLogTime(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, l = 2) => String(n).padStart(l, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

export const ServerLogsPage: React.FC = () => {
  const { toast } = useApp();
  const [level, setLevel] = useState('INFO');
  const [q, setQ] = useState('');
  const [live, setLive] = useState(false);
  const [entries, setEntries] = useState<ServerLogEntry[]>([]);
  const [fileSize, setFileSize] = useState(0);

  const load = useCallback(async () => {
    try {
      const res = await api.getLogs({ limit: 300, level, q: q.trim() || undefined });
      setEntries((res.entries || []).slice().reverse());
      setFileSize(res.file_size_bytes || 0);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [level, q, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (!live) return;
    const id = window.setInterval(() => void load(), 3000);
    return () => window.clearInterval(id);
  }, [live, load]);

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

  const handleClear = async () => {
    if (!window.confirm('确认清理系统内存运行日志？')) return;
    try {
      await api.clearLogs(false);
      toast('日志已清理', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 1180 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 22 }}>系统运行日志</h1>
          <p className="muted" style={{ margin: '4px 0 0', fontSize: 12 }}>日志文件体积：{formatBytes(fileSize)}</p>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <select className="input" value={level} onChange={(e) => setLevel(e.target.value)} style={{ width: 110 }}>
            {['DEBUG', 'INFO', 'WARN', 'ERROR'].map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
          <input className="input" placeholder="过滤关键字..." value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void load()} style={{ width: 200 }} />
          <button type="button" className="btn" onClick={() => setLive((v) => !v)}>
            {live ? <><Pause size={14} /> 停止自动刷新</> : <><Play size={14} /> 自动刷新</>}
          </button>
          <button type="button" className="btn" onClick={() => void load()}><RefreshCw size={14} /></button>
          <button type="button" className="btn" onClick={() => void handleDownload()}><Download size={14} /> 下载</button>
          <button type="button" className="btn" style={{ color: 'var(--danger)' }} onClick={() => void handleClear()}><Trash2 size={14} /> 清理</button>
        </div>
      </div>

      <div className="panel" style={{ padding: 14, fontFamily: 'var(--font-mono)', fontSize: 12.5, maxHeight: '70vh', overflowY: 'auto' }}>
        {entries.map((e) => (
          <div key={e.seq} style={{ padding: '4px 0', borderBottom: '1px solid var(--border-subtle)', display: 'flex', gap: 10 }}>
            <span className="muted">{formatLogTime(e.time_ms)}</span>
            <span style={{ minWidth: 48, fontWeight: 700, color: e.level === 'ERROR' ? 'var(--danger)' : e.level === 'WARN' ? 'var(--warning)' : 'var(--accent)' }}>
              {e.level}
            </span>
            <span style={{ color: 'var(--text-secondary)' }}>[{e.component}]</span>
            <span style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>{e.message}</span>
          </div>
        ))}
        {entries.length === 0 && <div className="muted" style={{ padding: 18, textAlign: 'center' }}>暂无匹配日志</div>}
      </div>
    </div>
  );
};
