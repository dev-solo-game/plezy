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
}
