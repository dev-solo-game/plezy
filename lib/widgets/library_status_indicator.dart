import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../library/library_settings.dart';
import '../library_cloud/scan_session_runner.dart';
import '../screens/sources/cloud_sources_screen.dart';
import '../screens/storage/scraper_settings_screen.dart';
import '../ttplay/ttplay_session_binder.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';

/// Compact top-bar indicator displaying local or cloud library scan/scrape
/// progress, cloud projection sync activity, or the latest failure.
class LibraryStatusIndicator extends StatelessWidget {
  const LibraryStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    LibraryScanService? scans;
    try {
      scans = context.watch<LibraryScanService?>();
    } on ProviderNotFoundException {
      scans = null;
    }

    TtplaySessionBinder? binder;
    try {
      binder = context.watch<TtplaySessionBinder?>();
    } on ProviderNotFoundException {
      binder = null;
    }

    final status = _resolveStatus(scans, binder);
    if (status == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = status.failed ? theme.colorScheme.error : theme.colorScheme.onSurface;
    final canOpenSettings = status.isNoTmdbKey && Provider.of<LibrarySettingsStore?>(context, listen: false) != null;
    final canOpenCloudSources = status.openCloudSources && !PlatformDetector.isTV();

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

    final VoidCallback? onTap = canOpenSettings
        ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ScraperSettingsScreen()))
        : canOpenCloudSources
        ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloudSourcesScreen()))
        : null;

    if (onTap != null) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
      );
    }

    return Tooltip(message: status.tooltip, child: content);
  }

  static ({String inlineText, String tooltip, bool failed, bool isNoTmdbKey, bool openCloudSources})? _resolveStatus(
    LibraryScanService? scans,
    TtplaySessionBinder? binder,
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
        openCloudSources: false,
      );
    }

    if (scrapeStatus != null && scrapeStatus.running) {
      final detail = scrapeStatus.total > 0
          ? t.storage.scrapingProgress(done: scrapeStatus.done, total: scrapeStatus.total)
          : t.storage.scraping;
      return (
        inlineText: detail,
        tooltip: '${t.storage.scrapeTitle} · $detail',
        failed: false,
        isNoTmdbKey: false,
        openCloudSources: false,
      );
    }

    final cloudRunner = binder?.cloudScanRunner;
    if (cloudRunner != null && cloudRunner.hasActiveScans) {
      final active = cloudRunner.activeScans;
      return _resolveCloudScanStatus(active, syncingProjection: binder?.isCloudProjectionSyncing == true);
    }

    if (binder?.isCloudProjectionSyncing == true) {
      return (
        inlineText: '同步云端片库中...',
        tooltip: '正在从服务端同步最新片库与元数据',
        failed: false,
        isNoTmdbKey: false,
        openCloudSources: true,
      );
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
        openCloudSources: false,
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
        openCloudSources: false,
      );
    }

    final cloudError = cloudRunner?.latestError;
    if (cloudError != null) {
      return (
        inlineText: '云端扫描失败',
        tooltip: '云端扫描失败\n${cloudError.message}',
        failed: true,
        isNoTmdbKey: false,
        openCloudSources: true,
      );
    }

    return null;
  }

  static ({String inlineText, String tooltip, bool failed, bool isNoTmdbKey, bool openCloudSources})
      _resolveCloudScanStatus(
    List<CloudScanProgress> active, {
    required bool syncingProjection,
  }) {
    var totalDirs = 0;
    var totalFound = 0;
    var totalReported = 0;
    var allCancelling = active.isNotEmpty;
    final allIncremental = active.isNotEmpty && active.every((p) => p.scanType == 'incremental');
    final lines = <String>[];

    for (final p in active) {
      totalDirs += p.directoriesVisited;
      totalFound += p.filesFound;
      totalReported += p.filesReported;
      if (!p.cancelling) allCancelling = false;
      final target = (p.targetLabel != null && p.targetLabel!.isNotEmpty) ? p.targetLabel! : p.sourceId;
      final isInc = p.scanType == 'incremental';
      final statusWord = p.cancelling ? '正在取消' : (isInc ? '增量扫描中' : '扫描中');
      lines.add(
        '$target（$statusWord）：已遍历 ${p.directoriesVisited} 目录 · 发现 ${p.filesFound} / 上报 ${p.filesReported} 文件'
        '${p.filesAdded + p.filesChanged > 0 ? ' · 新增 ${p.filesAdded} / 更新 ${p.filesChanged}' : ''}',
      );
    }

    if (syncingProjection) {
      lines.add('同时正在同步最新已刮削片库...');
    }

    final prefix = allIncremental ? '云端增量扫描' : '云端扫描';
    final String inlineText;
    if (allCancelling) {
      inlineText = '$prefix · 正在取消...';
    } else if (totalFound > 0 || totalReported > 0) {
      inlineText = '$prefix · 发现 $totalFound / 上报 $totalReported';
    } else if (allIncremental && totalDirs == 0) {
      inlineText = '云端增量检查中...';
    } else {
      inlineText = '$prefix · 已遍历 $totalDirs 目录';
    }

    return (
      inlineText: inlineText,
      tooltip: lines.isEmpty ? inlineText : lines.join('\n'),
      failed: false,
      isNoTmdbKey: false,
      openCloudSources: true,
    );
  }
}
