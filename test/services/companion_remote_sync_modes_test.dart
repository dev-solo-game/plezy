import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/companion_remote/remote_playback_models.dart';
import 'package:plezy/models/companion_remote/remote_session.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/companion_remote/lan_crypto.dart';
import 'package:plezy/services/companion_remote/lan_discovery_service.dart';
import 'package:plezy/services/companion_remote/lan_identity_store.dart';
import 'package:plezy/services/companion_remote/lan_pairing_service.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/widgets/companion_remote/discovery_view.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

class _SilentLanDiscoveryService extends LanDiscoveryService {
  final StreamController<List<DiscoveredHost>> _controller = StreamController<List<DiscoveredHost>>.broadcast(
    sync: true,
  );
  bool _broadcasting = false;
  bool _listening = false;

  @override
  bool get isBroadcasting => _broadcasting;

  @override
  bool get isListening => _listening;

  @override
  Future<void> startBroadcastingForContexts({
    required List<RemoteAuthContext> contexts,
    required String deviceName,
    required String platform,
    required int wsPort,
    required List<String> ips,
  }) async {
    _broadcasting = true;
  }

  @override
  Future<void> stopBroadcasting() async {
    _broadcasting = false;
  }

  @override
  Stream<List<DiscoveredHost>> startListeningForContexts(List<RemoteAuthContext> contexts) {
    _listening = true;
    return _controller.stream;
  }

  @override
  void stopListening() {
    _listening = false;
    if (!_controller.isClosed) {
      _controller.add(const []);
    }
  }

  void emitHosts(List<DiscoveredHost> hosts) {
    if (!_controller.isClosed) {
      _controller.add(hosts);
    }
  }

  @override
  void dispose() {
    _broadcasting = false;
    _listening = false;
    _controller.close();
    super.dispose();
  }
}

class _DeviceHarness {
  _DeviceHarness._({
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

  static Future<_DeviceHarness> create({
    String? customDeviceName,
    AppLoginMode mode = AppLoginMode.offline,
    SelfHostedSession? selfHostedSession,
    bool startLan = true,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final identityStore = LanIdentityStore(db);
    if (customDeviceName != null) {
      await identityStore.setDeviceName(customDeviceName);
    }
    final lan = LanPairingService(identityStore: identityStore, enableUdpBroadcast: false);
    if (startLan) {
      await lan.start(bindHttpPort: 0);
    }
    final session = AppSessionController(db: db, identityStore: identityStore)
      ..debugSetStateForTesting(
        mode: selfHostedSession != null ? AppLoginMode.selfHosted : mode,
        selfHostedSession: selfHostedSession,
      );

    final remote = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: _SilentLanDiscoveryService.new,
    );
    return _DeviceHarness._(db: db, identityStore: identityStore, lan: lan, session: session, remote: remote);
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

  test('LAN P2P host starts in standby, accepts initiated trust, and auto-connects remote', () async {
    final host = await _DeviceHarness.create(customDeviceName: 'Living Room TV');
    final phone = await _DeviceHarness.create(customDeviceName: 'Pixel Phone');
    addTearDown(() async {
      await phone.dispose();
      await host.dispose();
    });

    expect(await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore), isTrue);
    expect(await phone.remote.ensureLanCryptoReady(phone.lan, identityStore: phone.identityStore), isTrue);

    await host.remote.startHostServer();
    expect(host.remote.isHostServerRunning, isTrue);
    final remotePort = host.lan.advertisedRemotePort;
    expect(remotePort, isNotNull);
    expect(remotePort, greaterThan(0));

    // Register host as an untrusted discovered LAN peer on Phone (simulating UDP beacon receipt).
    final untrustedPeer = LanDiscoveredPeer(
      deviceId: host.lan.deviceId!,
      deviceName: 'Living Room TV',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: host.lan.listeningPort!,
      pubKeyBase64: host.lan.publicKeyBase64!,
      lastSeen: DateTime.now(),
      remotePort: remotePort,
    );
    phone.lan.registerDiscoveredPeer(untrustedPeer);

    expect(phone.remote.trustedLanRemoteHosts, isEmpty);
    expect(phone.remote.untrustedLanRemotePeers.map((p) => p.deviceId), [host.lan.deviceId]);

    final receivedCommands = <RemoteCommand>[];
    host.remote.onCommandReceived = receivedCommands.add;

    final incomingRequestArrived = Completer<LanPairRequest>();
    void onHostLanChanged() {
      final req = host.lan.incomingPairRequests.firstOrNull;
      if (req != null && !incomingRequestArrived.isCompleted) {
        incomingRequestArrived.complete(req);
      }
    }

    host.lan.addListener(onHostLanChanged);
    addTearDown(() => host.lan.removeListener(onHostLanChanged));

    // Phone initiates trust & auto-connects.
    final connectFuture = phone.remote.trustAndConnectLanPeer(untrustedPeer);

    final req = await incomingRequestArrived.future.timeout(const Duration(seconds: 5));
    expect(req.deviceId, phone.lan.deviceId);
    await host.lan.acceptPairRequest(req);

    await connectFuture.timeout(const Duration(seconds: 10));
    expect(phone.remote.isConnected, isTrue);
    expect(phone.remote.untrustedLanRemotePeers, isEmpty);
    expect(phone.remote.trustedLanRemoteHosts.map((h) => h.clientId), [host.lan.deviceId]);

    phone.remote.sendCommand(RemoteCommandType.playPause);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (receivedCommands.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(receivedCommands.map((c) => c.type), contains(RemoteCommandType.playPause));
  });

  test('LAN P2P trusted peer connects directly and revoking trust closes active session', () async {
    final host = await _DeviceHarness.create(customDeviceName: 'Office PC');
    final phone = await _DeviceHarness.create(customDeviceName: 'iPhone');
    addTearDown(() async {
      await phone.dispose();
      await host.dispose();
    });

    final sharedKey = await LanCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: (await host.identityStore.getOrCreateLanKeyPair()).privateKeyBase64,
      myPublicKeyBase64: host.lan.publicKeyBase64!,
      peerPublicKeyBase64: phone.lan.publicKeyBase64!,
    );
    await host.lan.stop();
    await phone.lan.stop();
    await host.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: phone.lan.deviceId!,
        deviceName: 'iPhone',
        pubKeyBase64: phone.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
      ),
    ]);
    await phone.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: host.lan.deviceId!,
        deviceName: 'Office PC',
        pubKeyBase64: host.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
      ),
    ]);
    await host.lan.start(bindHttpPort: 0);
    await phone.lan.start(bindHttpPort: 0);

    expect(await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore), isTrue);
    expect(await phone.remote.ensureLanCryptoReady(phone.lan, identityStore: phone.identityStore), isTrue);
    await host.remote.startHostServer();

    final remotePort = host.lan.advertisedRemotePort!;
    phone.lan.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: host.lan.deviceId!,
        deviceName: 'Office PC',
        platform: 'windows',
        host: '127.0.0.1',
        httpPort: host.lan.listeningPort!,
        pubKeyBase64: host.lan.publicKeyBase64!,
        lastSeen: DateTime.now(),
        remotePort: remotePort,
      ),
    );

    final trustedHosts = phone.remote.trustedLanRemoteHosts;
    expect(trustedHosts, hasLength(1));
    await phone.remote.connectToDiscoveredHost(trustedHosts.single);
    expect(phone.remote.isConnected, isTrue);

    final hostDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (host.remote.connectedDevice == null && DateTime.now().isBefore(hostDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(host.remote.connectedDevice, isNotNull);

    // Revoking trust on host must hot-update contexts and disconnect the remote client.
    await host.lan.removeTrustedPeer(phone.lan.deviceId!);
    final revokeDeadline = DateTime.now().add(const Duration(seconds: 5));
    while ((host.remote.connectedDevice != null || phone.remote.status == RemoteSessionStatus.connected) &&
        DateTime.now().isBefore(revokeDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(host.remote.connectedDevice, isNull);
    expect(phone.remote.status, isNot(RemoteSessionStatus.connected));
  });

  testWidgets('DiscoveryView shows untrusted LAN host in Offline mode without Plex login', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final identityStore = LanIdentityStore(db);
    final lan = LanPairingService(identityStore: identityStore, enableUdpBroadcast: false);
    final provider = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: _SilentLanDiscoveryService.new,
    );

    await tester.runAsync(() async {
      final kp = await LanCrypto.generateLanIdentityKeyPair();
      lan.debugSeedStateForTesting(
        deviceId: 'phone-self',
        deviceName: 'Phone',
        publicKeyBase64: kp.publicKeyBase64,
        discovered: [
          LanDiscoveredPeer(
            deviceId: 'tv-living-room',
            deviceName: 'Living Room TV',
            platform: 'android',
            host: '192.168.1.55',
            httpPort: 48635,
            pubKeyBase64: kp.publicKeyBase64,
            lastSeen: DateTime.now(),
            remotePort: 48632,
          ),
        ],
      );
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LanPairingService>.value(value: lan),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: provider),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: const InputModeTracker(child: Scaffold(body: DiscoveryView())),
        ),
      ),
    );

    for (var i = 0; i < 30 && !provider.isCryptoReady; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump();

    expect(find.text(t.companionRemote.pairing.cryptoInitFailed), findsNothing);
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(find.text('android · ${t.companionRemote.pairing.tapToTrustAndConnect}'), findsOneWidget);

    // Unmount and tear down in-body inside runAsync before testWidgets pending-timer check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() async {
      provider.dispose();
      await lan.stop();
      lan.dispose();
      await db.close();
    });
  });

  testWidgets('DiscoveryView tap on untrusted peer initiates trust and cancels cleanly', (tester) async {
    late _DeviceHarness host;
    late _DeviceHarness phone;
    await tester.runAsync(() async {
      host = await _DeviceHarness.create(customDeviceName: 'Bedroom TV');
      phone = await _DeviceHarness.create(customDeviceName: 'Handset');
      await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore);
      await host.remote.startHostServer();
      phone.lan.registerDiscoveredPeer(
        LanDiscoveredPeer(
          deviceId: host.lan.deviceId!,
          deviceName: 'Bedroom TV',
          platform: 'android',
          host: '127.0.0.1',
          httpPort: host.lan.listeningPort!,
          pubKeyBase64: host.lan.publicKeyBase64!,
          lastSeen: DateTime.now(),
          remotePort: host.lan.advertisedRemotePort,
        ),
      );
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LanPairingService>.value(value: phone.lan),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: phone.remote),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: const InputModeTracker(child: Scaffold(body: DiscoveryView())),
        ),
      ),
    );

    for (var i = 0; i < 40 && !phone.remote.isCryptoReady; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump();

    expect(find.text('Bedroom TV'), findsOneWidget);
    await tester.tap(find.text('Bedroom TV'));
    await tester.pump();

    for (var i = 0; i < 80 && host.lan.incomingPairRequests.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }

    expect(host.lan.incomingPairRequests, hasLength(1));
    expect(find.text(t.common.cancel), findsOneWidget);

    await tester.tap(find.text(t.common.cancel));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }

    // Cancelled wait must not show a failure banner and must re-list the device.
    expect(find.text('Bedroom TV'), findsOneWidget);
    expect(find.textContaining(t.companionRemote.pairing.trustTimedOut), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() async {
      await phone.dispose();
      await host.dispose();
    });
  });

  Future<void> pairLanDevices(_DeviceHarness a, _DeviceHarness b) async {
    final sharedKey = await LanCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: (await a.identityStore.getOrCreateLanKeyPair()).privateKeyBase64,
      myPublicKeyBase64: a.lan.publicKeyBase64!,
      peerPublicKeyBase64: b.lan.publicKeyBase64!,
    );
    final portA = a.lan.listeningPort!;
    final portB = b.lan.listeningPort!;
    final nameA = await a.identityStore.getDeviceName();
    final nameB = await b.identityStore.getDeviceName();
    await a.lan.stop();
    await b.lan.stop();
    await a.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: b.lan.deviceId!,
        deviceName: nameB,
        pubKeyBase64: b.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: portB,
      ),
    ]);
    await b.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: a.lan.deviceId!,
        deviceName: nameA,
        pubKeyBase64: a.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: portA,
      ),
    ]);
    await a.lan.start(bindHttpPort: 0);
    await b.lan.start(bindHttpPort: 0);
    final livePortA = a.lan.listeningPort!;
    final livePortB = b.lan.listeningPort!;
    await a.lan.stop();
    await b.lan.stop();
    await a.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: b.lan.deviceId!,
        deviceName: nameB,
        pubKeyBase64: b.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: livePortB,
      ),
    ]);
    await b.identityStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: a.lan.deviceId!,
        deviceName: nameA,
        pubKeyBase64: a.lan.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: livePortA,
      ),
    ]);
    await a.lan.start(bindHttpPort: livePortA);
    await b.lan.start(bindHttpPort: livePortB);
  }

  test('default device name ignores localhost and preserves DeviceIdentityService name', () async {
    expect(isMeaningfulDeviceName('localhost'), isFalse);
    expect(isMeaningfulDeviceName('LOCALHOST.localdomain'), isFalse);
    expect(isMeaningfulDeviceName('   '), isFalse);
    expect(isMeaningfulDeviceName('Xiaomi 23127PN0CC'), isTrue);

    DeviceIdentityService.debugOverride(
      const DeviceIdentity(platform: 'Android', deviceModel: '23127PN0CC', deviceName: 'Xiaomi 23127PN0CC'),
    );
    addTearDown(() => DeviceIdentityService.debugOverride(null));

    final androidHost = await _DeviceHarness.create();
    final viewer = await _DeviceHarness.create(customDeviceName: 'Viewer PC');
    addTearDown(() async {
      await viewer.dispose();
      await androidHost.dispose();
    });

    expect(await androidHost.identityStore.getCustomDeviceName(), isNull);
    expect(await androidHost.identityStore.getDeviceName(), 'Xiaomi 23127PN0CC');

    await pairLanDevices(androidHost, viewer);
    expect(await androidHost.remote.ensureLanCryptoReady(androidHost.lan, identityStore: androidHost.identityStore), isTrue);
    expect(await viewer.remote.ensureLanCryptoReady(viewer.lan, identityStore: viewer.identityStore), isTrue);
    await androidHost.remote.startHostServer();

    await viewer.remote.refreshOnlineDeviceStatuses();
    final discovered = viewer.remote.onlineTrustedHosts;
    expect(discovered, hasLength(1));
    expect(discovered.single.name, 'Xiaomi 23127PN0CC');

    await viewer.remote.connectToDiscoveredHost(discovered.single);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (viewer.remote.connectedDevice == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(viewer.remote.connectedDevice?.name, 'Xiaomi 23127PN0CC');
  });

  test(
    'overlapping connectAndPlayMedia and connectToDiscoveredHost deduplicates connect and delivers playMedia',
    () async {
      final host = await _DeviceHarness.create(customDeviceName: 'Office PC');
      final phone = await _DeviceHarness.create(customDeviceName: 'Emulator A');
      addTearDown(() async {
        await phone.dispose();
        await host.dispose();
      });

      await pairLanDevices(host, phone);
      expect(await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore), isTrue);
      expect(await phone.remote.ensureLanCryptoReady(phone.lan, identityStore: phone.identityStore), isTrue);

      final receivedTargets = <RemoteMediaTarget>[];
      host.remote.onPlayMediaRequested = (target) async {
        receivedTargets.add(target);
        return true;
      };
      await host.remote.startHostServer();

      await phone.remote.refreshOnlineDeviceStatuses();
      final hostTarget = phone.remote.onlineTrustedHosts.single;

      const mediaTarget = RemoteMediaTarget(kind: 'movie', title: 'Spirited Away', workKey: 'tmdb:movie:129');
      final f1 = phone.remote.connectAndPlayMedia(hostTarget, mediaTarget);
      final f2 = phone.remote.connectToDiscoveredHost(hostTarget);
      await Future.wait([f1, f2]);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (receivedTargets.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(phone.remote.isConnectedToHost(hostTarget), isTrue);
      expect(receivedTargets, hasLength(1));
      expect(receivedTargets.single.title, 'Spirited Away');
    },
  );

  test('bidirectional handoff keeps host server running, streams progress/commands, and hands back', () async {
    final deviceA = await _DeviceHarness.create(customDeviceName: 'Emulator A');
    final deviceB = await _DeviceHarness.create(customDeviceName: 'Desktop B');
    addTearDown(() async {
      await deviceB.dispose();
      await deviceA.dispose();
    });

    await pairLanDevices(deviceA, deviceB);
    expect(await deviceA.remote.ensureLanCryptoReady(deviceA.lan, identityStore: deviceA.identityStore), isTrue);
    expect(await deviceB.remote.ensureLanCryptoReady(deviceB.lan, identityStore: deviceB.identityStore), isTrue);

    final targetsA = <RemoteMediaTarget>[];
    final targetsB = <RemoteMediaTarget>[];
    final commandsOnA = <RemoteCommand>[];
    deviceA.remote.onPlayMediaRequested = (target) async {
      targetsA.add(target);
      return true;
    };
    deviceA.remote.onCommandReceived = commandsOnA.add;
    deviceB.remote.onPlayMediaRequested = (target) async {
      targetsB.add(target);
      return true;
    };

    await deviceA.remote.startHostServer();
    await deviceB.remote.startHostServer();
    expect(deviceA.remote.isHostServerRunning, isTrue);
    expect(deviceB.remote.isHostServerRunning, isTrue);
    final initialPortB = deviceB.lan.advertisedRemotePort;

    // Step 1: B pushes playback to A without stopping B's own host server.
    await deviceB.remote.refreshOnlineDeviceStatuses();
    final hostA = deviceB.remote.onlineTrustedHosts.single;
    await deviceB.remote.connectAndPlayMedia(
      hostA,
      const RemoteMediaTarget(kind: 'movie', title: 'Movie One', workKey: 'tmdb:movie:1001'),
    );

    final deadlineA = DateTime.now().add(const Duration(seconds: 5));
    while (targetsA.isEmpty && DateTime.now().isBefore(deadlineA)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(targetsA.map((t) => t.title), ['Movie One']);
    expect(deviceB.remote.isHostServerRunning, isTrue);
    expect(deviceB.remote.isConnected, isTrue);

    // Simulating a mid-session sync/host auto-start call on B must not corrupt B's remote link.
    await deviceB.remote.ensureLanCryptoReady(deviceB.lan, identityStore: deviceB.identityStore);
    await deviceB.remote.startHostServer();
    expect(deviceB.remote.isConnected, isTrue);

    // Step 2: A pushes live progress snapshots to B and receives transport commands from B.
    deviceA.remote.updateHostPlayerSnapshot(
      const RemotePlayerSnapshot(
        active: true,
        stage: 'playing',
        title: 'Movie One',
        playing: true,
        positionMs: 5000,
        durationMs: 1200000,
      ),
    );
    final progressDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (deviceB.remote.remotePlayerSnapshot.durationMs != 1200000 && DateTime.now().isBefore(progressDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(deviceB.remote.remotePlayerSnapshot.playing, isTrue);
    expect(deviceB.remote.remotePlayerSnapshot.positionMs, 5000);
    expect(deviceB.remote.remotePlayerSnapshot.durationMs, 1200000);

    deviceB.remote.sendCommand(RemoteCommandType.playPause);
    deviceB.remote.sendCommand(RemoteCommandType.seekTo, data: {'positionMs': 45000});
    deviceB.remote.sendCommand(RemoteCommandType.stop);
    final cmdDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (commandsOnA.length < 3 && DateTime.now().isBefore(cmdDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(commandsOnA.map((c) => c.type), [
      RemoteCommandType.playPause,
      RemoteCommandType.seekTo,
      RemoteCommandType.stop,
    ]);

    deviceA.remote.updateHostPlayerSnapshot(
      const RemotePlayerSnapshot(
        active: true,
        stage: 'paused',
        title: 'Movie One',
        playing: false,
        positionMs: 45000,
        durationMs: 1200000,
      ),
    );
    final updateDeadline = DateTime.now().add(const Duration(seconds: 5));
    while ((deviceB.remote.remotePlayerSnapshot.playing || deviceB.remote.remotePlayerSnapshot.positionMs != 45000) &&
        DateTime.now().isBefore(updateDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(deviceB.remote.remotePlayerSnapshot.playing, isFalse);
    expect(deviceB.remote.remotePlayerSnapshot.positionMs, 45000);

    // Step 3: B leaves the control session -> B's host server remained running on the same port.
    await deviceB.remote.leaveSession();
    expect(deviceB.remote.isHostServerRunning, isTrue);
    expect(deviceB.lan.advertisedRemotePort, initialPortB);

    // Step 4: A refreshes status and pushes playback back to B.
    await deviceA.remote.refreshOnlineDeviceStatuses();
    final discoveredOnA = deviceA.remote.onlineTrustedHosts;
    expect(discoveredOnA, hasLength(1));
    expect(discoveredOnA.single.port, initialPortB);

    await deviceA.remote.connectAndPlayMedia(
      discoveredOnA.single,
      const RemoteMediaTarget(kind: 'movie', title: 'Movie Two', workKey: 'tmdb:movie:1002'),
    );

    final deadlineB = DateTime.now().add(const Duration(seconds: 5));
    while (targetsB.isEmpty && DateTime.now().isBefore(deadlineB)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(targetsB.map((t) => t.title), ['Movie Two']);
  });

  test('Offline and Self-Hosted devices pair over LAN and control each other across modes', () async {
    final host = await _DeviceHarness.create(
      customDeviceName: 'SignedIn TV',
      selfHostedSession: SelfHostedSession(
        serverUrl: 'http://127.0.0.1:8088',
        username: 'alice',
        accessToken: 'tok-tv',
        serverName: 'Home NAS',
      ),
      startLan: false,
    );
    final phone = await _DeviceHarness.create(
      customDeviceName: 'Guest Phone',
      mode: AppLoginMode.offline,
      startLan: false,
    );
    addTearDown(host.dispose);
    addTearDown(phone.dispose);

    await host.lan.start(bindHttpPort: 0);
    await phone.lan.start(bindHttpPort: 0);

    await host.remote.ensureLanCryptoReady(host.lan, identityStore: host.identityStore);
    await host.remote.startHostServer();
    await phone.remote.ensureLanCryptoReady(phone.lan, identityStore: phone.identityStore);

    expect(host.session.isSelfHosted, isTrue);
    expect(host.lan.isRunning, isTrue);
    expect(phone.session.isOffline, isTrue);
    expect(phone.lan.isRunning, isTrue);

    phone.lan.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: host.lan.deviceId!,
        deviceName: 'SignedIn TV',
        platform: 'android',
        host: '127.0.0.1',
        httpPort: host.lan.listeningPort!,
        pubKeyBase64: host.lan.publicKeyBase64!,
        lastSeen: DateTime.now(),
        remotePort: host.lan.advertisedRemotePort,
      ),
    );

    expect(phone.remote.untrustedLanRemotePeers.map((p) => p.deviceId), [host.lan.deviceId]);

    final connectFuture = phone.remote.trustAndConnectLanPeer(phone.remote.untrustedLanRemotePeers.single);
    for (var i = 0; i < 60 && host.lan.incomingPairRequests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final pairReq = host.lan.incomingPairRequests.single;
    await host.lan.acceptPairRequest(pairReq);
    await connectFuture;

    expect(phone.remote.isConnected, isTrue);
    final received = <RemoteCommand>[];
    host.remote.onCommandReceived = received.add;
    phone.remote.sendCommand(RemoteCommandType.playPause);
    final cmdDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (received.isEmpty && DateTime.now().isBefore(cmdDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(received.map((c) => c.type), contains(RemoteCommandType.playPause));
  });
}
