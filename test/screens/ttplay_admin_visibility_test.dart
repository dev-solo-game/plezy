import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/local_workspace_archive.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/seerr_account_provider.dart';
import 'package:plezy/providers/theme_provider.dart';
import 'package:plezy/providers/trackers_provider.dart';
import 'package:plezy/screens/settings/settings_screen.dart';
import 'package:plezy/screens/ttplay_admin/ttplay_external_servers_screen.dart';
import 'package:plezy/screens/ttplay_admin/ttplay_item_admin_dialogs.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/supporter/supporter_mode.dart';
import 'package:plezy/services/supporter/supporter_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/session/app_session_store.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/ttplay/ttplay_server_client.dart';
import 'package:plezy/ttplay/ttplay_session_binder.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_context_menu.dart';
import 'package:provider/provider.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_stack.dart';

class _AdminMockServer {
  _AdminMockServer._(this._server);

  final HttpServer _server;
  bool ext1Enabled = true;
  final List<({String method, String path, Map<String, dynamic> body})> requests = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_AdminMockServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _AdminMockServer._(server);
    server.listen(s._handle);
    return s;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    Map<String, dynamic> body = const {};
    if (raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    }
    final path = req.uri.path;
    requests.add((method: req.method, path: path, body: body));

    if (path == '/api/v1/ext-servers' && req.method == 'GET') {
      await _json(req, 200, {
        'code': 0,
        'servers': [
          {
            'id': 'ext1',
            'name': 'Living Room Emby',
            'kind': 'emby',
            'base_url': 'http://192.168.1.20:8096',
            'auth_mode': 'password',
            'username': 'alice',
            'enabled': ext1Enabled,
          },
        ],
      });
      return;
    }
    if (path == '/api/v1/ext-servers/ext1' && req.method == 'PUT') {
      ext1Enabled = body['enabled'] == true;
      await _json(req, 200, {
        'code': 0,
        'server': {
          'id': 'ext1',
          'name': 'Living Room Emby',
          'kind': 'emby',
          'base_url': 'http://192.168.1.20:8096',
          'auth_mode': 'password',
          'username': 'alice',
          'enabled': ext1Enabled,
        },
      });
      return;
    }
    if (path == '/api/v1/items/101' && req.method == 'GET') {
      await _json(req, 200, {
        'code': 0,
        'detail': {
          'item': {
            'id': 101,
            'kind': 'movie',
            'library_type': 'movie',
            'title': 'Inception',
            'original_title': 'Inception',
            'year': 2010,
            'locked': false,
          },
          'files': [
            {'id': 1, 'path': '/movies/Inception.mkv'},
          ],
        },
      });
      return;
    }
    if (path == '/api/v1/scrape/search') {
      await _json(req, 200, {
        'code': 0,
        'results': [
          {'source': 'tmdb', 'id': '27205', 'title': 'Inception', 'original_title': 'Inception', 'year': 2010},
        ],
      });
      return;
    }
    if (path == '/api/v1/items/101/match' || path == '/api/v1/items/101/metadata') {
      await _json(req, 200, const {'code': 0});
      return;
    }
    if (path == '/api/v1/auth/logout') {
      await _json(req, 200, const {'code': 0});
      return;
    }

    await _json(req, 404, const {'error': 'not found'});
  }

  Future<void> _json(HttpRequest req, int status, Map<String, dynamic> body) async {
    req.response.persistentConnection = false;
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

class _FakeDownloads extends ChangeNotifier implements DownloadProvider {
  @override
  bool hasSyncRule(String globalKey) => false;

  @override
  String syncRuleKeyForClient(MediaServerClient? client, String ratingKey, {ServerId? serverId}) => ratingKey;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHiddenStorage implements StorageService {
  @override
  Set<String> getHiddenLibraries() => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WritableDownloadStorage extends Fake implements DownloadStorageService {
  @override
  Future<bool> isDirectoryWritable(Directory dir) async => true;
}

class _EnvBundle {
  _EnvBundle({
    required this.db,
    required this.serverManager,
    required this.multiServer,
    required this.sessionController,
    required this.binder,
    required this.mounts,
    required this.activeProfile,
    required this.plexHome,
  });

  final AppDatabase db;
  final MultiServerManager serverManager;
  final MultiServerProvider multiServer;
  final AppSessionController sessionController;
  final TtplaySessionBinder binder;
  final MountManager mounts;
  final ActiveProfileProvider activeProfile;
  final PlexHomeService plexHome;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    binder.dispose();
    multiServer.dispose();
    serverManager.dispose();
    sessionController.dispose();
    activeProfile.dispose();
    await plexHome.dispose();
    await mounts.dispose();
    await db.close();
  }
}

Future<_EnvBundle> _createSelfHostedEnv(_AdminMockServer server, {bool isTv = false}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final connections = ConnectionRegistry(db);
  final profileConnections = ProfileConnectionRegistry(db);
  final profiles = ProfileRegistry(db);
  final plexHome = PlexHomeService(
    connections: connections,
    profileConnections: profileConnections,
    plexHomeUserFetcher: (_) async => const [],
  );
  final activeProfile = ActiveProfileProvider(
    registry: profiles,
    plexHome: plexHome,
    connections: connections,
    profileConnections: profileConnections,
  );
  final mounts = MountManager(MountRegistry(db));
  final repo = LibraryRepository(db);
  final sessionController = AppSessionController(
    db: db,
    store: AppSessionStore(db),
    archive: LocalWorkspaceArchive(db),
    mountManager: mounts,
  );
  final session = SelfHostedSession(
    serverUrl: server.baseUrl,
    username: 'alice',
    accessToken: 'tok-123',
    serverName: 'NAS Server',
  );
  sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);

  final serverManager = MultiServerManager();
  final multiServer = MultiServerProvider(serverManager, DataAggregationService(serverManager));
  final binder = TtplaySessionBinder(
    sessionController: sessionController,
    serverManager: serverManager,
    localLibraryClient: LocalLibraryClient(repository: repo, mounts: mounts),
    isTv: () => isTv,
  )..attachMultiServerProvider(multiServer);
  binder.seedSelfHostedSynchronously(session);

  return _EnvBundle(
    db: db,
    serverManager: serverManager,
    multiServer: multiServer,
    sessionController: sessionController,
    binder: binder,
    mounts: mounts,
    activeProfile: activeProfile,
    plexHome: plexHome,
  );
}

Future<void> _pumpSelfHostedSettings(WidgetTester tester, _EnvBundle env) async {
  final hiddenLibraries = HiddenLibrariesProvider(storageService: _FakeHiddenStorage());
  await hiddenLibraries.ensureInitialized();
  final libraries = LibrariesProvider();
  final supporter = SupporterService.forTesting(availability: SupporterAvailability.hidden);
  final theme = ThemeProvider(supporter: supporter);
  final trackers = TrackersProvider(httpClientFactory: () => FakeHttpClient(HttpStatus.ok, const <int>[]));
  final seerr = SeerrAccountProvider();
  final accountPrefs = AccountPreferencesController();
  final settingsService = SettingsService.instance;
  final storageService = DownloadStorageService.instance;
  await tester.runAsync(() => storageService.initialize(settingsService));
  final downloadManager = DownloadManagerService(
    database: env.db,
    storageService: _WritableDownloadStorage(),
    clientResolver: (_, {clientScopeId}) => null,
    downloadsSupportedOverride: false,
    downloadLocationReader: () => (path: null, type: 'custom'),
    downloadPathWriter: (_) async {},
    downloadPathTypeWriter: (_) async {},
    downloadStorageRefresher: () async {},
  )..recoveryFuture = Future<void>.value();
  final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: env.db);

  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    downloadProvider.dispose();
    downloadManager.dispose();
    accountPrefs.dispose();
    seerr.dispose();
    trackers.dispose();
    theme.dispose();
    supporter.dispose();
    libraries.dispose();
    hiddenLibraries.dispose();
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: env.activeProfile),
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<TrackersProvider>.value(value: trackers),
          ChangeNotifierProvider<SeerrAccountProvider>.value(value: seerr),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
          ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPrefs),
          ChangeNotifierProvider<AppSessionController>.value(value: env.sessionController),
          ChangeNotifierProvider<TtplaySessionBinder>.value(value: env.binder),
          ChangeNotifierProvider<MultiServerProvider>.value(value: env.multiServer),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: SettingsScreen(downloadDirectoryWritableChecker: (_) async => true),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late PathProviderPlatform originalPathProvider;
  late Directory tempDir;
  late _AdminMockServer server;
  HttpOverrides? prevOverrides;

  setUpAll(() {
    originalPathProvider = PathProviderPlatform.instance;
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('plezy_ttplay_admin_vis_');
    PathProviderPlatform.instance = FakePathProvider(tempDir);
    await SettingsService.getInstance();
    server = await _AdminMockServer.start();
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    await server.close();
    HttpOverrides.global = prevOverrides;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('SettingsScreen shows server-admin tiles in self-hosted mode on PC/Mobile', (tester) async {
    tester.view.physicalSize = const Size(1800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final env = await _createSelfHostedEnv(server, isTv: false);
    addTearDown(() => env.dispose(tester));

    await _pumpSelfHostedSettings(tester, env);

    expect(find.text(t.storage.mediaSources), findsOneWidget);
    expect(find.text(t.serverAdmin.sectionTitle), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(t.storage.mediaSources)).dy,
      lessThan(tester.getTopLeft(find.text(t.serverAdmin.sectionTitle)).dy),
    );
    expect(find.text('云端媒体源'), findsOneWidget);
    expect(find.text('云端待匹配中心'), findsOneWidget);
    // Deprecated legacy ttplay-server admin tiles are removed.
    expect(find.text(t.serverAdmin.mountsTitle), findsNothing);
    expect(find.text(t.serverAdmin.scraperTitle), findsNothing);
    expect(find.text(t.serverAdmin.externalServersTitle), findsNothing);
    expect(find.text(t.sync.lanDevicesTitle), findsOneWidget);
    // Local folder mounts remain visible in both offline and online modes.
    expect(find.text(t.storage.title), findsOneWidget);
    expect(find.text(t.storage.scraperSettings), findsOneWidget);
  });

  testWidgets('SettingsScreen hides cloud-admin tiles on TV in self-hosted mode while keeping local folders & LAN devices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    TvDetectionService.debugSetAppleTVOverride(true);
    final env = await _createSelfHostedEnv(server, isTv: true);
    addTearDown(() => env.dispose(tester));

    await _pumpSelfHostedSettings(tester, env);

    expect(find.text(t.serverAdmin.sectionTitle), findsNothing);
    expect(find.text('云端媒体源'), findsNothing);
    expect(find.text('云端待匹配中心'), findsNothing);
    expect(find.text(t.storage.title), findsOneWidget);
    expect(find.text(t.sync.lanDevicesTitle), findsOneWidget);
  });

  testWidgets('TtplayExternalServersScreen toggle triggers PUT and refreshes binder external clients', (tester) async {
    final env = await _createSelfHostedEnv(server, isTv: false);
    addTearDown(() => env.dispose(tester));

    await tester.runAsync(() => env.binder.syncFromSession(refreshExternalServers: true));
    expect(env.serverManager.selfHostedServerIds, contains('ttplay-ext:ext1'));

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppSessionController>.value(value: env.sessionController),
            ChangeNotifierProvider<TtplaySessionBinder>.value(value: env.binder),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: const TtplayExternalServersScreen(),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.text('Living Room Emby').evaluate().isNotEmpty);

    expect(find.text('Living Room Emby'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await _pumpUntil(tester, () {
      final sw = tester.widget<Switch>(find.byType(Switch));
      return !sw.value && !env.serverManager.selfHostedServerIds.contains('ttplay-ext:ext1');
    });
    await tester.pumpAndSettle();

    expect(server.requests.any((r) => r.method == 'PUT' && r.path == '/api/v1/ext-servers/ext1'), isTrue);
    expect(env.serverManager.selfHostedServerIds, contains(TtplayServerClient.primaryServerId));
    expect(env.serverManager.selfHostedServerIds, isNot(contains('ttplay-ext:ext1')));
  });

  testWidgets('showTtplayManualMatchDialog and showTtplayMetadataEditDialog dispatch server mutations', (tester) async {
    tester.view.physicalSize = const Size(1800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final env = await _createSelfHostedEnv(server, isTv: false);
    addTearDown(() => env.dispose(tester));

    final item = MediaItem.jellyfin(
      id: '101',
      kind: MediaKind.movie,
      title: 'Inception',
      year: 2010,
      serverId: TtplayServerClient.primaryServerId,
    );

    bool? matchResult;
    bool? editResult;

    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<TtplaySessionBinder>.value(
          value: env.binder,
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: Row(
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        matchResult = await showTtplayManualMatchDialog(context, item);
                      },
                      child: const Text('open-match'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        editResult = await showTtplayMetadataEditDialog(context, item);
                      },
                      child: const Text('open-edit'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 1. Manual match flow
    await tester.tap(find.text('open-match'));
    await _pumpUntil(tester, () => find.text(t.serverAdmin.applyMatch).evaluate().isNotEmpty);
    expect(find.text(t.serverAdmin.applyMatch), findsOneWidget);
    await tester.tap(find.text(t.serverAdmin.applyMatch));
    await _pumpUntil(tester, () => matchResult != null);
    await tester.pumpAndSettle();
    expect(matchResult, isTrue);
    expect(
      server.requests.any(
        (r) => r.method == 'POST' && r.path == '/api/v1/items/101/match' && r.body['external_id'] == '27205',
      ),
      isTrue,
    );

    // 2. Metadata edit flow
    await tester.tap(find.text('open-edit'));
    await _pumpUntil(tester, () => find.widgetWithText(TextField, t.serverAdmin.fieldStudio).evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, t.serverAdmin.fieldTitle), 'Inception Renamed');
    await tester.tap(find.text(t.common.save));
    await _pumpUntil(tester, () => editResult != null);
    await tester.pumpAndSettle();
    expect(editResult, isTrue);
    expect(
      server.requests.any(
        (r) =>
            r.method == 'PUT' &&
            r.path == '/api/v1/items/101/metadata' &&
            r.body['title'] == 'Inception Renamed',
      ),
      isTrue,
    );
  });

  testWidgets('MediaContextMenu shows ttplay item admin actions on PC and hides them on TV', (tester) async {
    Future<void> verifyMenu({required bool tvMode}) async {
      TvDetectionService.debugSetAppleTVOverride(tvMode);
      final env = await _createSelfHostedEnv(server, isTv: tvMode);
      final stack = await ProfileStack.create(db: env.db, withStorage: false);
      final downloads = _FakeDownloads();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        downloads.dispose();
        await stack.dispose();
        await env.dispose(tester);
      });

      final menuKey = GlobalKey<MediaContextMenuState>();
      final item = MediaItem.jellyfin(
        id: '101',
        kind: MediaKind.movie,
        title: 'Inception',
        year: 2010,
        serverId: TtplayServerClient.primaryServerId,
      );

      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MultiServerProvider>.value(value: env.multiServer),
              ChangeNotifierProvider<ActiveProfileProvider>.value(value: stack.active),
              ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
              ChangeNotifierProvider<AppSessionController>.value(value: env.sessionController),
              ChangeNotifierProvider<TtplaySessionBinder>.value(value: env.binder),
            ],
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: Scaffold(
                body: Center(
                  child: MediaContextMenu(
                    key: menuKey,
                    item: item,
                    child: const SizedBox(width: 120, height: 60, child: Text('menu-target')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      menuKey.currentState!.showContextMenu(tester.element(find.text('menu-target')));
      await tester.pumpAndSettle();

      final expected = tvMode ? findsNothing : findsOneWidget;
      expect(find.text(t.serverAdmin.manualMatch), expected);
      expect(find.text(t.serverAdmin.editMetadata), expected);
      expect(find.text(t.serverAdmin.refreshMetadata), expected);
      expect(find.text(t.serverAdmin.unmatch), expected);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }

    await verifyMenu(tvMode: false);
    await verifyMenu(tvMode: true);
  });
}
