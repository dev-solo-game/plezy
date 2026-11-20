import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../library_cloud/cloud_api_client.dart';
import '../../library_cloud/scan_session_runner.dart';
import '../../library_cloud/source_repository.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/drivers/webdav_storage_driver.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';

/// Cloud media sources management & client-side scan screen for `media_library` (C1 + C2).
class CloudSourcesScreen extends StatefulWidget {
  const CloudSourcesScreen({super.key});

  @override
  State<CloudSourcesScreen> createState() => _CloudSourcesScreenState();
}

class _CloudSourcesScreenState extends State<CloudSourcesScreen> {
  static const double _maxWidth = 860;

  List<CloudSource> _sources = const [];
  final Map<String, CloudScanProgress> _scanProgress = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  CloudSourceRepository? get _repo => maybeReadTtplayBinder(context)?.cloudSourceRepository;
  CloudScanSessionRunner? get _runner => maybeReadTtplayBinder(context)?.cloudScanRunner;

  List<String> get _allowedAddKinds {
    if (PlatformDetector.isTV()) return const [];
    if (PlatformDetector.isDesktopOS()) return const ['quark', 'emby', 'jellyfin'];
    return const ['webdav', 'emby', 'jellyfin'];
  }

  Future<void> _load() async {
    final repo = _repo;
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await repo.listSources();
      if (!mounted) return;
      setState(() {
        _sources = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is CloudApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _openAddSourceDialog() async {
    final repo = _repo;
    if (repo == null) return;
    final allowed = _allowedAddKinds;
    if (allowed.isEmpty) return;

    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _AddCloudSourceDialog(repo: repo, allowedKinds: allowed),
    );
    if (created == true && mounted) {
      await _load();
    }
  }

  Future<void> _addFolder(CloudSource source) async {
    final repo = _repo;
    if (repo == null) return;
    final pathCtrl = TextEditingController(text: '/');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加媒体目录'),
        content: TextField(
          controller: pathCtrl,
          decoration: const InputDecoration(
            labelText: '目录路径（如 /Movies）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加')),
        ],
      ),
    );
    final path = pathCtrl.text.trim();
    pathCtrl.dispose();
    if (confirmed != true || path.isEmpty || !mounted) return;

    try {
      await repo.addFolder(source.id, path: path);
      if (!mounted) return;
      showSuccessSnackBar(context, '已添加目录 $path');
      await _load();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _deleteSource(CloudSource source) async {
    final repo = _repo;
    if (repo == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除媒体源'),
        content: Text('确认移除媒体源「${source.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await repo.deleteSource(source.id);
      if (!mounted) return;
      showSuccessSnackBar(context, '已删除 ${source.name}');
      await _load();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _startScan(CloudSource source) async {
    final repo = _repo;
    final runner = _runner;
    if (repo == null || runner == null) return;
    if (runner.isScanning(source.id)) return;

    StorageDriver? driver;
    try {
      final cred = await repo.fetchCredential(source.id);
      driver = _buildDriverForSource(source, cred.payload);
      if (driver == null) {
        if (mounted) showErrorSnackBar(context, '该媒体源类型无需客户端扫描（${source.kind}）');
        return;
      }
      final progress = await runner.runScan(
        sourceId: source.id,
        driver: driver,
        scanType: 'full',
        onProgress: (p) {
          if (mounted) setState(() => _scanProgress[source.id] = p);
        },
      );
      if (!mounted) return;
      showSuccessSnackBar(context, '扫描完成：共上报 ${progress.filesReported} 个文件');
      await _load();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    } finally {
      await driver?.close();
    }
  }

  StorageDriver? _buildDriverForSource(CloudSource source, Map<String, dynamic> cred) {
    if (source.kind == 'webdav') {
      final mount = StorageMount(
        id: source.id,
        kind: StorageKind.webdav,
        displayName: source.name,
        config: {
          MountKeys.baseUrl: cred['base_url'] ?? cred['url'] ?? '',
          MountKeys.username: cred['username'] ?? '',
          MountKeys.rootPath: cred['root_path'] ?? '/',
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
      return WebDavStorageDriver.fromMount(mount);
    }
    if (source.kind == 'quark') {
      final mount = StorageMount(
        id: source.id,
        kind: StorageKind.quark,
        displayName: source.name,
        config: {
          MountKeys.rootPath: cred['root_path'] ?? '/',
        },
        secrets: {
          if ((cred['cookie'] as String?)?.isNotEmpty == true) MountKeys.secretCookie: cred['cookie'] as String,
        },
      );
      return QuarkStorageDriver.fromMount(mount);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final session = maybeWatchAppSession(context);
    final binder = maybeWatchTtplayBinder(context);
    final hasCloud = session?.isSelfHosted == true && binder?.cloudSourceRepository != null;
    if (!hasCloud) {
      return buildTvAdminBlockedScaffold(context, '云端媒体源');
    }

    final isTv = PlatformDetector.isTV();
    final theme = Theme.of(context);
    final runner = binder?.cloudScanRunner;

    return Scaffold(
      appBar: AppBar(
        title: const Text('云端媒体源（客户端扫描）'),
        actions: [
          IconButton(tooltip: '刷新', icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          if (!isTv) ...[
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _openAddSourceDialog,
              icon: const AppIcon(Symbols.add_rounded, size: 18),
              label: const Text('添加媒体源'),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _sources.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : _sources.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(Symbols.cloud_off_rounded, size: 48),
                  const SizedBox(height: 12),
                  Text('尚未添加云端媒体源', style: theme.textTheme.titleMedium),
                ],
              ),
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _sources.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final src = _sources[index];
                    final scanning = runner?.isScanning(src.id) == true;
                    final prog = _scanProgress[src.id];
                    final canScan = !isTv && (src.kind == 'quark' || src.kind == 'webdav');
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                AppIcon(_iconForKind(src.kind)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(src.name, style: theme.textTheme.titleMedium),
                                      Text(
                                        '${src.kind.toUpperCase()} · 凭据状态：${src.credentialMeta?.status ?? 'valid'} · ${src.folders.length} 个目录',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                if (canScan)
                                  FilledButton.tonal(
                                    onPressed: scanning ? null : () => _startScan(src),
                                    child: Text(scanning ? '扫描中...' : '扫描上报'),
                                  ),
                                if (!isTv && (src.kind == 'quark' || src.kind == 'webdav')) ...[
                                  const SizedBox(width: 6),
                                  IconButton(
                                    tooltip: '添加目录',
                                    icon: const AppIcon(Symbols.create_new_folder_rounded),
                                    onPressed: () => _addFolder(src),
                                  ),
                                ],
                                if (!isTv)
                                  IconButton(
                                    tooltip: '删除',
                                    icon: const AppIcon(Symbols.delete_rounded),
                                    onPressed: () => _deleteSource(src),
                                  ),
                              ],
                            ),
                            if (prog != null && scanning) ...[
                              const SizedBox(height: 8),
                              Text(
                                '已遍历 ${prog.directoriesVisited} 个目录 · 上报 ${prog.filesReported} 个文件（第 ${prog.batchesSent} 批）',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (src.folders.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final f in src.folders) Chip(label: Text(f.path), visualDensity: VisualDensity.compact),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }

  IconData _iconForKind(String kind) => switch (kind) {
    'quark' => Symbols.cloud_rounded,
    'webdav' => Symbols.folder_shared_rounded,
    'emby' || 'jellyfin' => Symbols.dns_rounded,
    _ => Symbols.hard_drive_rounded,
  };
}

class _AddCloudSourceDialog extends StatefulWidget {
  const _AddCloudSourceDialog({required this.repo, required this.allowedKinds});

  final CloudSourceRepository repo;
  final List<String> allowedKinds;

  @override
  State<_AddCloudSourceDialog> createState() => _AddCloudSourceDialogState();
}

class _AddCloudSourceDialogState extends State<_AddCloudSourceDialog> {
  late String _kind = widget.allowedKinds.first;
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  final _uidCtrl = TextEditingController();
  final _folderCtrl = TextEditingController(text: '/');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _cookieCtrl.dispose();
    _uidCtrl.dispose();
    _folderCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入媒体源名称');
      return;
    }

    late String normIdentity;
    late Map<String, dynamic> cred;
    var folders = <Map<String, dynamic>>[];

    if (_kind == 'quark') {
      final uid = _uidCtrl.text.trim();
      final cookie = _cookieCtrl.text.trim();
      if (uid.isEmpty || cookie.isEmpty) {
        setState(() => _error = '请输入夸克 UID 与 Cookie');
        return;
      }
      normIdentity = 'quark:$uid';
      cred = {'uid': uid, 'cookie': cookie, 'root_path': '/'};
      folders = [
        {'path': _folderCtrl.text.trim().isEmpty ? '/' : _folderCtrl.text.trim()},
      ];
    } else if (_kind == 'webdav') {
      final url = _urlCtrl.text.trim();
      if (url.isEmpty) {
        setState(() => _error = '请输入 WebDAV 地址');
        return;
      }
      normIdentity = 'webdav:${url.toLowerCase()}@${_userCtrl.text.trim().toLowerCase()}';
      cred = {
        'base_url': url,
        'username': _userCtrl.text.trim(),
        'password': _passCtrl.text,
        'root_path': '/',
      };
      folders = [
        {'path': _folderCtrl.text.trim().isEmpty ? '/' : _folderCtrl.text.trim()},
      ];
    } else {
      final url = _urlCtrl.text.trim();
      if (url.isEmpty) {
        setState(() => _error = '请输入服务器地址');
        return;
      }
      normIdentity = '$_kind:${url.toLowerCase()}:${_userCtrl.text.trim().toLowerCase()}';
      cred = {
        'base_url': url,
        'username': _userCtrl.text.trim(),
        'password': _passCtrl.text,
      };
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.createSource(
        kind: _kind,
        name: name,
        normalizedIdentity: normIdentity,
        credentialPayload: cred,
        folders: folders,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is CloudApiException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加云端媒体源'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: '类型', border: OutlineInputBorder()),
                items: [for (final k in widget.allowedKinds) DropdownMenuItem(value: k, child: Text(k.toUpperCase()))],
                onChanged: (v) {
                  if (v != null) setState(() => _kind = v);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: '显示名称', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              if (_kind == 'quark') ...[
                TextField(
                  controller: _uidCtrl,
                  decoration: const InputDecoration(labelText: '夸克账号 UID', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _cookieCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '夸克 Cookie / 会话 JSON', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _folderCtrl,
                  decoration: const InputDecoration(labelText: '初始扫描目录（如 /Movies）', border: OutlineInputBorder()),
                ),
              ] else ...[
                TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(labelText: '服务器地址（URL）', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码 / Token', border: OutlineInputBorder()),
                ),
                if (_kind == 'webdav') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _folderCtrl,
                    decoration: const InputDecoration(labelText: '初始扫描目录（如 /Movies）', border: OutlineInputBorder()),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(_saving ? '加密上传中...' : '保存')),
      ],
    );
  }
}
