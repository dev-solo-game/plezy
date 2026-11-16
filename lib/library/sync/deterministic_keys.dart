import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:uuid/uuid.dart';

import '../../storage/drivers/quark_pc_session.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/storage_mount.dart';

/// Generates normalized paths and deterministic identifiers shared across
/// devices so local Drift rows can be mapped cleanly onto sync entities.
abstract final class DeterministicKeys {
  static final RegExp _cookieUidPattern = RegExp(r'(?:^|[;&\s])uid=([^;&\s]+)');

  /// Normalizes a mount-relative path with URL decoding, POSIX separators,
  /// `.`/`..` clamping at root, and Unicode NFC normalization so macOS/iOS NFD
  /// filenames produce the same hash as Windows/Android NFC filenames.
  static String normalizeMountPath(String rawPath) {
    var decoded = rawPath;
    try {
      decoded = Uri.decodeFull(rawPath);
    } catch (_) {
      // Keep malformed percent sequences verbatim instead of failing scans.
    }

    final segments = <String>[];
    for (final segment in decoded.replaceAll('\\', '/').split('/')) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty || trimmed == '.') continue;
      if (trimmed == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(unorm.nfc(trimmed));
    }
    return '/${segments.join('/')}';
  }

  /// Creates a persistent UUID v4 mount/source identifier. Changing a mount's
  /// IP, port, or fallback URL must preserve this ID so file IDs stay stable.
  static String newSourceId() => const Uuid().v4();

  /// Computes a canonical fingerprint for deduplicating mounts added
  /// independently on multiple devices before synchronization.
  static String canonicalSourceKey(StorageMount mount) {
    switch (mount.kind) {
      case StorageKind.local:
        final root = normalizeMountPath(mount.configString(MountKeys.rootPath) ?? '/');
        return 'local:$root';
      case StorageKind.quark:
        final rootFolderId = (mount.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId)
            .trim();
        final uid = _extractQuarkUid(mount.secret(MountKeys.secretCookie));
        return 'quark:$uid:$rootFolderId';
      case StorageKind.smb:
        final host = (mount.configString(MountKeys.host) ?? '').trim().toLowerCase();
        final share = (mount.configString(MountKeys.share) ?? '').trim().toLowerCase();
        final rootPath = normalizeMountPath(mount.configString(MountKeys.rootPath) ?? '/');
        return 'smb://$host/$share$rootPath';
      case StorageKind.webdav:
        final rawUrl = (mount.configString(MountKeys.baseUrl) ?? '').trim();
        final uri = Uri.tryParse(rawUrl);
        if (uri == null || uri.host.isEmpty) {
          return 'webdav://${rawUrl.toLowerCase()}';
        }
        final scheme = uri.scheme.toLowerCase();
        final host = uri.host.toLowerCase();
        final isDefaultPort = (scheme == 'http' && uri.port == 80) || (scheme == 'https' && uri.port == 443);
        final portPart = uri.hasPort && !isDefaultPort ? ':${uri.port}' : '';
        final normPath = normalizeMountPath(uri.path);
        return 'webdav://$scheme://$host$portPart$normPath';
    }
  }

  static String _extractQuarkUid(String? secret) {
    final trimmed = secret?.trim() ?? '';
    if (trimmed.isEmpty) return 'anonymous';
    final parsedUid = QuarkPcSession.parse(trimmed).uid.trim();
    if (parsedUid.isNotEmpty) return parsedUid;
    final match = _cookieUidPattern.firstMatch(trimmed);
    final cookieUid = match?.group(1)?.trim() ?? '';
    if (cookieUid.isNotEmpty) return cookieUid;
    return sha256.convert(utf8.encode(trimmed)).toString().substring(0, 16);
  }

  /// Generates the deterministic file identifier `sha256(sourceId:normPath)`.
  static String generateFileId({required String sourceId, required String mountRelativePath}) {
    final normPath = normalizeMountPath(mountRelativePath);
    return sha256.convert(utf8.encode('$sourceId:$normPath')).toString().substring(0, 32);
  }

  /// Generates a deterministic work key (`tmdb:movie:693134`, `bangumi:show:...`)
  /// or falls back to `raw:<hash>` using normalized file name and byte size.
  static String generateWorkKey({
    required int matchStatus,
    required String kind,
    String? provider,
    String? externalId,
    required String fileName,
    required int fileSize,
  }) {
    final cleanProvider = provider?.trim().toLowerCase();
    final cleanExternalId = externalId?.trim();
    if (matchStatus >= 3 &&
        cleanProvider != null &&
        cleanProvider.isNotEmpty &&
        cleanExternalId != null &&
        cleanExternalId.isNotEmpty) {
      return '$cleanProvider:$kind:$cleanExternalId';
    }
    final cleanName = unorm.nfc(fileName.trim()).toLowerCase();
    final hash = sha256.convert(utf8.encode('$cleanName:$fileSize')).toString().substring(0, 24);
    return 'raw:$hash';
  }

  /// Generates the deterministic watch progress key for a movie or episode.
  static String generateProgressKey({
    required String workKey,
    required String kind,
    int seasonNum = -1,
    int episodeNum = -1,
  }) {
    if (kind == 'show' && seasonNum >= 0 && episodeNum >= 0) {
      return '$workKey:s$seasonNum:e$episodeNum';
    }
    return workKey;
  }
}
