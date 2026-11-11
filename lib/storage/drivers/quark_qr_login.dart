import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../storage_driver.dart';

/// A pending QR login: [qrContent] is what the QR image must encode for the
/// Quark mobile app to recognise it.
class QuarkQrTicket {
  const QuarkQrTicket({required this.token, required this.qrContent});

  final String token;
  final String qrContent;
}

sealed class QuarkQrStatus {
  const QuarkQrStatus();
}

/// Nobody has confirmed the login on a phone yet.
class QuarkQrWaiting extends QuarkQrStatus {
  const QuarkQrWaiting();
}

/// The QR code is no longer valid; a new ticket is needed.
class QuarkQrExpired extends QuarkQrStatus {
  const QuarkQrExpired();
}

/// Login confirmed. [cookie] is the secret the mount stores for the drive
/// API: a `Cookie` header value in web mode, or the desktop session string in
/// PC mode.
class QuarkQrSuccess extends QuarkQrStatus {
  const QuarkQrSuccess(this.cookie);

  final String cookie;
}

/// A QR sign-in flow the login dialog can drive, whichever Quark client it
/// signs in as.
abstract interface class QuarkQrAuthenticator {
  Future<QuarkQrTicket> start();
  Future<QuarkQrStatus> poll(QuarkQrTicket ticket);
  void close();
}

/// Signs in to Quark the way pan.quark.cn does: show a QR code, wait for the
/// mobile app to confirm it, then trade the resulting service ticket for the
/// session cookies the drive API expects.
class QuarkQrLogin implements QuarkQrAuthenticator {
  QuarkQrLogin({HttpClient? httpClient, Uri? casBase, Uri? panBase, String allowedCookieHostSuffix = 'quark.cn'})
    : _client = httpClient ?? HttpClient(),
      _cookieHostSuffix = allowedCookieHostSuffix,
      _casBase = casBase ?? Uri.parse('https://uop.quark.cn'),
      _panBase = panBase ?? Uri.parse('https://pan.quark.cn') {
    _client
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
  }

  static const String _clientId = '532';
  static const String _apiVersion = '1.2';
  static const int _statusOk = 2000000;

  /// Poll answers that end the attempt: the code expired, was declined, or was
  /// rejected by the phone. Everything else short of success means "keep
  /// waiting".
  static const Set<int> _failedStatuses = {50004002, 50004003, 50004004};
  static const int _maxRedirects = 5;
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  final HttpClient _client;
  final Uri _casBase;
  final Uri _panBase;

  /// Hosts ending in this suffix receive the session's cookies, and redirects
  /// are only followed to them. Overridable so tests can run against loopback.
  final String _cookieHostSuffix;

  /// Cookies gathered over one login attempt, like a browser session: the
  /// sign-in servers set some when the code is issued and expect them back.
  final Map<String, String> _cookies = {};

  @override
  Future<QuarkQrTicket> start() async {
    _cookies.clear();
    final json = await _getJson(
      _casBase.replace(
        path: '/cas/ajax/getTokenForQrcodeLogin',
        queryParameters: {'client_id': _clientId, 'v': _apiVersion, 'request_id': const Uuid().v4()},
      ),
    );
    final token = _members(json)?['token'];
    if (json['status'] != _statusOk || token is! String || token.isEmpty) {
      throw StorageException(StorageErrorKind.other, 'Quark did not issue a QR code: ${json['message']}');
    }
    return QuarkQrTicket(token: token, qrContent: qrContentFor(token));
  }

  /// The URL the Quark app expects inside the QR code.
  ///
  /// Assembled by hand because the app is strict about its shape: `Uri`
  /// drops the `=` of the empty `uc_param_str`, and the app then rejects the
  /// code as expired.
  static String qrContentFor(String token) {
    const bizOptions = 'S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
    return 'https://su.quark.cn/4_eMHBJ'
        '?token=${Uri.encodeQueryComponent(token)}'
        '&client_id=$_clientId'
        '&ssb=weblogin'
        '&uc_param_str='
        '&uc_biz_str=${Uri.encodeQueryComponent(bizOptions)}';
  }

  /// Checks once whether [ticket] has been confirmed.
  @override
  Future<QuarkQrStatus> poll(QuarkQrTicket ticket) async {
    final json = await _getJson(
      _casBase.replace(
        path: '/cas/ajax/getServiceTicketByQrcodeToken',
        queryParameters: {
          'client_id': _clientId,
          'v': _apiVersion,
          'token': ticket.token,
          // A fresh id per call, as the web client sends.
          'request_id': const Uuid().v4(),
        },
      ),
    );
    final status = json['status'];
    if (status == _statusOk) {
      final serviceTicket = _members(json)?['service_ticket'];
      if (serviceTicket is! String || serviceTicket.isEmpty) {
        throw StorageException(StorageErrorKind.other, 'Quark QR login failed: ${json['message']}');
      }
      return QuarkQrSuccess(await _exchange(serviceTicket));
    }
    return _failedStatuses.contains(status) ? const QuarkQrExpired() : const QuarkQrWaiting();
  }

  /// Trades the service ticket for cookies, following redirects by hand so
  /// cookies set along the way are kept.
  Future<String> _exchange(String serviceTicket) async {
    var url = _panBase.replace(path: '/account/info', queryParameters: {'st': serviceTicket, 'lw': 'scan'});
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final response = await _send(url, followRedirects: false);
      await response.drain<void>().catchError((Object _) {});
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (!response.isRedirect || location == null) break;
      final next = url.resolve(location);
      // Session cookies must not follow a redirect off Quark's own hosts.
      if (!next.host.endsWith(_cookieHostSuffix)) break;
      url = next;
    }
    if (!_cookies.containsKey('__pus')) {
      throw const StorageException(
        StorageErrorKind.unauthorized,
        'Quark confirmed the login but sent no session cookie',
      );
    }
    return _cookieHeader();
  }

  String _cookieHeader() => _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  static Map<String, dynamic>? _members(Map<String, dynamic> json) {
    final data = json['data'];
    final members = data is Map ? data['members'] : null;
    return members is Map<String, dynamic> ? members : null;
  }

  /// One GET carrying the session's cookies and browser-like headers; cookies
  /// the response sets are added to the session.
  Future<HttpClientResponse> _send(Uri url, {bool followRedirects = true}) async {
    final HttpClientResponse response;
    try {
      final request = await _client.getUrl(url);
      request.followRedirects = followRedirects;
      request.headers
        ..set(HttpHeaders.refererHeader, '$_panBase/')
        ..set('origin', '$_panBase')
        ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
        ..set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
      if (_cookies.isNotEmpty && url.host.endsWith(_cookieHostSuffix)) {
        request.headers.set(HttpHeaders.cookieHeader, _cookieHeader());
      }
      response = await request.close().timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      throw _network(e);
    }
    for (final raw in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      // Parsed by hand: dart:io rejects some values Quark sends.
      final pair = raw.split(';').first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final value = pair.substring(eq + 1).trim();
      if (value.isNotEmpty) _cookies[pair.substring(0, eq).trim()] = value;
    }
    return response;
  }

  Future<Map<String, dynamic>> _getJson(Uri url) async {
    final response = await _send(url);
    final String body;
    try {
      body = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      throw _network(e);
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Fall through.
    }
    throw const StorageException(StorageErrorKind.other, 'Quark sent an unreadable login response');
  }

  static StorageException _network(Exception error) {
    if (error is StorageException) return error;
    return StorageException(StorageErrorKind.network, 'Cannot reach Quark', cause: error);
  }

  @override
  void close() => _client.close(force: true);
}
