import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { api } from '../api/client';
import { prefetchHome } from '../api/prefetch';
import { clearQueryCache } from '../api/queryCache';
import type { AccentTheme, BootstrapInfo, ExternalServerRecord, ScanProgressEvent, ScrapeProgressEvent } from '../types';

export interface ToastMessage {
  id: number;
  text: string;
  kind?: 'info' | 'success' | 'error';
}

interface AppContextValue {
  loading: boolean;
  bootstrap: BootstrapInfo | null;
  username: string | null;
  accentTheme: AccentTheme;
  setAccentTheme: (accent: AccentTheme) => void;
  setServerNameLocal: (name: string) => void;
  refreshAuth: () => Promise<void>;
  activeScans: ScanProgressEvent[];
  scanProgress: ScanProgressEvent | null;
  scrapeProgress: ScrapeProgressEvent | null;
  pendingScrapeCount: number;
  dismissScrapeBanner: () => void;
  refreshTaskStatus: () => Promise<void>;
  libraryVersion: number;
  bumpLibraryVersion: () => void;
  unmatchedCount: number;
  setUnmatchedCount: (n: number) => void;
  externalServers: ExternalServerRecord[];
  refreshExternalServers: () => Promise<void>;
  toasts: ToastMessage[];
  toast: (text: string, kind?: ToastMessage['kind']) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

export const AppProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [loading, setLoading] = useState(true);
  const [bootstrap, setBootstrap] = useState<BootstrapInfo | null>(null);
  const [username, setUsername] = useState<string | null>(null);
  const [accentTheme, setAccentState] = useState<AccentTheme>('glacier');
  const [activeScans, setActiveScans] = useState<ScanProgressEvent[]>([]);
  const [scrapeProgress, setScrapeProgress] = useState<ScrapeProgressEvent | null>(null);
  const [pendingScrapeCount, setPendingScrapeCount] = useState(0);
  const [libraryVersion, setLibraryVersion] = useState(0);
  const [unmatchedCount, setUnmatchedCount] = useState(0);
  const [externalServers, setExternalServers] = useState<ExternalServerRecord[]>([]);
  const [toasts, setToasts] = useState<ToastMessage[]>([]);

  const libRefreshTimerRef = useRef<number | null>(null);
  const lastLibRefreshAtRef = useRef<number>(0);
  const scrapeClearTimerRef = useRef<number | null>(null);

  const toast = useCallback((text: string, kind: ToastMessage['kind'] = 'info') => {
    const id = Date.now() + Math.floor(Math.random() * 1000);
    setToasts((prev) => [...prev.slice(-3), { id, text, kind }]);
    window.setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3600);
  }, []);

  const setAccentTheme = useCallback((accent: AccentTheme) => {
    setAccentState(accent);
    document.documentElement.setAttribute('data-accent', accent);
  }, []);

  const setServerNameLocal = useCallback((name: string) => {
    setBootstrap((prev) => (prev ? { ...prev, server_name: name } : prev));
  }, []);

  const bumpLibraryVersion = useCallback(() => {
    setLibraryVersion((v) => v + 1);
  }, []);

  const scheduleLibraryRefresh = useCallback(() => {
    const now = Date.now();
    if (now - lastLibRefreshAtRef.current > 1500 && libRefreshTimerRef.current === null) {
      lastLibRefreshAtRef.current = now;
      setLibraryVersion((v) => v + 1);
      return;
    }
    if (libRefreshTimerRef.current !== null) return;
    libRefreshTimerRef.current = window.setTimeout(() => {
      libRefreshTimerRef.current = null;
      lastLibRefreshAtRef.current = Date.now();
      setLibraryVersion((v) => v + 1);
    }, 1200);
  }, []);

  const dismissScrapeBanner = useCallback(() => {
    if (scrapeClearTimerRef.current !== null) {
      window.clearTimeout(scrapeClearTimerRef.current);
      scrapeClearTimerRef.current = null;
    }
    setScrapeProgress(null);
  }, []);

  const refreshTaskStatus = useCallback(async () => {
    if (!username) return;
    try {
      const res = await api.getTaskStatus();
      const st = res.status;
      setActiveScans(st.scans || []);
      setPendingScrapeCount(st.pending_scrape || 0);
      setUnmatchedCount(st.unmatched_count || 0);
      if (st.scrape && st.scrape.status !== 'idle') {
        setScrapeProgress(st.scrape);
      } else {
        setScrapeProgress(null);
      }
    } catch {
      // ignore transient network errors
    }
  }, [username]);

  const refreshExternalServers = useCallback(async () => {
    if (!username) {
      setExternalServers([]);
      return;
    }
    try {
      const res = await api.listExternalServers();
      setExternalServers(res.servers || []);
    } catch {
      // ignore transient network errors
    }
  }, [username]);

  const refreshAuth = useCallback(async () => {
    setLoading(true);
    try {
      const boot = await api.bootstrap();
      setBootstrap(boot);
      setAccentTheme(boot.accent_theme || 'glacier');
      if (boot.initialized) {
        try {
          const me = await api.me();
          setUsername(me.username);
        } catch {
          setUsername(null);
        }
      } else {
        setUsername(null);
      }
    } finally {
      setLoading(false);
    }
  }, [setAccentTheme]);

  useEffect(() => {
    void refreshAuth();
  }, [refreshAuth]);

  useEffect(() => {
    if (!username) {
      clearQueryCache();
      setActiveScans([]);
      setScrapeProgress(null);
      setPendingScrapeCount(0);
      setExternalServers([]);
      return;
    }
    prefetchHome();
    void refreshTaskStatus();
    void refreshExternalServers();

    let es: EventSource | null = null;
    try {
      es = new EventSource('/api/v1/events', { withCredentials: true });
      es.onopen = () => {
        void refreshTaskStatus();
      };
      es.addEventListener('scan_progress', (ev) => {
        try {
          const parsed = JSON.parse((ev as MessageEvent).data) as { data?: ScanProgressEvent } & ScanProgressEvent;
          const p = parsed.data ?? parsed;
          if (
            p.status === 'completed' ||
            p.status === 'done' ||
            p.status === 'failed' ||
            p.status === 'cancelled'
          ) {
            setActiveScans((prev) => prev.filter((s) => s.mount_id !== p.mount_id));
            scheduleLibraryRefresh();
            void refreshTaskStatus();
          } else {
            setActiveScans((prev) => {
              const idx = prev.findIndex((s) => s.mount_id === p.mount_id);
              if (idx >= 0) {
                const next = [...prev];
                next[idx] = p;
                return next;
              }
              return [...prev, p];
            });
          }
        } catch {
          // ignore malformed event
        }
      });

      es.addEventListener('scrape_progress', (ev) => {
        try {
          const parsed = JSON.parse((ev as MessageEvent).data) as { data?: ScrapeProgressEvent } & ScrapeProgressEvent;
          const p = parsed.data ?? parsed;
          if (scrapeClearTimerRef.current !== null) {
            window.clearTimeout(scrapeClearTimerRef.current);
            scrapeClearTimerRef.current = null;
          }
          if (p.status === 'idle') {
            setScrapeProgress(null);
          } else if (p.status === 'completed' || p.status === 'done') {
            setScrapeProgress(p);
            scheduleLibraryRefresh();
            void refreshTaskStatus();
            scrapeClearTimerRef.current = window.setTimeout(() => {
              scrapeClearTimerRef.current = null;
              setScrapeProgress((cur) => (cur && (cur.status === 'completed' || cur.status === 'done') ? null : cur));
            }, 4000);
          } else if (p.status === 'warning') {
            setScrapeProgress(p);
            scheduleLibraryRefresh();
            void refreshTaskStatus();
          } else {
            setScrapeProgress(p);
          }
        } catch {
          // ignore
        }
      });

      es.addEventListener('library_changed', () => {
        scheduleLibraryRefresh();
      });
    } catch {
      // EventSource not supported or failed
    }
    return () => {
      es?.close();
      if (libRefreshTimerRef.current !== null) {
        window.clearTimeout(libRefreshTimerRef.current);
        libRefreshTimerRef.current = null;
      }
      if (scrapeClearTimerRef.current !== null) {
        window.clearTimeout(scrapeClearTimerRef.current);
        scrapeClearTimerRef.current = null;
      }
    };
  }, [username, refreshTaskStatus, refreshExternalServers, scheduleLibraryRefresh]);

  return (
    <AppContext.Provider
      value={{
        loading,
        bootstrap,
        username,
        accentTheme,
        setAccentTheme,
        setServerNameLocal,
        refreshAuth,
        activeScans,
        scanProgress: activeScans[0] ?? null,
        scrapeProgress,
        pendingScrapeCount,
        dismissScrapeBanner,
        refreshTaskStatus,
        libraryVersion,
        bumpLibraryVersion,
        unmatchedCount,
        setUnmatchedCount,
        externalServers,
        refreshExternalServers,
        toasts,
        toast,
      }}
    >
      {children}
    </AppContext.Provider>
  );
};

export function useApp() {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used within AppProvider');
  return ctx;
}
