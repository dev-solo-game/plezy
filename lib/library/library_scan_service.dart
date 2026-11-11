import 'dart:async';

import 'package:flutter/foundation.dart';

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
      bool Function()? isCancelled,
      void Function(int done, int total)? onProgress,
    });

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
/// One scan per mount at a time; different mounts may scan side by side.
/// Lookups cover the whole library and run one at a time.
class LibraryScanService extends ChangeNotifier {
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
  bool _disposed = false;

  MountScanStatus statusOf(String mountId) => _status[mountId] ?? const MountScanStatus();

  LibraryScrapeStatus get scrapeStatus => _scrapeStatus;

  bool isScanning(String mountId) => _running.containsKey(mountId);

  /// Scans [mount], then looks up what it found. Returns the result, or null
  /// when a scan of this mount is already running or this one failed (the
  /// failure is in [statusOf]).
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
      _libraryChanged();
      if (!result.cancelled) unawaited(scrapeLibrary());
      return result;
    } catch (e) {
      LibraryScanner.logFailure(mount, e);
      _running.remove(mount.id);
      _publish(mount.id, MountScanStatus(error: e is StorageException ? e.message : '$e'));
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
    final scrapeFn = scrape;
    if (scrapeFn == null) return Future.value();
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
          _publishScrape(LibraryScrapeStatus(running: true, runs: _scrapeStatus.runs));
          String? note;
          try {
            note = await scrapeFn(
              retryUnmatched: retry,
              isCancelled: () => _scrapeCancelled || _disposed,
              onProgress: (done, total) {
                _publishScrape(LibraryScrapeStatus(running: true, done: done, total: total, runs: _scrapeStatus.runs));
                final last = _lastLiveRefresh;
                if (done > 0 && (last == null || DateTime.now().difference(last) >= _liveRefreshInterval)) {
                  _libraryChanged();
                }
              },
            );
          } catch (e) {
            note = '$e';
          }
          // A stopped run fails whatever request it was in; that is not news.
          if (_scrapeCancelled) note = null;
          _publishScrape(LibraryScrapeStatus(note: note, runs: _scrapeStatus.runs + 1));
          _libraryChanged();
          retry = _retryUnmatchedAgain;
        } while (_scrapeAgain && !_disposed);
      } finally {
        _scrapeRun = null;
      }
    }();
  }

  /// Stops a running lookup after the title it is on.
  void cancelScrape() {
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
    for (final token in _running.values) {
      token.cancel();
    }
    super.dispose();
  }
}
