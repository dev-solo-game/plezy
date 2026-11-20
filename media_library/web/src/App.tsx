import React from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from './components/AppShell';
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
    return <div className="muted" style={{ padding: 32 }}>加载中...</div>;
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

export const App: React.FC = () => (
  <AppProvider>
    <BrowserRouter>
      <AdminRoutes />
    </BrowserRouter>
  </AppProvider>
);

export default App;
