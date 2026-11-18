import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:uuid/uuid.dart';

import '../../storage/drivers/quark_pc_session.dart';
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
  ///
  /// One account/origin maps to one mount (directories belong in `includePaths`).
  static String canonicalSourceKey(StorageMount mount) {
    switch (mount.kind) {
      case StorageKind.local:
        final root = normalizeMountPath(mount.configString(MountKeys.rootPath) ?? '/');
        return 'local:$root';
      case StorageKind.quark:
        final uid = _extractQuarkUid(mount.secret(MountKeys.secretCookie));
        return 'quark:$uid';
      case StorageKind.smb:
        final host = (mount.configString(MountKeys.host) ?? '').trim().toLowerCase();
        final share = (mount.configString(MountKeys.share) ?? '').trim().toLowerCase();
        return 'smb://$host/$share';
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
        final user = mount.configString(MountKeys.username)?.trim().toLowerCase() ?? '';
        final userPart = user.isNotEmpty ? '${Uri.encodeComponent(user)}@' : '';
        return 'webdav://$scheme://$userPart$host$portPart$normPath';
    }
  }

  /// Normalizes legacy canonical source keys (e.g. `quark:<uid>:<rootFolderId>`)
  /// so comparisons stay compatible across upgrades and peers.
  static String normalizeCanonicalSourceKey(String rawKey) {
    final trimmed = rawKey.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('quark:')) {
      final rest = trimmed.substring('quark:'.length);
      final sep = rest.indexOf(':');
      final uid = sep == -1 ? rest : rest.substring(0, sep);
      return 'quark:$uid';
    }
    if (trimmed.startsWith('smb://')) {
      final rest = trimmed.substring('smb://'.length);
      final parts = rest.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.length >= 2) {
        return 'smb://${parts[0].toLowerCase()}/${parts[1].toLowerCase()}';
      }
      return trimmed.toLowerCase();
    }
    return trimmed;
  }

  static bool sameCanonicalSourceKey(String a, String b) {
    final na = normalizeCanonicalSourceKey(a);
    final nb = normalizeCanonicalSourceKey(b);
    return na.isNotEmpty && na == nb;
  }

  /// Computes a colon-free deterministic mount identifier (`quark_<uid>`,
  /// `smb_<hash24>`, `webdav_<hash24>`, `local_<hash24>`).
  ///
  /// Colons are forbidden because `mount:<mountId>:<path>` artwork sources
  /// split on `':'`.
  static String deterministicSourceId(StorageMount mount) {
    final canonicalKey = canonicalSourceKey(mount);
    final hash = sha256.convert(utf8.encode(canonicalKey)).toString().substring(0, 24);
    switch (mount.kind) {
      case StorageKind.quark:
        final uid = _extractQuarkUid(mount.secret(MountKeys.secretCookie));
        if (uid != 'anonymous' && RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(uid)) {
          return 'quark_$uid';
        }
        return 'quark_$hash';
      case StorageKind.smb:
        return 'smb_$hash';
      case StorageKind.webdav:
        return 'webdav_$hash';
      case StorageKind.local:
        return 'local_$hash';
    }
  }

  /// Normalizes a work key, mapping legacy `work:<kind>:<provider>:<id>` values
  /// onto `<provider>:<kind>:<id>`.
  static String canonicalizeWorkKey(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('work:')) {
      final parts = trimmed.split(':');
      if (parts.length >= 4) {
        final kind = parts[1];
        final provider = parts[2];
        final extId = parts.sublist(3).join(':');
        if (kind.isNotEmpty && provider.isNotEmpty && extId.isNotEmpty) {
          return '$provider:$kind:$extId';
        }
      }
    }
    return trimmed;
  }

  /// Computes the deterministic `work_key` for a matched movie or show item,
  /// returning `null` for unmatched/pending placeholders.
  static String? workKeyForMatchedItem({
    required String kind,
    String? tmdbId,
    String? bangumiId,
    String? imdbId,
    String? tvdbId,
    String? metadataSource,
    required String libraryType,
    required String sortTitle,
    int? year,
  }) {
    if (libraryType == 'pending') return null;
    final cleanTmdb = tmdbId?.trim() ?? '';
    if (cleanTmdb.isNotEmpty) return 'tmdb:$kind:$cleanTmdb';
    final cleanBangumi = bangumiId?.trim() ?? '';
    if (cleanBangumi.isNotEmpty) return 'bangumi:$kind:$cleanBangumi';
    final cleanImdb = imdbId?.trim() ?? '';
    if (cleanImdb.isNotEmpty) return 'imdb:$kind:$cleanImdb';
    final cleanTvdb = tvdbId?.trim() ?? '';
    if (cleanTvdb.isNotEmpty) return 'tvdb:$kind:$cleanTvdb';
    final cleanSource = metadataSource?.trim() ?? '';
    if (cleanSource.isEmpty) return null;
    return 'nfo:$kind:$sortTitle:${year ?? 0}';
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
