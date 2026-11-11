import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/storage_driver.dart';

/// A stand-in for the Quark API and its download host on one loopback server.
class _FakeQuark {
  late HttpServer server;
  final List<String> apiCalls = [];
  final List<String?> cookiesSeen = [];
  final List<Map<String, dynamic>> playInfoBodies = [];
  final Set<String> revokedLinks = {};
  int linkCounter = 0;
  String? rotateCookieTo;
  bool addMalformedSetCookie = false;
  bool requireLogin = false;

  static final fileBytes = List<int>.generate(64, (i) => i);

  /// folder id → rows.
  final Map<String, List<Map<String, Object?>>> folders = {
    '0': [
      {'fid': 'dir-movies', 'file_name': 'Movies', 'file': false, 'updated_at': 1000},
      {'fid': 'f-readme', 'file_name': 'readme.txt', 'file': true, 'size': 3, 'updated_at': 2000},
    ],
    'dir-movies': [
      {'fid': 'f-film', 'file_name': 'Film (2020).mkv', 'file': true, 'size': 64, 'updated_at': 3000},
    ],
  };

  Uri get apiBase => Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final body = await utf8.decodeStream(request);
    final path = request.uri.path;
    cookiesSeen.add(request.headers.value(HttpHeaders.cookieHeader));

    if (path.startsWith('/dl/')) {
      final token = path.substring('/dl/'.length);
      if (revokedLinks.contains(token)) {
        response.statusCode = HttpStatus.forbidden;
        return response.close();
      }
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final start = match == null ? 0 : int.parse(match.group(1)!);
      final end = match == null || match.group(2)!.isEmpty ? fileBytes.length - 1 : int.parse(match.group(2)!);
      response.statusCode = match == null ? HttpStatus.ok : HttpStatus.partialContent;
      response.add(fileBytes.sublist(start, end + 1));
      return response.close();
    }

    apiCalls.add('${request.method} ${path.replaceFirst('/1/clouddrive', '')} ${request.uri.queryParameters}');
    response.headers.contentType = ContentType.json;
    if (addMalformedSetCookie) {
      response.headers.add(HttpHeaders.setCookieHeader, 'noequals');
      response.headers.add(HttpHeaders.setCookieHeader, 'bad=x; Expires=NotADate');
    }
    if (rotateCookieTo != null) {
      response.headers.add(HttpHeaders.setCookieHeader, '__puus=$rotateCookieTo; Path=/');
    }
    if (requireLogin) {
      response.statusCode = HttpStatus.unauthorized;
      response.write(jsonEncode({'status': 401, 'code': 31001, 'message': 'require login [guest]'}));
      return response.close();
    }

    Object? data;
    Map<String, Object?> metadata = {};
    if (path.endsWith('/config')) {
      data = <String, Object?>{};
    } else if (path.endsWith('/file/sort')) {
      final query = request.uri.queryParameters;
      final all = folders[query['pdir_fid']] ?? const [];
      final size = int.parse(query['_size']!);
      final page = int.parse(query['_page']!);
      final from = (page - 1) * size;
      data = {'list': from >= all.length ? const [] : all.sublist(from, (from + size).clamp(0, all.length))};
      metadata = {'_total': all.length};
    } else if (path.endsWith('/file/download')) {
      final fids = (jsonDecode(body) as Map)['fids'] as List;
      data = [
        for (final fid in fids)
          {'fid': fid, 'download_url': 'http://127.0.0.1:${server.port}/dl/${fid}_${++linkCounter}'},
      ];
    } else if (path.endsWith('/file/v2/play')) {
      playInfoBodies.add(jsonDecode(body) as Map<String, dynamic>);
      data = {
        'video_list': [
          {
            'resolution': 'super',
            'video_info': {'url': 'http://127.0.0.1:${server.port}/hls/super.m3u8', 'width': 1920, 'height': 1080},
          },
        ],
      };
    }
    response.write(jsonEncode({'status': 200, 'code': 0, 'message': 'ok', 'data': data, 'metadata': metadata}));
    return response.close();
  }
}

void main() {
  late _FakeQuark fake;
  late QuarkStorageDriver driver;
  final rotated = <String>[];

  setUp(() async {
    HttpOverrides.global = null;
    rotated.clear();
    fake = _FakeQuark();
    await fake.start();
    driver = QuarkStorageDriver(
      cookie: '__pus=abc; __puus=old; other=1',
      requestInterval: Duration.zero,
      apiBase: fake.apiBase,
      onCookieChanged: rotated.add,
    );
  });

  tearDown(() async {
    await driver.close();
    await fake.server.close(force: true);
  });

  Future<List<int>> readAll(Stream<List<int>> stream) => stream.expand((c) => c).toList();

  test('lists the root with ids, sizes and timestamps', () async {
    final entries = await driver.list('/');
    expect(entries.map((e) => '${e.path}:${e.id}'), ['/Movies:dir-movies', '/readme.txt:f-readme']);
    expect(entries[0].isDirectory, isTrue);
    expect(entries[0].size, isNull);
    expect(entries[1].size, 3);
    expect(entries[1].modifiedAt, DateTime.fromMillisecondsSinceEpoch(2000));
    expect(fake.apiCalls.single, contains('pdir_fid: 0'));
    expect(fake.apiCalls.single, contains('pr: ucpro'));
  });

  test('resolves a nested path by walking down from the root', () async {
    final entries = await driver.list('/Movies');
    expect(entries.single.path, '/Movies/Film (2020).mkv');
    expect(fake.apiCalls.length, 2, reason: 'root listing to learn the folder id, then the folder itself');

    // The folder id is now known; no second walk.
    await driver.list('/Movies');
    expect(fake.apiCalls.length, 3);
  });

  test('a known parent entry skips path resolution', () async {
    await driver.list('/', parent: null);
    fake.apiCalls.clear();
    await driver.list(
      '/Movies',
      parent: const StorageEntry(path: '/Movies', name: 'Movies', isDirectory: true, id: 'dir-movies'),
    );
    expect(fake.apiCalls.single, contains('pdir_fid: dir-movies'));
  });

  test('a missing folder reports notFound', () async {
    await expectLater(
      driver.list('/Nope/Deeper'),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.notFound)),
    );
  });

  test('pages through folders larger than one page', () async {
    fake.folders['0'] = [
      for (var i = 0; i < 230; i++) {'fid': 'f$i', 'file_name': 'file$i.mkv', 'file': true, 'size': 1},
    ];
    final entries = await driver.list('/');
    expect(entries.length, 230);
    expect(fake.apiCalls.length, 3);
  });

  test('reads a range through a download link and reuses the link', () async {
    final film = (await driver.list('/Movies')).single;
    fake.apiCalls.clear();

    expect(await readAll(driver.openRead(film, start: 10, end: 19)), List<int>.generate(10, (i) => i + 10));
    expect(await readAll(driver.openRead(film, start: 60)), [60, 61, 62, 63]);
    expect(fake.apiCalls.where((c) => c.contains('/file/download')).length, 1);
    expect(fake.cookiesSeen.last, contains('__pus=abc'), reason: 'the download host needs the cookie too');
  });

  test('fetches a fresh link when the cached one is rejected', () async {
    final film = (await driver.list('/Movies')).single;
    await readAll(driver.openRead(film, end: 3));
    fake.revokedLinks.add('f-film_1');

    expect(await readAll(driver.openRead(film, start: 4, end: 7)), [4, 5, 6, 7]);
    expect(fake.linkCounter, 2);
  });

  test('persists a rotated session cookie and sends it afterwards', () async {
    fake.rotateCookieTo = 'new';
    await driver.check();
    expect(rotated, ['__pus=abc; __puus=new; other=1']);

    fake.rotateCookieTo = null;
    await driver.check();
    expect(fake.cookiesSeen.last, '__pus=abc; __puus=new; other=1');
    expect(rotated.length, 1, reason: 'an unchanged cookie is not reported again');
  });

  test('rotates __puus even when sibling Set-Cookie headers are malformed', () async {
    fake.addMalformedSetCookie = true;
    fake.rotateCookieTo = 'rotated-2';
    await driver.check();
    expect(rotated, ['__pus=abc; __puus=rotated-2; other=1']);

    fake.addMalformedSetCookie = false;
    fake.rotateCookieTo = null;
    await driver.check();
    expect(fake.cookiesSeen.last, '__pus=abc; __puus=rotated-2; other=1');
  });

  test('requests apollo and dolby_low capabilities in web play-info', () async {
    const film = StorageEntry(path: '/Movies/Film (2020).mkv', name: 'Film (2020).mkv', isDirectory: false, id: 'f-film');
    final variants = await driver.streamVariants(film);
    expect(variants.map((v) => v.id), ['super']);
    final supports = fake.playInfoBodies.single['supports'] as String;
    expect(supports.split(','), containsAll(['m3u8', 'fmp4', 'apollo', 'dolby_vision', 'dolby_low']));
  });

  test('an expired cookie surfaces as unauthorized', () async {
    fake.requireLogin = true;
    await expectLater(
      driver.check(),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.unauthorized)),
    );
  });
}
