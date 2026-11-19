import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../utils/app_logger.dart';
import '../library_repository.dart';
import '../library_scan_service.dart';
import 'deterministic_keys.dart';
import 'lan_peer_sync_service.dart';
import 'library_workspace_store.dart';
import 'sync_api_client.dart';
import 'sync_crypto.dart';
import 'sync_local_store.dart';
import 'sync_mapper.dart';
import 'sync_models.dart';
import 'sync_sign_in_preview.dart';

export 'sync_local_store.dart' show SyncMode, SyncServerKind, defaultOfficialSyncUrl, normalizeSyncServerUrl;
export 'sync_sign_in_preview.dart';

enum SyncQrAuthErrorCode { notSignedIn, invalidQrUri, serverMismatch, expired }

class SyncQrAuthException implements Exception {
  const SyncQrAuthException(this.code, {this.currentServer, this.targetServer});

  final SyncQrAuthErrorCode code;
  final String? currentServer;
  final String? targetServer;

  @override
  String toString() => 'SyncQrAuthException(${code.name}, current=$currentServer, target=$targetServer)';
}

/// Coordinates end-to-end encrypted multi-device cloud synchronization and local
/// library workspace isolation, while keeping LAN peer discovery active for
/// companion remote control.
class SyncAndScanCoordinator extends ChangeNotifier {
  SyncAndScanCoordinator({
    required this.db,
    required this.repo,
    required this.mountManager,
    this.scanService,
    SyncApiClient? apiClient,
    this.isTvDevice = false,
    this.enableLanUdp = true,
    this.autoStartLanService = true,
    this.onMountsChanged,
  }) : syncStore = SyncLocalStore(db),
       apiClient = apiClient ?? SyncApiClient(),
       _ownsApiClient = apiClient == null {
    workspaceStore = LibraryWorkspaceStore(db);
    mapper = SyncMapper(
      db: db,
      repo: repo,
      syncStore: syncStore,
      mountManager: mountManager,
      onPreemptMountScan: (mountId) async => await scanService?.cancelAndAwaitMount(mountId),
    );
    lanService = LanPeerSyncService(syncStore: syncStore, enableUdpBroadcast: enableLanUdp)
      ..addListener(_onLanServiceChanged);
  }

  final AppDatabase db;
  final LibraryRepository repo;
  final MountManager mountManager;
  final LibraryScanService? scanService;
  final SyncLocalStore syncStore;
  final SyncApiClient apiClient;
  final bool _ownsApiClient;
  final bool isTvDevice;
  final bool enableLanUdp;
  final bool autoStartLanService;
  Future<void> Function()? onMountsChanged;
  late final LibraryWorkspaceStore workspaceStore;
  late final SyncMapper mapper;
  late final LanPeerSyncService lanService;

  SyncSessionCredentials? _session;
  String? _deviceId;
  bool _onboardingCompleted = false;
  bool _initialSyncCompleted = false;
  bool _restoringMounts = false;
  bool _initialized = false;
  Future<void>? _initializeFuture;
  bool _isSyncing = false;
  bool _pendingFollowUpPush = false;
  bool _disposed = false;
  SyncProgress _progress = SyncProgress.idle;
  int _pendingOutboxCount = 0;
  DateTime? _lastSyncedAt;
  DateTime? _lastResumePullAt;
  String? _lastError;

  static const Duration liveRefreshInterval = Duration(milliseconds: 1200);
  static const Duration resumePullCooldown = Duration(seconds: 3);
  static const String _kExportedUserKey = 'exported_baseline_user_id';

  bool get isSignedIn => _session != null;
  SyncMode get syncMode => _session != null ? SyncMode.cloudServer : SyncMode.localOnly;
  bool get onboardingCompleted => _onboardingCompleted;
  bool get initialSyncCompleted => _initialSyncCompleted;
  bool get isRestoringMounts => _restoringMounts;
  SyncSessionCredentials? get session => _session;
  SyncProgress get progress => _progress;
  bool get isSyncing => _isSyncing || _progress.isActive;
  int get pendingOutboxCount => _pendingOutboxCount;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get lastError => _lastError;
  String get deviceId => _deviceId ?? '';

  void _setProgress(SyncProgress next) {
    if (_disposed || _progress == next) return;
    _progress = next;
    notifyListeners();
  }

  void _onLanServiceChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() {
    if (_initialized || _disposed) return Future.value();
    return _initializeFuture ??= _doInitialize().whenComplete(() {
      _initializeFuture = null;
    });
  }

  Future<void> _doInitialize() async {
    if (_initialized || _disposed) return;
    _deviceId = await syncStore.getOrCreateDeviceId();
    _session = await syncStore.loadSession();
    _onboardingCompleted = await syncStore.isOnboardingCompleted();
    _initialSyncCompleted = await syncStore.isInitialSyncCompleted();
    _pendingOutboxCount = (await syncStore.readPendingOutbox(limit: 1000)).length;
    if (_disposed) return;
    _initialized = true;

    final gc = await syncStore.journal.pruneExpiredTombstones(nowMs: clock.now().millisecondsSinceEpoch);
    if (gc.maxPurgedSeq > 0) {
      final oldMin = await syncStore.getMinRetainedSeq();
      if (gc.maxPurgedSeq > oldMin) {
        await syncStore.saveMinRetainedSeq(gc.maxPurgedSeq);
      }
    }
    try {
      final freeRow = await db.customSelect('PRAGMA freelist_count').getSingleOrNull();
      final freelistCount = freeRow?.data.values.whereType<int>().firstOrNull ?? 0;
      if (gc.deletedCount > 0 || freelistCount >= 500) {
        await db.customStatement('VACUUM');
      }
    } catch (_) {}
    final healed = await mapper.healCatalogFromJournal();
    if (healed > 0) {
      scanService?.notifyLibraryChanged();
    }

    if (_session != null) {
      await syncStore.setSyncMode(SyncMode.cloudServer);
      await syncStore.setActiveWorkspaceKey(
        LibraryWorkspaceStore.accountWorkspaceKey(_session!.serverUrl, _session!.userId),
      );
      if (autoStartLanService && !lanService.isRunning) {
        await lanService.start(runTombstoneGc: false);
      }
    } else if (_onboardingCompleted) {
      await syncStore.setSyncMode(SyncMode.localOnly);
      if (autoStartLanService && !lanService.isRunning) {
        await lanService.start(runTombstoneGc: false);
      }
    }

    if (!_disposed) notifyListeners();
  }

  Future<void> selectLocalMode({bool startService = true}) async {
    await initialize();
    await syncStore.setOnboardingCompleted(true);
    await syncStore.setSyncMode(SyncMode.localOnly);
    _onboardingCompleted = true;
    if (startService && autoStartLanService && !lanService.isRunning) {
      await lanService.start();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> selectLanMode({bool startService = true}) => selectLocalMode(startService: startService);

  Future<void> refreshOutboxCount() async {
    _pendingOutboxCount = (await syncStore.readPendingOutbox(limit: 1000)).length;
    if (!_disposed) notifyListeners();
  }

  Future<PendingSyncSignIn> prepareRegister({
    required String serverUrl,
    required String username,
    required String password,
    SyncKdfParams kdfParams = const SyncKdfParams(),
    SyncServerKind? serverKind,
    Map<String, Object?>? settings,
    bool includeLocalScraperSettings = false,
  }) async {
    await initialize();
    final masterKey = SyncCrypto.generateMasterKey();
    final salt = SyncCrypto.randomBytes(16);
    final derived = await SyncCrypto.derivePasswordKeys(password: password, salt: salt, params: kdfParams);
    final backupEnvelope = await SyncCrypto.sealMasterKeyBackup(masterKey, derived.kek);

    final effectiveSettings =
        settings ??
        (includeLocalScraperSettings
            ? await mapper.buildCloudUserSettingsPayload(masterKey)
            : const <String, Object?>{});

    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final resp = await apiClient.register(
      serverUrl: normalizedUrl,
      username: username.trim(),
      authVerifier: derived.authVerifier,
      kdfSalt: base64Encode(salt),
      kdfParams: kdfParams,
      encryptedMasterKeyBackup: backupEnvelope,
      deviceId: _deviceId!,
      settings: effectiveSettings,
    );

    final creds = SyncSessionCredentials(
      serverUrl: normalizedUrl,
      userId: resp.userId,
      username: resp.username,
      accessToken: resp.accessToken,
      masterKey: masterKey,
      serverKind: serverKind,
    );
    return PendingSyncSignIn(
      credentials: creds,
      serverTimeMs: resp.serverTimeMs,
      remoteSettings: resp.settings,
      isNewAccount: true,
    );
  }

  Future<void> register({
    required String serverUrl,
    required String username,
    required String password,
    SyncKdfParams kdfParams = const SyncKdfParams(),
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    SyncServerKind? serverKind,
  }) async {
    final pending = await prepareRegister(
      serverUrl: serverUrl,
      username: username,
      password: password,
      kdfParams: kdfParams,
      serverKind: serverKind,
      includeLocalScraperSettings: mergePolicy == LocalMergePolicy.mergeLocal,
    );
    await commitPendingSignIn(pending, mergePolicy: mergePolicy);
  }

  Future<PendingSyncSignIn> prepareLoginWithPassword({
    required String serverUrl,
    required String username,
    required String password,
    SyncServerKind? serverKind,
  }) async {
    await initialize();
    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final kdf = await apiClient.lookupKdf(normalizedUrl, username.trim());
    final derived = await SyncCrypto.derivePasswordKeys(
      password: password,
      salt: base64Decode(kdf.kdfSalt),
      params: kdf.kdfParams,
    );
    final resp = await apiClient.login(
      serverUrl: normalizedUrl,
      username: username.trim(),
      authVerifier: derived.authVerifier,
      deviceId: _deviceId!,
    );
    final masterKey = await SyncCrypto.unsealMasterKeyBackup(resp.encryptedMasterKeyBackup, derived.kek);
    final creds = SyncSessionCredentials(
      serverUrl: normalizedUrl,
      userId: resp.userId,
      username: resp.username,
      accessToken: resp.accessToken,
      masterKey: masterKey,
      serverKind: serverKind,
    );
    return PendingSyncSignIn(credentials: creds, serverTimeMs: resp.serverTimeMs, remoteSettings: resp.settings);
  }

  Future<void> loginWithPassword({
    required String serverUrl,
    required String username,
    required String password,
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    SyncServerKind? serverKind,
  }) async {
    final pending = await prepareLoginWithPassword(
      serverUrl: serverUrl,
      username: username,
      password: password,
      serverKind: serverKind,
    );
    await commitPendingSignIn(pending, mergePolicy: mergePolicy);
  }

  Future<({String sessionId, String qrUri, SyncQrKeyPair keyPair, int expiresAtMs})> startQrSession({
    required String serverUrl,
    String? deviceName,
    SyncServerKind? serverKind,
  }) async {
    await initialize();
    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final effectiveKind =
        serverKind ??
        (normalizedUrl.toLowerCase() == SyncLocalStore.effectiveDefaultOfficialSyncUrl.toLowerCase()
            ? SyncServerKind.official
            : SyncServerKind.selfHosted);
    final resolvedDeviceName = (deviceName != null && deviceName.trim().isNotEmpty)
        ? deviceName.trim()
        : await syncStore.getDeviceName();
    final keyPair = await SyncQrKeyPairFuture.generate();
    final created = await apiClient.createQrSession(
      normalizedUrl,
      tvPubKey: keyPair.publicKeyBase64,
      deviceName: resolvedDeviceName,
    );
    final uri = Uri(
      scheme: 'ttplay',
      host: 'qr-auth',
      queryParameters: {
        'mode': 'server',
        'kind': effectiveKind.name,
        'server': normalizedUrl,
        'session_id': created.sessionId,
        'pub_key': keyPair.publicKeyBase64,
      },
    ).toString();
    return (sessionId: created.sessionId, qrUri: uri, keyPair: keyPair, expiresAtMs: created.expiresAtMs);
  }

  Future<PendingSyncSignIn?> pollQrSessionPending({
    required String serverUrl,
    required String sessionId,
    required SyncQrKeyPair keyPair,
    SyncServerKind? serverKind,
  }) async {
    await initialize();
    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final poll = await apiClient.pollQrSession(normalizedUrl, sessionId);
    if (poll.status == 'expired') {
      throw const SyncApiException(410, 'QR session expired');
    }
    if (poll.status != 'confirmed' || poll.accessToken == null || poll.sealedMasterKey == null || poll.userId == null) {
      return null;
    }

    final masterKey = await SyncCrypto.unsealMasterKeyOnTv(
      sealedEnvelope: poll.sealedMasterKey!,
      tvKeyPair: keyPair.keyPair,
    );
    final creds = SyncSessionCredentials(
      serverUrl: normalizedUrl,
      userId: poll.userId!,
      username: poll.username ?? '',
      accessToken: poll.accessToken!,
      masterKey: masterKey,
      serverKind: serverKind,
    );
    return PendingSyncSignIn(credentials: creds, serverTimeMs: poll.serverTimeMs, remoteSettings: poll.settings);
  }

  Future<bool> pollQrSession({
    required String serverUrl,
    required String sessionId,
    required SyncQrKeyPair keyPair,
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    SyncServerKind? serverKind,
  }) async {
    final pending = await pollQrSessionPending(
      serverUrl: serverUrl,
      sessionId: sessionId,
      keyPair: keyPair,
      serverKind: serverKind,
    );
    if (pending == null) return false;
    await commitPendingSignIn(pending, mergePolicy: mergePolicy);
    return true;
  }

  /// Inspects differences between local syncable data and the authenticated
  /// cloud account in read-only mode before committing a workspace switch.
  Future<SyncSignInDiffPreview> inspectPendingSignIn(
    PendingSyncSignIn pending, {
    int maxPreviewPages = 4,
    int pageLimit = 5000,
  }) async {
    await initialize();
    final creds = pending.credentials;
    final toKey = LibraryWorkspaceStore.accountWorkspaceKey(creds.serverUrl, creds.userId);
    final hasArchive = await workspaceStore.hasWorkspaceArchive(toKey);
    final hasLocal = await workspaceStore.hasLocalSyncableContent();
    final localSnapshot = hasLocal ? await mapper.collectLocalPreviewSnapshot() : const LocalSyncPreviewSnapshot();
    final localStats = localSnapshot.stats;

    SyncLibraryStats? fetchedCloudStats;
    if (pending.isNewAccount) {
      fetchedCloudStats = const SyncLibraryStats();
    } else {
      try {
        fetchedCloudStats = await apiClient.getUserStats(creds.serverUrl, creds.accessToken);
      } on SyncApiException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) rethrow;
      } catch (_) {}
    }

    if (hasArchive) {
      return SyncSignInDiffPreview(
        username: creds.username,
        serverUrl: creds.serverUrl,
        serverKind: creds.serverKind,
        reason: SyncSignInDecisionReason.existingAccountArchive,
        recommendedPolicy: LocalMergePolicy.accountOnly,
        localStats: localStats,
        cloudStats: fetchedCloudStats ?? const SyncLibraryStats(),
      );
    }

    if (localStats.isEmpty) {
      return SyncSignInDiffPreview(
        username: creds.username,
        serverUrl: creds.serverUrl,
        serverKind: creds.serverKind,
        reason: SyncSignInDecisionReason.localEmpty,
        recommendedPolicy: LocalMergePolicy.accountOnly,
        localStats: localStats,
        cloudStats: fetchedCloudStats ?? const SyncLibraryStats(),
      );
    }

    if (fetchedCloudStats != null && fetchedCloudStats.isEmpty) {
      return SyncSignInDiffPreview(
        username: creds.username,
        serverUrl: creds.serverUrl,
        serverKind: creds.serverKind,
        reason: SyncSignInDecisionReason.cloudEmpty,
        recommendedPolicy: LocalMergePolicy.mergeLocal,
        localStats: localStats,
        cloudStats: fetchedCloudStats,
        localOnlySourceNames: localSnapshot.sourcesByCanonicalKey.values.toList()..sort(),
        localOnlyWorks: localSnapshot.workKeys.length,
        localOnlyLists: localSnapshot.listsByKey.length,
        localOnlyProgress: localSnapshot.progressByKey.length,
        localOnlyOrConflictingWorkPrefs: localSnapshot.workPrefsByKey.length,
      );
    }

    final cloudSources = <String, String>{};
    final cloudSourceKeyById = <String, String>{};
    final cloudWorkKeys = <String>{};
    final cloudFileIds = <String>{};
    final cloudLists = <String, SyncListPreview>{};
    final cloudProgress = <String, SyncProgressPreview>{};
    final cloudWorkPrefs = <String, SyncWorkPrefPreview>{};

    var seq = 0;
    var hasMore = true;
    var pages = 0;
    while (hasMore && pages < maxPreviewPages && !_disposed) {
      final resp = await apiClient.pullDelta(
        creds.serverUrl,
        creds.accessToken,
        sinceSeq: seq,
        limit: pageLimit,
        activeOnly: true,
      );
      if (resp.resetRequired) break;

      for (final src in resp.sources) {
        final sourceId = (src['source_id'] as String?)?.trim() ?? '';
        if (sourceId.isEmpty) continue;
        if (src['is_deleted'] == true) {
          final prevKey = cloudSourceKeyById.remove(sourceId);
          if (prevKey != null) cloudSources.remove(prevKey);
          continue;
        }
        final normCanon = DeterministicKeys.normalizeCanonicalSourceKey((src['canonical_key'] as String?) ?? '');
        final key = normCanon.isNotEmpty ? normCanon : sourceId;
        final rawName = (src['name'] as String?)?.trim() ?? '';
        final proto = (src['protocol'] as String?)?.trim() ?? '';
        final displayName = rawName.isNotEmpty ? rawName : (proto.isNotEmpty ? proto : sourceId);
        cloudSourceKeyById[sourceId] = key;
        cloudSources[key] = displayName;
      }

      for (final w in resp.works) {
        final wk = DeterministicKeys.canonicalizeWorkKey(w['work_key'] as String?);
        if (wk.isEmpty || wk.startsWith('raw:')) continue;
        if (w['is_deleted'] == true) {
          cloudWorkKeys.remove(wk);
        } else {
          cloudWorkKeys.add(wk);
        }
      }

      for (final f in resp.files) {
        final fid = (f['file_id'] as String?)?.trim() ?? '';
        if (fid.isEmpty) continue;
        if (f['is_deleted'] == true) {
          cloudFileIds.remove(fid);
        } else {
          cloudFileIds.add(fid);
        }
      }

      for (final l in resp.lists) {
        final listKey = (l['list_key'] as String?)?.trim() ?? '';
        if (listKey.isEmpty) continue;
        if (l['is_deleted'] == true) {
          cloudLists.remove(listKey);
          continue;
        }
        final title = (l['title'] as String?)?.trim() ?? '';
        final rawKeys = l['item_work_keys'] as List<dynamic>? ?? const [];
        final items = <String>[
          for (final raw in rawKeys)
            if (DeterministicKeys.canonicalizeWorkKey('$raw').isNotEmpty &&
                !DeterministicKeys.canonicalizeWorkKey('$raw').startsWith('raw:'))
              DeterministicKeys.canonicalizeWorkKey('$raw'),
        ];
        cloudLists[listKey] = (title: title, itemWorkKeys: items);
      }

      for (final g in resp.watchProgress) {
        final wk = DeterministicKeys.canonicalizeWorkKey(g['work_key'] as String?);
        if (wk.isEmpty || wk.startsWith('raw:')) continue;
        final parts = wk.split(':');
        if (parts.length < 3) continue;
        final kind = parts[1];
        final seasonNum = (g['season_num'] as num?)?.toInt() ?? -1;
        final episodeNum = (g['episode_num'] as num?)?.toInt() ?? -1;
        final rawPk = (g['progress_key'] as String?)?.trim() ?? '';
        final pk = rawPk.isNotEmpty
            ? rawPk
            : DeterministicKeys.generateProgressKey(
                workKey: wk,
                kind: kind,
                seasonNum: seasonNum,
                episodeNum: episodeNum,
              );
        cloudProgress[pk] = (watched: g['watched'] == true, positionMs: (g['position_ms'] as num?)?.toInt() ?? 0);
      }

      for (final p in resp.workPrefs) {
        final wk = DeterministicKeys.canonicalizeWorkKey(p['work_key'] as String?);
        if (wk.isEmpty || wk.startsWith('raw:')) continue;
        cloudWorkPrefs[wk] = (
          favorite: p['is_favorite'] == true,
          hidden: p['hidden_from_continue'] == true,
          introEnabled: p['intro_enabled'] == true,
          introStartMs: (p['intro_start_ms'] as num?)?.toInt() ?? 0,
          introEndMs: (p['intro_end_ms'] as num?)?.toInt() ?? 0,
          creditsEnabled: p['credits_enabled'] == true,
          creditsFromEndMs: (p['credits_from_end_ms'] as num?)?.toInt() ?? 0,
          keepEasterEggMs: (p['keep_easter_egg_ms'] as num?)?.toInt() ?? 0,
        );
      }

      pages++;
      hasMore = resp.hasMore;
      if (hasMore && resp.nextSeq <= seq) break;
      seq = resp.nextSeq;
    }

    final diffTruncated = hasMore;
    final derivedCloudStats = SyncLibraryStats(
      sources: cloudSources.length,
      works: cloudWorkKeys.length,
      files: cloudFileIds.length,
      lists: cloudLists.length,
      watchProgress: cloudProgress.length,
      workPrefs: cloudWorkPrefs.length,
    );
    final effectiveCloudStats = fetchedCloudStats ?? derivedCloudStats;

    if (effectiveCloudStats.isEmpty && !diffTruncated) {
      return SyncSignInDiffPreview(
        username: creds.username,
        serverUrl: creds.serverUrl,
        serverKind: creds.serverKind,
        reason: SyncSignInDecisionReason.cloudEmpty,
        recommendedPolicy: LocalMergePolicy.mergeLocal,
        localStats: localStats,
        cloudStats: effectiveCloudStats,
        localOnlySourceNames: localSnapshot.sourcesByCanonicalKey.values.toList()..sort(),
        localOnlyWorks: localSnapshot.workKeys.length,
        localOnlyLists: localSnapshot.listsByKey.length,
        localOnlyProgress: localSnapshot.progressByKey.length,
        localOnlyOrConflictingWorkPrefs: localSnapshot.workPrefsByKey.length,
      );
    }

    final localOnlySourceNames = <String>[
      for (final entry in localSnapshot.sourcesByCanonicalKey.entries)
        if (!cloudSources.containsKey(entry.key)) entry.value,
    ]..sort();
    final cloudOnlySourceNames = <String>[
      for (final entry in cloudSources.entries)
        if (!localSnapshot.sourcesByCanonicalKey.containsKey(entry.key)) entry.value,
    ]..sort();
    final sharedSourceNames = <String>[
      for (final entry in localSnapshot.sourcesByCanonicalKey.entries)
        if (cloudSources.containsKey(entry.key)) entry.value,
    ]..sort();

    final localOnlyWorks = localSnapshot.workKeys.where((k) => !cloudWorkKeys.contains(k)).length;
    final cloudOnlyWorks = cloudWorkKeys.where((k) => !localSnapshot.workKeys.contains(k)).length;

    var localOnlyLists = 0;
    var conflictingLists = 0;
    for (final entry in localSnapshot.listsByKey.entries) {
      final remote = cloudLists[entry.key];
      if (remote == null) {
        localOnlyLists++;
      } else if (entry.value.title != remote.title || !listEquals(entry.value.itemWorkKeys, remote.itemWorkKeys)) {
        conflictingLists++;
      }
    }
    final cloudOnlyLists = cloudLists.keys.where((k) => !localSnapshot.listsByKey.containsKey(k)).length;

    var localOnlyProgress = 0;
    var conflictingProgress = 0;
    for (final entry in localSnapshot.progressByKey.entries) {
      final remote = cloudProgress[entry.key];
      if (remote == null) {
        localOnlyProgress++;
      } else if (entry.value.watched != remote.watched || (entry.value.positionMs - remote.positionMs).abs() >= 5000) {
        conflictingProgress++;
      }
    }
    final cloudOnlyProgress = cloudProgress.keys.where((k) => !localSnapshot.progressByKey.containsKey(k)).length;

    var localOnlyOrConflictingWorkPrefs = 0;
    for (final entry in localSnapshot.workPrefsByKey.entries) {
      final remote = cloudWorkPrefs[entry.key];
      if (remote == null || remote != entry.value) {
        localOnlyOrConflictingWorkPrefs++;
      }
    }

    final hasLocalChanges =
        diffTruncated ||
        localOnlySourceNames.isNotEmpty ||
        localOnlyWorks > 0 ||
        localOnlyLists > 0 ||
        conflictingLists > 0 ||
        localOnlyProgress > 0 ||
        conflictingProgress > 0 ||
        localOnlyOrConflictingWorkPrefs > 0;

    return SyncSignInDiffPreview(
      username: creds.username,
      serverUrl: creds.serverUrl,
      serverKind: creds.serverKind,
      reason: hasLocalChanges
          ? SyncSignInDecisionReason.requiresMergeChoice
          : SyncSignInDecisionReason.noLocalDifferences,
      recommendedPolicy: hasLocalChanges ? LocalMergePolicy.mergeLocal : LocalMergePolicy.accountOnly,
      localStats: localStats,
      cloudStats: effectiveCloudStats,
      localOnlySourceNames: localOnlySourceNames,
      cloudOnlySourceNames: cloudOnlySourceNames,
      sharedSourceNames: sharedSourceNames,
      localOnlyWorks: localOnlyWorks,
      cloudOnlyWorks: cloudOnlyWorks,
      localOnlyLists: localOnlyLists,
      cloudOnlyLists: cloudOnlyLists,
      conflictingLists: conflictingLists,
      localOnlyProgress: localOnlyProgress,
      cloudOnlyProgress: cloudOnlyProgress,
      conflictingProgress: conflictingProgress,
      localOnlyOrConflictingWorkPrefs: localOnlyOrConflictingWorkPrefs,
      diffTruncated: diffTruncated,
    );
  }

  Future<void> commitPendingSignIn(
    PendingSyncSignIn pending, {
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
  }) => _finishSignIn(
    pending.credentials,
    serverTimeMs: pending.serverTimeMs,
    mergePolicy: mergePolicy,
    remoteSettings: pending.remoteSettings,
  );

  Future<void> cancelPendingSignIn(PendingSyncSignIn pending) async {
    try {
      await apiClient.revokeCurrentDeviceSession(pending.credentials.serverUrl, pending.credentials.accessToken);
    } catch (_) {}
  }

  Future<void> confirmQrUri(String rawInput) async {
    await initialize();
    final current = _session;
    if (current == null) {
      throw const SyncQrAuthException(SyncQrAuthErrorCode.notSignedIn);
    }

    final trimmed = rawInput.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'ttplay' && uri.scheme != 'plezy') || uri.host != 'qr-auth') {
      throw const SyncQrAuthException(SyncQrAuthErrorCode.invalidQrUri);
    }

    final sessionId = uri.queryParameters['session_id'] ?? '';
    final tvPubKey = uri.queryParameters['pub_key'] ?? '';
    final serverOverride = uri.queryParameters['server'];
    if (sessionId.isEmpty || tvPubKey.isEmpty) {
      throw const SyncQrAuthException(SyncQrAuthErrorCode.invalidQrUri);
    }
    if (serverOverride != null && serverOverride.trim().isNotEmpty) {
      final targetNorm = SyncLocalStore.normalizeServerUrl(serverOverride).toLowerCase();
      final currentNorm = SyncLocalStore.normalizeServerUrl(current.serverUrl).toLowerCase();
      if (targetNorm != currentNorm) {
        throw SyncQrAuthException(
          SyncQrAuthErrorCode.serverMismatch,
          currentServer: current.serverUrl,
          targetServer: serverOverride.trim(),
        );
      }
    }

    final sealed = await SyncCrypto.sealMasterKeyForTv(masterKey: current.masterKey, tvPubKeyBase64: tvPubKey);
    try {
      await apiClient.confirmQrSession(
        current.serverUrl,
        current.accessToken,
        sessionId: sessionId,
        sealedMasterKey: sealed,
        deviceId: _deviceId!,
      );
    } on SyncApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 410) {
        throw const SyncQrAuthException(SyncQrAuthErrorCode.expired);
      }
      rethrow;
    }
  }

  Future<void> _clearCloudSessionState() async {
    await initialize();
    _session = null;
    _initialSyncCompleted = false;
    _restoringMounts = false;
    _pendingFollowUpPush = false;
    _lastError = null;
    _lastSyncedAt = null;
    await syncStore.clearSession();
    await (db.delete(db.syncMetadata)..where((t) => t.key.equals(_kExportedUserKey))).go();
  }

  Future<void> signOut() async {
    await initialize();
    final fromKey = await syncStore.getActiveWorkspaceKey();
    await workspaceStore.switchToWorkspace(fromKey: fromKey, toKey: LibraryWorkspaceStore.localWorkspaceKey);
    await _clearCloudSessionState();
    await syncStore.setSyncMode(SyncMode.localOnly);
    await syncStore.setOnboardingCompleted(true);
    _onboardingCompleted = true;
    await onMountsChanged?.call();
    scanService?.notifyLibraryChanged();
    if (autoStartLanService && !lanService.isRunning) {
      await lanService.start();
    }
    await refreshOutboxCount();
    if (!_disposed) notifyListeners();
  }

  /// Clears any active cloud session and switches back to the local workspace
  /// so the user returns to login/mode selection without losing archived data.
  Future<void> logoutToModeSelection() async {
    await initialize();
    final fromKey = await syncStore.getActiveWorkspaceKey();
    await workspaceStore.switchToWorkspace(fromKey: fromKey, toKey: LibraryWorkspaceStore.localWorkspaceKey);
    await _clearCloudSessionState();
    await syncStore.setSyncMode(SyncMode.localOnly);
    await syncStore.setOnboardingCompleted(false);
    _onboardingCompleted = false;
    await onMountsChanged?.call();
    scanService?.notifyLibraryChanged();
    await refreshOutboxCount();
    if (!_disposed) notifyListeners();
  }

  Future<void> _finishSignIn(
    SyncSessionCredentials creds, {
    required int serverTimeMs,
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    Map<String, Object?> remoteSettings = const {},
  }) async {
    final fromKey = await syncStore.getActiveWorkspaceKey();
    final toKey = LibraryWorkspaceStore.accountWorkspaceKey(creds.serverUrl, creds.userId);
    final hadTargetArchive = await workspaceStore.hasWorkspaceArchive(toKey);
    await workspaceStore.switchToWorkspace(fromKey: fromKey, toKey: toKey, firstBindPolicy: mergePolicy);

    await syncStore.saveSession(creds);
    await syncStore.setSyncMode(SyncMode.cloudServer);
    await syncStore.setOnboardingCompleted(true);
    _onboardingCompleted = true;
    _initialSyncCompleted = await syncStore.isInitialSyncCompleted();
    if (serverTimeMs > 0) {
      final offset = serverTimeMs - clock.now().millisecondsSinceEpoch;
      await syncStore.saveServerTimeOffsetMs(offset);
    }
    _session = creds;
    _lastError = null;
    if (remoteSettings.isNotEmpty) {
      await mapper.applyUserSettings(remoteSettings, masterKey: creds.masterKey);
    }
    if (mergePolicy == LocalMergePolicy.accountOnly || hadTargetArchive) {
      await db
          .into(db.syncMetadata)
          .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: _kExportedUserKey, value: creds.userId));
    }
    if (autoStartLanService && !lanService.isRunning) {
      await lanService.start(runTombstoneGc: false);
    }
    await onMountsChanged?.call();
    scanService?.notifyLibraryChanged();
    if (!_disposed) notifyListeners();
    await syncNow(allowBackgroundScan: false);
    if (mergePolicy == LocalMergePolicy.mergeLocal &&
        ((remoteSettings['encrypted_tmdb_api_key'] as String?)?.isEmpty ?? true)) {
      unawaited(syncScraperSettingsToCloud());
    }
  }

  Future<bool> shouldAllowAutomaticIncrementalScan() async {
    await initialize();
    if (_disposed || isTvDevice || _isSyncing) {
      return false;
    }
    if (_session != null) return false;
    return true;
  }

  Future<void> onMountSaved(StorageMount mount, {bool dropDriver = true}) async {
    await initialize();
    if (dropDriver) {
      await mountManager.dropCachedDriver(mount.id);
    }
    if (mount.configStringList(MountKeys.includePaths).isNotEmpty ||
        mount.configStringList(MountKeys.excludePaths).isNotEmpty) {
      final localFiles = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals(mount.id))).get();
      final affectedIds = <int>{};
      var pruned = 0;
      for (final f in localFiles) {
        if (!mount.isFileAllowed(f.path)) {
          if (f.itemId != null) affectedIds.add(f.itemId!);
          await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
          pruned++;
        }
      }
      if (pruned > 0) {
        await repo.pruneEmptyTitles();
        if (affectedIds.isNotEmpty) {
          await repo.refreshSourceAddedTimesForLeaves(affectedIds, recomputeFromFilesOnly: true);
        }
        scanService?.notifyLibraryChanged();
      }
    }
    if (mount.kind == StorageKind.local) return;
    if (mount.secrets.isNotEmpty) {
      await syncStore.setAuthUpdatedAt(mount.id, await syncStore.calibratedNowMs());
    }
    await mapper.reconcileCatalogToJournal(mountIds: {mount.id}, allowTombstones: true);
    final sess = _session;
    if (sess == null) {
      return;
    }
    await mapper.enqueuePendingJournalForCloud(masterKey: sess.masterKey);
    await mapper.enqueueMount(mount, masterKey: sess.masterKey, forceAuthOverride: true);
    await refreshOutboxCount();
    unawaited(pushOutboxOnly());
  }

  Future<void> onMountRemoved(String mountId) async {
    await initialize();
    await mountManager.dropCachedDriver(mountId);
    await (db.delete(db.libraryFiles)..where((t) => t.mountId.equals(mountId))).go();
    await repo.pruneEmptyTitles();
    scanService?.notifyLibraryChanged();
    await mapper.reconcileMountRemovalToJournal(mountId);
    await syncStore.deleteAuthUpdatedAt(mountId);
    final sess = _session;
    if (sess == null) {
      return;
    }
    await mapper.enqueuePendingJournalForCloud(masterKey: sess.masterKey);
    await mapper.enqueueMountDeletion(mountId);
    await refreshOutboxCount();
    unawaited(pushOutboxOnly());
  }

  Future<void> onCatalogChanged({
    Set<String>? mountIds,
    Set<String>? directoryPrefixes,
    bool allowTombstones = true,
  }) async {
    await initialize();
    final changed = await mapper.reconcileCatalogToJournal(
      mountIds: mountIds,
      directoryPrefixes: directoryPrefixes,
      allowTombstones: allowTombstones,
      includeWorkStates: false,
    );
    if (changed == 0) return;
    final sess = _session;
    if (sess == null) {
      return;
    }
    await mapper.enqueuePendingJournalForCloud(masterKey: sess.masterKey);
    await refreshOutboxCount();
    unawaited(pushOutboxOnly());
  }

  Future<void> onPlaybackOutboxQueued() async {
    await initialize();
    await refreshOutboxCount();
    if (_session == null) {
      return;
    }
    unawaited(pushOutboxOnly());
  }

  Future<void> pushOutboxOnly() async {
    await initialize();
    final sess = _session;
    if (sess == null || _disposed) return;
    if (_isSyncing) {
      _pendingFollowUpPush = true;
      return;
    }
    _isSyncing = true;
    if (!_disposed) notifyListeners();
    try {
      final remapped = await _pushPendingOutbox(sess);
      if (remapped) {
        await _pullAllDeltas(sess);
        await onMountsChanged?.call();
      }
      _lastSyncedAt = clock.now();
      _lastError = null;
    } catch (e) {
      appLogger.w('[SyncCoordinator] Background push failed (kept in outbox)', error: e);
    } finally {
      _isSyncing = false;
      _progress = SyncProgress.idle;
      await refreshOutboxCount();
      if (_pendingFollowUpPush && !_disposed && _session != null) {
        _pendingFollowUpPush = false;
        unawaited(pushOutboxOnly());
      }
    }
  }

  /// Five-step synchronization pipeline:
  /// 1) Pull & merge deltas (advancing local_seq only here)
  /// 2) Export offline local baseline on first sign-in if applicable
  /// 3) Push pending outbox & reconcile any server-side source deduplication remaps
  /// 4) Probe storage reachability
  /// 5) Optional leased incremental Quark scan (skipped on passive TV devices)
  Future<bool> syncNow({bool allowBackgroundScan = false}) async {
    await initialize();
    final sess = _session;
    if (sess == null || _isSyncing || _disposed) return false;

    _isSyncing = true;
    _lastError = null;
    if (!_initialSyncCompleted) {
      _restoringMounts = true;
    }
    _progress = const SyncProgress(phase: SyncPhase.pulling);
    if (!_disposed) notifyListeners();

    try {
      // [Stage 2] Pull-Before-Scan (_pullAllDeltas fires throttled + final live refreshes immediately).
      await _pullAllDeltas(sess);
      await mapper.healCatalogFromJournal();
      await onMountsChanged?.call();
      if (!_initialSyncCompleted) {
        _initialSyncCompleted = true;
        await syncStore.setInitialSyncCompleted(true);
      }
      _restoringMounts = false;

      // Export pre-login / unsynced local journal delta cleanly without re-pushing unchanged items.
      final exportedRow = await (db.select(
        db.syncMetadata,
      )..where((t) => t.key.equals(_kExportedUserKey))).getSingleOrNull();
      if (exportedRow?.value != sess.userId) {
        await mapper.reconcileCatalogToJournal(allowTombstones: true, includeWorkStates: true);
        await db
            .into(db.syncMetadata)
            .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: _kExportedUserKey, value: sess.userId));
      } else {
        await mapper.ensureJournalUpToDate();
      }
      await mapper.enqueuePendingJournalForCloud(masterKey: sess.masterKey);
      await refreshOutboxCount();

      // [Stage 5 / Push local mutations]
      final remapped = await _pushPendingOutbox(sess);
      if (remapped) {
        await _pullAllDeltas(sess);
        await onMountsChanged?.call();
      }

      // [Stage 3] Protocol-level mount reachability probe
      _setProgress(const SyncProgress(phase: SyncPhase.probingMounts));
      await mountManager.probeAll();

      // [Stage 4] Optional leased incremental scan on active manager devices
      if (allowBackgroundScan && !isTvDevice && scanService != null) {
        final mounts = await mountManager.registry.list();
        final leasedMounts = <StorageMount>[];
        for (final mount in mounts) {
          if (mount.kind == StorageKind.local || !mountManager.isMountOnline(mount.id)) continue;
          try {
            final lease = await apiClient.tryAcquireScanLease(
              sess.serverUrl,
              sess.accessToken,
              sourceId: mount.id,
              deviceId: _deviceId!,
            );
            if (lease.acquired) leasedMounts.add(mount);
          } catch (_) {
            // Skip lease failures gracefully in degraded network environments.
          }
        }
        if (leasedMounts.isNotEmpty) {
          await scanService!.checkIncrementalUpdates(
            canRun: () => !_disposed,
            allowedMountIds: {for (final m in leasedMounts) m.id},
          );
        }
      }

      _lastSyncedAt = clock.now();
      return true;
    } catch (e) {
      _lastError = '$e';
      appLogger.w('[SyncCoordinator] Sync failed, remaining offline-safe', error: e);
      return false;
    } finally {
      _isSyncing = false;
      _restoringMounts = false;
      _progress = SyncProgress.idle;
      await refreshOutboxCount();
      if (_pendingFollowUpPush && !_disposed && _session != null) {
        _pendingFollowUpPush = false;
        unawaited(pushOutboxOnly());
      }
    }
  }

  /// Pushes the device's non-proxy scraper configuration (with an AES-GCM
  /// encrypted TMDB API key) to the sync server.
  Future<void> syncScraperSettingsToCloud() async {
    await initialize();
    final sess = _session;
    if (sess == null || _disposed) return;
    try {
      final payload = await mapper.buildCloudUserSettingsPayload(sess.masterKey);
      await apiClient.updateUserSettings(sess.serverUrl, sess.accessToken, payload);
    } catch (e) {
      appLogger.w('[SyncCoordinator] Failed to push scraper settings to cloud', error: e);
    }
  }

  /// Pulls recent cloud deltas when the app returns to the foreground (e.g.
  /// resuming playback on another device after switching from mobile/TV).
  Future<void> onAppResumed() async {
    await initialize();
    if (_disposed || _session == null) return;
    final now = clock.now();
    if (_lastResumePullAt != null && now.difference(_lastResumePullAt!) < resumePullCooldown) {
      return;
    }
    _lastResumePullAt = now;
    await syncNow(allowBackgroundScan: false);
  }

  Future<bool> _pullAllDeltas(SyncSessionCredentials sess) async {
    var localSeq = await syncStore.getLastPullSeq();
    var activeOnly = localSeq == 0;
    var hasMore = true;
    var anyChanges = false;
    var resetAttempted = false;
    var isRebuild = false;
    var appliedAcrossPages = 0;
    final sessionWorkCache = <String, int>{};
    final survivingFileIdsByMount = <String, Set<String>>{};
    final authoritativeMountIds = <String>{};
    DateTime? lastLiveNotify;

    void maybeNotifyLive({bool force = false}) {
      if (_disposed || scanService == null) return;
      final now = clock.now();
      if (force || lastLiveNotify == null || now.difference(lastLiveNotify!) >= liveRefreshInterval) {
        lastLiveNotify = now;
        scanService!.notifyLibraryChanged();
      }
    }

    while (hasMore && !_disposed) {
      _setProgress(SyncProgress(phase: SyncPhase.pulling, processed: appliedAcrossPages));
      final resp = await apiClient.pullDelta(
        sess.serverUrl,
        sess.accessToken,
        sinceSeq: localSeq,
        limit: 500,
        activeOnly: activeOnly,
      );
      if (resp.serverTimeMs > 0) {
        final offset = resp.serverTimeMs - clock.now().millisecondsSinceEpoch;
        await syncStore.saveServerTimeOffsetMs(offset);
      }
      if (resp.resetRequired) {
        if (resetAttempted) break;
        resetAttempted = true;
        isRebuild = true;
        activeOnly = true;
        survivingFileIdsByMount.clear();
        authoritativeMountIds.clear();
        await syncStore.resetSyncCursorsForFullRebuild();
        localSeq = 0;
        appliedAcrossPages = 0;
        hasMore = true;
        continue;
      }

      if (isRebuild) {
        final remaps = await syncStore.loadRemappedSources();
        for (final src in resp.sources) {
          final srcId = src['source_id'] as String?;
          if (srcId != null && srcId.isNotEmpty && src['is_deleted'] != true) {
            authoritativeMountIds.add(SyncLocalStore.resolveRemappedSourceIdFromMap(remaps, srcId));
          }
        }
        for (final f in resp.files) {
          final rawSrcId = f['source_id'] as String?;
          final relPath = f['relative_path'] as String?;
          if (rawSrcId != null &&
              rawSrcId.isNotEmpty &&
              relPath != null &&
              relPath.isNotEmpty &&
              f['is_deleted'] != true) {
            final srcId = SyncLocalStore.resolveRemappedSourceIdFromMap(remaps, rawSrcId);
            authoritativeMountIds.add(srcId);
            survivingFileIdsByMount
                .putIfAbsent(srcId, () => <String>{})
                .add(DeterministicKeys.generateFileId(sourceId: srcId, mountRelativePath: relPath));
          }
        }
      }

      final pageTotal =
          resp.sources.length +
          resp.works.length +
          resp.files.length +
          resp.workPrefs.length +
          resp.watchProgress.length +
          resp.lists.length;

      final touched = await mapper.applyPullBatch(
        masterKey: sess.masterKey,
        sources: resp.sources,
        works: resp.works,
        files: resp.files,
        workPrefs: resp.workPrefs,
        watchProgress: resp.watchProgress,
        lists: resp.lists,
        userSettings: resp.userSettings,
        nextSeq: resp.nextSeq,
        isFinalPage: !resp.hasMore,
        originDeviceId: 'cloud',
        originEpoch: sess.userId,
        sharedWorkItemCache: sessionWorkCache,
        onProgress: pageTotal == 0
            ? null
            : (done, total) => _setProgress(
                SyncProgress(
                  phase: SyncPhase.applying,
                  processed: appliedAcrossPages + done,
                  total: resp.hasMore ? 0 : appliedAcrossPages + total,
                ),
              ),
        onChunkApplied: () {
          anyChanges = true;
          maybeNotifyLive();
        },
      );
      if (resp.sources.isNotEmpty) {
        await onMountsChanged?.call();
      }
      if (touched > 0) anyChanges = true;
      appliedAcrossPages += pageTotal;
      localSeq = resp.nextSeq;
      hasMore = resp.hasMore;
    }

    if (isRebuild && authoritativeMountIds.isNotEmpty) {
      final pruned = await mapper.pruneStaleFilesAfterRebuild(
        survivingFileIdsByMount: survivingFileIdsByMount,
        authoritativeMountIds: authoritativeMountIds,
        remoteOriginId: 'cloud',
      );
      if (pruned > 0) anyChanges = true;
    }

    if (anyChanges) {
      maybeNotifyLive(force: true);
    }
    return anyChanges;
  }

  Future<bool> _pushPendingOutbox(SyncSessionCredentials sess) async {
    var remappedAny = false;
    final initialTotal = (await syncStore.readPendingOutbox(limit: 10000)).length;
    if (initialTotal == 0) return false;
    var pushedSoFar = 0;
    _setProgress(SyncProgress(phase: SyncPhase.pushing, processed: 0, total: initialTotal));

    while (!_disposed) {
      final batch = await syncStore.readPendingOutbox(limit: 200);
      if (batch.isEmpty) break;
      final resp = await apiClient.pushMutations(
        sess.serverUrl,
        sess.accessToken,
        deviceId: _deviceId!,
        mutations: batch,
      );
      if (resp.serverTimeMs > 0) {
        await syncStore.saveServerTimeOffsetMs(resp.serverTimeMs - clock.now().millisecondsSinceEpoch);
      }
      for (final entry in resp.remappedSources.entries) {
        await mapper.rehomeLocalMountId(oldMountId: entry.key, newMountId: entry.value);
        remappedAny = true;
      }
      if (resp.acceptedOpIds.isNotEmpty) {
        await syncStore.deleteAcceptedOutbox(resp.acceptedOpIds);
        pushedSoFar = math.min(initialTotal, pushedSoFar + resp.acceptedOpIds.length);
        _setProgress(SyncProgress(phase: SyncPhase.pushing, processed: pushedSoFar, total: initialTotal));
      } else {
        break;
      }
    }
    return remappedAny;
  }

  @visibleForTesting
  void debugSetSessionForTesting(
    SyncSessionCredentials? session, {
    int pendingOutboxCount = 0,
    SyncProgress? progress,
    String? lastError,
    bool clearError = false,
  }) {
    _session = session;
    _pendingOutboxCount = pendingOutboxCount;
    if (progress != null) _progress = progress;
    if (clearError) {
      _lastError = null;
    } else if (lastError != null) {
      _lastError = lastError;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    lanService.removeListener(_onLanServiceChanged);
    lanService.dispose();
    if (_ownsApiClient) apiClient.close();
    super.dispose();
  }
}

abstract final class SyncQrKeyPairFuture {
  static Future<SyncQrKeyPair> generate() => SyncCrypto.generateQrKeyPair();
}
