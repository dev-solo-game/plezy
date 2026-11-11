import 'dart:async';

import '../utils/app_logger.dart';
import 'drivers/local_storage_driver.dart';
import 'drivers/quark_storage_driver.dart';
import 'drivers/smb_storage_driver.dart';
import 'drivers/webdav_storage_driver.dart';
import 'mount_registry.dart';
import 'storage_driver.dart';
import 'storage_mount.dart';
import 'stream_proxy.dart';
import 'stream_variant.dart';

/// Owns the live [StorageDriver] of every mount and the [StreamProxy] that
/// serves their files. The scanner, the player and the downloader all reach
/// storage through here so each mount has exactly one driver instance — and
/// therefore one request throttle and one link cache.
class MountManager {
  MountManager(this.registry, {StreamProxy? proxy}) : proxy = proxy ?? StreamProxy();

  final MountRegistry registry;
  final StreamProxy proxy;

  final Map<String, StorageDriver> _drivers = {};

  /// Builds a driver for [mount] without registering it — for validating a
  /// mount the user is still editing. The caller closes it.
  StorageDriver createDriver(StorageMount mount) {
    return switch (mount.kind) {
      StorageKind.local => LocalStorageDriver.fromMount(mount),
      StorageKind.webdav => WebDavStorageDriver.fromMount(mount),
      StorageKind.quark => QuarkStorageDriver.fromMount(
        mount,
        onCookieChanged: (cookie) => unawaited(_persistSecret(mount.id, MountKeys.secretCookie, cookie)),
      ),
      StorageKind.smb => SmbStorageDriver.fromMount(mount),
    };
  }

  /// The shared driver for [mount], created on first use.
  StorageDriver driverFor(StorageMount mount) => _drivers[mount.id] ??= createDriver(mount);

  /// A loopback URL players can open for [entry].
  Future<Uri> streamUrl(StorageMount mount, StorageEntry entry) {
    return proxy.register(mountId: mount.id, driver: driverFor(mount), entry: entry);
  }

  /// The transcoded renditions [mount]'s backend offers for [entry], best
  /// first. Empty for backends that transcode nothing.
  Future<List<StreamVariant>> streamVariants(StorageMount mount, StorageEntry entry) async {
    return switch (driverFor(mount)) {
      final StreamVariantSource source => source.streamVariants(entry),
      _ => const [],
    };
  }

  /// The rendition names [mount]'s backend uses, best first.
  List<String> variantOrder(StorageMount mount) {
    return switch (driverFor(mount)) {
      final StreamVariantSource source => source.variantOrder,
      _ => const [],
    };
  }

  /// A loopback URL players can open for the [variant] rendition of [entry].
  Future<Uri> variantUrl(StorageMount mount, StorageEntry entry, StreamVariant variant) {
    final driver = driverFor(mount);
    if (driver is! StreamVariantSource) {
      throw const StorageException(StorageErrorKind.unsupported, 'This storage offers no renditions');
    }
    return proxy.registerVariant(
      mountId: mount.id,
      source: driver as StreamVariantSource,
      entry: entry,
      variant: variant,
    );
  }

  /// Saves [mount] and discards its current driver so the next use picks up
  /// the new settings.
  Future<void> save(StorageMount mount) async {
    await registry.upsert(mount);
    await _dropDriver(mount.id);
  }

  Future<void> remove(String mountId) async {
    await registry.remove(mountId);
    await _dropDriver(mountId);
  }

  Future<void> _dropDriver(String mountId) async {
    proxy.unregisterMount(mountId);
    await _drivers.remove(mountId)?.close();
  }

  Future<void> _persistSecret(String mountId, String key, String value) async {
    try {
      // Deliberately not `save`: the running driver already holds the new value.
      await registry.updateSecret(mountId, key, value);
    } catch (e) {
      appLogger.w('Failed to persist rotated credentials for mount $mountId: $e');
    }
  }

  Future<void> dispose() async {
    await proxy.stop();
    final drivers = _drivers.values.toList();
    _drivers.clear();
    await Future.wait(drivers.map((d) => d.close()));
  }
}
