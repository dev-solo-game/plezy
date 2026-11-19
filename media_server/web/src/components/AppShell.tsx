import React, { useEffect, useRef, useState } from 'react';
import { Link, NavLink, useNavigate } from 'react-router-dom';
import {
  Activity,
  AlertCircle,
  AlertTriangle,
  Bookmark,
  CheckCircle2,
  Clapperboard,
  Compass,
  Database,
  Film,
  FolderOpen,
  HardDrive,
  Heart,
  Home,
  Layers,
  Loader2,
  PanelLeftClose,
  PanelLeftOpen,
  Plus,
  RefreshCw,
  ScrollText,
  Search,
  Server,
  Settings,
  Sparkles,
  Square,
  Tv,
  Video,
  X,
} from 'lucide-react';
import { api } from '../api/client';
import {
  prefetchExtHome,
  prefetchExternalServers,
  prefetchHome,
  prefetchLists,
  prefetchMetadataTables,
  prefetchMounts,
  prefetchSettings,
  prefetchShelf,
  prefetchSystemLogs,
  prefetchUnmatched,
} from '../api/prefetch';
import { useApp } from '../contexts/AppContext';

export const AppShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const {
    bootstrap,
    username,
    activeScans,
    scrapeProgress,
    pendingScrapeCount,
    dismissScrapeBanner,
    unmatchedCount,
    externalServers,
    toasts,
    toast,
  } = useApp();
  const [collapsed, setCollapsed] = useState(false);
  const [searchQ, setSearchQ] = useState('');
  const [taskOpen, setTaskOpen] = useState(false);
  const popoverWrapRef = useRef<HTMLDivElement | null>(null);
  const navigate = useNavigate();

  useEffect(() => {
    if (!taskOpen) return;
    const onPointerDown = (e: MouseEvent) => {
      if (popoverWrapRef.current && !popoverWrapRef.current.contains(e.target as Node)) {
        setTaskOpen(false);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setTaskOpen(false);
    };
    window.addEventListener('mousedown', onPointerDown);
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('mousedown', onPointerDown);
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [taskOpen]);

  const onSearchSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = searchQ.trim();
    if (trimmed) {
      navigate(`/search?q=${encodeURIComponent(trimmed)}`);
    } else {
      navigate('/search');
    }
  };

  const serverTitle = bootstrap?.server_name || 'TTPlay Media';

  const scrapeStatus = scrapeProgress?.status || 'idle';
  const scrapePct =
    scrapeProgress && scrapeProgress.total > 0
      ? Math.min(100, Math.round((scrapeProgress.done / scrapeProgress.total) * 100))
      : 0;
  const showScrapePill = scrapeStatus !== 'idle' || pendingScrapeCount > 0;
  const hasAnyTaskPill = activeScans.length > 0 || showScrapePill;

  return (
    <div className="app-shell">
      <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
        <div className="brand-row">
          <NavLink to="/" className="brand-logo" title={serverTitle}>
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
            <div className="nav-group-label">探索与媒体库</div>
            <nav className="nav-list">
              <NavLink to="/" end className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchHome} onFocus={prefetchHome}>
                <Home size={18} />
                <span className="nav-text">首页推荐</span>
              </NavLink>
              <NavLink to="/library/movie" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('movie')} onFocus={() => prefetchShelf('movie')}>
                <Film size={18} />
                <span className="nav-text">电影</span>
              </NavLink>
              <NavLink to="/library/show" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('show')} onFocus={() => prefetchShelf('show')}>
                <Tv size={18} />
                <span className="nav-text">剧集</span>
              </NavLink>
              <NavLink to="/library/anime" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('anime')} onFocus={() => prefetchShelf('anime')}>
                <Sparkles size={18} />
                <span className="nav-text">动漫</span>
              </NavLink>
              <NavLink to="/library/variety" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('variety')} onFocus={() => prefetchShelf('variety')}>
                <Video size={18} />
                <span className="nav-text">综艺</span>
              </NavLink>
              <NavLink to="/library/documentary" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('documentary')} onFocus={() => prefetchShelf('documentary')}>
                <Compass size={18} />
                <span className="nav-text">纪录片</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">集合与浏览</div>
            <nav className="nav-list">
              <NavLink to="/favorites" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchShelf('all', true)} onFocus={() => prefetchShelf('all', true)}>
                <Heart size={18} />
                <span className="nav-text">我的收藏</span>
              </NavLink>
              <NavLink to="/lists" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={() => prefetchLists('all')} onFocus={() => prefetchLists('all')}>
                <Layers size={18} />
                <span className="nav-text">合集与播单</span>
              </NavLink>
              <NavLink to="/folders" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchMounts} onFocus={prefetchMounts}>
                <FolderOpen size={18} />
                <span className="nav-text">文件夹浏览</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label-row">
              <div className="nav-group-label">外部媒体服</div>
              <Link
                to="/manage/servers?add=1"
                className="nav-group-action"
                title="添加 Emby / Jellyfin 服务器"
              >
                <Plus size={13} />
              </Link>
            </div>
            <nav className="nav-list">
              {externalServers
                .filter((srv) => srv.enabled)
                .map((srv) => (
                  <NavLink
                    key={srv.id}
                    to={`/ext/${srv.id}`}
                    className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}
                    onMouseEnter={() => prefetchExtHome(srv.id)}
                    onFocus={() => prefetchExtHome(srv.id)}
                    title={`${srv.name} (${srv.kind === 'emby' ? 'Emby' : 'Jellyfin'})`}
                  >
                    <span className={`ext-kind-dot ${srv.kind}`}>
                      {srv.kind === 'emby' ? 'E' : 'J'}
                    </span>
                    <span className="nav-text" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {srv.name}
                    </span>
                  </NavLink>
                ))}
              {externalServers.filter((srv) => srv.enabled).length === 0 && (
                <Link
                  to="/manage/servers?add=1"
                  className="nav-item"
                  style={{ color: 'var(--text-muted)', fontSize: 13 }}
                  title="添加 Emby / Jellyfin 服务器"
                >
                  <Plus size={16} />
                  <span className="nav-text">添加 Emby / Jellyfin</span>
                </Link>
              )}
            </nav>
          </div>

          <div>
            <div className="nav-group-label">服务器管理</div>
            <nav className="nav-list">
              <NavLink to="/manage/mounts" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchMounts} onFocus={prefetchMounts}>
                <HardDrive size={18} />
                <span className="nav-text">存储挂载</span>
              </NavLink>
              <NavLink to="/manage/servers" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchExternalServers} onFocus={prefetchExternalServers}>
                <Server size={18} />
                <span className="nav-text">外部服务器</span>
                {externalServers.length > 0 && <span className="nav-badge">{externalServers.length}</span>}
              </NavLink>
              <NavLink to="/manage/unmatched" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchUnmatched} onFocus={prefetchUnmatched}>
                <AlertCircle size={18} />
                <span className="nav-text">待匹配中心</span>
                {unmatchedCount > 0 && <span className="nav-badge warn">{unmatchedCount}</span>}
              </NavLink>
              <NavLink to="/settings" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchSettings} onFocus={prefetchSettings}>
                <Settings size={18} />
                <span className="nav-text">系统设置</span>
              </NavLink>
              <NavLink to="/manage/metadata" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchMetadataTables} onFocus={prefetchMetadataTables}>
                <Database size={18} />
                <span className="nav-text">元数据管理</span>
              </NavLink>
              <NavLink to="/manage/logs" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} onMouseEnter={prefetchSystemLogs} onFocus={prefetchSystemLogs}>
                <ScrollText size={18} />
                <span className="nav-text">运行日志</span>
              </NavLink>
            </nav>
          </div>
        </div>

        {!collapsed && username && (
          <div style={{ paddingTop: 12, borderTop: '1px solid var(--border-subtle)', fontSize: 12, color: 'var(--text-muted)' }}>
            管理员：<strong style={{ color: 'var(--text-secondary)' }}>{username}</strong>
          </div>
        )}
      </aside>

      <div className="main-area">
        <header className="topbar">
          <form className="search-pill" onSubmit={onSearchSubmit}>
            <Search size={16} className="muted" />
            <input
              type="search"
              placeholder="搜索电影、剧集、单集或演职员..."
              value={searchQ}
              onChange={(e) => setSearchQ(e.target.value)}
            />
          </form>

          <div className="topbar-right" ref={popoverWrapRef}>
            {activeScans.length > 0 && (
              <button
                type="button"
                className="task-pill"
                onClick={() => setTaskOpen((v) => !v)}
                title={activeScans[0].current_path || '查看扫描详情'}
              >
                <Loader2 size={14} className="spin" />
                <span>
                  {activeScans.length === 1
                    ? `扫描 ${activeScans[0].mount_name}: ${activeScans[0].files_seen} 文件`
                    : `正在扫描 ${activeScans.length} 个挂载源`}
                </span>
              </button>
            )}

            {showScrapePill && (
              <button
                type="button"
                className={`task-pill ${
                  scrapeStatus === 'warning'
                    ? 'warn'
                    : scrapeStatus === 'completed' || scrapeStatus === 'done'
                    ? 'success'
                    : scrapeStatus === 'running'
                    ? ''
                    : 'idle'
                }`}
                onClick={() => setTaskOpen((v) => !v)}
                title="查看刮削入库实时进度"
              >
                {scrapeStatus === 'running' ? (
                  <Loader2 size={14} className="spin" />
                ) : scrapeStatus === 'warning' ? (
                  <AlertTriangle size={14} />
                ) : scrapeStatus === 'completed' || scrapeStatus === 'done' ? (
                  <CheckCircle2 size={14} />
                ) : (
                  <Sparkles size={14} />
                )}
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {scrapeStatus === 'running' && scrapeProgress
                    ? `刮削 ${scrapeProgress.done}/${scrapeProgress.total} (${scrapePct}%)${
                        scrapeProgress.title ? ` · ${scrapeProgress.title}` : ''
                      }`
                    : scrapeStatus === 'warning'
                    ? scrapeProgress?.message?.includes('Key')
                      ? '刮削暂停 · 未配置 Key'
                      : '刮削告警 · 查看详情'
                    : (scrapeStatus === 'completed' || scrapeStatus === 'done') && scrapeProgress
                    ? (scrapeProgress.matched || 0) + (scrapeProgress.merged || 0) === 0 &&
                      (scrapeProgress.unmatched || 0) > 0
                      ? `刮削完成 · 未匹配 ${scrapeProgress.unmatched}`
                      : `刮削完成 · 已入库 ${(scrapeProgress.matched || 0) + (scrapeProgress.merged || 0)}`
                    : `待刮削 ${pendingScrapeCount} 项`}
                </span>
                {scrapeStatus === 'running' && (
                  <span className="task-pill-bar">
                    <span className="task-pill-bar-fill" style={{ width: `${scrapePct}%` }} />
                  </span>
                )}
              </button>
            )}

            {!hasAnyTaskPill && (
              <button
                type="button"
                className="task-pill idle"
                onClick={() => setTaskOpen((v) => !v)}
                title="查看后台扫描与刮削状态"
              >
                <Activity size={14} />
                <span>任务空闲</span>
              </button>
            )}

            <NavLink to="/library/all" className="btn btn-sm" title="全部媒体库">
              <Bookmark size={14} />
              <span>全部库</span>
            </NavLink>

            {taskOpen && (
              <div className="task-popover">
                <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                  <strong style={{ fontSize: 14 }}>后台扫描与刮削任务中心</strong>
                  <button type="button" className="btn btn-icon btn-sm" style={{ width: 26, height: 26, padding: 0 }} onClick={() => setTaskOpen(false)}>
                    <X size={14} />
                  </button>
                </div>

                {/* Scans section */}
                <div className="card-box" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                    <span style={{ fontSize: 13, fontWeight: 600 }}>目录扫描</span>
                    {activeScans.length === 0 && (
                      <button
                        type="button"
                        className="btn btn-sm"
                        style={{ padding: '4px 9px', fontSize: 12 }}
                        onClick={() => api.scanAll(false).then(() => toast('已启动全库增量扫描', 'success'))}
                      >
                        <RefreshCw size={12} />
                        扫描全部
                      </button>
                    )}
                  </div>

                  {activeScans.length === 0 ? (
                    <div className="muted-sm">当前无进行中的目录扫描任务</div>
                  ) : (
                    activeScans.map((s) => (
                      <div key={s.mount_id} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                        <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                          <span style={{ fontSize: 13, fontWeight: 600 }}>{s.mount_name}</span>
                          <button
                            type="button"
                            className="btn btn-danger btn-sm"
                            style={{ padding: '3px 8px', fontSize: 11 }}
                            onClick={() => api.cancelScan(s.mount_id).then(() => toast('正在取消扫描...'))}
                          >
                            <Square size={11} />
                            取消
                          </button>
                        </div>
                        <div className="muted-sm">
                          已遍历 {s.directories_done} 目录 · 发现 {s.files_seen} 文件
                          {s.videos_found ? ` (含 ${s.videos_found} 视频)` : ''}
                        </div>
                        {s.current_path && (
                          <div
                            className="muted-sm"
                            style={{ fontFamily: 'var(--font-mono)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}
                            title={s.current_path}
                          >
                            {s.current_path}
                          </div>
                        )}
                      </div>
                    ))
                  )}
                </div>

                {/* Scrape section */}
                <div className="card-box" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                    <span style={{ fontSize: 13, fontWeight: 600 }}>自动刮削入库</span>
                    <div className="flex-row" style={{ gap: 6 }}>
                      {scrapeStatus === 'warning' && (
                        <button
                          type="button"
                          className="btn btn-sm"
                          style={{ padding: '3px 8px', fontSize: 11 }}
                          onClick={dismissScrapeBanner}
                        >
                          忽略提示
                        </button>
                      )}
                      {scrapeStatus !== 'running' && (
                        <button
                          type="button"
                          className="btn btn-primary btn-sm"
                          style={{ padding: '4px 9px', fontSize: 12 }}
                          onClick={() => api.scrapeAll(false, false).then(() => toast('已唤醒刮削队列', 'success'))}
                        >
                          <Sparkles size={12} />
                          立即刮削
                        </button>
                      )}
                    </div>
                  </div>

                  {scrapeProgress && scrapeStatus !== 'idle' ? (
                    <>
                      <div className="flex-row" style={{ justifyContent: 'space-between', fontSize: 12 }}>
                        <span style={{ color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 250 }}>
                          {scrapeStatus === 'running'
                            ? `正在处理：${scrapeProgress.title || '...'}`
                            : scrapeStatus === 'warning'
                            ? '刮削已暂停'
                            : '本轮刮削已完成'}
                        </span>
                        <span className="muted-sm">
                          {scrapeProgress.done} / {scrapeProgress.total} ({scrapePct}%)
                        </span>
                      </div>

                      <div className="progress-track">
                        <div className="progress-track-fill" style={{ width: `${scrapePct}%` }} />
                      </div>

                      <div className="flex-row" style={{ gap: 6 }}>
                        <span className="tag success">入库 {scrapeProgress.matched || 0}</span>
                        {(scrapeProgress.merged || 0) > 0 && (
                          <span className="tag accent">合并 {scrapeProgress.merged}</span>
                        )}
                        {(scrapeProgress.unmatched || 0) > 0 && (
                          <span className="tag">未匹配 {scrapeProgress.unmatched}</span>
                        )}
                        {pendingScrapeCount > 0 && (
                          <span className="tag">队列剩余 {pendingScrapeCount}</span>
                        )}
                      </div>

                      {scrapeProgress.message && (
                        <div style={{ fontSize: 12, color: 'var(--warning)' }}>
                          {scrapeProgress.message}{' '}
                          <Link
                            to="/settings"
                            style={{ textDecoration: 'underline', color: 'var(--accent)' }}
                            onClick={() => setTaskOpen(false)}
                          >
                            前往设置
                          </Link>
                        </div>
                      )}
                    </>
                  ) : (
                    <div className="muted-sm">
                      {pendingScrapeCount > 0
                        ? `当前队列有 ${pendingScrapeCount} 项待刮削，扫描新目录时会自动唤醒。`
                        : '全部目录均已处理完毕，等待新媒体加入。'}
                    </div>
                  )}

                  {unmatchedCount > 0 && (
                    <div className="flex-row" style={{ justifyContent: 'space-between', paddingTop: 4, borderTop: '1px solid var(--border-subtle)' }}>
                      <Link
                        to="/manage/unmatched"
                        className="muted-sm"
                        style={{ color: 'var(--warning)' }}
                        onClick={() => setTaskOpen(false)}
                      >
                        当前共有 {unmatchedCount} 项待手工匹配 →
                      </Link>
                      <button
                        type="button"
                        className="btn btn-sm"
                        style={{ padding: '3px 8px', fontSize: 11 }}
                        onClick={() => api.scrapeAll(true, false).then(() => toast('已发起未匹配重试', 'success'))}
                      >
                        重试未匹配
                      </button>
                    </div>
                  )}
                </div>
              </div>
            )}
          </div>
        </header>

        <main className="page-content">{children}</main>
      </div>

      <nav className="mobile-dock">
        <NavLink to="/" end className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Home size={18} />
          <span>首页</span>
        </NavLink>
        <NavLink to="/library/all" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Film size={18} />
          <span>片库</span>
        </NavLink>
        <NavLink to="/folders" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <FolderOpen size={18} />
          <span>目录</span>
        </NavLink>
        <NavLink to="/manage/mounts" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <HardDrive size={18} />
          <span>挂载</span>
        </NavLink>
        <NavLink to="/settings" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Settings size={18} />
          <span>设置</span>
        </NavLink>
      </nav>

      {toasts.length > 0 && (
        <div className="toast-stack">
          {toasts.map((t) => (
            <div key={t.id} className={`toast-item ${t.kind || ''}`}>
              {t.text}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};
