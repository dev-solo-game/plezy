import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Hls from 'hls.js';
import {
  ArrowLeft,
  Captions,
  Check,
  Copy,
  ExternalLink,
  FastForward,
  Layers,
  ListVideo,
  Loader2,
  Maximize,
  Minimize,
  Pause,
  PictureInPicture2,
  Play,
  RotateCcw,
  RotateCw,
  SkipBack,
  SkipForward,
  Sliders,
  Upload,
  Volume2,
  VolumeX,
  X,
} from 'lucide-react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { api, formatDurationMs } from '../api/client';
import { WorkSkipModal } from '../components/WorkSkipModal';
import { useApp } from '../contexts/AppContext';
import type { WorkPrefs } from '../types';
import {
  fromExternalPlayback,
  fromLocalPlayback,
  type NormalizedPlayerData,
  type NormalizedVersion,
} from '../utils/playerAdapter';

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

function formatClockHHMM(dateMs: number): string {
  const d = new Date(dateMs);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

function qualityButtonLabel(variantId?: string, fallbackLabel?: string): string {
  if (!variantId) return '原画';
  switch (variantId.toLowerCase()) {
    case '4k':
      return '4K';
    case '2k':
      return '2K';
    case 'super':
      return '超清';
    case 'high':
      return '高清';
    case 'normal':
      return '标清';
    case 'low':
      return '流畅';
    case 'auto':
      return '自适应';
    case '1080p_20m':
    case '1080p':
      return '1080p';
    case '720p':
    case '720p_2m':
      return '720p';
    case '480p':
      return '480p';
    default:
      return fallbackLabel || variantId.toUpperCase();
  }
}

function qualityRowTitle(v: { id: string; label: string }): string {
  switch (v.id.toLowerCase()) {
    case '4k':
      return '4K';
    case '2k':
      return '2K';
    case 'super':
      return '超清';
    case 'high':
      return '高清';
    case 'normal':
      return '标清';
    case 'low':
      return '流畅';
    default:
      return v.label;
  }
}

function formatRes(w?: number, h?: number): string {
  return w && w > 0 && h && h > 0 ? `${w}×${h}` : '';
}

interface SubTrackItem {
  id: string;
  label: string;
  vttUrl: string;
  rawVtt?: string;
}

type DrawerTab = 'quality' | 'subtitle' | 'episodes' | 'settings' | null;

export const PlayerPage: React.FC = () => {
  const { itemId, fileId, serverId, extItemId } = useParams();
  const isExt = Boolean(serverId && extItemId);
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const { toasts, toast } = useApp();

  const videoRef = useRef<HTMLVideoElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const timelineRef = useRef<HTMLDivElement | null>(null);
  const hlsRef = useRef<Hls | null>(null);
  const pendingSeekRef = useRef<number | null>(null);
  const lastSavedSecRef = useRef<number>(0);
  const extStartedRef = useRef<boolean>(false);
  const hudTimerRef = useRef<number | null>(null);
  const clickTimerRef = useRef<number | null>(null);
  const osdTimerRef = useRef<number | null>(null);

  const [pb, setPb] = useState<NormalizedPlayerData | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedVersionKey, setSelectedVersionKey] = useState<string>('');
  const [selectedStreamUrl, setSelectedStreamUrl] = useState<string>('');
  const [selectedIsHls, setSelectedIsHls] = useState<boolean>(false);

  // Playback telemetry & controls state
  const [isPlaying, setIsPlaying] = useState(false);
  const [isBuffering, setIsBuffering] = useState(false);
  const [currentTimeSec, setCurrentTimeSec] = useState(0);
  const [durationSec, setDurationSec] = useState(0);
  const [bufferedEndSec, setBufferedEndSec] = useState(0);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [speed, setSpeed] = useState<number>(1);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [videoFitCover, setVideoFitCover] = useState(false);
  const [videoDim, setVideoDim] = useState<{ w: number; h: number }>({ w: 0, h: 0 });
  const [showRemaining, setShowRemaining] = useState(false);
  const [clockText, setClockText] = useState(() => formatClockHHMM(Date.now()));

  // HUD & Drawer
  const [hudVisible, setHudVisible] = useState(true);
  const [drawerTab, setDrawerTab] = useState<DrawerTab>(null);
  const [compatDismissed, setCompatDismissed] = useState(false);
  const [osdText, setOsdText] = useState('');
  const [showSkipModal, setShowSkipModal] = useState(false);

  // Seekbar interaction
  const [scrubbing, setScrubbing] = useState(false);
  const [scrubSec, setScrubSec] = useState<number | null>(null);
  const [hoverTime, setHoverTime] = useState<{ sec: number; pct: number } | null>(null);

  // Subtitles
  const [localSubs, setLocalSubs] = useState<SubTrackItem[]>([]);
  const [activeSubId, setActiveSubId] = useState<string>('');
  const [activeSubBlobUrl, setActiveSubBlobUrl] = useState<string>('');
  const [subOffsetSec, setSubOffsetSec] = useState<number>(0);
  const [subFontSizePct, setSubFontSizePct] = useState<number>(100);
  const [serverSubVttCache, setServerSubVttCache] = useState<Record<string, string>>({});

  // Episodes drawer
  const [selectedSeasonNum, setSelectedSeasonNum] = useState<number>(1);

  const requestedFileId = Number(searchParams.get('file_id') || 0);
  const requestedSourceId = searchParams.get('source_id') || '';

  const showOsd = useCallback((text: string) => {
    setOsdText(text);
    if (osdTimerRef.current !== null) {
      window.clearTimeout(osdTimerRef.current);
    }
    osdTimerRef.current = window.setTimeout(() => {
      osdTimerRef.current = null;
      setOsdText('');
    }, 850);
  }, []);

  const kickHudTimer = useCallback(() => {
    setHudVisible(true);
    if (hudTimerRef.current !== null) {
      window.clearTimeout(hudTimerRef.current);
      hudTimerRef.current = null;
    }
    if (isPlaying && !scrubbing && !drawerTab && !showSkipModal) {
      hudTimerRef.current = window.setTimeout(() => {
        hudTimerRef.current = null;
        setHudVisible(false);
      }, 3000);
    }
  }, [isPlaying, scrubbing, drawerTab, showSkipModal]);

  useEffect(() => {
    kickHudTimer();
    return () => {
      if (hudTimerRef.current !== null) {
        window.clearTimeout(hudTimerRef.current);
      }
    };
  }, [kickHudTimer]);

  // System clock tick every 15s
  useEffect(() => {
    const t = window.setInterval(() => setClockText(formatClockHHMM(Date.now())), 15000);
    return () => window.clearInterval(t);
  }, []);

  // Track fullscreen changes
  useEffect(() => {
    const onFs = () => setIsFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener('fullscreenchange', onFs);
    return () => document.removeEventListener('fullscreenchange', onFs);
  }, []);

  // Load playback metadata
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setCompatDismissed(false);
    setDrawerTab(null);
    extStartedRef.current = false;

    const loadNormalized = async (): Promise<NormalizedPlayerData> => {
      if (isExt && serverId && extItemId) {
        const res = await api.extGetPlaybackInfo(serverId, extItemId, requestedSourceId || undefined);
        return fromExternalPlayback(serverId, res);
      }
      const res = fileId
        ? await api.getPlaybackInfoFile(Number(fileId))
        : await api.getPlaybackInfoItem(Number(itemId), requestedFileId || undefined);
      let eps = [] as Awaited<ReturnType<typeof api.getItemDetail>>['detail']['episodes'];
      if (res.show?.id) {
        try {
          const d = await api.getItemDetail(res.show.id);
          eps = d.detail.episodes || [];
        } catch {
          eps = [];
        }
      }
      return fromLocalPlayback(res, eps || []);
    };

    loadNormalized()
      .then((norm) => {
        if (cancelled) return;
        setPb(norm);
        const vKey = norm.selectedVersionKey || norm.versions[0]?.key || '';
        setSelectedVersionKey(vKey);

        const ver = norm.versions.find((v) => v.key === vKey) || norm.versions[0];
        if (ver) {
          const preferTranscode =
            (norm.webPreferTranscode || !ver.browserCompatible) && ver.variants.length > 0;
          if (preferTranscode) {
            setSelectedStreamUrl(ver.variants[0].stream_url);
            setSelectedIsHls(ver.variants[0].is_hls);
          } else {
            setSelectedStreamUrl(ver.streamUrl);
            setSelectedIsHls(false);
          }
        }

        setSpeed(
          norm.workPrefs?.playback_speed && norm.workPrefs.playback_speed > 0
            ? norm.workPrefs.playback_speed
            : 1
        );
        pendingSeekRef.current = norm.resumePositionMs > 2000 ? norm.resumePositionMs / 1000 : null;
        setActiveSubId(norm.subtitles.length > 0 ? norm.subtitles[0].id : '');
        setSubOffsetSec(0);

        if (norm.episodeTag) {
          const m = norm.episodeTag.match(/^S(\d+)/);
          if (m) setSelectedSeasonNum(Number(m[1]) || 1);
        } else if (norm.episodes.length > 0) {
          setSelectedSeasonNum(norm.episodes[0].seasonNumber || 1);
        }
      })
      .catch((err) => {
        if (!cancelled) toast((err as Error).message, 'error');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [isExt, serverId, extItemId, itemId, fileId, requestedFileId, requestedSourceId, toast]);

  const activeVersion: NormalizedVersion | undefined = useMemo(
    () => pb?.versions.find((v) => v.key === selectedVersionKey) || pb?.versions[0],
    [pb, selectedVersionKey]
  );

  // Attach media stream / HLS.js
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !selectedStreamUrl) return;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    setIsBuffering(true);
    setVideoDim({ w: 0, h: 0 });
    const applySeekAndPlay = () => {
      video.playbackRate = speed;
      video.volume = volume;
      video.muted = muted;
      if (pendingSeekRef.current !== null && Number.isFinite(pendingSeekRef.current)) {
        video.currentTime = pendingSeekRef.current;
        pendingSeekRef.current = null;
      }
      void video.play().catch(() => {});
      if (pb?.mode === 'ext' && pb.extServerId && pb.extItemId && !extStartedRef.current) {
        extStartedRef.current = true;
        void api
          .extReportPlayback(pb.extServerId, {
            state: 'start',
            item_id: pb.extItemId,
            media_source_id: selectedVersionKey || undefined,
            play_session_id: pb.extPlaySessionId,
            position_ms: Math.max(0, Math.floor((video.currentTime || 0) * 1000)),
            is_paused: false,
            play_method: selectedIsHls ? 'Transcode' : 'DirectStream',
          })
          .catch(() => {});
      }
    };

    if (selectedIsHls && Hls.isSupported() && !video.canPlayType('application/vnd.apple.mpegurl')) {
      const hls = new Hls({ enableWorker: true });
      hlsRef.current = hls;
      hls.loadSource(selectedStreamUrl);
      hls.attachMedia(video);
      hls.on(Hls.Events.MANIFEST_PARSED, applySeekAndPlay);
      hls.on(Hls.Events.ERROR, (_ev, data) => {
        if (data.fatal) {
          setIsBuffering(false);
          toast(`HLS 播放出错 (${data.type})，可切回原画或使用外部播放器`, 'error');
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
    if (videoRef.current) videoRef.current.playbackRate = speed;
  }, [speed]);

  useEffect(() => {
    if (videoRef.current) {
      videoRef.current.volume = volume;
      videoRef.current.muted = muted;
    }
  }, [volume, muted]);

  // Save playback progress
  const sendProgress = useCallback(
    (keepalive = false, isStop = false) => {
      const v = videoRef.current;
      if (!pb || !v) return;
      const posMs = Math.floor(v.currentTime * 1000);
      const dur = v.duration;
      const durMs = Number.isFinite(dur) && dur > 0 ? Math.floor(dur * 1000) : undefined;

      if (pb.mode === 'ext' && pb.extServerId && pb.extItemId) {
        if (posMs < 1000 && !isStop) return;
        lastSavedSecRef.current = v.currentTime;
        void api
          .extReportPlayback(
            pb.extServerId,
            {
              state: isStop ? 'stop' : 'progress',
              item_id: pb.extItemId,
              media_source_id: selectedVersionKey || undefined,
              play_session_id: pb.extPlaySessionId,
              position_ms: posMs,
              is_paused: v.paused,
              play_method: selectedIsHls ? 'Transcode' : 'DirectStream',
            },
            keepalive
          )
          .catch(() => {});
        return;
      }

      if (!pb.itemIdNum || posMs < 1000) return;
      lastSavedSecRef.current = v.currentTime;
      const numFileId = Number(selectedVersionKey);
      void api
        .reportProgress(
          {
            item_id: pb.itemIdNum,
            file_id: Number.isFinite(numFileId) && numFileId > 0 ? numFileId : undefined,
            position_ms: posMs,
            duration_ms: durMs,
          },
          keepalive
        )
        .catch(() => {});
    },
    [pb, selectedVersionKey, selectedIsHls]
  );

  useEffect(() => {
    const t = window.setInterval(() => {
      const v = videoRef.current;
      if (v && !v.paused && Math.abs(v.currentTime - lastSavedSecRef.current) >= 4) {
        sendProgress(false, false);
      }
    }, 10000);
    const onPageHide = () => sendProgress(true, true);
    window.addEventListener('pagehide', onPageHide);
    return () => {
      window.clearInterval(t);
      window.removeEventListener('pagehide', onPageHide);
      sendProgress(true, true);
    };
  }, [sendProgress]);

  // Subtitles combined
  const allSubTracks: SubTrackItem[] = useMemo(() => {
    const srv: SubTrackItem[] = (pb?.subtitles || []).map((s) => ({
      id: s.id,
      label: s.label,
      vttUrl: s.vttUrl,
    }));
    return [...srv, ...localSubs];
  }, [pb?.subtitles, localSubs]);

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

  const togglePlayPause = useCallback(() => {
    const v = videoRef.current;
    if (!v) return;
    kickHudTimer();
    if (v.paused) {
      void v.play().catch(() => {});
      showOsd('继续播放');
    } else {
      v.pause();
      showOsd('已暂停');
    }
  }, [kickHudTimer, showOsd]);

  const seekBy = useCallback(
    (deltaSec: number) => {
      const v = videoRef.current;
      if (!v) return;
      kickHudTimer();
      const target = Math.max(0, Math.min(v.duration || v.currentTime + Math.abs(deltaSec), v.currentTime + deltaSec));
      v.currentTime = target;
      setCurrentTimeSec(target);
      showOsd(deltaSec >= 0 ? `前进 ${deltaSec} 秒` : `后退 ${Math.abs(deltaSec)} 秒`);
    },
    [kickHudTimer, showOsd]
  );

  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else {
      void stageRef.current?.requestFullscreen();
    }
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || showSkipModal) return;
      if (e.code === 'Space' || e.key === 'k' || e.key === 'K') {
        e.preventDefault();
        togglePlayPause();
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        seekBy(-10);
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        seekBy(10);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        setMuted(false);
        setVolume((vol) => {
          const next = Math.min(1, Number((vol + 0.1).toFixed(2)));
          showOsd(`音量 ${Math.round(next * 100)}%`);
          return next;
        });
        kickHudTimer();
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        setVolume((vol) => {
          const next = Math.max(0, Number((vol - 0.1).toFixed(2)));
          showOsd(`音量 ${Math.round(next * 100)}%`);
          return next;
        });
        kickHudTimer();
      } else if (e.key === 'm' || e.key === 'M') {
        setMuted((m) => {
          showOsd(!m ? '已静音' : '取消静音');
          return !m;
        });
        kickHudTimer();
      } else if (e.key === 'f' || e.key === 'F') {
        e.preventDefault();
        toggleFullscreen();
      } else if (e.key === 'c' || e.key === 'C') {
        setDrawerTab((t) => (t === 'subtitle' ? null : 'subtitle'));
      } else if (e.key === 'e' || e.key === 'E') {
        if ((pb?.episodes.length || 0) > 0) {
          setDrawerTab((t) => (t === 'episodes' ? null : 'episodes'));
        }
      } else if (e.key === 'Escape') {
        if (drawerTab) setDrawerTab(null);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [drawerTab, pb?.episodes.length, showSkipModal, togglePlayPause, seekBy, toggleFullscreen, showOsd, kickHudTimer]);

  // Scrubbar calculation
  const secFromClientX = (clientX: number) => {
    const el = timelineRef.current;
    if (!el || durationSec <= 0) return 0;
    const rect = el.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    return ratio * durationSec;
  };

  const handleTimelinePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.stopPropagation();
    if (durationSec <= 0) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    const sec = secFromClientX(e.clientX);
    setScrubbing(true);
    setScrubSec(sec);
    kickHudTimer();
  };

  const handleTimelinePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = timelineRef.current;
    if (!el || durationSec <= 0) return;
    const rect = el.getBoundingClientRect();
    const pct = Math.max(0, Math.min(100, ((e.clientX - rect.left) / rect.width) * 100));
    const sec = (pct / 100) * durationSec;
    setHoverTime({ sec, pct });
    if (scrubbing) {
      setScrubSec(sec);
    }
  };

  const handleTimelinePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!scrubbing) return;
    e.stopPropagation();
    const target = scrubSec ?? secFromClientX(e.clientX);
    setScrubbing(false);
    setScrubSec(null);
    if (videoRef.current) {
      videoRef.current.currentTime = target;
      setCurrentTimeSec(target);
    }
    kickHudTimer();
  };

  const handleStageClick = () => {
    if (drawerTab) {
      setDrawerTab(null);
      return;
    }
    if (clickTimerRef.current !== null) {
      window.clearTimeout(clickTimerRef.current);
      clickTimerRef.current = null;
    }
    clickTimerRef.current = window.setTimeout(() => {
      clickTimerRef.current = null;
      togglePlayPause();
    }, 200);
  };

  const handleStageDoubleClick = () => {
    if (clickTimerRef.current !== null) {
      window.clearTimeout(clickTimerRef.current);
      clickTimerRef.current = null;
    }
    toggleFullscreen();
  };

  const switchStream = (url: string, isHls: boolean, nextVersionKey?: string) => {
    if (videoRef.current) {
      pendingSeekRef.current = videoRef.current.currentTime;
    }
    if (nextVersionKey && nextVersionKey !== selectedVersionKey) {
      setSelectedVersionKey(nextVersionKey);
      setSearchParams(
        (prev) => {
          const p = new URLSearchParams(prev);
          p.set(isExt ? 'source_id' : 'file_id', nextVersionKey);
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

  const togglePiP = async () => {
    const v = videoRef.current;
    if (!v) return;
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (v.requestPictureInPicture) {
        await v.requestPictureInPicture();
      }
    } catch {
      toast('当前浏览器不支持画中画', 'error');
    }
  };

  // Intro & Credits calculations
  const wp = pb?.workPrefs;
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
    pb?.nextEpisode && creditsThreshold > 0 && currentTimeSec >= creditsThreshold && currentTimeSec < durationSec
  );

  // Derived labels & stats
  const mainTitle = pb?.title || '视频播放';
  const subParts: string[] = [];
  if (pb?.episodeTag) {
    subParts.push(pb.episodeTag);
    if (pb.episodeTitle) subParts.push(pb.episodeTitle);
  }
  const activeVariant = activeVersion?.variants?.find((v) => v.stream_url === selectedStreamUrl);
  const activeQualityShort = qualityButtonLabel(activeVariant?.id, activeVariant?.label);
  const activeQualityTitle = activeVariant ? qualityRowTitle(activeVariant) : '原画';
  const activeRes =
    formatRes(videoDim.w, videoDim.h) ||
    (activeVariant
      ? formatRes(activeVariant.width, activeVariant.height)
      : formatRes(activeVersion?.width, activeVersion?.height));
  if (activeVersion?.mountLabel) {
    subParts.push(activeVersion.mountLabel);
  }
  subParts.push(activeRes ? `${activeQualityTitle} (${activeRes})` : activeQualityTitle);

  const displaySec = scrubSec ?? currentTimeSec;
  const progressPct = durationSec > 0 ? Math.min(100, (displaySec / durationSec) * 100) : 0;
  const bufferedPct = durationSec > 0 ? Math.min(100, (bufferedEndSec / durationSec) * 100) : 0;
  const finishAtText =
    durationSec > 0 && durationSec > displaySec
      ? `结束于 ${formatClockHHMM(Date.now() + ((durationSec - displaySec) / (speed || 1)) * 1000)}`
      : '';

  const episodesList = pb?.episodes || [];
  const activeEpId = pb?.mode === 'ext' ? pb.extItemId || '' : String(pb?.itemIdNum || '');

  const seasonNumbers = useMemo(() => {
    const nums = new Set<number>();
    for (const ep of episodesList) {
      nums.add(ep.seasonNumber || 1);
    }
    return Array.from(nums).sort((a, b) => a - b);
  }, [episodesList]);

  const filteredSeasonEpisodes = useMemo(
    () => episodesList.filter((ep) => (ep.seasonNumber || 1) === selectedSeasonNum),
    [episodesList, selectedSeasonNum]
  );

  const isSelectedOriginal = activeVersion?.streamUrl === selectedStreamUrl;
  const compatWarningText =
    !compatDismissed && isSelectedOriginal && activeVersion && !activeVersion.browserCompatible
      ? activeVersion.compatWarning
      : '';

  if (loading) {
    return (
      <div className="cinema-player" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div className="flex-row" style={{ gap: 10 }}>
          <Loader2 size={22} className="spin" style={{ color: 'var(--accent)' }} />
          <span className="muted">正在加载播放地址...</span>
        </div>
      </div>
    );
  }

  const toggleDrawer = (tab: Exclude<DrawerTab, null>) => {
    setDrawerTab((prev) => (prev === tab ? null : tab));
    kickHudTimer();
  };

  return (
    <div
      ref={stageRef}
      className={`cinema-player ${!hudVisible && isPlaying && !drawerTab ? 'hide-cursor' : ''}`}
      onMouseMove={kickHudTimer}
      onClick={handleStageClick}
      onDoubleClick={handleStageDoubleClick}
    >
      <style>{`video::cue { font-size: ${subFontSizePct}%; background: rgba(0, 0, 0, 0.56); color: #fff; text-shadow: 0 2px 6px rgba(0,0,0,0.95); }`}</style>

      <video
        ref={videoRef}
        className={`cinema-video ${videoFitCover ? 'fit-cover' : ''}`}
        playsInline
        crossOrigin="use-credentials"
        onPlay={() => {
          setIsPlaying(true);
          setIsBuffering(false);
        }}
        onPause={() => {
          setIsPlaying(false);
          sendProgress(false);
        }}
        onWaiting={() => setIsBuffering(true)}
        onPlaying={(e) => {
          setIsPlaying(true);
          setIsBuffering(false);
          const v = e.currentTarget;
          if (v.videoWidth > 0 && v.videoHeight > 0) {
            setVideoDim({ w: v.videoWidth, h: v.videoHeight });
          }
        }}
        onLoadedMetadata={(e) => {
          const v = e.currentTarget;
          if (v.videoWidth > 0 && v.videoHeight > 0) {
            setVideoDim({ w: v.videoWidth, h: v.videoHeight });
          }
        }}
        onCanPlay={(e) => {
          setIsBuffering(false);
          const v = e.currentTarget;
          if (v.videoWidth > 0 && v.videoHeight > 0) {
            setVideoDim({ w: v.videoWidth, h: v.videoHeight });
          }
        }}
        onProgress={() => {
          const v = videoRef.current;
          if (!v || v.buffered.length === 0) return;
          setBufferedEndSec(v.buffered.end(v.buffered.length - 1));
        }}
        onTimeUpdate={() => {
          const v = videoRef.current;
          if (!v) return;
          setCurrentTimeSec(v.currentTime);
          if (Number.isFinite(v.duration)) {
            setDurationSec(v.duration);
          }
        }}
        onEnded={() => {
          setIsPlaying(false);
          sendProgress(true, true);
          if (pb?.nextEpisode) {
            navigate(pb.nextEpisode.playRoute, { replace: true });
          }
        }}
      >
        {activeSubBlobUrl && (
          <track key={`${activeSubId}-${subOffsetSec}`} kind="subtitles" src={activeSubBlobUrl} default label="字幕" />
        )}
      </video>

      {/* Buffering spinner */}
      {isBuffering && (
        <div className="cinema-center-spinner">
          <Loader2 size={42} className="spin" style={{ color: 'var(--accent)' }} />
        </div>
      )}

      {/* Center OSD transient feedback */}
      {osdText && <div className="cinema-osd">{osdText}</div>}

      {/* Top HUD (Matches PC VideoControlsHeader) */}
      <div
        className={`cinema-hud-top ${hudVisible ? '' : 'hidden'}`}
        onClick={(e) => e.stopPropagation()}
        onDoubleClick={(e) => e.stopPropagation()}
      >
        <div className="flex-row" style={{ gap: 14, minWidth: 0, flex: 1 }}>
          <button
            type="button"
            className="cinema-ctrl-btn"
            style={{ width: 38, height: 38, padding: 0, borderRadius: '50%', background: 'rgba(255,255,255,0.1)' }}
            onClick={() => {
              sendProgress(true, true);
              navigate(-1);
            }}
            title="返回"
          >
            <ArrowLeft size={18} />
          </button>

          <div style={{ minWidth: 0 }}>
            <div
              style={{
                fontSize: 16,
                fontWeight: 700,
                color: '#fff',
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {mainTitle}
            </div>
            <div
              style={{
                fontSize: 12.5,
                color: 'rgba(255,255,255,0.68)',
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {subParts.join(' · ')}
            </div>
          </div>
        </div>

        <div className="flex-row" style={{ gap: 12 }}>
          <span style={{ fontSize: 14, fontWeight: 500, color: 'rgba(255,255,255,0.75)', fontVariantNumeric: 'tabular-nums' }}>
            {clockText}
          </span>
          {activeVersion?.hdrFormat && (
            <span className="tag dv">{activeVersion.hdrFormat}</span>
          )}
          {pb?.externalPlayers?.potplayer && (
            <a
              href={pb.externalPlayers.potplayer}
              className="cinema-ctrl-btn"
              style={{ background: 'rgba(255,255,255,0.08)' }}
              title="在 PotPlayer 中打开"
            >
              <ExternalLink size={14} />
              <span className="cinema-ctrl-label">PotPlayer</span>
            </a>
          )}
        </div>
      </div>

      {/* Compatibility warning bar */}
      {compatWarningText && (
        <div
          className="cinema-compat-toast"
          onClick={(e) => e.stopPropagation()}
          onDoubleClick={(e) => e.stopPropagation()}
        >
          <span>{compatWarningText}</span>
          <div className="flex-row" style={{ gap: 8 }}>
            {activeVersion?.variants && activeVersion.variants.length > 0 && (
              <button
                type="button"
                className="btn btn-primary btn-sm"
                onClick={() => switchStream(activeVersion.variants![0].stream_url, activeVersion.variants![0].is_hls)}
              >
                切至 {qualityRowTitle(activeVersion.variants[0])}
              </button>
            )}
            <button type="button" className="btn btn-sm" onClick={() => setCompatDismissed(true)}>
              知道了
            </button>
          </div>
        </div>
      )}

      {/* Floating Skip Intro / Next Episode Pill */}
      {showSkipIntro && (
        <button
          type="button"
          className="cinema-skip-pill"
          style={{ bottom: hudVisible ? 124 : 32 }}
          onClick={(e) => {
            e.stopPropagation();
            if (videoRef.current) videoRef.current.currentTime = introEnd;
            showOsd('已跳过片头');
          }}
        >
          <FastForward size={15} />
          跳过片头 ({formatDurationMs(introEnd * 1000)})
        </button>
      )}

      {showNextEpPrompt && pb?.nextEpisode && (
        <button
          type="button"
          className="cinema-skip-pill"
          style={{ bottom: hudVisible ? 124 : 32 }}
          onClick={(e) => {
            e.stopPropagation();
            sendProgress(true, true);
            navigate(pb.nextEpisode!.playRoute, { replace: true });
          }}
        >
          <SkipForward size={15} />
          播放下一集 · S{pb.nextEpisode.seasonNumber}E{pb.nextEpisode.episodeNumber}
        </button>
      )}

      {/* Right Glass Drawer (Quality / Subtitles / Episodes / Settings) */}
      {drawerTab && (
        <div
          className="cinema-drawer"
          onClick={(e) => e.stopPropagation()}
          onDoubleClick={(e) => e.stopPropagation()}
        >
          <div className="cinema-drawer-header">
            <strong style={{ fontSize: 14 }}>
              {drawerTab === 'quality'
                ? '画质与片源'
                : drawerTab === 'subtitle'
                ? '字幕设置'
                : drawerTab === 'episodes'
                ? `选集列表 (${episodesList.length})`
                : '画面与播放设置'}
            </strong>
            <button
              type="button"
              className="btn btn-icon btn-sm"
              style={{ width: 28, height: 28, padding: 0 }}
              onClick={() => setDrawerTab(null)}
            >
              <X size={14} />
            </button>
          </div>

          <div className="cinema-drawer-body">
            {drawerTab === 'quality' && activeVersion && (
              <>
                <div>
                  <div className="muted-sm" style={{ marginBottom: 8 }}>画质选择</div>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    <button
                      type="button"
                      className={`cinema-drawer-item ${isSelectedOriginal ? 'active' : ''}`}
                      onClick={() => {
                        switchStream(activeVersion.streamUrl, false);
                        showOsd('已切换至 原画');
                      }}
                    >
                      <span>原画</span>
                      <span className="flex-row" style={{ gap: 8 }}>
                        {(formatRes(activeVersion.width, activeVersion.height) ||
                          (isSelectedOriginal ? formatRes(videoDim.w, videoDim.h) : '')) && (
                          <span className="muted-sm" style={{ fontSize: 12, fontVariantNumeric: 'tabular-nums' }}>
                            {formatRes(activeVersion.width, activeVersion.height) ||
                              (isSelectedOriginal ? formatRes(videoDim.w, videoDim.h) : '')}
                          </span>
                        )}
                        {isSelectedOriginal && <Check size={14} />}
                      </span>
                    </button>
                    {(activeVersion.variants || []).map((v) => {
                      const active = selectedStreamUrl === v.stream_url;
                      const resLabel = formatRes(v.width, v.height) || (active ? formatRes(videoDim.w, videoDim.h) : '');
                      const rowTitle = qualityRowTitle(v);
                      return (
                        <button
                          key={v.id}
                          type="button"
                          className={`cinema-drawer-item ${active ? 'active' : ''}`}
                          onClick={() => {
                            switchStream(v.stream_url, v.is_hls);
                            showOsd(`已切换至 ${rowTitle}`);
                          }}
                        >
                          <span>{rowTitle}</span>
                          <span className="flex-row" style={{ gap: 8 }}>
                            {resLabel && (
                              <span className="muted-sm" style={{ fontSize: 12, fontVariantNumeric: 'tabular-nums' }}>
                                {resLabel}
                              </span>
                            )}
                            {active && <Check size={14} />}
                          </span>
                        </button>
                      );
                    })}
                    {(activeVersion.variants?.length || 0) === 0 && (
                      <div className="muted-sm" style={{ fontSize: 12, padding: '4px 2px' }}>
                        当前文件暂无转码档位，直接播放原画
                      </div>
                    )}
                  </div>
                </div>

                {pb && pb.versions.length > 1 && (
                  <div>
                    <div className="muted-sm" style={{ marginBottom: 8 }}>多文件 / 片源版本</div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {pb.versions.map((v) => {
                        const active = v.key === selectedVersionKey;
                        return (
                          <button
                            key={v.key}
                            type="button"
                            className={`cinema-drawer-item ${active ? 'active' : ''}`}
                            onClick={() => {
                              const useTranscode =
                                (pb.webPreferTranscode || !v.browserCompatible) &&
                                v.variants &&
                                v.variants.length > 0;
                              switchStream(
                                useTranscode ? v.variants[0].stream_url : v.streamUrl,
                                Boolean(useTranscode && v.variants[0].is_hls),
                                v.key
                              );
                            }}
                          >
                            <div style={{ minWidth: 0 }}>
                              <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                                {v.label}
                              </div>
                              <div className="muted-sm" style={{ fontSize: 11 }}>
                                {v.meta}
                              </div>
                            </div>
                            {active && <Check size={14} />}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                )}

                {pb?.externalPlayers && Object.keys(pb.externalPlayers).length > 0 && (
                  <div>
                    <div className="muted-sm" style={{ marginBottom: 8 }}>外部播放器打开</div>
                    <div className="flex-row" style={{ gap: 6 }}>
                      {(['potplayer', 'vlc', 'iina', 'mpv'] as const).map(
                        (p) =>
                          pb.externalPlayers[p] && (
                            <a key={p} href={pb.externalPlayers[p]} className="btn btn-sm">
                              {p.toUpperCase()}
                            </a>
                          )
                      )}
                      {pb.externalPlayers.direct && (
                        <button
                          type="button"
                          className="btn btn-sm"
                          onClick={() => {
                            if (pb?.externalPlayers?.direct) {
                              void navigator.clipboard.writeText(pb.externalPlayers.direct);
                              toast('已复制 12 小时签名直链', 'success');
                            }
                          }}
                        >
                          <Copy size={12} />
                          复制直链
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </>
            )}

            {drawerTab === 'subtitle' && (
              <>
                <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                  <span className="muted-sm">选择字幕轨道</span>
                  <label className="btn btn-sm" style={{ cursor: 'pointer', padding: '4px 10px', fontSize: 12 }}>
                    <Upload size={12} />
                    挂载本地字幕
                    <input type="file" accept=".srt,.vtt,.ass,.ssa" hidden onChange={(e) => void handleUploadSubtitle(e)} />
                  </label>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <button
                    type="button"
                    className={`cinema-drawer-item ${!activeSubId ? 'active' : ''}`}
                    onClick={() => {
                      setActiveSubId('');
                      setSubOffsetSec(0);
                    }}
                  >
                    <span>关闭字幕</span>
                    {!activeSubId && <Check size={14} />}
                  </button>
                  {allSubTracks.map((t) => {
                    const active = activeSubId === t.id;
                    return (
                      <button
                        key={t.id}
                        type="button"
                        className={`cinema-drawer-item ${active ? 'active' : ''}`}
                        onClick={() => {
                          setActiveSubId(t.id);
                          setSubOffsetSec(0);
                        }}
                      >
                        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {t.label}
                        </span>
                        {active && <Check size={14} />}
                      </button>
                    );
                  })}
                </div>

                {activeSubId && (
                  <>
                    <div>
                      <div className="muted-sm" style={{ marginBottom: 6 }}>
                        时间轴微调（当前 {subOffsetSec > 0 ? `+${subOffsetSec}s` : `${subOffsetSec}s`}）
                      </div>
                      <div className="flex-row" style={{ gap: 6 }}>
                        <button type="button" className="btn btn-sm" onClick={() => setSubOffsetSec((s) => Number((s - 0.5).toFixed(1)))}>
                          -0.5s
                        </button>
                        <button type="button" className="btn btn-sm" onClick={() => setSubOffsetSec(0)}>
                          归零
                        </button>
                        <button type="button" className="btn btn-sm" onClick={() => setSubOffsetSec((s) => Number((s + 0.5).toFixed(1)))}>
                          +0.5s
                        </button>
                      </div>
                    </div>

                    <div>
                      <div className="muted-sm" style={{ marginBottom: 6 }}>字幕字号</div>
                      <div className="grid-2" style={{ gap: 6 }}>
                        {[
                          [85, '小字'],
                          [100, '标准'],
                          [125, '大字'],
                          [150, '超大'],
                        ].map(([pct, label]) => (
                          <button
                            key={pct}
                            type="button"
                            className={`cinema-drawer-item ${subFontSizePct === pct ? 'active' : ''}`}
                            style={{ padding: '7px 10px', justifyContent: 'center' }}
                            onClick={() => setSubFontSizePct(Number(pct))}
                          >
                            {label}
                          </button>
                        ))}
                      </div>
                    </div>
                  </>
                )}
              </>
            )}

            {drawerTab === 'episodes' && (
              <>
                {seasonNumbers.length > 1 && (
                  <div className="flex-row" style={{ gap: 6 }}>
                    {seasonNumbers.map((sn) => (
                      <button
                        key={sn}
                        type="button"
                        className={`chip ${selectedSeasonNum === sn ? 'active' : ''}`}
                        onClick={() => setSelectedSeasonNum(sn)}
                      >
                        第 {sn} 季
                      </button>
                    ))}
                  </div>
                )}

                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {filteredSeasonEpisodes.map((ep) => {
                    const active = ep.id === activeEpId;
                    const watched = ep.watched;
                    const pos = ep.positionMs;
                    return (
                      <button
                        key={ep.id}
                        type="button"
                        className={`cinema-drawer-item ${active ? 'active' : ''}`}
                        onClick={() => {
                          if (active) return;
                          sendProgress(true, true);
                          navigate(ep.playRoute, { replace: true });
                        }}
                      >
                        <div style={{ minWidth: 0 }}>
                          <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                            E{String(ep.episodeNumber || 1).padStart(2, '0')} · {ep.title}
                          </div>
                          {(watched || pos > 0) && (
                            <div className="muted-sm" style={{ fontSize: 11 }}>
                              {watched ? '已看完' : `已播 ${formatDurationMs(pos)}`}
                            </div>
                          )}
                        </div>
                        {active && <Play size={13} fill="currentColor" />}
                      </button>
                    );
                  })}
                </div>
              </>
            )}

            {drawerTab === 'settings' && (
              <>
                <div>
                  <div className="muted-sm" style={{ marginBottom: 8 }}>播放倍速</div>
                  <div className="grid-3" style={{ gap: 6 }}>
                    {[0.5, 0.75, 1, 1.25, 1.5, 2].map((sp) => (
                      <button
                        key={sp}
                        type="button"
                        className={`cinema-drawer-item ${speed === sp ? 'active' : ''}`}
                        style={{ padding: '7px 8px', justifyContent: 'center' }}
                        onClick={() => {
                          setSpeed(sp);
                          showOsd(`${sp}x 倍速`);
                        }}
                      >
                        {sp}x
                      </button>
                    ))}
                  </div>
                </div>

                <div>
                  <div className="muted-sm" style={{ marginBottom: 8 }}>画面填充模式</div>
                  <div className="grid-2" style={{ gap: 6 }}>
                    <button
                      type="button"
                      className={`cinema-drawer-item ${!videoFitCover ? 'active' : ''}`}
                      style={{ justifyContent: 'center' }}
                      onClick={() => setVideoFitCover(false)}
                    >
                      适应画面
                    </button>
                    <button
                      type="button"
                      className={`cinema-drawer-item ${videoFitCover ? 'active' : ''}`}
                      style={{ justifyContent: 'center' }}
                      onClick={() => setVideoFitCover(true)}
                    >
                      铺满裁切
                    </button>
                  </div>
                </div>

                {pb?.mode === 'local' && pb.workKey && (
                  <div>
                    <div className="muted-sm" style={{ marginBottom: 8 }}>片头 / 片尾跳过</div>
                    <button
                      type="button"
                      className="btn btn-sm"
                      style={{ width: '100%' }}
                      onClick={() => {
                        setDrawerTab(null);
                        setShowSkipModal(true);
                      }}
                    >
                      <FastForward size={14} />
                      配置本作品片头片尾区间
                    </button>
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      )}

      {/* Bottom HUD (Matches PC DesktopVideoControls) */}
      <div
        className={`cinema-hud-bottom ${hudVisible ? '' : 'hidden'}`}
        onClick={(e) => e.stopPropagation()}
        onDoubleClick={(e) => e.stopPropagation()}
      >
        {/* Custom Timeline Bar */}
        <div className="cinema-timeline-wrap">
          <span style={{ minWidth: 50, textAlign: 'right' }}>
            {formatDurationMs(displaySec * 1000)}
          </span>

          <div
            ref={timelineRef}
            className={`cinema-timeline ${scrubbing ? 'scrubbing' : ''}`}
            onPointerDown={handleTimelinePointerDown}
            onPointerMove={handleTimelinePointerMove}
            onPointerUp={handleTimelinePointerUp}
            onPointerLeave={() => setHoverTime(null)}
          >
            <div className="cinema-timeline-track">
              <div className="cinema-timeline-buffered" style={{ width: `${bufferedPct}%` }} />
              {wp?.intro_enabled && durationSec > 0 && introEnd > introStart && (
                <div
                  className="cinema-timeline-marker"
                  style={{
                    left: `${Math.max(0, (introStart / durationSec) * 100)}%`,
                    width: `${Math.min(100, ((introEnd - introStart) / durationSec) * 100)}%`,
                  }}
                />
              )}
              {wp?.credits_enabled && durationSec > 0 && creditsThreshold > 0 && creditsThreshold < durationSec && (
                <div
                  className="cinema-timeline-marker"
                  style={{
                    left: `${(creditsThreshold / durationSec) * 100}%`,
                    width: `${((durationSec - creditsThreshold) / durationSec) * 100}%`,
                  }}
                />
              )}
              <div className="cinema-timeline-fill" style={{ width: `${progressPct}%` }} />
              <div className="cinema-timeline-thumb" style={{ left: `${progressPct}%` }} />
            </div>

            {hoverTime && (
              <div className="cinema-timeline-tooltip" style={{ left: `${hoverTime.pct}%` }}>
                {formatDurationMs(hoverTime.sec * 1000)}
              </div>
            )}
          </div>

          <button
            type="button"
            className="cinema-time-btn"
            onClick={() => setShowRemaining((v) => !v)}
            title="点击切换 总时长 / 剩余时间"
          >
            {showRemaining && durationSec > 0
              ? `-${formatDurationMs(Math.max(0, durationSec - displaySec) * 1000)}`
              : formatDurationMs(durationSec * 1000)}
          </button>
        </div>

        {/* Bottom Button Row */}
        <div className="cinema-controls-row">
          <div className="cinema-controls-left">
            <button
              type="button"
              className="cinema-ctrl-btn"
              disabled={!pb?.prevEpisode}
              onClick={() => {
                if (!pb?.prevEpisode) return;
                sendProgress(true, true);
                navigate(pb.prevEpisode.playRoute, { replace: true });
              }}
              title="上一集"
            >
              <SkipBack size={18} />
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn"
              onClick={() => seekBy(-10)}
              title="后退 10 秒 (←)"
            >
              <RotateCcw size={18} />
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn cinema-play-btn"
              onClick={togglePlayPause}
              title={isPlaying ? '暂停 (Space)' : '播放 (Space)'}
            >
              {isPlaying ? <Pause size={20} fill="currentColor" /> : <Play size={20} fill="currentColor" style={{ marginLeft: 2 }} />}
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn"
              onClick={() => seekBy(10)}
              title="前进 10 秒 (→)"
            >
              <RotateCw size={18} />
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn"
              disabled={!pb?.nextEpisode}
              onClick={() => {
                if (!pb?.nextEpisode) return;
                sendProgress(true, true);
                navigate(pb.nextEpisode.playRoute, { replace: true });
              }}
              title="下一集"
            >
              <SkipForward size={18} />
            </button>

            {finishAtText && (
              <span className="cinema-finish-time" style={{ marginLeft: 10, fontSize: 13, color: 'rgba(255,255,255,0.68)' }}>
                {finishAtText}
              </span>
            )}
          </div>

          <div className="cinema-controls-right">
            <button
              type="button"
              className="cinema-ctrl-btn"
              onClick={() => setMuted((m) => !m)}
              title="静音 (M)"
            >
              {muted || volume === 0 ? <VolumeX size={17} /> : <Volume2 size={17} />}
            </button>

            <input
              type="range"
              min={0}
              max={1}
              step={0.02}
              value={muted ? 0 : volume}
              className="cinema-volume-slider"
              onChange={(e) => {
                setMuted(false);
                setVolume(Number(e.target.value));
              }}
              title="音量"
            />

            <button
              type="button"
              className={`cinema-ctrl-btn ${drawerTab === 'quality' ? 'active' : ''}`}
              onClick={() => toggleDrawer('quality')}
              title="清晰度与版本"
            >
              <Layers size={16} />
              <span className="cinema-ctrl-label">{activeQualityShort}</span>
            </button>

            <button
              type="button"
              className={`cinema-ctrl-btn ${drawerTab === 'subtitle' ? 'active' : ''}`}
              onClick={() => toggleDrawer('subtitle')}
              title="字幕 (C)"
            >
              <Captions size={16} />
              <span className="cinema-ctrl-label">字幕</span>
            </button>

            {episodesList.length > 0 && (
              <button
                type="button"
                className={`cinema-ctrl-btn ${drawerTab === 'episodes' ? 'active' : ''}`}
                onClick={() => toggleDrawer('episodes')}
                title="选集 (E)"
              >
                <ListVideo size={16} />
                <span className="cinema-ctrl-label">选集</span>
              </button>
            )}

            <button
              type="button"
              className={`cinema-ctrl-btn ${drawerTab === 'settings' ? 'active' : ''}`}
              onClick={() => toggleDrawer('settings')}
              title="倍速与设置"
            >
              <Sliders size={15} />
              <span className="cinema-ctrl-label">{speed}x</span>
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn"
              onClick={() => void togglePiP()}
              title="画中画"
            >
              <PictureInPicture2 size={16} />
            </button>

            <button
              type="button"
              className="cinema-ctrl-btn"
              onClick={toggleFullscreen}
              title="全屏 (F)"
            >
              {isFullscreen ? <Minimize size={17} /> : <Maximize size={17} />}
            </button>
          </div>
        </div>
      </div>

      {showSkipModal && pb?.mode === 'local' && pb.workKey && (
        <WorkSkipModal
          workKey={pb.workKey}
          initialPrefs={wp}
          onClose={() => setShowSkipModal(false)}
          onSaved={(saved: WorkPrefs) => {
            setPb((prev) => (prev ? { ...prev, workPrefs: saved } : prev));
            if (saved.playback_speed > 0) setSpeed(saved.playback_speed);
          }}
        />
      )}

      {toasts.length > 0 && (
        <div className="toast-stack" style={{ bottom: hudVisible ? 124 : 24 }}>
          {toasts.map((t) => (
            <div key={t.id} className={`toast-item ${t.kind || ''}`}>
              {t.text}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};
