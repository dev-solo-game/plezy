import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_models.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _NoScanMockDriver implements StorageDriver {
  _NoScanMockDriver(this.kind);

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

class _SyncPeerNode {
  _SyncPeerNode(this.name) : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(registry, driverFactory: (mount, {bool useFallback = false}) => _NoScanMockDriver(mount.kind));
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
    scans.onScopedCatalogChanged = (mountIds, {directoryPrefixes, allowTombstones = true}) => unawaited(
      sync.onCatalogChanged(
        mountIds: mountIds,
        directoryPrefixes: directoryPrefixes,
        allowTombstones: allowTombstones,
      ),
    );
    client.onSyncOutboxEnqueued = () => unawaited(sync.onPlaybackOutboxQueued());
  }

  final String name;
  final AppDatabase db;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;
  bool _disposed = false;

  Future<void> initLan() async {
    await sync.initialize();
    await sync.syncStore.setDeviceName(name);
    await sync.selectLanMode();
  }

  LanDiscoveredPeer asDiscoveredPeer({int? revisionOverride}) => LanDiscoveredPeer(
    deviceId: sync.lanService.deviceId!,
    deviceName: name,
    platform: 'linux',
    host: '127.0.0.1',
    httpPort: sync.lanService.listeningPort!,
    pubKeyBase64: sync.lanService.publicKeyBase64!,
    revision: revisionOverride ?? 0,
    lastSeen: clock.now(),
    syncEpoch: sync.lanService.trustedPeers.isEmpty ? null : null,
  );

  Future<void> pairWith(_SyncPeerNode target) async {
    final targetRev = await target.sync.syncStore.getLocalLanRevision();
    final targetEpoch = await target.sync.syncStore.getOrCreateSyncEpoch();
    final discovered = LanDiscoveredPeer(
      deviceId: target.sync.lanService.deviceId!,
      deviceName: target.name,
      platform: 'android',
      host: '127.0.0.1',
      httpPort: target.sync.lanService.listeningPort!,
      pubKeyBase64: target.sync.lanService.publicKeyBase64!,
      revision: targetRev,
      lastSeen: clock.now(),
      syncEpoch: targetEpoch,
    );
    await sync.lanService.requestPairWithPeer(discovered);
    final req = target.sync.lanService.incomingPairRequests.singleWhere((r) => r.deviceId == sync.lanService.deviceId);
    await target.sync.lanService.acceptPairRequest(req);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    client.close();
    scans.dispose();
    sync.dispose();
    await mountManager.dispose();
    await db.close();
  }
}

Future<({int showId, int seasonId, int epId, int fileId})> _seedEpisode(
  _SyncPeerNode node, {
  required String mountId,
  required String showTmdbId,
  required String showTitle,
  required int episodeNumber,
  required String filePath,
  int updatedAt = 1000,
}) async {
  var show = await node.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: showTmdbId);
  show ??= (await node.repo.getItem(
    await node.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.show,
        libraryType: LibraryTypes.show,
        title: showTitle,
        sortTitle: showTitle.toLowerCase(),
        tmdbId: Value(showTmdbId),
        metadataSource: const Value('tmdb'),
        scrapedAt: Value(updatedAt),
        addedAt: updatedAt,
        updatedAt: updatedAt,
      ),
    ),
  ))!
      .item;

  final season = await node.repo.findChild(show.id, seasonNumber: 1);
  final seasonId =
      season?.id ??
      await node.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.season,
          libraryType: LibraryTypes.show,
          title: 'Season 1',
          sortTitle: 'season 0001',
          parentId: Value(show.id),
          showId: Value(show.id),
          seasonNumber: const Value(1),
          addedAt: updatedAt,
          updatedAt: updatedAt,
          scrapedAt: Value(updatedAt),
        ),
      );

  final epId = await node.repo.insertItem(
    LibraryItemsCompanion.insert(
      kind: LibraryKinds.episode,
      libraryType: LibraryTypes.show,
      title: 'Episode $episodeNumber',
      sortTitle: 's0001e${episodeNumber.toString().padLeft(4, '0')}',
      parentId: Value(seasonId),
      showId: Value(show.id),
      seasonNumber: const Value(1),
      episodeNumber: Value(episodeNumber),
      addedAt: updatedAt,
      updatedAt: updatedAt,
      scrapedAt: Value(updatedAt),
    ),
  );
  final fileId = await node.repo.upsertFile(
    mountId: mountId,
    path: filePath,
    role: LibraryFileRoles.video,
    scanId: 1,
    size: 10000 + episodeNumber,
    modifiedAt: updatedAt,
  );
  await node.repo.linkFile(fileId, epId);
  await node.repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
  return (showId: show.id, seasonId: seasonId, epId: epId, fileId: fileId);
}

Future<({int itemId, int fileId})> _seedMovie(
  _SyncPeerNode node, {
  required String mountId,
  required String tmdbId,
  required String title,
  required String filePath,
  int updatedAt = 1000,
  bool locked = false,
}) async {
  final itemId = await node.repo.insertItem(
    LibraryItemsCompanion.insert(
      kind: LibraryKinds.movie,
      libraryType: LibraryTypes.movie,
      title: title,
      sortTitle: title.toLowerCase(),
      tmdbId: Value(tmdbId),
      metadataSource: Value(locked ? 'nfo' : 'tmdb'),
      locked: Value(locked),
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
  await node.repo.updateFile(
    fileId,
    LibraryFilesCompanion(
      matchState: const Value(LibraryMatchStates.matched),
      matchLocked: Value(locked),
    ),
  );
  return (itemId: itemId, fileId: fileId);
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
    binTempDir = await Directory.systemTemp.createTemp('plezy_inc_sync_bin_');
    final exeName = Platform.isWindows ? 'plezy_sync_server.exe' : 'plezy_sync_server';
    serverExePath = p.join(binTempDir.path, exeName);
    final buildResult = await Process.run(
      'go',
      ['build', '-o', serverExePath, '.'],
      workingDirectory: p.join(Directory.current.path, 'sync_server'),
      environment: {'GOTOOLCHAIN': 'local'},
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

  Future<String> startSyncServer() async {
    final dataDir = await Directory.systemTemp.createTemp('plezy_inc_sync_data_');
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

  test('1. Zero-churn idle reconnect and 1-item watch progress delta without re-applying 80+ files', () async {
    final pc = _SyncPeerNode('PC');
    final android = _SyncPeerNode('Android');
    addTearDown(pc.dispose);
    addTearDown(android.dispose);

    await pc.initLan();
    await android.initLan();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_dav',
        kind: StorageKind.webdav,
        displayName: 'Home NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.50/dav'},
      ),
    );
    for (var i = 1; i <= 85; i++) {
      await _seedMovie(
        pc,
        mountId: 'm_dav',
        tmdbId: '${700000 + i}',
        title: 'Film $i',
        filePath: '/Movies/Film_$i.mkv',
      );
    }

    await pc.pairWith(android);
    await android.sync.lanService.syncWithAllTrustedPeers();
    expect((await android.db.select(android.db.libraryItems).get()).length, 85);

    // Idle rediscovery must execute 0 HTTP requests and 0 applying updates.
    final applyingEventsIdle = <SyncProgress>[];
    android.sync.addListener(() {
      if (android.sync.progress.phase == SyncPhase.applying) {
        applyingEventsIdle.add(android.sync.progress);
      }
    });
    final reqCountAfterInitial = android.sync.lanService.debugSyncHttpRequestCount;
    final pcRev1 = await pc.sync.syncStore.getLocalLanRevision();
    final pcEpoch = await pc.sync.syncStore.getOrCreateSyncEpoch();
    android.sync.lanService.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: pc.sync.lanService.deviceId!,
        deviceName: pc.name,
        platform: 'windows',
        host: '127.0.0.1',
        httpPort: pc.sync.lanService.listeningPort!,
        pubKeyBase64: pc.sync.lanService.publicKeyBase64!,
        revision: pcRev1,
        lastSeen: clock.now(),
        syncEpoch: pcEpoch,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(android.sync.lanService.debugSyncHttpRequestCount, reqCountAfterInitial);
    expect(applyingEventsIdle, isEmpty);

    // Update 1 movie's watch progress on PC -> Android must receive ONLY 1 item (NOT 85 files).
    final applyingTotals = <int>[];
    void trackApplying() {
      if (android.sync.progress.phase == SyncPhase.applying && android.sync.progress.total > 0) {
        applyingTotals.add(android.sync.progress.total);
      }
    }

    android.sync.addListener(trackApplying);
    final firstMovie = (await pc.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '700001'))!;
    await pc.client.reportPlaybackStopped(
      itemId: '${firstMovie.id}',
      position: const Duration(minutes: 15),
      duration: const Duration(minutes: 90),
    );
    await pc.sync.onPlaybackOutboxQueued();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await android.sync.lanService.syncWithAllTrustedPeers();
    android.sync.removeListener(trackApplying);

    expect(applyingTotals, isNotEmpty);
    expect(applyingTotals.last, 1);

    final androidMovie1 = (await android.repo.getItem(
      (await android.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '700001'))!.id,
    ))!;
    expect(androidMovie1.state?.positionMs, 900000);

    // Next idle discovery check stays at 0 HTTP requests.
    final reqCountAfterDelta = android.sync.lanService.debugSyncHttpRequestCount;
    final pcRev2 = await pc.sync.syncStore.getLocalLanRevision();
    android.sync.lanService.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: pc.sync.lanService.deviceId!,
        deviceName: pc.name,
        platform: 'windows',
        host: '127.0.0.1',
        httpPort: pc.sync.lanService.listeningPort!,
        pubKeyBase64: pc.sync.lanService.publicKeyBase64!,
        revision: pcRev2,
        lastSeen: clock.now(),
        syncEpoch: pcEpoch,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(android.sync.lanService.debugSyncHttpRequestCount, reqCountAfterDelta);
  });

  test('2. Concurrent partial increments on A & B converge via single-direction LAN sync and Cloud seq delta', () async {
    final serverUrl = await startSyncServer();
    final a = _SyncPeerNode('Device-A');
    final b = _SyncPeerNode('Device-B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.initLan();
    await b.initLan();
    const mount = StorageMount(
      id: 'm_shared',
      kind: StorageKind.webdav,
      displayName: 'Shared',
      config: {MountKeys.baseUrl: 'http://192.168.1.9/dav'},
    );
    await a.registry.upsert(mount);
    final ep1 = await _seedEpisode(
      a,
      mountId: 'm_shared',
      showTmdbId: '10001',
      showTitle: 'Test Show',
      episodeNumber: 1,
      filePath: '/Show/S01E01.mkv',
    );
    final movieA = await _seedMovie(
      a,
      mountId: 'm_shared',
      tmdbId: '20001',
      title: 'Shared Film',
      filePath: '/Movies/Shared.mkv',
    );

    await a.pairWith(b);
    await b.sync.lanService.syncWithAllTrustedPeers();
    expect(await b.repo.episodesOfShow((await b.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!.id), hasLength(1));

    // Concurrent changes offline from each other:
    // A adds Ep 2 and marks Ep 1 watched.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await _seedEpisode(
      a,
      mountId: 'm_shared',
      showTmdbId: '10001',
      showTitle: 'Test Show',
      episodeNumber: 2,
      filePath: '/Show/S01E02.mkv',
      updatedAt: 2000,
    );
    await a.client.markWatched(MediaItem.jellyfin(id: '${ep1.epId}', kind: MediaKind.episode, title: 'Episode 1'));
    await a.sync.onCatalogChanged(mountIds: {'m_shared'}, allowTombstones: false);

    // B adds Ep 3 and favorites Shared Film.
    await _seedEpisode(
      b,
      mountId: 'm_shared',
      showTmdbId: '10001',
      showTitle: 'Test Show',
      episodeNumber: 3,
      filePath: '/Show/S01E03.mkv',
      updatedAt: 2000,
    );
    final bFilm = (await b.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '20001'))!;
    await b.client.setFavorite(MediaItem.jellyfin(id: '${bFilm.id}', kind: MediaKind.movie, title: 'Shared Film'), true);
    await b.sync.onCatalogChanged(mountIds: {'m_shared'}, allowTombstones: false);

    // Single-direction A.syncWithPeer(B) must Pull B's increments AND Push A's increments!
    final trustedBOnA = a.sync.lanService.trustedPeers.singleWhere((p) => p.deviceId == b.sync.lanService.deviceId);
    await a.sync.lanService.syncWithPeer(trustedBOnA, hostOverride: '127.0.0.1', portOverride: b.sync.lanService.listeningPort);

    final aShow = (await a.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!;
    final bShow = (await b.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!;
    expect((await a.repo.episodesOfShow(aShow.id)).map((e) => e.item.episodeNumber).toSet(), {1, 2, 3});
    expect((await b.repo.episodesOfShow(bShow.id)).map((e) => e.item.episodeNumber).toSet(), {1, 2, 3});
    expect((await a.repo.getItem(movieA.itemId))!.state?.favorite, isTrue);
    expect((await b.repo.episodesOfShow(bShow.id)).firstWhere((e) => e.item.episodeNumber == 1).isWatched, isTrue);

    // Also verify Cloud server incremental push only advances seq for actual deltas:
    await a.sync.register(serverUrl: serverUrl, username: 'incuser', password: 'pw', kdfParams: fastKdf);
    await b.sync.loginWithPassword(serverUrl: serverUrl, username: 'incuser', password: 'pw');
    final baselineCloudSeq = await b.sync.syncStore.getLastPullSeq();

    await _seedMovie(
      a,
      mountId: 'm_shared',
      tmdbId: '20099',
      title: 'Cloud Delta Movie',
      filePath: '/Movies/CloudDelta.mkv',
      updatedAt: 5000,
    );
    await a.sync.onCatalogChanged(mountIds: {'m_shared'}, allowTombstones: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await b.sync.syncNow();
    final afterCloudSeq = await b.sync.syncStore.getLastPullSeq();
    // Only 1 work + 1 file = 2 seqs, NOT all baseline entities!
    expect(afterCloudSeq - baselineCloudSeq, 2);
  });

  test('3. Offline duplicate mount merges sync_journal so unique files on B sync back to A', () async {
    final a = _SyncPeerNode('Phone-A');
    final b = _SyncPeerNode('TV-B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.initLan();
    await b.initLan();

    await a.registry.upsert(
      StorageMount(
        id: 'uuid-A',
        kind: StorageKind.quark,
        displayName: 'Quark A',
        config: const {MountKeys.rootFolderId: '0'},
        secrets: const {MountKeys.secretCookie: 'uid=444555; __pus=a'},
        createdAt: DateTime.utc(2026, 11, 16, 8, 0, 0),
      ),
    );
    await _seedMovie(a, mountId: 'uuid-A', tmdbId: '27205', title: '盗梦空间', filePath: '/Movies/Inception.mkv');
    await a.sync.mapper.ensureJournalUpToDate();

    await b.registry.upsert(
      StorageMount(
        id: 'uuid-B',
        kind: StorageKind.quark,
        displayName: 'Quark B',
        config: const {MountKeys.rootFolderId: '0'},
        secrets: const {MountKeys.secretCookie: 'uid=444555; __pus=b'},
        createdAt: DateTime.utc(2026, 11, 16, 9, 0, 0),
      ),
    );
    await _seedMovie(b, mountId: 'uuid-B', tmdbId: '157336', title: '星际穿越', filePath: '/Movies/Interstellar.mkv');
    await b.sync.mapper.ensureJournalUpToDate();

    await a.pairWith(b);
    await a.sync.lanService.syncWithAllTrustedPeers();

    expect((await a.registry.list()).single.id, 'uuid-A');
    expect((await b.registry.list()).single.id, 'uuid-A');
    final aMovies = (await a.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title).toSet();
    final bMovies = (await b.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title).toSet();
    expect(aMovies, {'盗梦空间', '星际穿越'});
    expect(bMovies, {'盗梦空间', '星际穿越'});
  });

  test('4. Scoped directory refresh preserves untouched directories while deleting removed file via tombstone', () async {
    final pc = _SyncPeerNode('PC');
    final phone = _SyncPeerNode('Phone');
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);

    await pc.initLan();
    await phone.initLan();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_scoped',
        kind: StorageKind.webdav,
        displayName: 'Scoped DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.33/dav'},
      ),
    );
    final ep1 = await _seedEpisode(
      pc,
      mountId: 'm_scoped',
      showTmdbId: '30001',
      showTitle: 'Scoped Show',
      episodeNumber: 1,
      filePath: '/ShowA/Season 1/S01E01.mkv',
    );
    await _seedEpisode(
      pc,
      mountId: 'm_scoped',
      showTmdbId: '30001',
      showTitle: 'Scoped Show',
      episodeNumber: 2,
      filePath: '/ShowA/Season 1/S01E02.mkv',
    );
    await _seedMovie(pc, mountId: 'm_scoped', tmdbId: '40001', title: 'Untouched Film', filePath: '/Movies/Film1.mkv');

    await pc.pairWith(phone);
    await phone.sync.lanService.syncWithAllTrustedPeers();

    // Remove ONLY S01E01 from DB and run scoped directory reconcile on /ShowA/Season 1.
    await (pc.db.delete(pc.db.libraryFiles)..where((t) => t.id.equals(ep1.fileId))).go();
    await pc.repo.pruneEmptyTitles();
    await pc.sync.onCatalogChanged(mountIds: {'m_scoped'}, directoryPrefixes: {'/ShowA/Season 1'}, allowTombstones: true);
    await phone.sync.lanService.syncWithAllTrustedPeers();

    final phoneShow = (await phone.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '30001'))!;
    final phoneEps = await phone.repo.episodesOfShow(phoneShow.id);
    expect(phoneEps.map((e) => e.item.episodeNumber).toList(), [2]);
    expect(await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '40001'), isNotNull);
  });

  test('5. Provisional raw work upgrade to matched TMDB tombstones old raw work and protects Level 4 lock', () async {
    final a = _SyncPeerNode('PC');
    final b = _SyncPeerNode('Phone');
    final c = _SyncPeerNode('LateTV');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    addTearDown(c.dispose);

    await a.initLan();
    await b.initLan();
    await c.initLan();

    await a.registry.upsert(
      const StorageMount(
        id: 'm_raw',
        kind: StorageKind.webdav,
        displayName: 'Raw DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.44/dav'},
      ),
    );
    final rawMovieId = await a.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.pending,
        title: 'Unknown Film',
        sortTitle: 'unknown film',
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    final rawFileId = await a.repo.upsertFile(
      mountId: 'm_raw',
      path: '/Movies/UnknownFilm.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 123456,
      modifiedAt: 1000,
    );
    await a.repo.linkFile(rawFileId, rawMovieId);

    await a.pairWith(b);
    await b.sync.lanService.syncWithAllTrustedPeers();
    expect((await b.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, hasLength(1));

    // A scrapes Unknown Film -> TMDB 27205 (Level 3 matched).
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.repo.updateItem(
      rawMovieId,
      const LibraryItemsCompanion(
        libraryType: Value(LibraryTypes.movie),
        title: Value('Inception'),
        sortTitle: Value('inception'),
        tmdbId: Value('27205'),
        metadataSource: Value('tmdb'),
        scrapedAt: Value(2000),
        updatedAt: Value(2000),
      ),
    );
    await a.repo.updateFile(rawFileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
    await a.sync.onCatalogChanged(mountIds: {'m_raw'}, allowTombstones: false);

    await b.sync.lanService.syncWithAllTrustedPeers();
    expect((await b.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);

    // Old raw:* entry in sync_journal must be tombstoned, so LateTV joining fresh gets 0 ghost raw items.
    await a.pairWith(c);
    await c.sync.lanService.syncWithAllTrustedPeers();
    expect((await c.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);
    expect((await c.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title), ['Inception']);

    // Level 4 lock on B rejects an older/unmatched overwrite attempt.
    final bMovie = (await b.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '27205'))!;
    await b.repo.updateItem(bMovie.id, const LibraryItemsCompanion(locked: Value(true), metadataSource: Value('nfo')));
    await b.sync.mapper.applyPullBatch(
      masterKey: b.sync.lanService.trustedPeers.single.sharedKey,
      sources: const [],
      works: [
        {
          'work_key': 'tmdb:movie:27205',
          'kind': LibraryKinds.movie,
          'library_type': LibraryTypes.movie,
          'provider': 'tmdb',
          'external_id': '27205',
          'match_status': MatchStatusRank.matched,
          'metadata_json': {'title': 'Stale Override', 'tmdb_id': '27205'},
          'client_updated_at': 9999999,
          'is_deleted': false,
        },
      ],
      files: const [],
      workPrefs: const [],
      watchProgress: const [],
      userSettings: const {},
      nextSeq: 0,
      updateCloudCursor: false,
    );
    expect((await b.repo.getItem(bMovie.id))!.item.title, 'Inception');
  });

  test('6. 3-device mesh (PC -> Phone -> TV) works offline and restores wiped PC completely', () async {
    final pc = _SyncPeerNode('PC');
    final phone = _SyncPeerNode('Phone');
    final tv = _SyncPeerNode('TV');
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);
    addTearDown(tv.dispose);

    await pc.initLan();
    await phone.initLan();
    await tv.initLan();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_mesh',
        kind: StorageKind.webdav,
        displayName: 'Mesh DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.60/dav'},
      ),
    );
    await _seedMovie(pc, mountId: 'm_mesh', tmdbId: '603', title: 'The Matrix', filePath: '/Movies/Matrix.mkv');

    await pc.pairWith(phone);
    await phone.sync.lanService.syncWithAllTrustedPeers();
    expect((await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603')), isNotNull);

    // Pair Phone <-> TV, stop PC, and verify TV pulls PC's movie via Phone!
    final savedPcDeviceId = pc.sync.lanService.deviceId!;
    await pc.dispose();

    await phone.pairWith(tv);
    await tv.sync.lanService.syncWithAllTrustedPeers();
    expect((await tv.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603')), isNotNull);

    // Normal incremental sync check from same origin epoch has 0 echo items back to origin.
    final deltaSameEpoch = await phone.sync.mapper.buildDeltaBundle(
      encryptionKey: phone.sync.lanService.trustedPeers.first.sharedKey,
      sinceSeq: 1,
      limit: 500,
      skipOriginDeviceId: savedPcDeviceId,
      skipOriginEpoch: phone.sync.lanService.trustedPeers.firstWhere((p) => p.deviceId == savedPcDeviceId).lastSyncedEpoch,
    );
    expect(deltaSameEpoch.works, isEmpty);
    expect(deltaSameEpoch.files, isEmpty);

    // Simulate PC DB wipe & reinstall (brand-new DB, reusing savedPcDeviceId -> new sync_epoch, since_seq=0).
    final wipedPc = _SyncPeerNode('PC-Reinstalled');
    addTearDown(wipedPc.dispose);
    await wipedPc.sync.db
        .into(wipedPc.sync.db.syncMetadata)
        .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: 'device_id', value: savedPcDeviceId));
    await wipedPc.initLan();
    // Re-pair reinstalled PC with Phone and verify Phone restores 100% of items!
    await phone.pairWith(wipedPc);
    await wipedPc.sync.lanService.syncWithAllTrustedPeers();
    expect(await wipedPc.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603'), isNotNull);
  });

  test('7. Clock-skew HLC ensures normal-clock Phone progress beats skewed PC and preserves movie favorite', () async {
    final pc = _SyncPeerNode('Skewed-PC');
    final phone = _SyncPeerNode('Normal-Phone');
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);

    await pc.initLan();
    await phone.initLan();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_hlc',
        kind: StorageKind.webdav,
        displayName: 'HLC DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.70/dav'},
      ),
    );
    final movie = await _seedMovie(pc, mountId: 'm_hlc', tmdbId: '155', title: 'Dark Knight', filePath: '/Movies/TDK.mkv');

    // Simulate PC clock +5 minutes in the future when favoriting and watching to 10:00.
    final futureTime = clock.now().add(const Duration(minutes: 5));
    await withClock(Clock.fixed(futureTime), () async {
      await pc.client.setFavorite(
        MediaItem.jellyfin(id: '${movie.itemId}', kind: MediaKind.movie, title: 'Dark Knight'),
        true,
      );
      await pc.client.reportPlaybackStopped(
        itemId: '${movie.itemId}',
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 120),
      );
      await pc.sync.onPlaybackOutboxQueued();
    });

    await pc.pairWith(phone);
    await phone.sync.lanService.syncWithAllTrustedPeers();
    final phoneMovie = (await phone.repo.getItem((await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '155'))!.id))!;
    expect(phoneMovie.state?.favorite, isTrue);
    expect(phoneMovie.state?.positionMs, 600000);

    // Phone plays with normal clock (`now`, which is 5 minutes behind PC's skewed timestamp) to 30:00.
    await phone.client.reportPlaybackStopped(
      itemId: '${phoneMovie.item.id}',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 120),
    );
    await phone.sync.onPlaybackOutboxQueued();
    await pc.sync.lanService.syncWithAllTrustedPeers();

    final pcMovieAfter = (await pc.repo.getItem(movie.itemId))!;
    expect(pcMovieAfter.state?.positionMs, 1800000);
    expect(pcMovieAfter.state?.favorite, isTrue);

    final phoneMovieAfter = (await phone.repo.getItem(phoneMovie.item.id))!;
    expect(phoneMovieAfter.state?.positionMs, 1800000);
    expect(phoneMovieAfter.state?.favorite, isTrue);
  });

  test('8. Mid-sync page checkpointing persists page 1 cursor and resumes from page 2 after interruption', () async {
    final sender = _SyncPeerNode('Big-PC');
    final receiver = _SyncPeerNode('Phone');
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    await sender.initLan();
    await receiver.initLan();

    await sender.registry.upsert(
      const StorageMount(
        id: 'm_big',
        kind: StorageKind.webdav,
        displayName: 'Big DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.80/dav'},
      ),
    );
    sender.sync.lanService.syncPageLimit = 250;
    receiver.sync.lanService.syncPageLimit = 250;

    await sender.pairWith(receiver);
    // Wait for initial pair sync (only m_big source) to settle, then seed 260 movies offline.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await receiver.sync.lanService.syncWithAllTrustedPeers();

    // 260 movies -> 260 works + 260 files = 520 new seqs -> 3 pages at limit=250.
    for (var i = 1; i <= 260; i++) {
      await _seedMovie(
        sender,
        mountId: 'm_big',
        tmdbId: '${910000 + i}',
        title: 'Big Film $i',
        filePath: '/Movies/Big_$i.mkv',
      );
    }
    await sender.sync.mapper.ensureJournalUpToDate();
    final senderMaxSeq = await sender.sync.syncStore.getLocalLanRevision();
    expect(senderMaxSeq, greaterThan(500));

    // Simulate interruption right after Page 1 commits!
    var interrupted = false;
    receiver.sync.lanService.debugOnPullPageCommitted = (pageIndex, nextSeq) {
      if (pageIndex == 1 && !interrupted) {
        interrupted = true;
        throw const HttpException('simulated drop after page 1');
      }
    };

    await expectLater(
      receiver.sync.lanService.syncWithPeer(receiver.sync.lanService.trustedPeers.single, notifyBack: false),
      throwsA(isA<HttpException>()),
    );
    final checkpointRev = receiver.sync.lanService.trustedPeers.single.lastSyncedRevision;
    expect(checkpointRev, greaterThan(0));
    expect(checkpointRev, lessThan(senderMaxSeq));
    final countAfterPage1 = (await receiver.db.select(receiver.db.libraryItems).get()).length;
    expect(countAfterPage1, greaterThan(0));
    expect(countAfterPage1, lessThan(260));

    // Reconnect and resume: must resume from checkpointRev rather than 0, finishing all 260 items.
    receiver.sync.lanService.debugOnPullPageCommitted = null;
    await receiver.sync.lanService.syncWithAllTrustedPeers();
    expect(receiver.sync.lanService.trustedPeers.single.lastSyncedRevision, senderMaxSeq);
    expect((await receiver.db.select(receiver.db.libraryItems).get()).length, 260);
  });
}
