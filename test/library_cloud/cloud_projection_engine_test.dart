import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library_cloud/cloud_api_client.dart';
import 'package:plezy/library_cloud/cloud_keyring.dart';
import 'package:plezy/library_cloud/cloud_mount_mirror.dart';
import 'package:plezy/library_cloud/cloud_projection_engine.dart';
import 'package:plezy/library_cloud/projection_sync.dart';
import 'package:plezy/library_cloud/source_repository.dart';
import 'package:plezy/storage/mount_registry.dart';
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
  });
}
