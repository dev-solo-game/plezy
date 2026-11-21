import React, { useCallback, useEffect, useState } from 'react';
import {
  ChevronDown,
  ChevronUp,
  Loader2,
  Palette,
  Save,
  SlidersHorizontal,
  Sparkles,
  Wifi,
} from 'lucide-react';
import { api } from '../api/client';
import { CustomSelect, RadioCardGroup } from '../components/CustomSelect';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { AccentTheme, MetadataProvider, ServerSettings } from '../types';

const LANG_OPTIONS = [
  { value: 'zh-CN', label: '简体中文 (zh-CN)', description: '优先拉取中文标题、简介与海报' },
  { value: 'zh-TW', label: '繁体中文 (zh-TW)', description: '台湾地区译名优先' },
  { value: 'zh-HK', label: '香港繁体 (zh-HK)', description: '香港地区译名优先' },
  { value: 'en-US', label: 'English (en-US)', description: '英文原版元数据' },
  { value: 'ja-JP', label: '日本語 (ja-JP)', description: '日语元数据' },
  { value: 'ko-KR', label: '한국어 (ko-KR)', description: '韩语元数据' },
];

const ToggleSwitch: React.FC<{ checked: boolean; onChange: (next: boolean) => void }> = ({ checked, onChange }) => (
  <label className="toggle-switch">
    <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    <span className="toggle-track">
      <span className="toggle-thumb" />
    </span>
  </label>
);

export const SettingsPage: React.FC = () => {
  const { accentTheme, setAccentTheme, setServerNameLocal, toast } = useApp();
  const [tab, setTab] = useState<'scraper' | 'recognition' | 'appearance'>('scraper');
  const [settings, setSettings] = useState<ServerSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const [testingTmdb, setTestingTmdb] = useState(false);
  const [testingProvider, setTestingProvider] = useState<MetadataProvider | ''>('');
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  // Basic & TMDB
  const [serverName, setServerName] = useState('');
  const [selectedAccent, setSelectedAccent] = useState<AccentTheme>(accentTheme);
  const [minProto, setMinProto] = useState(1);
  const [tmdbKey, setTmdbKey] = useState('');
  const [tmdbBase, setTmdbBase] = useState('');
  const [tmdbImgBase, setTmdbImgBase] = useState('');
  const [proxy, setProxy] = useState('');
  const [scraperLang, setScraperLang] = useState('zh-CN');

  // Policies
  const [allowPublic, setAllowPublic] = useState(false);
  const [allowFallback, setAllowFallback] = useState(true);
  const [proxyImages, setProxyImages] = useState(true);
  const [preferNfo, setPreferNfo] = useState(true);

  // Auxiliary providers
  const [bangumi, setBangumi] = useState(true);
  const [bangumiBase, setBangumiBase] = useState('');
  const [bangumiToken, setBangumiToken] = useState('');
  const [douban, setDouban] = useState(true);
  const [doubanBase, setDoubanBase] = useState('');
  const [doubanCookie, setDoubanCookie] = useState('');
  const [anilist, setAnilist] = useState(true);
  const [anilistBase, setAnilistBase] = useState('');
  const [imdb, setImdb] = useState(true);
  const [imdbBase, setImdbBase] = useState('');
  const [tvdb, setTvdb] = useState(false);
  const [tvdbBase, setTvdbBase] = useState('');
  const [tvdbKey, setTvdbKey] = useState('');
  const [tvdbPin, setTvdbPin] = useState('');

  const [customWords, setCustomWords] = useState('');

  const apply = useCallback(
    (s: ServerSettings) => {
      setSettings(s);
      setServerName(s.server_name || '');
      if (
        s.accent_theme === 'glacier' ||
        s.accent_theme === 'neutral' ||
        s.accent_theme === 'ember' ||
        s.accent_theme === 'plum'
      ) {
        setSelectedAccent(s.accent_theme);
        setAccentTheme(s.accent_theme);
      }
      setMinProto(s.min_protocol_version || 1);
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
      setBangumiBase(s.bangumi_api_base || '');
      setBangumiToken('');
      setDouban(Boolean(s.douban_enabled));
      setDoubanBase(s.douban_api_base || '');
      setDoubanCookie('');
      setAnilist(Boolean(s.anilist_enabled));
      setAnilistBase(s.anilist_api_base || '');
      setImdb(Boolean(s.imdb_enabled));
      setImdbBase(s.imdb_api_base || '');
      setTvdb(Boolean(s.tvdb_enabled));
      setTvdbBase(s.tvdb_api_base || '');
      setTvdbKey('');
      setTvdbPin('');
      setCustomWords(s.custom_recognition_words || '');
    },
    [setAccentTheme]
  );

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.getSettings();
      apply(res.settings);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [apply, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleSave = async (e?: React.FormEvent) => {
    e?.preventDefault();
    if (saving) return;
    setSaving(true);
    try {
      const patch: Record<string, unknown> = {
        server_name: serverName.trim(),
        accent_theme: selectedAccent,
        min_protocol_version: minProto,
        tmdb_api_base: tmdbBase.trim(),
        tmdb_image_base: tmdbImgBase.trim(),
        metadata_proxy: proxy.trim(),
        scraper_lang: scraperLang,
        allow_public_metadata: allowPublic,
        allow_fallback_metadata: allowFallback,
        proxy_images: proxyImages,
        prefer_nfo: preferNfo,
        bangumi_enabled: bangumi,
        bangumi_api_base: bangumiBase.trim(),
        douban_enabled: douban,
        douban_api_base: doubanBase.trim(),
        anilist_enabled: anilist,
        anilist_api_base: anilistBase.trim(),
        imdb_enabled: imdb,
        imdb_api_base: imdbBase.trim(),
        tvdb_enabled: tvdb,
        tvdb_api_base: tvdbBase.trim(),
        custom_recognition_words: customWords,
      };
      if (tmdbKey.trim()) patch.tmdb_api_key = tmdbKey.trim();
      if (bangumiToken.trim()) patch.bangumi_token = bangumiToken.trim();
      if (doubanCookie.trim()) patch.douban_cookie = doubanCookie.trim();
      if (tvdbKey.trim()) patch.tvdb_api_key = tvdbKey.trim();
      if (tvdbPin.trim()) patch.tvdb_pin = tvdbPin.trim();
      const res = await api.updateSettings(patch);
      apply(res.settings);
      if (res.settings.server_name) {
        setServerNameLocal(res.settings.server_name);
      }
      toast('刮削与系统设置已保存', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  const testTmdb = async () => {
    if (testingTmdb) return;
    setTestingTmdb(true);
    try {
      const res = await api.testTmdb({
        tmdb_api_key: tmdbKey.trim() || undefined,
        tmdb_api_base: tmdbBase.trim() || undefined,
        metadata_proxy: proxy.trim(),
      });
      toast(`TMDB 连通正常（${res.latency_ms} ms）`, 'success');
    } catch (err) {
      toast(`TMDB 测试失败：${(err as Error).message}`, 'error');
    } finally {
      setTestingTmdb(false);
    }
  };

  const testProv = async (provider: MetadataProvider) => {
    if (testingProvider) return;
    setTestingProvider(provider);
    try {
      const res = await api.testProvider({
        provider,
        metadata_proxy: proxy.trim(),
        api_base:
          provider === 'bangumi'
            ? bangumiBase.trim() || undefined
            : provider === 'douban'
            ? doubanBase.trim() || undefined
            : provider === 'anilist'
            ? anilistBase.trim() || undefined
            : provider === 'imdb'
            ? imdbBase.trim() || undefined
            : provider === 'tvdb'
            ? tvdbBase.trim() || undefined
            : undefined,
        token: provider === 'bangumi' ? bangumiToken.trim() || undefined : undefined,
        cookie: provider === 'douban' ? doubanCookie.trim() || undefined : undefined,
        api_key: provider === 'tvdb' ? tvdbKey.trim() || undefined : undefined,
        pin: provider === 'tvdb' ? tvdbPin.trim() || undefined : undefined,
      });
      toast(`${provider.toUpperCase()} 连通正常（${res.latency_ms} ms）`, 'success');
    } catch (err) {
      toast(`${provider.toUpperCase()} 测试失败：${(err as Error).message}`, 'error');
    } finally {
      setTestingProvider('');
    }
  };

  const providers: Array<{
    key: MetadataProvider;
    title: string;
    badge: string;
    desc: string;
    enabled: boolean;
    setEnabled: (v: boolean) => void;
    apiBase: string;
    setApiBase: (v: string) => void;
    extra?: React.ReactNode;
  }> = [
    {
      key: 'bangumi',
      title: 'Bangumi 番组计划',
      badge: '动画推荐',
      desc: '补全番剧中文译名、日番分季与准确集数映射，显著提升动画识别率。',
      enabled: bangumi,
      setEnabled: setBangumi,
      apiBase: bangumiBase,
      setApiBase: setBangumiBase,
      extra: (
        <div className="field">
          <label>Bangumi Access Token（可选）</label>
          <input
            className="input"
            type="password"
            placeholder={settings?.bangumi_token_set ? '已配置 Token，留空保持不变' : '留空亦可匿名查询公开条目'}
            value={bangumiToken}
            onChange={(e) => setBangumiToken(e.target.value)}
          />
        </div>
      ),
    },
    {
      key: 'douban',
      title: '豆瓣电影',
      badge: '华语/国漫',
      desc: '优化华语片、国产剧与综艺的中文检索与别名桥接能力。',
      enabled: douban,
      setEnabled: setDouban,
      apiBase: doubanBase,
      setApiBase: setDoubanBase,
      extra: (
        <div className="field">
          <label>豆瓣 Cookie（可选）</label>
          <input
            className="input"
            type="password"
            placeholder={settings?.douban_cookie_set ? '已配置 Cookie，留空保持不变' : '遇到频率限制时可填写'}
            value={doubanCookie}
            onChange={(e) => setDoubanCookie(e.target.value)}
          />
        </div>
      ),
    },
    {
      key: 'anilist',
      title: 'AniList',
      badge: '番剧别名',
      desc: '提供丰富的罗马音与英文番剧别名对照，增强字幕组命名解析。',
      enabled: anilist,
      setEnabled: setAnilist,
      apiBase: anilistBase,
      setApiBase: setAnilistBase,
    },
    {
      key: 'imdb',
      title: 'IMDb',
      badge: '编号桥接',
      desc: '通过 tt 编号精确锚定欧美影视作品，减少同名混淆。',
      enabled: imdb,
      setEnabled: setImdb,
      apiBase: imdbBase,
      setApiBase: setImdbBase,
    },
    {
      key: 'tvdb',
      title: 'TheTVDB',
      badge: '长篇剧集',
      desc: '面向多季美剧与纪录片，提供更规范的剧集分季结构。',
      enabled: tvdb,
      setEnabled: setTvdb,
      apiBase: tvdbBase,
      setApiBase: setTvdbBase,
      extra: (
        <div className="grid-2">
          <div className="field">
            <label>TVDB API Key</label>
            <input
              className="input"
              type="password"
              placeholder={settings?.tvdb_api_key_set ? '已配置 Key，留空保留' : '输入 v4 API Key'}
              value={tvdbKey}
              onChange={(e) => setTvdbKey(e.target.value)}
            />
          </div>
          <div className="field">
            <label>TVDB PIN（可选）</label>
            <input
              className="input"
              type="password"
              placeholder={settings?.tvdb_pin_set ? '已配置 PIN，留空保留' : '订阅者 PIN'}
              value={tvdbPin}
              onChange={(e) => setTvdbPin(e.target.value)}
            />
          </div>
        </div>
      ),
    },
  ];

  return (
    <form onSubmit={handleSave} className="page-stack" style={{ maxWidth: 1080 }}>
      <div className="page-header">
        <div>
          <h1 className="page-title">刮削与平台设置</h1>
          <p className="page-subtitle">
            配置 TMDB 与多元数据提供商、公共识别策略、自定义词库及站点外观主题。
          </p>
        </div>
        <button type="submit" className="btn btn-primary" disabled={saving || loading}>
          {saving ? <Loader2 size={15} className="spin" /> : <Save size={15} />}
          {saving ? '正在保存...' : '保存全部设置'}
        </button>
      </div>

      {/* Segmented Tabs */}
      <div>
        <div className="tab-bar">
          <button type="button" className={`tab-btn ${tab === 'scraper' ? 'active' : ''}`} onClick={() => setTab('scraper')}>
            <Sparkles size={14} /> 刮削与数据源
          </button>
          <button type="button" className={`tab-btn ${tab === 'recognition' ? 'active' : ''}`} onClick={() => setTab('recognition')}>
            <SlidersHorizontal size={14} /> 识别词库与策略
          </button>
          <button type="button" className={`tab-btn ${tab === 'appearance' ? 'active' : ''}`} onClick={() => setTab('appearance')}>
            <Palette size={14} /> 站点与主题外观
          </button>
        </div>
      </div>

      {loading && !settings ? (
        <CardListSkeleton count={3} />
      ) : (
        <>
          {tab === 'scraper' && (
            <div className="page-stack">
              {/* TMDB Core Card */}
              <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
                <div className="card-title-row" style={{ marginBottom: 0 }}>
                  <div>
                    <h3 className="card-title">
                      TMDB 核心元数据引擎
                      {settings?.tmdb_api_key_set ? (
                        <span className="tag success">已配置 Key</span>
                      ) : (
                        <span className="tag danger">未配置 Key</span>
                      )}
                    </h3>
                    <div className="muted-sm" style={{ marginTop: 4 }}>
                      负责影视主库刮削、演职员表与高清海报拉取
                    </div>
                  </div>
                  <button type="button" className="btn btn-sm" onClick={() => void testTmdb()} disabled={testingTmdb}>
                    {testingTmdb ? <Loader2 size={14} className="spin" /> : <Wifi size={14} />}
                    测试 TMDB 连通
                  </button>
                </div>

                <div className="grid-2">
                  <div className="field">
                    <label>TMDB API Key / Read Access Token</label>
                    <input
                      className="input"
                      type="password"
                      placeholder={
                        settings?.tmdb_api_key_set
                          ? `当前已保存 (${settings.tmdb_api_key_masked})，留空保持不变`
                          : '填写 TMDB v3 API Key 或 v4 Bearer Token'
                      }
                      value={tmdbKey}
                      onChange={(e) => setTmdbKey(e.target.value)}
                    />
                  </div>
                  <div className="field">
                    <label>首选元数据语言</label>
                    <CustomSelect value={scraperLang} onChange={setScraperLang} options={LANG_OPTIONS} />
                  </div>
                  <div className="field">
                    <label>TMDB API 反代地址（可选）</label>
                    <input
                      className="input"
                      placeholder="默认 https://api.themoviedb.org/3"
                      value={tmdbBase}
                      onChange={(e) => setTmdbBase(e.target.value)}
                    />
                  </div>
                  <div className="field">
                    <label>TMDB 图片源地址（可选）</label>
                    <input
                      className="input"
                      placeholder="默认 https://image.tmdb.org/t/p"
                      value={tmdbImgBase}
                      onChange={(e) => setTmdbImgBase(e.target.value)}
                    />
                  </div>
                </div>

                <div className="field">
                  <label>网络代理（HTTP / HTTPS / SOCKS5，对所有数据源生效）</label>
                  <input
                    className="input"
                    placeholder="例如：http://127.0.0.1:7890 或 socks5://127.0.0.1:7891"
                    value={proxy}
                    onChange={(e) => setProxy(e.target.value)}
                  />
                </div>

                <div className="divider" />

                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <div className="setting-row">
                    <div className="setting-row-text">
                      <span className="setting-row-title">对外开放公共元数据接口</span>
                      <span className="setting-row-desc">
                        允许未登录的离线模式客户端调用本服务器 `/api/v1/public/metadata/*` 获取影视资料。
                      </span>
                    </div>
                    <ToggleSwitch checked={allowPublic} onChange={setAllowPublic} />
                  </div>

                  <div className="setting-row">
                    <div className="setting-row-text">
                      <span className="setting-row-title">服务端代理并缓存远程海报</span>
                      <span className="setting-row-desc">
                        通过服务端拉取并缓存 TMDB / 辅助源海报图片，客户端在无代理环境下也可秒开海报墙。
                      </span>
                    </div>
                    <ToggleSwitch checked={proxyImages} onChange={setProxyImages} />
                  </div>
                </div>
              </div>

              {/* Auxiliary Providers Grid */}
              <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                <div className="card-title-row" style={{ marginBottom: 0 }}>
                  <div>
                    <h3 className="card-title">多数据源辅助刮削模块</h3>
                    <div className="muted-sm" style={{ marginTop: 4 }}>
                      按需启用番剧、华语与编号桥接模块，点击「高级」可自定义接口地址或鉴权凭据
                    </div>
                  </div>
                </div>

                <div className="module-grid">
                  {providers.map((p) => {
                    const isOpen = Boolean(expanded[p.key]);
                    const isTesting = testingProvider === p.key;
                    return (
                      <div key={p.key} className={`module-card ${p.enabled ? 'active' : ''}`}>
                        <div className="module-card-head">
                          <div style={{ minWidth: 0 }}>
                            <div className="module-card-title">
                              <span>{p.title}</span>
                              <span className="tag accent">{p.badge}</span>
                            </div>
                            <div className="module-card-desc">{p.desc}</div>
                          </div>
                          <ToggleSwitch checked={p.enabled} onChange={p.setEnabled} />
                        </div>

                        <div className="module-card-actions">
                          <button
                            type="button"
                            className="btn btn-sm"
                            disabled={isTesting}
                            onClick={() => void testProv(p.key)}
                          >
                            {isTesting ? <Loader2 size={12} className="spin" /> : <Wifi size={12} />}
                            测试连通
                          </button>
                          <button
                            type="button"
                            className="btn btn-sm"
                            onClick={() => setExpanded((prev) => ({ ...prev, [p.key]: !prev[p.key] }))}
                          >
                            {isOpen ? <ChevronUp size={13} /> : <ChevronDown size={13} />}
                            高级配置
                          </button>
                        </div>

                        {isOpen && (
                          <div className="module-config-drawer">
                            <div className="field">
                              <label>自定义 API 地址（留空使用官方默认）</label>
                              <input
                                className="input"
                                placeholder="https://..."
                                value={p.apiBase}
                                onChange={(e) => p.setApiBase(e.target.value)}
                              />
                            </div>
                            {p.extra}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>
          )}

          {tab === 'recognition' && (
            <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <h3 className="card-title">识别策略与自定义词库</h3>

              <div className="setting-row">
                <div className="setting-row-text">
                  <span className="setting-row-title">优先读取客户端上报的 NFO 元数据</span>
                  <span className="setting-row-desc">
                    若文件同目录存在有效 `.nfo` 旁路文件，优先读取其中指定的 TMDB / IMDb ID 精准锚定作品。
                  </span>
                </div>
                <ToggleSwitch checked={preferNfo} onChange={setPreferNfo} />
              </div>

              <div className="setting-row">
                <div className="setting-row-text">
                  <span className="setting-row-title">TMDB 未命中时允许辅助源兜底入库</span>
                  <span className="setting-row-desc">
                    当某些冷门番剧或华语综艺在 TMDB 缺失条目时，允许使用 Bangumi / 豆瓣等辅助源直接生成作品条目。
                  </span>
                </div>
                <ToggleSwitch checked={allowFallback} onChange={setAllowFallback} />
              </div>

              <div className="divider" />

              <div className="field">
                <label>自定义识别 / 屏蔽词表（每行一条）</label>
                <textarea
                  className="textarea"
                  rows={9}
                  style={{ fontFamily: 'var(--font-mono)', fontSize: 13 }}
                  placeholder={'# 屏蔽发布组前缀或干扰词，每行一条\n# 亦支持 "原词 => 替换词" 格式进行名称标准化'}
                  value={customWords}
                  onChange={(e) => setCustomWords(e.target.value)}
                />
                <span className="muted-sm">
                  修改后将在下一次识别任务中自动生效；如需重新识别旧文件，可在客户端「待匹配中心」触发重刮。
                </span>
              </div>
            </div>
          )}

          {tab === 'appearance' && (
            <div className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
              <h3 className="card-title">站点标识与强调色主题</h3>

              <div className="grid-2">
                <div className="field">
                  <label>服务器显示名称</label>
                  <input
                    className="input"
                    placeholder="TTPlay Media Library"
                    value={serverName}
                    onChange={(e) => setServerName(e.target.value)}
                  />
                  <span className="muted-sm">展示于 Web 控制台左上角及客户端登录引导页</span>
                </div>

                <div className="field">
                  <label>最低客户端协议版本</label>
                  <input
                    className="input"
                    type="number"
                    min={1}
                    max={99}
                    value={minProto}
                    onChange={(e) => setMinProto(Math.max(1, Number(e.target.value) || 1))}
                  />
                  <span className="muted-sm">低于该协议版本的旧客户端将被提示升级</span>
                </div>
              </div>

              <div className="field">
                <label>控制台主题强调色（实时预览）</label>
                <RadioCardGroup
                  columns={4}
                  value={selectedAccent}
                  onChange={(v) => {
                    setSelectedAccent(v);
                    setAccentTheme(v);
                  }}
                  options={[
                    {
                      value: 'glacier',
                      title: '冰川蓝',
                      colorDot: '#7cc4ff',
                      description: '经典冷调蓝，默认高对比视觉体验',
                    },
                    {
                      value: 'neutral',
                      title: '极简白',
                      colorDot: '#e5e9f0',
                      description: '纯净单色高雅质感，减少色彩干扰',
                    },
                    {
                      value: 'ember',
                      title: '暖琥珀',
                      colorDot: '#ff9c6e',
                      description: '温润落日橙调，影院放映室氛围',
                    },
                    {
                      value: 'plum',
                      title: '暮光紫',
                      colorDot: '#c59bff',
                      description: '柔和霓虹紫，现代媒体中心格调',
                    },
                  ]}
                />
              </div>
            </div>
          )}
        </>
      )}
    </form>
  );
};
