import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/ttplay/ttplay_admin_service.dart';
import 'package:plezy/ttplay/ttplay_api_client.dart';

class _AdminRequest {
  _AdminRequest({required this.method, required this.path, required this.query, required this.body});

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic> body;
}

class _FakeAdminServer {
  _FakeAdminServer._(this._server);

  final HttpServer _server;
  final List<_AdminRequest> requests = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeAdminServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeAdminServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    Map<String, dynamic> reqBody = const {};
    if (text.trim().isNotEmpty) {
      final decoded = jsonDecode(text);
      if (decoded is Map) reqBody = Map<String, dynamic>.from(decoded);
    }
    final path = req.uri.path;
    requests.add(_AdminRequest(method: req.method, path: path, query: req.uri.queryParameters, body: reqBody));

    if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer admin-tok') {
      await _write(req, 401, const {'error': 'unauthorized'});
      return;
    }

    if (path == '/api/v1/mounts' && req.method == 'GET') {
      await _write(req, 200, {
        'code': 0,
        'mounts': [
          {
            'id': 'm1',
            'name': 'NAS Movies',
            'kind': 'smb',
            'config': {'host': '192.168.1.2', 'share': 'media', 'rootPath': '/movies'},
            'has_secret': true,
            'enabled': true,
            'video_count': 42,
            'total_file_bytes': 1024000,
            'matched_item_count': 40,
            'scan_state': {'status': 'idle'},
          },
        ],
      });
      return;
    }
    if (path == '/api/v1/mounts' && req.method == 'POST') {
      await _write(req, 200, {
        'code': 0,
        'mount': {
          'id': 'm2',
          'name': reqBody['name'],
          'kind': reqBody['kind'],
          'config': reqBody['config'] ?? const {},
          'has_secret': false,
          'enabled': reqBody['enabled'] ?? true,
        },
      });
      return;
    }
    if (path == '/api/v1/mounts/m1' && req.method == 'PUT') {
      await _write(req, 200, {
        'code': 0,
        'mount': {
          'id': 'm1',
          'name': reqBody['name'] ?? 'NAS Movies Updated',
          'kind': 'smb',
          'config': reqBody['config'] ?? const {'host': '192.168.1.2'},
          'has_secret': true,
          'enabled': reqBody['enabled'] ?? false,
        },
      });
      return;
    }
    if (path == '/api/v1/mounts/m1' && req.method == 'DELETE') {
      await _write(req, 200, const {'code': 0, 'status': 'deleted'});
      return;
    }
    if (path == '/api/v1/mounts/test' || path == '/api/v1/mounts/m1/scan' || path == '/api/v1/mounts/m1/cancel-scan') {
      await _write(req, 200, const {'code': 0, 'ok': true});
      return;
    }
    if (path == '/api/v1/fs/browse') {
      await _write(req, 200, {
        'code': 0,
        'current': '/media',
        'parent': '/',
        'dirs': [
          {'name': 'Anime', 'path': '/media/Anime'},
        ],
      });
      return;
    }
    if (path == '/api/v1/quark/qr/start') {
      await _write(req, 200, {
        'code': 0,
        'session_id': 'qr-1',
        'mode': 'pc',
        'qr_content': 'https://example.com/qr/1',
        'expires_at': 9999999999,
      });
      return;
    }
    if (path == '/api/v1/quark/qr/poll') {
      await _write(req, 200, const {'code': 0, 'status': 'confirmed', 'secret': '{"cookie":"ok"}'});
      return;
    }
    if (path == '/api/v1/tasks/status') {
      await _write(req, 200, {
        'code': 0,
        'status': {
          'scans': [
            {'mount_id': 'm1', 'mount_name': 'NAS Movies', 'status': 'running', 'current_path': '/movies/2026'},
          ],
          'scrape': {'status': 'running', 'done': 3, 'total': 10, 'matched': 2, 'unmatched': 1, 'title': 'Dune'},
          'pending_scrape': 7,
          'unmatched_count': 4,
        },
      });
      return;
    }
    if (path == '/api/v1/tasks/scan-all' || path == '/api/v1/tasks/scrape') {
      await _write(req, 200, const {'code': 0, 'status': 'started'});
      return;
    }
    if (path == '/api/v1/settings' && (req.method == 'GET' || req.method == 'PUT')) {
      await _write(req, 200, {
        'code': 0,
        'settings': {
          'server_name': 'Home NAS',
          'tmdb_api_key_set': true,
          'tmdb_api_key_masked': 'abcd****',
          'tmdb_api_base': 'https://api.themoviedb.org/3',
          'tmdb_image_base': 'https://image.tmdb.org/t/p',
          'metadata_proxy': reqBody['metadata_proxy'] ?? '',
          'bangumi_enabled': reqBody['bangumi_enabled'] ?? true,
          'douban_enabled': reqBody['douban_enabled'] ?? true,
          'anilist_enabled': false,
          'imdb_enabled': true,
          'tvdb_enabled': false,
          'allow_public_metadata': reqBody['allow_public_metadata'] ?? true,
          'allow_fallback_metadata': true,
          'custom_recognition_words': 'CUSTOM_TAG',
          'proxy_images': true,
          'scraper_lang': reqBody['scraper_lang'] ?? 'zh-CN',
          'prefer_nfo': false,
          'watched_threshold': 0.9,
          'scan_interval_min': 30,
          'watch_local_fs': true,
        },
      });
      return;
    }
    if (path == '/api/v1/settings/test-tmdb' || path == '/api/v1/settings/test-provider') {
      await _write(req, 200, const {'code': 0, 'ok': true, 'latency_ms': 42, 'message': 'reachable'});
      return;
    }
    if (path == '/api/v1/settings/clear-cache') {
      await _write(req, 200, const {'code': 0, 'deleted': 18});
      return;
    }
    if (path == '/api/v1/scrape/search') {
      await _write(req, 200, {
        'code': 0,
        'results': [
          {
            'source': 'douban',
            'id': '26149750',
            'title': 'Minecraft Movie',
            'original_title': 'A Minecraft Movie',
            'year': 2025,
            'poster_path': '/mc.jpg',
          },
        ],
      });
      return;
    }
    if (path == '/api/v1/items/101' && req.method == 'GET') {
      await _write(req, 200, {
        'code': 0,
        'detail': {
          'item': {
            'id': 101,
            'kind': 'movie',
            'library_type': 'movie',
            'title': 'Inception',
            'original_title': 'Inception',
            'year': 2010,
            'summary': 'Dream heist',
            'tagline': 'Your mind is the scene of the crime',
            'studio': 'Warner Bros',
            'rating': 8.8,
            'locked': true,
          },
          'files': [
            {'id': 1, 'path': '/movies/Inception.mkv'},
          ],
        },
      });
      return;
    }
    if (path == '/api/v1/items/101/match' ||
        path == '/api/v1/items/101/unmatch' ||
        path == '/api/v1/items/101/metadata' ||
        path == '/api/v1/items/101/refresh') {
      await _write(req, 200, const {'code': 0});
      return;
    }
    if (path == '/api/v1/ext-servers' && req.method == 'GET') {
      await _write(req, 200, {
        'code': 0,
        'servers': [
          {
            'id': 'ext1',
            'name': 'Emby Box',
            'kind': 'emby',
            'base_url': 'http://192.168.1.9:8096',
            'auth_mode': 'password',
            'username': 'admin',
            'enabled': true,
          },
        ],
      });
      return;
    }
    if (path == '/api/v1/ext-servers/test') {
      await _write(req, 200, const {
        'code': 0,
        'ok': true,
        'server_name': 'Emby Box',
        'detected_kind': 'emby',
        'latency_ms': 15,
      });
      return;
    }
    if (path == '/api/v1/ext-servers' && req.method == 'POST') {
      await _write(req, 200, {
        'code': 0,
        'server': {
          'id': 'ext2',
          'name': reqBody['name'] ?? 'New JF',
          'kind': reqBody['kind'] ?? 'jellyfin',
          'base_url': reqBody['base_url'] ?? 'http://127.0.0.1:8096',
          'auth_mode': reqBody['auth_mode'] ?? 'apikey',
          'enabled': true,
        },
      });
      return;
    }
    if (path == '/api/v1/ext-servers/ext1' && req.method == 'PUT') {
      await _write(req, 200, {
        'code': 0,
        'server': {
          'id': 'ext1',
          'name': 'Emby Box',
          'kind': 'emby',
          'base_url': 'http://192.168.1.9:8096',
          'auth_mode': 'password',
          'username': 'admin',
          'enabled': reqBody['enabled'] == true,
        },
      });
      return;
    }
    if (path == '/api/v1/ext-servers/ext1' && req.method == 'DELETE') {
      await _write(req, 200, const {'code': 0});
      return;
    }

    await _write(req, 404, const {'error': 'not found'});
  }

  Future<void> _write(HttpRequest req, int status, Map<String, dynamic> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdminServer server;
  late TtplayApiClient api;
  late TtplayAdminService admin;
  HttpOverrides? prevOverrides;

  setUp(() async {
    prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await _FakeAdminServer.start();
    api = TtplayApiClient(baseUrl: server.baseUrl, accessToken: 'admin-tok');
    admin = TtplayAdminService(api);
  });

  tearDown(() async {
    api.close();
    await server.close();
    HttpOverrides.global = prevOverrides;
  });

  test('TtplayAdminService mounts, host browse, quark QR, tasks & settings endpoints', () async {
    final mounts = await admin.listMounts();
    expect(mounts.single.id, 'm1');
    expect(mounts.single.videoCount, 42);

    final created = await admin.createMount(name: 'Local Anime', kind: 'local', config: {'rootPath': '/media/Anime'});
    expect(created.id, 'm2');
    expect(server.requests.last.body['kind'], 'local');

    final updated = await admin.updateMount('m1', enabled: false);
    expect(updated.enabled, isFalse);

    await admin.testMount(kind: 'smb', config: {'host': '192.168.1.2', 'share': 'media'});
    await admin.scanMount('m1', full: true);
    expect(server.requests.last.query['full'], '1');
    await admin.cancelScanMount('m1');
    await admin.deleteMount('m1');

    final fs = await admin.browseHostFs('/media');
    expect(fs.current, '/media');
    expect(fs.dirs.single.path, '/media/Anime');

    final qr = await admin.startQuarkQr();
    expect(qr.sessionId, 'qr-1');
    final poll = await admin.pollQuarkQr(qr.sessionId);
    expect(poll.status, 'confirmed');
    expect(poll.secret, '{"cookie":"ok"}');

    final tasks = await admin.fetchTaskStatus();
    expect(tasks.scans.single.mountId, 'm1');
    expect(tasks.scrape.isRunning, isTrue);
    expect(tasks.pendingScrape, 7);
    expect(tasks.unmatchedCount, 4);

    await admin.triggerScanAll(full: true);
    await admin.triggerScrape(retryUnmatched: true);
    expect(server.requests.last.query['retry_unmatched'], '1');

    final cfg = await admin.fetchSettings();
    expect(cfg.tmdbApiKeyMasked, 'abcd****');
    expect(cfg.customRecognitionWords, 'CUSTOM_TAG');

    final savedCfg = await admin.updateSettings({'scraper_lang': 'ja-JP', 'allow_public_metadata': false});
    expect(savedCfg.scraperLang, 'ja-JP');
    expect(savedCfg.allowPublicMetadata, isFalse);

    final tmdbTest = await admin.testTmdb(tmdbApiKey: 'key123');
    expect(tmdbTest.ok, isTrue);
    expect(tmdbTest.latencyMs, 42);

    final provTest = await admin.testProvider('douban');
    expect(provTest.ok, isTrue);
    expect(server.requests.last.body['provider'], 'douban');

    expect(await admin.clearMetadataCache(), 18);
  });

  test('TtplayAdminService item match/edit/refresh/unmatch and external servers endpoints', () async {
    final cands = await admin.searchScrapeCandidates(query: 'Minecraft', asShow: false, year: 2025, provider: 'douban');
    expect(cands.single.source, 'douban');
    expect(cands.single.id, '26149750');

    await admin.applyManualMatch('101', provider: 'douban', externalId: '26149750', asShow: false, libraryType: 'movie');
    expect(server.requests.last.path, '/api/v1/items/101/match');
    expect(server.requests.last.body['external_id'], '26149750');

    final editable = await admin.fetchEditableItem('101');
    expect(editable, isNotNull);
    expect(editable!.title, 'Inception');
    expect(editable.locked, isTrue);
    expect(editable.sampleFilePath, '/movies/Inception.mkv');

    await admin.updateItemMetadata('101', {'title': 'Inception (Edited)', 'year': 2010});
    expect(server.requests.last.path, '/api/v1/items/101/metadata');

    await admin.refreshItemMetadata('101');
    expect(server.requests.last.path, '/api/v1/items/101/refresh');

    await admin.unmatchItem('101');
    expect(server.requests.last.path, '/api/v1/items/101/unmatch');

    final exts = await admin.listExternalServers();
    expect(exts.single.id, 'ext1');

    final extTest = await admin.testExternalServer({'kind': 'emby', 'base_url': 'http://192.168.1.9:8096'});
    expect(extTest.serverName, 'Emby Box');
    expect(extTest.detectedKind, 'emby');

    final createdExt = await admin.createExternalServer({
      'name': 'New JF',
      'kind': 'jellyfin',
      'base_url': 'http://127.0.0.1:8096',
    });
    expect(createdExt.id, 'ext2');

    final toggledExt = await admin.updateExternalServer('ext1', {'enabled': false});
    expect(toggledExt.enabled, isFalse);

    await admin.deleteExternalServer('ext1');
    expect(server.requests.last.method, 'DELETE');
    expect(server.requests.last.path, '/api/v1/ext-servers/ext1');
  });
}
