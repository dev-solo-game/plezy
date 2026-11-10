import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/mount_manager.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_mount.dart';
import 'library_repository.dart';
import 'library_scanner.dart';

/// What the UI shows for one mount's scanning.
class MountScanStatus {
  const MountScanStatus({this.progress, this.error, this.lastResult});

  /// Non-null while a scan is running.
  final ScanProgress? progress;

  /// Why the last scan stopped, when it failed.
  final String? error;
  final ScanResult? lastResult;

  bool get isRunning => progress != null;
}

/// Runs library scans and publishes their progress. One scan per mount at a
/// time; different mounts may scan side by side.
class LibraryScanService extends ChangeNotifier {
  LibraryScanService({required this.repository, required LibraryScanner scanner, required MountManager mounts})
    : _libraryScanner = scanner,
      _mountManager = mounts;

  final LibraryRepository repository;
  final LibraryScanner _libraryScanner;
  final MountManager _mountManager;

  final Map<String, MountScanStatus> _status = {};
  final Map<String, ScanCancelToken> _running = {};
  bool _disposed = false;

  MountScanStatus statusOf(String mountId) => _status[mountId] ?? const MountScanStatus();

  bool isScanning(String mountId) => _running.containsKey(mountId);

  /// Scans [mount]. Returns the result, or null when a scan of this mount is
  /// already running or this one failed (the failure is in [statusOf]).
  Future<ScanResult?> scan(StorageMount mount) async {
    if (_running.containsKey(mount.id)) return null;
    final token = ScanCancelToken();
    _running[mount.id] = token;
    _publish(
      mount.id,
      const MountScanStatus(progress: ScanProgress(directoriesDone: 0, filesSeen: 0, currentPath: '/')),
    );

    try {
      final result = await _libraryScanner.scan(
        mount,
        _mountManager.driverFor(mount),
        cancel: token,
        onProgress: (progress) => _publish(mount.id, MountScanStatus(progress: progress)),
      );
      _running.remove(mount.id);
      _publish(mount.id, MountScanStatus(lastResult: result));
      return result;
    } catch (e) {
      LibraryScanner.logFailure(mount, e);
      _running.remove(mount.id);
      _publish(mount.id, MountScanStatus(error: e is StorageException ? e.message : '$e'));
      return null;
    }
  }

  /// Asks a running scan to stop after the directory it is on.
  void cancel(String mountId) => _running[mountId]?.cancel();

  void _publish(String mountId, MountScanStatus status) {
    if (_disposed) return;
    _status[mountId] = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _running.values) {
      token.cancel();
    }
    super.dispose();
  }
}
