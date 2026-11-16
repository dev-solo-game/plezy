import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/library/sync/sync_mapper.dart';
import 'package:plezy/screens/storage/lan_devices_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/lan_pair_prompt_host.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

class _PromptHarness {
  _PromptHarness({required this.db, required this.sync});

  final AppDatabase db;
  final SyncAndScanCoordinator sync;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    sync.dispose();
    await db.close();
  }
}

Future<_PromptHarness> _pumpPromptHost(WidgetTester tester) async {
  await SettingsService.getInstance();
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

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: sync,
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: LanPairPromptHost(
              child: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const LanDevicesScreen()),
                      ),
                      child: const Text('Open LAN Devices'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _PromptHarness(db: db, sync: sync);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  testWidgets('discovery auto-prompts once with 15s countdown, auto-cancels, and remains trustable in LanDevicesScreen', (
    tester,
  ) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await SyncCrypto.generateLanIdentityKeyPair();
    final tvKp = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 0);
    final peerTv = LanDiscoveredPeer(
      deviceId: 'peer-tv',
      deviceName: '客厅电视',
      platform: 'android',
      host: '192.168.1.40',
      httpPort: 48635,
      pubKeyBase64: tvKp.publicKeyBase64,
      revision: 1,
      lastSeen: now,
    );

    harness.sync.lanService.debugSeedStateForTesting(
      deviceName: 'Phone-A',
      publicKeyBase64: myKp.publicKeyBase64,
      discovered: [peerTv],
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(LanPairPromptDialog), findsOneWidget);
    expect(find.text(t.sync.lanPopupDiscoverTitle), findsOneWidget);
    expect(find.textContaining('客厅电视'), findsOneWidget);
    expect(find.text('Cancel (15s)'), findsOneWidget);
    expect(find.text(t.sync.lanPairButton), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Cancel (10s)'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LanPairPromptDialog), findsNothing);

    final prompted = await tester.runAsync(() => harness.sync.syncStore.loadPromptedLanPeerIds());
    expect(prompted, contains('peer-tv'));

    // Re-broadcasting the same peer never pops up again.
    harness.sync.lanService.debugSeedStateForTesting(
      discovered: [
        LanDiscoveredPeer(
          deviceId: 'peer-tv',
          deviceName: '客厅电视',
          platform: 'android',
          host: '192.168.1.40',
          httpPort: 48635,
          pubKeyBase64: tvKp.publicKeyBase64,
          revision: 2,
          lastSeen: now.add(const Duration(seconds: 20)),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LanPairPromptDialog), findsNothing);

    // Peer remains visible and manually trustable inside LanDevicesScreen.
    await tester.tap(find.text('Open LAN Devices'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(LanDevicesScreen), findsOneWidget);
    expect(find.text('客厅电视 (android)'), findsOneWidget);
    expect(find.text(t.sync.lanPairButton), findsOneWidget);
  });

  testWidgets('manual cancel dismisses immediately and subsequent discovery prompts only for a new device', (tester) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await SyncCrypto.generateLanIdentityKeyPair();
    final kp1 = await SyncCrypto.generateLanIdentityKeyPair();
    final kp2 = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 5);

    final peer1 = LanDiscoveredPeer(
      deviceId: 'peer-1',
      deviceName: 'MacBook-Pro',
      platform: 'macos',
      host: '192.168.1.20',
      httpPort: 48635,
      pubKeyBase64: kp1.publicKeyBase64,
      revision: 1,
      lastSeen: now,
    );
    final peer2 = LanDiscoveredPeer(
      deviceId: 'peer-2',
      deviceName: 'iPad-Pro',
      platform: 'ios',
      host: '192.168.1.21',
      httpPort: 48635,
      pubKeyBase64: kp2.publicKeyBase64,
      revision: 1,
      lastSeen: now,
    );

    harness.sync.lanService.debugSeedStateForTesting(
      publicKeyBase64: myKp.publicKeyBase64,
      discovered: [peer1],
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('MacBook-Pro'), findsOneWidget);

    await tester.tap(find.text('Cancel (15s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LanPairPromptDialog), findsNothing);

    harness.sync.lanService.debugSeedStateForTesting(discovered: [peer1, peer2]);
    await tester.pump();
    await tester.pump();
    expect(find.byType(LanPairPromptDialog), findsOneWidget);
    expect(find.textContaining('iPad-Pro'), findsOneWidget);
    expect(find.textContaining('MacBook-Pro'), findsNothing);

    await tester.tap(find.text('Cancel (15s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LanPairPromptDialog), findsNothing);
  });

  testWidgets('discovery popup upgrades in-place on incoming pair request and closes when trusted', (tester) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await SyncCrypto.generateLanIdentityKeyPair();
    final peerKp = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 10);
    final peer = LanDiscoveredPeer(
      deviceId: 'peer-1',
      deviceName: 'LivingRoom-TV',
      platform: 'android',
      host: '192.168.1.55',
      httpPort: 48635,
      pubKeyBase64: peerKp.publicKeyBase64,
      revision: 1,
      lastSeen: now,
    );

    harness.sync.lanService.debugSeedStateForTesting(
      publicKeyBase64: myKp.publicKeyBase64,
      discovered: [peer],
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(t.sync.lanPopupDiscoverTitle), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Cancel (9s)'), findsOneWidget);

    harness.sync.lanService.debugSeedStateForTesting(
      discovered: [peer],
      incomingRequests: [
        LanPairRequest(
          deviceId: 'peer-1',
          deviceName: 'LivingRoom-TV',
          platform: 'android',
          host: '192.168.1.55',
          httpPort: 48635,
          pubKeyBase64: peerKp.publicKeyBase64,
          pairingCode: '4821',
          requestedAt: now,
        ),
      ],
    );
    await tester.pump();

    expect(find.byType(LanPairPromptDialog), findsOneWidget);
    expect(find.text(t.sync.lanPopupRequestTitle), findsOneWidget);
    expect(find.text('Cancel (15s)'), findsOneWidget);
    expect(find.text(t.sync.lanAcceptButton), findsOneWidget);
    expect(find.textContaining('4821'), findsOneWidget);

    // Becoming trusted closes the dialog automatically without waiting for timeout.
    harness.sync.lanService.debugSeedStateForTesting(
      discovered: [peer],
      trusted: [
        LanTrustedPeer(
          deviceId: 'peer-1',
          deviceName: 'LivingRoom-TV',
          pubKeyBase64: peerKp.publicKeyBase64,
          sharedKeyBase64: myKp.publicKeyBase64,
          lastSyncedRevision: 0,
          pairedAtMs: now.millisecondsSinceEpoch,
        ),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LanPairPromptDialog), findsNothing);
  });

  testWidgets('timed-out incoming pair request remains accept/rejectable inside LanDevicesScreen', (tester) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await SyncCrypto.generateLanIdentityKeyPair();
    final peerKp = await SyncCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 15);
    final req = LanPairRequest(
      deviceId: 'peer-req',
      deviceName: 'Study-PC',
      platform: 'windows',
      host: '192.168.1.60',
      httpPort: 48635,
      pubKeyBase64: peerKp.publicKeyBase64,
      pairingCode: '7788',
      requestedAt: now,
    );

    harness.sync.lanService.debugSeedStateForTesting(
      publicKeyBase64: myKp.publicKeyBase64,
      incomingRequests: [req],
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(t.sync.lanPopupRequestTitle), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LanPairPromptDialog), findsNothing);

    await tester.tap(find.text('Open LAN Devices'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(LanDevicesScreen), findsOneWidget);
    expect(find.text(t.sync.lanRequestsTitle), findsOneWidget);
    expect(find.text('Study-PC'), findsOneWidget);
    expect(find.text(t.sync.lanAcceptButton), findsOneWidget);
    expect(find.text(t.sync.lanRejectButton), findsOneWidget);
  });

  test('simultaneous mutual click completes loopback handshake without secondary accept and never auto-prompts again', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    Future<({AppDatabase db, MountManager mounts, LanPeerSyncService lan})> startPeer(String name) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = LibraryRepository(db);
      final mounts = MountManager(MountRegistry(db));
      final syncStore = SyncLocalStore(db);
      await syncStore.setDeviceName(name);
      final lan = LanPeerSyncService(
        syncStore: syncStore,
        mapper: SyncMapper(db: db, repo: repo, syncStore: syncStore, mountManager: mounts),
        enableUdpBroadcast: false,
      );
      await lan.start();
      return (db: db, mounts: mounts, lan: lan);
    }

    final devA = await startPeer('Device-A');
    final devB = await startPeer('Device-B');
    addTearDown(() async {
      devA.lan.dispose();
      devB.lan.dispose();
      await devA.mounts.dispose();
      await devB.mounts.dispose();
      await devA.db.close();
      await devB.db.close();
    });

    final now = DateTime.now();
    final peerBOnA = LanDiscoveredPeer(
      deviceId: devB.lan.deviceId!,
      deviceName: 'Device-B',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: devB.lan.listeningPort!,
      pubKeyBase64: devB.lan.publicKeyBase64!,
      revision: 0,
      lastSeen: now,
    );
    final peerAOnB = LanDiscoveredPeer(
      deviceId: devA.lan.deviceId!,
      deviceName: 'Device-A',
      platform: 'windows',
      host: '127.0.0.1',
      httpPort: devA.lan.listeningPort!,
      pubKeyBase64: devA.lan.publicKeyBase64!,
      revision: 0,
      lastSeen: now,
    );

    devA.lan.registerDiscoveredPeer(peerBOnA);
    devB.lan.registerDiscoveredPeer(peerAOnB);

    expect(devA.lan.shouldAutoPromptPeer(devB.lan.deviceId!), isTrue);
    expect(devB.lan.shouldAutoPromptPeer(devA.lan.deviceId!), isTrue);

    await Future.wait([
      devA.lan.requestPairWithPeer(peerBOnA),
      devB.lan.requestPairWithPeer(peerAOnB),
    ]);

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while ((devA.lan.trustedPeers.isEmpty || devB.lan.trustedPeers.isEmpty) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(devA.lan.isPeerTrusted(devB.lan.deviceId!), isTrue);
    expect(devB.lan.isPeerTrusted(devA.lan.deviceId!), isTrue);
    expect(devA.lan.shouldAutoPromptPeer(devB.lan.deviceId!), isFalse);

    // Even after removing trust manually, an already-trusted-once device never auto-pops again.
    await devA.lan.removeTrustedPeer(devB.lan.deviceId!);
    expect(devA.lan.isPeerTrusted(devB.lan.deviceId!), isFalse);
    expect(devA.lan.shouldAutoPromptPeer(devB.lan.deviceId!), isFalse);
  });
}
