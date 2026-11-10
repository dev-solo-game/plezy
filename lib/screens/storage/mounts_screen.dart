// Phase-1 scaffolding for the local media library: lets a mount be added,
// browsed and played before the scanner and library UI exist. The real mount manager replaces this.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../widgets/app_icon.dart';
import 'mount_edit_screen.dart';
import 'storage_browser_screen.dart';

String storageKindLabel(StorageKind kind) => switch (kind) {
  StorageKind.local => t.storage.kind.local,
  StorageKind.webdav => t.storage.kind.webdav,
  StorageKind.quark => t.storage.kind.quark,
  StorageKind.smb => t.storage.kind.smb,
};

String mountLibraryTypeLabel(MountLibraryType type) => switch (type) {
  MountLibraryType.auto => t.storage.content.auto,
  MountLibraryType.movie => t.storage.content.movie,
  MountLibraryType.show => t.storage.content.show,
  MountLibraryType.anime => t.storage.content.anime,
};

class MountsScreen extends StatelessWidget {
  const MountsScreen({super.key});

  Future<void> _edit(BuildContext context, [StorageMount? mount]) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MountEditScreen(mount: mount)));
  }

  Future<void> _confirmRemove(BuildContext context, StorageMount mount) async {
    final manager = context.read<MountManager>();
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
    if (confirmed == true) await manager.remove(mount.id);
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.read<MountManager>();
    return Scaffold(
      appBar: AppBar(title: Text(t.storage.title)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const AppIcon(Symbols.add_rounded),
        label: Text(t.storage.addMount),
      ),
      body: StreamBuilder<List<StorageMount>>(
        stream: manager.registry.watch(),
        builder: (context, snapshot) {
          final mounts = snapshot.data;
          if (mounts == null) return const Center(child: CircularProgressIndicator());
          if (mounts.isEmpty) {
            return Center(child: Text(t.storage.empty));
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: mounts.length,
            itemBuilder: (context, index) {
              final mount = mounts[index];
              return ListTile(
                leading: AppIcon(switch (mount.kind) {
                  StorageKind.local => Symbols.folder_rounded,
                  StorageKind.webdav => Symbols.dns_rounded,
                  StorageKind.quark => Symbols.cloud_rounded,
                  StorageKind.smb => Symbols.lan_rounded,
                }),
                title: Text(mount.displayName),
                subtitle: Text('${storageKindLabel(mount.kind)} · ${mountLibraryTypeLabel(mount.libraryType)}'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StorageBrowserScreen(mount: mount, path: StoragePath.root),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: t.common.edit,
                      icon: const AppIcon(Symbols.edit_rounded),
                      onPressed: () => _edit(context, mount),
                    ),
                    IconButton(
                      tooltip: t.storage.remove,
                      icon: const AppIcon(Symbols.delete_rounded),
                      onPressed: () => _confirmRemove(context, mount),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
