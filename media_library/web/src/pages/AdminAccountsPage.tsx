import React, { useCallback, useEffect, useState } from 'react';
import { Plus, RefreshCw, Search } from 'lucide-react';
import { api, formatBytes, formatDateTime } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { AccountSummary } from '../types';

export const AdminAccountsPage: React.FC = () => {
  const { toast } = useApp();
  const [accounts, setAccounts] = useState<AccountSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [q, setQ] = useState('');
  const [loading, setLoading] = useState(true);

  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listAccounts({ q: q.trim() || undefined, limit: 100 });
      setAccounts(res.accounts || []);
      setTotal(res.total || 0);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [q, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (creating) return;
    setCreating(true);
    try {
      await api.createAccount({
        username: newUsername.trim(),
        password: newPassword,
        email: newEmail.trim() || undefined,
      });
      setNewUsername('');
      setNewPassword('');
      setNewEmail('');
      toast('用户账号已创建', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const handleResetPassword = async (acc: AccountSummary) => {
    const pw = window.prompt(
      `重置账号「${acc.username}」的密码（至少 8 位）。\n注意：端到端加密的媒体源凭据在重置密码后将需要用户在客户端重新验证。`
    );
    if (!pw) return;
    try {
      await api.resetAccountPassword(acc.id, pw);
      toast(`已重置 ${acc.username} 的密码`, 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 1180 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12 }}>
        <h1 style={{ margin: 0, fontSize: 22 }}>用户账号管理（共 {total} 个）</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="input"
            placeholder="搜索用户名或邮箱..."
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && void load()}
          />
          <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
            <Search size={14} /> 搜索
          </button>
          <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={14} />
          </button>
        </div>
      </div>

      <form onSubmit={handleCreate} className="panel" style={{ padding: 16, display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
        <input className="input" required placeholder="新用户名" value={newUsername} onChange={(e) => setNewUsername(e.target.value)} style={{ width: 180 }} />
        <input className="input" type="password" required minLength={8} placeholder="初始密码（≥8位）" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} style={{ width: 200 }} />
        <input className="input" placeholder="邮箱（可选）" value={newEmail} onChange={(e) => setNewEmail(e.target.value)} style={{ width: 220 }} />
        <button type="submit" className="btn btn-primary" disabled={creating}>
          <Plus size={14} /> 创建用户
        </button>
      </form>

      <div className="panel" style={{ padding: 16, overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1px solid var(--border-subtle)', color: 'var(--text-muted)' }}>
              <th style={{ padding: '8px 6px' }}>用户名 / 邮箱</th>
              <th style={{ padding: '8px 6px' }}>状态</th>
              <th style={{ padding: '8px 6px' }}>统计（设备 / 源 / 作品 / 文件 / 旁路）</th>
              <th style={{ padding: '8px 6px' }}>注册时间 / IP</th>
              <th style={{ padding: '8px 6px' }}>操作</th>
            </tr>
          </thead>
          <tbody>
            {accounts.map((acc) => (
              <tr key={acc.id} style={{ borderBottom: '1px solid var(--border-subtle)' }}>
                <td style={{ padding: '10px 6px' }}>
                  <div style={{ fontWeight: 600 }}>{acc.username}</div>
                  {acc.email && <div className="muted" style={{ fontSize: 12 }}>{acc.email}</div>}
                </td>
                <td style={{ padding: '10px 6px' }}>{acc.status}</td>
                <td style={{ padding: '10px 6px' }}>
                  {acc.device_count} 台 / {acc.source_count} 源 / {acc.item_count} 作品 / {acc.file_count} 文件 / {formatBytes(acc.sidecar_bytes)}
                </td>
                <td style={{ padding: '10px 6px' }}>
                  <div>{formatDateTime(acc.created_at)}</div>
                  <div className="muted" style={{ fontSize: 12 }}>{acc.register_ip || '-'}</div>
                </td>
                <td style={{ padding: '10px 6px' }}>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                    {acc.status === 'active' ? (
                      <button
                        type="button"
                        className="btn"
                        onClick={() => void api.setAccountStatus(acc.id, 'disabled').then(() => { toast('已禁用', 'info'); return load(); }).catch((e) => toast((e as Error).message, 'error'))}
                      >
                        禁用
                      </button>
                    ) : acc.status === 'disabled' ? (
                      <button
                        type="button"
                        className="btn"
                        onClick={() => void api.setAccountStatus(acc.id, 'active').then(() => { toast('已启用', 'success'); return load(); }).catch((e) => toast((e as Error).message, 'error'))}
                      >
                        启用
                      </button>
                    ) : (
                      <button
                        type="button"
                        className="btn"
                        onClick={() => void api.restoreAccount(acc.id).then(() => { toast('已恢复账号', 'success'); return load(); }).catch((e) => toast((e as Error).message, 'error'))}
                      >
                        恢复
                      </button>
                    )}
                    <button type="button" className="btn" onClick={() => void handleResetPassword(acc)}>
                      重置密码
                    </button>
                    <button
                      type="button"
                      className="btn"
                      onClick={() => void api.forceLogoutAccount(acc.id).then(() => toast('已强制下线', 'info')).catch((e) => toast((e as Error).message, 'error'))}
                    >
                      强退
                    </button>
                    {acc.status !== 'pending_delete' && (
                      <button
                        type="button"
                        className="btn"
                        style={{ color: 'var(--danger)' }}
                        onClick={() => {
                          if (window.confirm(`确认将账号「${acc.username}」标记为待删除？`)) {
                            void api.scheduleDeleteAccount(acc.id).then(() => { toast('已进入冷静期', 'info'); return load(); }).catch((e) => toast((e as Error).message, 'error'));
                          }
                        }}
                      >
                        删除
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {accounts.length === 0 && (
              <tr>
                <td colSpan={5} style={{ padding: 20, textAlign: 'center' }} className="muted">
                  暂无用户账号
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};
