import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'storage_driver.dart';

/// How a bulk transfer (the downloader) reads one file: over [connections]
/// connections at once, [chunkSize] bytes per request.
class BulkReadOptions {
  const BulkReadOptions({this.connections = defaultConnections, this.chunkSize = defaultChunkSize});

  final int connections;
  final int chunkSize;

  static const int defaultConnections = 4;
  static const int defaultChunkSize = 16 * 1024 * 1024;

  /// Maximum payload held in the ordered prefetch window for one download.
  static const int maxBufferedBytes = defaultConnections * defaultChunkSize;

  static const BulkReadOptions defaults = BulkReadOptions();
}

/// A fetchable location for a file's bytes, plus the headers the origin
/// requires. Cloud drives hand these out with a limited lifetime.
class StorageLink {
  const StorageLink(this.url, {this.headers = const {}, this.expiresAt});

  final Uri url;
  final Map<String, String> headers;
  final DateTime? expiresAt;
}

/// Resolves the current link for a file. [forceRefresh] is true when the
/// previous link was rejected and a cached one must not be reused.
typedef StorageLinkResolver = Future<StorageLink> Function({required bool forceRefresh});

/// Reads byte ranges over HTTP for drivers whose files are reachable by URL.
///
/// A link the origin rejects is refreshed once and the request retried, which
/// is what keeps playback alive across an expiring cloud-drive link.
class HttpRangeReader {
  HttpRangeReader(this._client, {this.chunkSize = defaultChunkSize, this.stallTimeout = const Duration(seconds: 30)});

  final HttpClient _client;

  /// How many bytes each connection of a parallel read fetches at a time,
  /// unless a read names its own.
  final int chunkSize;

  static const int defaultChunkSize = BulkReadOptions.defaultChunkSize;

  /// How often one chunk of a parallel read is tried before the read fails.
  static const int _chunkAttempts = 3;

  /// Link refreshes one parallel read may ask for before giving up.
  static const int _maxRefreshes = 2;

  /// How long a connection may wait for the origin's next bytes.
  final Duration stallTimeout;

  static const Set<int> _staleLinkStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
  };

  /// Reads [start]..[end] (inclusive; [end] null for the rest of the file).
  ///
  /// With [connections] above 1 and a known [end], the span is fetched as
  /// [chunkSize] (default: the reader's) pieces and delivered in order.
  /// The buffer budget can reduce the number of active connections.
  /// [expectedSize] is the whole file size for a bulk read, even when the
  /// caller requests only part of the file.
  Stream<List<int>> read(
    StorageLinkResolver resolve, {
    int start = 0,
    int? end,
    int connections = 1,
    int? chunkSize,
    int? expectedSize,
  }) {
    final piece = (chunkSize ?? this.chunkSize).clamp(1, BulkReadOptions.maxBufferedBytes);
    final slots = min(connections, BulkReadOptions.maxBufferedBytes ~/ piece);
    if (end == null || (expectedSize == null && (connections <= 1 || end - start + 1 <= piece))) {
      return _readSingle(resolve, start, end);
    }

    final pending = Queue<_Chunk>();
    late StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>(sync: true);
    controller
      ..onListen = () {
        subscription = _readBulk(
          resolve,
          start,
          end,
          slots,
          piece,
          expectedSize,
          pending,
        ).listen(controller.add, onError: controller.addError, onDone: controller.close);
      }
      ..onPause = () {
        subscription.pause();
      }
      ..onResume = () {
        subscription.resume();
      }
      ..onCancel = () {
        for (final chunk in pending) {
          chunk.cancel();
        }
        return subscription.cancel();
      };
    return controller.stream;
  }

  Stream<List<int>> _readSingle(StorageLinkResolver resolve, int start, int? end) async* {
    var response = await _get(await resolve(forceRefresh: false), start, end);
    if (_staleLinkStatuses.contains(response.statusCode)) {
      await _discard(response);
      response = await _get(await resolve(forceRefresh: true), start, end);
    }

    switch (response.statusCode) {
      case HttpStatus.partialContent:
        yield* response;
      case HttpStatus.ok:
        // The origin ignored the Range header and is sending the whole file.
        yield* _slice(response, start, end);
      default:
        final status = response.statusCode;
        await _discard(response);
        throw StorageException(_kindFor(status), 'Origin answered HTTP $status');
    }
  }

  Stream<List<int>> _readBulk(
    StorageLinkResolver resolve,
    int start,
    int end,
    int connections,
    int chunkSize,
    int? expectedSize,
    Queue<_Chunk> pending,
  ) async* {
    final links = _Links(resolve, _maxRefreshes);
    final parallel = connections > 1 && end - start + 1 > chunkSize;
    final first = _Chunk(start, parallel ? start + chunkSize - 1 : end);
    pending.add(first);
    try {
      // Probe with the first request before spending any other connections.
      final response = await _retry(first, () => _openChunk(first, links, expectedSize, allowFull: true));
      if (response.statusCode == HttpStatus.ok || !parallel) {
        final body = first.readBody(response, stallTimeout);
        final source = response.statusCode == HttpStatus.ok ? _slice(body, start, end) : body;
        var remaining = end - start + 1;
        await for (final bytes in source) {
          remaining -= bytes.length;
          if (remaining < 0) {
            throw const StorageException(StorageErrorKind.network, 'Origin sent more bytes than requested');
          }
          yield bytes;
        }
        first.checkCancelled();
        if (remaining != 0) {
          throw const StorageException(StorageErrorKind.network, 'Origin sent fewer bytes than requested');
        }
        return;
      }

      final size = expectedSize ?? _rangeSize(response, first);
      first.bytes = _fetchChunk(first, links, size, opened: response)..ignore();
      var next = first.to + 1;
      while (pending.isNotEmpty) {
        while (pending.length < connections && next <= end) {
          final chunk = _Chunk(next, min(end, next + chunkSize - 1));
          next = chunk.to + 1;
          pending.add(chunk);
          chunk.bytes = _fetchChunk(chunk, links, size)..ignore();
        }
        // Keep the emitted piece in the window until the consumer advances.
        yield await pending.first.bytes!;
        pending.removeFirst().bytes = null;
      }
    } on _Cancelled {
      // Cancelling the subscription also interrupts the awaited request.
    } finally {
      for (final chunk in pending) {
        chunk.cancel();
      }
      pending.clear();
    }
  }

  Future<Uint8List> _fetchChunk(_Chunk chunk, _Links links, int size, {HttpClientResponse? opened}) {
    return _retry(chunk, () async {
      final response = opened ?? await _openChunk(chunk, links, size);
      opened = null;
      final bytes = Uint8List(chunk.length);
      var offset = 0;
      await for (final block in chunk.readBody(response, stallTimeout)) {
        if (block.length > bytes.length - offset) {
          throw const StorageException(StorageErrorKind.network, 'Origin sent more bytes than requested');
        }
        bytes.setRange(offset, offset + block.length, block);
        offset += block.length;
      }
      chunk.checkCancelled();
      if (offset != bytes.length) {
        throw StorageException(
          StorageErrorKind.network,
          'Origin sent $offset of ${chunk.length} bytes at ${chunk.from}',
        );
      }
      return bytes;
    });
  }

  Future<HttpClientResponse> _openChunk(_Chunk chunk, _Links links, int? expectedSize, {bool allowFull = false}) async {
    var link = await chunk.untilCancelled(links.current());
    while (true) {
      final response = await _getBulk(link, chunk);
      final status = response.statusCode;
      try {
        chunk.checkCancelled();
        if (status == HttpStatus.partialContent) {
          final size = _rangeSize(response, chunk);
          if (expectedSize != null && size != expectedSize) {
            throw StorageException(StorageErrorKind.network, 'Origin reported size $size, expected $expectedSize');
          }
          return response;
        }
        if (allowFull && status == HttpStatus.ok) {
          if (expectedSize != null && response.contentLength >= 0 && response.contentLength != expectedSize) {
            throw const StorageException(StorageErrorKind.network, 'Origin reported a different file size');
          }
          return response;
        }
        if (!_staleLinkStatuses.contains(status)) {
          throw StorageException(_kindFor(status), 'Origin answered HTTP $status');
        }
      } catch (_) {
        await response.listen(null).cancel();
        rethrow;
      }
      await response.listen(null).cancel();
      link = await chunk.untilCancelled(links.refresh(link));
    }
  }

  Future<HttpClientResponse> _getBulk(StorageLink link, _Chunk chunk) async {
    // Keep each redirect request abortable as well as the initial one.
    var uri = link.url;
    var headers = link.headers;
    for (var redirects = 0; ; redirects++) {
      final response = await _get(StorageLink(uri, headers: headers), chunk.from, chunk.to, chunk: chunk);
      final location = response.isRedirect ? response.headers.value(HttpHeaders.locationHeader) : null;
      if (location == null) return response;
      await response.listen(null).cancel();
      final target = uri.resolve(location);
      if (redirects >= 5 || !(target.isScheme('http') || target.isScheme('https'))) {
        throw const StorageException(StorageErrorKind.network, 'Invalid origin redirect');
      }
      final canForwardCredentials =
          target.isScheme(uri.scheme) &&
          target.port == uri.port &&
          (target.host == uri.host || target.host.endsWith('.${uri.host}'));
      headers = Map.of(headers)
        ..removeWhere((name, _) {
          final lower = name.toLowerCase();
          return lower == HttpHeaders.hostHeader || (!canForwardCredentials && _credentialHeaders.contains(lower));
        });
      uri = target;
    }
  }

  static const _credentialHeaders = {
    HttpHeaders.authorizationHeader,
    HttpHeaders.proxyAuthorizationHeader,
    HttpHeaders.wwwAuthenticateHeader,
    HttpHeaders.cookieHeader,
    'cookie2',
  };

  static final _rangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$', caseSensitive: false);

  static int _rangeSize(HttpClientResponse response, _Chunk chunk) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null ? null : _rangePattern.firstMatch(value);
    final from = int.tryParse(match?.group(1) ?? '');
    final to = int.tryParse(match?.group(2) ?? '');
    final size = int.tryParse(match?.group(3) ?? '');
    if (from != chunk.from || to != chunk.to || size == null || size <= chunk.to) {
      throw StorageException(StorageErrorKind.network, 'Invalid Content-Range for ${chunk.from}-${chunk.to}: $value');
    }
    return size;
  }

  static Future<T> _retry<T>(_Chunk chunk, Future<T> Function() run) async {
    while (true) {
      chunk.checkCancelled();
      try {
        return await run();
      } on StorageException catch (e) {
        if (!_retryable(e.kind) || ++chunk.failures >= _chunkAttempts) rethrow;
      }
      await chunk.untilCancelled(Future<void>.delayed(Duration(milliseconds: 500 * chunk.failures)));
    }
  }

  static bool _retryable(StorageErrorKind kind) =>
      kind == StorageErrorKind.network || kind == StorageErrorKind.rateLimited || kind == StorageErrorKind.other;

  Future<HttpClientResponse> _get(StorageLink link, int start, int? end, {_Chunk? chunk}) async {
    try {
      chunk?.checkCancelled();
      final opening = _client.getUrl(link.url).then((request) {
        if (chunk?.cancelled ?? false) {
          request.abort();
          throw const _Cancelled();
        }
        return request;
      });
      final request = await (chunk?.untilCancelled(opening) ?? opening);
      if (chunk?.cancelled ?? false) {
        request.abort();
        throw const _Cancelled();
      }
      chunk?.request = request;
      link.headers.forEach(request.headers.set);
      if (start > 0 || end != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end ?? ''}');
      }
      // A ranged body must arrive byte-for-byte; never let the origin compress it.
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (chunk != null) request.followRedirects = false;
      final response = request.close();
      if (chunk == null) return await response;
      try {
        return await response.timeout(
          stallTimeout,
          onTimeout: () {
            final error = TimeoutException('Origin did not send response headers', stallTimeout);
            request.abort(error);
            throw StorageException(StorageErrorKind.network, error.message!, cause: error);
          },
        );
      } finally {
        chunk.request = null;
      }
    } on SocketException catch (e) {
      throw StorageException(StorageErrorKind.network, 'Cannot reach ${link.url.host}', cause: e);
    } on HandshakeException catch (e) {
      throw StorageException(StorageErrorKind.network, 'TLS handshake with ${link.url.host} failed', cause: e);
    } on HttpException catch (e) {
      throw StorageException(StorageErrorKind.network, e.message, cause: e);
    }
  }

  static Stream<List<int>> _slice(Stream<List<int>> source, int start, int? end) async* {
    var offset = 0;
    await for (final chunk in source) {
      final chunkStart = offset;
      offset += chunk.length;
      if (offset <= start) continue;
      final from = start > chunkStart ? start - chunkStart : 0;
      final to = end != null && end + 1 < offset ? end + 1 - chunkStart : chunk.length;
      yield from == 0 && to == chunk.length ? chunk : chunk.sublist(from, to);
      if (end != null && offset > end) return;
    }
  }

  static Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {
      // The body is unwanted either way.
    }
  }

  static StorageErrorKind _kindFor(int status) => switch (status) {
    HttpStatus.unauthorized || HttpStatus.forbidden => StorageErrorKind.unauthorized,
    HttpStatus.notFound || HttpStatus.gone => StorageErrorKind.notFound,
    HttpStatus.tooManyRequests => StorageErrorKind.rateLimited,
    _ => StorageErrorKind.other,
  };
}

/// The link one parallel read shares across its connections. When several
/// connections find the same link refused, only the first asks for a new one.
class _Links {
  _Links(this._resolve, this._maxRefreshes);

  final StorageLinkResolver _resolve;
  final int _maxRefreshes;
  Future<StorageLink>? _current;
  StorageLink? _latest;
  int _refreshes = 0;

  Future<StorageLink> current() => _current ??= _resolve(forceRefresh: false).then(_keep);

  /// A replacement for [stale], requested only if no other connection has
  /// already replaced it.
  Future<StorageLink> refresh(StorageLink stale) {
    if (identical(_latest, stale)) {
      if (++_refreshes > _maxRefreshes) {
        return Future.error(const StorageException(StorageErrorKind.unauthorized, 'Origin keeps refusing the link'));
      }
      _latest = null;
      _current = _resolve(forceRefresh: true).then(_keep);
    }
    return current();
  }

  StorageLink _keep(StorageLink link) => _latest = link;
}

/// One piece of a parallel read, fetched whole into memory.
class _Chunk {
  _Chunk(this.from, this.to);

  final int from;
  final int to;
  Future<Uint8List>? bytes;
  int failures = 0;
  final _cancelled = Completer<void>();
  HttpClientRequest? request;
  StreamIterator<List<int>>? _body;

  bool get cancelled => _cancelled.isCompleted;
  int get length => to - from + 1;

  void checkCancelled() {
    if (cancelled) throw const _Cancelled();
  }

  Future<T> untilCancelled<T>(Future<T> future) =>
      Future.any([future, _cancelled.future.then<T>((_) => throw const _Cancelled())]);

  Stream<List<int>> readBody(HttpClientResponse response, Duration timeout) async* {
    if (cancelled) {
      await response.listen(null).cancel();
      throw const _Cancelled();
    }
    final body = _body = StreamIterator(response.timeout(timeout));
    try {
      checkCancelled();
      while (await body.moveNext()) {
        yield body.current;
      }
      checkCancelled();
    } on Exception catch (e) {
      if (cancelled) return;
      throw StorageException(StorageErrorKind.network, 'Download interrupted at $from: $e', cause: e);
    } finally {
      await body.cancel();
      _body = null;
    }
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
    request?.abort(const _Cancelled());
    unawaited(_body?.cancel());
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
