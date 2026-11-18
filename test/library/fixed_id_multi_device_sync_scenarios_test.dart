import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scraper.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/scrapers/scraped_metadata.dart';
import 'package:plezy/library/sync/deterministic_keys.dart';
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
import 'package:plezy/storage/storage_path.dart';

import '../test_helpers/prefs.dart';

class _TrackingVirtualDriver implements StorageDriver {
  _TrackingVirtualDriver({required this.mount, required this.entries, this.onClose});

  final StorageMount mount;
  final Map<String, ({int size, int modifiedAt})> entries;
  final VoidCallback? onClose;

  bool closed = false;

  @override
  StorageKind get kind => mount.kind;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final directory = StoragePath.normalize(path);
    final depth = StoragePath.segments(directory).length;
    final seen = <String, StorageEntry>{};
    for (final entry in entries.entries) {
      final segments = StoragePath.segments(entry.key);
      if (segments.length <= depth) continue;
      final prefix = depth == 0 ? '' : '/${segments.sublist(0, depth).join('/')}';
      if (depth > 0 && prefix != directory) continue;
      final childPath = '$prefix/${segments[depth]}';
      final isFile = segments.length == depth + 1;
      seen.putIfAbsent(
        childPath,
        () => StorageEntry(
          path: childPath,
          name: segments[depth],
          isDirectory: !isFile,
          size: isFile ? entry.value.size : null,
          modifiedAt: isFile ? DateTime.fromMillisecondsSinceEpoch(entry.value.modifiedAt) : null,
        ),
      );
    }
    return seen.values.toList();
  }

  @override
  Future<StorageEntry> stat(String path) async {
    final norm = StoragePath.normalize(path);
    final meta = entries[norm];
    return StorageEntry(
      path: norm,
      name: StoragePath.name(norm),
      isDirectory: meta == null,
      size: meta?.size,
      modifiedAt: meta == null ? null : DateTime.fromMillisecondsSinceEpoch(meta.modifiedAt),
    );
  }

  static const int fixedStreamSize = 256;

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    final url = mount.configString(MountKeys.baseUrl) ?? '';
    final pass = mount.secrets[MountKeys.secretPassword] ?? '';
    final frame = 'STREAM:$url:$pass:${StoragePath.normalize(entry.path)}'.padRight(fixedStreamSize);
    final bytes = utf8.encode(frame);
    final sliced = bytes.sublist(start.clamp(0, bytes.length), (end ?? bytes.length).clamp(0, bytes.length));
    return Stream.value(sliced);
  }

  @override
  Future<void> close() async {
    closed = true;
    onClose?.call();
  }
}

class _FakeMetadataProvider implements MetadataProvider {
  _FakeMetadataProvider(this.source);

  @override
  final String source;

  final Map<String, ScrapedTitle> movies = {};
  final Map<String, ScrapedTitle> shows = {};
  final Map<String, ScrapedSeason> seasons = {};

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) async => const [];

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) async => const [];

  @override
  Future<ScrapedTitle> movie(String id) async => movies[id]!;

  @override
  Future<ScrapedTitle> show(String id) async => shows[id]!;

  @override
  Future<ScrapedSeason?> season(String showId, int seasonNumber) async => seasons['$showId:s$seasonNumber'];

  @override
  void close() {}
}

class _ScenarioNode {
  _ScenarioNode(this.name, {bool isTvDevice = false, Map<String, ({int size, int modifiedAt})>? sharedFiles})
    : sharedFiles = sharedFiles ?? {},
      db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) {
        driverCreates++;
        createdMountUrls.add(mount.configString(MountKeys.baseUrl) ?? mount.kind.id);
        final driver = _TrackingVirtualDriver(mount: mount, entries: this.sharedFiles, onClose: () => driverCloses++);
        return driver;
      },
    );
    client = LocalLibraryClient(repository: repo, mounts: mountManager);
    scanner = LibraryScanner(db, repo);
    scans = LibraryScanService(repository: repo, scanner: scanner, mounts: mountManager);
    sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      isTvDevice: isTvDevice,
      enableLanUdp: false,
    );
    scans.onScopedCatalogChanged = (mountIds, {directoryPrefixes, allowTombstones = true}) => unawaited(
      sync.onCatalogChanged(mountIds: mountIds, directoryPrefixes: directoryPrefixes, allowTombstones: allowTombstones),
    );
  }

  final String name;
  final Map<String, ({int size, int modifiedAt})> sharedFiles;
  final AppDatabase db;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScanner scanner;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;

  int driverCreates = 0;
  int driverCloses = 0;
  final List<String> createdMountUrls = [];
  bool _disposed = false;

  Future<void> initLocal() async {
    await sync.initialize();
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
    binTempDir = await Directory.systemTemp.createTemp('plezy_fixed_sync_bin_');
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

  setUp(() async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  tearDown(() {
    CredentialVault.resetKeyForTesting();
  });

  Future<String> startSyncServer() async {
    final dataDir = await Directory.systemTemp.createTemp('plezy_fixed_sync_data_');
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
        try {
          await dataDir.delete(recursive: true);
        } catch (_) {}
      }
    });
    return urlCompleter.future.timeout(const Duration(seconds: 5));
  }

  group('Fixed-ID Multi-Device Sync Scenarios', () {
    test(
      'Scenario 1: 600+ files multi-page Cloud Push/Pull + out-of-order file-before-work + 26-ep pending show',
      () async {
        final serverUrl = await startSyncServer();
        final pc = _ScenarioNode('PC');
        final android = _ScenarioNode('Android');
        addTearDown(pc.dispose);
        addTearDown(android.dispose);

        await pc.initLocal();
        await android.initLocal();

        const mount = StorageMount(
          id: 'quark_600100',
          kind: StorageKind.quark,
          displayName: 'Quark 600',
          config: {MountKeys.rootFolderId: '0'},
          secrets: {MountKeys.secretCookie: 'uid=600100; __pus=ok'},
        );
        await pc.registry.upsert(mount);

        // Seed 310 matched movies (310 works + 310 files = 620 entities -> multiple pages).
        for (var i = 1; i <= 310; i++) {
          final workKey = 'tmdb:movie:${500000 + i}';
          final mid = await pc.repo.insertItem(
            LibraryItemsCompanion.insert(
              workKey: Value(workKey),
              kind: LibraryKinds.movie,
              libraryType: LibraryTypes.movie,
              title: 'Movie $i',
              sortTitle: 'movie ${i.toString().padLeft(4, '0')}',
              tmdbId: Value('${500000 + i}'),
              metadataSource: const Value('tmdb'),
              scrapedAt: Value(1000 + i),
              addedAt: 1000 + i,
              updatedAt: 1000 + i,
            ),
          );
          final fid = await pc.repo.upsertFile(
            mountId: mount.id,
            path: '/Movies/Movie_$i (2024).mkv',
            role: LibraryFileRoles.video,
            scanId: 1,
            size: 1024 * 1024,
            modifiedAt: 2000 + i,
          );
          await pc.repo.linkFile(fid, mid);
          await pc.repo.updateFile(fid, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
        }

        // Seed 26 unmatched episodes of a Chinese show via LibraryScanner so file rules match production.
        final pendingFiles = <String, ({int size, int modifiedAt})>{
          for (var ep = 1; ep <= 26; ep++)
            '/Anime/剑来 第一季/S01E${ep.toString().padLeft(2, '0')}.mkv': (size: 500000, modifiedAt: 3000 + ep),
        };
        final pendingDriver = _TrackingVirtualDriver(mount: mount, entries: pendingFiles);
        await pc.scanner.scan(mount, pendingDriver, restart: true);
        await pc.sync.mapper.ensureJournalUpToDate();

        // No raw:* fake works may exist in sync_journal!
        final rawWorks = await pc.db
            .customSelect("SELECT 1 FROM sync_journal WHERE entity_type = 'work' AND entity_key LIKE 'raw:%'")
            .get();
        expect(rawWorks, isEmpty);

        // Cloud Pull across multiple pages (500/page) & multi-page Push (200/page).
        await pc.sync.register(serverUrl: serverUrl, username: 'scen1', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'scen1', password: 'pw');

        final pushReceiver = _ScenarioNode('PushReceiver');
        addTearDown(pushReceiver.dispose);
        await pushReceiver.initLocal();
        await pushReceiver.sync.loginWithPassword(serverUrl: serverUrl, username: 'scen1', password: 'pw');

        final pcMovies = (await pc.repo.queryTitles(
          const LibraryQuery(libraryType: LibraryTypes.movie, limit: 500),
        )).items;
        final androidMovies = (await android.repo.queryTitles(
          const LibraryQuery(libraryType: LibraryTypes.movie, limit: 500),
        )).items;
        final pushMovies = (await pushReceiver.repo.queryTitles(
          const LibraryQuery(libraryType: LibraryTypes.movie, limit: 500),
        )).items;
        expect(pcMovies, hasLength(310));
        expect(androidMovies, hasLength(310));
        expect(pushMovies, hasLength(310));
        expect(androidMovies.map((e) => e.item.workKey).toSet(), pcMovies.map((e) => e.item.workKey).toSet());

        final androidPending = (await android.repo.queryTitles(
          const LibraryQuery(libraryType: LibraryTypes.pending),
        )).items;
        expect(androidPending, hasLength(1));
        expect(await android.repo.episodesOfShow(androidPending.single.item.id), hasLength(26));
        final pushPending = (await pushReceiver.repo.queryTitles(
          const LibraryQuery(libraryType: LibraryTypes.pending),
        )).items;
        expect(pushPending, hasLength(1));
        expect(await pushReceiver.repo.episodesOfShow(pushPending.single.item.id), hasLength(26));

        final unbound = await android.db
            .customSelect(
              "SELECT 1 FROM library_files WHERE role = 'video' AND match_state != 'ignored' AND item_id IS NULL",
            )
            .get();
        expect(unbound, isEmpty);

        // Out-of-order chunk test: Page 1 sends file BEFORE work (isFinalPage: false); Page 2 sends work (isFinalPage: true).
        final outOfOrderNode = _ScenarioNode('OutOfOrder');
        addTearDown(outOfOrderNode.dispose);
        await outOfOrderNode.initLocal();
        final masterKey = (await pc.sync.syncStore.loadSession())!.masterKey;
        final bundle = await pc.sync.mapper.buildDeltaBundle(encryptionKey: masterKey, sinceSeq: 0, limit: 1000);
        final targetWork = bundle.works.firstWhere((w) => w['work_key'] == 'tmdb:movie:500001');
        final targetFile = bundle.files.firstWhere((f) => f['work_key'] == 'tmdb:movie:500001');

        // Page 1: source + file ONLY (no work yet!), isFinalPage: false.
        await outOfOrderNode.sync.mapper.applyPullBatch(
          masterKey: masterKey,
          sources: bundle.sources,
          works: const [],
          files: [targetFile],
          workPrefs: const [],
          watchProgress: const [],
          userSettings: const {},
          nextSeq: 1,
          updateCloudCursor: false,
          isFinalPage: false,
        );
        final waitingFile = await outOfOrderNode.repo.findFileByKey(targetFile['file_id'] as String);
        expect(waitingFile, isNotNull);
        expect(waitingFile!.workKey, 'tmdb:movie:500001');
        expect(waitingFile.itemId, isNull);

        // Page 2: work lands later, isFinalPage: true -> back-links waiting file automatically!
        await outOfOrderNode.sync.mapper.applyPullBatch(
          masterKey: masterKey,
          sources: const [],
          works: [targetWork],
          files: const [],
          workPrefs: const [],
          watchProgress: const [],
          userSettings: const {},
          nextSeq: 2,
          updateCloudCursor: false,
          isFinalPage: true,
        );
        final boundMovie = await outOfOrderNode.repo.findByWorkKey('tmdb:movie:500001');
        expect(boundMovie, isNotNull);
        final boundFile = await outOfOrderNode.repo.findFileByKey(targetFile['file_id'] as String);
        expect(boundFile!.itemId, boundMovie!.id);
      },
    );

    test(
      'Scenario 2: Self-healing corrupted Android SQLite (deleted items & item_id = NULL) even when journal hashes match',
      () async {
        final serverUrl = await startSyncServer();
        final pc = _ScenarioNode('PC');
        final android = _ScenarioNode('Android');
        addTearDown(pc.dispose);
        addTearDown(android.dispose);

        await pc.initLocal();
        await android.initLocal();

        const mount = StorageMount(
          id: 'webdav_heal_1',
          kind: StorageKind.webdav,
          displayName: 'Heal DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.20/dav'},
        );
        await pc.registry.upsert(mount);
        final m1Id = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:601'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Lost Movie A',
            sortTitle: 'lost movie a',
            tmdbId: const Value('601'),
            metadataSource: const Value('tmdb'),
            scrapedAt: const Value(1000),
            addedAt: 1000,
            updatedAt: 1000,
          ),
        );
        final f1Id = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/LostA.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: 1000,
          modifiedAt: 1000,
        );
        await pc.repo.linkFile(f1Id, m1Id);

        final p1Id = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.pending,
            title: 'Unmatched Film B',
            sortTitle: 'unmatched film b',
            addedAt: 1000,
            updatedAt: 1000,
          ),
        );
        final f2Id = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/UnmatchedB (2025).mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: 2000,
          modifiedAt: 1000,
        );
        await pc.repo.linkFile(f2Id, p1Id);

        await pc.sync.register(serverUrl: serverUrl, username: 'scen2', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'scen2', password: 'pw');

        expect(await android.repo.findByWorkKey('tmdb:movie:601'), isNotNull);
        expect(
          (await android.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items,
          hasLength(1),
        );

        // Corrupt Android SQLite while keeping sync_journal untouched (same hashes!).
        await android.db.customStatement('UPDATE library_files SET item_id = NULL, parsed = NULL');
        await android.db.customStatement('DELETE FROM library_items');
        expect(await android.repo.findByWorkKey('tmdb:movie:601'), isNull);

        // Part A: healCatalogFromJournal() restores both the matched movie and the pending item!
        final healed = await android.sync.mapper.healCatalogFromJournal();
        expect(healed, greaterThan(0));
        expect(await android.repo.findByWorkKey('tmdb:movie:601'), isNotNull);
        expect(
          (await android.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items,
          hasLength(1),
        );
        final unboundAfterHeal = await android.db
            .customSelect("SELECT 1 FROM library_files WHERE role = 'video' AND item_id IS NULL")
            .get();
        expect(unboundAfterHeal, isEmpty);

        // Part B: Corrupt SQLite again and verify applyPullBatch with identical hashes also self-heals!
        await android.db.customStatement('UPDATE library_files SET item_id = NULL, work_key = NULL');
        await android.db.customStatement('DELETE FROM library_items');
        final masterKey = (await pc.sync.syncStore.loadSession())!.masterKey;
        final delta = await pc.sync.mapper.buildDeltaBundle(encryptionKey: masterKey, sinceSeq: 0, limit: 100);
        await android.sync.mapper.applyPullBatch(
          masterKey: masterKey,
          sources: delta.sources,
          works: delta.works,
          files: delta.files,
          workPrefs: delta.workPrefs,
          watchProgress: delta.watchProgress,
          userSettings: delta.userSettings,
          nextSeq: delta.currentMaxSeq,
          updateCloudCursor: false,
          isFinalPage: true,
        );
        expect(await android.repo.findByWorkKey('tmdb:movie:601'), isNotNull);
        expect(
          (await android.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items,
          hasLength(1),
        );
      },
    );

    test(
      'Scenario 3: Multi-folder includePaths Quark mount add, narrow, and remove across 3 devices preserving watch history',
      () async {
        final serverUrl = await startSyncServer();
        final allFiles = <String, ({int size, int modifiedAt})>{
          '/电影/Inception (2010).mkv': (size: 5000, modifiedAt: 2000),
          '/动漫/Spirited.Away (2001).mkv': (size: 4000, modifiedAt: 3000),
          '/未选目录/Ignored (2020).mkv': (size: 3000, modifiedAt: 4000),
        };
        final pc = _ScenarioNode('PC', sharedFiles: allFiles);
        final android = _ScenarioNode('Android');
        final tv = _ScenarioNode('TV', isTvDevice: true);
        addTearDown(pc.dispose);
        addTearDown(android.dispose);
        addTearDown(tv.dispose);

        await pc.sync.register(serverUrl: serverUrl, username: 'multi_dir_user', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'multi_dir_user', password: 'pw');
        await tv.sync.loginWithPassword(serverUrl: serverUrl, username: 'multi_dir_user', password: 'pw');

        // Add single Quark mount with fixed ID and multi-folder includePaths.
        const initialMount = StorageMount(
          id: 'quark_333444',
          kind: StorageKind.quark,
          displayName: '我的夸克网盘',
          config: {
            MountKeys.rootFolderId: '0',
            MountKeys.includePaths: ['/电影', '/动漫'],
          },
          secrets: {MountKeys.secretCookie: 'uid=333444; __pus=t1'},
        );
        expect(DeterministicKeys.deterministicSourceId(initialMount), 'quark_333444');
        await pc.registry.upsert(initialMount);
        await pc.scanner.scan(
          initialMount,
          _TrackingVirtualDriver(mount: initialMount, entries: allFiles),
          restart: true,
        );

        // Assign shelves cleanly so both films are matched works.
        final pending = (await pc.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items;
        expect(pending.map((v) => v.item.title).toSet(), {'Inception', 'Spirited.Away'});
        for (final v in pending) {
          final isAnime = v.item.title.contains('Spirited');
          await pc.repo.updateItem(
            v.item.id,
            LibraryItemsCompanion(
              libraryType: Value(isAnime ? LibraryTypes.anime : LibraryTypes.movie),
              tmdbId: Value(isAnime ? '129' : '27205'),
              metadataSource: const Value('tmdb'),
              scrapedAt: Value(clock.now().millisecondsSinceEpoch),
            ),
          );
          final files = await pc.repo.versionsOf(v.item.id);
          await pc.repo.linkFile(files.single.id, v.item.id);
        }

        await pc.sync.onMountSaved(initialMount);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await android.sync.syncNow();
        await tv.sync.syncNow();

        expect((await android.repo.findByWorkKey('tmdb:movie:27205')), isNotNull);
        expect((await android.repo.findByWorkKey('tmdb:movie:129')), isNotNull);
        expect((await tv.repo.findByWorkKey('tmdb:movie:129')), isNotNull);

        // Android watches Inception so watch history exists before mount narrowing/removal.
        final androidInception = (await android.repo.findByWorkKey('tmdb:movie:27205'))!;
        await android.client.reportPlaybackStopped(
          itemId: '${androidInception.id}',
          position: const Duration(minutes: 25),
          duration: const Duration(minutes: 148),
        );
        await android.sync.syncNow();

        // Narrow includePaths to ['/电影'] only -> '/动漫' must prune across all 3 devices!
        final narrowedMount = StorageMount(
          id: initialMount.id,
          kind: initialMount.kind,
          displayName: initialMount.displayName,
          config: const {
            MountKeys.rootFolderId: '0',
            MountKeys.includePaths: ['/电影'],
          },
          secrets: initialMount.secrets,
          createdAt: initialMount.createdAt,
        );
        await pc.registry.upsert(narrowedMount);
        await pc.sync.onMountSaved(narrowedMount);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        await android.sync.syncNow();
        await tv.sync.syncNow();

        expect(await pc.repo.findByWorkKey('tmdb:movie:129'), isNull);
        expect(await android.repo.findByWorkKey('tmdb:movie:129'), isNull);
        expect(await tv.repo.findByWorkKey('tmdb:movie:129'), isNull);
        expect(await tv.repo.findByWorkKey('tmdb:movie:27205'), isNotNull);

        // Remove mount completely -> clears all files/items across all 3 devices, while WorkWatchStates remains!
        await pc.registry.remove(initialMount.id);
        await pc.sync.onMountRemoved(initialMount.id);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        await android.sync.syncNow();
        await tv.sync.syncNow();

        for (final node in [pc, android, tv]) {
          expect(await node.registry.list(), isEmpty);
          expect(await node.db.select(node.db.libraryFiles).get(), isEmpty);
          expect(await node.db.select(node.db.libraryItems).get(), isEmpty);
        }
        final watchStatesOnTv = await tv.db.select(tv.db.workWatchStates).get();
        expect(watchStatesOnTv.any((w) => w.externalId == '27205' && w.positionMs == 25 * 60 * 1000), isTrue);
      },
    );

    test(
      'Scenario 4: Duplicate mount guard + 2 machines independently adding same WebDAV mount offline converge cleanly',
      () async {
        final serverUrl = await startSyncServer();
        final a = _ScenarioNode('Machine-A');
        final b = _ScenarioNode('Machine-B');
        addTearDown(a.dispose);
        addTearDown(b.dispose);

        await a.initLocal();
        await b.initLocal();

        const sharedDav = StorageMount(
          id: 'webdav_dummy',
          kind: StorageKind.webdav,
          displayName: 'Home DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.99:5244/dav', MountKeys.username: 'admin'},
          secrets: {MountKeys.secretPassword: 'pw'},
        );
        final fixedDavId = DeterministicKeys.deterministicSourceId(sharedDav);
        expect(fixedDavId.startsWith('webdav_'), isTrue);
        expect(fixedDavId.contains(':'), isFalse);

        final davA = StorageMount(
          id: fixedDavId,
          kind: sharedDav.kind,
          displayName: 'PC DAV',
          config: const {MountKeys.baseUrl: 'http://192.168.1.99:5244/dav/', MountKeys.username: 'admin'},
          secrets: sharedDav.secrets,
        );
        final davB = StorageMount(
          id: fixedDavId,
          kind: sharedDav.kind,
          displayName: 'Phone DAV',
          config: const {MountKeys.baseUrl: 'http://192.168.1.99:5244/dav', MountKeys.username: 'admin'},
          secrets: sharedDav.secrets,
        );
        expect(DeterministicKeys.deterministicSourceId(davA), fixedDavId);
        expect(DeterministicKeys.deterministicSourceId(davB), fixedDavId);

        await a.registry.upsert(davA);
        await b.registry.upsert(davB);

        // Duplicate guard blocks adding same WebDAV URL or same Quark uid again.
        expect((await a.registry.findDuplicate(davB))?.id, fixedDavId);
        expect(await a.registry.findDuplicate(davA, ignoreId: fixedDavId), isNull);

        await a.registry.upsert(
          const StorageMount(
            id: 'quark_555666',
            kind: StorageKind.quark,
            displayName: 'Q1',
            config: {MountKeys.rootFolderId: '0'},
            secrets: {MountKeys.secretCookie: 'uid=555666'},
          ),
        );
        expect(
          (await a.registry.findDuplicate(
            const StorageMount(
              id: 'quark_555666_dup',
              kind: StorageKind.quark,
              displayName: 'Q2',
              config: {MountKeys.rootFolderId: 'sub_123'},
              secrets: {MountKeys.secretCookie: 'uid=555666'},
            ),
          ))?.id,
          'quark_555666',
        );

        // Machine A offline has Level 4 locked Dune + unmatched UniqueA.mkv.
        final duneA = await a.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:438631'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Dune (Locked)',
            sortTitle: 'dune',
            tmdbId: const Value('438631'),
            metadataSource: const Value('nfo'),
            locked: const Value(true),
            scrapedAt: const Value(1500),
            addedAt: 1500,
            updatedAt: 1500,
          ),
        );
        final faDune = await a.repo.upsertFile(
          mountId: fixedDavId,
          path: '/Movies/Dune.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 1500,
        );
        await a.repo.linkFile(faDune, duneA);
        await a.repo.updateFile(
          faDune,
          const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), matchLocked: Value(true)),
        );

        final uaItem = await a.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.pending,
            title: 'UniqueA',
            sortTitle: 'uniquea',
            addedAt: 1600,
            updatedAt: 1600,
          ),
        );
        final faUnique = await a.repo.upsertFile(
          mountId: fixedDavId,
          path: '/Pending/UniqueA.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 1600,
        );
        await a.repo.linkFile(faUnique, uaItem);

        // Machine B offline has Level 3 Dune + unique Level 3 Arrival.
        final duneB = await b.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:438631'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Dune (Level 3)',
            sortTitle: 'dune',
            tmdbId: const Value('438631'),
            metadataSource: const Value('tmdb'),
            scrapedAt: const Value(9999),
            addedAt: 9999,
            updatedAt: 9999,
          ),
        );
        final fbDune = await b.repo.upsertFile(
          mountId: fixedDavId,
          path: '/Movies/Dune.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 9999,
        );
        await b.repo.linkFile(fbDune, duneB);
        await b.repo.updateFile(fbDune, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

        final arrivalB = await b.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:329865'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Arrival',
            sortTitle: 'arrival',
            tmdbId: const Value('329865'),
            metadataSource: const Value('tmdb'),
            scrapedAt: const Value(2500),
            addedAt: 2500,
            updatedAt: 2500,
          ),
        );
        final fbArrival = await b.repo.upsertFile(
          mountId: fixedDavId,
          path: '/Movies/Arrival.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 2500,
        );
        await b.repo.linkFile(fbArrival, arrivalB);
        await b.repo.updateFile(fbArrival, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

        await a.sync.mapper.ensureJournalUpToDate();
        await b.sync.mapper.ensureJournalUpToDate();

        await a.sync.register(serverUrl: serverUrl, username: 'scen4', password: 'pw', kdfParams: fastKdf);
        await b.sync.loginWithPassword(serverUrl: serverUrl, username: 'scen4', password: 'pw');
        await b.drainAndSyncNow();
        await a.drainAndSyncNow();

        final aDune = (await a.repo.findByWorkKey('tmdb:movie:438631'))!;
        final bDune = (await b.repo.findByWorkKey('tmdb:movie:438631'))!;
        expect(aDune.title, 'Dune (Locked)');
        expect(bDune.title, 'Dune (Locked)');
        expect(await a.repo.findByWorkKey('tmdb:movie:329865'), isNotNull);
        expect(await b.repo.findByWorkKey('tmdb:movie:329865'), isNotNull);
        expect(
          (await b.repo.queryTitles(
            const LibraryQuery(libraryType: LibraryTypes.pending),
          )).items.map((v) => v.item.title),
          ['UniqueA'],
        );
      },
    );

    test(
      'Scenario 5: Editing WebDAV URL & credentials preserves mount.id & file_key, drops cached drivers, and updates stream URLs on all devices',
      () async {
        final serverUrl = await startSyncServer();
        final pc = _ScenarioNode('PC');
        final android = _ScenarioNode('Android');
        addTearDown(pc.dispose);
        addTearDown(android.dispose);

        await pc.sync.register(serverUrl: serverUrl, username: 'dav_edit_user', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'dav_edit_user', password: 'pw');

        const baseMount = StorageMount(
          id: 'webdav_stable_id',
          kind: StorageKind.webdav,
          displayName: 'My WebDAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.10:5244/dav', MountKeys.username: 'u1'},
          secrets: {MountKeys.secretPassword: 'oldpass'},
        );
        final stableId = DeterministicKeys.deterministicSourceId(baseMount);
        final initialMount = StorageMount(
          id: stableId,
          kind: StorageKind.webdav,
          displayName: 'My WebDAV',
          config: baseMount.config,
          secrets: baseMount.secrets,
        );
        await pc.registry.upsert(initialMount);
        final mId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:99901'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Stream Film',
            sortTitle: 'stream film',
            tmdbId: const Value('99901'),
            metadataSource: const Value('tmdb'),
            scrapedAt: const Value(1000),
            addedAt: 1000,
            updatedAt: 1000,
          ),
        );
        final fId = await pc.repo.upsertFile(
          mountId: stableId,
          path: '/Movies/Stream.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: _TrackingVirtualDriver.fixedStreamSize,
          modifiedAt: 1000,
        );
        await pc.repo.linkFile(fId, mId);
        final originalFileKey = (await pc.repo.getFile(fId))!.fileKey!;

        await pc.sync.onMountSaved(initialMount);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await android.sync.syncNow();

        // Warm cached drivers on both PC and Android so dropCachedDriver can be observed.
        pc.mountManager.setStatus(stableId, MountOnlineStatus.onlinePrimary);
        android.mountManager.setStatus(stableId, MountOnlineStatus.onlinePrimary);
        final androidMovie = (await android.repo.findByWorkKey('tmdb:movie:99901'))!;
        final pbBefore = await android.client.getPlaybackInitialization(
          PlaybackInitializationOptions(
            metadata: MediaItem.jellyfin(id: '${androidMovie.id}', kind: MediaKind.movie, title: 'Stream Film'),
            selectedMediaIndex: 0,
          ),
        );
        final http1 = HttpClient();
        final bodyBefore = await http1
            .getUrl(Uri.parse(pbBefore.videoUrl!))
            .then((req) => req.close())
            .then((res) => utf8.decodeStream(res))
            .whenComplete(() => http1.close(force: true));
        expect(bodyBefore.trimRight(), 'STREAM:http://192.168.1.10:5244/dav:oldpass:/Movies/Stream.mkv');

        // Record watch progress before editing WebDAV URL.
        await android.client.reportPlaybackStopped(
          itemId: '${androidMovie.id}',
          position: const Duration(minutes: 15),
          duration: const Duration(minutes: 90),
        );
        await android.sync.syncNow();

        // Edit WebDAV URL + password on PC while keeping mount.id!
        final updatedMount = StorageMount(
          id: stableId,
          kind: StorageKind.webdav,
          displayName: 'My WebDAV HTTPS',
          config: const {MountKeys.baseUrl: 'https://nas.example.com:5244/dav', MountKeys.username: 'u1'},
          secrets: const {MountKeys.secretPassword: 'newpass'},
          createdAt: initialMount.createdAt,
        );
        await pc.registry.upsert(updatedMount);
        await pc.sync.onMountSaved(updatedMount);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        await android.sync.syncNow();

        final androidMountAfter = (await android.registry.get(stableId))!;
        expect(androidMountAfter.id, stableId);
        expect(androidMountAfter.configString(MountKeys.baseUrl), 'https://nas.example.com:5244/dav');
        expect(androidMountAfter.secrets[MountKeys.secretPassword], 'newpass');
        expect(android.driverCloses, greaterThanOrEqualTo(1));

        // File key and watch progress stay identical!
        final androidFiles = await android.repo.versionsOf(androidMovie.id);
        expect(androidFiles.single.fileKey, originalFileKey);

        final pbAfter = await android.client.getPlaybackInitialization(
          PlaybackInitializationOptions(
            metadata: MediaItem.jellyfin(id: '${androidMovie.id}', kind: MediaKind.movie, title: 'Stream Film'),
            selectedMediaIndex: 0,
          ),
        );
        final http2 = HttpClient();
        final bodyAfter = await http2
            .getUrl(Uri.parse(pbAfter.videoUrl!))
            .then((req) => req.close())
            .then((res) => utf8.decodeStream(res))
            .whenComplete(() => http2.close(force: true));
        expect(bodyAfter.trimRight(), 'STREAM:https://nas.example.com:5244/dav:newpass:/Movies/Stream.mkv');
      },
    );

    test(
      'Scenario 6: Deletion tombstones apply cleanly when peer scanned old files with newer addedAt wall-clock',
      () async {
        final serverUrl = await startSyncServer();
        final pc = _ScenarioNode('PC');
        final android = _ScenarioNode('Android');
        addTearDown(pc.dispose);
        addTearDown(android.dispose);

        await pc.initLocal();
        await android.initLocal();

        const mount = StorageMount(
          id: 'smb_del_1',
          kind: StorageKind.smb,
          displayName: 'Del SMB',
          config: {MountKeys.host: 'nas', MountKeys.share: 'media', MountKeys.rootPath: '/'},
        );
        await pc.registry.upsert(mount);
        await android.registry.upsert(mount);

        final oldMtime = 100000;
        final deletionTs = 500000;
        final peerLaterScanAddedAt = 900000; // Greater than deletionTs!

        // PC scans and syncs file, then deletes it at t=500000.
        final pcM = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:7701'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Deleted Later',
            sortTitle: 'deleted later',
            tmdbId: const Value('7701'),
            metadataSource: const Value('tmdb'),
            scrapedAt: Value(oldMtime),
            addedAt: oldMtime,
            updatedAt: oldMtime,
          ),
        );
        final pcF = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/ToDelete.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: oldMtime,
        );
        await pc.repo.linkFile(pcF, pcM);

        // Android independently scanned the SAME old file later at addedAt=900000.
        final andM = await android.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:7701'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Deleted Later',
            sortTitle: 'deleted later',
            tmdbId: const Value('7701'),
            metadataSource: const Value('tmdb'),
            scrapedAt: Value(oldMtime),
            addedAt: peerLaterScanAddedAt,
            updatedAt: oldMtime,
          ),
        );
        final andF = await android.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/ToDelete.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: oldMtime,
        );
        await android.repo.linkFile(andF, andM);

        await withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(200000)), () async {
          await pc.sync.mapper.ensureJournalUpToDate();
        });
        await pc.sync.register(serverUrl: serverUrl, username: 'scen6', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'scen6', password: 'pw');

        // Delete on PC at deletionTs=500000 (older than Android's addedAt wall-clock ~1.79e12, newer than mtime=100000).
        await withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(deletionTs)), () async {
          await (pc.db.delete(pc.db.libraryFiles)..where((t) => t.id.equals(pcF))).go();
          await pc.repo.pruneEmptyTitles();
          await pc.sync.syncStore.saveServerTimeOffsetMs(0);
          await pc.sync.onCatalogChanged(mountIds: {mount.id}, allowTombstones: true);
        });

        await pc.drainAndSyncNow();
        await android.drainAndSyncNow();

        final deletedKey = DeterministicKeys.generateFileId(
          sourceId: mount.id,
          mountRelativePath: '/Movies/ToDelete.mkv',
        );
        expect(await android.repo.findFileByKey(deletedKey), isNull);
        expect(await android.repo.findByWorkKey('tmdb:movie:7701'), isNull);

        // Also verify direct applyPullBatch deletes an offline-scanned file when existingJ == null and existing.addedAt > deletionTs!
        final offlinePeer = _ScenarioNode('OfflinePeer');
        addTearDown(offlinePeer.dispose);
        await offlinePeer.initLocal();
        await offlinePeer.registry.upsert(mount);
        final offM = await offlinePeer.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:movie:7702'),
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Offline Old Mtime',
            sortTitle: 'offline old mtime',
            tmdbId: const Value('7702'),
            metadataSource: const Value('tmdb'),
            scrapedAt: Value(oldMtime),
            addedAt: peerLaterScanAddedAt,
            updatedAt: oldMtime,
          ),
        );
        final offF = await offlinePeer.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/OfflineDel.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: oldMtime,
        );
        await offlinePeer.repo.linkFile(offF, offM);
        final offKey = DeterministicKeys.generateFileId(
          sourceId: mount.id,
          mountRelativePath: '/Movies/OfflineDel.mkv',
        );
        await offlinePeer.sync.mapper.applyPullBatch(
          masterKey: (await pc.sync.syncStore.loadSession())!.masterKey,
          sources: const [],
          works: const [],
          files: [
            {
              'file_id': offKey,
              'source_id': mount.id,
              'relative_path': '/Movies/OfflineDel.mkv',
              'is_deleted': true,
              'client_updated_at': deletionTs,
            },
          ],
          workPrefs: const [],
          watchProgress: const [],
          userSettings: const {},
          nextSeq: 0,
          updateCloudCursor: false,
          isFinalPage: true,
        );
        expect(await offlinePeer.repo.findFileByKey(offKey), isNull);
        expect(await offlinePeer.repo.findByWorkKey('tmdb:movie:7702'), isNull);
      },
    );

    test(
      'Scenario 7: Manual match on PC syncs to Android & Home displays unified cross-shelf local.recent hub first',
      () async {
        final serverUrl = await startSyncServer();
        final pc = _ScenarioNode('PC');
        final android = _ScenarioNode('Android');
        addTearDown(pc.dispose);
        addTearDown(android.dispose);

        await pc.sync.register(serverUrl: serverUrl, username: 'hub_user', password: 'pw', kdfParams: fastKdf);
        await android.sync.loginWithPassword(serverUrl: serverUrl, username: 'hub_user', password: 'pw');

        const mount = StorageMount(
          id: 'webdav_hub_1',
          kind: StorageKind.webdav,
          displayName: 'Hub DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.30/dav'},
        );
        await pc.registry.upsert(mount);

        // Seed matched Anime (ts=5000) and matched Show (ts=3000) plus 1 unmatched Pending movie (ts=7000).
        final animeId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:tv:8001'),
            kind: LibraryKinds.show,
            libraryType: LibraryTypes.anime,
            title: 'Anime Latest',
            sortTitle: 'anime latest',
            tmdbId: const Value('8001'),
            metadataSource: const Value('tmdb'),
            sourceAddedAt: const Value(5000),
            scrapedAt: const Value(5000),
            addedAt: 5000,
            updatedAt: 5000,
          ),
        );
        final animeSeasonId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.season,
            libraryType: LibraryTypes.anime,
            title: 'Season 1',
            sortTitle: 'season 0001',
            parentId: Value(animeId),
            showId: Value(animeId),
            seasonNumber: const Value(1),
            addedAt: 5000,
            updatedAt: 5000,
          ),
        );
        final animeEpId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.episode,
            libraryType: LibraryTypes.anime,
            title: 'Ep 1',
            sortTitle: 's0001e0001',
            parentId: Value(animeSeasonId),
            showId: Value(animeId),
            seasonNumber: const Value(1),
            episodeNumber: const Value(1),
            addedAt: 5000,
            updatedAt: 5000,
          ),
        );
        final fAnime = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Anime/Ep1.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 5000,
        );
        await pc.repo.linkFile(fAnime, animeEpId);

        final showId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            workKey: const Value('tmdb:tv:8002'),
            kind: LibraryKinds.show,
            libraryType: LibraryTypes.show,
            title: 'Drama Earlier',
            sortTitle: 'drama earlier',
            tmdbId: const Value('8002'),
            metadataSource: const Value('tmdb'),
            sourceAddedAt: const Value(3000),
            scrapedAt: const Value(3000),
            addedAt: 3000,
            updatedAt: 3000,
          ),
        );
        final showSeasonId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.season,
            libraryType: LibraryTypes.show,
            title: 'Season 1',
            sortTitle: 'season 0001',
            parentId: Value(showId),
            showId: Value(showId),
            seasonNumber: const Value(1),
            addedAt: 3000,
            updatedAt: 3000,
          ),
        );
        final showEpId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.episode,
            libraryType: LibraryTypes.show,
            title: 'Ep 1',
            sortTitle: 's0001e0001',
            parentId: Value(showSeasonId),
            showId: Value(showId),
            seasonNumber: const Value(1),
            episodeNumber: const Value(1),
            addedAt: 3000,
            updatedAt: 3000,
          ),
        );
        final fShow = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Shows/Ep1.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 3000,
        );
        await pc.repo.linkFile(fShow, showEpId);

        final pendingMovieId = await pc.repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.pending,
            title: 'Mystery File',
            sortTitle: 'mystery file',
            addedAt: 7000,
            updatedAt: 7000,
          ),
        );
        final fPending = await pc.repo.upsertFile(
          mountId: mount.id,
          path: '/Movies/Mystery.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          modifiedAt: 7000,
        );
        await pc.repo.linkFile(fPending, pendingMovieId);

        await pc.sync.onMountSaved(mount);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await android.sync.syncNow();
        expect(
          (await android.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items,
          hasLength(1),
        );

        // User performs manual match on PC -> calls scans.notifyCatalogMutated()!
        final fakeTmdb = _FakeMetadataProvider('tmdb')
          ..movies['424242'] = const ScrapedTitle(
            source: 'tmdb',
            title: 'Matched Newest Movie',
            tmdbId: '424242',
            year: 2026,
          );
        final scraper = LibraryScraper(pc.db, pc.repo, providers: [fakeTmdb]);
        await scraper.applyManualMatch(
          pendingMovieId,
          const ScrapedCandidate(source: 'tmdb', id: '424242', title: 'Matched Newest Movie', year: 2026),
          asShow: false,
          libraryType: LibraryTypes.movie,
        );
        await pc.repo.refreshSourceAddedTimesForItems([pendingMovieId]);
        pc.scans.notifyCatalogMutated();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await android.sync.syncNow();

        expect((await android.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items, isEmpty);
        final matchedOnAndroid = await android.repo.findByWorkKey('tmdb:movie:424242');
        expect(matchedOnAndroid, isNotNull);
        expect(matchedOnAndroid!.title, 'Matched Newest Movie');
        expect(matchedOnAndroid.libraryType, LibraryTypes.movie);

        // Verify Home hubs: richHubs == true and 'local.recent' comes first interleaved across movie/anime/show!
        expect(android.client.capabilities.richHubs, isTrue);
        android.client.recentlyAddedAllTitle = '最近添加';
        final hubs = await android.client.fetchGlobalHubs(includePlaybackHubs: false);
        expect(hubs.first.id, 'local.recent');
        expect(hubs.first.title, '最近添加');
        expect(hubs.first.type, 'mixed');
        expect(hubs.first.items.map((i) => i.title).toList(), [
          'Matched Newest Movie',
          'Anime Latest',
          'Drama Earlier',
        ]);
        expect(hubs.skip(1).map((h) => h.id).toList(), [
          'local.recent.movie',
          'local.recent.show',
          'local.recent.anime',
        ]);
        final moreItems = await android.client.fetchMoreHubItems('local.recent');
        expect(moreItems.map((i) => i.title).toList(), ['Matched Newest Movie', 'Anime Latest', 'Drama Earlier']);
      },
    );
  });
}
