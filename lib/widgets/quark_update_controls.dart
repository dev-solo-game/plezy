import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../library/library_scan_service.dart';
import '../library/library_scrape_runner.dart';
import '../storage/storage_mount.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'focusable_list_tile.dart';

String libraryUpdateLabel(LibraryUpdateMode mode) => switch (mode) {
  LibraryUpdateMode.incremental => t.storage.incrementalUpdate,
  LibraryUpdateMode.full => t.storage.fullUpdate,
};

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

Future<void> showQuarkUpdateOptions(BuildContext context, LibraryScanService scans, List<StorageMount> mounts) async {
  final incremental = mounts.where(LibraryScanService.supportsIncremental).toList();
  final ready = <StorageMount>[];
  for (final mount in incremental) {
    if (await scans.hasIncrementalBaseline(mount)) ready.add(mount);
  }
  if (!context.mounted || scans.update != null) return;

  final mode = await showScopedDialog<LibraryUpdateMode>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(t.common.refresh),
      children: [
        FocusableListTile(
          autofocus: ready.isNotEmpty,
          enabled: ready.isNotEmpty,
          title: Text(t.storage.incrementalUpdate),
          subtitle: ready.length == mounts.length
              ? null
              : Text(
                  incremental.isEmpty
                      ? t.storage.incrementalUnavailable
                      : ready.isEmpty
                      ? t.storage.incrementalNeedsFull
                      : t.storage.incrementalReadyOnly,
                ),
          onTap: ready.isEmpty ? null : () => Navigator.pop(context, LibraryUpdateMode.incremental),
        ),
        FocusableListTile(
          autofocus: ready.isEmpty,
          title: Text(t.storage.fullUpdate),
          onTap: () => Navigator.pop(context, LibraryUpdateMode.full),
        ),
      ],
    ),
  );
  if (mode == null || !context.mounted || scans.update != null) return;
  if (mode == LibraryUpdateMode.full) {
    final confirmed = await showConfirmDialog(
      context,
      title: t.storage.fullUpdate,
      message: t.storage.fullUpdateMessage,
      warning: t.storage.fullUpdateWarning,
      confirmText: t.storage.fullUpdate,
    );
    if (!confirmed || !context.mounted) return;
  }

  final selected = mode == LibraryUpdateMode.full ? mounts : ready;
  unawaited(_runUpdate(context, scans, selected, mode));
}

Future<void> _runUpdate(
  BuildContext context,
  LibraryScanService scans,
  List<StorageMount> selected,
  LibraryUpdateMode mode,
) async {
  try {
    final scrapeRuns = scans.scrapeStatus.runs;
    final started = await scans.updateQuark(selected, mode);
    if (!context.mounted) return;
    if (!started) {
      showErrorSnackBar(context, t.storage.updateBusy);
      return;
    }
    for (final mount in selected) {
      final error = scans.statusOf(mount.id).error;
      if (error != null) {
        showErrorSnackBar(context, '${mount.displayName} · ${t.storage.scanFailed(message: error)}');
        return;
      }
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

class LibraryRefreshIcon extends StatefulWidget {
  const LibraryRefreshIcon({super.key, required this.color});

  final Color color;

  @override
  State<LibraryRefreshIcon> createState() => _LibraryRefreshIconState();
}

class _LibraryRefreshIconState extends State<LibraryRefreshIcon> with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _rotation,
    child: AppIcon(Symbols.refresh_rounded, color: widget.color),
  );
}
