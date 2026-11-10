import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../http_range_reader.dart';
import '../storage_driver.dart';
import '../storage_mount.dart';
import '../storage_path.dart';

/// A WebDAV collection: a NAS, an OpenList/AList instance, a hosted DAV drive.
///
/// Basic and Digest authentication are answered through `HttpClient`'s
/// credential store, so the password is only ever sent to the host the mount
/// was configured for — never to wherever a GET redirects (OpenList answers
/// file reads with a redirect to the underlying drive).
class WebDavStorageDriver implements StorageDriver {
  WebDavStorageDriver({required Uri baseUrl, String? username, String? password, bool allowInsecureTls = false})
    : _base = baseUrl,
      _baseSegments = baseUrl.pathSegments.where((s) => s.isNotEmpty).toList(growable: false),
      _client = HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    if (allowInsecureTls) {
      _client.badCertificateCallback = (cert, host, port) => host == baseUrl.host;
    }
    if (username != null && username.isNotEmpty) {
      final secret = password ?? '';
      // HttpClient asks again whenever the server rejects what it was given.
      // Offering the same credentials twice would retry forever, so a second
      // challenge for the same realm means they are wrong.
      final offered = <String>{};
      _client.authenticate = (uri, scheme, realm) async {
        if (uri.host != baseUrl.host) return false;
        if (!offered.add('${scheme.toLowerCase()}\u0000$realm')) return false;
        final credentials = scheme.toLowerCase() == 'digest'
            ? HttpClientDigestCredentials(username, secret)
            : HttpClientBasicCredentials(username, secret);
        _client.addCredentials(uri, realm ?? '', credentials);
        return true;
      };
    }
    _reader = HttpRangeReader(_client);
  }

  factory WebDavStorageDriver.fromMount(StorageMount mount) {
    final raw = mount.configString(MountKeys.baseUrl);
    final uri = raw == null ? null : Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const StorageException(StorageErrorKind.other, 'WebDAV mount needs an http(s) URL');
    }
    return WebDavStorageDriver(
      baseUrl: uri,
      username: mount.configString(MountKeys.username),
      password: mount.secret(MountKeys.secretPassword),
      allowInsecureTls: mount.configBool(MountKeys.allowInsecureTls),
    );
  }

  final Uri _base;
  final List<String> _baseSegments;
  final HttpClient _client;
  late final HttpRangeReader _reader;

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:"><D:prop>'
      '<D:resourcetype/><D:getcontentlength/><D:getlastmodified/>'
      '</D:prop></D:propfind>';

  @override
  StorageKind get kind => StorageKind.webdav;

  Uri _urlFor(String path, {required bool directory}) {
    final segments = [..._baseSegments, ...StoragePath.segments(path)];
    // A trailing empty segment yields a trailing slash, which collections expect.
    return _base.replace(pathSegments: directory ? [...segments, ''] : segments);
  }

  @override
  Future<void> check() async {
    await _propfind(StoragePath.root, depth: 0, directory: true);
  }

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final normalized = StoragePath.normalize(path);
    final depth = StoragePath.segments(normalized).length;
    final entries = await _propfind(normalized, depth: 1, directory: true);
    // Depth: 1 includes the collection itself; keep only its children.
    return entries.where((e) => StoragePath.segments(e.path).length == depth + 1).toList();
  }

  @override
  Future<StorageEntry> stat(String path) async {
    final normalized = StoragePath.normalize(path);
    if (normalized == StoragePath.root) {
      return const StorageEntry(path: StoragePath.root, name: '', isDirectory: true);
    }
    final entries = await _propfind(normalized, depth: 0, directory: false);
    for (final entry in entries) {
      if (entry.path == normalized) return entry;
    }
    throw StorageException(StorageErrorKind.notFound, 'Not found: $normalized');
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    final link = StorageLink(_urlFor(entry.path, directory: false));
    return _reader.read(({required bool forceRefresh}) async => link, start: start, end: end);
  }

  Future<List<StorageEntry>> _propfind(String path, {required int depth, required bool directory}) async {
    final url = _urlFor(path, directory: directory);
    final String body;
    final int status;
    try {
      final request = await _client.openUrl('PROPFIND', url);
      request.followRedirects = false;
      request.headers
        ..set('Depth', '$depth')
        ..contentType = ContentType('application', 'xml', charset: 'utf-8');
      request.add(utf8.encode(_propfindBody));
      final response = await request.close().timeout(const Duration(seconds: 30));
      status = response.statusCode;
      body = await utf8.decodeStream(response).timeout(const Duration(seconds: 60));
    } on SocketException catch (e) {
      throw StorageException(StorageErrorKind.network, 'Cannot reach ${url.host}', cause: e);
    } on HandshakeException catch (e) {
      throw StorageException(StorageErrorKind.network, 'TLS handshake with ${url.host} failed', cause: e);
    } on TimeoutException catch (e) {
      throw StorageException(StorageErrorKind.network, 'WebDAV request timed out', cause: e);
    } on HttpException catch (e) {
      throw StorageException(StorageErrorKind.network, e.message, cause: e);
    }

    switch (status) {
      case HttpStatus.multiStatus:
        return _parseMultiStatus(body);
      case HttpStatus.movedPermanently ||
              HttpStatus.found ||
              HttpStatus.temporaryRedirect ||
              HttpStatus.permanentRedirect
          when !directory:
        // Servers redirect a collection addressed without its trailing slash.
        return _propfind(path, depth: depth, directory: true);
      case HttpStatus.unauthorized || HttpStatus.forbidden:
        throw const StorageException(StorageErrorKind.unauthorized, 'WebDAV server rejected the credentials');
      case HttpStatus.notFound:
        throw StorageException(StorageErrorKind.notFound, 'Not found: $path');
      case HttpStatus.tooManyRequests:
        throw const StorageException(StorageErrorKind.rateLimited, 'WebDAV server is rate limiting');
      default:
        throw StorageException(StorageErrorKind.other, 'WebDAV server answered HTTP $status');
    }
  }

  List<StorageEntry> _parseMultiStatus(String body) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw StorageException(StorageErrorKind.other, 'WebDAV server sent malformed XML', cause: e);
    }

    final entries = <StorageEntry>[];
    for (final response in document.descendantElements.where((e) => e.name.local == 'response')) {
      final href = _firstText(response, 'href');
      if (href == null) continue;
      final path = _pathFromHref(href);
      if (path == null) continue;

      // A response can carry several propstat blocks; only the 200 one has values.
      XmlElement? prop;
      for (final propstat in response.childElements.where((e) => e.name.local == 'propstat')) {
        final statusLine = _firstText(propstat, 'status') ?? '';
        if (statusLine.isEmpty || statusLine.contains(' 200')) {
          prop = propstat.childElements.where((e) => e.name.local == 'prop').firstOrNull;
          if (prop != null) break;
        }
      }

      final resourceType = prop?.childElements.where((e) => e.name.local == 'resourcetype').firstOrNull;
      final isDirectory =
          (resourceType?.childElements.any((e) => e.name.local == 'collection') ?? false) ||
          (prop == null && href.endsWith('/'));
      final length = prop == null ? null : int.tryParse(_firstText(prop, 'getcontentlength') ?? '');
      final modified = prop == null ? null : _parseHttpDate(_firstText(prop, 'getlastmodified'));

      entries.add(
        StorageEntry(
          path: path,
          name: StoragePath.name(path),
          isDirectory: isDirectory,
          size: isDirectory ? null : length,
          modifiedAt: modified,
        ),
      );
    }
    return entries;
  }

  /// Maps a response href (absolute URL or path, percent-encoded) to a
  /// mount-relative path. Returns null for hrefs outside the mount.
  String? _pathFromHref(String href) {
    final Uri uri;
    try {
      uri = Uri.parse(href.trim());
    } on FormatException {
      return null;
    }
    final List<String> segments;
    try {
      segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    } on ArgumentError {
      // Invalid percent-encoding in the href.
      return null;
    }
    if (segments.length < _baseSegments.length) return null;
    for (var i = 0; i < _baseSegments.length; i++) {
      if (segments[i] != _baseSegments[i]) return null;
    }
    final relative = segments.sublist(_baseSegments.length);
    // A decoded segment containing a separator or a dot-step cannot be
    // addressed safely through a normalized path.
    if (relative.any((s) => s == '.' || s == '..' || s.contains('/') || s.contains('\\'))) return null;
    return '/${relative.join('/')}';
  }

  static String? _firstText(XmlElement parent, String localName) {
    final element = parent.descendantElements.where((e) => e.name.local == localName).firstOrNull;
    final text = element?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static DateTime? _parseHttpDate(String? value) {
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on Exception {
      return DateTime.tryParse(value);
    }
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}
