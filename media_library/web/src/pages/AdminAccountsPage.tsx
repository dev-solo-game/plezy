import React, { useCallback, useEffect, useState } from 'react';
import {
  KeyRound,
  Loader2,
  LogOut,
  Plus,
  RefreshCw,
  RotateCcw,
  Search,
  SlidersHorizontal,
  Trash2,
  UserCheck,
  UserMinus,
  Users,
  X,
} from 'lucide-react';
import { api, formatBytes, formatDateTime } from '../api/client';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { AccountSummary } from '../types';

function accountStatusBadge(status: string) {
  switch (status) {
    case 'active':
      return <span className="tag success">正常</span>;
    case 'disabled':
      return <span className="tag danger">已禁用</span>;
    case 'pending_delete':
      return <span className="tag gold">待删除</span>;
    default:
      return <span className="tag">{status}</span>;
  }
}

export const AdminAccountsPage: React.FC = () => {
  const { toast } = useApp();
  const [accounts, setAccounts] = useState<AccountSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [q, setQ] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [loading, setLoading] = useState(true);

  // Create modal
  const [createOpen, setCreateOpen] = useState(false);
  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [creating, setCreating] = useState(false);

  // Reset password modal
  const [resetTarget, setResetTarget] = useState<AccountSummary | null>(null);
  const [resetPw, setResetPw] = useState('');
  const [resetBusy, setResetBusy] = useState(false);

  // Quota modal
  const [quotaTarget, setQuotaTarget] = useState<AccountSummary | null>(null);
  const [maxSources, setMaxSources] = useState(20);
  const [maxFiles, setMaxFiles] = useState(200000);
  const [maxSidecarMb, setMaxSidecarMb] = useState(512);
  const [quotaBusy, setQuotaBusy] = useState(false);

  // Delete confirm modal
  const [deleteTarget, setDeleteTarget] = useState<AccountSummary | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listAccounts({
        q: q.trim() || undefined,
        status: statusFilter || undefined,
        limit: 100,
      });
      setAccounts(res.accounts || []);
      setTotal(res.total || 0);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [q, statusFilter, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (creating) return;
    setCreating(true);
    try {
      await api.createAccount({
        username: newUsername.trim(),
        password: newPassword,
        email: newEmail.trim() || undefined,
      });
      setNewUsername('');
      setNewPassword('');
      setNewEmail('');
      setCreateOpen(false);
      toast('用户账号已创建', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const handleResetPassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!resetTarget || resetBusy) return;
    setResetBusy(true);
    try {
      await api.resetAccountPassword(resetTarget.account_id, resetPw);
      toast(`已重置 ${resetTarget.username} 的登录密码`, 'success');
      setResetTarget(null);
      setResetPw('');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setResetBusy(false);
    }
  };

  const openQuotaModal = (acc: AccountSummary) => {
    setQuotaTarget(acc);
    setMaxSources(acc.quota_max_sources || 20);
    setMaxFiles(acc.quota_max_files || 200000);
    setMaxSidecarMb(Math.max(1, Math.round((acc.quota_max_sidecar_bytes || 536870912) / (1024 * 1024))));
  };

  const handleSaveQuotas = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!quotaTarget || quotaBusy) return;
    setQuotaBusy(true);
    try {
      await api.updateQuotas(quotaTarget.account_id, {
        max_sources: maxSources,
        max_files: maxFiles,
        max_sidecar_bytes: maxSidecarMb * 1024 * 1024,
      });
      toast(`已更新 ${quotaTarget.username} 的资源配额`, 'success');
      setQuotaTarget(null);
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setQuotaBusy(false);
    }
  };

  const handleScheduleDelete = async () => {
    if (!deleteTarget || deleteBusy) return;
    setDeleteBusy(true);
    try {
      await api.scheduleDeleteAccount(deleteTarget.account_id);
      toast(`账号 ${deleteTarget.username} 已标记为待删除`, 'info');
      setDeleteTarget(null);
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setDeleteBusy(false);
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">
            用户账号管理
            <span className="tag accent" style={{ fontSize: 12 }}>
              共 {total} 个
            </span>
          </h1>
          <p className="page-subtitle">
            管理注册用户状态、资源配额与会话安全；所有统计均为匿名计数，不包含用户媒体文件名或凭据明文。
          </p>
        </div>

        <div className="flex-row" style={{ gap: 8 }}>
          <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={15} className={loading ? 'spin' : ''} />
            刷新
          </button>
          <button type="button" className="btn btn-primary" onClick={() => setCreateOpen(true)}>
            <Plus size={16} />
            创建用户
          </button>
        </div>
      </div>

      {/* Filter Toolbar */}
      <div className="card-box" style={{ padding: 14 }}>
        <div className="flex-row" style={{ justifyContent: 'space-between', gap: 12 }}>
          <form
            className="search-pill"
            style={{ maxWidth: 360 }}
            onSubmit={(e) => {
              e.preventDefault();
              void load();
            }}
          >
            <Search size={15} className="muted" />
            <input
              type="search"
              placeholder="搜索用户名或邮箱..."
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
          </form>

          <div className="flex-row" style={{ gap: 6 }}>
            {[
              { id: '', label: '全部' },
              { id: 'active', label: '正常' },
              { id: 'disabled', label: '已禁用' },
              { id: 'pending_delete', label: '待删除' },
            ].map((st) => (
              <button
                key={st.id || 'all'}
                type="button"
                className={`chip ${statusFilter === st.id ? 'active' : ''}`}
                onClick={() => setStatusFilter(st.id)}
              >
                {st.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Accounts Table */}
      <div className="card-box" style={{ padding: 16 }}>
        {loading && accounts.length === 0 ? (
          <TableSkeleton rows={6} />
        ) : accounts.length === 0 ? (
          <div className="empty-state">
            <Users size={28} />
            <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>暂无匹配的用户账号</div>
            <div className="muted-sm">可点击右上角「创建用户」手动开户，或开放客户端自助注册</div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>用户</th>
                  <th>状态</th>
                  <th>聚合用量（设备 / 源 / 作品 / 文件 / 旁路）</th>
                  <th>注册时间 / IP</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {accounts.map((acc) => {
                  const totalSources = Object.values(acc.source_counts || {}).reduce((sum, n) => sum + (n || 0), 0);
                  return (
                  <tr key={acc.account_id}>
                    <td>
                      <div className="flex-row" style={{ gap: 10, flexWrap: 'nowrap' }}>
                        <span className="avatar-circle">{(acc.username || '?').slice(0, 1)}</span>
                        <div style={{ minWidth: 0 }}>
                          <div style={{ fontWeight: 600 }}>{acc.username}</div>
                          <div className="muted-sm">{acc.email || '未绑定邮箱'}</div>
                        </div>
                      </div>
                    </td>
                    <td>{accountStatusBadge(acc.status)}</td>
                    <td>
                      <div className="flex-row" style={{ gap: 6 }}>
                        <span className="tag">{acc.device_count ?? 0} 设备</span>
                        <span className="tag">{totalSources}/{acc.quota_max_sources || '∞'} 源</span>
                        <span className="tag">{acc.item_count ?? 0} 作品</span>
                        <span className="tag">{acc.file_count ?? 0} 文件</span>
                        <span className="tag">{formatBytes(acc.sidecar_bytes ?? 0)}</span>
                      </div>
                    </td>
                    <td>
                      <div>{formatDateTime(acc.created_at)}</div>
                      <div className="muted-sm">{acc.registered_ip || '-'}</div>
                    </td>
                    <td>
                      <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                        {acc.status === 'active' ? (
                          <button
                            type="button"
                            className="btn btn-sm"
                            title="禁用该账号"
                            onClick={() =>
                              void api
                                .setAccountStatus(acc.account_id, 'disabled')
                                .then(() => {
                                  toast(`已禁用 ${acc.username}`, 'info');
                                  return load();
                                })
                                .catch((e) => toast((e as Error).message, 'error'))
                            }
                          >
                            <UserMinus size={13} /> 禁用
                          </button>
                        ) : acc.status === 'disabled' ? (
                          <button
                            type="button"
                            className="btn btn-sm"
                            title="重新启用账号"
                            onClick={() =>
                              void api
                                .setAccountStatus(acc.account_id, 'active')
                                .then(() => {
                                  toast(`已启用 ${acc.username}`, 'success');
                                  return load();
                                })
                                .catch((e) => toast((e as Error).message, 'error'))
                            }
                          >
                            <UserCheck size={13} /> 启用
                          </button>
                        ) : (
                          <button
                            type="button"
                            className="btn btn-sm"
                            title="取消删除并恢复账号"
                            onClick={() =>
                              void api
                                .restoreAccount(acc.account_id)
                                .then(() => {
                                  toast(`已恢复 ${acc.username}`, 'success');
                                  return load();
                                })
                                .catch((e) => toast((e as Error).message, 'error'))
                            }
                          >
                            <RotateCcw size={13} /> 恢复
                          </button>
                        )}

                        <button
                          type="button"
                          className="btn btn-sm"
                          title="调整配额上限"
                          onClick={() => openQuotaModal(acc)}
                        >
                          <SlidersHorizontal size={13} /> 配额
                        </button>

                        <button
                          type="button"
                          className="btn btn-sm"
                          title="重置登录密码"
                          onClick={() => {
                            setResetTarget(acc);
                            setResetPw('');
                          }}
                        >
                          <KeyRound size={13} /> 改密
                        </button>

                        <button
                          type="button"
                          className="btn btn-sm"
                          title="踢出该账号所有在线设备"
                          onClick={() =>
                            void api
                              .forceLogoutAccount(acc.account_id)
                              .then(() => toast(`已强制下线 ${acc.username} 的全部设备`, 'info'))
                              .catch((e) => toast((e as Error).message, 'error'))
                          }
                        >
                          <LogOut size={13} /> 下线
                        </button>

                        {acc.status !== 'pending_delete' && (
                          <button
                            type="button"
                            className="btn btn-danger btn-sm"
                            title="标记待删除"
                            onClick={() => setDeleteTarget(acc)}
                          >
                            <Trash2 size={13} />
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Create User Modal */}
      {createOpen && (
        <ModalBackdrop onClose={() => !creating && setCreateOpen(false)}>
          <form className="modal-panel" style={{ maxWidth: 460 }} onSubmit={handleCreate}>
            <div className="modal-header">
              <h3>创建新用户账号</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setCreateOpen(false)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>用户名</label>
                <input
                  className="input"
                  required
                  autoFocus
                  placeholder="例如：alice"
                  value={newUsername}
                  onChange={(e) => setNewUsername(e.target.value)}
                />
              </div>
              <div className="field">
                <label>初始密码（至少 8 位）</label>
                <input
                  className="input"
                  type="password"
                  required
                  minLength={8}
                  placeholder="请设置登录密码"
                  value={newPassword}
                  onChange={(e) => setNewPassword(e.target.value)}
                />
              </div>
              <div className="field">
                <label>邮箱（可选）</label>
                <input
                  className="input"
                  type="email"
                  placeholder="alice@example.com"
                  value={newEmail}
                  onChange={(e) => setNewEmail(e.target.value)}
                />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setCreateOpen(false)} disabled={creating}>
                取消
              </button>
              <button type="submit" className="btn btn-primary" disabled={creating}>
                {creating ? <Loader2 size={15} className="spin" /> : <Plus size={15} />}
                确认创建
              </button>
            </div>
          </form>
        </ModalBackdrop>
      )}

      {/* Reset Password Modal */}
      {resetTarget && (
        <ModalBackdrop onClose={() => !resetBusy && setResetTarget(null)}>
          <form className="modal-panel" style={{ maxWidth: 460 }} onSubmit={handleResetPassword}>
            <div className="modal-header">
              <h3>重置密码 · {resetTarget.username}</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setResetTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <div className="setting-row" style={{ borderColor: 'rgba(245, 185, 66, 0.35)' }}>
                <div className="setting-row-text">
                  <span className="setting-row-title" style={{ color: 'var(--warning)' }}>
                    端到端加密提示
                  </span>
                  <span className="setting-row-desc">
                    重置登录密码后，该用户已加密的网盘 / WebDAV 凭据需要用户在客户端使用恢复密钥或重新授权验证。
                  </span>
                </div>
              </div>
              <div className="field">
                <label>新密码（至少 8 位）</label>
                <input
                  className="input"
                  type="password"
                  required
                  autoFocus
                  minLength={8}
                  placeholder="输入新的登录密码"
                  value={resetPw}
                  onChange={(e) => setResetPw(e.target.value)}
                />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setResetTarget(null)} disabled={resetBusy}>
                取消
              </button>
              <button type="submit" className="btn btn-primary" disabled={resetBusy}>
                {resetBusy ? <Loader2 size={15} className="spin" /> : <KeyRound size={15} />}
                确认重置
              </button>
            </div>
          </form>
        </ModalBackdrop>
      )}

      {/* Quotas Modal */}
      {quotaTarget && (
        <ModalBackdrop onClose={() => !quotaBusy && setQuotaTarget(null)}>
          <form className="modal-panel" style={{ maxWidth: 460 }} onSubmit={handleSaveQuotas}>
            <div className="modal-header">
              <h3>资源配额 · {quotaTarget.username}</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setQuotaTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>最大媒体源数量</label>
                <input
                  className="input"
                  type="number"
                  min={1}
                  max={1000}
                  value={maxSources}
                  onChange={(e) => setMaxSources(Number(e.target.value) || 1)}
                />
              </div>
              <div className="field">
                <label>最大索引文件数</label>
                <input
                  className="input"
                  type="number"
                  min={100}
                  max={10000000}
                  value={maxFiles}
                  onChange={(e) => setMaxFiles(Number(e.target.value) || 100)}
                />
              </div>
              <div className="field">
                <label>旁路文件（字幕 / NFO）最大容量（MB）</label>
                <input
                  className="input"
                  type="number"
                  min={10}
                  max={102400}
                  value={maxSidecarMb}
                  onChange={(e) => setMaxSidecarMb(Number(e.target.value) || 10)}
                />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setQuotaTarget(null)} disabled={quotaBusy}>
                取消
              </button>
              <button type="submit" className="btn btn-primary" disabled={quotaBusy}>
                {quotaBusy && <Loader2 size={15} className="spin" />}
                保存配额
              </button>
            </div>
          </form>
        </ModalBackdrop>
      )}

      {/* Delete Confirm Modal */}
      {deleteTarget && (
        <ModalBackdrop onClose={() => !deleteBusy && setDeleteTarget(null)}>
          <div className="modal-panel" style={{ maxWidth: 440 }}>
            <div className="modal-header">
              <h3>确认标记待删除</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setDeleteTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                确定将账号 <strong>{deleteTarget.username}</strong> 标记为待删除吗？该账号将立即无法登录，保留期内你仍可随时点击「恢复」撤销操作。
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setDeleteTarget(null)} disabled={deleteBusy}>
                取消
              </button>
              <button type="button" className="btn btn-danger" disabled={deleteBusy} onClick={() => void handleScheduleDelete()}>
                {deleteBusy ? <Loader2 size={15} className="spin" /> : <Trash2 size={15} />}
                确认标记删除
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
