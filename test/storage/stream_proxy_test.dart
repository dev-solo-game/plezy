import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/http_range_reader.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/storage/stream_proxy.dart';

class _MemoryDriver implements StorageDriver {
  _MemoryDriver(this.bytes);

  final List<int> bytes;
  StorageException? failWith;
  final List<({int start, int? end})> reads = [];

  @override
  StorageKind get kind => StorageKind.local;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => const [];

  @override
  Future<StorageEntry> stat(String path) async =>
      StorageEntry(path: path, name: 'file.mkv', isDirectory: false, size: bytes.length);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {
    reads.add((start: start, end: end));
    final failure = failWith;
    if (failure != null) throw failure;
    yield bytes.sublist(start, end == null ? bytes.length : end + 1);
  }

  @override
  Future<void> close() async {}
}

class _ParallelDriver extends _MemoryDriver implements ParallelReadSource {
  _ParallelDriver(super.bytes);

  final List<({int start, int end, int connections, int chunkSize})> parallelReads = [];

  @override
  Stream<List<int>> openReadParallel(
    StorageEntry entry, {
    int start = 0,
    required int end,
    required int connections,
    required int chunkSize,
  }) async* {
    parallelReads.add((start: start, end: end, connections: connections, chunkSize: chunkSize));
    yield bytes.sublist(start, end + 1);
  }
}

void main() {
  late StreamProxy proxy;
  late _MemoryDriver driver;
  late HttpClient client;
  final content = List<int>.generate(1000, (i) => i % 251);

  setUp(() {
    HttpOverrides.global = null;
    proxy = StreamProxy();
    driver = _MemoryDriver(content);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.stop();
  });

  Future<Uri> register({int? size = 1000, String name = 'file.mkv'}) {
    return proxy.register(
      mountId: 'm1',
      driver: driver,
      entry: StorageEntry(path: '/$name', name: name, isDirectory: false, size: size),
    );
  }

  Future<({int status, HttpHeaders headers, List<int> body})> fetch(
    Uri url, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await client.openUrl(method, url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.expand((c) => c).toList();
    return (status: response.statusCode, headers: response.headers, body: body);
  }

  test('binds to loopback and serves the whole file', () async {
    final url = await register();
    expect(url.host, '127.0.0.1');
    expect(url.pathSegments.last, 'file.mkv');

    final result = await fetch(url);
    expect(result.status, 200);
    expect(result.body, content);
    expect(result.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(result.headers.contentType?.mimeType, 'video/x-matroska');
  });

  test('serves bounded, open-ended and suffix ranges', () async {
    final url = await register();

    final bounded = await fetch(url, range: 'bytes=100-199');
    expect(bounded.status, 206);
    expect(bounded.body, content.sublist(100, 200));
    expect(bounded.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/1000');

    final open = await fetch(url, range: 'bytes=990-');
    expect(open.status, 206);
    expect(open.body, content.sublist(990));
    expect(open.headers.value(HttpHeaders.contentRangeHeader), 'bytes 990-999/1000');

    final suffix = await fetch(url, range: 'bytes=-10');
    expect(suffix.body, content.sublist(990));

    final clamped = await fetch(url, range: 'bytes=900-5000');
    expect(clamped.headers.value(HttpHeaders.contentRangeHeader), 'bytes 900-999/1000');
    expect(clamped.body.length, 100);
  });

  test('rejects a range past the end with 416', () async {
    final url = await register();
    final result = await fetch(url, range: 'bytes=1000-');
    expect(result.status, 416);
    expect(result.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
    expect(driver.reads, isEmpty);
  });

  test('HEAD reports the length without reading', () async {
    final url = await register();
    final result = await fetch(url, method: 'HEAD');
    expect(result.status, 200);
    expect(result.headers.contentLength, 1000);
    expect(driver.reads, isEmpty);
  });

  test('asks the driver for the size when the entry has none', () async {
    final url = await register(size: null);
    final result = await fetch(url, range: 'bytes=0-9');
    expect(result.status, 206);
    expect(result.body, content.sublist(0, 10));
  });

  test('unknown tokens and other methods are refused', () async {
    final url = await register();
    final wrongToken = url.replace(pathSegments: ['s', 'not-a-token', 'file.mkv']);
    expect((await fetch(wrongToken)).status, 404);
    expect((await fetch(url, method: 'POST')).status, 405);
  });

  test('registering the same file again keeps its URL; unregistering drops it', () async {
    final first = await register();
    final second = await register();
    expect(second, first);

    proxy.unregisterMount('m1');
    expect((await fetch(first)).status, 404);
  });

  test('a driver failure before any byte maps to an HTTP error', () async {
    final url = await register();
    driver.failWith = const StorageException(StorageErrorKind.unauthorized, 'cookie expired');
    expect((await fetch(url, range: 'bytes=0-9')).status, 403);

    driver.failWith = const StorageException(StorageErrorKind.notFound, 'deleted');
    expect((await fetch(url)).status, 404);
  });

  test('a bulk URL reads over several connections; the plain URL does not', () async {
    var options = const BulkReadOptions(connections: 3, chunkSize: 4096);
    await proxy.stop();
    proxy = StreamProxy(bulkOptions: () => options);
    final parallel = _ParallelDriver(content);
    final entry = StorageEntry(path: '/file.mkv', name: 'file.mkv', isDirectory: false, size: 1000);
    final plain = await proxy.register(mountId: 'm1', driver: parallel, entry: entry);
    final bulk = await proxy.register(mountId: 'm1', driver: parallel, entry: entry, bulk: true);
    expect(bulk.pathSegments[1], plain.pathSegments[1]);
    expect(bulk.pathSegments.first, 'd');

    final whole = await fetch(bulk);
    expect(whole.body, content);
    // A changed setting applies to the next request.
    options = const BulkReadOptions(connections: 6, chunkSize: 8192);
    final resumed = await fetch(bulk, range: 'bytes=400-');
    expect(resumed.status, 206);
    expect(resumed.body, content.sublist(400));
    expect(parallel.parallelReads, [
      (start: 0, end: 999, connections: 3, chunkSize: 4096),
      (start: 400, end: 999, connections: 6, chunkSize: 8192),
    ]);

    await fetch(plain, range: 'bytes=0-9');
    expect(parallel.parallelReads, hasLength(2));
    expect(parallel.reads, [(start: 0, end: 9)]);
  });

  test('a bulk URL falls back to a plain read for drivers without parallel reads', () async {
    final url = await register();
    final bulk = url.replace(pathSegments: ['d', ...url.pathSegments.skip(1)]);
    final result = await fetch(bulk);
    expect(result.body, content);
    expect(driver.reads, [(start: 0, end: null)]);
  });
}
