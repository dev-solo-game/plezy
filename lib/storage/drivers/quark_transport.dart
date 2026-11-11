import 'dart:convert';
import 'dart:io';

import '../../utils/app_logger.dart';
import '../storage_driver.dart';
import 'quark_pc_session.dart';
import 'quark_wsg.dart';

/// The subset of the driver's HTTP primitive a transport calls to make the
/// play-info and connectivity requests. Mirrors `QuarkStorageDriver._api`.
typedef QuarkApiCall =
    Future<Map<String, dynamic>> Function(
      String method,
      String path, {
      Map<String, String> query,
      Map<String, Object?>? body,
      Uri? base,
      List<String>? setCookies,
      bool wsgBody,
      String? cookie,
    });

const String quarkReferer = 'https://pan.quark.cn';

/// How a [QuarkStorageDriver] reaches Quark differs only by which client it
/// signs in as: the web client authenticates with a session cookie and reads
/// play info from drive.quark.cn, while the desktop ("PC") client signs every
/// request with three WSG headers and reads play info from drive-pc with an
/// encrypted body. A transport owns that difference — the auth state, the
/// query and headers, the body encoding, and the play-info call — so the
/// driver's directory, listing, read and caching logic stays mode-agnostic.
abstract class QuarkTransport {
  /// The client's User-Agent, sent on every request.
  String get userAgent;

  /// The common query parameters every request carries.
  Future<Map<String, String>> baseQuery();

  /// Sets the request's auth: the session cookie (web) or the WSG business
  /// headers (PC). [cookie], when given, is sent as the Cookie header — the
  /// desktop play-info call's `__kuus`.
  Future<void> authorize(HttpClientRequest request, {String? cookie});

  /// Writes [body] as the request payload, WSG-encrypting it when [wsgBody]
  /// and the client supports it.
  Future<void> writeBody(HttpClientRequest request, Map<String, Object?> body, {required bool wsgBody});

  /// Whether [playInfo] directly returns `trans_status == 'raw'` streams that
  /// [QuarkStorageDriver] should prefer for original-quality playback.
  bool get prefersRawPlayInfo => false;

  /// Takes in any session rotation the response carries (web cookies); a no-op
  /// for clients without one.
  void absorbResponse(HttpClientResponse response);

  /// Headers for a direct file download link.
  Future<Map<String, String>> downloadHeaders();

  /// Rebuilds headers for a cached download/play link so rotating or
  /// short-lived session material stays current while preserving link-scoped
  /// cookies such as `Video-Auth`.
  Future<Map<String, String>> refreshHeaders(Map<String, String> cached) => downloadHeaders();

  /// Requests a direct download link for [fid] as `(download_url, headers)`.
  Future<(Uri, Map<String, String>)> downloadLink(String fid, QuarkApiCall call);

  /// A lightweight request that fails if the session is no longer valid.
  Future<void> check(QuarkApiCall call, String rootFolderId);

  /// The file's renditions as `(video_list rows, player headers)`.
  Future<(List<dynamic>, Map<String, String>)> playInfo(String fid, QuarkApiCall call);

  /// Extracts `name -> value` pairs from raw `Set-Cookie` header lines. Raw
  /// because `dart:io` rejects some values Quark sends.
  static Map<String, String> parseSetCookies(List<String> setCookies) {
    final parsed = <String, String>{};
    for (final raw in setCookies) {
      final pair = parsePair(raw.split(';').first);
      if (pair != null) parsed[pair.$1] = pair.$2;
    }
    return parsed;
  }

  /// Splits a single `name=value` segment, returning null when missing or empty.
  static (String, String)? parsePair(String rawSegment) {
    final eq = rawSegment.indexOf('=');
    if (eq <= 0) return null;
    final name = rawSegment.substring(0, eq).trim();
    final value = rawSegment.substring(eq + 1).trim();
    if (name.isEmpty || value.isEmpty) return null;
    return (name, value);
  }

  /// Reads a named cookie out of raw `Set-Cookie` headers.
  static String? cookieValue(List<String> setCookies, String name) => parseSetCookies(setCookies)[name];

  /// Reads `download_url` out of a `/file/download` response payload.
  static Uri parseDownloadUrl(Map<String, dynamic> json) {
    final data = json['data'];
    final first = data is List && data.isNotEmpty ? data.first : null;
    final url = first is Map ? first['download_url'] : null;
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !uri.hasScheme) {
      throw const StorageException(StorageErrorKind.other, 'Quark returned no download link');
    }
    return uri;
  }
}

/// Web client: a session cookie, drive.quark.cn play info, and `__puus`/`__pus`
/// rotation.
class QuarkWebTransport extends QuarkTransport {
  QuarkWebTransport({required String cookie, required this.playApiBase, this.onCookieChanged}) : _cookie = cookie.trim();

  static const List<String> _renditions = ['4k', '2k', 'super', 'high', 'normal', 'low'];
  static const Set<String> _rotatingCookies = {'__puus', '__pus'};

  final Uri playApiBase;
  final void Function(String cookie)? onCookieChanged;
  String _cookie;

  @override
  String get userAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
      'Safari/537.36 Channel/pckk_other_ch';

  @override
  Future<Map<String, String>> baseQuery() async => const {'pr': 'ucpro', 'fr': 'pc'};

  @override
  Future<void> authorize(HttpClientRequest request, {String? cookie}) async {
    request.headers.set(HttpHeaders.cookieHeader, _cookie);
  }

  @override
  Future<void> writeBody(HttpClientRequest request, Map<String, Object?> body, {required bool wsgBody}) async {
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
  }

  @override
  void absorbResponse(HttpClientResponse response) {
    // Read raw header lines rather than response.cookies: dart:io throws if
    // any sibling Set-Cookie is malformed, which would drop __puus/__pus rotation.
    final raw = response.headers[HttpHeaders.setCookieHeader];
    if (raw == null || raw.isEmpty) return;
    final received = QuarkTransport.parseSetCookies(raw);
    var updated = _cookie;
    for (final entry in received.entries) {
      if (!_rotatingCookies.contains(entry.key)) continue;
      updated = _replaceCookie(updated, entry.key, entry.value);
    }
    if (updated == _cookie) return;
    _cookie = updated;
    appLogger.d('Quark rotated a session cookie');
    onCookieChanged?.call(updated);
  }

  @override
  Future<Map<String, String>> downloadHeaders() async => {
    HttpHeaders.cookieHeader: _cookie,
    HttpHeaders.refererHeader: quarkReferer,
    HttpHeaders.userAgentHeader: userAgent,
  };

  @override
  Future<(Uri, Map<String, String>)> downloadLink(String fid, QuarkApiCall call) async {
    final json = await call(
      'POST',
      '/file/download',
      body: {
        'fids': [fid],
      },
    );
    return (QuarkTransport.parseDownloadUrl(json), await downloadHeaders());
  }

  @override
  Future<void> check(QuarkApiCall call, String rootFolderId) async {
    await call('GET', '/config');
  }

  @override
  Future<(List<dynamic>, Map<String, String>)> playInfo(String fid, QuarkApiCall call) async {
    final setCookies = <String>[];
    final json = await call(
      'POST',
      '/file/v2/play',
      base: playApiBase,
      body: {
        'fid': fid,
        'resolutions': _renditions.reversed.join(','),
        'supports': 'm3u8,fmp4,apollo,dolby_vision,dolby_low',
      },
      setCookies: setCookies,
    );
    // The CDN refuses the renditions (HTTP 412) without this play-scoped cookie.
    final videoAuth = QuarkTransport.cookieValue(setCookies, 'Video-Auth');
    final headers = {
      HttpHeaders.cookieHeader: videoAuth == null ? _cookie : _replaceCookie(_cookie, 'Video-Auth', videoAuth),
      HttpHeaders.refererHeader: '$quarkReferer/',
      HttpHeaders.userAgentHeader: userAgent,
    };
    final data = json['data'];
    final rows = data is Map && data['video_list'] is List ? data['video_list'] as List : const [];
    return (rows, headers);
  }

  static String _replaceCookie(String cookieHeader, String name, String value) {
    final parts = cookieHeader.split(';').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    final index = parts.indexWhere((p) => p.startsWith('$name='));
    if (index >= 0) {
      parts[index] = '$name=$value';
    } else {
      parts.add('$name=$value');
    }
    return parts.join('; ');
  }
}

/// Desktop ("PC") client: three WSG business headers rebuilt per request, a
/// WSG-encrypted play-info body on drive-pc, and the `__kuus` play cookie.
class QuarkPcTransport extends QuarkTransport {
  QuarkPcTransport({required this.session, required this.wsg, required this.playInfoBase});

  final QuarkPcSession session;
  final QuarkWsg wsg;
  final Uri playInfoBase;

  @override
  String get userAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/130.0.0.0 Safari/537.36 QuarkPC/7.5.0.825 QuarkCloudDrivePC/7.5.0.825';

  @override
  Future<Map<String, String>> baseQuery() => session.commonQuery(wsg);

  @override
  Future<void> authorize(HttpClientRequest request, {String? cookie}) async {
    (await session.businessHeaders(wsg)).forEach(request.headers.set);
    if (cookie != null) request.headers.set(HttpHeaders.cookieHeader, cookie);
  }

  @override
  Future<void> writeBody(HttpClientRequest request, Map<String, Object?> body, {required bool wsgBody}) async {
    request.headers.contentType = ContentType.json;
    if (wsgBody) {
      request.headers.set('x-u-content-encoding', 'wg');
      request.add(ascii.encode(await wsg.encode(jsonEncode(body))));
    } else {
      request.add(utf8.encode(jsonEncode(body)));
    }
  }

  @override
  bool get prefersRawPlayInfo => true;

  @override
  void absorbResponse(HttpClientResponse response) {
    // The desktop session is ticket-based; nothing to rotate.
  }

  Map<String, String> _cdnHeadersFor(String kuus, {String? videoAuth}) => {
    HttpHeaders.cookieHeader: videoAuth == null ? kuus : '$kuus; Video-Auth=$videoAuth',
    HttpHeaders.refererHeader: '$quarkReferer/',
    HttpHeaders.userAgentHeader: userAgent,
  };

  static String? _cookieParam(String? header, String name) {
    if (header == null || header.isEmpty) return null;
    for (final part in header.split(';')) {
      final pair = QuarkTransport.parsePair(part);
      if (pair != null && pair.$1 == name) return pair.$2;
    }
    return null;
  }

  @override
  Future<Map<String, String>> downloadHeaders() async => _cdnHeadersFor(await session.kuusCookie(wsg));

  @override
  Future<Map<String, String>> refreshHeaders(Map<String, String> cached) async =>
      _cdnHeadersFor(await session.kuusCookie(wsg), videoAuth: _cookieParam(cached[HttpHeaders.cookieHeader], 'Video-Auth'));

  @override
  Future<(Uri, Map<String, String>)> downloadLink(String fid, QuarkApiCall call) async {
    final setCookies = <String>[];
    final kuus = await session.kuusCookie(wsg);
    final json = await call(
      'POST',
      '/file/download',
      body: {
        'fids': [fid],
      },
      wsgBody: true,
      cookie: kuus,
      setCookies: setCookies,
    );
    final videoAuth = QuarkTransport.cookieValue(setCookies, 'Video-Auth');
    return (QuarkTransport.parseDownloadUrl(json), _cdnHeadersFor(kuus, videoAuth: videoAuth));
  }

  @override
  Future<void> check(QuarkApiCall call, String rootFolderId) async {
    // The desktop host has no `/config`; a minimal root listing probes the
    // session instead.
    await call('GET', '/file/sort', query: {'pdir_fid': rootFolderId, '_size': '1', '_page': '1'});
  }

  @override
  Future<(List<dynamic>, Map<String, String>)> playInfo(String fid, QuarkApiCall call) async {
    final setCookies = <String>[];
    final kuus = await session.kuusCookie(wsg);
    final json = await call(
      'POST',
      '/batch/file/play/info',
      base: playInfoBase,
      body: {
        'fids': [fid],
        'resolutions': 'normal,low,high,super,2k,4k',
        'supports': 'm3u8,fmp4,apollo,dolby_vision,dolby_low',
        'fetch_credits_setting': 1,
        'fetch_play_video_resolution_setting': 1,
        'fetch_play_audio_type_setting': 1,
        'support_resolution_free_limit_ab': 1,
        'fetch_pdir': 1,
        'support_right': 'trial_1080P_zhizhen_pc',
      },
      wsgBody: true,
      cookie: kuus,
      setCookies: setCookies,
    );
    final videoAuth = QuarkTransport.cookieValue(setCookies, 'Video-Auth');
    final headers = _cdnHeadersFor(kuus, videoAuth: videoAuth);
    final data = json['data'];
    final rows = <dynamic>[];
    if (data is Map) {
      final item = data[fid] ?? (data.values.isNotEmpty ? data.values.first : null);
      if (item is Map && item['video_list'] is List) rows.addAll(item['video_list'] as List);
    }
    return (rows, headers);
  }
}
