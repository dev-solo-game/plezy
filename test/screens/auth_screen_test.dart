import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/navigation/profile_session_screen.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/auth/self_hosted_login_screen.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/profile/profile_teardown.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/system_shelf_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/session/app_session_store.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
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

class _TestDownloads extends ChangeNotifier implements DownloadProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCompanion extends ChangeNotifier implements CompanionRemoteProvider {
  @override
  Future<void> resetForLogout() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPlayback extends ChangeNotifier implements PlaybackStateProvider {
  @override
  void clearShuffle() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestServerManager extends MultiServerManager {
  @override
  Future<bool> addJellyfinConnection(JellyfinConnection connection) async {
    updateServerStatus(ServerId(connection.serverMachineId), false);
    return false;
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

  testWidgets('AuthScreen offers Offline and Self-Hosted modes without Plex or legacy sync', (tester) async {
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: AuthScreen(initializeServices: false))));
    await tester.pump();

    expect(find.text(t.session.modeOfflineTitle), findsOneWidget);
    expect(find.text(t.session.modeSelfHostedTitle), findsOneWidget);
    expect(find.text(t.auth.connectToMediaBrowser(product: 'Jellyfin')), findsNothing);
    expect(find.text(t.auth.connectToMediaBrowser(product: 'Emby')), findsNothing);
    expect(find.text(t.storage.title), findsNothing);
    expect(find.text(t.auth.signInWithPlex), findsNothing);
  });

  testWidgets('tapping Self-Hosted mode opens SelfHostedLoginScreen with Server URL and Test Connection', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MountManager(MountRegistry(db));
    final appSession = AppSessionController(db: db, mountManager: manager);
    addTearDown(() async {
      appSession.dispose();
      await manager.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppSessionController>.value(
        value: appSession,
        child: TranslationProvider(child: const MaterialApp(home: AuthScreen(initializeServices: false))),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.session.modeSelfHostedTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SelfHostedLoginScreen), findsOneWidget);
    expect(find.text(SelfHostedLoginScreen.defaultServerUrl), findsOneWidget);
    expect(SelfHostedLoginScreen.defaultServerUrl, 'https://play.ttai.net');
    expect(find.text(t.session.serverUrlLabel), findsOneWidget);
    expect(find.text(t.session.testServer), findsOneWidget);
    expect(find.text(t.session.usernameLabel), findsOneWidget);
    expect(find.text(t.session.passwordLabel), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.session.signInButton), findsOneWidget);
  });

  test('selecting Offline mode persists AppLoginMode.offline without requiring a server', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MountManager(MountRegistry(db));
    final appSession = AppSessionController(db: db, mountManager: manager);
    addTearDown(() async {
      appSession.dispose();
      await manager.dispose();
      await db.close();
    });

    await appSession.initialize();
    expect(appSession.hasSelectedMode, isFalse);

    await appSession.selectOfflineMode();
    expect(appSession.isOffline, isTrue);
    expect(appSession.hasSelectedMode, isTrue);
    expect((await AppSessionStore(db).load()).mode, AppLoginMode.offline);
  });

  testWidgets('logout preserves local library, profile, and media sources, and re-entering Offline loads Discover', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final manager = MountManager(MountRegistry(db));
    await tester.runAsync(() => manager.proxy.start());
    final localClient = LocalLibraryClient(repository: repo, mounts: manager);
    final profileRegistry = ProfileRegistry(db);
    final connectionRegistry = ConnectionRegistry(db);
    final profileConnectionRegistry = ProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
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
    final serverManager = _TestServerManager();
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
    final appSession = AppSessionController(db: db, mountManager: manager);
    final downloads = _TestDownloads();
    final companion = _TestCompanion();
    final playback = _TestPlayback();

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      binder.dispose();
      await activeProfile.resetForTesting();
      activeProfile.dispose();
      appSession.dispose();
      offlineWatch.dispose();
      multiServer.dispose();
      serverManager.dispose();
      await plexHome.dispose();
      await tester.runAsync(() async {
        await manager.dispose();
        await db.close();
      });
    });

    final localProfile = Profile.local(id: 'local-1', displayName: 'Local', createdAt: DateTime(2026, 1, 1));
    final jfConn = testJellyfinConnection(machineId: 'jf-1', userId: 'user-1');
    await profileRegistry.upsert(localProfile);
    await connectionRegistry.upsert(jfConn);
    await profileConnectionRegistry.upsert(
      ProfileConnection(profileId: localProfile.id, connectionId: jfConn.id, userToken: 'tok', userIdentifier: 'u1'),
    );
    await activeProfile.reloadFromStorage();
    await activeProfile.activate(localProfile);

    serverManager.registerLocalLibrary(localClient);
    await appSession.selectOfflineMode();
    binder.start();
    await binder.rebindActive();

    late BuildContext capturedContext;
    Widget wrapWithProviders(Widget home, {Key? appKey}) => MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        Provider<AppDatabase>.value(value: db),
        Provider<ProfileRegistry>.value(value: profileRegistry),
        Provider<ConnectionRegistry>.value(value: connectionRegistry),
        Provider<ProfileConnectionRegistry>.value(value: profileConnectionRegistry),
        Provider<PlexHomeService>.value(value: plexHome),
        ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
        Provider<ActiveProfileBinder>.value(value: binder),
        ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
        ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companion),
        ChangeNotifierProvider<PlaybackStateProvider>.value(value: playback),
        ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
        Provider<LocalLibraryClient>.value(value: localClient),
        ChangeNotifierProvider<AppSessionController>.value(value: appSession),
      ],
      child: TranslationProvider(
        child: MaterialApp(key: appKey, home: home),
      ),
    );

    await tester.pumpWidget(
      wrapWithProviders(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    await logoutAllProfiles(capturedContext);
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(appSession.hasSelectedMode, isFalse);
    expect(appSession.explicitlyLoggedOut, isTrue);
    expect((await AppSessionStore(db).load()).explicitlyLoggedOut, isTrue);
    expect(serverManager.isServerOnline(ServerId(LocalLibraryClient.localServerId)), isTrue);
    expect((await profileRegistry.list()).map((p) => p.id), [localProfile.id]);
    expect((await connectionRegistry.list()).map((c) => c.id), [jfConn.id]);

    late DiscoverProvider sessionDiscover;
    late MultiServerProvider sessionMultiServer;
    await tester.pumpWidget(
      wrapWithProviders(
        AuthScreen(
          initializeServices: false,
          sessionBuilder: (_) => ProfileSessionScreen.forTesting(
            initialPromptHandled: true,
            httpClientFactory: () => FakeHttpClient(200, const <int>[]),
            profileShellBuilder: (shellContext) {
              sessionDiscover = shellContext.read<DiscoverProvider>();
              sessionMultiServer = shellContext.read<MultiServerProvider>();
              return const Scaffold(body: Text('session-ready'));
            },
          ),
        ),
        appKey: const ValueKey('reenter-auth'),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.session.modeOfflineTitle));
    await tester.pumpAndSettle();

    expect(find.text('session-ready'), findsOneWidget);
    expect(sessionMultiServer.hasConnectedServers, isTrue);
    expect(sessionMultiServer.onlineServerIds, contains(LocalLibraryClient.localServerId));

    await sessionDiscover.load();
    expect(sessionDiscover.errorMessage, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
