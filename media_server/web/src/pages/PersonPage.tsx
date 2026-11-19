import React from 'react';
import { useParams } from 'react-router-dom';
import { User } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { MediaCard } from '../components/MediaCard';
import { DetailSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { MediaItem, Person } from '../types';

export const PersonPage: React.FC = () => {
  const { id } = useParams();
  const { libraryVersion, toast } = useApp();
  const personId = Number(id);

  const { data, showSkeleton } = useSWRQuery<{ person: Person; items: MediaItem[] }>(
    personId ? `person:${personId}` : null,
    () => api.getPerson(personId).then((r) => r.detail),
    {
      deps: [libraryVersion],
      onError: (err) => toast(err.message, 'error'),
    }
  );

  if (showSkeleton) return <DetailSkeleton />;
  if (!data) return null;

  const { person, items } = data;
  const photo = artworkUrl(person.photo_source, 'w500');

  return (
    <div>
      <div className="glass-panel" style={{ padding: 24, marginBottom: 24, display: 'flex', gap: 24, flexWrap: 'wrap' }}>
        {photo ? (
          <img
            src={photo}
            alt={person.name}
            decoding="async"
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
