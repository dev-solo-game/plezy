import React, { useState } from 'react';
import { Shield } from 'lucide-react';
import { api, setAdminToken } from '../api/client';
import { useApp } from '../contexts/AppContext';

export const LoginPage: React.FC = () => {
  const { admin, refreshAuth, toast } = useApp();
  const [username, setUsername] = useState('admin');
  const [password, setPassword] = useState('');
  const [oldPassword, setOldPassword] = useState('');
  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [busy, setBusy] = useState(false);

  const mustChange = Boolean(admin?.must_change_password);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    try {
      const res = await api.login(username.trim(), password);
      setAdminToken(res.access_token);
      setOldPassword(password);
      await refreshAuth();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const handleForceChange = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    try {
      await api.changePassword(oldPassword, newPassword, newUsername.trim() || undefined);
      toast('管理员密码已更新', 'success');
      await refreshAuth();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
      <div className="panel" style={{ width: '100%', maxWidth: 420, padding: 28 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 18 }}>
          <Shield size={24} style={{ color: 'var(--accent)' }} />
          <h2 style={{ margin: 0, fontSize: 20 }}>
            {mustChange ? '首次登录必须修改管理员密码' : 'Media Library 平台管理后台'}
          </h2>
        </div>

        {mustChange ? (
          <form onSubmit={handleForceChange} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <p className="muted" style={{ margin: 0, fontSize: 13 }}>
              当前管理员仍使用初始密码，请先修改为至少 8 位的新密码后继续操作。
            </p>
            <input
              className="input"
              placeholder="新管理员用户名（可选，留空保持不变）"
              value={newUsername}
              onChange={(e) => setNewUsername(e.target.value)}
            />
            <input
              className="input"
              type="password"
              required
              placeholder="当前密码"
              value={oldPassword}
              onChange={(e) => setOldPassword(e.target.value)}
            />
            <input
              className="input"
              type="password"
              required
              minLength={8}
              placeholder="新密码（至少 8 位）"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
            />
            <button type="submit" className="btn btn-primary" disabled={busy}>
              {busy ? '提交中...' : '确认修改并进入后台'}
            </button>
          </form>
        ) : (
          <form onSubmit={handleLogin} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <p className="muted" style={{ margin: 0, fontSize: 13 }}>
              仅限平台管理员登录。管理员仅查看聚合统计与系统配置，不访问任何用户片库隐私数据。
            </p>
            <input
              className="input"
              required
              placeholder="管理员用户名"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
            />
            <input
              className="input"
              type="password"
              required
              placeholder="管理员密码"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
            <button type="submit" className="btn btn-primary" disabled={busy}>
              {busy ? '登录中...' : '登录管理后台'}
            </button>
          </form>
        )}
      </div>
    </div>
  );
};
