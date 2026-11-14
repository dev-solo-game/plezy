import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../storage/drivers/quark_storage_driver.dart';
import '../storage/mount_manager.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_mount.dart';
import 'library_repository.dart';
import 'library_scanner.dart';

/// Looks up metadata for every title waiting for it. Returns a message when
/// it had to stop early (no API key, network down), or null.
typedef LibraryScrapeFunction =
    Future<String?> Function({
      bool retryUnmatched,
      Set<String>? mountIds,
      bool refreshMatched,
      bool Function()? isCancelled,
      void Function(int done, int total)? onProgress,
    });

enum LibraryUpdateMode { incremental, full }

class LibraryUpdate {
  LibraryUpdate(this.mode, this.mountIds);

  final LibraryUpdateMode mode;
  final Set<String> mountIds;
  final cancel = ScanCancelToken();
  final _finished = Completer<void>();
  final scrapingMounts = <String>{};
  bool scraping = false;
  int? filesSeen;
  int scraped = 0;
  int scrapeTotal = 0;
  String? _error;
  bool _refreshWhenFinished = false;
  bool get isBackground => mode == LibraryUpdateMode.incremental;
}

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

/// What the UI shows for metadata lookup, which covers the whole library
/// rather than one mount.
class LibraryScrapeStatus {
  const LibraryScrapeStatus({this.running = false, this.done = 0, this.total = 0, this.note, this.runs = 0});

  final bool running;
  final int done;
  final int total;

  /// Why the last run stopped early, when it did.
  final String? note;

  /// Counts finished runs, so views can tell that the library changed.
  final int runs;
}

/// Runs library scans and metadata lookups and publishes their progress.
/// Individual scans can run side by side. A media library update owns the scanner
/// through both traversal and metadata lookup.
class LibraryScanService extends ChangeNotifier {
  static const automaticInterval = Duration(minutes: 1);

  LibraryScanService({
    required this.repository,
    required LibraryScanner scanner,
    required MountManager mounts,
    this.scrape,
    this.onLibraryChanged,
  }) : _libraryScanner = scanner,
       _mountManager = mounts;

  final LibraryScrapeFunction? scrape;

  /// Called when a scan or scrape changed what the library holds.
  void Function()? onLibraryChanged;

  final Set<VoidCallback> _libraryListeners = {};

  /// Registers [listener] to run, like [onLibraryChanged], whenever what the
  /// library holds changed. Views that show library content (the library
  /// list, the home hubs) each add one.
  void addLibraryListener(VoidCallback listener) => _libraryListeners.add(listener);

  void removeLibraryListener(VoidCallback listener) => _libraryListeners.remove(listener);

  /// While a lookup runs, titles land on their shelves one by one; views are
  /// told at most this often, so they fill in without reloading per title.
  static const Duration _liveRefreshInterval = Duration(seconds: 5);
  DateTime? _lastLiveRefresh;

  /// Tells every view that the library changed outside a scan or lookup:
  /// a manual match, a removed mount.
  void notifyLibraryChanged() => _libraryChanged();

  void _libraryChanged() {
    if (_disposed) return;
    _lastLiveRefresh = DateTime.now();
    onLibraryChanged?.call();
    for (final listener in _libraryListeners.toList()) {
      listener();
    }
  }

  final LibraryRepository repository;
  final LibraryScanner _libraryScanner;
  final MountManager _mountManager;

  final Map<String, MountScanStatus> _status = {};
  final Map<String, ScanCancelToken> _running = {};
  LibraryScrapeStatus _scrapeStatus = const LibraryScrapeStatus();
  Future<void>? _scrapeRun;
  bool _scrapeAgain = false;
  bool _retryUnmatchedAgain = false;
  bool _scrapeCancelled = false;
  bool _scrapeAfterUpdate = false;
  bool _retryUnmatchedAfterUpdate = false;
  bool _disposed = false;
  LibraryUpdate? _update;
  ({LibraryUpdateMode mode, String message})? _updateError;
  bool _checkingAutomatic = false;
  DateTime? _automaticPausedUntil;
  final _automaticFailures = <String, ({int attempts, DateTime retryAt, String? rejectedCookie})>{};

  LibraryUpdate? get update => _update;
  ({LibraryUpdateMode mode, String message})? get updateError => _updateError;

  int? get standaloneScanFiles {
    if (_update != null || _running.isEmpty) return null;
    return _running.keys.fold<int>(0, (total, id) => total + (_status[id]?.progress?.filesSeen ?? 0));
  }

  bool canScan(String mountId) => _update == null && !_running.containsKey(mountId);

  static bool supportsIncremental(StorageMount mount) =>
      mount.kind == StorageKind.quark && QuarkMode.parse(mount.configString(MountKeys.quarkMode)).supportsIncremental;

  Future<bool> hasIncrementalBaseline(StorageMount mount) => _libraryScanner.hasQuarkBaseline(mount);

  Future<Duration> checkIncrementalUpdates({required bool Function() canRun, bool force = false}) async {
    if (_disposed || _checkingAutomatic || _update != null || _running.isNotEmpty || !canRun()) {
      return automaticInterval;
    }
    final now = clock.now();
    final pausedUntil = _automaticPausedUntil;
    if (!force && pausedUntil != null && now.isBefore(pausedUntil)) return pausedUntil.difference(now);
    _checkingAutomatic = true;
    try {
      var nextCheck = automaticInterval;
      final due = <StorageMount>[];
      final mounts = await _mountManager.registry.list();
      _automaticFailures.removeWhere((id, _) => !mounts.any((mount) => mount.id == id));
      for (final mount in mounts) {
        final cookie = mount.secret(MountKeys.secretCookie);
        if (!supportsIncremental(mount) || cookie == null) continue;
        final lastScan = await _libraryScanner.quarkLastSuccessfulScan(mount);
        if (lastScan == null) continue;
        final failure = _automaticFailures[mount.id];
        if (failure?.rejectedCookie == cookie) continue;
        if (failure != null && now.isBefore(failure.retryAt) && failure.rejectedCookie == null) continue;
        final elapsed = now.difference(lastScan);
        if (!force && !elapsed.isNegative && elapsed < automaticInterval) {
          final remaining = automaticInterval - elapsed;
          if (remaining < nextCheck) nextCheck = remaining;
          continue;
        }
        due.add(mount);
      }
      if (canRun()) await _updateMounts(due, LibraryUpdateMode.incremental, canRun: canRun);
      return nextCheck;
    } finally {
      _checkingAutomatic = false;
    }
  }

  Future<bool> updateMounts(List<StorageMount> mounts, LibraryUpdateMode mode) => _updateMounts(mounts, mode);

  Future<bool> scanAllMounts() async {
    final mounts = await _mountManager.registry.list();
    if (_disposed) return false;
    if (mounts.isEmpty) {
      _libraryChanged();
      return true;
    }
    return _updateMounts(mounts, LibraryUpdateMode.full, refreshWhenFinished: true);
  }

  Future<bool> _updateMounts(
    List<StorageMount> mounts,
    LibraryUpdateMode mode, {
    bool Function()? canRun,
    bool refreshWhenFinished = false,
  }) async {
    final running = _update;
    if (mode == LibraryUpdateMode.full && running != null && running.isBackground) {
      running.cancel.cancel();
      await running._finished.future;
    }
    if (_disposed || _update != null || _running.isNotEmpty || mounts.isEmpty) return false;
    final job = _update = LibraryUpdate(mode, mounts.map((mount) => mount.id).toSet())
      .._refreshWhenFinished = refreshWhenFinished;
    _updateError = null;
    notifyListeners();
    try {
      await _scrapeRun;
      for (final mount in mounts) {
        if (job.cancel.isCancelled || canRun?.call() == false) break;
        final current = await _mountManager.registry.get(mount.id);
        if (job.cancel.isCancelled || canRun?.call() == false) break;
        if (current == null) continue;
        if (mode == LibraryUpdateMode.incremental && !supportsIncremental(current)) continue;
        if (canRun != null && current.secret(MountKeys.secretCookie) != mount.secret(MountKeys.secretCookie)) continue;
        final result = await _scan(current, token: job.cancel, mode: mode);
        if (result != null && !result.cancelled) job.scrapingMounts.add(current.id);
      }
      if (!job.cancel.isCancelled && !_scrapeAfterUpdate && job.scrapingMounts.isNotEmpty && scrape != null) {
        job.scraping = true;
        _scrapeCancelled = false;
        if (!_disposed) notifyListeners();
        await _runScrape(
          mountIds: job.scrapingMounts,
          refreshMatched: mode == LibraryUpdateMode.full,
          cancel: job.cancel,
          silent: job.isBackground,
        );
      }
      return true;
    } catch (error) {
      job._error ??= '$error';
      rethrow;
    } finally {
      _update = null;
      final error = job._error;
      if (error != null && !job.cancel.isCancelled) _updateError = (mode: mode, message: error);
      job._finished.complete();
      if (!_disposed) {
        if (job._refreshWhenFinished) _libraryChanged();
        if (_scrapeAfterUpdate) {
          final retry = _retryUnmatchedAfterUpdate;
          _scrapeAfterUpdate = false;
          _retryUnmatchedAfterUpdate = false;
          unawaited(scrapeLibrary(retryUnmatched: retry));
        }
        notifyListeners();
      }
    }
  }

  void cancelUpdate(LibraryUpdate job) {
    if (_update != job) return;
    _automaticPausedUntil = clock.now().add(automaticInterval);
    job.cancel.cancel();
    if (!_disposed) notifyListeners();
  }

  MountScanStatus statusOf(String mountId) => _status[mountId] ?? const MountScanStatus();

  LibraryScrapeStatus get scrapeStatus => _scrapeStatus;

  bool isScanning(String mountId) => _running.containsKey(mountId);

  /// Scans [mount], then looks up what it found. Returns the result, or null
  /// when a scan of this mount is already running or this one failed (the
  /// failure is in [statusOf]).
  Future<ScanResult?> scan(StorageMount mount) async {
    final running = _update;
    if (running != null && running.isBackground) {
      running.cancel.cancel();
      await running._finished.future;
    }
    if (_disposed) return null;
    if (!canScan(mount.id)) return null;
    _updateError = null;
    final result = await _scan(mount, token: ScanCancelToken());
    if (result != null && !result.cancelled) unawaited(scrapeLibrary());
    return result;
  }

  Future<ScanResult?> _scan(StorageMount mount, {required ScanCancelToken token, LibraryUpdateMode? mode}) async {
    final silent = mode == LibraryUpdateMode.incremental;
    final job = _update;
    _running[mount.id] = token;
    if (job != null) {
      job.filesSeen = 0;
      if (silent && !_disposed) notifyListeners();
    }
    if (!silent) {
      _publish(
        mount.id,
        const MountScanStatus(progress: ScanProgress(directoriesDone: 0, filesSeen: 0, currentPath: '/')),
      );
    }

    try {
      final driver = _mountManager.driverFor(mount);
      void onProgress(ScanProgress progress) {
        final previous = job?.filesSeen;
        if (job != null) job.filesSeen = progress.filesSeen;
        if (!silent) {
          _publish(mount.id, MountScanStatus(progress: progress));
        } else if (!_disposed && previous != progress.filesSeen) {
          notifyListeners();
        }
      }

      final result = mode == LibraryUpdateMode.incremental
          ? await _libraryScanner.scanQuarkIncremental(
              mount,
              driver as QuarkStorageDriver,
              cancel: token,
              onProgress: onProgress,
            )
          : await _libraryScanner.scan(
              mount,
              driver,
              cancel: token,
              onProgress: onProgress,
              restart: mode == LibraryUpdateMode.full,
            );
      _running.remove(mount.id);
      if (!result.cancelled) _automaticFailures.remove(mount.id);
      if (!silent || result.hasChanges) _publish(mount.id, MountScanStatus(lastResult: result));
      if (job?._refreshWhenFinished != true && (!silent || result.hasChanges)) _libraryChanged();
      return result;
    } catch (e) {
      _running.remove(mount.id);
      if (token.isCancelled) {
        if (!silent) _publish(mount.id, const MountScanStatus());
        return null;
      }
      LibraryScanner.logFailure(mount, e);
      if (mount.kind == StorageKind.quark) {
        final attempts = ((_automaticFailures[mount.id]?.attempts ?? 0) + 1).clamp(1, 4);
        _automaticFailures[mount.id] = (
          attempts: attempts,
          retryAt: clock.now().add(automaticInterval * (1 << attempts)),
          rejectedCookie: e is StorageException && e.kind == StorageErrorKind.unauthorized
              ? mount.secret(MountKeys.secretCookie)
              : null,
        );
      }
      final message = e is StorageException ? e.message : '$e';
      if (job != null) {
        job._error ??= message;
      } else {
        _updateError = (mode: LibraryUpdateMode.full, message: message);
      }
      if (!silent) _publish(mount.id, MountScanStatus(error: message));
      return null;
    }
  }

  /// Re-files every mount's videos under the current naming rules from the
  /// names already stored, without listing any mount, then looks up what
  /// moved. Returns how many files moved.
  Future<int> refileAll() async {
    var moved = 0;
    for (final mount in await _mountManager.registry.list()) {
      if (_running.containsKey(mount.id)) continue;
      moved += await _libraryScanner.refileFromNames(mount.id);
    }
    if (moved > 0) _libraryChanged();
    return moved;
  }

  /// Asks a running scan to stop after the directory it is on.
  void cancel(String mountId) => _running[mountId]?.cancel();

  /// Looks up every title waiting for metadata. Only the metadata sources
  /// are asked; no mount is read. A call while a run is going makes it run
  /// once more afterwards, so titles added meanwhile are not missed.
  /// [retryUnmatched] also retries titles earlier runs could not match.
  /// [restart] stops a run that is going after its current title and starts
  /// over at once, for when the settings it was started with changed.
  Future<void> scrapeLibrary({bool retryUnmatched = false, bool restart = false}) {
    if (_disposed || scrape == null) return Future.value();
    if (_update != null) {
      _scrapeAfterUpdate = true;
      _retryUnmatchedAfterUpdate |= retryUnmatched;
      if (restart) _scrapeCancelled = true;
      return Future.value();
    }
    final running = _scrapeRun;
    if (running != null) {
      _scrapeAgain = true;
      _retryUnmatchedAgain |= retryUnmatched;
      if (restart) _scrapeCancelled = true;
      return running;
    }
    return _scrapeRun = () async {
      var retry = retryUnmatched;
      try {
        do {
          _scrapeAgain = false;
          _retryUnmatchedAgain = false;
          _scrapeCancelled = false;
          await _runScrape(retryUnmatched: retry);
          retry = _retryUnmatchedAgain;
        } while (_scrapeAgain && !_disposed);
      } finally {
        _scrapeRun = null;
      }
    }();
  }

  Future<void> _runScrape({
    bool retryUnmatched = false,
    Set<String>? mountIds,
    bool refreshMatched = false,
    ScanCancelToken? cancel,
    bool silent = false,
  }) async {
    final job = cancel == null ? null : _update;
    bool isCancelled() => _disposed || _scrapeCancelled || cancel?.isCancelled == true;
    if (!silent) _publishScrape(LibraryScrapeStatus(running: true, runs: _scrapeStatus.runs));
    String? note;
    var hadWork = false;
    try {
      note = await scrape!(
        retryUnmatched: retryUnmatched,
        mountIds: mountIds,
        refreshMatched: refreshMatched,
        isCancelled: isCancelled,
        onProgress: (done, total) {
          hadWork |= done > 0;
          final progressChanged = job != null && (job.scraped != done || job.scrapeTotal != total);
          if (progressChanged) {
            job.scraped = done;
            job.scrapeTotal = total;
          }
          if (silent) {
            if (progressChanged && !_disposed) notifyListeners();
            return;
          }
          _publishScrape(LibraryScrapeStatus(running: true, done: done, total: total, runs: _scrapeStatus.runs));
          if (job?._refreshWhenFinished == true) return;
          final last = _lastLiveRefresh;
          if (done > 0 && (last == null || DateTime.now().difference(last) >= _liveRefreshInterval)) {
            _libraryChanged();
          }
        },
      );
    } catch (e) {
      note = '$e';
    }
    if (job != null && !isCancelled()) job._error ??= note;
    if (!silent) {
      _publishScrape(LibraryScrapeStatus(note: isCancelled() ? null : note, runs: _scrapeStatus.runs + 1));
    }
    if (job?._refreshWhenFinished != true && (mountIds == null || hadWork)) _libraryChanged();
  }

  /// Stops a running lookup after the title it is on.
  void cancelScrape() {
    if (_update case final job? when job.scraping) {
      cancelUpdate(job);
      return;
    }
    _scrapeCancelled = true;
    _scrapeAgain = false;
  }

  void _publish(String mountId, MountScanStatus status) {
    if (_disposed) return;
    _status[mountId] = status;
    notifyListeners();
  }

  void _publishScrape(LibraryScrapeStatus status) {
    if (_disposed) return;
    _scrapeStatus = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _update?.cancel.cancel();
    for (final token in _running.values) {
      token.cancel();
    }
    super.dispose();
  }
}
