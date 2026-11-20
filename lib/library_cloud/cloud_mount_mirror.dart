import '../storage/mount_manager.dart';
import '../storage/mount_registry.dart';
import '../storage/storage_mount.dart';
import '../utils/app_logger.dart';
import 'source_repository.dart';

/// Mirrors cloud-registered media sources (`quark` / `webdav`) into the local
/// [MountRegistry] under deterministic `cloud:<sourceId>` mount IDs so
/// [MountManager], [StreamProxy], and [LocalLibraryClient] can resolve and
/// directly stream files without any server-side media relay (C3).
class CloudMountMirror {
  CloudMountMirror({
    required this.sourceRepository,
    required this.mountRegistry,
    this.mountManager,
  });

  static const String cloudMountPrefix = 'cloud:';

  static String mountIdForSource(String sourceId) => '$cloudMountPrefix$sourceId';
  static bool isCloudMountId(String mountId) => mountId.startsWith(cloudMountPrefix);

  final CloudSourceRepository sourceRepository;
  final MountRegistry mountRegistry;
  final MountManager? mountManager;

  /// Syncs cloud sources into local [MountRegistry], decrypting credentials
  /// locally with the unlocked E2EE master key. Local-only mounts (such as
  /// device folders) are never touched.
  Future<List<CloudSource>> mirrorAllSources() async {
    final remoteSources = await sourceRepository.listSources();
    final activeCloudMountIds = <String>{};

    for (final src in remoteSources) {
      if (src.status != 'active') continue;
      if (src.kind != 'quark' && src.kind != 'webdav') continue;

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

    return remoteSources;
  }

  StorageMount? _toStorageMount(CloudSource src, String mountId, Map<String, dynamic> cred) {
    if (src.kind == 'webdav') {
      final baseUrl = (cred['base_url'] as String? ?? cred['url'] as String? ?? '').trim();
      if (baseUrl.isEmpty) return null;
      return StorageMount(
        id: mountId,
        kind: StorageKind.webdav,
        displayName: src.name,
        config: {
          MountKeys.baseUrl: baseUrl,
          MountKeys.username: (cred['username'] as String? ?? '').trim(),
          MountKeys.rootPath: (cred['root_path'] as String? ?? '/').trim(),
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
    }
    if (src.kind == 'quark') {
      final cookie = (cred['cookie'] as String? ?? '').trim();
      if (cookie.isEmpty) return null;
      return StorageMount(
        id: mountId,
        kind: StorageKind.quark,
        displayName: src.name,
        config: {
          MountKeys.rootPath: (cred['root_path'] as String? ?? '/').trim(),
        },
        secrets: {
          MountKeys.secretCookie: cookie,
        },
      );
    }
    return null;
  }
}
