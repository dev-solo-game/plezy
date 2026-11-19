import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../i18n/strings.g.dart';
import '../../ttplay/ttplay_admin_service.dart';
import '../../ttplay/ttplay_api_client.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import 'ttplay_admin_guard.dart';

/// Server-authoritative mount configuration screen for self-hosted `ttplay-server`
/// (PC & mobile only; hidden on TV).
class TtplayMountsScreen extends StatefulWidget {
  const TtplayMountsScreen({super.key});

  @override
  State<TtplayMountsScreen> createState() => _TtplayMountsScreenState();
}

class _TtplayMountsScreenState extends State<TtplayMountsScreen> {
  static const double _maxWidth = 860;

  List<TtplayMountRecord> _mounts = const [];
  TtplayTaskStatus? _taskStatus;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  TtplayAdminService? get _admin => resolveTtplayAdminService(context);

  Future<void> _load({bool silent = false}) async {
    final admin = _admin;
    if (admin == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final (mounts, status) = await (admin.listMounts(), admin.fetchTaskStatus()).wait;
      if (!mounted) return;
      setState(() {
        _mounts = mounts;
        _taskStatus = status;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ttplayAdminErrorText(e);
      });
    }
  }

  Future<void> _openEditor([TtplayMountRecord? existing]) async {
    final admin = _admin;
    if (admin == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ServerMountEditDialog(admin: admin, existing: existing),
    );
    if (saved == true && mounted) {
      await _load(silent: true);
    }
  }

  Future<void> _toggleEnabled(TtplayMountRecord mount, bool enabled) async {
    final admin = _admin;
    if (admin == null) return;
    try {
      await admin.updateMount(mount.id, enabled: enabled);
      if (mounted) await _load(silent: true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _scanMount(TtplayMountRecord mount, {bool full = false}) async {
    final admin = _admin;
    if (admin == null) return;
    try {
      await admin.scanMount(mount.id, full: full);
      if (!mounted) return;
      showSuccessSnackBar(context, t.serverAdmin.scanStarted);
      await _load(silent: true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _cancelScan(TtplayMountRecord mount) async {
    final admin = _admin;
    if (admin == null) return;
    try {
      await admin.cancelScanMount(mount.id);
      if (mounted) await _load(silent: true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _scanAll() async {
    final admin = _admin;
    if (admin == null) return;
    try {
      await admin.triggerScanAll();
      if (!mounted) return;
      showSuccessSnackBar(context, t.serverAdmin.scanStarted);
      await _load(silent: true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _confirmDelete(TtplayMountRecord mount) async {
    final admin = _admin;
    if (admin == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: t.storage.removeMountTitle,
      message: t.serverAdmin.deleteMountConfirm(name: mount.name),
      confirmText: t.storage.remove,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await admin.deleteMount(mount.id);
      if (mounted) await _load(silent: true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = maybeWatchAppSession(context);
    final binder = maybeWatchTtplayBinder(context);
    if (PlatformDetector.isTV() || !canUseTtplayAdmin(session: session, binder: binder)) {
      return buildTvAdminBlockedScaffold(context, t.serverAdmin.mountsTitle);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.serverAdmin.mountsTitle),
        actions: [
          IconButton(tooltip: t.common.refresh, icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          if (_mounts.isNotEmpty)
            TextButton.icon(
              onPressed: _scanAll,
              icon: const AppIcon(Symbols.sync_rounded),
              label: Text(t.serverAdmin.scanAll),
            ),
          IconButton(
            tooltip: t.serverAdmin.addMount,
            icon: const AppIcon(Symbols.add_rounded),
            onPressed: () => _openEditor(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _mounts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: Text(t.common.retry)),
            ],
          ),
        ),
      );
    }
    if (_mounts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(Symbols.hard_drive_rounded, size: 48),
              const SizedBox(height: 12),
              Text(t.serverAdmin.noMounts),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const AppIcon(Symbols.add_rounded),
                label: Text(t.serverAdmin.addMount),
              ),
            ],
          ),
        ),
      );
    }

    final activeScans = {for (final s in _taskStatus?.scans ?? const <TtplayScanSnapshot>[]) s.mountId: s};

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: RefreshIndicator(
          onRefresh: () => _load(silent: true),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _mounts.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              if (index == _mounts.length) {
                return OutlinedButton.icon(
                  onPressed: () => _openEditor(),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const AppIcon(Symbols.add_rounded),
                  label: Text(t.serverAdmin.addMount),
                );
              }
              final mount = _mounts[index];
              final liveScan = activeScans[mount.id];
              return _MountCard(
                mount: mount,
                liveScan: liveScan,
                onToggleEnabled: (v) => _toggleEnabled(mount, v),
                onScan: () => _scanMount(mount),
                onFullScan: () => _scanMount(mount, full: true),
                onCancelScan: () => _cancelScan(mount),
                onEdit: () => _openEditor(mount),
                onDelete: () => _confirmDelete(mount),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MountCard extends StatelessWidget {
  const _MountCard({
    required this.mount,
    required this.liveScan,
    required this.onToggleEnabled,
    required this.onScan,
    required this.onFullScan,
    required this.onCancelScan,
    required this.onEdit,
    required this.onDelete,
  });

  final TtplayMountRecord mount;
  final TtplayScanSnapshot? liveScan;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onScan;
  final VoidCallback onFullScan;
  final VoidCallback onCancelScan;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanning = mount.isScanning || (liveScan?.status == 'running');
    final locationSummary = switch (mount.kind) {
      'local' => ttplayString(mount.config['rootPath']) ?? '/',
      'smb' =>
        'smb://${ttplayString(mount.config['host']) ?? ''}/${ttplayString(mount.config['share']) ?? ''}${ttplayString(mount.config['rootPath']) ?? ''}',
      'webdav' =>
        '${ttplayString(mount.config['baseUrl']) ?? ''}${ttplayString(mount.config['rootPath']) ?? ''}',
      'quark' => 'Quark (${ttplayString(mount.config['quarkMode']) ?? 'pc'})',
      _ => mount.kind,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(label: Text(mount.kind.toUpperCase()), visualDensity: VisualDensity.compact),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mount.name, style: theme.textTheme.titleMedium),
                      Text(
                        locationSummary,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch(value: mount.enabled, onChanged: onToggleEnabled),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t.serverAdmin.mountStats(videos: mount.videoCount, matched: mount.matchedItemCount),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (scanning) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: null),
              if (liveScan != null && liveScan!.currentPath.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  liveScan!.currentPath,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ] else if (mount.scanError != null && mount.scanError!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                mount.scanError!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (scanning)
                  OutlinedButton.icon(
                    onPressed: onCancelScan,
                    icon: const AppIcon(Symbols.close_rounded, size: 16),
                    label: Text(t.serverAdmin.cancelScan),
                  )
                else ...[
                  FilledButton.tonalIcon(
                    onPressed: onScan,
                    icon: const AppIcon(Symbols.search_rounded, size: 16),
                    label: Text(t.serverAdmin.scanNow),
                  ),
                  OutlinedButton(onPressed: onFullScan, child: Text(t.serverAdmin.fullScan)),
                ],
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const AppIcon(Symbols.edit_rounded, size: 16),
                  label: Text(t.common.edit),
                ),
                IconButton(
                  tooltip: t.storage.remove,
                  onPressed: onDelete,
                  icon: AppIcon(Symbols.delete_outline_rounded, color: theme.colorScheme.error),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerMountEditDialog extends StatefulWidget {
  const _ServerMountEditDialog({required this.admin, this.existing});

  final TtplayAdminService admin;
  final TtplayMountRecord? existing;

  @override
  State<_ServerMountEditDialog> createState() => _ServerMountEditDialogState();
}

class _ServerMountEditDialogState extends State<_ServerMountEditDialog> {
  late final bool _isEditing = widget.existing != null;
  late String _kind = widget.existing?.kind ?? 'local';
  late bool _enabled = widget.existing?.enabled ?? true;
  late String _quarkMode = ttplayString(widget.existing?.config['quarkMode']) ?? 'pc';

  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _rootPath = TextEditingController(
    text: ttplayString(widget.existing?.config['rootPath']) ?? '',
  );
  late final TextEditingController _host = TextEditingController(
    text: ttplayString(widget.existing?.config['host']) ?? '',
  );
  late final TextEditingController _port = TextEditingController(
    text: '${ttplayInt(widget.existing?.config['port']) ?? 445}',
  );
  late final TextEditingController _share = TextEditingController(
    text: ttplayString(widget.existing?.config['share']) ?? '',
  );
  late final TextEditingController _domain = TextEditingController(
    text: ttplayString(widget.existing?.config['domain']) ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: ttplayString(widget.existing?.config['baseUrl']) ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: ttplayString(widget.existing?.config['username']) ?? '',
  );
  late final TextEditingController _secret = TextEditingController();
  late final TextEditingController _quarkRootId = TextEditingController(
    text: ttplayString(widget.existing?.config['rootFolderId']) ?? '0',
  );

  bool _busy = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void dispose() {
    _name.dispose();
    _rootPath.dispose();
    _host.dispose();
    _port.dispose();
    _share.dispose();
    _domain.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _secret.dispose();
    _quarkRootId.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildConfig() {
    switch (_kind) {
      case 'smb':
        return {
          'host': _host.text.trim(),
          'port': int.tryParse(_port.text.trim()) ?? 445,
          'share': _share.text.trim(),
          'rootPath': _rootPath.text.trim(),
          'username': _username.text.trim(),
          if (_domain.text.trim().isNotEmpty) 'domain': _domain.text.trim(),
        };
      case 'webdav':
        return {
          'baseUrl': _baseUrl.text.trim(),
          'rootPath': _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
          'username': _username.text.trim(),
        };
      case 'quark':
        return {
          'quarkMode': _quarkMode,
          'rootFolderId': _quarkRootId.text.trim().isEmpty ? '0' : _quarkRootId.text.trim(),
        };
      default:
        return {'rootPath': _rootPath.text.trim()};
    }
  }

  Map<String, String> _buildSecrets() {
    final s = _secret.text.trim();
    if (s.isEmpty) return const {};
    if (_kind == 'quark') return {'cookie': s};
    if (_kind == 'smb' || _kind == 'webdav') return {'password': s};
    return const {};
  }

  Future<void> _browseHostDirectory() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _ServerHostDirectoryDialog(admin: widget.admin, initialPath: _rootPath.text.trim()),
    );
    if (picked != null && mounted) {
      setState(() => _rootPath.text = picked);
    }
  }

  Future<void> _openQuarkQr() async {
    final captured = await showDialog<String>(
      context: context,
      builder: (_) => _ServerQuarkQrDialog(admin: widget.admin, mode: _quarkMode),
    );
    if (captured != null && captured.isNotEmpty && mounted) {
      setState(() {
        _secret.text = captured;
        _statusMessage = t.serverAdmin.quarkQrSuccess;
        _statusIsError = false;
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      await widget.admin.testMount(
        id: widget.existing?.id,
        kind: _kind,
        config: _buildConfig(),
        secrets: _buildSecrets(),
      );
      if (!mounted) return;
      setState(() {
        _statusMessage = t.serverAdmin.testSuccess;
        _statusIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = ttplayAdminErrorText(e);
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() {
        _statusMessage = t.session.errRequiredField;
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      if (_isEditing) {
        await widget.admin.updateMount(
          widget.existing!.id,
          name: name,
          config: _buildConfig(),
          secrets: _buildSecrets(),
          enabled: _enabled,
        );
      } else {
        await widget.admin.createMount(
          name: name,
          kind: _kind,
          config: _buildConfig(),
          secrets: _buildSecrets(),
          enabled: _enabled,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMessage = ttplayAdminErrorText(e);
          _statusIsError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isEditing ? t.serverAdmin.editMount : t.serverAdmin.addMount),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: t.serverAdmin.mountName, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              if (!_isEditing) ...[
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: InputDecoration(labelText: t.serverAdmin.mountKind, border: const OutlineInputBorder()),
                  items: [
                    DropdownMenuItem(value: 'local', child: Text(t.serverAdmin.kindLocal)),
                    DropdownMenuItem(value: 'smb', child: Text(t.serverAdmin.kindSmb)),
                    DropdownMenuItem(value: 'webdav', child: Text(t.serverAdmin.kindWebdav)),
                    DropdownMenuItem(value: 'quark', child: Text(t.serverAdmin.kindQuark)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _kind = v);
                  },
                ),
                const SizedBox(height: 12),
              ],
              if (_kind == 'local') ...[
                TextField(
                  controller: _rootPath,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.rootPath,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: t.serverAdmin.browseHostDir,
                      onPressed: _browseHostDirectory,
                      icon: const AppIcon(Symbols.folder_open_rounded),
                    ),
                  ),
                ),
              ],
              if (_kind == 'smb') ...[
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.hostHost,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.port,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _share,
                  decoration: InputDecoration(labelText: t.serverAdmin.shareName, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _rootPath,
                  decoration: InputDecoration(labelText: t.serverAdmin.rootPath, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _username,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.username,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _domain,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.domain,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _secret,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.password,
                    hintText: _isEditing ? t.serverAdmin.keepSecretHint : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              if (_kind == 'webdav') ...[
                TextField(
                  controller: _baseUrl,
                  decoration: InputDecoration(labelText: t.serverAdmin.baseUrl, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _rootPath,
                  decoration: InputDecoration(labelText: t.serverAdmin.rootPath, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _username,
                  decoration: InputDecoration(labelText: t.serverAdmin.username, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _secret,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.password,
                    hintText: _isEditing ? t.serverAdmin.keepSecretHint : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              if (_kind == 'quark') ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'pc', label: Text('PC')),
                    ButtonSegment(value: 'web', label: Text('Web')),
                  ],
                  selected: {_quarkMode},
                  onSelectionChanged: (v) => setState(() => _quarkMode = v.first),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _secret,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.quarkCookie,
                    hintText: _isEditing ? t.serverAdmin.keepSecretHint : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openQuarkQr,
                  icon: const AppIcon(Symbols.qr_code_2_rounded),
                  label: Text(t.serverAdmin.quarkQrLogin),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                title: Text(t.serverAdmin.enabled),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _statusMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _statusIsError ? theme.colorScheme.error : theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
        OutlinedButton(onPressed: _busy ? null : _test, child: Text(t.serverAdmin.testConnection)),
        FilledButton(onPressed: _busy ? null : _save, child: Text(t.common.save)),
      ],
    );
  }
}

class _ServerHostDirectoryDialog extends StatefulWidget {
  const _ServerHostDirectoryDialog({required this.admin, required this.initialPath});

  final TtplayAdminService admin;
  final String initialPath;

  @override
  State<_ServerHostDirectoryDialog> createState() => _ServerHostDirectoryDialogState();
}

class _ServerHostDirectoryDialogState extends State<_ServerHostDirectoryDialog> {
  TtplayHostBrowseResult? _page;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load(widget.initialPath));
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.admin.browseHostFs(path);
      if (!mounted) return;
      setState(() {
        _page = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ttplayAdminErrorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return AlertDialog(
      title: Text(t.serverAdmin.browseHostDir),
      content: SizedBox(
        width: 420,
        height: 360,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!, textAlign: TextAlign.center))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (page?.parent != null && page!.parent != page.current)
                        IconButton(
                          icon: const AppIcon(Symbols.arrow_upward_rounded),
                          onPressed: () => _load(page.parent!),
                        ),
                      Expanded(
                        child: Text(
                          page?.current.isNotEmpty == true ? page!.current : '/',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: page?.dirs.length ?? 0,
                      itemBuilder: (context, index) {
                        final d = page!.dirs[index];
                        return ListTile(
                          leading: const AppIcon(Symbols.folder_rounded),
                          title: Text(d.name),
                          onTap: () => _load(d.path),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        if (page != null && page.current.isNotEmpty)
          FilledButton(onPressed: () => Navigator.of(context).pop(page.current), child: Text(t.serverAdmin.selectDir)),
      ],
    );
  }
}

class _ServerQuarkQrDialog extends StatefulWidget {
  const _ServerQuarkQrDialog({required this.admin, required this.mode});

  final TtplayAdminService admin;
  final String mode;

  @override
  State<_ServerQuarkQrDialog> createState() => _ServerQuarkQrDialogState();
}

class _ServerQuarkQrDialogState extends State<_ServerQuarkQrDialog> {
  TtplayQuarkQrStart? _start;
  String? _error;
  bool _expired = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    _pollTimer?.cancel();
    setState(() {
      _start = null;
      _error = null;
      _expired = false;
    });
    try {
      final started = await widget.admin.startQuarkQr(mode: widget.mode);
      if (!mounted) return;
      setState(() => _start = started);
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_poll()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ttplayAdminErrorText(e));
    }
  }

  Future<void> _poll() async {
    final sessionId = _start?.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    try {
      final res = await widget.admin.pollQuarkQr(sessionId);
      if (!mounted) return;
      if (res.status == 'confirmed' && res.secret != null && res.secret!.isNotEmpty) {
        _pollTimer?.cancel();
        Navigator.of(context).pop(res.secret);
      } else if (res.status == 'expired') {
        _pollTimer?.cancel();
        setState(() => _expired = true);
      } else if (res.status == 'error') {
        _pollTimer?.cancel();
        setState(() => _error = res.message ?? 'QR error');
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.serverAdmin.quarkQrLogin),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 240,
              height: 240,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: _start == null && _error == null
                  ? const Center(child: CircularProgressIndicator())
                  : _start != null
                  ? Opacity(
                      opacity: _expired ? 0.2 : 1.0,
                      child: QrImageView(
                        data: _start!.qrContent,
                        size: 220,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? (_expired ? t.serverAdmin.quarkQrExpired : t.serverAdmin.quarkScanQrHint),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: _error != null ? theme.colorScheme.error : null),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        if (_expired || _error != null) FilledButton(onPressed: _begin, child: Text(t.common.retry)),
      ],
    );
  }
}
