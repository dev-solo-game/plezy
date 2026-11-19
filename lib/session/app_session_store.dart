import 'dart:convert';

import '../database/app_database.dart';
import '../services/credential_vault.dart';
import '../utils/app_logger.dart';
import 'app_session_models.dart';

/// Persists dual-mode session selection (`offline` vs `self_hosted`) and the
/// encrypted self-hosted token inside `sync_metadata`.
class AppSessionStore {
  AppSessionStore(this.db);

  final AppDatabase db;

  static const keyMode = 'app_login_mode';
  static const keySelfHostedSession = 'self_hosted_session';
  static const loggedOutModeValue = 'logged_out';
  static const _legacyOnboardingKey = 'sync_onboarding_completed';
  static const _legacyCloudSessionKey = 'sync_session';

  Future<String?> _getMeta(String key) async {
    final row = await (db.select(db.syncMetadata)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _setMeta(String key, String value) async {
    await db
        .into(db.syncMetadata)
        .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: key, value: value));
  }

  Future<void> _deleteMeta(String key) async {
    await (db.delete(db.syncMetadata)..where((t) => t.key.equals(key))).go();
  }

  Future<({AppLoginMode? mode, SelfHostedSession? selfHosted, bool explicitlyLoggedOut})> load() async {
    final rawMode = await _getMeta(keyMode);
    var mode = AppLoginMode.fromStorage(rawMode);
    var explicitlyLoggedOut = rawMode == loggedOutModeValue;

    // Migrate legacy Local/LAN installs without prompting again; retire any
    // legacy cloud-sync session or explicit v1 logout to mode selection.
    if (mode == null && !explicitlyLoggedOut) {
      final legacyOnboarding = await _getMeta(_legacyOnboardingKey);
      final legacyCloud = await _getMeta(_legacyCloudSessionKey);
      if (legacyCloud != null && legacyCloud.isNotEmpty) {
        explicitlyLoggedOut = true;
        await _setMeta(keyMode, loggedOutModeValue);
      } else if (legacyOnboarding == '0' || legacyOnboarding == 'false') {
        explicitlyLoggedOut = true;
        await _setMeta(keyMode, loggedOutModeValue);
      } else if (legacyOnboarding == '1' || legacyOnboarding == 'true') {
        mode = AppLoginMode.offline;
        await _setMeta(keyMode, mode.storageValue);
      }
      if (legacyCloud != null) {
        await _deleteMeta(_legacyCloudSessionKey);
      }
      if (legacyOnboarding != null) {
        await _deleteMeta(_legacyOnboardingKey);
      }
    }

    SelfHostedSession? session;
    final rawSession = await _getMeta(keySelfHostedSession);
    if (rawSession != null && rawSession.isNotEmpty) {
      final clear = await CredentialVault.reveal(rawSession);
      if (clear != null && clear.isNotEmpty) {
        try {
          final decoded = jsonDecode(clear);
          if (decoded is Map) {
            final parsed = SelfHostedSession.fromJson(Map<String, dynamic>.from(decoded));
            if (parsed.serverUrl.isNotEmpty && parsed.accessToken.isNotEmpty && parsed.username.isNotEmpty) {
              session = parsed;
            }
          }
        } catch (e) {
          appLogger.w('Corrupt self-hosted session in store, dropping', error: e);
        }
      }
    }

    if (mode == AppLoginMode.selfHosted && session == null) {
      await clearMode();
      return (mode: null, selfHosted: null, explicitlyLoggedOut: true);
    }

    return (mode: mode, selfHosted: session, explicitlyLoggedOut: explicitlyLoggedOut);
  }

  Future<void> saveOfflineMode() async {
    await _setMeta(keyMode, AppLoginMode.offline.storageValue);
    await _deleteMeta(keySelfHostedSession);
  }

  Future<void> saveSelfHostedSession(SelfHostedSession session) async {
    await _setMeta(keyMode, AppLoginMode.selfHosted.storageValue);
    await _setMeta(keySelfHostedSession, await CredentialVault.protect(jsonEncode(session.toJson())));
  }

  Future<void> clearMode() async {
    await _setMeta(keyMode, loggedOutModeValue);
    await _deleteMeta(keySelfHostedSession);
  }
}
