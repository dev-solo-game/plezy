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
import 'package:plezy/library/sync/library_workspace_store.dart';
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
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) => _NoScanMockDriver(mount.kind),
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
    scans.onScopedCatalogChanged = (mountIds, {directoryPrefixes, allowTombstones = true}) => unawaited(
      sync.onCatalogChanged(mountIds: mountIds, directoryPrefixes: directoryPrefixes, allowTombstones: allowTombstones),
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

  Future<void> initLocal() async {
    await sync.initialize();
    await sync.syncStore.setDeviceName(name);
    await sync.selectLocalMode();
  }

  Future<void> waitIdle() async {
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> drainAndSyncNow() async {
    await waitIdle();
    await sync.syncNow(allowBackgroundScan: false);
    await waitIdle();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await waitIdle();
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
  ))!.item;

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
    LibraryFilesCompanion(matchState: const Value(LibraryMatchStates.matched), matchLocked: Value(locked)),
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

  test('1. Zero-churn idle sync and 1-item watch progress delta without re-applying 80+ files', () async {
    final serverUrl = await startSyncServer();
    final pc = _SyncPeerNode('PC');
    final android = _SyncPeerNode('Android');
    addTearDown(pc.dispose);
    addTearDown(android.dispose);

    await pc.initLocal();
    await android.initLocal();

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

    await pc.sync.register(serverUrl: serverUrl, username: 'inc1', password: 'pw', kdfParams: fastKdf);
    await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'inc1', password: 'pw');
    expect((await android.db.select(android.db.libraryItems).get()).length, 85);
    final seqAfterInitial = await android.sync.syncStore.getLastPullSeq();

    // Idle syncNow must advance 0 seqs and trigger 0 applying updates.
    final applyingEventsIdle = <SyncProgress>[];
    void trackIdleApplying() {
      if (android.sync.progress.phase == SyncPhase.applying) {
        applyingEventsIdle.add(android.sync.progress);
      }
    }

    android.sync.addListener(trackIdleApplying);
    await android.sync.syncNow(allowBackgroundScan: false);
    android.sync.removeListener(trackIdleApplying);
    expect(applyingEventsIdle, isEmpty);
    expect(await android.sync.syncStore.getLastPullSeq(), seqAfterInitial);

    // Update 1 movie's watch progress on PC -> Android must receive ONLY 1 item (NOT 85 files).
    final applyingTotals = <int>[];
    void trackApplying() {
      if (android.sync.progress.phase == SyncPhase.applying && android.sync.progress.total > 0) {
        applyingTotals.add(android.sync.progress.total);
      }
    }

    final firstMovie = (await pc.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '700001'))!;
    await pc.client.reportPlaybackStopped(
      itemId: '${firstMovie.id}',
      position: const Duration(minutes: 15),
      duration: const Duration(minutes: 90),
    );
    await pc.sync.onPlaybackOutboxQueued();
    await pc.drainAndSyncNow();

    android.sync.addListener(trackApplying);
    await android.drainAndSyncNow();
    android.sync.removeListener(trackApplying);

    expect(applyingTotals, isNotEmpty);
    expect(applyingTotals.last, 1);

    final androidMovie1 = (await android.repo.getItem(
      (await android.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '700001'))!.id,
    ))!;
    expect(androidMovie1.state?.positionMs, 900000);
    expect(await android.sync.syncStore.getLastPullSeq(), seqAfterInitial + 1);

    // Next idle syncNow stays at exact same seq with 0 churn.
    await android.sync.syncNow(allowBackgroundScan: false);
    expect(await android.sync.syncStore.getLastPullSeq(), seqAfterInitial + 1);
  });

  test('2. Concurrent partial increments on A & B converge via Cloud seq delta', () async {
    final serverUrl = await startSyncServer();
    final a = _SyncPeerNode('Device-A');
    final b = _SyncPeerNode('Device-B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.initLocal();
    await b.initLocal();
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

    await a.sync.register(serverUrl: serverUrl, username: 'incuser', password: 'pw', kdfParams: fastKdf);
    await b.sync.loginWithPassword(serverUrl: serverUrl, username: 'incuser', password: 'pw');
    expect(
      await b.repo.episodesOfShow((await b.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!.id),
      hasLength(1),
    );

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
    await a.drainAndSyncNow();

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
    await b.client.setFavorite(
      MediaItem.jellyfin(id: '${bFilm.id}', kind: MediaKind.movie, title: 'Shared Film'),
      true,
    );
    await b.sync.onCatalogChanged(mountIds: {'m_shared'}, allowTombstones: false);

    await b.drainAndSyncNow();
    await a.drainAndSyncNow();
    await b.drainAndSyncNow();

    final aShow = (await a.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!;
    final bShow = (await b.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '10001'))!;
    expect((await a.repo.episodesOfShow(aShow.id)).map((e) => e.item.episodeNumber).toSet(), {1, 2, 3});
    expect((await b.repo.episodesOfShow(bShow.id)).map((e) => e.item.episodeNumber).toSet(), {1, 2, 3});
    expect((await a.repo.getItem(movieA.itemId))!.state?.favorite, isTrue);
    expect((await b.repo.episodesOfShow(bShow.id)).firstWhere((e) => e.item.episodeNumber == 1).isWatched, isTrue);

    // Also verify Cloud server incremental push only advances seq for actual deltas:
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
    await a.drainAndSyncNow();
    await b.drainAndSyncNow();
    final afterCloudSeq = await b.sync.syncStore.getLastPullSeq();
    // Only 1 work + 1 file = 2 seqs, NOT all baseline entities!
    expect(afterCloudSeq - baselineCloudSeq, 2);
  });

  test('3. Offline duplicate mount merges sync_journal so unique files on B sync back to A', () async {
    final serverUrl = await startSyncServer();
    final a = _SyncPeerNode('Phone-A');
    final b = _SyncPeerNode('TV-B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.initLocal();
    await b.initLocal();

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

    await a.sync.register(serverUrl: serverUrl, username: 'dup3', password: 'pw', kdfParams: fastKdf);
    await b.sync.loginWithPassword(serverUrl: serverUrl, username: 'dup3', password: 'pw');
    await b.sync.syncNow(allowBackgroundScan: false);
    await a.sync.syncNow(allowBackgroundScan: false);

    expect((await a.registry.list()).single.id, 'uuid-A');
    expect((await b.registry.list()).single.id, 'uuid-A');
    final aMovies = (await a.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toSet();
    final bMovies = (await b.repo.queryTitles(
      const LibraryQuery(libraryType: LibraryTypes.movie),
    )).items.map((v) => v.item.title).toSet();
    expect(aMovies, {'盗梦空间', '星际穿越'});
    expect(bMovies, {'盗梦空间', '星际穿越'});
  });

  test(
    '4. Scoped directory refresh preserves untouched directories while deleting removed file via tombstone',
    () async {
      final serverUrl = await startSyncServer();
      final pc = _SyncPeerNode('PC');
      final phone = _SyncPeerNode('Phone');
      addTearDown(pc.dispose);
      addTearDown(phone.dispose);

      await pc.initLocal();
      await phone.initLocal();

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
      await _seedMovie(
        pc,
        mountId: 'm_scoped',
        tmdbId: '40001',
        title: 'Untouched Film',
        filePath: '/Movies/Film1.mkv',
      );

      await pc.sync.register(serverUrl: serverUrl, username: 'scoped4', password: 'pw', kdfParams: fastKdf);
      await phone.sync.loginWithPassword(serverUrl: serverUrl, username: 'scoped4', password: 'pw');

      // Remove ONLY S01E01 from DB and run scoped directory reconcile on /ShowA/Season 1.
      await (pc.db.delete(pc.db.libraryFiles)..where((t) => t.id.equals(ep1.fileId))).go();
      await pc.repo.pruneEmptyTitles();
      await pc.sync.onCatalogChanged(
        mountIds: {'m_scoped'},
        directoryPrefixes: {'/ShowA/Season 1'},
        allowTombstones: true,
      );
      await pc.sync.syncNow(allowBackgroundScan: false);
      await phone.sync.syncNow(allowBackgroundScan: false);

      final phoneShow = (await phone.repo.findByExternalId(kind: LibraryKinds.show, tmdbId: '30001'))!;
      final phoneEps = await phone.repo.episodesOfShow(phoneShow.id);
      expect(phoneEps.map((e) => e.item.episodeNumber).toList(), [2]);
      expect(await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '40001'), isNotNull);
    },
  );

  test('5. Provisional raw work upgrade to matched TMDB tombstones old raw work and protects Level 4 lock', () async {
    final serverUrl = await startSyncServer();
    final a = _SyncPeerNode('PC');
    final b = _SyncPeerNode('Phone');
    final c = _SyncPeerNode('LateTV');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    addTearDown(c.dispose);

    await a.initLocal();
    await b.initLocal();
    await c.initLocal();

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

    await a.sync.register(serverUrl: serverUrl, username: 'raw5', password: 'pw', kdfParams: fastKdf);
    await b.sync.loginWithPassword(serverUrl: serverUrl, username: 'raw5', password: 'pw');
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
    await a.drainAndSyncNow();

    await b.drainAndSyncNow();
    expect((await b.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);

    // Old raw:* entry in sync_journal must be tombstoned, so LateTV joining fresh gets 0 ghost raw items.
    await c.sync.loginWithPassword(serverUrl: serverUrl, username: 'raw5', password: 'pw');
    expect((await c.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);
    expect(
      (await c.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.map((v) => v.item.title),
      ['Inception'],
    );

    // Level 4 lock on B rejects an older/unmatched overwrite attempt.
    final bMovie = (await b.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '27205'))!;
    await b.repo.updateItem(bMovie.id, const LibraryItemsCompanion(locked: Value(true), metadataSource: Value('nfo')));
    await b.sync.mapper.applyPullBatch(
      masterKey: (await b.sync.syncStore.loadSession())!.masterKey,
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

  test('6. 3-device Cloud sync works across devices and restores wiped PC completely', () async {
    final serverUrl = await startSyncServer();
    final pc = _SyncPeerNode('PC');
    final phone = _SyncPeerNode('Phone');
    final tv = _SyncPeerNode('TV');
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);
    addTearDown(tv.dispose);

    await pc.initLocal();
    await phone.initLocal();
    await tv.initLocal();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_mesh',
        kind: StorageKind.webdav,
        displayName: 'Mesh DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.60/dav'},
      ),
    );
    await _seedMovie(pc, mountId: 'm_mesh', tmdbId: '603', title: 'The Matrix', filePath: '/Movies/Matrix.mkv');

    await pc.sync.register(serverUrl: serverUrl, username: 'meshuser', password: 'pw', kdfParams: fastKdf);
    await phone.sync.loginWithPassword(serverUrl: serverUrl, username: 'meshuser', password: 'pw');
    expect((await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603')), isNotNull);

    // Stop PC, login TV while PC is offline, and verify TV pulls PC's movie from Cloud!
    final savedPcDeviceId = await pc.sync.syncStore.getOrCreateDeviceId();
    await pc.dispose();

    await tv.sync.loginWithPassword(serverUrl: serverUrl, username: 'meshuser', password: 'pw');
    expect((await tv.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603')), isNotNull);

    // Normal incremental sync check from local cursor has 0 echo items.
    final deltaSameEpoch = await phone.sync.mapper.buildDeltaBundle(
      encryptionKey: (await phone.sync.syncStore.loadSession())!.masterKey,
      sinceSeq: await phone.sync.syncStore.getLocalLanRevision(),
      limit: 500,
    );
    expect(deltaSameEpoch.works, isEmpty);
    expect(deltaSameEpoch.files, isEmpty);

    // Simulate PC DB wipe & reinstall (brand-new DB, reusing savedPcDeviceId -> accountOnly restore).
    final wipedPc = _SyncPeerNode('PC-Reinstalled');
    addTearDown(wipedPc.dispose);
    await wipedPc.sync.db
        .into(wipedPc.sync.db.syncMetadata)
        .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: 'device_id', value: savedPcDeviceId));
    await wipedPc.initLocal();
    await wipedPc.sync.loginWithPassword(
      serverUrl: serverUrl,
      username: 'meshuser',
      password: 'pw',
      mergePolicy: LocalMergePolicy.accountOnly,
    );
    expect(await wipedPc.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '603'), isNotNull);
  });

  test('7. Clock-skew HLC ensures normal-clock Phone progress beats skewed PC and preserves movie favorite', () async {
    final serverUrl = await startSyncServer();
    final pc = _SyncPeerNode('Skewed-PC');
    final phone = _SyncPeerNode('Normal-Phone');
    addTearDown(pc.dispose);
    addTearDown(phone.dispose);

    await pc.initLocal();
    await phone.initLocal();

    await pc.registry.upsert(
      const StorageMount(
        id: 'm_hlc',
        kind: StorageKind.webdav,
        displayName: 'HLC DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.70/dav'},
      ),
    );
    final movie = await _seedMovie(
      pc,
      mountId: 'm_hlc',
      tmdbId: '155',
      title: 'Dark Knight',
      filePath: '/Movies/TDK.mkv',
    );

    // Simulate PC clock +5 minutes in the future while offline when favoriting and watching to 10:00.
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

    await pc.sync.register(serverUrl: serverUrl, username: 'hlcuser', password: 'pw', kdfParams: fastKdf);
    await phone.sync.loginWithPassword(serverUrl: serverUrl, username: 'hlcuser', password: 'pw');
    final phoneMovie = (await phone.repo.getItem(
      (await phone.repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '155'))!.id,
    ))!;
    expect(phoneMovie.state?.favorite, isTrue);
    expect(phoneMovie.state?.positionMs, 600000);

    // Phone plays with normal clock (`now`, which is 5 minutes behind PC's skewed timestamp) to 30:00.
    await phone.client.reportPlaybackStopped(
      itemId: '${phoneMovie.item.id}',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 120),
    );
    await phone.sync.onPlaybackOutboxQueued();
    await phone.drainAndSyncNow();
    await pc.drainAndSyncNow();

    final pcMovieAfter = (await pc.repo.getItem(movie.itemId))!;
    expect(pcMovieAfter.state?.positionMs, 1800000);
    expect(pcMovieAfter.state?.favorite, isTrue);

    final phoneMovieAfter = (await phone.repo.getItem(phoneMovie.item.id))!;
    expect(phoneMovieAfter.state?.positionMs, 1800000);
    expect(phoneMovieAfter.state?.favorite, isTrue);
  });

  test('8. Mid-sync page checkpointing persists page 1 cursor and resumes from page 2 after interruption', () async {
    final serverUrl = await startSyncServer();
    final sender = _SyncPeerNode('Big-PC');
    final receiver = _SyncPeerNode('Phone');
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);

    await sender.initLocal();
    await receiver.initLocal();

    await sender.registry.upsert(
      const StorageMount(
        id: 'm_big',
        kind: StorageKind.webdav,
        displayName: 'Big DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.80/dav'},
      ),
    );

    await sender.sync.register(serverUrl: serverUrl, username: 'pageuser', password: 'pw', kdfParams: fastKdf);
    await receiver.sync.loginWithPassword(serverUrl: serverUrl, username: 'pageuser', password: 'pw');

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
    await sender.sync.onCatalogChanged(mountIds: {'m_big'}, allowTombstones: false);
    await sender.drainAndSyncNow();

    // Simulate interruption right after Page 1 commits on receiver!
    final sess = (await receiver.sync.syncStore.loadSession())!;
    final page1 = await receiver.sync.apiClient.pullDelta(
      sess.serverUrl,
      sess.accessToken,
      sinceSeq: await receiver.sync.syncStore.getLastPullSeq(),
      limit: 250,
    );
    expect(page1.hasMore, isTrue);
    await receiver.sync.mapper.applyPullBatch(
      masterKey: sess.masterKey,
      sources: page1.sources,
      works: page1.works,
      files: page1.files,
      workPrefs: page1.workPrefs,
      watchProgress: page1.watchProgress,
      lists: page1.lists,
      userSettings: page1.userSettings,
      nextSeq: page1.nextSeq,
      isFinalPage: false,
    );

    final checkpointSeq = await receiver.sync.syncStore.getLastPullSeq();
    expect(checkpointSeq, page1.nextSeq);
    expect(checkpointSeq, greaterThan(0));
    final countAfterPage1 = (await receiver.db.select(receiver.db.libraryItems).get()).length;
    expect(countAfterPage1, greaterThan(0));
    expect(countAfterPage1, lessThan(260));

    // Reconnect and resume: must resume from checkpointSeq rather than 0, finishing all 260 items.
    await receiver.sync.syncNow(allowBackgroundScan: false);
    expect(await receiver.sync.syncStore.getLastPullSeq(), greaterThan(checkpointSeq));
    expect((await receiver.db.select(receiver.db.libraryItems).get()).length, 260);
  });
}
