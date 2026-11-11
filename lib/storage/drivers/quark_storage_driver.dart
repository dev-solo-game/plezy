import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import '../http_range_reader.dart';
import '../request_throttle.dart';
import '../storage_driver.dart';
import '../storage_mount.dart';
import '../storage_path.dart';
import '../stream_variant.dart';
import 'quark_pc_device_store.dart';
import 'quark_pc_session.dart';
import 'quark_transport.dart';
import 'quark_wsg.dart';

/// Which Quark client a mount signs in as. Each has its own login, its own
/// credentials and its own API, so a mount keeps the mode it was set up with.
enum QuarkMode {
  web,
  pc,
  tv;

  /// The modes a mount can be set up with today.
  static const Set<QuarkMode> supported = {web, pc};

  static QuarkMode parse(String? name) => values.firstWhere((m) => m.name == name, orElse: () => web);
}

/// Quark cloud drive, through one of its private clients.
///
/// The account is addressed by `fid`, so the driver keeps a path → fid map
/// filled in as directories are listed, and every call goes through a
/// [RequestThrottle] — Quark flags accounts that list too quickly. How a
/// request is signed and where play info comes from is the only thing that
/// differs between the web and desktop clients; a [QuarkTransport] owns that,
/// leaving the directory, listing, read and caching logic here mode-agnostic.
///
/// Besides the original file, Quark serves the renditions it transcoded
/// itself; see [streamVariants].
class QuarkStorageDriver implements StorageDriver, StreamVariantSource {
  QuarkStorageDriver({
    required String cookie,
    QuarkMode mode = QuarkMode.web,
    String rootFolderId = defaultRootFolderId,
    Duration requestInterval = defaultRequestInterval,
    void Function(String cookie)? onCookieChanged,
    HttpClient? httpClient,
    Uri? apiBase,
    Uri? playApiBase,
    QuarkPcDevice? fallbackDevice,
  }) : _apiBase = apiBase ?? Uri.parse('https://drive-pc.quark.cn/1/clouddrive'),
       _client = httpClient ?? HttpClient(),
       _throttle = RequestThrottle(requestInterval) {
    _transport = mode == QuarkMode.pc
        ? QuarkPcTransport(
            session: QuarkPcSession.parse(cookie.trim(), fallbackDevice: fallbackDevice),
            wsg: QuarkWsg(),
            playInfoBase: _apiBase,
          )
        : QuarkWebTransport(
            cookie: cookie,
            // The web client reads play info from drive.quark.cn, not the
            // desktop host the rest of the API is reached on.
            playApiBase: playApiBase ?? apiBase ?? Uri.parse('https://drive.quark.cn/1/clouddrive'),
            onCookieChanged: onCookieChanged,
          );
    _client
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _transport.userAgent;
    _reader = HttpRangeReader(_client);
    _folderIds[StoragePath.root] = rootFolderId.isEmpty ? defaultRootFolderId : rootFolderId;
  }

  factory QuarkStorageDriver.fromMount(
    StorageMount mount, {
    void Function(String cookie)? onCookieChanged,
    QuarkPcDevice? fallbackDevice,
  }) {
    final mode = QuarkMode.parse(mount.configString(MountKeys.quarkMode));
    if (!QuarkMode.supported.contains(mode)) {
      throw StorageException(StorageErrorKind.unsupported, 'Quark ${mode.name} sign-in is not supported yet');
    }
    final cookie = mount.secret(MountKeys.secretCookie);
    if (cookie == null) {
      throw const StorageException(StorageErrorKind.unauthorized, 'Quark mount has no credentials');
    }
    final intervalMs = mount.configInt(MountKeys.requestIntervalMs);
    return QuarkStorageDriver(
      cookie: cookie,
      mode: mode,
      rootFolderId: mount.configString(MountKeys.rootFolderId) ?? defaultRootFolderId,
      requestInterval: intervalMs == null
          ? defaultRequestInterval
          : Duration(milliseconds: intervalMs.clamp(minRequestIntervalMs, 60000)),
      onCookieChanged: onCookieChanged,
      fallbackDevice: fallbackDevice ?? QuarkPcDeviceStore.cached,
    );
  }

  static const String defaultRootFolderId = '0';
  static const Duration defaultRequestInterval = Duration(milliseconds: 1000);
  static const int minRequestIntervalMs = 200;

  static const int _pageSize = 100;
  static const Duration _linkLifetime = Duration(minutes: 30);

  late final QuarkTransport _transport;
  final Uri _apiBase;
  final HttpClient _client;
  final RequestThrottle _throttle;
  late final HttpRangeReader _reader;

  final Map<String, String> _folderIds = {};
  final Map<String, StorageLink> _links = {};
  final Map<String, StorageLink> _rawLinks = {};
  final Map<String, ({List<StreamVariant> variants, DateTime expiresAt})> _variants = {};

  /// Quark's rendition names, best first.
  static const List<String> renditions = ['4k', '2k', 'super', 'high', 'normal', 'low'];

  @override
  List<String> get variantOrder => renditions;
  static const Duration _variantLifetime = Duration(minutes: 20);

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<List<StreamVariant>> streamVariants(StorageEntry entry, {bool forceRefresh = false}) async {
    final fid = entry.id ?? (await stat(entry.path)).id!;
    return _loadVariants(fid, forceRefresh: forceRefresh);
  }

  Future<List<StreamVariant>> _loadVariants(String fid, {required bool forceRefresh}) async {
    final cached = _variants[fid];
    if (!forceRefresh && cached != null && cached.expiresAt.isAfter(clock.now())) return cached.variants;

    final (rows, headers) = await _transport.playInfo(fid, _api);
    final expiresAt = clock.now().add(_variantLifetime);
    final variants = <StreamVariant>[];
    StorageLink? bestRawLink;
    var bestRawRank = renditions.length + 1;

    int rankId(String id) {
      final index = renditions.indexOf(id);
      return index < 0 ? renditions.length : index;
    }

    for (final row in rows) {
      if (row is! Map || row['accessable'] == false) continue;
      final id = row['resolution'];
      final info = row['video_info'];
      final link = info is Map ? info['url'] : null;
      final url = link is String ? Uri.tryParse(link) : null;
      if (id is! String || url == null || !url.hasScheme) continue;
      if (variants.any((v) => v.id == id)) continue;
      final width = info['width'];
      final height = info['height'];
      final format = info['format'];
      final isHls = url.path.toLowerCase().endsWith('.m3u8') || (format is String && format.contains('m3u8'));
      variants.add(
        StreamVariant(
          id: id,
          url: url,
          headers: headers,
          width: width is num ? width.toInt() : null,
          height: height is num ? height.toInt() : null,
          isHls: isHls,
        ),
      );
      if (!isHls && row['trans_status'] == 'raw') {
        final rank = rankId(id);
        if (rank < bestRawRank) {
          bestRawRank = rank;
          bestRawLink = StorageLink(url, headers: headers, expiresAt: expiresAt);
        }
      }
    }

    variants.sort((a, b) => rankId(a.id).compareTo(rankId(b.id)));
    _variants[fid] = (variants: variants, expiresAt: expiresAt);
    if (bestRawLink != null) {
      _rawLinks[fid] = bestRawLink;
    } else {
      _rawLinks.remove(fid);
    }
    return variants;
  }

  @override
  Future<void> check() => _transport.check(_api, _folderIds[StoragePath.root]!);

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final normalized = StoragePath.normalize(path);
    final folderId = parent?.id ?? await _resolveFolderId(normalized);
    return _listFolder(normalized, folderId);
  }

  @override
  Future<StorageEntry> stat(String path) async {
    final normalized = StoragePath.normalize(path);
    if (normalized == StoragePath.root) {
      return StorageEntry(path: StoragePath.root, name: '', isDirectory: true, id: _folderIds[StoragePath.root]);
    }
    final siblings = await list(StoragePath.parent(normalized));
    for (final entry in siblings) {
      if (entry.path == normalized) return entry;
    }
    throw StorageException(StorageErrorKind.notFound, 'Not found: $normalized');
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    return _reader.read(
      ({required bool forceRefresh}) => _linkFor(entry, forceRefresh: forceRefresh),
      start: start,
      end: end,
    );
  }

  Future<String> _resolveFolderId(String path) async {
    final known = _folderIds[path];
    if (known != null) return known;

    // Walk down from the deepest ancestor whose id is already known.
    final segments = StoragePath.segments(path);
    var depth = segments.length - 1;
    while (depth > 0 && !_folderIds.containsKey('/${segments.sublist(0, depth).join('/')}')) {
      depth--;
    }
    for (var i = depth; i < segments.length; i++) {
      final parentPath = i == 0 ? StoragePath.root : '/${segments.sublist(0, i).join('/')}';
      await _listFolder(parentPath, _folderIds[parentPath]!);
      final childPath = '/${segments.sublist(0, i + 1).join('/')}';
      if (!_folderIds.containsKey(childPath)) {
        throw StorageException(StorageErrorKind.notFound, 'Not found: $childPath');
      }
    }
    return _folderIds[path]!;
  }

  Future<List<StorageEntry>> _listFolder(String path, String folderId) async {
    final entries = <StorageEntry>[];
    for (var page = 1; ; page++) {
      final json = await _api(
        'GET',
        '/file/sort',
        query: {
          'pdir_fid': folderId,
          '_size': '$_pageSize',
          '_page': '$page',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,file_name:asc',
        },
      );
      final data = json['data'];
      final rows = data is Map && data['list'] is List ? data['list'] as List : const [];
      for (final row in rows) {
        if (row is! Map) continue;
        final entry = _entryFromRow(path, row);
        if (entry == null) continue;
        entries.add(entry);
        if (entry.isDirectory) _folderIds[entry.path] = entry.id!;
      }
      final metadata = json['metadata'];
      final total = metadata is Map && metadata['_total'] is num ? (metadata['_total'] as num).toInt() : null;
      if (rows.length < _pageSize || (total != null && page * _pageSize >= total)) break;
    }
    return entries;
  }

  StorageEntry? _entryFromRow(String parentPath, Map<dynamic, dynamic> row) {
    final fid = row['fid'];
    final name = row['file_name'];
    if (fid is! String || fid.isEmpty || name is! String || name.isEmpty) return null;
    // A name that would change meaning when normalized cannot be addressed by path.
    if (name == '.' || name == '..' || name.contains('/') || name.contains('\\')) return null;
    final isFile = row['file'] == true;
    final updatedAt = row['updated_at'];
    final size = row['size'];
    return StorageEntry(
      path: StoragePath.join(parentPath, name),
      name: name,
      isDirectory: !isFile,
      size: isFile && size is num ? size.toInt() : null,
      modifiedAt: updatedAt is num ? DateTime.fromMillisecondsSinceEpoch(updatedAt.toInt()) : null,
      id: fid,
    );
  }

  Future<StorageLink> _linkFor(StorageEntry entry, {required bool forceRefresh}) async {
    final fid = entry.id ?? (await stat(entry.path)).id!;
    if (forceRefresh) {
      _links.remove(fid);
      _rawLinks.remove(fid);
    } else {
      final cached = _links[fid];
      if (cached != null && cached.expiresAt!.isAfter(clock.now())) {
        // Session cookies or signed tokens may have rotated since caching.
        return StorageLink(
          cached.url,
          headers: await _transport.refreshHeaders(cached.headers),
          expiresAt: cached.expiresAt,
        );
      }
      if (_transport.prefersRawPlayInfo) {
        final raw = _rawLinks[fid];
        if (raw != null && raw.expiresAt!.isAfter(clock.now())) {
          return StorageLink(raw.url, headers: await _transport.refreshHeaders(raw.headers), expiresAt: raw.expiresAt);
        }
      }
    }

    try {
      final (uri, headers) = await _transport.downloadLink(fid, _api);
      final link = StorageLink(uri, headers: headers, expiresAt: clock.now().add(_linkLifetime));
      _links[fid] = link;
      return link;
    } on StorageException catch (e) {
      if (!_transport.prefersRawPlayInfo ||
          e.kind == StorageErrorKind.unauthorized ||
          e.kind == StorageErrorKind.rateLimited) {
        rethrow;
      }
      await _loadVariants(fid, forceRefresh: true);
      final raw = _rawLinks[fid];
      if (raw != null) return raw;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _api(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    Uri? base,
    List<String>? setCookies,
    // PC mode: WSG-encrypt the JSON body (play info needs this); send [cookie]
    // as the request's Cookie header (the play-scoped `__kuus`).
    bool wsgBody = false,
    String? cookie,
  }) {
    final apiBase = base ?? _apiBase;
    return _throttle.run(() async {
      final url = apiBase.replace(
        path: '${apiBase.path}$path',
        queryParameters: {...await _transport.baseQuery(), ...query},
      );
      final int status;
      final String text;
      try {
        final request = await _client.openUrl(method, url);
        request.headers
          ..set(HttpHeaders.refererHeader, quarkReferer)
          ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
        await _transport.authorize(request, cookie: cookie);
        if (body != null) await _transport.writeBody(request, body, wsgBody: wsgBody);
        final response = await request.close().timeout(const Duration(seconds: 30));
        status = response.statusCode;
        // Raw, because dart:io refuses to parse some of the values Quark sends.
        setCookies?.addAll(response.headers[HttpHeaders.setCookieHeader] ?? const []);
        _transport.absorbResponse(response);
        text = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
      } on SocketException catch (e) {
        throw StorageException(StorageErrorKind.network, 'Cannot reach Quark', cause: e);
      } on HandshakeException catch (e) {
        throw StorageException(StorageErrorKind.network, 'TLS handshake with Quark failed', cause: e);
      } on TimeoutException catch (e) {
        throw StorageException(StorageErrorKind.network, 'Quark request timed out', cause: e);
      } on HttpException catch (e) {
        throw StorageException(StorageErrorKind.network, e.message, cause: e);
      }

      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      final json = decoded is Map<String, dynamic> ? decoded : null;
      final code = json?['code'];
      final apiStatus = json?['status'];
      final failed =
          status >= 400 || json == null || (code is num && code != 0) || (apiStatus is num && apiStatus >= 400);
      if (!failed) return json;

      final message = json?['message'] is String ? json!['message'] as String : 'HTTP $status';
      throw StorageException(_errorKind(status, apiStatus, message), 'Quark: $message');
    });
  }

  static StorageErrorKind _errorKind(int httpStatus, Object? apiStatus, String message) {
    final effective = apiStatus is num && apiStatus >= 400 ? apiStatus.toInt() : httpStatus;
    if (effective == HttpStatus.unauthorized || message.toLowerCase().contains('require login')) {
      return StorageErrorKind.unauthorized;
    }
    if (effective == HttpStatus.tooManyRequests) return StorageErrorKind.rateLimited;
    if (effective == HttpStatus.notFound) return StorageErrorKind.notFound;
    return StorageErrorKind.other;
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}
