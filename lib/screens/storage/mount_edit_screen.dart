import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/file_picker_service.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/drivers/smb_storage_driver.dart';
import '../../storage/mount_manager.dart';
import '../../storage/mount_registry.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../widgets/app_icon.dart';
import 'mounts_screen.dart';
import 'quark_qr_login_dialog.dart';
import 'storage_folder_picker.dart';

/// Adds a mount or edits an existing one.
///
/// A new mount starts on a type picker and then shows that type's form.
/// Saving first connects with the entered settings, so a mount that cannot be
/// reached is never stored.
class MountEditScreen extends StatefulWidget {
  const MountEditScreen({super.key, this.mount});

  final StorageMount? mount;

  @override
  State<MountEditScreen> createState() => _MountEditScreenState();
}

class _MountEditScreenState extends State<MountEditScreen> {
  static const List<StorageKind> _selectableKinds = [
    StorageKind.local,
    StorageKind.smb,
    StorageKind.webdav,
    StorageKind.quark,
  ];
  static const double _fieldGap = 14;

  final _formKey = GlobalKey<FormState>();

  /// Null while a new mount is still on the type picker.
  StorageKind? _kind;
  late MountLibraryType _libraryType;
  late bool _allowInsecureTls;
  late final TextEditingController _name;
  late final TextEditingController _rootPath;
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _cookie;

  /// Quark's mount root: the folder id the API needs and the path shown for it.
  late String _quarkFolderId;
  late String _quarkFolderPath;
  late final TextEditingController _requestInterval;
  late final TextEditingController _host;
  late final TextEditingController _share;
  late final TextEditingController _domain;
  late final TextEditingController _subfolder;

  bool _saving = false;
  String? _error;

  bool get _editing => widget.mount != null;

  @override
  void initState() {
    super.initState();
    final mount = widget.mount;
    _kind = mount?.kind;
    _libraryType = mount?.libraryType ?? MountLibraryType.auto;
    _allowInsecureTls = mount?.configBool(MountKeys.allowInsecureTls) ?? false;
    _name = TextEditingController(text: mount?.displayName ?? '');
    _rootPath = TextEditingController(
      text: mount?.kind == StorageKind.local ? mount?.configString(MountKeys.rootPath) ?? '' : '',
    );
    _baseUrl = TextEditingController(text: mount?.configString(MountKeys.baseUrl) ?? '');
    _username = TextEditingController(text: mount?.configString(MountKeys.username) ?? '');
    _password = TextEditingController(text: mount?.secret(MountKeys.secretPassword) ?? '');
    _cookie = TextEditingController(text: mount?.secret(MountKeys.secretCookie) ?? '');
    _host = TextEditingController(text: mount?.configString(MountKeys.host) ?? '');
    _share = TextEditingController(text: mount?.configString(MountKeys.share) ?? '');
    _domain = TextEditingController(text: mount?.configString(MountKeys.domain) ?? '');
    _subfolder = TextEditingController(
      text: mount?.kind == StorageKind.smb ? mount?.configString(MountKeys.rootPath) ?? '' : '',
    );
    _quarkFolderId = mount?.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId;
    _quarkFolderPath = mount?.configString(MountKeys.rootFolderPath) ?? StoragePath.root;
    _requestInterval = TextEditingController(
      text:
          '${mount?.configInt(MountKeys.requestIntervalMs) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds}',
    );
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _rootPath,
      _baseUrl,
      _username,
      _password,
      _cookie,
      _requestInterval,
      _host,
      _share,
      _domain,
      _subfolder,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  StorageMount _buildMount(StorageKind kind) {
    final (Map<String, Object?> config, Map<String, String> secrets) = switch (kind) {
      StorageKind.local => ({MountKeys.rootPath: _rootPath.text.trim()}, const <String, String>{}),
      StorageKind.webdav => (
        {
          MountKeys.baseUrl: _baseUrl.text.trim(),
          MountKeys.username: _username.text.trim(),
          MountKeys.allowInsecureTls: _allowInsecureTls,
        },
        {if (_password.text.isNotEmpty) MountKeys.secretPassword: _password.text},
      ),
      StorageKind.quark => (
        {
          MountKeys.rootFolderId: _quarkFolderId,
          MountKeys.rootFolderPath: _quarkFolderPath,
          MountKeys.requestIntervalMs:
              int.tryParse(_requestInterval.text.trim()) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds,
        },
        {MountKeys.secretCookie: _cookie.text.trim()},
      ),
      StorageKind.smb => (
        {
          MountKeys.host: _host.text.trim(),
          MountKeys.share: _share.text.trim(),
          MountKeys.rootPath: _subfolder.text.trim(),
          MountKeys.username: _username.text.trim(),
          MountKeys.domain: _domain.text.trim(),
        },
        {if (_password.text.isNotEmpty) MountKeys.secretPassword: _password.text},
      ),
    };
    final name = _name.text.trim();
    return StorageMount(
      id: widget.mount?.id ?? MountRegistry.newId(),
      kind: kind,
      displayName: name.isEmpty ? storageKindLabel(kind) : name,
      libraryType: _libraryType,
      config: config,
      secrets: secrets,
      createdAt: widget.mount?.createdAt,
    );
  }

  Future<void> _save() async {
    final kind = _kind;
    if (kind == null || _saving || !(_formKey.currentState?.validate() ?? false)) return;
    if (kind == StorageKind.quark && _cookie.text.trim().isEmpty) {
      setState(() => _error = t.storage.quarkLoginRequired);
      return;
    }
    final manager = context.read<MountManager>();
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });

    String? error;
    try {
      final mount = _buildMount(kind);
      final probe = manager.createDriver(mount);
      try {
        await probe.check();
      } finally {
        await probe.close();
      }
      await manager.save(mount);
    } on StorageException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    }

    if (!mounted) return;
    if (error == null) {
      navigator.pop();
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePickerService.instance.getDirectoryPath(dialogTitle: t.storage.selectFolder);
    if (path != null && mounted) setState(() => _rootPath.text = path);
  }

  Future<void> _scanQuark() async {
    final cookie = await showQuarkQrLoginDialog(context);
    if (cookie != null && mounted) {
      setState(() {
        _cookie.text = cookie;
        _error = null;
      });
    }
  }

  Future<void> _pickQuarkFolder() async {
    final cookie = _cookie.text.trim();
    if (cookie.isEmpty) {
      setState(() => _error = t.storage.quarkFolderNeedsLogin);
      return;
    }
    // Browses the whole drive, whatever root is currently selected. A short
    // gap keeps a person clicking through folders from waiting on the throttle.
    final driver = QuarkStorageDriver(cookie: cookie, requestInterval: const Duration(milliseconds: 300));
    try {
      final picked = await showStorageFolderPicker(context, driver: driver);
      if (picked == null || !mounted) return;
      setState(() {
        _quarkFolderId = picked.id ?? QuarkStorageDriver.defaultRootFolderId;
        _quarkFolderPath = picked.path;
        _error = null;
      });
    } finally {
      await driver.close();
    }
  }

  Future<void> _pickSmbFolder() async {
    if (_host.text.trim().isEmpty || _share.text.trim().isEmpty) {
      setState(() => _error = t.storage.smbFolderNeedsServer);
      return;
    }
    final whole = _buildMount(StorageKind.smb);
    final driver = SmbStorageDriver.fromMount(whole.copyWith(config: {...whole.config, MountKeys.rootPath: ''}));
    try {
      final picked = await showStorageFolderPicker(context, driver: driver);
      if (picked == null || !mounted) return;
      setState(() {
        _subfolder.text = picked.path == StoragePath.root ? '' : picked.path;
        _error = null;
      });
    } finally {
      await driver.close();
    }
  }

  static String? _required(String? value) => (value == null || value.trim().isEmpty) ? t.storage.required : null;

  static InputDecoration _decoration(String label, {String? hint, String? helper, Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 2,
      suffixIcon: suffixIcon,
      border: const OutlineInputBorder(),
    );
  }

  Widget _credentials() {
    return Column(
      children: [
        TextFormField(controller: _username, decoration: _decoration(t.storage.username), autocorrect: false),
        const SizedBox(height: _fieldGap),
        TextFormField(
          controller: _password,
          decoration: _decoration(t.storage.password),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
      ],
    );
  }

  List<Widget> _connectionFields(StorageKind kind) {
    switch (kind) {
      case StorageKind.local:
        // Android's picker returns SAF URIs this driver cannot read; a path
        // has to be typed there until the SAF driver exists.
        final canBrowse = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
        return [
          TextFormField(
            controller: _rootPath,
            decoration: _decoration(
              t.storage.folderPath,
              suffixIcon: canBrowse
                  ? IconButton(
                      tooltip: t.storage.browse,
                      icon: const AppIcon(Symbols.folder_open_rounded),
                      onPressed: _pickFolder,
                    )
                  : null,
            ),
            validator: _required,
          ),
        ];
      case StorageKind.webdav:
        return [
          TextFormField(
            controller: _baseUrl,
            decoration: _decoration(t.storage.url, hint: 'https://nas.example/dav/media'),
            keyboardType: TextInputType.url,
            autocorrect: false,
            validator: (value) {
              final uri = Uri.tryParse(value?.trim() ?? '');
              final valid = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
              return valid ? null : t.storage.urlInvalid;
            },
          ),
          const SizedBox(height: _fieldGap),
          _credentials(),
        ];
      case StorageKind.smb:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: _host,
                  decoration: _decoration(t.storage.smbHost, hint: '192.168.1.10'),
                  autocorrect: false,
                  validator: _required,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _share,
                  decoration: _decoration(t.storage.smbShare),
                  autocorrect: false,
                  validator: _required,
                ),
              ),
            ],
          ),
          const SizedBox(height: _fieldGap),
          _credentials(),
          const SizedBox(height: _fieldGap),
          _FolderTile(path: StoragePath.normalize(_subfolder.text), onChoose: _saving ? null : _pickSmbFolder),
        ];
      case StorageKind.quark:
        return [
          _QuarkLoginTile(signedIn: _cookie.text.trim().isNotEmpty, onScan: _saving ? null : _scanQuark),
          const SizedBox(height: _fieldGap),
          _FolderTile(path: _quarkFolderPath, onChoose: _saving ? null : _pickQuarkFolder),
        ];
    }
  }

  List<Widget> _advancedFields(StorageKind kind) {
    switch (kind) {
      case StorageKind.local:
        return const [];
      case StorageKind.webdav:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.storage.allowSelfSigned),
            value: _allowInsecureTls,
            onChanged: (value) => setState(() => _allowInsecureTls = value),
          ),
        ];
      case StorageKind.smb:
        return [TextFormField(controller: _domain, decoration: _decoration(t.storage.smbDomain), autocorrect: false)];
      case StorageKind.quark:
        return [
          TextFormField(
            controller: _requestInterval,
            decoration: _decoration(
              t.storage.requestInterval,
              helper: t.storage.requestIntervalHelp(min: QuarkStorageDriver.minRequestIntervalMs),
            ),
            keyboardType: TextInputType.number,
            validator: (value) {
              final parsed = int.tryParse(value?.trim() ?? '');
              return parsed != null && parsed >= QuarkStorageDriver.minRequestIntervalMs
                  ? null
                  : t.storage.requestIntervalInvalid(min: QuarkStorageDriver.minRequestIntervalMs);
            },
          ),
          const SizedBox(height: _fieldGap),
          TextFormField(
            controller: _cookie,
            decoration: _decoration(t.storage.quarkCookieManual),
            minLines: 1,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            // Keeps the sign-in tile's state in step with a pasted cookie.
            onChanged: (_) => setState(() {}),
          ),
        ];
    }
  }

  Widget _picker() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Text(t.storage.chooseType, style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final (index, kind) in _selectableKinds.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                autofocus: index == 0,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: StorageKindBadge(kind: kind),
                title: Text(storageKindLabel(kind)),
                subtitle: Text(storageKindDescription(kind)),
                trailing: const AppIcon(Symbols.chevron_right_rounded),
                onTap: () => setState(() => _kind = kind),
              ),
            ),
          ),
      ],
    );
  }

  Widget _form(StorageKind kind) {
    final theme = Theme.of(context);
    final advanced = _advancedFields(kind);
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              StorageKindBadge(kind: kind),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(storageKindLabel(kind), style: theme.textTheme.titleMedium),
                    Text(
                      storageKindDescription(kind),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              // The kind decides which driver owns the stored settings, so it
              // is fixed once the mount exists.
              if (!_editing)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _kind = null;
                          _error = null;
                        }),
                  child: Text(t.storage.changeType),
                ),
            ],
          ),
          _SectionTitle(t.storage.sectionConnection),
          ..._connectionFields(kind),
          _SectionTitle(t.storage.sectionLibrary),
          TextFormField(
            controller: _name,
            decoration: _decoration(t.storage.fieldName, hint: storageKindLabel(kind), helper: t.storage.nameHint),
          ),
          const SizedBox(height: _fieldGap),
          Text(t.storage.fieldContent, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in MountLibraryType.values)
                ChoiceChip(
                  label: Text(mountLibraryTypeLabel(type)),
                  selected: _libraryType == type,
                  onSelected: (_) => setState(() => _libraryType = type),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t.storage.fieldContentHelp,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (advanced.isNotEmpty)
            Theme(
              // ExpansionTile draws its own dividers; the section spacing is enough.
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 6, bottom: 8),
                // Collapsed children are not validated, so keep them built.
                maintainState: true,
                title: Text(t.storage.sectionAdvanced, style: theme.textTheme.titleSmall),
                children: advanced,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = _kind;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? t.storage.editMount : t.storage.addMount)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
          child: kind == null ? _picker() : _form(kind),
        ),
      ),
      bottomNavigationBar: kind == null
          ? null
          : SafeArea(
              child: Align(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    AppIcon(Symbols.error_rounded, color: theme.colorScheme.onErrorContainer),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(error, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                          child: _saving
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(t.storage.connecting),
                                  ],
                                )
                              : Text(t.storage.testAndSave),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// The folder a mount is rooted at, with a button that opens the picker.
class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.path, required this.onChoose});

  final String path;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.fromBorderSide(BorderSide(color: scheme.outlineVariant)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            AppIcon(Symbols.folder_rounded, color: scheme.outline, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.storage.mountFolder,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    path == StoragePath.root ? t.storage.rootFolder : path,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            OutlinedButton(onPressed: onChoose, child: Text(t.storage.choose)),
          ],
        ),
      ),
    );
  }
}

/// Sign-in state for a Quark mount with the button that starts a QR login.
class _QuarkLoginTile extends StatelessWidget {
  const _QuarkLoginTile({required this.signedIn, required this.onScan});

  final bool signedIn;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.fromBorderSide(BorderSide(color: scheme.outlineVariant)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            AppIcon(
              signedIn ? Symbols.check_circle_rounded : Symbols.account_circle_rounded,
              color: signedIn ? scheme.primary : scheme.outline,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                signedIn ? t.storage.quarkSignedIn : t.storage.quarkSignedOut,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (signedIn)
              OutlinedButton.icon(
                onPressed: onScan,
                icon: const AppIcon(Symbols.qr_code_scanner_rounded, size: 18),
                label: Text(t.storage.quarkRescan),
              )
            else
              FilledButton.icon(
                autofocus: true,
                onPressed: onScan,
                icon: const AppIcon(Symbols.qr_code_scanner_rounded, size: 18),
                label: Text(t.storage.quarkScan),
              ),
          ],
        ),
      ),
    );
  }
}
