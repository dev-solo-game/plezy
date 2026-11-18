import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../library/library_scan_service.dart';
import '../../library/sync/deterministic_keys.dart';
import '../../library/sync/sync_coordinator.dart';
import '../../services/file_picker_service.dart';
import '../../services/settings_service.dart';
import '../../storage/drivers/quark_pc_device_store.dart';
import '../../storage/drivers/quark_pc_session.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/drivers/smb_storage_driver.dart';
import '../../storage/drivers/webdav_storage_driver.dart';
import '../../storage/http_range_reader.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import 'mounts_screen.dart';
import 'quark_account_details.dart';
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
  late bool _allowInsecureTls;
  late final TextEditingController _name;
  late final TextEditingController _rootPath;
  late final TextEditingController _baseUrl;
  late final TextEditingController _fallbackUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _cookie;
  late final TextEditingController _includePaths;
  late final TextEditingController _excludePaths;

  /// Scan root subfolders stored in `MountKeys.includePaths`.
  late List<String> _selectedDirs;
  late QuarkMode _quarkMode;
  late int _downloadConnections;
  late int _downloadChunkMiB;
  StorageMount? _initialQuarkMount;
  late final TextEditingController _requestInterval;
  late final TextEditingController _host;
  late final TextEditingController _share;
  late final TextEditingController _domain;

  bool _saving = false;
  String? _error;

  /// The form's first control. On TV it takes focus whenever the form
  /// appears: `autofocus` cannot, since the type picker's tile still holds
  /// focus while the form builds, and a remote landing on the app bar's back
  /// button has no reliable way down into the form.
  final _firstFocus = FocusNode(debugLabel: 'mount-form-first');

  bool get _editing => widget.mount != null;

  @override
  void initState() {
    super.initState();
    final mount = widget.mount;
    _kind = mount?.kind;
    _allowInsecureTls = mount?.configBool(MountKeys.allowInsecureTls) ?? false;
    _name = TextEditingController(text: mount?.displayName ?? '');
    _rootPath = TextEditingController(
      text: mount?.kind == StorageKind.local ? mount?.configString(MountKeys.rootPath) ?? '' : '',
    );
    _baseUrl = TextEditingController(text: mount?.configString(MountKeys.baseUrl) ?? '');
    _fallbackUrl = TextEditingController(text: mount?.configString(MountKeys.fallbackUrl) ?? '');
    _username = TextEditingController(text: mount?.configString(MountKeys.username) ?? '');
    _password = TextEditingController(text: mount?.secret(MountKeys.secretPassword) ?? '');
    _cookie = TextEditingController(text: mount?.secret(MountKeys.secretCookie) ?? '');
    final initialIncludes = [
      for (final p in mount?.configStringList(MountKeys.includePaths) ?? const <String>[])
        StoragePath.normalize(p),
    ];
    var migratedQuarkRoot = false;
    if (mount?.kind == StorageKind.quark) {
      final savedFolderId = mount?.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId;
      final savedFolderPath = StoragePath.normalize(mount?.configString(MountKeys.rootFolderPath) ?? StoragePath.root);
      if (savedFolderId != QuarkStorageDriver.defaultRootFolderId) {
        migratedQuarkRoot = true;
        if (initialIncludes.isEmpty && savedFolderPath != StoragePath.root) {
          initialIncludes.add(savedFolderPath);
        }
      }
    }
    final smbLegacySubfolder = mount?.kind == StorageKind.smb
        ? (mount?.configString(MountKeys.rootPath)?.trim() ?? '')
        : '';
    if (smbLegacySubfolder.isNotEmpty) {
      final norm = StoragePath.normalize(smbLegacySubfolder);
      if (initialIncludes.isEmpty && norm != StoragePath.root) {
        initialIncludes.add(norm);
      }
    }
    _selectedDirs = [
      for (final p in initialIncludes)
        if (p != StoragePath.root) p,
    ];
    _includePaths = TextEditingController(text: _selectedDirs.join('\n'));
    _excludePaths = TextEditingController(text: mount?.configStringList(MountKeys.excludePaths).join('\n') ?? '');
    _host = TextEditingController(text: mount?.configString(MountKeys.host) ?? '');
    _share = TextEditingController(text: mount?.configString(MountKeys.share) ?? '');
    _domain = TextEditingController(text: mount?.configString(MountKeys.domain) ?? '');
    _quarkMode = QuarkMode.parse(mount?.configString(MountKeys.quarkMode));
    final downloadDefaults =
        (mount?.kind == StorageKind.quark ? SettingsService.instanceOrNull?.bulkReadOptions : null) ??
        BulkReadOptions.defaults;
    _downloadConnections = mount?.configInt(MountKeys.quarkDownloadConnections) ?? downloadDefaults.connections;
    _downloadChunkMiB =
        mount?.configInt(MountKeys.quarkDownloadChunkMiB) ?? downloadDefaults.chunkSize ~/ BulkReadOptions.bytesPerMiB;
    _requestInterval = TextEditingController(
      text:
          '${mount?.configInt(MountKeys.requestIntervalMs) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds}',
    );
    if (_kind == StorageKind.quark && !migratedQuarkRoot) {
      _initialQuarkMount = _buildMount(StorageKind.quark);
    }
    if (_kind != null) _focusFormOnTv();
  }

  void _focusFormOnTv() {
    if (!PlatformDetector.isTV()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _firstFocus.context != null) _firstFocus.requestFocus();
    });
  }

  void _chooseKind(StorageKind kind) {
    setState(() => _kind = kind);
    _focusFormOnTv();
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    for (final controller in [
      _name,
      _rootPath,
      _baseUrl,
      _fallbackUrl,
      _username,
      _password,
      _cookie,
      _includePaths,
      _excludePaths,
      _requestInterval,
      _host,
      _share,
      _domain,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  static List<String> _parsePaths(String raw) {
    final paths = <String>[];
    for (final segment in raw.split(RegExp(r'[\r\n,]+'))) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      final normalized = StoragePath.normalize(trimmed);
      if (normalized == StoragePath.root) continue;
      if (!paths.contains(normalized)) paths.add(normalized);
    }
    return paths;
  }

  StorageMount _buildMount(StorageKind kind) {
    final fallback = _fallbackUrl.text.trim();
    final includes = _parsePaths(_includePaths.text);
    final excludes = _parsePaths(_excludePaths.text);
    final filterConfig = <String, Object?>{
      if (includes.isNotEmpty) MountKeys.includePaths: includes,
      if (excludes.isNotEmpty) MountKeys.excludePaths: excludes,
    };
    final (Map<String, Object?> config, Map<String, String> secrets) = switch (kind) {
      StorageKind.local => ({MountKeys.rootPath: _rootPath.text.trim()}, const <String, String>{}),
      StorageKind.webdav => (
        {
          MountKeys.baseUrl: _baseUrl.text.trim(),
          if (fallback.isNotEmpty) MountKeys.fallbackUrl: fallback,
          MountKeys.username: _username.text.trim(),
          MountKeys.allowInsecureTls: _allowInsecureTls,
          ...filterConfig,
        },
        {if (_password.text.isNotEmpty) MountKeys.secretPassword: _password.text},
      ),
      StorageKind.quark => (
        {
          MountKeys.quarkMode: _quarkMode.name,
          MountKeys.rootFolderId: QuarkStorageDriver.defaultRootFolderId,
          MountKeys.rootFolderPath: StoragePath.root,
          MountKeys.quarkDownloadConnections: _downloadConnections,
          MountKeys.quarkDownloadChunkMiB: _downloadChunkMiB,
          MountKeys.requestIntervalMs:
              int.tryParse(_requestInterval.text.trim()) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds,
          ...filterConfig,
        },
        {MountKeys.secretCookie: _cookie.text.trim()},
      ),
      StorageKind.smb => (
        {
          MountKeys.host: _host.text.trim(),
          if (fallback.isNotEmpty) MountKeys.fallbackUrl: fallback,
          MountKeys.share: _share.text.trim(),
          MountKeys.username: _username.text.trim(),
          MountKeys.domain: _domain.text.trim(),
          ...filterConfig,
        },
        {if (_password.text.isNotEmpty) MountKeys.secretPassword: _password.text},
      ),
    };
    final name = _name.text.trim();
    final draft = StorageMount(
      id: widget.mount?.id ?? '',
      kind: kind,
      displayName: name.isEmpty ? storageKindLabel(kind) : name,
      config: config,
      secrets: secrets,
      createdAt: widget.mount?.createdAt,
    );
    return StorageMount(
      id: widget.mount?.id ?? DeterministicKeys.deterministicSourceId(draft),
      kind: kind,
      displayName: draft.displayName,
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
    final scans = context.read<LibraryScanService>();
    SyncAndScanCoordinator? syncCoordinator;
    try {
      syncCoordinator = context.read<SyncAndScanCoordinator>();
    } on ProviderNotFoundException catch (_) {}
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });

    String? error;
    try {
      final mount = _buildMount(kind);
      final duplicate = await manager.registry.findDuplicate(mount, ignoreId: widget.mount?.id);
      if (duplicate != null) {
        error = t.storage.duplicateMount(name: duplicate.displayName);
      } else if (_onlyQuarkDownloadOptionsChanged(mount)) {
        await manager.saveQuarkDownloadOptions(
          mount.id,
          connections: _downloadConnections,
          chunkMiB: _downloadChunkMiB,
        );
      } else {
        final resolvedStatus = await _probeOnSave(manager, mount);
        await scans.cancelAndAwaitMount(mount.id);
        await manager.save(mount);
        manager.setStatus(mount.id, resolvedStatus);
        if (syncCoordinator != null) {
          await syncCoordinator.onMountSaved(mount, dropDriver: false);
        }
        // A new or changed mount is scanned straight away; the list shows progress.
        unawaited(scans.scan(mount));
      }
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

  Future<MountOnlineStatus> _probeOnSave(MountManager manager, StorageMount mount) async {
    final primary = manager.createDriver(mount, useFallback: false);
    try {
      await primary.check();
      return MountOnlineStatus.onlinePrimary;
    } on StorageException {
      final fallbackUrl = mount.configString(MountKeys.fallbackUrl);
      if (fallbackUrl == null || (mount.kind != StorageKind.webdav && mount.kind != StorageKind.smb)) {
        rethrow;
      }
      final fallback = manager.createDriver(mount, useFallback: true);
      try {
        await fallback.check();
        return MountOnlineStatus.onlineFallback;
      } catch (_) {
        rethrow;
      } finally {
        await fallback.close();
      }
    } finally {
      await primary.close();
    }
  }

  bool _onlyQuarkDownloadOptionsChanged(StorageMount mount) {
    final initial = _initialQuarkMount;
    if (initial == null || mount.kind != StorageKind.quark) return false;
    return initial.displayName == mount.displayName &&
        mapEquals(initial.secrets, mount.secrets) &&
        (initial.configInt(MountKeys.quarkDownloadConnections) != _downloadConnections ||
            initial.configInt(MountKeys.quarkDownloadChunkMiB) != _downloadChunkMiB) &&
        mapEquals(mount.config, {
          ...initial.config,
          MountKeys.quarkDownloadConnections: _downloadConnections,
          MountKeys.quarkDownloadChunkMiB: _downloadChunkMiB,
        });
  }

  Future<void> _pickFolder() async {
    final path = await FilePickerService.instance.getDirectoryPath(dialogTitle: t.storage.selectFolder);
    if (path != null && mounted) setState(() => _rootPath.text = path);
  }

  Future<void> _scanQuark() async {
    // Keep one stable desktop device across mounts, re-scans, and mode
    // switches so Quark keeps seeing the same Windows machine.
    QuarkPcDevice? device;
    if (_quarkMode == QuarkMode.pc) {
      final existing = QuarkPcSession.tryParseDevice(_cookie.text.trim());
      if (existing != null) {
        unawaited(QuarkPcDeviceStore.adoptIfAbsent(existing));
        device = existing;
      } else {
        device = await QuarkPcDeviceStore.getOrCreate();
      }
    }
    if (!mounted) return;
    final cookie = await showQuarkQrLoginDialog(context, mode: _quarkMode, device: device);
    if (cookie != null && mounted) {
      setState(() {
        _cookie.text = cookie;
        _error = null;
      });
    }
  }

  Future<void> _addScanFolder(StorageKind kind) async {
    StorageDriver driver;
    switch (kind) {
      case StorageKind.quark:
        final cookie = _cookie.text.trim();
        if (cookie.isEmpty) {
          setState(() => _error = t.storage.quarkFolderNeedsLogin);
          return;
        }
        driver = QuarkStorageDriver(
          cookie: cookie,
          mode: _quarkMode,
          requestInterval: const Duration(milliseconds: 300),
        );
      case StorageKind.smb:
        if (_host.text.trim().isEmpty || _share.text.trim().isEmpty) {
          setState(() => _error = t.storage.smbFolderNeedsServer);
          return;
        }
        final whole = _buildMount(StorageKind.smb);
        driver = SmbStorageDriver.fromMount(whole.copyWith(config: {...whole.config, MountKeys.rootPath: ''}));
      case StorageKind.webdav:
        final whole = _buildMount(StorageKind.webdav);
        try {
          driver = WebDavStorageDriver.fromMount(whole);
        } on StorageException catch (e) {
          setState(() => _error = e.message);
          return;
        }
      case StorageKind.local:
        return;
    }
    try {
      final picked = await showStorageFolderPicker(context, driver: driver);
      if (picked == null || !mounted) return;
      final norm = StoragePath.normalize(picked.path);
      setState(() {
        if (norm == StoragePath.root) {
          _selectedDirs = [];
        } else if (!_selectedDirs.contains(norm)) {
          _selectedDirs = [..._selectedDirs, norm];
        }
        _includePaths.text = _selectedDirs.join('\n');
        _error = null;
      });
    } finally {
      await driver.close();
    }
  }

  void _removeScanFolder(String path) {
    setState(() {
      _selectedDirs = [
        for (final dir in _selectedDirs)
          if (dir != path) dir,
      ];
      _includePaths.text = _selectedDirs.join('\n');
    });
  }

  Widget _scanFoldersTile(StorageKind kind) => _ScanFoldersTile(
    paths: _selectedDirs,
    onAdd: _saving ? null : () => _addScanFolder(kind),
    onRemove: _saving ? null : _removeScanFolder,
  );

  static String? _required(String? value) => (value == null || value.trim().isEmpty) ? t.storage.required : null;

  // Every field here sets TvTextInputAutoOpenBehavior.never: on Android TV
  // the keyboard otherwise opens as the remote lands on a field and keeps
  // its arrows, so the form could only be left with Back. OK starts typing.
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
        FocusableTextFormField(
          controller: _username,
          tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
          decoration: _decoration(t.storage.username),
          autocorrect: false,
        ),
        const SizedBox(height: _fieldGap),
        FocusableTextFormField(
          tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
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
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _rootPath,
            focusNode: _firstFocus,
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
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _baseUrl,
            focusNode: _firstFocus,
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
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _fallbackUrl,
            decoration: _decoration(
              t.storage.fallbackUrl,
              hint: 'https://ddns.example:5244/dav/media',
              helper: t.storage.fallbackUrlHelp,
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            validator: (value) {
              final raw = value?.trim() ?? '';
              if (raw.isEmpty) return null;
              final uri = Uri.tryParse(raw);
              final valid = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
              return valid ? null : t.storage.urlInvalid;
            },
          ),
          const SizedBox(height: _fieldGap),
          _credentials(),
          const SizedBox(height: _fieldGap),
          _scanFoldersTile(StorageKind.webdav),
        ];
      case StorageKind.smb:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: FocusableTextFormField(
                  tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                  controller: _host,
                  focusNode: _firstFocus,
                  decoration: _decoration(t.storage.smbHost, hint: '192.168.1.10'),
                  autocorrect: false,
                  validator: _required,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FocusableTextFormField(
                  tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                  controller: _share,
                  decoration: _decoration(t.storage.smbShare),
                  autocorrect: false,
                  validator: _required,
                ),
              ),
            ],
          ),
          const SizedBox(height: _fieldGap),
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _fallbackUrl,
            decoration: _decoration(
              t.storage.smbFallbackHost,
              hint: 'ddns.example.com',
              helper: t.storage.fallbackUrlHelp,
            ),
            autocorrect: false,
          ),
          const SizedBox(height: _fieldGap),
          _credentials(),
          const SizedBox(height: _fieldGap),
          _scanFoldersTile(StorageKind.smb),
        ];
      case StorageKind.quark:
        return [
          _QuarkModePicker(
            mode: _quarkMode,
            focusNode: _firstFocus,
            onChanged: _saving
                ? null
                : (mode) => setState(() {
                    if (mode == _quarkMode) return;
                    // Each mode signs in its own way; the old login is of no use.
                    _quarkMode = mode;
                    _cookie.clear();
                  }),
          ),
          const SizedBox(height: _fieldGap),
          _quarkLoginFields(),
        ];
    }
  }

  Widget _quarkLoginFields() {
    final cookie = _cookie.text.trim();
    final saved = widget.mount;
    final usesSavedLogin =
        saved != null &&
        cookie == saved.secret(MountKeys.secretCookie)?.trim() &&
        _quarkMode == QuarkMode.parse(saved.configString(MountKeys.quarkMode));

    Widget fields([AsyncSnapshot<QuarkAccountInfo?>? snapshot]) {
      final account = snapshot?.connectionState == ConnectionState.done ? snapshot?.data : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _QuarkLoginTile(
            signedIn: cookie.isNotEmpty,
            onScan: _saving ? null : _scanQuark,
            account: snapshot == null ? null : QuarkAccountDetails(snapshot: snapshot),
          ),
          const SizedBox(height: _fieldGap),
          _scanFoldersTile(StorageKind.quark),
          if (account != null) ..._quarkDownloadFields(QuarkDownloadTier.forAccount(account)),
        ],
      );
    }

    return cookie.isEmpty
        ? fields()
        : QuarkAccountLoader(
            mount: usesSavedLogin ? saved : _buildMount(StorageKind.quark),
            draft: !usesSavedLogin,
            builder: (_, snapshot) => fields(snapshot),
          );
  }

  List<Widget> _quarkDownloadFields(QuarkDownloadTier tier) {
    final options = tier.options(connections: _downloadConnections, chunkMiB: _downloadChunkMiB);
    final chunkMiB = options.effectiveChunkSize ~/ BulkReadOptions.bytesPerMiB;

    Widget picker({
      required String title,
      required String subtitle,
      required IconData icon,
      required int selected,
      required int min,
      required int max,
      required String Function(int) label,
      required ValueChanged<int> onChanged,
    }) {
      return FocusableListTile(
        contentPadding: EdgeInsets.zero,
        enabled: !_saving,
        leading: AppIcon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const AppIcon(Symbols.chevron_right_rounded),
        onTap: () async {
          final picked = await showOptionPickerDialog<int>(
            context,
            title: title,
            options: [
              for (var value = min; value <= max; value++)
                (icon: value == selected ? Symbols.check_rounded : null, label: label(value), value: value),
            ],
          );
          if (mounted && picked != null) setState(() => onChanged(picked));
        },
      );
    }

    return [
      _SectionTitle(t.storage.quarkDownloadPerformance),
      picker(
        title: t.settings.downloadConnections,
        subtitle: t.storage.quarkDownloadConnectionsDescription(
          min: tier.minConnections,
          max: tier.maxConnections,
          effective: options.effectiveConnections,
        ),
        icon: Symbols.lan_rounded,
        selected: options.connections,
        min: tier.minConnections,
        max: tier.maxConnections,
        label: (value) => '$value',
        onChanged: (value) => _downloadConnections = value,
      ),
      picker(
        title: t.settings.downloadChunkSize,
        subtitle: t.settings.downloadChunkSizeDescription(size: chunkMiB),
        icon: Symbols.view_module_rounded,
        selected: chunkMiB,
        min: 1,
        max: BulkReadOptions.maxConfiguredChunkMiB,
        label: (value) => '$value MiB',
        onChanged: (value) => _downloadChunkMiB = value,
      ),
    ];
  }

  List<Widget> _pathFilterFields() {
    final maxLines = PlatformDetector.isTV() ? 1 : 3;
    return [
      FocusableTextFormField(
        tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
        controller: _includePaths,
        decoration: _decoration(
          t.storage.includePaths,
          hint: '/Movies, /Anime',
          helper: t.storage.includePathsHelp,
        ),
        minLines: 1,
        maxLines: maxLines,
        autocorrect: false,
        onChanged: (value) {
          final parsed = _parsePaths(value);
          setState(() => _selectedDirs = parsed);
        },
      ),
      const SizedBox(height: _fieldGap),
      FocusableTextFormField(
        tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
        controller: _excludePaths,
        decoration: _decoration(
          t.storage.excludePaths,
          hint: '/Photos, /Recordings',
          helper: t.storage.excludePathsHelp,
        ),
        minLines: 1,
        maxLines: maxLines,
        autocorrect: false,
      ),
    ];
  }

  List<Widget> _advancedFields(StorageKind kind) {
    switch (kind) {
      case StorageKind.local:
        return const [];
      case StorageKind.webdav:
        return [
          FocusableSwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: false,
            title: Text(t.storage.allowSelfSigned),
            value: _allowInsecureTls,
            onChanged: (value) => setState(() => _allowInsecureTls = value),
          ),
          const SizedBox(height: _fieldGap),
          ..._pathFilterFields(),
        ];
      case StorageKind.smb:
        return [
          FocusableTextFormField(
            controller: _domain,
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            decoration: _decoration(t.storage.smbDomain),
            autocorrect: false,
          ),
          const SizedBox(height: _fieldGap),
          ..._pathFilterFields(),
        ];
      case StorageKind.quark:
        return [
          ..._pathFilterFields(),
          const SizedBox(height: _fieldGap),
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
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
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _cookie,
            decoration: _decoration(t.storage.quarkCookieManual),
            minLines: 1,
            // One line on TV, so the remote's up/down leave the field instead
            // of moving the caret between lines.
            maxLines: PlatformDetector.isTV() ? 1 : 3,
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
              child: FocusableListTile(
                autofocus: index == 0,
                dense: false,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: StorageKindBadge(kind: kind),
                title: Text(storageKindLabel(kind)),
                subtitle: Text(storageKindDescription(kind)),
                trailing: const AppIcon(Symbols.chevron_right_rounded),
                onTap: () => _chooseKind(kind),
              ),
            ),
          ),
      ],
    );
  }

  void _changeType() => setState(() {
    _kind = null;
    _error = null;
  });

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
                FocusableButton(
                  onPressed: _saving ? null : _changeType,
                  child: TextButton(onPressed: _saving ? null : _changeType, child: Text(t.storage.changeType)),
                ),
            ],
          ),
          _SectionTitle(t.storage.sectionConnection),
          ..._connectionFields(kind),
          _SectionTitle(t.storage.sectionLibrary),
          FocusableTextFormField(
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            controller: _name,
            decoration: _decoration(t.storage.fieldName, hint: storageKindLabel(kind), helper: t.storage.nameHint),
          ),
          // A remote cannot reach into a collapsed section, so TV lays the
          // advanced settings out in the open.
          if (advanced.isNotEmpty && PlatformDetector.isTV()) ...[
            _SectionTitle(t.storage.sectionAdvanced),
            ...advanced,
          ] else if (advanced.isNotEmpty)
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
                        FocusableButton(
                          useBackgroundFocus: true,
                          onPressed: _saving ? null : _save,
                          child: FilledButton(
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

/// Visual multi-directory list for scan include paths, with folder-picker add
/// and per-folder removal.
class _ScanFoldersTile extends StatelessWidget {
  const _ScanFoldersTile({required this.paths, required this.onAdd, required this.onRemove});

  final List<String> paths;
  final VoidCallback? onAdd;
  final void Function(String path)? onRemove;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
                      if (paths.isEmpty) Text(t.storage.allFolders, style: theme.textTheme.titleSmall),
                    ],
                  ),
                ),
                FocusableButton(
                  onPressed: onAdd,
                  child: OutlinedButton.icon(
                    onPressed: onAdd,
                    icon: const AppIcon(Symbols.add_rounded, size: 18),
                    label: Text(t.storage.addScanFolder),
                  ),
                ),
              ],
            ),
            if (paths.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final dir in paths)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          AppIcon(Symbols.subdirectory_arrow_right_rounded, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dir,
                              style: theme.textTheme.bodyMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          FocusableButton(
                            onPressed: onRemove == null ? null : () => onRemove!(dir),
                            child: IconButton(
                              tooltip: t.storage.remove,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              icon: const AppIcon(Symbols.close_rounded, size: 18),
                              onPressed: onRemove == null ? null : () => onRemove!(dir),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Which Quark client the mount signs in as.
class _QuarkModePicker extends StatelessWidget {
  const _QuarkModePicker({required this.mode, required this.onChanged, this.focusNode});

  final QuarkMode mode;
  final FocusNode? focusNode;
  final ValueChanged<QuarkMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String label(QuarkMode mode) => switch (mode) {
      QuarkMode.web => t.storage.quarkModeWeb,
      QuarkMode.pc => t.storage.quarkModePc,
      QuarkMode.tv => t.storage.quarkModeTv,
    };
    final help = Text(
      t.storage.quarkModeHelp,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
    if (PlatformDetector.isDesktop(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FocusableListTile(
            focusNode: focusNode,
            contentPadding: EdgeInsets.zero,
            dense: false,
            enabled: onChanged != null,
            leading: const AppIcon(Symbols.devices_rounded),
            title: Text(t.storage.quarkMode),
            subtitle: Text(label(mode)),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () async {
              final picked = await showOptionPickerDialog<QuarkMode>(
                context,
                title: t.storage.quarkMode,
                options: [
                  for (final value in QuarkMode.values)
                    if (QuarkMode.supported.contains(value))
                      (icon: value == mode ? Symbols.check_rounded : null, label: label(value), value: value),
                ],
              );
              if (context.mounted && picked != null) onChanged?.call(picked);
            },
          ),
          help,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.storage.quarkMode, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<QuarkMode>(
          segments: [
            for (final value in QuarkMode.values)
              ButtonSegment(value: value, label: Text(label(value)), enabled: QuarkMode.supported.contains(value)),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: onChanged == null ? null : (selected) => onChanged!(selected.first),
        ),
        const SizedBox(height: 4),
        help,
      ],
    );
  }
}

/// Sign-in state for a Quark mount with the button that starts a QR login.
class _QuarkLoginTile extends StatelessWidget {
  const _QuarkLoginTile({required this.signedIn, required this.onScan, this.account});

  final bool signedIn;
  final VoidCallback? onScan;
  final Widget? account;

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    signedIn ? t.storage.quarkSignedIn : t.storage.quarkSignedOut,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (account != null) ...[const SizedBox(height: 4), account!],
                ],
              ),
            ),
            FocusableButton(
              // On TV the form focuses its first row instead.
              autofocus: !signedIn && !PlatformDetector.isTV(),
              onPressed: onScan,
              child: signedIn
                  ? OutlinedButton.icon(
                      onPressed: onScan,
                      icon: const AppIcon(Symbols.qr_code_scanner_rounded, size: 18),
                      label: Text(t.storage.quarkRescan),
                    )
                  : FilledButton.icon(
                      onPressed: onScan,
                      icon: const AppIcon(Symbols.qr_code_scanner_rounded, size: 18),
                      label: Text(t.storage.quarkScan),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
