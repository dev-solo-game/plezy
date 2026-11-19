import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { api } from '../api/client';
import type { AccentTheme, BootstrapInfo, ScanProgressEvent, ScrapeProgressEvent } from '../types';

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
  scanProgress: ScanProgressEvent | null;
  scrapeProgress: ScrapeProgressEvent | null;
  libraryVersion: number;
  bumpLibraryVersion: () => void;
  unmatchedCount: number;
  setUnmatchedCount: (n: number) => void;
  toasts: ToastMessage[];
  toast: (text: string, kind?: ToastMessage['kind']) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

export const AppProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [loading, setLoading] = useState(true);
  const [bootstrap, setBootstrap] = useState<BootstrapInfo | null>(null);
  const [username, setUsername] = useState<string | null>(null);
  const [accentTheme, setAccentState] = useState<AccentTheme>('glacier');
  const [scanProgress, setScanProgress] = useState<ScanProgressEvent | null>(null);
  const [scrapeProgress, setScrapeProgress] = useState<ScrapeProgressEvent | null>(null);
  const [libraryVersion, setLibraryVersion] = useState(0);
  const [unmatchedCount, setUnmatchedCount] = useState(0);
  const [toasts, setToasts] = useState<ToastMessage[]>([]);

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
    if (!username) return;
    let es: EventSource | null = null;
    try {
      es = new EventSource('/api/v1/events', { withCredentials: true });
      es.addEventListener('scan_progress', (ev) => {
        try {
          const parsed = JSON.parse((ev as MessageEvent).data) as { data?: ScanProgressEvent } & ScanProgressEvent;
          const p = parsed.data ?? parsed;
          if (p.status === 'done' || p.status === 'failed' || p.status === 'cancelled') {
            setScanProgress(null);
            setLibraryVersion((v) => v + 1);
          } else {
            setScanProgress(p);
          }
        } catch {
          // ignore malformed event
        }
      });
      es.addEventListener('scrape_progress', (ev) => {
        try {
          const parsed = JSON.parse((ev as MessageEvent).data) as { data?: ScrapeProgressEvent } & ScrapeProgressEvent;
          const p = parsed.data ?? parsed;
          if (p.status === 'done' || p.total === 0) {
            setScrapeProgress(null);
            setLibraryVersion((v) => v + 1);
          } else {
            setScrapeProgress(p);
          }
        } catch {
          // ignore
        }
      });
      es.addEventListener('library_changed', () => {
        setLibraryVersion((v) => v + 1);
      });
    } catch {
      // EventSource not supported or failed
    }
    return () => {
      es?.close();
    };
  }, [username]);

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
        scanProgress,
        scrapeProgress,
        libraryVersion,
        bumpLibraryVersion,
        unmatchedCount,
        setUnmatchedCount,
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
