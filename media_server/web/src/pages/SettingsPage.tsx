import React, { useEffect, useRef, useState } from 'react';
import { Database, Loader2, LogOut, Palette, PlayCircle, Shield, Sparkles, Trash2, Wifi } from 'lucide-react';
import { api, formatBytes } from '../api/client';
import type { SettingsBundle } from '../api/prefetch';
import { getCached, useSWRQuery } from '../api/queryCache';
import { CustomSelect, RadioCardGroup } from '../components/CustomSelect';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { AccentTheme, ServerSettings } from '../types';

export const SettingsPage: React.FC = () => {
  const { accentTheme, setAccentTheme, setServerNameLocal, refreshAuth, toast } = useApp();
  const [tab, setTab] = useState<'scraper' | 'playback' | 'appearance' | 'security'>('scraper');
  const [saving, setSaving] = useState(false);

  const initialBundle = getCached<SettingsBundle>('settings:bundle');
  const hydratedRef = useRef(Boolean(initialBundle));

  const {
    data: bundle,
    showSkeleton,
    mutate,
    reload,
  } = useSWRQuery<SettingsBundle>(
    'settings:bundle',
    async () => {
      const [sRes, oRes, sesRes] = await Promise.all([
        api.getSettings(),
        api.systemOverview(),
        api.listSessions(),
      ]);
      return {
        settings: sRes.settings,
        cache_stats: sRes.cache_stats,
        overview: oRes.overview,
        sessions: sesRes.sessions || [],
      };
    },
    { onError: (err) => toast(err.message, 'error') }
  );

  // Form states initialized from cache if present so zero-flicker on mount
  const initSt = initialBundle?.settings;
  const [serverName, setServerName] = useState(initSt?.server_name || '');
  const [tmdbKeyInput, setTmdbKeyInput] = useState('');
  const [tmdbBase, setTmdbBase] = useState(initSt?.tmdb_api_base || '');
  const [tmdbImageBase, setTmdbImageBase] = useState(initSt?.tmdb_image_base || '');
  const [proxyUrl, setProxyUrl] = useState(initSt?.metadata_proxy || '');
  const [bangumiEnabled, setBangumiEnabled] = useState(initSt?.bangumi_enabled ?? true);
  const [bangumiBase, setBangumiBase] = useState(initSt?.bangumi_api_base || '');
  const [proxyImages, setProxyImages] = useState(initSt?.proxy_images ?? true);
  const [scraperLang, setScraperLang] = useState(initSt?.scraper_lang || 'zh-CN');
  const [preferNfo, setPreferNfo] = useState(initSt?.prefer_nfo ?? true);
  const [scanIntervalMin, setScanIntervalMin] = useState(initSt?.scan_interval_min ?? 60);
  const [watchLocalFs, setWatchLocalFs] = useState(initSt?.watch_local_fs ?? true);
  const [webPreferCloud, setWebPreferCloud] = useState(initSt?.web_prefer_cloud_transcode ?? true);
  const [watchedThreshold, setWatchedThreshold] = useState(initSt?.watched_threshold ?? 0.9);
  const [testingTmdb, setTestingTmdb] = useState(false);

  // Account security states
  const [newUsername, setNewUsername] = useState('');
  const [oldPassword, setOldPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');

  const applySettingsToForm = (st: ServerSettings) => {
    setServerName(st.server_name);
    setTmdbBase(st.tmdb_api_base);
    setTmdbImageBase(st.tmdb_image_base);
    setProxyUrl(st.metadata_proxy);
    setBangumiEnabled(st.bangumi_enabled);
    setBangumiBase(st.bangumi_api_base);
    setProxyImages(st.proxy_images);
    setScraperLang(st.scraper_lang || 'zh-CN');
    setPreferNfo(st.prefer_nfo);
    setScanIntervalMin(st.scan_interval_min);
    setWatchLocalFs(st.watch_local_fs);
    setWebPreferCloud(st.web_prefer_cloud_transcode);
    setWatchedThreshold(st.watched_threshold);
  };

  useEffect(() => {
    if (bundle?.settings && !hydratedRef.current) {
      hydratedRef.current = true;
      applySettingsToForm(bundle.settings);
    }
  }, [bundle]);

  const settings = bundle?.settings;
  const cacheStats = bundle?.cache_stats;
  const overview = bundle?.overview;
  const sessions = bundle?.sessions || [];

  const handleSaveSettings = async (e?: React.FormEvent) => {
    e?.preventDefault();
    setSaving(true);
    try {
      const res = await api.updateSettings({
        server_name: serverName.trim(),
        ...(tmdbKeyInput.trim() ? { tmdb_api_key: tmdbKeyInput.trim() } : {}),
        tmdb_api_base: tmdbBase.trim(),
        tmdb_image_base: tmdbImageBase.trim(),
        metadata_proxy: proxyUrl.trim(),
        bangumi_enabled: bangumiEnabled,
        bangumi_api_base: bangumiBase.trim(),
        proxy_images: proxyImages,
        scraper_lang: scraperLang,
        prefer_nfo: preferNfo,
        scan_interval_min: Number(scanIntervalMin),
        watch_local_fs: watchLocalFs,
        web_prefer_cloud_transcode: webPreferCloud,
        watched_threshold: Number(watchedThreshold),
        accent_theme: accentTheme,
      });
      mutate((prev) =>
        prev ? { ...prev, settings: res.settings, cache_stats: res.cache_stats } : prev
      );
      setTmdbKeyInput('');
      setServerNameLocal(res.settings.server_name);
      toast('系统配置已保存', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  const handleClearTmdbKey = async () => {
    try {
      const res = await api.updateSettings({ clear_tmdb_api_key: true });
      mutate((prev) => (prev ? { ...prev, settings: res.settings } : prev));
      toast('已清除 TMDB API Key', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleTestTmdb = async () => {
    setTestingTmdb(true);
    try {
      const res = await api.testTmdb({
        tmdb_api_key: tmdbKeyInput.trim() || undefined,
        tmdb_api_base: tmdbBase.trim() || undefined,
        metadata_proxy: proxyUrl.trim(),
      });
      toast(`TMDB 连接正常，延迟 ${res.latency_ms} ms`, 'success');
    } catch (err) {
      toast(`TMDB 连接失败: ${(err as Error).message}`, 'error');
    } finally {
      setTestingTmdb(false);
    }
  };

  const handleClearCache = async (scope: 'all' | 'works' | 'seasons' | 'people' | 'search') => {
    try {
      const res = await api.clearMetaCache(scope);
      mutate((prev) => (prev ? { ...prev, cache_stats: res.cache_stats } : prev));
      toast(`已清理 ${res.deleted} 条元数据缓存`, 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleChangePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.changePassword({
        old_password: oldPassword,
        new_password: newPassword,
        new_username: newUsername.trim() || undefined,
      });
      setOldPassword('');
      setNewPassword('');
      toast('管理员凭据已修改，其他会话已下线', 'success');
      await refreshAuth();
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleRevokeSession = async (tokenId: string) => {
    try {
      await api.revokeSession(tokenId);
      mutate((prev) =>
        prev ? { ...prev, sessions: prev.sessions.filter((s) => s.token_id !== tokenId) } : prev
      );
      toast('会话已踢出下线', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleLogout = async () => {
    await api.logout();
    await refreshAuth();
  };

  if (showSkeleton || !settings) {
    return (
      <div>
        <div className="section-head" style={{ marginTop: 4 }}>
          <h2 className="section-title">系统设置</h2>
        </div>
        <CardListSkeleton count={4} />
      </div>
    );
  }

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">系统设置</h2>
        <button type="button" className="btn btn-primary btn-sm" onClick={() => void handleSaveSettings()} disabled={saving}>
          {saving && <Loader2 size={14} className="spin" />}
          保存全部配置
        </button>
      </div>

      <div className="flex-row" style={{ marginBottom: 20 }}>
        <button type="button" className={`chip ${tab === 'scraper' ? 'active' : ''}`} onClick={() => setTab('scraper')}>
          <Sparkles size={13} />
          刮削与代理
        </button>
        <button type="button" className={`chip ${tab === 'playback' ? 'active' : ''}`} onClick={() => setTab('playback')}>
          <PlayCircle size={13} />
          扫描与播放
        </button>
        <button type="button" className={`chip ${tab === 'appearance' ? 'active' : ''}`} onClick={() => setTab('appearance')}>
          <Palette size={13} />
          外观与概览
        </button>
        <button type="button" className={`chip ${tab === 'security' ? 'active' : ''}`} onClick={() => setTab('security')}>
          <Shield size={13} />
          账号与会话
        </button>
      </div>

      {tab === 'scraper' && (
        <form onSubmit={handleSaveSettings} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            <div className="flex-row" style={{ justifyContent: 'space-between' }}>
              <strong>TMDB 与 网络代理</strong>
              <button type="button" className="btn btn-sm" onClick={() => void handleTestTmdb()} disabled={testingTmdb}>
                {testingTmdb ? <Loader2 size={14} className="spin" /> : <Wifi size={14} />}
                测试 TMDB 连通性
              </button>
            </div>

            <div className="field">
              <label>
                TMDB API Key{' '}
                {settings.tmdb_api_key_set && (
                  <span className="tag success">当前已配置：{settings.tmdb_api_key_masked}</span>
                )}
              </label>
              <div className="flex-row">
                <input
                  className="input"
                  style={{ flex: 1 }}
                  type="password"
                  placeholder={settings.tmdb_api_key_set ? '留空保留现有 API Key，输入则覆盖' : '填入 TMDB v3 API Key 或 v4 Bearer Token'}
                  value={tmdbKeyInput}
                  onChange={(e) => setTmdbKeyInput(e.target.value)}
                />
                {settings.tmdb_api_key_set && (
                  <button type="button" className="btn btn-danger btn-sm" onClick={() => void handleClearTmdbKey()}>
                    清除 Key
                  </button>
                )}
              </div>
            </div>

            <div className="grid-2">
              <div className="field">
                <label>刮削网络代理（HTTP / HTTPS Proxy）</label>
                <input
                  className="input"
                  placeholder="http://127.0.0.1:7890"
                  value={proxyUrl}
                  onChange={(e) => setProxyUrl(e.target.value)}
                />
              </div>
              <div className="field">
                <label>首选刮削语言</label>
                <CustomSelect
                  value={scraperLang}
                  onChange={setScraperLang}
                  options={[
                    { value: 'zh-CN', label: '简体中文 (zh-CN)' },
                    { value: 'zh-TW', label: '繁体中文 (zh-TW)' },
                    { value: 'en-US', label: 'English (en-US)' },
                    { value: 'ja-JP', label: '日本語 (ja-JP)' },
                  ]}
                />
              </div>
              <div className="field">
                <label>TMDB API Base URL</label>
                <input className="input" value={tmdbBase} onChange={(e) => setTmdbBase(e.target.value)} />
              </div>
              <div className="field">
                <label>TMDB Image Base URL</label>
                <input className="input" value={tmdbImageBase} onChange={(e) => setTmdbImageBase(e.target.value)} />
              </div>
            </div>

            <div className="divider" />

            <div className="grid-2">
              <div className="field">
                <label>Bangumi API Base URL（用于动漫自动兜底）</label>
                <input className="input" value={bangumiBase} onChange={(e) => setBangumiBase(e.target.value)} />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8, justifyContent: 'center' }}>
                <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                  <input type="checkbox" checked={bangumiEnabled} onChange={(e) => setBangumiEnabled(e.target.checked)} />
                  启用 Bangumi 番剧刮削源
                </label>
                <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                  <input type="checkbox" checked={preferNfo} onChange={(e) => setPreferNfo(e.target.checked)} />
                  优先读取同目录 NFO 元数据与本地海报
                </label>
                <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                  <input type="checkbox" checked={proxyImages} onChange={(e) => setProxyImages(e.target.checked)} />
                  开启服务端远程海报代理与磁盘缓存
                </label>
              </div>
            </div>
          </div>

          {cacheStats && (
            <div className="card-box flex-row" style={{ justifyContent: 'space-between' }}>
              <div className="flex-row">
                <Database size={16} className="muted" />
                <span>
                  元数据缓存：作品 {cacheStats.works} · 分季 {cacheStats.seasons} · 演职员 {cacheStats.people} · 搜索{' '}
                  {cacheStats.searches}
                </span>
              </div>
              <div className="flex-row">
                <button type="button" className="btn btn-sm" onClick={() => void handleClearCache('search')}>
                  清空搜索缓存
                </button>
                <button type="button" className="btn btn-danger btn-sm" onClick={() => void handleClearCache('all')}>
                  <Trash2 size={13} />
                  清空全部元数据缓存
                </button>
              </div>
            </div>
          )}
        </form>
      )}

      {tab === 'playback' && (
        <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div className="grid-2">
            <div className="field">
              <label>定时全库扫描间隔（分钟，0 表示关闭定时扫描）</label>
              <input
                className="input"
                type="number"
                min={0}
                value={scanIntervalMin}
                onChange={(e) => setScanIntervalMin(Number(e.target.value))}
              />
            </div>
            <div className="field">
              <label>自动标记已看阈值（当前 {Math.round(watchedThreshold * 100)}%）</label>
              <input
                className="input"
                type="number"
                min={0.5}
                max={0.99}
                step={0.05}
                value={watchedThreshold}
                onChange={(e) => setWatchedThreshold(Number(e.target.value))}
              />
            </div>
          </div>

          <label className="flex-row" style={{ cursor: 'pointer' }}>
            <input type="checkbox" checked={watchLocalFs} onChange={(e) => setWatchLocalFs(e.target.checked)} />
            开启本地挂载目录实时文件变更监听 (fsnotify)
          </label>

          <label className="flex-row" style={{ cursor: 'pointer' }}>
            <input type="checkbox" checked={webPreferCloud} onChange={(e) => setWebPreferCloud(e.target.checked)} />
            网页端播放夸克网盘视频时默认优先使用云转码流（保证浏览器音视频全兼容，可在播放器中随时切回原画）
          </label>
        </div>
      )}

      {tab === 'appearance' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            <div className="field">
              <label>媒体服务器名称</label>
              <input className="input" value={serverName} onChange={(e) => setServerName(e.target.value)} />
            </div>
            <div className="field">
              <label>界面强调色调 (Liquid Glass Accent)</label>
              <RadioCardGroup
                columns={4}
                value={accentTheme}
                onChange={(k) => setAccentTheme(k as AccentTheme)}
                options={[
                  { value: 'glacier', title: '冰川蓝', description: 'Glacier', colorDot: '#7cc4ff' },
                  { value: 'neutral', title: '极简银白', description: 'Neutral', colorDot: '#e5e9f0' },
                  { value: 'ember', title: '暖琥珀', description: 'Ember', colorDot: '#ff9c6e' },
                  { value: 'plum', title: '暮夜紫', description: 'Plum', colorDot: '#c59bff' },
                ]}
              />
            </div>
          </div>

          {overview && (
            <div className="card-box">
              <h3 style={{ margin: '0 0 12px', fontSize: 15 }}>系统数据概览</h3>
              <div className="flex-row">
                <span className="tag">电影：{overview.movies}</span>
                <span className="tag">剧集：{overview.shows}</span>
                <span className="tag">单集：{overview.episodes}</span>
                <span className="tag">总索引文件：{overview.files}</span>
                <span className="tag">待匹配：{overview.unmatched}</span>
                <span className="tag">合集/播单：{overview.collections + overview.playlists}</span>
                <span className="tag">演职员：{overview.people}</span>
                <span className="tag">挂载源：{overview.mounts}</span>
                <span className="tag accent">数据库体积：{formatBytes(overview.db_bytes)}</span>
              </div>
            </div>
          )}
        </div>
      )}

      {tab === 'security' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <form className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 12 }} onSubmit={handleChangePassword}>
            <h3 style={{ margin: 0, fontSize: 15 }}>修改管理员密码与账号名</h3>
            <div className="grid-3">
              <div className="field">
                <label>新用户名（可选，留空保持）</label>
                <input className="input" placeholder="admin" value={newUsername} onChange={(e) => setNewUsername(e.target.value)} />
              </div>
              <div className="field">
                <label>当前密码</label>
                <input className="input" type="password" value={oldPassword} onChange={(e) => setOldPassword(e.target.value)} required />
              </div>
              <div className="field">
                <label>新密码（至少 6 位）</label>
                <input className="input" type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} required />
              </div>
            </div>
            <div className="flex-row">
              <button type="submit" className="btn btn-primary btn-sm">
                更新凭据
              </button>
              <button type="button" className="btn btn-danger btn-sm" style={{ marginLeft: 'auto' }} onClick={() => void handleLogout()}>
                <LogOut size={14} />
                退出当前登录
              </button>
            </div>
          </form>

          <div className="card-box">
            <h3 style={{ margin: '0 0 12px', fontSize: 15 }}>活跃登录会话 ({sessions.length})</h3>
            <table className="data-table">
              <thead>
                <tr>
                  <th>设备</th>
                  <th>平台 / IP</th>
                  <th>最近活跃</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((s) => (
                  <tr key={s.token_id}>
                    <td>
                      {s.device_name || 'Web Client'}{' '}
                      {s.current && <span className="tag accent">当前设备</span>}
                    </td>
                    <td className="muted-sm">
                      {s.platform} · {s.ip}
                    </td>
                    <td className="muted-sm">{new Date(s.last_used_at).toLocaleString()}</td>
                    <td style={{ textAlign: 'right' }}>
                      {!s.current && (
                        <button
                          type="button"
                          className="btn btn-danger btn-sm"
                          onClick={() => void handleRevokeSession(s.token_id)}
                        >
                          踢出下线
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
};
