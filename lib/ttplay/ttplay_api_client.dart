import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../exceptions/media_server_exceptions.dart';
import '../media/media_server_client.dart' show HealthStatus;
import '../session/app_session_models.dart';
import '../utils/media_server_http_client.dart' show AbortController;

/// External Emby or Jellyfin server registered on a self-hosted `ttplay-server`.
class TtplayExternalServerSummary {
  const TtplayExternalServerSummary({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.authMode,
    required this.username,
    required this.userId,
    required this.serverId,
    required this.serverVersion,
    required this.allowInsecureTls,
    required this.hasToken,
    required this.enabled,
  });

  final String id;
  final String name;
  final String kind; // emby | jellyfin
  final String baseUrl;
  final String authMode; // password | apikey
  final String username;
  final String userId;
  final String serverId;
  final String serverVersion;
  final bool allowInsecureTls;
  final bool hasToken;
  final bool enabled;

  factory TtplayExternalServerSummary.fromJson(Map<String, dynamic> json) => TtplayExternalServerSummary(
    id: ttplayString(json['id']) ?? '',
    name: ttplayString(json['name']) ?? '',
    kind: (ttplayString(json['kind']) ?? 'jellyfin').toLowerCase(),
    baseUrl: ttplayString(json['base_url']) ?? '',
    authMode: (ttplayString(json['auth_mode']) ?? 'password').toLowerCase(),
    username: ttplayString(json['username']) ?? '',
    userId: ttplayString(json['user_id']) ?? '',
    serverId: ttplayString(json['server_id']) ?? '',
    serverVersion: ttplayString(json['server_version']) ?? '',
    allowInsecureTls: json['allow_insecure_tls'] == true,
    hasToken: json['has_token'] == true,
    enabled: json['enabled'] != false,
  );
}

/// Shared authenticated JSON transport and URL helpers for `ttplay-server`.
class TtplayApiClient {
  TtplayApiClient({required String baseUrl, required this.accessToken, http.Client? httpClient})
    : baseUrl = SelfHostedSession.normalizeServerUrl(baseUrl),
      _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final String baseUrl;
  final String accessToken;
  final http.Client _httpClient;
  final bool _ownsClient;
  bool _closed = false;

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$baseUrl$normalizedPath');
    if (query == null || query.isEmpty) return uri;
    final cleanQuery = <String, String>{
      ...uri.queryParameters,
      for (final entry in query.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    return uri.replace(queryParameters: cleanQuery.isEmpty ? null : cleanQuery);
  }

  Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query, AbortController? abort}) =>
      _requestJson('GET', path, query: query, abort: abort);

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    AbortController? abort,
  }) => _requestJson('POST', path, query: query, body: body, abort: abort);

  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    AbortController? abort,
  }) => _requestJson('PUT', path, query: query, body: body, abort: abort);

  Future<Map<String, dynamic>> deleteJson(String path, {Map<String, String>? query, AbortController? abort}) =>
      _requestJson('DELETE', path, query: query, abort: abort);

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    AbortController? abort,
  }) async {
    abort?.throwIfAborted();
    if (_closed) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'Client closed');
    }

    final uri = _buildUri(path, query);
    final req = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $accessToken'
      ..headers['accept'] = 'application/json';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final http.StreamedResponse streamed;
    try {
      final sendFuture = _httpClient.send(req).timeout(const Duration(seconds: 25));
      if (abort != null) {
        streamed = await Future.any([
          sendFuture,
          abort.trigger.then<http.StreamedResponse>((_) {
            throw MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'Operation cancelled');
          }),
        ]);
      } else {
        streamed = await sendFuture;
      }
    } catch (e) {
      if (e is MediaServerException) rethrow;
      throw MediaServerHttpException.from(e, uri: uri);
    }

    abort?.throwIfAborted();

    final String text;
    try {
      text = await streamed.stream.bytesToString().timeout(const Duration(seconds: 30));
    } catch (e) {
      throw MediaServerHttpException.from(e, uri: uri);
    }

    abort?.throwIfAborted();

    Map<String, dynamic>? decoded;
    if (text.trim().isNotEmpty) {
      try {
        final raw = jsonDecode(text);
        if (raw is Map) {
          decoded = Map<String, dynamic>.from(raw);
        }
      } catch (e) {
        if (streamed.statusCode < 400) {
          throw MediaServerHttpException(
            type: MediaServerHttpErrorType.unknown,
            statusCode: streamed.statusCode,
            message: 'Invalid JSON response: $e',
            requestUri: uri,
          );
        }
      }
    }

    final status = streamed.statusCode;
    final errorMsg = ttplayString(decoded?['error']) ?? ttplayString(decoded?['message']);
    if (status == HttpStatus.unauthorized) {
      throw MediaServerAuthException(errorMsg ?? 'Unauthorized', statusCode: status);
    }
    if (status >= 400) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: status,
        message: errorMsg ?? 'HTTP $status',
        responseData: decoded ?? text,
        requestUri: uri,
      );
    }

    if (decoded == null) {
      return const <String, dynamic>{};
    }

    final code = ttplayInt(decoded['code']);
    if (code != null && code != 0) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: status,
        message: errorMsg ?? 'Server error code $code',
        responseData: decoded,
        requestUri: uri,
      );
    }
    return decoded;
  }

  /// Resolves a server-relative URL against [baseUrl], optionally appending
  /// `token=` in query parameters when not already signed.
  String resolveAbsoluteUrl(String relativeOrFull, {bool appendToken = false}) {
    final trimmed = relativeOrFull.trim();
    if (trimmed.isEmpty) return '';
    final full = trimmed.startsWith('/') ? '$baseUrl$trimmed' : trimmed;
    if (!appendToken || accessToken.isEmpty) return full;
    final uri = Uri.tryParse(full);
    if (uri == null || uri.queryParameters.containsKey('token')) return full;
    final query = <String, String>{...uri.queryParameters, 'token': accessToken};
    return uri.replace(queryParameters: query).toString();
  }

  Future<HealthStatus> checkHealth() async {
    try {
      await getJson('/api/v1/auth/me');
      return HealthStatus.online;
    } on MediaServerAuthException {
      return HealthStatus.authError;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == HttpStatus.unauthorized) return HealthStatus.authError;
      if (e.statusCode == HttpStatus.forbidden) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  Future<List<TtplayExternalServerSummary>> fetchExternalServers() async {
    final resp = await getJson('/api/v1/ext-servers');
    final raw = resp['servers'];
    if (raw is! List) return const [];
    return [for (final item in raw) ?(item is Map ? TtplayExternalServerSummary.fromJson(Map<String, dynamic>.from(item)) : null)];
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}

String? ttplayString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? ttplayInt(Object? value) => switch (value) {
  final int i => i,
  final num n => n.toInt(),
  final String s => int.tryParse(s.trim()),
  _ => null,
};

double? ttplayDouble(Object? value) => switch (value) {
  final double d => d,
  final num n => n.toDouble(),
  final String s => double.tryParse(s.trim()),
  _ => null,
};

Map<String, dynamic>? ttplayMap(Object? value) => value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> ttplayMapList(Object? value) {
  if (value is! List) return const [];
  return [for (final item in value) if (item is Map) Map<String, dynamic>.from(item)];
}
