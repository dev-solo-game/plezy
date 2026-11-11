import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/scrapers/scraped_metadata.dart';
import 'package:plezy/library/scrapers/tmdb_provider.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';

import '../test_helpers/prefs.dart';

/// A stand-in for TMDB that knows one film.
Future<HttpServer> _fakeTmdb() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    final Object? body = switch (path) {
      '/3/search/movie' when request.uri.queryParameters['query'] == 'Dune' => {
        'results': [
          {'id': 438631, 'title': '沙丘', 'original_title': 'Dune', 'release_date': '2021-09-15'},
        ],
      },
      '/3/search/movie' || '/3/search/tv' => {'results': <Object>[]},
      '/3/configuration' => {'images': <String, Object>{}},
      '/3/movie/438631' => {
        'id': 438631,
        'title': '沙丘',
        'original_title': 'Dune',
        'release_date': '2021-09-15',
        'genres': [
          {'id': 878, 'name': '科幻'},
        ],
      },
      _ => null,
    };
    request.response
      ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body == null ? '{}' : jsonEncode(body));
    await request.response.close();
  });
  return server;
}

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late LibrarySettingsStore store;
  late LibraryScanService service;
  late HttpServer tmdb;

  setUp(() async {
    resetSharedPreferencesForTest();
    // flutter_test answers every request with 400; these talk to a real
    // local server.
    HttpOverrides.global = null;
    CredentialVault.resetKeyForTesting();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    store = LibrarySettingsStore(db);
    final runner = LibraryScrapeRunner(database: db, repository: repo, settings: store);
    service = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: MountManager(MountRegistry(db)),
      scrape: runner.scrapePending,
    );
    tmdb = await _fakeTmdb();
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
    await tmdb.close(force: true);
    await db.close();
  });

  Future<LibraryItemRow> dune() => db.select(db.libraryItems).getSingle();

  test('saving settings that fix an unreachable host takes effect without a restart', () async {
    // A port nobody listens on: the lookup cannot reach TMDB.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = closed.port;
    await closed.close();
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:$deadPort', bangumiEnabled: false),
    );
    await service.scrapeLibrary();
    expect(service.scrapeStatus.note, contains('Cannot reach'));
    expect((await dune()).libraryType, LibraryTypes.pending);

    // What the settings screen does on save.
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${tmdb.port}', bangumiEnabled: false),
    );
    await service.scrapeLibrary(retryUnmatched: true, restart: true);

    expect(service.scrapeStatus.note, isNull);
    final movie = await dune();
    expect((movie.title, movie.libraryType, movie.tmdbId), ('沙丘', LibraryTypes.movie, '438631'));
  });

  test('saving during a run restarts it with the new settings', () async {
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:1', bangumiEnabled: false),
    );
    final first = service.scrapeLibrary();
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${tmdb.port}', bangumiEnabled: false),
    );
    final second = service.scrapeLibrary(retryUnmatched: true, restart: true);
    expect(identical(first, second), isTrue, reason: 'one run, started over');
    await second;

    expect(service.scrapeStatus.note, isNull);
    expect((await dune()).libraryType, LibraryTypes.movie);
  });

  test('saving does not wait for a request stuck on a host that never answers', () async {
    // Accepts connections and never replies, like a blackholed address.
    final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen((_) {});
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${silent.port}', bangumiEnabled: false),
    );
    final run = service.scrapeLibrary();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(service.scrapeStatus.running, isTrue);

    final watch = Stopwatch()..start();
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${tmdb.port}', bangumiEnabled: false),
    );
    await service.scrapeLibrary(retryUnmatched: true, restart: true);
    await run;
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'the stuck request is abandoned');
    expect(service.scrapeStatus.note, isNull);
    expect((await dune()).libraryType, LibraryTypes.movie);
    await silent.close(force: true);
  });

  test('a cancelled run is not restarted', () async {
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${tmdb.port}', bangumiEnabled: false),
    );
    final run = service.scrapeLibrary();
    unawaitedScrape(service.scrapeLibrary());
    service.cancelScrape();
    await run;
    expect(service.scrapeStatus.running, isFalse);
  });

  test('a wrong API address stops the run instead of filing everything as unmatched', () async {
    await store.saveScraper(
      ScraperSettings(tmdbApiKey: 'key', tmdbApiBase: 'http://127.0.0.1:${tmdb.port}/wrong', bangumiEnabled: false),
    );
    await service.scrapeLibrary();
    expect(service.scrapeStatus.note, contains('not found'));
    final movie = await dune();
    expect(movie.libraryType, LibraryTypes.pending);
    expect(movie.scrapedAt, isNull, reason: 'still queued');
  });

  test('the connection test tells a good address from a wrong one', () async {
    final good = TmdbProvider(apiKey: 'key', apiBase: 'http://127.0.0.1:${tmdb.port}');
    final wrong = TmdbProvider(apiKey: 'key', apiBase: 'http://127.0.0.1:${tmdb.port}/wrong');
    addTearDown(good.close);
    addTearDown(wrong.close);
    await expectLater(good.checkConnection(), completes);
    await expectLater(wrong.checkConnection(), throwsA(isA<ScrapeException>()));
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
}

void unawaitedScrape(Future<void> future) {}
