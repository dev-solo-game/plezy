import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/library_workspace_store.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _NoScanMockDriver implements StorageDriver {
  _NoScanMockDriver(this.kind, {this.failOnList = false});

  @override
  final StorageKind kind;
  final bool failOnList;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    if (failOnList) {
      throw StateError('Unexpected list($path) on zero-scan LAN peer');
    }
    return const [];
  }

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: false, size: 0);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _GatedStorageDriver implements StorageDriver {
  _GatedStorageDriver(
    this.kind, {
    required this.entriesByDir,
    this.blockedDir,
    this.onEnterBlockedDir,
    this.blockedGate,
  });

  @override
  final StorageKind kind;
  final Map<String, List<StorageEntry>> entriesByDir;
  final String? blockedDir;
  final Completer<void>? onEnterBlockedDir;
  final Future<List<StorageEntry>>? blockedGate;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    if (path == blockedDir) {
      if (onEnterBlockedDir != null && !onEnterBlockedDir!.isCompleted) {
        onEnterBlockedDir!.complete();
      }
      if (blockedGate != null) {
        return await blockedGate!;
      }
    }
    return entriesByDir[path] ?? const [];
  }

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: false, size: 0);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _PeerDevice {
  _PeerDevice({required this.name, this.failOnRemoteList = false, StorageDriver Function(StorageMount)? customDriver})
    : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) =>
          customDriver?.call(mount) ?? _NoScanMockDriver(mount.kind, failOnList: failOnRemoteList),
    );
    client = LocalLibraryClient(repository: repo, mounts: mountManager);
    scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mountManager);
    sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      enableLanUdp: false,
      autoStartLanService: true,
    );
  }

  final String name;
  final AppDatabase db;
  final bool failOnRemoteList;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;

  Future<void> initLan() async {
    await sync.initialize();
    await sync.syncStore.setDeviceName(name);
    await sync.selectLanMode();
  }

  Future<void> dispose() async {
    client.close();
    scans.dispose();
    sync.dispose();
    await mountManager.dispose();
    await db.close();
  }
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
    binTempDir = await Directory.systemTemp.createTemp('plezy_v12_bin_');
    final exeName = Platform.isWindows ? 'plezy_sync_server.exe' : 'plezy_sync_server';
    serverExePath = p.join(binTempDir.path, exeName);
    final build = await Process.run(
      'go',
      ['build', '-o', serverExePath, '.'],
      workingDirectory: p.join(Directory.current.path, 'sync_server'),
      environment: {'GOTOOLCHAIN': 'auto'},
    );
    if (build.exitCode != 0) {
      fail('Failed to build sync_server:\n${build.stdout}\n${build.stderr}');
    }
  });

  tearDownAll(() async {
    HttpOverrides.global = previousHttpOverrides;
    if (await binTempDir.exists()) {
      await binTempDir.delete(recursive: true);
    }
  });

  Future<String> startSyncServer() async {
    final dataDir = await Directory.systemTemp.createTemp('plezy_v12_data_');
    final proc = await Process.start(serverExePath, ['-addr', '127.0.0.1:0', '-data-dir', dataDir.path]);
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
        await dataDir.delete(recursive: true);
      }
    });

    return urlCompleter.future.timeout(const Duration(seconds: 10));
  }

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('retired LAN P2P sync endpoints return 410 Gone while remote pairing and revoke stay active', () async {
    final phoneA = _PeerDevice(name: 'Phone A');
    final tvB = _PeerDevice(name: 'LivingRoomTV', failOnRemoteList: true);
    addTearDown(phoneA.dispose);
    addTearDown(tvB.dispose);

    await phoneA.initLan();
    await tvB.initLan();

    final client = http.Client();
    addTearDown(client.close);
    final baseUri = 'http://127.0.0.1:${phoneA.sync.lanService.listeningPort}';

    // /lan/v1/hello stays up for remote control discovery without library revision metadata.
    final helloResp = await client.get(Uri.parse('$baseUri/lan/v1/hello'));
    expect(helloResp.statusCode, HttpStatus.ok);
    final helloJson = jsonDecode(helloResp.body) as Map<String, dynamic>;
    expect(helloJson.containsKey('revision'), isFalse);
    expect(helloJson.containsKey('sync_epoch'), isFalse);

    // Every legacy /lan/v1/sync/* endpoint must return 410 Gone.
    for (final req in [
      client.get(Uri.parse('$baseUri/lan/v1/sync/pull')),
      client.post(Uri.parse('$baseUri/lan/v1/sync/push'), body: '{}'),
      client.get(Uri.parse('$baseUri/lan/v1/sync/snapshot')),
      client.post(Uri.parse('$baseUri/lan/v1/sync/notify'), body: '{}'),
    ]) {
      final resp = await req;
      expect(resp.statusCode, HttpStatus.gone);
      expect((jsonDecode(resp.body) as Map<String, dynamic>)['error'], 'lan_library_sync_retired');
    }

    // 4-digit pairing still works for remote control, and revoke clears both peers cleanly.
    final discoveredTv = LanDiscoveredPeer(
      deviceId: tvB.sync.lanService.deviceId!,
      deviceName: 'LivingRoomTV',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: tvB.sync.lanService.listeningPort!,
      pubKeyBase64: tvB.sync.lanService.publicKeyBase64!,
      revision: 0,
      lastSeen: clock.now(),
    );
    phoneA.sync.lanService.registerDiscoveredPeer(discoveredTv);
    final codeOnPhone = discoveredTv.pairingCodeFor(phoneA.sync.lanService.publicKeyBase64!);

    await phoneA.sync.lanService.requestPairWithPeer(discoveredTv);
    final pairReq = tvB.sync.lanService.incomingPairRequests.single;
    expect(pairReq.pairingCode, codeOnPhone);
    await tvB.sync.lanService.acceptPairRequest(pairReq);
    expect(phoneA.sync.lanService.isPeerTrusted(tvB.sync.lanService.deviceId!), isTrue);
    expect(tvB.sync.lanService.isPeerTrusted(phoneA.sync.lanService.deviceId!), isTrue);

    await phoneA.sync.lanService.revokeTrustedPeer(tvB.sync.lanService.deviceId!);
    expect(phoneA.sync.lanService.isPeerTrusted(tvB.sync.lanService.deviceId!), isFalse);
    expect(tvB.sync.lanService.isPeerTrusted(phoneA.sync.lanService.deviceId!), isFalse);
  });

  test('Cloud Sync deterministically merges dual-offline same Quark mount regardless of push order', () async {
    final serverUrl = await startSyncServer();
    final devA = _PeerDevice(name: 'Phone A');
    final devB = _PeerDevice(name: 'TV B');
    addTearDown(devA.dispose);
    addTearDown(devB.dispose);

    await devA.initLan();
    await devB.initLan();

    final mountA = StorageMount(
      id: 'uuid-A',
      kind: StorageKind.quark,
      displayName: 'Phone Quark',
      config: const {MountKeys.rootFolderId: '0'},
      secrets: const {MountKeys.secretCookie: 'uid=555666; __pus=a'},
      createdAt: DateTime.utc(2026, 11, 16, 8, 0, 0),
    );
    final mountB = StorageMount(
      id: 'uuid-B',
      kind: StorageKind.quark,
      displayName: 'TV Quark',
      config: const {MountKeys.rootFolderId: '0'},
      secrets: const {MountKeys.secretCookie: 'uid=555666; __pus=b'},
      createdAt: DateTime.utc(2026, 11, 16, 9, 0, 0),
    );
    await devA.registry.upsert(mountA);
    await devB.registry.upsert(mountB);
    await devA.db
        .into(devA.db.libraryScanStates)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(
            mountId: 'uuid-A',
            finishedAt: const Value(3000),
            quarkCheckpoint: const Value('0:3000'),
          ),
        );
    await devB.db
        .into(devB.db.libraryScanStates)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(
            mountId: 'uuid-B',
            finishedAt: const Value(9000),
            quarkCheckpoint: const Value('0:9000'),
          ),
        );

    final movieA = await devA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '盗梦空间',
        sortTitle: 'inception',
        tmdbId: const Value('27205'),
        metadataSource: const Value('nfo'),
        locked: const Value(true),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final fA = await devA.repo.upsertFile(
      mountId: 'uuid-A',
      path: '/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await devA.repo.linkFile(fA, movieA);
    await devA.repo.updateFile(
      fA,
      const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), matchLocked: Value(true)),
    );

    final unmatchedB = await devB.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.pending,
        title: 'Inception Raw',
        sortTitle: 'inception raw',
        scrapedAt: const Value(9999999),
        addedAt: 2000,
        updatedAt: 9999999,
      ),
    );
    final fB = await devB.repo.upsertFile(
      mountId: 'uuid-B',
      path: '/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await devB.repo.linkFile(fB, unmatchedB);
    await devB.repo.updateFile(fB, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.unmatched)));

    final interB = await devB.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '星际穿越',
        sortTitle: 'interstellar',
        tmdbId: const Value('157336'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(2000),
        addedAt: 2000,
        updatedAt: 2000,
      ),
    );
    final fInterB = await devB.repo.upsertFile(
      mountId: 'uuid-B',
      path: '/Interstellar.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await devB.repo.linkFile(fInterB, interB);
    await devB.repo.updateFile(fInterB, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    await devA.sync.register(serverUrl: serverUrl, username: 'mergeuser', password: 'pw', kdfParams: fastKdf);
    await devB.sync.loginWithPassword(serverUrl: serverUrl, username: 'mergeuser', password: 'pw');
    await devA.sync.syncNow(allowBackgroundScan: false);
    await devB.sync.syncNow(allowBackgroundScan: false);

    final mountsA = await devA.registry.list();
    final mountsB = await devB.registry.list();
    expect(mountsA, hasLength(1));
    expect(mountsB, hasLength(1));
    expect(mountsA.single.id, 'uuid-A');
    expect(mountsB.single.id, 'uuid-A');

    final cpA = (await (devA.db.select(
      devA.db.libraryScanStates,
    )..where((t) => t.mountId.equals('uuid-A'))).getSingle()).quarkCheckpoint;
    final cpB = (await (devB.db.select(
      devB.db.libraryScanStates,
    )..where((t) => t.mountId.equals('uuid-A'))).getSingle()).quarkCheckpoint;
    expect(cpA, '0:9000');
    expect(cpB, '0:9000');

    final titlesA = (await devA.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toSet();
    final titlesB = (await devB.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toSet();
    expect(titlesA, {'盗梦空间', '星际穿越'});
    expect(titlesB, {'盗梦空间', '星际穿越'});
    expect((await devB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);
  });

  test('workspace isolation separates local vs accountOnly vs mergeLocal while keeping LAN service active', () async {
    final serverUrl = await startSyncServer();
    final phoneA = _PeerDevice(name: 'Phone A');
    final seedB = _PeerDevice(name: 'Seed B', failOnRemoteList: true);
    addTearDown(phoneA.dispose);
    addTearDown(seedB.dispose);

    // Seed cloud account X with "云端电影" on Seed B, then clear Seed B usage.
    const cloudMount = StorageMount(
      id: 'm_cloud_only',
      kind: StorageKind.webdav,
      displayName: 'Cloud WebDAV',
      config: {MountKeys.baseUrl: 'https://cloud.example.com/dav'},
      secrets: {MountKeys.secretPassword: 'pw'},
    );
    await seedB.registry.upsert(cloudMount);
    final cloudMovieId = await seedB.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '云端电影',
        sortTitle: 'cloud movie',
        tmdbId: const Value('999001'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    await seedB.repo.linkFile(
      await seedB.repo.upsertFile(mountId: 'm_cloud_only', path: '/Cloud.mkv', role: LibraryFileRoles.video, scanId: 1),
      cloudMovieId,
    );
    await seedB.sync.register(serverUrl: serverUrl, username: 'acct_x', password: 'pw', kdfParams: fastKdf);

    // Phone A starts in Local mode with local-only movie "流浪地球2".
    await phoneA.initLan();
    expect(phoneA.sync.syncMode, SyncMode.localOnly);
    expect(phoneA.sync.lanService.isRunning, isTrue);

    const localMount = StorageMount(
      id: 'm_local_only',
      kind: StorageKind.webdav,
      displayName: 'Local NAS',
      config: {MountKeys.baseUrl: 'http://192.168.1.2/dav'},
      secrets: {MountKeys.secretPassword: 'pw'},
    );
    await phoneA.registry.upsert(localMount);
    final localMovieId = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '流浪地球2',
        sortTitle: 'wandering earth 2',
        tmdbId: const Value('842675'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    await phoneA.repo.linkFile(
      await phoneA.repo.upsertFile(mountId: 'm_local_only', path: '/WE2.mkv', role: LibraryFileRoles.video, scanId: 1),
      localMovieId,
    );

    // Sign into Account X with accountOnly -> local library is archived safely, not merged into Account X!
    await phoneA.sync.loginWithPassword(
      serverUrl: serverUrl,
      username: 'acct_x',
      password: 'pw',
      mergePolicy: LocalMergePolicy.accountOnly,
    );
    expect(phoneA.sync.syncMode, SyncMode.cloudServer);
    // Remote control LAN discovery must remain running across cloud sign-in!
    expect(phoneA.sync.lanService.isRunning, isTrue);
    expect((await phoneA.registry.list()).map((m) => m.id), ['m_cloud_only']);
    final cloudTitlesOnA = (await phoneA.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toList();
    expect(cloudTitlesOnA, ['云端电影']);

    // Sign out -> switches workspace back to 'local', restoring "流浪地球2" & "m_local_only".
    await phoneA.sync.signOut();
    expect(phoneA.sync.syncMode, SyncMode.localOnly);
    expect(phoneA.sync.isSignedIn, isFalse);
    expect(phoneA.sync.lanService.isRunning, isTrue);
    expect((await phoneA.registry.list()).map((m) => m.id), ['m_local_only']);
    final restoredLocalTitles = (await phoneA.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toList();
    expect(restoredLocalTitles, ['流浪地球2']);

    // Sign into a new Account Y with mergeLocal -> merges local library up to cloud Account Y.
    await phoneA.sync.register(
      serverUrl: serverUrl,
      username: 'acct_y',
      password: 'pw',
      kdfParams: fastKdf,
      mergePolicy: LocalMergePolicy.mergeLocal,
    );
    expect((await phoneA.registry.list()).map((m) => m.id), ['m_local_only']);
    await phoneA.sync.signOut();

    // Verify Account X on server never received Account Y / local data.
    await seedB.sync.syncNow(allowBackgroundScan: false);
    final seedTitles = (await seedB.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toList();
    expect(seedTitles, ['云端电影']);
  });

  test('Plan B skeleton omits heavy details over sync and lazy ID hydration never dirties SyncOutbox', () async {
    final mockTmdb = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => mockTmdb.close(force: true));
    unawaited(() async {
      await for (final req in mockTmdb) {
        if (req.uri.path.endsWith('/3/movie/693134')) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'id': 693134,
                'title': 'Dune: Part Two',
                'overview': 'Paul Atreides unites with the Fremen on Arrakis.',
                'tagline': 'Long live the fighters.',
                'credits': {
                  'cast': [
                    {'id': 1190668, 'name': 'Timothée Chalamet', 'character': 'Paul Atreides'},
                  ],
                  'crew': [
                    {'id': 137427, 'name': 'Denis Villeneuve', 'job': 'Director'},
                  ],
                },
              }),
            );
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      }
    }());

    final serverUrl = await startSyncServer();
    final pc = _PeerDevice(name: 'PC');
    final tv = _PeerDevice(name: 'TV', failOnRemoteList: true);
    addTearDown(pc.dispose);
    addTearDown(tv.dispose);

    const mount = StorageMount(
      id: 'm_planb',
      kind: StorageKind.webdav,
      displayName: 'WebDAV',
      config: {MountKeys.baseUrl: 'https://dav.example.com'},
    );
    await pc.registry.upsert(mount);
    final movieId = await pc.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Dune: Part Two',
        sortTitle: 'dune part two',
        summary: const Value('Heavy summary that should stay out of unlocked skeleton.'),
        tagline: const Value('Heavy tagline'),
        tmdbId: const Value('693134'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    await pc.repo.setGenres(movieId, const ['Sci-Fi', 'Adventure']);
    await pc.repo.setCredits(movieId, const [
      (name: 'Timothée Chalamet', job: 'actor', character: 'Paul Atreides', tmdbId: '1190668', photoSource: null),
    ]);
    final fid = await pc.repo.upsertFile(
      mountId: mount.id,
      path: '/Dune2.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await pc.repo.linkFile(fid, movieId);
    await pc.repo.updateFile(fid, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    await pc.sync.initialize();
    await pc.sync.mapper.ensureJournalUpToDate();
    final skeletonBundle = await pc.sync.mapper.buildDeltaBundle(
      encryptionKey: SyncCrypto.generateMasterKey(),
      sinceSeq: 0,
    );
    final workMeta = (skeletonBundle.works.single['metadata_json'] as Map).cast<String, Object?>();
    expect(workMeta['genres'], unorderedEquals(['Sci-Fi', 'Adventure']));
    expect(workMeta.containsKey('summary'), isFalse);
    expect(workMeta.containsKey('tagline'), isFalse);
    expect(workMeta.containsKey('credits'), isFalse);

    await pc.sync.register(serverUrl: serverUrl, username: 'planb', password: 'pw', kdfParams: fastKdf);
    await tv.sync.loginWithPassword(serverUrl: serverUrl, username: 'planb', password: 'pw');

    // Configure TV scraper runner to point to mock local TMDB server.
    await LibrarySettingsStore(
      tv.db,
    ).saveScraper(ScraperSettings(tmdbApiKey: 'test-key', tmdbApiBase: 'http://127.0.0.1:${mockTmdb.port}/3'));
    final tvScrapeRunner = LibraryScrapeRunner(
      database: tv.db,
      repository: tv.repo,
      settings: LibrarySettingsStore(tv.db),
      mounts: tv.mountManager,
    );
    tv.client.scrapeRunner = tvScrapeRunner;

    final tvMovies = await tv.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(tvMovies.items.single.item.summary, isNull);

    final hydratedItem = await tv.client.fetchItem('${tvMovies.items.single.item.id}');
    expect(hydratedItem?.summary, 'Paul Atreides unites with the Fremen on Arrakis.');
    expect(hydratedItem?.tagline, 'Long live the fighters.');
    expect(hydratedItem?.roles?.map((r) => r.tag), contains('Timothée Chalamet'));
    expect(hydratedItem?.directors, contains('Denis Villeneuve'));

    // Lazy hydration must NOT produce dirty journal or SyncOutbox entries!
    final dirtyCount = await tv.sync.mapper.ensureJournalUpToDate();
    expect(dirtyCount, 0);
    expect(await tv.sync.syncStore.readPendingOutbox(), isEmpty);
  });

  test('sync_lists and encrypted scraper settings sync across devices while proxy stays local', () async {
    final serverUrl = await startSyncServer();
    final pc = _PeerDevice(name: 'PC');
    final phone = _PeerDevice(name: 'Phone', failOnRemoteList: true);
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);

    await LibrarySettingsStore(pc.db).saveScraper(
      const ScraperSettings(
        tmdbApiKey: 'tmdb-secret-key-xyz',
        tmdbApiBase: 'https://mirror.tmdb.example/3',
        tmdbImageBase: 'https://img.mirror.example/t/p',
        language: 'ja-JP',
        proxy: '127.0.0.1:7890',
        bangumiEnabled: false,
      ),
    );
    await LibrarySettingsStore(phone.db).saveScraper(const ScraperSettings(proxy: '192.168.1.99:8888'));

    const mount = StorageMount(
      id: 'm_list',
      kind: StorageKind.webdav,
      displayName: 'Share',
      config: {MountKeys.baseUrl: 'https://dav.example.com'},
    );
    await pc.registry.upsert(mount);
    final movieId = await pc.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Your Name',
        sortTitle: 'your name',
        tmdbId: const Value('372058'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final fid = await pc.repo.upsertFile(
      mountId: mount.id,
      path: '/YourName.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await pc.repo.linkFile(fid, movieId);
    await pc.repo.updateFile(fid, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    await pc.client.createPlaylist(
      title: 'Weekend Favorites',
      items: [MediaItem.jellyfin(id: '$movieId', kind: MediaKind.movie, title: 'Your Name')],
    );

    await pc.sync.register(serverUrl: serverUrl, username: 'listuser', password: 'pw', kdfParams: fastKdf);
    await phone.sync.loginWithPassword(serverUrl: serverUrl, username: 'listuser', password: 'pw');

    final phoneSettings = await LibrarySettingsStore(phone.db).loadScraper();
    expect(phoneSettings.tmdbApiKey, 'tmdb-secret-key-xyz');
    expect(phoneSettings.tmdbApiBase, 'https://mirror.tmdb.example/3');
    expect(phoneSettings.tmdbImageBase, 'https://img.mirror.example/t/p');
    expect(phoneSettings.language, 'ja-JP');
    expect(phoneSettings.bangumiEnabled, isFalse);
    expect(phoneSettings.proxy, '192.168.1.99:8888');

    final phonePlaylists = await phone.client.fetchPlaylistsPage();
    expect(phonePlaylists.items.map((p) => p.title), ['Weekend Favorites']);
    final playlistPage = await phone.client.fetchPlaylistPage(phonePlaylists.items.single.id);
    expect(playlistPage.items.map((m) => m.title), ['Your Name']);

    // Delete playlist on PC and verify tombstone removes it on Phone.
    final pcPlaylists = await pc.client.fetchPlaylistsPage();
    await pc.client.deletePlaylist(pcPlaylists.items.single);
    await pc.sync.syncNow(allowBackgroundScan: false);
    await phone.sync.syncNow(allowBackgroundScan: false);

    final afterDelete = await phone.client.fetchPlaylistsPage();
    expect(afterDelete.items, isEmpty);
  });

  test('LocalLibraryClient.getPlaybackInitialization probes unknown mount and falls back to reachable mount', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final registry = MountRegistry(db);
    final mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) {
        if (mount.id == 'm_dead_lan') {
          return _FailingCheckDriver(mount.kind);
        }
        return _LiveUrlDriver(mount);
      },
    );
    final client = LocalLibraryClient(repository: repo, mounts: mountManager);
    addTearDown(() async {
      client.close();
      await mountManager.dispose();
      await db.close();
    });

    const deadLanMount = StorageMount(
      id: 'm_dead_lan',
      kind: StorageKind.webdav,
      displayName: 'Home SMB/WebDAV',
      config: {MountKeys.baseUrl: 'http://192.168.1.10/dav'},
    );
    const liveCloudMount = StorageMount(
      id: 'm_live_cloud',
      kind: StorageKind.quark,
      displayName: 'Remote Quark',
      config: {MountKeys.rootFolderId: '0'},
    );
    await registry.upsert(deadLanMount);
    await registry.upsert(liveCloudMount);
    await client.refreshMounts();

    final movieId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Fallback Movie',
        sortTitle: 'fallback movie',
        tmdbId: const Value('111222'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final fDead = await repo.upsertFile(
      mountId: 'm_dead_lan',
      path: '/Film.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    final fLive = await repo.upsertFile(
      mountId: 'm_live_cloud',
      path: '/Film.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await repo.linkFile(fDead, movieId);
    await repo.linkFile(fLive, movieId);

    // Dead mount starts in unknown status and is selected as stale mediaSourceId.
    expect(mountManager.statusOf('m_dead_lan'), MountOnlineStatus.unknown);

    final init = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: MediaItem.jellyfin(id: '$movieId', kind: MediaKind.movie, title: 'Fallback Movie'),
        selectedMediaIndex: 0,
        selectedMediaSourceId: '$fDead',
      ),
    );

    expect(mountManager.statusOf('m_dead_lan'), MountOnlineStatus.offline);
    expect(mountManager.statusOf('m_live_cloud'), MountOnlineStatus.onlinePrimary);
    expect(init.selectedMediaSourceId, '$fLive');
    expect(init.videoUrl, contains('/Film.mkv'));
  });

  test('mid-scan loser mount is preempted cleanly without FK error during cloud sync', () async {
    final serverUrl = await startSyncServer();
    final enteredDir2 = Completer<void>();
    final dir2Gate = Completer<List<StorageEntry>>();

    final devA = _PeerDevice(name: 'PC-A');
    final devB = _PeerDevice(
      name: 'PC-B',
      customDriver: (_) => _GatedStorageDriver(
        StorageKind.quark,
        entriesByDir: {
          '/': const [
            StorageEntry(path: '/Dir3', name: 'Dir3', isDirectory: true),
            StorageEntry(path: '/Dir2', name: 'Dir2', isDirectory: true),
            StorageEntry(path: '/Dir1', name: 'Dir1', isDirectory: true),
          ],
          '/Dir1': const [StorageEntry(path: '/Dir1/Movie1.mkv', name: 'Movie1.mkv', isDirectory: false, size: 1000)],
        },
        blockedDir: '/Dir2',
        onEnterBlockedDir: enteredDir2,
        blockedGate: dir2Gate.future,
      ),
    );
    addTearDown(devA.dispose);
    addTearDown(devB.dispose);

    final mountA = StorageMount(
      id: 'uuid-early-A',
      kind: StorageKind.quark,
      displayName: 'Quark A',
      config: const {MountKeys.rootFolderId: '0'},
      secrets: const {MountKeys.secretCookie: 'uid=777111; __pus=ok'},
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final mountB = StorageMount(
      id: 'uuid-late-B',
      kind: StorageKind.quark,
      displayName: 'Quark B',
      config: const {MountKeys.rootFolderId: '0'},
      secrets: const {MountKeys.secretCookie: 'uid=777111; __pus=ok'},
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );
    await devA.registry.upsert(mountA);
    await devB.registry.upsert(mountB);
    devB.mountManager.setStatus('uuid-late-B', MountOnlineStatus.onlinePrimary);

    for (final (path, tmdbId, title) in [
      ('/Dir1/Movie1.mkv', '27205', '盗梦空间'),
      ('/Dir2/Movie2.mkv', '157336', '星际穿越'),
      ('/Dir3/Movie3.mkv', '603', '黑客帝国'),
    ]) {
      final itemId = await devA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: title,
          sortTitle: title,
          tmdbId: Value(tmdbId),
          metadataSource: const Value('tmdb'),
          scrapedAt: const Value(5000),
          addedAt: 5000,
          updatedAt: 5000,
        ),
      );
      final fileId = await devA.repo.upsertFile(
        mountId: 'uuid-early-A',
        path: path,
        role: LibraryFileRoles.video,
        scanId: 1,
      );
      await devA.repo.linkFile(fileId, itemId);
      await devA.repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
    }
    await devA.db
        .into(devA.db.libraryScanStates)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(
            mountId: 'uuid-early-A',
            scanId: const Value(1),
            finishedAt: const Value(5000),
            quarkCheckpoint: const Value('0:8000'),
          ),
        );

    await devA.sync.register(serverUrl: serverUrl, username: 'preempt_user', password: 'pw', kdfParams: fastKdf);

    // PC-B starts scanning locally and pauses while listing /Dir2 after /Dir1 is written.
    final scanFuture = devB.scans.scan(mountB);
    await enteredDir2.future;
    expect(devB.scans.isScanning('uuid-late-B'), isTrue);

    final loginFuture = devB.sync.loginWithPassword(serverUrl: serverUrl, username: 'preempt_user', password: 'pw');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    dir2Gate.complete(const [
      StorageEntry(path: '/Dir2/Movie2.mkv', name: 'Movie2.mkv', isDirectory: false, size: 1000),
    ]);

    await scanFuture;
    await loginFuture;

    expect(devB.scans.statusOf('uuid-late-B').error, isNull);
    expect(devB.scans.statusOf('uuid-early-A').error, isNull);
    final mountsB = await devB.registry.list();
    expect(mountsB.map((m) => m.id), ['uuid-early-A']);
    expect(await devB.scans.hasIncrementalBaseline(mountsB.single), isTrue);
    final moviesB = (await devB.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((e) => e.item.title).toSet();
    expect(moviesB, {'盗梦空间', '星际穿越', '黑客帝国'});
  });

  test('mid-scan sync never clobbers seenInScan or loses already-scanned files when local mount wins', () async {
    final enteredDir2 = Completer<void>();
    final dir2Gate = Completer<List<StorageEntry>>();

    final devB = _PeerDevice(
      name: 'PC-B-Winner',
      customDriver: (_) => _GatedStorageDriver(
        StorageKind.quark,
        entriesByDir: {
          '/': const [
            StorageEntry(path: '/Dir2', name: 'Dir2', isDirectory: true),
            StorageEntry(path: '/Dir1', name: 'Dir1', isDirectory: true),
          ],
          '/Dir1': const [StorageEntry(path: '/Dir1/Movie1.mkv', name: 'Movie1.mkv', isDirectory: false, size: 1000)],
        },
        blockedDir: '/Dir2',
        onEnterBlockedDir: enteredDir2,
        blockedGate: dir2Gate.future,
      ),
    );
    addTearDown(devB.dispose);

    final mountB = StorageMount(
      id: 'uuid-winner-B',
      kind: StorageKind.quark,
      displayName: 'Quark B',
      config: const {MountKeys.rootFolderId: '0'},
      secrets: const {MountKeys.secretCookie: 'uid=777222; __pus=ok'},
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await devB.registry.upsert(mountB);
    devB.mountManager.setStatus('uuid-winner-B', MountOnlineStatus.onlinePrimary);

    // Start scanning mountB; /Dir1 writes Movie1.mkv with seenInScan = 1, then pauses at /Dir2.
    final scanFuture = devB.scans.scan(mountB);
    await enteredDir2.future;

    // While paused mid-scan, a partial sync from a later-created peer upgrades Movie1.mkv to matched
    // (without any newer quark_checkpoint / scan_finished_at, so mountB's own scan continues).
    final dummyKey = SyncCrypto.generateMasterKey();
    await devB.sync.mapper.applyPullBatch(
      masterKey: dummyKey,
      sources: [
        {
          'source_id': 'uuid-loser-A',
          'canonical_key': 'quark:777222:0',
          'name': 'Quark A',
          'protocol': 'quark',
          'is_lan_only': false,
          'primary_url': 'quark://0',
          'config_json': const {'rootFolderId': '0'},
          'include_paths': const <String>[],
          'exclude_paths': const <String>[],
          'encrypted_auth': '',
          'auth_updated_at': 0,
          'created_at': 2000,
          'client_updated_at': 3000,
          'is_deleted': false,
        },
      ],
      works: [
        {
          'work_key': 'work:movie:tmdb:27205',
          'kind': LibraryKinds.movie,
          'library_type': LibraryTypes.movie,
          'provider': 'tmdb',
          'external_id': '27205',
          'match_status': 3,
          'metadata_json': const {'title': '盗梦空间', 'sort_title': 'dao meng kong jian', 'tmdb_id': '27205'},
          'client_updated_at': 3000,
          'is_deleted': false,
        },
      ],
      files: [
        {
          'file_id': 'file-from-A',
          'source_id': 'uuid-loser-A',
          'relative_path': '/Dir1/Movie1.mkv',
          'role': LibraryFileRoles.video,
          'file_name': 'Movie1.mkv',
          'file_size': 1000,
          'work_key': 'work:movie:tmdb:27205',
          'season_num': -1,
          'episode_num': -1,
          'match_status': 3,
          'client_updated_at': 3000,
          'is_deleted': false,
        },
      ],
      workPrefs: const [],
      watchProgress: const [],
      userSettings: const {},
      nextSeq: 0,
      updateCloudCursor: false,
      deterministicP2pSourceTieBreak: true,
    );

    // Resume /Dir2 so scan finishes and invokes removeFilesNotSeen('uuid-winner-B', scanId=1).
    dir2Gate.complete(const [
      StorageEntry(path: '/Dir2/Movie2.mkv', name: 'Movie2.mkv', isDirectory: false, size: 2000),
    ]);
    await scanFuture;

    final filesB = await (devB.db.select(devB.db.libraryFiles)..where((t) => t.mountId.equals('uuid-winner-B'))).get();
    expect(filesB.map((f) => f.path).toSet(), {'/Dir1/Movie1.mkv', '/Dir2/Movie2.mkv'});
    final movie1 = filesB.singleWhere((f) => f.path == '/Dir1/Movie1.mkv');
    expect(movie1.matchState, LibraryMatchStates.matched);
    expect(movie1.seenInScan, 1);
  });
}

class _FailingCheckDriver implements StorageDriver {
  _FailingCheckDriver(this.kind);

  @override
  final StorageKind kind;

  @override
  Future<void> check() async => throw const StorageException(StorageErrorKind.network, 'LAN unreachable');

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: false, size: 0);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _LiveUrlDriver implements StorageDriver {
  _LiveUrlDriver(this.mount);

  final StorageMount mount;

  @override
  StorageKind get kind => mount.kind;

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
