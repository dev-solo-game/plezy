import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../library_cloud/cloud_api_client.dart';
import '../../library_cloud/projection_sync.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../ttplay_admin/ttplay_admin_guard.dart';

/// Cloud unmatched files center & manual match screen for `media_library` (C4).
class CloudUnmatchedScreen extends StatefulWidget {
  const CloudUnmatchedScreen({super.key});

  @override
  State<CloudUnmatchedScreen> createState() => _CloudUnmatchedScreenState();
}

class _CloudUnmatchedScreenState extends State<CloudUnmatchedScreen> {
  static const double _maxWidth = 880;

  List<Map<String, dynamic>> _items = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  CloudProjectionSyncClient? get _sync => maybeReadTtplayBinder(context)?.cloudProjectionSync;

  Future<void> _load() async {
    final sync = _sync;
    if (sync == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await sync.listUnmatched(page: 1, pageSize: 100);
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _total = res.total;
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

  Future<void> _ignoreFile(Map<String, dynamic> item) async {
    final sync = _sync;
    final fileId = (item['id'] as num?)?.toInt();
    if (sync == null || fileId == null) return;
    try {
      await sync.ignoreUnmatched(fileIds: [fileId]);
      if (!mounted) return;
      showSuccessSnackBar(context, '已忽略该未匹配文件');
      await _load();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  Future<void> _openManualMatch(Map<String, dynamic> item) async {
    final sync = _sync;
    if (sync == null) return;
    final matched = await showDialog<bool>(
      context: context,
      builder: (_) => _CloudManualMatchDialog(sync: sync, file: item),
    );
    if (matched == true && mounted) {
      await _load();
    }
  }

  Future<void> _openMatchRulesDialog() async {
    final sync = _sync;
    if (sync == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _CloudMatchRulesDialog(sync: sync),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = maybeWatchAppSession(context);
    final binder = maybeWatchTtplayBinder(context);
    if (PlatformDetector.isTV() || session?.isSelfHosted != true || binder?.cloudProjectionSync == null) {
      return buildTvAdminBlockedScaffold(context, '云端待匹配中心');
    }

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? '云端待匹配中心 ($_total)' : '云端待匹配中心'),
        actions: [
          OutlinedButton.icon(
            onPressed: _openMatchRulesDialog,
            icon: const AppIcon(Symbols.rule_folder_rounded, size: 18),
            label: const Text('匹配规则'),
          ),
          const SizedBox(width: 4),
          IconButton(tooltip: '刷新', icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _items.isEmpty
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
          : _items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(Symbols.check_circle_rounded, size: 48),
                  const SizedBox(height: 12),
                  Text('所有云端文件均已完成匹配', style: theme.textTheme.titleMedium),
                ],
              ),
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final path = item['path'] as String? ?? '';
                    final sourceName = item['source_name'] as String? ?? '';
                    final state = item['match_state'] as String? ?? 'unmatched';
                    return Card(
                      child: ListTile(
                        leading: const AppIcon(Symbols.help_center_rounded),
                        title: Text(path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [if (sourceName.isNotEmpty) sourceName, state, path].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Wrap(
                          spacing: 6,
                          children: [
                            TextButton(
                              onPressed: () => _ignoreFile(item),
                              child: const Text('忽略'),
                            ),
                            FilledButton.tonal(
                              onPressed: () => _openManualMatch(item),
                              child: const Text('手工匹配'),
                            ),
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
}

class _CloudManualMatchDialog extends StatefulWidget {
  const _CloudManualMatchDialog({required this.sync, required this.file});

  final CloudProjectionSyncClient sync;
  final Map<String, dynamic> file;

  @override
  State<_CloudManualMatchDialog> createState() => _CloudManualMatchDialogState();
}

class _CloudManualMatchDialogState extends State<_CloudManualMatchDialog> {
  static const _providers = ['all', 'tmdb', 'douban', 'bangumi', 'anilist', 'imdb', 'tvdb'];

  late final TextEditingController _queryCtrl = TextEditingController(
    text: _initialTitle(widget.file),
  );
  final _yearCtrl = TextEditingController();
  String _kind = 'movie';
  String _provider = 'all';
  bool _createRule = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _results = const [];

  static String _initialTitle(Map<String, dynamic> file) {
    final parsed = file['parsed'];
    if (parsed is Map && (parsed['title'] as String?)?.trim().isNotEmpty == true) {
      return (parsed['title'] as String).trim();
    }
    final path = file['path'] as String? ?? '';
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  void initState() {
    super.initState();
    final parsed = widget.file['parsed'];
    if (parsed is Map) {
      if (parsed['is_tv'] == true) _kind = 'show';
      final y = (parsed['year'] as num?)?.toInt();
      if (y != null && y > 0) _yearCtrl.text = '$y';
    }
    unawaited(_search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await widget.sync.searchMetadata(
        query: q,
        kind: _kind,
        provider: _provider,
        year: int.tryParse(_yearCtrl.text.trim()),
      );
      if (mounted) {
        setState(() {
          _results = list;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is CloudApiException ? e.message : '$e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _apply(Map<String, dynamic> candidate) async {
    final fileId = (widget.file['id'] as num?)?.toInt();
    if (fileId == null || _busy) return;
    final provider = (candidate['source'] as String? ?? 'tmdb').toLowerCase();
    final extId = '${candidate['id'] ?? ''}';
    if (extId.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sync.applyManualMatch(
        fileIds: [fileId],
        provider: provider,
        externalId: extId,
        kind: _kind,
        createRule: _createRule,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is CloudApiException ? e.message : '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手工匹配云端元数据'),
      content: SizedBox(
        width: 540,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    decoration: const InputDecoration(labelText: '片名或直查 ID', border: OutlineInputBorder(), isDense: true),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: TextField(
                    controller: _yearCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '年份', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                DropdownButton<String>(
                  value: _kind,
                  items: const [
                    DropdownMenuItem(value: 'movie', child: Text('电影')),
                    DropdownMenuItem(value: 'show', child: Text('剧集')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _kind = v);
                  },
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _provider,
                  items: [for (final p in _providers) DropdownMenuItem(value: p, child: Text(p.toUpperCase()))],
                  onChanged: (v) {
                    if (v != null) setState(() => _provider = v);
                  },
                ),
                const Spacer(),
                FilledButton.tonal(onPressed: _busy ? null : _search, child: const Text('搜索')),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _createRule,
              onChanged: (v) => setState(() => _createRule = v ?? true),
              title: const Text('同时写入目录匹配规则（后续新增剧集自动归入）'),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 6),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final r = _results[index];
                        final title = r['title'] as String? ?? '';
                        final year = r['year'];
                        final src = (r['source'] as String? ?? 'tmdb').toUpperCase();
                        return ListTile(
                          dense: true,
                          title: Text(year != null ? '$title ($year)' : title),
                          subtitle: Text('$src · #${r['id']}'),
                          trailing: FilledButton(
                            onPressed: () => _apply(r),
                            child: const Text('应用'),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('关闭')),
      ],
    );
  }
}

class _CloudMatchRulesDialog extends StatefulWidget {
  const _CloudMatchRulesDialog({required this.sync});

  final CloudProjectionSyncClient sync;

  @override
  State<_CloudMatchRulesDialog> createState() => _CloudMatchRulesDialogState();
}

class _CloudMatchRulesDialogState extends State<_CloudMatchRulesDialog> {
  List<Map<String, dynamic>> _rules = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.sync.listMatchRules();
      if (mounted) {
        setState(() {
          _rules = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is CloudApiException ? e.message : '$e';
        });
      }
    }
  }

  Future<void> _deleteRule(String id) async {
    try {
      await widget.sync.deleteMatchRule(id);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e is CloudApiException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('云端目录匹配规则'),
      content: SizedBox(
        width: 540,
        height: 380,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!))
            : _rules.isEmpty
            ? const Center(child: Text('暂无目录匹配规则'))
            : ListView.separated(
                itemCount: _rules.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final r = _rules[index];
                  final id = r['id'] as String? ?? '';
                  final prefix = r['path_prefix'] as String? ?? '';
                  final action = r['action'] as String? ?? 'bind';
                  final target = [
                    if ((r['target_provider'] as String?)?.isNotEmpty == true) r['target_provider'],
                    if ((r['target_kind'] as String?)?.isNotEmpty == true) r['target_kind'],
                    if ((r['target_ext_id'] as String?)?.isNotEmpty == true) '#${r['target_ext_id']}',
                  ].join(':');
                  return ListTile(
                    dense: true,
                    title: Text(prefix, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(target.isNotEmpty ? '$action → $target' : action),
                    trailing: IconButton(
                      tooltip: '删除规则',
                      icon: const AppIcon(Symbols.delete_rounded),
                      onPressed: id.isEmpty ? null : () => _deleteRule(id),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
