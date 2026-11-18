import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../library/sync/sync_coordinator.dart';
import '../library/sync/sync_models.dart';
import 'app_icon.dart';

/// Formats a localized status line for an active [SyncProgress].
String? formatSyncProgressDetail(Translations translations, SyncProgress progress) {
  final syncStrings = translations.sync;
  return switch (progress.phase) {
    SyncPhase.idle => null,
    SyncPhase.connecting || SyncPhase.pulling =>
      progress.processed > 0 ? syncStrings.phaseApplyingCount(count: progress.processed) : syncStrings.phaseFetching,
    SyncPhase.applying => progress.total > 0
        ? syncStrings.phaseApplyingProgress(done: progress.processed, total: progress.total)
        : (progress.processed > 0
            ? syncStrings.phaseApplyingCount(count: progress.processed)
            : syncStrings.phaseApplying),
    SyncPhase.pushing => progress.total > 0
        ? syncStrings.phasePushingProgress(done: progress.processed, total: progress.total)
        : syncStrings.phasePushing,
    SyncPhase.probingMounts => syncStrings.phaseProbingMounts,
  };
}

/// Compact top-bar indicator displaying active sync progress, local library scan
/// or scrape progress, or the latest sync/scan failure.
class LibraryStatusIndicator extends StatelessWidget {
  const LibraryStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final scans = context.watch<LibraryScanService?>();
    final sync = context.watch<SyncAndScanCoordinator?>();

    final status = _resolveStatus(scans, sync);
    if (status == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = status.failed ? theme.colorScheme.error : theme.colorScheme.onSurface;
    final text = status.failed
        ? '${status.label} · ${t.common.error}'
        : (status.detail.isEmpty ? status.label : '${status.label} · ${status.detail}');

    return Tooltip(
      message: status.detail.isEmpty ? status.label : '${status.label}\n${status.detail}',
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status.failed)
              AppIcon(Symbols.error_outline_rounded, color: color, size: 14)
            else
              const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static ({String label, String detail, bool failed})? _resolveStatus(
    LibraryScanService? scans,
    SyncAndScanCoordinator? sync,
  ) {
    final syncProgress = sync?.progress;
    if (sync != null && syncProgress != null && syncProgress.isActive) {
      final label = sync.isSignedIn
          ? t.sync.progressCloud
          : (syncProgress.peerName != null && syncProgress.peerName!.isNotEmpty
                ? t.sync.progressLanWithPeer(peer: syncProgress.peerName!)
                : t.sync.progressLan);
      final detail = formatSyncProgressDetail(t, syncProgress) ?? '';
      return (label: label, detail: detail, failed: false);
    }

    final job = scans?.update;
    final files = job?.filesSeen ?? scans?.standaloneScanFiles;
    final scanError = scans?.updateError;
    if (job != null || files != null) {
      final mode = job?.mode ?? scanError?.mode ?? LibraryUpdateMode.full;
      final label = mode == LibraryUpdateMode.incremental ? t.storage.incrementalUpdate : t.storage.fullUpdate;
      final progress = switch (job) {
        LibraryUpdate(cancel: final cancel) when cancel.isCancelled => t.storage.cancellingUpdate,
        LibraryUpdate(scanning: true, scraping: true, :final scraped, :final scrapeTotal) when files != null =>
          '${t.storage.scanning(files: files)} · ${scrapeTotal == 0 ? t.storage.scraping : t.storage.scrapingProgress(done: scraped, total: scrapeTotal)}',
        LibraryUpdate(scraping: true, :final scraped, :final scrapeTotal) =>
          scrapeTotal == 0 ? t.storage.scraping : t.storage.scrapingProgress(done: scraped, total: scrapeTotal),
        _ when files != null => t.storage.scanning(files: files),
        _ => t.storage.waitingToUpdate(mode: label),
      };
      return (label: label, detail: progress, failed: false);
    }

    final syncError = sync?.lastError;
    if (sync != null && syncError != null && syncError.isNotEmpty) {
      final label = sync.isSignedIn ? t.sync.progressCloud : t.sync.progressLan;
      return (label: label, detail: syncError, failed: true);
    }

    if (scanError != null) {
      final label = scanError.mode == LibraryUpdateMode.incremental
          ? t.storage.incrementalUpdate
          : t.storage.fullUpdate;
      final detail = scanError.message == LibraryScrapeRunner.noTmdbKey ? t.storage.scrapeNoKey : scanError.message;
      return (label: label, detail: detail, failed: true);
    }

    return null;
  }
}
