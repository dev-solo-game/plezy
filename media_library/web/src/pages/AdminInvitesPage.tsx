import React, { useCallback, useEffect, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { api, formatDateTime } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { InviteCode } from '../types';

export const AdminInvitesPage: React.FC = () => {
  const { toast } = useApp();
  const [regMode, setRegMode] = useState('open');
  const [invites, setInvites] = useState<InviteCode[]>([]);
  const [maxUses, setMaxUses] = useState(1);
  const [note, setNote] = useState('');

  const load = useCallback(async () => {
    try {
      const [sRes, iRes] = await Promise.all([api.getSettings(), api.listInvites()]);
      setRegMode(sRes.settings.registration_mode || 'open');
      setInvites(iRes.invites || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const updateMode = async (mode: string) => {
    try {
      await api.updateSettings({ registration_mode: mode });
      setRegMode(mode);
      toast('注册策略已保存', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const createInvite = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.createInvite({ max_uses: maxUses, note: note.trim() || undefined });
      setNote('');
      toast('邀请码已生成', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 960 }}>
      <h1 style={{ margin: 0, fontSize: 22 }}>注册策略与邀请码</h1>

      <div className="panel" style={{ padding: 18, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <span style={{ fontWeight: 600 }}>注册模式：</span>
        {[
          { id: 'open', label: '开放注册' },
          { id: 'invite', label: '仅邀请码注册' },
          { id: 'closed', label: '关闭注册' },
        ].map((opt) => (
          <button
            key={opt.id}
            type="button"
            className={`btn ${regMode === opt.id ? 'btn-primary' : ''}`}
            onClick={() => void updateMode(opt.id)}
          >
            {opt.label}
          </button>
        ))}
      </div>

      <form onSubmit={createInvite} className="panel" style={{ padding: 16, display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        <label style={{ fontSize: 13 }}>
          可用次数：
          <input
            className="input"
            type="number"
            min={1}
            max={1000}
            value={maxUses}
            onChange={(e) => setMaxUses(Number(e.target.value) || 1)}
            style={{ width: 90, marginLeft: 6 }}
          />
        </label>
        <input className="input" placeholder="备注（可选）" value={note} onChange={(e) => setNote(e.target.value)} style={{ width: 240 }} />
        <button type="submit" className="btn btn-primary">
          <Plus size={14} /> 生成邀请码
        </button>
      </form>

      <div className="panel" style={{ padding: 16 }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1px solid var(--border-subtle)', color: 'var(--text-muted)' }}>
              <th style={{ padding: '8px 6px' }}>邀请码</th>
              <th style={{ padding: '8px 6px' }}>使用情况</th>
              <th style={{ padding: '8px 6px' }}>备注</th>
              <th style={{ padding: '8px 6px' }}>创建时间</th>
              <th style={{ padding: '8px 6px' }}>操作</th>
            </tr>
          </thead>
          <tbody>
            {invites.map((inv) => (
              <tr key={inv.code} style={{ borderBottom: '1px solid var(--border-subtle)' }}>
                <td style={{ padding: '10px 6px', fontFamily: 'var(--font-mono)', fontWeight: 600 }}>{inv.code}</td>
                <td style={{ padding: '10px 6px' }}>
                  {inv.used_count} / {inv.max_uses} {inv.revoked ? '（已作废）' : ''}
                </td>
                <td style={{ padding: '10px 6px' }}>{inv.note || '-'}</td>
                <td style={{ padding: '10px 6px' }}>{formatDateTime(inv.created_at)}</td>
                <td style={{ padding: '10px 6px' }}>
                  {!inv.revoked && (
                    <button
                      type="button"
                      className="btn"
                      onClick={() => void api.revokeInvite(inv.code).then(() => { toast('已作废', 'info'); return load(); }).catch((e) => toast((e as Error).message, 'error'))}
                    >
                      <Trash2 size={14} /> 作废
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {invites.length === 0 && (
              <tr>
                <td colSpan={5} style={{ padding: 18, textAlign: 'center' }} className="muted">
                  暂无邀请码
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};
