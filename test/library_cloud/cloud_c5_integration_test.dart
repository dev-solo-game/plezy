import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/scrapers/server_metadata_provider.dart';
import 'package:plezy/library_cloud/cloud_keyring.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/ttplay/ttplay_session_binder.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('ServerMetadataProvider uses authenticated /api/v1/metadata/* endpoints when accessToken is provided', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final seenPaths = <String>[];
    String? seenAuth;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      seenPaths.add(req.uri.path);
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
      req.response.statusCode = 200;
      if (req.uri.path == '/api/v1/metadata/identify') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'matched': true,
            'kind': 'movie',
            'work_key': 'tmdb:movie:27205',
            'source': 'tmdb',
            'bridged_from': '',
            'implied_season': 0,
            'work': {
              'source': 'tmdb',
              'id': '27205',
              'kind': 'movie',
              'title': 'Inception',
              'year': 2010,
            },
          }),
        );
      } else if (req.uri.path == '/api/v1/metadata/search') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'results': [
              {'source': 'tmdb', 'id': '27205', 'title': 'Inception', 'year': 2010},
            ],
          }),
        );
      }
      await req.response.close();
    });

    final provider = ServerMetadataProvider(
      serverUrl: 'http://127.0.0.1:${server.port}',
      accessToken: 'usr_secret_token',
    );
    addTearDown(provider.close);

    final ident = await provider.identify(title: 'Inception', year: 2010, kind: 'movie', filename: 'Inception.2010.mkv');
    expect(ident.matched, isTrue);
    expect(ident.workKey, 'tmdb:movie:27205');
    expect(seenAuth, 'Bearer usr_secret_token');

    final search = await provider.searchMovie('Inception', year: 2010);
    expect(search.length, 1);
    expect(seenPaths, ['/api/v1/metadata/identify', '/api/v1/metadata/search']);
  });

  test('TtplaySessionBinder wires CloudProjectionEngine, pushes watch state by work_key, manages match rules, and cleans up on logout', () async {
    resetSharedPreferencesForTest();
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
    final serverManager = MultiServerManager();
    final sessionController = AppSessionController(db: db, mountManager: mounts);

    // Seed a local-folder mount and local movie that must survive cloud login & logout.
    await mounts.registry.upsert(
      const StorageMount(
        id: 'local_disk',
        kind: StorageKind.local,
        displayName: 'Local Disk',
        config: {MountKeys.rootPath: 'D:/LocalMovies'},
      ),
    );
    final localItemId = await db.into(db.libraryItems).insert(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:157336'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Interstellar',
        sortTitle: 'interstellar',
        addedAt: 1700000000000,
        updatedAt: 1700000000000,
      ),
    );
    await db.into(db.libraryFiles).insert(
      LibraryFilesCompanion.insert(
        fileKey: const Value('local_fk_1'),
        mountId: 'local_disk',
        path: '/Interstellar.2014.mkv',
        role: LibraryFileRoles.video,
        itemId: Value(localItemId),
        matchState: const Value(LibraryMatchStates.matched),
        addedAt: 1700000000000,
      ),
    );

    final hk = CloudKeyring.generateMasterKey();
    final davCipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'base_url': 'https://nas.local/dav', 'username': 'u', 'password': 'p', 'root_path': '/'},
    );

    final pushedProgress = <Map<String, dynamic>>[];
    final pushedFavorites = <String>[];
    final deletedRuleIds = <String>[];

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      final bodyText = await utf8.decoder.bind(req).join();
      if (req.method == 'GET' && path == '/api/v1/sources') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'sources': [
              {
                'id': 'src_cloud_1',
                'kind': 'webdav',
                'name': 'Cloud WebDAV',
                'identity_key': 'hmac_c1',
                'status': 'active',
              },
            ],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/sources/src_cloud_1/credential') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_cloud_1',
              'ciphertext': davCipher,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        final kind = req.uri.queryParameters['kind'];
        req.response.write(
          jsonEncode({
            'code': 0,
            'snapshot_seq': 5,
            'total': kind == 'movie' ? 1 : 0,
            'page': 1,
            'page_size': 100,
            'has_more': false,
            'items': kind == 'movie'
                ? [
                    {
                      'id': 200,
                      'work_key': 'tmdb:movie:27205',
                      'kind': 'movie',
                      'library_type': 'movie',
                      'title': 'Inception',
                      'sort_title': 'inception',
                      'year': 2010,
                    },
                  ]
                : <Map<String, dynamic>>[],
          }),
        );
      } else if (req.method == 'GET' && path == '/api/v1/items/200') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'item': {
              'id': 200,
              'files': [
                {'id': 900, 'source_id': 'src_cloud_1', 'path': '/Movies/Inception.mkv', 'size': 4096, 'role': 'video'},
              ],
            },
          }),
        );
      } else if (req.method == 'GET' && (path == '/api/v1/progress' || path == '/api/v1/favorites')) {
        req.response.write(jsonEncode({'code': 0, 'items': <Map<String, dynamic>>[]}));
      } else if (req.method == 'POST' && path == '/api/v1/progress') {
        final m = jsonDecode(bodyText) as Map<String, dynamic>;
        pushedProgress.add(m);
        req.response.write(jsonEncode({'code': 0, 'progress': m}));
      } else if (req.method == 'PUT' && path.startsWith('/api/v1/favorites/')) {
        pushedFavorites.add(Uri.decodeComponent(path.split('/').last));
        req.response.write(jsonEncode({'code': 0}));
      } else if (req.method == 'GET' && path == '/api/v1/match-rules') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'rules': [
              {'id': 'rule_1', 'path_prefix': '/Anime/Frieren', 'action': 'bind', 'target_provider': 'tmdb'},
            ],
          }),
        );
      } else if (req.method == 'DELETE' && path.startsWith('/api/v1/match-rules/')) {
        deletedRuleIds.add(path.split('/').last);
        req.response.write(jsonEncode({'code': 0}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final session = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:${server.port}',
      username: 'alice',
      accessToken: 'usr_tok',
      householdId: 'hh_1',
      memberId: 'mem_1',
      masterKeyB64: base64Encode(hk),
    );
    sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: session);

    var localLibraryMutatedCalls = 0;
    final binder = TtplaySessionBinder(
      sessionController: sessionController,
      serverManager: serverManager,
      localLibraryClient: localClient,
      isTv: () => false,
      onLocalLibraryMutated: () => localLibraryMutatedCalls++,
    );
    addTearDown(binder.dispose);

    binder.seedSelfHostedSynchronously(session);
    expect(binder.cloudProjectionEngine, isNotNull);
    expect(binder.isMediaLibraryV1Active, isTrue);
    expect(serverManager.registeredServerIds, contains(LocalLibraryClient.localServerId));

    // Verify all poster artwork routes through our media_library server (never direct to TMDB).
    final proxiedThumb = localClient.thumbnailUrl('/abc123.jpg', width: 500);
    expect(proxiedThumb, startsWith('http://127.0.0.1:${server.port}/api/v1/metadata/artwork?src=%2Fabc123.jpg'));
    expect(proxiedThumb, contains('token=usr_tok'));
    expect(proxiedThumb, isNot(contains('image.tmdb.org')));

    // 1. Sync cloud projection -> DB now holds BOTH local Interstellar and cloud Inception
    final syncRes = await binder.syncCloudProjection(full: true);
    expect(syncRes, isNotNull);
    expect(syncRes!.itemsProjected, 1);
    expect(localLibraryMutatedCalls, 1);

    final allItems = await db.select(db.libraryItems).get();
    expect(allItems.map((e) => e.title), containsAll(['Interstellar', 'Inception']));

    // 2. Local progress & favorite mutations push upstream by work_key (even for local-disk item, per D9)
    await localClient.reportPlaybackProgress(
      itemId: '$localItemId',
      position: const Duration(seconds: 180),
      duration: const Duration(seconds: 600),
    );
    await localClient.setFavorite(
      MediaItem(id: '$localItemId', backend: MediaBackend.jellyfin, kind: MediaKind.movie, title: 'Interstellar'),
      true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(pushedProgress.any((p) => p['work_key'] == 'tmdb:movie:157336' && p['position_ms'] == 180000), isTrue);
    expect(pushedFavorites, contains('tmdb:movie:157336'));

    // 3. Match rules list & delete work through CloudProjectionSyncClient
    final rules = await binder.cloudProjectionSync!.listMatchRules();
    expect(rules.single['id'], 'rule_1');
    await binder.cloudProjectionSync!.deleteMatchRule('rule_1');
    expect(deletedRuleIds, ['rule_1']);

    // 4. Cloud cleanup removes cloud:* mount & cloud movie while preserving local-disk movie
    await binder.clearCloudProjectionData();
    final remainingMounts = await mounts.registry.list();
    expect(remainingMounts.map((m) => m.id), ['local_disk']);
    final remainingItems = await db.select(db.libraryItems).get();
    expect(remainingItems.map((e) => e.title), ['Interstellar']);
  });
}
