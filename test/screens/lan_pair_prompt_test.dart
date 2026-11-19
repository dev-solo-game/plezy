import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/storage/lan_devices_screen.dart';
import 'package:plezy/services/companion_remote/lan_crypto.dart';
import 'package:plezy/services/companion_remote/lan_identity_store.dart';
import 'package:plezy/services/companion_remote/lan_pairing_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/lan_pair_prompt_host.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

class _PromptHarness {
  _PromptHarness({required this.db, required this.lan, required this.appSession});

  final AppDatabase db;
  final LanPairingService lan;
  final AppSessionController appSession;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    lan.dispose();
    appSession.dispose();
    await db.close();
  }
}

Future<_PromptHarness> _pumpPromptHost(WidgetTester tester) async {
  await SettingsService.getInstance();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final identityStore = LanIdentityStore(db);
  final lan = LanPairingService(identityStore: identityStore, enableUdpBroadcast: false);
  final appSession = AppSessionController(db: db, identityStore: identityStore)
    ..debugSetStateForTesting(mode: AppLoginMode.offline);

  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<LanPairingService>.value(value: lan),
          ChangeNotifierProvider<AppSessionController>.value(value: appSession),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: LanPairPromptHost(
              child: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LanDevicesScreen())),
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
  return _PromptHarness(db: db, lan: lan, appSession: appSession);
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

  testWidgets('passive discovery does not auto-prompt, and nearby device remains pairable in LanDevicesScreen', (
    tester,
  ) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await LanCrypto.generateLanIdentityKeyPair();
    final tvKp = await LanCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 0);
    final peerTv = LanDiscoveredPeer(
      deviceId: 'peer-tv',
      deviceName: '客厅电视',
      platform: 'android',
      host: '192.168.1.40',
      httpPort: 48635,
      pubKeyBase64: tvKp.publicKeyBase64,
      lastSeen: now,
    );

    harness.lan.debugSeedStateForTesting(
      deviceName: 'Phone-A',
      publicKeyBase64: myKp.publicKeyBase64,
      discovered: [peerTv],
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(LanPairPromptDialog), findsNothing);

    // Peer remains visible and manually pairable inside LanDevicesScreen.
    await tester.tap(find.text('Open LAN Devices'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(LanDevicesScreen), findsOneWidget);
    expect(find.text('客厅电视 (android)'), findsOneWidget);
    expect(find.text(t.sync.lanPairButton), findsOneWidget);
  });

  testWidgets('explicit incoming pair request pops dialog even in Self-Hosted mode and closes when trusted', (
    tester,
  ) async {
    final harness = await _pumpPromptHost(tester);
    addTearDown(() => harness.dispose(tester));

    final myKp = await LanCrypto.generateLanIdentityKeyPair();
    final peerKp = await LanCrypto.generateLanIdentityKeyPair();
    final now = DateTime(2026, 11, 16, 20, 10);
    final peer = LanDiscoveredPeer(
      deviceId: 'peer-1',
      deviceName: 'LivingRoom-TV',
      platform: 'android',
      host: '192.168.1.55',
      httpPort: 48635,
      pubKeyBase64: peerKp.publicKeyBase64,
      lastSeen: now,
    );

    harness.appSession.debugSetStateForTesting(
      mode: AppLoginMode.selfHosted,
      selfHostedSession: SelfHostedSession(
        serverUrl: 'http://127.0.0.1:8088',
        username: 'alice',
        accessToken: 'tok-1',
      ),
    );
    harness.lan.debugSeedStateForTesting(
      publicKeyBase64: myKp.publicKeyBase64,
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
    await tester.pump();

    expect(find.byType(LanPairPromptDialog), findsOneWidget);
    expect(find.text(t.sync.lanPopupRequestTitle), findsOneWidget);
    expect(find.text('Cancel (15s)'), findsOneWidget);
    expect(find.text(t.sync.lanAcceptButton), findsOneWidget);
    expect(find.textContaining('4821'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Cancel (9s)'), findsOneWidget);

    // Becoming trusted closes the dialog automatically without waiting for timeout.
    harness.lan.debugSeedStateForTesting(
      discovered: [peer],
      trusted: [
        LanTrustedPeer(
          deviceId: 'peer-1',
          deviceName: 'LivingRoom-TV',
          pubKeyBase64: peerKp.publicKeyBase64,
          sharedKeyBase64: myKp.publicKeyBase64,
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

    final myKp = await LanCrypto.generateLanIdentityKeyPair();
    final peerKp = await LanCrypto.generateLanIdentityKeyPair();
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

    harness.lan.debugSeedStateForTesting(publicKeyBase64: myKp.publicKeyBase64, incomingRequests: [req]);
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

  test(
    'simultaneous mutual click completes loopback handshake without secondary accept and never auto-prompts again',
    () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      Future<({AppDatabase db, LanIdentityStore identityStore, LanPairingService lan})> startPeer(String name) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final identityStore = LanIdentityStore(db);
        await identityStore.setDeviceName(name);
        final lan = LanPairingService(identityStore: identityStore, enableUdpBroadcast: false);
        await lan.start(bindHttpPort: 0);
        return (db: db, identityStore: identityStore, lan: lan);
      }

      final devA = await startPeer('Device-A');
      final devB = await startPeer('Device-B');
      addTearDown(() async {
        devA.lan.dispose();
        devB.lan.dispose();
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
        lastSeen: now,
      );
      final peerAOnB = LanDiscoveredPeer(
        deviceId: devA.lan.deviceId!,
        deviceName: 'Device-A',
        platform: 'windows',
        host: '127.0.0.1',
        httpPort: devA.lan.listeningPort!,
        pubKeyBase64: devA.lan.publicKeyBase64!,
        lastSeen: now,
      );

      devA.lan.registerDiscoveredPeer(peerBOnA);
      devB.lan.registerDiscoveredPeer(peerAOnB);

      expect(devA.lan.shouldAutoPromptPeer(devB.lan.deviceId!), isTrue);
      expect(devB.lan.shouldAutoPromptPeer(devA.lan.deviceId!), isTrue);

      await Future.wait([devA.lan.requestPairWithPeer(peerBOnA), devB.lan.requestPairWithPeer(peerAOnB)]);

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
    },
  );
}
