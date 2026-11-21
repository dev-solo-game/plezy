import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library_cloud/cloud_api_client.dart';
import 'package:plezy/library_cloud/cloud_keyring.dart';
import 'package:plezy/library_cloud/cloud_mount_mirror.dart';
import 'package:plezy/library_cloud/cloud_projection_engine.dart';
import 'package:plezy/library_cloud/projection_sync.dart';
import 'package:plezy/library_cloud/scan_session_runner.dart';
import 'package:plezy/library_cloud/source_repository.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('CloudMountMirror + CloudProjectionEngine projects cloud snapshot, preserves local mounts, and prunes empty shells', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final mountRegistry = MountRegistry(db);

    // Seed a local-folder mount that MUST remain untouched by cloud projection.
    await mountRegistry.upsert(
      const StorageMount(
        id: 'local_1',
        kind: StorageKind.local,
        displayName: 'Local Disk',
        config: {MountKeys.rootPath: 'D:/Movies'},
      ),
    );

    final hk = CloudKeyring.generateMasterKey();
    final webdavCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'base_url': 'https://nas.example/dav', 'username': 'alice', 'password': 'pw123', 'root_path': '/'},
    );

    var includeMovieFile = true;
    var serverSeq = 10;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'sources': [
              {
                'id': 'src_dav',
                'kind': 'webdav',
                'name': 'Home WebDAV',
                'identity_key': 'hmac_1',
                'status': 'active',
                'folders': [
                  {'id': 'f1', 'source_id': 'src_dav', 'path': '/Movies'},
                ],
              },
            ],
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/sources/src_dav/credential') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_dav',
              'ciphertext': webdavCipher,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        final kind = req.uri.queryParameters['kind'];
        final items = <Map<String, dynamic>>[];
        if (kind == 'movie' && includeMovieFile) {
          items.add({
            'id': 100,
            'work_key': 'tmdb:movie:27205',
            'kind': 'movie',
            'library_type': 'movie',
            'title': 'Inception',
            'sort_title': 'inception',
            'year': 2010,
            'added_at': 1700000000000,
            'updated_at': 1700000000000,
          });
        }
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'snapshot_seq': serverSeq,
            'total': items.length,
            'page': 1,
            'page_size': 100,
            'has_more': false,
            'items': items,
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/items/100') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'item': {
              'id': 100,
              'files': includeMovieFile
                  ? [
                      {
                        'id': 500,
                        'source_id': 'src_dav',
                        'path': '/Movies/Inception.2010.mkv',
                        'size': 2048,
                        'role': 'video',
                      },
                    ]
                  : <Map<String, dynamic>>[],
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/library/changes') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'reset_required': true,
            'latest_seq': serverSeq,
            'min_retained_seq': serverSeq,
            'next_since_seq': serverSeq,
            'has_more': false,
            'changes': <Map<String, dynamic>>[],
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/progress') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'items': [
              {
                'work_key': 'tmdb:movie:27205',
                'position_ms': 95000,
                'watched': false,
                'play_count': 0,
              },
            ],
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/favorites') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'items': [
              {'work_key': 'tmdb:movie:27205'},
            ],
          }),
        );
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_proj');
    addTearDown(api.close);

    final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
    final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
    final syncClient = CloudProjectionSyncClient(api);
    final engine = CloudProjectionEngine(db: db, syncClient: syncClient, mountMirror: mirror);

    // 1. Full snapshot projects movie, mirrored cloud mount, and user state
    final res1 = await engine.syncFullSnapshot();
    expect(res1.fullReset, isTrue);
    expect(res1.latestSeq, 10);
    expect(res1.itemsProjected, 1);
    expect(res1.filesProjected, 1);

    final mounts = await mountRegistry.list();
    expect(mounts.map((m) => m.id), containsAll(['local_1', 'cloud:src_dav']));
    final mirrored = mounts.firstWhere((m) => m.id == 'cloud:src_dav');
    expect(mirrored.secrets[MountKeys.secretPassword], 'pw123');

    final items1 = await db.select(db.libraryItems).get();
    expect(items1.length, 1);
    expect(items1.single.title, 'Inception');

    final userStates = await db.select(db.libraryUserStates).get();
    expect(userStates.length, 1);
    expect(userStates.single.positionMs, 95000);
    expect(userStates.single.favorite, isTrue);

    // 2. Movie removed on server -> incremental sync hits reset_required -> empty shell pruned
    includeMovieFile = false;
    serverSeq = 12;
    final res2 = await engine.syncIncremental();
    expect(res2.fullReset, isTrue);
    expect(res2.latestSeq, 12);
    expect(res2.emptyShellsPruned, 1);

    final items2 = await db.select(db.libraryItems).get();
    expect(items2, isEmpty);

    // Local mount was preserved
    final localMount = await mountRegistry.get('local_1');
    expect(localMount, isNotNull);

    // 3. Server emits media_file / source_folder delta changes -> triggers full snapshot & sync-state notifications
    includeMovieFile = true;
    serverSeq = 15;
    final syncStates = <bool>[];
    final engine2 = CloudProjectionEngine(
      db: db,
      syncClient: syncClient,
      mountMirror: mirror,
      onSyncStateChanged: syncStates.add,
    );
    addTearDown(engine2.stopListeningEvents);

    // First snapshot puts lastSeq = 15, then verify media_file change at seq 15 triggers resync
    final initialRes = await engine2.syncFullSnapshot();
    expect(initialRes.latestSeq, 15);
    expect(syncStates, [true, false]);

    // Mock /changes: phase 1 returns media_file upsert (no full snapshot reset);
    // phase 2 returns source_folder upsert (triggers full snapshot fallback).
    final deltaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => deltaServer.close(force: true));
    var deltaSnapshotPasses = 0;
    var deltaChangesPhase = 1;
    deltaServer.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(jsonEncode({'code': 0, 'sources': <Map<String, dynamic>>[]}));
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        if (req.uri.queryParameters['kind'] == 'movie') {
          deltaSnapshotPasses++;
        }
        req.response.write(
          jsonEncode({
            'code': 0,
            'snapshot_seq': deltaSnapshotPasses == 1 ? 10 : 14,
            'total': 0,
            'page': 1,
            'page_size': 100,
            'has_more': false,
            'items': <Map<String, dynamic>>[],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
        if (deltaChangesPhase == 1) {
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': false,
              'latest_seq': 12,
              'min_retained_seq': 1,
              'next_since_seq': 12,
              'has_more': false,
              'changes': [
                {'seq': 11, 'entity': 'media_file', 'entity_id': '1', 'op': 'upsert'},
              ],
            }),
          );
        } else {
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': false,
              'latest_seq': 14,
              'min_retained_seq': 1,
              'next_since_seq': 14,
              'has_more': false,
              'changes': [
                {'seq': 13, 'entity': 'source_folder', 'entity_id': 'f1', 'op': 'upsert'},
              ],
            }),
          );
        }
      } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final deltaApi = CloudApiClient(baseUrl: 'http://127.0.0.1:${deltaServer.port}', accessToken: 'usr_d');
    addTearDown(deltaApi.close);
    final deltaRepo = CloudSourceRepository(api: deltaApi, masterKeyProvider: () => hk);
    final deltaEngine = CloudProjectionEngine(
      db: db,
      syncClient: CloudProjectionSyncClient(deltaApi),
      mountMirror: CloudMountMirror(sourceRepository: deltaRepo, mountRegistry: mountRegistry),
    );
    addTearDown(deltaEngine.stopListeningEvents);
    await deltaEngine.syncFullSnapshot();
    expect(deltaSnapshotPasses, 1);

    // Phase 1: pending media_file upsert advances seq without triggering full snapshot
    final mfRes = await deltaEngine.syncIncremental();
    expect(mfRes.fullReset, isFalse);
    expect(mfRes.hasChanges, isFalse);
    expect(mfRes.latestSeq, 12);
    expect(deltaSnapshotPasses, 1);

    // Phase 2: structural source_folder change triggers full snapshot fallback
    deltaChangesPhase = 2;
    final deltaRes = await deltaEngine.syncIncremental();
    expect(deltaRes.fullReset, isTrue);
    expect(deltaSnapshotPasses, 2);
  });

  test(
    'CloudProjectionEngine projects movie + show/season/episode with inline files, subtitles, and episode progress without item-detail N+1 calls',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);

      final hk = CloudKeyring.generateMasterKey();
      final quarkCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'cookie': 'uid=u123; pus=abc', 'root_id': '0'},
      );

      var itemDetailCalls = 0;
      String? seenIncludeFilesParam;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_qk',
                  'kind': 'quark',
                  'name': 'My Quark',
                  'identity_key': 'quark:u123',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_qk', 'path': '/Media'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_qk/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {
                'source_id': 'src_qk',
                'ciphertext': quarkCipher,
                'version': 1,
                'key_epoch': 1,
                'status': 'valid',
              },
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          seenIncludeFilesParam = req.uri.queryParameters['include_files'];
          final kind = req.uri.queryParameters['kind'];
          final items = switch (kind) {
            'movie' => [
              {
                'id': 10,
                'work_key': 'tmdb:movie:27205',
                'kind': 'movie',
                'library_type': 'movie',
                'title': 'Inception',
                'sort_title': 'inception',
                'year': 2010,
                'tmdb_id': '27205',
                'imdb_id': 'tt1375666',
                'poster_url': '/api/v1/metadata/artwork?src=%2Fp.jpg',
                'added_at': 1700000000000,
                'source_added_at': 1699999000000,
                'updated_at': 1700000005000,
                'files': [
                  {
                    'id': 101,
                    'source_id': 'src_qk',
                    'path': '/Media/Inception.mkv',
                    'remote_id': 'fid_m1',
                    'size': 4096,
                    'mtime_s': 1700000001,
                    'subtitles': [
                      {
                        'id': 201,
                        'source_id': 'src_qk',
                        'path': '/Media/Inception.zh.srt',
                        'remote_id': 'fid_ms1',
                        'language': 'zh',
                        'size': 512,
                      },
                    ],
                  },
                ],
              },
            ],
            'show' => [
              {
                'id': 20,
                'work_key': 'tmdb:show:100',
                'kind': 'show',
                'library_type': 'anime',
                'title': 'Sample Anime',
                'sort_title': 'sample anime',
                'year': 2024,
                'tmdb_id': '100',
                'added_at': 1700000000000,
                'source_added_at': 1699998000000,
                'updated_at': 1700000006000,
              },
            ],
            'season' => [
              {
                'id': 30,
                'work_key': '',
                'kind': 'season',
                'library_type': 'anime',
                'parent_id': 20,
                'show_id': 20,
                'title': 'Season 1',
                'sort_title': 'season 1',
                'season_number': 1,
                'added_at': 1700000000000,
                'updated_at': 1700000006000,
              },
            ],
            'episode' => [
              {
                'id': 40,
                'work_key': '',
                'kind': 'episode',
                'library_type': 'anime',
                'parent_id': 30,
                'show_id': 20,
                'title': 'Episode 2',
                'sort_title': 'episode 2',
                'season_number': 1,
                'episode_number': 2,
                'added_at': 1700000000000,
                'updated_at': 1700000006000,
                'files': [
                  {
                    'id': 102,
                    'source_id': 'src_qk',
                    'path': '/Media/Anime/S01E02.mkv',
                    'remote_id': 'fid_ep2',
                    'size': 8192,
                    'mtime_s': 1700000002,
                    'subtitles': [
                      {
                        'id': 202,
                        'source_id': 'src_qk',
                        'path': '/Media/Anime/S01E02.zh.srt',
                        'remote_id': 'fid_eps2',
                        'language': 'zh',
                        'size': 256,
                      },
                    ],
                  },
                ],
              },
            ],
            _ => <Map<String, dynamic>>[],
          };
          req.response.write(
            jsonEncode({
              'code': 0,
              'snapshot_seq': 42,
              'total': items.length,
              'page': 1,
              'page_size': 200,
              'has_more': false,
              'items': items,
            }),
          );
        } else if (req.method == 'GET' && path.startsWith('/api/v1/items/')) {
          itemDetailCalls++;
          req.response.statusCode = 404;
        } else if (req.method == 'GET' && path == '/api/v1/progress') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {
                  'progress_key': 'tmdb:show:100:s1:e2',
                  'work_key': 'tmdb:show:100',
                  'season_number': 1,
                  'episode_number': 2,
                  'position_ms': 123000,
                  'duration_ms': 1440000,
                  'watched': false,
                  'play_count': 1,
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/favorites') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'items': [
                {'work_key': 'tmdb:show:100'},
              ],
            }),
          );
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_hier');
      addTearDown(api.close);

      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final mirror = CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry);
      final engine = CloudProjectionEngine(db: db, syncClient: CloudProjectionSyncClient(api), mountMirror: mirror);

      final res = await engine.syncFullSnapshot();
      expect(seenIncludeFilesParam, '1');
      expect(itemDetailCalls, 0);
      expect(res.latestSeq, 42);
      expect(res.itemsProjected, 4);
      expect(res.filesProjected, 4); // 2 videos + 2 subtitles
      expect(res.emptyShellsPruned, 0);

      final items = await db.select(db.libraryItems).get();
      expect(items.length, 4);
      final movieRow = items.firstWhere((e) => e.kind == LibraryKinds.movie);
      final showRow = items.firstWhere((e) => e.kind == LibraryKinds.show);
      final seasonRow = items.firstWhere((e) => e.kind == LibraryKinds.season);
      final epRow = items.firstWhere((e) => e.kind == LibraryKinds.episode);

      expect(movieRow.tmdbId, '27205');
      expect(movieRow.metadataSource, 'tmdb');
      expect(movieRow.sourceAddedAt, 1699999000000);
      expect(showRow.libraryType, LibraryTypes.anime);
      expect(seasonRow.parentId, showRow.id);
      expect(seasonRow.showId, showRow.id);
      expect(seasonRow.workKey, 'tmdb:show:100:s1');
      expect(epRow.parentId, seasonRow.id);
      expect(epRow.showId, showRow.id);
      expect(epRow.workKey, 'tmdb:show:100:s1:e2');

      final files = await db.select(db.libraryFiles).get();
      expect(files.length, 4);
      final epVideo = files.firstWhere((f) => f.role == LibraryFileRoles.video && f.itemId == epRow.id);
      expect(epVideo.remoteId, 'fid_ep2');
      expect(epVideo.modifiedAt, 1700000002000);

      final epSub = files.firstWhere((f) => f.role == LibraryFileRoles.subtitle && f.ownerFileId == epVideo.id);
      expect(epSub.itemId, isNull);
      expect(epSub.language, 'zh');
      expect(epSub.path, '/Media/Anime/S01E02.zh.srt');

      final states = await db.select(db.libraryUserStates).get();
      final epState = states.firstWhere((s) => s.itemId == epRow.id);
      expect(epState.positionMs, 123000);
      expect(epState.durationMs, 1440000);
      expect(epState.favorite, isFalse);

      final showState = states.firstWhere((s) => s.itemId == showRow.id);
      expect(showState.favorite, isTrue);
    },
  );

  test('CloudProjectionEngine.syncIncremental emits onSyncStateChanged and hasChanges=false when no server changes', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final mountRegistry = MountRegistry(db);
    final hk = CloudKeyring.generateMasterKey();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(jsonEncode({'code': 0, 'sources': <Map<String, dynamic>>[]}));
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'snapshot_seq': 50,
            'total': 0,
            'page': 1,
            'page_size': 200,
            'has_more': false,
            'items': <Map<String, dynamic>>[],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'reset_required': false,
            'latest_seq': 50,
            'min_retained_seq': 1,
            'next_since_seq': 50,
            'has_more': false,
            'changes': <Map<String, dynamic>>[],
          }),
        );
      } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_empty');
    addTearDown(api.close);
    final syncStates = <bool>[];
    final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
    final engine = CloudProjectionEngine(
      db: db,
      syncClient: CloudProjectionSyncClient(api),
      mountMirror: CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry),
      onSyncStateChanged: syncStates.add,
    );
    addTearDown(engine.stopListeningEvents);

    await engine.syncFullSnapshot();
    syncStates.clear();

    final res = await engine.syncIncremental();
    expect(syncStates, [true, false]);
    expect(res.hasChanges, isFalse);
    expect(res.fullReset, isFalse);
  });

  test(
    'CloudProjectionEngine.syncIncremental projects item+files delta in place and hydrateItemDetailFromCloud pulls details',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final mountRegistry = MountRegistry(db);
      final hk = CloudKeyring.generateMasterKey();
      final qkCipher = await CloudKeyring.encryptCredentialJson(
        masterKey: hk,
        payload: {'cookie': 'uid=u1', 'root_id': '0'},
      );

      var snapshotMovieCalls = 0;
      var byWorkKeyCalls = 0;
      String? changesIncludeFiles;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final path = req.uri.path;
        if (req.method == 'GET' && path == '/api/v1/sources') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'sources': [
                {
                  'id': 'src_qk',
                  'kind': 'quark',
                  'name': 'Quark',
                  'identity_key': 'qk_1',
                  'status': 'active',
                  'folders': [
                    {'id': 'f1', 'source_id': 'src_qk', 'path': '/TV'},
                  ],
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/sources/src_qk/credential') {
          req.response.write(
            jsonEncode({
              'code': 0,
              'credential': {'source_id': 'src_qk', 'ciphertext': qkCipher, 'version': 1, 'key_epoch': 1, 'status': 'valid'},
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
          final kind = req.uri.queryParameters['kind'];
          if (kind == 'movie') snapshotMovieCalls++;
          final items = switch (kind) {
            'show' => [
              {
                'id': 20,
                'work_key': 'tmdb:show:279155',
                'kind': 'show',
                'library_type': 'show',
                'title': '谷雨',
                'sort_title': 'gu yu',
                'added_at': 1000,
                'source_added_at': 1000,
                'updated_at': 1000,
              },
            ],
            'season' => [
              {
                'id': 30,
                'kind': 'season',
                'library_type': 'show',
                'parent_id': 20,
                'show_id': 20,
                'title': '第 1 季',
                'season_number': 1,
                'added_at': 1000,
                'updated_at': 1000,
              },
            ],
            'episode' => [
              {
                'id': 40,
                'kind': 'episode',
                'library_type': 'show',
                'parent_id': 30,
                'show_id': 20,
                'title': '第 1 集',
                'season_number': 1,
                'episode_number': 1,
                'added_at': 1000,
                'updated_at': 1000,
                'files': [
                  {'id': 501, 'source_id': 'src_qk', 'path': '/TV/GuYu/S01E01.mkv', 'remote_id': 'rk_e1', 'mtime_s': 1000},
                ],
              },
            ],
            _ => <Map<String, dynamic>>[],
          };
          req.response.write(
            jsonEncode({'code': 0, 'snapshot_seq': 10, 'total': items.length, 'page': 1, 'page_size': 200, 'has_more': false, 'items': items}),
          );
        } else if (req.method == 'GET' && path == '/api/v1/library/changes') {
          changesIncludeFiles = req.uri.queryParameters['include_files'];
          req.response.write(
            jsonEncode({
              'code': 0,
              'reset_required': false,
              'latest_seq': 15,
              'min_retained_seq': 1,
              'next_since_seq': 15,
              'has_more': false,
              'changes': [
                {
                  'seq': 12,
                  'entity': 'item',
                  'entity_id': '20',
                  'op': 'upsert',
                  'data': {
                    'id': 20,
                    'work_key': 'tmdb:show:279155',
                    'kind': 'show',
                    'library_type': 'show',
                    'title': '谷雨',
                    'sort_title': 'gu yu',
                    'added_at': 1000,
                    'source_added_at': 5000000,
                    'updated_at': 5000000,
                  },
                },
                {
                  'seq': 15,
                  'entity': 'item',
                  'entity_id': '41',
                  'op': 'upsert',
                  'data': {
                    'id': 41,
                    'kind': 'episode',
                    'library_type': 'show',
                    'parent_id': 30,
                    'show_id': 20,
                    'show_work_key': 'tmdb:show:279155',
                    'title': '第 2 集',
                    'season_number': 1,
                    'episode_number': 2,
                    'added_at': 5000000,
                    'updated_at': 5000000,
                    'files': [
                      {
                        'id': 502,
                        'source_id': 'src_qk',
                        'path': '/TV/GuYu/S01E02.mkv',
                        'remote_id': 'rk_e2',
                        'mtime_s': 5000,
                        'subtitles': [
                          {'id': 602, 'source_id': 'src_qk', 'path': '/TV/GuYu/S01E02.zh.srt', 'remote_id': 'rk_s2', 'language': 'zh'},
                        ],
                      },
                    ],
                  },
                },
              ],
            }),
          );
        } else if (req.method == 'GET' && path == '/api/v1/items/by-work-key') {
          byWorkKeyCalls++;
          req.response.write(
            jsonEncode({
              'code': 0,
              'item': {
                'id': 20,
                'work_key': 'tmdb:show:279155',
                'kind': 'show',
                'library_type': 'show',
                'title': '谷雨',
                'sort_title': 'gu yu',
                'summary': 'Detailed summary',
                'tagline': 'Rain of Grain',
                'studio': 'Tencent',
                'genres': ['剧情', '悬疑'],
                'credits': [
                  {'person_id': 1, 'name': '张颂文', 'job': 'actor', 'character': '主角', 'photo_url': '/api/v1/metadata/artwork?src=%2Factor.jpg'},
                ],
                'children': [
                  {
                    'id': 30,
                    'kind': 'season',
                    'library_type': 'show',
                    'parent_id': 20,
                    'show_id': 20,
                    'show_work_key': 'tmdb:show:279155',
                    'title': '第 1 季',
                    'season_number': 1,
                    'added_at': 1000,
                    'updated_at': 1000,
                  },
                ],
                'episodes': [],
              },
            }),
          );
        } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
          req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_inc');
      addTearDown(api.close);
      final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
      final engine = CloudProjectionEngine(
        db: db,
        syncClient: CloudProjectionSyncClient(api),
        mountMirror: CloudMountMirror(sourceRepository: repo, mountRegistry: mountRegistry),
      );
      addTearDown(engine.stopListeningEvents);

      await engine.syncFullSnapshot();
      expect(snapshotMovieCalls, 1);

      final incRes = await engine.syncIncremental();
      expect(changesIncludeFiles, '1');
      expect(snapshotMovieCalls, 1); // zero extra full snapshots
      expect(incRes.fullReset, isFalse);
      expect(incRes.hasChanges, isTrue);
      expect(incRes.itemsProjected, 2);
      expect(incRes.filesProjected, 2); // 1 video + 1 subtitle

      final showRow = await (db.select(db.libraryItems)..where((t) => t.kind.equals('show'))).getSingle();
      expect(showRow.sourceAddedAt, 5000000);
      final eps = await (db.select(db.libraryItems)..where((t) => t.kind.equals('episode'))).get();
      expect(eps.length, 2);
      final ep2 = eps.firstWhere((e) => e.episodeNumber == 2);
      expect(ep2.workKey, 'tmdb:show:279155:s1:e2');

      final hydrated = await engine.hydrateItemDetailFromCloud(showRow.id, showRow.workKey!);
      expect(hydrated, isTrue);
      expect(byWorkKeyCalls, 1);

      final libRepo = LibraryRepository(db);
      final hydratedShow = (await libRepo.getItem(showRow.id))!.item;
      expect(hydratedShow.summary, 'Detailed summary');
      expect(hydratedShow.tagline, 'Rain of Grain');
      expect(hydratedShow.studio, 'Tencent');
      expect((await libRepo.genresOf(showRow.id)).map((g) => g.name), containsAll(['剧情', '悬疑']));
      final credits = await libRepo.creditsOf(showRow.id);
      expect(credits.single.person.name, '张颂文');
      expect(credits.single.person.photoSource, '/api/v1/metadata/artwork?src=%2Factor.jpg');
    },
  );

  test(
    'CloudScanSessionRunner.runQuarkIncrementalScan skips ancestry, dir list, and server session when known files unchanged',
    () async {
      resetSharedPreferencesForTest();
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      var scanSessionCalls = 0;
      var ancestryCalls = 0;
      var driverListCalls = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        if (req.method == 'POST' && req.uri.path.endsWith('/scan-sessions')) {
          scanSessionCalls++;
          req.response.write(
            jsonEncode({
              'code': 0,
              'session': {
                'id': 'sess_1',
                'incremental_watermark': 2000000,
                'folders': [
                  {'id': 'f1', 'path': '/TV', 'exclude_paths': <String>[]},
                ],
              },
            }),
          );
        } else if (req.method == 'POST' && req.uri.path.endsWith('/batches')) {
          req.response.write(jsonEncode({'code': 0, 'receipt': {'added': 1, 'changed': 0, 'removed': 0}}));
        } else if (req.method == 'POST' && req.uri.path.endsWith('/complete')) {
          req.response.write(jsonEncode({'code': 0}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_inc_scan');
      addTearDown(api.close);
      final runner = CloudScanSessionRunner(api: api);
      addTearDown(runner.dispose);

      final fakeDriver = _FakeQuarkIncrementalDriver(onList: () => driverListCalls++);

      // 1. Unchanged file within overlap window -> 0 session calls, 0 ancestry calls, 0 list calls
      final noopProg = await runner.runQuarkIncrementalScan(
        sourceId: 'src_qk',
        driver: fakeDriver,
        knownServerWatermark: 2000000,
        knownFileMtimesByRemoteId: const {'rk_1': 2000000},
        rootFolderIdOverride: '0',
        folderAncestryOverride: (id) async {
          ancestryCalls++;
          return [(id: '0', name: 'root'), (id: 'd1', name: 'TV')];
        },
        searchUpdatedPageOverride: (page, {size = 50}) async => [
          (
            entry: StorageEntry(id: 'rk_1', path: '/S01E01.mkv', name: 'S01E01.mkv', isDirectory: false),
            parentId: 'd1',
            updatedAt: 2000000,
          ),
        ],
      );
      expect(noopProg.completed, isTrue);
      expect(noopProg.filesReported, 0);
      expect(scanSessionCalls, 0);
      expect(ancestryCalls, 0);
      expect(driverListCalls, 0);

      // 2. New file with newer updatedAt -> opens session, resolves ancestry, lists dir, uploads batch
      final dirtyProg = await runner.runQuarkIncrementalScan(
        sourceId: 'src_qk',
        driver: fakeDriver,
        knownServerWatermark: 2000000,
        knownFileMtimesByRemoteId: const {'rk_1': 2000000},
        rootFolderIdOverride: '0',
        folderAncestryOverride: (id) async {
          ancestryCalls++;
          return [(id: '0', name: 'root'), (id: 'd1', name: 'TV')];
        },
        searchUpdatedPageOverride: (page, {size = 50}) async => [
          (
            entry: StorageEntry(id: 'rk_2', path: '/S01E02.mkv', name: 'S01E02.mkv', isDirectory: false),
            parentId: 'd1',
            updatedAt: 2500000,
          ),
        ],
      );
      expect(dirtyProg.completed, isTrue);
      expect(dirtyProg.filesReported, 1);
      expect(scanSessionCalls, 1);
      expect(ancestryCalls, 1);
      expect(driverListCalls, 1);
    },
  );
}

class _FakeQuarkIncrementalDriver implements StorageDriver {
  _FakeQuarkIncrementalDriver({required this.onList});

  final void Function() onList;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    onList();
    return [
      StorageEntry(
        id: 'rk_2',
        path: '/TV/S01E02.mkv',
        name: 'S01E02.mkv',
        isDirectory: false,
        size: 4096,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(2500000),
      ),
    ];
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int? start, int? end}) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
