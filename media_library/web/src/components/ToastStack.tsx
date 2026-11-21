import React from 'react';
import { AlertCircle, CheckCircle2, Info } from 'lucide-react';
import { useApp } from '../contexts/AppContext';

/**
 * Global toast notification stack rendered across both unauthenticated and authenticated views.
 */
export const ToastStack: React.FC = () => {
  const { toasts } = useApp();
  if (toasts.length === 0) return null;

  return (
    <div className="toast-stack" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast-item ${t.kind}`}>
          <div className="flex-row" style={{ gap: 8, flexWrap: 'nowrap' }}>
            {t.kind === 'success' ? (
              <CheckCircle2 size={15} style={{ flexShrink: 0 }} />
            ) : t.kind === 'error' ? (
              <AlertCircle size={15} style={{ flexShrink: 0 }} />
            ) : (
              <Info size={15} style={{ flexShrink: 0, color: 'var(--accent)' }} />
            )}
            <span>{t.message}</span>
          </div>
        </div>
      ))}
    </div>
  );
};
