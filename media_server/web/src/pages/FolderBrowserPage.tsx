import React, { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, Film, Folder, Play, RefreshCw } from 'lucide-react';
import { api, formatBytes, mountKindLabel } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MountBrowseEntry, MountRecord } from '../types';

export const FolderBrowserPage: React.FC = () => {
  const navigate = useNavigate();
  const { toast } = useApp();

  const [mounts, setMounts] = useState<MountRecord[]>([]);
  const [selectedMountId, setSelectedMountId] = useState('');
  const [currentPath, setCurrentPath] = useState('/');
  const [parentPath, setParentPath] = useState('/');
  const [entries, setEntries] = useState<MountBrowseEntry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api
      .listMounts()
      .then((res) => {
        const list = res.mounts || [];
        setMounts(list);
        if (list.length > 0) {
          setSelectedMountId(list[0].id);
        } else {
          setLoading(false);
        }
      })
      .catch((err) => {
        toast((err as Error).message, 'error');
        setLoading(false);
      });
  }, [toast]);

  const browse = useCallback(
    async (mid: string, p: string) => {
      if (!mid) return;
      setLoading(true);
      try {
        const res = await api.browseMount(mid, p);
        setCurrentPath(res.path || '/');
        setParentPath(res.parent || '/');
        setEntries(res.entries || []);
      } catch (err) {
        toast((err as Error).message, 'error');
      } finally {
        setLoading(false);
      }
    },
    [toast]
  );

  useEffect(() => {
    if (selectedMountId) {
      void browse(selectedMountId, '/');
    }
  }, [selectedMountId, browse]);

  if (mounts.length === 0 && !loading) {
    return (
      <div className="card-box" style={{ textAlign: 'center', padding: 48 }}>
        <p className="muted">还没有存储挂载源</p>
        <Link to="/manage/mounts" className="btn btn-primary">
          去添加挂载源
        </Link>
      </div>
    );
  }

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
            onClick={() => setSelectedMountId(m.id)}
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
            {currentPath !== '/' && (
              <button type="button" className="btn btn-sm" onClick={() => void browse(selectedMountId, parentPath)}>
                <ArrowLeft size={14} />
                返回上级
              </button>
            )}
            <span style={{ fontFamily: 'monospace', fontSize: 13 }}>{currentPath}</span>
          </div>
          <span className="muted-sm">{entries.length} 项</span>
        </div>

        {loading ? (
          <div style={{ padding: 28 }} className="muted">
            读取目录中...
          </div>
        ) : entries.length === 0 ? (
          <div style={{ padding: 36, textAlign: 'center' }} className="muted">
            空目录
          </div>
        ) : (
          <table className="data-table">
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
                        onClick={() => void browse(selectedMountId, entry.path)}
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
                          <Play size={13} fill="currentColor" />
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
