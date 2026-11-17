import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../media/work_identity.dart';
import '../../services/credential_vault.dart';
import '../../services/work_skip_settings_store.dart';
import '../../utils/device_identity.dart';
import '../library_watch_state_store.dart';
import 'deterministic_keys.dart';
import 'sync_crypto.dart';
import 'sync_journal_store.dart';

enum SyncMode { lanP2p, cloudServer }

class LanTrustedPeer {
  const LanTrustedPeer({
    required this.deviceId,
    required this.deviceName,
    required this.pubKeyBase64,
    required this.sharedKeyBase64,
    required this.lastSyncedRevision,
    required this.pairedAtMs,
    this.lastHost,
    this.lastPort,
    this.lastRemotePort,
    this.lastSyncedEpoch,
    this.peerAckedMySeq = 0,
  });

  final String deviceId;
  final String deviceName;
  final String pubKeyBase64;
  final String sharedKeyBase64;
  final int lastSyncedRevision;
  final int pairedAtMs;
  final String? lastHost;
  final int? lastPort;
  final int? lastRemotePort;
  final String? lastSyncedEpoch;
  final int peerAckedMySeq;

  Uint8List get sharedKey => Uint8List.fromList(base64Decode(sharedKeyBase64));

  LanTrustedPeer copyWith({
    String? deviceName,
    int? lastSyncedRevision,
    String? lastHost,
    int? lastPort,
    int? lastRemotePort,
    bool clearLastRemotePort = false,
    String? lastSyncedEpoch,
    bool clearLastSyncedEpoch = false,
    int? peerAckedMySeq,
  }) => LanTrustedPeer(
    deviceId: deviceId,
    deviceName: deviceName ?? this.deviceName,
    pubKeyBase64: pubKeyBase64,
    sharedKeyBase64: sharedKeyBase64,
    lastSyncedRevision: lastSyncedRevision ?? this.lastSyncedRevision,
    pairedAtMs: pairedAtMs,
    lastHost: lastHost ?? this.lastHost,
    lastPort: lastPort ?? this.lastPort,
    lastRemotePort: clearLastRemotePort ? null : (lastRemotePort ?? this.lastRemotePort),
    lastSyncedEpoch: clearLastSyncedEpoch ? null : (lastSyncedEpoch ?? this.lastSyncedEpoch),
    peerAckedMySeq: peerAckedMySeq ?? this.peerAckedMySeq,
  );

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'device_name': deviceName,
    'pub_key': pubKeyBase64,
    'shared_key': sharedKeyBase64,
    'last_synced_revision': lastSyncedRevision,
    'paired_at_ms': pairedAtMs,
    if (lastHost != null) 'last_host': lastHost,
    if (lastPort != null) 'last_port': lastPort,
    if (lastRemotePort != null) 'last_remote_port': lastRemotePort,
    if (lastSyncedEpoch != null) 'last_synced_epoch': lastSyncedEpoch,
    if (peerAckedMySeq > 0) 'peer_acked_my_seq': peerAckedMySeq,
  };

  factory LanTrustedPeer.fromJson(Map<String, dynamic> json) => LanTrustedPeer(
    deviceId: json['device_id'] as String,
    deviceName: json['device_name'] as String? ?? 'Device',
    pubKeyBase64: json['pub_key'] as String,
    sharedKeyBase64: json['shared_key'] as String,
    lastSyncedRevision: (json['last_synced_revision'] as num?)?.toInt() ?? 0,
    pairedAtMs: (json['paired_at_ms'] as num?)?.toInt() ?? 0,
    lastHost: json['last_host'] as String?,
    lastPort: (json['last_port'] as num?)?.toInt(),
    lastRemotePort: (json['last_remote_port'] as num?)?.toInt(),
    lastSyncedEpoch: json['last_synced_epoch'] as String?,
    peerAckedMySeq: (json['peer_acked_my_seq'] as num?)?.toInt() ?? 0,
  );
}

/// Persists local sync metadata, calibrated timestamps, and the pending
/// [SyncOutbox] queue used by incremental synchronization.
class SyncLocalStore {
  SyncLocalStore(this.db);

  final AppDatabase db;
  late final SyncJournalStore journal = SyncJournalStore(db);

  static const String _kLastPullSeq = 'last_pull_seq';
  static const String _kServerTimeOffsetMs = 'server_time_offset_ms';
  static const String _kDeviceId = 'device_id';
  static const String _kServerUrl = 'sync_server_url';
  static const String _kUserId = 'sync_user_id';
  static const String _kUsername = 'sync_username';
  static const String _kAccessToken = 'sync_access_token';
  static const String _kMasterKey = 'sync_master_key';
  static const String _kAuthUpdatedPrefix = 'source_auth_updated_at:';
  static const String _kSyncMode = 'sync_mode';
  static const String _kOnboardingDone = 'sync_onboarding_done';
  static const String _kDeviceName = 'sync_device_name';
  static const String _kLanPrivKey = 'sync_lan_priv_key';
  static const String _kLanPubKey = 'sync_lan_pub_key';
  static const String _kLanTrustedPeers = 'sync_lan_trusted_peers';
  static const String _kLanPromptedPeers = 'sync_lan_prompted_peers';
  static const String _kLanRevision = 'sync_lan_revision';
  static const String _kSyncEpoch = 'sync_journal_epoch';
  static const String _kMinRetainedSeq = 'sync_journal_min_retained_seq';
  static const String _kCloudPushedSeq = 'sync_cloud_pushed_seq';
  static const String _kRemappedSources = 'sync_remapped_sources';
  static const String _kJournalBootstrapped = 'sync_journal_bootstrapped_v1';
  static const String _kLastCatalogSignature = 'sync_journal_catalog_sig_v1';
  static const String _kLastStateSignature = 'sync_journal_state_sig_v1';

  static const String typeSource = 'source';
  static const String typeWork = 'work';
  static const String typeFile = 'file';
  static const String typeWorkPref = 'work_pref';
  static const String typeWatchProgress = 'watch_progress';

  static int computeNextHlc(int proposedMs, int existingMs) =>
      proposedMs > existingMs ? proposedMs : existingMs + 1;

  Future<String?> _getMeta(String key) async {
    final row = await (db.select(db.syncMetadata)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _putMeta(String key, String value) async {
    await db.into(db.syncMetadata).insertOnConflictUpdate(SyncMetadataCompanion.insert(key: key, value: value));
  }

  Future<int> getLastPullSeq() async => int.tryParse(await _getMeta(_kLastPullSeq) ?? '') ?? 0;

  Future<void> saveLastPullSeq(int seq) => _putMeta(_kLastPullSeq, '$seq');

  Future<int> getServerTimeOffsetMs() async => int.tryParse(await _getMeta(_kServerTimeOffsetMs) ?? '') ?? 0;

  Future<void> saveServerTimeOffsetMs(int offsetMs) => _putMeta(_kServerTimeOffsetMs, '$offsetMs');

  Future<String> getOrCreateDeviceId() async {
    final existing = await _getMeta(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await _putMeta(_kDeviceId, generated);
    return generated;
  }

  Future<String> getOrCreateSyncEpoch() async {
    final existing = await _getMeta(_kSyncEpoch);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await _putMeta(_kSyncEpoch, generated);
    return generated;
  }

  Future<int> getMinRetainedSeq() async => int.tryParse(await _getMeta(_kMinRetainedSeq) ?? '') ?? 0;

  Future<void> saveMinRetainedSeq(int seq) => _putMeta(_kMinRetainedSeq, '$seq');

  Future<int> getCloudPushedSeq() async => int.tryParse(await _getMeta(_kCloudPushedSeq) ?? '') ?? 0;

  Future<void> saveCloudPushedSeq(int seq) => _putMeta(_kCloudPushedSeq, '$seq');

  Future<bool> isJournalBootstrapped() async => await _getMeta(_kJournalBootstrapped) == 'true';

  Future<void> markJournalBootstrapped() => _putMeta(_kJournalBootstrapped, 'true');

  /// Loads the last persisted DB signatures written when `sync_journal` finished
  /// a full catalog/state reconciliation so cold starts can skip scanning.
  Future<({String? catalogSig, String? stateSig})> getReconciledSignatures() async {
    final rows = await (db.select(
      db.syncMetadata,
    )..where((t) => t.key.isIn([_kLastCatalogSignature, _kLastStateSignature]))).get();
    String? catalogSig;
    String? stateSig;
    for (final row in rows) {
      if (row.value.isEmpty) continue;
      if (row.key == _kLastCatalogSignature) {
        catalogSig = row.value;
      } else if (row.key == _kLastStateSignature) {
        stateSig = row.value;
      }
    }
    return (catalogSig: catalogSig, stateSig: stateSig);
  }

  /// Persists non-null reconciled DB signatures to avoid full-catalog startup work.
  Future<void> saveReconciledSignatures({String? catalogSig, String? stateSig}) async {
    if (catalogSig == null && stateSig == null) return;
    await db.transaction(() async {
      if (catalogSig != null) await _putMeta(_kLastCatalogSignature, catalogSig);
      if (stateSig != null) await _putMeta(_kLastStateSignature, stateSig);
    });
  }

  /// Clears persisted reconciled DB signatures for [catalog] and/or [state].
  Future<void> clearReconciledSignatures({bool catalog = true, bool state = true}) async {
    final keys = <String>[
      if (catalog) _kLastCatalogSignature,
      if (state) _kLastStateSignature,
    ];
    if (keys.isEmpty) return;
    await (db.delete(db.syncMetadata)..where((t) => t.key.isIn(keys))).go();
  }

  Future<Map<String, String>> loadRemappedSources() async {
    final raw = await _getMeta(_kRemappedSources);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String) '${entry.key}': '${entry.value}',
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> recordRemappedSource(String oldSourceId, String newSourceId) async {
    if (oldSourceId == newSourceId || oldSourceId.isEmpty || newSourceId.isEmpty) return;
    final current = await loadRemappedSources();
    // Collapse any chain already pointing to oldSourceId directly onto newSourceId.
    final resolvedTarget = resolveRemappedSourceIdFromMap(current, newSourceId);
    current[oldSourceId] = resolvedTarget;
    for (final entry in current.entries.toList()) {
      current[entry.key] = resolveRemappedSourceIdFromMap(current, entry.value);
    }
    await _putMeta(_kRemappedSources, jsonEncode(current));
  }

  static String resolveRemappedSourceIdFromMap(Map<String, String> remaps, String sourceId) {
    final visited = <String>{};
    var cur = sourceId;
    while (visited.add(cur)) {
      final next = remaps[cur];
      if (next == null || next.isEmpty || next == cur) break;
      cur = next;
    }
    return cur;
  }

  Future<int> calibratedNowMs() async => clock.now().millisecondsSinceEpoch + await getServerTimeOffsetMs();

  /// Inserts or collapses an outbox mutation for `(entityType, entityKey)`,
  /// assigning a fresh [opId] so older in-flight pushes cannot remove newer edits.
  Future<void> enqueue({
    required String entityType,
    required String entityKey,
    required Map<String, Object?> payload,
    int? updatedAt,
    bool recordInJournal = true,
    bool writeOutbox = true,
    Map<String, String>? sourceSecrets,
  }) async {
    final existingJournal = recordInJournal ? await journal.getEntry(entityType, entityKey) : null;
    final proposedUpdatedAt = updatedAt ?? await calibratedNowMs();
    final effectiveUpdatedAt = (updatedAt == null && existingJournal != null)
        ? computeNextHlc(proposedUpdatedAt, existingJournal.clientUpdatedAt)
        : proposedUpdatedAt;

    final normalizedPayload = Map<String, Object?>.from(payload);
    if (normalizedPayload.containsKey('client_updated_at')) {
      normalizedPayload['client_updated_at'] = effectiveUpdatedAt;
    }

    if (recordInJournal) {
      final hash = SyncJournalStore.computeEntityHash(entityType, normalizedPayload, rawSecrets: sourceSecrets);
      final isDeleted = normalizedPayload['is_deleted'] == true;
      if (existingJournal == null || existingJournal.payloadHash != hash || existingJournal.isDeleted != isDeleted) {
        final localSeq = await allocNextLocalSeq();
        final deviceId = await getOrCreateDeviceId();
        final epoch = await getOrCreateSyncEpoch();
        await journal.upsertEntry(
          SyncJournalEntry(
            entityType: entityType,
            entityKey: entityKey,
            sourceId: SyncJournalStore.extractSourceId(entityType, normalizedPayload),
            relativePath: SyncJournalStore.extractRelativePath(normalizedPayload),
            workKey: SyncJournalStore.extractWorkKey(normalizedPayload),
            localSeq: localSeq,
            payloadHash: hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(entityType, normalizedPayload),
            clientUpdatedAt: effectiveUpdatedAt,
            isDeleted: isDeleted,
            originDeviceId: deviceId,
            originEpoch: epoch,
          ),
        );
      }
    }

    if (!writeOutbox) return;
    final createdAt = clock.now().millisecondsSinceEpoch;
    final opId = const Uuid().v4();
    await db
        .into(db.syncOutbox)
        .insertOnConflictUpdate(
          SyncOutboxCompanion.insert(
            entityType: entityType,
            entityKey: entityKey,
            opId: opId,
            payloadJson: jsonEncode(normalizedPayload),
            clientUpdatedAt: effectiveUpdatedAt,
            createdAt: createdAt,
          ),
        );
  }

  /// Queues watch progress changes for a movie, episode, or all episodes of a
  /// show/season when marked watched/unwatched.
  Future<void> enqueueWatchProgressForItemId(int itemId, {int? updatedAt}) async {
    final item = await (db.select(db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null) return;

    if (item.kind == 'show' || item.kind == 'season') {
      final items = db.libraryItems;
      final episodes = await (db.select(items)
            ..where(
              (t) =>
                  t.kind.equals('episode') &
                  (item.kind == 'show' ? t.showId.equals(itemId) : t.parentId.equals(itemId)),
            ))
          .get();
      for (final episode in episodes) {
        await _enqueueLeafProgress(episode.id, updatedAt: updatedAt);
      }
      return;
    }

    if (item.kind == 'movie' || item.kind == 'episode') {
      await _enqueueLeafProgress(item.id, updatedAt: updatedAt);
    }
  }

  Future<void> _enqueueLeafProgress(int itemId, {int? updatedAt}) async {
    final binding = await (db.select(db.libraryWorkBindings)..where((t) => t.itemId.equals(itemId))).getSingleOrNull();
    if (binding == null) return;
    final state = await (db.select(
      db.workWatchStates,
    )..where((t) => t.stateKey.equals(binding.stateKey))).getSingleOrNull();
    if (state == null || state.source != WorkIdentity.localSource) return;

    final workKey = '${state.provider}:${state.kind}:${state.externalId}';
    final progressKey = DeterministicKeys.generateProgressKey(
      workKey: workKey,
      kind: state.kind,
      seasonNum: state.seasonNumber,
      episodeNum: state.episodeNumber,
    );
    final existingJournal = await journal.getEntry(typeWatchProgress, progressKey);
    final int effectiveUpdatedAt;
    if (updatedAt != null) {
      effectiveUpdatedAt = updatedAt;
    } else {
      final calibratedNow = await calibratedNowMs();
      final floor = math.max(state.updatedAt, existingJournal?.clientUpdatedAt ?? 0);
      effectiveUpdatedAt = computeNextHlc(calibratedNow, floor);
      if (effectiveUpdatedAt > state.updatedAt) {
        await (db.update(db.workWatchStates)..where((t) => t.stateKey.equals(binding.stateKey))).write(
          WorkWatchStatesCompanion(updatedAt: Value(effectiveUpdatedAt)),
        );
        await (db.update(db.libraryUserStates)..where((t) => t.itemId.equals(itemId))).write(
          LibraryUserStatesCompanion(updatedAt: Value(effectiveUpdatedAt)),
        );
      }
    }
    await enqueue(
      entityType: typeWatchProgress,
      entityKey: progressKey,
      updatedAt: effectiveUpdatedAt,
      payload: {
        'progress_key': progressKey,
        'work_key': workKey,
        'season_num': state.seasonNumber,
        'episode_num': state.episodeNumber,
        'position_ms': state.positionMs,
        'duration_ms': state.durationMs ?? 0,
        'watched': state.watched,
        'play_count': state.playCount,
        'last_played_at': state.lastPlayedAt,
        'client_updated_at': effectiveUpdatedAt,
      },
    );
  }

  Future<void> enqueueWorkPrefsForItemId(int itemId, {int? updatedAt}) async {
    final work = await LibraryWatchStateStore(db).resolveWork(itemId);
    if (work == null || work.source != WorkIdentity.localSource) return;
    await enqueueWorkPrefsForIdentity(work, updatedAt: updatedAt);
  }

  /// Queues whole-work preferences (intro/credits skip + favorite/hidden flags)
  /// for a scraped local movie or show.
  Future<void> enqueueWorkPrefsForIdentity(WorkIdentity work, {int? updatedAt}) async {
    if (work.source != WorkIdentity.localSource) return;
    final workKey = '${work.provider}:${work.kind}:${work.externalId}';
    final skip = await WorkSkipSettingsStore(db).read(work);
    final wholeState = await LibraryWatchStateStore(db).read(work.stateKey());
    final existingJournal = await journal.getEntry(typeWorkPref, workKey);
    final stampKey = 'sync-pref-ts:${work.stateKey()}';
    final localStamp = int.tryParse(
          (await (db.select(db.librarySettings)..where((t) => t.key.equals(stampKey))).getSingleOrNull())?.value ?? '',
        ) ??
        0;

    final int effectiveUpdatedAt;
    if (updatedAt != null) {
      effectiveUpdatedAt = updatedAt;
    } else {
      final calibratedNow = await calibratedNowMs();
      final floor = math.max(
        math.max(localStamp, wholeState?.updatedAt ?? 0),
        existingJournal?.clientUpdatedAt ?? 0,
      );
      effectiveUpdatedAt = computeNextHlc(calibratedNow, floor);
      await db
          .into(db.librarySettings)
          .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: stampKey, value: '$effectiveUpdatedAt'));
      if (wholeState != null && effectiveUpdatedAt > wholeState.updatedAt) {
        await (db.update(db.workWatchStates)..where((t) => t.stateKey.equals(work.stateKey()))).write(
          WorkWatchStatesCompanion(updatedAt: Value(effectiveUpdatedAt)),
        );
      }
    }
    await enqueue(
      entityType: typeWorkPref,
      entityKey: workKey,
      updatedAt: effectiveUpdatedAt,
      payload: {
        'work_key': workKey,
        'intro_enabled': skip.introEnabled,
        'intro_start_ms': skip.introStartMs,
        'intro_end_ms': skip.introEndMs,
        'credits_enabled': skip.creditsEnabled,
        'credits_from_end_ms': skip.creditsDurationMs,
        'keep_easter_egg_ms': skip.creditsResumeBeforeEndMs,
        'is_favorite': wholeState?.favorite ?? false,
        'hidden_from_continue': wholeState?.hiddenFromContinue ?? false,
        'client_updated_at': effectiveUpdatedAt,
      },
    );
  }

  Future<List<SyncOutboxRow>> readPendingOutbox({int limit = 200}) {
    return (db.select(db.syncOutbox)
          ..orderBy([(t) => OrderingTerm.asc(t.clientUpdatedAt)])
          ..limit(limit))
        .get();
  }

  Future<void> deleteAcceptedOutbox(Iterable<String> acceptedOpIds) async {
    final ids = acceptedOpIds.where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return;
    await (db.delete(db.syncOutbox)..where((t) => t.opId.isIn(ids))).go();
  }

  Future<void> saveSession(SyncSessionCredentials credentials) async {
    final normalizedUrl = credentials.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final protectedToken = await CredentialVault.protect(credentials.accessToken);
    final protectedKey = await CredentialVault.protect(base64Encode(credentials.masterKey));
    await db.transaction(() async {
      await _putMeta(_kServerUrl, normalizedUrl);
      await _putMeta(_kUserId, credentials.userId);
      await _putMeta(_kUsername, credentials.username);
      await _putMeta(_kAccessToken, protectedToken);
      await _putMeta(_kMasterKey, protectedKey);
    });
  }

  Future<SyncSessionCredentials?> loadSession() async {
    final serverUrl = await _getMeta(_kServerUrl);
    final userId = await _getMeta(_kUserId);
    final username = await _getMeta(_kUsername);
    final protectedToken = await _getMeta(_kAccessToken);
    final protectedKey = await _getMeta(_kMasterKey);
    if (serverUrl == null ||
        serverUrl.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        protectedToken == null ||
        protectedKey == null) {
      return null;
    }
    final token = await CredentialVault.reveal(protectedToken);
    final keyB64 = await CredentialVault.reveal(protectedKey);
    if (token == null || token.isEmpty || keyB64 == null || keyB64.isEmpty) return null;
    try {
      return SyncSessionCredentials(
        serverUrl: serverUrl,
        userId: userId,
        username: username ?? '',
        accessToken: token,
        masterKey: Uint8List.fromList(base64Decode(keyB64)),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> clearSession() async {
    await db.transaction(() async {
      await (db.delete(db.syncMetadata)
            ..where(
              (t) => t.key.isIn([
                _kServerUrl,
                _kUserId,
                _kUsername,
                _kAccessToken,
                _kMasterKey,
                _kLastPullSeq,
                _kServerTimeOffsetMs,
                _kCloudPushedSeq,
              ]),
            ))
          .go();
    });
  }

  Future<void> resetSyncCursorsForFullRebuild() async {
    await _putMeta(_kLastPullSeq, '0');
  }

  Future<int> getAuthUpdatedAt(String mountId) async =>
      int.tryParse(await _getMeta('$_kAuthUpdatedPrefix$mountId') ?? '') ?? 0;

  Future<void> setAuthUpdatedAt(String mountId, int timestampMs) =>
      _putMeta('$_kAuthUpdatedPrefix$mountId', '$timestampMs');

  Future<void> clearAllOutbox() => db.delete(db.syncOutbox).go();

  /// Rekeys pending `file` / `source` outbox entries when [oldSourceId] is
  /// deduplicated into an existing server [newSourceId].
  Future<void> rekeyOutboxForRemappedSource(String oldSourceId, String newSourceId) async {
    if (oldSourceId == newSourceId) return;
    final rows = await db.select(db.syncOutbox).get();
    final remappedFileIds = <String, String>{};
    final decodedFiles = <({SyncOutboxRow row, Map<String, dynamic> map})>[];

    for (final row in rows) {
      if (row.entityType == typeFile) {
        final map = jsonDecode(row.payloadJson) as Map<String, dynamic>;
        if (map['source_id'] == oldSourceId) {
          final oldFileId = map['file_id'] as String? ?? row.entityKey;
          final relPath = map['relative_path'] as String? ?? '';
          final newFileId = DeterministicKeys.generateFileId(sourceId: newSourceId, mountRelativePath: relPath);
          if (oldFileId.isNotEmpty) {
            remappedFileIds[oldFileId] = newFileId;
          }
          decodedFiles.add((row: row, map: map));
        }
      }
    }

    await db.transaction(() async {
      for (final row in rows) {
        if (row.entityType == typeSource && row.entityKey == oldSourceId) {
          await (db.delete(
            db.syncOutbox,
          )..where((t) => t.entityType.equals(row.entityType) & t.entityKey.equals(row.entityKey))).go();
        }
      }
      for (final entry in decodedFiles) {
        final map = entry.map;
        final relPath = map['relative_path'] as String? ?? '';
        final newFileId = DeterministicKeys.generateFileId(sourceId: newSourceId, mountRelativePath: relPath);
        map['source_id'] = newSourceId;
        map['file_id'] = newFileId;
        final owner = map['owner_file_id'] as String?;
        if (owner != null && remappedFileIds.containsKey(owner)) {
          map['owner_file_id'] = remappedFileIds[owner];
        }
        await (db.delete(
          db.syncOutbox,
        )..where((t) => t.entityType.equals(entry.row.entityType) & t.entityKey.equals(entry.row.entityKey))).go();
        await enqueue(
          entityType: typeFile,
          entityKey: newFileId,
          updatedAt: entry.row.clientUpdatedAt,
          payload: map.cast<String, Object?>(),
          recordInJournal: false,
        );
      }
    });
  }

  Future<SyncMode> getSyncMode() async {
    final raw = await _getMeta(_kSyncMode);
    if (raw == SyncMode.cloudServer.name) return SyncMode.cloudServer;
    if (raw == SyncMode.lanP2p.name) return SyncMode.lanP2p;
    final hasSession = (await _getMeta(_kAccessToken))?.isNotEmpty == true;
    return hasSession ? SyncMode.cloudServer : SyncMode.lanP2p;
  }

  Future<void> setSyncMode(SyncMode mode) => _putMeta(_kSyncMode, mode.name);

  Future<bool> isOnboardingCompleted() async => await _getMeta(_kOnboardingDone) == 'true';

  Future<bool> hasExplicitOnboardingState() async => await _getMeta(_kOnboardingDone) != null;

  Future<void> setOnboardingCompleted(bool completed) => _putMeta(_kOnboardingDone, '$completed');

  /// Returns the user-saved custom device name when present and meaningful,
  /// or null when falling back to platform-resolved defaults.
  Future<String?> getCustomDeviceName() async {
    final saved = await _getMeta(_kDeviceName);
    if (!isMeaningfulDeviceName(saved)) return null;
    return saved!.trim();
  }

  Future<String> getDeviceName() async {
    final saved = await getCustomDeviceName();
    if (saved != null) return saved;
    try {
      final identity = await DeviceIdentityService.resolve();
      if (isMeaningfulDeviceName(identity.deviceName)) {
        return identity.deviceName!.trim();
      }
    } catch (_) {}
    try {
      final host = Platform.localHostname.trim();
      if (isMeaningfulDeviceName(host)) return host;
    } catch (_) {}
    return 'Plezy Device';
  }

  Future<void> setDeviceName(String name) => _putMeta(_kDeviceName, name.trim());

  Future<int> getLocalLanRevision() async {
    final metaRev = int.tryParse(await _getMeta(_kLanRevision) ?? '') ?? 0;
    final maxJournalSeq = await journal.getMaxLocalSeq();
    return math.max(metaRev, maxJournalSeq);
  }

  Future<int> allocNextLocalSeq() => allocLocalSeqRange(1);

  /// Allocates [count] contiguous strictly monotonic local sequence numbers and
  /// returns the first sequence number allocated (`base + 1 .. base + count`).
  Future<int> allocLocalSeqRange(int count) async {
    final base = await getLocalLanRevision();
    if (count <= 0) return base + 1;
    await _putMeta(_kLanRevision, '${base + count}');
    return base + 1;
  }

  Future<int> bumpLocalLanRevision() => allocNextLocalSeq();

  Future<({String privateKeyBase64, String publicKeyBase64})> getOrCreateLanKeyPair() async {
    final encPriv = await _getMeta(_kLanPrivKey);
    final pub = await _getMeta(_kLanPubKey);
    if (encPriv != null && encPriv.isNotEmpty && pub != null && pub.isNotEmpty) {
      final clearPriv = await CredentialVault.reveal(encPriv);
      if (clearPriv != null && clearPriv.isNotEmpty) {
        return (privateKeyBase64: clearPriv, publicKeyBase64: pub);
      }
    }
    final generated = await SyncCrypto.generateLanIdentityKeyPair();
    final protectedPriv = await CredentialVault.protect(generated.privateKeyBase64);
    await db.transaction(() async {
      await _putMeta(_kLanPrivKey, protectedPriv);
      await _putMeta(_kLanPubKey, generated.publicKeyBase64);
    });
    return generated;
  }

  Future<List<LanTrustedPeer>> loadTrustedLanPeers() async {
    final protectedJson = await _getMeta(_kLanTrustedPeers);
    if (protectedJson == null || protectedJson.isEmpty) return const [];
    final rawJson = await CredentialVault.reveal(protectedJson);
    if (rawJson == null || rawJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) LanTrustedPeer.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveTrustedLanPeers(List<LanTrustedPeer> peers) async {
    final raw = jsonEncode([for (final p in peers) p.toJson()]);
    final protectedJson = await CredentialVault.protect(raw);
    await _putMeta(_kLanTrustedPeers, protectedJson);
  }

  Future<Set<String>> loadPromptedLanPeerIds() async {
    final rawJson = await _getMeta(_kLanPromptedPeers);
    if (rawJson == null || rawJson.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) return <String>{};
      return {
        for (final entry in decoded)
          if (entry is String && entry.isNotEmpty) entry,
      };
    } on FormatException {
      return <String>{};
    }
  }

  Future<void> savePromptedLanPeerIds(Iterable<String> peerIds) async {
    final sorted = [
      for (final id in {...peerIds})
        if (id.isNotEmpty) id,
    ]..sort();
    await _putMeta(_kLanPromptedPeers, jsonEncode(sorted));
  }
}
