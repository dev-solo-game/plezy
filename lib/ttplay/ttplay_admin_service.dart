import 'ttplay_api_client.dart';

class TtplayMountRecord {
  const TtplayMountRecord({
    required this.id,
    required this.name,
    required this.kind,
    required this.config,
    required this.hasSecret,
    required this.enabled,
    this.scanStatus,
    this.scanError,
    this.videoCount = 0,
    this.totalFileBytes = 0,
    this.matchedItemCount = 0,
  });

  final String id;
  final String name;
  final String kind; // local | smb | webdav | quark
  final Map<String, dynamic> config;
  final bool hasSecret;
  final bool enabled;
  final String? scanStatus;
  final String? scanError;
  final int videoCount;
  final int totalFileBytes;
  final int matchedItemCount;

  bool get isScanning => scanStatus == 'running';

  factory TtplayMountRecord.fromJson(Map<String, dynamic> json) {
    final scanState = ttplayMap(json['scan_state']);
    return TtplayMountRecord(
      id: ttplayString(json['id']) ?? '',
      name: ttplayString(json['name']) ?? '',
      kind: (ttplayString(json['kind']) ?? 'local').toLowerCase(),
      config: ttplayMap(json['config']) ?? const {},
      hasSecret: json['has_secret'] == true,
      enabled: json['enabled'] != false,
      scanStatus: ttplayString(scanState?['status']),
      scanError: ttplayString(scanState?['last_error']),
      videoCount: ttplayInt(json['video_count']) ?? 0,
      totalFileBytes: ttplayInt(json['total_file_bytes']) ?? 0,
      matchedItemCount: ttplayInt(json['matched_item_count']) ?? 0,
    );
  }
}

class TtplayHostDirItem {
  const TtplayHostDirItem({required this.name, required this.path});

  final String name;
  final String path;

  factory TtplayHostDirItem.fromJson(Map<String, dynamic> json) =>
      TtplayHostDirItem(name: ttplayString(json['name']) ?? '', path: ttplayString(json['path']) ?? '');
}

class TtplayHostBrowseResult {
  const TtplayHostBrowseResult({required this.current, this.parent, required this.dirs});

  final String current;
  final String? parent;
  final List<TtplayHostDirItem> dirs;

  factory TtplayHostBrowseResult.fromJson(Map<String, dynamic> json) => TtplayHostBrowseResult(
    current: ttplayString(json['current']) ?? '',
    parent: ttplayString(json['parent']),
    dirs: [for (final d in ttplayMapList(json['dirs'])) TtplayHostDirItem.fromJson(d)],
  );
}

class TtplayQuarkQrStart {
  const TtplayQuarkQrStart({required this.sessionId, required this.mode, required this.qrContent, required this.expiresAt});

  final String sessionId;
  final String mode;
  final String qrContent;
  final int expiresAt;

  factory TtplayQuarkQrStart.fromJson(Map<String, dynamic> json) => TtplayQuarkQrStart(
    sessionId: ttplayString(json['session_id']) ?? '',
    mode: ttplayString(json['mode']) ?? 'pc',
    qrContent: ttplayString(json['qr_content']) ?? '',
    expiresAt: ttplayInt(json['expires_at']) ?? 0,
  );
}

class TtplayQuarkQrPoll {
  const TtplayQuarkQrPoll({required this.status, this.secret, this.message});

  final String status; // pending | scanned | confirmed | expired | error
  final String? secret;
  final String? message;

  factory TtplayQuarkQrPoll.fromJson(Map<String, dynamic> json) => TtplayQuarkQrPoll(
    status: (ttplayString(json['status']) ?? 'pending').toLowerCase(),
    secret: ttplayString(json['secret']),
    message: ttplayString(json['message']),
  );
}

class TtplayServerSettings {
  const TtplayServerSettings({
    this.serverName = '',
    this.tmdbApiKeySet = false,
    this.tmdbApiKeyMasked = '',
    this.tmdbApiBase = '',
    this.tmdbImageBase = '',
    this.metadataProxy = '',
    this.bangumiEnabled = false,
    this.bangumiApiBase = '',
    this.bangumiTokenSet = false,
    this.doubanEnabled = false,
    this.doubanApiBase = '',
    this.doubanCookieSet = false,
    this.anilistEnabled = false,
    this.anilistApiBase = '',
    this.imdbEnabled = false,
    this.imdbApiBase = '',
    this.tvdbEnabled = false,
    this.tvdbApiBase = '',
    this.tvdbApiKeySet = false,
    this.tvdbPinSet = false,
    this.allowPublicMetadata = false,
    this.allowFallbackMetadata = true,
    this.customRecognitionWords = '',
    this.proxyImages = true,
    this.scraperLang = 'zh-CN',
    this.preferNfo = false,
    this.watchedThreshold = 0.9,
    this.scanIntervalMin = 0,
    this.watchLocalFS = true,
  });

  final String serverName;
  final bool tmdbApiKeySet;
  final String tmdbApiKeyMasked;
  final String tmdbApiBase;
  final String tmdbImageBase;
  final String metadataProxy;
  final bool bangumiEnabled;
  final String bangumiApiBase;
  final bool bangumiTokenSet;
  final bool doubanEnabled;
  final String doubanApiBase;
  final bool doubanCookieSet;
  final bool anilistEnabled;
  final String anilistApiBase;
  final bool imdbEnabled;
  final String imdbApiBase;
  final bool tvdbEnabled;
  final String tvdbApiBase;
  final bool tvdbApiKeySet;
  final bool tvdbPinSet;
  final bool allowPublicMetadata;
  final bool allowFallbackMetadata;
  final String customRecognitionWords;
  final bool proxyImages;
  final String scraperLang;
  final bool preferNfo;
  final double watchedThreshold;
  final int scanIntervalMin;
  final bool watchLocalFS;

  factory TtplayServerSettings.fromJson(Map<String, dynamic> json) => TtplayServerSettings(
    serverName: ttplayString(json['server_name']) ?? '',
    tmdbApiKeySet: json['tmdb_api_key_set'] == true,
    tmdbApiKeyMasked: ttplayString(json['tmdb_api_key_masked']) ?? '',
    tmdbApiBase: ttplayString(json['tmdb_api_base']) ?? '',
    tmdbImageBase: ttplayString(json['tmdb_image_base']) ?? '',
    metadataProxy: ttplayString(json['metadata_proxy']) ?? '',
    bangumiEnabled: json['bangumi_enabled'] == true,
    bangumiApiBase: ttplayString(json['bangumi_api_base']) ?? '',
    bangumiTokenSet: json['bangumi_token_set'] == true,
    doubanEnabled: json['douban_enabled'] == true,
    doubanApiBase: ttplayString(json['douban_api_base']) ?? '',
    doubanCookieSet: json['douban_cookie_set'] == true,
    anilistEnabled: json['anilist_enabled'] == true,
    anilistApiBase: ttplayString(json['anilist_api_base']) ?? '',
    imdbEnabled: json['imdb_enabled'] == true,
    imdbApiBase: ttplayString(json['imdb_api_base']) ?? '',
    tvdbEnabled: json['tvdb_enabled'] == true,
    tvdbApiBase: ttplayString(json['tvdb_api_base']) ?? '',
    tvdbApiKeySet: json['tvdb_api_key_set'] == true,
    tvdbPinSet: json['tvdb_pin_set'] == true,
    allowPublicMetadata: json['allow_public_metadata'] == true,
    allowFallbackMetadata: json['allow_fallback_metadata'] != false,
    customRecognitionWords: (json['custom_recognition_words'] as String?) ?? '',
    proxyImages: json['proxy_images'] != false,
    scraperLang: ttplayString(json['scraper_lang']) ?? 'zh-CN',
    preferNfo: json['prefer_nfo'] == true,
    watchedThreshold: ttplayDouble(json['watched_threshold']) ?? 0.9,
    scanIntervalMin: ttplayInt(json['scan_interval_min']) ?? 0,
    watchLocalFS: json['watch_local_fs'] != false,
  );
}

class TtplayScanSnapshot {
  const TtplayScanSnapshot({
    required this.mountId,
    required this.mountName,
    required this.status,
    this.directoriesDone = 0,
    this.filesSeen = 0,
    this.videosFound = 0,
    this.currentPath = '',
    this.error,
  });

  final String mountId;
  final String mountName;
  final String status;
  final int directoriesDone;
  final int filesSeen;
  final int videosFound;
  final String currentPath;
  final String? error;

  factory TtplayScanSnapshot.fromJson(Map<String, dynamic> json) => TtplayScanSnapshot(
    mountId: ttplayString(json['mount_id']) ?? '',
    mountName: ttplayString(json['mount_name']) ?? '',
    status: ttplayString(json['status']) ?? 'idle',
    directoriesDone: ttplayInt(json['directories_done']) ?? 0,
    filesSeen: ttplayInt(json['files_seen']) ?? 0,
    videosFound: ttplayInt(json['videos_found']) ?? 0,
    currentPath: ttplayString(json['current_path']) ?? '',
    error: ttplayString(json['error']),
  );
}

class TtplayScrapeSnapshot {
  const TtplayScrapeSnapshot({
    this.status = 'idle',
    this.done = 0,
    this.total = 0,
    this.matched = 0,
    this.unmatched = 0,
    this.title,
    this.message,
  });

  final String status;
  final int done;
  final int total;
  final int matched;
  final int unmatched;
  final String? title;
  final String? message;

  bool get isRunning => status == 'running';

  factory TtplayScrapeSnapshot.fromJson(Map<String, dynamic> json) => TtplayScrapeSnapshot(
    status: ttplayString(json['status']) ?? 'idle',
    done: ttplayInt(json['done']) ?? 0,
    total: ttplayInt(json['total']) ?? 0,
    matched: ttplayInt(json['matched']) ?? 0,
    unmatched: ttplayInt(json['unmatched']) ?? 0,
    title: ttplayString(json['title']),
    message: ttplayString(json['message']),
  );
}

class TtplayTaskStatus {
  const TtplayTaskStatus({
    this.scans = const [],
    this.scrape = const TtplayScrapeSnapshot(),
    this.pendingScrape = 0,
    this.unmatchedCount = 0,
  });

  final List<TtplayScanSnapshot> scans;
  final TtplayScrapeSnapshot scrape;
  final int pendingScrape;
  final int unmatchedCount;

  factory TtplayTaskStatus.fromJson(Map<String, dynamic> json) => TtplayTaskStatus(
    scans: [for (final s in ttplayMapList(json['scans'])) TtplayScanSnapshot.fromJson(s)],
    scrape: TtplayScrapeSnapshot.fromJson(ttplayMap(json['scrape']) ?? const {}),
    pendingScrape: ttplayInt(json['pending_scrape']) ?? 0,
    unmatchedCount: ttplayInt(json['unmatched_count']) ?? 0,
  );
}

class TtplayScrapeCandidate {
  const TtplayScrapeCandidate({
    required this.source,
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.summary,
    this.posterPath,
  });

  final String source;
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? summary;
  final String? posterPath;

  factory TtplayScrapeCandidate.fromJson(Map<String, dynamic> json) => TtplayScrapeCandidate(
    source: (ttplayString(json['source']) ?? 'tmdb').toLowerCase(),
    id: ttplayString(json['id']) ?? '${ttplayInt(json['id']) ?? ''}',
    title: ttplayString(json['title']) ?? '',
    originalTitle: ttplayString(json['original_title']),
    year: ttplayInt(json['year']),
    summary: ttplayString(json['summary']),
    posterPath: ttplayString(json['poster_path']),
  );
}

class TtplayEditableItem {
  const TtplayEditableItem({
    required this.id,
    required this.kind,
    required this.title,
    this.originalTitle,
    this.year,
    this.libraryType,
    this.summary,
    this.tagline,
    this.studio,
    this.rating,
    this.locked = false,
    this.sampleFilePath,
  });

  final String id;
  final String kind;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? libraryType;
  final String? summary;
  final String? tagline;
  final String? studio;
  final double? rating;
  final bool locked;
  final String? sampleFilePath;
}

class TtplayTestResult {
  const TtplayTestResult({required this.ok, this.latencyMs, this.message, this.serverName, this.detectedKind});

  final bool ok;
  final int? latencyMs;
  final String? message;
  final String? serverName;
  final String? detectedKind;

  factory TtplayTestResult.fromJson(Map<String, dynamic> json) => TtplayTestResult(
    ok: json['ok'] == true,
    latencyMs: ttplayInt(json['latency_ms']),
    message: ttplayString(json['message']),
    serverName: ttplayString(json['server_name']),
    detectedKind: ttplayString(json['detected_kind']),
  );
}

/// Server-authoritative administration client for a self-hosted `ttplay-server`.
class TtplayAdminService {
  TtplayAdminService(this.api);

  final TtplayApiClient api;

  // ─── Mounts & Host FS & Quark QR ───────────────────────────────────────

  Future<List<TtplayMountRecord>> listMounts() async {
    final resp = await api.getJson('/api/v1/mounts');
    return [for (final m in ttplayMapList(resp['mounts'])) TtplayMountRecord.fromJson(m)];
  }

  Future<TtplayMountRecord> createMount({
    required String name,
    required String kind,
    required Map<String, dynamic> config,
    Map<String, String> secrets = const {},
    bool enabled = true,
    bool autoScan = true,
  }) async {
    final resp = await api.postJson(
      '/api/v1/mounts',
      body: {
        'name': name,
        'kind': kind,
        'config': config,
        if (secrets.isNotEmpty) 'secrets': secrets,
        'enabled': enabled,
        'auto_scan': autoScan,
      },
    );
    return TtplayMountRecord.fromJson(ttplayMap(resp['mount']) ?? const {});
  }

  Future<TtplayMountRecord> updateMount(
    String id, {
    String? name,
    Map<String, dynamic>? config,
    Map<String, String>? secrets,
    bool? enabled,
  }) async {
    final resp = await api.putJson(
      '/api/v1/mounts/${Uri.encodeComponent(id)}',
      body: {
        'name': ?name,
        'config': ?config,
        if (secrets != null && secrets.isNotEmpty) 'secrets': secrets,
        'enabled': ?enabled,
      },
    );
    return TtplayMountRecord.fromJson(ttplayMap(resp['mount']) ?? const {});
  }

  Future<void> deleteMount(String id) async {
    await api.deleteJson('/api/v1/mounts/${Uri.encodeComponent(id)}');
  }

  Future<void> testMount({
    String? id,
    required String kind,
    required Map<String, dynamic> config,
    Map<String, String> secrets = const {},
  }) async {
    await api.postJson(
      '/api/v1/mounts/test',
      body: {
        if (id != null && id.isNotEmpty) 'id': id,
        'kind': kind,
        'config': config,
        if (secrets.isNotEmpty) 'secrets': secrets,
      },
    );
  }

  Future<void> scanMount(String id, {bool full = false}) async {
    await api.postJson('/api/v1/mounts/${Uri.encodeComponent(id)}/scan', query: {if (full) 'full': '1'});
  }

  Future<void> cancelScanMount(String id) async {
    await api.postJson('/api/v1/mounts/${Uri.encodeComponent(id)}/cancel-scan');
  }

  Future<TtplayHostBrowseResult> browseHostFs([String path = '']) async {
    final resp = await api.getJson('/api/v1/fs/browse', query: {if (path.trim().isNotEmpty) 'path': path.trim()});
    return TtplayHostBrowseResult.fromJson(resp);
  }

  Future<TtplayQuarkQrStart> startQuarkQr({String mode = 'pc'}) async {
    final resp = await api.postJson('/api/v1/quark/qr/start', body: {'mode': mode});
    return TtplayQuarkQrStart.fromJson(resp);
  }

  Future<TtplayQuarkQrPoll> pollQuarkQr(String sessionId) async {
    final resp = await api.getJson('/api/v1/quark/qr/poll', query: {'session_id': sessionId});
    return TtplayQuarkQrPoll.fromJson(resp);
  }

  // ─── Tasks & Scraper Settings ──────────────────────────────────────────

  Future<TtplayTaskStatus> fetchTaskStatus() async {
    final resp = await api.getJson('/api/v1/tasks/status');
    return TtplayTaskStatus.fromJson(ttplayMap(resp['status']) ?? const {});
  }

  Future<void> triggerScanAll({bool full = false}) async {
    await api.postJson('/api/v1/tasks/scan-all', query: {if (full) 'full': '1'});
  }

  Future<void> triggerScrape({bool retryUnmatched = false, bool refreshAll = false}) async {
    await api.postJson(
      '/api/v1/tasks/scrape',
      query: {if (retryUnmatched) 'retry_unmatched': '1', if (refreshAll) 'refresh_all': '1'},
    );
  }

  Future<TtplayServerSettings> fetchSettings() async {
    final resp = await api.getJson('/api/v1/settings');
    return TtplayServerSettings.fromJson(ttplayMap(resp['settings']) ?? const {});
  }

  Future<TtplayServerSettings> updateSettings(Map<String, dynamic> patch) async {
    final resp = await api.putJson('/api/v1/settings', body: patch);
    return TtplayServerSettings.fromJson(ttplayMap(resp['settings']) ?? const {});
  }

  Future<TtplayTestResult> testTmdb({String? tmdbApiKey, String? tmdbApiBase, String? metadataProxy}) async {
    final resp = await api.postJson(
      '/api/v1/settings/test-tmdb',
      body: {
        if (tmdbApiKey != null && tmdbApiKey.trim().isNotEmpty) 'tmdb_api_key': tmdbApiKey.trim(),
        if (tmdbApiBase != null) 'tmdb_api_base': tmdbApiBase.trim(),
        if (metadataProxy != null) 'metadata_proxy': metadataProxy.trim(),
      },
    );
    return TtplayTestResult.fromJson(resp);
  }

  Future<TtplayTestResult> testProvider(
    String provider, {
    String? apiKey,
    String? pin,
    String? token,
    String? cookie,
    String? apiBase,
    String? metadataProxy,
  }) async {
    final resp = await api.postJson(
      '/api/v1/settings/test-provider',
      body: {
        'provider': provider,
        if (apiKey != null && apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
        if (pin != null && pin.trim().isNotEmpty) 'pin': pin.trim(),
        if (token != null && token.trim().isNotEmpty) 'token': token.trim(),
        if (cookie != null && cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
        if (apiBase != null) 'api_base': apiBase.trim(),
        if (metadataProxy != null) 'metadata_proxy': metadataProxy.trim(),
      },
    );
    return TtplayTestResult.fromJson(resp);
  }

  Future<int> clearMetadataCache({String scope = 'all'}) async {
    final resp = await api.postJson('/api/v1/settings/clear-cache', body: {'scope': scope});
    return ttplayInt(resp['deleted']) ?? 0;
  }

  // ─── Item Match, Unmatch & Metadata ────────────────────────────────────

  Future<List<TtplayScrapeCandidate>> searchScrapeCandidates({
    required String query,
    required bool asShow,
    int? year,
    String provider = 'all',
    bool refresh = false,
  }) async {
    final resp = await api.getJson(
      '/api/v1/scrape/search',
      query: {
        'q': query.trim(),
        'kind': asShow ? 'show' : 'movie',
        if (year != null && year > 0) 'year': '$year',
        if (provider.isNotEmpty && provider != 'all') 'provider': provider,
        if (refresh) 'refresh': '1',
      },
    );
    return [for (final r in ttplayMapList(resp['results'])) TtplayScrapeCandidate.fromJson(r)];
  }

  Future<void> applyManualMatch(
    String itemId, {
    required String provider,
    required String externalId,
    required bool asShow,
    String? libraryType,
  }) async {
    await api.postJson(
      '/api/v1/items/${Uri.encodeComponent(itemId)}/match',
      body: {
        'provider': provider,
        'external_id': externalId,
        'as_show': asShow,
        if (libraryType != null && libraryType.isNotEmpty) 'library_type': libraryType,
      },
    );
  }

  Future<void> unmatchItem(String itemId) async {
    await api.postJson('/api/v1/items/${Uri.encodeComponent(itemId)}/unmatch');
  }

  Future<TtplayEditableItem?> fetchEditableItem(String itemId) async {
    final resp = await api.getJson('/api/v1/items/${Uri.encodeComponent(itemId)}');
    final detail = ttplayMap(resp['detail']);
    final item = ttplayMap(detail?['item']);
    if (item == null) return null;
    final files = ttplayMapList(detail?['files']);
    return TtplayEditableItem(
      id: '${ttplayInt(item['id']) ?? ttplayString(item['id']) ?? itemId}',
      kind: ttplayString(item['kind']) ?? 'movie',
      title: ttplayString(item['title']) ?? '',
      originalTitle: ttplayString(item['original_title']),
      year: ttplayInt(item['year']),
      libraryType: ttplayString(item['library_type']),
      summary: ttplayString(item['summary']),
      tagline: ttplayString(item['tagline']),
      studio: ttplayString(item['studio']),
      rating: ttplayDouble(item['rating']),
      locked: item['locked'] == true,
      sampleFilePath: files.isEmpty ? null : ttplayString(files.first['path']),
    );
  }

  Future<void> updateItemMetadata(String itemId, Map<String, dynamic> patch) async {
    await api.putJson('/api/v1/items/${Uri.encodeComponent(itemId)}/metadata', body: patch);
  }

  Future<void> refreshItemMetadata(String itemId) async {
    await api.postJson('/api/v1/items/${Uri.encodeComponent(itemId)}/refresh');
  }

  // ─── External Emby / Jellyfin Servers ──────────────────────────────────

  Future<List<TtplayExternalServerSummary>> listExternalServers() => api.fetchExternalServers();

  Future<TtplayTestResult> testExternalServer(Map<String, dynamic> payload) async {
    final resp = await api.postJson('/api/v1/ext-servers/test', body: payload);
    return TtplayTestResult.fromJson(resp);
  }

  Future<TtplayExternalServerSummary> createExternalServer(Map<String, dynamic> payload) async {
    final resp = await api.postJson('/api/v1/ext-servers', body: payload);
    return TtplayExternalServerSummary.fromJson(ttplayMap(resp['server']) ?? const {});
  }

  Future<TtplayExternalServerSummary> updateExternalServer(String id, Map<String, dynamic> payload) async {
    final resp = await api.putJson('/api/v1/ext-servers/${Uri.encodeComponent(id)}', body: payload);
    return TtplayExternalServerSummary.fromJson(ttplayMap(resp['server']) ?? const {});
  }

  Future<void> deleteExternalServer(String id) async {
    await api.deleteJson('/api/v1/ext-servers/${Uri.encodeComponent(id)}');
  }
}
