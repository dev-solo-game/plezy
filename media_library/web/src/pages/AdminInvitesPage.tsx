import React, { useCallback, useEffect, useState } from 'react';
import { Copy, Globe, KeyRound, Lock, Plus, RefreshCw, Ticket, Trash2 } from 'lucide-react';
import { api, formatDateTime } from '../api/client';
import { RadioCardGroup } from '../components/CustomSelect';
import { TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { InviteCode } from '../types';

export const AdminInvitesPage: React.FC = () => {
  const { toast } = useApp();
  const [regMode, setRegMode] = useState<'open' | 'invite' | 'closed'>('open');
  const [invites, setInvites] = useState<InviteCode[]>([]);
  const [loading, setLoading] = useState(true);
  const [savingMode, setSavingMode] = useState(false);

  const [maxUses, setMaxUses] = useState(1);
  const [expiresHours, setExpiresHours] = useState<string>('');
  const [note, setNote] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [sRes, iRes] = await Promise.all([api.getSettings(), api.listInvites()]);
      const mode = sRes.settings.registration_mode;
      setRegMode(mode === 'invite' || mode === 'closed' ? mode : 'open');
      setInvites(iRes.invites || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const updateMode = async (mode: 'open' | 'invite' | 'closed') => {
    if (mode === regMode || savingMode) return;
    setSavingMode(true);
    try {
      await api.updateSettings({ registration_mode: mode });
      setRegMode(mode);
      toast('注册策略已更新', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSavingMode(false);
    }
  };

  const createInvite = async (e: React.FormEvent) => {
    e.preventDefault();
    if (creating) return;
    setCreating(true);
    try {
      const hoursNum = Number(expiresHours);
      const res = await api.createInvite({
        max_uses: maxUses,
        expires_at: hoursNum > 0 ? Date.now() + hoursNum * 3600 * 1000 : undefined,
        note: note.trim() || undefined,
      });
      setNote('');
      setExpiresHours('');
      toast(`已生成邀请码：${res.invite.code}`, 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const copyCode = async (code: string) => {
    try {
      await navigator.clipboard.writeText(code);
      toast(`已复制邀请码 ${code}`, 'success');
    } catch {
      toast('复制失败，请手动复制', 'error');
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">注册策略与邀请码</h1>
          <p className="page-subtitle">
            灵活控制新用户注册门槛，随时签发或作废一次性 / 多次使用邀请码。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新
        </button>
      </div>

      {/* Registration Mode Selector */}
      <div className="card-box">
        <div className="card-title-row">
          <h3 className="card-title">自助注册策略</h3>
          <span className="tag accent">实时生效</span>
        </div>
        <RadioCardGroup
          columns={3}
          disabled={savingMode}
          value={regMode}
          onChange={(v) => void updateMode(v)}
          options={[
            {
              value: 'open',
              title: '开放注册',
              icon: <Globe size={15} style={{ color: 'var(--success)' }} />,
              description: '客户端可直接注册新账号，无需填写邀请码。适合私人局域网或体验阶段。',
            },
            {
              value: 'invite',
              title: '仅邀请码注册',
              icon: <KeyRound size={15} style={{ color: 'var(--accent)' }} />,
              description: '注册时必须提供有效的邀请码，推荐在公网部署时开启以防恶意注册。',
            },
            {
              value: 'closed',
              title: '关闭自助注册',
              icon: <Lock size={15} style={{ color: 'var(--warning)' }} />,
              description: '暂停所有客户端注册入口，新账号只能由管理员在「用户账号管理」中手动创建。',
            },
          ]}
        />
      </div>

      {/* Generate Invite Form */}
      <form onSubmit={createInvite} className="card-box">
        <div className="card-title-row">
          <h3 className="card-title">
            <Ticket size={16} style={{ color: 'var(--accent)' }} />
            签发新邀请码
          </h3>
        </div>
        <div className="grid-3" style={{ alignItems: 'end' }}>
          <div className="field">
            <label>最大可用次数</label>
            <input
              className="input"
              type="number"
              min={1}
              max={1000}
              value={maxUses}
              onChange={(e) => setMaxUses(Number(e.target.value) || 1)}
            />
          </div>
          <div className="field">
            <label>有效期（小时，留空永久有效）</label>
            <input
              className="input"
              type="number"
              min={1}
              max={8760}
              placeholder="例如：72"
              value={expiresHours}
              onChange={(e) => setExpiresHours(e.target.value)}
            />
          </div>
          <div className="field">
            <label>备注说明（可选）</label>
            <div className="flex-row" style={{ flexWrap: 'nowrap' }}>
              <input
                className="input"
                placeholder="例如：给朋友体验"
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
              <button type="submit" className="btn btn-primary" disabled={creating}>
                <Plus size={15} />
                生成
              </button>
            </div>
          </div>
        </div>
      </form>

      {/* Invites Table */}
      <div className="card-box" style={{ padding: 16 }}>
        <div className="card-title-row" style={{ padding: '0 4px' }}>
          <h3 className="card-title">邀请码列表</h3>
          <span className="muted-sm">共 {invites.length} 条</span>
        </div>

        {loading && invites.length === 0 ? (
          <TableSkeleton rows={5} />
        ) : invites.length === 0 ? (
          <div className="empty-state">
            <Ticket size={28} />
            <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>暂无已签发的邀请码</div>
            <div className="muted-sm">在上方填写次数与备注后即可快速生成</div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>邀请码（点击复制）</th>
                  <th>使用进度</th>
                  <th>状态</th>
                  <th>备注</th>
                  <th>创建 / 过期时间</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {invites.map((inv) => {
                  const exhausted = inv.used_count >= inv.max_uses;
                  const expired = Boolean(inv.expires_at && inv.expires_at > 0 && inv.expires_at < Date.now());
                  const pct = inv.max_uses > 0 ? Math.min(100, Math.round((inv.used_count / inv.max_uses) * 100)) : 0;
                  return (
                    <tr key={inv.code}>
                      <td>
                        <button
                          type="button"
                          className="code-pill"
                          onClick={() => void copyCode(inv.code)}
                          title="点击复制邀请码"
                        >
                          <span>{inv.code}</span>
                          <Copy size={12} />
                        </button>
                      </td>
                      <td style={{ minWidth: 140 }}>
                        <div className="flex-row" style={{ justifyContent: 'space-between', fontSize: 12, marginBottom: 4 }}>
                          <span>
                            {inv.used_count} / {inv.max_uses}
                          </span>
                          <span className="muted-sm">{pct}%</span>
                        </div>
                        <div className="progress-track">
                          <div className="progress-track-fill" style={{ width: `${pct}%` }} />
                        </div>
                      </td>
                      <td>
                        {inv.revoked ? (
                          <span className="tag danger">已作废</span>
                        ) : expired ? (
                          <span className="tag gold">已过期</span>
                        ) : exhausted ? (
                          <span className="tag">已用完</span>
                        ) : (
                          <span className="tag success">有效</span>
                        )}
                      </td>
                      <td>{inv.note || <span className="muted-sm">-</span>}</td>
                      <td>
                        <div>{formatDateTime(inv.created_at)}</div>
                        {inv.expires_at && inv.expires_at > 0 && (
                          <div className="muted-sm">过期：{formatDateTime(inv.expires_at)}</div>
                        )}
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        {!inv.revoked && (
                          <button
                            type="button"
                            className="btn btn-danger btn-sm"
                            onClick={() =>
                              void api
                                .revokeInvite(inv.code)
                                .then(() => {
                                  toast('邀请码已作废', 'info');
                                  return load();
                                })
                                .catch((e) => toast((e as Error).message, 'error'))
                            }
                          >
                            <Trash2 size={13} /> 作废
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
};
