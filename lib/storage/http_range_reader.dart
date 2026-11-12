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
  HttpRangeReader(this._client, {this.chunkSize = defaultChunkSize});

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
  static const Duration _stallTimeout = Duration(seconds: 30);

  static const Set<int> _staleLinkStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
  };

  /// Reads [start]..[end] (inclusive; [end] null for the rest of the file).
  ///
  /// With [connections] above 1 and a known [end], the span is fetched as
  /// [chunkSize] (default: the reader's) pieces over that many connections at
  /// once and delivered in order. Cloud drives cap each connection's speed, so bulk transfers (the
  /// downloader) go much faster this way; players keep the single connection,
  /// which wastes nothing when they seek.
  Stream<List<int>> read(StorageLinkResolver resolve, {int start = 0, int? end, int connections = 1, int? chunkSize}) {
    final piece = chunkSize ?? this.chunkSize;
    if (connections > 1 && end != null && end - start + 1 > piece) {
      return _readParallel(resolve, start, end, connections, piece);
    }
    return _readSingle(resolve, start, end);
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

  Stream<List<int>> _readParallel(
    StorageLinkResolver resolve,
    int start,
    int end,
    int connections,
    int chunkSize,
  ) async* {
    final links = _Links(resolve, _maxRefreshes);

    // The first piece goes out alone: its answer says whether the origin
    // honours ranges at all, and any failure to open the file surfaces before
    // a single byte is delivered.
    final firstEnd = start + chunkSize - 1;
    var link = await links.current();
    var first = await _get(link, start, firstEnd);
    if (_staleLinkStatuses.contains(first.statusCode)) {
      await _discard(first);
      link = await links.refresh(link);
      first = await _get(link, start, firstEnd);
    }
    switch (first.statusCode) {
      case HttpStatus.partialContent:
        break;
      case HttpStatus.ok:
        // Ranges are ignored, so more connections would each pull the
        // whole file. Stream this one instead.
        yield* _slice(first, start, end);
        return;
      default:
        final status = first.statusCode;
        await _discard(first);
        throw StorageException(_kindFor(status), 'Origin answered HTTP $status');
    }

    final pending = Queue<_Chunk>();
    var next = start;
    void launch(HttpClientResponse? opened) {
      final chunk = _Chunk(next, min(end, next + chunkSize - 1));
      next = chunk.to + 1;
      chunk.bytes = _fetchChunk(chunk, links, opened)..ignore();
      pending.add(chunk);
    }

    void fill() {
      while (pending.length < connections && next <= end) {
        launch(null);
      }
    }

    try {
      launch(first);
      fill();
      while (pending.isNotEmpty) {
        final bytes = await pending.first.bytes;
        pending.removeFirst();
        fill();
        yield bytes;
      }
    } finally {
      for (final chunk in pending) {
        chunk.cancel();
      }
    }
  }

  /// Fetches all of [chunk], retrying transient failures and renewing the
  /// link through [links] when the origin refuses it. [opened] is a response
  /// already requested for this chunk.
  Future<Uint8List> _fetchChunk(_Chunk chunk, _Links links, HttpClientResponse? opened) async {
    var response = opened;
    var attempt = 0;
    while (true) {
      if (chunk.cancelled) {
        if (response != null) unawaited(_discard(response));
        throw const _Cancelled();
      }
      try {
        if (response == null) {
          final link = await links.current();
          response = await _get(link, chunk.from, chunk.to).timeout(_stallTimeout);
          if (_staleLinkStatuses.contains(response.statusCode)) {
            await _discard(response);
            response = null;
            await links.refresh(link);
            continue;
          }
        }
        final status = response.statusCode;
        if (status != HttpStatus.partialContent) {
          await _discard(response);
          throw StorageException(_kindFor(status), 'Origin answered HTTP $status');
        }
        final bytes = await chunk.collect(response);
        if (bytes.length == chunk.length) return bytes;
        throw StorageException(
          StorageErrorKind.network,
          'Origin sent ${bytes.length} of ${chunk.length} bytes at ${chunk.from}',
        );
      } on TimeoutException catch (e) {
        response = null;
        if (chunk.cancelled || ++attempt >= _chunkAttempts) {
          throw StorageException(StorageErrorKind.network, 'Origin stopped answering', cause: e);
        }
      } on StorageException catch (e) {
        response = null;
        if (chunk.cancelled || !_retryable(e.kind) || ++attempt >= _chunkAttempts) rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
  }

  static bool _retryable(StorageErrorKind kind) =>
      kind == StorageErrorKind.network || kind == StorageErrorKind.rateLimited || kind == StorageErrorKind.other;

  Future<HttpClientResponse> _get(StorageLink link, int start, int? end) async {
    try {
      final request = await _client.getUrl(link.url);
      link.headers.forEach(request.headers.set);
      if (start > 0 || end != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end ?? ''}');
      }
      // A ranged body must arrive byte-for-byte; never let the origin compress it.
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      return await request.close();
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
  late final Future<Uint8List> bytes;
  bool cancelled = false;
  StreamSubscription<List<int>>? _subscription;
  Completer<Uint8List>? _done;

  int get length => to - from + 1;

  Future<Uint8List> collect(Stream<List<int>> body) {
    final builder = BytesBuilder(copy: false);
    final done = _done = Completer<Uint8List>();
    _subscription = body
        .timeout(HttpRangeReader._stallTimeout)
        .listen(
          builder.add,
          onError: (Object e, StackTrace st) {
            if (done.isCompleted) return;
            done.completeError(
              e is StorageException
                  ? e
                  : StorageException(StorageErrorKind.network, 'Download interrupted at $from: $e', cause: e),
              st,
            );
          },
          onDone: () {
            if (!done.isCompleted) done.complete(builder.takeBytes());
          },
          cancelOnError: true,
        );
    if (cancelled) cancel();
    return done.future;
  }

  /// Stops the transfer; the connection is dropped rather than drained.
  void cancel() {
    cancelled = true;
    unawaited(_subscription?.cancel());
    final done = _done;
    if (done != null && !done.isCompleted) done.completeError(const _Cancelled());
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
