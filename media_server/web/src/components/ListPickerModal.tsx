import React, { useEffect, useState } from 'react';
import { Loader2, Plus, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MediaList } from '../types';
import { ModalBackdrop } from './ModalBackdrop';

interface ListPickerModalProps {
  itemId: number;
  onClose: () => void;
}

export const ListPickerModal: React.FC<ListPickerModalProps> = ({ itemId, onClose }) => {
  const { toast } = useApp();
  const [lists, setLists] = useState<MediaList[]>([]);
  const [loading, setLoading] = useState(true);
  const [newTitle, setNewTitle] = useState('');
  const [creating, setCreating] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      const res = await api.listLists('playlist');
      setLists(res.lists || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const addTo = async (listId: number, title: string) => {
    try {
      await api.addListItems(listId, [itemId]);
      toast(`已添加到播单《${title}》`, 'success');
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const createAndAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newTitle.trim()) return;
    setCreating(true);
    try {
      await api.createList({ kind: 'playlist', title: newTitle.trim(), item_ids: [itemId] });
      toast(`已创建播单《${newTitle.trim()}》并加入`, 'success');
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  return (
    <ModalBackdrop onClose={onClose}>
      <div className="modal-panel" style={{ maxWidth: 460 }}>
        <div className="modal-header">
          <h3>添加到播单</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body">
          <form className="flex-row" onSubmit={createAndAdd}>
            <input
              className="input"
              style={{ flex: 1 }}
              placeholder="新建播单名称..."
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
            />
            <button type="submit" className="btn btn-primary btn-sm" disabled={creating || !newTitle.trim()}>
              {creating ? <Loader2 size={14} className="spin" /> : <Plus size={14} />}
              新建并加入
            </button>
          </form>

          <div className="divider" />

          {loading ? (
            <div className="muted-sm">加载中...</div>
          ) : lists.length === 0 ? (
            <div className="muted-sm">暂无播单，请在上方创建一个</div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {lists.map((l) => (
                <button
                  key={l.id}
                  type="button"
                  className="nav-item"
                  style={{ border: '1px solid var(--border-subtle)', justifyContent: 'space-between' }}
                  onClick={() => void addTo(l.id, l.title)}
                >
                  <span>{l.title}</span>
                  <span className="muted-sm">{l.item_count} 项</span>
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
    </ModalBackdrop>
  );
};
