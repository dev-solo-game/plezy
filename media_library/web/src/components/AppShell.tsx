import React from 'react';
import { NavLink } from 'react-router-dom';
import {
  Activity,
  Database,
  LogOut,
  ScrollText,
  Settings,
  Shield,
  Ticket,
  Users,
} from 'lucide-react';
import { useApp } from '../contexts/AppContext';

export const AppShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { bootstrap, admin, toasts, logout } = useApp();
  const title = bootstrap?.server_name || 'Media Library 管理后台';

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand-row">
          <div className="brand-logo" title={title}>
            <span className="brand-mark">
              <Shield size={18} />
            </span>
            <span className="brand-title">{title}</span>
          </div>
        </div>

        <div className="sidebar-scroll">
          <div>
            <div className="nav-group-label">平台运维（隐私隔离）</div>
            <nav className="nav-list">
              <NavLink to="/admin" end className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Activity size={18} />
                <span className="nav-text">平台概览与队列</span>
              </NavLink>
              <NavLink to="/admin/accounts" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Users size={18} />
                <span className="nav-text">用户账号管理</span>
              </NavLink>
              <NavLink to="/admin/invites" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Ticket size={18} />
                <span className="nav-text">注册与邀请码</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">刮削与系统</div>
            <nav className="nav-list">
              <NavLink to="/admin/settings" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Settings size={18} />
                <span className="nav-text">刮削与策略设置</span>
              </NavLink>
              <NavLink to="/admin/metadata" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Database size={18} />
                <span className="nav-text">公共元数据缓存</span>
              </NavLink>
              <NavLink to="/admin/logs" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <ScrollText size={18} />
                <span className="nav-text">系统运行日志</span>
              </NavLink>
              <NavLink to="/admin/audit" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
                <Shield size={18} />
                <span className="nav-text">审计日志与安全</span>
              </NavLink>
            </nav>
          </div>
        </div>

        <div style={{ padding: 14, borderTop: '1px solid var(--border-subtle)', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
          <div style={{ fontSize: 13, color: 'var(--text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            管理员：{admin?.username || 'admin'}
          </div>
          <button type="button" className="btn btn-icon" title="退出登录" onClick={() => void logout()}>
            <LogOut size={15} />
          </button>
        </div>
      </aside>

      <main className="main-area" style={{ flex: 1, minWidth: 0, padding: '24px 28px', overflowY: 'auto' }}>
        {children}
      </main>

      {toasts.length > 0 && (
        <div className="toast-stack">
          {toasts.map((t) => (
            <div key={t.id} className={`toast toast-${t.kind}`}>
              {t.message}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};
