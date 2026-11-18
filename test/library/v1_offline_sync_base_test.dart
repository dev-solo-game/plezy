import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scraper.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/deterministic_keys.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/library/sync/sync_models.dart';
import 'package:plezy/media/work_identity.dart';
import 'package:plezy/media/work_skip_settings.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/work_skip_settings_store.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/storage/storage_path.dart';

import '../test_helpers/prefs.dart';

class _VirtualMountDriver implements StorageDriver {
  _VirtualMountDriver({required this.kind, this.contents = const {}, this.checkHandler});

  @override
  final StorageKind kind;
  final Map<String, String> contents;
  final Future<void> Function()? checkHandler;

  final Set<String> files = {};

  @override
  Future<void> check() async {
    if (checkHandler != null) {
      await checkHandler!();
    }
  }

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final directory = StoragePath.normalize(path);
    final depth = StoragePath.segments(directory).length;
    final seen = <String, StorageEntry>{};
    for (final file in files) {
      final segments = StoragePath.segments(file);
      if (segments.length <= depth) continue;
      final prefix = depth == 0 ? '' : '/${segments.sublist(0, depth).join('/')}';
      if (depth > 0 && prefix != directory) continue;
      final childPath = '$prefix/${segments[depth]}';
      final isFile = segments.length == depth + 1;
      seen.putIfAbsent(
        childPath,
        () => StorageEntry(path: childPath, name: segments[depth], isDirectory: !isFile, size: isFile ? 1024 : null),
      );
    }
    return seen.values.toList();
  }

  @override
  Future<StorageEntry> stat(String path) => throw UnimplementedError();

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    final raw = contents[StoragePath.normalize(entry.path)];
    if (raw == null) return const Stream.empty();
    return Stream.value(utf8.encode(raw));
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeterministicKeys & MatchStatusRank', () {
    test('normalizes URL encoding, separators, parent traversals, and NFD/NFC Chinese paths identically', () {
      const nfcPath = '/\u52a8\u6f2b/\u4ed9\u9006/Season 1/S01E01.mp4';
      // Decomposed Latin accent + URL encoded Chinese + Windows backslashes.
      const macNfdRaw = '\\Anime\\Cafe\u0301\\..\\Cafe\u0301\\E01.mp4';
      const winNfcRaw = '/Anime/Caf\u00e9/E01.mp4';
      const urlEncoded = '%2F%E5%8A%A8%E6%BC%AB%2F%E4%BB%99%E9%80%86%2FSeason%201%2FS01E01.mp4';

      expect(DeterministicKeys.normalizeMountPath(urlEncoded), nfcPath);
      expect(DeterministicKeys.normalizeMountPath('/../../a//b/./c'), '/a/b/c');

      final macId = DeterministicKeys.generateFileId(
        sourceId: 'src-1',
        mountRelativePath: '\\Anime\\Cafe\u0301\\E01.mp4',
      );
      final winId = DeterministicKeys.generateFileId(sourceId: 'src-1', mountRelativePath: winNfcRaw);
      expect(macId, winId);
      expect(macId, hasLength(32));
      expect(DeterministicKeys.normalizeMountPath(macNfdRaw), '/Anime/Caf\u00e9/E01.mp4');
    });

    test('computes stable canonicalSourceKey across Quark, SMB, and WebDAV variants', () {
      const q1 = StorageMount(
        id: 'uuid-a',
        kind: StorageKind.quark,
        displayName: 'Quark A',
        config: {MountKeys.rootFolderId: '0'},
        secrets: {MountKeys.secretCookie: '{"token":"abc","uid":"888999","nickname":"u"}'},
      );
      const q2 = StorageMount(
        id: 'uuid-b',
        kind: StorageKind.quark,
        displayName: 'Quark B',
        config: {MountKeys.rootFolderId: '0'},
        secrets: {MountKeys.secretCookie: '__pus=xyz; uid=888999; other=1'},
      );
      expect(DeterministicKeys.canonicalSourceKey(q1), 'quark:888999');
      expect(DeterministicKeys.canonicalSourceKey(q2), 'quark:888999');
      expect(DeterministicKeys.deterministicSourceId(q1), 'quark_888999');
      expect(DeterministicKeys.deterministicSourceId(q2), 'quark_888999');

      const s1 = StorageMount(
        id: 's1',
        kind: StorageKind.smb,
        displayName: 'NAS',
        config: {MountKeys.host: 'NAS.LOCAL', MountKeys.share: 'Media', MountKeys.rootPath: r'\Movies\'},
      );
      const s2 = StorageMount(
        id: 's2',
        kind: StorageKind.smb,
        displayName: 'NAS 2',
        config: {MountKeys.host: 'nas.local', MountKeys.share: 'media', MountKeys.rootPath: '/Movies'},
      );
      expect(DeterministicKeys.canonicalSourceKey(s1), DeterministicKeys.canonicalSourceKey(s2));
      expect(DeterministicKeys.deterministicSourceId(s1).contains(':'), isFalse);

      const w1 = StorageMount(
        id: 'w1',
        kind: StorageKind.webdav,
        displayName: 'DAV',
        config: {MountKeys.baseUrl: 'https://NAS.Example.com:443/dav/media/'},
      );
      const w2 = StorageMount(
        id: 'w2',
        kind: StorageKind.webdav,
        displayName: 'DAV 2',
        config: {MountKeys.baseUrl: 'https://nas.example.com/dav/media'},
      );
      expect(DeterministicKeys.canonicalSourceKey(w1), DeterministicKeys.canonicalSourceKey(w2));
    });

    test('enforces four-tier monotonic override rules and merges Quark watermarks', () {
      expect(
        shouldOverrideEntity(
          remoteDeleted: false,
          localDeleted: false,
          remoteMatchStatus: MatchStatusRank.unmatched,
          localMatchStatus: MatchStatusRank.matched,
          remoteUpdatedAt: 999999,
          localUpdatedAt: 100,
        ),
        isFalse,
      );
      expect(
        shouldOverrideEntity(
          remoteDeleted: false,
          localDeleted: false,
          remoteMatchStatus: MatchStatusRank.matchLocked,
          localMatchStatus: MatchStatusRank.matched,
          remoteUpdatedAt: 50,
          localUpdatedAt: 100,
        ),
        isTrue,
      );
      expect(
        shouldOverrideEntity(
          remoteDeleted: false,
          localDeleted: false,
          remoteMatchStatus: MatchStatusRank.matched,
          localMatchStatus: MatchStatusRank.matchLocked,
          remoteUpdatedAt: 200,
          localUpdatedAt: 100,
          explicitUnlock: true,
        ),
        isTrue,
      );
      expect(mergeQuarkCheckpoint('0:1000', '0:2500'), '0:2500');
      expect(mergeQuarkCheckpoint('0:3000', '0:2500'), '0:3000');
      expect(mergeQuarkCheckpoint(null, '0:2500'), '0:2500');
    });
  });

  group('Bangumi identity & NFO offline scraping', () {
    late AppDatabase db;
    late LibraryRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = LibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Bangumi work watch states and skip settings survive index rebuild and carry into TMDB refinement', () async {
      final showId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.show,
          libraryType: LibraryTypes.anime,
          title: 'Frieren',
          sortTitle: 'frieren',
          bangumiId: const Value('400602'),
          metadataSource: const Value('bangumi'),
          scrapedAt: const Value(100),
          addedAt: 100,
          updatedAt: 100,
        ),
      );
      final seasonId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.season,
          libraryType: LibraryTypes.anime,
          title: 'Season 1',
          sortTitle: 'season 1',
          parentId: Value(showId),
          showId: Value(showId),
          seasonNumber: const Value(1),
          addedAt: 100,
          updatedAt: 100,
        ),
      );
      final ep1Id = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.episode,
          libraryType: LibraryTypes.anime,
          title: 'Episode 1',
          sortTitle: 'episode 1',
          parentId: Value(seasonId),
          showId: Value(showId),
          seasonNumber: const Value(1),
          episodeNumber: const Value(1),
          addedAt: 100,
          updatedAt: 100,
        ),
      );

      await repo.markWatched(ep1Id, watched: true);
      final workIdentity = WorkIdentity.resolve(
        source: WorkIdentity.localSource,
        kind: 'show',
        bangumiId: '400602',
      )!;
      expect(workIdentity.provider, 'bangumi');
      await WorkSkipSettingsStore(db).save(
        workIdentity,
        const WorkSkipSettings(introEnabled: true, introStartMs: 10000, introEndMs: 95000),
      );

      // Delete and recreate under a fresh item id -> watch state & skip rules persist.
      await repo.deleteItem(showId);
      final rebuiltShowId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.show,
          libraryType: LibraryTypes.anime,
          title: 'Frieren',
          sortTitle: 'frieren',
          bangumiId: const Value('400602'),
          metadataSource: const Value('bangumi'),
          scrapedAt: const Value(200),
          addedAt: 200,
          updatedAt: 200,
        ),
      );
      final rebuiltSeasonId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.season,
          libraryType: LibraryTypes.anime,
          title: 'Season 1',
          sortTitle: 'season 1',
          parentId: Value(rebuiltShowId),
          showId: Value(rebuiltShowId),
          seasonNumber: const Value(1),
          addedAt: 200,
          updatedAt: 200,
        ),
      );
      final rebuiltEpId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.episode,
          libraryType: LibraryTypes.anime,
          title: 'Episode 1',
          sortTitle: 'episode 1',
          parentId: Value(rebuiltSeasonId),
          showId: Value(rebuiltShowId),
          seasonNumber: const Value(1),
          episodeNumber: const Value(1),
          addedAt: 200,
          updatedAt: 200,
        ),
      );
      expect((await repo.getItem(rebuiltEpId))!.isWatched, isTrue);

      // Refining with TMDB id carries Bangumi watch state into TMDB state.
      await repo.updateItem(rebuiltShowId, const LibraryItemsCompanion(tmdbId: Value('209867')));
      final tmdbKey = const WorkIdentity(
        source: WorkIdentity.localSource,
        kind: 'show',
        provider: 'tmdb',
        externalId: '209867',
      ).stateKey(season: 1, episode: 1);
      final carried = await (db.select(db.workWatchStates)..where((t) => t.stateKey.equals(tmdbKey))).getSingleOrNull();
      expect(carried?.watched, isTrue);
    });

    test('scrapes movie and show with episode NFOs completely offline and locks metadata at Level 4', () async {
      await db
          .into(db.mounts)
          .insert(MountsCompanion.insert(id: 'm1', kind: 'local', displayName: 'Disk', configJson: '{}', createdAt: 0));
      const mount = StorageMount(id: 'm1', kind: StorageKind.local, displayName: 'Disk');
      final contents = <String, String>{
        '/Movies/Dune (2024)/dune.nfo': '''
          <movie>
            <title>沙丘2</title>
            <uniqueid type="tmdb">693134</uniqueid>
            <year>2024</year>
            <genre>科幻</genre>
          </movie>
        ''',
        '/Shows/TestShow/tvshow.nfo': '''
          <tvshow>
            <title>仙逆</title>
            <tmdbid>235412</tmdbid>
            <year>2023</year>
          </tvshow>
        ''',
        '/Shows/TestShow/Season 1/S01E01.nfo': '''
          <episodedetails>
            <title>第一集：离乡</title>
            <episode>1</episode>
            <plot>王林踏入修真界</plot>
          </episodedetails>
        ''',
      };
      final driver = _VirtualMountDriver(kind: StorageKind.local, contents: contents)
        ..files.addAll([
          '/Movies/Dune (2024)/dune.mkv',
          '/Movies/Dune (2024)/dune.nfo',
          '/Shows/TestShow/Season 1/S01E01.mp4',
          '/Shows/TestShow/Season 1/S01E01.nfo',
          '/Shows/TestShow/tvshow.nfo',
        ]);

      await LibraryScanner(db, repo).scan(mount, driver);
      final scraper = LibraryScraper(
        db,
        repo,
        providers: const [],
        readText: (_, path) async => contents[StoragePath.normalize(path)],
      );
      final summary = await scraper.scrapePending();
      expect(summary.matched, 2);
      expect(summary.skipped, 0);

      final movieRow = await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.movie))).getSingle();
      expect((movieRow.title, movieRow.tmdbId, movieRow.metadataSource, movieRow.locked), ('沙丘2', '693134', 'nfo', true));
      final movieFile = (await repo.versionsOf(movieRow.id)).single;
      expect((movieFile.matchState, movieFile.matchLocked), (LibraryMatchStates.matched, true));
      expect(MatchStatusRank.fromItem(movieRow), MatchStatusRank.matchLocked);

      final showRow = await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.show))).getSingle();
      expect((showRow.title, showRow.tmdbId, showRow.locked), ('仙逆', '235412', true));
      final epRow = (await repo.episodesOfShow(showRow.id)).single.item;
      expect((epRow.title, epRow.summary, epRow.metadataSource), ('第一集：离乡', '王林踏入修真界', 'nfo'));
    });
  });

  group('Mount filtering, probing, failover, offline protection & JIT refresh', () {
    late AppDatabase db;
    late LibraryRepository repo;
    late MountRegistry registry;

    setUp(() {
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = LibraryRepository(db);
      registry = MountRegistry(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('includePaths traverses ancestors and excludePaths prunes newly excluded files on rescan', () async {
      const mount = StorageMount(
        id: 'm_filter',
        kind: StorageKind.webdav,
        displayName: 'NAS',
        config: {
          MountKeys.baseUrl: 'https://nas.example/dav',
          MountKeys.includePaths: ['/Media/Movies'],
        },
      );
      await registry.upsert(mount);
      final driver = _VirtualMountDriver(kind: StorageKind.webdav)
        ..files.addAll([
          '/Media/root.mkv',
          '/Media/Clips/clip.mkv',
          '/Media/Movies/FilmA (2024).mkv',
          '/Media/Movies/Skip/Extra (2024).mkv',
        ]);

      final scanner = LibraryScanner(db, repo);
      final first = await scanner.scan(mount, driver);
      expect(first.videos, 2);

      // Excluding `/Media/Movies/Skip` removes it on next scan.
      const updated = StorageMount(
        id: 'm_filter',
        kind: StorageKind.webdav,
        displayName: 'NAS',
        config: {
          MountKeys.baseUrl: 'https://nas.example/dav',
          MountKeys.includePaths: ['/Media/Movies'],
          MountKeys.excludePaths: ['/Media/Movies/Skip'],
        },
      );
      await registry.upsert(updated);
      final second = await scanner.scan(updated, driver);
      expect(second.videos, 1);
      expect(second.removed, 1);
      final remaining = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals('m_filter'))).get();
      expect(remaining.map((f) => f.path), ['/Media/Movies/FilmA (2024).mkv']);
    });

    test('probes primary/fallback failover, protects offline mounts, filters UI queries, and prioritizes online versions', () async {
      const nasMount = StorageMount(
        id: 'nas',
        kind: StorageKind.webdav,
        displayName: 'Home NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.2:5244/dav'},
      );
      const ddnsMount = StorageMount(
        id: 'ddns',
        kind: StorageKind.webdav,
        displayName: 'DDNS NAS',
        config: {
          MountKeys.baseUrl: 'http://192.168.1.50:5244/dav',
          MountKeys.fallbackUrl: 'https://ddns.example:5244/dav',
        },
      );
      const quarkMount = StorageMount(
        id: 'quark',
        kind: StorageKind.quark,
        displayName: 'Quark',
        config: {MountKeys.rootFolderId: '0'},
        secrets: {MountKeys.secretCookie: 'uid=1'},
      );

      await registry.upsert(nasMount);
      await registry.upsert(ddnsMount);
      await registry.upsert(quarkMount);

      var nasReachable = false;
      final manager = MountManager(
        registry,
        driverFactory: (mount, {bool useFallback = false}) {
          if (mount.id == 'nas') {
            return _VirtualMountDriver(
              kind: StorageKind.webdav,
              checkHandler: () async {
                if (!nasReachable) throw const SocketException('unreachable');
              },
            );
          }
          if (mount.id == 'ddns') {
            return _VirtualMountDriver(
              kind: StorageKind.webdav,
              checkHandler: () async {
                if (!useFallback) throw const SocketException('lan unreachable');
              },
            );
          }
          return _VirtualMountDriver(kind: StorageKind.quark);
        },
      );
      addTearDown(manager.dispose);

      repo.hiddenMountIds = () => manager.hiddenOfflineMountIds;
      await manager.probeAll(timeout: const Duration(milliseconds: 500));

      expect(manager.statusOf('nas'), MountOnlineStatus.offline);
      expect(manager.statusOf('ddns'), MountOnlineStatus.onlineFallback);
      expect(manager.statusOf('quark'), MountOnlineStatus.onlinePrimary);

      // Seed one NAS-only movie and one shared movie (NAS + Quark).
      final nasOnlyId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'NAS Only',
          sortTitle: 'nas only',
          scrapedAt: const Value(1),
          addedAt: 1,
          updatedAt: 1,
        ),
      );
      await repo.linkFile(
        await repo.upsertFile(
          mountId: 'nas',
          path: '/Movies/NAS Only.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: 20000,
        ),
        nasOnlyId,
      );

      final sharedId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'Shared Film',
          sortTitle: 'shared film',
          scrapedAt: const Value(1),
          addedAt: 2,
          updatedAt: 2,
        ),
      );
      await repo.linkFile(
        await repo.upsertFile(
          mountId: 'nas',
          path: '/Movies/Shared 4K.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: 50000,
        ),
        sharedId,
      );
      await repo.linkFile(
        await repo.upsertFile(
          mountId: 'quark',
          path: '/Movies/Shared 1080p.mkv',
          role: LibraryFileRoles.video,
          scanId: 1,
          size: 10000,
        ),
        sharedId,
      );

      // Offline mount scan is blocked and does not delete existing files.
      final scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: manager);
      addTearDown(scans.dispose);
      expect(await scans.scan(nasMount), isNull);
      expect(await repo.versionsOf(nasOnlyId), hasLength(1));

      // Offline-only movie is hidden from shelves while shared movie remains visible.
      final visiblePage = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(visiblePage.items.map((v) => v.item.title), ['Shared Film']);

      // Showing offline mounts reveals the NAS-only movie again.
      manager.setShowOfflineMounts(true);
      final allPage = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(allPage.items.map((v) => v.item.title), containsAll(['NAS Only', 'Shared Film']));
      manager.setShowOfflineMounts(false);

      // Smart version ordering puts online Quark ahead of offline NAS even though NAS is larger.
      final client = LocalLibraryClient(repository: repo, mounts: manager);
      addTearDown(client.close);
      await client.refreshMounts();
      final detailed = await client.fetchItem('$sharedId');
      expect(detailed!.mediaVersions!.first.parts.first.file, '/Movies/Shared 1080p.mkv');
      expect(detailed.mediaVersions!.first.parts.first.accessible, isTrue);
      expect(detailed.mediaVersions!.last.parts.first.accessible, isFalse);

      // Attempting to play an offline-only movie fails immediately instead of hanging.
      final nasOnlyMeta = (await client.fetchItem('$nasOnlyId'))!;
      await expectLater(
        () => client.getPlaybackInitialization(
          PlaybackInitializationOptions(metadata: nasOnlyMeta, selectedMediaIndex: 0),
        ),
        throwsA(
          isA<PlaybackException>().having((e) => e.reason, 'reason', PlaybackFailureReason.localFileUnavailable),
        ),
      );

      // Re-probing after NAS comes back online restores visibility.
      nasReachable = true;
      await manager.probeAll(timeout: const Duration(milliseconds: 500));
      expect(manager.statusOf('nas'), MountOnlineStatus.onlinePrimary);
    });

    test('refreshSingleDirectory skips unchanged folders and picks up newly added episodes via JIT', () async {
      const mount = StorageMount(
        id: 'm_jit',
        kind: StorageKind.webdav,
        displayName: 'WebDAV',
        config: {MountKeys.baseUrl: 'https://nas.example/dav'},
      );
      await registry.upsert(mount);
      final driver = _VirtualMountDriver(kind: StorageKind.webdav)
        ..files.addAll(['/Anime/XianNi/Season 1/S01E01.mp4']);

      final scanner = LibraryScanner(db, repo);
      await scanner.scan(mount, driver);
      expect(await scanner.refreshSingleDirectory(mount, driver, '/Anime/XianNi/Season 1'), isFalse);

      driver.files.add('/Anime/XianNi/Season 1/S01E02.mp4');
      expect(await scanner.refreshSingleDirectory(mount, driver, '/Anime/XianNi/Season 1'), isTrue);
      final show = await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.show))).getSingle();
      expect((await repo.episodesOfShow(show.id)), hasLength(2));
    });
  });

  group('Schema v35 SyncOutbox & four-node playback throttling', () {
    test('enqueues SyncOutbox only on pause, seek+3s debounce, 90s heartbeat, and stop while saving locally', () async {
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();
      var now = DateTime.utc(2026, 11, 16, 10, 0, 0);
      await withClock(Clock(() => now), () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final repo = LibraryRepository(db);
        final manager = MountManager(MountRegistry(db));
        final client = LocalLibraryClient(
          repository: repo,
          mounts: manager,
          seekDebounceDuration: const Duration(milliseconds: 50),
        );
        try {
          final movieId = await repo.insertItem(
            LibraryItemsCompanion.insert(
              kind: LibraryKinds.movie,
              libraryType: LibraryTypes.movie,
              title: 'Inception',
              sortTitle: 'inception',
              tmdbId: const Value('27205'),
              metadataSource: const Value('tmdb'),
              scrapedAt: const Value(1),
              addedAt: 1,
              updatedAt: 1,
            ),
          );

          await client.reportPlaybackStarted(
            itemId: '$movieId',
            position: Duration.zero,
            duration: const Duration(hours: 2),
          );
          expect(await SyncLocalStore(db).readPendingOutbox(), isEmpty);

          // Regular 10s ticks save locally without flooding SyncOutbox.
          now = now.add(const Duration(seconds: 10));
          await client.reportPlaybackProgress(
            itemId: '$movieId',
            position: const Duration(seconds: 10),
            duration: const Duration(hours: 2),
          );
          now = now.add(const Duration(seconds: 10));
          await client.reportPlaybackProgress(
            itemId: '$movieId',
            position: const Duration(seconds: 20),
            duration: const Duration(hours: 2),
          );
          expect((await repo.getItem(movieId))!.state!.positionMs, 20000);
          expect(await SyncLocalStore(db).readPendingOutbox(), isEmpty);

          // Node 1: Pause enqueues immediately.
          await client.reportPlaybackProgress(
            itemId: '$movieId',
            position: const Duration(seconds: 20),
            duration: const Duration(hours: 2),
            isPaused: true,
          );
          final afterPause = await SyncLocalStore(db).readPendingOutbox();
          expect(afterPause, hasLength(1));
          final pauseOpId = afterPause.single.opId;

          // Node 3: Seek jump waits debounce before enqueueing.
          now = now.add(const Duration(seconds: 1));
          await client.reportPlaybackProgress(
            itemId: '$movieId',
            position: const Duration(minutes: 10),
            duration: const Duration(hours: 2),
            isPaused: false,
          );
          expect((await SyncLocalStore(db).readPendingOutbox()).single.opId, pauseOpId);
          now = now.add(const Duration(seconds: 3));
          await Future<void>.delayed(const Duration(milliseconds: 120));
          final afterSeek = await SyncLocalStore(db).readPendingOutbox();
          expect(afterSeek, hasLength(1));
          final seekOpId = afterSeek.single.opId;
          expect(seekOpId, isNot(pauseOpId));

          // Acknowledging old pauseOpId must NOT delete the newer seekOpId row.
          await SyncLocalStore(db).deleteAcceptedOutbox([pauseOpId]);
          expect((await SyncLocalStore(db).readPendingOutbox()).single.opId, seekOpId);

          // Node 4: 90s continuous playback heartbeat refreshes opId.
          now = now.add(const Duration(seconds: 90));
          await client.reportPlaybackProgress(
            itemId: '$movieId',
            position: const Duration(minutes: 11, seconds: 30),
            duration: const Duration(hours: 2),
            isPaused: false,
          );
          final afterHeartbeat = await SyncLocalStore(db).readPendingOutbox();
          final heartbeatOpId = afterHeartbeat.single.opId;
          expect(heartbeatOpId, isNot(seekOpId));

          // Node 2: Stop enqueues immediately and accepting its opId clears the outbox.
          now = now.add(const Duration(seconds: 5));
          await client.reportPlaybackStopped(
            itemId: '$movieId',
            position: const Duration(minutes: 12),
            duration: const Duration(hours: 2),
          );
          final afterStop = await SyncLocalStore(db).readPendingOutbox();
          expect(afterStop, hasLength(1));
          expect(afterStop.single.opId, isNot(heartbeatOpId));
          expect(jsonDecode(afterStop.single.payloadJson)['position_ms'], 720000);

          await SyncLocalStore(db).deleteAcceptedOutbox([afterStop.single.opId]);
          expect(await SyncLocalStore(db).readPendingOutbox(), isEmpty);
        } finally {
          client.close();
          await manager.dispose();
          await db.close();
        }
      });
    });

    test('MountRegistry.findDuplicate detects duplicate Quark, SMB, and WebDAV sources while allowing self-edit', () async {
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final registry = MountRegistry(db);

      const q1 = StorageMount(
        id: 'quark-1',
        kind: StorageKind.quark,
        displayName: 'Primary Quark',
        config: {MountKeys.rootFolderId: '0'},
        secrets: {MountKeys.secretCookie: 'uid=888999; __pus=old'},
      );
      const smb1 = StorageMount(
        id: 'smb-1',
        kind: StorageKind.smb,
        displayName: 'Home SMB',
        config: {MountKeys.host: 'NAS.LOCAL', MountKeys.share: 'Media', MountKeys.rootPath: '/Movies'},
      );
      await registry.upsert(q1);
      await registry.upsert(smb1);

      // Different mount ID + rotated cookie with same uid & rootFolderId -> duplicate detected.
      expect(
        (await registry.findDuplicate(
          const StorageMount(
            id: 'quark-2',
            kind: StorageKind.quark,
            displayName: 'Duplicate Quark',
            config: {MountKeys.rootFolderId: '0'},
            secrets: {MountKeys.secretCookie: 'uid=888999; __pus=new'},
          ),
        ))?.id,
        'quark-1',
      );
      // Editing the same mount ID (passing ignoreId) -> allowed.
      expect(await registry.findDuplicate(q1, ignoreId: q1.id), isNull);
      // Creating a new mount whose deterministic ID matches an existing mount without ignoreId -> duplicate detected.
      expect((await registry.findDuplicate(q1))?.id, 'quark-1');
      // Same Quark uid even with different folder is still duplicate (one mount per Quark account, multiple dirs via includePaths).
      expect(
        (await registry.findDuplicate(
          const StorageMount(
            id: 'quark-sub',
            kind: StorageKind.quark,
            displayName: 'Anime Folder',
            config: {MountKeys.rootFolderId: 'folder-anime'},
            secrets: {MountKeys.secretCookie: 'uid=888999; __pus=new'},
          ),
        ))?.id,
        'quark-1',
      );
      // Different Quark uid -> allowed.
      expect(
        await registry.findDuplicate(
          const StorageMount(
            id: 'quark-other',
            kind: StorageKind.quark,
            displayName: 'Second Quark',
            config: {MountKeys.rootFolderId: '0'},
            secrets: {MountKeys.secretCookie: 'uid=999111; __pus=new'},
          ),
        ),
        isNull,
      );
      // SMB case-insensitive host/share + Windows backslash path -> duplicate detected.
      expect(
        (await registry.findDuplicate(
          const StorageMount(
            id: 'smb-2',
            kind: StorageKind.smb,
            displayName: 'SMB Dup',
            config: {MountKeys.host: 'nas.local', MountKeys.share: 'media', MountKeys.rootPath: r'\Movies\'},
          ),
        ))?.id,
        'smb-1',
      );
    });
  });
}
