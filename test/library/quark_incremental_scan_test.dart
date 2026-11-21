import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/storage/stream_variant.dart';

Map<String, Object> _file(String id, String name, int time, {String parent = 'season'}) => {
  'fid': id,
  'pdir_fid': parent,
  'file_name': name,
  'dir': false,
  'updated_at': time,
  'size': 120,
};

class _MountManager extends MountManager {
  _MountManager(super.registry, this.driver);

  final QuarkStorageDriver driver;

  @override
  StorageDriver driverFor(StorageMount mount) => driver;

  @override
  Future<List<StreamVariant>> streamVariants(StorageMount mount, StorageEntry entry) async => const [];
}

class _MountRegistry extends MountRegistry {
  _MountRegistry(super.db, this.mount);

  StorageMount mount;

  @override
  Future<List<StorageMount>> list() async => [mount];

  @override
  Future<StorageMount?> get(String id) async => id == mount.id ? mount : null;
}

void main() {
  const mount = StorageMount(
    id: 'quark',
    kind: StorageKind.quark,
    displayName: 'Quark',
    config: {MountKeys.rootFolderId: 'library', MountKeys.quarkMode: 'pc'},
  );
  const root = {'fid': 'library', 'file_name': 'Mounted'};
  const season = {'fid': 'season', 'file_name': 'Series', 'dir': true};
  const baseline = 1000000;
  const next = baseline + 1000;
  late AppDatabase db;
  late LibraryScanner scanner;
  late QuarkStorageDriver driver;
  late HttpServer server;
  late List<Map<String, Object>> search;
  late List<Map<String, Object>> seasonFiles;
  late List<String> folderReads;
  late List<String> ancestryReads;
  late List<int> searchPages;
  late List<String?> searchCookies;
  late bool failSecondPage;
  late bool failFolderReads;
  late int? searchError;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scanner = LibraryScanner(db, LibraryRepository(db));
    await db
        .into(db.mounts)
        .insert(
          MountsCompanion.insert(
            id: mount.id,
            kind: 'quark',
            displayName: 'Quark',
            configJson: jsonEncode(mount.config),
            createdAt: 0,
          ),
        );
    search = [_file('old', 'Old Movie (2022).mkv', baseline)];
    seasonFiles = [...search];
    folderReads = [];
    ancestryReads = [];
    searchPages = [];
    searchCookies = [];
    failSecondPage = false;
    failFolderReads = false;
    searchError = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      final query = request.uri.queryParameters;
      final page = int.parse(query['_page']!);
      final size = int.parse(query['_size']!);
      final isSearch = request.uri.path.endsWith('/file/search');
      final folder = query['pdir_fid'];
      final ancestry = query['_fetch_full_path'] == '1';
      if (isSearch) {
        expect(query['cat'], 'video');
        searchPages.add(page);
        searchCookies.add(request.headers.value(HttpHeaders.cookieHeader));
        if (searchError != null || (page == 2 && failSecondPage)) {
          response.statusCode = searchError ?? HttpStatus.serviceUnavailable;
          await response.close();
          return;
        }
      } else if (ancestry) {
        ancestryReads.add(folder!);
      } else {
        folderReads.add(folder!);
        if (failFolderReads) {
          response.statusCode = HttpStatus.serviceUnavailable;
          await response.close();
          return;
        }
      }
      final rows = isSearch ? search : (folder == 'library' ? [season] : seasonFiles);
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'code': 0,
          'data': {
            'list': rows.skip((page - 1) * size).take(size).toList(),
            if (ancestry)
              'full_path': folder == 'season'
                  ? [root, season]
                  : [
                      {'fid': 'outside', 'file_name': 'Outside'},
                    ],
          },
        }),
      );
      await response.close();
    });
    driver = QuarkStorageDriver(
      cookie: 'token=test&uid=1',
      mode: QuarkMode.pc,
      rootFolderId: 'library',
      requestInterval: Duration.zero,
      apiBase: Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive'),
    );
  });

  tearDown(() async {
    await driver.close();
    await server.close(force: true);
    await db.close();
  });

  Future<ScanResult> incremental({ScanCancelToken? cancel}) =>
      scanner.scanQuarkIncremental(mount, driver, cancel: cancel ?? ScanCancelToken());

  Future<String?> checkpoint() async => (await db.select(db.libraryScanStates).getSingle()).quarkCheckpoint;

  void arrangeChanges() {
    final renamed = _file('old', 'Renamed (2022).mkv', next);
    final added = _file('new', 'Series.S01E01.mkv', next);
    search = [
      renamed,
      {'fid': 'dir-inv', 'pdir_fid': 'library', 'file_name': 'Series', 'dir': true, 'updated_at': next + 5000},
      for (var i = 0; i < 98; i++) _file('pic-$i', 'Picture $i.jpg', next, parent: 'outside'),
      added,
      _file('historical', 'Historical.mkv', baseline - 60001, parent: 'outside'),
    ];
    seasonFiles = [renamed, added];
    folderReads.clear();
    searchPages.clear();
  }

  test('follows equal timestamps across pages, filters by mount, and preserves a renamed file', () async {
    expect(await scanner.hasQuarkBaseline(mount), isFalse);
    await scanner.scan(mount, driver);
    final old = await db.select(db.libraryFiles).getSingle();
    await LibraryRepository(db).updateFile(old.id, const LibraryFilesCompanion(matchLocked: Value(true)));
    expect(await checkpoint(), 'library:$baseline');
    arrangeChanges();

    await incremental();
    expect(searchPages, [1, 2]);
    expect(folderReads, ['season']);
    final files = await db.select(db.libraryFiles).get();
    expect(files.map((row) => row.remoteId), unorderedEquals(['old', 'new']));
    final renamed = files.singleWhere((row) => row.remoteId == 'old');
    expect((renamed.id, renamed.itemId, renamed.matchLocked), (old.id, old.itemId, true));
    expect(renamed.path, '/Series/Renamed (2022).mkv');
    expect(await checkpoint(), 'library:$next');

    folderReads.clear();
    ancestryReads.clear();
    final idleSeen = <int>[];
    await scanner.scanQuarkIncremental(
      mount,
      driver,
      cancel: ScanCancelToken(),
      onProgress: (progress) => idleSeen.add(progress.filesSeen),
    );
    expect(idleSeen, [0, 0]);
    expect(ancestryReads, isEmpty);
    expect(folderReads, isEmpty);
    seasonFiles.removeLast();
    await incremental();
    expect(await db.select(db.libraryFiles).get(), hasLength(2));
    await scanner.scan(mount, driver, restart: true);
    expect(await db.select(db.libraryFiles).get(), hasLength(1));
  });

  test('keeps the checkpoint and library intact after a failed page or cancellation', () async {
    await scanner.scan(mount, driver);
    arrangeChanges();
    failSecondPage = true;
    await expectLater(incremental(), throwsA(isA<StorageException>()));
    expect(await checkpoint(), 'library:$baseline');
    expect((await db.select(db.libraryFiles).getSingle()).path, '/Series/Old Movie (2022).mkv');
    expect(folderReads, isEmpty);

    failSecondPage = false;
    final token = ScanCancelToken();
    final result = await scanner.scanQuarkIncremental(mount, driver, cancel: token, onProgress: (_) => token.cancel());
    expect(result.cancelled, isTrue);
    expect(await checkpoint(), 'library:$baseline');
    expect(await db.select(db.libraryFiles).get(), hasLength(1));
    await incremental();
    expect(await checkpoint(), 'library:$next');
  });

  test('detects a new file sharing the baseline timestamp while skipping the already-indexed file', () async {
    await scanner.scan(mount, driver);
    expect(await checkpoint(), 'library:$baseline');

    final sameWindow = _file('new-same-ts', 'Same Minute (2022).mkv', baseline);
    search = [sameWindow, ...search];
    seasonFiles = [...search];
    folderReads.clear();
    ancestryReads.clear();

    final seen = <int>[];
    final result = await scanner.scanQuarkIncremental(
      mount,
      driver,
      cancel: ScanCancelToken(),
      onProgress: (progress) => seen.add(progress.filesSeen),
    );
    expect(seen, [1, 1]);
    expect(result.hasChanges, isTrue);
    expect(ancestryReads, ['season']);
    expect(folderReads, ['season']);
    expect(
      (await db.select(db.libraryFiles).get()).map((row) => row.remoteId),
      unorderedEquals(['old', 'new-same-ts']),
    );
  });

  test('recently added prefers the Quark modification time and falls back to creation time', () async {
    search = [
      {..._file('old', 'Old Movie (2022).mkv', baseline), 'created_at': baseline - 1000},
    ];
    final createdOnly = {
      ..._file('created-only', 'Created Only (2024).mkv', 0)..remove('updated_at'),
      'created_at': baseline - 200,
    };
    seasonFiles = [...search, createdOnly];
    await scanner.scan(mount, driver);

    final newMovie = {..._file('new', 'New Movie (2025).mkv', next), 'created_at': next - 500};
    search = [newMovie, ...search];
    seasonFiles = [...search, createdOnly];
    await incremental();

    final titles = await db.select(db.libraryItems).get();
    expect(
      titles.map((item) => (item.title, item.sourceAddedAt)),
      unorderedEquals([
        ('Old Movie', baseline),
        ('New Movie', next),
        ('Created Only', baseline - 200),
      ]),
    );
  });

  test('subtitle-only uploads are found via refreshDirectorySubtitles without listing directories on playback', () async {
    seasonFiles.add(_file('sub-en', 'Old Movie (2022).en.srt', baseline));
    await scanner.scan(mount, driver);
    folderReads.clear();
    final repository = LibraryRepository(db);
    final mounts = _MountManager(MountRegistry(db), driver);
    addTearDown(mounts.dispose);
    LocalLibraryClient client() => LocalLibraryClient(repository: repository, mounts: mounts);
    final indexedVideo = (await db.select(db.libraryFiles).get()).singleWhere((file) => file.remoteId == 'old');
    final media = (await client().fetchItem('${indexedVideo.itemId}'))!;
    final options = PlaybackInitializationOptions(metadata: media, selectedMediaIndex: 0);
    seasonFiles.add(_file('sub-zh', 'Old Movie (2022).chs.ass', next));

    final initialPlayback = await client().getPlaybackInitialization(options);
    expect(initialPlayback.subtitleSidecars.map((sidecar) => sidecar.track.language), ['en']);
    expect(folderReads, isEmpty);
    expect(await repository.subtitlesOf(indexedVideo.id), hasLength(1));

    final added = await client().refreshDirectorySubtitles(media.id);
    expect(added, 1);
    expect(folderReads, ['season']);

    final reloadedPlayback = await client().getPlaybackInitialization(options);
    expect(reloadedPlayback.subtitleSidecars.map((sidecar) => sidecar.track.language), unorderedEquals(['en', 'zh-Hans']));
    expect(folderReads, ['season']);
    expect(await repository.subtitlesOf(indexedVideo.id), hasLength(2));
  });

  test('an existing Web mount can establish a baseline and update through the service', () async {
    // Older Web mounts omit the login mode in their saved configuration.
    final webMount = mount.copyWith(config: {MountKeys.rootFolderId: 'library'});
    await db.update(db.mounts).write(MountsCompanion(configJson: Value(jsonEncode(webMount.config))));
    await driver.close();
    driver = QuarkStorageDriver(
      cookie: '__puus=test-web-cookie',
      rootFolderId: 'library',
      requestInterval: Duration.zero,
      apiBase: Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive'),
    );
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(MountRegistry(db), driver),
    );
    addTearDown(scans.dispose);
    expect(LibraryScanService.supportsIncremental(webMount), isTrue);
    expect(LibraryScanService.supportsIncremental(mount.copyWith(config: {MountKeys.quarkMode: 'tv'})), isFalse);
    expect(await scans.hasIncrementalBaseline(webMount), isFalse);
    expect(await scans.updateMounts([webMount], LibraryUpdateMode.full), isTrue);
    expect(await scans.hasIncrementalBaseline(webMount), isTrue);
    expect(await checkpoint(), 'library:$baseline');

    arrangeChanges();
    expect(await scans.updateMounts([webMount], LibraryUpdateMode.incremental), isTrue);
    expect(scans.statusOf(webMount.id).error, isNull);
    expect(await checkpoint(), 'library:$next');
    expect((await db.select(db.libraryFiles).get()).map((row) => row.remoteId), unorderedEquals(['old', 'new']));
    expect(searchCookies, everyElement('__puus=test-web-cookie'));
  });

  test('home full scan publishes the library change once after scraping finishes', () async {
    final scraping = Completer<void>();
    final finishScraping = Completer<void>();
    var changes = 0;
    final seenModes = <bool>[];
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(MountRegistry(db), driver),
      onLibraryChanged: () => changes++,
      scrape: ({
        retryUnmatched = false,
        mountIds,
        refreshMatched = false,
        allowKindChange = true,
        refreshBeforeMs,
        isCancelled,
        onProgress,
      }) async {
        expect(mountIds, {mount.id});
        seenModes.add(refreshMatched);
        onProgress?.call(1, 1);
        if (!scraping.isCompleted) scraping.complete();
        await finishScraping.future;
        return const LibraryScrapeOutcome(hasChanges: true);
      },
    );
    addTearDown(scans.dispose);
    final fullScan = scans.scanAllMounts();
    await Future.any([scraping.future, fullScan.then((_) => fail('Scraping did not start'))]);
    expect(changes, 0);
    expect(scans.update?.scraping, isTrue);
    finishScraping.complete();
    expect(await fullScan, isTrue);
    expect(changes, 1);
    expect(seenModes, [false, true]);
    expect(scans.update, isNull);
  });

  test('holds the update lock through scraping and passes cancellation to the scraper', () async {
    final scrapes = Completer<void>();
    final finishScraping = Completer<void>();
    final cancelled = Completer<bool>();
    final seenModes = <bool>[];
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(MountRegistry(db), driver),
      scrape: ({
        retryUnmatched = false,
        mountIds,
        refreshMatched = false,
        allowKindChange = true,
        refreshBeforeMs,
        isCancelled,
        onProgress,
      }) async {
        expect(mountIds, {mount.id});
        seenModes.add(refreshMatched);
        if (!refreshMatched) {
          expect(allowKindChange, isFalse);
          return const LibraryScrapeOutcome();
        }
        if (!scrapes.isCompleted) scrapes.complete();
        await finishScraping.future;
        if (!cancelled.isCompleted) cancelled.complete(isCancelled!());
        return const LibraryScrapeOutcome();
      },
    );
    addTearDown(scans.dispose);
    final running = scans.updateMounts([mount], LibraryUpdateMode.full);
    expect(await scans.updateMounts([mount], LibraryUpdateMode.incremental), isFalse);
    await Future.any([scrapes.future, running.then((_) => fail('Scraping did not start'))]);
    expect(scans.update?.scraping, isTrue);
    expect(await scans.updateMounts([mount], LibraryUpdateMode.incremental), isFalse);
    scans.cancelUpdate(scans.update!);
    expect(scans.update?.cancel.isCancelled, isTrue);
    finishScraping.complete();
    expect(await running, isTrue);
    expect(await cancelled.future, isTrue);
    expect(seenModes, [false, true]);
    expect(scans.update, isNull);
  });

  test('restarts metadata lookup once after a settings change during an incremental update', () async {
    await scanner.scan(mount, driver);
    final started = Completer<void>();
    final release = Completer<void>();
    final restarted = Completer<bool>();
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(MountRegistry(db), driver),
      scrape: ({
        retryUnmatched = false,
        mountIds,
        refreshMatched = false,
        allowKindChange = true,
        refreshBeforeMs,
        isCancelled,
        onProgress,
      }) async {
        if (mountIds == null) {
          if (!restarted.isCompleted) restarted.complete(retryUnmatched);
        } else {
          if (!started.isCompleted) started.complete();
          await release.future;
          expect(isCancelled!(), isTrue);
        }
        return const LibraryScrapeOutcome();
      },
    );
    addTearDown(scans.dispose);
    final update = scans.updateMounts([mount], LibraryUpdateMode.incremental);
    await Future.any([started.future, update.then((_) => fail('Scraping did not start'))]);
    await scans.scrapeLibrary(retryUnmatched: true, restart: true);
    await scans.scrapeLibrary(restart: true);
    release.complete();
    await update;
    expect(await restarted.future, isTrue);
  });

  test('automatic checks share the persisted one-minute interval and only run incremental scans', () async {
    var now = DateTime(2026, 11, 14);
    var canRun = true;
    var notifications = 0;
    final registry = _MountRegistry(db, mount.copyWith(secrets: {MountKeys.secretCookie: 'test'}));
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(registry, driver),
      onLibraryChanged: () => notifications++,
    );
    addTearDown(scans.dispose);
    Future<Duration> check() => scans.checkIncrementalUpdates(canRun: () => canRun);

    await withClock(Clock(() => now), () async {
      await check();
      expect(searchPages, isEmpty, reason: 'no baseline must never trigger an automatic full scan');
      await scans.updateMounts([mount], LibraryUpdateMode.full);
      searchPages.clear();
      folderReads.clear();
      notifications = 0;

      now = now.add(const Duration(seconds: 59));
      expect(await check(), const Duration(seconds: 1));
      expect(searchPages, isEmpty);
      now = now.add(const Duration(seconds: 1));
      canRun = false;
      await check();
      expect(searchPages, isEmpty);
      canRun = true;
      await Future.wait([check(), check()]);
      expect(searchPages, [1]);
      expect(folderReads, isEmpty);
      expect(notifications, 0);
      await check();
      expect(searchPages, [1], reason: 'a resume immediately after a successful check must not scan again');

      arrangeChanges();
      now = now.add(const Duration(minutes: 1));
      await check();
      expect(searchPages, [1, 2]);
      expect(folderReads, ['season']);
      expect(notifications, 1);
      expect(await checkpoint(), 'library:$next');
    });
  });

  test('automatic checks back off after rate limits and wait for new credentials after unauthorized', () async {
    var now = DateTime(2026, 11, 14);
    final registry = _MountRegistry(db, mount.copyWith(secrets: {MountKeys.secretCookie: 'old'}));
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(registry, driver),
    );
    addTearDown(scans.dispose);
    Future<Duration> check() => scans.checkIncrementalUpdates(canRun: () => true);

    await withClock(Clock(() => now), () async {
      await scanner.scan(mount, driver);
      searchPages.clear();
      now = now.add(const Duration(minutes: 1));
      searchError = HttpStatus.tooManyRequests;
      await check();
      expect(scans.updateError?.mode, LibraryUpdateMode.incremental);
      expect(scans.updateError?.message, contains('429'));
      now = now.add(const Duration(minutes: 1));
      await check();
      expect(searchPages, [1]);

      now = now.add(const Duration(minutes: 1));
      searchError = HttpStatus.unauthorized;
      await check();
      now = now.add(const Duration(hours: 1));
      await check();
      expect(searchPages, [1, 1]);
      expect(await checkpoint(), 'library:$baseline');
      searchError = null;
      registry.mount = mount.copyWith(secrets: {MountKeys.secretCookie: 'new'});
      await check();
      expect(searchPages, [1, 1, 1]);
      expect(scans.updateError, isNull);
      expect(scans.statusOf(mount.id).error, isNull);
    });
  });

  test('full scan scrapes newly discovered directories and refreshes UI before scan finishes', () async {
    var now = DateTime(2026, 11, 18, 12);
    final folder2Entered = Completer<void>();
    final releaseFolder2 = Completer<void>();
    final firstScrapeDone = Completer<void>();
    final gatedDriver = _GatedStreamingDriver(
      onFolder2: () async {
        if (!folder2Entered.isCompleted) folder2Entered.complete();
        await releaseFolder2.future;
      },
    );
    final repo = LibraryRepository(db);
    var changes = 0;
    final scans = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: _DriverMountManager(MountRegistry(db), gatedDriver),
      onLibraryChanged: () => changes++,
      scrape: ({
        retryUnmatched = false,
        mountIds,
        refreshMatched = false,
        allowKindChange = true,
        refreshBeforeMs,
        isCancelled,
        onProgress,
      }) async {
        final pendingMovies = await (db.select(db.libraryItems)
              ..where((t) => t.kind.equals(LibraryKinds.movie) & t.libraryType.equals(LibraryTypes.pending)))
            .get();
        if (pendingMovies.isEmpty) return const LibraryScrapeOutcome();
        expect(refreshMatched, isFalse);
        expect(allowKindChange, isFalse);
        now = now.add(const Duration(seconds: 6));
        for (final movie in pendingMovies) {
          await repo.setLibraryType(movie.id, LibraryTypes.movie);
          await repo.updateItem(
            movie.id,
            LibraryItemsCompanion(
              metadataSource: const Value('tmdb'),
              tmdbId: Value('${movie.id}'),
              scrapedAt: Value(now.millisecondsSinceEpoch),
            ),
          );
          await (db.update(db.libraryFiles)..where((t) => t.itemId.equals(movie.id))).write(
            const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)),
          );
        }
        onProgress?.call(pendingMovies.length, pendingMovies.length);
        if (!firstScrapeDone.isCompleted) firstScrapeDone.complete();
        return const LibraryScrapeOutcome(hasChanges: true);
      },
    );
    addTearDown(scans.dispose);

    await withClock(Clock(() => now), () async {
      final fullScan = scans.scanAllMounts();
      await Future.wait([folder2Entered.future, firstScrapeDone.future]).timeout(const Duration(seconds: 5));

      expect(scans.update?.scanning, isTrue);
      expect(changes, greaterThanOrEqualTo(1));
      final shelved = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(shelved.items.map((v) => v.item.title), ['Dune']);

      releaseFolder2.complete();
      expect(await fullScan, isTrue);
      final allMovies = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(allMovies.items.map((v) => v.item.title), unorderedEquals(['Dune', 'Arrival']));
    });
  });

  test('calling scrapeLibrary(retryUnmatched: true) during a full scan unpauses and runs retry mid-scan', () async {
    final now = DateTime(2026, 11, 18, 12);
    final folder2Entered = Completer<void>();
    final releaseFolder2 = Completer<void>();
    final pausedOnce = Completer<void>();
    final retriedMidScan = Completer<void>();
    var hasKey = false;
    final retryCalls = <bool>[];
    final gatedDriver = _GatedStreamingDriver(
      onFolder2: () async {
        if (!folder2Entered.isCompleted) folder2Entered.complete();
        await releaseFolder2.future;
      },
    );
    final repo = LibraryRepository(db);
    final scans = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: _DriverMountManager(MountRegistry(db), gatedDriver),
      scrape: ({
        retryUnmatched = false,
        mountIds,
        refreshMatched = false,
        allowKindChange = true,
        refreshBeforeMs,
        isCancelled,
        onProgress,
      }) async {
        retryCalls.add(retryUnmatched);
        if (!hasKey) {
          if (!pausedOnce.isCompleted) pausedOnce.complete();
          return const LibraryScrapeOutcome(note: LibraryScrapeRunner.noTmdbKey);
        }
        final pendingMovies = await (db.select(db.libraryItems)
              ..where((t) => t.kind.equals(LibraryKinds.movie) & t.libraryType.equals(LibraryTypes.pending)))
            .get();
        for (final movie in pendingMovies) {
          await repo.setLibraryType(movie.id, LibraryTypes.movie);
          await repo.updateItem(
            movie.id,
            LibraryItemsCompanion(
              metadataSource: const Value('tmdb'),
              tmdbId: Value('${movie.id}'),
              scrapedAt: Value(now.millisecondsSinceEpoch),
            ),
          );
          await (db.update(db.libraryFiles)..where((t) => t.itemId.equals(movie.id))).write(
            const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)),
          );
        }
        onProgress?.call(pendingMovies.length, pendingMovies.length);
        if (retryUnmatched && !retriedMidScan.isCompleted) retriedMidScan.complete();
        return LibraryScrapeOutcome(hasChanges: pendingMovies.isNotEmpty);
      },
    );
    addTearDown(scans.dispose);

    await withClock(Clock(() => now), () async {
      final fullScan = scans.scanAllMounts();
      await Future.wait([folder2Entered.future, pausedOnce.future]).timeout(const Duration(seconds: 5));

      hasKey = true;
      await scans.scrapeLibrary(retryUnmatched: true);
      await retriedMidScan.future.timeout(const Duration(seconds: 5));

      expect(scans.update?.scanning, isTrue);
      expect(retryCalls, contains(true));
      final duneShelved = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(duneShelved.items.map((v) => v.item.title), ['Dune']);

      releaseFolder2.complete();
      expect(await fullScan, isTrue);
      final allMovies = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      expect(allMovies.items.map((v) => v.item.title), unorderedEquals(['Dune', 'Arrival']));
    });
  });
}

class _DriverMountManager extends MountManager {
  _DriverMountManager(super.registry, this.driver);

  final StorageDriver driver;

  @override
  StorageDriver driverFor(StorageMount mount) => driver;
}

class _GatedStreamingDriver implements StorageDriver {
  _GatedStreamingDriver({required this.onFolder2});

  final Future<void> Function() onFolder2;

  @override
  StorageKind get kind => StorageKind.local;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    switch (path) {
      case '/':
        return const [
          StorageEntry(path: '/Folder2', name: 'Folder2', isDirectory: true),
          StorageEntry(path: '/Folder1', name: 'Folder1', isDirectory: true),
        ];
      case '/Folder1':
        return const [
          StorageEntry(path: '/Folder1/Dune (2021).mkv', name: 'Dune (2021).mkv', isDirectory: false, size: 100),
        ];
      case '/Folder2':
        await onFolder2();
        return const [
          StorageEntry(path: '/Folder2/Arrival (2016).mkv', name: 'Arrival (2016).mkv', isDirectory: false, size: 100),
        ];
      default:
        return const [];
    }
  }

  @override
  Future<StorageEntry> stat(String path) => throw UnimplementedError();

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}
