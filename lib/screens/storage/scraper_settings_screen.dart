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
import '../../library/sync/sync_coordinator.dart';
import '../../library/sync/sync_local_store.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import 'mounts_screen.dart';

/// Server-managed metadata connection check and client-level language/Bangumi prefs.
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
  bool _bangumi = true;
  bool _loaded = false;
  bool _saving = false;
  ({bool ok, String message})? _testResult;
  bool _testing = false;

  String _endpointUrl = SyncLocalStore.effectiveDefaultOfficialSyncUrl;
  bool _isOfficialEndpoint = true;

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
    final sync = _maybeRead<SyncAndScanCoordinator>();

    final settings = store != null ? await store.loadScraper() : const ScraperSettings();
    var endpointUrl = SyncLocalStore.effectiveDefaultOfficialSyncUrl;
    var isOfficial = true;
    if (runner != null) {
      final resolved = await runner.resolveActiveMetadataEndpoint();
      endpointUrl = resolved.serverUrl;
      isOfficial = resolved.isOfficial;
    } else if (sync?.session case final sess?) {
      endpointUrl = sess.serverUrl;
      isOfficial = sess.serverKind == SyncServerKind.official;
    }

    if (!mounted) return;
    setState(() {
      _stored = settings;
      _language = settings.language;
      _bangumi = settings.bangumiEnabled;
      _endpointUrl = endpointUrl;
      _isOfficialEndpoint = isOfficial;
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
    try {
      final res = runner != null
          ? await runner.checkMetadataServerConnection()
          : (
              serverUrl: _endpointUrl,
              isOfficial: _isOfficialEndpoint,
              config: await ServerMetadataProvider.fetchConfig(serverUrl: _endpointUrl),
            );
      if (mounted) {
        setState(() {
          _endpointUrl = res.serverUrl;
          _isOfficialEndpoint = res.isOfficial;
        });
      }
      final cfg = res.config;
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
        _testResult = result;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final store = _maybeRead<LibrarySettingsStore>();
    final scans = _maybeRead<LibraryScanService>();
    final sync = _maybeRead<SyncAndScanCoordinator>();
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
          bangumiEnabled: _bangumi,
        ),
      );
    }
    if (scans != null) {
      unawaited(scans.scrapeLibrary(retryUnmatched: true, restart: true));
    }
    if (sync != null) {
      unawaited(sync.syncScraperSettingsToCloud());
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
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                AppIcon(
                                  _isOfficialEndpoint ? Symbols.cloud_sync_rounded : Symbols.dns_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(t.storage.metadataServiceTitle, style: theme.textTheme.titleMedium),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _isOfficialEndpoint
                                  ? t.storage.metadataServiceOfficial
                                  : t.storage.metadataServiceSelfHosted,
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _endpointUrl,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              t.storage.metadataServiceManagedHint,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                FocusableButton(
                                  onPressed: _testing ? null : _testConnection,
                                  child: OutlinedButton.icon(
                                    onPressed: _testing ? null : _testConnection,
                                    icon: _testing
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const AppIcon(Symbols.network_check_rounded),
                                    label: Text(t.storage.metadataServerTest),
                                  ),
                                ),
                              ],
                            ),
                            if (_testResult case final result?) ...[
                              const SizedBox(height: 10),
                              Text(
                                result.message,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: result.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: _gap),
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 8),
                      child: Text(
                        t.storage.metadataPreferencesHeading,
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
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
