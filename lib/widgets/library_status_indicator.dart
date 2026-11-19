import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../library/library_settings.dart';
import '../screens/storage/scraper_settings_screen.dart';
import 'app_icon.dart';

/// Compact top-bar indicator displaying local library scan or scrape progress,
/// or the latest scan/scrape failure.
class LibraryStatusIndicator extends StatelessWidget {
  const LibraryStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final scans = context.watch<LibraryScanService?>();

    final status = _resolveStatus(scans);
    if (status == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = status.failed ? theme.colorScheme.error : theme.colorScheme.onSurface;
    final canOpenSettings = status.isNoTmdbKey && Provider.of<LibrarySettingsStore?>(context, listen: false) != null;

    Widget content = Padding(
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
              status.inlineText,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (canOpenSettings) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ScraperSettingsScreen())),
          child: content,
        ),
      );
    }

    return Tooltip(message: status.tooltip, child: content);
  }

  static ({String inlineText, String tooltip, bool failed, bool isNoTmdbKey})? _resolveStatus(
    LibraryScanService? scans,
  ) {
    final job = scans?.update;
    final files = job?.filesSeen ?? scans?.standaloneScanFiles;
    final scanError = scans?.updateError;
    final scrapeStatus = scans?.scrapeStatus;
    if (job != null || files != null) {
      final mode = job?.mode ?? scanError?.mode ?? LibraryUpdateMode.full;
      final scanLabel = mode == LibraryUpdateMode.incremental ? t.storage.incrementalUpdate : t.storage.fullUpdate;
      final isCancelled = job != null && job.cancel.isCancelled;
      final isScraping = (job?.scraping ?? false) || (scrapeStatus?.running ?? false);
      final done = (job?.scraping ?? false) ? job!.scraped : (scrapeStatus?.done ?? 0);
      final total = (job?.scraping ?? false) ? job!.scrapeTotal : (scrapeStatus?.total ?? 0);

      final String line1;
      if (isCancelled) {
        line1 = '$scanLabel · ${t.storage.cancellingUpdate}';
      } else if ((job == null || job.scanning) && files != null) {
        line1 = job != null ? '$scanLabel · ${t.storage.scanning(files: files)}' : t.storage.scanning(files: files);
      } else if (job != null && !job.scanning) {
        line1 = files != null && files > 0
            ? '$scanLabel · ${t.storage.scanCompletedFiles(files: files)}'
            : '$scanLabel · ${t.storage.scanCompleted}';
      } else {
        line1 = t.storage.waitingToUpdate(mode: scanLabel);
      }

      String? line2;
      if (!isCancelled) {
        if (isScraping) {
          final scrapeDetail = total > 0 ? t.storage.scrapingProgress(done: done, total: total) : t.storage.scraping;
          line2 = '${t.storage.scrapeTitle} · $scrapeDetail';
        } else if (scrapeStatus?.note case final note?) {
          final noteMsg = note == LibraryScrapeRunner.noTmdbKey
              ? t.storage.scrapeNoKey
              : t.storage.scrapeStopped(message: note);
          line2 = '${t.storage.scrapeTitle} · $noteMsg';
        } else {
          line2 = '${t.storage.scrapeTitle} · ${t.storage.waitingToScrape}';
        }
      }

      final String inlineText;
      if (isCancelled) {
        inlineText = '$scanLabel · ${t.storage.cancellingUpdate}';
      } else if ((job == null || job.scanning) && files != null && isScraping) {
        final scrapeShort = total > 0 ? t.storage.scrapeShort(done: done, total: total) : t.storage.scrapeTitle;
        inlineText = '${t.storage.scanShort(files: files)} · $scrapeShort';
      } else if (isScraping) {
        inlineText = total > 0 ? t.storage.scrapingProgress(done: done, total: total) : t.storage.scraping;
      } else if (files != null) {
        inlineText = job != null
            ? '$scanLabel · ${t.storage.scanning(files: files)}'
            : t.storage.scanning(files: files);
      } else {
        inlineText = t.storage.waitingToUpdate(mode: scanLabel);
      }

      return (
        inlineText: inlineText,
        tooltip: line2 == null ? line1 : '$line1\n$line2',
        failed: false,
        isNoTmdbKey: false,
      );
    }

    if (scrapeStatus != null && scrapeStatus.running) {
      final detail = scrapeStatus.total > 0
          ? t.storage.scrapingProgress(done: scrapeStatus.done, total: scrapeStatus.total)
          : t.storage.scraping;
      return (inlineText: detail, tooltip: '${t.storage.scrapeTitle} · $detail', failed: false, isNoTmdbKey: false);
    }

    if (scanError != null) {
      final label = scanError.mode == LibraryUpdateMode.incremental
          ? t.storage.incrementalUpdate
          : t.storage.fullUpdate;
      final isNoKey = scanError.message == LibraryScrapeRunner.noTmdbKey;
      final detail = isNoKey ? t.storage.scrapeNoKey : scanError.message;
      return (
        inlineText: '$label · ${isNoKey ? t.storage.tmdbTestNoKey : t.common.error}',
        tooltip: '$label\n$detail',
        failed: true,
        isNoTmdbKey: isNoKey,
      );
    }

    final scrapeNote = scrapeStatus?.note;
    if (scrapeNote != null) {
      final isNoKey = scrapeNote == LibraryScrapeRunner.noTmdbKey;
      final detail = isNoKey ? t.storage.scrapeNoKey : t.storage.scrapeStopped(message: scrapeNote);
      return (
        inlineText: '${t.storage.scrapeTitle} · ${isNoKey ? t.storage.tmdbTestNoKey : t.common.error}',
        tooltip: '${t.storage.scrapeTitle}\n$detail',
        failed: true,
        isNoTmdbKey: isNoKey,
      );
    }

    return null;
  }
}
