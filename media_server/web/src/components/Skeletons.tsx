import React from 'react';

export const HomeSkeleton: React.FC = () => (
  <div>
    <div className="skel skel-hero" />
    <div style={{ marginBottom: 24 }}>
      <div className="skel skel-line" style={{ width: 140, height: 20, marginBottom: 14 }} />
      <div className="h-scroll-row landscape">
        {[1, 2, 3, 4].map((i) => (
          <div key={i}>
            <div className="skel skel-thumb-land" />
            <div className="skel skel-line" style={{ width: '72%', marginTop: 8 }} />
          </div>
        ))}
      </div>
    </div>
    <div>
      <div className="skel skel-line" style={{ width: 140, height: 20, marginBottom: 14 }} />
      <div className="h-scroll-row">
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <div key={i}>
            <div className="skel skel-thumb" />
            <div className="skel skel-line" style={{ width: '78%', marginTop: 8 }} />
            <div className="skel skel-line sm" style={{ width: '44%', marginTop: 6 }} />
          </div>
        ))}
      </div>
    </div>
  </div>
);

export const GridSkeleton: React.FC<{ count?: number }> = ({ count = 12 }) => (
  <div className="poster-grid">
    {Array.from({ length: count }, (_, idx) => (
      <div key={idx}>
        <div className="skel skel-thumb" />
        <div className="skel skel-line" style={{ width: '78%', marginTop: 8 }} />
        <div className="skel skel-line sm" style={{ width: '42%', marginTop: 6 }} />
      </div>
    ))}
  </div>
);

export const DetailSkeleton: React.FC = () => (
  <div>
    <div className="detail-hero" style={{ minHeight: 330 }}>
      <div className="detail-inner">
        <div className="skel skel-thumb" style={{ width: '100%' }} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14, paddingTop: 6 }}>
          <div className="flex-row">
            <div className="skel skel-line" style={{ width: 58, height: 22 }} />
            <div className="skel skel-line" style={{ width: 52, height: 22 }} />
            <div className="skel skel-line" style={{ width: 64, height: 22 }} />
          </div>
          <div className="skel skel-line" style={{ width: '48%', height: 34 }} />
          <div className="skel skel-line" style={{ width: '85%' }} />
          <div className="skel skel-line" style={{ width: '72%' }} />
          <div className="flex-row" style={{ marginTop: 8 }}>
            <div className="skel skel-line" style={{ width: 120, height: 38 }} />
            <div className="skel skel-line" style={{ width: 96, height: 38 }} />
            <div className="skel skel-line" style={{ width: 96, height: 38 }} />
          </div>
        </div>
      </div>
    </div>
  </div>
);

export const CardListSkeleton: React.FC<{ count?: number }> = ({ count = 4 }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
    {Array.from({ length: count }, (_, idx) => (
      <div key={idx} className="card-box" style={{ height: 88 }}>
        <div className="skel skel-line" style={{ width: '36%', height: 18, marginBottom: 10 }} />
        <div className="skel skel-line sm" style={{ width: '68%' }} />
      </div>
    ))}
  </div>
);

export const TableSkeleton: React.FC<{ rows?: number }> = ({ rows = 6 }) => (
  <div style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
    {Array.from({ length: rows }, (_, idx) => (
      <div key={idx} className="flex-row" style={{ justifyContent: 'space-between' }}>
        <div className="skel skel-line" style={{ width: `${32 + (idx % 3) * 14}%`, height: 18 }} />
        <div className="skel skel-line sm" style={{ width: 64 }} />
      </div>
    ))}
  </div>
);
