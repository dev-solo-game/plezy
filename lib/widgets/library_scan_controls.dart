import 'dart:async';

import 'package:flutter/widgets.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../storage/storage_mount.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';

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
