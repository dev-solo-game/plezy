import 'dart:async';

import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../media/artist_discography.dart';
import '../media/download_resolution.dart';
import '../media/ids.dart';
import '../media/library_change_event.dart';
import '../media/library_filter_result.dart';
import '../media/library_genre.dart';
import '../media/library_query.dart';
import '../media/live_tv_support.dart';
import '../media/lyrics.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../media/media_file_info.dart';
import '../media/media_filter.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_part.dart';
import '../media/media_person.dart';
import '../media/media_playlist.dart';
import '../media/media_role.dart';
import '../media/media_server_client.dart';
import '../media/media_sort.dart';
import '../media/media_source_info.dart';
import '../media/media_version.dart';
import '../media/playback_report_metadata.dart';
import '../media/server_capabilities.dart';
import '../media/stream_quality.dart';
import '../mpv/mpv.dart';
import '../services/api_cache.dart';
import '../services/jellyfin_api_cache.dart';
import '../services/playback_initialization_types.dart';
import '../services/scrub_preview_source.dart';
import '../utils/external_ids.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'ttplay_api_client.dart';

/// [MediaServerClient] backing a single external Emby/Jellyfin server proxied
/// through the user's self-hosted `ttplay-server` (`/api/v1/ext/{id}/*`).
class TtplayExternalServerClient implements MediaServerClient, StreamQualityClient {
  TtplayExternalServerClient({required this.api, required this.server})
    : _serverId = ServerId('$serverIdPrefix${server.id}');

  static const String serverIdPrefix = 'ttplay-ext:';
  static bool isExternalServerId(String? id) => id != null && id.startsWith(serverIdPrefix);

  final TtplayApiClient api;
  final TtplayExternalServerSummary server;
  final ServerId _serverId;

  final Map<String, String> _viewCollectionTypes = {};
  final Map<String, String> _viewTitles = {};
  bool _offlineMode = false;

  MediaBrowserDialect get _dialect =>
      server.kind.toLowerCase() == 'emby' ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin;

  String get _extPrefix => '/api/v1/ext/${Uri.encodeComponent(server.id)}';

  @override
  ServerId get serverId => _serverId;

  @override
  String? get serverName => server.name.isNotEmpty ? server.name : server.baseUrl;

  @override
  MediaBackend get backend => _dialect.backend;

  @override
  final Object authenticationSessionId = Object();

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    videoTranscoding: true,
    userFavorites: true,
    continueWatchingRemoval: false,
    folderGrouping: false,
    richHubs: true,
  );

  @override
  bool get isOfflineMode => _offlineMode;

  @override
  void setOfflineMode(bool offline) => _offlineMode = offline;

  @override
  ApiCache get cache => JellyfinApiCache.instance;

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  double get watchedThreshold => 0.9;

  @override
  bool get marksWatchedOnPlaybackStopped => true;

  @override
  LiveTvSupport get liveTv => const _ExtNoLiveTv();

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  void close() {
    // Lifecycle of shared [TtplayApiClient] is owned by [TtplaySessionBinder].
  }

  @override
  Future<HealthStatus> checkHealth() async {
    try {
      await api.getJson('$_extPrefix/home');
      return HealthStatus.online;
    } on MediaServerAuthException {
      return HealthStatus.authError;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 401) return HealthStatus.authError;
      if (e.statusCode == 403) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => server.serverId.isNotEmpty ? server.serverId : serverId.toString();

  // ─── Mapping ───────────────────────────────────────────────────────────

  static MediaKind _kindOf(String? raw) => switch (raw?.toLowerCase()) {
    'movie' || 'video' => MediaKind.movie,
    'show' => MediaKind.show,
    'season' => MediaKind.season,
    'episode' => MediaKind.episode,
    'boxset' => MediaKind.collection,
    'playlist' => MediaKind.playlist,
    _ => MediaKind.unknown,
  };

  static MediaKind _viewKind(String? collectionType) => switch (collectionType?.toLowerCase()) {
    'movies' => MediaKind.movie,
    'tvshows' => MediaKind.show,
    'music' => MediaKind.artist,
    _ => MediaKind.unknown,
  };

  MediaVersion _mapExtSourceToVersion(Map<String, dynamic> ms) {
    final id = ttplayString(ms['id']) ?? '';
    return MediaVersion(
      id: id,
      width: ttplayInt(ms['width']),
      height: ttplayInt(ms['height']),
      videoCodec: ttplayString(ms['video_codec']),
      bitrate: bitrateKbpsFromBps(ttplayInt(ms['bitrate'])),
      container: ttplayString(ms['container']),
      name: ttplayString(ms['name']),
      description: ttplayString(ms['path']),
      parts: [
        MediaPart(
          id: id,
          file: ttplayString(ms['path']),
          sizeBytes: ttplayInt(ms['size']),
          container: ttplayString(ms['container']),
          durationMs: ttplayInt(ms['runtime_ms']),
          accessible: true,
          exists: true,
        ),
      ],
    );
  }

  MediaItem _mapExtItem(
    Map<String, dynamic> j, {
    Map<String, dynamic>? show,
    List<Map<String, dynamic>>? people,
    List<Map<String, dynamic>>? mediaSources,
    String? libraryId,
    String? libraryTitle,
  }) {
    final id = ttplayString(j['id']) ?? '';
    final kind = _kindOf(ttplayString(j['kind']));
    final isEpisode = kind == MediaKind.episode;
    final isSeason = kind == MediaKind.season;
    final isContainer = kind == MediaKind.show || kind == MediaKind.season || kind == MediaKind.collection;
    final watched = j['watched'] == true;
    final positionMs = ttplayInt(j['position_ms']) ?? 0;

    List<MediaRole>? roles;
    List<String>? directors;
    List<String>? writers;
    if (people != null && people.isNotEmpty) {
      roles = [];
      directors = [];
      writers = [];
      for (final p in people) {
        final name = ttplayString(p['name']);
        if (name == null) continue;
        final type = ttplayString(p['type'])?.toLowerCase() ?? 'actor';
        switch (type) {
          case 'director':
            directors.add(name);
          case 'writer':
            writers.add(name);
          default:
            roles.add(
              MediaRole(
                id: ttplayString(p['id']),
                tag: name,
                role: ttplayString(p['role']),
                thumbPath: ttplayString(p['photo_url']),
              ),
            );
        }
      }
    }

    final studios = (j['studios'] is List) ? (j['studios'] as List).whereType<String>().toList() : const <String>[];
    final genres = (j['genres'] is List) ? (j['genres'] as List).whereType<String>().toList() : null;
    final versions = mediaSources != null && mediaSources.isNotEmpty
        ? [for (final ms in mediaSources) _mapExtSourceToVersion(ms)]
        : null;

    final thumb = ttplayString(j['poster_url']) ?? ttplayString(j['thumb_url']);
    final backdrop = ttplayString(j['backdrop_url']) ?? ttplayString(show?['backdrop_url']);
    final childCount = ttplayInt(j['child_count']);
    final unplayed = ttplayInt(j['unplayed_count']);

    return MediaItem.jellyfin(
      dialect: _dialect,
      id: id,
      kind: kind,
      title: ttplayString(j['title']),
      originalTitle: ttplayString(j['original_title']),
      summary: ttplayString(j['overview']),
      tagline: ttplayString(j['tagline']),
      studio: studios.firstOrNull,
      year: ttplayInt(j['year']),
      originallyAvailableAt: ttplayString(j['premiere_date']),
      contentRating: ttplayString(j['official_rating']),
      parentId: ttplayString(j['season_id']) ?? ttplayString(j['series_id']),
      parentIndex: isEpisode ? ttplayInt(j['season_number']) : null,
      index: isEpisode ? ttplayInt(j['episode_number']) : (isSeason ? ttplayInt(j['season_number']) : null),
      grandparentId: isEpisode ? ttplayString(j['series_id']) : null,
      grandparentTitle: isEpisode ? (ttplayString(j['series_name']) ?? ttplayString(show?['title'])) : null,
      grandparentThumbPath: isEpisode ? ttplayString(show?['poster_url']) : null,
      grandparentArtPath: isEpisode ? ttplayString(show?['backdrop_url']) : null,
      thumbPath: thumb,
      artPath: backdrop,
      durationMs: ttplayInt(j['runtime_ms']),
      viewOffsetMs: positionMs > 0 ? positionMs : null,
      viewCount: isContainer ? null : (watched ? 1 : 0),
      childCount: childCount,
      leafCount: isContainer ? childCount : null,
      viewedLeafCount: (isContainer && childCount != null && unplayed != null)
          ? (childCount - unplayed).clamp(0, childCount)
          : null,
      rating: ttplayDouble(j['rating']),
      isFavorite: j['favorite'] == true,
      genres: genres,
      directors: directors,
      writers: writers,
      roles: roles,
      mediaVersions: versions,
      libraryId: libraryId,
      libraryTitle: libraryTitle ?? (libraryId == null ? null : _viewTitles[libraryId]),
      serverId: serverId.toString(),
      serverName: serverName,
    );
  }

  // ─── Libraries & Hubs ──────────────────────────────────────────────────

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final resp = await api.getJson('$_extPrefix/home');
    final home = ttplayMap(resp['home']) ?? const {};
    final libraries = <MediaLibrary>[];
    for (final view in ttplayMapList(home['views'])) {
      final id = ttplayString(view['id']);
      final name = ttplayString(view['name']);
      if (id == null || name == null) continue;
      final collectionType = ttplayString(view['collection_type']) ?? '';
      _viewCollectionTypes[id] = collectionType;
      _viewTitles[id] = name;
      libraries.add(
        MediaLibrary(
          id: id,
          backend: backend,
          title: name,
          kind: _viewKind(collectionType),
          serverId: serverId.toString(),
          serverName: serverName,
        ),
      );
    }
    return libraries;
  }

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [
    MediaSort(key: 'added', descKey: 'added:desc', title: t.libraries.sortLabels.dateAdded, defaultDirection: 'desc'),
    MediaSort(key: 'title', descKey: 'title:desc', title: t.libraries.sortLabels.title, defaultDirection: 'asc'),
    MediaSort(key: 'year', descKey: 'year:desc', title: t.libraries.sortLabels.productionYear, defaultDirection: 'desc'),
    MediaSort(key: 'rating', descKey: 'rating:desc', title: t.libraries.sortLabels.rating, defaultDirection: 'desc'),
  ];

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final sortField = query.sort?.field.split(':').first ?? 'added';
    final wireSort = switch (sortField) {
      'addedAt' || 'added' => 'added',
      'year' => 'year',
      'rating' => 'rating',
      _ => 'title',
    };
    final descending = query.sort == null
        ? (wireSort != 'title')
        : query.sort!.direction == LibrarySortDirection.descending || query.sort!.field.endsWith(':desc');

    String? filter;
    for (final f in query.filters) {
      final val = f.values.firstOrNull;
      final negated = f.op.isNegated;
      switch (f.field) {
        case MediaFilterField.unwatched:
          final wantUnwatched = (val == '1' || val == 'true') != negated;
          filter = wantUnwatched ? 'unplayed' : 'played';
        case MediaFilterField.favorite:
          if ((val == '1' || val == 'true') && !negated) filter = 'favorite';
      }
    }

    final types = switch (query.kind ?? libraryKind) {
      MediaKind.movie => 'Movie',
      MediaKind.show => 'Series',
      MediaKind.collection => 'BoxSet',
      _ => null,
    };
    final collectionType = _viewCollectionTypes[libraryId];
    final search = [query.search, query.nameStartsWith].whereType<String>().where((s) => s.isNotEmpty).firstOrNull;

    final resp = await api.getJson(
      '$_extPrefix/items',
      query: {
        'parent_id': libraryId,
        if (collectionType != null && collectionType.isNotEmpty) 'collection_type': collectionType,
        'types': ?types,
        'sort': wireSort,
        'order': descending ? 'desc' : 'asc',
        'offset': '${query.offset}',
        'limit': '${query.limit}',
        'filter': ?filter,
        'q': ?search,
      },
      abort: abort,
    );

    final items = [
      for (final row in ttplayMapList(resp['items']))
        _mapExtItem(row, libraryId: libraryId, libraryTitle: _viewTitles[libraryId]),
    ];
    return LibraryPage(
      items: items,
      totalCount: ttplayInt(resp['total']) ?? items.length,
      offset: query.offset,
    );
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    return LibraryFilterResult(
      filters: [
        MediaFilter(
          filter: MediaFilterField.unwatched,
          filterType: MediaFilterType.boolean,
          key: 'ttplayext:unwatched',
          title: t.libraries.filterCategories.unwatched,
          type: 'filter',
          operators: const [LibraryFilterOperator.is_, LibraryFilterOperator.isNot],
        ),
        MediaFilter(
          filter: MediaFilterField.favorite,
          filterType: MediaFilterType.boolean,
          key: 'ttplayext:favorite',
          title: t.libraries.filterCategories.favorites,
          type: 'filter',
          operators: const [LibraryFilterOperator.is_],
        ),
      ],
      cachedValues: const {},
    );
  }

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async => const [];

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {}

  @override
  Future<void> scanLibrary(String libraryId) async {}

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    final resp = await api.getJson('$_extPrefix/home');
    final home = ttplayMap(resp['home']) ?? const {};
    final items = [for (final row in ttplayMapList(home['resume'])) _mapExtItem(row)];
    if (count != null && items.length > count) return items.take(count).toList();
    return items;
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    try {
      final resp = await api.getJson('$_extPrefix/home');
      final home = ttplayMap(resp['home']) ?? const {};
      final hubs = <MediaHub>[];

      for (final view in ttplayMapList(home['views'])) {
        final id = ttplayString(view['id']);
        final name = ttplayString(view['name']);
        if (id != null && name != null) {
          _viewCollectionTypes[id] = ttplayString(view['collection_type']) ?? '';
          _viewTitles[id] = name;
        }
      }

      if (includePlaybackHubs) {
        final resume = [for (final row in ttplayMapList(home['resume'])) _mapExtItem(row)];
        if (resume.isNotEmpty) {
          final sliced = resume.take(limit).toList();
          hubs.add(
            MediaHub(
              id: 'ttplay.ext.${server.id}.resume',
              identifier: 'home.continue',
              title: t.discover.continueWatching,
              type: 'mixed',
              items: sliced,
              size: resume.length,
              more: resume.length > sliced.length,
              serverId: serverId.toString(),
              serverName: serverName,
            ),
          );
        }
      }

      for (final group in ttplayMapList(home['latest_by_view'])) {
        final view = ttplayMap(group['view']);
        final viewId = ttplayString(view?['id']);
        final viewName = ttplayString(view?['name']);
        if (viewId == null || viewName == null) continue;
        final colType = ttplayString(view?['collection_type']);
        final items = [
          for (final row in ttplayMapList(group['items'])) _mapExtItem(row, libraryId: viewId, libraryTitle: viewName),
        ];
        if (items.isEmpty) continue;
        final sliced = items.take(limit).toList();
        hubs.add(
          MediaHub(
            id: 'ttplay.ext.${server.id}.latest.$viewId',
            title: t.discover.recentlyAdded,
            type: colType == 'movies' ? 'movie' : 'show',
            items: sliced,
            size: sliced.length,
            more: items.length >= limit,
            libraryId: viewId,
            serverId: serverId.toString(),
            serverName: serverName,
          ),
        );
      }
      return hubs;
    } catch (e) {
      diagnostics?.recordFailure(e);
      return const [];
    }
  }

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    try {
      final colType = _viewCollectionTypes[libraryId];
      final resp = await api.getJson(
        '$_extPrefix/items',
        query: {
          'parent_id': libraryId,
          if (colType != null && colType.isNotEmpty) 'collection_type': colType,
          'sort': 'added',
          'order': 'desc',
          'limit': '$limit',
        },
      );
      final items = [
        for (final row in ttplayMapList(resp['items']))
          _mapExtItem(row, libraryId: libraryId, libraryTitle: libraryName),
      ];
      if (items.isEmpty) return const [];
      return [
        MediaHub(
          id: 'ttplay.ext.${server.id}.latest.$libraryId',
          title: t.discover.recentlyAdded,
          type: libraryKind == MediaKind.movie ? 'movie' : 'show',
          items: items,
          size: items.length,
          more: (ttplayInt(resp['total']) ?? items.length) > items.length,
          libraryId: libraryId,
          serverId: serverId.toString(),
          serverName: serverName,
        ),
      ];
    } catch (e) {
      diagnostics?.recordFailure(e);
      return const [];
    }
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    final resumePrefix = 'ttplay.ext.${server.id}.resume';
    final latestPrefix = 'ttplay.ext.${server.id}.latest.';
    if (hubId == resumePrefix) return fetchContinueWatching(count: limit ?? 100);
    if (hubId.startsWith(latestPrefix)) {
      final viewId = hubId.substring(latestPrefix.length);
      final resp = await api.getJson(
        '$_extPrefix/items',
        query: {
          'parent_id': viewId,
          if (_viewCollectionTypes[viewId]?.isNotEmpty == true) 'collection_type': _viewCollectionTypes[viewId]!,
          'sort': 'added',
          'order': 'desc',
          'limit': '${limit ?? 100}',
        },
      );
      return [
        for (final row in ttplayMapList(resp['items']))
          _mapExtItem(row, libraryId: viewId, libraryTitle: _viewTitles[viewId]),
      ];
    }
    return const [];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = await fetchMoreHubItems(hubId);
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      totalCount: all.length,
      offset: offset,
    );
  }

  // ─── Items & Children ──────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _fetchExtDetailMap(String id) async {
    try {
      final resp = await api.getJson('$_extPrefix/items/${Uri.encodeComponent(id)}');
      return ttplayMap(resp['detail']);
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    final detail = await _fetchExtDetailMap(id);
    if (detail == null) return null;
    final item = ttplayMap(detail['item']);
    if (item == null) return null;
    return _mapExtItem(
      item,
      show: ttplayMap(detail['show']),
      people: ttplayMapList(detail['people']),
      mediaSources: ttplayMapList(detail['media_sources']),
    );
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final detail = await _fetchExtDetailMap(id);
    final rawItem = ttplayMap(detail?['item']);
    if (detail == null || rawItem == null) return (item: null, onDeckEpisode: null);
    final item = _mapExtItem(
      rawItem,
      show: ttplayMap(detail['show']),
      people: ttplayMapList(detail['people']),
      mediaSources: ttplayMapList(detail['media_sources']),
    );
    onItemReady?.call(item);
    final onDeckRaw = ttplayMap(detail['on_deck_episode']);
    final onDeck = onDeckRaw == null ? null : _mapExtItem(onDeckRaw, show: rawItem);
    return (item: item, onDeckEpisode: onDeck);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final detail = await _fetchExtDetailMap(parentId);
    if (detail == null) return const [];
    final parentItem = ttplayMap(detail['item']);
    final show = ttplayMap(detail['show']) ?? parentItem;
    final seasons = ttplayMapList(detail['seasons']);
    if (seasons.isNotEmpty) {
      return [for (final s in seasons) _mapExtItem(s, show: show)];
    }
    final episodes = ttplayMapList(detail['episodes']);
    if (episodes.isNotEmpty) {
      return [for (final ep in episodes) _mapExtItem(ep, show: show)];
    }
    return [for (final c in ttplayMapList(detail['children'])) _mapExtItem(c, show: show)];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = await fetchChildren(parentId);
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      totalCount: all.length,
      offset: offset,
    );
  }

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final detail = await _fetchExtDetailMap(parentId);
    if (detail == null) return const [];
    final show = ttplayMap(detail['show']) ?? ttplayMap(detail['item']);
    final episodes = ttplayMapList(detail['episodes']);
    if (episodes.isNotEmpty) {
      return [for (final ep in episodes) _mapExtItem(ep, show: show)];
    }
    final children = [
      for (final c in ttplayMapList(detail['children']))
        if (ttplayString(c['kind']) != 'show' && ttplayString(c['kind']) != 'season') _mapExtItem(c, show: show),
    ];
    if (children.isNotEmpty) return children;
    final item = ttplayMap(detail['item']);
    return item == null ? const [] : [_mapExtItem(item, show: show)];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = await fetchPlayableDescendants(parentId);
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      totalCount: all.length,
      offset: offset,
    );
  }

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) => fetchPlayableDescendants(seriesId);

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    final detail = await _fetchExtDetailMap(id);
    if (detail == null) return const [];
    final similar = [for (final s in ttplayMapList(detail['similar'])) _mapExtItem(s)];
    if (similar.isEmpty) return const [];
    return [
      MediaHub(
        id: 'ttplay.ext.${server.id}.similar.$id',
        title: t.discover.moreLikeThis,
        type: 'mixed',
        items: similar.take(count).toList(),
        size: similar.length,
        serverId: serverId.toString(),
        serverName: serverName,
      ),
    ];
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  Future<List<MediaItem>> fetchLibraryFolders(
    String libraryId, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  Future<bool> deleteMediaItem(MediaItem item) async => false;

  // ─── Search & People ───────────────────────────────────────────────────

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final resp = await api.getJson('$_extPrefix/search', query: {'q': q}, abort: abort);
    final results = ttplayMap(resp['results']) ?? const {};
    return [
      for (final key in const ['movies', 'shows', 'episodes', 'collections'])
        for (final row in ttplayMapList(results[key])) _mapExtItem(row),
    ];
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async =>
      MediaPersonDetails.empty;

  // ─── Watch state & Playback reporting ──────────────────────────────────

  @override
  Future<void> markWatched(MediaItem item) async {
    await api.postJson('$_extPrefix/items/${Uri.encodeComponent(item.id)}/watched', body: const {'watched': true});
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {
    await api.postJson('$_extPrefix/items/${Uri.encodeComponent(item.id)}/watched', body: const {'watched': false});
  }

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    throw UnsupportedError('External servers proxied through TTPlay do not support hiding Continue Watching');
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    await api.postJson('$_extPrefix/items/${Uri.encodeComponent(item.id)}/favorite', body: {'favorite': isFavorite});
  }

  Future<void> _report({
    required String state,
    required String itemId,
    required Duration position,
    bool isPaused = false,
    String? mediaSourceId,
    String? playSessionId,
    String? playMethod,
  }) async {
    await api.postJson(
      '$_extPrefix/playback/report',
      body: {
        'state': state,
        'item_id': itemId,
        if (mediaSourceId != null && mediaSourceId.isNotEmpty) 'media_source_id': mediaSourceId,
        if (playSessionId != null && playSessionId.isNotEmpty) 'play_session_id': playSessionId,
        'position_ms': position.inMilliseconds,
        'is_paused': isPaused,
        if (playMethod != null && playMethod.isNotEmpty) 'play_method': playMethod,
      },
    );
  }

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) => _report(
    state: 'start',
    itemId: itemId,
    position: position,
    mediaSourceId: mediaSourceId,
    playSessionId: playSessionId,
    playMethod: playMethod,
  );

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) => _report(
    state: 'progress',
    itemId: itemId,
    position: position,
    isPaused: isPaused,
    mediaSourceId: mediaSourceId,
    playSessionId: playSessionId,
    playMethod: playMethod,
  );

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) => _report(
    state: 'stop',
    itemId: itemId,
    position: position,
    mediaSourceId: mediaSourceId,
    playSessionId: playSessionId,
  );

  // ─── Artwork ───────────────────────────────────────────────────────────

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null) return '';
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final abs = api.resolveAbsoluteUrl(trimmed, appendToken: trimmed.startsWith('/api/v1/') || trimmed.contains('/api/v1/ext/'));
    if (width != null && width > 0 && abs.contains('/api/v1/ext/')) {
      final uri = Uri.tryParse(abs);
      if (uri != null) {
        return uri.replace(queryParameters: {...uri.queryParameters, 'maxWidth': '$width'}).toString();
      }
    }
    return abs;
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) =>
      thumbnailUrl(url, width: width, height: height, cover: cover);

  // ─── Playback & FileInfo ───────────────────────────────────────────────

  Future<Map<String, dynamic>> _fetchExtPlaybackInfo(String itemId, {String? sourceId}) {
    return api.getJson(
      '$_extPrefix/playback/${Uri.encodeComponent(itemId)}',
      query: {if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId},
    );
  }

  @override
  Future<bool> offersStreamQualities(MediaItem item, {String? mediaSourceId}) async {
    try {
      final qualities = await streamQualitiesOf(item, mediaSourceId: mediaSourceId);
      return qualities.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<StreamQuality>> streamQualitiesOf(MediaItem item, {String? mediaSourceId}) async {
    final info = await _fetchExtPlaybackInfo(item.id, sourceId: mediaSourceId);
    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) return const [];
    final picked = _pickExtVersion(
      versions,
      requestedSourceId: mediaSourceId,
      serverSourceId: ttplayString(info['selected_source_id']),
    );
    final variants = ttplayMapList(picked.version['variants']);
    return [
      for (final v in variants)
        if (ttplayString(v['id']) case final vid? when vid != StreamQuality.original)
          StreamQuality(id: vid, width: ttplayInt(v['width']), height: ttplayInt(v['height'])),
    ];
  }

  ({Map<String, dynamic> version, int index}) _pickExtVersion(
    List<Map<String, dynamic>> versions, {
    String? requestedSourceId,
    String? serverSourceId,
    int selectedIndex = 0,
  }) {
    if (requestedSourceId != null && requestedSourceId.isNotEmpty) {
      final idx = versions.indexWhere((v) => ttplayString(v['source_id']) == requestedSourceId);
      if (idx >= 0) return (version: versions[idx], index: idx);
    }
    if (serverSourceId != null && serverSourceId.isNotEmpty) {
      final idx = versions.indexWhere((v) => ttplayString(v['source_id']) == serverSourceId);
      if (idx >= 0) return (version: versions[idx], index: idx);
    }
    final clamped = selectedIndex.clamp(0, versions.length - 1);
    return (version: versions[clamped], index: clamped);
  }

  List<PlaybackSubtitleSidecar> _mapExtSubtitles(List<Map<String, dynamic>> subs) {
    final out = <PlaybackSubtitleSidecar>[];
    for (final s in subs) {
      final vttUrl = ttplayString(s['vtt_url']);
      if (vttUrl == null) continue;
      final language = ttplayString(s['language']);
      final fileName = ttplayString(s['file_name']);
      out.add(
        PlaybackSubtitleSidecar(
          sourceStreamId: ttplayInt(s['index']),
          track: SubtitleTrack.uri(
            api.resolveAbsoluteUrl(vttUrl),
            title: fileName ?? language ?? 'Subtitle',
            language: language,
            codec: ttplayString(s['ext']),
          ),
        ),
      );
    }
    return out;
  }

  MediaVersion _mapExtPlaybackVersion(Map<String, dynamic> v) {
    final id = ttplayString(v['source_id']) ?? '';
    return MediaVersion(
      id: id,
      width: ttplayInt(v['width']),
      height: ttplayInt(v['height']),
      videoCodec: ttplayString(v['video_codec']),
      bitrate: bitrateKbpsFromBps(ttplayInt(v['bitrate'])),
      container: ttplayString(v['container']),
      name: ttplayString(v['label']),
      parts: [
        MediaPart(
          id: id,
          sizeBytes: ttplayInt(v['size']),
          container: ttplayString(v['container']),
          accessible: true,
          exists: true,
        ),
      ],
    );
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final Map<String, dynamic> info;
    try {
      info = await _fetchExtPlaybackInfo(options.metadata.id, sourceId: options.selectedMediaSourceId);
    } catch (e) {
      throw classifyPlaybackFailure(e);
    }

    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) {
      throw const PlaybackException('No playable source available', reason: PlaybackFailureReason.noPlayableSource);
    }

    final picked = _pickExtVersion(
      versions,
      requestedSourceId: options.selectedMediaSourceId,
      serverSourceId: ttplayString(info['selected_source_id']),
      selectedIndex: options.selectedMediaIndex,
    );
    final chosen = picked.version;
    final chosenSourceId = ttplayString(chosen['source_id']) ?? '';
    final variants = ttplayMapList(chosen['variants']);
    final streamQualities = [
      for (final v in variants)
        if (ttplayString(v['id']) case final vid?)
          StreamQuality(id: vid, width: ttplayInt(v['width']), height: ttplayInt(v['height'])),
    ];

    String chosenQuality = StreamQuality.original;
    String? relUrl = ttplayString(chosen['stream_url']);
    var isTranscoding = false;
    if (options.streamQuality != StreamQuality.original) {
      final matched = variants.where((v) => ttplayString(v['id']) == options.streamQuality).firstOrNull;
      final variantUrl = ttplayString(matched?['stream_url']);
      if (matched != null && variantUrl != null) {
        chosenQuality = ttplayString(matched['id']) ?? StreamQuality.original;
        relUrl = variantUrl;
        isTranscoding = true;
      }
    }

    final videoUrl = relUrl == null ? '' : api.resolveAbsoluteUrl(relUrl);
    if (videoUrl.isEmpty) {
      throw const PlaybackException('Missing stream URL', reason: PlaybackFailureReason.noPlayableSource);
    }

    final sidecars = _mapExtSubtitles(ttplayMapList(info['subtitles']));
    final availableVersions = [for (final v in versions) _mapExtPlaybackVersion(v)];

    return PlaybackInitializationResult(
      availableVersions: availableVersions,
      videoUrl: videoUrl,
      mediaInfo: MediaSourceInfo(
        videoUrl: videoUrl,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        mediaSourceId: chosenSourceId,
        mediaIndex: picked.index,
      ),
      subtitleSidecars: sidecars,
      isTranscoding: isTranscoding,
      playSessionId: ttplayString(info['play_session_id']),
      playMethod: isTranscoding ? 'Transcode' : 'DirectStream',
      selectedMediaIndex: picked.index,
      selectedMediaSourceId: chosenSourceId,
      streamQualities: streamQualities,
      streamQuality: chosenQuality,
    );
  }

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final info = await _fetchExtPlaybackInfo(item.id, sourceId: mediaSourceId);
    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) return null;
    final picked = _pickExtVersion(
      versions,
      requestedSourceId: mediaSourceId,
      serverSourceId: ttplayString(info['selected_source_id']),
      selectedIndex: mediaIndex,
    );
    final streamUrl = ttplayString(picked.version['stream_url']);
    if (streamUrl == null) return null;
    final sidecars = _mapExtSubtitles(ttplayMapList(info['subtitles']));
    return ExternalPlaybackTarget(
      url: api.resolveAbsoluteUrl(streamUrl),
      subtitles: [for (final s in sidecars) s.track],
    );
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final info = await _fetchExtPlaybackInfo(item.id, sourceId: mediaSourceId);
    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) return const DownloadResolution(videoUrl: null);
    final picked = _pickExtVersion(
      versions,
      requestedSourceId: mediaSourceId,
      serverSourceId: ttplayString(info['selected_source_id']),
      selectedIndex: mediaIndex,
    );
    final streamUrl = ttplayString(picked.version['stream_url']);
    if (streamUrl == null) return const DownloadResolution(videoUrl: null);
    return DownloadResolution(
      videoUrl: api.resolveAbsoluteUrl(streamUrl),
      mediaSourceId: ttplayString(picked.version['source_id']),
      externalSubtitles: [
        for (final s in ttplayMapList(info['subtitles']))
          if (ttplayString(s['vtt_url']) case final subUrl?)
            DownloadSubtitleSpec(
              id: ttplayInt(s['index']) ?? 0,
              url: api.resolveAbsoluteUrl(subUrl),
              codec: ttplayString(s['ext']),
              language: ttplayString(s['language']),
              languageCode: ttplayString(s['language']),
              displayTitle: ttplayString(s['file_name']) ?? ttplayString(s['language']),
            ),
      ],
    );
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => [
    for (final (key, path) in [('thumb', item.thumbPath), ('art', item.artPath)])
      if (thumbnailUrl(path) case final String url when url.isNotEmpty) DownloadArtworkSpec(localKey: key, url: url),
  ];

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async {
    final detail = await _fetchExtDetailMap(item.id);
    final sources = ttplayMapList(detail?['media_sources']);
    if (sources.isEmpty) return null;
    return MediaFileInfo(
      versions: [
        for (final ms in sources)
          MediaFileVersion(
            id: ttplayString(ms['id']),
            title: ttplayString(ms['name']),
            container: ttplayString(ms['container']),
            bitrateKbps: bitrateKbpsFromBps(ttplayInt(ms['bitrate'])),
            durationMs: ttplayInt(ms['runtime_ms']),
            width: ttplayInt(ms['width']),
            height: ttplayInt(ms['height']),
            videoCodec: ttplayString(ms['video_codec']),
            parts: [
              MediaFilePart(
                id: ttplayString(ms['id']),
                filePath: ttplayString(ms['path']),
                fileSize: ttplayInt(ms['size']),
                container: ttplayString(ms['container']),
                durationMs: ttplayInt(ms['runtime_ms']),
                exists: true,
                accessible: true,
              ),
            ],
          ),
      ],
    );
  }

  // ─── Non-applicable / Unsupported capabilities ─────────────────────────

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) async => null;

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) async => false;

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async => false;

  @override
  Future<bool> deleteCollection(MediaItem collection) async => false;

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => null;

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async => null;

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) async => false;

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async => false;

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async => false;

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async => false;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
  }) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async => null;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async => const ExternalIds();

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => null;

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async => const [];

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) async => const [];

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async => const [];

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) async => const [];

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async => null;
}

class _ExtNoLiveTv implements LiveTvSupport {
  const _ExtNoLiveTv();

  @override
  Future<bool> isAvailable() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Live TV is not supported on proxied external servers');
}
