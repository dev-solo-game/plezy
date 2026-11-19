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
import 'scrapers/scraped_metadata.dart';
import 'scrapers/server_metadata_provider.dart';

typedef MetadataEndpointResolver = Future<({String serverUrl, String? accessToken, bool isOfficial})?> Function();

/// Builds a [LibraryScraper] routed through `media_server` public metadata
/// endpoints and runs library/manual matching and lazy detail hydration.
class LibraryScrapeRunner {
  LibraryScrapeRunner({
    required AppDatabase database,
    required LibraryRepository repository,
    required this.settings,
    this.mounts,
    this.resolveMetadataEndpoint,
    this.onImageBaseUpdated,
  }) : _db = database,
       _repo = repository;

  final AppDatabase _db;
  final LibraryRepository _repo;
  final LibrarySettingsStore settings;
  final MountManager? mounts;
  final MetadataEndpointResolver? resolveMetadataEndpoint;
  final void Function(String imageBase)? onImageBaseUpdated;
  final Map<int, Future<bool>> _inFlightHydrations = {};

  /// Returned by [scrapePending] when titles were left waiting because no
  /// TMDB key is configured on the server.
  static const String noTmdbKey = 'no-tmdb-key';

  Future<({String serverUrl, String? accessToken, bool isOfficial})> resolveActiveMetadataEndpoint() async {
    final resolved = await resolveMetadataEndpoint?.call();
    if (resolved != null && resolved.serverUrl.trim().isNotEmpty) {
      return resolved;
    }
    return (serverUrl: ServerMetadataProvider.defaultOfficialMetadataUrl, accessToken: null, isOfficial: true);
  }

  Future<({String serverUrl, bool isOfficial, ServerMetadataConfig config})> checkMetadataServerConnection() async {
    final endpoint = await resolveActiveMetadataEndpoint();
    final cfg = await ServerMetadataProvider.fetchConfig(
      serverUrl: endpoint.serverUrl,
      accessToken: endpoint.accessToken,
    );
    if (cfg.tmdbImageBase.isNotEmpty) {
      onImageBaseUpdated?.call(cfg.tmdbImageBase);
    }
    return (serverUrl: endpoint.serverUrl, isOfficial: endpoint.isOfficial, config: cfg);
  }

  /// Lazily fills heavy details (`summary`, `tagline`, `credits`, episode
  /// overviews) for an item, deduplicating concurrent requests for the same
  /// root ID.
  Future<bool> hydrateItemDetailsIfNeeded(int itemId) async {
    final initial = (await _repo.getItem(itemId))?.item;
    if (initial == null) return false;
    final rootId = (initial.kind == LibraryKinds.season || initial.kind == LibraryKinds.episode)
        ? (initial.showId ?? initial.parentId ?? initial.id)
        : initial.id;
    final existing = _inFlightHydrations[rootId];
    if (existing != null) return existing;

    final future = withScraper((scraper, _) => scraper.hydrateWorkDetailsById(rootId));
    _inFlightHydrations[rootId] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightHydrations[rootId], future)) {
        unawaited(_inFlightHydrations.remove(rootId));
      }
    }
  }

  /// Runs [action] with a scraper backed by the official `media_server`
  /// public metadata endpoint, closing HTTP clients on completion or cancel.
  Future<T> withScraper<T>(
    Future<T> Function(LibraryScraper scraper, ScraperSettings settings) action, {
    bool Function()? isCancelled,
  }) async {
    final current = await settings.loadScraper();
    final endpoint = await resolveActiveMetadataEndpoint();
    final providers = <MetadataProvider>[
      ServerMetadataProvider(
        serverUrl: endpoint.serverUrl,
        source: 'all',
        language: current.language,
        accessToken: endpoint.accessToken,
        onImageBaseDiscovered: onImageBaseUpdated,
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
      final note = summary.stoppedByMissingKey ? noTmdbKey : summary.stoppedBy;
      return LibraryScrapeOutcome(note: note, hasChanges: summary.hasChanges);
    }, isCancelled: isCancelled);
  }
}
