import React, { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Activity,
  ArrowRight,
  Cpu,
  Database,
  HardDrive,
  Layers,
  Pause,
  Play,
  RefreshCw,
  RotateCcw,
  Smartphone,
  Users,
} from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { CacheStats, IdentifyQueueStats, PlatformOverview } from '../types';

const SOURCE_KIND_LABELS: Record<string, string> = {
  quark: '夸克网盘',
  webdav: 'WebDAV',
  smb: 'SMB 共享',
  emby: 'Emby',
  jellyfin: 'Jellyfin',
  local: '本地目录',
};

export const AdminOverviewPage: React.FC = () => {
  const { toast, refreshQueue } = useApp();
  const [overview, setOverview] = useState<PlatformOverview | null>(null);
  const [cacheStats, setCacheStats] = useState<CacheStats | null>(null);
  const [queue, setQueue] = useState<IdentifyQueueStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.overview();
      setOverview(res.overview);
      setCacheStats(res.cache_stats || null);
      setQueue(res.identify_queue || null);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const togglePause = async () => {
    if (!queue || busy) return;
    setBusy(true);
    try {
      if (queue.paused) {
        await api.identifyResume();
        toast('已恢复全局识别队列', 'success');
      } else {
        await api.identifyPause();
        toast('已暂停全局识别队列', 'info');
      }
      await Promise.all([load(), refreshQueue()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const retryFailed = async () => {
    if (busy) return;
    setBusy(true);
    try {
      const res = await api.identifyRetryFailed();
      toast(`已重新入队 ${res.retried} 个失败任务`, 'success');
      await Promise.all([load(), refreshQueue()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const sourceEntries = Object.entries(overview?.sources_by_kind || {}).sort((a, b) => b[1] - a[1]);
  const totalSources = sourceEntries.reduce((sum, [, n]) => sum + n, 0) || overview?.sources_total || 0;

  const qTotal = (queue?.done || 0) + (queue?.queued || 0) + (queue?.processing || 0) + (queue?.failed || 0);
  const qDonePct = qTotal > 0 ? Math.min(100, Math.round(((queue?.done || 0) / qTotal) * 100)) : 100;

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">平台运行概览</h1>
          <p className="page-subtitle">
            汇总全站账号规模、存储占用、公共元数据缓存与后台刮削队列状态（严格遵守零隐私聚合原则）。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新数据
        </button>
      </div>

      {loading && !overview ? (
        <CardListSkeleton count={4} />
      ) : (
        <>
          {overview && (
            <div className="kpi-grid">
              <div className="kpi-card">
                <div className="kpi-head">
                  <span className="kpi-label">平台用户账号</span>
                  <span className="kpi-icon">
                    <Users size={17} />
                  </span>
                </div>
                <div className="kpi-value">{overview.accounts_total}</div>
                <div className="kpi-meta">
                  <span className="tag success">正常 {overview.accounts_active}</span>
                  {overview.accounts_today > 0 && <span className="tag accent">今日 +{overview.accounts_today}</span>}
                </div>
              </div>

              <div className="kpi-card">
                <div className="kpi-head">
                  <span className="kpi-label">接入客户端设备</span>
                  <span className="kpi-icon success">
                    <Smartphone size={17} />
                  </span>
                </div>
                <div className="kpi-value">{overview.devices_total}</div>
                <div className="kpi-meta">
                  <span>近 7 日活跃</span>
                  <strong style={{ color: 'var(--text-primary)' }}>{overview.devices_active_7d} 台</strong>
                </div>
              </div>

              <div className="kpi-card">
                <div className="kpi-head">
                  <span className="kpi-label">聚合影视索引</span>
                  <span className="kpi-icon plum">
                    <Layers size={17} />
                  </span>
                </div>
                <div className="kpi-value">{(overview.items_total ?? 0).toLocaleString()}</div>
                <div className="kpi-meta">
                  <span>{overview.sources_total ?? 0} 媒体源</span>
                  <span>·</span>
                  <span>{(overview.files_total ?? 0).toLocaleString()} 文件</span>
                </div>
              </div>

              <div className="kpi-card">
                <div className="kpi-head">
                  <span className="kpi-label">服务端存储占用</span>
                  <span className="kpi-icon warn">
                    <HardDrive size={17} />
                  </span>
                </div>
                <div className="kpi-value">{formatBytes((overview.db_bytes ?? 0) + (overview.sidecar_bytes ?? 0))}</div>
                <div className="kpi-meta">
                  <span>DB {formatBytes(overview.db_bytes ?? 0)}</span>
                  <span>·</span>
                  <span>旁路 {formatBytes(overview.sidecar_bytes ?? 0)}</span>
                </div>
              </div>
            </div>
          )}

          <div className="grid-2">
            {/* Source distribution */}
            <div className="card-box">
              <div className="card-title-row">
                <h3 className="card-title">
                  <Activity size={16} style={{ color: 'var(--accent)' }} />
                  媒体源类型分布
                </h3>
                <span className="tag">共 {totalSources} 个</span>
              </div>

              {sourceEntries.length === 0 ? (
                <div className="empty-state" style={{ padding: '24px 12px' }}>
                  <Layers size={24} />
                  <div style={{ fontSize: 13 }}>暂未接入任何媒体源</div>
                  <div className="muted-sm">用户在客户端添加夸克 / WebDAV / SMB 源后将在此聚合统计</div>
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  {sourceEntries.map(([kind, count]) => {
                    const pct = totalSources > 0 ? Math.max(4, Math.round((count / totalSources) * 100)) : 0;
                    return (
                      <div key={kind} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                        <div className="flex-row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
                          <span style={{ fontWeight: 600 }}>{SOURCE_KIND_LABELS[kind] || kind.toUpperCase()}</span>
                          <span className="muted-sm">
                            <strong style={{ color: 'var(--text-primary)' }}>{count}</strong> ({pct}%)
                          </span>
                        </div>
                        <div className="progress-track">
                          <div className="progress-track-fill" style={{ width: `${pct}%` }} />
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>

            {/* Metadata cache breakdown */}
            <div className="card-box">
              <div className="card-title-row">
                <h3 className="card-title">
                  <Database size={16} style={{ color: 'var(--accent)' }} />
                  公共元数据缓存
                </h3>
                <Link to="/admin/metadata" className="btn btn-sm">
                  管理缓存
                  <ArrowRight size={13} />
                </Link>
              </div>

              {cacheStats ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  <div className="grid-2" style={{ gap: 10 }}>
                    <div className="metric-cell">
                      <span className="metric-cell-label">影视作品缓存</span>
                      <span className="metric-cell-value">{(cacheStats.works ?? 0).toLocaleString()}</span>
                    </div>
                    <div className="metric-cell">
                      <span className="metric-cell-label">剧集季/集缓存</span>
                      <span className="metric-cell-value">{(cacheStats.seasons ?? 0).toLocaleString()}</span>
                    </div>
                    <div className="metric-cell">
                      <span className="metric-cell-label">演职员资料缓存</span>
                      <span className="metric-cell-value">{(cacheStats.people ?? 0).toLocaleString()}</span>
                    </div>
                    <div className="metric-cell">
                      <span className="metric-cell-label">检索结果缓存</span>
                      <span className="metric-cell-value">
                        {(cacheStats.searches ?? cacheStats.search ?? 0).toLocaleString()}
                      </span>
                    </div>
                  </div>
                  {(cacheStats.image_files !== undefined || cacheStats.image_bytes !== undefined) && (
                    <div className="flex-row" style={{ justifyContent: 'space-between', fontSize: 12.5 }}>
                      <span className="muted">本地代理海报缓存</span>
                      <span>
                        <strong>{cacheStats.image_files || 0}</strong> 张 ·{' '}
                        <strong>{formatBytes(cacheStats.image_bytes || 0)}</strong>
                      </span>
                    </div>
                  )}
                </div>
              ) : (
                <div className="empty-state" style={{ padding: '24px 12px' }}>
                  <Database size={24} />
                  <div className="muted-sm">暂无缓存统计数据</div>
                </div>
              )}
            </div>
          </div>

          {/* Identify queue card */}
          {queue && (
            <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
              <div className="card-title-row" style={{ marginBottom: 0 }}>
                <div className="flex-row" style={{ gap: 10 }}>
                  <h3 className="card-title">
                    <Cpu size={16} style={{ color: 'var(--accent)' }} />
                    全局识别与刮削队列
                  </h3>
                  <span className={`tag ${queue.paused ? 'gold' : queue.failed > 0 ? 'danger' : 'success'}`}>
                    <span className={`status-dot ${queue.paused ? 'warn' : queue.failed > 0 ? 'danger' : 'live'}`} style={{ width: 6, height: 6 }} />
                    {queue.paused ? '已暂停' : '运行中'}
                  </span>
                  <span className="tag">{queue.workers} 并发线程</span>
                </div>

                <div className="flex-row" style={{ gap: 8 }}>
                  <button type="button" className="btn btn-sm" disabled={busy} onClick={() => void togglePause()}>
                    {queue.paused ? <><Play size={13} /> 恢复队列</> : <><Pause size={13} /> 暂停队列</>}
                  </button>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    disabled={busy || queue.failed === 0}
                    onClick={() => void retryFailed()}
                  >
                    <RotateCcw size={13} /> 重试全部失败任务
                  </button>
                </div>
              </div>

              <div className="metric-strip">
                <div className="metric-cell">
                  <span className="metric-cell-label">排队等待</span>
                  <span className="metric-cell-value" style={{ color: queue.queued > 0 ? 'var(--accent)' : undefined }}>
                    {queue.queued}
                  </span>
                </div>
                <div className="metric-cell">
                  <span className="metric-cell-label">正在识别</span>
                  <span className="metric-cell-value">{queue.processing}</span>
                </div>
                <div className="metric-cell">
                  <span className="metric-cell-label">已完成</span>
                  <span className="metric-cell-value" style={{ color: 'var(--success)' }}>
                    {queue.done}
                  </span>
                </div>
                <div className="metric-cell">
                  <span className="metric-cell-label">识别失败</span>
                  <span className="metric-cell-value" style={{ color: queue.failed > 0 ? 'var(--danger)' : undefined }}>
                    {queue.failed}
                  </span>
                </div>
              </div>

              <div>
                <div className="flex-row" style={{ justifyContent: 'space-between', marginBottom: 6, fontSize: 12 }}>
                  <span className="muted-sm">队列总体完成进度</span>
                  <span className="muted-sm">{qDonePct}%</span>
                </div>
                <div className="progress-track">
                  <div className="progress-track-fill" style={{ width: `${qDonePct}%` }} />
                </div>
              </div>

              {queue.by_household && queue.by_household.length > 0 && (
                <div className="table-wrap">
                  <table className="data-table">
                    <thead>
                      <tr>
                        <th>匿名空间 ID</th>
                        <th>排队</th>
                        <th>处理中</th>
                        <th>已完成</th>
                        <th>失败</th>
                        <th>最近错误码</th>
                      </tr>
                    </thead>
                    <tbody>
                      {queue.by_household.map((h) => (
                        <tr key={h.household_id}>
                          <td style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}>
                            {(h.household_id || '').slice(0, 14)}…
                          </td>
                          <td>{h.queued}</td>
                          <td>{h.processing}</td>
                          <td style={{ color: 'var(--success)' }}>{h.done}</td>
                          <td style={{ color: h.failed > 0 ? 'var(--danger)' : undefined }}>{h.failed}</td>
                          <td>
                            {h.last_error_code ? (
                              <span className="tag danger">{h.last_error_code}</span>
                            ) : (
                              <span className="muted-sm">-</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
};
