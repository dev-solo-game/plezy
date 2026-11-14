import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

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
  late List<int> searchPages;
  late List<String?> searchCookies;
  late bool failSecondPage;
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
    searchPages = [];
    searchCookies = [];
    failSecondPage = false;
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
        searchPages.add(page);
        searchCookies.add(request.headers.value(HttpHeaders.cookieHeader));
        if (searchError != null || (page == 2 && failSecondPage)) {
          response.statusCode = searchError ?? HttpStatus.serviceUnavailable;
          await response.close();
          return;
        }
      } else if (!ancestry) {
        folderReads.add(folder!);
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
      for (var i = 0; i < 99; i++) _file('pic-$i', 'Picture $i.jpg', next, parent: 'outside'),
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
    await incremental();
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
    expect(await scans.updateQuark([webMount], LibraryUpdateMode.full), isTrue);
    expect(await scans.hasIncrementalBaseline(webMount), isTrue);
    expect(await checkpoint(), 'library:$baseline');

    arrangeChanges();
    expect(await scans.updateQuark([webMount], LibraryUpdateMode.incremental), isTrue);
    expect(scans.statusOf(webMount.id).error, isNull);
    expect(await checkpoint(), 'library:$next');
    expect((await db.select(db.libraryFiles).get()).map((row) => row.remoteId), unorderedEquals(['old', 'new']));
    expect(searchCookies, everyElement('__puus=test-web-cookie'));
  });

  test('holds the update lock through scraping and passes cancellation to the scraper', () async {
    final scrapes = Completer<void>();
    final finishScraping = Completer<void>();
    final cancelled = Completer<bool>();
    final scans = LibraryScanService(
      repository: LibraryRepository(db),
      scanner: scanner,
      mounts: _MountManager(MountRegistry(db), driver),
      scrape: ({retryUnmatched = false, mountIds, refreshMatched = false, isCancelled, onProgress}) async {
        if (mountIds?.contains(mount.id) != true || !refreshMatched) return 'Incorrect scrape scope';
        scrapes.complete();
        await finishScraping.future;
        cancelled.complete(isCancelled!());
        return null;
      },
    );
    addTearDown(scans.dispose);
    final running = scans.updateQuark([mount], LibraryUpdateMode.full);
    expect(await scans.updateQuark([mount], LibraryUpdateMode.incremental), isFalse);
    await Future.any([scrapes.future, running.then((_) => fail('Scraping did not start'))]);
    expect(scans.update?.scraping, isTrue);
    expect(await scans.updateQuark([mount], LibraryUpdateMode.incremental), isFalse);
    scans.cancelUpdate(scans.update!);
    expect(scans.update?.cancel.isCancelled, isTrue);
    finishScraping.complete();
    expect(await running, isTrue);
    expect(await cancelled.future, isTrue);
    expect(scans.update, isNull);
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
    Future<Duration> check() => scans.checkAutomaticQuarkUpdates(canRun: () => canRun);

    await withClock(Clock(() => now), () async {
      await check();
      expect(searchPages, isEmpty, reason: 'no baseline must never trigger an automatic full scan');
      await scans.updateQuark([mount], LibraryUpdateMode.full);
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
    Future<Duration> check() => scans.checkAutomaticQuarkUpdates(canRun: () => true);

    await withClock(Clock(() => now), () async {
      await scanner.scan(mount, driver);
      searchPages.clear();
      now = now.add(const Duration(minutes: 1));
      searchError = HttpStatus.tooManyRequests;
      await check();
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
      expect(scans.statusOf(mount.id).error, isNull);
    });
  });
}
