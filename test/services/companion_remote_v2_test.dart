import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart' hide LibraryPage, LibraryQuery;
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/companion_remote/remote_playback_models.dart';
import 'package:plezy/models/companion_remote/remote_session.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/companion_remote/mobile_remote_screen.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/companion_remote/lan_discovery_service.dart';
import 'package:plezy/services/companion_remote/lan_identity_store.dart';
import 'package:plezy/services/companion_remote/lan_pairing_service.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/services/companion_remote/remote_host_catalog_handler.dart';
import 'package:plezy/services/companion_remote/remote_playback_launcher.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/ttplay/ttplay_server_client.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

class _SilentDiscoveryService extends LanDiscoveryService {
  final StreamController<List<DiscoveredHost>> _controller = StreamController<List<DiscoveredHost>>.broadcast(
    sync: true,
  );

  @override
  Future<void> startBroadcastingForContexts({
    required List<RemoteAuthContext> contexts,
    required String deviceName,
    required String platform,
    required int wsPort,
    required List<String> ips,
  }) async {}

  @override
  Future<void> stopBroadcasting() async {}

  @override
  Stream<List<DiscoveredHost>> startListeningForContexts(List<RemoteAuthContext> contexts) => _controller.stream;

  @override
  void stopListening() {}

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

class _FakeCatalogClient implements MediaServerClient {
  _FakeCatalogClient({
    required this.id,
    required this.name,
    this.thumbnailResolver,
    this.libraries = const [],
    this.continueWatching = const [],
    this.globalHubs = const [],
    this.searchResults = const [],
    this.pagedItems = const {},
    this.itemsById = const {},
    this.onDeckById = const {},
    this.childrenById = const {},
    this.descendantsById = const {},
    this.throwOnSearch = false,
  });

  final String id;
  final String name;
  final String Function(String? path)? thumbnailResolver;
  final List<MediaLibrary> libraries;
  final List<MediaItem> continueWatching;
  final List<MediaHub> globalHubs;
  final List<MediaItem> searchResults;
  final Map<String, List<MediaItem>> pagedItems;
  final Map<String, MediaItem> itemsById;
  final Map<String, MediaItem> onDeckById;
  final Map<String, List<MediaItem>> childrenById;
  final Map<String, List<MediaItem>> descendantsById;
  final bool throwOnSearch;

  @override
  ServerId get serverId => ServerId(id);

  @override
  String? get serverName => name;

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (thumbnailResolver != null) return thumbnailResolver!(path);
    return path ?? '';
  }

  @override
  void close() {}

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => libraries;

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async =>
      continueWatching;

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = 20,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async => globalHubs;

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final items = pagedItems[libraryId] ?? const [];
    return LibraryPage(items: items.take(query.limit).toList(), totalCount: items.length);
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    if (throwOnSearch) {
      throw StateError('Simulated search failure on $id');
    }
    return searchResults;
  }

  @override
  Future<MediaItem?> fetchItem(String id) async => itemsById[id];

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async => (item: itemsById[id], onDeckEpisode: onDeckById[id]);

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => childrenById[parentId] ?? const [];

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async => descendantsById[parentId] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ModeDeviceHarness {
  _ModeDeviceHarness._({
    required this.db,
    required this.identityStore,
    required this.lan,
    required this.session,
    required this.remote,
  });

  final AppDatabase db;
  final LanIdentityStore identityStore;
  final LanPairingService lan;
  final AppSessionController session;
  final CompanionRemoteProvider remote;
  bool _disposed = false;

  static Future<_ModeDeviceHarness> create({
    required String deviceName,
    required AppLoginMode mode,
    SelfHostedSession? selfHostedSession,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final identityStore = LanIdentityStore(db);
    await identityStore.setDeviceName(deviceName);
    final lan = LanPairingService(identityStore: identityStore, enableUdpBroadcast: false);
    await lan.start(bindHttpPort: 0);
    final session = AppSessionController(db: db, identityStore: identityStore)
      ..debugSetStateForTesting(mode: mode, selfHostedSession: selfHostedSession);
    final remote = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: _SilentDiscoveryService.new,
    );
    return _ModeDeviceHarness._(db: db, identityStore: identityStore, lan: lan, session: session, remote: remote);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await remote.leaveSession();
    remote.dispose();
    await lan.stop();
    lan.dispose();
    session.dispose();
    await db.close();
  }
}

class _WidgetCatalogProvider extends CompanionRemoteProvider {
  _WidgetCatalogProvider({
    required this.homeResponse,
    required this.searchHandler,
    required this.childrenHandler,
  });

  final RemoteHostHomeResponse homeResponse;
  final Future<RemoteHostSearchResponse> Function(String query) searchHandler;
  final Future<RemoteHostChildrenResponse> Function(String serverId, String itemId, String? kind) childrenHandler;

  final RemoteSessionStatus _status = RemoteSessionStatus.connected;
  RemotePlayerSnapshot _snapshot = RemotePlayerSnapshot.idle;
  final List<({RemoteCommandType type, Map<String, dynamic>? data})> sent = [];
  final List<RemoteCatalogItem> playedItems = [];

  @override
  RemoteSessionStatus get status => _status;

  @override
  bool get isConnected => _status == RemoteSessionStatus.connected;

  @override
  RemotePlayerSnapshot get remotePlayerSnapshot => _snapshot;

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) {
    sent.add((type: type, data: data));
  }

  @override
  Future<RemoteHostHomeResponse> fetchHostHome({Duration timeout = const Duration(seconds: 10)}) async => homeResponse;

  @override
  Future<RemoteHostSearchResponse> searchHostCatalog(
    String query, {
    int limit = 40,
    Duration timeout = const Duration(seconds: 10),
  }) => searchHandler(query);

  @override
  Future<RemoteHostChildrenResponse> fetchHostItemChildren({
    required String serverId,
    required String itemId,
    String? kind,
    Duration timeout = const Duration(seconds: 10),
  }) => childrenHandler(serverId, itemId, kind);

  @override
  void playHostCatalogItem(RemoteCatalogItem item) {
    playedItems.add(item);
    _snapshot = RemotePlayerSnapshot(
      active: true,
      stage: 'opening',
      mediaKind: item.kind,
      title: item.title,
      seriesTitle: item.seriesTitle,
    );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  HttpOverrides? previousHttpOverrides;

  setUpAll(() {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('RemoteCommandType & Catalog DTOs', () {
    test('preserves legacy wire indices and round-trips new catalog commands and DTOs', () {
      expect(RemoteCommandType.playMedia.index, 40);
      expect(RemoteCommandType.requestState.index, 50);

      for (final type in const [
        RemoteCommandType.searchHostCatalog,
        RemoteCommandType.hostCatalogSearchResult,
        RemoteCommandType.browseHostHome,
        RemoteCommandType.hostHomeResult,
        RemoteCommandType.browseHostItemChildren,
        RemoteCommandType.hostItemChildrenResult,
      ]) {
        final cmd = RemoteCommand(type: type, data: const {'requestId': 'req_1', 'ok': true});
        final parsed = RemoteCommand.fromJson(cmd.toJson());
        expect(parsed.type, type);
        expect(parsed.data, {'requestId': 'req_1', 'ok': true});
      }

      const item = RemoteCatalogItem(
        serverId: 'ttplay-server',
        serverName: 'Home NAS',
        itemId: '42',
        kind: 'show',
        title: 'Severance',
        subtitle: '2022',
        year: 2022,
        thumbUrl: 'http://192.168.1.20:8080/api/v1/artwork/remote?src=%2Fabc.jpg',
        watched: true,
      );
      expect(item.isContainer, isTrue);

      final roundItem = RemoteCatalogItem.fromJson(item.toJson());
      expect(roundItem.serverId, 'ttplay-server');
      expect(roundItem.serverName, 'Home NAS');
      expect(roundItem.itemId, '42');
      expect(roundItem.kind, 'show');
      expect(roundItem.title, 'Severance');
      expect(roundItem.thumbUrl, item.thumbUrl);
      expect(roundItem.watched, isTrue);

      final target = roundItem.toRemoteMediaTarget();
      expect(target.remoteServerId, 'ttplay-server');
      expect(target.remoteItemId, '42');
      expect(target.kind, 'show');
      expect(target.posterUrl, item.thumbUrl);

      final home = RemoteHostHomeResponse(
        hubs: [RemoteCatalogHub(id: 'cw', title: 'Continue Watching', items: [item])],
        libraries: const [
          RemoteCatalogLibrary(
            serverId: 'ttplay-server',
            serverName: 'Home NAS',
            libraryId: 'movie',
            title: 'Movies',
            kind: 'movie',
          ),
        ],
      );
      final parsedHome = RemoteHostHomeResponse.fromJson(home.toJson());
      expect(parsedHome.hubs, hasLength(1));
      expect(parsedHome.hubs.first.items.first.title, 'Severance');
      expect(parsedHome.libraries, hasLength(1));
      expect(parsedHome.libraries.first.libraryId, 'movie');

      final search = RemoteHostSearchResponse(query: 'Sev', items: [item]);
      expect(RemoteHostSearchResponse.fromJson(search.toJson()).items.first.itemId, '42');

      final children = RemoteHostChildrenResponse(
        serverId: 'ttplay-server',
        itemId: '42',
        title: 'Severance',
        items: [item.copyWithLike()],
      );
      final parsedChildren = RemoteHostChildrenResponse.fromJson(children.toJson());
      expect(parsedChildren.title, 'Severance');
      expect(parsedChildren.items, hasLength(1));
    });
  });

  group('resolveRemoteReachablePosterUrl', () {
    test('accepts LAN/HTTPS reachable URLs and rejects loopback or local paths', () {
      final lanClient = _FakeCatalogClient(
        id: 'ttplay-server',
        name: 'NAS',
        thumbnailResolver: (p) => 'http://192.168.1.88:8080/api/v1/artwork/remote?src=$p&token=abc',
      );
      final localClient = _FakeCatalogClient(
        id: 'local-library',
        name: 'Local',
        thumbnailResolver: (p) => p == '/tmdb.jpg' ? 'https://image.tmdb.org/t/p/w342/tmdb.jpg' : (p ?? ''),
      );
      final loopbackClient = _FakeCatalogClient(
        id: 'ttplay-server',
        name: 'Loopback',
        thumbnailResolver: (p) => 'http://127.0.0.1:8080/api/v1/artwork/remote?src=$p',
      );

      expect(
        resolveRemoteReachablePosterUrl(lanClient, testMediaItem(id: '1', thumbPath: '/poster.jpg')),
        'http://192.168.1.88:8080/api/v1/artwork/remote?src=/poster.jpg&token=abc',
      );
      expect(
        resolveRemoteReachablePosterUrl(localClient, testMediaItem(id: '2', thumbPath: '/tmdb.jpg')),
        'https://image.tmdb.org/t/p/w342/tmdb.jpg',
      );
      expect(resolveRemoteReachablePosterUrl(localClient, testMediaItem(id: '3', thumbPath: 'mount:1:a.jpg')), isNull);
      expect(
        resolveRemoteReachablePosterUrl(localClient, testMediaItem(id: '4', thumbPath: 'file:///tmp/a.jpg')),
        isNull,
      );
      expect(resolveRemoteReachablePosterUrl(loopbackClient, testMediaItem(id: '5', thumbPath: '/p.jpg')), isNull);
      expect(
        resolveRemoteReachablePosterUrl(null, testMediaItem(id: '6', thumbPath: 'http://localhost:8080/a.jpg')),
        isNull,
      );
      expect(resolveRemoteReachablePosterUrl(null, testMediaItem(id: '7', thumbPath: 'http://[::1]:8080/a.jpg')), isNull);
    });
  });

  group('RemoteHostCatalogHandler', () {
    test('aggregates search across online servers, tolerates failures, ranks exact match first', () async {
      final selfHostedClient = _FakeCatalogClient(
        id: TtplayServerClient.primaryServerId,
        name: 'SelfHosted',
        thumbnailResolver: (p) => p == null ? '' : 'http://192.168.1.50:8080/art$p',
        searchResults: [
          testMediaItem(
            id: '10',
            backend: MediaBackend.jellyfin,
            kind: MediaKind.movie,
            title: 'Beyond Dune',
            year: 2020,
            thumbPath: '/beyond.jpg',
            serverId: TtplayServerClient.primaryServerId,
          ),
          testMediaItem(
            id: '11',
            backend: MediaBackend.jellyfin,
            kind: MediaKind.artist,
            title: 'Dune Artist',
            serverId: TtplayServerClient.primaryServerId,
          ),
        ],
      );
      final extClient = _FakeCatalogClient(
        id: 'ttplay-ext:1',
        name: 'Emby Box',
        searchResults: [
          testMediaItem(
            id: 'e-1',
            backend: MediaBackend.emby,
            kind: MediaKind.movie,
            title: 'Dune',
            year: 2021,
            serverId: 'ttplay-ext:1',
          ),
        ],
      );
      final failingClient = _FakeCatalogClient(id: 'ttplay-ext:2', name: 'Broken', throwOnSearch: true);

      final env = testMultiServer(clients: [selfHostedClient, extClient, failingClient]);
      final handler = RemoteHostCatalogHandler(env.manager);

      final resp = await handler.searchCatalog('Dune');
      expect(resp.query, 'Dune');
      expect(resp.items.map((i) => i.title).toList(), ['Dune', 'Beyond Dune']);
      expect(resp.items[1].thumbUrl, 'http://192.168.1.50:8080/art/beyond.jpg');
    });

    test('browseHome merges Continue Watching, skips music/hidden libs, falls back when hubs empty', () async {
      final cwItem = testMediaItem(
        id: 'm1',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.movie,
        title: 'Inception',
        viewOffsetMs: 90000,
        serverId: TtplayServerClient.primaryServerId,
      );
      final recentShow = testMediaItem(
        id: 's1',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.show,
        title: 'Dark',
        year: 2017,
        serverId: TtplayServerClient.primaryServerId,
      );
      final extMovie = testMediaItem(
        id: 'em-1',
        backend: MediaBackend.emby,
        kind: MediaKind.movie,
        title: 'Blade Runner',
        serverId: 'ttplay-ext:1',
      );

      final primary = _FakeCatalogClient(
        id: TtplayServerClient.primaryServerId,
        name: 'Primary',
        libraries: [
          const MediaLibrary(
            id: 'lib-movie',
            backend: MediaBackend.jellyfin,
            title: 'Movies',
            kind: MediaKind.movie,
            serverId: TtplayServerClient.primaryServerId,
          ),
          const MediaLibrary(
            id: 'lib-music',
            backend: MediaBackend.jellyfin,
            title: 'Music',
            kind: MediaKind.artist,
            serverId: TtplayServerClient.primaryServerId,
          ),
          const MediaLibrary(
            id: 'lib-hidden',
            backend: MediaBackend.jellyfin,
            title: 'Secret',
            kind: MediaKind.movie,
            hidden: true,
            serverId: TtplayServerClient.primaryServerId,
          ),
        ],
        continueWatching: [cwItem],
        globalHubs: [
          MediaHub(
            id: 'recent',
            title: 'Recently Added',
            type: 'mixed',
            items: [recentShow],
            serverId: TtplayServerClient.primaryServerId,
          ),
        ],
      );

      final extWithEmptyHubs = _FakeCatalogClient(
        id: 'ttplay-ext:1',
        name: 'Emby Fallback',
        libraries: const [
          MediaLibrary(
            id: 'ext-movies',
            backend: MediaBackend.emby,
            title: 'Emby Movies',
            kind: MediaKind.movie,
            serverId: 'ttplay-ext:1',
          ),
        ],
        globalHubs: const [],
        pagedItems: {
          'ext-movies': [extMovie],
        },
        itemsById: {'s1': recentShow},
        childrenById: {
          's1': [
            testMediaItem(
              id: 'season-1',
              backend: MediaBackend.emby,
              kind: MediaKind.season,
              title: 'Season 1',
              index: 1,
              parentId: 's1',
              parentTitle: 'Dark',
              serverId: 'ttplay-ext:1',
            ),
          ],
        },
      );

      final env = testMultiServer(clients: [primary, extWithEmptyHubs]);
      final handler = RemoteHostCatalogHandler(env.manager);

      final home = await handler.browseHome(continueWatchingTitle: 'Continue Watching');
      expect(home.libraries.map((l) => l.libraryId).toList(), ['lib-movie', 'ext-movies']);
      expect(home.hubs.map((h) => h.id).toList(), [
        'continue_watching',
        'ttplay-server:recent',
        'ttplay-ext:1:lib:ext-movies',
      ]);
      expect(home.hubs.last.items.single.title, 'Blade Runner');

      final libChildren = await handler.browseItemChildren(
        serverId: 'ttplay-ext:1',
        itemId: 'ext-movies',
        kind: 'library',
      );
      expect(libChildren.title, 'Emby Movies');
      expect(libChildren.items.single.title, 'Blade Runner');

      final showChildren = await handler.browseItemChildren(serverId: 'ttplay-ext:1', itemId: 's1', kind: 'show');
      expect(showChildren.items.single.kind, 'season');

      final missing = await handler.browseItemChildren(serverId: 'missing-srv', itemId: '1');
      expect(missing.error, isNotNull);
    });
  });

  group('resolveRemoteMediaTargetLocally for catalog show/season targets', () {
    test('resolves show via onDeck or unwatched descendant and season via unwatched episode', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final mountManager = MountManager(MountRegistry(db));
      final repo = LibraryRepository(db);
      final localClient = LocalLibraryClient(repository: repo, mounts: mountManager);
      addTearDown(() async {
        localClient.close();
        await mountManager.dispose();
        await db.close();
      });

      final show1 = testMediaItem(
        id: 'show-1',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.show,
        title: 'Show One',
        serverId: TtplayServerClient.primaryServerId,
      );
      final epOnDeck = testMediaItem(
        id: 'ep-on-deck',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.episode,
        title: 'Episode Two',
        parentIndex: 1,
        index: 2,
        grandparentTitle: 'Show One',
        serverId: TtplayServerClient.primaryServerId,
      );
      final show2 = testMediaItem(
        id: 'show-2',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.show,
        title: 'Show Two',
        serverId: TtplayServerClient.primaryServerId,
      );
      final epWatched = testMediaItem(
        id: 'ep-w',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.episode,
        title: 'Watched',
        viewCount: 1,
        serverId: TtplayServerClient.primaryServerId,
      );
      final epUnwatched = testMediaItem(
        id: 'ep-u',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.episode,
        title: 'Next Unwatched',
        viewCount: 0,
        serverId: TtplayServerClient.primaryServerId,
      );
      final season1 = testMediaItem(
        id: 'season-1',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.season,
        title: 'Season 1',
        index: 1,
        serverId: TtplayServerClient.primaryServerId,
      );

      final client = _FakeCatalogClient(
        id: TtplayServerClient.primaryServerId,
        name: 'NAS',
        itemsById: {'show-1': show1, 'show-2': show2, 'season-1': season1},
        onDeckById: {'show-1': epOnDeck},
        descendantsById: {
          'show-2': [epWatched, epUnwatched],
        },
        childrenById: {
          'season-1': [epWatched, epUnwatched],
        },
      );

      final res1 = await resolveRemoteMediaTargetLocally(
        target: const RemoteMediaTarget(
          kind: 'show',
          title: 'Show One',
          remoteServerId: TtplayServerClient.primaryServerId,
          remoteItemId: 'show-1',
        ),
        db: db,
        localClient: localClient,
        remoteClientLookup: (id) => id == client.id ? client : null,
      );
      expect(res1?.item.id, 'ep-on-deck');

      final res2 = await resolveRemoteMediaTargetLocally(
        target: const RemoteMediaTarget(
          kind: 'show',
          title: 'Show Two',
          remoteServerId: TtplayServerClient.primaryServerId,
          remoteItemId: 'show-2',
        ),
        db: db,
        localClient: localClient,
        remoteClientLookup: (id) => id == client.id ? client : null,
      );
      expect(res2?.item.id, 'ep-u');

      final res3 = await resolveRemoteMediaTargetLocally(
        target: const RemoteMediaTarget(
          kind: 'season',
          title: 'Season 1',
          remoteServerId: TtplayServerClient.primaryServerId,
          remoteItemId: 'season-1',
        ),
        db: db,
        localClient: localClient,
        remoteClientLookup: (id) => id == client.id ? client : null,
      );
      expect(res3?.item.id, 'ep-u');
    });
  });

  group('Mode-decoupled WebSocket RPC & playback handoff', () {
    test(
      'offline controller pairs with self-hosted host, searches/browses host catalog, and triggers playback without local ownership',
      () async {
        final host = await _ModeDeviceHarness.create(
          deviceName: 'Living Room TV',
          mode: AppLoginMode.selfHosted,
          selfHostedSession: SelfHostedSession(
            serverUrl: 'http://192.168.1.99:8080',
            username: 'tv',
            accessToken: 'jwt-host',
            serverName: 'NAS',
          ),
        );
        final phone = await _ModeDeviceHarness.create(
          deviceName: 'Offline Phone',
          mode: AppLoginMode.offline,
        );
        addTearDown(() async {
          await phone.dispose();
          await host.dispose();
        });

        final hostMovie = MediaItem.jellyfin(
          dialect: MediaBrowserDialect.jellyfin,
          id: 'movie-99',
          kind: MediaKind.movie,
          title: 'Dune',
          year: 2021,
          thumbPath: '/dune.jpg',
          serverId: TtplayServerClient.primaryServerId,
          serverName: 'NAS',
        );
        final hostShow = MediaItem.jellyfin(
          dialect: MediaBrowserDialect.jellyfin,
          id: 'show-77',
          kind: MediaKind.show,
          title: 'Dune: Prophecy',
          year: 2024,
          serverId: TtplayServerClient.primaryServerId,
          serverName: 'NAS',
        );
        final hostEpisode = MediaItem.jellyfin(
          dialect: MediaBrowserDialect.jellyfin,
          id: 'ep-7701',
          kind: MediaKind.episode,
          title: 'The Hidden Hand',
          parentIndex: 1,
          index: 1,
          grandparentTitle: 'Dune: Prophecy',
          serverId: TtplayServerClient.primaryServerId,
          serverName: 'NAS',
        );

        final fakeClient = _FakeCatalogClient(
          id: TtplayServerClient.primaryServerId,
          name: 'NAS',
          thumbnailResolver: (p) => p == null ? '' : 'http://192.168.1.99:8080/api/v1/artwork/remote?src=$p&token=t',
          libraries: const [
            MediaLibrary(
              id: 'movie',
              backend: MediaBackend.jellyfin,
              title: 'Movies',
              kind: MediaKind.movie,
              serverId: TtplayServerClient.primaryServerId,
            ),
          ],
          continueWatching: [hostMovie],
          searchResults: [hostMovie, hostShow],
          childrenById: {
            'show-77': [hostEpisode],
          },
        );
        final env = testMultiServer(clients: [fakeClient]);
        final catalogHandler = RemoteHostCatalogHandler(env.manager);
        host.remote.onSearchHostCatalog = (q, l) => catalogHandler.searchCatalog(q, limit: l);
        host.remote.onBrowseHostHome = () => catalogHandler.browseHome(continueWatchingTitle: 'Continue Watching');
        host.remote.onBrowseHostItemChildren = (sId, iId, kind) =>
            catalogHandler.browseItemChildren(serverId: sId, itemId: iId, kind: kind);

        final playTargets = <RemoteMediaTarget>[];
        final playCompleter = Completer<void>();
        host.remote.onPlayMediaRequested = (target) async {
          playTargets.add(target);
          host.remote.updateHostPlayerSnapshot(
            RemotePlayerSnapshot(
              active: true,
              stage: 'playing',
              mediaKind: target.kind,
              title: target.title,
              posterUrl: target.posterUrl,
              playing: true,
              durationMs: 7200000,
              positionMs: 1000,
            ),
          );
          if (!playCompleter.isCompleted) playCompleter.complete();
          return true;
        };

        await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore);
        await phone.remote.ensureLanCryptoReady(phone.lan, identityStore: phone.identityStore);
        await host.remote.startHostServer();

        final peer = LanDiscoveredPeer(
          deviceId: host.lan.deviceId!,
          deviceName: 'Living Room TV',
          platform: 'android',
          host: '127.0.0.1',
          httpPort: host.lan.listeningPort!,
          pubKeyBase64: host.lan.publicKeyBase64!,
          lastSeen: DateTime.now(),
          remotePort: host.lan.advertisedRemotePort,
        );
        phone.lan.registerDiscoveredPeer(peer);

        final reqReady = Completer<LanPairRequest>();
        host.lan.addListener(() {
          final req = host.lan.incomingPairRequests.firstOrNull;
          if (req != null && !reqReady.isCompleted) reqReady.complete(req);
        });
        final connectFut = phone.remote.trustAndConnectLanPeer(peer);
        await host.lan.acceptPairRequest(await reqReady.future.timeout(const Duration(seconds: 5)));
        await connectFut.timeout(const Duration(seconds: 10));

        // Controller has zero local items, yet queries host home & search cleanly.
        expect(await phone.db.select(phone.db.libraryItems).get(), isEmpty);

        final home = await phone.remote.fetchHostHome();
        expect(home.libraries.single.title, 'Movies');
        expect(home.hubs.first.items.single.title, 'Dune');

        final search = await phone.remote.searchHostCatalog('Dune');
        expect(search.items.map((i) => i.itemId).toList(), ['movie-99', 'show-77']);
        expect(search.items.first.thumbUrl, 'http://192.168.1.99:8080/api/v1/artwork/remote?src=/dune.jpg&token=t');

        final children = await phone.remote.fetchHostItemChildren(
          serverId: TtplayServerClient.primaryServerId,
          itemId: 'show-77',
          kind: 'show',
        );
        expect(children.items.single.title, 'The Hidden Hand');

        phone.remote.playHostCatalogItem(search.items.first);
        await playCompleter.future.timeout(const Duration(seconds: 5));
        expect(playTargets.single.remoteServerId, TtplayServerClient.primaryServerId);
        expect(playTargets.single.remoteItemId, 'movie-99');

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (phone.remote.remotePlayerSnapshot.stage != 'playing' && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(phone.remote.remotePlayerSnapshot.title, 'Dune');
        expect(phone.remote.remotePlayerSnapshot.posterUrl, search.items.first.thumbUrl);
      },
    );
  });

  group('RemoteControlScreen v2 widget interactions', () {
    testWidgets('browses target media, searches, drills down, plays, and sends D-pad commands', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const showItem = RemoteCatalogItem(
        serverId: TtplayServerClient.primaryServerId,
        serverName: 'Home NAS',
        itemId: 'show-1',
        kind: 'show',
        title: 'Severance',
        subtitle: '2022',
      );
      const episodeItem = RemoteCatalogItem(
        serverId: TtplayServerClient.primaryServerId,
        serverName: 'Home NAS',
        itemId: 'ep-101',
        kind: 'episode',
        title: 'Good News About Hell',
        subtitle: 'Severance · S01E01',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const searchMovie = RemoteCatalogItem(
        serverId: TtplayServerClient.primaryServerId,
        serverName: 'Home NAS',
        itemId: 'movie-2',
        kind: 'movie',
        title: 'Dune: Part Two',
        subtitle: '2024',
      );

      final queries = <String>[];
      final provider = _WidgetCatalogProvider(
        homeResponse: const RemoteHostHomeResponse(
          libraries: [
            RemoteCatalogLibrary(
              serverId: TtplayServerClient.primaryServerId,
              serverName: 'Home NAS',
              libraryId: 'shows',
              title: 'Shows',
              kind: 'show',
            ),
          ],
          hubs: [
            RemoteCatalogHub(
              id: 'continue_watching',
              title: 'Continue Watching',
              items: [showItem],
            ),
          ],
        ),
        searchHandler: (query) async {
          queries.add(query);
          return const RemoteHostSearchResponse(query: 'Dune', items: [searchMovie]);
        },
        childrenHandler: (serverId, itemId, kind) async {
          if (itemId == 'show-1') {
            return const RemoteHostChildrenResponse(
              serverId: TtplayServerClient.primaryServerId,
              itemId: 'show-1',
              title: 'Severance',
              items: [episodeItem],
            );
          }
          return const RemoteHostChildrenResponse(
            serverId: TtplayServerClient.primaryServerId,
            itemId: 'shows',
            title: 'Shows',
            items: [showItem],
          );
        },
      );
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<CompanionRemoteProvider>.value(
          value: provider,
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const RemoteControlScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Idle card exposes target media search/browse entry.
      await tester.tap(find.text(t.companionRemote.browseTargetMedia));
      await tester.pumpAndSettle();

      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('Severance'), findsOneWidget);

      // Drill into a show's children.
      await tester.tap(find.text('Severance'));
      await tester.pumpAndSettle();
      expect(find.text('Good News About Hell'), findsOneWidget);

      // Go back to home browse.
      await tester.tap(find.text(t.companionRemote.backToBrowse));
      await tester.pumpAndSettle();

      // Search target device catalog (triggers debounce -> run search).
      await tester.enterText(find.byType(TextField), 'Dune');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(queries, ['Dune']);
      expect(find.text('Dune: Part Two'), findsOneWidget);

      // Tapping Play dispatches playHostCatalogItem and returns to Control tab.
      await tester.tap(find.byTooltip(t.companionRemote.playOnTarget));
      await tester.pumpAndSettle();
      expect(provider.playedItems.map((e) => e.itemId).toList(), ['movie-2']);
      expect(find.byKey(const PageStorageKey<String>('remote_control_scroll')), findsOneWidget);

      // Switch to D-Pad tab and dispatch navigation keys.
      await tester.tap(find.text(t.companionRemote.tabDpad));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Symbols.keyboard_arrow_up_rounded));
      await tester.tap(find.byIcon(Symbols.keyboard_arrow_down_rounded));
      await tester.tap(find.byIcon(Symbols.keyboard_arrow_left_rounded));
      await tester.tap(find.byIcon(Symbols.keyboard_arrow_right_rounded));
      await tester.tap(find.text(t.companionRemote.ok));
      await tester.tap(find.text(t.companionRemote.backToBrowse));
      await tester.tap(find.byIcon(Symbols.home_rounded));
      await tester.pump();
      expect(provider.sent.map((c) => c.type).toList(), [
        RemoteCommandType.dpadUp,
        RemoteCommandType.dpadDown,
        RemoteCommandType.dpadLeft,
        RemoteCommandType.dpadRight,
        RemoteCommandType.select,
        RemoteCommandType.back,
        RemoteCommandType.home,
      ]);
    });
  });
}

extension on RemoteCatalogItem {
  RemoteCatalogItem copyWithLike() => RemoteCatalogItem(
    serverId: serverId,
    serverName: serverName,
    itemId: '$itemId-child',
    kind: kind,
    title: '$title Child',
  );
}
