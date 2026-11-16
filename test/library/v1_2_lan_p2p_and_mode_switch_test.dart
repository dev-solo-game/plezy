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
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/work_identity.dart';
import 'package:plezy/media/work_skip_settings.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/work_skip_settings_store.dart';
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

class _PeerDevice {
  _PeerDevice({required this.name, this.failOnRemoteList = false})
    : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) =>
          _NoScanMockDriver(mount.kind, failOnList: failOnRemoteList),
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
      environment: {'GOTOOLCHAIN': 'local'},
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

  test('serverless LAN P2P blocks untrusted strangers and syncs Quark + library after 1-tap trust', () async {
    final phoneA = _PeerDevice(name: 'Phone A');
    final tvB = _PeerDevice(name: 'LivingRoomTV', failOnRemoteList: true);
    addTearDown(phoneA.dispose);
    addTearDown(tvB.dispose);

    await phoneA.initLan();
    await tvB.initLan();

    const quarkMount = StorageMount(
      id: 'm_lan_quark',
      kind: StorageKind.quark,
      displayName: '家里夸克',
      config: {MountKeys.quarkMode: 'pc', MountKeys.rootFolderId: '0'},
      secrets: {MountKeys.secretCookie: 'uid=888999; __pus=lan_secret'},
    );
    await phoneA.registry.upsert(quarkMount);
    await phoneA.db
        .into(phoneA.db.libraryScanStates)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(mountId: quarkMount.id, quarkCheckpoint: const Value('0:5000')),
        );

    final showId = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.show,
        libraryType: LibraryTypes.anime,
        title: '仙逆',
        sortTitle: 'xian ni',
        tmdbId: const Value('235412'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final seasonId = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.season,
        libraryType: LibraryTypes.anime,
        title: 'Season 1',
        sortTitle: 'season 1',
        parentId: Value(showId),
        showId: Value(showId),
        seasonNumber: const Value(1),
        addedAt: 1000,
        updatedAt: 1000,
        scrapedAt: const Value(1000),
      ),
    );
    final ep1Id = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.episode,
        libraryType: LibraryTypes.anime,
        title: '第1集：离乡',
        sortTitle: 's0001e0001',
        parentId: Value(seasonId),
        showId: Value(showId),
        seasonNumber: const Value(1),
        episodeNumber: const Value(1),
        addedAt: 1000,
        updatedAt: 1000,
        scrapedAt: const Value(1000),
      ),
    );
    final ep1File = await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Anime/XianNi/S01E01.mp4',
      role: LibraryFileRoles.video,
      scanId: 1,
      remoteId: 'fid_lan_ep1',
      size: 4000,
    );
    await phoneA.repo.linkFile(ep1File, ep1Id);
    await phoneA.repo.updateFile(ep1File, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
    await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Anime/XianNi/S01E01.chi.ass',
      role: LibraryFileRoles.subtitle,
      scanId: 1,
      remoteId: 'fid_lan_sub1',
      language: 'chi',
      ownerFileId: ep1File,
    );

    final movieId = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '沙丘2',
        sortTitle: 'dune 2',
        tmdbId: const Value('693134'),
        metadataSource: const Value('nfo'),
        locked: const Value(true),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final movieFile = await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Movies/Dune2.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      remoteId: 'fid_lan_m1',
      size: 9000,
    );
    await phoneA.repo.linkFile(movieFile, movieId);
    await phoneA.repo.updateFile(
      movieFile,
      const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), matchLocked: Value(true)),
    );

    final showIdentity = WorkIdentity.resolve(source: WorkIdentity.localSource, kind: 'show', tmdbId: '235412')!;
    await WorkSkipSettingsStore(
      phoneA.db,
    ).save(showIdentity, const WorkSkipSettings(introEnabled: true, introStartMs: 5000, introEndMs: 90000));
    await phoneA.client.reportPlaybackStopped(
      itemId: '$ep1Id',
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 24),
    );

    // 1. Untrusted stranger on public Wi-Fi attempting to read snapshot MUST get 403 Forbidden.
    final client = http.Client();
    addTearDown(client.close);
    final strangerResp = await client.get(
      Uri.parse('http://127.0.0.1:${phoneA.sync.lanService.listeningPort}/lan/v1/sync/snapshot'),
      headers: {'X-Plezy-Device': 'stranger', 'X-Plezy-Timestamp': '1', 'X-Plezy-Signature': 'forged'},
    );
    expect(strangerResp.statusCode, HttpStatus.forbidden);

    // 2. Discover & pair TV B with Phone A via TOFU + 4-digit visual pairing code.
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
    expect(tvB.sync.lanService.incomingPairRequests, hasLength(1));
    final pairReq = tvB.sync.lanService.incomingPairRequests.single;
    expect(pairReq.pairingCode, codeOnPhone);

    await tvB.sync.lanService.acceptPairRequest(pairReq);
    // Sync explicitly to guarantee background notify/pull has completed in deterministic test timing.
    await tvB.sync.lanService.syncWithAllTrustedPeers();

    // 3. Verify TV B has Phone A's decrypted Quark mount, checkpoint, full library, skip rules & watch progress.
    final tvMounts = await tvB.registry.list();
    expect(tvMounts, hasLength(1));
    expect(tvMounts.single.id, 'm_lan_quark');
    expect(tvMounts.single.secret(MountKeys.secretCookie), contains('uid=888999'));
    final tvScan = await (tvB.db.select(tvB.db.libraryScanStates)..where((t) => t.mountId.equals('m_lan_quark'))).getSingle();
    expect(tvScan.quarkCheckpoint, '0:5000');

    final tvAnime = await tvB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.anime));
    expect(tvAnime.items.map((v) => v.item.title), ['仙逆']);
    final tvEpisodes = await tvB.repo.episodesOfShow(tvAnime.items.single.item.id);
    expect(tvEpisodes.single.state?.positionMs, 720000);
    final tvEpFiles = await tvB.repo.versionsOf(tvEpisodes.single.item.id);
    expect((await tvB.repo.subtitlesOf(tvEpFiles.single.id)).single.language, 'chi');

    final tvMovies = await tvB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(tvMovies.items.single.item.title, '沙丘2');
    expect(tvMovies.items.single.item.locked, isTrue);

    final tvSkip = await WorkSkipSettingsStore(tvB.db).read(showIdentity);
    expect((tvSkip.introEnabled, tvSkip.introStartMs, tvSkip.introEndMs), (true, 5000, 90000));

    // 4. TV B marks Dune 2 watched and pushes back over LAN P2P without re-pairing!
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await tvB.client.markWatched(MediaItem.jellyfin(id: '${tvMovies.items.single.item.id}', kind: MediaKind.movie, title: '沙丘2'));
    await tvB.sync.onPlaybackOutboxQueued();
    await phoneA.sync.lanService.syncWithAllTrustedPeers();
    expect((await phoneA.repo.getItem(movieId))!.isWatched, isTrue);
  });

  test('serverless LAN P2P deterministically merges dual-offline same Quark mount regardless of sync order', () async {
    final devA = _PeerDevice(name: 'Phone A');
    final devB = _PeerDevice(name: 'TV B');
    addTearDown(devA.dispose);
    addTearDown(devB.dispose);

    await devA.initLan();
    await devB.initLan();

    // Device A created mount earlier (08:00), Device B created same Quark mount later (09:00) with newer checkpoint.
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
        .insertOnConflictUpdate(LibraryScanStatesCompanion.insert(mountId: 'uuid-A', quarkCheckpoint: const Value('0:3000')));
    await devB.db
        .into(devB.db.libraryScanStates)
        .insertOnConflictUpdate(LibraryScanStatesCompanion.insert(mountId: 'uuid-B', quarkCheckpoint: const Value('0:9000')));

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
    final fA = await devA.repo.upsertFile(mountId: 'uuid-A', path: '/Inception.mkv', role: LibraryFileRoles.video, scanId: 1);
    await devA.repo.linkFile(fA, movieA);
    await devA.repo.updateFile(fA, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), matchLocked: Value(true)));

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
    final fB = await devB.repo.upsertFile(mountId: 'uuid-B', path: '/Inception.mkv', role: LibraryFileRoles.video, scanId: 1);
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
    final fInterB = await devB.repo.upsertFile(mountId: 'uuid-B', path: '/Interstellar.mkv', role: LibraryFileRoles.video, scanId: 1);
    await devB.repo.linkFile(fInterB, interB);
    await devB.repo.updateFile(fInterB, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    final peerB = LanDiscoveredPeer(
      deviceId: devB.sync.lanService.deviceId!,
      deviceName: 'TV B',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: devB.sync.lanService.listeningPort!,
      pubKeyBase64: devB.sync.lanService.publicKeyBase64!,
      revision: 1,
      lastSeen: clock.now(),
    );
    await devA.sync.lanService.requestPairWithPeer(peerB);
    await devB.sync.lanService.acceptPairRequest(devB.sync.lanService.incomingPairRequests.single);
    await devA.sync.lanService.syncWithAllTrustedPeers();
    await devB.sync.lanService.syncWithAllTrustedPeers();

    final mountsA = await devA.registry.list();
    final mountsB = await devB.registry.list();
    expect(mountsA, hasLength(1));
    expect(mountsB, hasLength(1));
    expect(mountsA.single.id, 'uuid-A');
    expect(mountsB.single.id, 'uuid-A');

    final cpA = (await (devA.db.select(devA.db.libraryScanStates)..where((t) => t.mountId.equals('uuid-A'))).getSingle()).quarkCheckpoint;
    final cpB = (await (devB.db.select(devB.db.libraryScanStates)..where((t) => t.mountId.equals('uuid-A'))).getSingle()).quarkCheckpoint;
    expect(cpA, '0:9000');
    expect(cpB, '0:9000');

    final titlesA = (await devA.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title).toSet();
    final titlesB = (await devB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title).toSet();
    expect(titlesA, {'盗梦空间', '星际穿越'});
    expect(titlesB, {'盗梦空间', '星际穿越'});
    expect((await devB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);
  });

  test('switching between Local/LAN P2P and Go Sync Server is mutually exclusive and preserves all data', () async {
    final serverUrl = await startSyncServer();
    final phoneA = _PeerDevice(name: 'Phone A');
    final tvB = _PeerDevice(name: 'TV B', failOnRemoteList: true);
    addTearDown(phoneA.dispose);
    addTearDown(tvB.dispose);

    // 1. Phone A starts in Local/LAN P2P mode and builds library offline.
    await phoneA.initLan();
    expect(phoneA.sync.syncMode, SyncMode.lanP2p);
    expect(phoneA.sync.lanService.isRunning, isTrue);

    const mount = StorageMount(
      id: 'm_switch',
      kind: StorageKind.webdav,
      displayName: 'Home NAS',
      config: {MountKeys.baseUrl: 'http://192.168.1.2/dav'},
      secrets: {MountKeys.secretPassword: 'pw'},
    );
    await phoneA.registry.upsert(mount);
    final movieId = await phoneA.repo.insertItem(
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
      await phoneA.repo.upsertFile(mountId: 'm_switch', path: '/WE2.mkv', role: LibraryFileRoles.video, scanId: 1),
      movieId,
    );

    // 2. Phone A logs into Go Sync Server -> automatically stops LAN P2P server & uploads library.
    await phoneA.sync.register(serverUrl: serverUrl, username: 'switcher', password: 'pw', kdfParams: fastKdf);
    expect(phoneA.sync.syncMode, SyncMode.cloudServer);
    expect(phoneA.sync.lanService.isRunning, isFalse);

    // Empty TV B logs into the same Go Sync Server -> receives Phone A's pre-existing library automatically.
    await tvB.sync.loginWithPassword(serverUrl: serverUrl, username: 'switcher', password: 'pw');
    expect(tvB.sync.syncMode, SyncMode.cloudServer);
    expect(tvB.sync.lanService.isRunning, isFalse);
    final tvMovies = await tvB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(tvMovies.items.map((v) => v.item.title), ['流浪地球2']);

    // 3. Signing out on Phone A returns seamlessly to Local/LAN P2P mode without losing data.
    await phoneA.sync.signOut();
    expect(phoneA.sync.syncMode, SyncMode.lanP2p);
    expect(phoneA.sync.isSignedIn, isFalse);
    expect(phoneA.sync.lanService.isRunning, isTrue);
    expect((await phoneA.registry.list()).single.id, 'm_switch');
    final phoneMovies = await phoneA.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(phoneMovies.items.map((v) => v.item.title), ['流浪地球2']);
  });
}
