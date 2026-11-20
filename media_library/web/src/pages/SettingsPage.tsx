import React, { useCallback, useEffect, useState } from 'react';
import { Save, Wifi } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MetadataProvider, ServerSettings } from '../types';

export const SettingsPage: React.FC = () => {
  const { toast } = useApp();
  const [settings, setSettings] = useState<ServerSettings | null>(null);
  const [saving, setSaving] = useState(false);

  const [serverName, setServerName] = useState('');
  const [tmdbKey, setTmdbKey] = useState('');
  const [tmdbBase, setTmdbBase] = useState('');
  const [tmdbImgBase, setTmdbImgBase] = useState('');
  const [proxy, setProxy] = useState('');
  const [scraperLang, setScraperLang] = useState('zh-CN');
  const [allowPublic, setAllowPublic] = useState(false);
  const [allowFallback, setAllowFallback] = useState(true);
  const [proxyImages, setProxyImages] = useState(true);
  const [preferNfo, setPreferNfo] = useState(true);
  const [bangumi, setBangumi] = useState(true);
  const [douban, setDouban] = useState(true);
  const [anilist, setAnilist] = useState(true);
  const [imdb, setImdb] = useState(true);
  const [tvdb, setTvdb] = useState(false);
  const [tvdbKey, setTvdbKey] = useState('');
  const [tvdbPin, setTvdbPin] = useState('');
  const [customWords, setCustomWords] = useState('');

  const apply = (s: ServerSettings) => {
    setSettings(s);
    setServerName(s.server_name || '');
    setTmdbKey('');
    setTmdbBase(s.tmdb_api_base || '');
    setTmdbImgBase(s.tmdb_image_base || '');
    setProxy(s.metadata_proxy || '');
    setScraperLang(s.scraper_lang || 'zh-CN');
    setAllowPublic(Boolean(s.allow_public_metadata));
    setAllowFallback(s.allow_fallback_metadata !== false);
    setProxyImages(s.proxy_images !== false);
    setPreferNfo(Boolean(s.prefer_nfo));
    setBangumi(Boolean(s.bangumi_enabled));
    setDouban(Boolean(s.douban_enabled));
    setAnilist(Boolean(s.anilist_enabled));
    setImdb(Boolean(s.imdb_enabled));
    setTvdb(Boolean(s.tvdb_enabled));
    setTvdbKey('');
    setTvdbPin('');
    setCustomWords(s.custom_recognition_words || '');
  };

  const load = useCallback(async () => {
    try {
      const res = await api.getSettings();
      apply(res.settings);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (saving) return;
    setSaving(true);
    try {
      const patch: Record<string, unknown> = {
        server_name: serverName.trim(),
        tmdb_api_base: tmdbBase.trim(),
        tmdb_image_base: tmdbImgBase.trim(),
        metadata_proxy: proxy.trim(),
        scraper_lang: scraperLang,
        allow_public_metadata: allowPublic,
        allow_fallback_metadata: allowFallback,
        proxy_images: proxyImages,
        prefer_nfo: preferNfo,
        bangumi_enabled: bangumi,
        douban_enabled: douban,
        anilist_enabled: anilist,
        imdb_enabled: imdb,
        tvdb_enabled: tvdb,
        custom_recognition_words: customWords,
      };
      if (tmdbKey.trim()) patch.tmdb_api_key = tmdbKey.trim();
      if (tvdbKey.trim()) patch.tvdb_api_key = tvdbKey.trim();
      if (tvdbPin.trim()) patch.tvdb_pin = tvdbPin.trim();
      const res = await api.updateSettings(patch);
      apply(res.settings);
      toast('刮削与系统设置已保存', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  const testTmdb = async () => {
    try {
      const res = await api.testTmdb({
        tmdb_api_key: tmdbKey.trim() || undefined,
        tmdb_api_base: tmdbBase.trim() || undefined,
        metadata_proxy: proxy.trim(),
      });
      toast(`TMDB 连通正常（${res.latency_ms} ms）`, 'success');
    } catch (err) {
      toast(`TMDB 测试失败：${(err as Error).message}`, 'error');
    }
  };

  const testProv = async (provider: MetadataProvider) => {
    try {
      const res = await api.testProvider({
        provider,
        metadata_proxy: proxy.trim(),
        api_key: provider === 'tvdb' ? tvdbKey.trim() || undefined : undefined,
        pin: provider === 'tvdb' ? tvdbPin.trim() || undefined : undefined,
      });
      toast(`${provider.toUpperCase()} 连通正常（${res.latency_ms} ms）`, 'success');
    } catch (err) {
      toast(`${provider.toUpperCase()} 测试失败：${(err as Error).message}`, 'error');
    }
  };

  return (
    <form onSubmit={handleSave} style={{ display: 'flex', flexDirection: 'column', gap: 18, maxWidth: 880 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ margin: 0, fontSize: 22 }}>刮削与平台设置</h1>
        <button type="submit" className="btn btn-primary" disabled={saving}>
          <Save size={15} /> {saving ? '保存中...' : '保存设置'}
        </button>
      </div>

      <div className="panel" style={{ padding: 18, display: 'flex', flexDirection: 'column', gap: 12 }}>
        <h3 style={{ margin: 0, fontSize: 15 }}>基础与 TMDB 核心配置</h3>
        <input className="input" placeholder="服务器名称" value={serverName} onChange={(e) => setServerName(e.target.value)} />
        <input
          className="input"
          type="password"
          placeholder={settings?.tmdb_api_key_set ? `已配置 TMDB Key (${settings.tmdb_api_key_masked})，留空保留` : 'TMDB API Key / Bearer Token'}
          value={tmdbKey}
          onChange={(e) => setTmdbKey(e.target.value)}
        />
        <input className="input" placeholder="TMDB API 地址（可选反代）" value={tmdbBase} onChange={(e) => setTmdbBase(e.target.value)} />
        <input className="input" placeholder="TMDB 图片源地址" value={tmdbImgBase} onChange={(e) => setTmdbImgBase(e.target.value)} />
        <input className="input" placeholder="网络代理（HTTP / SOCKS5）" value={proxy} onChange={(e) => setProxy(e.target.value)} />
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
          <label style={{ fontSize: 13 }}>
            默认语言：
            <select className="input" value={scraperLang} onChange={(e) => setScraperLang(e.target.value)} style={{ marginLeft: 6, width: 130 }}>
              {['zh-CN', 'zh-TW', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'].map((l) => (
                <option key={l} value={l}>{l}</option>
              ))}
            </select>
          </label>
          <button type="button" className="btn" onClick={() => void testTmdb()}>
            <Wifi size={14} /> 测试 TMDB 连通
          </button>
        </div>

        <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13 }}>
          <input type="checkbox" checked={allowPublic} onChange={(e) => setAllowPublic(e.target.checked)} />
          对外开放公共元数据识别接口（供未登录客户端使用）
        </label>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13 }}>
          <input type="checkbox" checked={allowFallback} onChange={(e) => setAllowFallback(e.target.checked)} />
          TMDB 未命中时允许兜底数据源
        </label>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13 }}>
          <input type="checkbox" checked={proxyImages} onChange={(e) => setProxyImages(e.target.checked)} />
          通过服务端代理远程海报图片
        </label>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13 }}>
          <input type="checkbox" checked={preferNfo} onChange={(e) => setPreferNfo(e.target.checked)} />
          优先读取客户端上传的 NFO 信息
        </label>
      </div>

      <div className="panel" style={{ padding: 18, display: 'flex', flexDirection: 'column', gap: 10 }}>
        <h3 style={{ margin: 0, fontSize: 15 }}>辅助数据源开关与测试</h3>
        {[
          { key: 'bangumi' as MetadataProvider, label: 'Bangumi（动画）', val: bangumi, set: setBangumi },
          { key: 'douban' as MetadataProvider, label: '豆瓣', val: douban, set: setDouban },
          { key: 'anilist' as MetadataProvider, label: 'AniList', val: anilist, set: setAnilist },
          { key: 'imdb' as MetadataProvider, label: 'IMDb', val: imdb, set: setImdb },
          { key: 'tvdb' as MetadataProvider, label: 'TheTVDB', val: tvdb, set: setTvdb },
        ].map((p) => (
          <div key={p.key} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 14 }}>
              <input type="checkbox" checked={p.val} onChange={(e) => p.set(e.target.checked)} />
              {p.label}
            </label>
            <button type="button" className="btn" onClick={() => void testProv(p.key)}>测试</button>
          </div>
        ))}
        {tvdb && (
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <input className="input" type="password" placeholder={settings?.tvdb_api_key_set ? '已配置 TVDB Key（留空保留）' : 'TVDB API Key'} value={tvdbKey} onChange={(e) => setTvdbKey(e.target.value)} style={{ flex: 1 }} />
            <input className="input" type="password" placeholder={settings?.tvdb_pin_set ? '已配置 PIN（留空保留）' : 'TVDB PIN（可选）'} value={tvdbPin} onChange={(e) => setTvdbPin(e.target.value)} style={{ flex: 1 }} />
          </div>
        )}
      </div>

      <div className="panel" style={{ padding: 18, display: 'flex', flexDirection: 'column', gap: 8 }}>
        <h3 style={{ margin: 0, fontSize: 15 }}>自定义识别 / 屏蔽词</h3>
        <textarea
          className="input"
          rows={5}
          placeholder="每行一条规则或屏蔽词"
          value={customWords}
          onChange={(e) => setCustomWords(e.target.value)}
        />
      </div>
    </form>
  );
};
