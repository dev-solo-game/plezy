import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../ttplay/ttplay_admin_service.dart';
import '../../ttplay/ttplay_api_client.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import 'ttplay_admin_guard.dart';

/// Server-authoritative management of external Emby / Jellyfin servers proxied
/// separately by `ttplay-server` (PC & mobile only; hidden on TV).
class TtplayExternalServersScreen extends StatefulWidget {
  const TtplayExternalServersScreen({super.key});

  @override
  State<TtplayExternalServersScreen> createState() => _TtplayExternalServersScreenState();
}

class _TtplayExternalServersScreenState extends State<TtplayExternalServersScreen> {
  static const double _maxWidth = 860;

  List<TtplayExternalServerSummary> _servers = const [];
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
      final list = await admin.listExternalServers();
      if (!mounted) return;
      setState(() {
        _servers = list;
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

  Future<void> _syncBinderAndReload() async {
    final binder = maybeReadTtplayBinder(context);
    await binder?.refreshExternalServers();
    if (mounted) await _load(silent: true);
  }

  Future<void> _openEditor([TtplayExternalServerSummary? existing]) async {
    final admin = _admin;
    if (admin == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ExternalServerDialog(admin: admin, existing: existing),
    );
    if (saved == true && mounted) {
      await _syncBinderAndReload();
    }
  }

  Future<void> _toggleEnabled(TtplayExternalServerSummary srv, bool enabled) async {
    final admin = _admin;
    if (admin == null) return;
    try {
      await admin.updateExternalServer(srv.id, {'enabled': enabled});
      if (mounted) await _syncBinderAndReload();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _confirmDelete(TtplayExternalServerSummary srv) async {
    final admin = _admin;
    if (admin == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: t.serverAdmin.externalServersTitle,
      message: t.serverAdmin.deleteExternalConfirm(name: srv.name.isNotEmpty ? srv.name : srv.baseUrl),
      confirmText: t.storage.remove,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await admin.deleteExternalServer(srv.id);
      if (mounted) await _syncBinderAndReload();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = maybeWatchAppSession(context);
    final binder = maybeWatchTtplayBinder(context);
    if (PlatformDetector.isTV() || !canUseTtplayAdmin(session: session, binder: binder)) {
      return buildTvAdminBlockedScaffold(context, t.serverAdmin.externalServersTitle);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.serverAdmin.externalServersTitle),
        actions: [
          IconButton(tooltip: t.common.refresh, icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          IconButton(
            tooltip: t.serverAdmin.addExternalServer,
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(t.common.retry)),
          ],
        ),
      );
    }
    if (_servers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(Symbols.dns_rounded, size: 48),
              const SizedBox(height: 12),
              Text(t.serverAdmin.noExternalServers, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const AppIcon(Symbols.add_rounded),
                label: Text(t.serverAdmin.addExternalServer),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: _servers.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            if (index == _servers.length) {
              return OutlinedButton.icon(
                onPressed: () => _openEditor(),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const AppIcon(Symbols.add_rounded),
                label: Text(t.serverAdmin.addExternalServer),
              );
            }
            final srv = _servers[index];
            final theme = Theme.of(context);
            return Card(
              child: ListTile(
                leading: Chip(label: Text(srv.kind.toUpperCase()), visualDensity: VisualDensity.compact),
                title: Text(srv.name.isNotEmpty ? srv.name : srv.baseUrl),
                subtitle: Text('${srv.baseUrl} · ${srv.authMode == 'apikey' ? t.serverAdmin.apiKey : srv.username}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(value: srv.enabled, onChanged: (v) => _toggleEnabled(srv, v)),
                    IconButton(
                      tooltip: t.common.edit,
                      icon: const AppIcon(Symbols.edit_rounded),
                      onPressed: () => _openEditor(srv),
                    ),
                    IconButton(
                      tooltip: t.storage.remove,
                      icon: AppIcon(Symbols.delete_outline_rounded, color: theme.colorScheme.error),
                      onPressed: () => _confirmDelete(srv),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ExternalServerDialog extends StatefulWidget {
  const _ExternalServerDialog({required this.admin, this.existing});

  final TtplayAdminService admin;
  final TtplayExternalServerSummary? existing;

  @override
  State<_ExternalServerDialog> createState() => _ExternalServerDialogState();
}

class _ExternalServerDialogState extends State<_ExternalServerDialog> {
  late final bool _isEditing = widget.existing != null;
  late String _kind = widget.existing?.kind ?? 'emby';
  late String _authMode = widget.existing?.authMode ?? 'password';
  late bool _allowInsecure = widget.existing?.allowInsecureTls ?? false;
  late bool _enabled = widget.existing?.enabled ?? true;

  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _baseUrl = TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final TextEditingController _username = TextEditingController(text: widget.existing?.username ?? '');
  late final TextEditingController _password = TextEditingController();
  late final TextEditingController _apiKey = TextEditingController();
  late final TextEditingController _userId = TextEditingController(text: widget.existing?.userId ?? '');

  bool _busy = false;
  String? _status;
  bool _statusError = false;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _apiKey.dispose();
    _userId.dispose();
    super.dispose();
  }

  Map<String, dynamic> _payload() => {
    if (_isEditing) 'id': widget.existing!.id,
    if (_name.text.trim().isNotEmpty) 'name': _name.text.trim(),
    'kind': _kind,
    'base_url': _baseUrl.text.trim(),
    'auth_mode': _authMode,
    'username': _username.text.trim(),
    if (_password.text.isNotEmpty) 'password': _password.text,
    if (_apiKey.text.trim().isNotEmpty) 'api_key': _apiKey.text.trim(),
    if (_userId.text.trim().isNotEmpty) 'user_id': _userId.text.trim(),
    'allow_insecure_tls': _allowInsecure,
    'enabled': _enabled,
  };

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final res = await widget.admin.testExternalServer(_payload());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = t.serverAdmin.testExternalOk(
          name: res.serverName ?? _name.text.trim(),
          kind: res.detectedKind ?? _kind,
        );
        _statusError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = ttplayAdminErrorText(e);
        _statusError = true;
      });
    }
  }

  Future<void> _save() async {
    if (_baseUrl.text.trim().isEmpty) {
      setState(() {
        _status = t.session.errRequiredField;
        _statusError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      if (_isEditing) {
        await widget.admin.updateExternalServer(widget.existing!.id, _payload());
      } else {
        await widget.admin.createExternalServer(_payload());
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = ttplayAdminErrorText(e);
          _statusError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isEditing ? t.serverAdmin.editExternalServer : t.serverAdmin.addExternalServer),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: t.serverAdmin.mountName, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: InputDecoration(labelText: t.serverAdmin.serverKind, border: const OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'emby', child: Text('Emby')),
                  DropdownMenuItem(value: 'jellyfin', child: Text('Jellyfin')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _kind = v);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrl,
                decoration: InputDecoration(labelText: t.serverAdmin.baseUrl, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _authMode,
                decoration: InputDecoration(labelText: t.serverAdmin.authMode, border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem(value: 'password', child: Text(t.serverAdmin.authPassword)),
                  DropdownMenuItem(value: 'apikey', child: Text(t.serverAdmin.authApiKey)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _authMode = v);
                },
              ),
              const SizedBox(height: 10),
              if (_authMode == 'password') ...[
                TextField(
                  controller: _username,
                  decoration: InputDecoration(labelText: t.serverAdmin.username, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.password,
                    hintText: _isEditing ? t.serverAdmin.keepSecretHint : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _apiKey,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.apiKey,
                    hintText: _isEditing ? t.serverAdmin.keepSecretHint : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _userId,
                  decoration: InputDecoration(
                    labelText: t.serverAdmin.userIdOptional,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _allowInsecure,
                onChanged: (v) => setState(() => _allowInsecure = v),
                title: Text(t.serverAdmin.allowInsecureTls),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                title: Text(t.serverAdmin.enabled),
              ),
              if (_status != null) ...[
                const SizedBox(height: 8),
                Text(
                  _status!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _statusError ? theme.colorScheme.error : theme.colorScheme.primary,
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
