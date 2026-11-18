import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/library_workspace_store.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _NoScanDriver implements StorageDriver {
  _NoScanDriver(this.kind);

  @override
  final StorageKind kind;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: false, size: 0);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _ModeNode {
  _ModeNode(this.name, {bool autoStartLan = false}) : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) => _NoScanDriver(mount.kind),
    );
    client = LocalLibraryClient(repository: repo, mounts: mountManager);
    scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mountManager);
    sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      enableLanUdp: false,
      autoStartLanService: autoStartLan,
    );
  }

  final String name;
  final AppDatabase db;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;

  Future<void> dispose() async {
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    client.close();
    scans.dispose();
    sync.dispose();
    await mountManager.dispose();
    await db.close();
  }
}

Future<void> _seedMovie(
  _ModeNode node, {
  required String mountId,
  required String tmdbId,
  required String title,
  required String filePath,
  required int updatedAt,
}) async {
  await node.registry.upsert(
    StorageMount(
      id: mountId,
      kind: StorageKind.webdav,
      displayName: 'Test DAV',
      config: {MountKeys.baseUrl: 'http://192.168.1.50/$mountId'},
    ),
  );
  final itemId = await node.repo.insertItem(
    LibraryItemsCompanion.insert(
      workKey: Value('tmdb:movie:$tmdbId'),
      kind: LibraryKinds.movie,
      libraryType: LibraryTypes.movie,
      title: title,
      sortTitle: title.toLowerCase(),
      tmdbId: Value(tmdbId),
      metadataSource: const Value('tmdb'),
      scrapedAt: Value(updatedAt),
      addedAt: updatedAt,
      updatedAt: updatedAt,
    ),
  );
  final fileId = await node.repo.upsertFile(
    mountId: mountId,
    path: filePath,
    role: LibraryFileRoles.video,
    scanId: 1,
    size: 50000,
    modifiedAt: updatedAt,
  );
  await node.repo.linkFile(fileId, itemId);
  await node.repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fastKdf = SyncKdfParams(memoryKiB: 1024, iterations: 1, parallelism: 1);

  late Directory binTempDir;
  late String serverExePath;
  HttpOverrides? previousHttpOverrides;

  setUpAll(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    binTempDir = await Directory.systemTemp.createTemp('plezy_three_modes_bin_');
    final exeName = Platform.isWindows ? 'plezy_sync_server.exe' : 'plezy_sync_server';
    serverExePath = p.join(binTempDir.path, exeName);
    final buildResult = await Process.run(
      'go',
      ['build', '-o', serverExePath, '.'],
      workingDirectory: p.join(Directory.current.path, 'sync_server'),
      environment: {'GOTOOLCHAIN': 'auto'},
    );
    if (buildResult.exitCode != 0) {
      fail('Failed to build sync_server:\n${buildResult.stdout}\n${buildResult.stderr}');
    }
  });

  tearDownAll(() async {
    HttpOverrides.global = previousHttpOverrides;
    if (await binTempDir.exists()) {
      await binTempDir.delete(recursive: true);
    }
  });

  Future<String> startSyncServer({List<String> extraArgs = const []}) async {
    final dataDir = await Directory.systemTemp.createTemp('plezy_three_modes_data_');
    final proc = await Process.start(serverExePath, ['-addr', '127.0.0.1:0', '-data-dir', dataDir.path, ...extraArgs]);
    final urlCompleter = Completer<String>();
    final stdoutSub = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('LISTENING ') && !urlCompleter.isCompleted) {
        urlCompleter.complete(line.substring('LISTENING '.length).trim());
      }
    });
    final stderrSub = proc.stderr.transform(utf8.decoder).listen((_) {});
    addTearDown(() async {
      proc.kill();
      await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (await dataDir.exists()) {
        try {
          await dataDir.delete(recursive: true);
        } catch (_) {}
      }
    });
    return urlCompleter.future.timeout(const Duration(seconds: 10));
  }

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('1. probeServer, Official vs Self-Hosted kind persistence, lastSelfHostedUrl & isolated workspaces', () async {
    final officialUrl = await startSyncServer();
    final selfUrl = await startSyncServer(extraArgs: ['-admin-user', 'nas_owner', '-allow-register=false']);
    final node = _ModeNode('Phone');
    addTearDown(node.dispose);

    final officialInfo = await node.sync.apiClient.probeServer(officialUrl);
    expect(officialInfo.allowRegistration, isTrue);

    final selfInfo = await node.sync.apiClient.probeServer(selfUrl);
    expect(selfInfo.allowRegistration, isFalse);

    await node.sync.initialize();
    await node.sync.selectLocalMode();
    expect(node.sync.syncMode, SyncMode.localOnly);

    // Seed local-only item before signing into Official Sync.
    await node.repo.insertItem(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:11'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Local Movie',
        sortTitle: 'local movie',
        tmdbId: const Value('11'),
        metadataSource: const Value('tmdb'),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );

    // Sign into Official (with accountOnly so Local Movie remains isolated in local workspace).
    await node.sync.register(
      serverUrl: officialUrl,
      username: 'official_u',
      password: 'pw',
      kdfParams: fastKdf,
      mergePolicy: LocalMergePolicy.accountOnly,
      serverKind: SyncServerKind.official,
    );
    expect(node.sync.session?.serverKind, SyncServerKind.official);
    expect((await node.sync.syncStore.loadSession())?.serverKind, SyncServerKind.official);
    expect(await node.sync.syncStore.getLastSelfHostedUrl(), isNull);
    expect(await node.repo.findByWorkKey('tmdb:movie:11'), isNull);

    await node.sync.signOut();
    expect(await node.repo.findByWorkKey('tmdb:movie:11'), isNotNull);

    // Register designated admin on Self-Hosted server and verify serverKind & lastSelfHostedUrl persist.
    await node.sync.register(
      serverUrl: selfUrl,
      username: 'nas_owner',
      password: 'pw',
      kdfParams: fastKdf,
      mergePolicy: LocalMergePolicy.accountOnly,
      serverKind: SyncServerKind.selfHosted,
    );
    expect(node.sync.session?.serverKind, SyncServerKind.selfHosted);
    expect((await node.sync.syncStore.loadSession())?.serverKind, SyncServerKind.selfHosted);
    expect(await node.sync.syncStore.getLastSelfHostedUrl(), SyncLocalStore.normalizeServerUrl(selfUrl));

    // Sign out preserves lastSelfHostedUrl so Self-Hosted form opens pre-filled next time.
    await node.sync.signOut();
    expect(await node.sync.syncStore.getLastSelfHostedUrl(), SyncLocalStore.normalizeServerUrl(selfUrl));
  });

  test('2. Mobile confirmQrUri rejects signed-out devices and cross-server QR URIs', () async {
    final officialUrl = await startSyncServer();
    final selfUrl = await startSyncServer();
    final phone = _ModeNode('Phone');
    final pc = _ModeNode('PC');
    addTearDown(phone.dispose);
    addTearDown(pc.dispose);

    await phone.sync.initialize();
    await expectLater(
      phone.sync.confirmQrUri('ttplay://qr-auth?mode=server&server=$officialUrl&session_id=abc&pub_key=xyz'),
      throwsA(isA<SyncQrAuthException>().having((e) => e.code, 'code', SyncQrAuthErrorCode.notSignedIn)),
    );

    await phone.sync.register(
      serverUrl: selfUrl,
      username: 'self_user',
      password: 'pw',
      kdfParams: fastKdf,
      serverKind: SyncServerKind.selfHosted,
    );

    final pcQr = await pc.sync.startQrSession(serverUrl: officialUrl, serverKind: SyncServerKind.official);
    await expectLater(
      phone.sync.confirmQrUri(pcQr.qrUri),
      throwsA(
        isA<SyncQrAuthException>()
            .having((e) => e.code, 'code', SyncQrAuthErrorCode.serverMismatch)
            .having((e) => e.currentServer, 'currentServer', selfUrl)
            .having((e) => e.targetServer, 'targetServer', officialUrl),
      ),
    );
  });

  test('3. Official Sync Server QR login signs in PC as official and syncs library', () async {
    final officialUrl = await startSyncServer();
    final phone = _ModeNode('Phone');
    final pc = _ModeNode('PC');
    addTearDown(phone.dispose);
    addTearDown(pc.dispose);

    await phone.sync.register(
      serverUrl: officialUrl,
      username: 'qr_off',
      password: 'pw',
      kdfParams: fastKdf,
      serverKind: SyncServerKind.official,
    );
    await _seedMovie(
      phone,
      mountId: 'm_qr_off',
      tmdbId: '603',
      title: 'The Matrix',
      filePath: '/Movies/Matrix.mkv',
      updatedAt: 2000,
    );
    await phone.sync.onCatalogChanged(allowTombstones: false);
    while (phone.sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await phone.sync.syncNow(allowBackgroundScan: false);

    final pcQr = await pc.sync.startQrSession(serverUrl: officialUrl, serverKind: SyncServerKind.official);
    final parsed = Uri.parse(pcQr.qrUri);
    expect(parsed.queryParameters['mode'], 'server');
    expect(parsed.queryParameters['kind'], 'official');

    await phone.sync.confirmQrUri(pcQr.qrUri);
    final signedIn = await pc.sync.pollQrSession(
      serverUrl: officialUrl,
      sessionId: pcQr.sessionId,
      keyPair: pcQr.keyPair,
      serverKind: SyncServerKind.official,
    );
    expect(signedIn, isTrue);
    expect(pc.sync.session?.serverKind, SyncServerKind.official);
    expect(await pc.repo.findByWorkKey('tmdb:movie:603'), isNotNull);
  });

  test('4. Zero-URL LAN QR handoff signs fresh TV into Phone Self-Hosted server automatically', () async {
    final selfUrl = await startSyncServer();
    final phone = _ModeNode('Phone');
    final tv = _ModeNode('LivingRoom-TV', autoStartLan: true);
    addTearDown(phone.dispose);
    addTearDown(tv.dispose);

    await phone.sync.register(
      serverUrl: selfUrl,
      username: 'qr_self',
      password: 'pw',
      kdfParams: fastKdf,
      serverKind: SyncServerKind.selfHosted,
    );
    await _seedMovie(
      phone,
      mountId: 'm_qr_self',
      tmdbId: '27205',
      title: 'Inception',
      filePath: '/Movies/Inception.mkv',
      updatedAt: 3000,
    );
    await phone.sync.onCatalogChanged(allowTombstones: false);
    while (phone.sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await phone.sync.syncNow(allowBackgroundScan: false);

    final completed = Completer<void>();
    final tvQr = await tv.sync.startLanQrHandoffSession(
      onCompleted: () {
        if (!completed.isCompleted) completed.complete();
      },
      onError: (e) {
        if (!completed.isCompleted) completed.completeError(e);
      },
    );
    final parsed = Uri.parse(tvQr.qrUri);
    expect(parsed.queryParameters['mode'], 'lan');
    expect(parsed.queryParameters['server'], isNull);
    expect(parsed.queryParameters['hosts'], isNotEmpty);

    await phone.sync.confirmQrUri(tvQr.qrUri);
    await completed.future.timeout(const Duration(seconds: 5));

    expect(tv.sync.isSignedIn, isTrue);
    expect(tv.sync.session?.serverKind, SyncServerKind.selfHosted);
    expect(tv.sync.session?.serverUrl, SyncLocalStore.normalizeServerUrl(selfUrl));
    expect(await tv.sync.syncStore.getLastSelfHostedUrl(), SyncLocalStore.normalizeServerUrl(selfUrl));
    expect(await tv.repo.findByWorkKey('tmdb:movie:27205'), isNotNull);
  });
}
