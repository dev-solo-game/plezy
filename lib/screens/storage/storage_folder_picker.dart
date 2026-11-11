import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_path.dart';
import '../../focus/focusable_button.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';

/// Lets the user walk [driver]'s folders and pick one. Resolves with the
/// chosen directory (the root has path `/` and may carry no id), or null when
/// dismissed. The caller owns [driver] and closes it.
Future<StorageEntry?> showStorageFolderPicker(BuildContext context, {required StorageDriver driver}) {
  return showDialog<StorageEntry>(
    context: context,
    builder: (_) => _FolderPickerDialog(driver: driver),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({required this.driver});

  final StorageDriver driver;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  static const StorageEntry _root = StorageEntry(path: StoragePath.root, name: '', isDirectory: true);

  /// The folders walked into, root first. The last one is being shown.
  final List<StorageEntry> _trail = [_root];
  late Future<List<StorageEntry>> _children;

  StorageEntry get _current => _trail.last;

  @override
  void initState() {
    super.initState();
    _children = _load();
  }

  Future<List<StorageEntry>> _load() async {
    final current = _current;
    final entries = await widget.driver.list(current.path, parent: current.id == null ? null : current);
    return entries.where((e) => e.isDirectory).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void _enter(StorageEntry folder) {
    setState(() {
      _trail.add(folder);
      _children = _load();
    });
  }

  void _up() {
    if (_trail.length <= 1) return;
    setState(() {
      _trail.removeLast();
      _children = _load();
    });
  }

  // Pops past this dialog's own PopScope, which only guards the Back key.
  void _close() => Navigator.of(context).pop();
  void _choose() => Navigator.of(context).pop(_current);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final atRoot = _trail.length == 1;
    // Back climbs one folder before it closes the picker, as a remote expects.
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: AlertDialog(
        title: Text(t.storage.pickFolderTitle),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        content: SizedBox(
          width: 460,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    FocusableButton(
                      onPressed: atRoot ? null : _up,
                      child: IconButton(
                        tooltip: t.storage.parentFolder,
                        icon: const AppIcon(Symbols.arrow_upward_rounded),
                        onPressed: atRoot ? null : _up,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        atRoot ? t.storage.rootFolder : _current.path,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 12),
              Expanded(
                child: FutureBuilder<List<StorageEntry>>(
                  future: _children,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final error = snapshot.error;
                    if (error != null) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            error is StorageException ? error.message : '$error',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      );
                    }
                    final folders = snapshot.data ?? const [];
                    if (folders.isEmpty) {
                      return Center(
                        child: Text(
                          t.storage.noSubfolders,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: folders.length,
                      itemBuilder: (context, index) {
                        final folder = folders[index];
                        return FocusableListTile(
                          autofocus: index == 0,
                          dense: true,
                          leading: const AppIcon(Symbols.folder_rounded),
                          title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const AppIcon(Symbols.chevron_right_rounded),
                          onTap: () => _enter(folder),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          FocusableButton(
            onPressed: _close,
            child: TextButton(onPressed: _close, child: Text(t.common.cancel)),
          ),
          FocusableButton(
            useBackgroundFocus: true,
            onPressed: _choose,
            child: FilledButton(onPressed: _choose, child: Text(t.storage.selectThisFolder)),
          ),
        ],
      ),
    );
  }
}
