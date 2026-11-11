import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/app_logger.dart';
import 'http_range_reader.dart';
import 'storage_driver.dart';
import 'storage_path.dart';
import 'stream_variant.dart';

/// Serves mounted files to players over loopback HTTP.
///
/// Players, the downloader and external apps only understand URLs, while
/// drivers speak SMB, need cookies, or hand out links that expire. The proxy
/// gives every file a plain `http://127.0.0.1:port/...` address with Range
/// support and leaves the rest to the driver.
///
/// It binds to loopback only, and each URL carries an unguessable token, so
/// other devices cannot reach it and other local processes cannot enumerate it.
class StreamProxy {
  StreamProxy({Random? random, BulkReadOptions Function()? bulkOptions})
    : _random = random ?? Random.secure(),
      _bulkOptions = bulkOptions ?? (() => BulkReadOptions.defaults);

  final Random _random;

  /// Read per bulk request, so a changed setting applies to the next one.
  final BulkReadOptions Function() _bulkOptions;
  final Map<String, _Source> _sources = {};
  final Map<String, _VariantSource> _variants = {};
  final Map<String, String> _tokensByKey = {};
  HttpServer? _server;
  HttpClient? _upstream;

  HttpClient get _upstreamClient => _upstream ??= HttpClient()..connectionTimeout = const Duration(seconds: 15);
  Future<HttpServer>? _starting;

  bool get isRunning => _server != null;

  /// Starts listening. Safe to call repeatedly and concurrently.
  Future<void> start() async {
    await _ensureServer();
  }

  Future<HttpServer> _ensureServer() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= () async {
      try {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.autoCompress = false;
        _server = server;
        unawaited(_serve(server));
        return server;
      } finally {
        _starting = null;
      }
    }();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  /// Returns a loopback URL for [entry] on [driver], starting the server if
  /// needed. Registering the same file of the same mount again returns the
  /// same URL, so a resumed playback keeps hitting one address.
  ///
  /// [mountId] only namespaces the registration; it never appears in the URL.
  ///
  /// A [bulk] URL is for whole-file transfers (the downloader): drivers that
  /// can are read over several connections at once (see `bulkOptions`). Players get the
  /// plain URL, which keeps one connection and wastes nothing on a seek.
  Future<Uri> register({
    required String mountId,
    required StorageDriver driver,
    required StorageEntry entry,
    bool bulk = false,
  }) async {
    if (entry.isDirectory) {
      throw const StorageException(StorageErrorKind.unsupported, 'Cannot stream a directory');
    }
    final server = await _ensureServer();
    final key = '$mountId\u0000${entry.path}';
    final token = _tokensByKey.putIfAbsent(key, _newToken);
    _sources[token] = _Source(driver, entry);
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      // The file name is cosmetic: it lets players sniff the container from
      // the extension and show a sensible title.
      pathSegments: [bulk ? 'd' : 's', token, entry.name],
    );
  }

  /// A loopback URL for [path] on [driver], without touching the driver: the
  /// file's size is looked up when the URL is first requested. Synchronous,
  /// for callers that must produce a URL on the spot (image widgets). Returns
  /// null until [start] has completed.
  Uri? urlForPath({required String mountId, required StorageDriver driver, required String path}) {
    final server = _server;
    if (server == null) return null;
    final normalized = StoragePath.normalize(path);
    final key = '$mountId\u0000$normalized';
    final token = _tokensByKey.putIfAbsent(key, _newToken);
    _sources.putIfAbsent(
      token,
      () => _Source(driver, StorageEntry(path: normalized, name: StoragePath.name(normalized), isDirectory: false)),
    );
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['s', token, StoragePath.name(normalized)],
    );
  }

  /// Returns a loopback URL for the [variant] rendition of [entry], served
  /// from the backend's own transcode through [source].
  ///
  /// The origin's links expire and need headers players cannot send, so the
  /// proxy forwards every request with those headers, renews the link when
  /// the origin refuses it, and points the segments of an HLS playlist back
  /// at itself.
  Future<Uri> registerVariant({
    required String mountId,
    required StreamVariantSource source,
    required StorageEntry entry,
    required StreamVariant variant,
  }) async {
    final server = await _ensureServer();
    final key = '$mountId\u0000${entry.path}\u0000${variant.id}';
    final token = _tokensByKey.putIfAbsent(key, _newToken);
    final registered = _variants[token] ??= _VariantSource(source, entry, variant.id);
    registered.current = variant;
    final stem = entry.name.contains('.') ? entry.name.substring(0, entry.name.lastIndexOf('.')) : entry.name;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      // The extension tells players that pick a demuxer by name (ExoPlayer)
      // whether this is a playlist.
      pathSegments: ['v', token, '$stem.${variant.isHls ? 'm3u8' : 'mp4'}'],
    );
  }

  /// Forgets every file registered for [mountId], e.g. when the mount is
  /// removed or its driver is rebuilt with new credentials.
  void unregisterMount(String mountId) {
    final prefix = '$mountId\u0000';
    final keys = _tokensByKey.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      final token = _tokensByKey.remove(key);
      _sources.remove(token);
      _variants.remove(token);
    }
  }

  String _newToken() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return await _finish(response, HttpStatus.methodNotAllowed);
      }
      final segments = request.uri.pathSegments;
      if (segments.length >= 2 && segments[0] == 'v') {
        final variant = _variants[segments[1]];
        if (variant == null) return await _finish(response, HttpStatus.notFound);
        return await _handleVariant(request, variant, segments);
      }
      final bulk = segments.isNotEmpty && segments[0] == 'd';
      final source = segments.length >= 2 && (segments[0] == 's' || bulk) ? _sources[segments[1]] : null;
      if (source == null) return await _finish(response, HttpStatus.notFound);

      var entry = source.entry;
      if (entry.size == null) {
        // Range arithmetic needs the length; ask the driver once and keep it.
        entry = await source.driver.stat(entry.path);
        source.entry = entry;
      }
      final size = entry.size;
      if (size == null) return await _finish(response, HttpStatus.badGateway);

      final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader), size);
      if (range == _unsatisfiable) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        return await _finish(response, HttpStatus.requestedRangeNotSatisfiable);
      }

      final start = range?.start ?? 0;
      final end = range?.end ?? size - 1;
      final length = size == 0 ? 0 : end - start + 1;

      final wantsBody = request.method == 'GET' && length > 0;
      // Pull the first chunk before committing the status line, so a failure
      // to open the file at all (expired cookie, deleted file) reaches the
      // player as an HTTP error instead of a truncated 200.
      final driver = source.driver;
      final bulkOptions = bulk ? _bulkOptions() : null;
      final chunks = !wantsBody
          ? null
          : StreamIterator(
              bulkOptions != null && driver is ParallelReadSource
                  ? (driver as ParallelReadSource).openReadParallel(
                      entry,
                      start: start,
                      end: end,
                      connections: bulkOptions.connections,
                      chunkSize: bulkOptions.chunkSize,
                    )
                  : driver.openRead(entry, start: start, end: range == null ? null : end),
            );
      try {
        final hasFirst = chunks != null && await chunks.moveNext();

        response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentTypeHeader, _contentType(entry.name))
          ..contentLength = length;
        if (range != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
        }
        if (chunks != null && hasFirst) {
          // From here a driver failure can only be signalled by dropping the
          // connection, which players answer by reconnecting with a new Range.
          await response.addStream(_remaining(chunks));
        }
        await response.close();
      } finally {
        await chunks?.cancel();
      }
    } on StorageException catch (e) {
      appLogger.w('Stream proxy: ${e.message}');
      await _fail(response, _statusFor(e.kind));
    } catch (e) {
      // A player closing the socket mid-stream lands here too; that is routine.
      appLogger.d('Stream proxy request ended early: $e');
      await _fail(response, HttpStatus.badGateway);
    }
  }

  /// Origin answers that mean the link or its cookie went stale. 412 is what
  /// Quark's CDN sends once the play cookie has expired.
  static const Set<int> _staleStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
    HttpStatus.preconditionFailed,
  };

  /// Largest playlist the proxy reads into memory to rewrite.
  static const int _maxPlaylistBytes = 8 * 1024 * 1024;

  /// Serves `/v/<token>/<name>` (the rendition itself) and
  /// `/v/<token>/r/<n>/<name>` (the n-th URL a playlist of it referred to).
  Future<void> _handleVariant(HttpRequest request, _VariantSource source, List<String> segments) async {
    final response = request.response;
    Uri? resource;
    if (segments.length >= 4 && segments[2] == 'r') {
      final index = int.tryParse(segments[3]);
      if (index == null || index < 0 || index >= source.resources.length) {
        return _finish(response, HttpStatus.notFound);
      }
      resource = source.resources[index];
    }

    Future<(HttpClientResponse, Uri)> fetch({required bool refresh}) async {
      final variant = await source.variant(forceRefresh: refresh);
      final target = resource ?? variant.url;
      try {
        final upstream = await _upstreamClient.openUrl(request.method, target);
        variant.headers.forEach(upstream.headers.set);
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
        upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final answer = await upstream.close().timeout(const Duration(seconds: 30));
        final redirects = answer.redirects;
        return (answer, redirects.isEmpty ? target : target.resolveUri(redirects.last.location));
      } on SocketException catch (e) {
        throw StorageException(StorageErrorKind.network, 'Cannot reach ${target.host}', cause: e);
      } on TimeoutException catch (e) {
        throw StorageException(StorageErrorKind.network, '${target.host} timed out', cause: e);
      } on HttpException catch (e) {
        throw StorageException(StorageErrorKind.network, e.message, cause: e);
      }
    }

    var (upstream, finalUrl) = await fetch(refresh: false);
    if (_staleStatuses.contains(upstream.statusCode)) {
      await upstream.drain<void>().catchError((Object _) {});
      (upstream, finalUrl) = await fetch(refresh: true);
    }
    final status = upstream.statusCode;
    if (status >= 400) {
      await upstream.drain<void>().catchError((Object _) {});
      appLogger.w('Stream proxy: rendition ${source.variantId} answered HTTP $status');
      return _finish(response, status == HttpStatus.notFound ? HttpStatus.notFound : HttpStatus.badGateway);
    }

    final contentType = upstream.headers.contentType?.mimeType.toLowerCase() ?? '';
    final isPlaylist = contentType.contains('mpegurl') || finalUrl.path.toLowerCase().endsWith('.m3u8');
    if (isPlaylist) {
      final bytes = <int>[];
      await for (final chunk in upstream) {
        bytes.addAll(chunk);
        if (bytes.length > _maxPlaylistBytes) {
          throw const StorageException(StorageErrorKind.other, 'Playlist too large');
        }
      }
      final server = _server!;
      final token = segments[1];
      final text = rewritePlaylist(utf8.decode(bytes, allowMalformed: true), finalUrl, (uri) {
        final name = uri.pathSegments.isEmpty ? 'resource' : uri.pathSegments.last;
        return Uri(
          scheme: 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          pathSegments: ['v', token, 'r', '${source.indexOf(uri)}', if (name.isEmpty) 'resource' else name],
        ).toString();
      });
      final body = utf8.encode(text);
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache')
        ..contentLength = body.length;
      if (request.method == 'GET') response.add(body);
      return response.close();
    }

    response.statusCode = status;
    for (final name in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
    if (upstream.contentLength >= 0) response.headers.contentLength = upstream.contentLength;
    if (request.method == 'GET') {
      await response.addStream(upstream);
    } else {
      await upstream.drain<void>().catchError((Object _) {});
    }
    await response.close();
  }

  /// [playlist] with every URL it refers to — media lines and `URI="…"`
  /// attributes alike — resolved against [base] and passed through [proxied].
  /// Only http(s) URLs are rewritten; anything else is left as it is.
  @visibleForTesting
  static String rewritePlaylist(String playlist, Uri base, String Function(Uri url) proxied) {
    String rewrite(String reference) {
      final resolved = base.resolve(reference.trim());
      return resolved.scheme == 'http' || resolved.scheme == 'https' ? proxied(resolved) : reference;
    }

    final attribute = RegExp(r'URI="([^"]*)"');
    final out = StringBuffer();
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.writeln(line);
      } else if (trimmed.startsWith('#')) {
        out.writeln(line.replaceAllMapped(attribute, (m) => 'URI="${rewrite(m[1]!)}"'));
      } else {
        out.writeln(rewrite(trimmed));
      }
    }
    return out.toString();
  }

  /// The chunk [chunks] is positioned on, followed by the rest of the stream.
  static Stream<List<int>> _remaining(StreamIterator<List<int>> chunks) async* {
    do {
      yield chunks.current;
    } while (await chunks.moveNext());
  }

  static Future<void> _finish(HttpResponse response, int status) async {
    response.statusCode = status;
    response.contentLength = 0;
    await response.close();
  }

  /// Reports [status] when nothing has been sent yet; otherwise tears the
  /// connection down so the client does not mistake a short body for the file.
  static Future<void> _fail(HttpResponse response, int status) async {
    try {
      response.statusCode = status;
      response.contentLength = 0;
      await response.close();
    } catch (_) {
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        // Already gone.
      }
    }
  }

  static int _statusFor(StorageErrorKind kind) => switch (kind) {
    StorageErrorKind.notFound => HttpStatus.notFound,
    StorageErrorKind.unauthorized => HttpStatus.forbidden,
    StorageErrorKind.rateLimited => HttpStatus.serviceUnavailable,
    StorageErrorKind.network => HttpStatus.gatewayTimeout,
    StorageErrorKind.unsupported => HttpStatus.notImplemented,
    StorageErrorKind.other => HttpStatus.badGateway,
  };

  static const ({int start, int end}) _unsatisfiable = (start: -1, end: -1);

  /// Parses a single-range `Range` header against [size]. Returns null when
  /// the header is absent or not understood (serve the whole file), or
  /// [_unsatisfiable] when it lies outside the file.
  static ({int start, int end})? _parseRange(String? header, int size) {
    if (header == null) return null;
    final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
    if (match == null) return null;
    final first = match.group(1)!;
    final last = match.group(2)!;
    if (first.isEmpty && last.isEmpty) return null;
    if (size == 0) return _unsatisfiable;

    if (first.isEmpty) {
      // Suffix range: the final N bytes.
      final suffix = int.tryParse(last);
      if (suffix == null || suffix == 0) return _unsatisfiable;
      return (start: suffix >= size ? 0 : size - suffix, end: size - 1);
    }
    final start = int.tryParse(first);
    if (start == null || start >= size) return _unsatisfiable;
    final requestedEnd = last.isEmpty ? null : int.tryParse(last);
    if (requestedEnd != null && requestedEnd < start) return _unsatisfiable;
    return (start: start, end: requestedEnd == null || requestedEnd >= size ? size - 1 : requestedEnd);
  }

  static String _contentType(String name) => switch (StoragePath.extension(name)) {
    'mkv' => 'video/x-matroska',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    'webm' => 'video/webm',
    'ts' || 'm2ts' || 'mts' => 'video/mp2t',
    'wmv' => 'video/x-ms-wmv',
    'flv' => 'video/x-flv',
    'mpg' || 'mpeg' => 'video/mpeg',
    'rmvb' || 'rm' => 'application/vnd.rn-realmedia-vbr',
    'mp3' => 'audio/mpeg',
    'flac' => 'audio/flac',
    'm4a' || 'aac' => 'audio/mp4',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'srt' => 'application/x-subrip',
    'ass' || 'ssa' => 'text/x-ssa',
    'vtt' => 'text/vtt',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'nfo' || 'xml' => 'application/xml',
    _ => 'application/octet-stream',
  };

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _sources.clear();
    _variants.clear();
    _tokensByKey.clear();
    _upstream?.close(force: true);
    _upstream = null;
    await server?.close(force: true);
  }
}

/// A rendition registered with the proxy, and the URLs its playlists have
/// referred to so far. Segments are addressed by their index in
/// [resources], so a proxy URL can only ever reach what the origin's own
/// playlist pointed at.
class _VariantSource {
  _VariantSource(this.source, this.entry, this.variantId);

  final StreamVariantSource source;
  final StorageEntry entry;
  final String variantId;
  StreamVariant? current;
  final List<Uri> resources = [];
  final Map<Uri, int> _indexes = {};

  Future<StreamVariant> variant({required bool forceRefresh}) async {
    final known = current;
    if (!forceRefresh && known != null) return known;
    final offered = await source.streamVariants(entry, forceRefresh: forceRefresh);
    for (final variant in offered) {
      if (variant.id == variantId) return current = variant;
    }
    throw StorageException(StorageErrorKind.notFound, 'Rendition $variantId is no longer offered');
  }

  int indexOf(Uri url) => _indexes.putIfAbsent(url, () {
    resources.add(url);
    return resources.length - 1;
  });
}

class _Source {
  _Source(this.driver, this.entry);

  final StorageDriver driver;
  StorageEntry entry;
}
