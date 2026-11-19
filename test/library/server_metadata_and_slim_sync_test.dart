import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_scraper.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_workspace_archive.dart';
import 'package:plezy/library/scrapers/server_metadata_provider.dart';
import 'package:plezy/services/companion_remote/lan_crypto.dart';
import 'package:plezy/services/companion_remote/lan_identity_store.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

class _MockMetadataAndAuthServer {
  _MockMetadataAndAuthServer._(this._server);

  final HttpServer _server;
  bool proxyImages = true;
  bool identifyReturns502 = false;
  final List<String> requestedPaths = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_MockMetadataAndAuthServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = _MockMetadataAndAuthServer._(server);
    server.listen(mock._handle);
    return mock;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requestedPaths.add(path);
    final bodyText = await utf8.decoder.bind(request).join();
    Map<String, dynamic> reqBody = const {};
    if (bodyText.trim().isNotEmpty) {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) reqBody = Map<String, dynamic>.from(decoded);
    }

    const matrixWork = <String, dynamic>{
      'source': 'tmdb',
      'external_id': '603',
      'tmdb_id': '603',
      'imdb_id': 'tt0133093',
      'title': 'The Matrix',
      'original_title': 'The Matrix',
      'year': 1999,
      'release_date': '1999-03-30',
      'summary': 'Set in the 22nd century, The Matrix tells the story of a computer hacker.',
      'runtime_ms': 8160000,
      'poster_path': '/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg',
      'backdrop_path': '/ncEsesgOJDNrTUED89hYbA117wo.jpg',
      'logo_path': '/logo.png',
      'genres': ['Action', 'Sci-Fi'],
      'credits': [
        {
          'name': 'Keanu Reeves',
          'job': 'actor',
          'character': 'Neo',
          'tmdb_id': '6384',
          'photo_path': '/4D0PpNI0kmP58hgrwGC3wCjxhnm.jpg',
        },
      ],
    };

    if (path == '/api/v1/public/metadata/identify' && identifyReturns502) {
      request.response
        ..statusCode = HttpStatus.badGateway
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(const {'error': 'tmdb upstream unavailable'}));
      await request.response.close();
      return;
    }

    Object? body;
    switch (path) {
      case '/api/v1/public/metadata/config':
        body = {
          'tmdb_image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'providers': const ['tmdb', 'bangumi'],
          'tmdb_configured': true,
        };
      case '/api/v1/public/metadata/identify':
        body = {
          'matched': true,
          'kind': 'movie',
          'source': 'tmdb',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'work': matrixWork,
        };
      case '/api/v1/public/metadata/search':
        body = {
          'image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'results': const [
            {
              'source': 'tmdb',
              'id': '603',
              'title': 'The Matrix',
              'original_title': 'The Matrix',
              'year': 1999,
              'poster_path': '/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg',
            },
          ],
        };
      case '/api/v1/public/metadata/work':
      case '/api/v1/public/metadata/work/tmdb/movie/603':
        body = {
          'image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'work': matrixWork,
        };
      case '/api/v1/public/metadata/season':
        body = {
          'image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'season': const {
            'number': 1,
            'title': 'Season 1',
            'episodes': [
              {'number': 1, 'title': 'Pilot', 'summary': 'Opening episode'},
            ],
          },
        };
      case '/api/v1/public/metadata/batch':
        final requestedWorks = (reqBody['works'] as List?) ?? const [];
        final works = <String, dynamic>{};
        for (final entry in requestedWorks.whereType<Map>()) {
          final key = '${entry['provider']}:${entry['kind']}:${entry['id']}';
          if (key == 'tmdb:movie:603') {
            works[key] = matrixWork;
          }
        }
        body = {
          'image_base': 'https://image.tmdb.org/t/p',
          'proxy_images': proxyImages,
          'artwork_proxy_path': '/api/v1/public/metadata/artwork',
          'works': works,
          'seasons': const <String, dynamic>{},
          'errors': const <String, dynamic>{},
        };
      case '/api/v1/public/bootstrap':
        body = const {
          'code': 0,
          'initialized': true,
          'server_name': 'Home NAS Server',
          'accent_theme': 'mono',
          'version': '2.0.0',
        };
      case '/api/v1/auth/login':
        body = {
          'code': 0,
          'access_token': 'sh-tok-${reqBody['username'] ?? 'user'}',
          'token_id': 'tok-id-1',
          'username': reqBody['username'] ?? 'alice',
        };
      case '/api/v1/auth/logout':
        body = const {'code': 0};
      default:
        body = null;
    }

    request.response
      ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body == null ? '{}' : jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  HttpOverrides? previousHttpOverrides;

  setUp(() {
    resetSharedPreferencesForTest();
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    CredentialVault.resetKeyForTesting();
  });

  tearDown(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  test('artwork proxy URL rewriting rewrites TMDB & external paths cleanly and preserves mount URIs', () async {
    final server = await _MockMetadataAndAuthServer.start();
    addTearDown(server.close);

    const proxyPath = '/api/v1/public/metadata/artwork';
    expect(
      ServerMetadataProvider.resolveArtworkUrl(
        '/abc.jpg',
        serverBaseUrl: server.baseUrl,
        proxyImages: true,
        artworkProxyPath: proxyPath,
        size: 'w500',
      ),
      '${server.baseUrl}$proxyPath?src=%2Fabc.jpg&size=w500',
    );
    expect(
      ServerMetadataProvider.resolveArtworkUrl(
        '$proxyPath?src=%2Fabc.jpg&size=w500',
        serverBaseUrl: server.baseUrl,
        proxyImages: true,
        artworkProxyPath: proxyPath,
        size: 'w500',
      ),
      '${server.baseUrl}$proxyPath?src=%2Fabc.jpg&size=w500',
    );
    expect(
      ServerMetadataProvider.resolveArtworkUrl(
        '${server.baseUrl}$proxyPath?src=%2Fabc.jpg&size=w500',
        serverBaseUrl: server.baseUrl,
        proxyImages: true,
        artworkProxyPath: proxyPath,
        size: 'w500',
      ),
      '${server.baseUrl}$proxyPath?src=%2Fabc.jpg&size=w500',
    );
    expect(
      ServerMetadataProvider.resolveArtworkUrl(
        'mount:m1/poster.jpg',
        serverBaseUrl: server.baseUrl,
        proxyImages: true,
        artworkProxyPath: proxyPath,
        size: 'w500',
      ),
      'mount:m1/poster.jpg',
    );

    final provider = ServerMetadataProvider(serverUrl: server.baseUrl);
    addTearDown(provider.close);

    final candidates = await provider.searchAll(kind: 'movie', title: 'The Matrix');
    expect(candidates.single.posterUrl, contains('${server.baseUrl}$proxyPath?src='));

    final work = await provider.workFor(provider: 'tmdb', kind: 'movie', id: '603');
    expect(work.posterSource, '${server.baseUrl}$proxyPath?src=%2Ff89U3ADr1oiB1s9GkdPOEpXUk5H.jpg&size=w500');
    expect(work.backdropSource, '${server.baseUrl}$proxyPath?src=%2FncEsesgOJDNrTUED89hYbA117wo.jpg&size=w1280');
    expect(work.credits.single.photoUrl, '${server.baseUrl}$proxyPath?src=%2F4D0PpNI0kmP58hgrwGC3wCjxhnm.jpg&size=w185');
  });

  test('502 TMDB upstream outage halts scrapePending without marking pending items unmatched', () async {
    final server = await _MockMetadataAndAuthServer.start();
    addTearDown(server.close);
    server.identifyReturns502 = true;

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final settings = LibrarySettingsStore(db);
    final mounts = MountManager(MountRegistry(db));
    final runner = LibraryScrapeRunner(
      database: db,
      repository: repo,
      settings: settings,
      mounts: mounts,
      resolveMetadataEndpoint: () async => (serverUrl: server.baseUrl, accessToken: null, isOfficial: true),
    );
    final scans = LibraryScanService(
      repository: repo,
      scanner: LibraryScanner(db, repo),
      mounts: mounts,
      scrape: runner.scrapePending,
    );
    addTearDown(() async {
      scans.dispose();
      await mounts.dispose();
      await db.close();
    });

    await MountRegistry(db).upsert(
      const StorageMount(
        id: 'm-1',
        kind: StorageKind.webdav,
        displayName: 'Local NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.50/dav'},
      ),
    );
    final now = DateTime(2026).millisecondsSinceEpoch;
    final movieId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.pending,
        title: 'The Matrix',
        sortTitle: 'matrix',
        year: const Value(1999),
        addedAt: now,
        updatedAt: now,
      ),
    );
    final fileId = await repo.upsertFile(
      mountId: 'm-1',
      path: '/Movies/The.Matrix.1999.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
      size: 2048,
      modifiedAt: now,
    );
    await repo.linkFile(fileId, movieId);

    await scans.scrapeLibrary();
    expect(scans.scrapeStatus.note, isNotNull);
    expect(scans.scrapeStatus.note, contains('tmdb upstream unavailable'));

    final itemAfter502 = (await db.select(db.libraryItems).getSingle());
    final fileAfter502 = (await db.select(db.libraryFiles).getSingle());
    expect(itemAfter502.libraryType, LibraryTypes.pending);
    expect(itemAfter502.scrapedAt, isNull);
    expect(fileAfter502.matchState, isNot(LibraryMatchStates.unmatched));

    // Recovering upstream allows retryUnmatched to complete the match.
    server.identifyReturns502 = false;
    await scans.scrapeLibrary(retryUnmatched: true);
    expect(scans.scrapeStatus.note, isNull);
    final itemAfterRecovery = (await db.select(db.libraryItems).getSingle());
    final fileAfterRecovery = (await db.select(db.libraryFiles).getSingle());
    expect(itemAfterRecovery.libraryType, LibraryTypes.movie);
    expect(itemAfterRecovery.tmdbId, '603');
    expect(itemAfterRecovery.scrapedAt, isNotNull);
    expect(fileAfterRecovery.matchState, LibraryMatchStates.matched);
  });

  test('hydrateWorkDetailsById fetches missing details via /api/v1/public/metadata/batch', () async {
    final server = await _MockMetadataAndAuthServer.start();
    addTearDown(server.close);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final provider = ServerMetadataProvider(serverUrl: server.baseUrl);
    addTearDown(() async {
      provider.close();
      await db.close();
    });

    final now = DateTime(2026).millisecondsSinceEpoch;
    final movieId = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'The Matrix',
        sortTitle: 'matrix',
        tmdbId: const Value('603'),
        metadataSource: const Value('tmdb'),
        scrapedAt: Value(now),
        addedAt: now,
        updatedAt: now,
      ),
    );

    server.requestedPaths.clear();
    final scraper = LibraryScraper(db, repo, providers: [provider]);
    final hydrated = await scraper.hydrateWorkDetailsById(movieId);

    expect(hydrated, isTrue);
    expect(server.requestedPaths, contains('/api/v1/public/metadata/batch'));
    expect(server.requestedPaths, isNot(contains('/api/v1/public/metadata/work')));

    final updated = await repo.getItem(movieId);
    expect(updated?.item.summary, contains('computer hacker'));
    expect(updated?.item.runtimeMs, 8160000);
    expect(updated?.item.imdbId, 'tt0133093');
    expect(updated?.item.backdropSource, contains('/api/v1/public/metadata/artwork?src='));
    final credits = await repo.creditsOf(movieId);
    expect(credits.single.person.name, 'Keanu Reeves');
  });

  test(
    'LocalWorkspaceArchive and AppSessionController archive and restore local workspace without losing trusted LAN peers',
    () async {
      final server = await _MockMetadataAndAuthServer.start();
      addTearDown(server.close);

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = LibraryRepository(db);
      final mountRegistry = MountRegistry(db);
      final mounts = MountManager(mountRegistry);
      final identityStore = LanIdentityStore(db);
      final archive = LocalWorkspaceArchive(db);
      final session = AppSessionController(
        db: db,
        archive: archive,
        mountManager: mounts,
        identityStore: identityStore,
      );
      addTearDown(() async {
        session.dispose();
        await mounts.dispose();
        await db.close();
      });

      final myDeviceId = await identityStore.getOrCreateDeviceId();
      await identityStore.setDeviceName('LivingRoom-PC');
      final peerKp = await LanCrypto.generateLanIdentityKeyPair();
      await identityStore.saveTrustedLanPeers([
        LanTrustedPeer(
          deviceId: 'tv-1',
          deviceName: 'Bedroom-TV',
          pubKeyBase64: peerKp.publicKeyBase64,
          sharedKeyBase64: base64Encode(List<int>.filled(32, 9)),
          pairedAtMs: 123456,
        ),
      ]);

      await mountRegistry.upsert(
        const StorageMount(
          id: 'cur_mount',
          kind: StorageKind.webdav,
          displayName: 'Cur DAV',
          config: {MountKeys.baseUrl: 'http://192.168.1.10/cur'},
        ),
      );
      final now = DateTime(2026).millisecondsSinceEpoch;
      final movieId = await repo.insertItem(
        LibraryItemsCompanion.insert(
          workKey: const Value('tmdb:movie:603'),
          kind: LibraryKinds.movie,
          libraryType: LibraryTypes.movie,
          title: 'The Matrix',
          sortTitle: 'matrix',
          tmdbId: const Value('603'),
          metadataSource: const Value('tmdb'),
          scrapedAt: Value(now),
          addedAt: now,
          updatedAt: now,
        ),
      );
      final fileId = await repo.upsertFile(
        mountId: 'cur_mount',
        path: '/Movies/Matrix.mkv',
        role: LibraryFileRoles.video,
        scanId: 1,
        size: 4096,
        modifiedAt: now,
      );
      await repo.linkFile(fileId, movieId);
      await repo.setProgress(movieId, positionMs: 42000, durationMs: 8160000);

      await session.initialize();
      await session.selectOfflineMode();
      expect(session.isOffline, isTrue);

      // Switching to Self-Hosted archives local workspace, clears local tables, and keeps LAN identity & peers.
      final sh = await session.loginSelfHosted(serverUrl: server.baseUrl, username: 'alice', password: 'secret');
      expect(sh.username, 'alice');
      expect(session.isSelfHosted, isTrue);
      expect(server.requestedPaths, containsAll(['/api/v1/public/bootstrap', '/api/v1/auth/login']));
      expect(await session.hasArchivedLocalWorkspace(), isTrue);
      expect(await mountRegistry.list(), isEmpty);
      expect(await db.select(db.libraryItems).get(), isEmpty);
      expect(await identityStore.getOrCreateDeviceId(), myDeviceId);
      expect((await identityStore.loadTrustedLanPeers()).map((p) => p.deviceId), ['tv-1']);

      // Switching back to Offline restores mount, catalog, and watch progress while keeping LAN identity & peers.
      await session.switchToOfflineMode();
      expect(session.isOffline, isTrue);
      expect(session.selfHostedSession, isNull);
      expect(await session.hasArchivedLocalWorkspace(), isFalse);
      expect((await mountRegistry.list()).map((m) => m.id), ['cur_mount']);
      final restoredItem = await db.select(db.libraryItems).getSingle();
      expect(restoredItem.title, 'The Matrix');
      final restoredView = await repo.getItem(restoredItem.id);
      expect(restoredView?.state?.positionMs, 42000);
      expect((await identityStore.loadTrustedLanPeers()).map((p) => p.deviceId), ['tv-1']);
    },
  );
}
