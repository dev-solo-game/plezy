import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../database/app_database.dart';
import '../storage/mount_manager.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_path.dart';
import 'library_repository.dart';
import 'library_scan_service.dart';
import 'library_scraper.dart';
import 'library_settings.dart';
import 'scrapers/bangumi_provider.dart';
import 'scrapers/scraped_metadata.dart';
import 'scrapers/scraper_http.dart';
import 'scrapers/tmdb_provider.dart';

/// Builds a [LibraryScraper] from the saved settings and runs it. One place
/// for the scan service, the manual-match UI and the retry action to get a
/// scraper that reflects what the user configured.
class LibraryScrapeRunner {
  LibraryScrapeRunner({
    required AppDatabase database,
    required LibraryRepository repository,
    required this.settings,
    this.mounts,
  }) : _db = database,
       _repo = repository;

  final AppDatabase _db;
  final LibraryRepository _repo;
  final LibrarySettingsStore settings;
  final MountManager? mounts;

  /// Returned by [scrapePending] when titles were left waiting because no
  /// TMDB key is set. The UI turns it into a localized prompt.
  static const String noTmdbKey = 'no-tmdb-key';

  /// Runs [action] with a scraper built from the current settings, closing
  /// its HTTP clients afterwards. Once [isCancelled] turns true the clients
  /// are closed at once, so a request waiting on a slow or unreachable host
  /// does not hold the run up.
  Future<T> withScraper<T>(
    Future<T> Function(LibraryScraper scraper, ScraperSettings settings) action, {
    bool Function()? isCancelled,
  }) async {
    final current = await settings.loadScraper();
    final providers = <MetadataProvider>[
      if (current.hasTmdb)
        TmdbProvider(
          apiKey: current.tmdbApiKey,
          language: current.language,
          apiBase: current.tmdbApiBase,
          imageBase: current.tmdbImageBase,
          http: ScraperHttp(proxy: current.proxy),
        ),
      if (current.bangumiEnabled)
        BangumiProvider(
          http: ScraperHttp(proxy: current.proxy, userAgent: 'local-media-library/1.0 (anime metadata lookup)'),
        ),
    ];
    void closeAll() {
      for (final provider in providers) {
        provider.close();
      }
    }

    final watch = isCancelled == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 200), (timer) {
            if (!isCancelled()) return;
            timer.cancel();
            closeAll();
          });
    Future<String?> readText(String mountId, String path) async {
      final manager = mounts;
      if (manager == null || !manager.isMountOnline(mountId)) return null;
      try {
        final mount = await manager.registry.get(mountId);
        if (mount == null) return null;
        final driver = manager.driverFor(mount);
        final entry = StorageEntry(path: path, name: StoragePath.name(path), isDirectory: false);
        const maxBytes = 512 * 1024;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in driver.openRead(entry, start: 0, end: maxBytes - 1)) {
          bytes.add(chunk);
          if (bytes.length >= maxBytes) break;
        }
        return utf8.decode(bytes.takeBytes(), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }

    try {
      return await action(
        LibraryScraper(_db, _repo, providers: providers, readText: mounts == null ? null : readText),
        current,
      );
    } finally {
      watch?.cancel();
      closeAll();
    }
  }

  /// Scrapes everything queued. Returns the outcome including any early-stop
  /// note (or [noTmdbKey]) and whether any titles changed match state.
  ///
  /// [retryUnmatched] first puts titles and episode files an earlier run
  /// could not match back in the queue.
  Future<LibraryScrapeOutcome> scrapePending({
    bool retryUnmatched = false,
    Set<String>? mountIds,
    bool refreshMatched = false,
    bool allowKindChange = true,
    int? refreshBeforeMs,
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) {
    return withScraper((scraper, current) async {
      if (retryUnmatched) await scraper.requeueUnmatched();
      final summary = await scraper.scrapePending(
        mountIds: mountIds,
        refreshMatched: refreshMatched,
        allowKindChange: allowKindChange,
        refreshBeforeMs: refreshBeforeMs,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
      final note = summary.stoppedBy ?? (summary.skipped > 0 && !current.hasTmdb ? noTmdbKey : null);
      return LibraryScrapeOutcome(note: note, hasChanges: summary.hasChanges);
    }, isCancelled: isCancelled);
  }
}
