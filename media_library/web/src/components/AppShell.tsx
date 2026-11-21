import React, { useEffect, useRef, useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import {
  Activity,
  AlertCircle,
  Clapperboard,
  Database,
  Loader2,
  LogOut,
  PanelLeftClose,
  PanelLeftOpen,
  Pause,
  Play,
  RotateCcw,
  ScrollText,
  Settings,
  Shield,
  ShieldCheck,
  Ticket,
  Users,
  X,
} from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';

const ROUTE_TITLES: Record<string, { title: string; subtitle: string }> = {
  '/admin': { title: '平台概览与队列', subtitle: '非隐私聚合指标与全局识别引擎监控' },
  '/admin/accounts': { title: '用户账号管理', subtitle: '账号生命周期、配额调控与强制登出' },
  '/admin/invites': { title: '注册策略与邀请码', subtitle: '控制自助注册模式与邀请码发放' },
  '/admin/settings': { title: '刮削与平台设置', subtitle: 'TMDB、多数据源连通、识别词库与站点外观' },
  '/admin/metadata': { title: '公共元数据缓存', subtitle: '跨用户共享的影视条目、季集与海报缓存管理' },
  '/admin/logs': { title: '系统运行日志', subtitle: '实时日志流与服务端日志文件导出' },
  '/admin/audit': { title: '审计日志与安全', subtitle: '平台管理凭据变更与敏感操作追踪' },
};

export const AppShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { bootstrap, admin, identifyQueue, refreshQueue, toast, logout } = useApp();
  const location = useLocation();
  const [collapsed, setCollapsed] = useState(false);
  const [queueOpen, setQueueOpen] = useState(false);
  const [queueBusy, setQueueBusy] = useState(false);
  const popoverWrapRef = useRef<HTMLDivElement | null>(null);

  const serverTitle = bootstrap?.server_name || 'TTPlay Media';
  const routeMeta = ROUTE_TITLES[location.pathname] || ROUTE_TITLES['/admin'];

  useEffect(() => {
    if (!queueOpen) return;
    const onPointerDown = (e: MouseEvent) => {
      if (popoverWrapRef.current && !popoverWrapRef.current.contains(e.target as Node)) {
        setQueueOpen(false);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setQueueOpen(false);
    };
    window.addEventListener('mousedown', onPointerDown);
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('mousedown', onPointerDown);
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [queueOpen]);

  const handleToggleQueue = async () => {
    if (!identifyQueue || queueBusy) return;
    setQueueBusy(true);
    try {
      if (identifyQueue.paused) {
        await api.identifyResume();
        toast('已恢复全局识别队列', 'success');
      } else {
        await api.identifyPause();
        toast('已暂停全局识别队列', 'info');
      }
      await refreshQueue();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setQueueBusy(false);
    }
  };

  const handleRetryFailed = async () => {
    if (queueBusy) return;
    setQueueBusy(true);
    try {
      const res = await api.identifyRetryFailed();
      toast(`已重新入队 ${res.retried} 个失败任务`, 'success');
      await refreshQueue();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setQueueBusy(false);
    }
  };

  const pendingCount = (identifyQueue?.queued || 0) + (identifyQueue?.processing || 0);
  const failedCount = identifyQueue?.failed || 0;
  const totalProcessed = (identifyQueue?.done || 0) + pendingCount + failedCount;
  const donePct = totalProcessed > 0 ? Math.min(100, Math.round(((identifyQueue?.done || 0) / totalProcessed) * 100)) : 100;

  const pillClass = identifyQueue?.paused
    ? 'warn'
    : pendingCount > 0
    ? ''
    : failedCount > 0
    ? 'warn'
    : 'idle';

  return (
    <div className="app-shell">
      <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
        <div className="brand-row">
          <NavLink to="/admin" className="brand-logo" title={serverTitle}>
            <span className="brand-mark">
              <Clapperboard size={18} />
            </span>
            <span className="brand-title">{serverTitle}</span>
          </NavLink>
          <button
            type="button"
            className="btn btn-icon"
            style={{ width: 30, height: 30, padding: 0 }}
            onClick={() => setCollapsed((v) => !v)}
            title={collapsed ? '展开侧边栏' : '收起侧边栏'}
          >
            {collapsed ? <PanelLeftOpen size={15} /> : <PanelLeftClose size={15} />}
          </button>
        </div>

        <div className="sidebar-scroll">
          <div>
            <div className="nav-group-label">平台运营</div>
            <nav className="nav-list">
              <NavLink to="/admin" end className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="平台概览与队列">
                <Activity size={18} />
                <span className="nav-text">平台概览与队列</span>
                {failedCount > 0 && <span className="nav-badge warn">{failedCount}</span>}
              </NavLink>
              <NavLink to="/admin/accounts" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="用户账号管理">
                <Users size={18} />
                <span className="nav-text">用户账号管理</span>
              </NavLink>
              <NavLink to="/admin/invites" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="注册与邀请码">
                <Ticket size={18} />
                <span className="nav-text">注册与邀请码</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">刮削与系统</div>
            <nav className="nav-list">
              <NavLink to="/admin/settings" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="刮削与平台设置">
                <Settings size={18} />
                <span className="nav-text">刮削与平台设置</span>
              </NavLink>
              <NavLink to="/admin/metadata" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="公共元数据缓存">
                <Database size={18} />
                <span className="nav-text">公共元数据缓存</span>
              </NavLink>
              <NavLink to="/admin/logs" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="系统运行日志">
                <ScrollText size={18} />
                <span className="nav-text">系统运行日志</span>
              </NavLink>
              <NavLink to="/admin/audit" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="审计日志与安全">
                <Shield size={18} />
                <span className="nav-text">审计日志与安全</span>
              </NavLink>
            </nav>
          </div>
        </div>

        <div className="sidebar-footer">
          <div className="flex-row sidebar-user-meta" style={{ gap: 10, minWidth: 0, flexWrap: 'nowrap' }}>
            <span className="avatar-circle" style={{ width: 30, height: 30, fontSize: 12 }}>
              {(admin?.username || 'A').slice(0, 1)}
            </span>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {admin?.username || 'admin'}
              </div>
              <div className="muted-sm" style={{ fontSize: 11 }}>
                平台管理员{bootstrap?.version ? ` · v${bootstrap.version}` : ''}
              </div>
            </div>
          </div>
          <button
            type="button"
            className="btn btn-icon"
            style={{ width: 32, height: 32, padding: 0 }}
            title="退出管理后台"
            onClick={() => void logout()}
          >
            <LogOut size={15} />
          </button>
        </div>
      </aside>

      <div className="main-area">
        <header className="topbar">
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                {routeMeta.title}
              </div>
              <div className="muted-sm" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                {routeMeta.subtitle}
              </div>
            </div>
          </div>

          <div className="topbar-right" ref={popoverWrapRef}>
            <span className="privacy-pill" title="平台管理员不访问任何用户文件名、路径、媒体源或观看历史">
              <ShieldCheck size={13} />
              <span>零隐私运维</span>
            </span>

            <button
              type="button"
              className={`task-pill ${pillClass}`}
              onClick={() => {
                setQueueOpen((v) => !v);
                void refreshQueue();
              }}
              title="查看并控制全局识别队列"
            >
              {identifyQueue?.paused ? (
                <Pause size={13} />
              ) : pendingCount > 0 ? (
                <Loader2 size={13} className="spin" />
              ) : failedCount > 0 ? (
                <AlertCircle size={13} />
              ) : (
                <Activity size={13} />
              )}
              <span>
                {identifyQueue?.paused
                  ? '识别队列已暂停'
                  : pendingCount > 0
                  ? `识别处理中 · 剩余 ${pendingCount}`
                  : failedCount > 0
                  ? `识别队列 · ${failedCount} 失败`
                  : '识别引擎空闲'}
              </span>
            </button>

            {queueOpen && (
              <div className="task-popover">
                <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                  <div className="flex-row" style={{ gap: 8 }}>
                    <span className={`status-dot ${identifyQueue?.paused ? 'warn' : failedCount > 0 ? 'danger' : 'live'}`} />
                    <strong style={{ fontSize: 14 }}>全局识别队列</strong>
                  </div>
                  <button
                    type="button"
                    className="btn btn-icon btn-sm"
                    style={{ width: 26, height: 26, padding: 0 }}
                    onClick={() => setQueueOpen(false)}
                  >
                    <X size={14} />
                  </button>
                </div>

                {identifyQueue ? (
                  <>
                    <div className="card-box" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
                      <div className="flex-row" style={{ justifyContent: 'space-between', fontSize: 12 }}>
                        <span className="muted">
                          状态：{identifyQueue.paused ? '已暂停' : '运行中'} · {identifyQueue.workers} 工作线程
                        </span>
                        <span className="muted-sm">{donePct}%</span>
                      </div>
                      <div className="progress-track">
                        <div className="progress-track-fill" style={{ width: `${donePct}%` }} />
                      </div>
                      <div className="flex-row" style={{ gap: 6 }}>
                        <span className="tag accent">排队 {identifyQueue.queued}</span>
                        <span className="tag">处理中 {identifyQueue.processing}</span>
                        <span className="tag success">完成 {identifyQueue.done}</span>
                        {identifyQueue.failed > 0 && <span className="tag danger">失败 {identifyQueue.failed}</span>}
                      </div>
                    </div>

                    <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 8 }}>
                      <button type="button" className="btn btn-sm" disabled={queueBusy} onClick={() => void handleToggleQueue()}>
                        {identifyQueue.paused ? <><Play size={13} /> 恢复队列</> : <><Pause size={13} /> 暂停队列</>}
                      </button>
                      <button
                        type="button"
                        className="btn btn-primary btn-sm"
                        disabled={queueBusy || identifyQueue.failed === 0}
                        onClick={() => void handleRetryFailed()}
                      >
                        <RotateCcw size={13} /> 重试失败
                      </button>
                    </div>
                  </>
                ) : (
                  <div className="muted-sm">正在获取队列状态...</div>
                )}
              </div>
            )}
          </div>
        </header>

        <main className="page-content">{children}</main>
      </div>

      <nav className="mobile-dock">
        <NavLink to="/admin" end className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Activity size={18} />
          <span>概览</span>
        </NavLink>
        <NavLink to="/admin/accounts" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Users size={18} />
          <span>账号</span>
        </NavLink>
        <NavLink to="/admin/invites" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Ticket size={18} />
          <span>邀请</span>
        </NavLink>
        <NavLink to="/admin/settings" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Settings size={18} />
          <span>设置</span>
        </NavLink>
        <NavLink to="/admin/logs" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <ScrollText size={18} />
          <span>日志</span>
        </NavLink>
      </nav>
    </div>
  );
};
