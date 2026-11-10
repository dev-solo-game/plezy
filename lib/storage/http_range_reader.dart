import 'dart:async';
import 'dart:io';

import 'storage_driver.dart';

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
  HttpRangeReader(this._client);

  final HttpClient _client;

  static const Set<int> _staleLinkStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
  };

  Stream<List<int>> read(StorageLinkResolver resolve, {int start = 0, int? end}) async* {
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
