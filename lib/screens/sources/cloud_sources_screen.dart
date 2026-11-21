import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../library_cloud/cloud_api_client.dart';
import '../../library_cloud/scan_session_runner.dart';
import '../../library_cloud/source_repository.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/drivers/smb_storage_driver.dart';
import '../../storage/drivers/webdav_storage_driver.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../storage/storage_folder_picker.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';
import 'cloud_source_edit_screen.dart';

/// Cloud media sources management & per-folder manual scan screen for `media_library`.
class CloudSourcesScreen extends StatefulWidget {
  const CloudSourcesScreen({super.key});

  @override
  State<CloudSourcesScreen> createState() => _CloudSourcesScreenState();
}

class _CloudSourcesScreenState extends State<CloudSourcesScreen> {
  static const double _maxWidth = 880;

  List<CloudSource> _sources = const [];

  /// Keys currently fetching credentials / opening a scan session (prevents double-tap).
  final Set<String> _startingKeys = <String>{};

  /// Tracks finished progress timestamps already reflected into [_sessionsBySource].
  final Map<String, int> _seenFinishedAtByKey = <String, int>{};

  final Set<String> _refreshingSessionSources = <String>{};

  /// Historical scan sessions fetched from server per sourceId (newest first).
  final Map<String, List<CloudScanSessionRecord>> _sessionsBySource = {};

  /// Cached per-source `auto_incremental_scan` preference decoded from E2EE credential.
  final Map<String, bool> _autoIncrementalBySource = {};
  final Map<String, int> _autoIntervalBySource = {};
  final Set<String> _togglingAutoIncremental = {};

  bool _loading = true;
  bool _syncingProjection = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  CloudSourceRepository? get _repo => maybeReadTtplayBinder(context)?.cloudSourceRepository;
  CloudScanSessionRunner? get _runner => maybeReadTtplayBinder(context)?.cloudScanRunner;

  static bool _isScannableKind(String kind) => kind == 'quark' || kind == 'webdav' || kind == 'smb';

  Future<void> _load() async {
    final repo = _repo;
    final runner = _runner;
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
      final sessionsMap = <String, List<CloudScanSessionRecord>>{};
      final autoMap = <String, bool>{};
      final intervalMap = <String, int>{};

      await Future.wait([
        for (final src in list)
          if (_isScannableKind(src.kind))
            Future(() async {
              if (runner != null) {
                try {
                  sessionsMap[src.id] = await runner.listRecentSessions(src.id);
                } catch (_) {
                  sessionsMap[src.id] = const [];
                }
              }
              try {
                final cred = await repo.fetchCredential(src.id);
                autoMap[src.id] = cred.payload['auto_incremental_scan'] == true;
                final rawInterval = (cred.payload['auto_incremental_interval_minutes'] as num?)?.toInt();
                intervalMap[src.id] = (rawInterval != null && rawInterval >= 1)
                    ? rawInterval.clamp(1, 1440)
                    : MountKeys.defaultAutoIncrementalIntervalMinutes;
              } catch (_) {
                autoMap[src.id] = false;
                intervalMap[src.id] = MountKeys.defaultAutoIncrementalIntervalMinutes;
              }
            }),
      ]);

      if (!mounted) return;
      setState(() {
        _sources = list;
        _sessionsBySource
          ..clear()
          ..addAll(sessionsMap);
        _autoIncrementalBySource
          ..clear()
          ..addAll(autoMap);
        _autoIntervalBySource
          ..clear()
          ..addAll(intervalMap);
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

  bool _hasCompletedAnyScan(String sourceId) {
    final runner = _runner;
    if (runner != null) {
      if (runner.progressOf(sourceId)?.completed == true) return true;
      for (final src in _sources) {
        if (src.id != sourceId) continue;
        for (final f in src.folders) {
          if (runner.progressOf(sourceId, folderId: f.id)?.completed == true) return true;
        }
      }
    }
    final sessions = _sessionsBySource[sourceId] ?? const [];
    return sessions.any((s) => s.isCompleted);
  }

  CloudScanSessionRecord? _latestSessionFor(String sourceId, {String? folderId}) {
    final sessions = _sessionsBySource[sourceId] ?? const [];
    for (final s in sessions) {
      if (folderId != null) {
        if (s.folderId == folderId) return s;
      } else {
        if (s.folderId == null || s.folderId!.isEmpty) return s;
      }
    }
    return null;
  }

  Future<void> _syncProjection({bool quiet = false}) async {
    final binder = maybeReadTtplayBinder(context);
    if (binder == null || _syncingProjection) return;
    setState(() => _syncingProjection = true);
    try {
      final res = await binder.syncCloudProjection(full: true);
      if (!mounted) return;
      if (!quiet && res != null) {
        showSuccessSnackBar(context, '片库已同步：${res.itemsProjected} 部作品 · ${res.filesProjected} 个文件');
      }
      await _load();
    } catch (e) {
      if (mounted && !quiet) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _syncingProjection = false);
    }
  }

  Future<void> _openAddSource() async {
    final repo = _repo;
    if (repo == null || PlatformDetector.isTV()) return;

    final created = await Navigator.of(context).push<CloudSource>(
      MaterialPageRoute<CloudSource>(builder: (_) => CloudSourceEditScreen(repo: repo)),
    );
    if (!mounted || created == null) return;

    // Do NOT auto-scan on add; user manually scans mount or individual folders.
    showSuccessSnackBar(context, '已添加「${created.name}」，请按需手动触发扫描');
    await _load();
    unawaited(_syncProjection(quiet: true));
  }

  Future<void> _openEditSource(CloudSource source) async {
    final repo = _repo;
    if (repo == null || PlatformDetector.isTV()) return;

    final updated = await Navigator.of(context).push<CloudSource>(
      MaterialPageRoute<CloudSource>(
        builder: (_) => CloudSourceEditScreen(repo: repo, existingSource: source),
      ),
    );
    if (!mounted || updated == null) return;

    showSuccessSnackBar(context, '已保存「${updated.name}」的修改');
    await _load();
    unawaited(_syncProjection(quiet: true));
  }

  Future<void> _toggleAutoIncremental(CloudSource source, bool enabled) async {
    final repo = _repo;
    if (repo == null || _togglingAutoIncremental.contains(source.id)) return;
    if (enabled && !_hasCompletedAnyScan(source.id)) {
      showErrorSnackBar(context, '请先完成至少一次手动扫描后，再开启自动增量扫描');
      return;
    }

    setState(() => _togglingAutoIncremental.add(source.id));
    try {
      final cred = await repo.fetchCredential(source.id);
      final intervalMinutes = _autoIntervalBySource[source.id] ?? MountKeys.defaultAutoIncrementalIntervalMinutes;
      final updatedPayload = Map<String, dynamic>.from(cred.payload)
        ..['auto_incremental_scan'] = enabled
        ..['auto_incremental_interval_minutes'] = intervalMinutes;
      await repo.updateCredential(
        sourceId: source.id,
        baseVersion: cred.version,
        credentialPayload: updatedPayload,
        mode: 'refresh',
      );
      if (!mounted) return;
      setState(() => _autoIncrementalBySource[source.id] = enabled);
      showSuccessSnackBar(context, enabled ? '已为「${source.name}」开启自动增量扫描' : '已关闭自动增量扫描');
      unawaited(_syncProjection(quiet: true));
      maybeReadTtplayBinder(context)?.rescheduleCloudIncrementalTimer();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _togglingAutoIncremental.remove(source.id));
    }
  }

  Future<void> _updateAutoIncrementalInterval(CloudSource source, int minutes) async {
    final repo = _repo;
    if (repo == null || _togglingAutoIncremental.contains(source.id)) return;
    setState(() => _togglingAutoIncremental.add(source.id));
    try {
      final cred = await repo.fetchCredential(source.id);
      final updatedPayload = Map<String, dynamic>.from(cred.payload)
        ..['auto_incremental_interval_minutes'] = minutes;
      await repo.updateCredential(
        sourceId: source.id,
        baseVersion: cred.version,
        credentialPayload: updatedPayload,
        mode: 'refresh',
      );
      if (!mounted) return;
      setState(() => _autoIntervalBySource[source.id] = minutes);
      showSuccessSnackBar(
        context,
        '已将「${source.name}」增量检查间隔设为 ${MountKeys.formatAutoIncrementalInterval(minutes)}',
      );
      unawaited(_syncProjection(quiet: true));
      maybeReadTtplayBinder(context)?.rescheduleCloudIncrementalTimer();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _togglingAutoIncremental.remove(source.id));
    }
  }

  Future<void> _pickAndAddFolder(CloudSource source) async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final cred = await repo.fetchCredential(source.id);
      final driver = _buildDriverForSource(source, cred.payload);
      if (driver == null) return;
      try {
        if (!mounted) return;
        final picked = await showStorageFolderPicker(context, driver: driver);
        if (!mounted || picked == null) return;
        final path = StoragePath.normalize(picked.path);
        await repo.addFolder(source.id, path: path);
        if (!mounted) return;
        // Do NOT auto-scan after adding a folder; user triggers scan per folder.
        showSuccessSnackBar(context, '已添加目录：$path（可点击该行右侧按钮手动扫描）');
        await _load();
      } finally {
        await driver.close();
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _deleteFolder(CloudSource source, CloudSourceFolder folder) async {
    final repo = _repo;
    if (repo == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除扫描目录'),
        content: Text('确定从「${source.name}」中移除目录「${folder.path}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await repo.deleteFolder(source.id, folder.id);
      if (mounted) {
        showSuccessSnackBar(context, '已移除目录：${folder.path}');
        await _load();
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _deleteSource(CloudSource source) async {
    final repo = _repo;
    if (repo == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除云端媒体源'),
        content: Text('确定删除「${source.name}」吗？相关云端文件索引和凭据将被移除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await repo.deleteSource(source.id);
      if (mounted) {
        showSuccessSnackBar(context, '已删除「${source.name}」');
        await _syncProjection(quiet: true);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _startScan(CloudSource source, {CloudSourceFolder? folder}) async {
    final repo = _repo;
    final runner = _runner;
    if (repo == null || runner == null) return;
    final folderId = folder?.id;
    final key = CloudScanSessionRunner.taskKey(source.id, folderId);
    if (_startingKeys.contains(key)) return;

    if (runner.isScanning(source.id, folderId: folderId)) {
      if (runner.isCancelling(source.id, folderId: folderId)) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('停止扫描'),
          content: const Text('确定停止本次扫描吗？已上报的文件会保留在服务端继续刮削，未扫完的目录不会误删旧文件。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续扫描')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('停止扫描')),
          ],
        ),
      );
      if (confirmed == true) {
        runner.cancelScan(source.id, folderId: folderId);
      }
      return;
    }

    setState(() => _startingKeys.add(key));
    StorageDriver? driver;
    try {
      final cred = await repo.fetchCredential(source.id);
      driver = _buildDriverForSource(source, cred.payload);
      if (driver == null) {
        if (mounted) showErrorSnackBar(context, '该类型媒体源无需客户端目录扫描');
        return;
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _startingKeys.remove(key));
      } else {
        _startingKeys.remove(key);
      }
    }

    final activeDriver = driver;
    final targetLabel = folder != null ? '${source.name} · ${folder.path}' : source.name;
    try {
      final summary = await runner.runScan(
        sourceId: source.id,
        folderId: folderId,
        scanType: folderId != null ? 'folder' : 'full',
        targetLabel: targetLabel,
        driver: activeDriver,
      );
      _seenFinishedAtByKey[key] = summary.updatedAtMs;
      if (!mounted) return;
      if (summary.cancelled) {
        showSuccessSnackBar(
          context,
          summary.filesReported > 0
              ? '已停止扫描（已上报 ${summary.filesReported} 文件会保留并继续刮削）'
              : '已停止扫描',
        );
      } else {
        final label = folder != null ? folder.path : source.name;
        showSuccessSnackBar(
          context,
          '$label 扫描完成：上报 ${summary.filesReported} 文件（新增 ${summary.filesAdded} · 更新 ${summary.filesChanged}）',
        );
      }
      unawaited(_refreshSessionsFor(source.id));
    } catch (e) {
      final msg = e is CloudApiException ? e.message : '$e';
      if (mounted) {
        showErrorSnackBar(context, msg);
      }
    } finally {
      await activeDriver.close();
    }
  }

  Future<void> _refreshSessionsFor(String sourceId) async {
    final runner = _runner;
    if (runner == null || !_refreshingSessionSources.add(sourceId)) return;
    try {
      final sessions = await runner.listRecentSessions(sourceId);
      if (mounted) {
        setState(() => _sessionsBySource[sourceId] = sessions);
      }
    } catch (_) {
    } finally {
      _refreshingSessionSources.remove(sourceId);
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
          if ((cred['fallback_url'] as String?)?.isNotEmpty == true) MountKeys.fallbackUrl: cred['fallback_url'],
          MountKeys.username: cred['username'] ?? '',
          MountKeys.rootPath: cred['root_path'] ?? '/',
          MountKeys.allowInsecureTls: cred['allow_insecure_tls'] == true,
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
      return WebDavStorageDriver.fromMount(mount);
    }
    if (source.kind == 'smb') {
      final mount = StorageMount(
        id: source.id,
        kind: StorageKind.smb,
        displayName: source.name,
        config: {
          MountKeys.host: cred['host'] ?? '',
          MountKeys.share: cred['share'] ?? '',
          if ((cred['fallback_url'] as String?)?.isNotEmpty == true) MountKeys.fallbackUrl: cred['fallback_url'],
          if ((cred['username'] as String?)?.isNotEmpty == true) MountKeys.username: cred['username'],
          if ((cred['domain'] as String?)?.isNotEmpty == true) MountKeys.domain: cred['domain'],
          MountKeys.rootPath: cred['root_path'] ?? '/',
        },
        secrets: {
          if ((cred['password'] as String?)?.isNotEmpty == true) MountKeys.secretPassword: cred['password'] as String,
        },
      );
      return SmbStorageDriver.fromMount(mount);
    }
    if (source.kind == 'quark') {
      final mount = StorageMount(
        id: source.id,
        kind: StorageKind.quark,
        displayName: source.name,
        config: {
          MountKeys.quarkMode: cred['quark_mode'] ?? QuarkMode.web.name,
          MountKeys.rootFolderId: cred['root_folder_id'] ?? QuarkStorageDriver.defaultRootFolderId,
          MountKeys.rootPath: cred['root_path'] ?? '/',
          if (cred['download_connections'] is num)
            MountKeys.quarkDownloadConnections: (cred['download_connections'] as num).toInt(),
          if (cred['download_chunk_mib'] is num)
            MountKeys.quarkDownloadChunkMiB: (cred['download_chunk_mib'] as num).toInt(),
          if (cred['request_interval_ms'] is num)
            MountKeys.requestIntervalMs: (cred['request_interval_ms'] as num).toInt(),
        },
        secrets: {
          if ((cred['cookie'] as String?)?.isNotEmpty == true) MountKeys.secretCookie: cred['cookie'] as String,
        },
      );
      return QuarkStorageDriver.fromMount(mount);
    }
    return null;
  }

  static String _formatTime(int? ms) {
    if (ms == null || ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${dt.month}-${dt.day} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  Widget _buildStatusLine({
    required ThemeData theme,
    required bool scanning,
    required bool starting,
    required bool cancelling,
    required CloudScanProgress? live,
    required String? errorText,
    required CloudScanSessionRecord? latestSession,
    required String emptyHint,
  }) {
    if (cancelling) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            live != null
                ? '正在取消扫描 · 已遍历 ${live.directoriesVisited} 目录 · 已上报 ${live.filesReported} 文件'
                : '正在取消扫描...',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    if (scanning) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            live != null
                ? '扫描中 · 已遍历 ${live.directoriesVisited} 目录 · 发现 ${live.filesFound} / 上报 ${live.filesReported} 文件'
                    '${live.batchesSent > 0 ? '（第 ${live.batchesSent} 批）' : ''}'
                : '扫描中...',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    if (starting) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '正在连接媒体源并准备扫描...',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    if (errorText != null && errorText.isNotEmpty) {
      return Text(
        '扫描失败：$errorText',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (live != null && live.completed) {
      return Text(
        '扫描完成 · ${live.directoriesVisited} 目录 · 上报 ${live.filesReported} 文件'
        '（新增 ${live.filesAdded} / 更新 ${live.filesChanged}'
        '${live.filesMissing > 0 ? ' / 缺失 ${live.filesMissing}' : ''}）',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
      );
    }
    if (live != null && live.cancelled) {
      return Text('扫描已停止（已上报 ${live.filesReported} 文件）', style: theme.textTheme.bodySmall);
    }
    if (latestSession != null) {
      final ts = _formatTime(latestSession.finishedAt ?? latestSession.startedAt);
      final stateLabel = switch (latestSession.status) {
        'completed' => '已完成',
        'running' => '运行中',
        'partial' => '部分完成',
        _ => latestSession.status,
      };
      return Text(
        '最近扫描（$stateLabel${ts.isNotEmpty ? ' · $ts' : ''}）：上报 ${latestSession.filesReported} 文件'
        '（新增 ${latestSession.filesAdded} / 更新 ${latestSession.filesChanged}）',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Text(
      emptyHint,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
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
        title: const Text('云端媒体源'),
        actions: [
          OutlinedButton.icon(
            onPressed: _syncingProjection ? null : () => _syncProjection(),
            icon: const AppIcon(Symbols.sync_rounded, size: 18),
            label: Text(_syncingProjection ? '同步中...' : '同步片库'),
          ),
          const SizedBox(width: 6),
          IconButton(tooltip: '刷新', icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          if (!isTv) ...[
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _openAddSource,
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
                  const SizedBox(height: 6),
                  Text(
                    '添加夸克网盘、WebDAV、SMB 或 Emby / Jellyfin，端到端加密同步到全部设备',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  if (!isTv) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _openAddSource,
                      icon: const AppIcon(Symbols.add_rounded, size: 18),
                      label: const Text('添加云端媒体源'),
                    ),
                  ],
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
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (context, index) => _buildSourceCard(context, _sources[index], isTv: isTv, runner: runner),
                ),
              ),
            ),
    );
  }

  Widget _buildSourceCard(
    BuildContext context,
    CloudSource src, {
    required bool isTv,
    required CloudScanSessionRunner? runner,
  }) {
    final theme = Theme.of(context);
    final isScannable = _isScannableKind(src.kind);
    final canScan = !isTv && isScannable;
    final credStatus = src.credentialMeta?.status ?? 'valid';
    final credBad = credStatus != 'valid';

    final wholeKey = CloudScanSessionRunner.taskKey(src.id);
    final wholeStarting = _startingKeys.contains(wholeKey);
    final wholeScanning = runner?.isScanning(src.id) == true;
    final wholeCancelling = runner?.isCancelling(src.id) == true;
    final wholeLive = runner?.progressOf(src.id);
    final wholeErr = runner?.errorOf(src.id);
    final wholeLatest = _latestSessionFor(src.id);
    _scheduleSessionRefreshIfNewlyFinished(src.id, wholeKey, wholeLive);

    final hasCompletedOnce = _hasCompletedAnyScan(src.id);
    final autoIncEnabled = _autoIncrementalBySource[src.id] == true;
    final autoIntervalMinutes = _autoIntervalBySource[src.id] ?? MountKeys.defaultAutoIncrementalIntervalMinutes;
    final intervalLabel = MountKeys.formatAutoIncrementalInterval(autoIntervalMinutes);
    final togglingAuto = _togglingAutoIncremental.contains(src.id);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Clickable header -> opens CloudSourceEditScreen for editing name, credentials, folders, etc.
          InkWell(
            onTap: isTv ? null : () => _openEditSource(src),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              child: Row(
                children: [
                  AppIcon(_iconForKind(src.kind)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                src.name,
                                style: theme.textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (!isTv) ...[
                              const SizedBox(width: 4),
                              AppIcon(
                                Symbols.chevron_right_rounded,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_labelForKind(src.kind)} · ${credBad ? '凭据需重新授权（点击编辑）' : '已加密同步'}'
                          '${isScannable ? ' · ${src.folders.length} 个目录' : ' · 直连播放'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: credBad ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canScan)
                    FilledButton.tonal(
                      onPressed: (wholeStarting || wholeCancelling) ? null : () => _startScan(src),
                      child: Text(
                        wholeCancelling
                            ? '取消中...'
                            : wholeScanning
                            ? '取消扫描'
                            : wholeStarting
                            ? '启动中...'
                            : '扫描全部',
                      ),
                    ),
                  if (canScan) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '添加扫描目录',
                      icon: const AppIcon(Symbols.create_new_folder_rounded),
                      onPressed: () => _pickAndAddFolder(src),
                    ),
                  ],
                  if (!isTv)
                    IconButton(
                      tooltip: '删除媒体源',
                      icon: const AppIcon(Symbols.delete_rounded),
                      onPressed: () => _deleteSource(src),
                    ),
                ],
              ),
            ),
          ),

          // Whole-source scan status (shown when scanning whole source or when whole-source result exists)
          if (isScannable &&
              (wholeStarting ||
                  wholeScanning ||
                  wholeCancelling ||
                  wholeLive != null ||
                  wholeErr != null ||
                  wholeLatest != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _buildStatusLine(
                theme: theme,
                scanning: wholeScanning,
                starting: wholeStarting,
                cancelling: wholeCancelling,
                live: wholeLive,
                errorText: wholeErr,
                latestSession: wholeLatest,
                emptyHint: '',
              ),
            ),

          // Per-mount automatic incremental scan switch
          if (isScannable && !isTv) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  AppIcon(
                    Symbols.autorenew_rounded,
                    size: 18,
                    color: hasCompletedOnce ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('自动增量扫描', style: theme.textTheme.bodyMedium),
                        Text(
                          autoIncEnabled
                              ? '每 $intervalLabel 自动检查新增与变更'
                              : (hasCompletedOnce ? '已具备首次扫描基线，开启后自动增量检查变更' : '需先完成至少一次手动扫描后才可开启'),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (autoIncEnabled) ...[
                    PopupMenuButton<int>(
                      enabled: !togglingAuto,
                      tooltip: '调整增量检查间隔',
                      initialValue: autoIntervalMinutes,
                      onSelected: (minutes) => unawaited(_updateAutoIncrementalInterval(src, minutes)),
                      itemBuilder: (_) => [
                        for (final m in MountKeys.autoIncrementalIntervalPresets)
                          PopupMenuItem<int>(
                            value: m,
                            child: Text('每 ${MountKeys.formatAutoIncrementalInterval(m)}'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '每 $intervalLabel',
                              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                            ),
                            const SizedBox(width: 2),
                            AppIcon(Symbols.arrow_drop_down_rounded, size: 18, color: theme.colorScheme.primary),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Switch(
                    value: autoIncEnabled,
                    onChanged: togglingAuto ? null : (v) => _toggleAutoIncremental(src, v),
                  ),
                ],
              ),
            ),
          ],

          // Per-folder rows (one folder per line, each with independent scan button, live status & result)
          if (isScannable) ...[
            const Divider(height: 1),
            if (src.folders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    AppIcon(Symbols.folder_off_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '暂未添加独立目录（可点击右上角文件夹图标添加目录，或点击「扫描全部」扫描根目录）',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (var i = 0; i < src.folders.length; i++) ...[
                _buildFolderRow(context, src, src.folders[i], isTv: isTv, runner: runner),
                if (i < src.folders.length - 1) const Divider(height: 1, indent: 48),
              ],
          ],
        ],
      ),
    );
  }

  void _scheduleSessionRefreshIfNewlyFinished(String sourceId, String key, CloudScanProgress? live) {
    if (live == null || (!live.completed && !live.cancelled) || live.updatedAtMs <= 0) return;
    if (_seenFinishedAtByKey[key] == live.updatedAtMs) return;
    _seenFinishedAtByKey[key] = live.updatedAtMs;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshSessionsFor(sourceId));
    });
  }

  Widget _buildFolderRow(
    BuildContext context,
    CloudSource src,
    CloudSourceFolder folder, {
    required bool isTv,
    required CloudScanSessionRunner? runner,
  }) {
    final theme = Theme.of(context);
    final key = CloudScanSessionRunner.taskKey(src.id, folder.id);
    final starting = _startingKeys.contains(key);
    final scanning = runner?.isScanning(src.id, folderId: folder.id) == true;
    final cancelling = runner?.isCancelling(src.id, folderId: folder.id) == true;
    final live = runner?.progressOf(src.id, folderId: folder.id);
    final err = runner?.errorOf(src.id, folderId: folder.id);
    final latest = _latestSessionFor(src.id, folderId: folder.id);
    _scheduleSessionRefreshIfNewlyFinished(src.id, key, live);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(Symbols.folder_rounded, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folder.path,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                _buildStatusLine(
                  theme: theme,
                  scanning: scanning,
                  starting: starting,
                  cancelling: cancelling,
                  live: live,
                  errorText: err,
                  latestSession: latest,
                  emptyHint: '尚未扫描（点击右侧手动扫描此目录）',
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isTv) ...[
            OutlinedButton.icon(
              onPressed: (starting || cancelling) ? null : () => _startScan(src, folder: folder),
              icon: AppIcon(scanning ? Symbols.stop_rounded : Symbols.play_arrow_rounded, size: 16),
              label: Text(
                cancelling
                    ? '取消中...'
                    : scanning
                    ? '取消'
                    : starting
                    ? '启动中...'
                    : '扫描',
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '移除目录',
              icon: const AppIcon(Symbols.delete_outline_rounded, size: 20),
              onPressed: (scanning || starting) ? null : () => _deleteFolder(src, folder),
            ),
          ],
        ],
      ),
    );
  }

  String _labelForKind(String kind) => switch (kind) {
    'quark' => '夸克网盘',
    'webdav' => 'WebDAV',
    'smb' => 'SMB 共享',
    'emby' => 'Emby',
    'jellyfin' => 'Jellyfin',
    _ => kind.toUpperCase(),
  };

  IconData _iconForKind(String kind) => switch (kind) {
    'quark' => Symbols.cloud_rounded,
    'webdav' => Symbols.dns_rounded,
    'smb' => Symbols.lan_rounded,
    'emby' || 'jellyfin' => Symbols.video_library_rounded,
    _ => Symbols.hard_drive_rounded,
  };
}
