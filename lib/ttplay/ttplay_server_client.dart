import 'dart:async';

import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../library/local_library_client.dart';
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
import '../session/app_session_models.dart';
import '../storage/storage_path.dart';
import '../utils/external_ids.dart';
import '../utils/global_key_utils.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'ttplay_api_client.dart';
import 'ttplay_event_channel.dart';

/// Populates localized shelf and sort titles on [client] from `t`.
void configureTtplayServerClientLabels(TtplayServerClient client) {
  client
    ..shelfTitles = {
      'movie': t.storage.content.movie,
      'show': t.storage.content.show,
      'anime': t.storage.content.anime,
      'variety': t.storage.content.variety,
      'documentary': t.storage.content.documentary,
      'pending': t.storage.unmatchedTitles,
    }
    ..sortTitles = {
      'title': t.storage.sortTitle,
      'year': t.storage.sortYear,
      'releaseDate': t.storage.sortReleaseDate,
      'rating': t.storage.sortRating,
      'addedAt': t.storage.sortAddedAt,
      'lastPlayed': t.storage.sortLastPlayed,
    }
    ..recentlyAddedAllTitle = t.discover.recentlyAdded
    ..recentlyAddedTitle = t.storage.recentlyAdded(shelf: '{shelf}')
    ..continueWatchingTitle = t.storage.continueWatching;
}

/// Primary [MediaServerClient] talking to the user's self-hosted `ttplay-server`.
class TtplayServerClient implements MediaServerClient {
  TtplayServerClient({
    required this.api,
    required this.session,
    this.includePendingShelf = true,
    this.onRawEvent,
    ServerId? serverIdOverride,
  }) : _serverId = serverIdOverride ?? ServerId(primaryServerId),
       serverName = (session.serverName?.isNotEmpty == true)
           ? session.serverName
           : (Uri.tryParse(session.serverUrl)?.host ?? 'TTPlay Server');

  static const String primaryServerId = 'ttplay-server';
  static String get pendingLibraryGlobalKey => buildGlobalKey(ServerId(primaryServerId), 'pending');
  static bool isPendingLibrary(MediaLibrary library) =>
      library.serverId == primaryServerId && library.id == 'pending';

  static const List<String> shelves = LocalLibraryClient.shelves;
  static const String _hubContinue = 'ttplay.continuewatching';
  static const String _hubRecentAll = 'ttplay.recent';
  static const String _hubRecentPrefix = 'ttplay.recent.';
  static const String _collectionPrefix = 'list-';

  final TtplayApiClient api;
  final SelfHostedSession session;
  final bool includePendingShelf;
  final void Function(String event, Map<String, dynamic> data)? onRawEvent;
  final ServerId _serverId;

  bool _offlineMode = false;
  bool _closed = false;

  Map<String, String> shelfTitles = const {
    'movie': 'Movies',
    'show': 'TV Shows',
    'anime': 'Anime',
    'variety': 'Variety',
    'documentary': 'Documentaries',
    'pending': 'Unmatched',
  };

  Map<String, String> sortTitles = const {
    'title': 'Title',
    'year': 'Year',
    'releaseDate': 'Release date',
    'rating': 'Rating',
    'addedAt': 'Date added',
    'lastPlayed': 'Last played',
  };

  String recentlyAddedAllTitle = 'Recently Added';
  String recentlyAddedTitle = 'Recently added in {shelf}';
  String continueWatchingTitle = 'Continue watching';

  @override
  ServerId get serverId => _serverId;

  @override
  String? serverName;

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  final Object authenticationSessionId = Object();

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    videoTranscoding: false,
    userFavorites: true,
    continueWatchingRemoval: true,
    folderGrouping: false,
    richHubs: true,
    richMetadataEdit: true,
    libraryChangeEvents: true,
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
  LiveTvSupport get liveTv => const _TtplayNoLiveTv();

  @override
  LibraryEventChannel? createLibraryEventChannel() => TtplayEventChannel(
    serverId: serverId,
    baseUrl: api.baseUrl,
    accessToken: api.accessToken,
    onRawEvent: onRawEvent,
  );

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    api.close();
  }

  @override
  Future<HealthStatus> checkHealth() => api.checkHealth();

  @override
  Future<String?> getMachineIdentifier() async => primaryServerId;

  // ─── Mapping helpers ───────────────────────────────────────────────────

  static MediaKind _kindOf(String? raw) => switch (raw?.toLowerCase()) {
    'movie' => MediaKind.movie,
    'show' => MediaKind.show,
    'season' => MediaKind.season,
    'episode' => MediaKind.episode,
    'collection' => MediaKind.collection,
    'playlist' => MediaKind.playlist,
    _ => MediaKind.unknown,
  };

  static int? _epochSeconds(int? value) {
    if (value == null || value <= 0) return null;
    return value > 100000000000 ? value ~/ 1000 : value;
  }

  static LibraryPage<MediaItem> _slicePage(List<MediaItem> all, int? start, int? size) {
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      totalCount: all.length,
      offset: offset,
    );
  }

  MediaVersion _mapFileToVersion(Map<String, dynamic> file) {
    final id = '${ttplayInt(file['id']) ?? ttplayString(file['id']) ?? ''}';
    final path = ttplayString(file['path']) ?? '';
    final ext = StoragePath.extension(path);
    final container = ttplayString(file['container']) ?? (ext.isEmpty ? null : ext);
    final mountName = ttplayString(file['mount_name']);
    final versionLabel = ttplayString(file['version_label']);
    final titleParts = [?mountName, ?versionLabel];
    return MediaVersion(
      id: id,
      width: ttplayInt(file['width']),
      height: ttplayInt(file['height']),
      videoCodec: ttplayString(file['video_codec']),
      bitrate: ttplayInt(file['bitrate_kbps']),
      container: container,
      name: titleParts.isEmpty ? null : titleParts.join(' · '),
      description: path.isEmpty ? null : path,
      parts: [
        MediaPart(
          id: id,
          file: path.isEmpty ? null : path,
          sizeBytes: ttplayInt(file['size']),
          container: container,
          durationMs: ttplayInt(file['duration_ms']),
          accessible: true,
          exists: true,
        ),
      ],
    );
  }

  MediaItem _mapItem(
    Map<String, dynamic> j, {
    Map<String, dynamic>? show,
    Map<String, dynamic>? parent,
    List<String>? genres,
    List<Map<String, dynamic>>? credits,
    List<Map<String, dynamic>>? files,
  }) {
    final id = '${ttplayInt(j['id']) ?? ttplayString(j['id']) ?? ''}';
    final rawKind = ttplayString(j['kind']);
    final kind = _kindOf(rawKind);
    final isEpisode = kind == MediaKind.episode;
    final isSeason = kind == MediaKind.season;
    final isContainer = kind == MediaKind.show || kind == MediaKind.season;
    final libraryType = ttplayString(j['library_type']);
    final watchState = ttplayMap(j['watch_state']);
    final watched = watchState?['watched'] == true;
    final playCount = ttplayInt(watchState?['play_count']) ?? 0;
    final positionMs = ttplayInt(watchState?['position_ms']) ?? 0;

    List<MediaRole>? roles;
    List<String>? directors;
    List<String>? writers;
    if (credits != null && credits.isNotEmpty) {
      roles = [];
      directors = [];
      writers = [];
      for (final c in credits) {
        final person = ttplayMap(c['person']);
        final name = ttplayString(person?['name']);
        if (name == null) continue;
        final job = ttplayString(c['job'])?.toLowerCase();
        switch (job) {
          case 'actor':
            roles.add(
              MediaRole(
                id: person?['id'] != null ? '${person!['id']}' : null,
                tag: name,
                role: ttplayString(c['character']),
                thumbPath: ttplayString(person?['photo_source']),
              ),
            );
          case 'director':
            directors.add(name);
          case 'writer':
            writers.add(name);
        }
      }
    }

    List<MediaVersion>? versions;
    if (files != null && files.isNotEmpty) {
      versions = [
        for (final f in files)
          if (ttplayString(f['role']) == null || ttplayString(f['role']) == 'video') _mapFileToVersion(f),
      ];
      if (versions.isEmpty) versions = null;
    }

    final showId = ttplayInt(j['show_id']);
    final parentId = ttplayInt(j['parent_id']);
    final poster = ttplayString(j['poster_source']) ?? (isSeason ? ttplayString(parent?['poster_source']) : null);
    final backdrop =
        ttplayString(j['backdrop_source']) ??
        ttplayString(show?['backdrop_source']) ??
        ttplayString(j['show_backdrop']) ??
        ttplayString(parent?['backdrop_source']);
    final logo = ttplayString(j['logo_source']) ?? ttplayString(show?['logo_source']);

    final episodeCount = ttplayInt(j['episode_count']);
    final watchedEpCount = ttplayInt(j['watched_episode_count']);

    return MediaItem.jellyfin(
      id: id,
      kind: kind,
      title: ttplayString(j['title']),
      titleSort: ttplayString(j['sort_title']),
      originalTitle: ttplayString(j['original_title']),
      summary: ttplayString(j['summary']),
      tagline: ttplayString(j['tagline']),
      studio: ttplayString(j['studio']),
      year: ttplayInt(j['year']),
      originallyAvailableAt: ttplayString(j['release_date']),
      contentRating: ttplayString(j['content_rating']),
      parentId: parentId?.toString(),
      parentTitle: ttplayString(parent?['title']),
      parentThumbPath: ttplayString(parent?['poster_source']),
      parentIndex: isEpisode ? ttplayInt(j['season_number']) : null,
      index: isEpisode ? ttplayInt(j['episode_number']) : (isSeason ? ttplayInt(j['season_number']) : null),
      grandparentId: isEpisode ? showId?.toString() : null,
      grandparentTitle: isEpisode ? (ttplayString(j['show_title']) ?? ttplayString(show?['title'])) : null,
      grandparentThumbPath: isEpisode ? (ttplayString(j['show_poster']) ?? ttplayString(show?['poster_source'])) : null,
      grandparentArtPath: isEpisode ? (ttplayString(j['show_backdrop']) ?? ttplayString(show?['backdrop_source'])) : null,
      thumbPath: poster,
      artPath: backdrop,
      clearLogoPath: logo,
      durationMs: ttplayInt(j['runtime_ms']) ?? ttplayInt(watchState?['duration_ms']),
      viewOffsetMs: positionMs > 0 ? positionMs : null,
      viewCount: isContainer ? null : (watched ? (playCount == 0 ? 1 : playCount) : 0),
      lastViewedAt: _epochSeconds(ttplayInt(watchState?['last_played_at'])),
      leafCount: isContainer ? episodeCount : null,
      viewedLeafCount: isContainer ? watchedEpCount : null,
      addedAt: _epochSeconds(ttplayInt(j['source_added_at'])) ?? _epochSeconds(ttplayInt(j['added_at'])),
      updatedAt: _epochSeconds(ttplayInt(j['updated_at'])),
      rating: ttplayDouble(j['rating']),
      isFavorite: watchState?['favorite'] == true,
      genres: genres,
      directors: directors,
      writers: writers,
      roles: roles,
      mediaVersions: versions,
      libraryId: libraryType,
      libraryTitle: libraryType == null ? null : (shelfTitles[libraryType] ?? libraryType),
      serverId: serverId.toString(),
      serverName: serverName,
    );
  }

  // ─── Libraries & Hubs ──────────────────────────────────────────────────

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final resp = await api.getJson('/api/v1/home');
    final home = ttplayMap(resp['home']) ?? const {};
    final counts = ttplayMap(home['counts']) ?? const {};
    final unmatchedCount = ttplayInt(home['unmatched_count']) ?? 0;

    final libraries = <MediaLibrary>[];
    for (final shelf in shelves) {
      if ((ttplayInt(counts[shelf]) ?? 0) <= 0) continue;
      libraries.add(
        MediaLibrary(
          id: shelf,
          backend: backend,
          title: shelfTitles[shelf] ?? shelf,
          kind: shelf == 'movie' ? MediaKind.movie : MediaKind.show,
          serverId: serverId.toString(),
          serverName: serverName,
        ),
      );
    }
    if (includePendingShelf && unmatchedCount > 0) {
      libraries.add(
        MediaLibrary(
          id: 'pending',
          backend: backend,
          title: shelfTitles['pending'] ?? 'Unmatched',
          kind: MediaKind.unknown,
          serverId: serverId.toString(),
          serverName: serverName,
        ),
      );
    }
    return libraries;
  }

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [
    for (final key in const ['title', 'year', 'releaseDate', 'rating', 'addedAt', 'lastPlayed'])
      MediaSort(
        key: key,
        descKey: '$key:desc',
        title: sortTitles[key] ?? key,
        defaultDirection: key == 'title' ? 'asc' : 'desc',
      ),
  ];

  static String? _shelfKind(String libraryId, MediaKind? requested) {
    if (requested == MediaKind.movie) return 'movie';
    if (requested == MediaKind.show) return libraryId == 'show' ? 'show' : null;
    return switch (libraryId) {
      'movie' => 'movie',
      'show' => 'show',
      _ => null,
    };
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final sortRaw = query.sort?.field.split(':').first ?? 'title';
    final serverSort = switch (sortRaw) {
      'addedAt' => 'added_at',
      'releaseDate' => 'release_date',
      'lastPlayed' => 'last_played',
      'year' => 'year',
      'rating' => 'rating',
      _ => 'title',
    };
    final descending = query.sort == null
        ? false
        : query.sort!.direction == LibrarySortDirection.descending || query.sort!.field.endsWith(':desc');

    String? genreId;
    String? year;
    String? watched;
    var favorite = false;
    for (final filter in query.filters) {
      final value = filter.values.firstOrNull;
      final negated = filter.op.isNegated;
      switch (filter.field) {
        case MediaFilterField.genre:
          genreId = value;
        case MediaFilterField.year:
          year = value;
        case MediaFilterField.unwatched:
          final wantUnwatched = (value == '1' || value == 'true') != negated;
          watched = wantUnwatched ? '0' : '1';
        case MediaFilterField.favorite:
          favorite = (value == '1' || value == 'true') && !negated;
      }
    }

    final kind = _shelfKind(libraryId, query.kind ?? libraryKind);
    final resp = await api.getJson(
      '/api/v1/library/items',
      query: {
        'shelf': libraryId,
        'kind': ?kind,
        'sort': serverSort,
        'order': descending ? 'desc' : 'asc',
        'offset': '${query.offset}',
        'limit': '${query.limit}',
        if (genreId != null && genreId.isNotEmpty) 'genre_id': genreId,
        if (year != null && year.isNotEmpty) 'year': year,
        'watched': ?watched,
        if (favorite) 'favorite': '1',
        if (query.search != null && query.search!.trim().isNotEmpty) 'search': query.search!.trim(),
        if (query.nameStartsWith != null && query.nameStartsWith!.isNotEmpty) 'letter': query.nameStartsWith!,
      },
      abort: abort,
    );

    final items = [for (final row in ttplayMapList(resp['items'])) _mapItem(row)];
    return LibraryPage(
      items: items,
      totalCount: ttplayInt(resp['total']) ?? items.length,
      offset: query.offset,
    );
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    const booleanOperators = [LibraryFilterOperator.is_, LibraryFilterOperator.isNot];
    const valueOperators = [LibraryFilterOperator.is_];
    final filters = <MediaFilter>[
      MediaFilter(
        filter: MediaFilterField.unwatched,
        filterType: MediaFilterType.boolean,
        key: 'ttplay:unwatched',
        title: t.libraries.filterCategories.unwatched,
        type: 'filter',
        operators: booleanOperators,
      ),
      MediaFilter(
        filter: MediaFilterField.favorite,
        filterType: MediaFilterType.boolean,
        key: 'ttplay:favorite',
        title: t.libraries.filterCategories.favorites,
        type: 'filter',
        operators: valueOperators,
      ),
    ];

    try {
      final resp = await api.getJson('/api/v1/library/facets', query: {'shelf': libraryId});
      final facets = ttplayMap(resp['facets']) ?? const {};
      final cachedValues = <String, List<MediaFilterValue>>{};

      final genreValues = [
        for (final g in ttplayMapList(facets['genres']))
          if (ttplayInt(g['id']) != null && ttplayString(g['name']) != null)
            MediaFilterValue(key: '${g['id']}', title: ttplayString(g['name'])!),
      ];
      if (genreValues.isNotEmpty) {
        filters.add(
          MediaFilter(
            filter: MediaFilterField.genre,
            filterType: MediaFilterType.tag,
            key: 'ttplay:genre',
            title: t.libraries.filterCategories.genre,
            type: 'filter',
            operators: valueOperators,
          ),
        );
        cachedValues[MediaFilterField.genre] = genreValues;
      }

      final rawYears = facets['years'];
      if (rawYears is List) {
        final yearValues = [
          for (final y in rawYears)
            if (ttplayInt(y) case final yr?) MediaFilterValue(key: '$yr', title: '$yr'),
        ];
        if (yearValues.isNotEmpty) {
          filters.add(
            MediaFilter(
              filter: MediaFilterField.year,
              filterType: MediaFilterType.integer,
              key: 'ttplay:year',
              title: t.libraries.filterCategories.year,
              type: 'filter',
              operators: valueOperators,
            ),
          );
          cachedValues[MediaFilterField.year] = yearValues;
        }
      }
      return LibraryFilterResult(filters: filters, cachedValues: cachedValues);
    } catch (_) {
      return LibraryFilterResult(filters: filters, cachedValues: const {});
    }
  }

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async {
    final resp = await api.getJson('/api/v1/library/facets', query: {'shelf': libraryId});
    final facets = ttplayMap(resp['facets']) ?? const {};
    return [
      for (final g in ttplayMapList(facets['genres']))
        if (ttplayInt(g['id']) != null && ttplayString(g['name']) != null)
          LibraryGenre(title: ttplayString(g['name'])!, filterValue: '${g['id']}'),
    ];
  }

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {
    await api.postJson('/api/v1/tasks/scrape', query: {'refresh_all': '1'});
  }

  @override
  Future<void> scanLibrary(String libraryId) async {
    await api.postJson('/api/v1/tasks/scan-all');
  }

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    final resp = await api.getJson('/api/v1/home');
    final home = ttplayMap(resp['home']) ?? const {};
    final items = [
      for (final row in ttplayMapList(home['continue_watching']))
        if (!excludedLibraryIds.contains(ttplayString(row['library_type']))) _mapItem(row),
    ];
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
      final resp = await api.getJson('/api/v1/home');
      final home = ttplayMap(resp['home']) ?? const {};
      final hubs = <MediaHub>[];

      if (includePlaybackHubs) {
        final resume = [for (final row in ttplayMapList(home['continue_watching'])) _mapItem(row)];
        if (resume.isNotEmpty) {
          final sliced = resume.take(limit).toList();
          hubs.add(
            MediaHub(
              id: _hubContinue,
              title: continueWatchingTitle,
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

      final recentAll = [for (final row in ttplayMapList(home['recent_all'])) _mapItem(row)];
      if (recentAll.isNotEmpty) {
        final sliced = recentAll.take(limit).toList();
        hubs.add(
          MediaHub(
            id: _hubRecentAll,
            title: recentlyAddedAllTitle,
            type: 'mixed',
            items: sliced,
            size: sliced.length,
            more: recentAll.length >= limit,
            serverId: serverId.toString(),
            serverName: serverName,
          ),
        );
      }

      for (final shelfMap in ttplayMapList(home['shelves'])) {
        final key = ttplayString(shelfMap['key']);
        if (key == null) continue;
        final shelfItems = [for (final row in ttplayMapList(shelfMap['items'])) _mapItem(row)];
        if (shelfItems.isEmpty) continue;
        final sliced = shelfItems.take(limit).toList();
        final localizedTitle = shelfTitles[key] ?? ttplayString(shelfMap['title']) ?? key;
        hubs.add(
          MediaHub(
            id: '$_hubRecentPrefix$key',
            title: recentlyAddedTitle.replaceAll('{shelf}', localizedTitle),
            type: key == 'movie' ? 'movie' : 'show',
            items: sliced,
            size: sliced.length,
            more: shelfItems.length >= limit,
            libraryId: key,
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
      final resp = await api.getJson(
        '/api/v1/library/items',
        query: {'shelf': libraryId, 'sort': 'added_at', 'order': 'desc', 'limit': '$limit'},
      );
      final items = [for (final row in ttplayMapList(resp['items'])) _mapItem(row)];
      if (items.isEmpty) return const [];
      return [
        MediaHub(
          id: '$_hubRecentPrefix$libraryId',
          title: recentlyAddedTitle.replaceAll('{shelf}', shelfTitles[libraryId] ?? libraryName),
          type: libraryId == 'movie' ? 'movie' : 'show',
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
    if (hubId == _hubContinue) return fetchContinueWatching(count: limit ?? 100);
    if (hubId == _hubRecentAll) {
      final resp = await api.getJson(
        '/api/v1/library/items',
        query: {'sort': 'added_at', 'order': 'desc', 'limit': '${limit ?? 200}'},
      );
      return [for (final row in ttplayMapList(resp['items'])) _mapItem(row)];
    }
    if (hubId.startsWith(_hubRecentPrefix)) {
      final shelf = hubId.substring(_hubRecentPrefix.length);
      final resp = await api.getJson(
        '/api/v1/library/items',
        query: {'shelf': shelf, 'sort': 'added_at', 'order': 'desc', 'limit': '${limit ?? 200}'},
      );
      return [for (final row in ttplayMapList(resp['items'])) _mapItem(row)];
    }
    return const [];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slicePage(await fetchMoreHubItems(hubId), start, size);

  // ─── Items & Children ──────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _fetchItemDetailMap(String id) async {
    try {
      final resp = await api.getJson('/api/v1/items/$id');
      return ttplayMap(resp['detail']);
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  MediaItem _mapDetailToItem(Map<String, dynamic> detail) {
    final itemMap = ttplayMap(detail['item']) ?? const {};
    final genreNames = [
      for (final g in ttplayMapList(detail['genres'])) ?ttplayString(g['name']),
    ];
    return _mapItem(
      itemMap,
      show: ttplayMap(detail['show']),
      parent: ttplayMap(detail['parent']),
      genres: genreNames,
      credits: ttplayMapList(detail['credits']),
      files: ttplayMapList(detail['files']),
    );
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    if (id.startsWith(_collectionPrefix)) {
      final listId = _listId(id);
      if (listId == null) return null;
      try {
        final resp = await api.getJson('/api/v1/lists/$listId');
        final list = ttplayMap(resp['list']);
        return list == null ? null : _collectionItem(list);
      } on MediaServerHttpException catch (e) {
        if (e.statusCode == 404) return null;
        rethrow;
      }
    }
    final detail = await _fetchItemDetailMap(id);
    return detail == null ? null : _mapDetailToItem(detail);
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final detail = await _fetchItemDetailMap(id);
    if (detail == null) return (item: null, onDeckEpisode: null);
    final item = _mapDetailToItem(detail);
    onItemReady?.call(item);
    final onDeckMap = ttplayMap(detail['on_deck_episode']);
    final onDeck = onDeckMap == null ? null : _mapItem(onDeckMap, show: ttplayMap(detail['item']));
    return (item: item, onDeckEpisode: onDeck);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    if (parentId.startsWith(_collectionPrefix)) {
      final listId = _listId(parentId);
      if (listId == null) return const [];
      final resp = await api.getJson('/api/v1/lists/$listId');
      final list = ttplayMap(resp['list']);
      return [for (final row in ttplayMapList(list?['items'])) _mapItem(row)];
    }
    final detail = await _fetchItemDetailMap(parentId);
    if (detail == null) return const [];
    final seasons = ttplayMapList(detail['seasons']);
    if (seasons.isNotEmpty) {
      return [for (final s in seasons) _mapItem(s, parent: ttplayMap(detail['item']), show: ttplayMap(detail['item']))];
    }
    final episodes = ttplayMapList(detail['episodes']);
    final itemMap = ttplayMap(detail['item']);
    final showMap = ttplayMap(detail['show']) ?? (ttplayString(itemMap?['kind']) == 'show' ? itemMap : null);
    return [for (final ep in episodes) _mapItem(ep, parent: itemMap, show: showMap)];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slicePage(await fetchChildren(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final detail = await _fetchItemDetailMap(parentId);
    if (detail == null) return const [];
    final episodes = ttplayMapList(detail['episodes']);
    if (episodes.isNotEmpty) {
      final itemMap = ttplayMap(detail['item']);
      final showMap = ttplayMap(detail['show']) ?? (ttplayString(itemMap?['kind']) == 'show' ? itemMap : null);
      return [for (final ep in episodes) _mapItem(ep, show: showMap)];
    }
    return [_mapDetailToItem(detail)];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slicePage(await fetchPlayableDescendants(parentId), start, size);

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) => fetchPlayableDescendants(seriesId);

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    final detail = await _fetchItemDetailMap(id);
    if (detail == null) return const [];
    final similar = [for (final s in ttplayMapList(detail['similar'])) _mapItem(s)];
    if (similar.isEmpty) return const [];
    return [
      MediaHub(
        id: 'ttplay.similar.$id',
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
    final resp = await api.getJson('/api/v1/search', query: {'q': q, 'limit': '$limit'}, abort: abort);
    final results = ttplayMap(resp['results']) ?? const {};
    final out = <MediaItem>[];
    for (final key in const ['movies', 'shows', 'episodes']) {
      for (final row in ttplayMapList(results[key])) {
        final lib = ttplayString(row['library_type']);
        if (lib != null && excludedLibraryIds.contains(lib)) continue;
        out.add(_mapItem(row));
      }
    }
    return out;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final resp = await api.getJson('/api/v1/search', query: {'q': q, 'limit': '$limit'}, abort: abort);
    final results = ttplayMap(resp['results']) ?? const {};
    return [
      for (final p in ttplayMapList(results['people']))
        if (ttplayString(p['name']) case final name?)
          MediaPerson(
            id: '${ttplayInt(p['id']) ?? ttplayString(p['id']) ?? ''}',
            name: name,
            thumbPath: ttplayString(p['photo_source']),
            backend: backend,
            serverId: serverId,
            serverName: serverName,
          ),
    ];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final resp = await api.getJson('/api/v1/people/$personId', abort: abort);
    final detail = ttplayMap(resp['detail']) ?? const {};
    final items = [for (final row in ttplayMapList(detail['items'])) _mapItem(row)];
    return _slicePage(items, start, size);
  }

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async {
    final resp = await api.getJson('/api/v1/people/$personId', abort: abort);
    final detail = ttplayMap(resp['detail']) ?? const {};
    final person = ttplayMap(detail['person']);
    if (person == null) return MediaPersonDetails.empty;
    return MediaPersonDetails(
      biography: ttplayString(person['biography']),
      birthDate: MediaPersonDetails.parseDate(person['birthday']),
      birthPlace: ttplayString(person['place_of_birth']),
    );
  }

  // ─── Watch state & Progress ────────────────────────────────────────────

  @override
  Future<void> markWatched(MediaItem item) async {
    await api.postJson('/api/v1/items/${item.id}/watched', body: const {'watched': true});
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {
    await api.postJson('/api/v1/items/${item.id}/watched', body: const {'watched': false});
  }

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    await api.postJson('/api/v1/items/${item.id}/hide-continue');
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    await api.postJson('/api/v1/items/${item.id}/favorite', body: {'favorite': isFavorite});
  }

  Future<void> _sendProgress(String itemId, Duration position, Duration? duration, String? mediaSourceId) async {
    if (_closed) return;
    final parsedItem = int.tryParse(itemId);
    if (parsedItem == null) return;
    final parsedFile = mediaSourceId == null ? null : int.tryParse(mediaSourceId);
    await api.postJson(
      '/api/v1/playback/progress',
      body: {
        'item_id': parsedItem,
        'file_id': ?parsedFile,
        'position_ms': position.inMilliseconds,
        if (duration != null) 'duration_ms': duration.inMilliseconds,
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
  }) => _sendProgress(itemId, position, duration, mediaSourceId);

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
  }) => _sendProgress(itemId, position, duration, mediaSourceId);

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
  }) => _sendProgress(itemId, position, duration, mediaSourceId);

  // ─── Collections & Playlists ───────────────────────────────────────────

  static String? _listId(String id) => id.startsWith(_collectionPrefix) ? id.substring(_collectionPrefix.length) : id;

  MediaItem _collectionItem(Map<String, dynamic> list) {
    final id = '${ttplayInt(list['id']) ?? ttplayString(list['id']) ?? ''}';
    final count = ttplayInt(list['item_count']) ?? ttplayMapList(list['items']).length;
    return MediaItem.jellyfin(
      id: '$_collectionPrefix$id',
      kind: MediaKind.collection,
      title: ttplayString(list['title']),
      summary: ttplayString(list['summary']),
      thumbPath: ttplayString(list['poster_source']),
      childCount: count,
      leafCount: count,
      serverId: serverId.toString(),
      serverName: serverName,
    );
  }

  MediaPlaylist _mapPlaylist(Map<String, dynamic> list) => MediaPlaylist(
    id: '${ttplayInt(list['id']) ?? ttplayString(list['id']) ?? ''}',
    backend: backend,
    title: ttplayString(list['title']) ?? '',
    playlistType: 'video',
    summary: ttplayString(list['summary']),
    leafCount: ttplayInt(list['item_count']) ?? ttplayMapList(list['items']).length,
    addedAt: _epochSeconds(ttplayInt(list['created_at'])),
    updatedAt: _epochSeconds(ttplayInt(list['updated_at'])),
    thumbPath: ttplayString(list['poster_source']),
    serverId: serverId.toString(),
    serverName: serverName,
  );

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final resp = await api.getJson('/api/v1/lists', query: const {'kind': 'collection'}, abort: abort);
    final collections = [for (final l in ttplayMapList(resp['lists'])) _collectionItem(l)];
    return _slicePage(collections, start, size);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) async {
    final id = _listId(collectionId);
    if (id == null || id.isEmpty) return const LibraryPage(items: [], totalCount: 0);
    final resp = await api.getJson('/api/v1/lists/$id', abort: abort);
    final list = ttplayMap(resp['list']);
    final items = [for (final row in ttplayMapList(list?['items'])) _mapItem(row)];
    return _slicePage(items, start, size);
  }

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) async {
    final ids = [for (final i in items) ?int.tryParse(i.id)];
    final resp = await api.postJson(
      '/api/v1/lists',
      body: {'kind': 'collection', 'title': title, if (ids.isNotEmpty) 'item_ids': ids},
    );
    final list = ttplayMap(resp['list']);
    final id = ttplayInt(list?['id']);
    return id == null ? null : '$_collectionPrefix$id';
  }

  Future<bool> _addToList(String listId, List<MediaItem> items) async {
    final id = _listId(listId);
    if (id == null || id.isEmpty) return false;
    final ids = [for (final i in items) ?int.tryParse(i.id)];
    if (ids.isEmpty) return true;
    await api.postJson('/api/v1/lists/$id/items', body: {'item_ids': ids});
    return true;
  }

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) =>
      _addToList(collectionId, items);

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async {
    final id = _listId(collectionId);
    if (id == null || id.isEmpty) return false;
    await api.deleteJson('/api/v1/lists/$id/items/${item.id}');
    return true;
  }

  @override
  Future<bool> deleteCollection(MediaItem collection) async {
    final id = _listId(collection.id);
    if (id == null || id.isEmpty) return false;
    await api.deleteJson('/api/v1/lists/$id');
    return true;
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    if (playlistType != 'video' || smart == true) return const LibraryPage(items: [], totalCount: 0);
    final resp = await api.getJson('/api/v1/lists', query: const {'kind': 'playlist'}, abort: abort);
    final all = [for (final l in ttplayMapList(resp['lists'])) _mapPlaylist(l)];
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(items: offset >= all.length ? const [] : all.sublist(offset, end), totalCount: all.length, offset: offset);
  }

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async {
    final listId = _listId(id);
    if (listId == null || listId.isEmpty) return null;
    try {
      final resp = await api.getJson('/api/v1/lists/$listId');
      final list = ttplayMap(resp['list']);
      return list == null ? null : _mapPlaylist(list);
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      fetchCollectionPage(id, start: start, size: size, abort: abort);

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async {
    final ids = [for (final i in items) ?int.tryParse(i.id)];
    final resp = await api.postJson(
      '/api/v1/lists',
      body: {'kind': 'playlist', 'title': title, if (ids.isNotEmpty) 'item_ids': ids},
    );
    final list = ttplayMap(resp['list']);
    return list == null ? null : _mapPlaylist(list);
  }

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) =>
      _addToList(playlistId, items);

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async {
    final id = _listId(playlist.id);
    if (id == null || id.isEmpty) return false;
    await api.deleteJson('/api/v1/lists/$id');
    return true;
  }

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async {
    final id = _listId(playlistId);
    if (id == null || id.isEmpty) return false;
    final resp = await api.getJson('/api/v1/lists/$id');
    final list = ttplayMap(resp['list']);
    final current = [for (final row in ttplayMapList(list?['items'])) ?ttplayInt(row['id'])];
    final targetId = int.tryParse(item.id);
    if (targetId == null || !current.remove(targetId)) return false;
    current.insert(newIndex.clamp(0, current.length), targetId);
    await api.putJson('/api/v1/lists/$id/reorder', body: {'item_ids': current});
    return true;
  }

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async {
    final id = _listId(playlistId);
    if (id == null || id.isEmpty) return false;
    await api.deleteJson('/api/v1/lists/$id/items/${item.id}');
    return true;
  }

  // ─── Artwork ───────────────────────────────────────────────────────────

  static String _tmdbSizeFor(int? width, bool cover) {
    if (!cover && (width == null || width >= 1000)) return 'original';
    if (width == null) return 'w500';
    if (width <= 200) return 'w185';
    if (width <= 400) return 'w342';
    if (width <= 700) return 'w500';
    if (width <= 1000) return 'w780';
    return 'w1280';
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null) return '';
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('mount:')) {
      final rest = trimmed.substring('mount:'.length);
      final sep = rest.indexOf(':');
      if (sep <= 0) return '';
      final mountId = rest.substring(0, sep);
      final filePath = rest.substring(sep + 1);
      final tok = api.accessToken.isEmpty ? '' : '&token=${Uri.encodeQueryComponent(api.accessToken)}';
      return '${api.baseUrl}/api/v1/artwork/local/${Uri.encodeComponent(mountId)}'
          '?path=${Uri.encodeQueryComponent(filePath)}$tok';
    }
    if (trimmed.startsWith('/api/v1/')) {
      return api.resolveAbsoluteUrl(trimmed, appendToken: true);
    }
    final size = _tmdbSizeFor(width, cover);
    final tok = api.accessToken.isEmpty ? '' : '&token=${Uri.encodeQueryComponent(api.accessToken)}';
    return '${api.baseUrl}/api/v1/artwork/remote?src=${Uri.encodeQueryComponent(trimmed)}&size=$size$tok';
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) =>
      thumbnailUrl(url, width: width, height: height, cover: cover);

  // ─── Playback & FileInfo ───────────────────────────────────────────────

  Future<Map<String, dynamic>> _fetchPlaybackInfo(String itemId, {String? fileId}) {
    return api.getJson('/api/v1/playback/info/$itemId', query: {if (fileId != null && fileId.isNotEmpty) 'file_id': fileId});
  }

  ({Map<String, dynamic> version, int index}) _pickPlaybackVersion(
    List<Map<String, dynamic>> versions, {
    String? selectedSourceId,
    int? serverSelectedFileId,
    int selectedIndex = 0,
  }) {
    if (selectedSourceId != null && selectedSourceId.isNotEmpty) {
      final idx = versions.indexWhere((v) {
        final f = ttplayMap(v['file']);
        return '${ttplayInt(f?['id']) ?? ''}' == selectedSourceId;
      });
      if (idx >= 0) return (version: versions[idx], index: idx);
    }
    if (serverSelectedFileId != null) {
      final idx = versions.indexWhere((v) => ttplayInt(ttplayMap(v['file'])?['id']) == serverSelectedFileId);
      if (idx >= 0) return (version: versions[idx], index: idx);
    }
    final clamped = selectedIndex.clamp(0, versions.length - 1);
    return (version: versions[clamped], index: clamped);
  }

  List<PlaybackSubtitleSidecar> _mapSubtitleSidecars(List<Map<String, dynamic>> subs) {
    final out = <PlaybackSubtitleSidecar>[];
    for (final s in subs) {
      final rawUrl = ttplayString(s['raw_url']);
      final vttUrl = ttplayString(s['vtt_url']);
      final url = rawUrl ?? vttUrl;
      if (url == null) continue;
      final language = ttplayString(s['language']);
      final fileName = ttplayString(s['file_name']);
      final ext = ttplayString(s['ext']);
      out.add(
        PlaybackSubtitleSidecar(
          sourceStreamId: ttplayInt(s['id']),
          track: SubtitleTrack.uri(
            api.resolveAbsoluteUrl(url),
            title: language ?? fileName ?? 'Subtitle',
            language: language,
            codec: ext,
          ),
        ),
      );
    }
    return out;
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final Map<String, dynamic> info;
    try {
      info = await _fetchPlaybackInfo(options.metadata.id, fileId: options.selectedMediaSourceId);
    } catch (e) {
      throw classifyPlaybackFailure(e);
    }

    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) {
      throw const PlaybackException('No playable source available', reason: PlaybackFailureReason.noPlayableSource);
    }

    final picked = _pickPlaybackVersion(
      versions,
      selectedSourceId: options.selectedMediaSourceId,
      serverSelectedFileId: ttplayInt(info['selected_file_id']),
      selectedIndex: options.selectedMediaIndex,
    );
    final chosen = picked.version;
    final chosenFile = ttplayMap(chosen['file']) ?? const {};
    final chosenFileId = '${ttplayInt(chosenFile['id']) ?? ttplayString(chosenFile['id']) ?? ''}';

    final variants = ttplayMapList(chosen['variants']);
    final streamQualities = [
      for (final v in variants)
        if (ttplayString(v['id']) case final vid?)
          StreamQuality(id: vid, width: ttplayInt(v['width']), height: ttplayInt(v['height'])),
    ];

    String chosenQuality = StreamQuality.original;
    String? relStreamUrl = ttplayString(chosen['stream_url']);
    var isTranscoding = false;
    if (options.streamQuality != StreamQuality.original) {
      final matched = variants.where((v) => ttplayString(v['id']) == options.streamQuality).firstOrNull;
      final variantUrl = ttplayString(matched?['stream_url']);
      if (matched != null && variantUrl != null) {
        chosenQuality = ttplayString(matched['id']) ?? StreamQuality.original;
        relStreamUrl = variantUrl;
        isTranscoding = matched['is_hls'] == true;
      }
    }

    final videoUrl = relStreamUrl == null ? '' : api.resolveAbsoluteUrl(relStreamUrl);
    if (videoUrl.isEmpty) {
      throw const PlaybackException('Missing stream URL', reason: PlaybackFailureReason.noPlayableSource);
    }

    final availableVersions = [
      for (final v in versions)
        if (ttplayMap(v['file']) case final file?) _mapFileToVersion(file),
    ];
    final sidecars = _mapSubtitleSidecars(ttplayMapList(info['subtitles']));

    return PlaybackInitializationResult(
      availableVersions: availableVersions,
      videoUrl: videoUrl,
      mediaInfo: MediaSourceInfo(
        videoUrl: videoUrl,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        mediaSourceId: chosenFileId,
        mediaIndex: picked.index,
      ),
      subtitleSidecars: sidecars,
      isTranscoding: isTranscoding,
      playMethod: isTranscoding || chosenQuality != StreamQuality.original ? 'DirectStream' : 'DirectPlay',
      selectedMediaIndex: picked.index,
      selectedMediaSourceId: chosenFileId,
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
    final info = await _fetchPlaybackInfo(item.id, fileId: mediaSourceId);
    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) return null;
    final picked = _pickPlaybackVersion(
      versions,
      selectedSourceId: mediaSourceId,
      serverSelectedFileId: ttplayInt(info['selected_file_id']),
      selectedIndex: mediaIndex,
    );
    final streamUrl = ttplayString(picked.version['stream_url']);
    if (streamUrl == null) return null;
    final sidecars = _mapSubtitleSidecars(ttplayMapList(info['subtitles']));
    return ExternalPlaybackTarget(
      url: api.resolveAbsoluteUrl(streamUrl),
      subtitles: [for (final s in sidecars) s.track],
    );
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final info = await _fetchPlaybackInfo(item.id, fileId: mediaSourceId);
    final versions = ttplayMapList(info['versions']);
    if (versions.isEmpty) return const DownloadResolution(videoUrl: null);
    final picked = _pickPlaybackVersion(
      versions,
      selectedSourceId: mediaSourceId,
      serverSelectedFileId: ttplayInt(info['selected_file_id']),
      selectedIndex: mediaIndex,
    );
    final chosenFile = ttplayMap(picked.version['file']) ?? const {};
    final chosenFileId = '${ttplayInt(chosenFile['id']) ?? ttplayString(chosenFile['id']) ?? ''}';
    final streamUrl = ttplayString(picked.version['stream_url']);
    if (streamUrl == null) return const DownloadResolution(videoUrl: null);

    return DownloadResolution(
      videoUrl: api.resolveAbsoluteUrl(streamUrl),
      mediaSourceId: chosenFileId,
      externalSubtitles: [
        for (final s in ttplayMapList(info['subtitles']))
          if ((ttplayString(s['raw_url']) ?? ttplayString(s['vtt_url'])) case final subUrl?)
            DownloadSubtitleSpec(
              id: ttplayInt(s['id']) ?? 0,
              url: api.resolveAbsoluteUrl(subUrl),
              codec: ttplayString(s['ext']),
              language: ttplayString(s['language']),
              languageCode: ttplayString(s['language']),
              displayTitle: ttplayString(s['language']) ?? ttplayString(s['file_name']),
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
    final detail = await _fetchItemDetailMap(item.id);
    if (detail == null) return null;
    final files = [
      for (final f in ttplayMapList(detail['files']))
        if (ttplayString(f['role']) == null || ttplayString(f['role']) == 'video') f,
    ];
    if (files.isEmpty) return null;
    final subtitles = ttplayMapList(detail['subtitles']);
    return MediaFileInfo(
      versions: [
        for (final f in files) _toFileVersion(f, subtitles),
      ],
    );
  }

  MediaFileVersion _toFileVersion(Map<String, dynamic> file, List<Map<String, dynamic>> subtitles) {
    final path = ttplayString(file['path']) ?? '';
    final ext = StoragePath.extension(path);
    final container = ttplayString(file['container']) ?? (ext.isEmpty ? null : ext);
    final mountName = ttplayString(file['mount_name']);
    final versionLabel = ttplayString(file['version_label']);
    final rawStreams = ttplayMapList(file['streams']);
    final audio = rawStreams.where((s) => ttplayString(s['kind']) == 'audio').firstOrNull;
    final video = rawStreams.where((s) => ttplayString(s['kind']) == 'video').firstOrNull;
    final frameRate = ttplayDouble(video?['frame_rate']);

    final ordinals = <MediaStreamKind, int>{};
    MediaStreamDetails buildStream(MediaStreamKind kind, MediaStreamDetails Function(int ordinal) fn) {
      final ord = (ordinals[kind] ?? 0) + 1;
      ordinals[kind] = ord;
      return fn(ord);
    }

    final streams = <MediaStreamDetails>[
      for (final s in rawStreams)
        if (_streamKind(ttplayString(s['kind'])) case final kind?)
          buildStream(
            kind,
            (ordinal) => MediaStreamDetails(
              kind: kind,
              ordinal: ordinal,
              index: ttplayInt(s['index']),
              codec: ttplayString(s['codec']),
              title: ttplayString(s['title']),
              language: ttplayString(s['language']),
              languageCode: ttplayString(s['language']),
              isDefault: s['default'] == true,
              isForced: s['forced'] == true,
              isExternal: false,
              width: ttplayInt(s['width']),
              height: ttplayInt(s['height']),
              frameRate: ttplayDouble(s['frame_rate']),
              videoRange: switch (ttplayString(s['hdr'])) {
                'hdr10' => MediaVideoRange.hdr10,
                'hlg' => MediaVideoRange.hlg,
                'dolbyVision' => MediaVideoRange.dolbyVision,
                _ => kind == MediaStreamKind.video ? MediaVideoRange.sdr : MediaVideoRange.unknown,
              },
              channels: ttplayInt(s['channels']),
              sampleRate: ttplayInt(s['sample_rate']),
              bitDepth: ttplayInt(s['bit_depth']),
            ),
          ),
      for (final sub in subtitles)
        buildStream(
          MediaStreamKind.subtitle,
          (ordinal) {
            final subPath = ttplayString(sub['path']) ?? '';
            return MediaStreamDetails(
              kind: MediaStreamKind.subtitle,
              ordinal: ordinal,
              title: StoragePath.name(subPath),
              codec: StoragePath.extension(subPath),
              language: ttplayString(sub['language']),
              languageCode: ttplayString(sub['language']),
              isExternal: true,
              filePath: subPath.isEmpty ? null : subPath,
            );
          },
        ),
    ];

    final titleParts = [?mountName, ?versionLabel];
    return MediaFileVersion(
      id: '${ttplayInt(file['id']) ?? ''}',
      title: titleParts.isEmpty ? null : titleParts.join(' · '),
      container: container,
      bitrateKbps: ttplayInt(file['bitrate_kbps']),
      durationMs: ttplayInt(file['duration_ms']),
      width: ttplayInt(file['width']),
      height: ttplayInt(file['height']),
      videoCodec: ttplayString(file['video_codec']),
      audioCodec: ttplayString(audio?['codec']),
      audioChannels: ttplayInt(audio?['channels']),
      videoFrameRateLabel: frameRate == null ? null : '$frameRate fps',
      parts: [
        MediaFilePart(
          id: '${ttplayInt(file['id']) ?? ''}',
          filePath: mountName == null ? path : '$mountName:$path',
          fileSize: ttplayInt(file['size']),
          container: container,
          durationMs: ttplayInt(file['duration_ms']),
          exists: true,
          accessible: true,
          streams: streams,
        ),
      ],
    );
  }

  static MediaStreamKind? _streamKind(String? raw) => switch (raw) {
    'video' => MediaStreamKind.video,
    'audio' => MediaStreamKind.audio,
    'subtitle' => MediaStreamKind.subtitle,
    _ => null,
  };

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
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final detail = await _fetchItemDetailMap(itemId);
    final item = ttplayMap(detail?['item']);
    if (item == null) return const ExternalIds();
    return ExternalIds(
      imdb: ttplayString(item['imdb_id']),
      tmdb: ttplayInt(item['tmdb_id']),
      tvdb: ttplayInt(item['tvdb_id']),
    );
  }

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => const [];

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

class _TtplayNoLiveTv implements LiveTvSupport {
  const _TtplayNoLiveTv();

  @override
  Future<bool> isAvailable() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Live TV is not supported on TTPlay self-hosted servers');
}
