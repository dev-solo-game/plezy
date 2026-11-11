import '../database/app_database.dart';
import '../services/credential_vault.dart';
import 'scrapers/tmdb_provider.dart';

/// How the scrapers are configured.
class ScraperSettings {
  const ScraperSettings({
    this.tmdbApiKey = '',
    this.tmdbApiBase = '',
    this.tmdbImageBase = '',
    this.language = defaultLanguage,
    this.proxy = '',
    this.bangumiEnabled = true,
  });

  static const String defaultLanguage = 'zh-CN';

  /// A TMDB v3 key or v4 read-access token. Empty disables TMDB.
  final String tmdbApiKey;

  /// Empty means the official host.
  final String tmdbApiBase;
  final String tmdbImageBase;

  /// Metadata language as TMDB writes it: `zh-CN`, `zh-TW`, `en-US`…
  final String language;

  /// `host:port` of an HTTP proxy for metadata requests, or empty.
  final String proxy;

  /// Whether anime is looked up on Bangumi before TMDB.
  final bool bangumiEnabled;

  bool get hasTmdb => tmdbApiKey.trim().isNotEmpty;

  String get effectiveTmdbApiBase => tmdbApiBase.trim().isEmpty ? TmdbProvider.defaultApiBase : tmdbApiBase.trim();

  String get effectiveTmdbImageBase =>
      tmdbImageBase.trim().isEmpty ? TmdbProvider.defaultImageBase : tmdbImageBase.trim();
}

/// Persists [ScraperSettings] in the `library_settings` table.
class LibrarySettingsStore {
  LibrarySettingsStore(this._db);

  final AppDatabase _db;

  static const String _tmdbApiKey = 'scraper.tmdb.apiKey';
  static const String _tmdbApiBase = 'scraper.tmdb.apiBase';
  static const String _tmdbImageBase = 'scraper.tmdb.imageBase';
  static const String _language = 'scraper.language';
  static const String _proxy = 'scraper.proxy';
  static const String _bangumiEnabled = 'scraper.bangumi.enabled';

  Future<ScraperSettings> loadScraper() async {
    final rows = {for (final row in await _db.select(_db.librarySettings).get()) row.key: row.value};
    final storedKey = rows[_tmdbApiKey];
    return ScraperSettings(
      // A key that no longer decrypts reads as "not set"; the user re-enters it.
      tmdbApiKey: storedKey == null ? '' : await CredentialVault.reveal(storedKey) ?? '',
      tmdbApiBase: rows[_tmdbApiBase] ?? '',
      tmdbImageBase: rows[_tmdbImageBase] ?? '',
      language: rows[_language] ?? ScraperSettings.defaultLanguage,
      proxy: rows[_proxy] ?? '',
      bangumiEnabled: rows[_bangumiEnabled] != 'false',
    );
  }

  static const String _namingVersion = 'library.namingVersion';

  /// The version of the naming rules the stored files were filed with.
  Future<int> namingVersion() async {
    final row = await (_db.select(_db.librarySettings)..where((t) => t.key.equals(_namingVersion))).getSingleOrNull();
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  Future<void> setNamingVersion(int version) async {
    await _db
        .into(_db.librarySettings)
        .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: _namingVersion, value: '$version'));
  }

  Future<void> saveScraper(ScraperSettings settings) async {
    final key = settings.tmdbApiKey.trim();
    final values = {
      _tmdbApiKey: key.isEmpty ? '' : await CredentialVault.protect(key),
      _tmdbApiBase: settings.tmdbApiBase.trim(),
      _tmdbImageBase: settings.tmdbImageBase.trim(),
      _language: settings.language.trim().isEmpty ? ScraperSettings.defaultLanguage : settings.language.trim(),
      _proxy: settings.proxy.trim(),
      _bangumiEnabled: '${settings.bangumiEnabled}',
    };
    await _db.transaction(() async {
      for (final entry in values.entries) {
        await _db
            .into(_db.librarySettings)
            .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: entry.key, value: entry.value));
      }
    });
  }
}
