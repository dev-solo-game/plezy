import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../library/library_scan_service.dart';
import '../../library/library_scrape_runner.dart';
import '../../library/library_settings.dart';
import '../../library/scrapers/scraped_metadata.dart';
import '../../library/scrapers/server_metadata_provider.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';

/// Official metadata server connection check and client-level metadata language prefs.
class ScraperSettingsScreen extends StatefulWidget {
  const ScraperSettingsScreen({super.key});

  @override
  State<ScraperSettingsScreen> createState() => _ScraperSettingsScreenState();
}

class _ScraperSettingsScreenState extends State<ScraperSettingsScreen> {
  static const double _gap = 14;
  static const List<String> _languages = ['zh-CN', 'zh-TW', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'];

  ScraperSettings _stored = const ScraperSettings();
  String _language = ScraperSettings.defaultLanguage;
  bool _loaded = false;
  bool _saving = false;
  ({bool ok, String message})? _testResult;
  bool _testing = false;

  String _endpointUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
  List<String> _enabledProviders = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  T? _maybeRead<T>() {
    try {
      return Provider.of<T>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final store = _maybeRead<LibrarySettingsStore>();
    final runner = _maybeRead<LibraryScrapeRunner>();

    final settings = store != null ? await store.loadScraper() : const ScraperSettings();
    var endpointUrl = ServerMetadataProvider.defaultOfficialMetadataUrl;
    if (runner != null) {
      final resolved = await runner.resolveActiveMetadataEndpoint();
      endpointUrl = resolved.serverUrl;
    }

    if (!mounted) return;
    setState(() {
      _stored = settings;
      _language = settings.language;
      _endpointUrl = endpointUrl;
      _loaded = true;
    });
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final runner = _maybeRead<LibraryScrapeRunner>();
    ({bool ok, String message}) result;
    var providers = _enabledProviders;
    try {
      final res = runner != null
          ? await runner.checkMetadataServerConnection()
          : (
              serverUrl: _endpointUrl,
              isOfficial: true,
              config: await ServerMetadataProvider.fetchConfig(serverUrl: _endpointUrl),
            );
      if (mounted) {
        setState(() {
          _endpointUrl = res.serverUrl;
        });
      }
      final cfg = res.config;
      providers = cfg.enabledProviders;
      if (cfg.tmdbConfigured) {
        result = (
          ok: true,
          message: t.storage.metadataServerTestOk(
            works: cfg.cachedWorks,
            seasons: cfg.cachedSeasons,
            people: cfg.cachedPeople,
          ),
        );
      } else {
        result = (ok: false, message: t.storage.metadataServerTestNoKey);
      }
    } on ScrapeException catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: e.message));
    } catch (e) {
      result = (ok: false, message: t.storage.tmdbTestFailed(message: '$e'));
    }

    if (mounted) {
      setState(() {
        _testing = false;
        _enabledProviders = providers;
        _testResult = result;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final store = _maybeRead<LibrarySettingsStore>();
    final scans = _maybeRead<LibraryScanService>();
    final navigator = Navigator.of(context);

    setState(() => _saving = true);
    if (store != null) {
      await store.saveScraper(
        ScraperSettings(
          tmdbApiKey: _stored.tmdbApiKey,
          tmdbApiBase: _stored.tmdbApiBase,
          tmdbImageBase: _stored.tmdbImageBase,
          language: _language,
          proxy: _stored.proxy,
          bangumiEnabled: _stored.bangumiEnabled,
        ),
      );
    }
    if (scans != null) {
      unawaited(scans.scrapeLibrary(retryUnmatched: true, restart: true));
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.storage.scraperSettings)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            AppIcon(Symbols.cloud_done_rounded, size: 22, color: colorScheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                t.storage.metadataServiceTitle,
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t.storage.metadataServiceOfficial,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _endpointUrl,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        if (_enabledProviders.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final p in _enabledProviders)
                                Chip(
                                  label: Text(p.toUpperCase()),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          t.storage.metadataServiceManagedHint,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        FocusableButton(
                          child: OutlinedButton.icon(
                            onPressed: _testing ? null : _testConnection,
                            icon: _testing
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const AppIcon(Symbols.network_check_rounded, size: 18),
                            label: Text(t.storage.metadataServerTest),
                          ),
                        ),
                        if (_testResult case final result?) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: result.ok ? colorScheme.primaryContainer : colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                AppIcon(
                                  result.ok ? Symbols.check_circle_rounded : Symbols.error_outline_rounded,
                                  size: 18,
                                  color: result.ok ? colorScheme.onPrimaryContainer : colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    result.message,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: result.ok ? colorScheme.onPrimaryContainer : colorScheme.onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  t.storage.metadataPreferencesHeading,
                  style: theme.textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                FocusableListTile(
                  leading: const AppIcon(Symbols.translate_rounded),
                  title: Text(t.storage.metadataLanguage),
                  subtitle: Text(_language),
                  trailing: const AppIcon(Symbols.chevron_right_rounded),
                  onTap: _pickLanguage,
                ),
                const SizedBox(height: _gap * 1.5),
                FocusableButton(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(t.common.save),
                  ),
                ),
              ],
            ),
    );
  }
}
