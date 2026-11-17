import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/companion_remote/remote_playback_models.dart';
import 'package:plezy/models/companion_remote/remote_session.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/companion_remote/lan_discovery_service.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/widgets/companion_remote/discovery_view.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

class _SilentLanDiscoveryService extends LanDiscoveryService {
  final StreamController<List<DiscoveredHost>> _controller = StreamController<List<DiscoveredHost>>.broadcast(sync: true);
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
  _DeviceHarness._({required this.db, required this.sync, required this.remote});

  final AppDatabase db;
  final SyncAndScanCoordinator sync;
  final CompanionRemoteProvider remote;
  bool _disposed = false;

  static Future<_DeviceHarness> create({
    String? customDeviceName,
    SyncSessionCredentials? cloudSession,
    bool selectLanMode = false,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final mountManager = MountManager(MountRegistry(db));
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      enableLanUdp: false,
      autoStartLanService: true,
    );
    await sync.initialize();
    if (customDeviceName != null) {
      await sync.syncStore.setDeviceName(customDeviceName);
    }
    if (cloudSession != null) {
      await sync.syncStore.saveSession(cloudSession);
      await sync.syncStore.setOnboardingCompleted(true);
    } else if (selectLanMode) {
      await sync.selectLanMode(startService: true);
    }

    // Re-create coordinator after persisting session/onboarding when cloudSession was seeded.
    late SyncAndScanCoordinator effectiveSync;
    if (cloudSession != null) {
      await sync.lanService.stop();
      sync.dispose();
      effectiveSync = SyncAndScanCoordinator(
        db: db,
        repo: repo,
        mountManager: mountManager,
        enableLanUdp: false,
        autoStartLanService: false,
      );
      await effectiveSync.initialize();
    } else {
      effectiveSync = sync;
    }

    final remote = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: _SilentLanDiscoveryService.new,
    );
    return _DeviceHarness._(db: db, sync: effectiveSync, remote: remote);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await remote.leaveSession();
    remote.dispose();
    await sync.lanService.stop();
    sync.dispose();
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
    final host = await _DeviceHarness.create(customDeviceName: 'Living Room TV', selectLanMode: true);
    final phone = await _DeviceHarness.create(customDeviceName: 'Pixel Phone', selectLanMode: true);
    addTearDown(() async {
      await phone.dispose();
      await host.dispose();
    });

    expect(await host.remote.ensureSyncCryptoReady(host.sync), isTrue);
    expect(await phone.remote.ensureSyncCryptoReady(phone.sync), isTrue);

    await host.remote.startHostServer();
    expect(host.remote.isHostServerRunning, isTrue);
    final remotePort = host.sync.lanService.advertisedRemotePort;
    expect(remotePort, isNotNull);
    expect(remotePort, greaterThan(0));

    // Register host as an untrusted discovered LAN peer on Phone (simulating UDP beacon receipt).
    final untrustedPeer = LanDiscoveredPeer(
      deviceId: host.sync.lanService.deviceId!,
      deviceName: 'Living Room TV',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: host.sync.lanService.listeningPort!,
      pubKeyBase64: host.sync.lanService.publicKeyBase64!,
      revision: 0,
      lastSeen: DateTime.now(),
      remotePort: remotePort,
    );
    phone.sync.lanService.registerDiscoveredPeer(untrustedPeer);

    expect(phone.remote.trustedLanRemoteHosts, isEmpty);
    expect(phone.remote.untrustedLanRemotePeers.map((p) => p.deviceId), [host.sync.lanService.deviceId]);

    final receivedCommands = <RemoteCommand>[];
    host.remote.onCommandReceived = receivedCommands.add;

    final incomingRequestArrived = Completer<LanPairRequest>();
    void onHostLanChanged() {
      final req = host.sync.lanService.incomingPairRequests.firstOrNull;
      if (req != null && !incomingRequestArrived.isCompleted) {
        incomingRequestArrived.complete(req);
      }
    }

    host.sync.lanService.addListener(onHostLanChanged);
    addTearDown(() => host.sync.lanService.removeListener(onHostLanChanged));

    // Phone initiates trust & auto-connects.
    final connectFuture = phone.remote.trustAndConnectLanPeer(untrustedPeer);

    final req = await incomingRequestArrived.future.timeout(const Duration(seconds: 5));
    expect(req.deviceId, phone.sync.lanService.deviceId);
    await host.sync.lanService.acceptPairRequest(req);

    await connectFuture.timeout(const Duration(seconds: 10));
    expect(phone.remote.isConnected, isTrue);
    expect(phone.remote.untrustedLanRemotePeers, isEmpty);
    expect(phone.remote.trustedLanRemoteHosts.map((h) => h.clientId), [host.sync.lanService.deviceId]);

    phone.remote.sendCommand(RemoteCommandType.playPause);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (receivedCommands.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(receivedCommands.map((c) => c.type), contains(RemoteCommandType.playPause));
  });

  test('LAN P2P trusted peer connects directly and revoking trust closes active session', () async {
    final host = await _DeviceHarness.create(customDeviceName: 'Office PC', selectLanMode: true);
    final phone = await _DeviceHarness.create(customDeviceName: 'iPhone', selectLanMode: true);
    addTearDown(() async {
      await phone.dispose();
      await host.dispose();
    });

    final sharedKey = await SyncCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: (await host.sync.syncStore.getOrCreateLanKeyPair()).privateKeyBase64,
      myPublicKeyBase64: host.sync.lanService.publicKeyBase64!,
      peerPublicKeyBase64: phone.sync.lanService.publicKeyBase64!,
    );
    await host.sync.lanService.stop();
    await phone.sync.lanService.stop();
    await host.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: phone.sync.deviceId,
        deviceName: 'iPhone',
        pubKeyBase64: phone.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
      ),
    ]);
    await phone.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: host.sync.deviceId,
        deviceName: 'Office PC',
        pubKeyBase64: host.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
      ),
    ]);
    await host.sync.lanService.start(bindHttpPort: 0);
    await phone.sync.lanService.start(bindHttpPort: 0);

    expect(await host.remote.ensureSyncCryptoReady(host.sync), isTrue);
    expect(await phone.remote.ensureSyncCryptoReady(phone.sync), isTrue);
    await host.remote.startHostServer();

    final remotePort = host.sync.lanService.advertisedRemotePort!;
    phone.sync.lanService.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: host.sync.lanService.deviceId!,
        deviceName: 'Office PC',
        platform: 'windows',
        host: '127.0.0.1',
        httpPort: host.sync.lanService.listeningPort!,
        pubKeyBase64: host.sync.lanService.publicKeyBase64!,
        revision: 0,
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
    await host.sync.lanService.removeTrustedPeer(phone.sync.lanService.deviceId!);
    final revokeDeadline = DateTime.now().add(const Duration(seconds: 5));
    while ((host.remote.connectedDevice != null || phone.remote.status == RemoteSessionStatus.connected) &&
        DateTime.now().isBefore(revokeDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(host.remote.connectedDevice, isNull);
    expect(phone.remote.status, isNot(RemoteSessionStatus.connected));
  });

  test('Cloud Sync account devices connect over LAN with zero pairing and reject different keys', () async {
    final sharedMasterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 10));
    final otherMasterKey = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

    final host = await _DeviceHarness.create(
      customDeviceName: 'Study Desktop',
      cloudSession: SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'user-alpha',
        username: 'alpha',
        accessToken: 'tok-host',
        masterKey: sharedMasterKey,
      ),
    );
    final phone = await _DeviceHarness.create(
      customDeviceName: 'Pocket Phone',
      cloudSession: SyncSessionCredentials(
        serverUrl: 'https://sync.example.com/',
        userId: 'USER-ALPHA',
        username: 'alpha',
        accessToken: 'tok-phone',
        masterKey: sharedMasterKey,
      ),
    );
    final intruder = await _DeviceHarness.create(
      customDeviceName: 'Other User',
      cloudSession: SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'user-alpha',
        username: 'alpha',
        accessToken: 'tok-intruder',
        masterKey: otherMasterKey,
      ),
    );
    addTearDown(() async {
      await intruder.dispose();
      await phone.dispose();
      await host.dispose();
    });

    expect(await host.remote.ensureSyncCryptoReady(host.sync), isTrue);
    expect(await phone.remote.ensureSyncCryptoReady(phone.sync), isTrue);
    expect(await intruder.remote.ensureSyncCryptoReady(intruder.sync), isTrue);

    await host.remote.startHostServer();
    expect(host.remote.isHostServerRunning, isTrue);
    expect(host.sync.lanService.advertisedRemotePort, isNull);

    final hostPort = host.remote.hostServerAddresses.first.split(':').last;
    final commands = <RemoteCommand>[];
    host.remote.onCommandReceived = commands.add;

    await phone.remote.connectToManualHost('127.0.0.1:$hostPort');
    expect(phone.remote.isConnected, isTrue);

    phone.remote.sendCommand(RemoteCommandType.home);
    final cmdDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (commands.isEmpty && DateTime.now().isBefore(cmdDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(commands.map((c) => c.type), contains(RemoteCommandType.home));

    await expectLater(
      intruder.remote.connectToManualHost('127.0.0.1:$hostPort'),
      throwsA(isA<PeerError>().having((e) => e.type, 'type', PeerErrorType.authFailed)),
    );
  });

  testWidgets('DiscoveryView shows untrusted LAN host in LAN P2P mode without Plex login', (tester) async {
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
    final provider = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: _SilentLanDiscoveryService.new,
    );

    await tester.runAsync(() async {
      await sync.initialize();
      await sync.selectLanMode(startService: false);
      final kp = await SyncCrypto.generateLanIdentityKeyPair();
      sync.lanService.debugSeedStateForTesting(
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
            revision: 1,
            lastSeen: DateTime.now(),
            remotePort: 48632,
          ),
        ],
      );
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SyncAndScanCoordinator>.value(value: sync),
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
      await sync.lanService.stop();
      sync.dispose();
      await db.close();
    });
  });

  test('Cloud Sync discoverHosts filters out local deviceId and exposes same-account peers', () async {
    final sharedMasterKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: LibraryRepository(db),
      mountManager: MountManager(MountRegistry(db)),
      enableLanUdp: false,
      autoStartLanService: false,
    );
    await sync.initialize();
    await sync.syncStore.saveSession(
      SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'user-self-filter',
        username: 'tester',
        accessToken: 'tok',
        masterKey: sharedMasterKey,
      ),
    );
    await sync.lanService.stop();
    sync.dispose();

    final effectiveSync = SyncAndScanCoordinator(
      db: db,
      repo: LibraryRepository(db),
      mountManager: MountManager(MountRegistry(db)),
      enableLanUdp: false,
      autoStartLanService: false,
    );
    await effectiveSync.initialize();

    final discovery = _SilentLanDiscoveryService();
    final provider = CompanionRemoteProvider.forTesting(
      peerServiceFactory: CompanionRemotePeerService.new,
      discoveryServiceFactory: () => discovery,
    );
    addTearDown(() async {
      provider.dispose();
      await effectiveSync.lanService.stop();
      effectiveSync.dispose();
      await db.close();
    });

    expect(await provider.ensureSyncCryptoReady(effectiveSync), isTrue);
    final emissions = <List<DiscoveredHost>>[];
    final sub = provider.discoverHosts()!.listen(emissions.add);
    addTearDown(sub.cancel);

    discovery.emitHosts([
      DiscoveredHost(
        authContextId: 'ctx',
        clientId: effectiveSync.deviceId,
        name: 'My Own Phone',
        platform: 'android',
        port: 48632,
        ips: const ['192.168.1.10'],
      ),
      DiscoveredHost(
        authContextId: 'ctx',
        clientId: 'desktop-host-id',
        name: 'Living Room PC',
        platform: 'windows',
        port: 48632,
        ips: const ['192.168.1.20'],
      ),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(emissions.last.map((h) => h.clientId), ['desktop-host-id']);
  });

  testWidgets('DiscoveryView tap on untrusted peer initiates trust and cancels cleanly', (tester) async {
    late _DeviceHarness host;
    late _DeviceHarness phone;
    await tester.runAsync(() async {
      host = await _DeviceHarness.create(customDeviceName: 'Bedroom TV', selectLanMode: true);
      phone = await _DeviceHarness.create(customDeviceName: 'Handset', selectLanMode: true);
      await host.remote.ensureSyncCryptoReady(host.sync);
      await host.remote.startHostServer();
      phone.sync.lanService.registerDiscoveredPeer(
        LanDiscoveredPeer(
          deviceId: host.sync.lanService.deviceId!,
          deviceName: 'Bedroom TV',
          platform: 'android',
          host: '127.0.0.1',
          httpPort: host.sync.lanService.listeningPort!,
          pubKeyBase64: host.sync.lanService.publicKeyBase64!,
          revision: 0,
          lastSeen: DateTime.now(),
          remotePort: host.sync.lanService.advertisedRemotePort,
        ),
      );
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SyncAndScanCoordinator>.value(value: phone.sync),
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

    for (var i = 0; i < 80 && host.sync.lanService.incomingPairRequests.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }

    expect(host.sync.lanService.incomingPairRequests, hasLength(1));
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
    final sharedKey = await SyncCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: (await a.sync.syncStore.getOrCreateLanKeyPair()).privateKeyBase64,
      myPublicKeyBase64: a.sync.lanService.publicKeyBase64!,
      peerPublicKeyBase64: b.sync.lanService.publicKeyBase64!,
    );
    final portA = a.sync.lanService.listeningPort!;
    final portB = b.sync.lanService.listeningPort!;
    final nameA = await a.sync.syncStore.getDeviceName();
    final nameB = await b.sync.syncStore.getDeviceName();
    await a.sync.lanService.stop();
    await b.sync.lanService.stop();
    await a.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: b.sync.deviceId,
        deviceName: nameB,
        pubKeyBase64: b.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: portB,
      ),
    ]);
    await b.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: a.sync.deviceId,
        deviceName: nameA,
        pubKeyBase64: a.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: portA,
      ),
    ]);
    await a.sync.lanService.start(bindHttpPort: 0);
    await b.sync.lanService.start(bindHttpPort: 0);
    final livePortA = a.sync.lanService.listeningPort!;
    final livePortB = b.sync.lanService.listeningPort!;
    await a.sync.lanService.stop();
    await b.sync.lanService.stop();
    await a.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: b.sync.deviceId,
        deviceName: nameB,
        pubKeyBase64: b.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: livePortB,
      ),
    ]);
    await b.sync.syncStore.saveTrustedLanPeers([
      LanTrustedPeer(
        deviceId: a.sync.deviceId,
        deviceName: nameA,
        pubKeyBase64: a.sync.lanService.publicKeyBase64!,
        sharedKeyBase64: base64Encode(sharedKey),
        lastSyncedRevision: 0,
        pairedAtMs: 1,
        lastHost: '127.0.0.1',
        lastPort: livePortA,
      ),
    ]);
    await a.sync.lanService.start(bindHttpPort: livePortA);
    await b.sync.lanService.start(bindHttpPort: livePortB);
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

    final androidHost = await _DeviceHarness.create(selectLanMode: true);
    final viewer = await _DeviceHarness.create(customDeviceName: 'Viewer PC', selectLanMode: true);
    addTearDown(() async {
      await viewer.dispose();
      await androidHost.dispose();
    });

    expect(await androidHost.sync.syncStore.getCustomDeviceName(), isNull);
    expect(await androidHost.sync.syncStore.getDeviceName(), 'Xiaomi 23127PN0CC');

    await pairLanDevices(androidHost, viewer);
    expect(await androidHost.remote.ensureSyncCryptoReady(androidHost.sync), isTrue);
    expect(await viewer.remote.ensureSyncCryptoReady(viewer.sync), isTrue);
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

  test('overlapping connectAndPlayMedia and connectToDiscoveredHost deduplicates connect and delivers playMedia', () async {
    final host = await _DeviceHarness.create(customDeviceName: 'Office PC', selectLanMode: true);
    final phone = await _DeviceHarness.create(customDeviceName: 'Emulator A', selectLanMode: true);
    addTearDown(() async {
      await phone.dispose();
      await host.dispose();
    });

    await pairLanDevices(host, phone);
    expect(await host.remote.ensureSyncCryptoReady(host.sync), isTrue);
    expect(await phone.remote.ensureSyncCryptoReady(phone.sync), isTrue);

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
  });

  test('bidirectional handoff restores suspended host server on leaveSession and probes updated remotePort', () async {
    final deviceA = await _DeviceHarness.create(customDeviceName: 'Emulator A', selectLanMode: true);
    final deviceB = await _DeviceHarness.create(customDeviceName: 'Desktop B', selectLanMode: true);
    addTearDown(() async {
      await deviceB.dispose();
      await deviceA.dispose();
    });

    await pairLanDevices(deviceA, deviceB);
    expect(await deviceA.remote.ensureSyncCryptoReady(deviceA.sync), isTrue);
    expect(await deviceB.remote.ensureSyncCryptoReady(deviceB.sync), isTrue);

    final targetsA = <RemoteMediaTarget>[];
    final targetsB = <RemoteMediaTarget>[];
    deviceA.remote.onPlayMediaRequested = (target) async {
      targetsA.add(target);
      return true;
    };
    deviceB.remote.onPlayMediaRequested = (target) async {
      targetsB.add(target);
      return true;
    };

    await deviceA.remote.startHostServer();
    await deviceB.remote.startHostServer();
    expect(deviceA.remote.isHostServerRunning, isTrue);
    expect(deviceB.remote.isHostServerRunning, isTrue);

    // Step 1: B pushes playback to A, suspending B's own host server.
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
    expect(deviceB.remote.isHostServerRunning, isFalse);

    // Step 2: B leaves RemoteControlScreen / session -> B's host server automatically restarts.
    await deviceB.remote.leaveSession();
    expect(deviceB.remote.isHostServerRunning, isTrue);
    final restartedPortB = deviceB.sync.lanService.advertisedRemotePort;
    expect(restartedPortB, isNotNull);
    expect(restartedPortB, greaterThan(0));

    // Step 3: A refreshes status (unicast probe discovers B's new port) and pushes back to B.
    await deviceA.remote.refreshOnlineDeviceStatuses();
    final discoveredOnA = deviceA.remote.onlineTrustedHosts;
    expect(discoveredOnA, hasLength(1));
    expect(discoveredOnA.single.port, restartedPortB);

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
}
