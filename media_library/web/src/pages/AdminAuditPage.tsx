import React, { useCallback, useEffect, useState } from 'react';
import { Copy, KeyRound, Loader2, RefreshCw, Shield, X } from 'lucide-react';
import { api, formatDateTime } from '../api/client';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { AuditLogRecord } from '../types';

export const AdminAuditPage: React.FC = () => {
  const { admin, toast, refreshAuth } = useApp();
  const [logs, setLogs] = useState<AuditLogRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [actorFilter, setActorFilter] = useState('');

  const [oldPw, setOldPw] = useState('');
  const [newUser, setNewUser] = useState('');
  const [newPw, setNewPw] = useState('');
  const [saving, setSaving] = useState(false);

  const [detailModal, setDetailModal] = useState<{ title: string; content: string } | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listAuditLogs({
        actor_type: actorFilter || undefined,
        limit: 100,
      });
      setLogs(res.logs || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [actorFilter, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleChangePw = async (e: React.FormEvent) => {
    e.preventDefault();
    if (saving) return;
    setSaving(true);
    try {
      await api.changePassword(oldPw, newPw, newUser.trim() || undefined);
      setOldPw('');
      setNewPw('');
      setNewUser('');
      toast('平台管理员凭据已更新', 'success');
      await refreshAuth();
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  const openDetail = (l: AuditLogRecord) => {
    let formatted = l.detail_json || '{}';
    try {
      formatted = JSON.stringify(JSON.parse(formatted), null, 2);
    } catch {
      // keep raw
    }
    setDetailModal({ title: `审计详情 · ${l.action}`, content: formatted });
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">审计日志与管理员安全</h1>
          <p className="page-subtitle">
            定期轮换平台管理员凭据，审计账号变更、邀请码签发、系统设置修改等关键操作记录。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新日志
        </button>
      </div>

      {/* Admin Credential Card */}
      <form onSubmit={handleChangePw} className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div className="card-title-row" style={{ marginBottom: 0 }}>
          <div>
            <h3 className="card-title">
              <KeyRound size={16} style={{ color: 'var(--accent)' }} />
              修改平台管理员凭据
            </h3>
            <div className="muted-sm" style={{ marginTop: 4 }}>
              当前登录账号：<strong style={{ color: 'var(--text-primary)' }}>{admin?.username || 'admin'}</strong>
              {admin?.last_login_at ? ` · 最近登录 ${formatDateTime(admin.last_login_at)}` : ''}
              {admin?.last_login_ip ? ` (${admin.last_login_ip})` : ''}
            </div>
          </div>
        </div>

        <div className="grid-3">
          <div className="field">
            <label>新用户名（可选）</label>
            <input
              className="input"
              placeholder="留空保持当前用户名"
              value={newUser}
              onChange={(e) => setNewUser(e.target.value)}
            />
          </div>
          <div className="field">
            <label>当前密码</label>
            <input
              className="input"
              type="password"
              required
              placeholder="验证当前管理员密码"
              value={oldPw}
              onChange={(e) => setOldPw(e.target.value)}
            />
          </div>
          <div className="field">
            <label>新密码（至少 8 位）</label>
            <input
              className="input"
              type="password"
              required
              minLength={8}
              placeholder="设置高强度新密码"
              value={newPw}
              onChange={(e) => setNewPw(e.target.value)}
            />
          </div>
        </div>

        <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving ? <Loader2 size={15} className="spin" /> : <KeyRound size={15} />}
            更新管理员凭据
          </button>
        </div>
      </form>

      {/* Audit Logs Card */}
      <div className="card-box" style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div className="card-title-row" style={{ marginBottom: 0, padding: '0 4px' }}>
          <h3 className="card-title">
            <Shield size={16} style={{ color: 'var(--accent)' }} />
            近期操作审计记录
          </h3>
          <div className="flex-row" style={{ gap: 6 }}>
            {[
              { id: '', label: '全部操作者' },
              { id: 'admin', label: '管理员' },
              { id: 'user', label: '用户' },
              { id: 'system', label: '系统' },
            ].map((f) => (
              <button
                key={f.id || 'all'}
                type="button"
                className={`chip ${actorFilter === f.id ? 'active' : ''}`}
                onClick={() => setActorFilter(f.id)}
              >
                {f.label}
              </button>
            ))}
          </div>
        </div>

        {loading && logs.length === 0 ? (
          <TableSkeleton rows={6} />
        ) : logs.length === 0 ? (
          <div className="empty-state">
            <Shield size={28} />
            <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>暂无审计日志记录</div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>时间</th>
                  <th>操作者</th>
                  <th>动作</th>
                  <th>目标对象</th>
                  <th>来源 IP</th>
                  <th style={{ textAlign: 'right' }}>详情</th>
                </tr>
              </thead>
              <tbody>
                {logs.map((l) => (
                  <tr key={l.id}>
                    <td style={{ whiteSpace: 'nowrap' }}>{formatDateTime(l.created_at)}</td>
                    <td>
                      <span className={`tag ${l.actor_type === 'admin' ? 'accent' : ''}`}>
                        {l.actor_type}:{(l.actor_id || '').slice(0, 8)}
                      </span>
                    </td>
                    <td>
                      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 12.5 }}>{l.action}</span>
                    </td>
                    <td>
                      {l.target_type ? (
                        <span>
                          {l.target_type}
                          {l.target_id ? (
                            <span className="muted-sm" style={{ marginLeft: 6, fontFamily: 'var(--font-mono)' }}>
                              {(l.target_id || '').slice(0, 14)}
                            </span>
                          ) : null}
                        </span>
                      ) : (
                        <span className="muted-sm">-</span>
                      )}
                    </td>
                    <td style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}>{l.ip || '-'}</td>
                    <td style={{ textAlign: 'right' }}>
                      {l.detail_json && l.detail_json !== '{}' ? (
                        <button
                          type="button"
                          className="code-pill"
                          style={{ fontSize: 11.5, padding: '2px 8px' }}
                          onClick={() => openDetail(l)}
                        >
                          JSON
                        </button>
                      ) : (
                        <span className="muted-sm">-</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Audit Detail Modal */}
      {detailModal && (
        <ModalBackdrop onClose={() => setDetailModal(null)}>
          <div className="modal-panel" style={{ maxWidth: 620 }}>
            <div className="modal-header">
              <h3>{detailModal.title}</h3>
              <div className="flex-row" style={{ gap: 6 }}>
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() =>
                    void navigator.clipboard
                      .writeText(detailModal.content)
                      .then(() => toast('已复制详情 JSON', 'success'))
                  }
                >
                  <Copy size={13} /> 复制
                </button>
                <button type="button" className="btn btn-icon btn-sm" onClick={() => setDetailModal(null)}>
                  <X size={15} />
                </button>
              </div>
            </div>
            <div className="modal-body">
              <pre className="json-pre">{detailModal.content}</pre>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
