import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';

import '../../i18n/strings.g.dart';
import '../../library_cloud/cloud_api_client.dart';
import '../../library_cloud/source_repository.dart';
import '../../media/media_browser_dialect.dart';
import '../../services/jellyfin_auth_service.dart';
import '../../services/settings_service.dart';
import '../../storage/drivers/quark_pc_device_store.dart';
import '../../storage/drivers/quark_pc_session.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/drivers/smb_storage_driver.dart';
import '../../storage/drivers/webdav_storage_driver.dart';
import '../../storage/http_range_reader.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../storage/mounts_screen.dart';
import '../storage/quark_account_details.dart';
import '../storage/quark_qr_login_dialog.dart';
import '../storage/storage_folder_picker.dart';

/// Full-page screen for adding or editing a cloud-synced media source (`quark`,
/// `webdav`, `smb`, `emby`, or `jellyfin`) on `media_library`.
///
/// Reuses the exact same QR sign-in, account info card, connectivity check,
/// and visual folder picker components as the offline mount editor.
class CloudSourceEditScreen extends StatefulWidget {
  const CloudSourceEditScreen({
    super.key,
    required this.repo,
    this.existingSource,
  });

  final CloudSourceRepository repo;
  final CloudSource? existingSource;

  @override
  State<CloudSourceEditScreen> createState() => _CloudSourceEditScreenState();
}

class _CloudSourceEditScreenState extends State<CloudSourceEditScreen> {
  static const double _maxWidth = storageContentMaxWidth;
  static const double _fieldGap = 14;

  static const List<({String kind, String title, String desc, IconData icon})> _kinds = [
    (
      kind: 'quark',
      title: '夸克网盘',
      desc: '扫码登录夸克，端到端加密同步，多端免重扫直连原画/转码播放',
      icon: Symbols.cloud_rounded,
    ),
    (
      kind: 'webdav',
      title: 'WebDAV',
      desc: '连接 NAS / Alist / OpenList 等 WebDAV 服务并可视化选目录',
      icon: Symbols.dns_rounded,
    ),
    (
      kind: 'smb',
      title: 'SMB 局域网共享',
      desc: '连接局域网 NAS 或 Windows 共享目录并跨端同步配置',
      icon: Symbols.lan_rounded,
    ),
    (
      kind: 'emby',
      title: 'Emby',
      desc: '端到端加密同步 Emby 凭据，各设备直连播放（不经服务端中转）',
      icon: Symbols.video_library_rounded,
    ),
    (
      kind: 'jellyfin',
      title: 'Jellyfin',
      desc: '端到端加密同步 Jellyfin 凭据，各设备直连播放（不经服务端中转）',
      icon: Symbols.movie_rounded,
    ),
  ];

  final _formKey = GlobalKey<FormState>();
  String? _kind;

  final _nameCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _fallbackUrlCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _shareCtrl = TextEditingController();
  final _domainCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  final _requestIntervalCtrl = TextEditingController(
    text: '${QuarkStorageDriver.defaultRequestInterval.inMilliseconds}',
  );

  bool _allowInsecureTls = false;
  bool _autoIncrementalScan = false;
  int _autoIncrementalIntervalMinutes = MountKeys.defaultAutoIncrementalIntervalMinutes;
  QuarkMode _quarkMode = QuarkMode.pc;
  int _downloadConnections = BulkReadOptions.defaults.connections;
  int _downloadChunkMiB = BulkReadOptions.defaults.chunkSize ~/ BulkReadOptions.bytesPerMiB;
  final List<String> _selectedDirs = [];

  DecryptedSourceCredential? _loadedCredential;
  bool _loadingInitial = false;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.existingSource != null;

  @override
  void initState() {
    super.initState();
    final defaults = SettingsService.instanceOrNull?.bulkReadOptions ?? BulkReadOptions.defaults;
    _downloadConnections = defaults.connections;
    _downloadChunkMiB = defaults.chunkSize ~/ BulkReadOptions.bytesPerMiB;
    if (!QuarkMode.supported.contains(_quarkMode)) {
      _quarkMode = QuarkMode.web;
    }

    final existing = widget.existingSource;
    if (existing != null) {
      _kind = existing.kind;
      _nameCtrl.text = existing.name;
      for (final f in existing.folders) {
        final norm = StoragePath.normalize(f.path);
        if (!_selectedDirs.contains(norm)) {
          _selectedDirs.add(norm);
        }
      }
      unawaited(_loadExistingCredential(existing));
    }
  }

  Future<void> _loadExistingCredential(CloudSource existing) async {
    setState(() {
      _loadingInitial = true;
      _error = null;
    });
    try {
      final cred = await widget.repo.fetchCredential(existing.id);
      if (!mounted) return;
      final p = cred.payload;
      setState(() {
        _loadedCredential = cred;
        _autoIncrementalScan = p['auto_incremental_scan'] == true;
        final rawInterval = (p['auto_incremental_interval_minutes'] as num?)?.toInt();
        if (rawInterval != null && rawInterval >= 1) {
          _autoIncrementalIntervalMinutes = rawInterval.clamp(1, 1440);
        }
        if (existing.kind == 'quark') {
          _quarkMode = QuarkMode.parse(p['quark_mode'] as String?);
          _cookieCtrl.text = (p['cookie'] as String? ?? '').trim();
          if (p['download_connections'] is num) {
            _downloadConnections = (p['download_connections'] as num).toInt();
          }
          if (p['download_chunk_mib'] is num) {
            _downloadChunkMiB = (p['download_chunk_mib'] as num).toInt();
          }
          if (p['request_interval_ms'] is num) {
            _requestIntervalCtrl.text = '${(p['request_interval_ms'] as num).toInt()}';
          }
        } else if (existing.kind == 'webdav') {
          _baseUrlCtrl.text = (p['base_url'] as String? ?? p['url'] as String? ?? '').trim();
          _fallbackUrlCtrl.text = (p['fallback_url'] as String? ?? '').trim();
          _usernameCtrl.text = (p['username'] as String? ?? '').trim();
          _passwordCtrl.text = (p['password'] as String? ?? '');
          _allowInsecureTls = p['allow_insecure_tls'] == true;
        } else if (existing.kind == 'smb') {
          _hostCtrl.text = (p['host'] as String? ?? '').trim();
          _shareCtrl.text = (p['share'] as String? ?? '').trim();
          _fallbackUrlCtrl.text = (p['fallback_url'] as String? ?? '').trim();
          _usernameCtrl.text = (p['username'] as String? ?? '').trim();
          _passwordCtrl.text = (p['password'] as String? ?? '');
          _domainCtrl.text = (p['domain'] as String? ?? '').trim();
        } else {
          _baseUrlCtrl.text = (p['base_url'] as String? ?? p['url'] as String? ?? '').trim();
          _usernameCtrl.text = (p['username'] as String? ?? '').trim();
        }
        _loadingInitial = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingInitial = false;
        _error = e is CloudApiException ? e.message : '$e';
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl,
      _baseUrlCtrl,
      _fallbackUrlCtrl,
      _usernameCtrl,
      _passwordCtrl,
      _hostCtrl,
      _shareCtrl,
      _domainCtrl,
      _cookieCtrl,
      _requestIntervalCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  StorageMount _buildDraftMount(String kind) {
    final fallback = _fallbackUrlCtrl.text.trim();
    switch (kind) {
      case 'quark':
        return StorageMount(
          id: widget.existingSource?.id ?? 'draft-cloud-quark',
          kind: StorageKind.quark,
          displayName: _nameCtrl.text.trim().isEmpty ? '夸克网盘' : _nameCtrl.text.trim(),
          config: {
            MountKeys.quarkMode: _quarkMode.name,
            MountKeys.rootFolderId: QuarkStorageDriver.defaultRootFolderId,
            MountKeys.rootPath: StoragePath.root,
            MountKeys.quarkDownloadConnections: _downloadConnections,
            MountKeys.quarkDownloadChunkMiB: _downloadChunkMiB,
            MountKeys.requestIntervalMs:
                int.tryParse(_requestIntervalCtrl.text.trim()) ??
                QuarkStorageDriver.defaultRequestInterval.inMilliseconds,
          },
          secrets: {
            if (_cookieCtrl.text.trim().isNotEmpty) MountKeys.secretCookie: _cookieCtrl.text.trim(),
          },
        );
      case 'webdav':
        return StorageMount(
          id: widget.existingSource?.id ?? 'draft-cloud-webdav',
          kind: StorageKind.webdav,
          displayName: _nameCtrl.text.trim().isEmpty ? 'WebDAV' : _nameCtrl.text.trim(),
          config: {
            MountKeys.baseUrl: _baseUrlCtrl.text.trim(),
            if (fallback.isNotEmpty) MountKeys.fallbackUrl: fallback,
            MountKeys.username: _usernameCtrl.text.trim(),
            MountKeys.rootPath: StoragePath.root,
            MountKeys.allowInsecureTls: _allowInsecureTls,
          },
          secrets: {
            if (_passwordCtrl.text.isNotEmpty) MountKeys.secretPassword: _passwordCtrl.text,
          },
        );
      case 'smb':
      default:
        return StorageMount(
          id: widget.existingSource?.id ?? 'draft-cloud-smb',
          kind: StorageKind.smb,
          displayName: _nameCtrl.text.trim().isEmpty ? 'SMB' : _nameCtrl.text.trim(),
          config: {
            MountKeys.host: _hostCtrl.text.trim(),
            MountKeys.share: _shareCtrl.text.trim(),
            if (fallback.isNotEmpty) MountKeys.fallbackUrl: fallback,
            if (_usernameCtrl.text.trim().isNotEmpty) MountKeys.username: _usernameCtrl.text.trim(),
            if (_domainCtrl.text.trim().isNotEmpty) MountKeys.domain: _domainCtrl.text.trim(),
            MountKeys.rootPath: StoragePath.root,
          },
          secrets: {
            if (_passwordCtrl.text.isNotEmpty) MountKeys.secretPassword: _passwordCtrl.text,
          },
        );
    }
  }

  StorageDriver _buildDraftDriver(String kind) {
    final draft = _buildDraftMount(kind);
    return switch (kind) {
      'quark' => QuarkStorageDriver.fromMount(draft),
      'webdav' => WebDavStorageDriver.fromMount(draft),
      'smb' => SmbStorageDriver.fromMount(draft),
      _ => throw UnsupportedError('Unsupported driver kind: $kind'),
    };
  }

  Future<void> _scanQuarkQr() async {
    QuarkPcDevice? device;
    if (_quarkMode == QuarkMode.pc) {
      final existing = QuarkPcSession.tryParseDevice(_cookieCtrl.text.trim());
      if (existing != null) {
        unawaited(QuarkPcDeviceStore.adoptIfAbsent(existing));
        device = existing;
      } else {
        device = await QuarkPcDeviceStore.getOrCreate();
      }
    }
    if (!mounted) return;
    final secret = await showQuarkQrLoginDialog(context, mode: _quarkMode, device: device);
    if (!mounted || secret == null) return;
    setState(() {
      _cookieCtrl.text = secret;
      if (_nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = '夸克网盘';
      }
      _error = null;
    });
  }

  Future<void> _pickFolder(String kind) async {
    if (kind == 'quark' && _cookieCtrl.text.trim().isEmpty) {
      setState(() => _error = t.storage.quarkFolderNeedsLogin);
      return;
    }
    if (kind == 'webdav' && _baseUrlCtrl.text.trim().isEmpty) {
      setState(() => _error = '请先填写 WebDAV 地址');
      return;
    }
    if (kind == 'smb' && (_hostCtrl.text.trim().isEmpty || _shareCtrl.text.trim().isEmpty)) {
      setState(() => _error = '请先填写主机地址与共享名');
      return;
    }

    setState(() => _error = null);
    late final StorageDriver driver;
    try {
      driver = _buildDraftDriver(kind);
    } on StorageException catch (e) {
      setState(() => _error = e.message);
      return;
    }

    try {
      final picked = await showStorageFolderPicker(context, driver: driver);
      if (!mounted || picked == null) return;
      final norm = StoragePath.normalize(picked.path);
      setState(() {
        if (!_selectedDirs.contains(norm)) {
          _selectedDirs.add(norm);
        }
      });
    } finally {
      await driver.close();
    }
  }

  static String _deriveQuarkNormalizedIdentity(String cookieSecret, QuarkMode mode) {
    final trimmed = cookieSecret.trim();
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map) {
        for (final key in const ['uid', 'puid', 'user_id', 'member_id', 'utdid']) {
          final v = parsed[key];
          if (v != null && v.toString().trim().isNotEmpty) {
            return 'quark:${v.toString().trim()}';
          }
        }
      }
    } catch (_) {
      // Cookie header string in web mode.
    }
    final match = RegExp(r'(?:^|;\s*)(?:__uid|uid|puid)=([^;\s]+)').firstMatch(trimmed);
    if (match != null && (match.group(1)?.isNotEmpty ?? false)) {
      return 'quark:${match.group(1)}';
    }
    final digest = sha256.convert(utf8.encode('${mode.name}:$trimmed')).toString().substring(0, 16);
    return 'quark:hash:$digest';
  }

  Future<void> _save() async {
    final kind = _kind;
    if (kind == null || _saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (kind == 'quark' && _cookieCtrl.text.trim().isEmpty) {
      setState(() => _error = t.storage.quarkLoginRequired);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final result = _editing ? await _saveExisting(widget.existingSource!) : await _createNew(kind);
      if (mounted) Navigator.of(context).pop<CloudSource>(result);
    } on CloudApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on StorageException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<CloudSource> _createNew(String kind) => switch (kind) {
    'quark' => _createQuark(),
    'webdav' => _createWebDav(),
    'smb' => _createSmb(),
    'emby' => _createMediaBrowser(MediaBrowserDialect.emby),
    'jellyfin' => _createMediaBrowser(MediaBrowserDialect.jellyfin),
    _ => throw UnsupportedError('Unsupported cloud source kind: $kind'),
  };

  Future<CloudSource> _saveExisting(CloudSource existing) async {
    final kind = existing.kind;
    final desiredName = _nameCtrl.text.trim();
    if (desiredName.isNotEmpty && desiredName != existing.name) {
      await widget.repo.renameSource(existing.id, desiredName);
    }

    final baseVersion = _loadedCredential?.version ?? existing.credentialMeta?.version ?? 1;
    late Map<String, dynamic> credPayload;

    if (kind == 'quark') {
      await _testDriverConnectivity('quark');
      final intervalMs =
          int.tryParse(_requestIntervalCtrl.text.trim()) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds;
      credPayload = {
        'cookie': _cookieCtrl.text.trim(),
        'quark_mode': _quarkMode.name,
        'root_folder_id': QuarkStorageDriver.defaultRootFolderId,
        'root_path': StoragePath.root,
        'download_connections': _downloadConnections,
        'download_chunk_mib': _downloadChunkMiB,
        'request_interval_ms': intervalMs,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      };
    } else if (kind == 'webdav') {
      await _testDriverConnectivity('webdav');
      final fallback = _fallbackUrlCtrl.text.trim();
      credPayload = {
        'base_url': _baseUrlCtrl.text.trim(),
        if (fallback.isNotEmpty) 'fallback_url': fallback,
        'username': _usernameCtrl.text.trim(),
        'password': _passwordCtrl.text,
        'root_path': StoragePath.root,
        'allow_insecure_tls': _allowInsecureTls,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      };
    } else if (kind == 'smb') {
      await _testDriverConnectivity('smb');
      final fallback = _fallbackUrlCtrl.text.trim();
      final domain = _domainCtrl.text.trim();
      credPayload = {
        'host': _hostCtrl.text.trim(),
        'share': _shareCtrl.text.trim(),
        if (fallback.isNotEmpty) 'fallback_url': fallback,
        'username': _usernameCtrl.text.trim(),
        'password': _passwordCtrl.text,
        if (domain.isNotEmpty) 'domain': domain,
        'root_path': StoragePath.root,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      };
    } else {
      final dialect = kind == 'emby' ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin;
      final existingPayload = Map<String, dynamic>.from(_loadedCredential?.payload ?? const {});
      final newUrl = _baseUrlCtrl.text.trim();
      final newUser = _usernameCtrl.text.trim();
      final newPass = _passwordCtrl.text;
      final needsReAuth =
          newPass.isNotEmpty ||
          newUrl != (existingPayload['base_url'] as String? ?? '') ||
          newUser != (existingPayload['username'] as String? ?? '');
      if (needsReAuth) {
        final auth = JellyfinConnectionAuthService(
          clientName: 'Plezy',
          clientVersion: '1.0.0',
          deviceName: PlatformDetector.isDesktopOS() ? 'Plezy Desktop' : 'Plezy Mobile',
          dialect: dialect,
        );
        final conn = await auth.authenticateByName(
          baseUrl: newUrl,
          username: newUser,
          password: newPass,
          deviceId: (existingPayload['device_id'] as String?)?.isNotEmpty == true
              ? existingPayload['device_id'] as String
              : const Uuid().v4(),
        );
        credPayload = {
          'base_url': conn.baseUrl,
          'base_urls': conn.baseUrls,
          'server_name': conn.serverName,
          'server_machine_id': conn.serverMachineId,
          'user_id': conn.userId,
          'username': conn.userName,
          'access_token': conn.accessToken,
          'device_id': conn.deviceId,
          'is_administrator': conn.isAdministrator,
        };
      } else {
        credPayload = existingPayload;
      }
    }

    await widget.repo.updateCredential(
      sourceId: existing.id,
      baseVersion: baseVersion,
      credentialPayload: credPayload,
      mode: 'refresh',
    );

    // Reconcile folder additions & removals without triggering any scan.
    if (kind == 'quark' || kind == 'webdav' || kind == 'smb') {
      final existingByPath = <String, CloudSourceFolder>{
        for (final f in existing.folders) StoragePath.normalize(f.path): f,
      };
      final desiredSet = _selectedDirs.map(StoragePath.normalize).toSet();

      for (final entry in existingByPath.entries) {
        if (!desiredSet.contains(entry.key)) {
          await widget.repo.deleteFolder(existing.id, entry.value.id);
        }
      }
      for (final path in desiredSet) {
        if (!existingByPath.containsKey(path)) {
          await widget.repo.addFolder(existing.id, path: path);
        }
      }
    }

    return widget.repo.getSource(existing.id);
  }

  Future<void> _testDriverConnectivity(String kind) async {
    final driver = _buildDraftDriver(kind);
    try {
      await driver.list(StoragePath.root);
    } finally {
      await driver.close();
    }
  }

  List<Map<String, dynamic>> _foldersPayload() {
    return [
      for (final d in _selectedDirs) {'path': d},
    ];
  }

  Future<CloudSource> _createQuark() async {
    await _testDriverConnectivity('quark');
    final cookie = _cookieCtrl.text.trim();
    final name = _nameCtrl.text.trim().isEmpty ? '夸克网盘' : _nameCtrl.text.trim();
    final intervalMs =
        int.tryParse(_requestIntervalCtrl.text.trim()) ?? QuarkStorageDriver.defaultRequestInterval.inMilliseconds;
    return widget.repo.createSource(
      kind: 'quark',
      name: name,
      normalizedIdentity: _deriveQuarkNormalizedIdentity(cookie, _quarkMode),
      credentialPayload: {
        'cookie': cookie,
        'quark_mode': _quarkMode.name,
        'root_folder_id': QuarkStorageDriver.defaultRootFolderId,
        'root_path': StoragePath.root,
        'download_connections': _downloadConnections,
        'download_chunk_mib': _downloadChunkMiB,
        'request_interval_ms': intervalMs,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      },
      folders: _foldersPayload(),
    );
  }

  Future<CloudSource> _createWebDav() async {
    await _testDriverConnectivity('webdav');
    final baseUrl = _baseUrlCtrl.text.trim();
    final fallback = _fallbackUrlCtrl.text.trim();
    final user = _usernameCtrl.text.trim();
    final name = _nameCtrl.text.trim().isEmpty ? (Uri.tryParse(baseUrl)?.host ?? 'WebDAV') : _nameCtrl.text.trim();
    return widget.repo.createSource(
      kind: 'webdav',
      name: name,
      normalizedIdentity: 'webdav:${baseUrl.toLowerCase()}@${user.toLowerCase()}',
      credentialPayload: {
        'base_url': baseUrl,
        if (fallback.isNotEmpty) 'fallback_url': fallback,
        'username': user,
        'password': _passwordCtrl.text,
        'root_path': StoragePath.root,
        'allow_insecure_tls': _allowInsecureTls,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      },
      folders: _foldersPayload(),
    );
  }

  Future<CloudSource> _createSmb() async {
    await _testDriverConnectivity('smb');
    final host = _hostCtrl.text.trim();
    final share = _shareCtrl.text.trim();
    final fallback = _fallbackUrlCtrl.text.trim();
    final user = _usernameCtrl.text.trim();
    final domain = _domainCtrl.text.trim();
    final name = _nameCtrl.text.trim().isEmpty ? '$host/$share' : _nameCtrl.text.trim();
    return widget.repo.createSource(
      kind: 'smb',
      name: name,
      normalizedIdentity: 'smb:${host.toLowerCase()}/${share.toLowerCase()}@${user.toLowerCase()}',
      credentialPayload: {
        'host': host,
        'share': share,
        if (fallback.isNotEmpty) 'fallback_url': fallback,
        'username': user,
        'password': _passwordCtrl.text,
        if (domain.isNotEmpty) 'domain': domain,
        'root_path': StoragePath.root,
        'auto_incremental_scan': _autoIncrementalScan,
        'auto_incremental_interval_minutes': _autoIncrementalIntervalMinutes,
      },
      folders: _foldersPayload(),
    );
  }

  Future<CloudSource> _createMediaBrowser(MediaBrowserDialect dialect) async {
    final url = _baseUrlCtrl.text.trim();
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text;
    final auth = JellyfinConnectionAuthService(
      clientName: 'Plezy',
      clientVersion: '1.0.0',
      deviceName: PlatformDetector.isDesktopOS() ? 'Plezy Desktop' : 'Plezy Mobile',
      dialect: dialect,
    );
    final conn = await auth.authenticateByName(
      baseUrl: url,
      username: user,
      password: pass,
      deviceId: const Uuid().v4(),
    );
    final kind = dialect == MediaBrowserDialect.emby ? 'emby' : 'jellyfin';
    final name = _nameCtrl.text.trim().isEmpty ? conn.serverName : _nameCtrl.text.trim();
    return widget.repo.createSource(
      kind: kind,
      name: name,
      normalizedIdentity: '$kind:${conn.serverMachineId}:${conn.userId}',
      credentialPayload: {
        'base_url': conn.baseUrl,
        'base_urls': conn.baseUrls,
        'server_name': conn.serverName,
        'server_machine_id': conn.serverMachineId,
        'user_id': conn.userId,
        'username': conn.userName,
        'access_token': conn.accessToken,
        'device_id': conn.deviceId,
        'is_administrator': conn.isAdministrator,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _editing
              ? '编辑 ${widget.existingSource!.name}'
              : kind == null
              ? '添加云端媒体源'
              : '添加${_kindTitle(kind)}',
        ),
        leading: (!_editing && kind != null)
            ? IconButton(
                tooltip: '返回选择类型',
                icon: const AppIcon(Symbols.arrow_back_rounded),
                onPressed: _saving ? null : () => setState(() => _kind = null),
              )
            : null,
        actions: [
          if (kind != null && !_loadingInitial) ...[
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('校验并保存'),
              ),
            ),
          ],
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: _loadingInitial
              ? const Center(child: CircularProgressIndicator())
              : kind == null
              ? _buildKindPicker(context)
              : _buildForm(context, kind),
        ),
      ),
    );
  }

  String _kindTitle(String kind) => _kinds.firstWhere((e) => e.kind == kind, orElse: () => _kinds.first).title;

  Widget _buildKindPicker(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _kinds.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _kinds[index];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: FocusableListTile(
            autofocus: index == 0,
            leading: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox.square(
                dimension: 44,
                child: Center(
                  child: AppIcon(item.icon, size: 24, color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ),
            title: Text(item.title),
            subtitle: Text(item.desc),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () => setState(() {
              _kind = item.kind;
              _error = null;
              _selectedDirs.clear();
            }),
          ),
        );
      },
    );
  }

  Widget _buildForm(BuildContext context, String kind) {
    final theme = Theme.of(context);
    final isScannable = kind == 'quark' || kind == 'webdav' || kind == 'smb';
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            Material(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
            const SizedBox(height: _fieldGap),
          ],
          TextFormField(
            controller: _nameCtrl,
            enabled: !_saving,
            decoration: InputDecoration(
              labelText: '显示名称（可选）',
              hintText: kind == 'quark' ? '例如：我的夸克网盘' : '留空将自动命名',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: _fieldGap),
          if (kind == 'quark') ..._buildQuarkFields(context),
          if (kind == 'webdav') ..._buildWebDavFields(),
          if (kind == 'smb') ..._buildSmbFields(),
          if (kind == 'emby' || kind == 'jellyfin') ..._buildMediaBrowserFields(kind),
          if (isScannable) ...[
            const SizedBox(height: _fieldGap),
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('自动增量扫描'),
                    subtitle: const Text('仅在完成至少一次手动扫描后才会自动检查新增与变更；保存挂载或添加目录不会自动全量扫描'),
                    value: _autoIncrementalScan,
                    onChanged: _saving ? null : (v) => setState(() => _autoIncrementalScan = v),
                  ),
                  if (_autoIncrementalScan)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: DropdownButtonFormField<int>(
                        initialValue: _autoIncrementalIntervalMinutes,
                        decoration: const InputDecoration(
                          labelText: '增量检查间隔',
                          helperText: '前台运行时按此间隔自动检查云盘新增与变更',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final minutes
                              in (<int>{
                                ...MountKeys.autoIncrementalIntervalPresets,
                                _autoIncrementalIntervalMinutes,
                              }.toList()..sort()))
                            DropdownMenuItem<int>(
                              value: minutes,
                              child: Text(MountKeys.formatAutoIncrementalInterval(minutes)),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) {
                                if (v != null) {
                                  setState(() => _autoIncrementalIntervalMinutes = v);
                                }
                              },
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const AppIcon(Symbols.cloud_done_rounded, size: 20),
            label: Text(_saving ? '正在校验并加密同步...' : (_editing ? '保存修改' : '校验连通性并加密同步到云端')),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildQuarkFields(BuildContext context) {
    final cookie = _cookieCtrl.text.trim();
    final supportedModes = QuarkMode.supported;

    Widget loginContent([AsyncSnapshot<QuarkAccountInfo?>? snapshot]) {
      final account = snapshot?.connectionState == ConnectionState.done ? snapshot?.data : null;
      final tier = account != null ? QuarkDownloadTier.forAccount(account) : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const AppIcon(Symbols.qr_code_scanner_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cookie.isEmpty ? '扫码登录夸克账号' : '已获取夸克登录会话',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        if (snapshot != null)
                          QuarkAccountDetails(snapshot: snapshot)
                        else
                          Text(
                            '使用手机夸克 App 扫码授权，凭据仅在本地加密后上传服务器',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _saving ? null : _scanQuarkQr,
                    icon: const AppIcon(Symbols.qr_code_2_rounded, size: 18),
                    label: Text(cookie.isEmpty ? '扫码登录' : '重新扫码'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _fieldGap),
          _buildScanFoldersSection('quark'),
          if (tier != null) ...[
            const SizedBox(height: _fieldGap),
            _buildQuarkDownloadPicker(tier),
          ],
        ],
      );
    }

    return [
      if (supportedModes.length > 1) ...[
        SegmentedButton<QuarkMode>(
          segments: [
            for (final mode in supportedModes)
              ButtonSegment<QuarkMode>(
                value: mode,
                label: Text(mode == QuarkMode.pc ? 'PC 客户端模式（推荐）' : '网页模式'),
              ),
          ],
          selected: {_quarkMode},
          onSelectionChanged: _saving
              ? null
              : (next) {
                  final mode = next.first;
                  if (mode == _quarkMode) return;
                  setState(() {
                    _quarkMode = mode;
                    _cookieCtrl.clear();
                  });
                },
        ),
        const SizedBox(height: _fieldGap),
      ],
      if (cookie.isEmpty)
        loginContent()
      else
        QuarkAccountLoader(
          mount: _buildDraftMount('quark'),
          draft: true,
          builder: (_, snapshot) => loginContent(snapshot),
        ),
    ];
  }

  Widget _buildQuarkDownloadPicker(QuarkDownloadTier tier) {
    final opts = tier.options(connections: _downloadConnections, chunkMiB: _downloadChunkMiB);
    final effectiveChunkMiB = opts.effectiveChunkSize ~/ BulkReadOptions.bytesPerMiB;
    return Card(
      child: Column(
        children: [
          FocusableListTile(
            enabled: !_saving,
            leading: const AppIcon(Symbols.speed_rounded),
            title: const Text('下载并发连接数'),
            subtitle: Text('${opts.connections} 并发连接（同步到所有设备）'),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () async {
              final picked = await showOptionPickerDialog<int>(
                context,
                title: '下载并发连接数',
                options: [
                  for (var v = tier.minConnections; v <= tier.maxConnections; v++)
                    (icon: v == opts.connections ? Symbols.check_rounded : null, label: '$v', value: v),
                ],
              );
              if (mounted && picked != null) setState(() => _downloadConnections = picked);
            },
          ),
          const Divider(height: 1),
          FocusableListTile(
            enabled: !_saving,
            leading: const AppIcon(Symbols.view_stream_rounded),
            title: const Text('分片读取大小'),
            subtitle: Text('$effectiveChunkMiB MiB'),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () async {
              final picked = await showOptionPickerDialog<int>(
                context,
                title: '分片读取大小',
                options: [
                  for (var v = 1; v <= BulkReadOptions.maxConfiguredChunkMiB; v++)
                    (icon: v == effectiveChunkMiB ? Symbols.check_rounded : null, label: '$v MiB', value: v),
                ],
              );
              if (mounted && picked != null) setState(() => _downloadChunkMiB = picked);
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWebDavFields() => [
    TextFormField(
      controller: _baseUrlCtrl,
      enabled: !_saving,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'WebDAV 地址',
        hintText: 'https://nas.example.com:5244/dav',
        border: OutlineInputBorder(),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入 WebDAV 地址' : null,
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _fallbackUrlCtrl,
      enabled: !_saving,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: '备用地址（可选，如外网域名）',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _usernameCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(labelText: '用户名（可选）', border: OutlineInputBorder()),
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _passwordCtrl,
      enabled: !_saving,
      obscureText: true,
      decoration: const InputDecoration(labelText: '密码（可选）', border: OutlineInputBorder()),
    ),
    const SizedBox(height: 8),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('允许自签名 HTTPS 证书'),
      value: _allowInsecureTls,
      onChanged: _saving ? null : (v) => setState(() => _allowInsecureTls = v),
    ),
    const SizedBox(height: 8),
    _buildScanFoldersSection('webdav'),
  ];

  List<Widget> _buildSmbFields() => [
    TextFormField(
      controller: _hostCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: '主机 / IP 地址',
        hintText: '192.168.1.10',
        border: OutlineInputBorder(),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入主机或 IP 地址' : null,
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _shareCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: '共享名称（Share）',
        hintText: 'Media',
        border: OutlineInputBorder(),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入共享名称' : null,
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _usernameCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(labelText: '用户名（可选）', border: OutlineInputBorder()),
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _passwordCtrl,
      enabled: !_saving,
      obscureText: true,
      decoration: const InputDecoration(labelText: '密码（可选）', border: OutlineInputBorder()),
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _domainCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(labelText: '工作组 / 域（可选）', border: OutlineInputBorder()),
    ),
    const SizedBox(height: _fieldGap),
    _buildScanFoldersSection('smb'),
  ];

  List<Widget> _buildMediaBrowserFields(String kind) => [
    TextFormField(
      controller: _baseUrlCtrl,
      enabled: !_saving,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        labelText: '${kind == 'emby' ? 'Emby' : 'Jellyfin'} 服务器地址',
        hintText: 'http://192.168.1.10:8096',
        border: const OutlineInputBorder(),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入服务器地址' : null,
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _usernameCtrl,
      enabled: !_saving,
      decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder()),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
    ),
    const SizedBox(height: _fieldGap),
    TextFormField(
      controller: _passwordCtrl,
      enabled: !_saving,
      obscureText: true,
      decoration: InputDecoration(
        labelText: _editing ? '新密码（留空保持当前登录会话）' : '密码（无密码可留空）',
        border: const OutlineInputBorder(),
      ),
    ),
  ];

  Widget _buildScanFoldersSection(String kind) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AppIcon(Symbols.folder_open_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('扫描目录', style: theme.textTheme.titleSmall),
                      Text(
                        _selectedDirs.isEmpty ? '暂未选择目录，可浏览添加（保存后需手动扫描）' : '已配置 ${_selectedDirs.length} 个目录',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => _pickFolder(kind),
                  icon: const AppIcon(Symbols.create_new_folder_rounded, size: 18),
                  label: const Text('浏览添加'),
                ),
              ],
            ),
            if (_selectedDirs.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              for (var i = 0; i < _selectedDirs.length; i++) ...[
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const AppIcon(Symbols.folder_rounded, size: 18),
                  title: Text(_selectedDirs[i]),
                  trailing: IconButton(
                    tooltip: '移除目录',
                    icon: const AppIcon(Symbols.close_rounded, size: 18),
                    onPressed: _saving ? null : () => setState(() => _selectedDirs.removeAt(i)),
                  ),
                ),
                if (i < _selectedDirs.length - 1) const Divider(height: 1),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
