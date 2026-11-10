// Phase-1 scaffolding for the local media library: lets a mount be added,
// browsed and played before the scanner and library UI exist.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../library/library_scan_service.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../widgets/app_icon.dart';
import 'library_preview_screen.dart';
import 'mount_edit_screen.dart';
import 'storage_browser_screen.dart';

/// Widest the mount screens let their content grow on large windows.
const double storageContentMaxWidth = 640;

String storageKindLabel(StorageKind kind) => switch (kind) {
  StorageKind.local => t.storage.kind.local,
  StorageKind.webdav => t.storage.kind.webdav,
  StorageKind.quark => t.storage.kind.quark,
  StorageKind.smb => t.storage.kind.smb,
};

String storageKindDescription(StorageKind kind) => switch (kind) {
  StorageKind.local => t.storage.kindDescription.local,
  StorageKind.webdav => t.storage.kindDescription.webdav,
  StorageKind.quark => t.storage.kindDescription.quark,
  StorageKind.smb => t.storage.kindDescription.smb,
};

IconData storageKindIcon(StorageKind kind) => switch (kind) {
  StorageKind.local => Symbols.folder_rounded,
  StorageKind.webdav => Symbols.dns_rounded,
  StorageKind.quark => Symbols.cloud_rounded,
  StorageKind.smb => Symbols.lan_rounded,
};

String mountLibraryTypeLabel(MountLibraryType type) => switch (type) {
  MountLibraryType.auto => t.storage.content.auto,
  MountLibraryType.movie => t.storage.content.movie,
  MountLibraryType.show => t.storage.content.show,
  MountLibraryType.anime => t.storage.content.anime,
};

/// Where a mount points, in one line, without credentials.
String? mountLocationSummary(StorageMount mount) {
  switch (mount.kind) {
    case StorageKind.local:
      return mount.configString(MountKeys.rootPath);
    case StorageKind.webdav:
      final uri = Uri.tryParse(mount.configString(MountKeys.baseUrl) ?? '');
      return uri == null || uri.host.isEmpty ? null : '${uri.host}${uri.path}';
    case StorageKind.smb:
      final host = mount.configString(MountKeys.host);
      final share = mount.configString(MountKeys.share);
      if (host == null || share == null) return null;
      final sub = StoragePath.normalize(mount.configString(MountKeys.rootPath) ?? '');
      return '$host/$share${sub == StoragePath.root ? '' : sub}';
    case StorageKind.quark:
      return null;
  }
}

/// The rounded tinted icon used for a storage kind across the mount screens.
class StorageKindBadge extends StatelessWidget {
  const StorageKindBadge({super.key, required this.kind, this.size = 44});

  final StorageKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(size * 0.28)),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: AppIcon(storageKindIcon(kind), size: size * 0.55, color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

enum _MountAction { scan, edit, remove }

class MountsScreen extends StatelessWidget {
  const MountsScreen({super.key});

  Future<void> _edit(BuildContext context, [StorageMount? mount]) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MountEditScreen(mount: mount)));
  }

  Future<void> _confirmRemove(BuildContext context, StorageMount mount) async {
    final manager = context.read<MountManager>();
    final scans = context.read<LibraryScanService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.storage.removeMountTitle),
        content: Text(t.storage.removeMountMessage(name: mount.displayName)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.storage.remove)),
        ],
      ),
    );
    if (confirmed != true) return;
    scans.cancel(mount.id);
    await manager.remove(mount.id);
    // The mount's files went with it; drop the titles that leaves empty.
    await scans.repository.pruneEmptyTitles();
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.read<MountManager>();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.storage.title),
        actions: [
          TextButton.icon(
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LibraryPreviewScreen())),
            icon: const AppIcon(Symbols.video_library_rounded),
            label: Text(t.storage.scanResults),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<StorageMount>>(
        stream: manager.registry.watch(),
        builder: (context, snapshot) {
          final mounts = snapshot.data;
          if (mounts == null) return const Center(child: CircularProgressIndicator());
          if (mounts.isEmpty) return _EmptyState(onAdd: () => _edit(context));
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: mounts.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  if (index == mounts.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: OutlinedButton.icon(
                        onPressed: () => _edit(context),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        icon: const AppIcon(Symbols.add_rounded),
                        label: Text(t.storage.addMount),
                      ),
                    );
                  }
                  final mount = mounts[index];
                  return _MountCard(
                    mount: mount,
                    autofocus: index == 0,
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => StorageBrowserScreen(mount: mount, path: StoragePath.root),
                      ),
                    ),
                    onScan: () {
                      final scans = context.read<LibraryScanService>();
                      if (scans.isScanning(mount.id)) {
                        scans.cancel(mount.id);
                      } else {
                        unawaited(scans.scan(mount));
                      }
                    },
                    onEdit: () => _edit(context, mount),
                    onRemove: () => _confirmRemove(context, mount),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(Symbols.hard_drive_rounded, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              Text(t.storage.emptyTitle, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                t.storage.empty,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                autofocus: true,
                onPressed: onAdd,
                style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
                icon: const AppIcon(Symbols.add_rounded),
                label: Text(t.storage.addMount),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MountCard extends StatelessWidget {
  const _MountCard({
    required this.mount,
    required this.onOpen,
    required this.onScan,
    required this.onEdit,
    required this.onRemove,
    this.autofocus = false,
  });

  final StorageMount mount;
  final VoidCallback onOpen;
  final VoidCallback onScan;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final location = mountLocationSummary(mount);
    final status = context.watch<LibraryScanService>().statusOf(mount.id);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        autofocus: autofocus,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Row(
            children: [
              StorageKindBadge(kind: mount.kind),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mount.displayName,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text('${storageKindLabel(mount.kind)} · ${mountLibraryTypeLabel(mount.libraryType)}', style: muted),
                    if (location != null) Text(location, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    _ScanLine(mountId: mount.id, status: status),
                  ],
                ),
              ),
              PopupMenuButton<_MountAction>(
                tooltip: t.common.options,
                icon: const AppIcon(Symbols.more_vert_rounded),
                onSelected: (action) => switch (action) {
                  _MountAction.scan => onScan(),
                  _MountAction.edit => onEdit(),
                  _MountAction.remove => onRemove(),
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _MountAction.scan,
                    child: Text(status.isRunning ? t.storage.scanStop : t.storage.scan),
                  ),
                  PopupMenuItem(value: _MountAction.edit, child: Text(t.common.edit)),
                  PopupMenuItem(value: _MountAction.remove, child: Text(t.storage.remove)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line under a mount: scan progress, the last failure, or what the
/// library holds from it.
class _ScanLine extends StatelessWidget {
  const _ScanLine({required this.mountId, required this.status});

  final String mountId;
  final MountScanStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final progress = status.progress;
    if (progress != null) {
      return Row(
        children: [
          const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.storage.scanning(files: progress.filesSeen),
              style: style?.copyWith(color: theme.colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    final error = status.error;
    if (error != null) {
      return Text(
        t.storage.scanFailed(message: error),
        style: style?.copyWith(color: theme.colorScheme.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    final scans = context.read<LibraryScanService>();
    return FutureBuilder(
      // Keyed on the last result so the counts refresh when a scan ends.
      key: ValueKey(status.lastResult),
      future: scans.repository.mountSummary(mountId),
      builder: (context, snapshot) {
        final summary = snapshot.data;
        final muted = style?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        if (summary == null) return Text('', style: muted);
        if (summary.videos == 0) return Text(t.storage.scanNever, style: muted);
        return Text(
          summary.unidentified == 0
              ? t.storage.scanSummary(videos: summary.videos)
              : t.storage.scanSummaryUnidentified(videos: summary.videos, unidentified: summary.unidentified),
          style: muted,
        );
      },
    );
  }
}
