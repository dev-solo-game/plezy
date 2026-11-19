import React from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from './components/AppShell';
import { AppProvider, useApp } from './contexts/AppContext';
import { FolderBrowserPage } from './pages/FolderBrowserPage';
import { HomePage } from './pages/HomePage';
import { ItemDetailPage } from './pages/ItemDetailPage';
import { LibraryBrowsePage } from './pages/LibraryBrowsePage';
import { ListDetailPage } from './pages/ListDetailPage';
import { ListsPage } from './pages/ListsPage';
import { LoginPage } from './pages/LoginPage';
import { MountsManagePage } from './pages/MountsManagePage';
import { PersonPage } from './pages/PersonPage';
import { PlayerPage } from './pages/PlayerPage';
import { SearchPage } from './pages/SearchPage';
import { SettingsPage } from './pages/SettingsPage';
import { SetupPage } from './pages/SetupPage';
import { UnmatchedPage } from './pages/UnmatchedPage';

const AppRoutes: React.FC = () => {
  const { loading, bootstrap, username } = useApp();

  if (loading) {
    return (
      <div className="auth-screen">
        <div className="muted">正在连接 TTPlay Media Server...</div>
      </div>
    );
  }

  if (bootstrap && !bootstrap.initialized) {
    return (
      <Routes>
        <Route path="/setup" element={<SetupPage />} />
        <Route path="*" element={<Navigate to="/setup" replace />} />
      </Routes>
    );
  }

  if (!username) {
    return (
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    );
  }

  return (
    <Routes>
      <Route path="/play/:itemId" element={<PlayerPage />} />
      <Route path="/play/file/:fileId" element={<PlayerPage />} />
      <Route
        path="*"
        element={
          <AppShell>
            <Routes>
              <Route path="/" element={<HomePage />} />
              <Route path="/library/:shelf" element={<LibraryBrowsePage />} />
              <Route path="/favorites" element={<LibraryBrowsePage favoritesOnly />} />
              <Route path="/lists" element={<ListsPage />} />
              <Route path="/lists/:id" element={<ListDetailPage />} />
              <Route path="/folders" element={<FolderBrowserPage />} />
              <Route path="/search" element={<SearchPage />} />
              <Route path="/person/:id" element={<PersonPage />} />
              <Route path="/item/:id" element={<ItemDetailPage />} />
              <Route path="/manage/mounts" element={<MountsManagePage />} />
              <Route path="/manage/unmatched" element={<UnmatchedPage />} />
              <Route path="/settings" element={<SettingsPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </AppShell>
        }
      />
    </Routes>
  );
};

export function App() {
  return (
    <AppProvider>
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    </AppProvider>
  );
}

export default App;
