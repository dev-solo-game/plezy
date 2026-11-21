import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { api, getAdminToken, setAdminToken } from '../api/client';
import type { AccentTheme, AdminPrincipal, BootstrapInfo, IdentifyQueueStats } from '../types';

export interface ToastItem {
  id: number;
  message: string;
  kind: 'info' | 'success' | 'error';
}

const ACCENT_STORAGE_KEY = 'media_library_accent_theme';

function isAccentTheme(v: string | null | undefined): v is AccentTheme {
  return v === 'glacier' || v === 'neutral' || v === 'ember' || v === 'plum';
}

interface AppContextValue {
  loading: boolean;
  bootstrap: BootstrapInfo | null;
  admin: AdminPrincipal | null;
  accentTheme: AccentTheme;
  setAccentTheme: (theme: AccentTheme) => void;
  setServerNameLocal: (name: string) => void;
  identifyQueue: IdentifyQueueStats | null;
  refreshQueue: () => Promise<void>;
  toasts: ToastItem[];
  toast: (message: string, kind?: 'info' | 'success' | 'error') => void;
  refreshAuth: () => Promise<void>;
  logout: () => Promise<void>;
}

const AppContext = createContext<AppContextValue | null>(null);

export const AppProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [loading, setLoading] = useState(true);
  const [bootstrap, setBootstrap] = useState<BootstrapInfo | null>(null);
  const [admin, setAdmin] = useState<AdminPrincipal | null>(null);
  const [identifyQueue, setIdentifyQueue] = useState<IdentifyQueueStats | null>(null);
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const [accentTheme, setAccentThemeState] = useState<AccentTheme>(() => {
    const saved = localStorage.getItem(ACCENT_STORAGE_KEY);
    return isAccentTheme(saved) ? saved : 'glacier';
  });

  useEffect(() => {
    document.documentElement.setAttribute('data-accent', accentTheme);
  }, [accentTheme]);

  const setAccentTheme = useCallback((theme: AccentTheme) => {
    setAccentThemeState(theme);
    localStorage.setItem(ACCENT_STORAGE_KEY, theme);
    document.documentElement.setAttribute('data-accent', theme);
  }, []);

  const setServerNameLocal = useCallback((name: string) => {
    setBootstrap((prev) => (prev ? { ...prev, server_name: name } : prev));
  }, []);

  const toast = useCallback((message: string, kind: 'info' | 'success' | 'error' = 'info') => {
    const id = Date.now() + Math.floor(Math.random() * 1000);
    setToasts((prev) => [...prev.slice(-3), { id, message, kind }]);
    window.setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3600);
  }, []);

  const refreshQueue = useCallback(async () => {
    if (!getAdminToken()) {
      setIdentifyQueue(null);
      return;
    }
    try {
      const res = await api.identifyStatus();
      setIdentifyQueue(res.status || null);
    } catch {
      // ignore transient polling error
    }
  }, []);

  const refreshAuth = useCallback(async () => {
    try {
      const bs = await api.bootstrap();
      setBootstrap(bs);
      if (isAccentTheme(bs.accent_theme)) {
        setAccentTheme(bs.accent_theme);
      }
    } catch {
      // ignore bootstrap error
    }
    if (!getAdminToken()) {
      setAdmin(null);
      setIdentifyQueue(null);
      setLoading(false);
      return;
    }
    try {
      const res = await api.me();
      setAdmin(res.admin);
      if (!res.admin.must_change_password) {
        void refreshQueue();
      }
    } catch {
      setAdminToken('');
      setAdmin(null);
      setIdentifyQueue(null);
    } finally {
      setLoading(false);
    }
  }, [refreshQueue, setAccentTheme]);

  useEffect(() => {
    void refreshAuth();
  }, [refreshAuth]);

  useEffect(() => {
    if (!admin || admin.must_change_password) return;
    const timer = window.setInterval(() => void refreshQueue(), 15000);
    return () => window.clearInterval(timer);
  }, [admin, refreshQueue]);

  const logout = useCallback(async () => {
    try {
      await api.logout();
    } catch {
      // ignore
    }
    setAdminToken('');
    setAdmin(null);
    setIdentifyQueue(null);
  }, []);

  return (
    <AppContext.Provider
      value={{
        loading,
        bootstrap,
        admin,
        accentTheme,
        setAccentTheme,
        setServerNameLocal,
        identifyQueue,
        refreshQueue,
        toasts,
        toast,
        refreshAuth,
        logout,
      }}
    >
      {children}
    </AppContext.Provider>
  );
};

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used within AppProvider');
  return ctx;
}
