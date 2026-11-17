import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../media/work_identity.dart';
import '../../media/work_skip_settings.dart';
import '../../services/work_skip_settings_store.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_mount.dart';
import '../../storage/storage_path.dart';
import '../../utils/serial_future_queue.dart';
import '../library_repository.dart';
import '../library_settings.dart';
import '../library_watch_state_store.dart';
import 'deterministic_keys.dart';
import 'sync_crypto.dart';
import 'sync_journal_store.dart';
import 'sync_local_store.dart';
import 'sync_models.dart';

/// Translates between local Drift auto-increment rows (`LibraryItems`,
/// `LibraryFiles`, `Mounts`, `WorkWatchStates`) and deterministic cloud sync
/// payloads while enforcing canonical source deduplication and monotonic conflict rules.
class SyncMapper {
  SyncMapper({
    required this.db,
    required this.repo,
    required this.syncStore,
    required this.mountManager,
    this.onPreemptMountScan,
  });

  final AppDatabase db;
  final LibraryRepository repo;
  final SyncLocalStore syncStore;
  final MountManager mountManager;
  final Future<void> Function(String mountId)? onPreemptMountScan;

  static const int workChunkSize = 25;
  static const int fileChunkSize = 80;
  static const int stateChunkSize = 120;
  static const int _outboxBatchSize = 250;

  final SerialFutureQueue _journalQueue = SerialFutureQueue();
  String? _lastCatalogSignature;
  String? _lastStateSignature;

  static int _nowMs() => clock.now().millisecondsSinceEpoch;

  void _invalidateSignatureCache() {
    _lastCatalogSignature = null;
    _lastStateSignature = null;
  }

  static StorageKind? _parseKind(String protocol) => StorageKind.fromId(protocol);

  static String _primaryUrlOf(StorageMount mount) => switch (mount.kind) {
    StorageKind.webdav => mount.configString(MountKeys.baseUrl) ?? '',
    StorageKind.quark => 'quark://${mount.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId}',
    StorageKind.smb =>
      'smb://${mount.configString(MountKeys.host) ?? ''}/${mount.configString(MountKeys.share) ?? ''}${StoragePath.normalize(mount.configString(MountKeys.rootPath) ?? '')}',
    StorageKind.local => mount.configString(MountKeys.rootPath) ?? '/',
  };

  Future<Map<String, Object?>> _buildSourcePayload(
    StorageMount mount, {
    Uint8List? encryptionKey,
    required int ts,
    bool forceAuthOverride = false,
    String? quarkCheckpointOverride,
    int? scanFinishedAtOverride,
  }) async {
    final canonicalKey = DeterministicKeys.canonicalSourceKey(mount);
    String? quarkCp = quarkCheckpointOverride;
    int? finishedAt = scanFinishedAtOverride;
    if (quarkCp == null && finishedAt == null) {
      final scanRow = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).getSingleOrNull();
      quarkCp = scanRow?.quarkCheckpoint;
      finishedAt = scanRow?.finishedAt;
    }
    final encryptedAuth = (encryptionKey == null || mount.secrets.isEmpty)
        ? ''
        : await SyncCrypto.encryptPayload(jsonEncode(mount.secrets), encryptionKey);

    var authUpdatedAt = await syncStore.getAuthUpdatedAt(mount.id);
    if (authUpdatedAt == 0 && mount.secrets.isNotEmpty) {
      authUpdatedAt = ts;
      await syncStore.setAuthUpdatedAt(mount.id, authUpdatedAt);
    }

    final extraConfig = <String, Object?>{
      for (final entry in mount.config.entries)
        if (entry.key != MountKeys.fallbackUrl &&
            entry.key != MountKeys.includePaths &&
            entry.key != MountKeys.excludePaths &&
            entry.key != MountKeys.isLanOnly)
          entry.key: entry.value,
    };

    return {
      'source_id': mount.id,
      'canonical_key': canonicalKey,
      'name': mount.displayName,
      'protocol': mount.kind.id,
      'is_lan_only': mount.configBool(MountKeys.isLanOnly),
      'primary_url': _primaryUrlOf(mount),
      'fallback_url': mount.configString(MountKeys.fallbackUrl),
      'config_json': extraConfig,
      'include_paths': mount.configStringList(MountKeys.includePaths),
      'exclude_paths': mount.configStringList(MountKeys.excludePaths),
      'encrypted_auth': encryptedAuth,
      'auth_updated_at': authUpdatedAt,
      if (forceAuthOverride) 'force_auth_override': true,
      'quark_checkpoint': quarkCp,
      'scan_finished_at': finishedAt,
      'created_at': mount.createdAt?.millisecondsSinceEpoch ?? ts,
      'client_updated_at': ts,
      'is_deleted': false,
    };
  }

  Future<Map<String, Object?>> _buildWorkPayload(
    LibraryItemRow workItem, {
    required String workKey,
    required int workRank,
    required int updatedAt,
  }) async {
    final genres = [for (final g in await repo.genresOf(workItem.id)) g.name];
    final credits = [
      for (final c in (await repo.creditsOf(workItem.id)).take(25))
        {
          'name': c.person.name,
          'job': c.job,
          'character': c.character,
          'tmdb_id': c.person.tmdbId,
          'photo_url': c.person.photoSource,
        },
    ];
    final (provider, extId) = _primaryProviderAndId(workItem);
    return {
      'work_key': workKey,
      'kind': workItem.kind,
      'library_type': workItem.libraryType,
      'provider': provider ?? workItem.metadataSource,
      'external_id': extId,
      'match_status': workRank,
      'metadata_json': {
        'title': workItem.title,
        'sort_title': workItem.sortTitle,
        'original_title': workItem.originalTitle,
        'aliases': workItem.aliases,
        'year': workItem.year,
        'release_date': workItem.releaseDate,
        'summary': workItem.summary,
        'tagline': workItem.tagline,
        'content_rating': workItem.contentRating,
        'studio': workItem.studio,
        'rating': workItem.rating,
        'runtime_ms': workItem.runtimeMs,
        'tmdb_id': workItem.tmdbId,
        'imdb_id': workItem.imdbId,
        'tvdb_id': workItem.tvdbId,
        'bangumi_id': workItem.bangumiId,
        'douban_id': workItem.doubanId,
        'poster_path': workItem.posterSource,
        'backdrop_path': workItem.backdropSource,
        'logo_path': workItem.logoSource,
        'metadata_source': workItem.metadataSource,
        'locked': workItem.locked,
        'source_added_at': workItem.sourceAddedAt,
        'genres': genres,
        'credits': credits,
      },
      'client_updated_at': updatedAt,
      'is_deleted': false,
    };
  }

  Map<String, Object?> _buildVideoFilePayload(
    LibraryFileRow file, {
    required String fileId,
    required String? workKey,
    LibraryItemRow? item,
    LibraryItemRow? workItem,
    required int updatedAt,
  }) {
    final ep = item != null && item.kind == LibraryKinds.episode ? item : null;
    return {
      'file_id': fileId,
      'source_id': file.mountId,
      'relative_path': DeterministicKeys.normalizeMountPath(file.path),
      'remote_id': file.remoteId,
      'role': file.role,
      'owner_file_id': null,
      'language': file.language,
      'file_name': StoragePath.name(file.path),
      'file_size': file.size ?? 0,
      'file_mtime': file.modifiedAt ?? 0,
      'file_created_at': file.sourceCreatedAt ?? 0,
      'work_key': workKey,
      'season_num': ep?.seasonNumber ?? -1,
      'episode_num': ep?.episodeNumber ?? -1,
      'match_status': MatchStatusRank.fromFile(file, item: workItem),
      'version_label': file.versionLabel,
      'parsed_json': file.parsed,
      'media_spec_json': {
        if (file.durationMs != null) 'duration_ms': file.durationMs,
        if (file.container != null) 'container': file.container,
        if (file.videoCodec != null) 'video_codec': file.videoCodec,
        if (file.width != null) 'width': file.width,
        if (file.height != null) 'height': file.height,
        if (file.hdrFormat != null) 'hdr_format': file.hdrFormat,
        if (ep != null) 'ep_title': ep.title,
        if (ep?.summary != null) 'ep_overview': ep!.summary,
        if (ep?.posterSource != null) 'ep_still_path': ep!.posterSource,
        if (ep?.runtimeMs != null) 'ep_runtime_ms': ep!.runtimeMs,
        if (ep?.metadataSource != null) 'ep_metadata_source': ep!.metadataSource,
        if (ep?.scrapedAt != null) 'ep_scraped_at': ep!.scrapedAt,
        if (ep?.releaseDate != null) 'ep_release_date': ep!.releaseDate,
      },
      'client_updated_at': updatedAt,
      'is_deleted': false,
    };
  }

  Map<String, Object?> _buildSubtitleFilePayload(
    LibraryFileRow file, {
    required String fileId,
    required String? ownerFileId,
    required int updatedAt,
  }) => {
    'file_id': fileId,
    'source_id': file.mountId,
    'relative_path': DeterministicKeys.normalizeMountPath(file.path),
    'remote_id': file.remoteId,
    'role': LibraryFileRoles.subtitle,
    'owner_file_id': ownerFileId,
    'language': file.language,
    'file_name': StoragePath.name(file.path),
    'file_size': file.size ?? 0,
    'file_mtime': file.modifiedAt ?? 0,
    'season_num': -1,
    'episode_num': -1,
    'match_status': MatchStatusRank.matched,
    'media_spec_json': const <String, Object?>{},
    'client_updated_at': updatedAt,
    'is_deleted': false,
  };

  /// Enqueues [mount] (excluding [StorageKind.local]) into `SyncOutbox` and `sync_journal`.
  Future<void> enqueueMount(
    StorageMount mount, {
    required Uint8List masterKey,
    bool forceAuthOverride = false,
    int? updatedAt,
  }) async {
    if (mount.kind == StorageKind.local) return;
    _invalidateSignatureCache();
    final ts = updatedAt ?? await syncStore.calibratedNowMs();
    final payload = await _buildSourcePayload(
      mount,
      encryptionKey: masterKey,
      ts: ts,
      forceAuthOverride: forceAuthOverride,
    );
    await syncStore.enqueue(
      entityType: SyncLocalStore.typeSource,
      entityKey: mount.id,
      updatedAt: ts,
      payload: payload,
      sourceSecrets: mount.secrets,
    );
  }

  Future<void> enqueueMountDeletion(String mountId, {int? updatedAt}) async {
    _invalidateSignatureCache();
    final ts = updatedAt ?? await syncStore.calibratedNowMs();
    await syncStore.enqueue(
      entityType: SyncLocalStore.typeSource,
      entityKey: mountId,
      updatedAt: ts,
      payload: {
        'source_id': mountId,
        'is_deleted': true,
        'client_updated_at': ts,
      },
    );
  }

  Future<({String catalogSig, String stateSig})> _computeDbSignatures() async {
    final mountRow = await db.customSelect(
      "SELECT COUNT(*) || ':' || COALESCE(SUM(LENGTH(config_json)),0) || ':' || "
      "COALESCE(SUM(LENGTH(secrets)),0) || ':' || COALESCE(SUM(LENGTH(display_name)),0) AS s "
      "FROM mounts WHERE kind != 'local'",
    ).getSingle();
    final fileRow = await db.customSelect(
      "SELECT COUNT(*) || ':' || COALESCE(MAX(id),0) || ':' || "
      "COALESCE(SUM(CASE WHEN match_state='matched' THEN 2 WHEN match_state='unmatched' THEN 1 ELSE 0 END),0) || ':' || "
      "COALESCE(SUM(CASE WHEN match_locked=1 THEN 1 ELSE 0 END),0) || ':' || "
      "COALESCE(SUM(item_id),0) || ':' || COALESCE(SUM(size),0) || ':' || COALESCE(SUM(modified_at),0) AS s "
      "FROM library_files WHERE match_state != 'ignored'",
    ).getSingle();
    final itemRow = await db.customSelect(
      'SELECT COUNT(*) || \':\' || COALESCE(MAX(updated_at),0) || \':\' || '
      'COALESCE(MAX(id),0) || \':\' || COALESCE(SUM(CASE WHEN locked=1 THEN 1 ELSE 0 END),0) || \':\' || '
      'COALESCE(SUM(LENGTH(library_type)),0) AS s FROM library_items',
    ).getSingle();
    final scanRow = await db.customSelect(
      'SELECT COUNT(*) || \':\' || COALESCE(SUM(LENGTH(quark_checkpoint)),0) || \':\' || '
      'COALESCE(SUM(finished_at),0) AS s FROM library_scan_states',
    ).getSingle();

    final stateRow = await db.customSelect(
      "SELECT COUNT(*) || ':' || COALESCE(MAX(updated_at),0) || ':' || "
      "COALESCE(SUM(position_ms),0) || ':' || COALESCE(SUM(watched),0) || ':' || "
      "COALESCE(SUM(favorite),0) || ':' || COALESCE(SUM(hidden_from_continue),0) AS s "
      "FROM work_watch_states WHERE source = 'local'",
    ).getSingle();
    final skipRow = await db.customSelect(
      "SELECT COUNT(*) || ':' || COALESCE(SUM(LENGTH(value)),0) AS s "
      "FROM library_settings WHERE key LIKE 'work-skip:local:%'",
    ).getSingle();

    final catalogSig = '${mountRow.read<String>('s')}|${fileRow.read<String>('s')}|${itemRow.read<String>('s')}|${scanRow.read<String>('s')}';
    final stateSig = '${stateRow.read<String>('s')}|${skipRow.read<String>('s')}';
    return (catalogSig: catalogSig, stateSig: stateSig);
  }

  /// Ensures `sync_journal` reflects any local DB changes (including rows
  /// inserted directly without triggering scan/playback hooks), returning the
  /// number of newly journaled or updated entries.
  Future<int> ensureJournalUpToDate() {
    return _journalQueue.run(() async {
      final bootstrapped = await syncStore.isJournalBootstrapped();
      final sigs = await _computeDbSignatures();
      if (bootstrapped && sigs.catalogSig == _lastCatalogSignature && sigs.stateSig == _lastStateSignature) {
        return 0;
      }

      var touched = 0;
      if (!bootstrapped || sigs.catalogSig != _lastCatalogSignature) {
        touched = await _reconcileCatalogInternal(
          allowTombstones: true,
          includeWorkStates: true,
        );
        final refreshed = await _computeDbSignatures();
        _lastCatalogSignature = refreshed.catalogSig;
        _lastStateSignature = refreshed.stateSig;
      } else if (sigs.stateSig != _lastStateSignature) {
        touched = await _reconcileWorkStatesInternal();
        final refreshed = await _computeDbSignatures();
        _lastStateSignature = refreshed.stateSig;
      }
      if (!bootstrapped) {
        await syncStore.markJournalBootstrapped();
      }
      return touched;
    });
  }

  /// Reconciles local catalog tables into `sync_journal`, allocating strictly
  /// monotonic `local_seq` numbers only for entities whose canonical content changed
  /// or were removed within scope.
  Future<int> reconcileCatalogToJournal({
    Set<String>? mountIds,
    Set<String>? directoryPrefixes,
    bool allowTombstones = true,
    bool includeWorkStates = false,
  }) {
    return _journalQueue.run(() async {
      final changed = await _reconcileCatalogInternal(
        mountIds: mountIds,
        directoryPrefixes: directoryPrefixes,
        allowTombstones: allowTombstones,
        includeWorkStates: includeWorkStates,
      );
      if (mountIds == null && directoryPrefixes == null && allowTombstones && includeWorkStates) {
        final sigs = await _computeDbSignatures();
        _lastCatalogSignature = sigs.catalogSig;
        _lastStateSignature = sigs.stateSig;
      } else {
        _invalidateSignatureCache();
      }
      await syncStore.markJournalBootstrapped();
      return changed;
    });
  }

  /// Marks a removed mount and all of its previously synced files as deleted
  /// tombstones in `sync_journal` and cleans up orphaned `raw:` works.
  Future<int> reconcileMountRemovalToJournal(String mountId) {
    return _journalQueue.run(() async {
      _invalidateSignatureCache();
      final calibratedNow = await syncStore.calibratedNowMs();
      final deviceId = await syncStore.getOrCreateDeviceId();
      final epoch = await syncStore.getOrCreateSyncEpoch();
      final pending = <_JournalCandidate>[];

      final activeFiles = await syncStore.journal.getActiveFilesForMount(mountId);
      for (final fileEntry in activeFiles) {
        final delTs = SyncLocalStore.computeNextHlc(calibratedNow, fileEntry.clientUpdatedAt);
        final delPayload = <String, Object?>{
          'file_id': fileEntry.entityKey,
          'source_id': mountId,
          if (fileEntry.relativePath != null) 'relative_path': fileEntry.relativePath,
          'is_deleted': true,
          'client_updated_at': delTs,
        };
        pending.add(
          _JournalCandidate(
            entityType: SyncLocalStore.typeFile,
            entityKey: fileEntry.entityKey,
            sourceId: mountId,
            relativePath: fileEntry.relativePath,
            workKey: fileEntry.workKey,
            payload: delPayload,
            hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, delPayload),
            updatedAt: delTs,
            isDeleted: true,
          ),
        );
      }

      final existingSource = await syncStore.journal.getEntry(SyncLocalStore.typeSource, mountId);
      final srcTs = existingSource != null
          ? SyncLocalStore.computeNextHlc(calibratedNow, existingSource.clientUpdatedAt)
          : calibratedNow;
      final srcDelPayload = <String, Object?>{
        'source_id': mountId,
        'is_deleted': true,
        'client_updated_at': srcTs,
      };
      pending.add(
        _JournalCandidate(
          entityType: SyncLocalStore.typeSource,
          entityKey: mountId,
          sourceId: mountId,
          payload: srcDelPayload,
          hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeSource, srcDelPayload),
          updatedAt: srcTs,
          isDeleted: true,
        ),
      );

      if (pending.isEmpty) return 0;
      await _commitJournalCandidates(pending, originDeviceId: deviceId, originEpoch: epoch);
      final orphanCount = await _tombstoneOrphanedRawWorks(
        calibratedNow: calibratedNow,
        deviceId: deviceId,
        epoch: epoch,
      );
      return pending.length + orphanCount;
    });
  }

  Future<int> _reconcileCatalogInternal({
    Set<String>? mountIds,
    Set<String>? directoryPrefixes,
    required bool allowTombstones,
    required bool includeWorkStates,
  }) async {
    final calibratedNow = await syncStore.calibratedNowMs();
    final deviceId = await syncStore.getOrCreateDeviceId();
    final epoch = await syncStore.getOrCreateSyncEpoch();

    final mounts = await mountManager.registry.list();
    final sharedMounts = [
      for (final m in mounts)
        if (m.kind != StorageKind.local && (mountIds == null || mountIds.contains(m.id))) m,
    ];
    final sharedIds = sharedMounts.map((m) => m.id).toSet();

    final normalizedPrefixes = directoryPrefixes == null || directoryPrefixes.isEmpty
        ? null
        : <String>{
            for (final dir in directoryPrefixes) DeterministicKeys.normalizeMountPath(dir),
          };
    final effectivePrefixes = (normalizedPrefixes != null && normalizedPrefixes.contains('/')) ? null : normalizedPrefixes;

    bool pathInScope(String rawPath) {
      if (effectivePrefixes == null) return true;
      final norm = DeterministicKeys.normalizeMountPath(rawPath);
      for (final prefix in effectivePrefixes) {
        if (norm == prefix || norm.startsWith('$prefix/')) return true;
      }
      return false;
    }

    final existingSources = await syncStore.journal.getEntriesForType(
      SyncLocalStore.typeSource,
      sharedIds,
    );

    final scanRows = sharedIds.isEmpty
        ? const <LibraryScanStateRow>[]
        : await (db.select(db.libraryScanStates)..where((t) => t.mountId.isIn(sharedIds))).get();
    final scanByMount = {for (final s in scanRows) s.mountId: s};

    final sourceCandidates = <_JournalCandidate>[];
    for (final mount in sharedMounts) {
      final existing = existingSources[mount.id];
      final initialTs = mount.createdAt?.millisecondsSinceEpoch ?? calibratedNow;
      final provisionalTs = existing?.clientUpdatedAt ?? initialTs;
      final scan = scanByMount[mount.id];
      final payload = await _buildSourcePayload(
        mount,
        ts: provisionalTs,
        quarkCheckpointOverride: scan?.quarkCheckpoint,
        scanFinishedAtOverride: scan?.finishedAt,
      );
      final hash = SyncJournalStore.computeEntityHash(
        SyncLocalStore.typeSource,
        payload,
        rawSecrets: mount.secrets,
      );
      if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

      final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : initialTs;
      payload['client_updated_at'] = effectiveTs;
      sourceCandidates.add(
        _JournalCandidate(
          entityType: SyncLocalStore.typeSource,
          entityKey: mount.id,
          sourceId: mount.id,
          payload: payload,
          hash: hash,
          updatedAt: effectiveTs,
        ),
      );
    }

    final workCandidates = <_JournalCandidate>[];
    final videoCandidates = <_JournalCandidate>[];
    final subtitleCandidates = <_JournalCandidate>[];
    final tombstoneCandidates = <_JournalCandidate>[];

    if (sharedIds.isNotEmpty) {
      final allMountFiles = await (db.select(
        db.libraryFiles,
      )..where((t) => t.mountId.isIn(sharedIds) & t.matchState.isNotValue(LibraryMatchStates.ignored))).get();
      final filesById = <int, LibraryFileRow>{for (final f in allMountFiles) f.id: f};
      final scopedFiles = effectivePrefixes == null
          ? allMountFiles
          : [for (final f in allMountFiles) if (pathInScope(f.path)) f];

      final itemsCache = <int, LibraryItemRow>{};
      Future<LibraryItemRow?> tryLoadItem(int? id) async {
        if (id == null) return null;
        if (itemsCache.containsKey(id)) return itemsCache[id];
        final row = await (db.select(db.libraryItems)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row != null) itemsCache[id] = row;
        return row;
      }

      final fileKeyByRowId = <int, String>{
        for (final f in allMountFiles) f.id: DeterministicKeys.generateFileId(sourceId: f.mountId, mountRelativePath: f.path),
      };

      final resolvedVideos = <({
        LibraryFileRow file,
        String fileId,
        LibraryItemRow? item,
        LibraryItemRow? workItem,
        String? workKey,
      })>[];
      final workItemsToCheck = <String, ({LibraryItemRow workItem, int rank})>{};
      final survivingFileIdsByMount = <String, Set<String>>{for (final id in sharedIds) id: <String>{}};

      for (final file in scopedFiles) {
        final fileId = fileKeyByRowId[file.id]!;
        survivingFileIdsByMount[file.mountId]?.add(fileId);
        if (file.role != LibraryFileRoles.video) continue;

        final item = await tryLoadItem(file.itemId);
        LibraryItemRow? workItem;
        if (item != null) {
          if (item.kind == LibraryKinds.movie) {
            workItem = item;
          } else if (item.kind == LibraryKinds.episode || item.kind == LibraryKinds.season) {
            workItem = await tryLoadItem(item.showId ?? item.parentId);
          }
        }
        final workKey = await _resolveSyncWorkKey(workItem: workItem, repFile: file);
        final workRank = workItem != null ? MatchStatusRank.fromItem(workItem) : MatchStatusRank.fromFile(file);
        if (workItem != null && workKey != null) {
          workItemsToCheck.putIfAbsent(workKey, () => (workItem: workItem!, rank: workRank));
        }
        resolvedVideos.add((
          file: file,
          fileId: fileId,
          item: item,
          workItem: workItem,
          workKey: workKey,
        ));
      }

      final existingWorks = await syncStore.journal.getEntriesForType(
        SyncLocalStore.typeWork,
        workItemsToCheck.keys,
      );
      for (final entry in workItemsToCheck.entries) {
        final workKey = entry.key;
        final workItem = entry.value.workItem;
        final rank = entry.value.rank;
        final existing = existingWorks[workKey];
        final initialTs = workItem.updatedAt > 0 ? workItem.updatedAt : calibratedNow;
        final payload = await _buildWorkPayload(
          workItem,
          workKey: workKey,
          workRank: rank,
          updatedAt: existing?.clientUpdatedAt ?? initialTs,
        );
        final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWork, payload);
        if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

        final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : initialTs;
        payload['client_updated_at'] = effectiveTs;
        workCandidates.add(
          _JournalCandidate(
            entityType: SyncLocalStore.typeWork,
            entityKey: workKey,
            workKey: workKey,
            payload: payload,
            hash: hash,
            updatedAt: effectiveTs,
          ),
        );
      }

      final scopedFileIds = [for (final f in scopedFiles) fileKeyByRowId[f.id]!];
      final existingFiles = await syncStore.journal.getEntriesForType(
        SyncLocalStore.typeFile,
        scopedFileIds,
      );

      for (final rv in resolvedVideos) {
        final existing = existingFiles[rv.fileId];
        final initialTs = (rv.file.modifiedAt != null && rv.file.modifiedAt! > 0)
            ? rv.file.modifiedAt!
            : (rv.file.addedAt > 0 ? rv.file.addedAt : calibratedNow);
        final payload = _buildVideoFilePayload(
          rv.file,
          fileId: rv.fileId,
          workKey: rv.workKey,
          item: rv.item,
          workItem: rv.workItem,
          updatedAt: existing?.clientUpdatedAt ?? initialTs,
        );
        final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, payload);
        if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

        final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : initialTs;
        payload['client_updated_at'] = effectiveTs;
        videoCandidates.add(
          _JournalCandidate(
            entityType: SyncLocalStore.typeFile,
            entityKey: rv.fileId,
            sourceId: rv.file.mountId,
            relativePath: payload['relative_path'] as String?,
            workKey: rv.workKey,
            payload: payload,
            hash: hash,
            updatedAt: effectiveTs,
          ),
        );
      }

      for (final file in scopedFiles) {
        if (file.role != LibraryFileRoles.subtitle) continue;
        final owner = file.ownerFileId == null ? null : filesById[file.ownerFileId];
        final ownerFileId = owner == null ? null : fileKeyByRowId[owner.id];
        final fileId = fileKeyByRowId[file.id]!;
        final existing = existingFiles[fileId];
        final initialTs = (file.modifiedAt != null && file.modifiedAt! > 0)
            ? file.modifiedAt!
            : (file.addedAt > 0 ? file.addedAt : calibratedNow);
        final payload = _buildSubtitleFilePayload(
          file,
          fileId: fileId,
          ownerFileId: ownerFileId,
          updatedAt: existing?.clientUpdatedAt ?? initialTs,
        );
        final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, payload);
        if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

        final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : initialTs;
        payload['client_updated_at'] = effectiveTs;
        subtitleCandidates.add(
          _JournalCandidate(
            entityType: SyncLocalStore.typeFile,
            entityKey: fileId,
            sourceId: file.mountId,
            relativePath: payload['relative_path'] as String?,
            payload: payload,
            hash: hash,
            updatedAt: effectiveTs,
          ),
        );
      }

      if (allowTombstones) {
        for (final mountId in sharedIds) {
          final journalFiles = await syncStore.journal.getActiveFilesForMount(
            mountId,
            directoryPrefixes: effectivePrefixes,
          );
          final surviving = survivingFileIdsByMount[mountId] ?? const <String>{};
          for (final jf in journalFiles) {
            if (surviving.contains(jf.entityKey)) continue;
            final delTs = SyncLocalStore.computeNextHlc(calibratedNow, jf.clientUpdatedAt);
            final delPayload = <String, Object?>{
              'file_id': jf.entityKey,
              'source_id': mountId,
              if (jf.relativePath != null) 'relative_path': jf.relativePath,
              'is_deleted': true,
              'client_updated_at': delTs,
            };
            tombstoneCandidates.add(
              _JournalCandidate(
                entityType: SyncLocalStore.typeFile,
                entityKey: jf.entityKey,
                sourceId: mountId,
                relativePath: jf.relativePath,
                workKey: jf.workKey,
                payload: delPayload,
                hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, delPayload),
                updatedAt: delTs,
                isDeleted: true,
              ),
            );
          }
        }
      }
    }

    // Handle mounts that were deleted completely when running a full catalog reconciliation.
    final deletedSourceTombstones = <_JournalCandidate>[];
    if (allowTombstones && mountIds == null && effectivePrefixes == null) {
      final journalSources = await syncStore.journal.getEntriesByType(SyncLocalStore.typeSource, onlyActive: true);
      for (final js in journalSources) {
        if (sharedIds.contains(js.entityKey)) continue;
        final orphanFiles = await syncStore.journal.getActiveFilesForMount(js.entityKey);
        for (final jf in orphanFiles) {
          final delTs = SyncLocalStore.computeNextHlc(calibratedNow, jf.clientUpdatedAt);
          final delPayload = <String, Object?>{
            'file_id': jf.entityKey,
            'source_id': js.entityKey,
            if (jf.relativePath != null) 'relative_path': jf.relativePath,
            'is_deleted': true,
            'client_updated_at': delTs,
          };
          tombstoneCandidates.add(
            _JournalCandidate(
              entityType: SyncLocalStore.typeFile,
              entityKey: jf.entityKey,
              sourceId: js.entityKey,
              relativePath: jf.relativePath,
              workKey: jf.workKey,
              payload: delPayload,
              hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, delPayload),
              updatedAt: delTs,
              isDeleted: true,
            ),
          );
        }
        final srcTs = SyncLocalStore.computeNextHlc(calibratedNow, js.clientUpdatedAt);
        final srcPayload = <String, Object?>{
          'source_id': js.entityKey,
          'is_deleted': true,
          'client_updated_at': srcTs,
        };
        deletedSourceTombstones.add(
          _JournalCandidate(
            entityType: SyncLocalStore.typeSource,
            entityKey: js.entityKey,
            sourceId: js.entityKey,
            payload: srcPayload,
            hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeSource, srcPayload),
            updatedAt: srcTs,
            isDeleted: true,
          ),
        );
      }
    }

    final stateCandidates = includeWorkStates
        ? await _collectChangedWorkStateCandidates(calibratedNow: calibratedNow)
        : const <_JournalCandidate>[];

    final ordered = <_JournalCandidate>[
      ...sourceCandidates,
      ...workCandidates,
      ...videoCandidates,
      ...subtitleCandidates,
      ...stateCandidates,
      ...tombstoneCandidates,
      ...deletedSourceTombstones,
    ];

    var totalWritten = ordered.length;
    if (ordered.isNotEmpty) {
      await _commitJournalCandidates(ordered, originDeviceId: deviceId, originEpoch: epoch);
    }

    totalWritten += await _tombstoneOrphanedRawWorks(
      calibratedNow: calibratedNow,
      deviceId: deviceId,
      epoch: epoch,
    );
    return totalWritten;
  }

  Future<int> _reconcileWorkStatesInternal() async {
    final calibratedNow = await syncStore.calibratedNowMs();
    final deviceId = await syncStore.getOrCreateDeviceId();
    final epoch = await syncStore.getOrCreateSyncEpoch();
    final candidates = await _collectChangedWorkStateCandidates(calibratedNow: calibratedNow);
    if (candidates.isEmpty) return 0;
    await _commitJournalCandidates(candidates, originDeviceId: deviceId, originEpoch: epoch);
    return candidates.length;
  }

  Future<List<_JournalCandidate>> _collectChangedWorkStateCandidates({required int calibratedNow}) async {
    final skipStore = WorkSkipSettingsStore(db);
    final stateStore = LibraryWatchStateStore(db);
    final allStates = await (db.select(
      db.workWatchStates,
    )..where((t) => t.source.equals(WorkIdentity.localSource))).get();

    final seenWorkPrefs = <String, WorkIdentity>{};
    final prefUpdatedHints = <String, int>{};
    final progressPayloads = <String, ({Map<String, Object?> payload, int updatedAt, String workKey})>{};

    for (final st in allStates) {
      final workKey = '${st.provider}:${st.kind}:${st.externalId}';
      seenWorkPrefs.putIfAbsent(
        workKey,
        () => WorkIdentity(source: st.source, kind: st.kind, provider: st.provider, externalId: st.externalId),
      );
      final prevHint = prefUpdatedHints[workKey] ?? 0;
      if (st.updatedAt > prevHint) prefUpdatedHints[workKey] = st.updatedAt;
      if (st.kind == LibraryKinds.show && (st.seasonNumber < 0 || st.episodeNumber < 0)) {
        continue;
      }

      final progressKey = DeterministicKeys.generateProgressKey(
        workKey: workKey,
        kind: st.kind,
        seasonNum: st.seasonNumber,
        episodeNum: st.episodeNumber,
      );
      final initialTs = st.updatedAt > 0 ? st.updatedAt : calibratedNow;
      progressPayloads[progressKey] = (
        workKey: workKey,
        updatedAt: initialTs,
        payload: {
          'progress_key': progressKey,
          'work_key': workKey,
          'season_num': st.seasonNumber,
          'episode_num': st.episodeNumber,
          'position_ms': st.positionMs,
          'duration_ms': st.durationMs ?? 0,
          'watched': st.watched,
          'play_count': st.playCount,
          'last_played_at': st.lastPlayedAt,
          'client_updated_at': initialTs,
        },
      );
    }

    final skipSettings = await (db.select(
      db.librarySettings,
    )..where((t) => t.key.like('work-skip:${WorkIdentity.localSource}:%'))).get();
    for (final row in skipSettings) {
      final parts = row.key.substring('work-skip:'.length).split(':');
      if (parts.length < 4) continue;
      final identity = WorkIdentity(
        source: parts[0],
        kind: parts[1],
        provider: parts[2],
        externalId: parts.sublist(3).join(':'),
      );
      final workKey = '${identity.provider}:${identity.kind}:${identity.externalId}';
      seenWorkPrefs.putIfAbsent(workKey, () => identity);
      prefUpdatedHints.putIfAbsent(workKey, () => calibratedNow);
    }

    final existingPrefs = await syncStore.journal.getEntriesForType(
      SyncLocalStore.typeWorkPref,
      seenWorkPrefs.keys,
    );
    final existingProgress = await syncStore.journal.getEntriesForType(
      SyncLocalStore.typeWatchProgress,
      progressPayloads.keys,
    );

    final out = <_JournalCandidate>[];
    for (final entry in seenWorkPrefs.entries) {
      final workKey = entry.key;
      final identity = entry.value;
      final skip = await skipStore.read(identity);
      final wholeState = await stateStore.read(identity.stateKey());
      final existing = existingPrefs[workKey];
      final isFavorite = wholeState?.favorite ?? false;
      final isHidden = wholeState?.hiddenFromContinue ?? false;
      final hasNonDefaultSkip =
          skip.introEnabled ||
          skip.introStartMs != 0 ||
          skip.introEndMs != 0 ||
          skip.creditsEnabled ||
          skip.creditsDurationMs != 0 ||
          skip.creditsResumeBeforeEndMs != 0;
      if (existing == null && !hasNonDefaultSkip && !isFavorite && !isHidden) {
        continue;
      }
      final initialTs = wholeState?.updatedAt ?? prefUpdatedHints[workKey] ?? calibratedNow;
      final payload = <String, Object?>{
        'work_key': workKey,
        'intro_enabled': skip.introEnabled,
        'intro_start_ms': skip.introStartMs,
        'intro_end_ms': skip.introEndMs,
        'credits_enabled': skip.creditsEnabled,
        'credits_from_end_ms': skip.creditsDurationMs,
        'keep_easter_egg_ms': skip.creditsResumeBeforeEndMs,
        'is_favorite': isFavorite,
        'hidden_from_continue': isHidden,
        'client_updated_at': initialTs,
      };
      final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWorkPref, payload);
      if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

      final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : initialTs;
      payload['client_updated_at'] = effectiveTs;
      out.add(
        _JournalCandidate(
          entityType: SyncLocalStore.typeWorkPref,
          entityKey: workKey,
          workKey: workKey,
          payload: payload,
          hash: hash,
          updatedAt: effectiveTs,
        ),
      );
    }

    for (final entry in progressPayloads.entries) {
      final progressKey = entry.key;
      final item = entry.value;
      final existing = existingProgress[progressKey];
      final payload = Map<String, Object?>.from(item.payload);
      final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWatchProgress, payload);
      if (existing != null && existing.payloadHash == hash && !existing.isDeleted) continue;

      final effectiveTs = existing != null ? SyncLocalStore.computeNextHlc(calibratedNow, existing.clientUpdatedAt) : item.updatedAt;
      payload['client_updated_at'] = effectiveTs;
      out.add(
        _JournalCandidate(
          entityType: SyncLocalStore.typeWatchProgress,
          entityKey: progressKey,
          workKey: item.workKey,
          payload: payload,
          hash: hash,
          updatedAt: effectiveTs,
        ),
      );
    }
    return out;
  }

  Future<void> _commitJournalCandidates(
    List<_JournalCandidate> candidates, {
    required String originDeviceId,
    required String originEpoch,
  }) async {
    if (candidates.isEmpty) return;
    await db.transaction(() async {
      final firstSeq = await syncStore.allocLocalSeqRange(candidates.length);
      for (var i = 0; i < candidates.length; i++) {
        final c = candidates[i];
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: c.entityType,
            entityKey: c.entityKey,
            sourceId: c.sourceId,
            relativePath: c.relativePath,
            workKey: c.workKey,
            localSeq: firstSeq + i,
            payloadHash: c.hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(c.entityType, c.payload),
            clientUpdatedAt: c.updatedAt,
            isDeleted: c.isDeleted,
            originDeviceId: originDeviceId,
            originEpoch: originEpoch,
          ),
        );
      }
    });
  }

  Future<int> _tombstoneOrphanedRawWorks({
    required int calibratedNow,
    required String deviceId,
    required String epoch,
  }) async {
    final orphans = await syncStore.journal.findOrphanedActiveRawWorks();
    if (orphans.isEmpty) return 0;
    final candidates = <_JournalCandidate>[];
    for (final orphan in orphans) {
      final decoded = orphan.decodePayload();
      final ts = SyncLocalStore.computeNextHlc(calibratedNow, orphan.clientUpdatedAt);
      final delPayload = <String, Object?>{
        'work_key': orphan.entityKey,
        'kind': decoded['kind'] ?? LibraryKinds.movie,
        'library_type': decoded['library_type'] ?? LibraryTypes.pending,
        'match_status': decoded['match_status'] ?? MatchStatusRank.pending,
        'metadata_json': const <String, Object?>{},
        'is_deleted': true,
        'client_updated_at': ts,
      };
      candidates.add(
        _JournalCandidate(
          entityType: SyncLocalStore.typeWork,
          entityKey: orphan.entityKey,
          workKey: orphan.entityKey,
          payload: delPayload,
          hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeWork, delPayload),
          updatedAt: ts,
          isDeleted: true,
        ),
      );
    }
    await _commitJournalCandidates(candidates, originDeviceId: deviceId, originEpoch: epoch);
    return candidates.length;
  }

  /// Builds a paginated delta bundle from `sync_journal` ordered strictly by `local_seq`,
  /// re-encrypting shared mount secrets on the fly with [encryptionKey].
  Future<({
    int currentMaxSeq,
    int nextSeq,
    bool hasMore,
    Map<String, Object?> userSettings,
    List<Map<String, Object?>> sources,
    List<Map<String, Object?>> works,
    List<Map<String, Object?>> files,
    List<Map<String, Object?>> workPrefs,
    List<Map<String, Object?>> watchProgress,
  })> buildDeltaBundle({
    required Uint8List encryptionKey,
    required int sinceSeq,
    int limit = 500,
    String? skipOriginDeviceId,
    String? skipOriginEpoch,
    bool skipEchoEvenFromZero = false,
  }) async {
    final page = await syncStore.journal.queryDelta(
      sinceSeq: sinceSeq,
      limit: limit,
      skipOriginDeviceId: skipOriginDeviceId,
      skipOriginEpoch: skipOriginEpoch,
      skipEchoEvenFromZero: skipEchoEvenFromZero,
    );

    final sources = <Map<String, Object?>>[];
    final works = <Map<String, Object?>>[];
    final files = <Map<String, Object?>>[];
    final workPrefs = <Map<String, Object?>>[];
    final watchProgress = <Map<String, Object?>>[];

    final mountsById = {for (final m in await mountManager.registry.list()) m.id: m};

    for (final entry in page.entries) {
      final payload = entry.decodePayload();
      switch (entry.entityType) {
        case SyncLocalStore.typeSource:
          if (!entry.isDeleted) {
            final mount = mountsById[entry.entityKey];
            if (mount != null && mount.secrets.isNotEmpty) {
              payload['encrypted_auth'] = await SyncCrypto.encryptPayload(
                jsonEncode(mount.secrets),
                encryptionKey,
              );
              payload['auth_updated_at'] = await syncStore.getAuthUpdatedAt(mount.id);
            }
          }
          sources.add(payload);
        case SyncLocalStore.typeWork:
          works.add(payload);
        case SyncLocalStore.typeFile:
          files.add(payload);
        case SyncLocalStore.typeWorkPref:
          workPrefs.add(payload);
        case SyncLocalStore.typeWatchProgress:
          watchProgress.add(payload);
      }
    }

    final scraperSettings = await LibrarySettingsStore(db).loadScraper();
    final userSettings = <String, Object?>{
      if (scraperSettings.tmdbImageBase.isNotEmpty) 'tmdb_image_base_url': scraperSettings.tmdbImageBase,
    };

    return (
      currentMaxSeq: page.maxSeq,
      nextSeq: page.nextSeq,
      hasMore: page.hasMore,
      userSettings: userSettings,
      sources: sources,
      works: works,
      files: files,
      workPrefs: workPrefs,
      watchProgress: watchProgress,
    );
  }

  /// Enqueues only incremental `sync_journal` entries past `cloud_pushed_seq`
  /// (excluding rows originating from `'cloud'`) into `SyncOutbox`.
  Future<int> enqueuePendingJournalForCloud({required Uint8List masterKey}) async {
    var cursor = await syncStore.getCloudPushedSeq();
    final mountsById = {for (final m in await mountManager.registry.list()) m.id: m};
    var enqueuedCount = 0;

    while (true) {
      final batch = await syncStore.journal.getPendingCloudEntries(afterSeq: cursor, limit: _outboxBatchSize);
      if (batch.isEmpty) break;
      await db.transaction(() async {
        for (final entry in batch) {
          final payload = entry.decodePayload();
          Map<String, String>? secrets;
          if (entry.entityType == SyncLocalStore.typeSource && !entry.isDeleted) {
            final mount = mountsById[entry.entityKey];
            if (mount != null && mount.secrets.isNotEmpty) {
              secrets = mount.secrets;
              payload['encrypted_auth'] = await SyncCrypto.encryptPayload(jsonEncode(secrets), masterKey);
              payload['auth_updated_at'] = await syncStore.getAuthUpdatedAt(mount.id);
            }
          }
          await syncStore.enqueue(
            entityType: entry.entityType,
            entityKey: entry.entityKey,
            updatedAt: entry.clientUpdatedAt,
            payload: payload,
            recordInJournal: false,
            writeOutbox: true,
            sourceSecrets: secrets,
          );
          enqueuedCount++;
        }
      });
      cursor = batch.last.localSeq;
    }

    if (enqueuedCount > 0) {
      await syncStore.saveCloudPushedSeq(cursor);
    } else {
      final maxSeq = await syncStore.journal.getMaxLocalSeq();
      if (maxSeq > cursor) {
        await syncStore.saveCloudPushedSeq(maxSeq);
      }
    }
    return enqueuedCount;
  }

  /// Removes stale remote-originated files missing from a complete `reset_required`
  /// rebuild snapshot while preserving local unsynced offline additions.
  Future<int> pruneStaleFilesAfterRebuild({
    required Map<String, Set<String>> survivingFileIdsByMount,
    required Set<String> authoritativeMountIds,
    required String remoteOriginId,
  }) async {
    if (authoritativeMountIds.isEmpty) return 0;
    var pruned = 0;
    final myDeviceId = await syncStore.getOrCreateDeviceId();
    final epoch = await syncStore.getOrCreateSyncEpoch();
    final calibratedNow = await syncStore.calibratedNowMs();
    final tombstones = <_JournalCandidate>[];

    await db.transaction(() async {
      for (final mountId in authoritativeMountIds) {
        final surviving = survivingFileIdsByMount[mountId] ?? const <String>{};
        final localFiles = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals(mountId))).get();
        final journalActive = await syncStore.journal.getActiveFilesForMount(mountId);
        final journalByKey = {for (final j in journalActive) j.entityKey: j};

        for (final file in localFiles) {
          final fileId = DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: file.path);
          if (surviving.contains(fileId)) continue;
          final jEntry = journalByKey[fileId];
          // Preserve offline local files that haven't originated from the remote source.
          if (jEntry != null && jEntry.originDeviceId == myDeviceId) continue;

          await (db.delete(db.libraryFiles)..where((t) => t.id.equals(file.id))).go();
          pruned++;
          if (jEntry != null) {
            final delTs = SyncLocalStore.computeNextHlc(calibratedNow, jEntry.clientUpdatedAt);
            final delPayload = <String, Object?>{
              'file_id': fileId,
              'source_id': mountId,
              'relative_path': DeterministicKeys.normalizeMountPath(file.path),
              'is_deleted': true,
              'client_updated_at': delTs,
            };
            tombstones.add(
              _JournalCandidate(
                entityType: SyncLocalStore.typeFile,
                entityKey: fileId,
                sourceId: mountId,
                relativePath: delPayload['relative_path'] as String?,
                workKey: jEntry.workKey,
                payload: delPayload,
                hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, delPayload),
                updatedAt: delTs,
                isDeleted: true,
              ),
            );
          }
        }
      }
      if (pruned > 0) {
        await repo.pruneEmptyTitles();
      }
    });

    if (tombstones.isNotEmpty) {
      await _commitJournalCandidates(tombstones, originDeviceId: myDeviceId, originEpoch: epoch);
      await _tombstoneOrphanedRawWorks(calibratedNow: calibratedNow, deviceId: myDeviceId, epoch: epoch);
      _invalidateSignatureCache();
    }
    return pruned;
  }

  /// Exports shared mounts, works, files, skip preferences, and watch progress
  /// to `SyncOutbox` so a newly joined device receives a full zero-scan index.
  Future<void> enqueueSharedCatalog({
    required Uint8List masterKey,
    Set<String>? mountIds,
    bool includeAllWorkStates = true,
  }) async {
    await reconcileCatalogToJournal(
      mountIds: mountIds,
      allowTombstones: mountIds == null,
      includeWorkStates: includeAllWorkStates,
    );
    await enqueuePendingJournalForCloud(masterKey: masterKey);
  }

  /// Builds an E2EE full snapshot bundle for legacy `/lan/v1/sync/snapshot`
  /// compatibility without mutating `SyncOutbox`.
  Future<Map<String, Object?>> buildSnapshotBundle({required Uint8List encryptionKey}) async {
    await ensureJournalUpToDate();
    final delta = await buildDeltaBundle(encryptionKey: encryptionKey, sinceSeq: 0, limit: 1 << 30);
    return {
      'server_time_ms': _nowMs(),
      'user_settings': delta.userSettings,
      'sources': delta.sources,
      'works': delta.works,
      'files': delta.files,
      'work_prefs': delta.workPrefs,
      'watch_progress': delta.watchProgress,
    };
  }

  static (String?, String?) _primaryProviderAndId(LibraryItemRow item) {
    if (item.tmdbId != null && item.tmdbId!.isNotEmpty) return ('tmdb', item.tmdbId);
    if (item.bangumiId != null && item.bangumiId!.isNotEmpty) return ('bangumi', item.bangumiId);
    if (item.imdbId != null && item.imdbId!.isNotEmpty) return ('imdb', item.imdbId);
    return (null, null);
  }

  Future<String?> _resolveSyncWorkKey({LibraryItemRow? workItem, required LibraryFileRow repFile}) async {
    if (workItem == null) {
      return DeterministicKeys.generateWorkKey(
        matchStatus: MatchStatusRank.pending,
        kind: LibraryKinds.movie,
        fileName: StoragePath.name(repFile.path),
        fileSize: repFile.size ?? 0,
      );
    }
    final (provider, extId) = _primaryProviderAndId(workItem);
    final matchStatus = MatchStatusRank.fromItem(workItem);
    if (matchStatus >= MatchStatusRank.matched && provider != null && extId != null) {
      return DeterministicKeys.generateWorkKey(
        matchStatus: matchStatus,
        kind: workItem.kind,
        provider: provider,
        externalId: extId,
        fileName: StoragePath.name(repFile.path),
        fileSize: repFile.size ?? 0,
      );
    }
    if (workItem.kind == LibraryKinds.show) {
      final hash = sha256.convert(utf8.encode('show:${workItem.sortTitle}')).toString().substring(0, 24);
      return 'raw:$hash';
    }
    return DeterministicKeys.generateWorkKey(
      matchStatus: matchStatus,
      kind: workItem.kind,
      provider: provider,
      externalId: extId,
      fileName: StoragePath.name(repFile.path),
      fileSize: repFile.size ?? 0,
    );
  }

  Future<void> _restoreTouchedRootItems(Set<int> touchedItemIds) async {
    if (touchedItemIds.isEmpty) return;
    final rows = await (db.select(db.libraryItems)..where((t) => t.id.isIn(touchedItemIds))).get();
    final rootIds = <int>{};
    for (final item in rows) {
      if (item.kind == LibraryKinds.episode || item.kind == LibraryKinds.season) {
        rootIds.add(item.showId ?? item.parentId ?? item.id);
      } else {
        rootIds.add(item.id);
      }
    }
    final watchStates = LibraryWatchStateStore(db);
    for (final rootId in rootIds) {
      await watchStates.restoreItemAndChildren(rootId);
    }
  }

  static List<({List<Map<String, dynamic>> works, List<Map<String, dynamic>> files})> _buildStage3Chunks(
    List<Map<String, dynamic>> works,
    List<Map<String, dynamic>> effectiveFiles,
  ) {
    final workKeysInBatch = <String>{
      for (final w in works)
        if (w['work_key'] is String && (w['work_key'] as String).isNotEmpty) w['work_key'] as String,
    };

    final videos = <Map<String, dynamic>>[];
    final subtitlesByOwner = <String, List<Map<String, dynamic>>>{};
    final unownedSubtitles = <Map<String, dynamic>>[];
    for (final f in effectiveFiles) {
      if (f['role'] == LibraryFileRoles.subtitle) {
        final owner = f['owner_file_id'] as String?;
        if (owner != null && owner.isNotEmpty) {
          subtitlesByOwner.putIfAbsent(owner, () => []).add(f);
        } else {
          unownedSubtitles.add(f);
        }
      } else {
        videos.add(f);
      }
    }

    final videosByWorkKey = <String, List<Map<String, dynamic>>>{};
    final remainingVideos = <Map<String, dynamic>>[];
    for (final v in videos) {
      final wk = v['work_key'] as String?;
      if (wk != null && workKeysInBatch.contains(wk)) {
        videosByWorkKey.putIfAbsent(wk, () => []).add(v);
      } else {
        remainingVideos.add(v);
      }
    }

    void appendOwnedSubtitles(List<Map<String, dynamic>> targetFiles, List<Map<String, dynamic>> addedVideos) {
      for (final v in addedVideos) {
        final fileId = v['file_id'] as String?;
        if (fileId == null || fileId.isEmpty) continue;
        final owned = subtitlesByOwner.remove(fileId);
        if (owned != null && owned.isNotEmpty) {
          targetFiles.addAll(owned);
        }
      }
    }

    final chunks = <({List<Map<String, dynamic>> works, List<Map<String, dynamic>> files})>[];
    var curWorks = <Map<String, dynamic>>[];
    var curFiles = <Map<String, dynamic>>[];

    void flushCurrentChunk() {
      if (curWorks.isEmpty && curFiles.isEmpty) return;
      chunks.add((works: curWorks, files: curFiles));
      curWorks = <Map<String, dynamic>>[];
      curFiles = <Map<String, dynamic>>[];
    }

    for (final w in works) {
      final wk = w['work_key'] as String?;
      final wVideos =
          wk != null ? (videosByWorkKey.remove(wk) ?? const <Map<String, dynamic>>[]) : const <Map<String, dynamic>>[];

      if (curWorks.isNotEmpty &&
          (curWorks.length >= workChunkSize ||
              curFiles.length + math.min(wVideos.length, fileChunkSize) > fileChunkSize)) {
        flushCurrentChunk();
      }

      curWorks.add(w);
      if (wVideos.length <= fileChunkSize) {
        curFiles.addAll(wVideos);
        appendOwnedSubtitles(curFiles, wVideos);
      } else {
        final firstBatch = wVideos.sublist(0, fileChunkSize);
        curFiles.addAll(firstBatch);
        appendOwnedSubtitles(curFiles, firstBatch);
        flushCurrentChunk();
        for (var i = fileChunkSize; i < wVideos.length; i += fileChunkSize) {
          final batch = wVideos.sublist(i, math.min(i + fileChunkSize, wVideos.length));
          curFiles.addAll(batch);
          appendOwnedSubtitles(curFiles, batch);
          flushCurrentChunk();
        }
      }

      if (curWorks.length >= workChunkSize || curFiles.length >= fileChunkSize) {
        flushCurrentChunk();
      }
    }
    flushCurrentChunk();

    for (final leftover in videosByWorkKey.values) {
      remainingVideos.addAll(leftover);
    }
    for (var i = 0; i < remainingVideos.length; i += fileChunkSize) {
      final batch = remainingVideos.sublist(i, math.min(i + fileChunkSize, remainingVideos.length));
      final chunkFiles = <Map<String, dynamic>>[...batch];
      appendOwnedSubtitles(chunkFiles, batch);
      chunks.add((works: const [], files: chunkFiles));
    }

    final trailingSubs = <Map<String, dynamic>>[
      for (final list in subtitlesByOwner.values) ...list,
      ...unownedSubtitles,
    ];
    for (var i = 0; i < trailingSubs.length; i += fileChunkSize) {
      final batch = trailingSubs.sublist(i, math.min(i + fileChunkSize, trailingSubs.length));
      chunks.add((works: const [], files: batch));
    }

    return chunks;
  }

  /// Applies one pull batch progressively across bounded micro-transactions so
  /// synced titles and progress render incrementally without blocking the UI.
  /// Returns the count of processed entities.
  Future<int> applyPullBatch({
    required Uint8List masterKey,
    required List<Map<String, dynamic>> sources,
    required List<Map<String, dynamic>> works,
    required List<Map<String, dynamic>> files,
    required List<Map<String, dynamic>> workPrefs,
    required List<Map<String, dynamic>> watchProgress,
    required Map<String, Object?> userSettings,
    required int nextSeq,
    bool isFinalPage = true,
    bool updateCloudCursor = true,
    bool deterministicP2pSourceTieBreak = false,
    String? originDeviceId,
    String? originEpoch,
    Map<String, int>? sharedWorkItemCache,
    void Function(int processed, int total)? onProgress,
    FutureOr<void> Function()? onChunkApplied,
  }) async {
    var changes = 0;
    var dbMutations = 0;
    final totalEntities = sources.length + works.length + files.length + workPrefs.length + watchProgress.length;
    var processedEntities = 0;
    if (totalEntities > 0) {
      onProgress?.call(0, totalEntities);
    }

    final myDeviceId = await syncStore.getOrCreateDeviceId();
    final myEpoch = await syncStore.getOrCreateSyncEpoch();
    final remoteOriginId = (originDeviceId != null && originDeviceId.isNotEmpty) ? originDeviceId : 'remote';
    final remoteOriginEpoch = (originEpoch != null && originEpoch.isNotEmpty) ? originEpoch : remoteOriginId;

    final imageBase = userSettings['tmdb_image_base_url'];
    if (imageBase is String && imageBase.trim().isNotEmpty) {
      final settingsStore = LibrarySettingsStore(db);
      final current = await settingsStore.loadScraper();
      if (current.tmdbImageBase != imageBase.trim()) {
        await settingsStore.saveScraper(
          ScraperSettings(
            tmdbApiKey: current.tmdbApiKey,
            tmdbApiBase: current.tmdbApiBase,
            tmdbImageBase: imageBase.trim(),
            language: current.language,
            proxy: current.proxy,
            bangumiEnabled: current.bangumiEnabled,
          ),
        );
      }
    }

    if (onPreemptMountScan != null && sources.isNotEmpty) {
      await _preemptConflictingScans(sources, deterministicP2pSourceTieBreak: deterministicP2pSourceTieBreak);
    }

    final persistedRemaps = await syncStore.loadRemappedSources();
    final localWinnerRemaps = <String, String>{};
    final workItemByKey = sharedWorkItemCache ?? <String, int>{};
    final rowIdBySyncFileId = <String, int>{};

    // Stage 1: Merge shared mounts & canonical source deduplication first.
    if (sources.isNotEmpty) {
      final rehomedMounts = <(String, String)>[];
      final deletedMountIds = <String>[];
      var sourceProcessed = 0;
      var sourceMutations = 0;
      await db.transaction(() async {
        final res = await _applyIncomingSources(
          sources,
          masterKey: masterKey,
          rehomedMounts: rehomedMounts,
          deletedMountIds: deletedMountIds,
          deterministicP2pSourceTieBreak: deterministicP2pSourceTieBreak,
          localWinnerRemaps: localWinnerRemaps,
          myDeviceId: myDeviceId,
          myEpoch: myEpoch,
          remoteOriginId: remoteOriginId,
          remoteOriginEpoch: remoteOriginEpoch,
        );
        sourceProcessed = res.processed;
        sourceMutations = res.mutations;
      });
      changes += sourceProcessed;
      dbMutations += sourceMutations;
      for (final (oldId, newId) in rehomedMounts) {
        await mountManager.dropCachedDriver(oldId);
        await syncStore.rekeyOutboxForRemappedSource(oldId, newId);
      }
      for (final deletedId in deletedMountIds) {
        await mountManager.dropCachedDriver(deletedId);
      }
      processedEntities += sources.length;
      onProgress?.call(processedEntities, totalEntities);
      if (sourceMutations > 0) {
        await onChunkApplied?.call();
      }
    }

    final effectiveRemaps = <String, String>{...persistedRemaps, ...localWinnerRemaps};
    final effectiveFiles = effectiveRemaps.isEmpty ? files : _remapIncomingFiles(files, effectiveRemaps);
    final stage3Chunks = _buildStage3Chunks(works, effectiveFiles);

    if (sources.isNotEmpty && (workPrefs.isNotEmpty || watchProgress.isNotEmpty || stage3Chunks.isNotEmpty)) {
      await Future<void>.delayed(Duration.zero);
    }

    // Stage 2: Write work preferences & watch progress in chunks BEFORE works/files so
    // existing works update immediately and new works/episodes inherit states as they land.
    for (var i = 0; i < workPrefs.length; i += stateChunkSize) {
      final slice = workPrefs.sublist(i, math.min(i + stateChunkSize, workPrefs.length));
      final chunkTouchedIds = <int>{};
      var chunkProcessed = 0;
      var chunkMutations = 0;
      await db.transaction(() async {
        final res = await _applyIncomingWorkPrefs(
          slice,
          touchedItemIds: chunkTouchedIds,
          remoteOriginId: remoteOriginId,
          remoteOriginEpoch: remoteOriginEpoch,
        );
        chunkProcessed = res.processed;
        chunkMutations = res.mutations;
        if (chunkTouchedIds.isNotEmpty) {
          await _restoreTouchedRootItems(chunkTouchedIds);
        }
      });
      changes += chunkProcessed;
      dbMutations += chunkMutations;
      processedEntities += slice.length;
      onProgress?.call(processedEntities, totalEntities);
      if (chunkTouchedIds.isNotEmpty && chunkMutations > 0) {
        await onChunkApplied?.call();
      }
      final hasMore = i + stateChunkSize < workPrefs.length || watchProgress.isNotEmpty || stage3Chunks.isNotEmpty;
      if (hasMore) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    for (var i = 0; i < watchProgress.length; i += stateChunkSize) {
      final slice = watchProgress.sublist(i, math.min(i + stateChunkSize, watchProgress.length));
      final chunkTouchedIds = <int>{};
      var chunkProcessed = 0;
      var chunkMutations = 0;
      await db.transaction(() async {
        final res = await _applyIncomingWatchProgress(
          slice,
          touchedItemIds: chunkTouchedIds,
          remoteOriginId: remoteOriginId,
          remoteOriginEpoch: remoteOriginEpoch,
        );
        chunkProcessed = res.processed;
        chunkMutations = res.mutations;
        if (chunkTouchedIds.isNotEmpty) {
          await _restoreTouchedRootItems(chunkTouchedIds);
        }
      });
      changes += chunkProcessed;
      dbMutations += chunkMutations;
      processedEntities += slice.length;
      onProgress?.call(processedEntities, totalEntities);
      if (chunkTouchedIds.isNotEmpty && chunkMutations > 0) {
        await onChunkApplied?.call();
      }
      final hasMore = i + stateChunkSize < watchProgress.length || stage3Chunks.isNotEmpty;
      if (hasMore) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // Stage 3: Merge works & co-located video/subtitle files in bounded micro-transactions.
    for (var i = 0; i < stage3Chunks.length; i++) {
      final chunk = stage3Chunks[i];
      final chunkTouchedIds = <int>{};
      var chunkProcessed = 0;
      var chunkMutations = 0;
      await db.transaction(() async {
        if (chunk.works.isNotEmpty) {
          final res = await _applyIncomingWorks(
            chunk.works,
            workItemByKey: workItemByKey,
            touchedItemIds: chunkTouchedIds,
            myDeviceId: myDeviceId,
            myEpoch: myEpoch,
            remoteOriginId: remoteOriginId,
            remoteOriginEpoch: remoteOriginEpoch,
          );
          chunkProcessed += res.processed;
          chunkMutations += res.mutations;
        }
        if (chunk.files.isNotEmpty) {
          final res = await _applyIncomingFiles(
            chunk.files,
            workItemByKey: workItemByKey,
            touchedItemIds: chunkTouchedIds,
            rowIdBySyncFileId: rowIdBySyncFileId,
            myDeviceId: myDeviceId,
            myEpoch: myEpoch,
            remoteOriginId: remoteOriginId,
            remoteOriginEpoch: remoteOriginEpoch,
          );
          chunkProcessed += res.processed;
          chunkMutations += res.mutations;
        }
        if (chunkTouchedIds.isNotEmpty) {
          await _restoreTouchedRootItems(chunkTouchedIds);
        }
      });
      changes += chunkProcessed;
      dbMutations += chunkMutations;
      processedEntities += chunk.works.length + chunk.files.length;
      onProgress?.call(processedEntities, totalEntities);
      if (chunkMutations > 0) {
        await onChunkApplied?.call();
      }
      if (i + 1 < stage3Chunks.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // Finalization: prune orphans on the final page and advance cloud cursor after all chunks commit.
    if ((isFinalPage && dbMutations > 0) || updateCloudCursor) {
      await db.transaction(() async {
        if (isFinalPage && dbMutations > 0) {
          await repo.pruneEmptyTitles();
        }
        if (updateCloudCursor) {
          await syncStore.saveLastPullSeq(nextSeq);
        }
      });
    }

    if (isFinalPage && dbMutations > 0) {
      await _tombstoneOrphanedRawWorks(
        calibratedNow: await syncStore.calibratedNowMs(),
        deviceId: myDeviceId,
        epoch: myEpoch,
      );
    }

    if (dbMutations > 0) {
      _invalidateSignatureCache();
    }

    return changes;
  }

  /// Migrates all local references from [oldMountId] to [newMountId] inside an
  /// active DB transaction (or opens one) without triggering cascade file deletes.
  Future<void> rehomeLocalMountId({
    required String oldMountId,
    required String newMountId,
    StorageMount? targetMount,
    String? remoteCheckpoint,
    int? remoteFinishedAt,
  }) async {
    if (oldMountId == newMountId) return;
    await onPreemptMountScan?.call(oldMountId);
    await db.transaction(() async {
      await _rehomeMountTx(
        oldMountId: oldMountId,
        newMountId: newMountId,
        targetMount: targetMount,
        remoteCheckpoint: remoteCheckpoint,
        remoteFinishedAt: remoteFinishedAt,
      );
    });
    await mountManager.dropCachedDriver(oldMountId);
    await syncStore.rekeyOutboxForRemappedSource(oldMountId, newMountId);
    _invalidateSignatureCache();
  }

  Future<void> _preemptConflictingScans(
    List<Map<String, dynamic>> rawSources, {
    required bool deterministicP2pSourceTieBreak,
  }) async {
    final preemptCallback = onPreemptMountScan;
    if (preemptCallback == null) return;

    final currentMounts = await mountManager.registry.list();
    final byId = {for (final m in currentMounts) m.id: m};
    final byCanonical = {for (final m in currentMounts) DeterministicKeys.canonicalSourceKey(m): m};
    final toPreempt = <String>{};

    for (final src in rawSources) {
      final sourceId = src['source_id'] as String?;
      if (sourceId == null || sourceId.isEmpty) continue;

      if (src['is_deleted'] == true) {
        if (byId.containsKey(sourceId)) toPreempt.add(sourceId);
        continue;
      }

      final canonicalKey = src['canonical_key'] as String? ?? '';
      final existing = byId[sourceId] ?? (canonicalKey.isNotEmpty ? byCanonical[canonicalKey] : null);
      if (existing == null) continue;

      final remoteCreatedAt = (src['created_at'] as num?)?.toInt();
      if (existing.id != sourceId) {
        final remoteWins =
            !deterministicP2pSourceTieBreak ||
            _remoteSourceWinsTieBreak(remoteId: sourceId, remoteCreatedAt: remoteCreatedAt, local: existing);
        if (remoteWins) {
          toPreempt.add(existing.id);
          continue;
        }
      }

      final curScan = await (db.select(
        db.libraryScanStates,
      )..where((t) => t.mountId.equals(existing.id))).getSingleOrNull();
      final remoteCp = src['quark_checkpoint'] as String?;
      final remoteFinishedAt = (src['scan_finished_at'] as num?)?.toInt();
      final hasNewerCp =
          remoteCp != null &&
          remoteCp.isNotEmpty &&
          mergeQuarkCheckpoint(curScan?.quarkCheckpoint, remoteCp) != curScan?.quarkCheckpoint;
      final peerFinishedNewer =
          remoteFinishedAt != null &&
          remoteFinishedAt > 0 &&
          (curScan?.finishedAt == null || remoteFinishedAt > curScan!.finishedAt!) &&
          (curScan?.startedAt == null || remoteFinishedAt >= curScan!.startedAt!);
      if (hasNewerCp || peerFinishedNewer) {
        toPreempt.add(existing.id);
      }
    }

    for (final mountId in toPreempt) {
      await preemptCallback(mountId);
    }
  }

  Future<void> _persistSyncedScanState(
    String mountId, {
    String? mergedCheckpoint,
    int? oldFinishedAt,
    int? curFinishedAt,
    int? remoteFinishedAt,
  }) async {
    final maxLocal = math.max(oldFinishedAt ?? 0, curFinishedAt ?? 0);
    final fallbackRemote = mergedCheckpoint != null && mergedCheckpoint.isNotEmpty ? _nowMs() : 0;
    final effectiveFinishedAt = math.max(maxLocal, remoteFinishedAt ?? fallbackRemote);
    if (mergedCheckpoint == null && effectiveFinishedAt <= 0) return;
    await db
        .into(db.libraryScanStates)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(
            mountId: mountId,
            status: const Value('idle'),
            pending: const Value(null),
            lastError: const Value(null),
            finishedAt: effectiveFinishedAt > 0 ? Value(effectiveFinishedAt) : const Value.absent(),
            quarkCheckpoint: mergedCheckpoint != null ? Value(mergedCheckpoint) : const Value.absent(),
          ),
        );
  }

  Future<void> _rehomeMountTx({
    required String oldMountId,
    required String newMountId,
    StorageMount? targetMount,
    String? remoteCheckpoint,
    int? remoteFinishedAt,
  }) async {
    final oldMountRow = await (db.select(db.mounts)..where((t) => t.id.equals(oldMountId))).getSingleOrNull();
    final existingTargetRow = await (db.select(db.mounts)..where((t) => t.id.equals(newMountId))).getSingleOrNull();

    final effectiveMount =
        targetMount ??
        await mountManager.registry.get(oldMountId) ??
        await mountManager.registry.get(newMountId);
    if (effectiveMount != null) {
      final merged = effectiveMount.id == newMountId
          ? effectiveMount
          : StorageMount(
              id: newMountId,
              kind: effectiveMount.kind,
              displayName: effectiveMount.displayName,
              config: effectiveMount.config,
              secrets: effectiveMount.secrets,
              createdAt: effectiveMount.createdAt,
            );
      await mountManager.registry.upsert(merged);
    } else if (existingTargetRow == null && oldMountRow != null) {
      await db
          .into(db.mounts)
          .insertOnConflictUpdate(
            MountsCompanion.insert(
              id: newMountId,
              kind: oldMountRow.kind,
              displayName: oldMountRow.displayName,
              configJson: oldMountRow.configJson,
              secrets: Value(oldMountRow.secrets),
              createdAt: oldMountRow.createdAt,
            ),
          );
    }

    // Move files safely without colliding on unique (mount_id, path).
    final oldFiles = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals(oldMountId))).get();
    final targetFiles = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals(newMountId))).get();
    final targetByPath = {for (final f in targetFiles) f.path: f};
    final movedOrKeptPaths = <String>{};

    for (final oldFile in oldFiles) {
      final collision = targetByPath[oldFile.path];
      if (collision == null) {
        await (db.update(db.libraryFiles)..where((t) => t.id.equals(oldFile.id))).write(
          LibraryFilesCompanion(mountId: Value(newMountId)),
        );
        movedOrKeptPaths.add(oldFile.path);
      } else {
        await (db.update(db.libraryFiles)..where((t) => t.ownerFileId.equals(oldFile.id))).write(
          LibraryFilesCompanion(ownerFileId: Value(collision.id)),
        );
        if (collision.itemId == null && oldFile.itemId != null) {
          await (db.update(db.libraryFiles)..where((t) => t.id.equals(collision.id))).write(
            LibraryFilesCompanion(
              itemId: Value(oldFile.itemId),
              matchState: Value(oldFile.matchState),
              matchLocked: Value(oldFile.matchLocked),
            ),
          );
          movedOrKeptPaths.add(oldFile.path);
        }
        await (db.delete(db.libraryFiles)..where((t) => t.id.equals(oldFile.id))).go();
      }
    }

    // Migrate mount:<oldId>: artwork references.
    final oldPrefix = 'mount:$oldMountId:';
    final newPrefix = 'mount:$newMountId:';
    final items = await (db.select(db.libraryItems)
          ..where(
            (t) =>
                t.posterSource.like('$oldPrefix%') |
                t.backdropSource.like('$oldPrefix%') |
                t.logoSource.like('$oldPrefix%'),
          ))
        .get();
    for (final item in items) {
      await (db.update(db.libraryItems)..where((t) => t.id.equals(item.id))).write(
        LibraryItemsCompanion(
          posterSource: item.posterSource?.startsWith(oldPrefix) == true
              ? Value('$newPrefix${item.posterSource!.substring(oldPrefix.length)}')
              : const Value.absent(),
          backdropSource: item.backdropSource?.startsWith(oldPrefix) == true
              ? Value('$newPrefix${item.backdropSource!.substring(oldPrefix.length)}')
              : const Value.absent(),
          logoSource: item.logoSource?.startsWith(oldPrefix) == true
              ? Value('$newPrefix${item.logoSource!.substring(oldPrefix.length)}')
              : const Value.absent(),
        ),
      );
    }

    // Merge Quark checkpoints & scan completion baseline cleanly.
    final oldScan = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(oldMountId))).getSingleOrNull();
    final newScan = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(newMountId))).getSingleOrNull();
    var mergedCp = mergeQuarkCheckpoint(oldScan?.quarkCheckpoint, newScan?.quarkCheckpoint);
    mergedCp = mergeQuarkCheckpoint(mergedCp, remoteCheckpoint);
    await _persistSyncedScanState(
      newMountId,
      mergedCheckpoint: mergedCp,
      oldFinishedAt: oldScan?.finishedAt,
      curFinishedAt: newScan?.finishedAt,
      remoteFinishedAt: remoteFinishedAt,
    );
    await (db.delete(db.libraryScanStates)..where((t) => t.mountId.equals(oldMountId))).go();

    // Remove the superseded old Mount row last (zero foreign-key children remain).
    await (db.delete(db.mounts)..where((t) => t.id.equals(oldMountId))).go();

    // Rekey sync_journal entries under oldMountId so offline-added unique files
    // propagate under newMountId and late peers still learn about oldMountId -> newMountId.
    await syncStore.recordRemappedSource(oldMountId, newMountId);
    final oldJournalEntries = await syncStore.journal.getEntriesForSource(oldMountId);
    final oldFileIdToNewFileId = <String, String>{};
    final rekeyedEntries = <SyncJournalEntry>[];
    for (final entry in oldJournalEntries) {
      await syncStore.journal.deleteEntry(entry.entityType, entry.entityKey);
      if (entry.entityType == SyncLocalStore.typeFile && !entry.isDeleted && entry.relativePath != null) {
        final normPath = DeterministicKeys.normalizeMountPath(entry.relativePath!);
        final newFileId = DeterministicKeys.generateFileId(sourceId: newMountId, mountRelativePath: normPath);
        oldFileIdToNewFileId[entry.entityKey] = newFileId;
        if (!movedOrKeptPaths.contains(normPath)) continue;
        final existingTarget = await syncStore.journal.getEntry(SyncLocalStore.typeFile, newFileId);
        final payload = entry.decodePayload();
        payload['source_id'] = newMountId;
        payload['file_id'] = newFileId;
        final hash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, payload);
        if (existingTarget != null && existingTarget.payloadHash == hash && !existingTarget.isDeleted) {
          continue;
        }
        rekeyedEntries.add(
          entry.copyWith(
            sourceId: newMountId,
            relativePath: normPath,
            payloadHash: hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeFile, payload),
          ),
        );
      }
    }
    if (rekeyedEntries.isNotEmpty) {
      final myDeviceId = await syncStore.getOrCreateDeviceId();
      final myEpoch = await syncStore.getOrCreateSyncEpoch();
      final calibratedNow = await syncStore.calibratedNowMs();
      final firstSeq = await syncStore.allocLocalSeqRange(rekeyedEntries.length);
      for (var i = 0; i < rekeyedEntries.length; i++) {
        final base = rekeyedEntries[i];
        final payload = base.decodePayload();
        final newFileId = payload['file_id'] as String;
        final owner = payload['owner_file_id'] as String?;
        var effectiveHash = base.payloadHash;
        if (owner != null && oldFileIdToNewFileId.containsKey(owner)) {
          payload['owner_file_id'] = oldFileIdToNewFileId[owner];
          effectiveHash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, payload);
        }
        final updatedAt = SyncLocalStore.computeNextHlc(calibratedNow, base.clientUpdatedAt);
        payload['client_updated_at'] = updatedAt;
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeFile,
            entityKey: newFileId,
            sourceId: newMountId,
            relativePath: base.relativePath,
            workKey: base.workKey,
            localSeq: firstSeq + i,
            payloadHash: effectiveHash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeFile, payload),
            clientUpdatedAt: updatedAt,
            isDeleted: false,
            originDeviceId: myDeviceId,
            originEpoch: myEpoch,
          ),
        );
      }
    }
  }

  Future<({int processed, int mutations})> _applyIncomingSources(
    List<Map<String, dynamic>> rawSources, {
    required Uint8List masterKey,
    required List<(String, String)> rehomedMounts,
    required List<String> deletedMountIds,
    required bool deterministicP2pSourceTieBreak,
    required Map<String, String> localWinnerRemaps,
    required String myDeviceId,
    required String myEpoch,
    required String remoteOriginId,
    required String remoteOriginEpoch,
  }) async {
    var processed = 0;
    var mutations = 0;
    final currentMounts = await mountManager.registry.list();
    final byId = {for (final m in currentMounts) m.id: m};
    final byCanonical = {for (final m in currentMounts) DeterministicKeys.canonicalSourceKey(m): m};
    final existingJournalById = await syncStore.journal.getEntriesForType(
      SyncLocalStore.typeSource,
      [
        for (final src in rawSources)
          if (src['source_id'] is String) src['source_id'] as String,
      ],
    );

    for (final src in rawSources) {
      final sourceId = src['source_id'] as String?;
      if (sourceId == null || sourceId.isEmpty) continue;
      processed++;

      if (src['is_deleted'] == true) {
        final existingJ = existingJournalById[sourceId];
        final remoteUpdatedAt = (src['client_updated_at'] as num?)?.toInt() ?? _nowMs();
        if (existingJ != null && existingJ.isDeleted && existingJ.payloadHash == SyncJournalStore.computeEntityHash(SyncLocalStore.typeSource, src)) {
          continue;
        }
        if (byId.containsKey(sourceId)) {
          await (db.delete(db.mounts)..where((t) => t.id.equals(sourceId))).go();
          deletedMountIds.add(sourceId);
          mutations++;
        }
        for (final jf in await syncStore.journal.getActiveFilesForMount(sourceId)) {
          await syncStore.journal.deleteEntry(jf.entityType, jf.entityKey);
        }
        final seq = await syncStore.allocNextLocalSeq();
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeSource,
            entityKey: sourceId,
            sourceId: sourceId,
            localSeq: seq,
            payloadHash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeSource, {'is_deleted': true}),
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeSource, {
              'source_id': sourceId,
              'is_deleted': true,
              'client_updated_at': remoteUpdatedAt,
            }),
            clientUpdatedAt: remoteUpdatedAt,
            isDeleted: true,
            originDeviceId: remoteOriginId,
            originEpoch: remoteOriginEpoch,
          ),
        );
        continue;
      }

      final kind = _parseKind(src['protocol'] as String? ?? '');
      if (kind == null || kind == StorageKind.local) continue;

      final existingById = byId[sourceId];
      final canonicalKey = src['canonical_key'] as String? ?? '';
      final existingByCanonical = existingById ?? (canonicalKey.isNotEmpty ? byCanonical[canonicalKey] : null);

      final config = <String, Object?>{
        ..._mapOf(src['config_json']),
        if (src['fallback_url'] is String && (src['fallback_url'] as String).isNotEmpty)
          MountKeys.fallbackUrl: src['fallback_url'],
        MountKeys.isLanOnly: src['is_lan_only'] == true,
        if (src['include_paths'] is List && (src['include_paths'] as List).isNotEmpty)
          MountKeys.includePaths: [for (final p in src['include_paths'] as List) '$p'],
        if (src['exclude_paths'] is List && (src['exclude_paths'] as List).isNotEmpty)
          MountKeys.excludePaths: [for (final p in src['exclude_paths'] as List) '$p'],
      };

      var secrets = existingByCanonical?.secrets ?? const <String, String>{};
      final encryptedAuth = src['encrypted_auth'] as String? ?? '';
      final remoteAuthUpdatedAt = (src['auth_updated_at'] as num?)?.toInt() ?? 0;
      final localAuthUpdatedAt = existingByCanonical != null
          ? await syncStore.getAuthUpdatedAt(existingByCanonical.id)
          : 0;
      var localAuthContributed = false;
      if (encryptedAuth.isNotEmpty && (secrets.isEmpty || remoteAuthUpdatedAt >= localAuthUpdatedAt)) {
        try {
          final decryptedJson = await SyncCrypto.decryptPayload(encryptedAuth, masterKey);
          final decoded = jsonDecode(decryptedJson);
          if (decoded is Map) {
            secrets = {for (final entry in decoded.entries) '${entry.key}': '${entry.value}'};
            await syncStore.setAuthUpdatedAt(sourceId, remoteAuthUpdatedAt);
          }
        } catch (_) {
          // Keep existing local secrets if decryption fails cleanly.
        }
      } else if (secrets.isNotEmpty && (encryptedAuth.isEmpty || localAuthUpdatedAt > remoteAuthUpdatedAt)) {
        localAuthContributed = true;
        if (existingByCanonical != null && existingByCanonical.id != sourceId && localAuthUpdatedAt > 0) {
          await syncStore.setAuthUpdatedAt(sourceId, localAuthUpdatedAt);
        }
      }

      final remoteCreatedAt = (src['created_at'] as num?)?.toInt();
      final incomingCreatedAt =
          (existingByCanonical != null && existingByCanonical.id == sourceId)
              ? existingByCanonical.createdAt
              : (remoteCreatedAt != null && remoteCreatedAt > 0
                  ? DateTime.fromMillisecondsSinceEpoch(remoteCreatedAt)
                  : existingByCanonical?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(_nowMs()));

      final incomingMount = StorageMount(
        id: sourceId,
        kind: kind,
        displayName: (src['name'] as String?)?.trim().isNotEmpty == true ? src['name'] as String : kind.id,
        config: config,
        secrets: secrets,
        createdAt: incomingCreatedAt,
      );

      final incomingHash = SyncJournalStore.computeEntityHash(
        SyncLocalStore.typeSource,
        src.cast<String, Object?>(),
        rawSecrets: secrets,
      );
      final existingJ = existingJournalById[sourceId];
      if (existingById != null &&
          existingByCanonical?.id == sourceId &&
          existingJ != null &&
          existingJ.payloadHash == incomingHash &&
          !existingJ.isDeleted) {
        continue;
      }

      mutations++;
      final remoteCp = src['quark_checkpoint'] as String?;
      final remoteFinishedAt = (src['scan_finished_at'] as num?)?.toInt();
      var resolvedMountId = sourceId;
      var localMergedOrWon = localAuthContributed;
      var finalCp = remoteCp;
      var finalFinishedAt = remoteFinishedAt;

      if (existingByCanonical != null && existingByCanonical.id != sourceId) {
        final remoteWins = !deterministicP2pSourceTieBreak ||
            _remoteSourceWinsTieBreak(
              remoteId: sourceId,
              remoteCreatedAt: remoteCreatedAt,
              local: existingByCanonical,
            );
        if (remoteWins) {
          final oldScan = await (db.select(
            db.libraryScanStates,
          )..where((t) => t.mountId.equals(existingByCanonical.id))).getSingleOrNull();
          rehomedMounts.add((existingByCanonical.id, sourceId));
          await _rehomeMountTx(
            oldMountId: existingByCanonical.id,
            newMountId: sourceId,
            targetMount: incomingMount,
            remoteCheckpoint: remoteCp,
            remoteFinishedAt: remoteFinishedAt,
          );
          final newScan = await (db.select(
            db.libraryScanStates,
          )..where((t) => t.mountId.equals(sourceId))).getSingleOrNull();
          finalCp = newScan?.quarkCheckpoint;
          finalFinishedAt = newScan?.finishedAt;
          if ((oldScan?.quarkCheckpoint != null && finalCp != remoteCp) || existingByCanonical.secrets.isNotEmpty) {
            localMergedOrWon = true;
          }
          byId.remove(existingByCanonical.id);
          byId[sourceId] = incomingMount;
          if (canonicalKey.isNotEmpty) byCanonical[canonicalKey] = incomingMount;
        } else {
          resolvedMountId = existingByCanonical.id;
          localWinnerRemaps[sourceId] = resolvedMountId;
          await syncStore.recordRemappedSource(sourceId, resolvedMountId);
          localMergedOrWon = true;
          final mergedLocal = StorageMount(
            id: resolvedMountId,
            kind: existingByCanonical.kind,
            displayName: existingByCanonical.displayName,
            config: existingByCanonical.config,
            secrets: existingByCanonical.secrets.isNotEmpty ? existingByCanonical.secrets : secrets,
            createdAt: existingByCanonical.createdAt,
          );
          await mountManager.registry.upsert(mergedLocal);
          final curScan = await (db.select(
            db.libraryScanStates,
          )..where((t) => t.mountId.equals(resolvedMountId))).getSingleOrNull();
          if ((remoteCp != null && remoteCp.isNotEmpty) || (remoteFinishedAt != null && remoteFinishedAt > 0)) {
            final mergedCp = mergeQuarkCheckpoint(curScan?.quarkCheckpoint, remoteCp);
            await _persistSyncedScanState(
              resolvedMountId,
              mergedCheckpoint: mergedCp,
              curFinishedAt: curScan?.finishedAt,
              remoteFinishedAt: remoteFinishedAt,
            );
            finalCp = mergedCp;
            finalFinishedAt = math.max(curScan?.finishedAt ?? 0, remoteFinishedAt ?? 0);
          } else {
            finalCp = curScan?.quarkCheckpoint;
            finalFinishedAt = curScan?.finishedAt;
          }
          byId[resolvedMountId] = mergedLocal;
          if (canonicalKey.isNotEmpty) byCanonical[canonicalKey] = mergedLocal;
        }
      } else {
        await mountManager.registry.upsert(incomingMount);
        final curScan = await (db.select(
          db.libraryScanStates,
        )..where((t) => t.mountId.equals(sourceId))).getSingleOrNull();
        if ((remoteCp != null && remoteCp.isNotEmpty) || (remoteFinishedAt != null && remoteFinishedAt > 0)) {
          final mergedCp = mergeQuarkCheckpoint(curScan?.quarkCheckpoint, remoteCp);
          await _persistSyncedScanState(
            sourceId,
            mergedCheckpoint: mergedCp,
            curFinishedAt: curScan?.finishedAt,
            remoteFinishedAt: remoteFinishedAt,
          );
          if (mergedCp != remoteCp) localMergedOrWon = true;
          finalCp = mergedCp;
          finalFinishedAt = math.max(curScan?.finishedAt ?? 0, remoteFinishedAt ?? 0);
        } else {
          finalCp = curScan?.quarkCheckpoint;
          finalFinishedAt = curScan?.finishedAt;
        }
        byId[sourceId] = incomingMount;
        if (canonicalKey.isNotEmpty) byCanonical[canonicalKey] = incomingMount;
      }

      final activeMount = byId[resolvedMountId];
      // Prune existing local files matching newly excluded directories.
      if (activeMount != null && activeMount.configStringList(MountKeys.excludePaths).isNotEmpty) {
        final localFiles = await (db.select(db.libraryFiles)..where((t) => t.mountId.equals(resolvedMountId))).get();
        for (final f in localFiles) {
          if (!activeMount.isFileAllowed(f.path)) {
            await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
          }
        }
      }

      if (activeMount != null) {
        final resolvedTs = (src['client_updated_at'] as num?)?.toInt() ?? _nowMs();
        final resolvedPayload = await _buildSourcePayload(
          activeMount,
          ts: resolvedTs,
          quarkCheckpointOverride: finalCp,
          scanFinishedAtOverride: finalFinishedAt,
        );
        final finalHash = SyncJournalStore.computeEntityHash(
          SyncLocalStore.typeSource,
          resolvedPayload,
          rawSecrets: activeMount.secrets,
        );
        final prevResolvedJ = existingJournalById[resolvedMountId] ?? await syncStore.journal.getEntry(SyncLocalStore.typeSource, resolvedMountId);
        if (prevResolvedJ == null || prevResolvedJ.payloadHash != finalHash || prevResolvedJ.isDeleted) {
          final seq = await syncStore.allocNextLocalSeq();
          final updatedAt = localMergedOrWon && prevResolvedJ != null
              ? SyncLocalStore.computeNextHlc(await syncStore.calibratedNowMs(), prevResolvedJ.clientUpdatedAt)
              : resolvedTs;
          resolvedPayload['client_updated_at'] = updatedAt;
          await syncStore.journal.upsertEntry(
            SyncJournalEntry(
              entityType: SyncLocalStore.typeSource,
              entityKey: resolvedMountId,
              sourceId: resolvedMountId,
              localSeq: seq,
              payloadHash: finalHash,
              payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeSource, resolvedPayload),
              clientUpdatedAt: updatedAt,
              isDeleted: false,
              originDeviceId: localMergedOrWon ? myDeviceId : remoteOriginId,
              originEpoch: localMergedOrWon ? myEpoch : remoteOriginEpoch,
            ),
          );
        }
      }
    }
    return (processed: processed, mutations: mutations);
  }

  static bool _remoteSourceWinsTieBreak({
    required String remoteId,
    int? remoteCreatedAt,
    required StorageMount local,
  }) {
    final rCreated = (remoteCreatedAt != null && remoteCreatedAt > 0) ? remoteCreatedAt : (1 << 62);
    final lCreated = (local.createdAt != null && local.createdAt!.millisecondsSinceEpoch > 0)
        ? local.createdAt!.millisecondsSinceEpoch
        : (1 << 62);
    if (rCreated != lCreated) return rCreated < lCreated;
    return remoteId.compareTo(local.id) < 0;
  }

  static List<Map<String, dynamic>> _remapIncomingFiles(
    List<Map<String, dynamic>> files,
    Map<String, String> sourceRemaps,
  ) {
    final fileIdMap = <String, String>{};
    final out = <Map<String, dynamic>>[];
    for (final raw in files) {
      final copy = Map<String, dynamic>.from(raw);
      final srcId = copy['source_id'] as String?;
      if (srcId != null && sourceRemaps.containsKey(srcId)) {
        final newSrc = sourceRemaps[srcId]!;
        final relPath = copy['relative_path'] as String? ?? '';
        final oldFileId = copy['file_id'] as String?;
        final newFileId = DeterministicKeys.generateFileId(sourceId: newSrc, mountRelativePath: relPath);
        copy['source_id'] = newSrc;
        copy['file_id'] = newFileId;
        if (oldFileId != null && oldFileId.isNotEmpty) {
          fileIdMap[oldFileId] = newFileId;
        }
      }
      out.add(copy);
    }
    if (fileIdMap.isNotEmpty) {
      for (final copy in out) {
        final owner = copy['owner_file_id'] as String?;
        if (owner != null && fileIdMap.containsKey(owner)) {
          copy['owner_file_id'] = fileIdMap[owner];
        }
      }
    }
    return out;
  }

  Future<({int processed, int mutations})> _applyIncomingWorks(
    List<Map<String, dynamic>> rawWorks, {
    required Map<String, int> workItemByKey,
    required Set<int> touchedItemIds,
    required String myDeviceId,
    required String myEpoch,
    required String remoteOriginId,
    required String remoteOriginEpoch,
  }) async {
    var processed = 0;
    var mutations = 0;
    final workKeys = [
      for (final w in rawWorks)
        if (w['work_key'] is String && (w['work_key'] as String).isNotEmpty) w['work_key'] as String,
    ];
    final existingJournalByKey = await syncStore.journal.getEntriesForType(SyncLocalStore.typeWork, workKeys);
    final toJournal = <({
      SyncJournalEntry? prev,
      String workKey,
      Map<String, Object?> payload,
      String hash,
      int updatedAt,
      bool isDeleted,
      String originDeviceId,
      String originEpoch,
    })>[];

    for (final w in rawWorks) {
      final workKey = w['work_key'] as String?;
      final kind = w['kind'] as String?;
      if (workKey == null || workKey.isEmpty || kind == null || kind.isEmpty) continue;
      processed++;

      final remoteDeleted = w['is_deleted'] == true;
      final wMap = w.cast<String, Object?>();
      final incomingHash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWork, wMap);
      final existingJ = existingJournalByKey[workKey];
      if (existingJ != null && existingJ.payloadHash == incomingHash && existingJ.isDeleted == remoteDeleted) {
        continue;
      }

      final meta = _mapOf(w['metadata_json']);
      final tmdbId = meta['tmdb_id'] as String?;
      final bangumiId = meta['bangumi_id'] as String?;
      final imdbId = meta['imdb_id'] as String?;
      final title = (meta['title'] as String?) ?? workKey;
      final year = (meta['year'] as num?)?.toInt();
      final remoteStatus = (w['match_status'] as num?)?.toInt() ?? MatchStatusRank.matched;
      final remoteUpdatedAt = (w['client_updated_at'] as num?)?.toInt() ?? _nowMs();

      var existing = await _findExistingWorkItem(
        kind: kind,
        tmdbId: tmdbId,
        bangumiId: bangumiId,
        imdbId: imdbId,
        title: title,
        year: year,
      );

      var remoteApplied = false;
      if (existing != null) {
        final canOverride = shouldOverrideEntity(
          remoteDeleted: remoteDeleted,
          localDeleted: false,
          remoteMatchStatus: remoteStatus,
          localMatchStatus: MatchStatusRank.fromItem(existing),
          remoteUpdatedAt: remoteUpdatedAt,
          localUpdatedAt: existing.updatedAt,
          explicitUnlock: w['explicit_unlock'] == true,
        );
        if (canOverride) {
          remoteApplied = true;
          mutations++;
          if (remoteDeleted) {
            await repo.deleteItem(existing.id);
            existing = null;
          } else {
            await repo.updateItem(existing.id, _buildWorkCompanionUpdate(w, meta));
            await _applyWorkRelations(existing.id, meta);
            touchedItemIds.add(existing.id);
          }
        } else if (existingJ == null) {
          // Local superior item wasn't in journal yet; capture it with local origin.
          final localPayload = await _buildWorkPayload(
            existing,
            workKey: workKey,
            workRank: MatchStatusRank.fromItem(existing),
            updatedAt: existing.updatedAt > 0 ? existing.updatedAt : _nowMs(),
          );
          toJournal.add((
            prev: null,
            workKey: workKey,
            payload: localPayload,
            hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeWork, localPayload),
            updatedAt: (localPayload['client_updated_at'] as num).toInt(),
            isDeleted: false,
            originDeviceId: myDeviceId,
            originEpoch: myEpoch,
          ));
        }
      } else if (!remoteDeleted) {
        remoteApplied = true;
        mutations++;
        final newId = await repo.insertItem(_buildWorkCompanionInsert(w, meta));
        await _applyWorkRelations(newId, meta);
        existing = (await repo.getItem(newId))?.item;
        touchedItemIds.add(newId);
      } else if (existingJ == null || !existingJ.isDeleted) {
        remoteApplied = true;
      }

      if (remoteApplied) {
        toJournal.add((
          prev: existingJ,
          workKey: workKey,
          payload: wMap,
          hash: incomingHash,
          updatedAt: remoteUpdatedAt,
          isDeleted: remoteDeleted,
          originDeviceId: remoteOriginId,
          originEpoch: remoteOriginEpoch,
        ));
      }

      if (existing != null) {
        workItemByKey[workKey] = existing.id;
      }
    }

    if (toJournal.isNotEmpty) {
      final firstSeq = await syncStore.allocLocalSeqRange(toJournal.length);
      for (var i = 0; i < toJournal.length; i++) {
        final j = toJournal[i];
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeWork,
            entityKey: j.workKey,
            workKey: j.workKey,
            localSeq: firstSeq + i,
            payloadHash: j.hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeWork, j.payload),
            clientUpdatedAt: j.updatedAt,
            isDeleted: j.isDeleted,
            originDeviceId: j.originDeviceId,
            originEpoch: j.originEpoch,
          ),
        );
      }
    }

    return (processed: processed, mutations: mutations);
  }

  Future<LibraryItemRow?> _findExistingWorkItem({
    required String kind,
    String? tmdbId,
    String? bangumiId,
    String? imdbId,
    required String title,
    int? year,
  }) async {
    if (tmdbId != null && tmdbId.isNotEmpty) {
      final hit = await repo.findByExternalId(kind: kind, tmdbId: tmdbId);
      if (hit != null) return hit;
    }
    if (bangumiId != null && bangumiId.isNotEmpty) {
      final hit = await (db.select(
        db.libraryItems,
      )..where((t) => t.kind.equals(kind) & t.bangumiId.equals(bangumiId))).getSingleOrNull();
      if (hit != null) return hit;
    }
    if (imdbId != null && imdbId.isNotEmpty) {
      final hit = await repo.findByExternalId(kind: kind, imdbId: imdbId);
      if (hit != null) return hit;
    }
    if (title.trim().isEmpty) return null;
    return repo.findTitleByName(kind: kind, name: title, year: year);
  }

  LibraryItemsCompanion _buildWorkCompanionInsert(Map<String, dynamic> w, Map<String, Object?> meta) {
    final title = (meta['title'] as String?) ?? (w['work_key'] as String);
    final sortTitle = (meta['sort_title'] as String?) ?? LibraryRepository.sortTitleFor(title);
    final matchStatus = (w['match_status'] as num?)?.toInt() ?? MatchStatusRank.matched;
    final metaSource = (meta['metadata_source'] as String?) ?? (w['provider'] as String?);
    final locked = (meta['locked'] as bool?) ?? (matchStatus >= MatchStatusRank.matchLocked);
    final updatedAt = (w['client_updated_at'] as num?)?.toInt() ?? _nowMs();
    return LibraryItemsCompanion.insert(
      kind: w['kind'] as String,
      libraryType: (w['library_type'] as String?) ?? LibraryTypes.movie,
      title: title,
      sortTitle: sortTitle,
      originalTitle: Value(meta['original_title'] as String?),
      aliases: Value(meta['aliases'] as String?),
      year: Value((meta['year'] as num?)?.toInt()),
      releaseDate: Value(meta['release_date'] as String?),
      summary: Value(meta['summary'] as String?),
      tagline: Value(meta['tagline'] as String?),
      contentRating: Value(meta['content_rating'] as String?),
      studio: Value(meta['studio'] as String?),
      rating: Value((meta['rating'] as num?)?.toDouble()),
      runtimeMs: Value((meta['runtime_ms'] as num?)?.toInt()),
      posterSource: Value(meta['poster_path'] as String?),
      backdropSource: Value(meta['backdrop_path'] as String?),
      logoSource: Value(meta['logo_path'] as String?),
      tmdbId: Value(meta['tmdb_id'] as String?),
      imdbId: Value(meta['imdb_id'] as String?),
      tvdbId: Value(meta['tvdb_id'] as String?),
      bangumiId: Value(meta['bangumi_id'] as String?),
      doubanId: Value(meta['douban_id'] as String?),
      metadataSource: Value(metaSource),
      locked: Value(locked),
      addedAt: updatedAt,
      sourceAddedAt: Value((meta['source_added_at'] as num?)?.toInt()),
      updatedAt: updatedAt,
      scrapedAt: Value(matchStatus >= MatchStatusRank.unmatched ? updatedAt : null),
    );
  }

  LibraryItemsCompanion _buildWorkCompanionUpdate(Map<String, dynamic> w, Map<String, Object?> meta) {
    final title = (meta['title'] as String?) ?? (w['work_key'] as String);
    final sortTitle = (meta['sort_title'] as String?) ?? LibraryRepository.sortTitleFor(title);
    final matchStatus = (w['match_status'] as num?)?.toInt() ?? MatchStatusRank.matched;
    final metaSource = (meta['metadata_source'] as String?) ?? (w['provider'] as String?);
    final locked = (meta['locked'] as bool?) ?? (matchStatus >= MatchStatusRank.matchLocked);
    final updatedAt = (w['client_updated_at'] as num?)?.toInt() ?? _nowMs();
    return LibraryItemsCompanion(
      libraryType: Value((w['library_type'] as String?) ?? LibraryTypes.movie),
      title: Value(title),
      sortTitle: Value(sortTitle),
      originalTitle: Value(meta['original_title'] as String?),
      aliases: Value(meta['aliases'] as String?),
      year: Value((meta['year'] as num?)?.toInt()),
      releaseDate: Value(meta['release_date'] as String?),
      summary: Value(meta['summary'] as String?),
      tagline: Value(meta['tagline'] as String?),
      contentRating: Value(meta['content_rating'] as String?),
      studio: Value(meta['studio'] as String?),
      rating: Value((meta['rating'] as num?)?.toDouble()),
      runtimeMs: Value((meta['runtime_ms'] as num?)?.toInt()),
      posterSource: Value(meta['poster_path'] as String?),
      backdropSource: Value(meta['backdrop_path'] as String?),
      logoSource: Value(meta['logo_path'] as String?),
      tmdbId: Value(meta['tmdb_id'] as String?),
      imdbId: Value(meta['imdb_id'] as String?),
      tvdbId: Value(meta['tvdb_id'] as String?),
      bangumiId: Value(meta['bangumi_id'] as String?),
      doubanId: Value(meta['douban_id'] as String?),
      metadataSource: Value(metaSource),
      locked: Value(locked),
      sourceAddedAt: Value((meta['source_added_at'] as num?)?.toInt()),
      updatedAt: Value(updatedAt),
      scrapedAt: Value(matchStatus >= MatchStatusRank.unmatched ? updatedAt : null),
    );
  }

  Future<void> _applyWorkRelations(int itemId, Map<String, Object?> meta) async {
    final genres = meta['genres'];
    if (genres is List) {
      await repo.setGenres(itemId, [for (final g in genres) '$g']);
    }
    final credits = meta['credits'];
    if (credits is List) {
      await repo.setCredits(itemId, [
        for (final raw in credits)
          if (raw is Map)
            (
              name: '${raw['name'] ?? ''}',
              job: '${raw['job'] ?? 'actor'}',
              character: raw['character'] as String?,
              tmdbId: raw['tmdb_id'] as String?,
              photoSource: raw['photo_url'] as String?,
            ),
      ]);
    }
  }

  Future<({int processed, int mutations})> _applyIncomingFiles(
    List<Map<String, dynamic>> rawFiles, {
    required Map<String, int> workItemByKey,
    required Set<int> touchedItemIds,
    Map<String, int>? rowIdBySyncFileId,
    required String myDeviceId,
    required String myEpoch,
    required String remoteOriginId,
    required String remoteOriginEpoch,
  }) async {
    var processed = 0;
    var mutations = 0;
    final fileRowIds = rowIdBySyncFileId ?? <String, int>{};
    final runningScanIdByMount = <String, int>{};
    final knownMountIds = {for (final m in await mountManager.registry.list()) m.id};

    final canonicalIds = <String>[];
    for (final f in rawFiles) {
      final mountId = f['source_id'] as String?;
      final rawPath = f['relative_path'] as String?;
      if (mountId != null && mountId.isNotEmpty && rawPath != null && rawPath.isNotEmpty) {
        canonicalIds.add(DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: rawPath));
      } else if (f['file_id'] is String && (f['file_id'] as String).isNotEmpty) {
        canonicalIds.add(f['file_id'] as String);
      }
    }
    final existingJournalById = await syncStore.journal.getEntriesForType(SyncLocalStore.typeFile, canonicalIds);
    final toJournal = <({
      String fileId,
      String mountId,
      String? normPath,
      String? workKey,
      Map<String, Object?> payload,
      String hash,
      int updatedAt,
      bool isDeleted,
      String originDeviceId,
      String originEpoch,
    })>[];

    Future<int> activeScanIdFor(String mountId) async {
      final cached = runningScanIdByMount[mountId];
      if (cached != null) return cached;
      final row = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(mountId))).getSingleOrNull();
      final activeId = (row != null && row.status == 'running') ? row.scanId : 0;
      return runningScanIdByMount[mountId] = activeId;
    }

    final videos = [
      for (final f in rawFiles)
        if ((f['role'] as String? ?? LibraryFileRoles.video) != LibraryFileRoles.subtitle) f,
    ];
    final subtitles = [
      for (final f in rawFiles)
        if (f['role'] == LibraryFileRoles.subtitle) f,
    ];

    Future<void> processOne(Map<String, dynamic> f, {int? ownerRowIdOverride, required bool isVideo}) async {
      processed++;
      final mountId = f['source_id'] as String?;
      final rawPath = f['relative_path'] as String?;
      final canonicalFileId = (mountId != null && mountId.isNotEmpty && rawPath != null && rawPath.isNotEmpty)
          ? DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: rawPath)
          : (f['file_id'] as String? ?? '');
      if (mountId == null || mountId.isEmpty || canonicalFileId.isEmpty) return;

      final fMap = f.cast<String, Object?>();
      final remoteDeleted = f['is_deleted'] == true;
      final incomingHash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, fMap);
      final existingJ = existingJournalById[canonicalFileId];
      final activeScanId = await activeScanIdFor(mountId);

      // O(1) fast-skip when canonical state is identical and no scan on this mount needs seenInScan updates.
      if (activeScanId == 0 &&
          existingJ != null &&
          existingJ.payloadHash == incomingHash &&
          existingJ.isDeleted == remoteDeleted) {
        return;
      }

      if (rawPath == null || rawPath.isEmpty || !knownMountIds.contains(mountId)) {
        return;
      }

      final path = DeterministicKeys.normalizeMountPath(rawPath);
      final role = (f['role'] as String?) ?? LibraryFileRoles.video;
      final existing = await (db.select(
        db.libraryFiles,
      )..where((t) => t.mountId.equals(mountId) & t.path.equals(path))).getSingleOrNull();
      final remoteUpdatedAt = (f['client_updated_at'] as num?)?.toInt() ?? _nowMs();
      final remoteMatchStatus = (f['match_status'] as num?)?.toInt() ?? MatchStatusRank.pending;

      if (existing != null) {
        final localUpdatedAt = math.max(existing.addedAt, existingJ?.clientUpdatedAt ?? 0);
        final canOverride = shouldOverrideEntity(
          remoteDeleted: remoteDeleted,
          localDeleted: false,
          remoteMatchStatus: remoteMatchStatus,
          localMatchStatus: MatchStatusRank.fromFile(existing),
          remoteUpdatedAt: remoteUpdatedAt,
          localUpdatedAt: localUpdatedAt,
          explicitUnlock: f['explicit_unlock'] == true,
        );
        if (!canOverride) {
          final fileId = f['file_id'] as String?;
          if (isVideo && fileId != null) {
            fileRowIds[fileId] = existing.id;
          }
          if (existingJ == null) {
            final item = existing.itemId == null ? null : (await repo.getItem(existing.itemId!))?.item;
            LibraryItemRow? workItem = item;
            if (item != null && (item.kind == LibraryKinds.episode || item.kind == LibraryKinds.season)) {
              final workId = item.showId ?? item.parentId;
              if (workId != null) workItem = (await repo.getItem(workId))?.item;
            }
            final wk = await _resolveSyncWorkKey(workItem: workItem, repFile: existing);
            final localPayload = existing.role == LibraryFileRoles.subtitle
                ? _buildSubtitleFilePayload(existing, fileId: canonicalFileId, ownerFileId: null, updatedAt: localUpdatedAt)
                : _buildVideoFilePayload(
                    existing,
                    fileId: canonicalFileId,
                    workKey: wk,
                    item: item,
                    workItem: workItem,
                    updatedAt: localUpdatedAt,
                  );
            toJournal.add((
              fileId: canonicalFileId,
              mountId: mountId,
              normPath: path,
              workKey: wk,
              payload: localPayload,
              hash: SyncJournalStore.computeEntityHash(SyncLocalStore.typeFile, localPayload),
              updatedAt: localUpdatedAt,
              isDeleted: false,
              originDeviceId: myDeviceId,
              originEpoch: myEpoch,
            ));
          }
          return;
        }
        if (remoteDeleted) {
          if (existing.itemId != null) touchedItemIds.add(existing.itemId!);
          await (db.delete(db.libraryFiles)..where((t) => t.id.equals(existing.id))).go();
          mutations++;
          toJournal.add((
            fileId: canonicalFileId,
            mountId: mountId,
            normPath: path,
            workKey: f['work_key'] as String?,
            payload: fMap,
            hash: incomingHash,
            updatedAt: remoteUpdatedAt,
            isDeleted: true,
            originDeviceId: remoteOriginId,
            originEpoch: remoteOriginEpoch,
          ));
          return;
        }
      } else if (remoteDeleted) {
        if (existingJ == null || !existingJ.isDeleted) {
          toJournal.add((
            fileId: canonicalFileId,
            mountId: mountId,
            normPath: path,
            workKey: f['work_key'] as String?,
            payload: fMap,
            hash: incomingHash,
            updatedAt: remoteUpdatedAt,
            isDeleted: true,
            originDeviceId: remoteOriginId,
            originEpoch: remoteOriginEpoch,
          ));
        }
        return;
      }

      mutations++;
      final preservedScanId = math.max(existing?.seenInScan ?? 0, activeScanId);
      final fileRowId = await repo.upsertFile(
        mountId: mountId,
        path: path,
        role: role,
        scanId: preservedScanId,
        remoteId: f['remote_id'] as String?,
        size: (f['file_size'] as num?)?.toInt(),
        modifiedAt: (f['file_mtime'] as num?)?.toInt(),
        sourceCreatedAt: (f['file_created_at'] as num?)?.toInt(),
        parsed: f['parsed_json'] as String?,
        versionLabel: f['version_label'] as String?,
        language: f['language'] as String?,
        ownerFileId: ownerRowIdOverride,
      );

      final spec = _mapOf(f['media_spec_json']);
      if (spec.isNotEmpty && role == LibraryFileRoles.video) {
        await repo.updateFile(
          fileRowId,
          LibraryFilesCompanion(
            durationMs: Value((spec['duration_ms'] as num?)?.toInt()),
            container: Value(spec['container'] as String?),
            videoCodec: Value(spec['video_codec'] as String?),
            width: Value((spec['width'] as num?)?.toInt()),
            height: Value((spec['height'] as num?)?.toInt()),
            hdrFormat: Value(spec['hdr_format'] as String?),
          ),
        );
      }

      if (role == LibraryFileRoles.video) {
        final workKey = f['work_key'] as String?;
        final seasonNum = (f['season_num'] as num?)?.toInt() ?? -1;
        final episodeNum = (f['episode_num'] as num?)?.toInt() ?? -1;
        final workItemId = workKey == null ? null : await _resolveWorkItemId(workKey, workItemByKey);

        int? targetItemId = workItemId;
        if (workItemId != null) {
          final workRow = (await repo.getItem(workItemId))?.item;
          if (workRow != null && workRow.kind == LibraryKinds.show && seasonNum >= 0 && episodeNum >= 0) {
            targetItemId = await _ensureShowEpisode(
              show: workRow,
              seasonNum: seasonNum,
              episodeNum: episodeNum,
              spec: spec,
              updatedAt: remoteUpdatedAt,
            );
          }
        }

        if (targetItemId != null) {
          await repo.linkFile(fileRowId, targetItemId);
          await repo.updateFile(
            fileRowId,
            LibraryFilesCompanion(
              matchState: Value(
                remoteMatchStatus >= MatchStatusRank.matched ? LibraryMatchStates.matched : LibraryMatchStates.unmatched,
              ),
              matchLocked: Value(remoteMatchStatus >= MatchStatusRank.matchLocked),
            ),
          );
          touchedItemIds.add(targetItemId);
          if (workItemId != null) touchedItemIds.add(workItemId);
        }
      }

      final rawFileId = f['file_id'] as String?;
      if (isVideo && rawFileId != null) {
        fileRowIds[rawFileId] = fileRowId;
      }

      if (existingJ == null || existingJ.payloadHash != incomingHash || existingJ.isDeleted) {
        toJournal.add((
          fileId: canonicalFileId,
          mountId: mountId,
          normPath: path,
          workKey: f['work_key'] as String?,
          payload: fMap,
          hash: incomingHash,
          updatedAt: remoteUpdatedAt,
          isDeleted: false,
          originDeviceId: remoteOriginId,
          originEpoch: remoteOriginEpoch,
        ));
      }
    }

    for (final f in videos) {
      await processOne(f, isVideo: true);
    }

    for (final f in subtitles) {
      final mountId = f['source_id'] as String?;
      final ownerSyncId = f['owner_file_id'] as String?;
      int? ownerRowId = ownerSyncId == null ? null : fileRowIds[ownerSyncId];
      if (ownerRowId == null && ownerSyncId != null && mountId != null) {
        final candidates = await (db.select(
          db.libraryFiles,
        )..where((t) => t.mountId.equals(mountId) & t.role.equals(LibraryFileRoles.video))).get();
        for (final c in candidates) {
          if (DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: c.path) == ownerSyncId) {
            ownerRowId = c.id;
            break;
          }
        }
      }
      await processOne(f, ownerRowIdOverride: ownerRowId, isVideo: false);
    }

    if (toJournal.isNotEmpty) {
      final firstSeq = await syncStore.allocLocalSeqRange(toJournal.length);
      for (var i = 0; i < toJournal.length; i++) {
        final j = toJournal[i];
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeFile,
            entityKey: j.fileId,
            sourceId: j.mountId,
            relativePath: j.normPath,
            workKey: j.workKey,
            localSeq: firstSeq + i,
            payloadHash: j.hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeFile, j.payload),
            clientUpdatedAt: j.updatedAt,
            isDeleted: j.isDeleted,
            originDeviceId: j.originDeviceId,
            originEpoch: j.originEpoch,
          ),
        );
      }
    }

    return (processed: processed, mutations: mutations);
  }

  Future<int?> _resolveWorkItemId(String workKey, Map<String, int> cache) async {
    if (cache.containsKey(workKey)) return cache[workKey];
    if (workKey.startsWith('raw:')) {
      final jWork = await syncStore.journal.getEntry(SyncLocalStore.typeWork, workKey);
      if (jWork != null && !jWork.isDeleted) {
        final decoded = jWork.decodePayload();
        final meta = _mapOf(decoded['metadata_json']);
        final kind = decoded['kind'] as String? ?? LibraryKinds.movie;
        final title = meta['title'] as String? ?? '';
        final year = (meta['year'] as num?)?.toInt();
        final hit = await _findExistingWorkItem(kind: kind, title: title, year: year);
        if (hit != null) {
          cache[workKey] = hit.id;
          return hit.id;
        }
      }
      return null;
    }
    final parts = workKey.split(':');
    if (parts.length >= 3) {
      final provider = parts[0];
      final kind = parts[1];
      final extId = parts.sublist(2).join(':');
      LibraryItemRow? hit;
      if (provider == 'tmdb' || provider == 'imdb') {
        hit = await repo.findByExternalId(
          kind: kind,
          tmdbId: provider == 'tmdb' ? extId : null,
          imdbId: provider == 'imdb' ? extId : null,
        );
      } else if (provider == 'bangumi') {
        hit = await (db.select(
          db.libraryItems,
        )..where((t) => t.kind.equals(kind) & t.bangumiId.equals(extId))).getSingleOrNull();
      }
      if (hit != null) {
        cache[workKey] = hit.id;
        return hit.id;
      }
    }
    return null;
  }

  Future<int> _ensureShowEpisode({
    required LibraryItemRow show,
    required int seasonNum,
    required int episodeNum,
    required Map<String, Object?> spec,
    required int updatedAt,
  }) async {
    final season = await repo.findChild(show.id, seasonNumber: seasonNum);
    final seasonId =
        season?.id ??
        await repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.season,
            libraryType: show.libraryType,
            title: seasonNum == 0 ? 'Specials' : 'Season $seasonNum',
            sortTitle: seasonNum == 0 ? 'specials' : 'season ${seasonNum.toString().padLeft(4, '0')}',
            parentId: Value(show.id),
            showId: Value(show.id),
            seasonNumber: Value(seasonNum),
            addedAt: updatedAt,
            updatedAt: updatedAt,
            scrapedAt: Value(updatedAt),
          ),
        );

    final ep = await repo.findChild(seasonId, episodeNumber: episodeNum);
    final epTitle = (spec['ep_title'] as String?) ?? 'Episode $episodeNum';
    if (ep == null) {
      return repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.episode,
          libraryType: show.libraryType,
          title: epTitle,
          sortTitle: 's${seasonNum.toString().padLeft(4, '0')}e${episodeNum.toString().padLeft(4, '0')}',
          parentId: Value(seasonId),
          showId: Value(show.id),
          seasonNumber: Value(seasonNum),
          episodeNumber: Value(episodeNum),
          summary: Value(spec['ep_overview'] as String?),
          posterSource: Value(spec['ep_still_path'] as String?),
          runtimeMs: Value((spec['ep_runtime_ms'] as num?)?.toInt()),
          releaseDate: Value(spec['ep_release_date'] as String?),
          metadataSource: Value(spec['ep_metadata_source'] as String?),
          addedAt: updatedAt,
          updatedAt: updatedAt,
          scrapedAt: Value((spec['ep_scraped_at'] as num?)?.toInt() ?? updatedAt),
        ),
      );
    }

    await repo.updateItem(
      ep.id,
      LibraryItemsCompanion(
        libraryType: Value(show.libraryType),
        title: spec['ep_title'] != null ? Value(epTitle) : const Value.absent(),
        summary: spec['ep_overview'] != null ? Value(spec['ep_overview'] as String?) : const Value.absent(),
        posterSource: spec['ep_still_path'] != null ? Value(spec['ep_still_path'] as String?) : const Value.absent(),
        runtimeMs: spec['ep_runtime_ms'] != null
            ? Value((spec['ep_runtime_ms'] as num?)?.toInt())
            : const Value.absent(),
        releaseDate: spec['ep_release_date'] != null ? Value(spec['ep_release_date'] as String?) : const Value.absent(),
        metadataSource: spec['ep_metadata_source'] != null
            ? Value(spec['ep_metadata_source'] as String?)
            : const Value.absent(),
        updatedAt: Value(updatedAt),
      ),
    );
    return ep.id;
  }

  Future<({int processed, int mutations})> _applyIncomingWorkPrefs(
    List<Map<String, dynamic>> rawPrefs, {
    required Set<int> touchedItemIds,
    required String remoteOriginId,
    required String remoteOriginEpoch,
  }) async {
    var processed = 0;
    var mutations = 0;
    final skipStore = WorkSkipSettingsStore(db);
    final keys = [
      for (final p in rawPrefs)
        if (p['work_key'] is String && (p['work_key'] as String).isNotEmpty) p['work_key'] as String,
    ];
    final existingJournalByKey = await syncStore.journal.getEntriesForType(SyncLocalStore.typeWorkPref, keys);
    final toJournal = <({
      String workKey,
      Map<String, Object?> payload,
      String hash,
      int updatedAt,
    })>[];

    for (final p in rawPrefs) {
      final workKey = p['work_key'] as String?;
      if (workKey == null || workKey.isEmpty) continue;
      final parts = workKey.split(':');
      if (parts.length < 3) continue;
      final provider = parts[0];
      if (provider == 'raw') continue;
      processed++;

      final pMap = p.cast<String, Object?>();
      final incomingHash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWorkPref, pMap);
      final existingJ = existingJournalByKey[workKey];
      if (existingJ != null && existingJ.payloadHash == incomingHash && !existingJ.isDeleted) {
        continue;
      }

      final kind = parts[1];
      final externalId = parts.sublist(2).join(':');
      final work = WorkIdentity(
        source: WorkIdentity.localSource,
        kind: kind,
        provider: provider,
        externalId: externalId,
      );
      final remoteUpdatedAt = (p['client_updated_at'] as num?)?.toInt() ?? 0;

      final stampKey = 'sync-pref-ts:${work.stateKey()}';
      final localStamp = int.tryParse(
            (await (db.select(db.librarySettings)..where((t) => t.key.equals(stampKey))).getSingleOrNull())?.value ?? '',
          ) ??
          0;
      if (remoteUpdatedAt < math.max(localStamp, existingJ?.clientUpdatedAt ?? 0)) continue;

      mutations++;
      final settings = WorkSkipSettings(
        introEnabled: p['intro_enabled'] == true,
        introStartMs: (p['intro_start_ms'] as num?)?.toInt() ?? 0,
        introEndMs: (p['intro_end_ms'] as num?)?.toInt() ?? 0,
        creditsEnabled: p['credits_enabled'] == true,
        creditsDurationMs: (p['credits_from_end_ms'] as num?)?.toInt() ?? 0,
        creditsResumeBeforeEndMs: (p['keep_easter_egg_ms'] as num?)?.toInt() ?? 0,
      );
      if (settings.validFor()) {
        await skipStore.save(work, settings, syncToOutbox: false);
      }

      final stateKey = work.stateKey();
      final existingState = await (db.select(
        db.workWatchStates,
      )..where((t) => t.stateKey.equals(stateKey))).getSingleOrNull();
      final favorite = p['is_favorite'] == true;
      final hidden = p['hidden_from_continue'] == true;
      if (existingState == null) {
        await db
            .into(db.workWatchStates)
            .insertOnConflictUpdate(
              WorkWatchStatesCompanion.insert(
                stateKey: stateKey,
                source: work.source,
                kind: work.kind,
                provider: work.provider,
                externalId: work.externalId,
                favorite: Value(favorite),
                hiddenFromContinue: Value(hidden),
                updatedAt: remoteUpdatedAt,
              ),
            );
      } else {
        await (db.update(db.workWatchStates)..where((t) => t.stateKey.equals(stateKey))).write(
          WorkWatchStatesCompanion(
            favorite: Value(favorite),
            hiddenFromContinue: Value(hidden),
            updatedAt: Value(math.max(existingState.updatedAt, remoteUpdatedAt)),
          ),
        );
      }

      await db
          .into(db.librarySettings)
          .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: stampKey, value: '$remoteUpdatedAt'));

      toJournal.add((
        workKey: workKey,
        payload: pMap,
        hash: incomingHash,
        updatedAt: remoteUpdatedAt,
      ));

      final item = await _findExistingWorkItem(
        kind: kind,
        tmdbId: provider == 'tmdb' ? externalId : null,
        bangumiId: provider == 'bangumi' ? externalId : null,
        imdbId: provider == 'imdb' ? externalId : null,
        title: '',
      );
      if (item != null) touchedItemIds.add(item.id);
    }

    if (toJournal.isNotEmpty) {
      final firstSeq = await syncStore.allocLocalSeqRange(toJournal.length);
      for (var i = 0; i < toJournal.length; i++) {
        final j = toJournal[i];
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeWorkPref,
            entityKey: j.workKey,
            workKey: j.workKey,
            localSeq: firstSeq + i,
            payloadHash: j.hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeWorkPref, j.payload),
            clientUpdatedAt: j.updatedAt,
            isDeleted: false,
            originDeviceId: remoteOriginId,
            originEpoch: remoteOriginEpoch,
          ),
        );
      }
    }

    return (processed: processed, mutations: mutations);
  }

  Future<({int processed, int mutations})> _applyIncomingWatchProgress(
    List<Map<String, dynamic>> rawProgress, {
    required Set<int> touchedItemIds,
    required String remoteOriginId,
    required String remoteOriginEpoch,
  }) async {
    var processed = 0;
    var mutations = 0;
    final progressKeys = <String>[];
    for (final g in rawProgress) {
      final workKey = g['work_key'] as String?;
      if (workKey == null || workKey.isEmpty) continue;
      final parts = workKey.split(':');
      if (parts.length < 3 || parts[0] == 'raw') continue;
      final kind = parts[1];
      final seasonNum = (g['season_num'] as num?)?.toInt() ?? -1;
      final episodeNum = (g['episode_num'] as num?)?.toInt() ?? -1;
      final pk = (g['progress_key'] as String?)?.isNotEmpty == true
          ? g['progress_key'] as String
          : DeterministicKeys.generateProgressKey(
              workKey: workKey,
              kind: kind,
              seasonNum: seasonNum,
              episodeNum: episodeNum,
            );
      progressKeys.add(pk);
    }
    final existingJournalByKey = await syncStore.journal.getEntriesForType(
      SyncLocalStore.typeWatchProgress,
      progressKeys,
    );
    final toJournal = <({
      String progressKey,
      String workKey,
      Map<String, Object?> payload,
      String hash,
      int updatedAt,
    })>[];

    for (final g in rawProgress) {
      final workKey = g['work_key'] as String?;
      if (workKey == null || workKey.isEmpty) continue;
      final parts = workKey.split(':');
      if (parts.length < 3 || parts[0] == 'raw') continue;
      processed++;

      final provider = parts[0];
      final kind = parts[1];
      final externalId = parts.sublist(2).join(':');
      final seasonNum = (g['season_num'] as num?)?.toInt() ?? -1;
      final episodeNum = (g['episode_num'] as num?)?.toInt() ?? -1;
      final remoteUpdatedAt = (g['client_updated_at'] as num?)?.toInt() ?? 0;
      final progressKey = (g['progress_key'] as String?)?.isNotEmpty == true
          ? g['progress_key'] as String
          : DeterministicKeys.generateProgressKey(
              workKey: workKey,
              kind: kind,
              seasonNum: seasonNum,
              episodeNum: episodeNum,
            );

      final gMap = g.cast<String, Object?>();
      final incomingHash = SyncJournalStore.computeEntityHash(SyncLocalStore.typeWatchProgress, gMap);
      final existingJ = existingJournalByKey[progressKey];
      if (existingJ != null && existingJ.payloadHash == incomingHash && !existingJ.isDeleted) {
        continue;
      }

      final work = WorkIdentity(
        source: WorkIdentity.localSource,
        kind: kind,
        provider: provider,
        externalId: externalId,
      );
      final stateKey = work.stateKey(season: seasonNum, episode: episodeNum);
      final existing = await (db.select(
        db.workWatchStates,
      )..where((t) => t.stateKey.equals(stateKey))).getSingleOrNull();
      final localProgTimestamp = existingJ?.clientUpdatedAt ?? existing?.updatedAt ?? 0;
      if (remoteUpdatedAt < localProgTimestamp) continue;

      mutations++;
      final durMs = (g['duration_ms'] as num?)?.toInt();
      await db
          .into(db.workWatchStates)
          .insertOnConflictUpdate(
            WorkWatchStatesCompanion.insert(
              stateKey: stateKey,
              source: work.source,
              kind: work.kind,
              provider: work.provider,
              externalId: work.externalId,
              seasonNumber: Value(seasonNum),
              episodeNumber: Value(episodeNum),
              positionMs: Value((g['position_ms'] as num?)?.toInt() ?? 0),
              durationMs: Value(durMs != null && durMs > 0 ? durMs : null),
              watched: Value(g['watched'] == true),
              playCount: Value((g['play_count'] as num?)?.toInt() ?? 0),
              lastPlayedAt: Value((g['last_played_at'] as num?)?.toInt()),
              favorite: Value(existing?.favorite ?? false),
              hiddenFromContinue: Value(existing?.hiddenFromContinue ?? false),
              updatedAt: math.max(existing?.updatedAt ?? 0, remoteUpdatedAt),
            ),
          );

      toJournal.add((
        progressKey: progressKey,
        workKey: workKey,
        payload: gMap,
        hash: incomingHash,
        updatedAt: remoteUpdatedAt,
      ));

      final item = await _findExistingWorkItem(
        kind: kind,
        tmdbId: provider == 'tmdb' ? externalId : null,
        bangumiId: provider == 'bangumi' ? externalId : null,
        imdbId: provider == 'imdb' ? externalId : null,
        title: '',
      );
      if (item != null) touchedItemIds.add(item.id);
    }

    if (toJournal.isNotEmpty) {
      final firstSeq = await syncStore.allocLocalSeqRange(toJournal.length);
      for (var i = 0; i < toJournal.length; i++) {
        final j = toJournal[i];
        await syncStore.journal.upsertEntry(
          SyncJournalEntry(
            entityType: SyncLocalStore.typeWatchProgress,
            entityKey: j.progressKey,
            workKey: j.workKey,
            localSeq: firstSeq + i,
            payloadHash: j.hash,
            payloadJson: SyncJournalStore.sanitizePayloadJsonForStorage(SyncLocalStore.typeWatchProgress, j.payload),
            clientUpdatedAt: j.updatedAt,
            isDeleted: false,
            originDeviceId: remoteOriginId,
            originEpoch: remoteOriginEpoch,
          ),
        );
      }
    }

    return (processed: processed, mutations: mutations);
  }

  static Map<String, Object?> _mapOf(Object? raw) =>
      raw is Map ? {for (final entry in raw.entries) '${entry.key}': entry.value} : const {};
}

class _JournalCandidate {
  const _JournalCandidate({
    required this.entityType,
    required this.entityKey,
    this.sourceId,
    this.relativePath,
    this.workKey,
    required this.payload,
    required this.hash,
    required this.updatedAt,
    this.isDeleted = false,
  });

  final String entityType;
  final String entityKey;
  final String? sourceId;
  final String? relativePath;
  final String? workKey;
  final Map<String, Object?> payload;
  final String hash;
  final int updatedAt;
  final bool isDeleted;
}
