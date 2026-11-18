import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_models.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/discover_screen.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/screens/storage/lan_devices_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/side_navigation_rail.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  testWidgets('Local/LAN mode menu shows non-clickable mode header, device count, Switch Sync Mode, and opens LanDevicesScreen', (
    tester,
  ) async {
    final harness = await _pumpDiscoverWithSync(tester);
    addTearDown(() => harness.dispose(tester));

    final kp1 = await SyncCrypto.generateLanIdentityKeyPair();
    final kp2 = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 17, 0);

    harness.sync.lanService.debugSeedStateForTesting(
      deviceName: 'LivingRoom-PC',
      publicKeyBase64: kp1.publicKeyBase64,
      discovered: [
        LanDiscoveredPeer(
          deviceId: 'peer-1',
          deviceName: 'MacBook-Pro',
          platform: 'macos',
          host: '192.168.1.20',
          httpPort: 48635,
          pubKeyBase64: kp2.publicKeyBase64,
          revision: 3,
          lastSeen: now,
        ),
        LanDiscoveredPeer(
          deviceId: 'peer-2',
          deviceName: 'iPhone-15',
          platform: 'ios',
          host: '192.168.1.21',
          httpPort: 48636,
          pubKeyBase64: kp1.publicKeyBase64,
          revision: 1,
          lastSeen: now,
        ),
      ],
    );
    await tester.pump();

    final menuButton = find.byTooltip(t.sync.userMenuTooltip);
    expect(menuButton, findsOneWidget);

    await tester.tap(menuButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Mode header (non-clickable)
    final headerFinder = find.text(t.sync.menuModeLanTitle);
    expect(headerFinder, findsOneWidget);
    expect(find.text(t.sync.menuModeLanSubtitle(device: 'LivingRoom-PC')), findsOneWidget);

    // Legacy profile UI and logout must not appear in Local/LAN mode
    expect(find.text(t.profiles.sectionTitle), findsNothing);
    expect(find.text(t.common.logout), findsNothing);

    // Tapping the mode header keeps the menu open
    await tester.tap(headerFinder);
    await tester.pump(const Duration(milliseconds: 150));
    expect(headerFinder, findsOneWidget);

    // Switch Sync Mode + LAN devices with discovered count
    expect(find.text(t.sync.switchSyncMode), findsOneWidget);
    expect(find.text(t.sync.lanDevicesTitle), findsOneWidget);
    expect(find.text(t.sync.lanDiscoveredCount(count: 2)), findsOneWidget);

    // Tap LAN Devices -> opens standalone LanDevicesScreen without cloud login fields
    await tester.tap(find.text(t.sync.lanDevicesTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(LanDevicesScreen), findsOneWidget);
    expect(find.text('MacBook-Pro (macos)'), findsOneWidget);
    expect(find.text('iPhone-15 (ios)'), findsOneWidget);
    expect(find.text(t.sync.password), findsNothing);
  });

  testWidgets('Cloud Sync mode shows account avatar initial, cloud mode header, Sync Settings, and Logout', (
    tester,
  ) async {
    final harness = await _pumpDiscoverWithSync(tester);
    addTearDown(() => harness.dispose(tester));

    harness.sync.debugSetSessionForTesting(
      SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'u-1',
        username: 'alice',
        accessToken: 'tok-1',
        masterKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      pendingOutboxCount: 3,
    );
    await tester.pump();

    final menuButton = find.byTooltip(t.sync.userMenuTooltip);
    expect(menuButton, findsOneWidget);
    expect(find.text('A'), findsOneWidget);

    await tester.tap(menuButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text(t.sync.menuModeCloudTitle), findsOneWidget);
    expect(find.text(t.sync.menuModeCloudSubtitle(name: 'alice')), findsOneWidget);
    expect(find.text(t.sync.title), findsOneWidget);
    expect(find.text(t.sync.pendingChanges(count: 3)), findsOneWidget);
    expect(find.text(t.common.settings), findsOneWidget);
    expect(find.text(t.common.logout), findsOneWidget);

    expect(find.text(t.sync.lanDevicesTitle), findsNothing);
    expect(find.text(t.sync.switchSyncMode), findsNothing);
  });

  testWidgets('Local/LAN mode shows Chinese mode labels and incoming pair request badge', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zh));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));
    final harness = await _pumpDiscoverWithSync(tester);
    addTearDown(() => harness.dispose(tester));

    final kp = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 17, 5);
    harness.sync.lanService.debugSeedStateForTesting(
      deviceName: '客厅电脑',
      publicKeyBase64: kp.publicKeyBase64,
      discovered: [
        LanDiscoveredPeer(
          deviceId: 'peer-zh-1',
          deviceName: '书房手机',
          platform: 'android',
          host: '192.168.1.30',
          httpPort: 48635,
          pubKeyBase64: kp.publicKeyBase64,
          revision: 1,
          lastSeen: now,
        ),
      ],
      incomingRequests: [
        LanPairRequest(
          deviceId: 'peer-zh-1',
          deviceName: '书房手机',
          platform: 'android',
          host: '192.168.1.30',
          httpPort: 48635,
          pubKeyBase64: kp.publicKeyBase64,
          pairingCode: '1234',
          requestedAt: now,
        ),
      ],
    );
    await tester.pump();

    await tester.tap(find.byTooltip('同步与设备菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('本地与局域网模式'), findsOneWidget);
    expect(find.text('本机：客厅电脑'), findsOneWidget);
    expect(find.text('局域网设备'), findsOneWidget);
    expect(find.text('已发现 1 台'), findsOneWidget);
    expect(find.text('1 条配对请求'), findsOneWidget);
    expect(find.text('切换同步模式'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('DiscoverScreen top bar and user menu display active LAN and Cloud sync progress', (tester) async {
    final harness = await _pumpDiscoverWithSync(tester);
    addTearDown(() => harness.dispose(tester));

    harness.sync.lanService.debugSeedStateForTesting(
      deviceName: 'Phone-A',
      progress: const SyncProgress(
        phase: SyncPhase.applying,
        processed: 42,
        total: 120,
        peerName: 'LivingRoom-TV',
      ),
    );
    await tester.pump();

    expect(find.text('LAN Sync (LivingRoom-TV) · Updating 42/120'), findsOneWidget);

    await tester.tap(find.byTooltip(t.sync.userMenuTooltip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Updating 42/120'), findsOneWidget);

    // Dismiss menu before switching locale and verifying Chinese copy.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zh));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));
    harness.sync.lanService.debugSeedStateForTesting(
      progress: const SyncProgress(
        phase: SyncPhase.applying,
        processed: 42,
        total: 120,
        peerName: '客厅电视',
      ),
    );
    await tester.pump();
    expect(find.text('局域网同步 (客厅电视) · 正在更新 42/120'), findsOneWidget);

    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
    harness.sync.lanService.debugSeedStateForTesting(progress: SyncProgress.idle);
    harness.sync.debugSetSessionForTesting(
      SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'u-1',
        username: 'alice',
        accessToken: 'tok-1',
        masterKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      pendingOutboxCount: 20,
      progress: const SyncProgress(phase: SyncPhase.pushing, processed: 8, total: 20),
    );
    await tester.pump();

    expect(find.text('Cloud Sync · Uploading 8/20'), findsOneWidget);

    await tester.tap(find.byTooltip(t.sync.userMenuTooltip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Uploading 8/20'), findsOneWidget);

    harness.sync.debugSetSessionForTesting(null, progress: SyncProgress.idle);
    await tester.pump();
  });
}

class _MenuHarness {
  _MenuHarness({
    required this.db,
    required this.sync,
    required this.offlineWatch,
    required this.discoverProvider,
    required this.librariesProvider,
    required this.hiddenLibrariesProvider,
    required this.companionRemoteProvider,
    required this.multiServerProvider,
  });

  final AppDatabase db;
  final SyncAndScanCoordinator sync;
  final OfflineWatchSyncService offlineWatch;
  final DiscoverProvider discoverProvider;
  final LibrariesProvider librariesProvider;
  final HiddenLibrariesProvider hiddenLibrariesProvider;
  final CompanionRemoteProvider companionRemoteProvider;
  final MultiServerProvider multiServerProvider;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    sync.dispose();
    offlineWatch.dispose();
    discoverProvider.dispose();
    librariesProvider.dispose();
    hiddenLibrariesProvider.dispose();
    companionRemoteProvider.dispose();
    multiServerProvider.dispose();
    await db.close();
  }
}

Future<_MenuHarness> _pumpDiscoverWithSync(WidgetTester tester) async {
  await SettingsService.getInstance();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final client = _FakeClient();
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final multiServerProvider = testMultiServerProvider(manager);
  final hiddenLibrariesProvider = HiddenLibrariesProvider();
  final librariesProvider = LibrariesProvider();
  final companionRemoteProvider = CompanionRemoteProvider();

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final repo = LibraryRepository(db);
  final mountManager = MountManager(MountRegistry(db));
  final sync = SyncAndScanCoordinator(
    db: db,
    repo: repo,
    mountManager: mountManager,
    enableLanUdp: false,
    autoStartLanService: false,
  );
  final offlineWatch = OfflineWatchSyncService(database: db, serverManager: manager);
  final discoverProvider = DiscoverProvider(
    multiServerProvider,
    hiddenLibrariesProvider,
    librariesProvider,
    profileId: null,
    isProfileBinding: () => false,
  );

  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<SyncAndScanCoordinator>.value(value: sync),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
          ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              focusSidebar: () {},
              sideNavigationWidth: SideNavigationRailState.expandedWidth,
              reservedSideNavigationWidth: SideNavigationRailState.tvCollapsedWidth,
              foregroundLeft: 0,
              foregroundWidth: 1280,
              viewportWidth: 1280,
              child: const DiscoverScreen(),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  return _MenuHarness(
    db: db,
    sync: sync,
    offlineWatch: offlineWatch,
    discoverProvider: discoverProvider,
    librariesProvider: librariesProvider,
    hiddenLibrariesProvider: hiddenLibrariesProvider,
    companionRemoteProvider: companionRemoteProvider,
    multiServerProvider: multiServerProvider,
  );
}

class _FakeClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async =>
      const [];

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
