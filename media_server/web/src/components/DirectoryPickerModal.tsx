import React, { useCallback, useEffect, useState } from 'react';
import { ArrowLeft, Check, ChevronRight, Folder, Loader2, Plus, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MountKind } from '../types';
import { ModalBackdrop } from './ModalBackdrop';

interface RemotePreviewSpec {
  id?: string;
  kind: MountKind;
  config: Record<string, unknown>;
  secrets?: Record<string, string>;
}

interface DirectoryPickerModalProps {
  title?: string;
  sourceType: 'host' | 'remote';
  selectMode: 'single' | 'multi';
  mountPreview?: RemotePreviewSpec;
  initialPath?: string;
  initialSelected?: string[];
  onClose: () => void;
  onConfirm: (paths: string[]) => void;
}

interface DirItem {
  name: string;
  path: string;
  id?: string;
}

export const DirectoryPickerModal: React.FC<DirectoryPickerModalProps> = ({
  title,
  sourceType,
  selectMode,
  mountPreview,
  initialPath,
  initialSelected = [],
  onClose,
  onConfirm,
}) => {
  const { toast } = useApp();
  const [loading, setLoading] = useState(true);
  const [currentPath, setCurrentPath] = useState(initialPath || (sourceType === 'remote' ? '/' : ''));
  const [parentPath, setParentPath] = useState('');
  const [pathInput, setPathInput] = useState(initialPath || '');
  const [dirs, setDirs] = useState<DirItem[]>([]);
  const [fileCount, setFileCount] = useState(0);
  const [remoteIdCache, setRemoteIdCache] = useState<Record<string, string>>({});
  const [selectedSet, setSelectedSet] = useState<string[]>(initialSelected);
  const [errorMsg, setErrorMsg] = useState('');

  const loadDir = useCallback(
    async (targetPath: string, folderIdHint?: string) => {
      setLoading(true);
      setErrorMsg('');
      try {
        if (sourceType === 'host') {
          const res = await api.browseHostFS(targetPath || undefined);
          setCurrentPath(res.current || '');
          setParentPath(res.parent || '');
          setPathInput(res.current || '');
          setDirs((res.dirs || []).map((d) => ({ name: d.name, path: d.path })));
          setFileCount(0);
        } else if (mountPreview) {
          const norm = targetPath || '/';
          const pid = folderIdHint ?? remoteIdCache[norm];
          const res = await api.browseMountPreview({
            id: mountPreview.id,
            kind: mountPreview.kind,
            config: mountPreview.config,
            secrets: mountPreview.secrets,
            path: norm,
            parent_id: pid,
          });
          setCurrentPath(res.path || '/');
          setParentPath(res.parent || '/');
          setPathInput(res.path || '/');
          setFileCount(res.file_count || 0);
          const nextDirs = (res.dirs || []).map((d) => ({ name: d.name, path: d.path, id: d.id }));
          setDirs(nextDirs);
          setRemoteIdCache((prev) => {
            const copy = { ...prev };
            for (const d of nextDirs) {
              if (d.id) copy[d.path] = d.id;
            }
            return copy;
          });
        }
      } catch (err) {
        const msg = (err as Error).message || '读取目录失败';
        setErrorMsg(msg);
        toast(msg, 'error');
      } finally {
        setLoading(false);
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [sourceType, mountPreview]
  );

  useEffect(() => {
    void loadDir(sourceType === 'remote' ? initialPath || '/' : initialPath || '');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const toggleSelect = (p: string) => {
    setSelectedSet((prev) => (prev.includes(p) ? prev.filter((x) => x !== p) : [...prev, p]));
  };

  const canGoUp = sourceType === 'host' ? parentPath !== currentPath : currentPath !== '/' && currentPath !== '';

  const headerTitle =
    title || (selectMode === 'multi' ? '浏览并勾选需要添加的目录' : '选择目标目录');

  return (
    <ModalBackdrop subModal onClose={onClose}>
      <div className="modal-panel" style={{ maxWidth: 660 }}>
        <div className="modal-header">
          <h3>{headerTitle}</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body" style={{ gap: 12 }}>
          <form
            className="flex-row"
            onSubmit={(e) => {
              e.preventDefault();
              void loadDir(pathInput.trim());
            }}
          >
            {canGoUp && (
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => void loadDir(parentPath)}
                disabled={loading}
              >
                <ArrowLeft size={14} />
                上一级
              </button>
            )}
            <input
              className="input"
              style={{ flex: 1, fontFamily: 'var(--font-mono)', fontSize: 13 }}
              placeholder={sourceType === 'host' ? '输入服务器路径，留空显示盘符列表' : '/'}
              value={pathInput}
              onChange={(e) => setPathInput(e.target.value)}
            />
            <button type="submit" className="btn btn-sm" disabled={loading}>
              前往
            </button>
          </form>

          <div className="flex-row" style={{ justifyContent: 'space-between' }}>
            <span className="muted-sm">
              当前位置：<strong style={{ color: 'var(--text-primary)' }}>{currentPath || '此电脑 / 盘符'}</strong>
              {sourceType === 'remote' && fileCount > 0 ? ` · 当前目录含 ${fileCount} 个文件` : ''}
            </span>
            {selectMode === 'multi' && currentPath && currentPath !== '/' && (
              <button
                type="button"
                className={`btn btn-sm ${selectedSet.includes(currentPath) ? 'btn-primary' : ''}`}
                onClick={() => toggleSelect(currentPath)}
              >
                {selectedSet.includes(currentPath) ? <Check size={13} /> : <Plus size={13} />}
                {selectedSet.includes(currentPath) ? '已选当前目录' : '选中当前所在目录'}
              </button>
            )}
          </div>

          <div
            style={{
              border: '1px solid var(--border-subtle)',
              borderRadius: 12,
              background: 'rgba(6, 8, 12, 0.55)',
              minHeight: 240,
              maxHeight: 330,
              overflowY: 'auto',
              padding: 8,
              display: 'flex',
              flexDirection: 'column',
              gap: 4,
            }}
          >
            {loading ? (
              <div className="flex-row" style={{ justifyContent: 'center', padding: 48 }}>
                <Loader2 size={18} className="spin" />
                <span className="muted">正在读取目录列表...</span>
              </div>
            ) : errorMsg ? (
              <div style={{ padding: 24, textAlign: 'center', color: 'var(--danger)', fontSize: 13 }}>
                {errorMsg}
              </div>
            ) : dirs.length === 0 ? (
              <div className="muted-sm" style={{ padding: 36, textAlign: 'center' }}>
                此目录下没有子文件夹
              </div>
            ) : (
              dirs.map((d) => {
                const checked = selectedSet.includes(d.path);
                return (
                  <div key={d.path} className="dir-browser-row">
                    <div className="flex-row" style={{ flex: 1, minWidth: 0, gap: 10 }}>
                      {selectMode === 'multi' && (
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleSelect(d.path)}
                          style={{ width: 16, height: 16, cursor: 'pointer', flexShrink: 0 }}
                        />
                      )}
                      <button
                        type="button"
                        style={{
                          flex: 1,
                          minWidth: 0,
                          display: 'flex',
                          alignItems: 'center',
                          gap: 8,
                          background: 'transparent',
                          border: 'none',
                          textAlign: 'left',
                          cursor: 'pointer',
                          padding: '2px 0',
                        }}
                        onClick={() => void loadDir(d.path, d.id)}
                      >
                        <Folder size={16} style={{ color: 'var(--accent)', flexShrink: 0 }} />
                        <span
                          style={{
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            whiteSpace: 'nowrap',
                            fontSize: 13,
                          }}
                        >
                          {d.name}
                        </span>
                      </button>
                    </div>

                    <button
                      type="button"
                      className="btn btn-sm"
                      style={{ padding: '4px 8px', fontSize: 12 }}
                      onClick={() => void loadDir(d.path, d.id)}
                      title="打开子目录"
                    >
                      打开 <ChevronRight size={13} />
                    </button>
                  </div>
                );
              })
            )}
          </div>

          {selectMode === 'multi' && (
            <div>
              <div className="muted-sm" style={{ marginBottom: 6 }}>
                已选择目录 ({selectedSet.length})：
              </div>
              {selectedSet.length === 0 ? (
                <div className="muted-sm">尚未勾选目录（若不添加则默认扫描全部根目录）</div>
              ) : (
                <div className="flex-row" style={{ maxHeight: 74, overflowY: 'auto' }}>
                  {selectedSet.map((p) => (
                    <button key={p} type="button" className="chip active" onClick={() => toggleSelect(p)}>
                      <span>{p}</span>
                      <X size={12} />
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>
            取消
          </button>
          {selectMode === 'single' ? (
            <button
              type="button"
              className="btn btn-primary"
              disabled={loading || !currentPath}
              onClick={() => {
                onConfirm([currentPath]);
                onClose();
              }}
            >
              <Check size={14} />
              选择此目录 ({currentPath || '-'})
            </button>
          ) : (
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => {
                onConfirm(selectedSet);
                onClose();
              }}
            >
              <Check size={14} />
              确认选择 ({selectedSet.length})
            </button>
          )}
        </div>
      </div>
    </ModalBackdrop>
  );
};
