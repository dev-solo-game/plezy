import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/scrapers/server_metadata_provider.dart';
import 'package:plezy/library/scrapers/tmdb_provider.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';

import '../test_helpers/prefs.dart';

/// Stand-in for `ttplay-server`'s `/api/v1/public/metadata/*` endpoints that knows one film.
Future<HttpServer> _fakePublicMetadataServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    final bodyText = await utf8.decoder.bind(request).join();
    Map<String, dynamic> reqBody = const {};
    if (bodyText.trim().isNotEmpty) {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) reqBody = Map<String, dynamic>.from(decoded);
    }

    const duneWork = <String, dynamic>{
      'source': 'tmdb',
      'external_id': '438631',
      'tmdb_id': '438631',
      'title': '沙丘',
      'original_title': 'Dune',
      'year': 2021,
      'release_date': '2021-09-15',
      'summary': 'A mythic and emotionally charged hero journey.',
      'genres': ['科幻'],
    };

    Object? body;
    switch (path) {
      case '/api/v1/public/metadata/config':
        body = const {
          'tmdb_image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': false,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'providers': ['tmdb'],
          'tmdb_configured': true,
        };
      case '/api/v1/public/metadata/identify':
        final title = '${reqBody['title'] ?? ''}'.toLowerCase();
        body = title.contains('dune')
            ? const {
                'matched': true,
                'kind': 'movie',
                'source': 'tmdb',
                'work': duneWork,
              }
            : const {'matched': false, 'kind': 'movie', 'source': ''};
      case '/api/v1/public/metadata/search':
        final title = '${reqBody['title'] ?? ''}'.toLowerCase();
        body = {
          'image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': false,
          'results': title.contains('dune')
              ? const [
                  {
                    'source': 'tmdb',
                    'id': '438631',
                    'title': '沙丘',
                    'original_title': 'Dune',
                    'year': 2021,
                  },
                ]
              : const <Object>[],
        };
      case '/api/v1/public/metadata/work':
        if (reqBody['id'] == '438631') {
          body = const {
            'image_base': 'https://image.tmdb.org/t/p',
            'proxy_images': false,
            'work': duneWork,
          };
        }
      default:
        body = null;
    }

    request.response
      ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body == null ? '{}' : jsonEncode(body));
    await request.response.close();
  });
  return server;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late LibraryRepository repo;
  late LibrarySettingsStore store;
  late MountManager mounts;
  late LibraryScanService service;
  late HttpServer metadataServer;
  late String endpointUrl;
  HttpOverrides? previousHttpOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    previousHttpOverrides = HttpOverrides.current;
    // flutter_test answers every request with 400; these talk to a real local server.
    HttpOverrides.global = null;
    CredentialVault.resetKeyForTesting();

    metadataServer = await _fakePublicMetadataServer();
    endpointUrl = 'http://127.0.0.1:${metadataServer.port}';

    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    store = LibrarySettingsStore(db);
    mounts = MountManager(MountRegistry(db));
    final runner = LibraryScrapeRunner(
      database: db,
      repository: repo,
      settings: store,
      mounts: mounts,
      resolveMetadataEndpoint: () async => (serverUrl: endpointUrl, accessToken: null, isOfficial: true),
    );
    service = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: mounts,
      scrape: runner.scrapePending,
    );

    final now = DateTime(2026).millisecondsSinceEpoch;
    await repo.insertItem(
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
  });

  tearDown(() async {
    service.dispose();
    await mounts.dispose();
    await metadataServer.close(force: true);
    await db.close();
    HttpOverrides.global = previousHttpOverrides;
  });

  Future<LibraryItemRow> dune() => db.select(db.libraryItems).getSingle();

  test('fixing an unreachable metadata server takes effect without a restart', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = closed.port;
    await closed.close();
    endpointUrl = 'http://127.0.0.1:$deadPort';

    await service.scrapeLibrary();
    expect(service.scrapeStatus.note, contains('Cannot reach'));
    expect((await dune()).libraryType, LibraryTypes.pending);

    endpointUrl = 'http://127.0.0.1:${metadataServer.port}';
    await service.scrapeLibrary(retryUnmatched: true, restart: true);

    expect(service.scrapeStatus.note, isNull);
    final movie = await dune();
    expect((movie.title, movie.libraryType, movie.tmdbId), ('沙丘', LibraryTypes.movie, '438631'));
  });

  test('restarting during a run switches to the updated metadata server', () async {
    endpointUrl = 'http://127.0.0.1:1';
    final first = service.scrapeLibrary();
    endpointUrl = 'http://127.0.0.1:${metadataServer.port}';
    final second = service.scrapeLibrary(retryUnmatched: true, restart: true);
    expect(identical(first, second), isTrue, reason: 'one run, started over');
    await second;

    expect(service.scrapeStatus.note, isNull);
    expect((await dune()).libraryType, LibraryTypes.movie);
  });

  test('restarting does not wait for a request stuck on a host that never answers', () async {
    final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen((_) {});
    endpointUrl = 'http://127.0.0.1:${silent.port}';

    final run = service.scrapeLibrary();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(service.scrapeStatus.running, isTrue);

    final watch = Stopwatch()..start();
    endpointUrl = 'http://127.0.0.1:${metadataServer.port}';
    await service.scrapeLibrary(retryUnmatched: true, restart: true);
    await run;
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'the stuck request is abandoned');
    expect(service.scrapeStatus.note, isNull);
    expect((await dune()).libraryType, LibraryTypes.movie);
    await silent.close(force: true);
  });

  test('a cancelled run is not restarted', () async {
    final run = service.scrapeLibrary();
    unawaited(service.scrapeLibrary());
    service.cancelScrape();
    await run;
    expect(service.scrapeStatus.running, isFalse);
  });

  test('a wrong API address stops the run instead of filing everything as unmatched', () async {
    endpointUrl = 'http://127.0.0.1:${metadataServer.port}/wrong';
    await service.scrapeLibrary();
    expect(service.scrapeStatus.note, contains('not found'));
    final movie = await dune();
    expect(movie.libraryType, LibraryTypes.pending);
    expect(movie.scrapedAt, isNull, reason: 'still queued');
  });

  test('ServerMetadataProvider.fetchConfig tells a good address from a wrong one', () async {
    await expectLater(
      ServerMetadataProvider.fetchConfig(serverUrl: 'http://127.0.0.1:${metadataServer.port}'),
      completes,
    );
    await expectLater(
      ServerMetadataProvider.fetchConfig(serverUrl: 'http://127.0.0.1:${metadataServer.port}/wrong'),
      throwsA(isA<ServerMetadataException>()),
    );
  });

  test('base addresses are completed the way people type them', () {
    String api(String value) => TmdbProvider.normalizeBase(value, TmdbProvider.defaultApiBase, defaultPath: '/3');
    String images(String value) =>
        TmdbProvider.normalizeBase(value, TmdbProvider.defaultImageBase, defaultPath: '/t/p');

    expect(api(''), TmdbProvider.defaultApiBase);
    expect(api('api.tmdb.org'), 'https://api.tmdb.org/3');
    expect(api('https://api.tmdb.org/'), 'https://api.tmdb.org/3');
    expect(api('http://192.168.1.2:8080/tmdb/3/'), 'http://192.168.1.2:8080/tmdb/3');
    expect(images('image.tmdb.org'), 'https://image.tmdb.org/t/p');
    expect(images('https://image.tmdb.org/t/p'), 'https://image.tmdb.org/t/p');
  });

  test('scrapeLibrary notifies catalog/library listeners only when items change state', () async {
    var libraryChanges = 0;
    var catalogChanges = 0;
    service.onLibraryChanged = () => libraryChanges++;
    service.onCatalogChanged = (_) => catalogChanges++;

    // Unreachable metadata endpoint leaves the queued movie pending without firing state changes.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = closed.port;
    await closed.close();
    endpointUrl = 'http://127.0.0.1:$deadPort';
    await service.scrapeLibrary();
    expect(libraryChanges, 0);
    expect(catalogChanges, 0);

    // Restoring a healthy endpoint matches Dune and fires both once.
    endpointUrl = 'http://127.0.0.1:${metadataServer.port}';
    await service.scrapeLibrary();
    expect(libraryChanges, 1);
    expect(catalogChanges, 1);

    // Running again with nothing left in the queue must not trigger notifications.
    await service.scrapeLibrary();
    expect(libraryChanges, 1);
    expect(catalogChanges, 1);
  });
}
