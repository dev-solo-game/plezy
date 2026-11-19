import React, { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { Check, Folder, Loader2, QrCode, RefreshCw, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { HostDirEntry, MountKind, MountRecord } from '../types';

interface MountEditorModalProps {
  mount?: MountRecord | null;
  onClose: () => void;
  onSaved: () => void;
}

export const MountEditorModal: React.FC<MountEditorModalProps> = ({ mount, onClose, onSaved }) => {
  const { toast } = useApp();
  const isEdit = Boolean(mount);

  const [kind, setKind] = useState<MountKind>((mount?.kind as MountKind) || 'local');
  const [name, setName] = useState(mount?.name || '');
  const [enabled, setEnabled] = useState(mount ? mount.enabled : true);
  const [autoScan, setAutoScan] = useState(true);

  // Local
  const [rootPath, setRootPath] = useState(String(mount?.config?.rootPath || ''));
  const [hostCurrent, setHostCurrent] = useState('');
  const [hostParent, setHostParent] = useState('');
  const [hostDirs, setHostDirs] = useState<HostDirEntry[]>([]);
  const [showHostBrowser, setShowHostBrowser] = useState(!isEdit && kind === 'local');

  // SMB
  const [smbHost, setSmbHost] = useState(String(mount?.config?.host || ''));
  const [smbShare, setSmbShare] = useState(String(mount?.config?.share || ''));
  const [smbRoot, setSmbRoot] = useState(String(mount?.config?.rootPath || '/'));
  const [smbDomain, setSmbDomain] = useState(String(mount?.config?.domain || ''));
  const [smbUser, setSmbUser] = useState(String(mount?.config?.username || ''));
  const [smbPass, setSmbPass] = useState('');
  const [smbFallback, setSmbFallback] = useState(String(mount?.config?.fallbackUrl || ''));

  // WebDAV
  const [davUrl, setDavUrl] = useState(String(mount?.config?.baseUrl || ''));
  const [davFallback, setDavFallback] = useState(String(mount?.config?.fallbackUrl || ''));
  const [davUser, setDavUser] = useState(String(mount?.config?.username || ''));
  const [davPass, setDavPass] = useState('');
  const [davInsecure, setDavInsecure] = useState(Boolean(mount?.config?.allowInsecureTls));

  // Quark
  const [quarkMode, setQuarkMode] = useState<'pc' | 'web'>((mount?.config?.quarkMode as 'pc' | 'web') || 'pc');
  const [quarkRootId, setQuarkRootId] = useState(String(mount?.config?.rootFolderId || '0'));
  const [quarkIntervalMs, setQuarkIntervalMs] = useState(Number(mount?.config?.requestIntervalMs || 1000));
  const [quarkCookie, setQuarkCookie] = useState('');
  const [qrImgUrl, setQrImgUrl] = useState('');
  const [qrStatus, setQrStatus] = useState('');
  const [qrSessionId, setQrSessionId] = useState('');

  // Path filters
  const toLines = (v: unknown): string => (Array.isArray(v) ? v.map(String).join('\n') : '');
  const [includeText, setIncludeText] = useState(toLines(mount?.config?.includePaths));
  const [excludeText, setExcludeText] = useState(toLines(mount?.config?.excludePaths));
  const [mountDirs, setMountDirs] = useState<string[]>([]);

  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);

  const loadHostDir = async (p?: string) => {
    try {
      const res = await api.browseHostFS(p);
      setHostCurrent(res.current);
      setHostParent(res.parent);
      setHostDirs(res.dirs || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  useEffect(() => {
    if (showHostBrowser) {
      void loadHostDir(rootPath || undefined);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [showHostBrowser]);

  useEffect(() => {
    if (mount?.id) {
      api
        .browseMount(mount.id, '/')
        .then((res) => {
          setMountDirs(res.entries.filter((e) => e.is_dir).map((e) => e.path));
        })
        .catch(() => {});
    }
  }, [mount?.id]);

  // Poll Quark QR status
  useEffect(() => {
    if (!qrSessionId) return;
    let active = true;
    const timer = window.setInterval(async () => {
      try {
        const res = await api.quarkQrPoll(qrSessionId);
        if (!active) return;
        if (res.status === 'confirmed' && res.secret) {
          setQuarkCookie(res.secret);
          setQrStatus('扫码授权成功，凭据已自动填入！');
          setQrSessionId('');
          toast('夸克扫码登录成功', 'success');
        } else if (res.status === 'expired') {
          setQrStatus('二维码已过期，请点击刷新重试');
          setQrSessionId('');
        }
      } catch (err) {
        if (active) setQrStatus((err as Error).message);
      }
    }, 2000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [qrSessionId, toast]);

  const startQuarkQr = async () => {
    setQrStatus('正在生成二维码...');
    setQrImgUrl('');
    try {
      const res = await api.quarkQrStart(quarkMode);
      const url = await QRCode.toDataURL(res.qr_content, { width: 220, margin: 2 });
      setQrImgUrl(url);
      setQrSessionId(res.session_id);
      setQrStatus(quarkMode === 'pc' ? '请使用手机夸克 App 扫码登录 (PC 令牌模式)' : '请使用手机夸克 App 扫码登录 (Web 模式)');
    } catch (err) {
      setQrStatus((err as Error).message);
    }
  };

  const splitLines = (txt: string): string[] =>
    txt
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);

  const buildPayload = () => {
    const includePaths = splitLines(includeText);
    const excludePaths = splitLines(excludeText);
    let config: Record<string, unknown> = { includePaths, excludePaths };
    const secrets: Record<string, string> = {};

    if (kind === 'local') {
      config = { ...config, rootPath: rootPath.trim() };
    } else if (kind === 'smb') {
      config = {
        ...config,
        host: smbHost.trim(),
        share: smbShare.trim(),
        rootPath: smbRoot.trim() || '/',
        domain: smbDomain.trim(),
        username: smbUser.trim(),
        fallbackUrl: smbFallback.trim(),
      };
      if (smbPass) secrets.password = smbPass;
    } else if (kind === 'webdav') {
      config = {
        ...config,
        baseUrl: davUrl.trim(),
        fallbackUrl: davFallback.trim(),
        username: davUser.trim(),
        allowInsecureTls: davInsecure,
      };
      if (davPass) secrets.password = davPass;
    } else if (kind === 'quark') {
      config = {
        ...config,
        quarkMode,
        rootFolderId: quarkRootId.trim() || '0',
        requestIntervalMs: Number(quarkIntervalMs) || 1000,
      };
      if (quarkCookie.trim()) secrets.cookie = quarkCookie.trim();
    }

    return { config, secrets };
  };

  const handleTest = async () => {
    setTesting(true);
    try {
      const { config, secrets } = buildPayload();
      await api.testMount({ id: mount?.id, kind, config, secrets });
      toast('连接测试成功', 'success');
    } catch (err) {
      toast(`连接失败: ${(err as Error).message}`, 'error');
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast('请输入挂载源名称', 'error');
      return;
    }
    setSaving(true);
    try {
      const { config, secrets } = buildPayload();
      if (mount) {
        await api.updateMount(mount.id, {
          name: name.trim(),
          config,
          secrets: Object.keys(secrets).length > 0 ? secrets : undefined,
          enabled,
        });
        toast('挂载源已更新', 'success');
      } else {
        await api.createMount({
          name: name.trim(),
          kind,
          config,
          secrets,
          enabled,
          auto_scan: autoScan,
        });
        toast('挂载源已添加并开始扫描', 'success');
      }
      onSaved();
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  const toggleIncludeDir = (p: string) => {
    const lines = splitLines(includeText);
    if (lines.includes(p)) {
      setIncludeText(lines.filter((x) => x !== p).join('\n'));
    } else {
      setIncludeText([...lines, p].join('\n'));
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <form className="modal-panel" onClick={(e) => e.stopPropagation()} onSubmit={handleSave}>
        <div className="modal-header">
          <h3>{isEdit ? `编辑挂载源：${mount?.name}` : '添加存储挂载源'}</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body">
          {!isEdit && (
            <div className="field">
              <label>存储类型</label>
              <div className="flex-row">
                {(
                  [
                    ['local', '本地/服务器目录'],
                    ['smb', 'SMB/CIFS 共享'],
                    ['webdav', 'WebDAV / Alist'],
                    ['quark', '夸克网盘'],
                  ] as const
                ).map(([k, label]) => (
                  <button
                    key={k}
                    type="button"
                    className={`chip ${kind === k ? 'active' : ''}`}
                    onClick={() => {
                      setKind(k);
                      if (k === 'local') setShowHostBrowser(true);
                    }}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
          )}

          <div className="grid-2">
            <div className="field">
              <label>挂载源名称</label>
              <input
                className="input"
                placeholder="例如：NAS 4K 电影 / 我的夸克网盘"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </div>
            <div className="field">
              <label>状态与扫描</label>
              <div className="flex-row" style={{ paddingTop: 6 }}>
                <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                  <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
                  启用此挂载源
                </label>
                {!isEdit && (
                  <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                    <input type="checkbox" checked={autoScan} onChange={(e) => setAutoScan(e.target.checked)} />
                    保存后自动扫描
                  </label>
                )}
              </div>
            </div>
          </div>

          {kind === 'local' && (
            <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div className="field">
                <label>服务器本地目录路径</label>
                <div className="flex-row">
                  <input
                    className="input"
                    style={{ flex: 1 }}
                    placeholder="例如：E:\Movies 或 /mnt/media"
                    value={rootPath}
                    onChange={(e) => setRootPath(e.target.value)}
                    required
                  />
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => setShowHostBrowser((v) => !v)}
                  >
                    <Folder size={14} />
                    浏览服务器目录
                  </button>
                </div>
              </div>

              {showHostBrowser && (
                <div
                  style={{
                    border: '1px solid var(--border-subtle)',
                    borderRadius: 10,
                    padding: 10,
                    background: 'rgba(0,0,0,0.28)',
                  }}
                >
                  <div className="flex-row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
                    <span className="muted-sm">{hostCurrent || '此电脑 / 根目录'}</span>
                    <div className="flex-row">
                      {hostParent !== hostCurrent && (
                        <button type="button" className="btn btn-sm" onClick={() => void loadHostDir(hostParent)}>
                          返回上级
                        </button>
                      )}
                      {hostCurrent && (
                        <button
                          type="button"
                          className="btn btn-sm btn-primary"
                          onClick={() => {
                            setRootPath(hostCurrent);
                            setShowHostBrowser(false);
                          }}
                        >
                          选择当前目录
                        </button>
                      )}
                    </div>
                  </div>
                  <div style={{ maxHeight: 170, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 4 }}>
                    {hostDirs.map((d) => (
                      <button
                        key={d.path}
                        type="button"
                        className="nav-item"
                        style={{ padding: '6px 10px', fontSize: 13 }}
                        onClick={() => void loadHostDir(d.path)}
                      >
                        <Folder size={14} />
                        <span>{d.name}</span>
                      </button>
                    ))}
                    {hostDirs.length === 0 && <span className="muted-sm">此目录下无子文件夹</span>}
                  </div>
                </div>
              )}
            </div>
          )}

          {kind === 'smb' && (
            <div className="grid-2">
              <div className="field">
                <label>主机地址 (IP 或主机名)</label>
                <input className="input" placeholder="192.168.1.10" value={smbHost} onChange={(e) => setSmbHost(e.target.value)} required />
              </div>
              <div className="field">
                <label>共享名 (Share)</label>
                <input className="input" placeholder="Media" value={smbShare} onChange={(e) => setSmbShare(e.target.value)} required />
              </div>
              <div className="field">
                <label>共享内子目录</label>
                <input className="input" placeholder="/" value={smbRoot} onChange={(e) => setSmbRoot(e.target.value)} />
              </div>
              <div className="field">
                <label>域名 / Domain (可选)</label>
                <input className="input" placeholder="WORKGROUP" value={smbDomain} onChange={(e) => setSmbDomain(e.target.value)} />
              </div>
              <div className="field">
                <label>用户名</label>
                <input className="input" value={smbUser} onChange={(e) => setSmbUser(e.target.value)} />
              </div>
              <div className="field">
                <label>{isEdit && mount?.has_secret ? '密码（留空保留原密码）' : '密码'}</label>
                <input className="input" type="password" value={smbPass} onChange={(e) => setSmbPass(e.target.value)} />
              </div>
              <div className="field" style={{ gridColumn: '1 / -1' }}>
                <label>客户端直连基准 URL（可选，供原生客户端直连预留）</label>
                <input className="input" placeholder="smb://192.168.1.10/Media" value={smbFallback} onChange={(e) => setSmbFallback(e.target.value)} />
              </div>
            </div>
          )}

          {kind === 'webdav' && (
            <div className="grid-2">
              <div className="field" style={{ gridColumn: '1 / -1' }}>
                <label>WebDAV Base URL</label>
                <input className="input" placeholder="https://nas.example.com:5006/video" value={davUrl} onChange={(e) => setDavUrl(e.target.value)} required />
              </div>
              <div className="field">
                <label>用户名</label>
                <input className="input" value={davUser} onChange={(e) => setDavUser(e.target.value)} />
              </div>
              <div className="field">
                <label>{isEdit && mount?.has_secret ? '密码（留空保留原密码）' : '密码'}</label>
                <input className="input" type="password" value={davPass} onChange={(e) => setDavPass(e.target.value)} />
              </div>
              <div className="field">
                <label>备用/直连 URL（可选）</label>
                <input className="input" value={davFallback} onChange={(e) => setDavFallback(e.target.value)} />
              </div>
              <div className="field" style={{ justifyContent: 'flex-end' }}>
                <label className="flex-row" style={{ cursor: 'pointer', paddingBottom: 8 }}>
                  <input type="checkbox" checked={davInsecure} onChange={(e) => setDavInsecure(e.target.checked)} />
                  允许自签名 HTTPS 证书
                </label>
              </div>
            </div>
          )}

          {kind === 'quark' && (
            <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div className="grid-3">
                <div className="field">
                  <label>登录模式</label>
                  <select className="select" value={quarkMode} onChange={(e) => setQuarkMode(e.target.value as 'pc' | 'web')}>
                    <option value="pc">PC 令牌模式（推荐，支持高画质签名）</option>
                    <option value="web">Web Cookie 模式</option>
                  </select>
                </div>
                <div className="field">
                  <label>根目录 FID (0 为全部)</label>
                  <input className="input" value={quarkRootId} onChange={(e) => setQuarkRootId(e.target.value)} />
                </div>
                <div className="field">
                  <label>请求间隔 (ms)</label>
                  <input
                    className="input"
                    type="number"
                    min={200}
                    max={10000}
                    value={quarkIntervalMs}
                    onChange={(e) => setQuarkIntervalMs(Number(e.target.value))}
                  />
                </div>
              </div>

              <div className="flex-row" style={{ alignItems: 'flex-start', gap: 16 }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <button type="button" className="btn btn-sm" onClick={() => void startQuarkQr()}>
                    {qrImgUrl ? <RefreshCw size={14} /> : <QrCode size={14} />}
                    {qrImgUrl ? '刷新二维码' : '手机夸克扫码获取授权'}
                  </button>
                  {qrImgUrl && (
                    <img
                      src={qrImgUrl}
                      alt="夸克登录二维码"
                      style={{ width: 160, height: 160, borderRadius: 10, background: '#fff', padding: 6 }}
                    />
                  )}
                  {qrStatus && <span className="muted-sm">{qrStatus}</span>}
                </div>

                <div className="field" style={{ flex: 1 }}>
                  <label>
                    {isEdit && mount?.has_secret
                      ? '授权 Cookie / PC 凭据 JSON（留空保持现有凭据）'
                      : '授权 Cookie / PC 凭据 JSON（扫码自动填入，也可手动粘贴）'}
                  </label>
                  <textarea
                    className="textarea"
                    placeholder='扫码后自动填入；或粘贴 web cookie / {"token":"...","uid":"..."}'
                    value={quarkCookie}
                    onChange={(e) => setQuarkCookie(e.target.value)}
                  />
                </div>
              </div>
            </div>
          )}

          <div className="divider" />

          {mountDirs.length > 0 && (
            <div className="field">
              <label>快速选择子目录加入仅扫描范围（点击切换）</label>
              <div className="flex-row">
                {mountDirs.slice(0, 16).map((p) => {
                  const selected = splitLines(includeText).includes(p);
                  return (
                    <button
                      key={p}
                      type="button"
                      className={`chip ${selected ? 'active' : ''}`}
                      onClick={() => toggleIncludeDir(p)}
                    >
                      {selected && <Check size={12} />}
                      <span>{p}</span>
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          <div className="grid-2">
            <div className="field">
              <label>仅扫描子目录（每行一个相对路径，留空扫描全部）</label>
              <textarea
                className="textarea"
                style={{ minHeight: 68 }}
                placeholder="/电影&#10;/剧集"
                value={includeText}
                onChange={(e) => setIncludeText(e.target.value)}
              />
            </div>
            <div className="field">
              <label>排除目录（每行一个相对路径）</label>
              <textarea
                className="textarea"
                style={{ minHeight: 68 }}
                placeholder="/临时下载&#10;/花絮"
                value={excludeText}
                onChange={(e) => setExcludeText(e.target.value)}
              />
            </div>
          </div>
        </div>

        <div className="modal-footer">
          <button type="button" className="btn" onClick={() => void handleTest()} disabled={testing || saving}>
            {testing && <Loader2 size={14} className="spin" />}
            测试连接
          </button>
          <div style={{ flex: 1 }} />
          <button type="button" className="btn" onClick={onClose}>
            取消
          </button>
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving && <Loader2 size={14} className="spin" />}
            {isEdit ? '保存更改' : '保存并挂载'}
          </button>
        </div>
      </form>
    </div>
  );
};
