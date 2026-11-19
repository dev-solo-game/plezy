import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../ttplay/ttplay_admin_service.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import 'ttplay_admin_guard.dart';

/// Server-authoritative scraper, metadata provider & task configuration screen
/// for self-hosted `ttplay-server` (PC & mobile only; hidden on TV).
class TtplayScraperSettingsScreen extends StatefulWidget {
  const TtplayScraperSettingsScreen({super.key});

  @override
  State<TtplayScraperSettingsScreen> createState() => _TtplayScraperSettingsScreenState();
}

class _TtplayScraperSettingsScreenState extends State<TtplayScraperSettingsScreen> {
  static const double _maxWidth = 860;
  static const List<String> _languages = ['zh-CN', 'zh-TW', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'];

  TtplayServerSettings? _settings;
  TtplayTaskStatus? _tasks;
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _testStatus;

  final _tmdbKey = TextEditingController();
  final _tmdbApiBase = TextEditingController();
  final _tmdbImageBase = TextEditingController();
  final _proxy = TextEditingController();
  final _scanInterval = TextEditingController();
  final _tvdbApiKey = TextEditingController();
  final _tvdbPin = TextEditingController();
  final _recognitionWords = TextEditingController();

  bool _clearTmdbKey = false;
  String _lang = 'zh-CN';
  bool _preferNfo = false;
  bool _allowFallback = true;
  bool _allowPublic = false;
  bool _proxyImages = true;
  bool _watchLocalFs = true;
  bool _bangumi = false;
  bool _douban = false;
  bool _anilist = false;
  bool _imdb = false;
  bool _tvdb = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tmdbKey.dispose();
    _tmdbApiBase.dispose();
    _tmdbImageBase.dispose();
    _proxy.dispose();
    _scanInterval.dispose();
    _tvdbApiKey.dispose();
    _tvdbPin.dispose();
    _recognitionWords.dispose();
    super.dispose();
  }

  TtplayAdminService? get _admin => resolveTtplayAdminService(context);

  void _applySettingsToForm(TtplayServerSettings s) {
    _settings = s;
    _tmdbKey.clear();
    _clearTmdbKey = false;
    _tmdbApiBase.text = s.tmdbApiBase;
    _tmdbImageBase.text = s.tmdbImageBase;
    _proxy.text = s.metadataProxy;
    _scanInterval.text = '${s.scanIntervalMin}';
    _tvdbApiKey.clear();
    _tvdbPin.clear();
    _recognitionWords.text = s.customRecognitionWords;
    _lang = _languages.contains(s.scraperLang) ? s.scraperLang : 'zh-CN';
    _preferNfo = s.preferNfo;
    _allowFallback = s.allowFallbackMetadata;
    _allowPublic = s.allowPublicMetadata;
    _proxyImages = s.proxyImages;
    _watchLocalFs = s.watchLocalFS;
    _bangumi = s.bangumiEnabled;
    _douban = s.doubanEnabled;
    _anilist = s.anilistEnabled;
    _imdb = s.imdbEnabled;
    _tvdb = s.tvdbEnabled;
  }

  Future<void> _load() async {
    final admin = _admin;
    if (admin == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (settings, tasks) = await (admin.fetchSettings(), admin.fetchTaskStatus()).wait;
      if (!mounted) return;
      setState(() {
        _applySettingsToForm(settings);
        _tasks = tasks;
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

  Future<void> _save() async {
    final admin = _admin;
    if (admin == null || _saving) return;
    setState(() => _saving = true);
    try {
      final patch = <String, dynamic>{
        'tmdb_api_base': _tmdbApiBase.text.trim(),
        'tmdb_image_base': _tmdbImageBase.text.trim(),
        'metadata_proxy': _proxy.text.trim(),
        'scraper_lang': _lang,
        'prefer_nfo': _preferNfo,
        'allow_fallback_metadata': _allowFallback,
        'allow_public_metadata': _allowPublic,
        'proxy_images': _proxyImages,
        'watch_local_fs': _watchLocalFs,
        'scan_interval_min': int.tryParse(_scanInterval.text.trim()) ?? 0,
        'bangumi_enabled': _bangumi,
        'douban_enabled': _douban,
        'anilist_enabled': _anilist,
        'imdb_enabled': _imdb,
        'tvdb_enabled': _tvdb,
        'custom_recognition_words': _recognitionWords.text,
      };
      if (_clearTmdbKey) {
        patch['clear_tmdb_api_key'] = true;
      } else if (_tmdbKey.text.trim().isNotEmpty) {
        patch['tmdb_api_key'] = _tmdbKey.text.trim();
      }
      if (_tvdbApiKey.text.trim().isNotEmpty) {
        patch['tvdb_api_key'] = _tvdbApiKey.text.trim();
      }
      if (_tvdbPin.text.trim().isNotEmpty) {
        patch['tvdb_pin'] = _tvdbPin.text.trim();
      }
      final updated = await admin.updateSettings(patch);
      if (!mounted) return;
      setState(() {
        _applySettingsToForm(updated);
        _saving = false;
      });
      showSuccessSnackBar(context, t.serverAdmin.saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _runTest(Future<TtplayTestResult> Function() fn, String label) async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testStatus = null;
    });
    try {
      final res = await fn();
      if (!mounted) return;
      final latency = res.latencyMs != null ? ' (${res.latencyMs}ms)' : '';
      final msg = res.message != null && res.message!.isNotEmpty ? ' · ${res.message}' : '';
      setState(() {
        _testing = false;
        _testStatus = '$label: ${t.serverAdmin.testSuccess}$latency$msg';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testStatus = '$label: ${ttplayAdminErrorText(e)}';
      });
    }
  }

  Future<void> _triggerAction(Future<void> Function() fn, String successMsg) async {
    try {
      await fn();
      if (!mounted) return;
      showSuccessSnackBar(context, successMsg);
      final status = await _admin?.fetchTaskStatus();
      if (mounted && status != null) {
        setState(() => _tasks = status);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  Future<void> _clearCache() async {
    final admin = _admin;
    if (admin == null) return;
    try {
      final deleted = await admin.clearMetadataCache();
      if (!mounted) return;
      showSuccessSnackBar(context, t.serverAdmin.cacheCleared(count: deleted));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, ttplayAdminErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = maybeWatchAppSession(context);
    final binder = maybeWatchTtplayBinder(context);
    if (PlatformDetector.isTV() || !canUseTtplayAdmin(session: session, binder: binder)) {
      return buildTvAdminBlockedScaffold(context, t.serverAdmin.scraperTitle);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.serverAdmin.scraperTitle),
        actions: [
          IconButton(tooltip: t.common.refresh, icon: const AppIcon(Symbols.refresh_rounded), onPressed: _load),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: (_loading || _saving) ? null : _save,
            child: Text(t.common.save),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _settings == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: Text(t.common.retry)),
                ],
              ),
            )
          : _buildForm(context),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final admin = _admin!;
    final settings = _settings ?? const TtplayServerSettings();
    final tasks = _tasks ?? const TtplayTaskStatus();

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.serverAdmin.taskStatus, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        Chip(label: Text(t.serverAdmin.scanningCount(count: tasks.scans.length))),
                        Chip(label: Text(t.serverAdmin.pendingCount(count: tasks.pendingScrape))),
                        Chip(label: Text(t.serverAdmin.unmatchedCount(count: tasks.unmatchedCount))),
                      ],
                    ),
                    if (tasks.scrape.isRunning) ...[
                      const SizedBox(height: 8),
                      Text(
                        t.serverAdmin.scrapingProgress(
                          done: tasks.scrape.done,
                          total: tasks.scrape.total,
                          title: tasks.scrape.title ?? '',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: () => _triggerAction(() => admin.triggerScanAll(), t.serverAdmin.scanStarted),
                          child: Text(t.serverAdmin.scanAll),
                        ),
                        FilledButton.tonal(
                          onPressed: () => _triggerAction(() => admin.triggerScrape(), t.serverAdmin.scrapePending),
                          child: Text(t.serverAdmin.scrapePending),
                        ),
                        OutlinedButton(
                          onPressed: () => _triggerAction(
                            () => admin.triggerScrape(retryUnmatched: true),
                            t.serverAdmin.retryUnmatched,
                          ),
                          child: Text(t.serverAdmin.retryUnmatched),
                        ),
                        OutlinedButton(onPressed: _clearCache, child: Text(t.serverAdmin.clearCache)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.serverAdmin.tmdbSection, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tmdbKey,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.tmdbApiKey,
                        hintText: settings.tmdbApiKeySet
                            ? t.serverAdmin.tmdbApiKeySet(masked: settings.tmdbApiKeyMasked)
                            : null,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (settings.tmdbApiKeySet)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _clearTmdbKey,
                        onChanged: (v) => setState(() => _clearTmdbKey = v == true),
                        title: Text(t.serverAdmin.clearKey),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _tmdbApiBase,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.tmdbApiBase,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _tmdbImageBase,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.tmdbImageBase,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _proxy,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.metadataProxy,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _testing
                              ? null
                              : () => _runTest(
                                  () => admin.testTmdb(
                                    tmdbApiKey: _tmdbKey.text.trim(),
                                    tmdbApiBase: _tmdbApiBase.text.trim(),
                                    metadataProxy: _proxy.text.trim(),
                                  ),
                                  'TMDB',
                                ),
                          icon: const AppIcon(Symbols.network_check_rounded, size: 16),
                          label: Text(t.serverAdmin.testTmdb),
                        ),
                      ],
                    ),
                    if (_testStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(_testStatus!, style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _lang,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.scraperLang,
                        border: const OutlineInputBorder(),
                      ),
                      items: [for (final l in _languages) DropdownMenuItem(value: l, child: Text(l))],
                      onChanged: (v) {
                        if (v != null) setState(() => _lang = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _scanInterval,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.scanIntervalMin,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _preferNfo,
                      onChanged: (v) => setState(() => _preferNfo = v),
                      title: Text(t.serverAdmin.preferNfo),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _allowFallback,
                      onChanged: (v) => setState(() => _allowFallback = v),
                      title: Text(t.serverAdmin.allowFallbackMetadata),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _allowPublic,
                      onChanged: (v) => setState(() => _allowPublic = v),
                      title: Text(t.serverAdmin.allowPublicMetadata),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _proxyImages,
                      onChanged: (v) => setState(() => _proxyImages = v),
                      title: Text(t.serverAdmin.proxyImages),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _watchLocalFs,
                      onChanged: (v) => setState(() => _watchLocalFs = v),
                      title: Text(t.serverAdmin.watchLocalFs),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.serverAdmin.providersSection, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _providerRow(admin, 'bangumi', t.serverAdmin.bangumi, _bangumi, (v) => setState(() => _bangumi = v)),
                    _providerRow(admin, 'douban', t.serverAdmin.douban, _douban, (v) => setState(() => _douban = v)),
                    _providerRow(admin, 'anilist', t.serverAdmin.anilist, _anilist, (v) => setState(() => _anilist = v)),
                    _providerRow(admin, 'imdb', t.serverAdmin.imdb, _imdb, (v) => setState(() => _imdb = v)),
                    _providerRow(admin, 'tvdb', t.serverAdmin.tvdb, _tvdb, (v) => setState(() => _tvdb = v)),
                    if (_tvdb) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _tvdbApiKey,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.tvdbApiKey,
                          hintText: settings.tvdbApiKeySet ? t.serverAdmin.keepSecretHint : null,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _tvdbPin,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: t.serverAdmin.tvdbPin,
                          hintText: settings.tvdbPinSet ? t.serverAdmin.keepSecretHint : null,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _recognitionWords,
                      minLines: 3,
                      maxLines: 6,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.customRecognitionWords,
                        hintText: t.serverAdmin.customRecognitionWordsHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _providerRow(
    TtplayAdminService admin,
    String providerId,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: SwitchListTile(contentPadding: EdgeInsets.zero, value: value, onChanged: onChanged, title: Text(label)),
        ),
        TextButton(
          onPressed: _testing
              ? null
              : () => _runTest(
                  () => admin.testProvider(
                    providerId,
                    apiKey: providerId == 'tvdb' ? _tvdbApiKey.text.trim() : null,
                    pin: providerId == 'tvdb' ? _tvdbPin.text.trim() : null,
                    metadataProxy: _proxy.text.trim(),
                  ),
                  label,
                ),
          child: Text(t.serverAdmin.testProvider),
        ),
      ],
    );
  }
}
