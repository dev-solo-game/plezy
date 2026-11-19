import React, { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, Film, Folder, RefreshCw } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { CardListSkeleton, TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { MountBrowseEntry, MountRecord } from '../types';

interface FolderListing {
  path: string;
  parent: string;
  entries: MountBrowseEntry[];
}

export const FolderBrowserPage: React.FC = () => {
  const navigate = useNavigate();
  const { libraryVersion, toast } = useApp();

  const [selectedMountId, setSelectedMountId] = useState('');
  const [currentPath, setCurrentPath] = useState('/');

  const {
    data: mounts = [],
    showSkeleton: showMountsSkeleton,
  } = useSWRQuery<MountRecord[]>('mounts', () => api.listMounts().then((r) => r.mounts || []), {
    deps: [libraryVersion],
    onError: (err) => toast(err.message, 'error'),
  });

  useEffect(() => {
    if (mounts.length > 0 && (!selectedMountId || !mounts.some((m) => m.id === selectedMountId))) {
      setSelectedMountId(mounts[0].id);
      setCurrentPath('/');
    }
  }, [mounts, selectedMountId]);

  const browseKey = selectedMountId ? `browse:${selectedMountId}:${currentPath}` : null;
  const {
    data: dirData,
    showSkeleton: showDirSkeleton,
    isStaleData,
  } = useSWRQuery<FolderListing>(
    browseKey,
    () =>
      api.browseMount(selectedMountId, currentPath).then((res) => ({
        path: res.path || '/',
        parent: res.parent || '/',
        entries: res.entries || [],
      })),
    {
      enabled: Boolean(selectedMountId),
      keepPreviousData: true,
      onError: (err) => toast(err.message, 'error'),
    }
  );

  if (showMountsSkeleton) {
    return <CardListSkeleton />;
  }

  if (mounts.length === 0) {
    return (
      <div className="card-box" style={{ textAlign: 'center', padding: 48 }}>
        <p className="muted">还没有存储挂载源</p>
        <Link to="/manage/mounts" className="btn btn-primary">
          去添加挂载源
        </Link>
      </div>
    );
  }

  const entries = dirData?.entries || [];
  const activePath = dirData?.path || currentPath;
  const parentPath = dirData?.parent || '/';

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">文件夹浏览</h2>
        {selectedMountId && (
          <button
            type="button"
            className="btn btn-sm"
            onClick={() => api.scanMount(selectedMountId, false).then(() => toast('已开始扫描此挂载源', 'success'))}
          >
            <RefreshCw size={14} />
            扫描此挂载源
          </button>
        )}
      </div>

      <div className="flex-row" style={{ marginBottom: 16 }}>
        {mounts.map((m) => (
          <button
            key={m.id}
            type="button"
            className={`chip ${selectedMountId === m.id ? 'active' : ''}`}
            onClick={() => {
              setSelectedMountId(m.id);
              setCurrentPath('/');
            }}
          >
            <span>{m.name}</span>
            <span className="muted-sm">({mountKindLabel(m.kind)})</span>
          </button>
        ))}
      </div>

      <div className="card-box" style={{ padding: 0, overflow: 'hidden' }}>
        <div
          className="flex-row"
          style={{
            padding: '12px 16px',
            borderBottom: '1px solid var(--border-subtle)',
            justifyContent: 'space-between',
          }}
        >
          <div className="flex-row">
            {activePath !== '/' && (
              <button type="button" className="btn btn-sm" onClick={() => setCurrentPath(parentPath)}>
                <ArrowLeft size={14} />
                返回上级
              </button>
            )}
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 13 }}>{activePath}</span>
          </div>
          <span className="muted-sm">{entries.length} 项</span>
        </div>

        {showDirSkeleton && !dirData ? (
          <TableSkeleton />
        ) : entries.length === 0 ? (
          <div style={{ padding: 36, textAlign: 'center' }} className="muted">
            空目录
          </div>
        ) : (
          <table className={`data-table ${isStaleData ? 'stale-dim' : ''}`}>
            <thead>
              <tr>
                <th>名称</th>
                <th>大小</th>
                <th>状态 / 关联作品</th>
                <th style={{ textAlign: 'right' }}>操作</th>
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr key={entry.path}>
                  <td>
                    {entry.is_dir ? (
                      <button
                        type="button"
                        className="nav-item"
                        style={{ padding: '4px 6px', display: 'inline-flex', width: 'auto' }}
                        onClick={() => setCurrentPath(entry.path)}
                      >
                        <Folder size={16} style={{ color: 'var(--accent)' }} />
                        <span>{entry.name}</span>
                      </button>
                    ) : (
                      <div className="flex-row" style={{ gap: 8 }}>
                        <Film size={15} className="muted" />
                        <span>{entry.name}</span>
                      </div>
                    )}
                  </td>
                  <td className="muted-sm">{entry.is_dir ? '文件夹' : formatBytes(entry.size)}</td>
                  <td>
                    {entry.title ? (
                      <Link to={`/item/${entry.item_id}`} className="tag accent">
                        {entry.title}
                      </Link>
                    ) : entry.is_video ? (
                      <span className="tag">已索引视频</span>
                    ) : (
                      <span className="muted-sm">-</span>
                    )}
                  </td>
                  <td style={{ textAlign: 'right' }}>
                    {!entry.is_dir && entry.file_id && (
                      <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
                        {entry.item_id && (
                          <button
                            type="button"
                            className="btn btn-sm"
                            onClick={() => navigate(`/item/${entry.item_id}`)}
                          >
                            详情
                          </button>
                        )}
                        <button
                          type="button"
                          className="btn btn-primary btn-sm"
                          onClick={() => navigate(`/play/file/${entry.file_id}`)}
                        >
                          播放
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
};
