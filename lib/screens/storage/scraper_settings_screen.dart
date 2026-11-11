import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../library/scrapers/scraper_http.dart';
import '../../library/scrapers/scraped_metadata.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../library/library_scan_service.dart';
import '../../library/library_settings.dart';
import '../../library/scrapers/tmdb_provider.dart';
import 'mounts_screen.dart';

/// Where metadata comes from: the TMDB key, language, mirrors and proxy.
class ScraperSettingsScreen extends StatefulWidget {
  const ScraperSettingsScreen({super.key});

  @override
  State<ScraperSettingsScreen> createState() => _ScraperSettingsScreenState();
}

class _ScraperSettingsScreenState extends State<ScraperSettingsScreen> {
  static const double _gap = 14;
  static const List<String> _languages = ['zh-CN', 'zh-TW', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'];

  final _apiKey = TextEditingController();
  final _apiBase = TextEditingController();
  final _imageBase = TextEditingController();
  final _proxy = TextEditingController();
  String _language = ScraperSettings.defaultLanguage;
  bool _bangumi = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = await context.read<LibrarySettingsStore>().loadScraper();
    if (!mounted) return;
    setState(() {
      _apiKey.text = settings.tmdbApiKey;
      // Shown filled in, so the default host can be edited rather than typed.
      _apiBase.text = settings.tmdbApiBase.isEmpty ? TmdbProvider.defaultApiHost : settings.tmdbApiBase;
      _imageBase.text = settings.tmdbImageBase.isEmpty ? TmdbProvider.defaultImageHost : settings.tmdbImageBase;
      _proxy.text = settings.proxy;
      _language = settings.language;
      _bangumi = settings.bangumiEnabled;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    for (final controller in [_apiKey, _apiBase, _imageBase, _proxy]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Result of the last connection test: null while none ran, else the
  /// message to show and whether it passed.
  ({bool ok, String message})? _testResult;
  bool _testing = false;

  Future<void> _testConnection() async {
    if (_testing) return;
    final key = _apiKey.text.trim();
    if (key.isEmpty) {
      setState(() => _testResult = (ok: false, message: t.storage.tmdbTestNoKey));
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final provider = TmdbProvider(
      apiKey: key,
      language: _language,
      apiBase: _apiBase.text,
      imageBase: _imageBase.text,
      http: ScraperHttp(proxy: _proxy.text),
    );
    ({bool ok, String message}) result;
    try {
      await provider.checkConnection();
      result = (ok: true, message: t.storage.tmdbTestOk);
    } on ScrapeException catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: e.message));
    } finally {
      provider.close();
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final store = context.read<LibrarySettingsStore>();
    final scans = context.read<LibraryScanService>();
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    await store.saveScraper(
      ScraperSettings(
        tmdbApiKey: _apiKey.text,
        tmdbApiBase: _apiBase.text,
        tmdbImageBase: _imageBase.text,
        language: _language,
        proxy: _proxy.text,
        bangumiEnabled: _bangumi,
      ),
    );
    // New settings may reach titles the old ones could not: try them again,
    // and stop a run still going with the old ones.
    unawaited(scans.scrapeLibrary(retryUnmatched: true, restart: true));
    if (mounted) navigator.pop();
  }

  Future<void> _pickLanguage() async {
    final picked = await showOptionPickerDialog<String>(
      context,
      title: t.storage.metadataLanguage,
      options: [
        for (final code in _languages)
          (icon: code == _language ? Symbols.check_rounded : null, label: code, value: code),
      ],
    );
    if (picked != null && mounted) setState(() => _language = picked);
  }

  // The fields set TvTextInputAutoOpenBehavior.never: on Android TV the
  // keyboard otherwise opens as the remote lands on a field and keeps its
  // arrows. OK starts typing.
  InputDecoration _decoration(String label, {String? hint, String? helper}) => InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.storage.scraperSettings)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _apiKey,
                      autofocus: PlatformDetector.isTV(),
                      decoration: _decoration(t.storage.tmdbKey, helper: t.storage.tmdbKeyHelp),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    const SizedBox(height: _gap),
                    // A picker rather than a dropdown: a remote's arrows move
                    // between rows instead of getting lost in a menu.
                    FocusableListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: false,
                      leading: const AppIcon(Symbols.translate_rounded),
                      title: Text(t.storage.metadataLanguage),
                      subtitle: Text(_language),
                      trailing: const AppIcon(Symbols.chevron_right_rounded),
                      onTap: _pickLanguage,
                    ),
                    FocusableSwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: false,
                      title: Text(t.storage.bangumiForAnime),
                      subtitle: Text(t.storage.bangumiForAnimeHelp),
                      value: _bangumi,
                      onChanged: (value) => setState(() => _bangumi = value),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 20, bottom: 12),
                      child: Text(
                        t.storage.sectionAdvanced,
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _proxy,
                      decoration: _decoration(
                        t.storage.metadataProxy,
                        hint: '127.0.0.1:7890',
                        helper: t.storage.metadataProxyHelp,
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _apiBase,
                      decoration: _decoration(t.storage.tmdbApiBase, hint: TmdbProvider.defaultApiHost),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    FocusableTextField(
                      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                      controller: _imageBase,
                      decoration: _decoration(t.storage.tmdbImageBase, hint: TmdbProvider.defaultImageHost),
                      autocorrect: false,
                    ),
                    const SizedBox(height: _gap),
                    Row(
                      children: [
                        FocusableButton(
                          onPressed: _testing ? null : _testConnection,
                          child: OutlinedButton.icon(
                            onPressed: _testing ? null : _testConnection,
                            icon: _testing
                                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const AppIcon(Symbols.network_check_rounded),
                            label: Text(t.storage.tmdbTest),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_testResult case final result?)
                          Expanded(
                            child: Text(
                              result.message,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: result.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FocusableButton(
                useBackgroundFocus: true,
                onPressed: _saving || !_loaded ? null : _save,
                child: FilledButton(
                  onPressed: _saving || !_loaded ? null : _save,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: Text(t.common.save),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
