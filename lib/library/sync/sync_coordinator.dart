import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../utils/app_logger.dart';
import '../library_repository.dart';
import '../library_scan_service.dart';
import '../library_settings.dart';
import 'deterministic_keys.dart';
import 'lan_peer_sync_service.dart';
import 'sync_api_client.dart';
import 'sync_crypto.dart';
import 'sync_local_store.dart';
import 'sync_mapper.dart';
import 'sync_models.dart';

/// Coordinates end-to-end encrypted multi-device synchronization in mutually
/// exclusive modes: either serverless LAN P2P sync ([SyncMode.lanP2p]) or the
/// remote Go sync server ([SyncMode.cloudServer]).
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
  }) : syncStore = SyncLocalStore(db),
       apiClient = apiClient ?? SyncApiClient(),
       _ownsApiClient = apiClient == null {
    mapper = SyncMapper(
      db: db,
      repo: repo,
      syncStore: syncStore,
      mountManager: mountManager,
      onPreemptMountScan: (mountId) async => await scanService?.cancelAndAwaitMount(mountId),
    );
    lanService = LanPeerSyncService(
      syncStore: syncStore,
      mapper: mapper,
      onLibraryChanged: () => scanService?.notifyLibraryChanged(),
      enableUdpBroadcast: enableLanUdp,
    )..addListener(_onLanServiceChanged);
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
  late final SyncMapper mapper;
  late final LanPeerSyncService lanService;

  SyncSessionCredentials? _session;
  String? _deviceId;
  bool _onboardingCompleted = false;
  bool _initialized = false;
  Future<void>? _initializeFuture;
  bool _isSyncing = false;
  bool _disposed = false;
  SyncProgress _progress = SyncProgress.idle;
  int _pendingOutboxCount = 0;
  DateTime? _lastSyncedAt;
  String? _lastError;

  static const Duration liveRefreshInterval = Duration(milliseconds: 1200);
  static const String _kExportedUserKey = 'exported_baseline_user_id';

  bool get isSignedIn => _session != null;
  SyncMode get syncMode => _session != null ? SyncMode.cloudServer : SyncMode.lanP2p;
  bool get onboardingCompleted => _onboardingCompleted;
  SyncSessionCredentials? get session => _session;
  SyncProgress get progress => _progress.isActive ? _progress : lanService.progress;
  bool get isSyncing => _isSyncing || _progress.isActive || lanService.isSyncing;
  int get pendingOutboxCount => _pendingOutboxCount;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get lastError => _lastError ?? lanService.lastError;
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
      await lanService.stop();
    } else if (_onboardingCompleted && autoStartLanService) {
      await syncStore.setSyncMode(SyncMode.lanP2p);
      await lanService.start(runTombstoneGc: false);
    }

    if (!_disposed) notifyListeners();
  }

  Future<void> selectLanMode({bool startService = true}) async {
    await initialize();
    await syncStore.setOnboardingCompleted(true);
    await syncStore.setSyncMode(SyncMode.lanP2p);
    _onboardingCompleted = true;
    if (_session == null && startService && autoStartLanService) {
      await lanService.start();
    }
    if (!_disposed) notifyListeners();
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
  }) async {
    await initialize();
    final masterKey = SyncCrypto.generateMasterKey();
    final salt = SyncCrypto.randomBytes(16);
    final derived = await SyncCrypto.derivePasswordKeys(password: password, salt: salt, params: kdfParams);
    final backupEnvelope = await SyncCrypto.sealMasterKeyBackup(masterKey, derived.kek);

    final scraperSettings = await LibrarySettingsStore(db).loadScraper();
    final settingsMap = <String, Object?>{
      if (scraperSettings.tmdbImageBase.isNotEmpty) 'tmdb_image_base_url': scraperSettings.tmdbImageBase,
      'preferred_scrape_lang': scraperSettings.language,
    };

    final hadLocalContent = await _hasLocalSyncableContent();
    final resp = await apiClient.register(
      serverUrl: serverUrl,
      username: username.trim(),
      authVerifier: derived.authVerifier,
      kdfSalt: base64Encode(salt),
      kdfParams: kdfParams,
      encryptedMasterKeyBackup: backupEnvelope,
      deviceId: _deviceId!,
      settings: settingsMap,
    );

    final creds = SyncSessionCredentials(
      serverUrl: serverUrl,
      userId: resp.userId,
      username: resp.username,
      accessToken: resp.accessToken,
      masterKey: masterKey,
    );
    await _finishSignIn(creds, serverTimeMs: resp.serverTimeMs, hadLocalContentBeforeSignIn: hadLocalContent);
  }

  Future<void> loginWithPassword({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    await initialize();
    final kdf = await apiClient.lookupKdf(serverUrl, username.trim());
    final derived = await SyncCrypto.derivePasswordKeys(
      password: password,
      salt: base64Decode(kdf.kdfSalt),
      params: kdf.kdfParams,
    );
    final hadLocalContent = await _hasLocalSyncableContent();
    final resp = await apiClient.login(
      serverUrl: serverUrl,
      username: username.trim(),
      authVerifier: derived.authVerifier,
      deviceId: _deviceId!,
    );
    final masterKey = await SyncCrypto.unsealMasterKeyBackup(resp.encryptedMasterKeyBackup, derived.kek);
    final creds = SyncSessionCredentials(
      serverUrl: serverUrl,
      userId: resp.userId,
      username: resp.username,
      accessToken: resp.accessToken,
      masterKey: masterKey,
    );
    await _finishSignIn(creds, serverTimeMs: resp.serverTimeMs, hadLocalContentBeforeSignIn: hadLocalContent);
  }

  Future<({String sessionId, String qrUri, SyncQrKeyPair keyPair, int expiresAtMs})> startQrSession({
    required String serverUrl,
    required String deviceName,
  }) async {
    await initialize();
    final keyPair = await SyncQrKeyPairFuture.generate();
    final created = await apiClient.createQrSession(
      serverUrl,
      tvPubKey: keyPair.publicKeyBase64,
      deviceName: deviceName,
    );
    final uri = Uri(
      scheme: 'ttplay',
      host: 'qr-auth',
      queryParameters: {
        'server': serverUrl.trim().replaceAll(RegExp(r'/+$'), ''),
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
  }) async {
    await initialize();
    final poll = await apiClient.pollQrSession(serverUrl, sessionId);
    if (poll.status == 'expired') {
      throw const SyncApiException(410, 'QR session expired');
    }
    if (poll.status != 'confirmed' ||
        poll.accessToken == null ||
        poll.sealedMasterKey == null ||
        poll.userId == null) {
      return false;
    }

    final masterKey = await SyncCrypto.unsealMasterKeyOnTv(
      sealedEnvelope: poll.sealedMasterKey!,
      tvKeyPair: keyPair.keyPair,
    );
    final hadLocalContent = await _hasLocalSyncableContent();
    final creds = SyncSessionCredentials(
      serverUrl: serverUrl,
      userId: poll.userId!,
      username: poll.username ?? '',
      accessToken: poll.accessToken!,
      masterKey: masterKey,
    );
    await _finishSignIn(creds, serverTimeMs: poll.serverTimeMs, hadLocalContentBeforeSignIn: hadLocalContent);
    return true;
  }

  Future<void> confirmQrUri(String rawInput) async {
    await initialize();
    final current = _session;
    if (current == null) throw StateError('Not signed in');

    final trimmed = rawInput.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'ttplay' && uri.scheme != 'plezy') || uri.host != 'qr-auth') {
      throw const FormatException('Invalid QR pairing URI');
    }
    final sessionId = uri.queryParameters['session_id'] ?? '';
    final tvPubKey = uri.queryParameters['pub_key'] ?? '';
    final serverOverride = uri.queryParameters['server'];
    if (sessionId.isEmpty || tvPubKey.isEmpty) {
      throw const FormatException('Missing QR pairing parameters');
    }
    final sealed = await SyncCrypto.sealMasterKeyForTv(masterKey: current.masterKey, tvPubKeyBase64: tvPubKey);
    await apiClient.confirmQrSession(
      serverOverride != null && serverOverride.isNotEmpty ? serverOverride : current.serverUrl,
      current.accessToken,
      sessionId: sessionId,
      sealedMasterKey: sealed,
      deviceId: _deviceId!,
    );
  }

  Future<void> _clearCloudSessionState() async {
    await initialize();
    _session = null;
    _lastError = null;
    _lastSyncedAt = null;
    await syncStore.clearSession();
    await (db.delete(db.syncMetadata)..where((t) => t.key.equals(_kExportedUserKey))).go();
  }

  Future<void> signOut() async {
    await _clearCloudSessionState();
    await syncStore.setSyncMode(SyncMode.lanP2p);
    await syncStore.setOnboardingCompleted(true);
    _onboardingCompleted = true;
    if (autoStartLanService) {
      await lanService.start();
    }
    if (!_disposed) notifyListeners();
  }

  /// Clears any active cloud session and stops LAN sync so the user returns to
  /// login/mode selection without discarding local library data or media sources.
  Future<void> logoutToModeSelection() async {
    await _clearCloudSessionState();
    await lanService.stop();
    await syncStore.setOnboardingCompleted(false);
    _onboardingCompleted = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> _finishSignIn(
    SyncSessionCredentials creds, {
    required int serverTimeMs,
    required bool hadLocalContentBeforeSignIn,
  }) async {
    await lanService.stop();
    await syncStore.saveSession(creds);
    await syncStore.setSyncMode(SyncMode.cloudServer);
    await syncStore.setOnboardingCompleted(true);
    _onboardingCompleted = true;
    if (serverTimeMs > 0) {
      final offset = serverTimeMs - clock.now().millisecondsSinceEpoch;
      await syncStore.saveServerTimeOffsetMs(offset);
    }
    _session = creds;
    _lastError = null;
    if (!hadLocalContentBeforeSignIn) {
      await db
          .into(db.syncMetadata)
          .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: _kExportedUserKey, value: creds.userId));
    }
    if (!_disposed) notifyListeners();
    await syncNow(allowBackgroundScan: false);
  }

  Future<bool> _hasLocalSyncableContent() async {
    final mounts = await mountManager.registry.list();
    if (mounts.any((m) => m.kind != StorageKind.local)) return true;
    final states = await (db.select(db.workWatchStates)..limit(1)).get();
    if (states.isNotEmpty) return true;
    final skips = await (db.select(db.librarySettings)..where((t) => t.key.like('work-skip:%'))).get();
    return skips.isNotEmpty;
  }

  Future<bool> shouldAllowAutomaticIncrementalScan() async {
    await initialize();
    if (_disposed || isTvDevice || _isSyncing || lanService.isSyncing) {
      return false;
    }
    if (_session != null) return false;
    return true;
  }

  Future<void> onMountSaved(StorageMount mount) async {
    await initialize();
    await mountManager.dropCachedDriver(mount.id);
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
      unawaited(lanService.notifyTrustedPeersOfLocalChange());
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
      unawaited(lanService.notifyTrustedPeersOfLocalChange());
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
      unawaited(lanService.notifyTrustedPeersOfLocalChange());
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
      unawaited(lanService.notifyTrustedPeersOfLocalChange());
      return;
    }
    unawaited(pushOutboxOnly());
  }

  Future<void> pushOutboxOnly() async {
    await initialize();
    final sess = _session;
    if (sess == null || _isSyncing || _disposed) return;
    _isSyncing = true;
    if (!_disposed) notifyListeners();
    try {
      final remapped = await _pushPendingOutbox(sess);
      if (remapped) {
        await _pullAllDeltas(sess);
      }
      _lastSyncedAt = clock.now();
      _lastError = null;
    } catch (e) {
      appLogger.w('[SyncCoordinator] Background push failed (kept in outbox)', error: e);
    } finally {
      _isSyncing = false;
      _progress = SyncProgress.idle;
      await refreshOutboxCount();
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
    _progress = const SyncProgress(phase: SyncPhase.pulling);
    if (!_disposed) notifyListeners();

    try {
      // [Stage 2] Pull-Before-Scan (_pullAllDeltas fires throttled + final live refreshes immediately).
      await _pullAllDeltas(sess);
      await mapper.healCatalogFromJournal();

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
          await scanService!.checkIncrementalUpdates(canRun: () => !_disposed);
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
      _progress = SyncProgress.idle;
      await refreshOutboxCount();
    }
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

      final pageTotal = resp.sources.length +
          resp.works.length +
          resp.files.length +
          resp.workPrefs.length +
          resp.watchProgress.length;

      final touched = await mapper.applyPullBatch(
        masterKey: sess.masterKey,
        sources: resp.sources,
        works: resp.works,
        files: resp.files,
        workPrefs: resp.workPrefs,
        watchProgress: resp.watchProgress,
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
