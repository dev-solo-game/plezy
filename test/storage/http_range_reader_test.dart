import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/http_range_reader.dart';
import 'package:plezy/storage/storage_driver.dart';

/// A local origin serving [content] with Range support, and knobs for the
/// misbehaviour cloud CDNs show.
class _Origin {
  _Origin(this.content);

  final List<int> content;
  late HttpServer _server;

  final List<String?> ranges = [];
  int active = 0;
  int maxActive = 0;

  /// Answers 200 with the whole file, as an origin that ignores Range does.
  bool ignoreRange = false;

  /// Paths (links) the origin refuses with 403.
  final Set<String> refused = {};

  /// Paths the origin serves this many more times before refusing them, as
  /// a link that expires mid-read.
  final Map<String, int> expiresAfter = {};

  /// Range starts whose next answer is cut short once.
  final Set<int> truncateOnce = {};

  final Map<int, String> contentRanges = {};
  final Map<int, Future<void>> stallHeadersOnce = {};
  void Function(String? range)? onRange;

  Uri link(String name) => Uri.parse('http://127.0.0.1:${_server.port}/$name');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    onRange?.call(range);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      // Long enough for the reader's other connections to overlap.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final path = request.uri.path;
      final left = expiresAfter[path];
      if (left != null) {
        if (left <= 0) refused.add(path);
        expiresAfter[path] = left - 1;
      }
      if (refused.contains(path)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (ignoreRange || match == null) {
        response.contentLength = content.length;
        response.add(content);
        return;
      }
      final start = int.parse(match[1]!);
      final end = match[2]!.isEmpty ? content.length - 1 : int.parse(match[2]!);
      final stall = stallHeadersOnce.remove(start);
      if (stall != null) {
        await stall;
        return;
      }
      var body = content.sublist(start, end + 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        contentRanges[start] ?? 'bytes $start-$end/${content.length}',
      );
      if (truncateOnce.remove(start)) {
        // Claim the full length but close early, as a dropped connection does.
        body = body.sublist(0, body.length ~/ 2);
        response.headers.chunkedTransferEncoding = true;
      } else {
        response.contentLength = body.length;
      }
      response.add(body);
    } finally {
      active--;
      await response.close().catchError((Object _) {});
    }
  }
}

void main() {
  late _Origin origin;
  late HttpClient client;
  final content = List<int>.generate(10000, (i) => (i * 7) % 256);

  setUp(() async {
    HttpOverrides.global = null;
    origin = _Origin(content);
    await origin.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await origin.stop();
  });

  Future<List<int>> collect(Stream<List<int>> stream) async => (await stream.toList()).expand((c) => c).toList();

  StorageLinkResolver resolverFor(List<String> names, List<bool> calls) {
    var index = 0;
    return ({required bool forceRefresh}) async {
      calls.add(forceRefresh);
      if (forceRefresh) index++;
      return StorageLink(origin.link(names[index]));
    };
  }

  test('fetches a span over several connections and keeps the order', () async {
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final calls = <bool>[];
    final bytes = await collect(reader.read(resolverFor(['a'], calls), start: 500, end: 9499, connections: 4));

    expect(bytes, content.sublist(500, 9500));
    expect(origin.ranges, hasLength(9));
    expect(origin.ranges.first, 'bytes=500-1499');
    expect(origin.ranges, contains('bytes=8500-9499'));
    expect(origin.maxActive, greaterThan(1));
    expect(origin.maxActive, lessThanOrEqualTo(4));
    expect(calls, [false]);
  });

  test('a span within one chunk stays on a single connection', () async {
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final bytes = await collect(reader.read(resolverFor(['a'], []), start: 0, end: 999, connections: 4));
    expect(bytes, content.sublist(0, 1000));
    expect(origin.ranges, ['bytes=0-999']);
  });

  test('an origin that ignores Range is read once, not once per connection', () async {
    origin.ignoreRange = true;
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final bytes = await collect(reader.read(resolverFor(['a'], []), start: 2000, end: 7999, connections: 4));
    expect(bytes, content.sublist(2000, 8000));
    expect(origin.ranges, hasLength(1));
  });

  test('a link refused mid-read is renewed once for every connection', () async {
    // 'a' serves the first chunk, then expires under the other connections.
    origin.expiresAfter['/a'] = 1;
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final calls = <bool>[];
    final bytes = await collect(reader.read(resolverFor(['a', 'b'], calls), start: 0, end: 9999, connections: 4));

    expect(bytes, content);
    expect(calls, [false, true]);
    expect(origin.refused, {'/a'});
  });

  test('a connection cut short is retried', () async {
    origin.truncateOnce.add(3000);
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final bytes = await collect(reader.read(resolverFor(['a'], []), start: 0, end: 9999, connections: 3));
    expect(bytes, content);
    expect(origin.ranges.where((r) => r == 'bytes=3000-3999'), hasLength(2));
  });

  test('rejects an equal-length chunk reporting the wrong byte offsets', () async {
    origin.contentRanges[1000] = 'bytes 2000-2999/10000';
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final bytes = <int>[];

    await expectLater(
      reader.read(resolverFor(['a'], []), end: 2999, connections: 2, expectedSize: 10000).forEach(bytes.addAll),
      throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('Invalid Content-Range'))),
    );
    expect(bytes, content.sublist(0, 1000));
  });

  test('rejects a different file size before sending the first bytes', () async {
    final reader = HttpRangeReader(client, chunkSize: 1000);
    await expectLater(
      reader.read(resolverFor(['a'], []), start: 1000, end: 1999, expectedSize: 12000),
      emitsError(isA<StorageException>().having((e) => e.message, 'message', contains('expected 12000'))),
    );
  });

  test('retries when the first request stalls before response headers', () async {
    final stalled = Completer<void>();
    addTearDown(stalled.complete);
    origin.stallHeadersOnce[0] = stalled.future;
    final reader = HttpRangeReader(client, chunkSize: 1000, stallTimeout: const Duration(milliseconds: 250));

    final bytes = await collect(reader.read(resolverFor(['a'], []), end: 2999, connections: 2));

    expect(bytes, content.sublist(0, 3000));
    expect(origin.ranges.where((r) => r == 'bytes=0-999'), hasLength(2));
  });

  test('cancelling before the first response does not wait for its headers', () async {
    final accepted = Completer<void>();
    final disconnected = Completer<void>();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.listen(
        (_) {
          if (!accepted.isCompleted) accepted.complete();
        },
        onDone: () {
          socket.destroy();
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/video');
    final subscription = reader
        .read(({required forceRefresh}) async => StorageLink(uri), end: 2999, connections: 2)
        .listen((_) {});
    addTearDown(subscription.cancel);
    const deadline = Duration(seconds: 3);

    await accepted.future.timeout(deadline);
    await subscription.cancel().timeout(deadline);
    await disconnected.future.timeout(deadline);
  });

  test('cancelling a redirected request closes the target connection', () async {
    final accepted = Completer<void>();
    final disconnected = Completer<void>();
    final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(target.close);
    target.listen((socket) {
      socket.listen(
        (_) {
          if (!accepted.isCompleted) accepted.complete();
        },
        onDone: () {
          socket.destroy();
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => redirect.close(force: true));
    redirect.listen((request) {
      unawaited(request.response.redirect(Uri.parse('http://127.0.0.1:${target.port}/video')));
    });
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final uri = Uri.parse('http://127.0.0.1:${redirect.port}/redirect');
    final subscription = reader
        .read(({required forceRefresh}) async => StorageLink(uri), end: 2999, connections: 2)
        .listen((_) {});
    addTearDown(subscription.cancel);
    const deadline = Duration(seconds: 3);

    await accepted.future.timeout(deadline);
    await subscription.cancel().timeout(deadline);
    await disconnected.future.timeout(deadline);
  });

  test('a paused consumer keeps the emitted piece within the prefetch window', () async {
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final chunks = StreamIterator(reader.read(resolverFor(['a'], []), end: 2999, connections: 2));
    addTearDown(chunks.cancel);
    final prefetched = Completer<void>();
    origin.onRange = (range) {
      if (range == 'bytes=1000-1999') prefetched.complete();
    };

    expect(await chunks.moveNext(), isTrue);
    expect(chunks.current, content.sublist(0, 1000));
    await prefetched.future;
    expect(origin.ranges, ['bytes=0-999', 'bytes=1000-1999']);
    expect(await chunks.moveNext(), isTrue);
    expect(await chunks.moveNext(), isTrue);
    expect(chunks.current, content.sublist(2000, 3000));
  });

  test('large configured chunks reduce the effective concurrency to fit the byte budget', () async {
    origin.ignoreRange = true;
    const size = 2 * BulkReadOptions.maxBufferedBytes;
    final reader = HttpRangeReader(client, chunkSize: BulkReadOptions.maxBufferedBytes);
    await expectLater(
      collect(reader.read(resolverFor(['a'], []), end: size - 1, connections: 16)),
      throwsA(isA<StorageException>()),
    );
    expect(origin.ranges, ['bytes=0-${size - 1}']);
  });

  test('a link that keeps being refused fails the read', () async {
    origin.refused.addAll({'/a', '/b', '/c', '/d'});
    final reader = HttpRangeReader(client, chunkSize: 1000);
    await expectLater(
      collect(reader.read(resolverFor(['a', 'b', 'c', 'd'], []), start: 0, end: 9999, connections: 4)),
      throwsA(isA<StorageException>()),
    );
  });

  test('without a known end it reads over one connection', () async {
    final reader = HttpRangeReader(client, chunkSize: 1000);
    final bytes = await collect(reader.read(resolverFor(['a'], []), start: 9000, connections: 4));
    expect(bytes, content.sublist(9000));
    expect(origin.ranges, ['bytes=9000-']);
  });
}
