import React, { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Search, User } from 'lucide-react';
import { api, artworkUrl } from '../api/client';
import { MediaCard } from '../components/MediaCard';
import { useApp } from '../contexts/AppContext';
import type { MediaItem, Person } from '../types';

export const SearchPage: React.FC = () => {
  const [params, setParams] = useSearchParams();
  const { toast } = useApp();
  const initialQ = params.get('q') || '';
  const [q, setQ] = useState(initialQ);
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<{
    movies: MediaItem[];
    shows: MediaItem[];
    episodes: MediaItem[];
    people: Person[];
  }>({ movies: [], shows: [], episodes: [], people: [] });

  useEffect(() => {
    setQ(params.get('q') || '');
  }, [params]);

  useEffect(() => {
    const keyword = (params.get('q') || '').trim();
    if (!keyword) {
      setResults({ movies: [], shows: [], episodes: [], people: [] });
      return;
    }
    setLoading(true);
    api
      .search(keyword)
      .then((res) => setResults(res.results))
      .catch((err) => toast((err as Error).message, 'error'))
      .finally(() => setLoading(false));
  }, [params, toast]);

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setParams(q.trim() ? { q: q.trim() } : {});
  };

  const hasAny =
    results.movies.length + results.shows.length + results.episodes.length + results.people.length > 0;

  return (
    <div>
      <form className="card-box flex-row" style={{ padding: 14, marginBottom: 24 }} onSubmit={onSubmit}>
        <Search size={18} className="muted" />
        <input
          className="input"
          style={{ flex: 1 }}
          placeholder="输入关键词搜索电影、剧集、单集或演职员..."
          value={q}
          onChange={(e) => setQ(e.target.value)}
          autoFocus
        />
        <button type="submit" className="btn btn-primary">
          搜索
        </button>
      </form>

      {loading ? (
        <div className="muted">搜索中...</div>
      ) : !params.get('q') ? (
        <div className="muted">输入标题、原名、剧集或演员姓名开始搜索。</div>
      ) : !hasAny ? (
        <div className="card-box muted" style={{ textAlign: 'center', padding: 48 }}>
          未找到与「{params.get('q')}」相关的内容
        </div>
      ) : (
        <>
          {results.movies.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">电影 ({results.movies.length})</h2>
              </div>
              <div className="poster-grid">
                {results.movies.map((m) => (
                  <MediaCard key={m.id} item={m} />
                ))}
              </div>
            </section>
          )}

          {results.shows.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">剧集 / 动漫 / 综艺 ({results.shows.length})</h2>
              </div>
              <div className="poster-grid">
                {results.shows.map((s) => (
                  <MediaCard key={s.id} item={s} />
                ))}
              </div>
            </section>
          )}

          {results.episodes.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">单集 ({results.episodes.length})</h2>
              </div>
              <div className="poster-grid">
                {results.episodes.map((ep) => (
                  <MediaCard key={ep.id} item={ep} landscape />
                ))}
              </div>
            </section>
          )}

          {results.people.length > 0 && (
            <section>
              <div className="section-head">
                <h2 className="section-title">演职员 ({results.people.length})</h2>
              </div>
              <div className="flex-row" style={{ gap: 16 }}>
                {results.people.map((p) => {
                  const photo = artworkUrl(p.photo_source, 'w185');
                  return (
                    <Link
                      key={p.id}
                      to={`/person/${p.id}`}
                      className="card-box"
                      style={{ width: 140, padding: 12, textAlign: 'center' }}
                    >
                      {photo ? (
                        <img
                          src={photo}
                          alt={p.name}
                          style={{ width: 84, height: 84, borderRadius: '50%', objectFit: 'cover', marginBottom: 8 }}
                        />
                      ) : (
                        <div
                          style={{
                            width: 84,
                            height: 84,
                            borderRadius: '50%',
                            background: 'var(--bg-card)',
                            display: 'inline-flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            marginBottom: 8,
                          }}
                        >
                          <User size={28} className="muted" />
                        </div>
                      )}
                      <div style={{ fontWeight: 600, fontSize: 13 }}>{p.name}</div>
                    </Link>
                  );
                })}
              </div>
            </section>
          )}
        </>
      )}
    </div>
  );
};
