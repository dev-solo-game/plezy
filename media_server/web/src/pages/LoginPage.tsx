import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Clapperboard, Loader2, LogIn } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';

export const LoginPage: React.FC = () => {
  const navigate = useNavigate();
  const { bootstrap, refreshAuth, toast } = useApp();

  const [username, setUsername] = useState('admin');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      await api.login({
        username: username.trim() || 'admin',
        password,
        device_name: navigator.userAgent.includes('Mobile') ? 'Mobile Browser' : 'Web Browser',
        platform: 'web',
      });
      await refreshAuth();
      toast('登录成功', 'success');
      navigate('/');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="auth-screen">
      <form className="glass-panel auth-card" onSubmit={handleSubmit}>
        <div className="flex-row" style={{ gap: 12 }}>
          <span className="brand-mark" style={{ width: 42, height: 42 }}>
            <Clapperboard size={22} />
          </span>
          <div>
            <h2 style={{ margin: 0, fontSize: 20 }}>{bootstrap?.server_name || 'TTPlay Media Server'}</h2>
            <div className="muted-sm">管理员登录</div>
          </div>
        </div>

        <div className="field">
          <label>管理员账号</label>
          <input className="input" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus required />
        </div>

        <div className="field">
          <label>密码</label>
          <input
            className="input"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>

        <button type="submit" className="btn btn-primary" disabled={submitting}>
          {submitting ? <Loader2 size={16} className="spin" /> : <LogIn size={16} />}
          登录媒体库
        </button>
      </form>
    </div>
  );
};
