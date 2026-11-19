import React, { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Layers, Plus } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MediaList } from '../types';

export const ListsPage: React.FC = () => {
  const { toast } = useApp();
  const [tab, setTab] = useState<'all' | 'collection' | 'playlist'>('all');
  const [lists, setLists] = useState<MediaList[]>([]);
  const [loading, setLoading] = useState(true);
  const [newTitle, setNewTitle] = useState('');
  const [newKind, setNewKind] = useState<'playlist' | 'collection'>('playlist');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listLists(tab === 'all' ? undefined : tab);
      setLists(res.lists || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [tab, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newTitle.trim()) return;
    try {
      await api.createList({ kind: newKind, title: newTitle.trim() });
      setNewTitle('');
      toast('创建成功', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <h2 className="section-title">合集与播放列表</h2>
        <div className="flex-row">
          {(
            [
              ['all', '全部'],
              ['collection', '系列合集'],
              ['playlist', '播放列表'],
            ] as const
          ).map(([k, label]) => (
            <button key={k} type="button" className={`chip ${tab === k ? 'active' : ''}`} onClick={() => setTab(k)}>
              {label}
            </button>
          ))}
        </div>
      </div>

      <form className="card-box flex-row" style={{ padding: 14, marginBottom: 20 }} onSubmit={handleCreate}>
        <select className="select" style={{ width: 130 }} value={newKind} onChange={(e) => setNewKind(e.target.value as 'playlist' | 'collection')}>
          <option value="playlist">播放列表</option>
          <option value="collection">自定义合集</option>
        </select>
        <input
          className="input"
          style={{ flex: 1 }}
          placeholder="输入新列表标题..."
          value={newTitle}
          onChange={(e) => setNewTitle(e.target.value)}
        />
        <button type="submit" className="btn btn-primary" disabled={!newTitle.trim()}>
          <Plus size={15} />
          新建
        </button>
      </form>

      {loading ? (
        <div className="muted">加载中...</div>
      ) : lists.length === 0 ? (
        <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
          暂无合集或播单（TMDB 刮削电影系列时也会自动生成合集）
        </div>
      ) : (
        <div className="poster-grid">
          {lists.map((l) => {
            const img = artworkUrl(l.poster_source, 'w500');
            return (
              <Link key={l.id} to={`/lists/${l.id}`} className="media-card">
                <div className="media-thumb">
                  {img ? (
                    <img src={img} alt={l.title} loading="lazy" />
                  ) : (
                    <div className="media-fallback">
                      <Layers size={26} />
                      <span>{l.title}</span>
                    </div>
                  )}
                  <span className="badge-top-right">{l.kind === 'collection' ? '合集' : '播单'}</span>
                </div>
                <div className="media-title">{l.title}</div>
                <div className="media-sub">
                  <span>{l.item_count} 部作品</span>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
};
