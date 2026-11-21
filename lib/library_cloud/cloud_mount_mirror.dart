import '../connection/connection.dart';
import '../media/media_browser_dialect.dart';
import '../storage/drivers/quark_storage_driver.dart';
import '../storage/mount_manager.dart';
import '../storage/mount_registry.dart';
import '../storage/storage_mount.dart';
import '../utils/app_logger.dart';
import 'source_repository.dart';

class CloudMirrorResult {
  const CloudMirrorResult({
    required this.sources,
    required this.directExternalConnections,
  });

  final List<CloudSource> sources;
  final List<JellyfinConnection> directExternalConnections;
}

/// Mirrors cloud-registered media sources (`quark` / `webdav` / `smb`) into the
/// local [MountRegistry] under deterministic `cloud:<sourceId>` mount IDs so
/// [MountManager], [StreamProxy], and [LocalLibraryClient] can resolve and
/// directly stream files without any server-side media relay (C3).
///
/// Also decrypts cloud `emby` / `jellyfin` sources into ephemeral
/// [JellyfinConnection] descriptors for direct client connection.
class CloudMountMirror {
  CloudMountMirror({
    required this.sourceRepository,
    required this.mountRegistry,
    this.mountManager,
  });

  static const String cloudMountPrefix = 'cloud:';

  static String mountIdForSource(String sourceId) => '$cloudMountPrefix$sourceId';
  static bool isCloudMountId(String mountId) => mountId.startsWith(cloudMountPrefix);
  static String sourceIdFromMountId(String mountId) =>
      isCloudMountId(mountId) ? mountId.substring(cloudMountPrefix.length) : mountId;

  final CloudSourceRepository sourceRepository;
  final MountRegistry mountRegistry;
  final MountManager? mountManager;

  List<JellyfinConnection> _lastExternalConnections = const [];
  List<JellyfinConnection> get lastExternalConnections => _lastExternalConnections;

  /// Syncs cloud sources into local [MountRegistry], decrypting credentials
  /// locally with the unlocked E2EE master key. Local-only mounts (such as
  /// device folders) are never touched.
  Future<List<CloudSource>> mirrorAllSources() async {
    final res = await mirrorAllWithExternals();
    return res.sources;
  }

  Future<CloudMirrorResult> mirrorAllWithExternals() async {
    final remoteSources = await sourceRepository.listSources();
    final activeCloudMountIds = <String>{};
    final externalConnections = <JellyfinConnection>[];

    for (final src in remoteSources) {
      if (src.status != 'active') continue;

      if (src.kind == 'emby' || src.kind == 'jellyfin') {
        try {
          final cred = await sourceRepository.fetchCredential(src.id);
          final conn = _toExternalConnection(src, cred.payload);
          if (conn != null) {
            externalConnections.add(conn);
          }
        } catch (e) {
          appLogger.w('CloudMountMirror: skipped external credential sync for ${src.id}: $e');
        }
        continue;
      }

      if (src.kind != 'quark' && src.kind != 'webdav' && src.kind != 'smb') continue;

      final mountId = mountIdForSource(src.id);
      activeCloudMountIds.add(mountId);

      try {
        final cred = await sourceRepository.fetchCredential(src.id);
        final mount = _toStorageMount(src, mountId, cred.payload);
        if (mount != null) {
          await mountRegistry.upsert(mount);
          await mountManager?.dropCachedDriver(mountId);
        }
      } catch (e) {
        appLogger.w('CloudMountMirror: skipped credential sync for ${src.id}: $e');
      }
    }

    // Prune stale cloud mounts removed on the server while keeping local mounts intact.
    final existing = await mountRegistry.list();
    for (final m in existing) {
      if (isCloudMountId(m.id) && !activeCloudMountIds.contains(m.id)) {
        await mountManager?.dropCachedDriver(m.id);
        await mountRegistry.remove(m.id);
      }
    }

    _lastExternalConnections = List.unmodifiable(externalConnections);
    return CloudMirrorResult(
      sources: remoteSources,
      directExternalConnections: _lastExternalConnections,
    );
  }

  StorageMount? _toStorageMount(CloudSource src, String mountId, Map<String, dynamic> cred) {
    final includePaths = [
      for (final f in src.folders)
        if (f.path.trim().isNotEmpty && f.path.trim() != '/') f.path.trim(),
    ];
    final autoIncremental = cred['auto_incremental_scan'] == true;
    final rawInterval = (cred['auto_incremental_interval_minutes'] as num?)?.toInt();
    final autoIntervalMinutes = (rawInterval != null && rawInterval >= 1)
        ? rawInterval.clamp(1, 1440)
        : MountKeys.defaultAutoIncrementalIntervalMinutes;

    if (src.kind == 'webdav') {
      final baseUrl = (cred['base_url'] as String? ?? cred['url'] as String? ?? '').trim();
      if (baseUrl.isEmpty) return null;
      final fallbackUrl = (cred['fallback_url'] as String? ?? '').trim();
      return StorageMount(
        id: mountId,
        kind: StorageKind.webdav,
        displayName: src.name,
        config: {
          MountKeys.baseUrl: baseUrl,
          if (fallbackUrl.isNotEmpty) MountKeys.fallbackUrl: fallbackUrl,
          MountKeys.username: (cred['username'] as String? ?? '').trim(),
          MountKeys.rootPath: (cred['root_path'] as String? ?? '/').trim(),
          MountKeys.allowInsecureTls: cred['allow_insecure_tls'] == true,
          MountKeys.autoIncrementalScan: autoIncremental,
          MountKeys.autoIncrementalIntervalMinutes: autoIntervalMinutes,
          if (includePaths.isNotEmpty) MountKeys.includePaths: includePaths,
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
    }

    if (src.kind == 'smb') {
      final host = (cred['host'] as String? ?? '').trim();
      final share = (cred['share'] as String? ?? '').trim();
      if (host.isEmpty || share.isEmpty) return null;
      final fallbackUrl = (cred['fallback_url'] as String? ?? '').trim();
      final domain = (cred['domain'] as String? ?? '').trim();
      final username = (cred['username'] as String? ?? '').trim();
      return StorageMount(
        id: mountId,
        kind: StorageKind.smb,
        displayName: src.name,
        config: {
          MountKeys.host: host,
          MountKeys.share: share,
          if (fallbackUrl.isNotEmpty) MountKeys.fallbackUrl: fallbackUrl,
          if (username.isNotEmpty) MountKeys.username: username,
          if (domain.isNotEmpty) MountKeys.domain: domain,
          MountKeys.rootPath: (cred['root_path'] as String? ?? '/').trim(),
          MountKeys.autoIncrementalScan: autoIncremental,
          MountKeys.autoIncrementalIntervalMinutes: autoIntervalMinutes,
          if (includePaths.isNotEmpty) MountKeys.includePaths: includePaths,
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
    }

    if (src.kind == 'quark') {
      final cookie = (cred['cookie'] as String? ?? '').trim();
      if (cookie.isEmpty) return null;
      final quarkMode = (cred['quark_mode'] as String? ?? QuarkMode.web.name).trim();
      final downloadConnections = (cred['download_connections'] as num?)?.toInt();
      final downloadChunkMiB = (cred['download_chunk_mib'] as num?)?.toInt();
      final requestIntervalMs = (cred['request_interval_ms'] as num?)?.toInt();
      return StorageMount(
        id: mountId,
        kind: StorageKind.quark,
        displayName: src.name,
        config: {
          MountKeys.quarkMode: quarkMode.isEmpty ? QuarkMode.web.name : quarkMode,
          MountKeys.rootFolderId:
              (cred['root_folder_id'] as String?)?.trim().isNotEmpty == true
                  ? (cred['root_folder_id'] as String).trim()
                  : QuarkStorageDriver.defaultRootFolderId,
          MountKeys.rootPath: (cred['root_path'] as String? ?? '/').trim(),
          MountKeys.autoIncrementalScan: autoIncremental,
          MountKeys.autoIncrementalIntervalMinutes: autoIntervalMinutes,
          if (downloadConnections != null && downloadConnections > 0)
            MountKeys.quarkDownloadConnections: downloadConnections,
          if (downloadChunkMiB != null && downloadChunkMiB > 0)
            MountKeys.quarkDownloadChunkMiB: downloadChunkMiB,
          if (requestIntervalMs != null && requestIntervalMs > 0)
            MountKeys.requestIntervalMs: requestIntervalMs,
          if (includePaths.isNotEmpty) MountKeys.includePaths: includePaths,
        },
        secrets: {
          MountKeys.secretCookie: cookie,
        },
      );
    }
    return null;
  }

  JellyfinConnection? _toExternalConnection(CloudSource src, Map<String, dynamic> cred) {
    final baseUrl = (cred['base_url'] as String? ?? cred['url'] as String? ?? '').trim();
    final accessToken = (cred['access_token'] as String? ?? cred['api_key'] as String? ?? '').trim();
    final userId = (cred['user_id'] as String? ?? '').trim();
    if (baseUrl.isEmpty || accessToken.isEmpty || userId.isEmpty) return null;

    final dialect = src.kind == 'emby' ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin;
    final serverMachineId = (cred['server_machine_id'] as String? ?? '').trim().isNotEmpty
        ? (cred['server_machine_id'] as String).trim()
        : 'cloud-${src.kind}-${src.id}';
    final userName = (cred['username'] as String? ?? cred['user_name'] as String? ?? 'user').trim();
    final deviceId = (cred['device_id'] as String? ?? '').trim().isNotEmpty
        ? (cred['device_id'] as String).trim()
        : 'plezy-cloud-${src.id}';
    final serverName = (cred['server_name'] as String? ?? '').trim().isNotEmpty
        ? (cred['server_name'] as String).trim()
        : src.name;
    final rawUrls = cred['base_urls'];
    final baseUrls = rawUrls is List
        ? [for (final u in rawUrls) if (u is String && u.trim().isNotEmpty) u.trim()]
        : <String>[baseUrl];

    return JellyfinConnection(
      id: 'cloud-${src.id}',
      baseUrl: baseUrl,
      baseUrls: baseUrls.isEmpty ? [baseUrl] : baseUrls,
      serverName: serverName,
      serverMachineId: serverMachineId,
      userId: userId,
      userName: userName,
      accessToken: accessToken,
      deviceId: deviceId,
      dialect: dialect,
      isAdministrator: cred['is_administrator'] == true,
      createdAt: DateTime.now(),
    );
  }
}
