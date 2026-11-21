import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _TrackingMountManager extends MountManager {
  _TrackingMountManager(super.registry);

  int driverForCalls = 0;

  @override
  StorageDriver driverFor(StorageMount mount) {
    driverForCalls++;
    throw UnimplementedError('driverFor should not be called for cloud mounts');
  }

  @override
  MountOnlineStatus statusOf(String mountId) => MountOnlineStatus.onlinePrimary;

  @override
  bool isMountOnline(String mountId) => true;
}

class _TrackingScrapeRunner extends LibraryScrapeRunner {
  _TrackingScrapeRunner({required super.database, required super.repository, required super.settings});

  int hydrateCalls = 0;

  @override
  Future<bool> hydrateItemDetailsIfNeeded(int itemId) async {
    hydrateCalls++;
    return false;
  }
}

class _SpyCloudBridge extends LocalCloudUserDataBridge {
  int detailHydrateCalls = 0;
  String? lastWorkKey;
  int? lastLocalItemId;

  @override
  Future<void> pushProgress({
    required String workKey,
    int seasonNumber = 0,
    int episodeNumber = 0,
    required int positionMs,
    int? durationMs,
    bool? watched,
  }) async {}

  @override
  Future<void> pushFavorite({required String workKey, required bool isFavorite}) async {}

  @override
  Future<void> pushHideContinue({required String workKey, int seasonNumber = 0, int episodeNumber = 0}) async {}

  @override
  Future<bool> hydrateCloudItemDetail(int localItemId, String workKey) async {
    detailHydrateCalls++;
    lastLocalItemId = localItemId;
    lastWorkKey = workKey;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('LibraryScanService.refreshShowDirectories skips cloud:* mounts and LocalLibraryClient hydrates cloud items without local scraper', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final repo = LibraryRepository(db);
    final registry = MountRegistry(db);
    final mounts = _TrackingMountManager(registry);
    addTearDown(mounts.dispose);

    await registry.upsert(
      const StorageMount(
        id: 'cloud:src_quark_1',
        kind: StorageKind.quark,
        displayName: 'Cloud Quark',
        config: {MountKeys.rootFolderId: '0'},
      ),
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    final showId = await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:show:279155'),
        kind: LibraryKinds.show,
        libraryType: LibraryTypes.show,
        title: '谷雨',
        sortTitle: 'gu yu',
        addedAt: now,
        updatedAt: now,
      ),
    );
    final seasonId = await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:show:279155:s1'),
        kind: LibraryKinds.season,
        libraryType: LibraryTypes.show,
        parentId: Value(showId),
        showId: Value(showId),
        title: 'Season 1',
        sortTitle: '00001',
        seasonNumber: const Value(1),
        addedAt: now,
        updatedAt: now,
      ),
    );
    final epId = await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:show:279155:s1:e1'),
        kind: LibraryKinds.episode,
        libraryType: LibraryTypes.show,
        parentId: Value(seasonId),
        showId: Value(showId),
        title: 'Episode 1',
        sortTitle: '00001',
        seasonNumber: const Value(1),
        episodeNumber: const Value(1),
        addedAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.libraryFiles).insert(
      LibraryFilesCompanion.insert(
        fileKey: const Value('cf_1'),
        mountId: 'cloud:src_quark_1',
        path: '/TV/GuYu/S01E01.mkv',
        role: LibraryFileRoles.video,
        itemId: Value(epId),
        addedAt: now,
      ),
    );

    final scanService = LibraryScanService(mounts: mounts, scanner: LibraryScanner(db, repo), repository: repo);
    addTearDown(scanService.dispose);
    final changed = await scanService.refreshShowDirectories(showId);
    expect(changed, isFalse);
    expect(mounts.driverForCalls, 0);

    final runner = _TrackingScrapeRunner(database: db, repository: repo, settings: LibrarySettingsStore(db));
    final bridge = _SpyCloudBridge();
    final client = LocalLibraryClient(repository: repo, mounts: mounts, scrapeRunner: runner)
      ..cloudUserDataBridge = bridge;

    await client.fetchItemWithOnDeck('$showId');
    expect(bridge.detailHydrateCalls, 1);
    expect(bridge.lastLocalItemId, showId);
    expect(bridge.lastWorkKey, 'tmdb:show:279155');
    expect(runner.hydrateCalls, 0);

    // Opening episode detail also routes root workKey to cloud detail hydration cleanly.
    await client.fetchItem('$epId');
    expect(bridge.detailHydrateCalls, 2);
    expect(bridge.lastLocalItemId, showId);
    expect(bridge.lastWorkKey, 'tmdb:show:279155');
    expect(runner.hydrateCalls, 0);
  });

  test('LocalLibraryClient.getPlaybackInitialization skips directory listing and refreshDirectorySubtitles scans once', () async {
    resetSharedPreferencesForTest();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final repo = LibraryRepository(db);
    final registry = MountRegistry(db);
    final driver = _FakeSubtitleDriver([
      const StorageEntry(path: '/Movies/Film.mkv', name: 'Film.mkv', isDirectory: false, id: 'vid_1', size: 1024),
      const StorageEntry(path: '/Movies/Film.en.srt', name: 'Film.en.srt', isDirectory: false, id: 'sub_1', size: 120),
    ]);
    final mounts = _FakeSubtitleMountManager(registry, driver);
    addTearDown(mounts.dispose);

    await registry.upsert(
      const StorageMount(
        id: 'cloud:src_sub_1',
        kind: StorageKind.quark,
        displayName: 'Cloud Quark',
        config: {MountKeys.rootFolderId: '0'},
      ),
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    final movieId = await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:999'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Film',
        sortTitle: 'film',
        addedAt: now,
        updatedAt: now,
      ),
    );
    final videoFileId = await db.into(db.libraryFiles).insert(
      LibraryFilesCompanion.insert(
        fileKey: const Value('cf_vid_1'),
        mountId: 'cloud:src_sub_1',
        path: '/Movies/Film.mkv',
        role: LibraryFileRoles.video,
        itemId: Value(movieId),
        seenInScan: const Value(7),
        addedAt: now,
      ),
    );
    await db.into(db.libraryFiles).insert(
      LibraryFilesCompanion.insert(
        fileKey: const Value('cf_sub_1'),
        mountId: 'cloud:src_sub_1',
        path: '/Movies/Film.en.srt',
        role: LibraryFileRoles.subtitle,
        ownerFileId: Value(videoFileId),
        language: const Value('en'),
        addedAt: now,
      ),
    );

    final client = LocalLibraryClient(repository: repo, mounts: mounts);
    final item = (await client.fetchItem('$movieId'))!;
    final options = PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0);

    // 1. Playback reads only DB sidecar rows -> 0 directory list calls.
    final initial = await client.getPlaybackInitialization(options);
    expect(driver.listCalls, 0);
    expect(initial.subtitleSidecars.map((s) => s.track.language), ['en']);

    // 2. Add a new subtitle file on storage, then explicitly trigger refreshDirectorySubtitles.
    driver.entries.add(
      const StorageEntry(path: '/Movies/Film.zh.srt', name: 'Film.zh.srt', isDirectory: false, id: 'sub_2', size: 150),
    );
    final added = await client.refreshDirectorySubtitles(item.id);
    expect(added, 1);
    expect(driver.listCalls, 1);
    expect(await repo.subtitlesOf(videoFileId), hasLength(2));

    // 3. Repeating without new files still scans on demand and reports 0 new files.
    final addedAgain = await client.refreshDirectorySubtitles(item.id);
    expect(addedAgain, 0);
    expect(driver.listCalls, 2);

    // 4. Subsequent playback picks up both DB subtitles with zero additional list calls.
    final refreshed = await client.getPlaybackInitialization(options);
    expect(driver.listCalls, 2);
    expect(refreshed.subtitleSidecars.map((s) => s.track.language), ['en', 'zh']);
  });
}

class _FakeSubtitleDriver implements StorageDriver {
  _FakeSubtitleDriver(this.entries);

  final List<StorageEntry> entries;
  int listCalls = 0;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    listCalls++;
    return List<StorageEntry>.from(entries);
  }

  @override
  Future<StorageEntry> stat(String path) => throw UnimplementedError();

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {}
}

class _FakeSubtitleMountManager extends MountManager {
  _FakeSubtitleMountManager(super.registry, this.driver);

  final StorageDriver driver;

  @override
  StorageDriver driverFor(StorageMount mount) => driver;

  @override
  MountOnlineStatus statusOf(String mountId) => MountOnlineStatus.onlinePrimary;

  @override
  bool isMountOnline(String mountId) => true;

  @override
  Future<Uri> streamUrl(StorageMount mount, StorageEntry entry, {bool bulk = false}) async =>
      Uri.parse('http://127.0.0.1/stream${entry.path}');
}
