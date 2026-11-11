import 'dart:async';

import '../database/app_database.dart';
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
import '../storage/mount_manager.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_mount.dart';
import '../storage/storage_path.dart';
import '../storage/stream_variant.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'library_repository.dart' as lib;
import 'scrapers/bangumi_provider.dart';

/// The local media library, presented to the app as a media server.
///
/// Every screen talks to a [MediaServerClient]; this one answers from the
/// library database and the mounts instead of from HTTP. Items take the
/// neutral MediaBrowser item shape, with library row ids as their ids.
class LocalLibraryClient implements MediaServerClient {
  LocalLibraryClient({required lib.LibraryRepository repository, required MountManager mounts})
    : _repo = repository,
      _mountManager = mounts;

  static const String localServerId = 'local-library';

  /// Shelf ids double as the `libraryType` stored on titles.
  static const List<String> shelves = lib.LibraryTypes.shelves;

  static const String _hubContinue = 'local.continuewatching';
  static const String _hubRecentPrefix = 'local.recent.';
  static const String _collectionPrefix = 'list-';
  static const int _pageSize = 50;

  final lib.LibraryRepository _repo;
  final MountManager _mountManager;
  Map<String, StorageMount> _mountsById = const {};

  /// Shelf titles are shown by the UI; the owner sets them from localized
  /// strings so this class stays free of presentation.
  Map<String, String> shelfTitles = const {
    'movie': 'Movies',
    'show': 'TV Shows',
    'anime': 'Anime',
    'variety': 'Variety',
    'documentary': 'Documentaries',
    'pending': 'Unmatched',
  };

  @override
  ServerId get serverId => ServerId(localServerId);

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
  );

  @override
  bool get isOfflineMode => false;

  @override
  void setOfflineMode(bool offline) {}

  @override
  ApiCache get cache => JellyfinApiCache.instance;

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  double get watchedThreshold => lib.LibraryRepository.watchedThreshold;

  /// Progress reports decide watched state themselves (see [reportPlaybackStopped]).
  @override
  bool get marksWatchedOnPlaybackStopped => true;

  @override
  LiveTvSupport get liveTv => const _NoLiveTv();

  /// Starts the stream proxy and loads the mounts. Call before first use and
  /// again whenever the set of mounts changes.
  Future<void> refreshMounts() async {
    await _mountManager.proxy.start();
    _mountsById = {for (final mount in await _mountManager.registry.list()) mount.id: mount};
  }

  @override
  void close() {}

  @override
  Future<HealthStatus> checkHealth() async => HealthStatus.online;

  @override
  Future<String?> getMachineIdentifier() async => localServerId;

  // ─── Mapping ───────────────────────────────────────────────────────────

  static int? _id(String? raw) => raw == null ? null : int.tryParse(raw);

  static MediaKind _kindOf(String kind) => switch (kind) {
    lib.LibraryKinds.movie => MediaKind.movie,
    lib.LibraryKinds.show => MediaKind.show,
    lib.LibraryKinds.season => MediaKind.season,
    lib.LibraryKinds.episode => MediaKind.episode,
    _ => MediaKind.unknown,
  };

  static int? _seconds(int? milliseconds) => milliseconds == null ? null : milliseconds ~/ 1000;

  /// Maps rows to items, loading each distinct parent and show once so
  /// seasons and episodes carry their ancestors' titles and artwork.
  Future<List<MediaItem>> _toItems(List<lib.LibraryItemView> views, {bool withDetails = false}) async {
    final ancestors = <int, LibraryItemRow>{};
    for (final view in views) {
      for (final id in [view.item.parentId, view.item.showId]) {
        if (id != null && !ancestors.containsKey(id)) {
          final row = (await _repo.getItem(id))?.item;
          if (row != null) ancestors[id] = row;
        }
      }
    }
    return [for (final view in views) await _toItem(view, ancestors, withDetails: withDetails)];
  }

  Future<MediaItem> _toItem(
    lib.LibraryItemView view,
    Map<int, LibraryItemRow> ancestors, {
    bool withDetails = false,
  }) async {
    final row = view.item;
    final state = view.state;
    final parent = row.parentId == null ? null : ancestors[row.parentId];
    final show = row.showId == null ? null : ancestors[row.showId];
    final isEpisode = row.kind == lib.LibraryKinds.episode;
    final isSeason = row.kind == lib.LibraryKinds.season;

    List<String>? genres;
    List<MediaRole>? roles;
    List<String>? directors;
    List<String>? writers;
    List<MediaVersion>? versions;
    if (withDetails) {
      // Episodes and seasons show their series' genres and cast.
      final detailId = show?.id ?? row.id;
      // Titles scraped before Bangumi's tags were cleaned still carry air
      // dates and formats ("2023", "TV") as genres.
      genres = [
        for (final genre in await _repo.genresOf(detailId))
          if (!BangumiProvider.isNoiseTag(genre.name)) genre.name,
      ];
      final credits = await _repo.creditsOf(detailId);
      roles = [
        for (final credit in credits.where((c) => c.job == 'actor'))
          MediaRole(
            id: '${credit.person.id}',
            tag: credit.person.name,
            role: credit.character,
            thumbPath: credit.person.photoSource,
          ),
      ];
      directors = [for (final c in credits.where((c) => c.job == 'director')) c.person.name];
      writers = [for (final c in credits.where((c) => c.job == 'writer')) c.person.name];
      if (row.kind == lib.LibraryKinds.movie || isEpisode) {
        versions = [for (final file in await _repo.versionsOf(row.id)) _toVersion(file)];
      }
    }

    return MediaItem.jellyfin(
      id: '${row.id}',
      kind: _kindOf(row.kind),
      title: row.title,
      titleSort: row.sortTitle,
      originalTitle: row.originalTitle,
      summary: row.summary,
      tagline: row.tagline,
      studio: row.studio,
      year: row.year,
      originallyAvailableAt: row.releaseDate,
      contentRating: row.contentRating,
      parentId: parent == null ? null : '${parent.id}',
      parentTitle: parent?.title,
      parentThumbPath: parent?.posterSource,
      parentIndex: isEpisode ? row.seasonNumber : null,
      index: isEpisode ? row.episodeNumber : (isSeason ? row.seasonNumber : null),
      grandparentId: isEpisode && show != null ? '${show.id}' : null,
      grandparentTitle: isEpisode ? show?.title : null,
      grandparentThumbPath: isEpisode ? show?.posterSource : null,
      grandparentArtPath: isEpisode ? show?.backdropSource : null,
      thumbPath: row.posterSource ?? (isSeason ? parent?.posterSource : null),
      artPath: row.backdropSource ?? show?.backdropSource ?? parent?.backdropSource,
      clearLogoPath: row.logoSource ?? show?.logoSource,
      durationMs: row.runtimeMs ?? state?.durationMs,
      viewOffsetMs: (state?.positionMs ?? 0) > 0 ? state!.positionMs : null,
      viewCount: view.isContainer
          ? null
          : (state?.watched ?? false ? (state!.playCount == 0 ? 1 : state.playCount) : 0),
      lastViewedAt: _seconds(state?.lastPlayedAt),
      leafCount: view.isContainer ? view.episodeCount : null,
      viewedLeafCount: view.isContainer ? view.watchedEpisodeCount : null,
      addedAt: _seconds(row.addedAt),
      updatedAt: _seconds(row.updatedAt),
      rating: row.rating,
      isFavorite: state?.favorite ?? false,
      genres: genres,
      directors: directors,
      writers: writers,
      roles: roles,
      mediaVersions: versions,
      libraryId: row.libraryType,
      libraryTitle: shelfTitles[row.libraryType],
      serverId: localServerId,
      serverName: serverName,
    );
  }

  MediaVersion _toVersion(LibraryFileRow file) {
    final extension = StoragePath.extension(file.path);
    return MediaVersion(
      id: '${file.id}',
      width: file.width,
      height: file.height,
      videoCodec: file.videoCodec,
      container: file.container ?? (extension.isEmpty ? null : extension),
      // The mount leads, so copies of one film on different sources read
      // apart at a glance; the path below says exactly which file it is.
      name: [?_mountsById[file.mountId]?.displayName, ?file.versionLabel].join(' · '),
      description: file.path,
      parts: [
        MediaPart(
          id: '${file.id}',
          file: file.path,
          sizeBytes: file.size,
          container: file.container ?? (extension.isEmpty ? null : extension),
          durationMs: file.durationMs,
          accessible: true,
          exists: true,
        ),
      ],
    );
  }

  Future<MediaItem?> _itemById(String id, {bool withDetails = false}) async {
    final itemId = _id(id);
    if (itemId == null) return null;
    final view = await _repo.getItem(itemId);
    return view == null ? null : (await _toItems([view], withDetails: withDetails)).single;
  }

  LibraryPage<MediaItem> _page(List<MediaItem> all, int? start, int? size) {
    final offset = start ?? 0;
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      totalCount: all.length,
      offset: offset,
    );
  }

  // ─── Libraries ─────────────────────────────────────────────────────────

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final libraries = <MediaLibrary>[];
    // Titles no source recognised (or not looked up yet) get a shelf of
    // their own, last, so they can be watched before they are matched.
    for (final shelf in [...shelves, lib.LibraryTypes.pending]) {
      final page = await _repo.queryTitles(lib.LibraryQuery(libraryType: shelf, limit: 1));
      // An empty shelf is not worth a tab.
      if (page.total == 0) continue;
      libraries.add(
        MediaLibrary(
          id: shelf,
          backend: backend,
          title: shelfTitles[shelf] ?? shelf,
          kind: shelf == 'movie' ? MediaKind.movie : MediaKind.show,
          serverId: localServerId,
          serverName: serverName,
        ),
      );
    }
    return libraries;
  }

  static const Map<String, lib.LibrarySort> _sorts = {
    'title': lib.LibrarySort.title,
    'year': lib.LibrarySort.year,
    'releaseDate': lib.LibrarySort.releaseDate,
    'rating': lib.LibrarySort.rating,
    'addedAt': lib.LibrarySort.addedAt,
    'lastPlayed': lib.LibrarySort.lastPlayed,
  };

  /// Sort titles shown by the UI; set by the owner from localized strings.
  Map<String, String> sortTitles = const {
    'title': 'Title',
    'year': 'Year',
    'releaseDate': 'Release date',
    'rating': 'Rating',
    'addedAt': 'Date added',
    'lastPlayed': 'Last played',
  };

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [
    for (final key in _sorts.keys)
      MediaSort(
        key: key,
        descKey: '$key:desc',
        title: sortTitles[key] ?? key,
        defaultDirection: key == 'title' ? 'asc' : 'desc',
      ),
  ];

  String? _shelfKind(String libraryId, MediaKind? requested) {
    // Anime, variety and documentaries mix series and films unless a kind
    // is asked for.
    if (requested == MediaKind.movie) return lib.LibraryKinds.movie;
    if (requested == MediaKind.show) return libraryId == 'show' ? lib.LibraryKinds.show : null;
    return switch (libraryId) {
      'movie' => lib.LibraryKinds.movie,
      'show' => lib.LibraryKinds.show,
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
    final sortField = query.sort?.field.split(':').first ?? 'title';
    final descending = query.sort == null
        ? false
        : query.sort!.direction == LibrarySortDirection.descending || query.sort!.field.endsWith(':desc');

    int? genreId;
    int? year;
    bool? watched;
    var favoritesOnly = false;
    for (final filter in query.filters) {
      final value = filter.values.firstOrNull;
      final negated = filter.op.isNegated;
      switch (filter.field) {
        case MediaFilterField.genre:
          genreId = int.tryParse(value ?? '');
        case MediaFilterField.year:
          year = int.tryParse(value ?? '');
        case MediaFilterField.unwatched:
          // "unwatched is true" keeps the unwatched; negating it flips that.
          watched = (value == '1' || value == 'true') == negated;
        case MediaFilterField.favorite:
          favoritesOnly = (value == '1' || value == 'true') && !negated;
      }
    }

    final search = [query.search, query.nameStartsWith].whereType<String>().where((s) => s.isNotEmpty).firstOrNull;
    final page = await _repo.queryTitles(
      lib.LibraryQuery(
        libraryType: libraryId,
        kind: _shelfKind(libraryId, query.kind ?? libraryKind),
        sort: _sorts[sortField] ?? lib.LibrarySort.title,
        descending: descending,
        genreId: genreId,
        year: year,
        watched: watched,
        favoritesOnly: favoritesOnly,
        search: search,
        offset: query.offset,
        limit: query.limit,
      ),
    );
    return LibraryPage(items: await _toItems(page.items), totalCount: page.total, offset: query.offset);
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async {
    final kind = _shelfKind(libraryId, libraryKind) ?? lib.LibraryKinds.show;
    return [
      for (final genre in await _repo.genresOnShelf(libraryType: libraryId, kind: kind))
        LibraryGenre(title: genre.name, filterValue: '${genre.id}'),
    ];
  }

  /// Rescans and re-scrapes are driven from the mount screens, not per shelf.
  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {}

  @override
  Future<void> scanLibrary(String libraryId) async {}

  // ─── Items ─────────────────────────────────────────────────────────────

  @override
  Future<MediaItem?> fetchItem(String id) => _itemById(id, withDetails: true);

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await _itemById(id, withDetails: true);
    if (item == null) return (item: null, onDeckEpisode: null);
    onItemReady?.call(item);
    MediaItem? onDeck;
    if (item.kind == MediaKind.show) {
      final next = await _repo.nextUnwatchedEpisode(int.parse(id));
      if (next != null) onDeck = (await _toItems([next])).single;
    }
    return (item: item, onDeckEpisode: onDeck);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final id = _id(parentId);
    return id == null ? const [] : _toItems(await _repo.children(id));
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _page(await fetchChildren(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final id = _id(parentId);
    if (id == null) return const [];
    final parent = await _repo.getItem(id);
    if (parent == null) return const [];
    return switch (parent.item.kind) {
      lib.LibraryKinds.show => _toItems(await _repo.episodesOfShow(id)),
      lib.LibraryKinds.season => _toItems(await _repo.children(id)),
      _ => _toItems([parent]),
    };
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _page(await fetchPlayableDescendants(parentId), start, size);

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) => fetchPlayableDescendants(seriesId);

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
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async => const [];

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  Future<bool> deleteMediaItem(MediaItem item) async => false;

  // ─── Search, hubs, home ────────────────────────────────────────────────

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final hits = await _repo.search(query, limit: limit);
    return _toItems(hits.where((v) => !excludedLibraryIds.contains(v.item.libraryType)).toList());
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    final rows = await _repo.continueWatching(limit: count ?? 50);
    return _toItems(rows.where((v) => !excludedLibraryIds.contains(v.item.libraryType)).toList());
  }

  /// Hub titles shown by the UI; `{shelf}` is replaced by the shelf's title.
  String recentlyAddedTitle = 'Recently added in {shelf}';
  String continueWatchingTitle = 'Continue watching';

  Future<MediaHub?> _recentHub(String shelf, int limit) async {
    final rows = await _repo.recentlyAdded(libraryType: shelf, limit: limit);
    if (rows.isEmpty) return null;
    return MediaHub(
      id: '$_hubRecentPrefix$shelf',
      title: recentlyAddedTitle.replaceAll('{shelf}', shelfTitles[shelf] ?? shelf),
      type: shelf == 'movie' ? 'movie' : 'show',
      items: await _toItems(rows),
      size: rows.length,
      more: rows.length >= limit,
      libraryId: shelf,
      serverId: localServerId,
      serverName: serverName,
    );
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    final hubs = <MediaHub>[];
    if (includePlaybackHubs) {
      final resume = await fetchContinueWatching(count: limit);
      if (resume.isNotEmpty) {
        hubs.add(
          MediaHub(
            id: _hubContinue,
            title: continueWatchingTitle,
            type: 'mixed',
            items: resume,
            size: resume.length,
            serverId: localServerId,
            serverName: serverName,
          ),
        );
      }
    }
    for (final shelf in shelves) {
      final hub = await _recentHub(shelf, limit);
      if (hub != null) hubs.add(hub);
    }
    return hubs;
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
    final hub = await _recentHub(libraryId, limit);
    return [?hub];
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    if (hubId == _hubContinue) return fetchContinueWatching(count: limit ?? 100);
    if (hubId.startsWith(_hubRecentPrefix)) {
      final shelf = hubId.substring(_hubRecentPrefix.length);
      return _toItems(await _repo.recentlyAdded(libraryType: shelf, limit: limit ?? 200));
    }
    return const [];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _page(await fetchMoreHubItems(hubId), start, size);

  // ─── People ────────────────────────────────────────────────────────────

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final id = _id(personId);
    if (id == null) return const LibraryPage(items: [], totalCount: 0);
    return _page(await _toItems(await _repo.titlesWithPerson(id)), start, size);
  }

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async =>
      MediaPersonDetails.empty;

  // ─── Watch state ───────────────────────────────────────────────────────

  @override
  Future<void> markWatched(MediaItem item) async {
    final id = _id(item.id);
    if (id != null) await _repo.markWatched(id, watched: true);
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {
    final id = _id(item.id);
    if (id != null) await _repo.markWatched(id, watched: false);
  }

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    final id = _id(item.id);
    if (id != null) await _repo.hideFromContinueWatching(id);
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    final id = _id(item.id);
    if (id != null) await _repo.setFavorite(id, favorite: isFavorite);
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
  }) => _saveProgress(itemId, position, duration);

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
  }) => _saveProgress(itemId, position, duration);

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
  }) => _saveProgress(itemId, position, duration);

  Future<void> _saveProgress(String itemId, Duration position, Duration? duration) async {
    final id = _id(itemId);
    if (id == null) return;
    await _repo.setProgress(id, positionMs: position.inMilliseconds, durationMs: duration?.inMilliseconds);
  }

  // ─── Collections and playlists ─────────────────────────────────────────

  MediaItem _collectionItem(LibraryListRow list, int count) => MediaItem.jellyfin(
    id: '$_collectionPrefix${list.id}',
    kind: MediaKind.collection,
    title: list.title,
    summary: list.summary,
    thumbPath: list.posterSource,
    childCount: count,
    leafCount: count,
    serverId: localServerId,
    serverName: serverName,
  );

  static int? _listId(String id) =>
      id.startsWith(_collectionPrefix) ? int.tryParse(id.substring(_collectionPrefix.length)) : int.tryParse(id);

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final collections = <MediaItem>[];
    for (final list in await _repo.lists(lib.LibraryListKinds.collection)) {
      final members = await _repo.listItems(list.id);
      final onShelf = members.where((m) => m.item.libraryType == libraryId).length;
      // A one-film "series" is not a collection worth browsing.
      if (onShelf >= 2) collections.add(_collectionItem(list, onShelf));
    }
    return _page(collections, start, size);
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
    if (id == null) return const LibraryPage(items: [], totalCount: 0);
    return _page(await _toItems(await _repo.listItems(id)), start, size);
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
    final id = await _repo.createList(kind: lib.LibraryListKinds.collection, title: title);
    await addToCollection(collectionId: '$id', items: items);
    return '$_collectionPrefix$id';
  }

  Future<bool> _addToList(String listId, List<MediaItem> items) async {
    final id = _listId(listId);
    if (id == null) return false;
    for (final item in items) {
      final itemId = _id(item.id);
      if (itemId != null) await _repo.addToList(id, itemId);
    }
    return true;
  }

  Future<bool> _removeFromList(String listId, MediaItem item) async {
    final id = _listId(listId);
    final itemId = _id(item.id);
    if (id == null || itemId == null) return false;
    await _repo.removeFromList(id, itemId);
    return true;
  }

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) =>
      _addToList(collectionId, items);

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) =>
      _removeFromList(collectionId, item);

  @override
  Future<bool> deleteCollection(MediaItem collection) async {
    final id = _listId(collection.id);
    if (id == null) return false;
    await _repo.deleteList(id);
    return true;
  }

  MediaPlaylist _playlist(LibraryListRow list, int count) => MediaPlaylist(
    id: '${list.id}',
    backend: backend,
    title: list.title,
    playlistType: 'video',
    summary: list.summary,
    leafCount: count,
    addedAt: _seconds(list.createdAt),
    updatedAt: _seconds(list.updatedAt),
    thumbPath: list.posterSource,
    serverId: localServerId,
    serverName: serverName,
  );

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    if (playlistType != 'video' || smart == true) return const LibraryPage(items: [], totalCount: 0);
    final playlists = [
      for (final list in await _repo.lists(lib.LibraryListKinds.playlist))
        _playlist(list, (await _repo.listItems(list.id)).length),
    ];
    final offset = start ?? 0;
    final end = size == null ? playlists.length : (offset + size).clamp(0, playlists.length);
    return LibraryPage(
      items: offset >= playlists.length ? const [] : playlists.sublist(offset, end),
      totalCount: playlists.length,
      offset: offset,
    );
  }

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async {
    final listId = _listId(id);
    final list = (await _repo.lists(lib.LibraryListKinds.playlist)).where((l) => l.id == listId).firstOrNull;
    return list == null ? null : _playlist(list, (await _repo.listItems(list.id)).length);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async {
    final listId = _listId(id);
    if (listId == null) return const LibraryPage(items: [], totalCount: 0);
    return _page(await _toItems(await _repo.listItems(listId)), start, size);
  }

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async {
    final id = await _repo.createList(kind: lib.LibraryListKinds.playlist, title: title);
    await _addToList('$id', items);
    return fetchPlaylistMetadata('$id');
  }

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) =>
      _addToList(playlistId, items);

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async {
    final id = _listId(playlist.id);
    if (id == null) return false;
    await _repo.deleteList(id);
    return true;
  }

  /// Reordering is not stored yet; playlists keep insertion order.
  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async => false;

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) =>
      _removeFromList(playlistId, item);

  // ─── Artwork ───────────────────────────────────────────────────────────

  /// Resolves an artwork source to something an image widget can load: a
  /// remote URL as it is, or a proxy URL for an image on a mount.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    if (!path.startsWith('mount:')) return path;
    final rest = path.substring('mount:'.length);
    final separator = rest.indexOf(':');
    if (separator <= 0) return '';
    final mount = _mountsById[rest.substring(0, separator)];
    if (mount == null) return '';
    final url = _mountManager.proxy.urlForPath(
      mountId: mount.id,
      driver: _mountManager.driverFor(mount),
      path: rest.substring(separator + 1),
    );
    return url?.toString() ?? '';
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  // ─── Playback ──────────────────────────────────────────────────────────

  Future<StorageMount> _mountOf(LibraryFileRow file) async {
    final mount = _mountsById[file.mountId] ?? await _mountManager.registry.get(file.mountId);
    if (mount == null) throw const PlaybackException('The mount this file is on was removed');
    return mount;
  }

  static StorageEntry _entryOf(LibraryFileRow file) => StorageEntry(
    path: file.path,
    name: StoragePath.name(file.path),
    isDirectory: false,
    size: file.size,
    id: file.remoteId,
  );

  Future<Uri> _streamUrl(LibraryFileRow file) async => _mountManager.streamUrl(await _mountOf(file), _entryOf(file));

  /// How long playback waits for the backend's rendition list. Playing the
  /// original goes ahead without the list rather than wait longer.
  static const Duration _variantsTimeout = Duration(seconds: 8);

  /// The renditions the backend serves for [file], best first; empty when it
  /// serves none or cannot be asked right now.
  Future<List<StreamVariant>> _streamVariants(StorageMount mount, LibraryFileRow file) async {
    try {
      return await _mountManager.streamVariants(mount, _entryOf(file)).timeout(_variantsTimeout);
    } on StorageException catch (e) {
      appLogger.w('No renditions for ${file.path}: ${e.message}');
    } on TimeoutException {
      appLogger.w('Timed out listing renditions for ${file.path}');
    }
    return const [];
  }

  Future<List<LibraryFileRow>> _versions(String itemId) async {
    final id = _id(itemId);
    return id == null ? const [] : _repo.versionsOf(id);
  }

  ({LibraryFileRow file, int index})? _pickVersion(List<LibraryFileRow> files, int mediaIndex, String? sourceId) {
    if (files.isEmpty) return null;
    if (sourceId != null) {
      final byId = files.indexWhere((f) => '${f.id}' == sourceId);
      if (byId >= 0) return (file: files[byId], index: byId);
    }
    final index = mediaIndex >= 0 && mediaIndex < files.length ? mediaIndex : 0;
    return (file: files[index], index: index);
  }

  Future<List<SubtitleTrack>> _externalSubtitles(LibraryFileRow video) async {
    final tracks = <SubtitleTrack>[];
    for (final subtitle in await _repo.subtitlesOf(video.id)) {
      final url = await _streamUrl(subtitle);
      tracks.add(
        SubtitleTrack.uri(
          url.toString(),
          title: subtitle.language ?? StoragePath.name(subtitle.path),
          language: subtitle.language,
          codec: StoragePath.extension(subtitle.path),
        ),
      );
    }
    return tracks;
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final files = await _versions(options.metadata.id);
    final picked = _pickVersion(files, options.selectedMediaIndex, options.selectedMediaSourceId);
    if (picked == null) {
      throw const PlaybackException(
        'No file is available for this title',
        reason: PlaybackFailureReason.noPlayableSource,
      );
    }
    final String url;
    final List<SubtitleTrack> subtitles;
    final List<StreamVariant> variants;
    StreamVariant? variant;
    try {
      final mount = await _mountOf(picked.file);
      variants = await _streamVariants(mount, picked.file);
      variant = StreamVariant.pick(variants, options.streamQuality, _mountManager.variantOrder(mount));
      url =
          (variant == null
                  ? await _mountManager.streamUrl(mount, _entryOf(picked.file))
                  : await _mountManager.variantUrl(mount, _entryOf(picked.file), variant))
              .toString();
      subtitles = await _externalSubtitles(picked.file);
    } on StorageException catch (e) {
      throw PlaybackException(e.message, reason: PlaybackFailureReason.serverUnavailable);
    }
    return PlaybackInitializationResult(
      availableVersions: [for (final file in files) _toVersion(file)],
      videoUrl: url,
      // Audio and embedded subtitle tracks are read from the file by the player.
      mediaInfo: MediaSourceInfo(
        videoUrl: url,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        mediaSourceId: '${picked.file.id}',
        mediaIndex: picked.index,
      ),
      subtitleSidecars: [for (final track in subtitles) PlaybackSubtitleSidecar(sourceStreamId: null, track: track)],
      playMethod: variant == null ? 'DirectPlay' : 'DirectStream',
      selectedMediaIndex: picked.index,
      selectedMediaSourceId: '${picked.file.id}',
      streamQualities: [for (final v in variants) StreamQuality(id: v.id, width: v.width, height: v.height)],
      streamQuality: variant?.id ?? StreamQuality.original,
    );
  }

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final picked = _pickVersion(await _versions(item.id), mediaIndex, mediaSourceId);
    if (picked == null) return null;
    return ExternalPlaybackTarget(
      url: (await _streamUrl(picked.file)).toString(),
      subtitles: await _externalSubtitles(picked.file),
    );
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final picked = _pickVersion(await _versions(item.id), mediaIndex, mediaSourceId);
    if (picked == null) return const DownloadResolution(videoUrl: null);
    final subtitles = await _repo.subtitlesOf(picked.file.id);
    return DownloadResolution(
      videoUrl: (await _streamUrl(picked.file)).toString(),
      mediaSourceId: '${picked.file.id}',
      externalSubtitles: [
        for (final subtitle in subtitles)
          DownloadSubtitleSpec(
            id: subtitle.id,
            url: (await _streamUrl(subtitle)).toString(),
            codec: StoragePath.extension(subtitle.path),
            languageCode: subtitle.language,
            displayTitle: subtitle.language ?? StoragePath.name(subtitle.path),
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
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

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

  // ─── External ids ──────────────────────────────────────────────────────

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final id = _id(itemId);
    final row = id == null ? null : (await _repo.getItem(id))?.item;
    if (row == null) return const ExternalIds();
    return ExternalIds(imdb: row.imdbId, tmdb: int.tryParse(row.tmdbId ?? ''), tvdb: int.tryParse(row.tvdbId ?? ''));
  }

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async {
    final libraryKind = kind == MediaKind.movie ? lib.LibraryKinds.movie : lib.LibraryKinds.show;
    final row = await _repo.findByExternalId(
      kind: libraryKind,
      tmdbId: ids.tmdb == null ? null : '${ids.tmdb}',
      imdbId: ids.tmdb == null ? ids.imdb : null,
    );
    final view = row == null ? null : await _repo.getItem(row.id);
    return _toItems([?view]);
  }

  // ─── Music: not part of the local library yet ──────────────────────────

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

  static const int pageSize = _pageSize;
}

/// The local library has no live TV; the capability flag keeps the UI from
/// ever asking.
class _NoLiveTv implements LiveTvSupport {
  const _NoLiveTv();

  @override
  Future<bool> isAvailable() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Live TV is not available in the local library');
}
