import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { api, getAdminToken, setAdminToken } from '../api/client';
import type { AdminPrincipal, BootstrapInfo } from '../types';

export interface ToastItem {
  id: number;
  message: string;
  kind: 'info' | 'success' | 'error';
}

interface AppContextValue {
  loading: boolean;
  bootstrap: BootstrapInfo | null;
  admin: AdminPrincipal | null;
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
  const [toasts, setToasts] = useState<ToastItem[]>([]);

  const toast = useCallback((message: string, kind: 'info' | 'success' | 'error' = 'info') => {
    const id = Date.now() + Math.floor(Math.random() * 1000);
    setToasts((prev) => [...prev.slice(-3), { id, message, kind }]);
    window.setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3500);
  }, []);

  const refreshAuth = useCallback(async () => {
    try {
      const bs = await api.bootstrap();
      setBootstrap(bs);
      if (bs.accent_theme) {
        document.documentElement.setAttribute('data-accent', bs.accent_theme);
      }
    } catch {
      // ignore bootstrap error
    }
    if (!getAdminToken()) {
      setAdmin(null);
      setLoading(false);
      return;
    }
    try {
      const res = await api.me();
      setAdmin(res.admin);
    } catch {
      setAdminToken('');
      setAdmin(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshAuth();
  }, [refreshAuth]);

  const logout = useCallback(async () => {
    try {
      await api.logout();
    } catch {
      // ignore
    }
    setAdminToken('');
    setAdmin(null);
  }, []);

  return (
    <AppContext.Provider value={{ loading, bootstrap, admin, toasts, toast, refreshAuth, logout }}>
      {children}
    </AppContext.Provider>
  );
};

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used within AppProvider');
  return ctx;
}
