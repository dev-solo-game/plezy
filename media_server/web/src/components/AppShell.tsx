import React, { useState } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';
import {
  AlertCircle,
  Bookmark,
  Clapperboard,
  Compass,
  Film,
  FolderOpen,
  HardDrive,
  Heart,
  Home,
  Layers,
  Loader2,
  PanelLeftClose,
  PanelLeftOpen,
  Search,
  Settings,
  Sparkles,
  Tv,
  Video,
} from 'lucide-react';
import { useApp } from '../contexts/AppContext';

export const AppShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { bootstrap, username, scanProgress, scrapeProgress, unmatchedCount, toasts } = useApp();
  const [collapsed, setCollapsed] = useState(false);
  const [searchQ, setSearchQ] = useState('');
  const navigate = useNavigate();

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
              <NavLink to="/" end className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Home size={18} />
                <span className="nav-text">首页推荐</span>
              </NavLink>
              <NavLink to="/library/movie" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Film size={18} />
                <span className="nav-text">电影</span>
              </NavLink>
              <NavLink to="/library/show" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Tv size={18} />
                <span className="nav-text">剧集</span>
              </NavLink>
              <NavLink to="/library/anime" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Sparkles size={18} />
                <span className="nav-text">动漫</span>
              </NavLink>
              <NavLink to="/library/variety" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Video size={18} />
                <span className="nav-text">综艺</span>
              </NavLink>
              <NavLink to="/library/documentary" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Compass size={18} />
                <span className="nav-text">纪录片</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">集合与浏览</div>
            <nav className="nav-list">
              <NavLink to="/favorites" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Heart size={18} />
                <span className="nav-text">我的收藏</span>
              </NavLink>
              <NavLink to="/lists" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Layers size={18} />
                <span className="nav-text">合集与播单</span>
              </NavLink>
              <NavLink to="/folders" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <FolderOpen size={18} />
                <span className="nav-text">文件夹浏览</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">服务器管理</div>
            <nav className="nav-list">
              <NavLink to="/manage/mounts" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <HardDrive size={18} />
                <span className="nav-text">存储挂载</span>
              </NavLink>
              <NavLink to="/manage/unmatched" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <AlertCircle size={18} />
                <span className="nav-text">待匹配中心</span>
                {unmatchedCount > 0 && <span className="nav-badge warn">{unmatchedCount}</span>}
              </NavLink>
              <NavLink to="/settings" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Settings size={18} />
                <span className="nav-text">系统设置</span>
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

          <div className="topbar-right">
            {scanProgress && (
              <div className="task-pill" title={scanProgress.current_path || ''}>
                <Loader2 size={14} className="spin" />
                <span>
                  扫描 {scanProgress.mount_name}: {scanProgress.files_seen} 文件
                </span>
              </div>
            )}
            {scrapeProgress && (
              <div className="task-pill">
                <Loader2 size={14} className="spin" />
                <span>
                  刮削 {scrapeProgress.done}/{scrapeProgress.total} · {scrapeProgress.title}
                </span>
              </div>
            )}
            <NavLink to="/library/all" className="btn btn-sm" title="全部媒体库">
              <Bookmark size={14} />
              <span>全部库</span>
            </NavLink>
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
