import React from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { Clapperboard, Loader2 } from 'lucide-react';
import { AppShell } from './components/AppShell';
import { ToastStack } from './components/ToastStack';
import { AppProvider, useApp } from './contexts/AppContext';
import { AdminAccountsPage } from './pages/AdminAccountsPage';
import { AdminAuditPage } from './pages/AdminAuditPage';
import { AdminInvitesPage } from './pages/AdminInvitesPage';
import { AdminOverviewPage } from './pages/AdminOverviewPage';
import { LoginPage } from './pages/LoginPage';
import { MetadataManagePage } from './pages/MetadataManagePage';
import { ServerLogsPage } from './pages/ServerLogsPage';
import { SettingsPage } from './pages/SettingsPage';

const AdminRoutes: React.FC = () => {
  const { loading, admin } = useApp();

  if (loading) {
    return (
      <div className="auth-screen">
        <div className="glass-panel" style={{ padding: '24px 32px', display: 'flex', alignItems: 'center', gap: 14 }}>
          <span className="brand-mark">
            <Clapperboard size={18} />
          </span>
          <div className="flex-row" style={{ gap: 8 }}>
            <Loader2 size={16} className="spin" style={{ color: 'var(--accent)' }} />
            <span style={{ fontSize: 14, color: 'var(--text-secondary)' }}>正在加载管理控制台...</span>
          </div>
        </div>
      </div>
    );
  }

  if (!admin || admin.must_change_password) {
    return <LoginPage />;
  }

  return (
    <AppShell>
      <Routes>
        <Route path="/admin" element={<AdminOverviewPage />} />
        <Route path="/admin/accounts" element={<AdminAccountsPage />} />
        <Route path="/admin/invites" element={<AdminInvitesPage />} />
        <Route path="/admin/settings" element={<SettingsPage />} />
        <Route path="/admin/metadata" element={<MetadataManagePage />} />
        <Route path="/admin/logs" element={<ServerLogsPage />} />
        <Route path="/admin/audit" element={<AdminAuditPage />} />
        <Route path="*" element={<Navigate to="/admin" replace />} />
      </Routes>
    </AppShell>
  );
};

class AppErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: Error | null }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <div className="auth-screen">
          <div className="glass-panel auth-card" style={{ maxWidth: 520 }}>
            <h2 style={{ margin: 0, fontSize: 18, color: 'var(--danger)' }}>页面渲染发生异常</h2>
            <p className="muted" style={{ margin: 0, fontSize: 13, lineHeight: 1.5 }}>
              {this.state.error.message || '未知前端错误'}
            </p>
            <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
              <button type="button" className="btn btn-primary" onClick={() => window.location.reload()}>
                重新加载页面
              </button>
            </div>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

export const App: React.FC = () => (
  <AppErrorBoundary>
    <AppProvider>
      <BrowserRouter>
        <AdminRoutes />
        <ToastStack />
      </BrowserRouter>
    </AppProvider>
  </AppErrorBoundary>
);

export default App;
