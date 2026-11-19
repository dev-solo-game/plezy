import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../providers/offline_mode_provider.dart';
import '../session/app_session_controller.dart';
import '../storage/storage_mount.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';

T? _readOptional<T>(BuildContext context) {
  try {
    return Provider.of<T?>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Whether toolbar refreshes in [context] should also trigger offline local
/// incremental directory updates.
bool isOfflineRefreshContext(BuildContext context) {
  final session = _readOptional<AppSessionController>(context);
  if (session != null && session.hasSelectedMode) {
    return session.isOffline;
  }
  final offline = _readOptional<OfflineModeProvider>(context);
  if (offline != null) {
    return offline.isOffline;
  }
  return false;
}

/// Triggers an incremental directory check in offline mode with a shared
/// cross-screen cooldown, surfacing a brief cooldown notice when skipped.
Future<void> triggerOfflineToolbarIncrementalRefresh(BuildContext context) async {
  if (!isOfflineRefreshContext(context)) return;
  final scans = _readOptional<LibraryScanService>(context);
  if (scans == null) return;
  try {
    final result = await scans.triggerManualIncrementalRefresh(canRun: () => context.mounted);
    if (!context.mounted) return;
    if (result.onCooldown && result.remaining != null && Scaffold.maybeOf(context) != null) {
      final seconds = result.remaining!.inSeconds.clamp(1, 3600);
      showAppSnackBar(context, t.storage.incrementalCooldown(seconds: seconds));
    }
  } catch (error, stack) {
    appLogger.w('Media library incremental update failed', error: error, stackTrace: stack);
  }
}

/// Prompts to clear scanned local library data (preserving mounts and watch
/// history) and run a full rescan of all mounted sources.
Future<void> confirmRebuildFullLibraryScan(BuildContext context, LibraryScanService scans) async {
  final confirmed = await showConfirmDialog(
    context,
    title: t.storage.fullUpdate,
    message: t.storage.rebuildFullScanMessage,
    warning: t.storage.rebuildFullScanWarning,
    confirmText: t.storage.fullUpdate,
    isDestructive: true,
  );
  if (!confirmed || !context.mounted) return;
  try {
    final started = await scans.rebuildAllMounts();
    if (!started && context.mounted) {
      showErrorSnackBar(context, t.storage.updateBusy);
    }
  } catch (error, stack) {
    appLogger.w('Media library rebuild full scan failed', error: error, stackTrace: stack);
    if (context.mounted && scans.updateError == null) {
      showErrorSnackBar(context, t.storage.scanFailed(message: '$error'));
    }
  }
}

Future<void> confirmCancelLibraryUpdate(BuildContext context, LibraryScanService scans, LibraryUpdate job) async {
  if (job.cancel.isCancelled) return;
  final confirmed = await showConfirmDialog(
    context,
    title: t.storage.cancelUpdateTitle,
    message: t.storage.cancelUpdateMessage,
    confirmText: t.storage.scanStop,
  );
  if (confirmed) scans.cancelUpdate(job);
}

Future<bool> showFullLibraryScanConfirmation(BuildContext context, {bool allSources = false}) {
  return showConfirmDialog(
    context,
    title: t.storage.fullUpdate,
    message: allSources ? t.storage.fullLibraryScanMessage : t.storage.fullUpdateMessage,
    warning: t.storage.fullUpdateWarning,
    confirmText: t.storage.fullUpdate,
  );
}

Future<void> confirmFullLibraryScan(BuildContext context, LibraryScanService scans, StorageMount mount) async {
  final confirmed = await showFullLibraryScanConfirmation(context);
  if (!confirmed || !context.mounted) return;
  try {
    final scrapeRuns = scans.scrapeStatus.runs;
    final started = await scans.updateMounts([mount], LibraryUpdateMode.full);
    if (!context.mounted) return;
    if (!started) {
      showErrorSnackBar(context, t.storage.updateBusy);
      return;
    }
    final error = scans.statusOf(mount.id).error;
    if (error != null) {
      showErrorSnackBar(context, '${mount.displayName} · ${t.storage.scanFailed(message: error)}');
      return;
    }
    final note = scans.scrapeStatus.note;
    if (note != null && scans.scrapeStatus.runs != scrapeRuns) {
      showErrorSnackBar(
        context,
        note == LibraryScrapeRunner.noTmdbKey ? t.storage.scrapeNoKey : t.storage.scrapeStopped(message: note),
      );
    }
  } catch (error) {
    if (context.mounted) showErrorSnackBar(context, t.storage.scanFailed(message: '$error'));
  }
}
