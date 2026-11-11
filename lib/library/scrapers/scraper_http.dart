import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'scraped_metadata.dart';

/// JSON over HTTP for the metadata providers: one client, an optional proxy,
/// and failures translated into [ScrapeException].
class ScraperHttp {
  ScraperHttp({String? proxy, String? userAgent, HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    if (userAgent != null) _client.userAgent = userAgent;
    final target = proxy?.trim();
    if (target != null && target.isNotEmpty) {
      // "host:port", with or without a scheme in front.
      final hostPort = target.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '').replaceAll(RegExp(r'/+$'), '');
      _client.findProxy = (_) => 'PROXY $hostPort';
    }
  }

  final HttpClient _client;

  /// Sends a request and decodes a JSON object or array. A 404 yields null.
  Future<Object?> json(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
    String service = 'The metadata service',
  }) async {
    final int status;
    final String text;
    try {
      final request = await _client.openUrl(method, url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(const Duration(seconds: 30));
      status = response.statusCode;
      text = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
    } on TimeoutException catch (e) {
      throw ScrapeException('$service did not answer in time', cause: e);
    } on IOException catch (e) {
      throw ScrapeException('Cannot reach ${url.host}', cause: e);
    }

    if (status == HttpStatus.notFound) return null;
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      throw ScrapeException('$service rejected the API key', isConfiguration: true);
    }
    if (status == HttpStatus.tooManyRequests) throw ScrapeException('$service is rate limiting');
    if (status >= 400) throw ScrapeException('$service answered HTTP $status');
    try {
      return jsonDecode(text);
    } on FormatException catch (e) {
      throw ScrapeException('$service sent an unreadable answer', cause: e);
    }
  }

  void close() => _client.close(force: true);
}

/// Null-tolerant readers for decoded JSON.
extension JsonMapReaders on Map<dynamic, dynamic> {
  String? str(String key) {
    final value = this[key];
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is num) return '$value';
    return null;
  }

  int? integer(String key) {
    final value = this[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? number(String key) {
    final value = this[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Map<dynamic, dynamic>? obj(String key) {
    final value = this[key];
    return value is Map ? value : null;
  }

  List<Map<dynamic, dynamic>> objs(String key) {
    final value = this[key];
    return value is List ? value.whereType<Map<dynamic, dynamic>>().toList() : const [];
  }
}

/// The year of a `YYYY-MM-DD` date.
int? yearOfDate(String? date) {
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}
