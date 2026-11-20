import React, { useCallback, useEffect, useState } from 'react';
import { Pause, Play, RefreshCw, RotateCcw } from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { CacheStats, IdentifyQueueStats, PlatformOverview } from '../types';

export const AdminOverviewPage: React.FC = () => {
  const { toast } = useApp();
  const [overview, setOverview] = useState<PlatformOverview | null>(null);
  const [cacheStats, setCacheStats] = useState<CacheStats | null>(null);
  const [queue, setQueue] = useState<IdentifyQueueStats | null>(null);
  const [loading, setLoading] = useState(true);

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
    if (!queue) return;
    try {
      if (queue.paused) {
        await api.identifyResume();
        toast('已恢复全局识别队列', 'success');
      } else {
        await api.identifyPause();
        toast('已暂停全局识别队列', 'info');
      }
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const retryFailed = async () => {
    try {
      const res = await api.identifyRetryFailed();
      toast(`已重新入队 ${res.retried} 个失败任务`, 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 1100 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 22 }}>平台概览与识别队列</h1>
          <p className="muted" style={{ margin: '4px 0 0', fontSize: 13 }}>
            所有指标均为非隐私聚合统计，不展示任何用户文件名、路径、媒体源名称或观看记录。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} /> 刷新
        </button>
      </div>

      {overview && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(210px, 1fr))', gap: 14 }}>
          <div className="panel" style={{ padding: 16 }}>
            <div className="muted" style={{ fontSize: 12 }}>总用户数 / 活跃 / 今日新增</div>
            <div style={{ fontSize: 24, fontWeight: 700, marginTop: 6 }}>
              {overview.accounts_total} / {overview.accounts_active} / +{overview.accounts_today}
            </div>
          </div>
          <div className="panel" style={{ padding: 16 }}>
            <div className="muted" style={{ fontSize: 12 }}>设备总数 / 7日活跃设备</div>
            <div style={{ fontSize: 24, fontWeight: 700, marginTop: 6 }}>
              {overview.devices_total} / {overview.devices_active_7d}
            </div>
          </div>
          <div className="panel" style={{ padding: 16 }}>
            <div className="muted" style={{ fontSize: 12 }}>总媒体源 / 作品 / 文件</div>
            <div style={{ fontSize: 24, fontWeight: 700, marginTop: 6 }}>
              {overview.sources_total} / {overview.items_total} / {overview.files_total}
            </div>
          </div>
          <div className="panel" style={{ padding: 16 }}>
            <div className="muted" style={{ fontSize: 12 }}>数据库体积 / 旁路文件占用</div>
            <div style={{ fontSize: 20, fontWeight: 700, marginTop: 6 }}>
              {formatBytes(overview.db_bytes)} / {formatBytes(overview.sidecar_bytes)}
            </div>
          </div>
        </div>
      )}

      {overview && Object.keys(overview.sources_by_kind || {}).length > 0 && (
        <div className="panel" style={{ padding: 18 }}>
          <h3 style={{ margin: '0 0 10px', fontSize: 15 }}>媒体源类型分布</h3>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
            {Object.entries(overview.sources_by_kind).map(([kind, count]) => (
              <span key={kind} className="badge" style={{ padding: '6px 12px', fontSize: 13 }}>
                {kind.toUpperCase()}: {count}
              </span>
            ))}
          </div>
        </div>
      )}

      {cacheStats && (
        <div className="panel" style={{ padding: 18 }}>
          <h3 style={{ margin: '0 0 10px', fontSize: 15 }}>公共元数据缓存统计</h3>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, fontSize: 14 }}>
            <span>作品缓存：{cacheStats.works}</span>
            <span>季集缓存：{cacheStats.seasons}</span>
            <span>演职员缓存：{cacheStats.people}</span>
            <span>搜索缓存：{cacheStats.search}</span>
          </div>
        </div>
      )}

      {queue && (
        <div className="panel" style={{ padding: 18, display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <h3 style={{ margin: 0, fontSize: 15 }}>
              全局识别队列（状态：{queue.paused ? '已暂停' : '运行中'}，工作线程：{queue.workers}）
            </h3>
            <div style={{ display: 'flex', gap: 8 }}>
              <button type="button" className="btn" onClick={() => void togglePause()}>
                {queue.paused ? <><Play size={14} /> 恢复队列</> : <><Pause size={14} /> 暂停队列</>}
              </button>
              <button type="button" className="btn" onClick={() => void retryFailed()}>
                <RotateCcw size={14} /> 重试全部失败任务
              </button>
            </div>
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 16, fontSize: 14 }}>
            <span>排队中：{queue.queued}</span>
            <span>处理中：{queue.processing}</span>
            <span>已完成：{queue.done}</span>
            <span style={{ color: queue.failed > 0 ? 'var(--danger)' : undefined }}>失败：{queue.failed}</span>
          </div>
        </div>
      )}
    </div>
  );
};
