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
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/scrapers/tmdb_image_url.dart';
import 'package:plezy/library/sync/library_workspace_store.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _NoScanDriver implements StorageDriver {
  _NoScanDriver(this.kind);

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

class _TestNode {
  _TestNode({String? serverMetadataUrl}) : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    repo = LibraryRepository(db);
    registry = MountRegistry(db);
    settings = LibrarySettingsStore(db);
    mountManager = MountManager(
      registry,
      driverFactory: (mount, {bool useFallback = false}) => _NoScanDriver(mount.kind),
    );
    client = LocalLibraryClient(repository: repo, mounts: mountManager);
    runner = LibraryScrapeRunner(
      database: db,
      repository: repo,
      settings: settings,
      mounts: mountManager,
      resolveMetadataEndpoint: serverMetadataUrl == null
          ? null
          : () async {
              final sess = sync.session;
              if (sess != null) {
                return (
                  serverUrl: sess.serverUrl,
                  accessToken: sess.accessToken,
                  isOfficial: sess.serverKind == SyncServerKind.official,
                );
              }
              return (serverUrl: serverMetadataUrl, accessToken: null, isOfficial: true);
            },
      onImageBaseUpdated: (base) {
        if (base.trim().isNotEmpty) {
          client.tmdbImageBase = base.trim();
        }
      },
    );
    client.scrapeRunner = runner;
    scans = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: mountManager,
      scrape: runner.scrapePending,
    );
    sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mountManager,
      scanService: scans,
      enableLanUdp: false,
      autoStartLanService: false,
    );
  }

  final AppDatabase db;
  late final LibraryRepository repo;
  late final MountRegistry registry;
  late final LibrarySettingsStore settings;
  late final MountManager mountManager;
  late final LocalLibraryClient client;
  late final LibraryScrapeRunner runner;
  late final LibraryScanService scans;
  late final SyncAndScanCoordinator sync;

  Future<void> dispose() async {
    while (sync.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
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
    binTempDir = await Directory.systemTemp.createTemp('plezy_meta_sync_bin_');
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

  Future<String> startSyncServer({String? bangumiApiBase}) async {
    final dataDir = await Directory.systemTemp.createTemp('plezy_meta_sync_data_');
    final args = ['-addr', '127.0.0.1:0', '-data-dir', dataDir.path];
    if (bangumiApiBase != null) {
      args.addAll(['-bangumi-api-base', bangumiApiBase]);
    }
    final proc = await Process.start(serverExePath, args);
    final urlCompleter = Completer<String>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('LISTENING ') && !urlCompleter.isCompleted) {
        urlCompleter.complete(line.substring('LISTENING '.length).trim());
      }
    });
    unawaited(proc.stderr.drain<void>());
    addTearDown(() async {
      proc.kill();
      await proc.exitCode.catchError((_) => -1);
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

  test(
    'Phase 1 cleanup: initial sync skips tombstones, mount removal cleans auth key, prune cleans orphan people, archive uses gzip without tombstones',
    () async {
      final serverUrl = await startSyncServer();
      final nodeA = _TestNode();
      final nodeB = _TestNode();
      addTearDown(nodeA.dispose);
      addTearDown(nodeB.dispose);

      // 1. Seed a mount + movie + file + orphan person check.
      const oldMount = StorageMount(
        id: 'old_mount',
        kind: StorageKind.webdav,
        displayName: 'Old DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.10/old'},
        secrets: {MountKeys.secretPassword: 'pw'},
      );
      await nodeA.registry.upsert(oldMount);
      await nodeA.sync.initialize();
      await nodeA.sync.syncStore.setAuthUpdatedAt('old_mount', 123456);

      final orphanedPersonMovie = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          workKey: const Value('tmdb:movie:777'),
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'Temp',
          sortTitle: 'temp',
          tmdbId: const Value('777'),
          metadataSource: const Value('tmdb'),
          scrapedAt: const Value(1000),
          addedAt: 1000,
          updatedAt: 1000,
        ),
      );
      await nodeA.repo.setCredits(orphanedPersonMovie, [
        (name: 'Orphan Actor', job: 'actor', character: 'Lead', tmdbId: '9001', photoSource: '/orphan.jpg'),
      ]);
      final oldFid = await nodeA.repo.upsertFile(
        mountId: 'old_mount',
        path: '/Temp.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 1000,
      );
      await nodeA.repo.linkFile(oldFid, orphanedPersonMovie);
      await nodeA.sync.onMountSaved(oldMount);
      await nodeA.sync.onCatalogChanged(mountIds: {'old_mount'});

      // Removing old_mount leaves tombstones in sync_journal, deletes Temp, prunes Orphan Actor, and cleans auth key.
      await nodeA.registry.remove('old_mount');
      await nodeA.sync.onMountRemoved('old_mount');

      expect(await nodeA.sync.syncStore.getAuthUpdatedAt('old_mount'), 0);
      expect(await nodeA.db.select(nodeA.db.libraryPeople).get(), isEmpty);

      // Add a real surviving mount & movie.
      const curMount = StorageMount(
        id: 'cur_mount',
        kind: StorageKind.webdav,
        displayName: 'Cur DAV',
        config: {MountKeys.baseUrl: 'http://192.168.1.10/cur'},
      );
      await nodeA.registry.upsert(curMount);
      final keepMovie = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          workKey: const Value('tmdb:movie:438631'),
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: '沙丘',
          sortTitle: 'sha qiu',
          tmdbId: const Value('438631'),
          metadataSource: const Value('tmdb'),
          scrapedAt: const Value(2000),
          addedAt: 2000,
          updatedAt: 2000,
        ),
      );
      final keepFid = await nodeA.repo.upsertFile(
        mountId: 'cur_mount',
        path: '/Dune.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 2000,
      );
      await nodeA.repo.linkFile(keepFid, keepMovie);
      await nodeA.repo.updateFile(keepFid, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));
      await nodeA.sync.onMountSaved(curMount);
      await nodeA.sync.onCatalogChanged(mountIds: {'cur_mount'});

      // Confirm local journal currently has tombstones from old_mount AND initial cloud query skips them!
      final deletedRows = await nodeA.db
          .customSelect('SELECT COUNT(*) AS c FROM sync_journal WHERE is_deleted = 1')
          .getSingle();
      expect(deletedRows.read<int>('c'), greaterThan(0));
      final pendingAtZero = await nodeA.sync.syncStore.journal.getPendingCloudEntries(afterSeq: 0);
      expect(pendingAtZero.every((e) => !e.isDeleted), isTrue);

      // Sign up & mergeLocal: verify compressed workspace archive contains zero deleted rows & restores cleanly.
      await nodeA.sync.register(
        serverUrl: serverUrl,
        username: 'phase1user',
        password: 'pw',
        kdfParams: fastKdf,
        mergePolicy: LocalMergePolicy.mergeLocal,
      );

      final archRow = await nodeA.db
          .customSelect("SELECT snapshot_json FROM sync_workspace_archives WHERE workspace_key = 'local'")
          .getSingle();
      final rawSnap = archRow.read<String>('snapshot_json');
      expect(rawSnap, startsWith('gz:'));
      final decodedSnap =
          jsonDecode(utf8.decode(gzip.decode(base64Decode(rawSnap.substring(3))))) as Map<String, dynamic>;
      final archivedJournal = (decodedSnap['tables'] as Map)['sync_journal'] as List;
      expect(archivedJournal.any((row) => (row as Map)['is_deleted'] == 1), isFalse);

      // Server user stats should reflect only 1 source, 1 work, 1 file (zero tombstones pushed).
      final stats = await nodeA.sync.apiClient.getUserStats(serverUrl, nodeA.sync.session!.accessToken);
      expect((stats.sources, stats.works, stats.files), (1, 1, 1));

      // Device B logs in and verifies initial pull delivers only active rows.
      await nodeB.sync.loginWithPassword(serverUrl: serverUrl, username: 'phase1user', password: 'pw');
      final deletedOnB = await nodeB.db
          .customSelect('SELECT COUNT(*) AS c FROM sync_journal WHERE is_deleted = 1')
          .getSingle();
      expect(deletedOnB.read<int>('c'), 0);
      expect(
        (await nodeB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie))).items.single.item.title,
        '沙丘',
      );
    },
  );

  test(
    'Phase 2 & 3: pure local mode uses server metadata cache, slim sync strips heavy fields, and Device B hydrates lazily with 0 outbox churn',
    () async {
      var tmdbMovieHits = 0;
      var tmdbShowHits = 0;
      var tmdbSeasonHits = 0;
      var tmdbSearchHits = 0;

      final fakeTmdb = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fakeTmdb.listen((req) async {
        final path = req.uri.path;
        Object? body;
        if (path == '/3/configuration') {
          body = {'images': <String, Object>{}};
        } else if (path == '/3/search/movie') {
          tmdbSearchHits++;
          body = {
            'results': [
              {
                'id': 438631,
                'title': '沙丘',
                'original_title': 'Dune',
                'release_date': '2021-09-15',
                'overview': 'Arrakis',
                'poster_path': '/dune_poster.jpg',
              },
            ],
          };
        } else if (path == '/3/search/tv') {
          tmdbSearchHits++;
          body = {
            'results': [
              {
                'id': 94997,
                'name': '龙之家族',
                'original_name': 'House of the Dragon',
                'first_air_date': '2022-08-21',
                'overview': 'Targaryen dynasty',
                'poster_path': '/hotd_poster.jpg',
              },
            ],
          };
        } else if (path == '/3/movie/438631') {
          tmdbMovieHits++;
          body = {
            'id': 438631,
            'title': '沙丘',
            'original_title': 'Dune',
            'release_date': '2021-09-15',
            'status': 'Released',
            'overview': 'Paul Atreides journeys to Arrakis.',
            'tagline': 'Beyond fear, destiny awaits.',
            'runtime': 155,
            'vote_average': 7.8,
            'imdb_id': 'tt1160419',
            'poster_path': '/dune_poster.jpg',
            'backdrop_path': '/dune_backdrop.jpg',
            'genres': [
              {'id': 878, 'name': '科幻'},
            ],
            'images': {
              'logos': [
                {'iso_639_1': 'zh', 'file_path': '/dune_logo_zh.png'},
              ],
            },
            'alternative_titles': {
              'titles': [
                {'title': '沙丘：第一部'},
              ],
            },
            'credits': {
              'crew': [
                {'id': 137427, 'name': 'Denis Villeneuve', 'job': 'Director', 'profile_path': '/denis.jpg'},
              ],
              'cast': [
                {
                  'id': 1190668,
                  'name': 'Timothée Chalamet',
                  'character': 'Paul Atreides',
                  'profile_path': '/timothee.jpg',
                },
              ],
            },
          };
        } else if (path == '/3/tv/94997') {
          tmdbShowHits++;
          body = {
            'id': 94997,
            'name': '龙之家族',
            'original_name': 'House of the Dragon',
            'first_air_date': '2022-08-21',
            'status': 'Ended',
            'overview': 'A Targaryen civil war.',
            'tagline': 'Fire will reign.',
            'vote_average': 8.4,
            'poster_path': '/hotd_poster.jpg',
            'backdrop_path': '/hotd_backdrop.jpg',
            'genres': [
              {'id': 18, 'name': '剧情'},
            ],
            'images': {
              'logos': [
                {'iso_639_1': 'zh', 'file_path': '/hotd_logo.png'},
              ],
            },
            'credits': {
              'cast': [
                {'id': 1190668, 'name': 'Timothée Chalamet', 'character': 'Guest', 'profile_path': '/timothee.jpg'},
              ],
            },
          };
        } else if (path == '/3/tv/94997/season/1') {
          tmdbSeasonHits++;
          body = {
            'name': '第 1 季',
            'overview': 'Season 1',
            'poster_path': '/hotd_s1.jpg',
            'episodes': [
              {
                'episode_number': 1,
                'name': '龙之继承人',
                'overview': 'King Viserys names his heir.',
                'air_date': '2022-08-21',
                'runtime': 66,
                'still_path': '/hotd_s1e1.jpg',
                'vote_average': 8.2,
              },
            ],
          };
        }
        req.response
          ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(body == null ? '{}' : jsonEncode(body));
        await req.response.close();
      });
      addTearDown(() => fakeTmdb.close(force: true));

      final fakeBangumi = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fakeBangumi.listen((req) async {
        final path = req.uri.path;
        Object? body;
        if (path == '/v0/search/subjects') {
          body = {
            'data': [
              {'id': 328609, 'name': '葬送のフリーレン', 'name_cn': '葬送的芙莉莲', 'date': '2023-09-29'},
            ],
          };
        } else if (path == '/v0/subjects/328609') {
          body = {
            'id': 328609,
            'name': '葬送のフリーレン',
            'name_cn': '葬送的芙莉莲',
            'date': '2023-09-29',
            'summary': 'Elf mage journey.',
            'rating': {'score': 8.7},
            'images': {'large': 'https://lain.bgm.tv/frieren.jpg'},
            'tags': [
              {'name': '奇幻'},
            ],
          };
        } else if (path == '/v0/episodes') {
          body = {
            'data': [
              {'ep': 1, 'name': '冒険の終わり', 'name_cn': '冒险的终点', 'desc': 'After ten years', 'airdate': '2023-09-29'},
            ],
          };
        }
        req.response
          ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(body == null ? '{}' : jsonEncode(body));
        await req.response.close();
      });
      addTearDown(() => fakeBangumi.close(force: true));

      final serverUrl = await startSyncServer(bangumiApiBase: 'http://127.0.0.1:${fakeBangumi.port}');

      // Register admin on sync_server and configure TMDB settings + image mirror via admin HTTP API.
      final adminClient = HttpClient();
      addTearDown(() => adminClient.close(force: true));
      final regReq = await adminClient.postUrl(Uri.parse('$serverUrl/api/v1/web/register'));
      regReq.headers.contentType = ContentType.json;
      regReq.write(jsonEncode({'username': 'server_admin', 'password': 'admin_password'}));
      final regResp = await regReq.close();
      final regJson = jsonDecode(await utf8.decodeStream(regResp)) as Map<String, dynamic>;
      final adminToken = regJson['access_token'] as String;

      final cfgReq = await adminClient.postUrl(Uri.parse('$serverUrl/api/v1/admin/metadata/config'));
      cfgReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $adminToken');
      cfgReq.headers.contentType = ContentType.json;
      cfgReq.write(
        jsonEncode({
          'tmdb_api_key': 'server-managed-key',
          'tmdb_api_base': 'http://127.0.0.1:${fakeTmdb.port}/3',
          'tmdb_image_base': 'https://cdn-mirror.example/t/p',
          'bangumi_enabled': true,
          'allow_public_metadata': true,
        }),
      );
      final cfgResp = await cfgReq.close();
      expect(cfgResp.statusCode, HttpStatus.ok);

      // Pure Local Mode Node A (unauthenticated! points to serverUrl as "official" metadata server).
      final nodeA = _TestNode(serverMetadataUrl: serverUrl);
      final nodeB = _TestNode(serverMetadataUrl: serverUrl);
      addTearDown(nodeA.dispose);
      addTearDown(nodeB.dispose);

      const mountA = StorageMount(
        id: 'dav_main',
        kind: StorageKind.webdav,
        displayName: 'Media Share',
        config: {MountKeys.baseUrl: 'https://dav.example.com'},
      );
      await nodeA.registry.upsert(mountA);

      final now = DateTime(2026, 5, 1).millisecondsSinceEpoch;
      final pendingMovieId = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.pending,
          title: 'Dune',
          sortTitle: 'dune',
          year: const Value(2021),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final mFid = await nodeA.repo.upsertFile(
        mountId: mountA.id,
        path: '/Movies/Dune (2021).mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 12000,
      );
      await nodeA.repo.linkFile(mFid, pendingMovieId);
      await nodeA.repo.updateFile(mFid, const LibraryFilesCompanion(durationMs: Value(9300000), width: Value(3840)));

      final pendingShowId = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.show,
          libraryType: LibraryTypes.pending,
          title: 'House of the Dragon',
          sortTitle: 'house of the dragon',
          year: const Value(2022),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final s1Id = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.season,
          libraryType: LibraryTypes.pending,
          title: 'Season 1',
          sortTitle: 'season 0001',
          parentId: Value(pendingShowId),
          showId: Value(pendingShowId),
          seasonNumber: const Value(1),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final ep1Id = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.episode,
          libraryType: LibraryTypes.pending,
          title: 'Episode 1',
          sortTitle: 's0001e0001',
          parentId: Value(s1Id),
          showId: Value(pendingShowId),
          seasonNumber: const Value(1),
          episodeNumber: const Value(1),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final eFid = await nodeA.repo.upsertFile(
        mountId: mountA.id,
        path: '/Shows/HotD/S01E01.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 8000,
      );
      await nodeA.repo.linkFile(eFid, ep1Id);

      // Seed an anime show under /Anime so Bangumi goes first through ServerMetadataProvider.
      final pendingAnimeId = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.show,
          libraryType: LibraryTypes.pending,
          title: '葬送的芙莉莲',
          sortTitle: 'frieren',
          addedAt: now,
          updatedAt: now,
        ),
      );
      final animeS1Id = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.season,
          libraryType: LibraryTypes.pending,
          title: 'Season 1',
          sortTitle: 'season 0001',
          parentId: Value(pendingAnimeId),
          showId: Value(pendingAnimeId),
          seasonNumber: const Value(1),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final animeEp1Id = await nodeA.repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.episode,
          libraryType: LibraryTypes.pending,
          title: 'Episode 1',
          sortTitle: 's0001e0001',
          parentId: Value(animeS1Id),
          showId: Value(pendingAnimeId),
          seasonNumber: const Value(1),
          episodeNumber: const Value(1),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final animeFid = await nodeA.repo.upsertFile(
        mountId: mountA.id,
        path: '/Anime/Frieren/S01E01.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 6000,
      );
      await nodeA.repo.linkFile(animeFid, animeEp1Id);

      // Pure local scrape (NO local TMDB key, NO sync account signed in).
      await nodeA.scans.scrapeLibrary();
      expect(nodeA.scans.scrapeStatus.note, isNull);
      expect((tmdbSearchHits, tmdbMovieHits, tmdbShowHits, tmdbSeasonHits), (2, 1, 1, 1));
      final scrapedAnime = (await nodeA.repo.getItem(pendingAnimeId))!.item;
      expect(scrapedAnime.title, '葬送的芙莉莲');
      expect(scrapedAnime.posterSource, 'https://lain.bgm.tv/frieren.jpg');
      expect(nodeA.client.thumbnailUrl(scrapedAnime.posterSource), 'https://lain.bgm.tv/frieren.jpg');
      final animeEps = await nodeA.repo.episodesOfShow(pendingAnimeId);
      expect(animeEps.single.item.title, '冒险的终点');

      // Verify Node A stores relative TMDB paths and LocalLibraryClient expands them with server image_base.
      final scrapedMovie = (await nodeA.repo.getItem(pendingMovieId))!.item;
      expect(scrapedMovie.title, '沙丘');
      expect(scrapedMovie.posterSource, '/dune_poster.jpg');
      expect(scrapedMovie.backdropSource, '/dune_backdrop.jpg');
      expect(scrapedMovie.logoSource, '/dune_logo_zh.png');
      expect(
        nodeA.client.thumbnailUrl(scrapedMovie.posterSource, width: 400),
        'https://cdn-mirror.example/t/p/w342/dune_poster.jpg',
      );
      expect(
        nodeA.client.thumbnailUrl(scrapedMovie.logoSource),
        'https://cdn-mirror.example/t/p/w500/dune_logo_zh.png',
      );
      // Relative path helper preserves non-TMDB URLs & strips legacy full TMDB URLs.
      expect(TmdbImageUrl.toRelativePath('https://image.tmdb.org/t/p/w780/dune_poster.jpg'), '/dune_poster.jpg');
      expect(TmdbImageUrl.toRelativePath('https://lain.bgm.tv/frieren.jpg'), 'https://lain.bgm.tv/frieren.jpg');

      // Verify slim sync payloads omit heavy work details, file_name, and all ep_* episode metadata!
      await nodeA.sync.initialize();
      await nodeA.sync.mapper.ensureJournalUpToDate();
      final bundle = await nodeA.sync.mapper.buildDeltaBundle(
        encryptionKey: SyncCrypto.generateMasterKey(),
        sinceSeq: 0,
      );
      final movieWorkJson = bundle.works.firstWhere((w) => w['work_key'] == 'tmdb:movie:438631');
      final movieMeta = movieWorkJson['metadata_json'] as Map<String, dynamic>;
      expect(movieMeta['title'], '沙丘');
      expect(movieMeta['poster_path'], '/dune_poster.jpg');
      for (final omitted in const [
        'aliases',
        'backdrop_path',
        'logo_path',
        'original_title',
        'release_date',
        'summary',
        'tagline',
        'content_rating',
        'studio',
        'runtime_ms',
        'credits',
      ]) {
        expect(movieMeta.containsKey(omitted), isFalse, reason: 'work metadata should omit $omitted');
      }

      for (final f in bundle.files) {
        expect(f.containsKey('file_name'), isFalse);
        final spec = f['media_spec_json'] as Map<String, dynamic>;
        expect(spec.keys.where((k) => k.startsWith('ep_')), isEmpty);
      }

      // Device A signs up to a user account and pushes slim library; Device B logs in and hydrates lazily!
      await nodeA.sync.register(
        serverUrl: serverUrl,
        username: 'family_user',
        password: 'pw',
        kdfParams: fastKdf,
        mergePolicy: LocalMergePolicy.mergeLocal,
      );
      await nodeB.sync.loginWithPassword(serverUrl: serverUrl, username: 'family_user', password: 'pw');
      final connInfo = await nodeB.runner.checkMetadataServerConnection();
      expect(connInfo.config.tmdbConfigured, isTrue);
      expect(nodeB.client.tmdbImageBase, 'https://cdn-mirror.example/t/p');

      // Before opening details: Device B has slim skeleton ready for instant poster wall rendering.
      final bMovies = await nodeB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.movie));
      final bMovieRow = bMovies.items.single.item;
      expect(bMovieRow.title, '沙丘');
      expect(bMovieRow.summary, isNull);
      expect(bMovieRow.backdropSource, isNull);
      expect(
        nodeB.client.thumbnailUrl(bMovieRow.posterSource, width: 350),
        'https://cdn-mirror.example/t/p/w342/dune_poster.jpg',
      );

      final bShows = await nodeB.repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.show));
      final bShowRow = bShows.items.single.item;
      final bEpBefore = (await nodeB.repo.episodesOfShow(bShowRow.id)).single.item;
      expect(bEpBefore.title, 'Episode 1');
      expect(bEpBefore.summary, isNull);

      // Opening movie & show details on Device B lazily hydrates everything from sync_server cache (0 extra upstream TMDB hits!).
      final hydratedMovie = await nodeB.client.fetchItem('${bMovieRow.id}');
      expect(hydratedMovie?.summary, 'Paul Atreides journeys to Arrakis.');
      expect(hydratedMovie?.tagline, 'Beyond fear, destiny awaits.');
      expect(hydratedMovie?.clearLogoPath, '/dune_logo_zh.png');
      expect(hydratedMovie?.artPath, '/dune_backdrop.jpg');
      expect(hydratedMovie?.roles?.map((r) => r.tag), contains('Timothée Chalamet'));
      expect(
        nodeB.client.thumbnailUrl(hydratedMovie?.roles?.first.thumbPath, width: 185),
        'https://cdn-mirror.example/t/p/w185/timothee.jpg',
      );

      final hydratedShow = await nodeB.client.fetchItem('${bShowRow.id}');
      expect(hydratedShow?.summary, 'A Targaryen civil war.');
      expect(hydratedShow?.clearLogoPath, '/hotd_logo.png');
      final bEpAfter = (await nodeB.repo.episodesOfShow(bShowRow.id)).single.item;
      expect(bEpAfter.title, '龙之继承人');
      expect(bEpAfter.summary, 'King Viserys names his heir.');
      expect(bEpAfter.posterSource, '/hotd_s1e1.jpg');

      // Assert zero additional upstream TMDB requests (everything served from sync_server cache)!
      expect((tmdbSearchHits, tmdbMovieHits, tmdbShowHits, tmdbSeasonHits), (2, 1, 1, 1));

      // Lazy hydration must NEVER create dirty journal entries or SyncOutbox items.
      expect(await nodeB.sync.mapper.ensureJournalUpToDate(), 0);
      expect(await nodeB.sync.syncStore.readPendingOutbox(), isEmpty);

      // Subsequent slim work pull on Device B must preserve locally hydrated heavy fields.
      await nodeA.repo.updateItem(scrapedMovie.id, const LibraryItemsCompanion(rating: Value(8.0)));
      await nodeA.sync.onCatalogChanged(mountIds: {'dav_main'});
      await nodeA.sync.pushOutboxOnly();
      while (nodeA.sync.isSyncing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if ((await nodeA.sync.syncStore.readPendingOutbox()).isNotEmpty) {
        await nodeA.sync.syncNow();
      }
      await nodeB.sync.syncNow();
      final movieAfterResync = (await nodeB.repo.getItem(bMovieRow.id))!.item;
      expect(movieAfterResync.rating, 8.0);
      expect(movieAfterResync.summary, 'Paul Atreides journeys to Arrakis.');
      expect(movieAfterResync.backdropSource, '/dune_backdrop.jpg');
      expect(movieAfterResync.logoSource, '/dune_logo_zh.png');
    },
  );
}
