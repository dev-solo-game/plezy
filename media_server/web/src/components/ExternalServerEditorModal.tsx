import React, { useState } from 'react';
import { CheckCircle2, KeyRound, Loader2, Server, UserCheck, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type {
  ExternalServerAuthMode,
  ExternalServerKind,
  ExternalServerRecord,
  ExternalServerTestResult,
} from '../types';
import { RadioCardGroup } from './CustomSelect';

interface ExternalServerEditorModalProps {
  server?: ExternalServerRecord | null;
  onClose: () => void;
  onSaved: () => void;
}

export const ExternalServerEditorModal: React.FC<ExternalServerEditorModalProps> = ({
  server,
  onClose,
  onSaved,
}) => {
  const { toast, refreshExternalServers } = useApp();
  const isEdit = Boolean(server);

  const [kind, setKind] = useState<ExternalServerKind>(server?.kind || 'jellyfin');
  const [authMode, setAuthMode] = useState<ExternalServerAuthMode>(server?.auth_mode || 'password');
  const [name, setName] = useState(server?.name || '');
  const [baseUrl, setBaseUrl] = useState(server?.base_url || '');
  const [username, setUsername] = useState(server?.username || '');
  const [password, setPassword] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [userId, setUserId] = useState(server?.user_id || '');
  const [allowInsecureTls, setAllowInsecureTls] = useState(Boolean(server?.allow_insecure_tls));
  const [enabled, setEnabled] = useState(server ? server.enabled : true);

  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);
  const [testResult, setTestResult] = useState<ExternalServerTestResult | null>(null);

  const handleTest = async () => {
    if (!baseUrl.trim()) {
      toast('请填写服务器地址', 'error');
      return;
    }
    if (authMode === 'password' && !username.trim()) {
      toast('请填写登录用户名', 'error');
      return;
    }
    if (authMode === 'password' && !isEdit && !password.trim()) {
      toast('请填写登录密码', 'error');
      return;
    }
    if (authMode === 'apikey' && !isEdit && !apiKey.trim()) {
      toast('请填写 API Key', 'error');
      return;
    }

    setTesting(true);
    setTestResult(null);
    try {
      const res = await api.testExternalServer({
        id: server?.id,
        kind,
        base_url: baseUrl.trim(),
        auth_mode: authMode,
        username: username.trim(),
        password: password,
        api_key: apiKey.trim(),
        user_id: userId.trim(),
        allow_insecure_tls: allowInsecureTls,
      });
      setTestResult(res);
      if (!name.trim() && res.server_name) {
        setName(res.server_name);
      }
      if (res.effective_base_url && res.effective_base_url !== baseUrl.trim()) {
        setBaseUrl(res.effective_base_url);
      }
      if (res.detected_kind === 'emby' || res.detected_kind === 'jellyfin') {
        if (res.detected_kind !== kind) {
          setKind(res.detected_kind);
          toast(`已自动识别服务器类型为 ${res.detected_kind === 'emby' ? 'Emby' : 'Jellyfin'}`, 'info');
        }
      }
      toast(`连接成功 (${res.latency_ms}ms)`, 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!baseUrl.trim()) {
      toast('请填写服务器地址', 'error');
      return;
    }
    if (authMode === 'password' && !username.trim()) {
      toast('请填写用户名', 'error');
      return;
    }
    if (!isEdit) {
      if (authMode === 'password' && !password.trim()) {
        toast('请填写密码', 'error');
        return;
      }
      if (authMode === 'apikey' && !apiKey.trim()) {
        toast('请填写 API Key', 'error');
        return;
      }
    }

    setSaving(true);
    try {
      if (isEdit && server) {
        await api.updateExternalServer(server.id, {
          name: name.trim() || undefined,
          kind,
          base_url: baseUrl.trim(),
          auth_mode: authMode,
          username: username.trim(),
          password: password || undefined,
          api_key: apiKey.trim() || undefined,
          user_id: userId.trim() || undefined,
          allow_insecure_tls: allowInsecureTls,
          enabled,
        });
        toast('已更新外部媒体服务器', 'success');
      } else {
        await api.createExternalServer({
          name: name.trim() || undefined,
          kind,
          base_url: baseUrl.trim(),
          auth_mode: authMode,
          username: username.trim(),
          password: password || undefined,
          api_key: apiKey.trim() || undefined,
          user_id: userId.trim() || undefined,
          allow_insecure_tls: allowInsecureTls,
          enabled,
        });
        toast('已连接并添加外部媒体服务器', 'success');
      }
      await refreshExternalServers();
      onSaved();
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <form
        className="modal-panel"
        style={{ maxWidth: 640 }}
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => void handleSave(e)}
      >
        <div className="modal-header">
          <div className="flex-row" style={{ gap: 10 }}>
            <Server size={18} style={{ color: 'var(--accent)' }} />
            <h3>{isEdit ? `编辑服务器 · ${server?.name}` : '添加外部媒体服务器'}</h3>
          </div>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body" style={{ gap: 16 }}>
          <div className="field">
            <label>服务器类型</label>
            <RadioCardGroup
              value={kind}
              onChange={setKind}
              columns={2}
              options={[
                {
                  value: 'emby',
                  title: 'Emby',
                  description: '连接已有 Emby Server（支持 4.x+ 与 /emby 反代前缀）',
                  colorDot: '#52B54B',
                },
                {
                  value: 'jellyfin',
                  title: 'Jellyfin',
                  description: '连接已有 Jellyfin Server（支持 10.8 ~ 10.11+）',
                  colorDot: '#9A6CFF',
                },
              ]}
            />
          </div>

          <div className="field">
            <label>认证方式</label>
            <RadioCardGroup
              value={authMode}
              onChange={setAuthMode}
              columns={2}
              options={[
                {
                  value: 'password',
                  title: '账号密码登录',
                  description: '自动换取长效 Access Token，不在本地保存明文密码',
                  icon: <UserCheck size={15} />,
                  badge: '推荐',
                },
                {
                  value: 'apikey',
                  title: 'API Key 令牌',
                  description: '使用管理员后台签发的 API 密钥连接并绑定用户',
                  icon: <KeyRound size={15} />,
                },
              ]}
            />
          </div>

          <div className="grid-2" style={{ gap: 12 }}>
            <div className="field">
              <label>服务器地址 (URL)</label>
              <input
                className="input"
                value={baseUrl}
                onChange={(e) => setBaseUrl(e.target.value)}
                placeholder={kind === 'emby' ? 'http://192.168.1.20:8096' : 'https://jf.example.com'}
                required
              />
            </div>

            <div className="field">
              <label>显示名称（可选）</label>
              <input
                className="input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder={kind === 'emby' ? '留空自动读取服务器名称（如：家庭 Emby）' : '留空自动读取服务器名称（如：公益 Jellyfin）'}
              />
            </div>
          </div>

          {authMode === 'password' ? (
            <div className="grid-2" style={{ gap: 12 }}>
              <div className="field">
                <label>用户名</label>
                <input
                  className="input"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  placeholder="Emby / Jellyfin 账号"
                  required
                />
              </div>
              <div className="field">
                <label>
                  密码 {isEdit && server?.has_token ? '（留空保持已保存令牌）' : ''}
                </label>
                <input
                  className="input"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder={isEdit && server?.has_token ? '••••••••（留空不改）' : '登录密码'}
                  required={!isEdit}
                />
              </div>
            </div>
          ) : (
            <div className="grid-2" style={{ gap: 12 }}>
              <div className="field">
                <label>
                  API Key {isEdit && server?.has_token ? '（留空保持已保存令牌）' : ''}
                </label>
                <input
                  className="input"
                  type="password"
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  placeholder={isEdit && server?.has_token ? '已加密保存，留空不修改' : '粘贴 API Key'}
                  required={!isEdit}
                />
              </div>
              <div className="field">
                <label>目标用户名或 UserId（可选）</label>
                <input
                  className="input"
                  value={userId || username}
                  onChange={(e) => {
                    setUserId(e.target.value);
                    setUsername(e.target.value);
                  }}
                  placeholder="留空默认选择管理员用户"
                />
              </div>
            </div>
          )}

          <div className="flex-row" style={{ gap: 20, marginTop: 4 }}>
            <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
              <input
                type="checkbox"
                checked={allowInsecureTls}
                onChange={(e) => setAllowInsecureTls(e.target.checked)}
              />
              <span>允许自签名 HTTPS 证书（跳过 TLS 校验）</span>
            </label>

            {isEdit && (
              <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={enabled}
                  onChange={(e) => setEnabled(e.target.checked)}
                />
                <span>在侧边栏启用该服务器</span>
              </label>
            )}
          </div>

          {testResult && (
            <div
              className="card-box"
              style={{
                padding: '10px 14px',
                background: 'rgba(93, 214, 138, 0.08)',
                borderColor: 'rgba(93, 214, 138, 0.3)',
                fontSize: 13,
              }}
            >
              <div className="flex-row" style={{ gap: 8, color: 'var(--success)', fontWeight: 600 }}>
                <CheckCircle2 size={15} />
                <span>
                  已连通 · {testResult.server_name} ({testResult.product_name || kind.toUpperCase()} {testResult.version})
                </span>
              </div>
              <div className="muted-sm" style={{ marginTop: 4 }}>
                用户：{testResult.username || '-'}（{testResult.user_id}） · 延迟 {testResult.latency_ms}ms
              </div>
            </div>
          )}
        </div>

        <div className="modal-footer">
          <button type="button" className="btn" onClick={() => void handleTest()} disabled={testing || saving}>
            {testing && <Loader2 size={14} className="spin" />}
            测试连接
          </button>
          <div style={{ flex: 1 }} />
          <button type="button" className="btn" onClick={onClose} disabled={saving}>
            取消
          </button>
          <button type="submit" className="btn btn-primary" disabled={saving || testing}>
            {saving && <Loader2 size={14} className="spin" />}
            {isEdit ? '保存更改' : '连接并添加'}
          </button>
        </div>
      </form>
    </div>
  );
};
