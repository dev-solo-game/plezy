import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Clapperboard, Loader2 } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';

export const SetupPage: React.FC = () => {
  const navigate = useNavigate();
  const { refreshAuth, toast } = useApp();

  const [serverName, setServerName] = useState('TTPlay Media Server');
  const [username, setUsername] = useState('admin');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [tmdbKey, setTmdbKey] = useState('');
  const [proxy, setProxy] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password.length < 6) {
      toast('管理员密码至少需要 6 位字符', 'error');
      return;
    }
    if (password !== confirmPassword) {
      toast('两次输入的密码不一致', 'error');
      return;
    }
    setSubmitting(true);
    try {
      await api.setup({
        username: username.trim() || 'admin',
        password,
        server_name: serverName.trim() || 'TTPlay Media Server',
        tmdb_api_key: tmdbKey.trim(),
        metadata_proxy: proxy.trim(),
        device_name: navigator.userAgent.includes('Mobile') ? 'Mobile Web' : 'Desktop Web',
      });
      toast('初始化成功！欢迎使用自建媒体库', 'success');
      await refreshAuth();
      navigate('/');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="auth-screen">
      <form className="glass-panel auth-card" style={{ maxWidth: 520 }} onSubmit={handleSubmit}>
        <div className="flex-row" style={{ gap: 12 }}>
          <span className="brand-mark" style={{ width: 42, height: 42 }}>
            <Clapperboard size={22} />
          </span>
          <div>
            <h2 style={{ margin: 0, fontSize: 20 }}>初始化管理员媒体库</h2>
            <div className="muted-sm">单账号管理模式 · 首次启动配置向导</div>
          </div>
        </div>

        <div className="field">
          <label>媒体服务器名称</label>
          <input className="input" value={serverName} onChange={(e) => setServerName(e.target.value)} />
        </div>

        <div className="grid-2">
          <div className="field">
            <label>管理员账号</label>
            <input className="input" value={username} onChange={(e) => setUsername(e.target.value)} required />
          </div>
          <div className="field">
            <label>管理员密码（至少 6 位）</label>
            <input
              className="input"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
        </div>

        <div className="field">
          <label>确认密码</label>
          <input
            className="input"
            type="password"
            value={confirmPassword}
            onChange={(e) => setConfirmPassword(e.target.value)}
            required
          />
        </div>

        <div className="divider" />

        <div className="field">
          <label>TMDB API Key（可选，用于电影与剧集海报/简介自动刮削）</label>
          <input
            className="input"
            placeholder="可留空，稍后在系统设置中填写与测速"
            value={tmdbKey}
            onChange={(e) => setTmdbKey(e.target.value)}
          />
        </div>

        <div className="field">
          <label>刮削网络代理 URL（可选，支持 http:// 或 https://）</label>
          <input
            className="input"
            placeholder="例如 http://127.0.0.1:7890"
            value={proxy}
            onChange={(e) => setProxy(e.target.value)}
          />
        </div>

        <button type="submit" className="btn btn-primary" disabled={submitting} style={{ marginTop: 4 }}>
          {submitting && <Loader2 size={16} className="spin" />}
          完成初始化并进入媒体库
        </button>
      </form>
    </div>
  );
};
