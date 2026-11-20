import React, { useCallback, useEffect, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { api, formatDateTime } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { AuditLogRecord } from '../types';

export const AdminAuditPage: React.FC = () => {
  const { toast, refreshAuth } = useApp();
  const [logs, setLogs] = useState<AuditLogRecord[]>([]);
  const [oldPw, setOldPw] = useState('');
  const [newUser, setNewUser] = useState('');
  const [newPw, setNewPw] = useState('');
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    try {
      const res = await api.listAuditLogs({ limit: 100 });
      setLogs(res.logs || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleChangePw = async (e: React.FormEvent) => {
    e.preventDefault();
    if (saving) return;
    setSaving(true);
    try {
      await api.changePassword(oldPw, newPw, newUser.trim() || undefined);
      setOldPw('');
      setNewPw('');
      setNewUser('');
      toast('管理员凭据已更新', 'success');
      await refreshAuth();
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 1080 }}>
      <h1 style={{ margin: 0, fontSize: 22 }}>审计日志与管理员安全</h1>

      <form onSubmit={handleChangePw} className="panel" style={{ padding: 18, display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
        <span style={{ fontWeight: 600, width: '100%' }}>修改平台管理员账号与密码</span>
        <input className="input" placeholder="新用户名（可选）" value={newUser} onChange={(e) => setNewUser(e.target.value)} style={{ width: 180 }} />
        <input className="input" type="password" required placeholder="当前密码" value={oldPw} onChange={(e) => setOldPw(e.target.value)} style={{ width: 180 }} />
        <input className="input" type="password" required minLength={8} placeholder="新密码（≥8位）" value={newPw} onChange={(e) => setNewPw(e.target.value)} style={{ width: 200 }} />
        <button type="submit" className="btn btn-primary" disabled={saving}>更新管理员凭据</button>
      </form>

      <div className="panel" style={{ padding: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <h3 style={{ margin: 0, fontSize: 15 }}>近期审计日志</h3>
          <button type="button" className="btn" onClick={() => void load()}><RefreshCw size={14} /> 刷新</button>
        </div>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1px solid var(--border-subtle)', color: 'var(--text-muted)' }}>
              <th style={{ padding: '8px 6px' }}>时间</th>
              <th style={{ padding: '8px 6px' }}>操作者</th>
              <th style={{ padding: '8px 6px' }}>动作</th>
              <th style={{ padding: '8px 6px' }}>对象</th>
              <th style={{ padding: '8px 6px' }}>IP</th>
            </tr>
          </thead>
          <tbody>
            {logs.map((l) => (
              <tr key={l.id} style={{ borderBottom: '1px solid var(--border-subtle)' }}>
                <td style={{ padding: '8px 6px' }}>{formatDateTime(l.created_at)}</td>
                <td style={{ padding: '8px 6px' }}>{l.actor_type}:{l.actor_id.slice(0, 8)}</td>
                <td style={{ padding: '8px 6px', fontFamily: 'var(--font-mono)' }}>{l.action}</td>
                <td style={{ padding: '8px 6px' }}>{l.target_type || '-'} {l.target_id ? `(${l.target_id.slice(0, 16)})` : ''}</td>
                <td style={{ padding: '8px 6px' }}>{l.ip || '-'}</td>
              </tr>
            ))}
            {logs.length === 0 && (
              <tr>
                <td colSpan={5} style={{ padding: 18, textAlign: 'center' }} className="muted">暂无审计记录</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};
