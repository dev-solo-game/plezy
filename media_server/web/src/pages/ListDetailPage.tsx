import React, { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowDown, ArrowLeft, ArrowUp, Edit3, Play, Trash2 } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { MediaList } from '../types';

export const ListDetailPage: React.FC = () => {
  const { id } = useParams();
  const navigate = useNavigate();
  const { libraryVersion, toast } = useApp();
  const listId = Number(id);

  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState('');
  const [summary, setSummary] = useState('');

  const {
    data: list,
    showSkeleton,
    reload,
  } = useSWRQuery<MediaList>(
    listId ? `list:${listId}` : null,
    () => api.getList(listId).then((r) => r.list),
    {
      deps: [libraryVersion],
      onError: (err) => toast(err.message, 'error'),
    }
  );

  useEffect(() => {
    if (list && !editing) {
      setTitle(list.title);
      setSummary(list.summary || '');
    }
  }, [list, editing]);

  const handleSaveMeta = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.updateList(listId, { title: title.trim(), summary: summary.trim() });
      setEditing(false);
      toast('已更新', 'success');
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleDelete = async () => {
    if (!window.confirm(`确认删除「${list?.title}」？作品本身不会被删除。`)) return;
    try {
      await api.deleteList(listId);
      toast('已删除列表', 'success');
      navigate('/lists');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const moveItem = async (idx: number, dir: -1 | 1) => {
    const items = list?.items || [];
    const target = idx + dir;
    if (target < 0 || target >= items.length) return;
    const ids = items.map((x) => x.id);
    const tmp = ids[idx];
    ids[idx] = ids[target];
    ids[target] = tmp;
    try {
      await api.reorderList(listId, ids);
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const removeItem = async (itemId: number) => {
    try {
      await api.removeListItem(listId, itemId);
      await reload();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  if (showSkeleton) return <CardListSkeleton />;
  if (!list) return null;

  const items = list.items || [];

  return (
    <div>
      <div className="flex-row" style={{ marginBottom: 16 }}>
        <Link to="/lists" className="btn btn-sm">
          <ArrowLeft size={14} />
          返回列表
        </Link>
      </div>

      <div className="glass-panel" style={{ padding: 24, marginBottom: 24 }}>
        {!editing ? (
          <div className="flex-row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div>
              <div className="flex-row" style={{ marginBottom: 6 }}>
                <span className="tag accent">{list.kind === 'collection' ? '系列合集' : '播放列表'}</span>
                <span className="tag">{items.length} 项</span>
              </div>
              <h1 style={{ margin: '0 0 8px', fontSize: 26 }}>{list.title}</h1>
              {list.summary && <p className="muted" style={{ margin: 0 }}>{list.summary}</p>}
            </div>

            <div className="flex-row">
              {items.length > 0 && (
                <button type="button" className="btn btn-primary" onClick={() => navigate(`/play/${items[0].id}`)}>
                  <Play size={15} fill="currentColor" />
                  从第一项播放
                </button>
              )}
              <button type="button" className="btn btn-sm" onClick={() => setEditing(true)}>
                <Edit3 size={14} />
                编辑
              </button>
              <button type="button" className="btn btn-danger btn-sm" onClick={() => void handleDelete()}>
                <Trash2 size={14} />
                删除
              </button>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSaveMeta} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div className="field">
              <label>标题</label>
              <input className="input" value={title} onChange={(e) => setTitle(e.target.value)} required />
            </div>
            <div className="field">
              <label>简介</label>
              <textarea className="textarea" value={summary} onChange={(e) => setSummary(e.target.value)} />
            </div>
            <div className="flex-row">
              <button type="submit" className="btn btn-primary btn-sm">
                保存
              </button>
              <button type="button" className="btn btn-sm" onClick={() => setEditing(false)}>
                取消
              </button>
            </div>
          </form>
        )}
      </div>

      {items.length === 0 ? (
        <div className="card-box muted" style={{ textAlign: 'center', padding: 40 }}>
          列表内暂无作品，可在任意电影/剧集详情页点击「加入播单」添加。
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {items.map((it, idx) => {
            const poster = artworkUrl(it.poster_source || it.show_poster, 'w185');
            return (
              <div key={it.id} className="card-box flex-row" style={{ padding: 12, justifyContent: 'space-between' }}>
                <div className="flex-row" style={{ gap: 14, flex: 1, minWidth: 0 }}>
                  <span className="muted-sm" style={{ width: 24, textAlign: 'center' }}>
                    {idx + 1}
                  </span>
                  {poster && (
                    <img
                      src={poster}
                      alt={it.title}
                      loading="lazy"
                      decoding="async"
                      style={{ width: 44, height: 64, objectFit: 'cover', borderRadius: 6 }}
                    />
                  )}
                  <div style={{ minWidth: 0 }}>
                    <Link to={`/item/${it.id}`} style={{ fontWeight: 600 }}>
                      {it.title}
                    </Link>
                    <div className="muted-sm">
                      {it.year || ''} {it.quality_badge ? `· ${it.quality_badge}` : ''}
                    </div>
                  </div>
                </div>

                <div className="flex-row">
                  <button type="button" className="btn btn-icon btn-sm" onClick={() => void moveItem(idx, -1)} disabled={idx === 0} title="上移">
                    <ArrowUp size={14} />
                  </button>
                  <button type="button" className="btn btn-icon btn-sm" onClick={() => void moveItem(idx, 1)} disabled={idx === items.length - 1} title="下移">
                    <ArrowDown size={14} />
                  </button>
                  <button type="button" className="btn btn-primary btn-sm" onClick={() => navigate(`/play/${it.id}`)}>
                    <Play size={13} fill="currentColor" />
                    播放
                  </button>
                  <button type="button" className="btn btn-danger btn-sm" onClick={() => void removeItem(it.id)}>
                    移除
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
};
