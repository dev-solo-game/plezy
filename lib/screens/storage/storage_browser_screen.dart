import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import 'storage_preview_screen.dart';

/// Lists one directory of a mount. Folders push another browser; playable
/// files open in [StoragePreviewScreen] through the stream proxy.
class StorageBrowserScreen extends StatefulWidget {
  const StorageBrowserScreen({super.key, required this.mount, required this.path, this.directory});

  final StorageMount mount;
  final String path;

  /// The entry for [path] when the parent listing already produced it, so
  /// id-addressed drivers skip resolving the path again.
  final StorageEntry? directory;

  @override
  State<StorageBrowserScreen> createState() => _StorageBrowserScreenState();
}

class _StorageBrowserScreenState extends State<StorageBrowserScreen> {
  static const Set<String> _playable = {
    'mkv', 'mp4', 'm4v', 'mov', 'avi', 'webm', 'ts', 'm2ts', 'mts', 'wmv', 'flv', 'mpg', 'mpeg', 'rmvb', 'rm', //
    'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav',
  };

  late Future<List<StorageEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<List<StorageEntry>> _load() async {
    final driver = context.read<MountManager>().driverFor(widget.mount);
    final entries = await driver.list(widget.path, parent: widget.directory);
    return entries..sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  void _open(StorageEntry entry) {
    if (entry.isDirectory) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StorageBrowserScreen(mount: widget.mount, path: entry.path, directory: entry),
        ),
      );
    } else if (_playable.contains(StoragePath.extension(entry.name))) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StoragePreviewScreen(mount: widget.mount, entry: entry),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.path == StoragePath.root ? widget.mount.displayName : StoragePath.name(widget.path);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: t.common.refresh,
            icon: const AppIcon(Symbols.refresh_rounded),
            onPressed: () => setState(() => _entries = _load()),
          ),
        ],
      ),
      body: FutureBuilder<List<StorageEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final error = snapshot.error;
          if (error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(error is StorageException ? error.message : '$error', textAlign: TextAlign.center),
              ),
            );
          }
          final entries = snapshot.data ?? const [];
          if (entries.isEmpty) return Center(child: Text(t.storage.emptyFolder));
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final playable = !entry.isDirectory && _playable.contains(StoragePath.extension(entry.name));
              final size = entry.size;
              return ListTile(
                leading: AppIcon(
                  entry.isDirectory
                      ? Symbols.folder_rounded
                      : playable
                      ? Symbols.play_circle_rounded
                      : Symbols.draft_rounded,
                ),
                title: Text(entry.name),
                subtitle: size == null ? null : Text(ByteFormatter.formatBytes(size)),
                enabled: entry.isDirectory || playable,
                onTap: () => _open(entry),
              );
            },
          );
        },
      ),
    );
  }
}
