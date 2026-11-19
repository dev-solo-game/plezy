import React, { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { User } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { MediaCard } from '../components/MediaCard';
import { useApp } from '../contexts/AppContext';
import type { MediaItem, Person } from '../types';

export const PersonPage: React.FC = () => {
  const { id } = useParams();
  const { toast } = useApp();
  const [person, setPerson] = useState<Person | null>(null);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    api
      .getPerson(Number(id))
      .then((res) => {
        setPerson(res.detail.person);
        setItems(res.detail.items || []);
      })
      .catch((err) => toast((err as Error).message, 'error'))
      .finally(() => setLoading(false));
  }, [id, toast]);

  if (loading) return <div className="muted">加载中...</div>;
  if (!person) return null;

  const photo = artworkUrl(person.photo_source, 'w500');

  return (
    <div>
      <div className="glass-panel" style={{ padding: 24, marginBottom: 24, display: 'flex', gap: 24, flexWrap: 'wrap' }}>
        {photo ? (
          <img
            src={photo}
            alt={person.name}
            style={{ width: 150, height: 210, objectFit: 'cover', borderRadius: 14 }}
          />
        ) : (
          <div
            style={{
              width: 150,
              height: 210,
              borderRadius: 14,
              background: 'var(--bg-card)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <User size={40} className="muted" />
          </div>
        )}
        <div style={{ flex: 1, minWidth: 260 }}>
          <h1 style={{ margin: '0 0 8px' }}>{person.name}</h1>
          <div className="flex-row" style={{ marginBottom: 12 }}>
            {person.department && <span className="tag accent">{person.department}</span>}
            {person.birthday && <span className="tag">生于 {person.birthday}</span>}
            {person.place_of_birth && <span className="tag">{person.place_of_birth}</span>}
          </div>
          {person.biography ? (
            <p className="muted" style={{ lineHeight: 1.7, margin: 0, whiteSpace: 'pre-line' }}>
              {person.biography}
            </p>
          ) : (
            <p className="muted-sm">暂无详细简介</p>
          )}
        </div>
      </div>

      <div className="section-head">
        <h2 className="section-title">媒体库相关作品 ({items.length})</h2>
      </div>
      <div className="poster-grid">
        {items.map((item) => (
          <MediaCard key={item.id} item={item} />
        ))}
      </div>
    </div>
  );
};
