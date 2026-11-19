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

export 'sync_local_store.dart' show SyncMode, SyncServerKind, defaultOfficialSyncUrl, normalizeSyncServerUrl;

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

  Future<bool> hasLocalDataToMerge() async {
    await initialize();
    if (_session != null) return false;
    return workspaceStore.hasLocalSyncableContent();
  }

  Future<void> refreshOutboxCount() async {
    _pendingOutboxCount = (await syncStore.readPendingOutbox(limit: 1000)).length;
    if (!_disposed) notifyListeners();
  }

  Future<void> register({
    required String serverUrl,
    required String username,
    required String password,
    SyncKdfParams kdfParams = const SyncKdfParams(),
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    SyncServerKind? serverKind,
  }) async {
    await initialize();
    final masterKey = SyncCrypto.generateMasterKey();
    final salt = SyncCrypto.randomBytes(16);
    final derived = await SyncCrypto.derivePasswordKeys(password: password, salt: salt, params: kdfParams);
    final backupEnvelope = await SyncCrypto.sealMasterKeyBackup(masterKey, derived.kek);

    final settingsMap = mergePolicy == LocalMergePolicy.mergeLocal
        ? await mapper.buildCloudUserSettingsPayload(masterKey)
        : const <String, Object?>{};

    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final resp = await apiClient.register(
      serverUrl: normalizedUrl,
      username: username.trim(),
      authVerifier: derived.authVerifier,
      kdfSalt: base64Encode(salt),
      kdfParams: kdfParams,
      encryptedMasterKeyBackup: backupEnvelope,
      deviceId: _deviceId!,
      settings: settingsMap,
    );

    final creds = SyncSessionCredentials(
      serverUrl: normalizedUrl,
      userId: resp.userId,
      username: resp.username,
      accessToken: resp.accessToken,
      masterKey: masterKey,
      serverKind: serverKind,
    );
    await _finishSignIn(
      creds,
      serverTimeMs: resp.serverTimeMs,
      mergePolicy: mergePolicy,
      remoteSettings: resp.settings,
    );
  }

  Future<void> loginWithPassword({
    required String serverUrl,
    required String username,
    required String password,
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
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
    await _finishSignIn(
      creds,
      serverTimeMs: resp.serverTimeMs,
      mergePolicy: mergePolicy,
      remoteSettings: resp.settings,
    );
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

  Future<bool> pollQrSession({
    required String serverUrl,
    required String sessionId,
    required SyncQrKeyPair keyPair,
    LocalMergePolicy mergePolicy = LocalMergePolicy.mergeLocal,
    SyncServerKind? serverKind,
  }) async {
    await initialize();
    final normalizedUrl = SyncLocalStore.normalizeServerUrl(serverUrl);
    final poll = await apiClient.pollQrSession(normalizedUrl, sessionId);
    if (poll.status == 'expired') {
      throw const SyncApiException(410, 'QR session expired');
    }
    if (poll.status != 'confirmed' || poll.accessToken == null || poll.sealedMasterKey == null || poll.userId == null) {
      return false;
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
    await _finishSignIn(
      creds,
      serverTimeMs: poll.serverTimeMs,
      mergePolicy: mergePolicy,
      remoteSettings: poll.settings,
    );
    return true;
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
      final resp = await apiClient.pullDelta(sess.serverUrl, sess.accessToken, sinceSeq: localSeq, limit: 500);
      if (resp.serverTimeMs > 0) {
        final offset = resp.serverTimeMs - clock.now().millisecondsSinceEpoch;
        await syncStore.saveServerTimeOffsetMs(offset);
      }
      if (resp.resetRequired) {
        if (resetAttempted) break;
        resetAttempted = true;
        isRebuild = true;
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
