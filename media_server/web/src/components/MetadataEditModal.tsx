import React, { useState } from 'react';
import { Loader2, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MediaItem } from '../types';

interface MetadataEditModalProps {
  item: MediaItem;
  onClose: () => void;
  onSaved: () => void;
}

export const MetadataEditModal: React.FC<MetadataEditModalProps> = ({ item, onClose, onSaved }) => {
  const { toast } = useApp();
  const [title, setTitle] = useState(item.title || '');
  const [originalTitle, setOriginalTitle] = useState(item.original_title || '');
  const [year, setYear] = useState(item.year ? String(item.year) : '');
  const [libraryType, setLibraryType] = useState(item.library_type || 'movie');
  const [rating, setRating] = useState(item.rating !== undefined && item.rating !== null ? String(item.rating) : '');
  const [studio, setStudio] = useState(item.studio || '');
  const [tagline, setTagline] = useState(item.tagline || '');
  const [summary, setSummary] = useState(item.summary || '');
  const [posterSource, setPosterSource] = useState(item.poster_source || '');
  const [backdropSource, setBackdropSource] = useState(item.backdrop_source || '');
  const [locked, setLocked] = useState(item.locked ?? true);
  const [saving, setSaving] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      await api.updateMetadata(item.id, {
        title: title.trim(),
        original_title: originalTitle.trim(),
        year: year.trim() ? Number(year) : null,
        library_type: libraryType,
        rating: rating.trim() ? Number(rating) : null,
        studio: studio.trim(),
        tagline: tagline.trim(),
        summary: summary.trim(),
        poster_source: posterSource.trim(),
        backdrop_source: backdropSource.trim(),
        locked,
      });
      toast('元数据已保存', 'success');
      onSaved();
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <form className="modal-panel" onClick={(e) => e.stopPropagation()} onSubmit={handleSubmit}>
        <div className="modal-header">
          <h3>编辑元数据</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body">
          <div className="grid-2">
            <div className="field">
              <label>主标题</label>
              <input className="input" value={title} onChange={(e) => setTitle(e.target.value)} required />
            </div>
            <div className="field">
              <label>原名 / 英文名</label>
              <input className="input" value={originalTitle} onChange={(e) => setOriginalTitle(e.target.value)} />
            </div>
            <div className="field">
              <label>年份</label>
              <input className="input" type="number" value={year} onChange={(e) => setYear(e.target.value)} />
            </div>
            <div className="field">
              <label>分类架位</label>
              <select className="select" value={libraryType} onChange={(e) => setLibraryType(e.target.value)}>
                <option value="movie">电影</option>
                <option value="show">剧集</option>
                <option value="anime">动漫</option>
                <option value="variety">综艺</option>
                <option value="documentary">纪录片</option>
                <option value="pending">待匹配</option>
              </select>
            </div>
            <div className="field">
              <label>评分 (0-10)</label>
              <input className="input" type="number" step="0.1" value={rating} onChange={(e) => setRating(e.target.value)} />
            </div>
            <div className="field">
              <label>制片方 / 出品</label>
              <input className="input" value={studio} onChange={(e) => setStudio(e.target.value)} />
            </div>
          </div>

          <div className="field">
            <label>宣传语 (Tagline)</label>
            <input className="input" value={tagline} onChange={(e) => setTagline(e.target.value)} />
          </div>

          <div className="field">
            <label>剧情简介</label>
            <textarea className="textarea" value={summary} onChange={(e) => setSummary(e.target.value)} />
          </div>

          <div className="grid-2">
            <div className="field">
              <label>海报地址 / TMDB Path / mount:...</label>
              <input className="input" value={posterSource} onChange={(e) => setPosterSource(e.target.value)} />
            </div>
            <div className="field">
              <label>背景图地址 / TMDB Path</label>
              <input className="input" value={backdropSource} onChange={(e) => setBackdropSource(e.target.value)} />
            </div>
          </div>

          <label className="flex-row" style={{ cursor: 'pointer', fontSize: 13 }}>
            <input type="checkbox" checked={locked} onChange={(e) => setLocked(e.target.checked)} />
            锁定元数据（后续自动刮削时不覆盖手工修改）
          </label>
        </div>

        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>
            取消
          </button>
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving && <Loader2 size={14} className="spin" />}
            保存
          </button>
        </div>
      </form>
    </div>
  );
};
