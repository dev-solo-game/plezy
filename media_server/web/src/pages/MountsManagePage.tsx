import React, { useEffect, useState } from 'react';
import { AlertTriangle, Edit3, HardDrive, Loader2, Plus, Power, RefreshCw, Sparkles, Square, Trash2, X } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { MountEditorModal } from '../components/MountEditorModal';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { MountRecord } from '../types';

export const MountsManagePage: React.FC = () => {
  const { libraryVersion, toast } = useApp();
  const [editingMount, setEditingMount] = useState<MountRecord | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [fullScanMount, setFullScanMount] = useState<MountRecord | null>(null);
  const [submittingFullScan, setSubmittingFullScan] = useState(false);
  const [quarkInfoMap, setQuarkInfoMap] = useState<
    Record<string, { member_type: string; used_bytes: number; total_bytes: number }>
  >({});

  const {
    data: mounts = [],
    showSkeleton,
    reload,
  } = useSWRQuery<MountRecord[]>('mounts', () => api.listMounts().then((r) => r.mounts || []), {
    deps: [libraryVersion],
    onError: (err) => toast(err.message, 'error'),
  });

  useEffect(() => {
    for (const m of mounts) {
      if (m.kind === 'quark' && m.enabled && !quarkInfoMap[m.id]) {
        api
          .quarkAccount(m.id)
          .then((qRes) => {
            setQuarkInfoMap((prev) => ({ ...prev, [m.id]: qRes.account }));
          })
          .catch(() => {});
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mounts]);

  const handleDelete = async (m: MountRecord) => {
    if (!window.confirm(`确认删除挂载源「${m.name}」？关联索引记录也将一并移除，不会删除物理磁盘文件。`)) return;
    try {
      await api.deleteMount(m.id);
      toast(`已删除「${m.name}」`, 'success');
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const toggleEnabled = async (m: MountRecord) => {
    try {
      await api.updateMount(m.id, { enabled: !m.enabled });
      toast(m.enabled ? '已停用挂载源' : '已启用挂载源', 'success');
      await reload();
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

      {showSkeleton ? (
        <CardListSkeleton />
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

                <div className="muted-sm" style={{ fontFamily: 'var(--font-mono)', wordBreak: 'break-all' }}>
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
                        onClick={() => setFullScanMount(m)}
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
          onSaved={() => void reload()}
        />
      )}

      {fullScanMount && (
        <ModalBackdrop onClose={() => !submittingFullScan && setFullScanMount(null)}>
          <div className="modal-panel" style={{ maxWidth: 480 }}>
            <div className="modal-header">
              <div className="flex-row" style={{ gap: 10 }}>
                <AlertTriangle size={18} style={{ color: 'var(--warning)' }} />
                <h3>确认全量重扫？</h3>
              </div>
              <button
                type="button"
                className="btn btn-icon btn-sm"
                disabled={submittingFullScan}
                onClick={() => setFullScanMount(null)}
              >
                <X size={16} />
              </button>
            </div>

            <div className="modal-body" style={{ gap: 12 }}>
              <div className="flex-row" style={{ gap: 8 }}>
                <span className="tag accent">{mountKindLabel(fullScanMount.kind)}</span>
                <strong style={{ fontSize: 15 }}>{fullScanMount.name}</strong>
                <span className="tag">当前已索引 {fullScanMount.video_count} 个视频</span>
              </div>

              <div
                className="card-box"
                style={{
                  padding: '12px 14px',
                  background: 'rgba(245, 185, 66, 0.08)',
                  borderColor: 'rgba(245, 185, 66, 0.32)',
                  fontSize: 13,
                  lineHeight: 1.65,
                }}
              >
                <div>
                  <strong>全量重扫耗时较长：</strong>
                  将忽略已有增量扫描水位线与目录缓存，从根目录开始逐层递归重新遍历全部文件夹并核对文件变化。
                </div>
                <div className="muted-sm" style={{ marginTop: 6 }}>
                  对于大体积片库或限流网盘（如夸克网盘 / WebDAV / SMB），全量重扫可能需要数分钟至数十分钟。日常新增文件建议直接使用{' '}
                  <strong style={{ color: 'var(--text-primary)' }}>「增量扫描」</strong>。
                </div>
              </div>
            </div>

            <div className="modal-footer">
              <button
                type="button"
                className="btn"
                disabled={submittingFullScan}
                onClick={() => setFullScanMount(null)}
              >
                取消
              </button>
              <div style={{ flex: 1 }} />
              <button
                type="button"
                className="btn"
                disabled={submittingFullScan}
                onClick={() => {
                  const target = fullScanMount;
                  setSubmittingFullScan(true);
                  api
                    .scanMount(target.id, false)
                    .then(() => {
                      toast('已开始增量扫描', 'success');
                      setFullScanMount(null);
                    })
                    .catch((err) => toast((err as Error).message, 'error'))
                    .finally(() => setSubmittingFullScan(false));
                }}
              >
                <RefreshCw size={14} />
                改用增量扫描
              </button>
              <button
                type="button"
                className="btn btn-danger"
                disabled={submittingFullScan}
                onClick={() => {
                  const target = fullScanMount;
                  setSubmittingFullScan(true);
                  api
                    .scanMount(target.id, true)
                    .then(() => {
                      toast('已启动全量重扫', 'success');
                      setFullScanMount(null);
                    })
                    .catch((err) => toast((err as Error).message, 'error'))
                    .finally(() => setSubmittingFullScan(false));
                }}
              >
                {submittingFullScan && <Loader2 size={14} className="spin" />}
                确认全量重扫
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
