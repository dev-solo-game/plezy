import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Hls from 'hls.js';
import {
  ArrowLeft,
  Captions,
  ChevronRight,
  ExternalLink,
  FastForward,
  ListVideo,
  SkipForward,
  Upload,
} from 'lucide-react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { api, formatDurationMs, mountKindLabel } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { MediaItem, PlaybackInfo, PlaybackVersion } from '../types';

function decodeSubtitleBytes(buf: ArrayBuffer): string {
  const utf8 = new TextDecoder('utf-8', { fatal: false }).decode(buf);
  if (!utf8.includes('\uFFFD')) return utf8;
  try {
    return new TextDecoder('gb18030', { fatal: false }).decode(buf);
  } catch {
    return utf8;
  }
}

function parseAssTimestampMs(ts: string): number {
  const m = ts.trim().match(/^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$/);
  if (!m) return 0;
  const h = Number(m[1]);
  const min = Number(m[2]);
  const s = Number(m[3]);
  const frac = m[4].length === 2 ? Number(m[4]) * 10 : m[4].length === 1 ? Number(m[4]) * 100 : Number(m[4]);
  return ((h * 60 + min) * 60 + s) * 1000 + frac;
}

function formatVttMs(ms: number): string {
  const clamped = Math.max(0, Math.round(ms));
  const h = Math.floor(clamped / 3600000);
  const m = Math.floor((clamped % 3600000) / 60000);
  const s = Math.floor((clamped % 60000) / 1000);
  const milli = clamped % 1000;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${String(milli).padStart(3, '0')}`;
}

function convertToVttText(raw: string, ext: string): string {
  const norm = raw.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lowerExt = ext.toLowerCase();
  if (lowerExt === 'vtt' || norm.trimStart().startsWith('WEBVTT')) {
    return norm;
  }
  if (lowerExt === 'ass' || lowerExt === 'ssa') {
    const lines = norm.split('\n');
    const out: string[] = ['WEBVTT', ''];
    for (const line of lines) {
      if (!line.startsWith('Dialogue:')) continue;
      const parts = line.slice('Dialogue:'.length).split(',');
      if (parts.length < 10) continue;
      const start = formatVttMs(parseAssTimestampMs(parts[1]));
      const end = formatVttMs(parseAssTimestampMs(parts[2]));
      const text = parts
        .slice(9)
        .join(',')
        .replace(/\{[^}]*\}/g, '')
        .replace(/\\[Nn]/g, '\n')
        .trim();
      if (text) {
        out.push(`${start} --> ${end}`);
        out.push(text);
        out.push('');
      }
    }
    return out.join('\n');
  }
  // Default SRT -> VTT
  const converted = norm.replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, '$1.$2');
  return `WEBVTT\n\n${converted}`;
}

function shiftVttText(vtt: string, offsetSec: number): string {
  if (!offsetSec) return vtt;
  const shiftMs = offsetSec * 1000;
  return vtt.replace(
    /(?:(\d{1,2}):)?(\d{2}):(\d{2})\.(\d{3})/g,
    (_all, hStr: string | undefined, mStr: string, sStr: string, msStr: string) => {
      const h = hStr ? Number(hStr) : 0;
      const total = ((h * 60 + Number(mStr)) * 60 + Number(sStr)) * 1000 + Number(msStr) + shiftMs;
      return formatVttMs(total);
    }
  );
}

interface SubTrackItem {
  id: string;
  label: string;
  vttUrl: string;
  rawVtt?: string;
}

export const PlayerPage: React.FC = () => {
  const { itemId, fileId } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const { toast } = useApp();

  const videoRef = useRef<HTMLVideoElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const hlsRef = useRef<Hls | null>(null);
  const pendingSeekRef = useRef<number | null>(null);
  const lastSavedSecRef = useRef<number>(0);

  const [pb, setPb] = useState<PlaybackInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedFileId, setSelectedFileId] = useState<number>(0);
  const [selectedStreamUrl, setSelectedStreamUrl] = useState<string>('');
  const [selectedIsHls, setSelectedIsHls] = useState<boolean>(false);
  const [speed, setSpeed] = useState<number>(1);
  const [currentTimeSec, setCurrentTimeSec] = useState<number>(0);
  const [durationSec, setDurationSec] = useState<number>(0);

  // Subtitles
  const [localSubs, setLocalSubs] = useState<SubTrackItem[]>([]);
  const [activeSubId, setActiveSubId] = useState<string>('');
  const [activeSubBlobUrl, setActiveSubBlobUrl] = useState<string>('');
  const [subOffsetSec, setSubOffsetSec] = useState<number>(0);
  const [subFontSizePct, setSubFontSizePct] = useState<number>(100);
  const [serverSubVttCache, setServerSubVttCache] = useState<Record<string, string>>({});

  // Episodes drawer
  const [showEpisodes, setShowEpisodes] = useState(false);
  const [seasonEpisodes, setSeasonEpisodes] = useState<MediaItem[]>([]);

  const requestedFileId = Number(searchParams.get('file_id') || 0);

  useEffect(() => {
    setLoading(true);
    const loadPromise = fileId
      ? api.getPlaybackInfoFile(Number(fileId))
      : api.getPlaybackInfoItem(Number(itemId), requestedFileId || undefined);

    loadPromise
      .then((res) => {
        setPb(res);
        const fid = res.selected_file_id || res.versions?.[0]?.file.id || 0;
        setSelectedFileId(fid);

        const ver = res.versions?.find((v) => v.file.id === fid) || res.versions?.[0];
        if (ver) {
          const preferTranscode =
            (res.web_prefer_cloud_transcode || !ver.browser_compatible) &&
            ver.variants &&
            ver.variants.length > 0;
          if (preferTranscode && ver.variants && ver.variants.length > 0) {
            setSelectedStreamUrl(ver.variants[0].stream_url);
            setSelectedIsHls(ver.variants[0].is_hls);
          } else {
            setSelectedStreamUrl(ver.stream_url);
            setSelectedIsHls(false);
          }
        }

        if (res.work_prefs?.playback_speed && res.work_prefs.playback_speed > 0) {
          setSpeed(res.work_prefs.playback_speed);
        } else {
          setSpeed(1);
        }

        if (res.resume_position_ms > 2000) {
          pendingSeekRef.current = res.resume_position_ms / 1000;
        } else {
          pendingSeekRef.current = null;
        }

        if (res.subtitles && res.subtitles.length > 0) {
          setActiveSubId(`srv-${res.subtitles[0].id}`);
        } else {
          setActiveSubId('');
        }

        if (res.show?.id) {
          api
            .getItemDetail(res.show.id)
            .then((d) => setSeasonEpisodes(d.detail.episodes || []))
            .catch(() => {});
        } else {
          setSeasonEpisodes([]);
        }
      })
      .catch((err) => toast((err as Error).message, 'error'))
      .finally(() => setLoading(false));
  }, [itemId, fileId, requestedFileId, toast]);

  const activeVersion: PlaybackVersion | undefined = useMemo(
    () => pb?.versions?.find((v) => v.file.id === selectedFileId) || pb?.versions?.[0],
    [pb, selectedFileId]
  );

  // Mount video source + Hls.js cleanly
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !selectedStreamUrl) return;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    const applySeekAndPlay = () => {
      video.playbackRate = speed;
      if (pendingSeekRef.current !== null && Number.isFinite(pendingSeekRef.current)) {
        video.currentTime = pendingSeekRef.current;
        pendingSeekRef.current = null;
      }
      void video.play().catch(() => {});
    };

    if (selectedIsHls && Hls.isSupported() && !video.canPlayType('application/vnd.apple.mpegurl')) {
      const hls = new Hls({ enableWorker: true });
      hlsRef.current = hls;
      hls.loadSource(selectedStreamUrl);
      hls.attachMedia(video);
      hls.on(Hls.Events.MANIFEST_PARSED, applySeekAndPlay);
      hls.on(Hls.Events.ERROR, (_ev, data) => {
        if (data.fatal) {
          toast(`HLS 播放出错 (${data.type})，可尝试切换其他清晰度或外部播放器`, 'error');
        }
      });
    } else {
      video.src = selectedStreamUrl;
      const onLoaded = () => {
        applySeekAndPlay();
      };
      video.addEventListener('loadedmetadata', onLoaded, { once: true });
      return () => {
        video.removeEventListener('loadedmetadata', onLoaded);
      };
    }

    return () => {
      if (hlsRef.current) {
        hlsRef.current.destroy();
        hlsRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedStreamUrl, selectedIsHls]);

  useEffect(() => {
    if (videoRef.current) {
      videoRef.current.playbackRate = speed;
    }
  }, [speed]);

  // Report playback progress
  const sendProgress = useCallback(
    (keepalive = false) => {
      if (!pb?.item?.id || !videoRef.current) return;
      const posMs = Math.floor(videoRef.current.currentTime * 1000);
      const dur = videoRef.current.duration;
      const durMs = Number.isFinite(dur) && dur > 0 ? Math.floor(dur * 1000) : undefined;
      if (posMs < 1000) return;
      lastSavedSecRef.current = videoRef.current.currentTime;
      void api
        .reportProgress(
          {
            item_id: pb.item.id,
            file_id: selectedFileId || undefined,
            position_ms: posMs,
            duration_ms: durMs,
          },
          keepalive
        )
        .catch(() => {});
    },
    [pb?.item?.id, selectedFileId]
  );

  useEffect(() => {
    const t = window.setInterval(() => {
      const v = videoRef.current;
      if (v && !v.paused && Math.abs(v.currentTime - lastSavedSecRef.current) >= 4) {
        sendProgress(false);
      }
    }, 10000);
    const onPageHide = () => sendProgress(true);
    window.addEventListener('pagehide', onPageHide);
    return () => {
      window.clearInterval(t);
      window.removeEventListener('pagehide', onPageHide);
      sendProgress(true);
    };
  }, [sendProgress]);

  // All subtitle tracks combined (server + local uploaded)
  const allSubTracks: SubTrackItem[] = useMemo(() => {
    const srv: SubTrackItem[] = (pb?.subtitles || []).map((s) => ({
      id: `srv-${s.id}`,
      label: s.language ? `${s.file_name} (${s.language})` : s.file_name,
      vttUrl: s.vtt_url,
    }));
    return [...srv, ...localSubs];
  }, [pb?.subtitles, localSubs]);

  // Build shifted Blob URL whenever activeSubId or subOffsetSec changes
  useEffect(() => {
    let revokedUrl = '';
    if (!activeSubId) {
      setActiveSubBlobUrl('');
      return;
    }
    const track = allSubTracks.find((t) => t.id === activeSubId);
    if (!track) {
      setActiveSubBlobUrl('');
      return;
    }
    if (track.rawVtt) {
      const shifted = shiftVttText(track.rawVtt, subOffsetSec);
      revokedUrl = URL.createObjectURL(new Blob([shifted], { type: 'text/vtt' }));
      setActiveSubBlobUrl(revokedUrl);
    } else if (subOffsetSec === 0) {
      setActiveSubBlobUrl(track.vttUrl);
    } else {
      const cached = serverSubVttCache[track.id];
      if (cached) {
        const shifted = shiftVttText(cached, subOffsetSec);
        revokedUrl = URL.createObjectURL(new Blob([shifted], { type: 'text/vtt' }));
        setActiveSubBlobUrl(revokedUrl);
      } else {
        fetch(track.vttUrl)
          .then((r) => r.text())
          .then((txt) => {
            setServerSubVttCache((prev) => ({ ...prev, [track.id]: txt }));
            const shifted = shiftVttText(txt, subOffsetSec);
            const blobUrl = URL.createObjectURL(new Blob([shifted], { type: 'text/vtt' }));
            revokedUrl = blobUrl;
            setActiveSubBlobUrl(blobUrl);
          })
          .catch(() => setActiveSubBlobUrl(track.vttUrl));
      }
    }
    return () => {
      if (revokedUrl) URL.revokeObjectURL(revokedUrl);
    };
  }, [activeSubId, subOffsetSec, allSubTracks, serverSubVttCache]);

  // Keyboard shortcuts
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
      const v = videoRef.current;
      if (!v) return;
      if (e.code === 'Space') {
        e.preventDefault();
        if (v.paused) void v.play();
        else v.pause();
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        v.currentTime = Math.max(0, v.currentTime - 10);
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        v.currentTime = Math.min(v.duration || v.currentTime + 10, v.currentTime + 10);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        v.volume = Math.min(1, v.volume + 0.1);
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        v.volume = Math.max(0, v.volume - 0.1);
      } else if (e.key === 'm' || e.key === 'M') {
        v.muted = !v.muted;
      } else if (e.key === 'f' || e.key === 'F') {
        if (document.fullscreenElement) void document.exitFullscreen();
        else void stageRef.current?.requestFullscreen();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const switchStream = (url: string, isHls: boolean, nextFileId?: number) => {
    if (videoRef.current && (!nextFileId || nextFileId === selectedFileId)) {
      pendingSeekRef.current = videoRef.current.currentTime;
    } else if (nextFileId && nextFileId !== selectedFileId) {
      pendingSeekRef.current = videoRef.current?.currentTime || null;
      setSelectedFileId(nextFileId);
      setSearchParams(
        (prev) => {
          const p = new URLSearchParams(prev);
          p.set('file_id', String(nextFileId));
          return p;
        },
        { replace: true }
      );
    }
    setSelectedStreamUrl(url);
    setSelectedIsHls(isHls);
  };

  const handleUploadSubtitle = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const buf = await file.arrayBuffer();
    const rawText = decodeSubtitleBytes(buf);
    const ext = file.name.split('.').pop() || 'srt';
    const vttText = convertToVttText(rawText, ext);
    const id = `local-${Date.now()}`;
    setLocalSubs((prev) => [...prev, { id, label: `本地: ${file.name}`, vttUrl: '', rawVtt: vttText }]);
    setActiveSubId(id);
    setSubOffsetSec(0);
    toast(`已挂载本地字幕 ${file.name}`, 'success');
    e.target.value = '';
  };

  const wp = pb?.work_prefs;
  const introStart = wp ? wp.intro_start_ms / 1000 : 0;
  const introEnd = wp ? wp.intro_end_ms / 1000 : 0;
  const showSkipIntro = Boolean(
    wp?.intro_enabled && introEnd > introStart && currentTimeSec >= introStart && currentTimeSec < introEnd
  );

  const creditsThreshold =
    wp?.credits_enabled && durationSec > 0 && wp.credits_from_end_ms > 0
      ? durationSec - wp.credits_from_end_ms / 1000 - (wp.keep_easter_egg_ms || 0) / 1000
      : 0;
  const showNextEpPrompt = Boolean(
    pb?.next_episode && creditsThreshold > 0 && currentTimeSec >= creditsThreshold && currentTimeSec < durationSec
  );

  const titleText = pb?.show
    ? `${pb.show.title} · S${String(pb.item?.season_number || 1).padStart(2, '0')}E${String(
        pb.item?.episode_number || 1
      ).padStart(2, '0')} ${pb.item?.title || ''}`
    : pb?.item?.title || activeVersion?.file.file_name || '视频播放';

  const isSelectedOriginal = activeVersion?.stream_url === selectedStreamUrl;

  if (loading) {
    return (
      <div className="player-page" style={{ alignItems: 'center', justifyContent: 'center' }}>
        <div className="muted">正在准备播放流...</div>
      </div>
    );
  }

  return (
    <div className="player-page">
      <style>{`video::cue { font-size: ${subFontSizePct}%; background: rgba(0, 0, 0, 0.58); color: #fff; }`}</style>

      <div className="player-stage" ref={stageRef}>
        <div className="player-overlay-top">
          <div className="flex-row">
            <button
              type="button"
              className="btn btn-sm"
              onClick={() => {
                sendProgress(true);
                navigate(-1);
              }}
            >
              <ArrowLeft size={15} />
              返回
            </button>
            <strong style={{ fontSize: 15 }}>{titleText}</strong>
          </div>

          <div className="flex-row">
            {pb?.next_episode && (
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => {
                  sendProgress(true);
                  navigate(`/play/${pb.next_episode!.id}`, { replace: true });
                }}
              >
                <SkipForward size={14} />
                下一集
              </button>
            )}
            {seasonEpisodes.length > 0 && (
              <button type="button" className="btn btn-sm" onClick={() => setShowEpisodes((v) => !v)}>
                <ListVideo size={14} />
                选集 ({seasonEpisodes.length})
              </button>
            )}
          </div>
        </div>

        <video
          ref={videoRef}
          className="player-video"
          controls
          playsInline
          crossOrigin="use-credentials"
          onTimeUpdate={() => {
            if (!videoRef.current) return;
            setCurrentTimeSec(videoRef.current.currentTime);
            if (Number.isFinite(videoRef.current.duration)) {
              setDurationSec(videoRef.current.duration);
            }
          }}
          onPause={() => sendProgress(false)}
          onEnded={() => {
            sendProgress(true);
            if (pb?.next_episode) {
              navigate(`/play/${pb.next_episode.id}`, { replace: true });
            }
          }}
        >
          {activeSubBlobUrl && (
            <track key={`${activeSubId}-${subOffsetSec}`} kind="subtitles" src={activeSubBlobUrl} default label="字幕" />
          )}
        </video>

        {showSkipIntro && (
          <button
            type="button"
            className="player-skip-pill"
            onClick={() => {
              if (videoRef.current) videoRef.current.currentTime = introEnd;
            }}
          >
            <FastForward size={14} style={{ marginRight: 6, verticalAlign: 'middle' }} />
            跳过片头
          </button>
        )}

        {showNextEpPrompt && pb?.next_episode && (
          <button
            type="button"
            className="player-skip-pill"
            onClick={() => {
              sendProgress(true);
              navigate(`/play/${pb.next_episode!.id}`, { replace: true });
            }}
          >
            <SkipForward size={14} style={{ marginRight: 6, verticalAlign: 'middle' }} />
            即将结束 · 立即播放下一集
          </button>
        )}
      </div>

      {/* Compatibility warning banner */}
      {isSelectedOriginal && activeVersion && !activeVersion.browser_compatible && (
        <div
          style={{
            padding: '10px 20px',
            background: 'rgba(245, 185, 66, 0.14)',
            borderTop: '1px solid rgba(245, 185, 66, 0.35)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            flexWrap: 'wrap',
            gap: 10,
            fontSize: 13,
          }}
        >
          <span style={{ color: '#ffd984' }}>{activeVersion.compat_warning}</span>
          <div className="flex-row">
            {activeVersion.variants && activeVersion.variants.length > 0 && (
              <button
                type="button"
                className="btn btn-primary btn-sm"
                onClick={() =>
                  switchStream(activeVersion.variants![0].stream_url, activeVersion.variants![0].is_hls)
                }
              >
                切换为 {activeVersion.variants[0].label}
              </button>
            )}
            {pb?.external_players?.potplayer && (
              <a href={pb.external_players.potplayer} className="btn btn-sm">
                <ExternalLink size={13} />
                PotPlayer 打开
              </a>
            )}
            {pb?.external_players?.vlc && (
              <a href={pb.external_players.vlc} className="btn btn-sm">
                VLC 打开
              </a>
            )}
          </div>
        </div>
      )}

      {/* Control Bar: Version, Quality, Subtitles, Speed, External Player */}
      <div className="player-controls-bar">
        {pb && pb.versions.length > 1 && (
          <div className="flex-row">
            <span className="muted-sm">文件版本：</span>
            <select
              className="select"
              style={{ width: 'auto', padding: '5px 10px', fontSize: 12 }}
              value={selectedFileId}
              onChange={(e) => {
                const nextId = Number(e.target.value);
                const ver = pb.versions.find((v) => v.file.id === nextId);
                if (ver) {
                  const useTranscode =
                    (pb.web_prefer_cloud_transcode || !ver.browser_compatible) &&
                    ver.variants &&
                    ver.variants.length > 0;
                  switchStream(
                    useTranscode ? ver.variants![0].stream_url : ver.stream_url,
                    Boolean(useTranscode && ver.variants![0].is_hls),
                    nextId
                  );
                }
              }}
            >
              {pb.versions.map((v) => (
                <option key={v.file.id} value={v.file.id}>
                  [{mountKindLabel(v.file.mount_kind)}] {v.file.version_label || v.file.file_name}
                </option>
              ))}
            </select>
          </div>
        )}

        {activeVersion && (
          <div className="flex-row">
            <span className="muted-sm">清晰度：</span>
            <button
              type="button"
              className={`chip ${isSelectedOriginal ? 'active' : ''}`}
              onClick={() => switchStream(activeVersion.stream_url, false)}
            >
              原画直传
            </button>
            {(activeVersion.variants || []).map((v) => (
              <button
                key={v.id}
                type="button"
                className={`chip ${selectedStreamUrl === v.stream_url ? 'active' : ''}`}
                onClick={() => switchStream(v.stream_url, v.is_hls)}
              >
                {v.label}
              </button>
            ))}
          </div>
        )}

        <div className="flex-row">
          <Captions size={15} className="muted" />
          <select
            className="select"
            style={{ width: 'auto', maxWidth: 200, padding: '5px 10px', fontSize: 12 }}
            value={activeSubId}
            onChange={(e) => {
              setActiveSubId(e.target.value);
              setSubOffsetSec(0);
            }}
          >
            <option value="">关闭字幕</option>
            {allSubTracks.map((t) => (
              <option key={t.id} value={t.id}>
                {t.label}
              </option>
            ))}
          </select>

          <label className="btn btn-sm" style={{ cursor: 'pointer' }}>
            <Upload size={13} />
            上传字幕
            <input type="file" accept=".srt,.vtt,.ass,.ssa" hidden onChange={(e) => void handleUploadSubtitle(e)} />
          </label>

          {activeSubId && (
            <>
              <button type="button" className="btn btn-sm" onClick={() => setSubOffsetSec((s) => Number((s - 0.5).toFixed(1)))}>
                字幕 -0.5s
              </button>
              <span className="muted-sm">{subOffsetSec > 0 ? `+${subOffsetSec}s` : `${subOffsetSec}s`}</span>
              <button type="button" className="btn btn-sm" onClick={() => setSubOffsetSec((s) => Number((s + 0.5).toFixed(1)))}>
                +0.5s
              </button>
              <select
                className="select"
                style={{ width: 84, padding: '4px 8px', fontSize: 12 }}
                value={subFontSizePct}
                onChange={(e) => setSubFontSizePct(Number(e.target.value))}
              >
                <option value={85}>小字</option>
                <option value={100}>标准</option>
                <option value={125}>大字</option>
                <option value={150}>超大</option>
              </select>
            </>
          )}
        </div>

        <div className="flex-row" style={{ marginLeft: 'auto' }}>
          <select
            className="select"
            style={{ width: 82, padding: '5px 8px', fontSize: 12 }}
            value={speed}
            onChange={(e) => setSpeed(Number(e.target.value))}
          >
            <option value={0.75}>0.75x</option>
            <option value={1}>1.0x</option>
            <option value={1.25}>1.25x</option>
            <option value={1.5}>1.5x</option>
            <option value={2}>2.0x</option>
          </select>

          {pb?.external_players?.potplayer && (
            <a href={pb.external_players.potplayer} className="btn btn-sm">
              PotPlayer
            </a>
          )}
          {pb?.external_players?.vlc && (
            <a href={pb.external_players.vlc} className="btn btn-sm">
              VLC
            </a>
          )}
          {pb?.external_players?.iina && (
            <a href={pb.external_players.iina} className="btn btn-sm">
              IINA
            </a>
          )}
        </div>
      </div>

      {showEpisodes && seasonEpisodes.length > 0 && (
        <div className="card-box" style={{ margin: 16 }}>
          <div className="flex-row" style={{ justifyContent: 'space-between', marginBottom: 10 }}>
            <strong>剧集列表</strong>
            <span className="muted-sm">当前播放进度 {formatDurationMs(currentTimeSec * 1000)}</span>
          </div>
          <div className="grid-3">
            {seasonEpisodes.map((ep) => (
              <button
                key={ep.id}
                type="button"
                className={`nav-item ${ep.id === pb?.item?.id ? 'active' : ''}`}
                style={{ border: '1px solid var(--border-subtle)', justifyContent: 'space-between' }}
                onClick={() => {
                  sendProgress(true);
                  navigate(`/play/${ep.id}`, { replace: true });
                }}
              >
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  S{ep.season_number || 1}E{ep.episode_number || 1} · {ep.title}
                </span>
                <ChevronRight size={14} />
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};
