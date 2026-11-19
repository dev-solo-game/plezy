import React, { Suspense, lazy, useEffect } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from './components/AppShell';
import { AppProvider, useApp } from './contexts/AppContext';
import { HomePage } from './pages/HomePage';
import { LoginPage } from './pages/LoginPage';

// Route-level code splitting: only the shell, home and login ship in the entry
// bundle. Heavy pages (player + hls.js, settings, mount editor + qrcode, ...)
// load on demand, and the common browse/detail/player chunks are warmed while
// the browser is idle.
const loaders = {
  ExternalItemDetailPage: () => import('./pages/ExternalItemDetailPage'),
  ExternalLibraryBrowsePage: () => import('./pages/ExternalLibraryBrowsePage'),
  ExternalServerHomePage: () => import('./pages/ExternalServerHomePage'),
  ExternalServersManagePage: () => import('./pages/ExternalServersManagePage'),
  FolderBrowserPage: () => import('./pages/FolderBrowserPage'),
  ItemDetailPage: () => import('./pages/ItemDetailPage'),
  LibraryBrowsePage: () => import('./pages/LibraryBrowsePage'),
  ListDetailPage: () => import('./pages/ListDetailPage'),
  ListsPage: () => import('./pages/ListsPage'),
  MetadataManagePage: () => import('./pages/MetadataManagePage'),
  MountsManagePage: () => import('./pages/MountsManagePage'),
  PersonPage: () => import('./pages/PersonPage'),
  PlayerPage: () => import('./pages/PlayerPage'),
  SearchPage: () => import('./pages/SearchPage'),
  ServerLogsPage: () => import('./pages/ServerLogsPage'),
  SettingsPage: () => import('./pages/SettingsPage'),
  SetupPage: () => import('./pages/SetupPage'),
  UnmatchedPage: () => import('./pages/UnmatchedPage'),
};

function lazyPage<K extends keyof typeof loaders>(name: K) {
  return lazy(async () => {
    const mod = (await loaders[name]()) as unknown as Record<string, React.ComponentType<any>>;
    return { default: mod[name] };
  });
}

const ExternalItemDetailPage = lazyPage('ExternalItemDetailPage');
const ExternalLibraryBrowsePage = lazyPage('ExternalLibraryBrowsePage');
const ExternalServerHomePage = lazyPage('ExternalServerHomePage');
const ExternalServersManagePage = lazyPage('ExternalServersManagePage');
const FolderBrowserPage = lazyPage('FolderBrowserPage');
const ItemDetailPage = lazyPage('ItemDetailPage');
const LibraryBrowsePage = lazyPage('LibraryBrowsePage');
const ListDetailPage = lazyPage('ListDetailPage');
const ListsPage = lazyPage('ListsPage');
const MetadataManagePage = lazyPage('MetadataManagePage');
const MountsManagePage = lazyPage('MountsManagePage');
const PersonPage = lazyPage('PersonPage');
const PlayerPage = lazyPage('PlayerPage');
const SearchPage = lazyPage('SearchPage');
const ServerLogsPage = lazyPage('ServerLogsPage');
const SettingsPage = lazyPage('SettingsPage');
const SetupPage = lazyPage('SetupPage');
const UnmatchedPage = lazyPage('UnmatchedPage');

function warmCommonChunks() {
  const warm = () => {
    void loaders.LibraryBrowsePage();
    void loaders.ItemDetailPage();
    void loaders.PlayerPage();
    void loaders.SearchPage();
  };
  const ric = (window as unknown as { requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number })
    .requestIdleCallback;
  if (ric) {
    ric(warm, { timeout: 4000 });
  } else {
    window.setTimeout(warm, 1500);
  }
}

const PageFallback: React.FC = () => <div className="muted" style={{ padding: 24 }} />;

const AppRoutes: React.FC = () => {
  const { loading, bootstrap, username } = useApp();

  useEffect(() => {
    if (username) warmCommonChunks();
  }, [username]);

  if (loading) {
    return (
      <div className="auth-screen">
        <div className="muted">正在连接 TTPlay Media Server...</div>
      </div>
    );
  }

  if (bootstrap && !bootstrap.initialized) {
    return (
      <Suspense fallback={<PageFallback />}>
        <Routes>
          <Route path="/setup" element={<SetupPage />} />
          <Route path="*" element={<Navigate to="/setup" replace />} />
        </Routes>
      </Suspense>
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
    <Suspense fallback={<PageFallback />}>
      <Routes>
        <Route path="/play/:itemId" element={<PlayerPage />} />
        <Route path="/play/file/:fileId" element={<PlayerPage />} />
        <Route path="/play/ext/:serverId/:extItemId" element={<PlayerPage />} />
        <Route
          path="*"
          element={
            <AppShell>
              <Suspense fallback={<PageFallback />}>
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
                  <Route path="/manage/servers" element={<ExternalServersManagePage />} />
                  <Route path="/ext/:serverId" element={<ExternalServerHomePage />} />
                  <Route path="/ext/:serverId/library/:viewId" element={<ExternalLibraryBrowsePage />} />
                  <Route path="/ext/:serverId/item/:itemId" element={<ExternalItemDetailPage />} />
                  <Route path="/manage/unmatched" element={<UnmatchedPage />} />
                  <Route path="/manage/metadata" element={<MetadataManagePage />} />
                  <Route path="/manage/logs" element={<ServerLogsPage />} />
                  <Route path="/settings" element={<SettingsPage />} />
                  <Route path="*" element={<Navigate to="/" replace />} />
                </Routes>
              </Suspense>
            </AppShell>
          }
        />
      </Routes>
    </Suspense>
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
