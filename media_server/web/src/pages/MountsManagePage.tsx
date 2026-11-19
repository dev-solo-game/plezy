import React, { useCallback, useEffect, useState } from 'react';
import { Edit3, HardDrive, Plus, Power, RefreshCw, Sparkles, Square, Trash2 } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { MountEditorModal } from '../components/MountEditorModal';
import { useApp } from '../contexts/AppContext';
import type { MountRecord } from '../types';

export const MountsManagePage: React.FC = () => {
  const { libraryVersion, toast } = useApp();
  const [mounts, setMounts] = useState<MountRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [editingMount, setEditingMount] = useState<MountRecord | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [quarkInfoMap, setQuarkInfoMap] = useState<
    Record<string, { member_type: string; used_bytes: number; total_bytes: number }>
  >({});

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listMounts();
      const list = res.mounts || [];
      setMounts(list);
      for (const m of list) {
        if (m.kind === 'quark' && m.enabled) {
          api
            .quarkAccount(m.id)
            .then((qRes) => {
              setQuarkInfoMap((prev) => ({ ...prev, [m.id]: qRes.account }));
            })
            .catch(() => {});
        }
      }
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load, libraryVersion]);

  const handleDelete = async (m: MountRecord) => {
    if (!window.confirm(`确认删除挂载源「${m.name}」？关联索引记录也将一并移除，不会删除物理磁盘文件。`)) return;
    try {
      await api.deleteMount(m.id);
      toast(`已删除「${m.name}」`, 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const toggleEnabled = async (m: MountRecord) => {
    try {
      await api.updateMount(m.id, { enabled: !m.enabled });
      toast(m.enabled ? '已停用挂载源' : '已启用挂载源', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">存储挂载管理</h2>
        <div className="flex-row">
          <button
            type="button"
            className="btn btn-sm"
            onClick={() => api.scanAll(false).then(() => toast('已启动全库增量扫描', 'success'))}
          >
            <RefreshCw size={14} />
            扫描全部
          </button>
          <button
            type="button"
            className="btn btn-sm"
            onClick={() => api.scrapeAll(false, false).then(() => toast('已启动待匹配自动刮削', 'success'))}
          >
            <Sparkles size={14} />
            刮削待处理
          </button>
          <button type="button" className="btn btn-primary btn-sm" onClick={() => setShowCreate(true)}>
            <Plus size={15} />
            添加挂载源
          </button>
        </div>
      </div>

      {loading ? (
        <div className="muted">加载中...</div>
      ) : mounts.length === 0 ? (
        <div className="card-box" style={{ textAlign: 'center', padding: 48 }}>
          <HardDrive size={36} className="muted" style={{ marginBottom: 12 }} />
          <p className="muted">暂无存储挂载源。支持本地目录、SMB/NAS、WebDAV 和夸克网盘。</p>
          <button type="button" className="btn btn-primary" onClick={() => setShowCreate(true)}>
            <Plus size={16} />
            添加挂载源
          </button>
        </div>
      ) : (
        <div className="grid-2">
          {mounts.map((m) => {
            const isRunning = m.scan_state?.status === 'running';
            const qAcc = quarkInfoMap[m.id];
            return (
              <div key={m.id} className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                  <div className="flex-row">
                    <span className="tag accent">{mountKindLabel(m.kind)}</span>
                    <strong style={{ fontSize: 16 }}>{m.name}</strong>
                    {!m.enabled && <span className="tag danger">已停用</span>}
                    {isRunning && <span className="tag gold">扫描中</span>}
                  </div>
                  <button
                    type="button"
                    className="btn btn-icon btn-sm"
                    onClick={() => void toggleEnabled(m)}
                    title={m.enabled ? '停用' : '启用'}
                  >
                    <Power size={14} />
                  </button>
                </div>

                <div className="muted-sm" style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                  {m.kind === 'local' && String(m.config?.rootPath || '')}
                  {m.kind === 'smb' && `smb://${m.config?.host}/${m.config?.share}${m.config?.rootPath || '/'}`}
                  {m.kind === 'webdav' && String(m.config?.baseUrl || '')}
                  {m.kind === 'quark' &&
                    `Quark (${m.config?.quarkMode || 'pc'}) · FID=${m.config?.rootFolderId || '0'}`}
                </div>

                <div className="flex-row">
                  <span className="tag">视频文件：{m.video_count}</span>
                  <span className="tag">已匹配作品：{m.matched_item_count}</span>
                  <span className="tag">占用：{formatBytes(m.total_file_bytes)}</span>
                </div>

                {qAcc && (
                  <div className="muted-sm">
                    夸克会员：{qAcc.member_type || '普通用户'} · 网盘空间{' '}
                    {formatBytes(qAcc.used_bytes)} / {formatBytes(qAcc.total_bytes)}
                  </div>
                )}

                {m.scan_state?.last_error && (
                  <div className="muted-sm" style={{ color: 'var(--danger)' }}>
                    上次扫描错误：{m.scan_state.last_error}
                  </div>
                )}

                <div className="divider" />

                <div className="flex-row">
                  {isRunning ? (
                    <button
                      type="button"
                      className="btn btn-danger btn-sm"
                      onClick={() => api.cancelScan(m.id).then(() => toast('已请求取消扫描'))}
                    >
                      <Square size={13} />
                      取消扫描
                    </button>
                  ) : (
                    <>
                      <button
                        type="button"
                        className="btn btn-sm"
                        onClick={() => api.scanMount(m.id, false).then(() => toast('开始增量扫描', 'success'))}
                      >
                        <RefreshCw size={13} />
                        增量扫描
                      </button>
                      <button
                        type="button"
                        className="btn btn-sm"
                        onClick={() => api.scanMount(m.id, true).then(() => toast('开始全量扫描', 'success'))}
                      >
                        全量重扫
                      </button>
                    </>
                  )}
                  <div style={{ flex: 1 }} />
                  <button type="button" className="btn btn-sm" onClick={() => setEditingMount(m)}>
                    <Edit3 size={13} />
                    编辑
                  </button>
                  <button type="button" className="btn btn-danger btn-sm" onClick={() => void handleDelete(m)}>
                    <Trash2 size={13} />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {(showCreate || editingMount) && (
        <MountEditorModal
          mount={editingMount}
          onClose={() => {
            setShowCreate(false);
            setEditingMount(null);
          }}
          onSaved={() => void load()}
        />
      )}
    </div>
  );
};
