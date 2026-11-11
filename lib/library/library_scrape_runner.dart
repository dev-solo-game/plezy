import 'dart:async';

import '../database/app_database.dart';
import 'library_repository.dart';
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
  LibraryScrapeRunner({required AppDatabase database, required LibraryRepository repository, required this.settings})
    : _db = database,
      _repo = repository;

  final AppDatabase _db;
  final LibraryRepository _repo;
  final LibrarySettingsStore settings;

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
    try {
      return await action(LibraryScraper(_db, _repo, providers: providers), current);
    } finally {
      watch?.cancel();
      closeAll();
    }
  }

  /// Scrapes everything queued. Returns null when the run completed, a
  /// message when it stopped early, or [noTmdbKey].
  ///
  /// [retryUnmatched] first puts titles an earlier run could not match back
  /// in the queue.
  Future<String?> scrapePending({
    bool retryUnmatched = false,
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) {
    return withScraper((scraper, current) async {
      if (retryUnmatched) await scraper.requeueUnmatched();
      final summary = await scraper.scrapePending(isCancelled: isCancelled, onProgress: onProgress);
      if (summary.stoppedBy != null) return summary.stoppedBy;
      return summary.skipped > 0 && !current.hasTmdb ? noTmdbKey : null;
    }, isCancelled: isCancelled);
  }
}
