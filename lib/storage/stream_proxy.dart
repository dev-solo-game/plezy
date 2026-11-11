import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../utils/app_logger.dart';
import 'storage_driver.dart';
import 'storage_path.dart';

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
  StreamProxy({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, _Source> _sources = {};
  final Map<String, String> _tokensByKey = {};
  HttpServer? _server;
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
  Future<Uri> register({required String mountId, required StorageDriver driver, required StorageEntry entry}) async {
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
      pathSegments: ['s', token, entry.name],
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

  /// Forgets every file registered for [mountId], e.g. when the mount is
  /// removed or its driver is rebuilt with new credentials.
  void unregisterMount(String mountId) {
    final prefix = '$mountId\u0000';
    final keys = _tokensByKey.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      _sources.remove(_tokensByKey.remove(key));
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
      final source = segments.length >= 2 && segments[0] == 's' ? _sources[segments[1]] : null;
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
      final chunks = wantsBody
          ? StreamIterator(source.driver.openRead(entry, start: start, end: range == null ? null : end))
          : null;
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
    _tokensByKey.clear();
    await server?.close(force: true);
  }
}

class _Source {
  _Source(this.driver, this.entry);

  final StorageDriver driver;
  StorageEntry entry;
}
