import React, { useState } from 'react';
import { AlertCircle, Clapperboard, KeyRound, Loader2, LogIn, ShieldCheck } from 'lucide-react';
import { ApiError, api, setAdminToken } from '../api/client';
import { useApp } from '../contexts/AppContext';

function formatAuthError(err: unknown): string {
  if (err instanceof ApiError) {
    if (err.status === 401 || err.errorCode === 'invalid_credentials') {
      return '账号或密码错误，请重新检查';
    }
    if (err.status === 429 || err.errorCode === 'rate_limited') {
      return '登录尝试过于频繁，请稍后再试';
    }
    if (err.status === 403 || err.errorCode === 'forbidden_ip') {
      return '当前 IP 不在管理员允许访问列表中';
    }
    return err.message || `请求失败 (${err.status})`;
  }
  if (err instanceof Error && err.message) {
    return err.message;
  }
  return '登录失败，请检查网络连接';
}

export const LoginPage: React.FC = () => {
  const { bootstrap, admin, refreshAuth, toast } = useApp();
  const [username, setUsername] = useState('admin');
  const [password, setPassword] = useState('');
  const [oldPassword, setOldPassword] = useState('');
  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const mustChange = Boolean(admin?.must_change_password);
  const serverTitle = bootstrap?.server_name || 'TTPlay Media Library';

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setErrorMsg('');
    try {
      const res = await api.login(username.trim(), password);
      setAdminToken(res.access_token);
      setOldPassword(password);
      toast('登录成功', 'success');
      await refreshAuth();
    } catch (err) {
      const msg = formatAuthError(err);
      setErrorMsg(msg);
      toast(msg, 'error');
    } finally {
      setBusy(false);
    }
  };

  const handleForceChange = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setErrorMsg('');
    try {
      await api.changePassword(oldPassword, newPassword, newUsername.trim() || undefined);
      toast('管理员凭据已更新，正在进入控制台', 'success');
      await refreshAuth();
    } catch (err) {
      const msg = formatAuthError(err);
      setErrorMsg(msg);
      toast(msg, 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-screen">
      {mustChange ? (
        <form className="glass-panel auth-card" onSubmit={handleForceChange}>
          <div className="flex-row" style={{ gap: 12 }}>
            <span className="brand-mark" style={{ width: 42, height: 42 }}>
              <KeyRound size={20} />
            </span>
            <div>
              <h2 style={{ margin: 0, fontSize: 20 }}>初始化管理员密码</h2>
              <div className="muted-sm">首次登录必须修改初始密码后方可进入后台</div>
            </div>
          </div>

          <div className="field">
            <label>新管理员用户名（可选）</label>
            <input
              className="input"
              placeholder="留空则保持当前用户名不变"
              value={newUsername}
              onChange={(e) => setNewUsername(e.target.value)}
            />
          </div>

          <div className="field">
            <label>当前初始密码</label>
            <input
              className="input"
              type="password"
              required
              placeholder="输入刚刚登录使用的密码"
              value={oldPassword}
              onChange={(e) => setOldPassword(e.target.value)}
            />
          </div>

          <div className="field">
            <label>新密码（至少 8 位）</label>
            <input
              className="input"
              type="password"
              required
              minLength={8}
              placeholder="请设置高强度管理密码"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
            />
          </div>

          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? <Loader2 size={16} className="spin" /> : <KeyRound size={16} />}
            {busy ? '提交中...' : '确认修改并进入后台'}
          </button>
          {errorMsg && (
            <div
              role="alert"
              className="flex-row"
              style={{
                gap: 8,
                padding: '10px 12px',
                borderRadius: 10,
                background: 'rgba(239, 68, 68, 0.12)',
                border: '1px solid rgba(239, 68, 68, 0.35)',
                color: 'var(--danger)',
                fontSize: 13,
              }}
            >
              <AlertCircle size={15} style={{ flexShrink: 0 }} />
              <span>{errorMsg}</span>
            </div>
          )}
        </form>
      ) : (
        <form className="glass-panel auth-card" onSubmit={handleLogin}>
          <div className="flex-row" style={{ gap: 12 }}>
            <span className="brand-mark" style={{ width: 44, height: 44 }}>
              <Clapperboard size={22} />
            </span>
            <div>
              <h2 style={{ margin: 0, fontSize: 20 }}>{serverTitle}</h2>
              <div className="muted-sm">平台管理员控制台</div>
            </div>
          </div>

          <div className="setting-row" style={{ padding: '10px 12px' }}>
            <div className="flex-row" style={{ gap: 8, flexWrap: 'nowrap' }}>
              <ShieldCheck size={16} style={{ color: 'var(--success)', flexShrink: 0 }} />
              <span className="muted-sm" style={{ lineHeight: 1.45 }}>
                管理员仅查看非隐私聚合统计与系统配置，不访问任何用户文件名、媒体源或观看历史。
              </span>
            </div>
          </div>

          <div className="field">
            <label>管理员账号</label>
            <input
              className="input"
              required
              autoFocus
              placeholder="admin"
              value={username}
              onChange={(e) => {
                setUsername(e.target.value);
                if (errorMsg) setErrorMsg('');
              }}
            />
          </div>

          <div className="field">
            <label>密码</label>
            <input
              className="input"
              type="password"
              required
              placeholder="请输入管理员密码"
              value={password}
              onChange={(e) => {
                setPassword(e.target.value);
                if (errorMsg) setErrorMsg('');
              }}
            />
          </div>

          {errorMsg && (
            <div
              role="alert"
              className="flex-row"
              style={{
                gap: 8,
                padding: '10px 12px',
                borderRadius: 10,
                background: 'rgba(239, 68, 68, 0.12)',
                border: '1px solid rgba(239, 68, 68, 0.35)',
                color: 'var(--danger)',
                fontSize: 13,
              }}
            >
              <AlertCircle size={15} style={{ flexShrink: 0 }} />
              <span>{errorMsg}</span>
            </div>
          )}

          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? <Loader2 size={16} className="spin" /> : <LogIn size={16} />}
            {busy ? '正在验证...' : '登录管理后台'}
          </button>
        </form>
      )}
    </div>
  );
};
