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
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/library/sync/sync_mapper.dart';
import 'package:plezy/main.dart';
import 'package:plezy/media/work_identity.dart';
import 'package:plezy/media/work_skip_settings.dart';
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
import 'package:plezy/services/work_skip_settings_store.dart';
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

  test('SyncMapper persisted DB signatures skip cold-start reconciliation and isolate state vs catalog deltas', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final mountManager = MountManager(MountRegistry(db));
    final syncStore = SyncLocalStore(db);
    final workSkipStore = WorkSkipSettingsStore(db);

    addTearDown(() async {
      await mountManager.dispose();
      await db.close();
    });

    await mountManager.registry.upsert(
      const StorageMount(
        id: 'mount-dav-1',
        kind: StorageKind.webdav,
        displayName: 'Media NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.20/dav'},
      ),
    );
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
    final movieFileId = await repo.upsertFile(
      mountId: 'mount-dav-1',
      path: '/Movies/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 2048000,
      modifiedAt: 1000,
    );
    await repo.linkFile(movieFileId, movieId);
    await repo.updateFile(movieFileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    final showId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.show,
        libraryType: LibraryTypes.show,
        title: 'Severance',
        sortTitle: 'severance',
        tmdbId: const Value('95396'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final seasonId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.season,
        libraryType: LibraryTypes.show,
        parentId: Value(showId),
        showId: Value(showId),
        seasonNumber: const Value(1),
        title: 'Season 1',
        sortTitle: 'season 1',
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final epId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.episode,
        libraryType: LibraryTypes.show,
        parentId: Value(seasonId),
        showId: Value(showId),
        seasonNumber: const Value(1),
        episodeNumber: const Value(1),
        title: 'Good News About Hell',
        sortTitle: 'good news about hell',
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final epFileId = await repo.upsertFile(
      mountId: 'mount-dav-1',
      path: '/Shows/Severance/S01E01.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 1024000,
      modifiedAt: 1000,
    );
    await repo.linkFile(epFileId, epId);
    await repo.updateFile(epFileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    await repo.setProgress(movieId, positionMs: 120000, durationMs: 7200000);
    await workSkipStore.save(
      const WorkIdentity(
        source: WorkIdentity.localSource,
        kind: LibraryKinds.show,
        provider: 'tmdb',
        externalId: '95396',
      ),
      const WorkSkipSettings(introEnabled: true, introStartMs: 0, introEndMs: 90000),
      syncToOutbox: false,
    );

    final mapper1 = SyncMapper(db: db, repo: repo, syncStore: syncStore, mountManager: mountManager);
    final initialTouched = await mapper1.ensureJournalUpToDate();
    expect(initialTouched, greaterThan(0));
    final revAfterBootstrap = await syncStore.getLocalLanRevision();
    final savedSigs1 = await syncStore.getReconciledSignatures();
    expect(savedSigs1.catalogSig, isNotNull);
    expect(savedSigs1.stateSig, isNotNull);

    // Cold restart simulation: fresh SyncMapper instance with empty in-memory signature cache.
    final mapper2 = SyncMapper(db: db, repo: repo, syncStore: SyncLocalStore(db), mountManager: mountManager);
    final coldRestartTouched = await mapper2.ensureJournalUpToDate();
    expect(coldRestartTouched, 0);
    expect(await syncStore.getLocalLanRevision(), revAfterBootstrap);

    // Mutate only watch progress -> only stateSig changes, catalogSig remains identical.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.setProgress(movieId, positionMs: 240000, durationMs: 7200000);
    final mapper3 = SyncMapper(db: db, repo: repo, syncStore: SyncLocalStore(db), mountManager: mountManager);
    final stateOnlyTouched = await mapper3.ensureJournalUpToDate();
    expect(stateOnlyTouched, 1);
    expect(await syncStore.getLocalLanRevision(), revAfterBootstrap + 1);
    final savedSigsAfterState = await syncStore.getReconciledSignatures();
    expect(savedSigsAfterState.catalogSig, savedSigs1.catalogSig);
    expect(savedSigsAfterState.stateSig, isNot(savedSigs1.stateSig));

    // Another cold restart after state update -> immediate 0-work skip.
    final mapper4 = SyncMapper(db: db, repo: repo, syncStore: SyncLocalStore(db), mountManager: mountManager);
    expect(await mapper4.ensureJournalUpToDate(), 0);

    // Add a new catalog movie + file -> catalogSig changes and reconciles the new items.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final movie2Id = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Interstellar',
        sortTitle: 'interstellar',
        tmdbId: const Value('157336'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(2000),
        addedAt: 2000,
        updatedAt: 2000,
      ),
    );
    final movie2FileId = await repo.upsertFile(
      mountId: 'mount-dav-1',
      path: '/Movies/Interstellar.mkv',
      role: LibraryFileRoles.video,
      scanId: 2,
      size: 4096000,
      modifiedAt: 2000,
    );
    await repo.linkFile(movie2FileId, movie2Id);
    await repo.updateFile(movie2FileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    final mapper5 = SyncMapper(db: db, repo: repo, syncStore: SyncLocalStore(db), mountManager: mountManager);
    expect(await mapper5.ensureJournalUpToDate(), greaterThanOrEqualTo(2));
    final savedSigsAfterCatalog = await syncStore.getReconciledSignatures();
    expect(savedSigsAfterCatalog.catalogSig, isNot(savedSigsAfterState.catalogSig));
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
    expect(find.text(t.sync.modeLanTitle), findsOneWidget);
    expect(find.text(t.sync.modeCloudTitle), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await freshBootstrap.dispose();

    // Even when mounts exist, an explicit logout (`sync_onboarding_done == 'false'`) must keep AuthScreen.
    await MountRegistry(db).upsert(
      const StorageMount(
        id: 'm1',
        kind: StorageKind.webdav,
        displayName: 'Home NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.30/dav'},
      ),
    );
    await SyncLocalStore(db).setOnboardingCompleted(false);

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
    await SyncLocalStore(db).setOnboardingCompleted(true);

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
    expect(
      discover.hubs.expand((h) => h.items).map((item) => item.title),
      contains('Inception'),
    );

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
    expect(
      discover.hubs.expand((h) => h.items).map((item) => item.title),
      contains('Spirited Away'),
    );
  });
}
