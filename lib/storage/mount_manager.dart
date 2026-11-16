import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/connectivity_probe.dart';
import '../utils/app_logger.dart';
import 'drivers/local_storage_driver.dart';
import 'drivers/quark_pc_device_store.dart';
import 'drivers/quark_pc_session.dart';
import 'drivers/quark_storage_driver.dart';
import 'drivers/smb_storage_driver.dart';
import 'drivers/webdav_storage_driver.dart';
import 'http_range_reader.dart';
import 'mount_registry.dart';
import 'storage_driver.dart';
import 'storage_mount.dart';
import 'stream_proxy.dart';
import 'stream_variant.dart';

enum MountOnlineStatus { unknown, probing, onlinePrimary, onlineFallback, offline }

typedef MountDriverFactory = StorageDriver Function(StorageMount mount, {bool useFallback});

/// Owns the live [StorageDriver] of every mount and the [StreamProxy] that
/// serves their files. The scanner, the player and the downloader all reach
/// storage through here so each mount has exactly one driver instance — and
/// therefore one request throttle and one link cache.
class MountManager {
  MountManager(
    this.registry, {
    StreamProxy? proxy,
    BulkReadOptions Function()? bulkOptions,
    this._driverFactory,
  }) : proxy = proxy ?? StreamProxy(bulkOptions: bulkOptions);

  final MountRegistry registry;
  final StreamProxy proxy;
  final MountDriverFactory? _driverFactory;

  final Map<String, StorageDriver> _drivers = {};
  final ValueNotifier<Map<String, MountOnlineStatus>> onlineStatuses = ValueNotifier(const {});

  bool _showOfflineMounts = false;
  bool _monitoring = false;
  bool _disposed = false;
  StreamSubscription<Object?>? _connectivitySub;
  Future<void>? _activeProbeAll;

  VoidCallback? onReachabilityChanged;

  bool get showOfflineMounts => _showOfflineMounts;

  void setShowOfflineMounts(bool value) {
    if (_showOfflineMounts == value) return;
    _showOfflineMounts = value;
    onReachabilityChanged?.call();
  }

  MountOnlineStatus statusOf(String mountId) => onlineStatuses.value[mountId] ?? MountOnlineStatus.unknown;

  bool isMountOnline(String mountId) => statusOf(mountId) != MountOnlineStatus.offline;

  Set<String> get offlineMountIds => {
    for (final entry in onlineStatuses.value.entries)
      if (entry.value == MountOnlineStatus.offline) entry.key,
  };

  Set<String> get hiddenOfflineMountIds => _showOfflineMounts ? const {} : offlineMountIds;

  void setStatus(String mountId, MountOnlineStatus status) {
    if (_disposed || statusOf(mountId) == status) return;
    onlineStatuses.value = {...onlineStatuses.value, mountId: status};
  }

  /// Builds a driver for [mount] without registering it — for validating a
  /// mount the user is still editing. The caller closes it.
  StorageDriver createDriver(StorageMount mount, {bool? useFallback}) {
    final effectiveFallback = useFallback ?? (statusOf(mount.id) == MountOnlineStatus.onlineFallback);
    if (_driverFactory != null) {
      return _driverFactory(mount, useFallback: effectiveFallback);
    }
    return switch (mount.kind) {
      StorageKind.local => LocalStorageDriver.fromMount(mount),
      StorageKind.webdav => WebDavStorageDriver.fromMount(mount, useFallback: effectiveFallback),
      StorageKind.quark => QuarkStorageDriver.fromMount(
        mount,
        fallbackDevice: _pcFallbackDevice(mount),
        onCookieChanged: (cookie) => unawaited(_persistSecret(mount.id, MountKeys.secretCookie, cookie)),
      ),
      StorageKind.smb => SmbStorageDriver.fromMount(mount, useFallback: effectiveFallback),
    };
  }

  QuarkPcDevice? _pcFallbackDevice(StorageMount mount) {
    if (QuarkMode.parse(mount.configString(MountKeys.quarkMode)) != QuarkMode.pc) return null;
    final cached = QuarkPcDeviceStore.cached;
    if (cached != null) return cached;
    final secret = mount.secret(MountKeys.secretCookie);
    final candidate = (secret != null ? QuarkPcSession.tryParseDevice(secret) : null) ?? QuarkPcDevice.generate();
    unawaited(QuarkPcDeviceStore.adoptIfAbsent(candidate));
    return QuarkPcDeviceStore.cached ?? candidate;
  }

  /// The shared driver for [mount], created on first use.
  StorageDriver driverFor(StorageMount mount) => _drivers[mount.id] ??= createDriver(mount);

  /// A loopback URL players can open for [entry]. A [bulk] URL is for
  /// downloading the whole file and may be read over several connections.
  Future<Uri> streamUrl(StorageMount mount, StorageEntry entry, {bool bulk = false}) {
    return proxy.register(mountId: mount.id, driver: driverFor(mount), entry: entry, bulk: bulk);
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

  /// Updates tuning in place so existing transfers keep their stream and any
  /// new bulk reads use the new settings.
  Future<void> saveQuarkDownloadOptions(String mountId, {required int connections, required int chunkMiB}) async {
    final updated = await registry.updateQuarkDownloadOptions(mountId, connections: connections, chunkMiB: chunkMiB);
    if (!updated) throw const StorageException(StorageErrorKind.notFound, 'Quark mount no longer exists');
    final driver = _drivers[mountId];
    if (driver is QuarkStorageDriver) driver.updateDownloadOptions(connections: connections, chunkMiB: chunkMiB);
  }

  Future<void> remove(String mountId) async {
    await registry.remove(mountId);
    await _dropDriver(mountId);
    if (!_disposed && onlineStatuses.value.containsKey(mountId)) {
      final updated = Map<String, MountOnlineStatus>.from(onlineStatuses.value)..remove(mountId);
      onlineStatuses.value = updated;
    }
  }

  /// Probes whether [mount] (and any configured fallback URL/host) is reachable
  /// at the storage protocol level within [timeout].
  Future<MountOnlineStatus> probeMount(
    StorageMount mount, {
    Duration timeout = const Duration(milliseconds: 2000),
  }) async {
    switch (mount.kind) {
      case StorageKind.local:
        final driver = createDriver(mount, useFallback: false);
        try {
          await driver.check().timeout(timeout);
          return MountOnlineStatus.onlinePrimary;
        } catch (_) {
          return MountOnlineStatus.offline;
        } finally {
          await driver.close();
        }
      case StorageKind.quark:
        final driver = createDriver(mount, useFallback: false);
        try {
          await driver.check().timeout(timeout);
          return MountOnlineStatus.onlinePrimary;
        } on TimeoutException {
          return MountOnlineStatus.offline;
        } on SocketException {
          return MountOnlineStatus.offline;
        } on StorageException catch (e) {
          return e.kind == StorageErrorKind.network ? MountOnlineStatus.offline : MountOnlineStatus.onlinePrimary;
        } catch (_) {
          return MountOnlineStatus.onlinePrimary;
        } finally {
          await driver.close();
        }
      case StorageKind.webdav:
      case StorageKind.smb:
        final hasFallback = mount.configString(MountKeys.fallbackUrl) != null;
        final probes = await Future.wait([
          _probeEndpoint(mount, useFallback: false, timeout: timeout),
          if (hasFallback) _probeEndpoint(mount, useFallback: true, timeout: timeout),
        ]);
        final primary = probes.first;
        final fallback = hasFallback ? probes.last : null;
        if (primary.reachable && !primary.authFailed) return MountOnlineStatus.onlinePrimary;
        if (fallback != null && fallback.reachable && !fallback.authFailed) {
          return MountOnlineStatus.onlineFallback;
        }
        if (primary.authFailed) return MountOnlineStatus.onlinePrimary;
        if (fallback != null && fallback.authFailed) return MountOnlineStatus.onlineFallback;
        return MountOnlineStatus.offline;
    }
  }

  Future<({bool reachable, bool authFailed})> _probeEndpoint(
    StorageMount mount, {
    required bool useFallback,
    required Duration timeout,
  }) async {
    final StorageDriver driver;
    try {
      driver = createDriver(mount, useFallback: useFallback);
    } catch (_) {
      return (reachable: false, authFailed: false);
    }
    try {
      await driver.check().timeout(timeout);
      return (reachable: true, authFailed: false);
    } on StorageException catch (e) {
      if (e.kind == StorageErrorKind.unauthorized) {
        return (reachable: true, authFailed: true);
      }
      return (reachable: false, authFailed: false);
    } catch (_) {
      return (reachable: false, authFailed: false);
    } finally {
      await driver.close();
    }
  }

  /// Concurrently probes all configured mounts, updates [onlineStatuses],
  /// drops drivers whose active primary/fallback endpoint changed, and invokes
  /// [onReachabilityChanged] when visibility or routes changed.
  Future<void> probeAll({Duration timeout = const Duration(milliseconds: 2000)}) {
    final running = _activeProbeAll;
    if (running != null) return running;
    final job = _runProbeAll(timeout: timeout);
    _activeProbeAll = job;
    return job.whenComplete(() {
      if (identical(_activeProbeAll, job)) _activeProbeAll = null;
    });
  }

  Future<void> _runProbeAll({required Duration timeout}) async {
    if (_disposed) return;
    final mounts = await registry.list();
    if (_disposed) return;

    final previousHidden = Set<String>.from(hiddenOfflineMountIds);
    final previousStatuses = Map<String, MountOnlineStatus>.from(onlineStatuses.value);
    final activeIds = {for (final m in mounts) m.id};

    // Only mark unprobed mounts as probing so settled offline mounts don't flicker.
    final initial = <String, MountOnlineStatus>{
      for (final mount in mounts) mount.id: previousStatuses[mount.id] ?? MountOnlineStatus.probing,
    };
    onlineStatuses.value = initial;

    final results = await Future.wait([
      for (final mount in mounts) probeMount(mount, timeout: timeout).then((status) => (mount.id, status)),
    ]);
    if (_disposed) return;

    var routeChanged = false;
    final nextStatuses = <String, MountOnlineStatus>{};
    for (final (id, status) in results) {
      nextStatuses[id] = status;
      final prev = previousStatuses[id];
      final switchedRoute =
          (prev == MountOnlineStatus.onlinePrimary && status == MountOnlineStatus.onlineFallback) ||
          (prev == MountOnlineStatus.onlineFallback && status == MountOnlineStatus.onlinePrimary);
      if (switchedRoute) {
        routeChanged = true;
        await _dropDriver(id);
      }
    }

    // Remove deleted mounts that disappeared while probing.
    nextStatuses.removeWhere((id, _) => !activeIds.contains(id));
    onlineStatuses.value = nextStatuses;

    final nextHidden = hiddenOfflineMountIds;
    if (routeChanged || !setEquals(previousHidden, nextHidden)) {
      onReachabilityChanged?.call();
    }
  }

  /// Starts initial background probing and re-probes whenever network
  /// connectivity changes.
  void startReachabilityMonitor() {
    if (_monitoring || _disposed) return;
    _monitoring = true;
    unawaited(probeAll());
    _connectivitySub = ConnectivityProbe.changes.listen((_) {
      if (!_disposed) unawaited(probeAll());
    });
  }

  Future<void> dropCachedDriver(String mountId) async {
    await _dropDriver(mountId);
    if (!_disposed && onlineStatuses.value.containsKey(mountId)) {
      final updated = Map<String, MountOnlineStatus>.from(onlineStatuses.value)..remove(mountId);
      onlineStatuses.value = updated;
    }
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
    _disposed = true;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    onlineStatuses.dispose();
    await proxy.stop();
    final drivers = _drivers.values.toList();
    _drivers.clear();
    await Future.wait(drivers.map((d) => d.close()));
  }
}
