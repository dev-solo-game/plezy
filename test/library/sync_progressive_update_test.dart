import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/sync/deterministic_keys.dart';
import 'package:plezy/library/sync/lan_peer_sync_service.dart';
import 'package:plezy/library/sync/sync_api_client.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/library/sync/sync_mapper.dart';
import 'package:plezy/library/sync/sync_models.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _GatedProbeDriver implements StorageDriver {
  _GatedProbeDriver(this.kind, {this.onCheckEntered, this.checkGate});

  @override
  final StorageKind kind;
  final void Function()? onCheckEntered;
  final Future<void>? checkGate;

  @override
  Future<void> check() async {
    onCheckEntered?.call();
    if (checkGate != null) {
      await checkGate!;
    }
  }

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: false, size: 0);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _FakeSyncApiClient extends SyncApiClient {
  _FakeSyncApiClient(this.pullResult);

  final SyncPullResult pullResult;
  bool pulled = false;

  @override
  Future<SyncPullResult> pullDelta(String serverUrl, String accessToken, {int sinceSeq = 0, int limit = 500}) async {
    if (!pulled) {
      pulled = true;
      return pullResult;
    }
    return SyncPullResult(
      serverTimeMs: pullResult.serverTimeMs,
      currentMaxSeq: pullResult.currentMaxSeq,
      nextSeq: pullResult.nextSeq,
      hasMore: false,
      resetRequired: false,
      userSettings: const {},
      sources: const [],
      works: const [],
      files: const [],
      workPrefs: const [],
      watchProgress: const [],
    );
  }

  @override
  Future<SyncPushResult> pushMutations(
    String serverUrl,
    String accessToken, {
    required String deviceId,
    required List<SyncOutboxRow> mutations,
  }) async {
    return SyncPushResult(
      serverTimeMs: pullResult.serverTimeMs,
      acceptedOpIds: [for (final m in mutations) m.opId],
      remappedSources: const {},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<int> countMovies(AppDatabase db) async =>
      (await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.movie))).get()).length;

  HttpOverrides? previousHttpOverrides;

  setUpAll(() {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('SyncMapper.applyPullBatch commits chunks progressively with incremental DB visibility and progress', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final registry = MountRegistry(db);
    final mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) => _GatedProbeDriver(mount.kind),
    );
    final syncStore = SyncLocalStore(db);
    final mapper = SyncMapper(db: db, repo: repo, syncStore: syncStore, mountManager: mountManager);
    addTearDown(() async {
      await mountManager.dispose();
      await db.close();
    });

    final masterKey = Uint8List.fromList(List<int>.filled(32, 3));
    const mount = StorageMount(
      id: 'm_prog_1',
      kind: StorageKind.webdav,
      displayName: 'Test WebDAV',
      config: {MountKeys.baseUrl: 'https://dav.example.com'},
    );
    await registry.upsert(mount);

    const movieCount = 60;
    final works = <Map<String, dynamic>>[];
    final files = <Map<String, dynamic>>[];
    final watchProgress = <Map<String, dynamic>>[];
    for (var i = 1; i <= movieCount; i++) {
      final tmdbId = '${900000 + i}';
      final workKey = 'tmdb:movie:$tmdbId';
      final relPath = '/Movies/Movie_$i.mkv';
      final fileId = DeterministicKeys.generateFileId(sourceId: mount.id, mountRelativePath: relPath);
      works.add({
        'work_key': workKey,
        'kind': LibraryKinds.movie,
        'library_type': LibraryTypes.movie,
        'provider': 'tmdb',
        'external_id': tmdbId,
        'match_status': MatchStatusRank.matched,
        'metadata_json': {
          'title': 'Movie $i',
          'sort_title': 'movie ${i.toString().padLeft(4, '0')}',
          'tmdb_id': tmdbId,
          'metadata_source': 'tmdb',
        },
        'client_updated_at': 1000 + i,
        'is_deleted': false,
      });
      files.add({
        'file_id': fileId,
        'source_id': mount.id,
        'relative_path': relPath,
        'role': LibraryFileRoles.video,
        'file_name': 'Movie_$i.mkv',
        'file_size': 1024 * i,
        'work_key': workKey,
        'season_num': -1,
        'episode_num': -1,
        'match_status': MatchStatusRank.matched,
        'media_spec_json': {'duration_ms': 6000000},
        'client_updated_at': 1000 + i,
        'is_deleted': false,
      });
      files.add({
        'file_id': '${fileId}_sub',
        'source_id': mount.id,
        'relative_path': '/Movies/Movie_$i.chi.ass',
        'role': LibraryFileRoles.subtitle,
        'owner_file_id': fileId,
        'language': 'chi',
        'file_name': 'Movie_$i.chi.ass',
        'file_size': 1024,
        'season_num': -1,
        'episode_num': -1,
        'match_status': MatchStatusRank.matched,
        'media_spec_json': const <String, Object?>{},
        'client_updated_at': 1000 + i,
        'is_deleted': false,
      });
      if (i <= 5) {
        watchProgress.add({
          'progress_key': DeterministicKeys.generateProgressKey(
            workKey: workKey,
            kind: LibraryKinds.movie,
            seasonNum: -1,
            episodeNum: -1,
          ),
          'work_key': workKey,
          'season_num': -1,
          'episode_num': -1,
          'position_ms': 123456,
          'duration_ms': 6000000,
          'watched': false,
          'play_count': 0,
          'last_played_at': 5000,
          'client_updated_at': 5000,
        });
      }
    }

    final progressEvents = <(int processed, int total)>[];
    final movieCountsAtChunkCallback = <int>[];

    final touched = await mapper.applyPullBatch(
      masterKey: masterKey,
      sources: const [],
      works: works,
      files: files,
      workPrefs: const [],
      watchProgress: watchProgress,
      userSettings: const {},
      nextSeq: 42,
      isFinalPage: true,
      updateCloudCursor: true,
      onProgress: (processed, total) => progressEvents.add((processed, total)),
      onChunkApplied: () async {
        final committedMovies = await countMovies(db);
        movieCountsAtChunkCallback.add(committedMovies);
      },
    );

    expect(touched, movieCount + files.length + watchProgress.length);

    final totalEntities = works.length + files.length + watchProgress.length;
    expect(progressEvents.first, (0, totalEntities));
    expect(progressEvents.last, (totalEntities, totalEntities));
    for (var i = 1; i < progressEvents.length; i++) {
      expect(progressEvents[i].$1, greaterThanOrEqualTo(progressEvents[i - 1].$1));
    }

    // Multiple Stage-3 chunks must have committed incrementally before completion:
    expect(movieCountsAtChunkCallback.length, greaterThanOrEqualTo(3));
    expect(movieCountsAtChunkCallback.first, lessThan(movieCount));
    expect(movieCountsAtChunkCallback.first, greaterThan(0));
    expect(movieCountsAtChunkCallback.last, movieCount);

    // Watch progress from Stage 2 must have been projected onto Stage 3 works:
    final movie1 = await repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '900001');
    expect(movie1, isNotNull);
    final movie1State = await (db.select(db.libraryUserStates)..where((t) => t.itemId.equals(movie1!.id))).getSingleOrNull();
    expect(movie1State?.positionMs, 123456);
    expect(await syncStore.getLastPullSeq(), 42);
  });

  test('LAN P2P syncWithPeer emits SyncProgress phases and triggers live library notifications', () async {
    Future<({
      AppDatabase db,
      LibraryRepository repo,
      MountRegistry registry,
      MountManager mountManager,
      LibraryScanService scans,
      SyncAndScanCoordinator sync,
    })> createDevice(String name) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = LibraryRepository(db);
      final registry = MountRegistry(db);
      final mountManager = MountManager(
        registry,
        driverFactory: (mount, {bool useFallback = false}) => _GatedProbeDriver(mount.kind),
      );
      final scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mountManager);
      final sync = SyncAndScanCoordinator(
        db: db,
        repo: repo,
        mountManager: mountManager,
        scanService: scans,
        enableLanUdp: false,
        autoStartLanService: true,
      );
      await sync.initialize();
      await sync.syncStore.setDeviceName(name);
      await sync.selectLanMode();
      return (db: db, repo: repo, registry: registry, mountManager: mountManager, scans: scans, sync: sync);
    }

    final sender = await createDevice('Phone A');
    final receiver = await createDevice('LivingRoomTV');
    addTearDown(() async {
      sender.scans.dispose();
      sender.sync.dispose();
      await sender.mountManager.dispose();
      await sender.db.close();
      receiver.scans.dispose();
      receiver.sync.dispose();
      await receiver.mountManager.dispose();
      await receiver.db.close();
    });

    // Pair while empty first, then populate sender and trigger explicit syncWithPeer.
    final discoveredReceiver = LanDiscoveredPeer(
      deviceId: receiver.sync.lanService.deviceId!,
      deviceName: 'LivingRoomTV',
      platform: 'android',
      host: '127.0.0.1',
      httpPort: receiver.sync.lanService.listeningPort!,
      pubKeyBase64: receiver.sync.lanService.publicKeyBase64!,
      revision: 0,
      lastSeen: clock.now(),
    );
    await sender.sync.lanService.requestPairWithPeer(discoveredReceiver);
    await receiver.sync.lanService.acceptPairRequest(receiver.sync.lanService.incomingPairRequests.single);

    const mount = StorageMount(
      id: 'm_lan_prog',
      kind: StorageKind.webdav,
      displayName: 'LAN Share',
      config: {MountKeys.baseUrl: 'https://lan.example.com'},
    );
    await sender.registry.upsert(mount);
    for (var i = 1; i <= 55; i++) {
      final tmdbId = '${800000 + i}';
      final itemId = await sender.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'LAN Film $i',
          sortTitle: 'lan film ${i.toString().padLeft(4, '0')}',
          tmdbId: Value(tmdbId),
          metadataSource: const Value('tmdb'),
          scrapedAt: const Value(1000),
          addedAt: 1000,
          updatedAt: 1000,
        ),
      );
      final fileId = await sender.repo.upsertFile(
        mountId: mount.id,
        path: '/Movies/LAN_$i.mp4',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 5000,
      );
      await sender.repo.linkFile(fileId, itemId);
      await sender.repo.updateFile(fileId, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
    }
    await sender.sync.syncStore.bumpLocalLanRevision();

    final progressTrace = <SyncProgress>[];
    final syncingFlags = <bool>[];
    var libraryNotifyCount = 0;

    void onSyncChanged() {
      progressTrace.add(receiver.sync.progress);
      syncingFlags.add(receiver.sync.isSyncing);
    }

    receiver.sync.addListener(onSyncChanged);
    receiver.scans.addLibraryListener(() => libraryNotifyCount++);

    final trustedSender = receiver.sync.lanService.trustedPeers.single;
    await receiver.sync.lanService.syncWithPeer(
      trustedSender,
      hostOverride: '127.0.0.1',
      portOverride: sender.sync.lanService.listeningPort,
    );

    expect(receiver.sync.isSyncing, isFalse);
    expect(receiver.sync.progress, SyncProgress.idle);
    expect(syncingFlags, contains(true));
    expect(progressTrace.any((p) => p.phase == SyncPhase.pulling && p.peerName == 'Phone A'), isTrue);
    final applyingEvents = progressTrace.where((p) => p.phase == SyncPhase.applying).toList();
    expect(applyingEvents, isNotEmpty);
    expect(applyingEvents.first.peerName, 'Phone A');
    expect(applyingEvents.last.processed, applyingEvents.last.total);
    expect(applyingEvents.last.total, greaterThan(55));
    expect(libraryNotifyCount, greaterThanOrEqualTo(1));
    expect(await countMovies(receiver.db), 55);
  });

  test('Cloud syncNow refreshes library UI immediately after pull before slow mount probe completes', () async {
    final probeEntered = Completer<void>();
    final probeGate = Completer<void>();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final registry = MountRegistry(db);
    final mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) => _GatedProbeDriver(
        mount.kind,
        onCheckEntered: () {
          if (!probeEntered.isCompleted) probeEntered.complete();
        },
        checkGate: probeGate.future,
      ),
    );
    await registry.upsert(
      const StorageMount(
        id: 'm_cloud_slow_probe',
        kind: StorageKind.webdav,
        displayName: 'Slow WebDAV',
        config: {MountKeys.baseUrl: 'https://slow.example.com'},
      ),
    );

    final pullResult = SyncPullResult(
      serverTimeMs: 100000,
      currentMaxSeq: 10,
      nextSeq: 10,
      hasMore: false,
      resetRequired: false,
      userSettings: const {},
      sources: const [],
      works: [
        {
          'work_key': 'tmdb:movie:777001',
          'kind': LibraryKinds.movie,
          'library_type': LibraryTypes.movie,
          'provider': 'tmdb',
          'external_id': '777001',
          'match_status': MatchStatusRank.matched,
          'metadata_json': {
            'title': 'Synced Before Probe',
            'sort_title': 'synced before probe',
            'tmdb_id': '777001',
            'metadata_source': 'tmdb',
          },
          'client_updated_at': 2000,
          'is_deleted': false,
        },
      ],
      files: [
        {
          'file_id': DeterministicKeys.generateFileId(
            sourceId: 'm_cloud_slow_probe',
            mountRelativePath: '/Synced.mkv',
          ),
          'source_id': 'm_cloud_slow_probe',
          'relative_path': '/Synced.mkv',
          'role': LibraryFileRoles.video,
          'file_name': 'Synced.mkv',
          'file_size': 12345,
          'work_key': 'tmdb:movie:777001',
          'season_num': -1,
          'episode_num': -1,
          'match_status': MatchStatusRank.matched,
          'media_spec_json': const <String, Object?>{},
          'client_updated_at': 2000,
          'is_deleted': false,
        },
      ],
      workPrefs: const [],
      watchProgress: const [],
    );

    final scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mountManager);
    final apiClient = _FakeSyncApiClient(pullResult);
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      apiClient: apiClient,
      enableLanUdp: false,
      autoStartLanService: false,
    );
    await sync.initialize();
    sync.debugSetSessionForTesting(
      SyncSessionCredentials(
        serverUrl: 'https://sync.example.com',
        userId: 'u-1',
        username: 'alice',
        accessToken: 'tok-1',
        masterKey: Uint8List.fromList(List<int>.filled(32, 9)),
      ),
    );

    addTearDown(() async {
      if (!probeGate.isCompleted) probeGate.complete();
      scans.dispose();
      sync.dispose();
      await mountManager.dispose();
      await db.close();
    });

    var libraryRefreshCountWhileProbing = 0;
    scans.addLibraryListener(() {
      libraryRefreshCountWhileProbing++;
    });

    final syncFuture = sync.syncNow(allowBackgroundScan: false);
    await probeEntered.future.timeout(const Duration(seconds: 5));

    // Even while mountManager.probeAll() is blocked on network I/O, UI notification and
    // DB persistence must ALREADY be complete, and progress must indicate probingMounts.
    expect(sync.progress.phase, SyncPhase.probingMounts);
    expect(libraryRefreshCountWhileProbing, greaterThanOrEqualTo(1));
    expect(await countMovies(db), 1);

    probeGate.complete();
    final ok = await syncFuture;
    expect(ok, isTrue);
    expect(sync.progress, SyncProgress.idle);
    expect(sync.isSyncing, isFalse);
  });
}
