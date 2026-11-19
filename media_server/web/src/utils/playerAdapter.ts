import { extServerKindLabel, formatBytes, mountKindLabel } from '../api/client';
import type { ExtPlaybackInfo, MediaItem, PlaybackInfo, PlaybackVariant, WorkPrefs } from '../types';

export interface NormalizedVersion {
  key: string;
  label: string;
  meta: string;
  mountLabel?: string;
  width?: number;
  height?: number;
  hdrFormat?: string;
  streamUrl: string;
  browserCompatible: boolean;
  compatWarning?: string;
  variants: PlaybackVariant[];
}

export interface NormalizedSubtitle {
  id: string;
  label: string;
  vttUrl: string;
}

export interface NormalizedEpisode {
  id: string;
  title: string;
  seasonNumber: number;
  episodeNumber: number;
  watched: boolean;
  positionMs: number;
  playRoute: string;
}

export interface NormalizedPlayerData {
  mode: 'local' | 'ext';
  title: string;
  episodeTag?: string;
  episodeTitle?: string;
  sourceLabel?: string;
  itemIdNum?: number;
  workKey?: string;
  workPrefs?: WorkPrefs;
  extServerId?: string;
  extItemId?: string;
  extPlaySessionId?: string;
  resumePositionMs: number;
  selectedVersionKey: string;
  versions: NormalizedVersion[];
  subtitles: NormalizedSubtitle[];
  episodes: NormalizedEpisode[];
  prevEpisode?: NormalizedEpisode;
  nextEpisode?: NormalizedEpisode;
  externalPlayers: Record<string, string>;
  webPreferTranscode: boolean;
}

export function fromLocalPlayback(pb: PlaybackInfo, episodesList: MediaItem[]): NormalizedPlayerData {
  const firstFile = pb.versions?.[0]?.file;
  const versions: NormalizedVersion[] = (pb.versions || []).map((v) => ({
    key: String(v.file.id),
    label: v.file.version_label || v.file.file_name || '原画',
    meta: `${mountKindLabel(v.file.mount_kind)} · ${formatBytes(v.file.size)}`,
    mountLabel: v.file.mount_kind ? mountKindLabel(v.file.mount_kind) : undefined,
    width: v.file.width,
    height: v.file.height,
    hdrFormat: v.file.hdr_format,
    streamUrl: v.stream_url,
    browserCompatible: v.browser_compatible,
    compatWarning: v.compat_warning,
    variants: v.variants || [],
  }));

  const mapLocalEp = (ep: MediaItem): NormalizedEpisode => ({
    id: String(ep.id),
    title: ep.title,
    seasonNumber: ep.season_number || 1,
    episodeNumber: ep.episode_number || 1,
    watched: Boolean(ep.watch_state?.watched),
    positionMs: ep.watch_state?.position_ms || 0,
    playRoute: `/play/${ep.id}`,
  });

  const selectedKey = String(pb.selected_file_id || firstFile?.id || '');

  return {
    mode: 'local',
    title: pb.show?.title || pb.item?.title || firstFile?.file_name || '视频播放',
    episodeTag:
      pb.show && pb.item
        ? `S${String(pb.item.season_number || 1).padStart(2, '0')}E${String(pb.item.episode_number || 1).padStart(2, '0')}`
        : undefined,
    episodeTitle: pb.show && pb.item ? pb.item.title : undefined,
    itemIdNum: pb.item?.id,
    workKey: pb.item?.work_key || pb.show?.work_key,
    workPrefs: pb.work_prefs,
    resumePositionMs: pb.resume_position_ms || 0,
    selectedVersionKey: selectedKey,
    versions,
    subtitles: (pb.subtitles || []).map((s) => ({
      id: `srv-${s.id}`,
      label: s.language ? `${s.file_name} (${s.language})` : s.file_name,
      vttUrl: s.vtt_url,
    })),
    episodes: episodesList.map(mapLocalEp),
    prevEpisode: pb.prev_episode ? mapLocalEp(pb.prev_episode) : undefined,
    nextEpisode: pb.next_episode ? mapLocalEp(pb.next_episode) : undefined,
    externalPlayers: pb.external_players || {},
    webPreferTranscode: Boolean(pb.web_prefer_cloud_transcode),
  };
}

export function fromExternalPlayback(serverId: string, pb: ExtPlaybackInfo): NormalizedPlayerData {
  const versions: NormalizedVersion[] = (pb.versions || []).map((v) => ({
    key: v.source_id,
    label: v.label || '原画',
    meta: `${extServerKindLabel(pb.server?.kind)} · ${v.size ? formatBytes(v.size) : v.container?.toUpperCase() || '流'}`,
    mountLabel: pb.server ? `${extServerKindLabel(pb.server.kind)} · ${pb.server.name}` : undefined,
    width: v.width,
    height: v.height,
    hdrFormat: v.hdr_format,
    streamUrl: v.stream_url,
    browserCompatible: v.browser_compatible,
    compatWarning: v.compat_warning,
    variants: v.variants || [],
  }));

  const mapExtEp = (ep: ExtPlaybackInfo['item']): NormalizedEpisode => ({
    id: ep.id,
    title: ep.title,
    seasonNumber: ep.season_number || 1,
    episodeNumber: ep.episode_number || 1,
    watched: Boolean(ep.watched),
    positionMs: ep.position_ms || 0,
    playRoute: `/play/ext/${encodeURIComponent(serverId)}/${encodeURIComponent(ep.id)}`,
  });

  return {
    mode: 'ext',
    title: pb.show?.title || pb.item?.series_name || pb.item?.title || '视频播放',
    episodeTag:
      pb.item?.kind === 'episode'
        ? `S${String(pb.item.season_number || 1).padStart(2, '0')}E${String(pb.item.episode_number || 1).padStart(2, '0')}`
        : undefined,
    episodeTitle: pb.item?.kind === 'episode' ? pb.item.title : undefined,
    sourceLabel: pb.server ? `${extServerKindLabel(pb.server.kind)} · ${pb.server.name}` : undefined,
    extServerId: serverId,
    extItemId: pb.item?.id,
    extPlaySessionId: pb.play_session_id,
    resumePositionMs: pb.resume_position_ms || 0,
    selectedVersionKey: pb.selected_source_id || versions[0]?.key || '',
    versions,
    subtitles: (pb.subtitles || []).map((s) => ({
      id: `ext-${s.index}`,
      label: s.language ? `${s.file_name} (${s.language})` : s.file_name,
      vttUrl: s.vtt_url,
    })),
    episodes: (pb.episodes || []).map(mapExtEp),
    prevEpisode: pb.prev_episode ? mapExtEp(pb.prev_episode) : undefined,
    nextEpisode: pb.next_episode ? mapExtEp(pb.next_episode) : undefined,
    externalPlayers: pb.external_players || {},
    webPreferTranscode: false,
  };
}
