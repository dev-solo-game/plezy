import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/tvos_database_recovery_store.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/session/app_session_store.dart';
import 'package:plezy/main.dart';
import 'package:plezy/navigation/profile_session_screen.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/system_shelf_service.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:provider/provider.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

class _TestPlexHome extends PlexHomeService {
  _TestPlexHome({required super.connections, required super.profileConnections, required super.storage})
    : super(plexHomeUserFetcher: (_) async => const []);

  @override
  Future<void> start() async {}

  @override
  Future<void> reloadFromStorage() async {}

  @override
  Future<void> dispose() async {}
}

class _HangingJellyfinServerManager extends MultiServerManager {
  final Completer<bool> probeCompleter = Completer<bool>();
  int addJellyfinCalls = 0;

  @override
  Future<bool> addJellyfinConnection(JellyfinConnection connection) {
    addJellyfinCalls++;
    return probeCompleter.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    SystemShelfService().debugReset();
  });

  tearDown(() {
    SystemShelfService().debugReset();
  });

  test('Legacy mounts auto-migrate to offline mode once while explicit logout stays on AuthScreen', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final storage = await StorageService.getInstance();
    final settings = await SettingsService.getInstance();
    final store = AppSessionStore(db);

    await MountRegistry(db).upsert(
      const StorageMount(
        id: 'mount-legacy-1',
        kind: StorageKind.webdav,
        displayName: 'Legacy NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.20/dav'},
      ),
    );

    final migratedBootstrap = await resolveStartupSessionBootstrap(
      appDatabase: db,
      storage: storage,
      settings: settings,
      databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable,
    );
    expect(migratedBootstrap.mode, StartupSessionMode.readyForHome);
    expect(migratedBootstrap.loginMode, AppLoginMode.offline);
    expect((await store.load()).mode, AppLoginMode.offline);
    await migratedBootstrap.dispose();

    // Clear back to explicit logged-out state; existing mounts must NOT override explicit logout.
    await store.clearMode();
    final loadedAfterLogout = await store.load();
    expect(loadedAfterLogout.mode, isNull);
    expect(loadedAfterLogout.explicitlyLoggedOut, isTrue);

    final loggedOutBootstrap = await resolveStartupSessionBootstrap(
      appDatabase: db,
      storage: storage,
      settings: settings,
      databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable,
    );
    expect(loggedOutBootstrap.mode, StartupSessionMode.onboardingRequired);
    await loggedOutBootstrap.dispose();
    await db.close();
  });

  testWidgets('Fresh install and explicit logout still route to AuthScreen mode picker', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final storage = await StorageService.getInstance();
    final settings = await SettingsService.getInstance();

    final freshBootstrap = await resolveStartupSessionBootstrap(
      appDatabase: db,
      storage: storage,
      settings: settings,
      databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.fresh,
    );
    expect(freshBootstrap.mode, StartupSessionMode.onboardingRequired);

    await tester.pumpWidget(
      MainApp(
        settings: settings,
        storage: storage,
        appDatabase: db,
        databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.fresh,
        sessionBootstrap: freshBootstrap,
        enableBackgroundSyncServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text(t.session.modeOfflineTitle), findsOneWidget);
    expect(find.text(t.session.modeSelfHostedTitle), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await freshBootstrap.dispose();

    // Even when mounts exist, an explicit logout (no active mode in AppSessionStore) must keep AuthScreen.
    await MountRegistry(db).upsert(
      const StorageMount(
        id: 'm1',
        kind: StorageKind.webdav,
        displayName: 'Home NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.30/dav'},
      ),
    );
    await AppSessionStore(db).clearMode();

    final loggedOutBootstrap = await resolveStartupSessionBootstrap(
      appDatabase: db,
      storage: storage,
      settings: settings,
      databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable,
    );
    expect(loggedOutBootstrap.mode, StartupSessionMode.onboardingRequired);
    await loggedOutBootstrap.dispose();
    await db.close();
  });

  testWidgets('Completed onboarding skips SetupScreen and loads local library directly into Home', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final storage = await StorageService.getInstance();
    final settings = await SettingsService.getInstance();
    final repo = LibraryRepository(db);
    await LibrarySettingsStore(db).setNamingVersion(LibraryScanner.namingVersion);

    await MountRegistry(db).upsert(
      const StorageMount(
        id: 'm-home',
        kind: StorageKind.webdav,
        displayName: 'Home NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.40/dav'},
      ),
    );
    await AppSessionStore(db).saveOfflineMode();

    final movieId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Inception',
        sortTitle: 'inception',
        tmdbId: const Value('27205'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final fileId = await repo.upsertFile(
      mountId: 'm-home',
      path: '/Movies/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 1024,
      modifiedAt: 1000,
    );
    await repo.linkFile(fileId, movieId);
    await repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    final bootstrap = await resolveStartupSessionBootstrap(
      appDatabase: db,
      storage: storage,
      settings: settings,
      databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable,
    );
    expect(bootstrap.mode, StartupSessionMode.readyForHome);
    expect(bootstrap.shouldGuideToMounts, isFalse);
    expect(bootstrap.activeProfileProvider?.active, isNotNull);

    await tester.pumpWidget(
      MainApp(
        settings: settings,
        storage: storage,
        appDatabase: db,
        databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable,
        sessionBootstrap: bootstrap,
        enableBackgroundSyncServices: false,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SetupScreen), findsNothing);
    expect(find.text(t.common.connectingToServers), findsNothing);
    expect(find.byType(ProfileSessionScreen), findsOneWidget);
    expect(find.byType(MainScreen), findsOneWidget);

    await tester.pumpAndSettle();
    final mainElement = tester.element(find.byType(MainScreen));
    final discover = mainElement.read<DiscoverProvider>();
    final libraries = mainElement.read<LibrariesProvider>();
    expect(libraries.libraries, isNotEmpty);
    expect(discover.hubs.expand((h) => h.items).map((item) => item.title), contains('Inception'));

    // Advance FakeAsync past ConnectivityProbe's 3s fallback timeout before tearing down MainScreen.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    // Flush WinHttpClient._maybeCloseSession's 2s timer scheduled during MainApp teardown.
    await tester.pump(const Duration(seconds: 3));
    await bootstrap.dispose();
    await db.close();
  });

  testWidgets('Cold start renders local library on Frame 1 even while an optional Jellyfin server probe hangs', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final storage = await StorageService.getInstance();
    final repo = LibraryRepository(db);
    final mountManager = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: repo, mounts: mountManager);
    final profileRegistry = ProfileRegistry(db);
    final connectionRegistry = ConnectionRegistry(db);
    final profileConnectionRegistry = ProfileConnectionRegistry(db);
    final plexHome = _TestPlexHome(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final activeProfile = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final serverManager = _HangingJellyfinServerManager();
    final multiServer = testMultiServerProvider(serverManager);
    final binder = ActiveProfileBinder(
      activeProfile: activeProfile,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      serverManager: serverManager,
      multiServerProvider: multiServer,
      pinPrompt: (_, {String? errorMessage}) async => null,
    );
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: serverManager);

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      if (!serverManager.probeCompleter.isCompleted) {
        serverManager.probeCompleter.complete(false);
      }
      binder.dispose();
      await activeProfile.resetForTesting();
      activeProfile.dispose();
      offlineWatch.dispose();
      multiServer.dispose();
      serverManager.dispose();
      await plexHome.dispose();
      localClient.close();
      await mountManager.dispose();
      await db.close();
    });

    const mount = StorageMount(
      id: 'm-local-with-jf',
      kind: StorageKind.webdav,
      displayName: 'Home NAS',
      config: {MountKeys.baseUrl: 'http://192.168.1.50/dav'},
    );
    await mountManager.registry.upsert(mount);
    final movieId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Spirited Away',
        sortTitle: 'spirited away',
        tmdbId: const Value('129'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final fileId = await repo.upsertFile(
      mountId: mount.id,
      path: '/Movies/SpiritedAway.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 2048,
      modifiedAt: 1000,
    );
    await repo.linkFile(fileId, movieId);
    await repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    final profile = Profile.local(id: 'local-default', displayName: 'Local', createdAt: DateTime(2026, 1, 1));
    final jfConn = testJellyfinConnection(
      machineId: 'jf-slow-machine',
      userId: 'u1',
      baseUrl: 'http://10.0.0.99:8096',
      serverName: 'Slow Jellyfin',
      userName: 'user',
      accessToken: 'tok',
    );
    await profileRegistry.upsert(profile);
    await connectionRegistry.upsert(jfConn);
    await profileConnectionRegistry.upsert(
      ProfileConnection(profileId: profile.id, connectionId: jfConn.id, userToken: 'tok', userIdentifier: 'u1'),
    );
    await activeProfile.initialize();
    await activeProfile.activate(profile);

    localClient.seedMounts([mount]);
    serverManager.registerLocalLibrary(localClient);

    // Start background remote binding (probe stays pending on serverManager.probeCompleter).
    binder.start();
    expect(activeProfile.isBinding, isTrue);
    expect(binder.hasBoundOnce, isFalse);

    late DiscoverProvider discover;
    late LibrariesProvider libraries;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          Provider<AppDatabase>.value(value: db),
          Provider<ConnectionRegistry>.value(value: connectionRegistry),
          Provider<ProfileConnectionRegistry>.value(value: profileConnectionRegistry),
          Provider<PlexHomeService>.value(value: plexHome),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
          Provider<ActiveProfileBinder>.value(value: binder),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          Provider<LocalLibraryClient>.value(value: localClient),
        ],
        child: MaterialApp(
          home: ProfileSessionScreen.forTesting(
            initialPromptHandled: true,
            httpClientFactory: () => FakeHttpClient(200, utf8.encode('{}')),
            profileShellBuilder: (context) {
              discover = context.read<DiscoverProvider>();
              libraries = context.read<LibrariesProvider>();
              return const Scaffold(body: Text('home-frame-1'));
            },
          ),
        ),
      ),
    );
    await tester.pump();

    libraries.initialize(multiServer.aggregationService);
    await libraries.loadLibraries();
    await discover.load();

    // Even while Jellyfin probe is still stuck (`isBinding == true`), local library loaded immediately!
    expect(activeProfile.isBinding, isTrue);
    expect(serverManager.addJellyfinCalls, 1);
    expect(libraries.hasLibraries, isTrue);
    expect(discover.hubs.expand((h) => h.items).map((item) => item.title), contains('Spirited Away'));
  });
}
