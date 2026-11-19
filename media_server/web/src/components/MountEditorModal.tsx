import React, { useEffect, useState } from 'react';
import {
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Cloud,
  FolderOpen,
  Globe,
  HardDrive,
  Loader2,
  Lock,
  Plus,
  QrCode,
  Server,
  Trash2,
  X,
} from 'lucide-react';
import { api, formatBytes } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MountKind, MountRecord } from '../types';
import { RadioCardGroup } from './CustomSelect';
import { DirectoryPickerModal } from './DirectoryPickerModal';
import { QuarkQrModal } from './QuarkQrModal';

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
  const [quarkIntervalMs, setQuarkIntervalMs] = useState(Number(mount?.config?.requestIntervalMs || 1000));
  const [quarkCookie, setQuarkCookie] = useState('');
  const [showQrModal, setShowQrModal] = useState(false);
  const [showManualQuarkInput, setShowManualQuarkInput] = useState(false);
  const [quarkAccount, setQuarkAccount] = useState<{
    nickname?: string;
    member_type: string;
    used_bytes: number;
    total_bytes: number;
  } | null>(null);
  const [quarkAccountLoading, setQuarkAccountLoading] = useState(false);
  const [quarkAccountErr, setQuarkAccountErr] = useState('');

  // Path filters (array lists managed via popup modals)
  const toArray = (v: unknown): string[] => (Array.isArray(v) ? v.map(String).filter(Boolean) : []);
  const [includePaths, setIncludePaths] = useState<string[]>(toArray(mount?.config?.includePaths));
  const [excludePaths, setExcludePaths] = useState<string[]>(toArray(mount?.config?.excludePaths));
  const [showAdvanced, setShowAdvanced] = useState(
    toArray(mount?.config?.excludePaths).length > 0 || Number(mount?.config?.requestIntervalMs || 1000) !== 1000
  );

  // Unified Directory Picker Popup state
  const [dirPicker, setDirPicker] = useState<
    | null
    | {
        mode: 'local-root' | 'smb-root' | 'include-dirs' | 'exclude-dirs';
      }
  >(null);

  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);

  const isQuarkAuthed =
    kind === 'quark' && Boolean(quarkCookie.trim() || (isEdit && mount?.has_secret && mount.kind === 'quark'));

  useEffect(() => {
    if (!isQuarkAuthed) {
      setQuarkAccount(null);
      setQuarkAccountErr('');
      return;
    }
    let cancelled = false;
    setQuarkAccountLoading(true);
    setQuarkAccountErr('');
    api
      .quarkAccountPreview({
        id: mount?.id,
        mode: quarkMode,
        secret: quarkCookie.trim() || undefined,
      })
      .then((res) => {
        if (!cancelled) {
          setQuarkAccount(res.account);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setQuarkAccount(null);
          setQuarkAccountErr((err as Error).message || '无法读取夸克账号信息');
        }
      })
      .finally(() => {
        if (!cancelled) setQuarkAccountLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [isQuarkAuthed, mount?.id, quarkMode, quarkCookie]);

  const buildPayload = () => {
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
        rootFolderId: String(mount?.config?.rootFolderId || '0'),
        requestIntervalMs: Number(quarkIntervalMs) || 1000,
      };
      if (quarkCookie.trim()) secrets.cookie = quarkCookie.trim();
    }

    return { config, secrets };
  };

  const canBrowseRemote = () => {
    if (kind === 'quark') return isQuarkAuthed;
    if (kind === 'smb') return Boolean(smbHost.trim() && smbShare.trim());
    if (kind === 'webdav') return Boolean(davUrl.trim());
    return Boolean(rootPath.trim());
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
    if (kind === 'local' && !rootPath.trim()) {
      toast('请选择本地媒体目录', 'error');
      return;
    }
    if (kind === 'quark' && !isQuarkAuthed) {
      toast('请先扫码登录夸克网盘后再保存', 'error');
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

  const { config: previewConfig, secrets: previewSecrets } = buildPayload();

  return (
    <>
      <div className="modal-backdrop" onClick={onClose}>
        <form className="modal-panel" style={{ maxWidth: 720 }} onClick={(e) => e.stopPropagation()} onSubmit={handleSave}>
          <div className="modal-header">
            <h3>{isEdit ? `编辑挂载源：${mount?.name}` : '添加存储挂载源'}</h3>
            <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
              <X size={16} />
            </button>
          </div>

          <div className="modal-body" style={{ gap: 16 }}>
            {!isEdit && (
              <div className="field">
                <label>选择存储类型</label>
                <RadioCardGroup
                  columns={2}
                  value={kind}
                  onChange={(nextKind) => setKind(nextKind)}
                  options={[
                    {
                      value: 'local',
                      title: '本地 / 服务器目录',
                      description: '直接挂载服务器本机磁盘路径或高速硬盘阵列',
                      icon: <HardDrive size={15} style={{ color: 'var(--accent)' }} />,
                    },
                    {
                      value: 'quark',
                      title: '夸克网盘',
                      badge: '推荐',
                      description: '扫码登录读取网盘目录，支持原画直传与云端转码',
                      icon: <Cloud size={15} style={{ color: 'var(--accent)' }} />,
                    },
                    {
                      value: 'smb',
                      title: 'SMB / CIFS 共享',
                      description: '连接局域网 NAS 或路由器 SMB 网络共享文件夹',
                      icon: <Server size={15} style={{ color: 'var(--accent)' }} />,
                    },
                    {
                      value: 'webdav',
                      title: 'WebDAV / Alist',
                      description: '挂载标准 WebDAV 网盘或 Alist 聚合存储服务',
                      icon: <Globe size={15} style={{ color: 'var(--accent)' }} />,
                    },
                  ]}
                />
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
                <label>启用状态与行为</label>
                <div className="flex-row" style={{ paddingTop: 7 }}>
                  <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                    <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
                    启用此挂载源
                  </label>
                  {!isEdit && (
                    <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                      <input type="checkbox" checked={autoScan} onChange={(e) => setAutoScan(e.target.checked)} />
                      保存后立即扫描
                    </label>
                  )}
                </div>
              </div>
            </div>

            {/* ─── Local Directory ─── */}
            {kind === 'local' && (
              <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
                <div className="field">
                  <label>服务器本地目录</label>
                  <div className="flex-row">
                    <input
                      className="input"
                      style={{ flex: 1, fontFamily: 'var(--font-mono)' }}
                      placeholder="点击右侧按钮通过弹窗选择本地目录..."
                      value={rootPath}
                      onChange={(e) => setRootPath(e.target.value)}
                      required
                    />
                    <button
                      type="button"
                      className="btn btn-primary btn-sm"
                      onClick={() => setDirPicker({ mode: 'local-root' })}
                    >
                      <FolderOpen size={14} />
                      选择目录
                    </button>
                  </div>
                </div>
              </div>
            )}

            {/* ─── SMB Share ─── */}
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
                  <label>共享起始子目录</label>
                  <div className="flex-row">
                    <input className="input" style={{ flex: 1 }} placeholder="/" value={smbRoot} onChange={(e) => setSmbRoot(e.target.value)} />
                    <button
                      type="button"
                      className="btn btn-sm"
                      disabled={!smbHost.trim() || !smbShare.trim()}
                      onClick={() => setDirPicker({ mode: 'smb-root' })}
                    >
                      <FolderOpen size={14} />
                      浏览
                    </button>
                  </div>
                </div>
                <div className="field">
                  <label>域名 / Domain（可选）</label>
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
                  <label>客户端直连基准 URL（可选）</label>
                  <input className="input" placeholder="smb://192.168.1.10/Media" value={smbFallback} onChange={(e) => setSmbFallback(e.target.value)} />
                </div>
              </div>
            )}

            {/* ─── WebDAV ─── */}
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
                  <label>备用直连 URL（可选）</label>
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

            {/* ─── Quark Cloud Drive ─── */}
            {kind === 'quark' && (
              <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 14 }}>
                <div className="field">
                  <label>登录授权模式</label>
                  <RadioCardGroup
                    columns={2}
                    value={quarkMode}
                    onChange={(m) => setQuarkMode(m)}
                    options={[
                      {
                        value: 'pc',
                        title: 'PC 令牌模式',
                        badge: '推荐',
                        description: '支持原画直传签名与自动续期，画质与稳定性最佳',
                      },
                      {
                        value: 'web',
                        title: 'Web Cookie 模式',
                        description: '使用网页端 Cookie 会话，兼容多档云转码流',
                      },
                    ]}
                  />
                </div>

                {/* Login status & QR trigger */}
                <div
                  style={{
                    padding: '12px 14px',
                    borderRadius: 12,
                    border: `1px solid ${isQuarkAuthed ? 'rgba(93, 214, 138, 0.35)' : 'var(--border-glass)'}`,
                    background: isQuarkAuthed ? 'rgba(93, 214, 138, 0.08)' : 'rgba(255, 255, 255, 0.02)',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 10,
                  }}
                >
                  <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                    <div className="flex-row" style={{ gap: 8 }}>
                      {isQuarkAuthed ? (
                        <>
                          <CheckCircle2 size={17} style={{ color: 'var(--success)' }} />
                          <strong style={{ fontSize: 14, color: '#bdf7d2' }}>夸克账号已登录</strong>
                          {quarkAccountLoading && <Loader2 size={14} className="spin muted" />}
                          {quarkAccount && (
                            <span className="muted-sm">
                              {quarkAccount.nickname ? `${quarkAccount.nickname} · ` : ''}
                              {quarkAccount.member_type || '标准账号'} · 已用{' '}
                              {formatBytes(quarkAccount.used_bytes)} / {formatBytes(quarkAccount.total_bytes)}
                            </span>
                          )}
                          {quarkAccountErr && (
                            <span className="muted-sm" style={{ color: 'var(--warning)' }}>
                              ({quarkAccountErr})
                            </span>
                          )}
                        </>
                      ) : (
                        <>
                          <Lock size={16} className="muted" />
                          <span style={{ fontSize: 13 }}>尚未登录夸克账号</span>
                        </>
                      )}
                    </div>

                    <div className="flex-row">
                      <button
                        type="button"
                        className={`btn btn-sm ${isQuarkAuthed ? '' : 'btn-primary'}`}
                        onClick={() => setShowQrModal(true)}
                      >
                        <QrCode size={14} />
                        {isQuarkAuthed ? '重新扫码授权' : '获取登录二维码'}
                      </button>
                      <button
                        type="button"
                        className="btn btn-sm"
                        onClick={() => setShowManualQuarkInput((v) => !v)}
                      >
                        {showManualQuarkInput ? '收起手动输入' : '手动粘贴凭据'}
                      </button>
                    </div>
                  </div>

                  {showManualQuarkInput && (
                    <div className="field" style={{ marginTop: 4 }}>
                      <label>手动粘贴 Cookie / PC 凭据 JSON</label>
                      <textarea
                        className="textarea"
                        style={{ minHeight: 68, fontFamily: 'var(--font-mono)', fontSize: 12 }}
                        placeholder='可粘贴 web cookie，或 {"token":"...","uid":"...","nickname":"..."}'
                        value={quarkCookie}
                        onChange={(e) => setQuarkCookie(e.target.value)}
                      />
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* ─── Scan Directories (Quark requires login first!) ─── */}
            <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                <div>
                  <strong style={{ fontSize: 14 }}>
                    {kind === 'quark' ? '夸克网盘扫描目录' : '指定扫描目录（可选）'}
                  </strong>
                  <div className="muted-sm">
                    {kind === 'quark'
                      ? '登录后点击右侧按钮读取夸克网盘内的目录并添加；不添加时默认扫描网盘全部内容'
                      : '不添加时默认扫描整个挂载源根目录；添加后仅扫描所选目录'}
                  </div>
                </div>
                <button
                  type="button"
                  className="btn btn-primary btn-sm"
                  disabled={!canBrowseRemote()}
                  onClick={() => setDirPicker({ mode: 'include-dirs' })}
                >
                  <Plus size={14} />
                  添加目录
                </button>
              </div>

              {kind === 'quark' && !isQuarkAuthed ? (
                <div className="locked-box">
                  <Lock size={16} />
                  <span>请先点击上方「获取登录二维码」完成夸克登录，登录后即可读取并添加网盘内的文件夹。</span>
                </div>
              ) : includePaths.length === 0 ? (
                <div className="muted-sm" style={{ padding: '4px 0' }}>
                  当前将扫描全部目录（可点击「添加目录」限定只扫描指定文件夹）。
                </div>
              ) : (
                <div className="selected-dir-list">
                  {includePaths.map((p) => (
                    <div key={p} className="selected-dir-item">
                      <span style={{ fontFamily: 'var(--font-mono)', wordBreak: 'break-all' }}>{p}</span>
                      <button
                        type="button"
                        className="btn btn-icon btn-sm"
                        style={{ width: 26, height: 26, padding: 0 }}
                        onClick={() => setIncludePaths((prev) => prev.filter((x) => x !== p))}
                        title="移除此目录"
                      >
                        <Trash2 size={13} />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* ─── Advanced Options ─── */}
            <div>
              <button
                type="button"
                className="btn btn-sm"
                style={{ background: 'transparent', borderColor: 'transparent', paddingLeft: 4, color: 'var(--text-secondary)' }}
                onClick={() => setShowAdvanced((v) => !v)}
              >
                {showAdvanced ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                高级筛选与请求参数
              </button>

              {showAdvanced && (
                <div className="card-box" style={{ padding: 14, marginTop: 8, display: 'flex', flexDirection: 'column', gap: 12 }}>
                  <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                    <div>
                      <strong style={{ fontSize: 13 }}>排除目录（跳过不扫描）</strong>
                      <div className="muted-sm">例如临时下载目录或花絮目录</div>
                    </div>
                    <button
                      type="button"
                      className="btn btn-sm"
                      disabled={!canBrowseRemote()}
                      onClick={() => setDirPicker({ mode: 'exclude-dirs' })}
                    >
                      <FolderOpen size={13} />
                      选择排除目录
                    </button>
                  </div>

                  {excludePaths.length > 0 && (
                    <div className="selected-dir-list">
                      {excludePaths.map((p) => (
                        <div key={p} className="selected-dir-item">
                          <span style={{ fontFamily: 'var(--font-mono)' }}>{p}</span>
                          <button
                            type="button"
                            className="btn btn-icon btn-sm"
                            style={{ width: 26, height: 26, padding: 0 }}
                            onClick={() => setExcludePaths((prev) => prev.filter((x) => x !== p))}
                          >
                            <X size={13} />
                          </button>
                        </div>
                      ))}
                    </div>
                  )}

                  {kind === 'quark' && (
                    <div className="field" style={{ maxWidth: 240 }}>
                      <label>夸克 API 请求间隔 (毫秒，防限流)</label>
                      <input
                        className="input"
                        type="number"
                        min={200}
                        max={10000}
                        value={quarkIntervalMs}
                        onChange={(e) => setQuarkIntervalMs(Number(e.target.value))}
                      />
                    </div>
                  )}
                </div>
              )}
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

      {/* Independent Quark QR Login Modal */}
      {showQrModal && (
        <QuarkQrModal
          mode={quarkMode}
          onClose={() => setShowQrModal(false)}
          onSuccess={(secret) => setQuarkCookie(secret)}
        />
      )}

      {/* Unified Directory Picker Modal */}
      {dirPicker && (
        <DirectoryPickerModal
          title={
            dirPicker.mode === 'local-root'
              ? '选择本地媒体根目录'
              : dirPicker.mode === 'smb-root'
              ? '选择 SMB 共享起始目录'
              : dirPicker.mode === 'include-dirs'
              ? kind === 'quark'
                ? '浏览夸克网盘并添加扫描目录'
                : '选择要扫描的子目录'
              : '选择要排除的目录'
          }
          sourceType={dirPicker.mode === 'local-root' ? 'host' : 'remote'}
          selectMode={
            dirPicker.mode === 'local-root' || dirPicker.mode === 'smb-root' ? 'single' : 'multi'
          }
          mountPreview={
            dirPicker.mode === 'local-root'
              ? undefined
              : {
                  id: mount?.id,
                  kind,
                  config:
                    dirPicker.mode === 'smb-root'
                      ? { ...previewConfig, rootPath: '/' }
                      : previewConfig,
                  secrets: previewSecrets,
                }
          }
          initialPath={dirPicker.mode === 'local-root' ? rootPath : '/'}
          initialSelected={
            dirPicker.mode === 'include-dirs'
              ? includePaths
              : dirPicker.mode === 'exclude-dirs'
              ? excludePaths
              : []
          }
          onClose={() => setDirPicker(null)}
          onConfirm={(paths) => {
            if (dirPicker.mode === 'local-root' && paths[0]) {
              setRootPath(paths[0]);
            } else if (dirPicker.mode === 'smb-root' && paths[0]) {
              setSmbRoot(paths[0]);
            } else if (dirPicker.mode === 'include-dirs') {
              setIncludePaths(paths);
            } else if (dirPicker.mode === 'exclude-dirs') {
              setExcludePaths(paths);
            }
          }}
        />
      )}
    </>
  );
};
