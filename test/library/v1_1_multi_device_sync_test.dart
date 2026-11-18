import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/sync/deterministic_keys.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
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
      throw StateError('Unexpected remote mount list($path) on zero-scan passive receiver');
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

class _DeviceHarness {
  _DeviceHarness({this._failOnRemoteList = false, this._isTvDevice = false})
    : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) =>
          _NoScanMockDriver(mount.kind, failOnList: _failOnRemoteList),
    );
    client = LocalLibraryClient(repository: repo, mounts: mountManager);
    scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mountManager);
    sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      isTvDevice: _isTvDevice,
    );
  }

  final AppDatabase db;
  final bool _failOnRemoteList;
  final bool _isTvDevice;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;

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
    binTempDir = await Directory.systemTemp.createTemp('plezy_sync_bin_');
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
    final dataDir = await Directory.systemTemp.createTemp('plezy_sync_data_');
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

  test('empty TV B logs in via X25519 QR in 1s and renders full Quark library without scanning', () async {
    final serverUrl = await startSyncServer();
    final phoneA = _DeviceHarness();
    final tvB = _DeviceHarness(failOnRemoteList: true, isTvDevice: true);
    addTearDown(phoneA.dispose);
    addTearDown(tvB.dispose);

    // Phone A sets custom image mirror & Quark mount with incremental checkpoint.
    await LibrarySettingsStore(
      phoneA.db,
    ).saveScraper(const ScraperSettings(tmdbImageBase: 'https://image-mirror.example/t/p', language: 'zh-CN'));

    const quarkMount = StorageMount(
      id: 'm_quark_a',
      kind: StorageKind.quark,
      displayName: '我的夸克网盘',
      config: {MountKeys.quarkMode: 'pc', MountKeys.rootFolderId: '0', MountKeys.includePaths: ['/Anime', '/Movies']},
      secrets: {MountKeys.secretCookie: '{"uid":"888999","ticket":"t_abc","nickname":"user","utdid":"u1","machine":"m1"}'},
    );
    await phoneA.registry.upsert(quarkMount);
    await phoneA.db
        .into(phoneA.db.libraryScanStates)
        .insertOnConflictUpdate(LibraryScanStatesCompanion.insert(mountId: quarkMount.id, quarkCheckpoint: const Value('0:5000')));

    // Seed scraped show + 2 episodes + subtitle + 4K movie on Phone A.
    final showId = await phoneA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.show,
        libraryType: LibraryTypes.anime,
        title: '仙逆',
        sortTitle: 'xian ni',
        tmdbId: const Value('235412'),
        posterSource: const Value('/xianni_poster.jpg'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    await phoneA.repo.setGenres(showId, ['动画', '奇幻']);
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
    final ep1FileId = await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Anime/XianNi/S01E01.mp4',
      role: LibraryFileRoles.video,
      scanId: 1,
      remoteId: 'fid_ep1',
      size: 8000,
    );
    await phoneA.repo.linkFile(ep1FileId, ep1Id);
    await phoneA.repo.updateFile(
      ep1FileId,
      const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), width: Value(1920), height: Value(1080), videoCodec: Value('hevc')),
    );
    await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Anime/XianNi/S01E01.chi.ass',
      role: LibraryFileRoles.subtitle,
      scanId: 1,
      remoteId: 'fid_sub1',
      language: 'chi',
      ownerFileId: ep1FileId,
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
    final movieFileId = await phoneA.repo.upsertFile(
      mountId: quarkMount.id,
      path: '/Movies/Dune2.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      remoteId: 'fid_m1',
      size: 50000,
      versionLabel: '4K DoVi',
    );
    await phoneA.repo.linkFile(movieFileId, movieId);
    await phoneA.repo.updateFile(
      movieFileId,
      const LibraryFilesCompanion(
        matchState: Value(LibraryMatchStates.matched),
        matchLocked: Value(true),
        width: Value(3840),
        height: Value(2160),
        videoCodec: Value('hevc'),
        hdrFormat: Value('DoVi'),
      ),
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

    // Phone A creates account & uploads encrypted credentials + catalog + progress.
    await phoneA.sync.register(serverUrl: serverUrl, username: 'alice', password: 'secret-password', kdfParams: fastKdf);

    // Empty TV B pairs via X25519 QR without typing any password or scanning Quark.
    final qr = await tvB.sync.startQrSession(serverUrl: serverUrl, deviceName: 'LivingRoomTV');
    await phoneA.sync.confirmQrUri(qr.qrUri);
    final confirmed = await tvB.sync.pollQrSession(serverUrl: serverUrl, sessionId: qr.sessionId, keyPair: qr.keyPair);
    expect(confirmed, isTrue);

    // Verify TV B immediately reconstructed mounts, Quark secrets/checkpoint, works, subtitles, skips, and progress.
    final tvMounts = await tvB.registry.list();
    expect(tvMounts, hasLength(1));
    expect(tvMounts.single.id, 'm_quark_a');
    expect(tvMounts.single.secret(MountKeys.secretCookie), contains('"utdid":"u1"'));
    final tvScan = await (tvB.db.select(tvB.db.libraryScanStates)..where((t) => t.mountId.equals('m_quark_a'))).getSingle();
    expect(tvScan.quarkCheckpoint, '0:5000');

    expect((await LibrarySettingsStore(tvB.db).loadScraper()).tmdbImageBase, 'https://image-mirror.example/t/p');

    final animePage = await tvB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.anime));
    expect(animePage.items.map((v) => v.item.title), ['仙逆']);
    final tvShow = animePage.items.single.item;
    final tvEpisodes = await tvB.repo.episodesOfShow(tvShow.id);
    expect(tvEpisodes, hasLength(1));
    expect(tvEpisodes.single.state?.positionMs, 720000);
    final tvEpFiles = await tvB.repo.versionsOf(tvEpisodes.single.item.id);
    expect((await tvB.repo.subtitlesOf(tvEpFiles.single.id)).single.language, 'chi');

    final moviePage = await tvB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(moviePage.items.single.item.title, '沙丘2');
    expect(moviePage.items.single.item.locked, isTrue);
    final tvMovieFile = (await tvB.repo.versionsOf(moviePage.items.single.item.id)).single;
    expect((tvMovieFile.width, tvMovieFile.videoCodec, tvMovieFile.hdrFormat), (3840, 'hevc', 'DoVi'));

    final tvSkip = await WorkSkipSettingsStore(tvB.db).read(showIdentity);
    expect((tvSkip.introEnabled, tvSkip.introStartMs, tvSkip.introEndMs), (true, 5000, 90000));
  });

  test('canonicalSourceKey merges same Quark added offline on A and B to identical Mount ID and protects Level 4', () async {
    final serverUrl = await startSyncServer();
    final devA = _DeviceHarness();
    final devB = _DeviceHarness();
    addTearDown(devA.dispose);
    addTearDown(devB.dispose);

    // Device A offline adds Quark as uuid-A with checkpoint 0:3000 + Level 4 Inception.
    const mountA = StorageMount(
      id: 'uuid-A',
      kind: StorageKind.quark,
      displayName: 'Phone Quark',
      config: {MountKeys.rootFolderId: '0'},
      secrets: {MountKeys.secretCookie: 'uid=777888; __pus=old'},
    );
    await devA.registry.upsert(mountA);
    await devA.db
        .into(devA.db.libraryScanStates)
        .insertOnConflictUpdate(LibraryScanStatesCompanion.insert(mountId: 'uuid-A', quarkCheckpoint: const Value('0:3000')));
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
    final fileA = await devA.repo.upsertFile(
      mountId: 'uuid-A',
      path: '/Movies/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 20000,
    );
    await devA.repo.linkFile(fileA, movieA);
    await devA.repo.updateFile(fileA, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched), matchLocked: Value(true)));

    // Device B offline independently adds the SAME Quark under uuid-B with newer checkpoint 0:8500
    // + unmatched (Level 2) Inception + another matched film Interstellar.
    const mountB = StorageMount(
      id: 'uuid-B',
      kind: StorageKind.quark,
      displayName: 'TV Quark',
      config: {MountKeys.rootFolderId: '0'},
      secrets: {MountKeys.secretCookie: 'uid=777888; __pus=new'},
    );
    await devB.registry.upsert(mountB);
    await devB.db
        .into(devB.db.libraryScanStates)
        .insertOnConflictUpdate(LibraryScanStatesCompanion.insert(mountId: 'uuid-B', quarkCheckpoint: const Value('0:8500')));
    final unmatchedOnB = await devB.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.pending,
        title: 'Inception Pending',
        sortTitle: 'inception pending',
        scrapedAt: const Value(99999999),
        addedAt: 2000,
        updatedAt: 99999999,
      ),
    );
    final fileIncB = await devB.repo.upsertFile(
      mountId: 'uuid-B',
      path: '/Movies/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 20000,
    );
    await devB.repo.linkFile(fileIncB, unmatchedOnB);
    await devB.repo.updateFile(fileIncB, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.unmatched)));

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
    final fileInterB = await devB.repo.upsertFile(
      mountId: 'uuid-B',
      path: '/Movies/Interstellar.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 30000,
    );
    await devB.repo.linkFile(fileInterB, interB);
    await devB.repo.updateFile(fileInterB, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    // Device A registers & syncs first; Device B logs in & syncs; then A pulls updates back.
    await devA.sync.register(serverUrl: serverUrl, username: 'mergeuser', password: 'pw1', kdfParams: fastKdf);
    await devB.sync.loginWithPassword(serverUrl: serverUrl, username: 'mergeuser', password: 'pw1');
    await devA.sync.syncNow();

    final mountsOnA = await devA.registry.list();
    final mountsOnB = await devB.registry.list();
    expect(mountsOnA, hasLength(1));
    expect(mountsOnB, hasLength(1));
    expect(mountsOnA.single.id, 'uuid-A');
    expect(mountsOnB.single.id, 'uuid-A');
    expect(DeterministicKeys.canonicalSourceKey(mountsOnB.single), 'quark:777888');

    final scanA = await (devA.db.select(devA.db.libraryScanStates)..where((t) => t.mountId.equals('uuid-A'))).getSingle();
    final scanB = await (devB.db.select(devB.db.libraryScanStates)..where((t) => t.mountId.equals('uuid-A'))).getSingle();
    expect(scanA.quarkCheckpoint, '0:8500');
    expect(scanB.quarkCheckpoint, '0:8500');

    final moviesA = await devA.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    final moviesB = await devB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(moviesA.items.map((v) => v.item.title).toSet(), {'盗梦空间', '星际穿越'});
    expect(moviesB.items.map((v) => v.item.title).toSet(), {'盗梦空间', '星际穿越'});

    // B's unmatched item was pruned rather than leaving duplicate rows, and Inception stayed Level 4 locked.
    final pendingB = await devB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending));
    expect(pendingB.items, isEmpty);
    expect(moviesB.items.firstWhere((v) => v.item.title == '盗梦空间').item.locked, isTrue);
  });

  test('password envelope recovers MasterKey, isolates local disk mounts, and syncs unwatched via LWW', () async {
    final serverUrl = await startSyncServer();
    final devA = _DeviceHarness();
    final devC = _DeviceHarness();
    addTearDown(devA.dispose);
    addTearDown(devC.dispose);

    // Device A has one shared WebDAV mount + one StorageKind.local private disk mount.
    const webdavMount = StorageMount(
      id: 'm_dav_a',
      kind: StorageKind.webdav,
      displayName: 'Home WebDAV',
      config: {MountKeys.baseUrl: 'http://192.168.1.10/dav', MountKeys.fallbackUrl: 'https://home.ddns.example/dav'},
      secrets: {MountKeys.secretPassword: 'dav-password'},
    );
    const localMount = StorageMount(
      id: 'm_local_pc',
      kind: StorageKind.local,
      displayName: 'Local Disk',
      config: {MountKeys.rootPath: r'D:\PrivateMovies'},
    );
    await devA.registry.upsert(webdavMount);
    await devA.registry.upsert(localMount);

    final sharedFilmId = await devA.repo.insertItem(
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
    await devA.repo.linkFile(
      await devA.repo.upsertFile(mountId: 'm_dav_a', path: '/Movies/WE2.mkv', role: LibraryFileRoles.video, scanId: 1),
      sharedFilmId,
    );

    final localOnlyId = await devA.repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: '黑客帝国',
        sortTitle: 'matrix',
        tmdbId: const Value('603'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(1000),
        addedAt: 1000,
        updatedAt: 1000,
      ),
    );
    await devA.repo.linkFile(
      await devA.repo.upsertFile(mountId: 'm_local_pc', path: '/Matrix.mkv', role: LibraryFileRoles.video, scanId: 1),
      localOnlyId,
    );
    await devA.client.markWatched(
      MediaItem.jellyfin(id: '$sharedFilmId', kind: MediaKind.movie, title: '流浪地球2'),
    );
    await devA.client.markWatched(
      MediaItem.jellyfin(id: '$localOnlyId', kind: MediaKind.movie, title: '黑客帝国'),
    );

    await devA.sync.register(serverUrl: serverUrl, username: 'carol', password: 'recovery-password', kdfParams: fastKdf);

    // Device C recovers MasterKey using only username & password.
    await devC.sync.loginWithPassword(serverUrl: serverUrl, username: 'carol', password: 'recovery-password');

    final mountsC = await devC.registry.list();
    expect(mountsC.map((m) => m.id), ['m_dav_a']);
    expect(mountsC.single.secret(MountKeys.secretPassword), 'dav-password');
    expect(mountsC.single.configString(MountKeys.fallbackUrl), 'https://home.ddns.example/dav');

    // Local disk file never synced to C, yet Matrix's watch state IS preserved in WorkWatchStates!
    final cMovies = await devC.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
    expect(cMovies.items.map((v) => v.item.title), ['流浪地球2']);
    expect(cMovies.items.single.isWatched, isTrue);
    final matrixKey = WorkIdentity.resolve(source: WorkIdentity.localSource, kind: 'movie', tmdbId: '603')!.stateKey();
    final matrixStateOnC = await (devC.db.select(devC.db.workWatchStates)..where((t) => t.stateKey.equals(matrixKey))).getSingleOrNull();
    expect(matrixStateOnC?.watched, isTrue);

    // Device C marks Wandering Earth 2 UNWATCHED -> LWW overwrites Device A back to unwatched.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await devC.client.markUnwatched(
      MediaItem.jellyfin(id: '${cMovies.items.single.item.id}', kind: MediaKind.movie, title: '流浪地球2'),
    );
    await devC.sync.syncNow();
    await devA.sync.syncNow();
    expect((await devA.repo.getItem(sharedFilmId))!.isWatched, isFalse);
  });
}
