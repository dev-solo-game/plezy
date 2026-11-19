import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart' hide LibraryPage, LibraryQuery;
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/library/local_workspace_archive.dart';
import 'package:plezy/media/library_change_event.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_filter.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/session/app_session_store.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/ttplay/ttplay_api_client.dart';
import 'package:plezy/ttplay/ttplay_external_server_client.dart';
import 'package:plezy/ttplay/ttplay_server_client.dart';
import 'package:plezy/ttplay/ttplay_session_binder.dart';

import '../test_helpers/prefs.dart';

class _TestPlexHomeService extends PlexHomeService {
  _TestPlexHomeService({required super.connections, required super.profileConnections, required super.storage})
    : super(plexHomeUserFetcher: (_) async => const []);

  @override
  Future<void> start() async {}

  @override
  Future<void> reloadFromStorage() async {}

  @override
  Future<void> dispose() async {}
}

class _RecordedRequest {
  _RecordedRequest({required this.method, required this.path, required this.query, required this.body});

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic> body;
}

class _FakeTtplayServer {
  _FakeTtplayServer._(this._server);

  final HttpServer _server;
  String validToken = 'tok-secret-123';
  final List<_RecordedRequest> requests = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeTtplayServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeTtplayServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final bodyText = await utf8.decoder.bind(req).join();
    Map<String, dynamic> reqBody = const {};
    if (bodyText.trim().isNotEmpty) {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) {
        reqBody = Map<String, dynamic>.from(decoded);
      }
    }
    requests.add(_RecordedRequest(method: req.method, path: path, query: req.uri.queryParameters, body: reqBody));

    if (path == '/api/v1/public/bootstrap') {
      await _writeJson(req, 200, const {
        'code': 0,
        'initialized': true,
        'server_name': 'NAS Media',
        'accent_theme': 'amber',
      });
      return;
    }
    if (path == '/api/v1/auth/login') {
      await _writeJson(req, 200, {
        'code': 0,
        'access_token': validToken,
        'token_id': 'tok-1',
        'username': 'alice',
      });
      return;
    }
    if (path == '/api/v1/auth/logout') {
      await _writeJson(req, 200, const {'code': 0});
      return;
    }

    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (auth != 'Bearer $validToken') {
      await _writeJson(req, HttpStatus.unauthorized, const {'error': 'unauthorized'});
      return;
    }

    if (path == '/api/v1/auth/me') {
      await _writeJson(req, 200, const {'code': 0, 'username': 'alice'});
      return;
    }

    if (path == '/api/v1/events') {
      req.response.statusCode = 200;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
      req.response.bufferOutput = false;
      req.response.write('event: library_changed\ndata: {"reason":"scan"}\n\n');
      await req.response.flush();
      // Keep the stream open briefly so the client processes the event cleanly before disconnect.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await req.response.close();
      return;
    }

    if (path == '/api/v1/home') {
      await _writeJson(req, 200, {
        'code': 0,
        'home': {
          'counts': {'movie': 1, 'show': 1},
          'unmatched_count': 2,
          'continue_watching': [
            {
              'id': 101,
              'kind': 'movie',
              'library_type': 'movie',
              'title': 'Inception',
              'year': 2010,
              'poster_source': '/posters/inception.jpg',
              'watch_state': {'watched': false, 'position_ms': 42000, 'duration_ms': 120000},
            },
          ],
          'recent_all': [
            {
              'id': 101,
              'kind': 'movie',
              'library_type': 'movie',
              'title': 'Inception',
              'year': 2010,
            },
          ],
          'shelves': [
            {
              'key': 'movie',
              'title': 'Movies',
              'items': [
                {'id': 101, 'kind': 'movie', 'library_type': 'movie', 'title': 'Inception', 'year': 2010},
              ],
            },
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/library/items') {
      await _writeJson(req, 200, {
        'code': 0,
        'total': 1,
        'items': [
          {
            'id': 101,
            'kind': 'movie',
            'library_type': 'movie',
            'title': 'Inception',
            'year': 2010,
            'rating': 8.8,
            'poster_source': 'mount:m1:/Inception/poster.jpg',
          },
        ],
      });
      return;
    }

    if (path == '/api/v1/library/facets') {
      await _writeJson(req, 200, {
        'code': 0,
        'facets': {
          'genres': [
            {'id': 12, 'name': 'Sci-Fi'},
          ],
          'years': [2010, 2014],
        },
      });
      return;
    }

    if (path == '/api/v1/items/101') {
      await _writeJson(req, 200, {
        'code': 0,
        'detail': {
          'item': {
            'id': 101,
            'kind': 'movie',
            'library_type': 'movie',
            'title': 'Inception',
            'original_title': 'Inception',
            'year': 2010,
            'summary': 'Dream heist.',
            'tmdb_id': 27205,
            'poster_source': '/abc123.jpg',
            'watch_state': {'watched': false, 'position_ms': 1000},
          },
          'genres': [
            {'id': 12, 'name': 'Sci-Fi'},
          ],
          'credits': [
            {
              'job': 'actor',
              'character': 'Cobb',
              'person': {'id': 77, 'name': 'Leonardo DiCaprio', 'photo_source': '/leo.jpg'},
            },
          ],
          'files': [
            {
              'id': 501,
              'role': 'video',
              'path': '/movies/Inception.mkv',
              'container': 'mkv',
              'width': 1920,
              'height': 1080,
              'duration_ms': 8880000,
              'size': 4000000000,
            },
          ],
          'similar': [
            {'id': 102, 'kind': 'movie', 'library_type': 'movie', 'title': 'Interstellar', 'year': 2014},
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/search') {
      await _writeJson(req, 200, {
        'code': 0,
        'results': {
          'movies': [
            {'id': 101, 'kind': 'movie', 'library_type': 'movie', 'title': 'Inception', 'year': 2010},
          ],
          'people': [
            {'id': 77, 'name': 'Leonardo DiCaprio', 'photo_source': '/leo.jpg'},
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/people/77') {
      await _writeJson(req, 200, {
        'code': 0,
        'detail': {
          'person': {'id': 77, 'name': 'Leonardo DiCaprio', 'biography': 'Actor'},
          'items': [
            {'id': 101, 'kind': 'movie', 'library_type': 'movie', 'title': 'Inception', 'year': 2010},
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/items/101/watched' || path == '/api/v1/playback/progress') {
      await _writeJson(req, 200, const {'code': 0});
      return;
    }

    if (path == '/api/v1/lists') {
      await _writeJson(req, 200, {
        'code': 0,
        'lists': [
          {'id': 9, 'title': 'Mind Benders', 'summary': 'Fav sci-fi', 'item_count': 2},
        ],
      });
      return;
    }

    if (path == '/api/v1/playback/info/101') {
      await _writeJson(req, 200, {
        'code': 0,
        'selected_file_id': 501,
        'versions': [
          {
            'stream_url': '/api/v1/stream/501?token=$validToken',
            'file': {
              'id': 501,
              'path': '/movies/Inception.mkv',
              'container': 'mkv',
              'width': 1920,
              'height': 1080,
              'duration_ms': 8880000,
              'bitrate_kbps': 8000,
            },
            'variants': [
              {'id': '1080p', 'width': 1920, 'height': 1080, 'stream_url': '/api/v1/hls/501/index.m3u8', 'is_hls': true},
            ],
          },
        ],
        'subtitles': [
          {'id': 88, 'raw_url': '/api/v1/subtitles/88?token=$validToken', 'language': 'eng', 'ext': 'srt'},
        ],
      });
      return;
    }

    if (path == '/api/v1/ext-servers') {
      await _writeJson(req, 200, {
        'code': 0,
        'servers': [
          {
            'id': 'ext-emby',
            'name': 'Living Room Emby',
            'kind': 'emby',
            'base_url': 'http://192.168.1.50:8096',
            'auth_mode': 'password',
            'username': 'alice',
            'user_id': 'u1',
            'server_id': 'emby-srv-1',
            'server_version': '4.8.0',
            'allow_insecure_tls': false,
            'has_token': true,
            'enabled': true,
          },
          {
            'id': 'ext-jf',
            'name': 'Studio Jellyfin',
            'kind': 'jellyfin',
            'base_url': 'http://192.168.1.51:8096',
            'auth_mode': 'password',
            'username': 'alice',
            'user_id': 'u2',
            'server_id': 'jf-srv-2',
            'server_version': '10.9.0',
            'allow_insecure_tls': false,
            'has_token': true,
            'enabled': true,
          },
          {
            'id': 'ext-off',
            'name': 'Disabled Server',
            'kind': 'jellyfin',
            'base_url': 'http://192.168.1.52:8096',
            'auth_mode': 'apikey',
            'username': '',
            'user_id': 'u3',
            'server_id': 'jf-off-3',
            'server_version': '10.9.0',
            'allow_insecure_tls': false,
            'has_token': true,
            'enabled': false,
          },
        ],
      });
      return;
    }

    if (path == '/api/v1/ext/ext-emby/home' || path == '/api/v1/ext/ext-jf/home') {
      final isEmby = path.contains('ext-emby');
      await _writeJson(req, 200, {
        'code': 0,
        'home': {
          'views': [
            {
              'id': isEmby ? 'v-movies' : 'v-shows',
              'name': isEmby ? 'Emby Movies' : 'Jellyfin Shows',
              'collection_type': isEmby ? 'movies' : 'tvshows',
            },
          ],
          'resume': [
            {
              'id': isEmby ? 'emby-m-1' : 'jf-s-1',
              'kind': isEmby ? 'movie' : 'show',
              'title': isEmby ? 'Dune' : 'Severance',
              'year': 2021,
              'watched': false,
              'position_ms': 15000,
              'poster_url': isEmby
                  ? '/api/v1/ext/ext-emby/image/emby-m-1/Primary'
                  : '/api/v1/ext/ext-jf/image/jf-s-1/Primary',
            },
          ],
          'latest_by_view': [
            {
              'view': {
                'id': isEmby ? 'v-movies' : 'v-shows',
                'name': isEmby ? 'Emby Movies' : 'Jellyfin Shows',
                'collection_type': isEmby ? 'movies' : 'tvshows',
              },
              'items': [
                {
                  'id': isEmby ? 'emby-m-1' : 'jf-s-1',
                  'kind': isEmby ? 'movie' : 'show',
                  'title': isEmby ? 'Dune' : 'Severance',
                  'year': 2021,
                },
              ],
            },
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/ext/ext-emby/items') {
      await _writeJson(req, 200, {
        'code': 0,
        'total': 1,
        'items': [
          {
            'id': 'emby-m-1',
            'kind': 'movie',
            'title': 'Dune',
            'year': 2021,
            'poster_url': '/api/v1/ext/ext-emby/image/emby-m-1/Primary',
          },
        ],
      });
      return;
    }

    if (path == '/api/v1/ext/ext-emby/items/emby-m-1') {
      await _writeJson(req, 200, {
        'code': 0,
        'detail': {
          'item': {
            'id': 'emby-m-1',
            'kind': 'movie',
            'title': 'Dune',
            'overview': 'Arrakis.',
            'year': 2021,
            'poster_url': '/api/v1/ext/ext-emby/image/emby-m-1/Primary',
          },
          'people': [
            {'id': 'p1', 'name': 'Timothee Chalamet', 'type': 'actor', 'role': 'Paul'},
          ],
          'media_sources': [
            {'id': 'ms-1', 'name': 'Dune 4K', 'container': 'mkv', 'bitrate': 12000000, 'runtime_ms': 9300000},
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/ext/ext-emby/search') {
      await _writeJson(req, 200, {
        'code': 0,
        'results': {
          'movies': [
            {'id': 'emby-m-1', 'kind': 'movie', 'title': 'Dune', 'year': 2021},
          ],
        },
      });
      return;
    }

    if (path == '/api/v1/ext/ext-emby/items/emby-m-1/watched') {
      await _writeJson(req, 200, const {'code': 0});
      return;
    }

    if (path == '/api/v1/ext/ext-emby/playback/emby-m-1') {
      await _writeJson(req, 200, {
        'code': 0,
        'selected_source_id': 'ms-1',
        'play_session_id': 'ps-ext-1',
        'versions': [
          {
            'source_id': 'ms-1',
            'label': 'Dune 4K',
            'container': 'mkv',
            'width': 3840,
            'height': 2160,
            'bitrate': 12000000,
            'stream_url': '/api/v1/ext/ext-emby/stream/emby-m-1?source_id=ms-1',
          },
        ],
        'subtitles': [
          {'index': 2, 'language': 'eng', 'ext': 'vtt', 'vtt_url': '/api/v1/ext/ext-emby/subtitles/emby-m-1/2.vtt'},
        ],
      });
      return;
    }

    await _writeJson(req, 404, const {'error': 'not found'});
  }

  Future<void> _writeJson(HttpRequest req, int status, Map<String, dynamic> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _FakeTtplayServer server;
  HttpOverrides? previousHttpOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    CredentialVault.resetKeyForTesting();
    server = await _FakeTtplayServer.start();
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = previousHttpOverrides;
  });

  test('TtplayServerClient handles health, browse, filters, metadata, search, watch state, playback & SSE', () async {
    final session = SelfHostedSession(
      serverUrl: server.baseUrl,
      username: 'alice',
      accessToken: server.validToken,
      serverName: 'NAS Media',
    );
    final api = TtplayApiClient(baseUrl: server.baseUrl, accessToken: server.validToken);
    final withPending = TtplayServerClient(api: api, session: session, includePendingShelf: true);
    final withoutPending = TtplayServerClient(api: api, session: session, includePendingShelf: false);
    addTearDown(withPending.close);

    expect(await withPending.checkHealth(), HealthStatus.online);

    final badApi = TtplayApiClient(baseUrl: server.baseUrl, accessToken: 'wrong-token');
    final badClient = TtplayServerClient(api: badApi, session: session);
    addTearDown(badClient.close);
    expect(await badClient.checkHealth(), HealthStatus.authError);

    final libsWithPending = await withPending.fetchLibraries();
    expect(libsWithPending.map((l) => l.id), containsAll(['movie', 'show', 'pending']));

    final libsNoPending = await withoutPending.fetchLibraries();
    expect(libsNoPending.map((l) => l.id), isNot(contains('pending')));
    expect(libsNoPending.map((l) => l.id), containsAll(['movie', 'show']));

    final hubs = await withPending.fetchGlobalHubs();
    expect(hubs, isNotEmpty);
    expect(hubs.first.items.first.title, 'Inception');

    final page = await withPending.fetchLibraryPagedContent('movie', query: const LibraryQuery());
    expect(page.totalCount, 1);
    expect(page.items.single.id, '101');
    expect(page.items.single.rating, closeTo(8.8, 0.01));

    final filterResult = await withPending.fetchLibraryFiltersWithValues('movie', libraryKind: MediaKind.movie);
    expect(filterResult.filters.map((f) => f.filter), containsAll([MediaFilterField.genre, MediaFilterField.year]));
    expect(filterResult.cachedValues[MediaFilterField.genre]?.single.title, 'Sci-Fi');

    final item = await withPending.fetchItem('101');
    expect(item, isNotNull);
    expect(item!.title, 'Inception');
    expect(item.genres, ['Sci-Fi']);
    expect(item.roles?.single.tag, 'Leonardo DiCaprio');

    final searchHits = await withPending.searchItems('Inception');
    expect(searchHits.single.id, '101');

    final personMedia = await withPending.fetchPersonMediaPage('77');
    expect(personMedia.items.single.title, 'Inception');

    final collections = await withPending.fetchCollectionsPage('movie');
    expect(collections.items.single.title, 'Mind Benders');

    await withPending.markWatched(item);
    await withPending.reportPlaybackProgress(
      itemId: '101',
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 2),
    );
    expect(server.requests.any((r) => r.path == '/api/v1/items/101/watched' && r.body['watched'] == true), isTrue);
    expect(
      server.requests.any((r) => r.path == '/api/v1/playback/progress' && r.body['position_ms'] == 30000),
      isTrue,
    );

    final playback = await withPending.getPlaybackInitialization(
      PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0),
    );
    expect(playback.videoUrl, contains('/api/v1/stream/501?token=${server.validToken}'));
    expect(playback.subtitleSidecars.single.track.uri, contains('/api/v1/subtitles/88?token=${server.validToken}'));

    final localThumb = withPending.thumbnailUrl('mount:m1:/Inception/poster.jpg');
    expect(localThumb, contains('/api/v1/artwork/local/m1'));
    expect(localThumb, contains('token=${server.validToken}'));

    final remoteThumb = withPending.thumbnailUrl('/abc123.jpg', width: 500);
    expect(remoteThumb, contains('/api/v1/artwork/remote'));
    expect(remoteThumb, contains('token=${server.validToken}'));

    final channel = withPending.createLibraryEventChannel()!;
    final received = <LibraryChangeEvent>[];
    final sub = channel.events.listen(received.add);
    addTearDown(() async {
      await sub.cancel();
      channel.dispose();
    });
    channel.start();
    // Wait past the 500ms coalesce window for the SSE library_changed event to emit.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (received.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(received, isNotEmpty);
  });

  test('TtplayServerClient shares one /home request across libraries, hubs and continue watching', () async {
    final session = SelfHostedSession(
      serverUrl: server.baseUrl,
      username: 'alice',
      accessToken: server.validToken,
      serverName: 'NAS Media',
    );
    final api = TtplayApiClient(baseUrl: server.baseUrl, accessToken: server.validToken);
    final client = TtplayServerClient(api: api, session: session);
    addTearDown(client.close);
    int homeRequests() => server.requests.where((r) => r.path == '/api/v1/home').length;
    final before = homeRequests();

    final results = await Future.wait<Object>([
      client.fetchLibraries(),
      client.fetchGlobalHubs(),
      client.fetchContinueWatching(),
    ]);
    expect((results[0] as List).isNotEmpty, isTrue);
    expect((results[1] as List).isNotEmpty, isTrue);
    expect((results[2] as List).isNotEmpty, isTrue);
    expect(homeRequests() - before, 1);

    // Served from the short-lived cache.
    await client.fetchLibraries();
    expect(homeRequests() - before, 1);

    // Watch-state mutations drop the cache.
    final item = (await client.fetchContinueWatching()).first;
    expect(homeRequests() - before, 1);
    await client.markWatched(item);
    await client.fetchContinueWatching();
    expect(homeRequests() - before, 2);

    client.invalidateHomeCache();
    await client.fetchGlobalHubs();
    expect(homeRequests() - before, 3);
  });

  test('TtplayExternalServerClient maps Emby and Jellyfin dialects, browse, search, watch & playback', () async {
    final api = TtplayApiClient(baseUrl: server.baseUrl, accessToken: server.validToken);
    addTearDown(api.close);

    final summaries = await api.fetchExternalServers();
    expect(summaries, hasLength(3));

    final embyClient = TtplayExternalServerClient(api: api, server: summaries[0]);
    final jfClient = TtplayExternalServerClient(api: api, server: summaries[1]);

    expect(embyClient.serverId.toString(), 'ttplay-ext:ext-emby');
    expect(embyClient.backend, MediaBackend.emby);
    expect(jfClient.serverId.toString(), 'ttplay-ext:ext-jf');
    expect(jfClient.backend, MediaBackend.jellyfin);

    final embyLibs = await embyClient.fetchLibraries();
    expect(embyLibs.single.title, 'Emby Movies');
    expect(embyLibs.single.backend, MediaBackend.emby);

    final jfLibs = await jfClient.fetchLibraries();
    expect(jfLibs.single.title, 'Jellyfin Shows');
    expect(jfLibs.single.backend, MediaBackend.jellyfin);

    final hubs = await embyClient.fetchGlobalHubs();
    expect(hubs.length, 2);

    final page = await embyClient.fetchLibraryPagedContent('v-movies', query: const LibraryQuery());
    expect(page.items.single.id, 'emby-m-1');
    expect(page.items.single.serverId, 'ttplay-ext:ext-emby');

    final item = await embyClient.fetchItem('emby-m-1');
    expect(item, isNotNull);
    expect(item!.title, 'Dune');
    expect(item.roles?.single.tag, 'Timothee Chalamet');

    final hits = await embyClient.searchItems('Dune');
    expect(hits.single.id, 'emby-m-1');

    await embyClient.markWatched(item);
    expect(server.requests.any((r) => r.path == '/api/v1/ext/ext-emby/items/emby-m-1/watched'), isTrue);

    final playback = await embyClient.getPlaybackInitialization(
      PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0),
    );
    expect(playback.videoUrl, '${server.baseUrl}/api/v1/ext/ext-emby/stream/emby-m-1?source_id=ms-1');
    expect(
      playback.subtitleSidecars.single.track.uri,
      '${server.baseUrl}/api/v1/ext/ext-emby/subtitles/emby-m-1/2.vtt',
    );
    expect(playback.playSessionId, 'ps-ext-1');

    final thumb = embyClient.thumbnailUrl('/api/v1/ext/ext-emby/image/emby-m-1/Primary', width: 320);
    expect(thumb, contains('token=${server.validToken}'));
    expect(thumb, contains('maxWidth=320'));
  });

  test(
    'TtplaySessionBinder coordinates Offline <-> Self-Hosted, ActiveProfileBinder preservation, and logout',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final storage = await StorageService.getInstance();
      final repo = LibraryRepository(db);
      final mounts = MountManager(MountRegistry(db));
      final connections = ConnectionRegistry(db);
      final profileConnections = ProfileConnectionRegistry(db);
      final profileRegistry = ProfileRegistry(db);
      final plexHome = _TestPlexHomeService(
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
      );
      final activeProfile = ActiveProfileProvider(
        registry: profileRegistry,
        plexHome: plexHome,
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
      );
      final localProfile = Profile.local(id: 'local-owner', displayName: 'Owner', createdAt: DateTime(2026));
      await profileRegistry.upsert(localProfile);
      await activeProfile.initialize();
      await activeProfile.activate(localProfile);

      final serverManager = MultiServerManager();
      final multiServer = MultiServerProvider(serverManager, DataAggregationService(serverManager));
      final binder = ActiveProfileBinder(
        activeProfile: activeProfile,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: serverManager,
        multiServerProvider: multiServer,
      );
      final sessionController = AppSessionController(
        db: db,
        store: AppSessionStore(db),
        archive: LocalWorkspaceArchive(db),
        mountManager: mounts,
      );
      final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
      final ttplayBinder = TtplaySessionBinder(
        sessionController: sessionController,
        serverManager: serverManager,
        localLibraryClient: localClient,
        isTv: () => false,
      )..attachMultiServerProvider(multiServer);

      addTearDown(() async {
        ttplayBinder.dispose();
        binder.dispose();
        multiServer.dispose();
        serverManager.dispose();
        sessionController.dispose();
        activeProfile.dispose();
        await plexHome.dispose();
        await mounts.dispose();
        await db.close();
      });

      final now = DateTime(2026).millisecondsSinceEpoch;
      final localItemId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: 'movie',
          libraryType: 'movie',
          title: 'Local Movie',
          sortTitle: 'local movie',
          year: const Value(2024),
          tmdbId: const Value('999001'),
          scrapedAt: Value(now),
          addedAt: now,
          updatedAt: now,
        ),
      );

      // 1. Offline mode registers local-library and binds visibility.
      await sessionController.initialize();
      await sessionController.selectOfflineMode();
      await ttplayBinder.syncFromSession();
      binder.primeLocalOnlyStartup();

      expect(serverManager.onlineServerIds, contains(LocalLibraryClient.localServerId));
      expect(multiServer.onlineServerIds, equals([LocalLibraryClient.localServerId]));
      expect((await localClient.fetchLibraries()).map((l) => l.id), contains('movie'));

      // 2. Offline -> Self-Hosted unregisters local without closing it, and registers
      // primary + ONLY enabled external servers (`ext-emby`, `ext-jf`, not `ext-off`).
      await sessionController.loginSelfHosted(serverUrl: server.baseUrl, username: 'alice', password: 'pw');
      await ttplayBinder.syncFromSession(refreshExternalServers: true);

      expect(serverManager.onlineServerIds, isNot(contains(LocalLibraryClient.localServerId)));
      expect(
        serverManager.onlineServerIds,
        containsAll([TtplayServerClient.primaryServerId, 'ttplay-ext:ext-emby', 'ttplay-ext:ext-jf']),
      );
      expect(serverManager.onlineServerIds, isNot(contains('ttplay-ext:ext-off')));
      expect(
        multiServer.onlineServerIds,
        containsAll([TtplayServerClient.primaryServerId, 'ttplay-ext:ext-emby', 'ttplay-ext:ext-jf']),
      );

      // 3. ActiveProfileBinder.rebindActive preserves self-hosted + enabled externals.
      await binder.rebindActive();
      expect(
        serverManager.onlineServerIds,
        containsAll([TtplayServerClient.primaryServerId, 'ttplay-ext:ext-emby', 'ttplay-ext:ext-jf']),
      );
      expect(
        multiServer.onlineServerIds,
        containsAll([TtplayServerClient.primaryServerId, 'ttplay-ext:ext-emby', 'ttplay-ext:ext-jf']),
      );

      // 4. Self-Hosted -> Offline clears self-hosted servers and restores working LocalLibraryClient.
      await sessionController.selectOfflineMode();
      await ttplayBinder.syncFromSession();

      expect(serverManager.selfHostedServerIds, isEmpty);
      expect(serverManager.onlineServerIds, contains(LocalLibraryClient.localServerId));
      expect(multiServer.onlineServerIds, contains(LocalLibraryClient.localServerId));
      expect((await localClient.fetchLibraries()).map((l) => l.id), contains('movie'));
      // Verify LocalLibraryClient was NOT closed (`_closed` remains false so progress persists).
      await localClient.reportPlaybackStopped(
        itemId: '$localItemId',
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 2),
      );
      final restoredItem = await localClient.fetchItem('$localItemId');
      expect(restoredItem?.viewOffsetMs, 12000);

      // 5. Logout preserves LocalLibraryClient when previously Offline.
      await sessionController.logoutToModeSelection();
      await ttplayBinder.syncFromSession();
      expect(serverManager.onlineServerIds, contains(LocalLibraryClient.localServerId));
      expect(serverManager.selfHostedServerIds, isEmpty);

      // 6. Logout after Self-Hosted clears all self-hosted servers without re-adding local.
      await sessionController.loginSelfHosted(serverUrl: server.baseUrl, username: 'alice', password: 'pw');
      await ttplayBinder.syncFromSession(refreshExternalServers: true);
      expect(serverManager.isSelfHostedServer(TtplayServerClient.primaryServerId), isTrue);

      await sessionController.logoutToModeSelection();
      await ttplayBinder.syncFromSession();
      expect(serverManager.selfHostedServerIds, isEmpty);
      expect(serverManager.onlineServerIds, isEmpty);
      expect(multiServer.onlineServerIds, isEmpty);
    },
  );
}
