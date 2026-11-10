import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/file_picker_service.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/mount_manager.dart';
import '../../storage/mount_registry.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../widgets/app_icon.dart';
import 'mounts_screen.dart';

/// Adds a mount or edits an existing one. Saving first connects with the
/// entered settings, so a mount that cannot be reached is never stored.
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

  final _formKey = GlobalKey<FormState>();
  late StorageKind _kind;
  late MountLibraryType _libraryType;
  late bool _allowInsecureTls;
  late final TextEditingController _name;
  late final TextEditingController _rootPath;
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _cookie;
  late final TextEditingController _rootFolderId;
  late final TextEditingController _host;
  late final TextEditingController _share;
  late final TextEditingController _domain;
  late final TextEditingController _subfolder;
  late final TextEditingController _requestInterval;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final mount = widget.mount;
    _kind = mount?.kind ?? StorageKind.local;
    _libraryType = mount?.libraryType ?? MountLibraryType.auto;
    _allowInsecureTls = mount?.configBool(MountKeys.allowInsecureTls) ?? false;
    _name = TextEditingController(text: mount?.displayName ?? '');
    _rootPath = TextEditingController(text: mount?.configString(MountKeys.rootPath) ?? '');
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
    _rootFolderId = TextEditingController(
      text: mount?.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId,
    );
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
      _rootFolderId,
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

  StorageMount _buildMount() {
    final (Map<String, Object?> config, Map<String, String> secrets) = switch (_kind) {
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
          MountKeys.rootFolderId: _rootFolderId.text.trim(),
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
      kind: _kind,
      displayName: name.isEmpty ? storageKindLabel(_kind) : name,
      libraryType: _libraryType,
      config: config,
      secrets: secrets,
      createdAt: widget.mount?.createdAt,
    );
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    final manager = context.read<MountManager>();
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });

    String? error;
    try {
      final mount = _buildMount();
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

  static String? _required(String? value) => (value == null || value.trim().isEmpty) ? t.storage.required : null;

  List<Widget> _kindFields() {
    switch (_kind) {
      case StorageKind.local:
        return [
          TextFormField(
            controller: _rootPath,
            decoration: InputDecoration(
              labelText: t.storage.folderPath,
              // Android's picker returns SAF URIs this driver cannot read; a
              // path has to be typed there until the SAF driver exists.
              suffixIcon: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
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
            decoration: InputDecoration(labelText: t.storage.url, hintText: 'https://nas.example/dav/media'),
            keyboardType: TextInputType.url,
            autocorrect: false,
            validator: (value) {
              final uri = Uri.tryParse(value?.trim() ?? '');
              final valid = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
              return valid ? null : t.storage.urlInvalid;
            },
          ),
          TextFormField(
            controller: _username,
            decoration: InputDecoration(labelText: t.storage.username),
            autocorrect: false,
          ),
          TextFormField(
            controller: _password,
            decoration: InputDecoration(labelText: t.storage.password),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.storage.allowSelfSigned),
            value: _allowInsecureTls,
            onChanged: (value) => setState(() => _allowInsecureTls = value),
          ),
        ];
      case StorageKind.quark:
        return [
          TextFormField(
            controller: _cookie,
            decoration: InputDecoration(
              labelText: t.storage.cookie,
              helperText: t.storage.cookieHelp,
              helperMaxLines: 2,
            ),
            minLines: 1,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            validator: _required,
          ),
          TextFormField(
            controller: _rootFolderId,
            decoration: InputDecoration(labelText: t.storage.rootFolderId, helperText: t.storage.rootFolderIdHelp),
            autocorrect: false,
            validator: _required,
          ),
          TextFormField(
            controller: _requestInterval,
            decoration: InputDecoration(
              labelText: t.storage.requestInterval,
              helperText: t.storage.requestIntervalHelp(min: QuarkStorageDriver.minRequestIntervalMs),
            ),
            keyboardType: TextInputType.number,
            validator: (value) {
              final parsed = int.tryParse(value?.trim() ?? '');
              return parsed != null && parsed >= QuarkStorageDriver.minRequestIntervalMs
                  ? null
                  : t.storage.requestIntervalInvalid(min: QuarkStorageDriver.minRequestIntervalMs);
            },
          ),
        ];
      case StorageKind.smb:
        return [
          TextFormField(
            controller: _host,
            decoration: InputDecoration(labelText: t.storage.smbHost, hintText: '192.168.1.10'),
            autocorrect: false,
            validator: _required,
          ),
          TextFormField(
            controller: _share,
            decoration: InputDecoration(labelText: t.storage.smbShare),
            autocorrect: false,
            validator: _required,
          ),
          TextFormField(
            controller: _subfolder,
            decoration: InputDecoration(labelText: t.storage.smbSubfolder),
            autocorrect: false,
          ),
          TextFormField(
            controller: _username,
            decoration: InputDecoration(labelText: t.storage.username),
            autocorrect: false,
          ),
          TextFormField(
            controller: _password,
            decoration: InputDecoration(labelText: t.storage.password),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          TextFormField(
            controller: _domain,
            decoration: InputDecoration(labelText: t.storage.smbDomain),
            autocorrect: false,
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.mount != null;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? t.storage.editMount : t.storage.addMount)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<StorageKind>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: t.storage.fieldType),
              items: [
                for (final kind in _selectableKinds) DropdownMenuItem(value: kind, child: Text(storageKindLabel(kind))),
              ],
              // The kind decides which driver owns the stored settings, so it
              // is fixed once the mount exists.
              onChanged: editing ? null : (kind) => setState(() => _kind = kind ?? _kind),
            ),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(labelText: t.storage.fieldName),
            ),
            DropdownButtonFormField<MountLibraryType>(
              initialValue: _libraryType,
              decoration: InputDecoration(
                labelText: t.storage.fieldContent,
                helperText: t.storage.fieldContentHelp,
                helperMaxLines: 2,
              ),
              items: [
                for (final type in MountLibraryType.values)
                  DropdownMenuItem(value: type, child: Text(mountLibraryTypeLabel(type))),
              ],
              onChanged: (type) => setState(() => _libraryType = type ?? _libraryType),
            ),
            ..._kindFields(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? t.storage.connecting : t.storage.testAndSave),
            ),
          ],
        ),
      ),
    );
  }
}
