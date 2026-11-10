import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/webdav_storage_driver.dart';
import 'package:plezy/storage/storage_driver.dart';

const _listing = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/media/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/media/%E7%94%B5%E5%BD%B1/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
    <D:getlastmodified>Mon, 02 Nov 2026 10:00:00 GMT</D:getlastmodified></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>http://ignored.example/dav/media/My%20Film%20(2020).mkv</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12</D:getcontentlength>
    <D:getlastmodified>Mon, 02 Nov 2026 10:00:00 GMT</D:getlastmodified></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    <D:propstat><D:prop><D:quota/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/elsewhere/outside.mkv</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

void main() {
  late HttpServer server;
  late WebDavStorageDriver driver;
  final requests = <String>[];
  const fileBytes = 'hello world!';
  final expectedAuth = 'Basic ${base64Encode(utf8.encode('alice:s3cret'))}';

  setUp(() async {
    HttpOverrides.global = null;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      await request.drain<void>();
      requests.add('${request.method} ${request.uri.path} depth=${request.headers.value('Depth')}');
      if (request.headers.value(HttpHeaders.authorizationHeader) != expectedAuth) {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="dav"');
        return response.close();
      }
      if (request.method == 'PROPFIND') {
        if (request.uri.path.startsWith('/dav/media/missing')) {
          response.statusCode = HttpStatus.notFound;
          return response.close();
        }
        response.statusCode = HttpStatus.multiStatus;
        response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        response.add(utf8.encode(_listing));
        return response.close();
      }
      // GET: honour the Range header.
      final bytes = utf8.encode(fileBytes);
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (match == null) {
        response.add(bytes);
      } else {
        final start = int.parse(match.group(1)!);
        final end = match.group(2)!.isEmpty ? bytes.length - 1 : int.parse(match.group(2)!);
        response.statusCode = HttpStatus.partialContent;
        response.add(bytes.sublist(start, end + 1));
      }
      return response.close();
    });
    driver = WebDavStorageDriver(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/dav/media'),
      username: 'alice',
      password: 's3cret',
    );
  });

  tearDown(() async {
    await driver.close();
    await server.close(force: true);
  });

  test('lists children, decoding hrefs and skipping the collection itself', () async {
    final entries = await driver.list('/');
    expect(entries.map((e) => e.path), ['/电影', '/My Film (2020).mkv']);
    expect(entries[0].isDirectory, isTrue);
    expect(entries[1].isDirectory, isFalse);
    expect(entries[1].size, 12);
    expect(entries[1].modifiedAt, DateTime.utc(2026, 11, 2, 10));
    expect(requests.last, 'PROPFIND /dav/media/ depth=1');
  });

  test('authenticates after a 401 challenge', () async {
    await driver.check();
    expect(requests.first, startsWith('PROPFIND'));
    expect(requests.length, 2, reason: 'one challenged request, one authenticated retry');
  });

  test('wrong credentials surface as unauthorized', () async {
    final wrong = WebDavStorageDriver(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/dav/media'),
      username: 'alice',
      password: 'nope',
    );
    addTearDown(wrong.close);
    await expectLater(
      wrong.check(),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.unauthorized)),
    );
  });

  test('a missing path reports notFound', () async {
    await expectLater(
      driver.list('/missing'),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.notFound)),
    );
  });

  test('reads a byte range, percent-encoding the request path', () async {
    final entry = (await driver.list('/')).last;
    final bytes = await driver.openRead(entry, start: 6, end: 10).expand((c) => c).toList();
    expect(utf8.decode(bytes), 'world');
    expect(requests.last, startsWith('GET /dav/media/My%20Film%20(2020).mkv'));
  });
}
