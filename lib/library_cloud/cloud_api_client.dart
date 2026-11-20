import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Structured exception for `media_library` `/api/v1/*` responses.
class CloudApiException implements Exception {
  const CloudApiException({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.rawBody,
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final Map<String, dynamic>? rawBody;

  bool get isUnauthorized => statusCode == HttpStatus.unauthorized;
  bool get isForbidden => statusCode == HttpStatus.forbidden;
  bool get isNotFound => statusCode == HttpStatus.notFound;
  bool get isConflict => statusCode == HttpStatus.conflict;
  bool get isUpgradeRequired => statusCode == HttpStatus.upgradeRequired;
  bool get isSourceKindDisallowed => errorCode == 'source_kind_not_allowed_on_device';
  bool get isDuplicateSource => errorCode == 'source_already_exists';

  String? get existingSourceId => rawBody?['existing_source_id'] as String?;

  @override
  String toString() => 'CloudApiException($statusCode, $errorCode): $message';
}

/// Typed HTTP client for `media_library` v1 endpoints.
class CloudApiClient {
  CloudApiClient({
    required String baseUrl,
    required this.accessToken,
    http.Client? httpClient,
    String? clientPlatform,
    this.protocolVersion = 1,
  }) : baseUrl = _normalizeBase(baseUrl),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _clientPlatform = clientPlatform ?? Platform.operatingSystem;

  final String baseUrl;
  final String accessToken;
  final http.Client _http;
  final bool _ownsClient;
  final String _clientPlatform;
  final int protocolVersion;
  bool _closed = false;

  static String _normalizeBase(String raw) {
    var s = raw.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri buildUri(String path, [Map<String, String>? query]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$baseUrl$normalizedPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Map<String, String> _baseHeaders({bool jsonContent = false, bool gzipBody = false}) => {
    'accept': 'application/json',
    'authorization': 'Bearer $accessToken',
    'x-ttplay-client': 'plezy/$_clientPlatform/$protocolVersion',
    if (jsonContent) 'content-type': 'application/json; charset=utf-8',
    if (gzipBody) 'content-encoding': 'gzip',
  };

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) => _requestJson('GET', path, query: query, timeout: timeout);

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    bool gzipBody = false,
    Duration timeout = const Duration(seconds: 30),
  }) => _requestJson('POST', path, body: body, query: query, gzipBody: gzipBody, timeout: timeout);

  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 30),
  }) => _requestJson('PUT', path, body: body, query: query, timeout: timeout);

  Future<Map<String, dynamic>> patchJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 30),
  }) => _requestJson('PATCH', path, body: body, query: query, timeout: timeout);

  Future<Map<String, dynamic>> deleteJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) => _requestJson('DELETE', path, body: body, query: query, timeout: timeout);

  Future<bool> headExists(String path, {Duration timeout = const Duration(seconds: 15)}) async {
    _ensureOpen();
    final req = http.Request('HEAD', buildUri(path))..headers.addAll(_baseHeaders());
    final streamed = await _http.send(req).timeout(timeout);
    await streamed.stream.drain<void>();
    if (streamed.statusCode == HttpStatus.ok) return true;
    if (streamed.statusCode == HttpStatus.notFound) return false;
    throw CloudApiException(
      statusCode: streamed.statusCode,
      errorCode: 'http_${streamed.statusCode}',
      message: 'HEAD $path failed (${streamed.statusCode})',
    );
  }

  Future<void> putRawBytes(
    String path, {
    required List<int> bytes,
    required String contentType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _ensureOpen();
    final req = http.Request('PUT', buildUri(path))
      ..headers.addAll(_baseHeaders())
      ..headers['content-type'] = contentType
      ..bodyBytes = bytes;
    final streamed = await _http.send(req).timeout(timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    _throwForResponse(resp);
  }

  Future<http.StreamedResponse> openEventStream(String path) async {
    _ensureOpen();
    final req = http.Request('GET', buildUri(path))
      ..headers.addAll(_baseHeaders())
      ..headers['accept'] = 'text/event-stream';
    return _http.send(req);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool gzipBody = false,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    _ensureOpen();
    final req = http.Request(method, buildUri(path, query))
      ..headers.addAll(_baseHeaders(jsonContent: body != null, gzipBody: body != null && gzipBody));
    if (body != null) {
      final raw = utf8.encode(jsonEncode(body));
      req.bodyBytes = gzipBody ? gzip.encode(raw) : raw;
    }

    final streamed = await _http.send(req).timeout(timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _throwForResponse(resp);
    }
    if (resp.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return const {};
  }

  Never _throwForResponse(http.Response resp) {
    Map<String, dynamic>? map;
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map) map = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final errCode = (map?['error'] as String?) ?? 'http_${resp.statusCode}';
    final msg = (map?['message'] as String?) ?? (map?['error'] as String?) ?? 'HTTP ${resp.statusCode}';
    throw CloudApiException(
      statusCode: resp.statusCode,
      errorCode: errCode,
      message: msg,
      rawBody: map,
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('CloudApiClient is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _http.close();
    }
  }
}
