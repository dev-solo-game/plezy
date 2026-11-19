import '../../services/companion_remote/lan_discovery_service.dart';

class RemoteMediaTarget {
  const RemoteMediaTarget({
    required this.kind,
    required this.title,
    this.seriesTitle,
    this.posterUrl,
    this.syncFileId,
    this.canonicalSourceKey,
    this.mountRelativePath,
    this.workKey,
    this.seasonNumber,
    this.episodeNumber,
    this.positionMs,
    this.playbackRate,
    this.streamQuality,
    this.remoteServerBackend,
    this.remoteServerId,
    this.remoteItemId,
  });

  final String kind; // 'movie' or 'episode'
  final String title;
  final String? seriesTitle;
  final String? posterUrl;
  final String? syncFileId;
  final String? canonicalSourceKey;
  final String? mountRelativePath;
  final String? workKey;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? positionMs;
  final double? playbackRate;
  final String? streamQuality;
  final String? remoteServerBackend;
  final String? remoteServerId;
  final String? remoteItemId;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'title': title,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (syncFileId != null) 'syncFileId': syncFileId,
    if (canonicalSourceKey != null) 'canonicalSourceKey': canonicalSourceKey,
    if (mountRelativePath != null) 'mountRelativePath': mountRelativePath,
    if (workKey != null) 'workKey': workKey,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    if (positionMs != null) 'positionMs': positionMs,
    if (playbackRate != null) 'playbackRate': playbackRate,
    if (streamQuality != null) 'streamQuality': streamQuality,
    if (remoteServerBackend != null) 'remoteServerBackend': remoteServerBackend,
    if (remoteServerId != null) 'remoteServerId': remoteServerId,
    if (remoteItemId != null) 'remoteItemId': remoteItemId,
  };

  factory RemoteMediaTarget.fromJson(Map<String, dynamic> json) => RemoteMediaTarget(
    kind: json['kind'] as String? ?? 'movie',
    title: json['title'] as String? ?? '',
    seriesTitle: json['seriesTitle'] as String?,
    posterUrl: json['posterUrl'] as String?,
    syncFileId: json['syncFileId'] as String?,
    canonicalSourceKey: json['canonicalSourceKey'] as String?,
    mountRelativePath: json['mountRelativePath'] as String?,
    workKey: json['workKey'] as String?,
    seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
    positionMs: (json['positionMs'] as num?)?.toInt(),
    playbackRate: (json['playbackRate'] as num?)?.toDouble(),
    streamQuality: json['streamQuality'] as String?,
    remoteServerBackend: json['remoteServerBackend'] as String?,
    remoteServerId: json['remoteServerId'] as String?,
    remoteItemId: json['remoteItemId'] as String?,
  );

  RemoteMediaTarget copyWith({
    String? kind,
    String? title,
    String? seriesTitle,
    String? posterUrl,
    String? syncFileId,
    String? canonicalSourceKey,
    String? mountRelativePath,
    String? workKey,
    int? seasonNumber,
    int? episodeNumber,
    int? positionMs,
    double? playbackRate,
    String? streamQuality,
    String? remoteServerBackend,
    String? remoteServerId,
    String? remoteItemId,
  }) => RemoteMediaTarget(
    kind: kind ?? this.kind,
    title: title ?? this.title,
    seriesTitle: seriesTitle ?? this.seriesTitle,
    posterUrl: posterUrl ?? this.posterUrl,
    syncFileId: syncFileId ?? this.syncFileId,
    canonicalSourceKey: canonicalSourceKey ?? this.canonicalSourceKey,
    mountRelativePath: mountRelativePath ?? this.mountRelativePath,
    workKey: workKey ?? this.workKey,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    positionMs: positionMs ?? this.positionMs,
    playbackRate: playbackRate ?? this.playbackRate,
    streamQuality: streamQuality ?? this.streamQuality,
    remoteServerBackend: remoteServerBackend ?? this.remoteServerBackend,
    remoteServerId: remoteServerId ?? this.remoteServerId,
    remoteItemId: remoteItemId ?? this.remoteItemId,
  );
}

class RemoteTrackOption {
  const RemoteTrackOption({
    required this.id,
    required this.label,
    this.language,
    this.codec,
    this.selected = false,
  });

  final String id;
  final String label;
  final String? language;
  final String? codec;
  final bool selected;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    if (language != null) 'language': language,
    if (codec != null) 'codec': codec,
    'selected': selected,
  };

  factory RemoteTrackOption.fromJson(Map<String, dynamic> json) => RemoteTrackOption(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    language: json['language'] as String?,
    codec: json['codec'] as String?,
    selected: json['selected'] == true,
  );

  RemoteTrackOption copyWith({String? id, String? label, String? language, String? codec, bool? selected}) =>
      RemoteTrackOption(
        id: id ?? this.id,
        label: label ?? this.label,
        language: language ?? this.language,
        codec: codec ?? this.codec,
        selected: selected ?? this.selected,
      );
}

class RemoteQualityOption {
  const RemoteQualityOption({required this.id, required this.label, this.selected = false});

  final String id;
  final String label;
  final bool selected;

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'selected': selected};

  factory RemoteQualityOption.fromJson(Map<String, dynamic> json) => RemoteQualityOption(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    selected: json['selected'] == true,
  );

  RemoteQualityOption copyWith({String? id, String? label, bool? selected}) =>
      RemoteQualityOption(id: id ?? this.id, label: label ?? this.label, selected: selected ?? this.selected);
}

class RemoteSeasonSummary {
  const RemoteSeasonSummary({
    required this.seasonId,
    this.itemKey,
    required this.seasonNumber,
    required this.title,
    this.episodeCount = 0,
  });

  final int seasonId;
  final String? itemKey;
  final int seasonNumber;
  final String title;
  final int episodeCount;

  Map<String, dynamic> toJson() => {
    'seasonId': seasonId,
    if (itemKey != null) 'itemKey': itemKey,
    'seasonNumber': seasonNumber,
    'title': title,
    'episodeCount': episodeCount,
  };

  factory RemoteSeasonSummary.fromJson(Map<String, dynamic> json) => RemoteSeasonSummary(
    seasonId: (json['seasonId'] as num?)?.toInt() ?? 0,
    itemKey: json['itemKey'] as String?,
    seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
  );

  RemoteSeasonSummary copyWith({int? seasonId, String? itemKey, int? seasonNumber, String? title, int? episodeCount}) =>
      RemoteSeasonSummary(
        seasonId: seasonId ?? this.seasonId,
        itemKey: itemKey ?? this.itemKey,
        seasonNumber: seasonNumber ?? this.seasonNumber,
        title: title ?? this.title,
        episodeCount: episodeCount ?? this.episodeCount,
      );
}

class RemoteEpisodeSummary {
  const RemoteEpisodeSummary({
    required this.itemKey,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.durationMs,
    this.viewOffsetMs,
    this.watched = false,
    this.current = false,
  });

  final String itemKey;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final int? durationMs;
  final int? viewOffsetMs;
  final bool watched;
  final bool current;

  Map<String, dynamic> toJson() => {
    'itemKey': itemKey,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'title': title,
    if (durationMs != null) 'durationMs': durationMs,
    if (viewOffsetMs != null) 'viewOffsetMs': viewOffsetMs,
    'watched': watched,
    'current': current,
  };

  factory RemoteEpisodeSummary.fromJson(Map<String, dynamic> json) => RemoteEpisodeSummary(
    itemKey: json['itemKey'] as String? ?? '',
    seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 0,
    episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt(),
    viewOffsetMs: (json['viewOffsetMs'] as num?)?.toInt(),
    watched: json['watched'] == true,
    current: json['current'] == true,
  );

  RemoteEpisodeSummary copyWith({
    String? itemKey,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    int? durationMs,
    int? viewOffsetMs,
    bool? watched,
    bool? current,
  }) => RemoteEpisodeSummary(
    itemKey: itemKey ?? this.itemKey,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    title: title ?? this.title,
    durationMs: durationMs ?? this.durationMs,
    viewOffsetMs: viewOffsetMs ?? this.viewOffsetMs,
    watched: watched ?? this.watched,
    current: current ?? this.current,
  );
}

class RemotePlayerSnapshot {
  const RemotePlayerSnapshot({
    required this.active,
    this.stage = 'idle',
    this.errorMessage,
    this.mediaKind,
    this.currentItemKey,
    this.title,
    this.seriesTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.posterUrl,
    this.playing = false,
    this.buffering = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.volume = 100.0,
    this.muted = false,
    this.playbackRate = 1.0,
    this.boxFitMode = 0,
    this.isFullscreen = false,
    this.isDesktopHost = false,
    this.audioSyncOffsetMs = 0,
    this.subtitleSyncOffsetMs = 0,
    this.canPrevious = false,
    this.canNext = false,
    this.canSkipIntro = false,
    this.canSkipCredits = false,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.qualities = const [],
    this.seasons = const [],
    this.browsedSeasonNumber,
    this.episodes = const [],
    this.updatedAtMs = 0,
  });

  static const idle = RemotePlayerSnapshot(active: false);

  final bool active;
  final String stage; // 'idle' | 'opening' | 'playing' | 'paused' | 'buffering' | 'error'
  final String? errorMessage;
  final String? mediaKind;
  final String? currentItemKey;
  final String? title;
  final String? seriesTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? posterUrl;
  final bool playing;
  final bool buffering;
  final int positionMs;
  final int durationMs;
  final double volume;
  final bool muted;
  final double playbackRate;
  final int boxFitMode;
  final bool isFullscreen;
  final bool isDesktopHost;
  final int audioSyncOffsetMs;
  final int subtitleSyncOffsetMs;
  final bool canPrevious;
  final bool canNext;
  final bool canSkipIntro;
  final bool canSkipCredits;
  final List<RemoteTrackOption> audioTracks;
  final List<RemoteTrackOption> subtitleTracks;
  final List<RemoteQualityOption> qualities;
  final List<RemoteSeasonSummary> seasons;
  final int? browsedSeasonNumber;
  final List<RemoteEpisodeSummary> episodes;
  final int updatedAtMs;

  double get progressFraction {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0).toDouble();
  }

  Map<String, dynamic> toJson() => {
    'active': active,
    'stage': stage,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (mediaKind != null) 'mediaKind': mediaKind,
    if (currentItemKey != null) 'currentItemKey': currentItemKey,
    if (title != null) 'title': title,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    if (posterUrl != null) 'posterUrl': posterUrl,
    'playing': playing,
    'buffering': buffering,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'volume': volume,
    'muted': muted,
    'playbackRate': playbackRate,
    'boxFitMode': boxFitMode,
    'isFullscreen': isFullscreen,
    'isDesktopHost': isDesktopHost,
    'audioSyncOffsetMs': audioSyncOffsetMs,
    'subtitleSyncOffsetMs': subtitleSyncOffsetMs,
    'canPrevious': canPrevious,
    'canNext': canNext,
    'canSkipIntro': canSkipIntro,
    'canSkipCredits': canSkipCredits,
    if (audioTracks.isNotEmpty) 'audioTracks': [for (final t in audioTracks) t.toJson()],
    if (subtitleTracks.isNotEmpty) 'subtitleTracks': [for (final t in subtitleTracks) t.toJson()],
    if (qualities.isNotEmpty) 'qualities': [for (final q in qualities) q.toJson()],
    if (seasons.isNotEmpty) 'seasons': [for (final s in seasons) s.toJson()],
    if (browsedSeasonNumber != null) 'browsedSeasonNumber': browsedSeasonNumber,
    if (episodes.isNotEmpty) 'episodes': [for (final e in episodes) e.toJson()],
    'updatedAtMs': updatedAtMs,
  };

  factory RemotePlayerSnapshot.fromJson(Map<String, dynamic> json) {
    List<T> parseList<T>(String key, T Function(Map<String, dynamic>) parser) {
      final raw = json[key];
      if (raw is! List) return <T>[];
      return [
        for (final item in raw)
          if (item is Map) parser(Map<String, dynamic>.from(item)),
      ];
    }

    return RemotePlayerSnapshot(
      active: json['active'] == true,
      stage: json['stage'] as String? ?? (json['active'] == true ? 'playing' : 'idle'),
      errorMessage: json['errorMessage'] as String?,
      mediaKind: json['mediaKind'] as String?,
      currentItemKey: json['currentItemKey'] as String?,
      title: json['title'] as String?,
      seriesTitle: json['seriesTitle'] as String?,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      posterUrl: json['posterUrl'] as String?,
      playing: json['playing'] == true,
      buffering: json['buffering'] == true,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      volume: (json['volume'] as num?)?.toDouble() ?? 100.0,
      muted: json['muted'] == true,
      playbackRate: (json['playbackRate'] as num?)?.toDouble() ?? 1.0,
      boxFitMode: (json['boxFitMode'] as num?)?.toInt() ?? 0,
      isFullscreen: json['isFullscreen'] == true,
      isDesktopHost: json['isDesktopHost'] == true,
      audioSyncOffsetMs: (json['audioSyncOffsetMs'] as num?)?.toInt() ?? 0,
      subtitleSyncOffsetMs: (json['subtitleSyncOffsetMs'] as num?)?.toInt() ?? 0,
      canPrevious: json['canPrevious'] == true,
      canNext: json['canNext'] == true,
      canSkipIntro: json['canSkipIntro'] == true,
      canSkipCredits: json['canSkipCredits'] == true,
      audioTracks: parseList('audioTracks', RemoteTrackOption.fromJson),
      subtitleTracks: parseList('subtitleTracks', RemoteTrackOption.fromJson),
      qualities: parseList('qualities', RemoteQualityOption.fromJson),
      seasons: parseList('seasons', RemoteSeasonSummary.fromJson),
      browsedSeasonNumber: (json['browsedSeasonNumber'] as num?)?.toInt(),
      episodes: parseList('episodes', RemoteEpisodeSummary.fromJson),
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  RemotePlayerSnapshot copyWith({
    bool? active,
    String? stage,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? mediaKind,
    String? currentItemKey,
    String? title,
    String? seriesTitle,
    int? seasonNumber,
    int? episodeNumber,
    String? posterUrl,
    bool? playing,
    bool? buffering,
    int? positionMs,
    int? durationMs,
    double? volume,
    bool? muted,
    double? playbackRate,
    int? boxFitMode,
    bool? isFullscreen,
    bool? isDesktopHost,
    int? audioSyncOffsetMs,
    int? subtitleSyncOffsetMs,
    bool? canPrevious,
    bool? canNext,
    bool? canSkipIntro,
    bool? canSkipCredits,
    List<RemoteTrackOption>? audioTracks,
    List<RemoteTrackOption>? subtitleTracks,
    List<RemoteQualityOption>? qualities,
    List<RemoteSeasonSummary>? seasons,
    int? browsedSeasonNumber,
    List<RemoteEpisodeSummary>? episodes,
    int? updatedAtMs,
  }) => RemotePlayerSnapshot(
    active: active ?? this.active,
    stage: stage ?? this.stage,
    errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    mediaKind: mediaKind ?? this.mediaKind,
    currentItemKey: currentItemKey ?? this.currentItemKey,
    title: title ?? this.title,
    seriesTitle: seriesTitle ?? this.seriesTitle,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    posterUrl: posterUrl ?? this.posterUrl,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    playbackRate: playbackRate ?? this.playbackRate,
    boxFitMode: boxFitMode ?? this.boxFitMode,
    isFullscreen: isFullscreen ?? this.isFullscreen,
    isDesktopHost: isDesktopHost ?? this.isDesktopHost,
    audioSyncOffsetMs: audioSyncOffsetMs ?? this.audioSyncOffsetMs,
    subtitleSyncOffsetMs: subtitleSyncOffsetMs ?? this.subtitleSyncOffsetMs,
    canPrevious: canPrevious ?? this.canPrevious,
    canNext: canNext ?? this.canNext,
    canSkipIntro: canSkipIntro ?? this.canSkipIntro,
    canSkipCredits: canSkipCredits ?? this.canSkipCredits,
    audioTracks: audioTracks ?? this.audioTracks,
    subtitleTracks: subtitleTracks ?? this.subtitleTracks,
    qualities: qualities ?? this.qualities,
    seasons: seasons ?? this.seasons,
    browsedSeasonNumber: browsedSeasonNumber ?? this.browsedSeasonNumber,
    episodes: episodes ?? this.episodes,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
}

class RemoteOnlineDevice {
  const RemoteOnlineDevice({required this.host, this.snapshot = RemotePlayerSnapshot.idle, this.loadingStatus = false});

  final DiscoveredHost host;
  final RemotePlayerSnapshot snapshot;
  final bool loadingStatus;

  String get key => '${host.authContextId}:${host.clientId}';
}

class RemoteCatalogItem {
  const RemoteCatalogItem({
    required this.serverId,
    this.serverName,
    required this.itemId,
    required this.kind,
    required this.title,
    this.subtitle,
    this.seriesTitle,
    this.year,
    this.seasonNumber,
    this.episodeNumber,
    this.thumbUrl,
    this.durationMs,
    this.viewOffsetMs,
    this.watched = false,
  });

  final String serverId;
  final String? serverName;
  final String itemId;
  final String kind; // 'movie' | 'show' | 'season' | 'episode'
  final String title;
  final String? subtitle;
  final String? seriesTitle;
  final int? year;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? thumbUrl;
  final int? durationMs;
  final int? viewOffsetMs;
  final bool watched;

  bool get isContainer => kind == 'show' || kind == 'season';

  RemoteMediaTarget toRemoteMediaTarget() => RemoteMediaTarget(
    kind: kind,
    title: title,
    seriesTitle: seriesTitle,
    posterUrl: thumbUrl,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    positionMs: viewOffsetMs,
    remoteServerId: serverId,
    remoteItemId: itemId,
  );

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    if (serverName != null) 'serverName': serverName,
    'itemId': itemId,
    'kind': kind,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    if (year != null) 'year': year,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    if (thumbUrl != null) 'thumbUrl': thumbUrl,
    if (durationMs != null) 'durationMs': durationMs,
    if (viewOffsetMs != null) 'viewOffsetMs': viewOffsetMs,
    if (watched) 'watched': true,
  };

  factory RemoteCatalogItem.fromJson(Map<String, dynamic> json) => RemoteCatalogItem(
    serverId: json['serverId'] as String? ?? '',
    serverName: json['serverName'] as String?,
    itemId: json['itemId'] as String? ?? '',
    kind: json['kind'] as String? ?? 'movie',
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String?,
    seriesTitle: json['seriesTitle'] as String?,
    year: (json['year'] as num?)?.toInt(),
    seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
    thumbUrl: json['thumbUrl'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt(),
    viewOffsetMs: (json['viewOffsetMs'] as num?)?.toInt(),
    watched: json['watched'] == true,
  );
}

class RemoteCatalogHub {
  const RemoteCatalogHub({
    required this.id,
    required this.title,
    this.serverId,
    this.serverName,
    this.items = const [],
  });

  final String id;
  final String title;
  final String? serverId;
  final String? serverName;
  final List<RemoteCatalogItem> items;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (serverId != null) 'serverId': serverId,
    if (serverName != null) 'serverName': serverName,
    'items': [for (final item in items) item.toJson()],
  };

  factory RemoteCatalogHub.fromJson(Map<String, dynamic> json) => RemoteCatalogHub(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    serverId: json['serverId'] as String?,
    serverName: json['serverName'] as String?,
    items: [
      if (json['items'] is List)
        for (final raw in json['items'] as List)
          if (raw is Map) RemoteCatalogItem.fromJson(Map<String, dynamic>.from(raw)),
    ],
  );
}

class RemoteCatalogLibrary {
  const RemoteCatalogLibrary({
    required this.serverId,
    this.serverName,
    required this.libraryId,
    required this.title,
    required this.kind,
  });

  final String serverId;
  final String? serverName;
  final String libraryId;
  final String title;
  final String kind;

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    if (serverName != null) 'serverName': serverName,
    'libraryId': libraryId,
    'title': title,
    'kind': kind,
  };

  factory RemoteCatalogLibrary.fromJson(Map<String, dynamic> json) => RemoteCatalogLibrary(
    serverId: json['serverId'] as String? ?? '',
    serverName: json['serverName'] as String?,
    libraryId: json['libraryId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    kind: json['kind'] as String? ?? 'unknown',
  );
}

class RemoteHostSearchResponse {
  const RemoteHostSearchResponse({required this.query, this.items = const [], this.error});

  final String query;
  final List<RemoteCatalogItem> items;
  final String? error;

  Map<String, dynamic> toJson() => {
    'query': query,
    'items': [for (final item in items) item.toJson()],
    if (error != null) 'error': error,
  };

  factory RemoteHostSearchResponse.fromJson(Map<String, dynamic> json) => RemoteHostSearchResponse(
    query: json['query'] as String? ?? '',
    items: [
      if (json['items'] is List)
        for (final raw in json['items'] as List)
          if (raw is Map) RemoteCatalogItem.fromJson(Map<String, dynamic>.from(raw)),
    ],
    error: json['error'] as String?,
  );
}

class RemoteHostHomeResponse {
  const RemoteHostHomeResponse({this.hubs = const [], this.libraries = const [], this.error});

  final List<RemoteCatalogHub> hubs;
  final List<RemoteCatalogLibrary> libraries;
  final String? error;

  Map<String, dynamic> toJson() => {
    'hubs': [for (final hub in hubs) hub.toJson()],
    'libraries': [for (final lib in libraries) lib.toJson()],
    if (error != null) 'error': error,
  };

  factory RemoteHostHomeResponse.fromJson(Map<String, dynamic> json) => RemoteHostHomeResponse(
    hubs: [
      if (json['hubs'] is List)
        for (final raw in json['hubs'] as List)
          if (raw is Map) RemoteCatalogHub.fromJson(Map<String, dynamic>.from(raw)),
    ],
    libraries: [
      if (json['libraries'] is List)
        for (final raw in json['libraries'] as List)
          if (raw is Map) RemoteCatalogLibrary.fromJson(Map<String, dynamic>.from(raw)),
    ],
    error: json['error'] as String?,
  );
}

class RemoteHostChildrenResponse {
  const RemoteHostChildrenResponse({
    required this.serverId,
    required this.itemId,
    this.title,
    this.items = const [],
    this.error,
  });

  final String serverId;
  final String itemId;
  final String? title;
  final List<RemoteCatalogItem> items;
  final String? error;

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'itemId': itemId,
    if (title != null) 'title': title,
    'items': [for (final item in items) item.toJson()],
    if (error != null) 'error': error,
  };

  factory RemoteHostChildrenResponse.fromJson(Map<String, dynamic> json) => RemoteHostChildrenResponse(
    serverId: json['serverId'] as String? ?? '',
    itemId: json['itemId'] as String? ?? '',
    title: json['title'] as String?,
    items: [
      if (json['items'] is List)
        for (final raw in json['items'] as List)
          if (raw is Map) RemoteCatalogItem.fromJson(Map<String, dynamic>.from(raw)),
    ],
    error: json['error'] as String?,
  );
}
