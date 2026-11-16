import 'dart:convert';

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
import '../library_repository.dart';
import '../library_settings.dart';
import '../library_watch_state_store.dart';
import 'deterministic_keys.dart';
import 'sync_crypto.dart';
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
  });

  final AppDatabase db;
  final LibraryRepository repo;
  final SyncLocalStore syncStore;
  final MountManager mountManager;

  static int _nowMs() => clock.now().millisecondsSinceEpoch;

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
    required Uint8List encryptionKey,
    required int ts,
    bool forceAuthOverride = false,
  }) async {
    final canonicalKey = DeterministicKeys.canonicalSourceKey(mount);
    final scanRow = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).getSingleOrNull();
    final encryptedAuth = mount.secrets.isEmpty
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
      'quark_checkpoint': scanRow?.quarkCheckpoint,
      'created_at': mount.createdAt?.millisecondsSinceEpoch ?? ts,
      'client_updated_at': ts,
      'is_deleted': false,
    };
  }

  /// Enqueues [mount] (excluding [StorageKind.local]) into `SyncOutbox`.
  Future<void> enqueueMount(
    StorageMount mount, {
    required Uint8List masterKey,
    bool forceAuthOverride = false,
    int? updatedAt,
  }) async {
    if (mount.kind == StorageKind.local) return;
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
    );
  }

  Future<void> enqueueMountDeletion(String mountId, {int? updatedAt}) async {
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

  Future<({
    int ts,
    List<Map<String, Object?>> sources,
    List<Map<String, Object?>> works,
    List<Map<String, Object?>> files,
    List<Map<String, Object?>> workPrefs,
    List<Map<String, Object?>> watchProgress,
    Map<String, Object?> userSettings,
  })> _collectCatalogBundle({
    required Uint8List encryptionKey,
    Set<String>? mountIds,
    bool includeAllWorkStates = true,
  }) async {
    final ts = await syncStore.calibratedNowMs();
    final mounts = await mountManager.registry.list();
    final sharedMounts = [
      for (final m in mounts)
        if (m.kind != StorageKind.local && (mountIds == null || mountIds.contains(m.id))) m,
    ];

    final sources = <Map<String, Object?>>[];
    for (final mount in sharedMounts) {
      sources.add(await _buildSourcePayload(mount, encryptionKey: encryptionKey, ts: ts));
    }

    final works = <Map<String, Object?>>[];
    final outFiles = <Map<String, Object?>>[];
    final workPrefs = <Map<String, Object?>>[];
    final watchProgress = <Map<String, Object?>>[];

    final sharedIds = sharedMounts.map((m) => m.id).toSet();
    if (sharedIds.isNotEmpty) {
      final dbFiles = await (db.select(
        db.libraryFiles,
      )..where((t) => t.mountId.isIn(sharedIds) & t.matchState.isNotValue(LibraryMatchStates.ignored))).get();

      final filesById = <int, LibraryFileRow>{for (final f in dbFiles) f.id: f};
      final itemsCache = <int, LibraryItemRow>{};
      Future<LibraryItemRow?> tryLoadItem(int? id) async {
        if (id == null) return null;
        if (itemsCache.containsKey(id)) return itemsCache[id];
        final row = await (db.select(db.libraryItems)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row != null) itemsCache[id] = row;
        return row;
      }

      final exportedWorks = <String>{};
      final fileKeyByRowId = <int, String>{
        for (final f in dbFiles) f.id: DeterministicKeys.generateFileId(sourceId: f.mountId, mountRelativePath: f.path),
      };

      for (final file in dbFiles) {
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

        final String? workKey = await _resolveSyncWorkKey(workItem: workItem, repFile: file);
        final workRank = workItem != null ? MatchStatusRank.fromItem(workItem) : MatchStatusRank.fromFile(file);

        if (workItem != null && workKey != null && exportedWorks.add(workKey)) {
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
          final updatedAt = workItem.updatedAt > 0 ? workItem.updatedAt : ts;
          works.add({
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
          });
        }

        final fileId = fileKeyByRowId[file.id]!;
        final ep = item != null && item.kind == LibraryKinds.episode ? item : null;
        outFiles.add({
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
          'client_updated_at': ts,
          'is_deleted': false,
        });
      }

      for (final file in dbFiles) {
        if (file.role != LibraryFileRoles.subtitle) continue;
        final owner = file.ownerFileId == null ? null : filesById[file.ownerFileId];
        final ownerFileId = owner == null ? null : fileKeyByRowId[owner.id];
        final fileId = fileKeyByRowId[file.id]!;
        outFiles.add({
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
          'client_updated_at': ts,
          'is_deleted': false,
        });
      }
    }

    if (includeAllWorkStates) {
      final skipStore = WorkSkipSettingsStore(db);
      final stateStore = LibraryWatchStateStore(db);
      final allStates = await (db.select(
        db.workWatchStates,
      )..where((t) => t.source.equals(WorkIdentity.localSource))).get();
      final seenWorkPrefs = <String>{};

      Future<void> addPref(WorkIdentity identity, int updatedAt) async {
        final workKey = '${identity.provider}:${identity.kind}:${identity.externalId}';
        if (!seenWorkPrefs.add(workKey)) return;
        final skip = await skipStore.read(identity);
        final wholeState = await stateStore.read(identity.stateKey());
        workPrefs.add({
          'work_key': workKey,
          'intro_enabled': skip.introEnabled,
          'intro_start_ms': skip.introStartMs,
          'intro_end_ms': skip.introEndMs,
          'credits_enabled': skip.creditsEnabled,
          'credits_from_end_ms': skip.creditsDurationMs,
          'keep_easter_egg_ms': skip.creditsResumeBeforeEndMs,
          'is_favorite': wholeState?.favorite ?? false,
          'hidden_from_continue': wholeState?.hiddenFromContinue ?? false,
          'client_updated_at': updatedAt,
        });
      }

      for (final st in allStates) {
        final identity = WorkIdentity(
          source: st.source,
          kind: st.kind,
          provider: st.provider,
          externalId: st.externalId,
        );
        await addPref(identity, st.updatedAt);
        final workKey = '${st.provider}:${st.kind}:${st.externalId}';
        final progressKey = DeterministicKeys.generateProgressKey(
          workKey: workKey,
          kind: st.kind,
          seasonNum: st.seasonNumber,
          episodeNum: st.episodeNumber,
        );
        watchProgress.add({
          'progress_key': progressKey,
          'work_key': workKey,
          'season_num': st.seasonNumber,
          'episode_num': st.episodeNumber,
          'position_ms': st.positionMs,
          'duration_ms': st.durationMs ?? 0,
          'watched': st.watched,
          'play_count': st.playCount,
          'last_played_at': st.lastPlayedAt,
          'client_updated_at': st.updatedAt,
        });
      }

      final skipSettings = await (db.select(
        db.librarySettings,
      )..where((t) => t.key.like('work-skip:${WorkIdentity.localSource}:%'))).get();
      for (final row in skipSettings) {
        final parts = row.key.substring('work-skip:'.length).split(':');
        if (parts.length < 4) continue;
        await addPref(
          WorkIdentity(source: parts[0], kind: parts[1], provider: parts[2], externalId: parts[3]),
          ts,
        );
      }
    }

    final scraperSettings = await LibrarySettingsStore(db).loadScraper();
    final userSettings = <String, Object?>{
      if (scraperSettings.tmdbImageBase.isNotEmpty) 'tmdb_image_base_url': scraperSettings.tmdbImageBase,
    };

    return (
      ts: ts,
      sources: sources,
      works: works,
      files: outFiles,
      workPrefs: workPrefs,
      watchProgress: watchProgress,
      userSettings: userSettings,
    );
  }

  /// Exports shared mounts, works, files, skip preferences, and watch progress
  /// to `SyncOutbox` so a newly joined device receives a full zero-scan index.
  Future<void> enqueueSharedCatalog({
    required Uint8List masterKey,
    Set<String>? mountIds,
    bool includeAllWorkStates = true,
  }) async {
    final bundle = await _collectCatalogBundle(
      encryptionKey: masterKey,
      mountIds: mountIds,
      includeAllWorkStates: includeAllWorkStates,
    );
    for (final src in bundle.sources) {
      await syncStore.enqueue(
        entityType: SyncLocalStore.typeSource,
        entityKey: src['source_id'] as String,
        updatedAt: bundle.ts,
        payload: src,
      );
    }
    for (final w in bundle.works) {
      await syncStore.enqueue(
        entityType: SyncLocalStore.typeWork,
        entityKey: w['work_key'] as String,
        updatedAt: (w['client_updated_at'] as num?)?.toInt() ?? bundle.ts,
        payload: w,
      );
    }
    for (final f in bundle.files) {
      await syncStore.enqueue(
        entityType: SyncLocalStore.typeFile,
        entityKey: f['file_id'] as String,
        updatedAt: (f['client_updated_at'] as num?)?.toInt() ?? bundle.ts,
        payload: f,
      );
    }
    for (final p in bundle.workPrefs) {
      await syncStore.enqueue(
        entityType: SyncLocalStore.typeWorkPref,
        entityKey: p['work_key'] as String,
        updatedAt: (p['client_updated_at'] as num?)?.toInt() ?? bundle.ts,
        payload: p,
      );
    }
    for (final g in bundle.watchProgress) {
      await syncStore.enqueue(
        entityType: SyncLocalStore.typeWatchProgress,
        entityKey: g['progress_key'] as String,
        updatedAt: (g['client_updated_at'] as num?)?.toInt() ?? bundle.ts,
        payload: g,
      );
    }
  }

  /// Builds an E2EE snapshot bundle for direct serverless LAN P2P transfer
  /// without mutating `SyncOutbox`.
  Future<Map<String, Object?>> buildSnapshotBundle({required Uint8List encryptionKey}) async {
    final bundle = await _collectCatalogBundle(encryptionKey: encryptionKey, includeAllWorkStates: true);
    return {
      'server_time_ms': _nowMs(),
      'user_settings': bundle.userSettings,
      'sources': bundle.sources,
      'works': bundle.works,
      'files': bundle.files,
      'work_prefs': bundle.workPrefs,
      'watch_progress': bundle.watchProgress,
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

  /// Applies one paginated pull batch atomically into the local Drift database.
  /// Returns the count of touched entities.
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
  }) async {
    var changes = 0;

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

    final rehomedMounts = <(String, String)>[];
    final deletedMountIds = <String>[];
    final touchedItemIds = <int>{};
    final localWinnerRemaps = <String, String>{};

    await db.transaction(() async {
      // 1. Merge shared mounts & canonical source deduplication.
      changes += await _applyIncomingSources(
        sources,
        masterKey: masterKey,
        rehomedMounts: rehomedMounts,
        deletedMountIds: deletedMountIds,
        deterministicP2pSourceTieBreak: deterministicP2pSourceTieBreak,
        localWinnerRemaps: localWinnerRemaps,
      );

      // 2. Merge works & files under 4-tier monotonic weights.
      final workItemByKey = <String, int>{};
      final effectiveFiles = localWinnerRemaps.isEmpty ? files : _remapIncomingFiles(files, localWinnerRemaps);
      changes += await _applyIncomingWorks(works, workItemByKey: workItemByKey, touchedItemIds: touchedItemIds);
      changes += await _applyIncomingFiles(effectiveFiles, workItemByKey: workItemByKey, touchedItemIds: touchedItemIds);

      if (isFinalPage && changes > 0) {
        await repo.pruneEmptyTitles();
      }

      // 3. Merge work preferences (intro/credits skip + favorites) & calibrated LWW watch progress.
      changes += await _applyIncomingWorkPrefs(workPrefs, touchedItemIds: touchedItemIds);
      changes += await _applyIncomingWatchProgress(watchProgress, touchedItemIds: touchedItemIds);

      // Project updated WorkWatchStates onto local LibraryUserStates for all touched titles.
      final watchStates = LibraryWatchStateStore(db);
      for (final itemId in touchedItemIds) {
        await watchStates.restoreItemAndChildren(itemId);
      }
      if (workPrefs.isNotEmpty || watchProgress.isNotEmpty || works.isNotEmpty || effectiveFiles.isNotEmpty) {
        await watchStates.restoreAll();
      }

      // Advance cloud cursor ONLY during cloud pulls and after transactional persistence succeeds.
      if (updateCloudCursor) {
        await syncStore.saveLastPullSeq(nextSeq);
      }
    });

    for (final (oldId, newId) in rehomedMounts) {
      await mountManager.dropCachedDriver(oldId);
      await syncStore.rekeyOutboxForRemappedSource(oldId, newId);
    }
    for (final deletedId in deletedMountIds) {
      await mountManager.dropCachedDriver(deletedId);
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
  }) async {
    if (oldMountId == newMountId) return;
    await db.transaction(() async {
      await _rehomeMountTx(
        oldMountId: oldMountId,
        newMountId: newMountId,
        targetMount: targetMount,
        remoteCheckpoint: remoteCheckpoint,
      );
    });
    await mountManager.dropCachedDriver(oldMountId);
    await syncStore.rekeyOutboxForRemappedSource(oldMountId, newMountId);
  }

  Future<void> _rehomeMountTx({
    required String oldMountId,
    required String newMountId,
    StorageMount? targetMount,
    String? remoteCheckpoint,
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

    for (final oldFile in oldFiles) {
      final collision = targetByPath[oldFile.path];
      if (collision == null) {
        await (db.update(db.libraryFiles)..where((t) => t.id.equals(oldFile.id))).write(
          LibraryFilesCompanion(mountId: Value(newMountId)),
        );
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

    // Merge Quark checkpoints cleanly.
    final oldScan = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(oldMountId))).getSingleOrNull();
    final newScan = await (db.select(db.libraryScanStates)..where((t) => t.mountId.equals(newMountId))).getSingleOrNull();
    var mergedCp = mergeQuarkCheckpoint(oldScan?.quarkCheckpoint, newScan?.quarkCheckpoint);
    mergedCp = mergeQuarkCheckpoint(mergedCp, remoteCheckpoint);
    if (mergedCp != null) {
      await db
          .into(db.libraryScanStates)
          .insertOnConflictUpdate(
            LibraryScanStatesCompanion.insert(mountId: newMountId, quarkCheckpoint: Value(mergedCp)),
          );
    }
    await (db.delete(db.libraryScanStates)..where((t) => t.mountId.equals(oldMountId))).go();

    // Remove the superseded old Mount row last (zero foreign-key children remain).
    await (db.delete(db.mounts)..where((t) => t.id.equals(oldMountId))).go();
  }

  Future<int> _applyIncomingSources(
    List<Map<String, dynamic>> rawSources, {
    required Uint8List masterKey,
    required List<(String, String)> rehomedMounts,
    required List<String> deletedMountIds,
    required bool deterministicP2pSourceTieBreak,
    required Map<String, String> localWinnerRemaps,
  }) async {
    var count = 0;
    final currentMounts = await mountManager.registry.list();
    final byId = {for (final m in currentMounts) m.id: m};
    final byCanonical = {for (final m in currentMounts) DeterministicKeys.canonicalSourceKey(m): m};

    for (final src in rawSources) {
      final sourceId = src['source_id'] as String?;
      if (sourceId == null || sourceId.isEmpty) continue;
      count++;

      if (src['is_deleted'] == true) {
        if (byId.containsKey(sourceId)) {
          await (db.delete(db.mounts)..where((t) => t.id.equals(sourceId))).go();
          deletedMountIds.add(sourceId);
        }
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
      }

      final remoteCreatedAt = (src['created_at'] as num?)?.toInt();
      final incomingCreatedAt = existingByCanonical?.createdAt ??
          (remoteCreatedAt != null && remoteCreatedAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(remoteCreatedAt)
              : DateTime.fromMillisecondsSinceEpoch(_nowMs()));

      final incomingMount = StorageMount(
        id: sourceId,
        kind: kind,
        displayName: (src['name'] as String?)?.trim().isNotEmpty == true ? src['name'] as String : kind.id,
        config: config,
        secrets: secrets,
        createdAt: incomingCreatedAt,
      );

      final remoteCp = src['quark_checkpoint'] as String?;
      var resolvedMountId = sourceId;
      if (existingByCanonical != null && existingByCanonical.id != sourceId) {
        final remoteWins = !deterministicP2pSourceTieBreak ||
            _remoteSourceWinsTieBreak(
              remoteId: sourceId,
              remoteCreatedAt: remoteCreatedAt,
              local: existingByCanonical,
            );
        if (remoteWins) {
          rehomedMounts.add((existingByCanonical.id, sourceId));
          await _rehomeMountTx(
            oldMountId: existingByCanonical.id,
            newMountId: sourceId,
            targetMount: incomingMount,
            remoteCheckpoint: remoteCp,
          );
          byId.remove(existingByCanonical.id);
          byId[sourceId] = incomingMount;
          if (canonicalKey.isNotEmpty) byCanonical[canonicalKey] = incomingMount;
        } else {
          resolvedMountId = existingByCanonical.id;
          localWinnerRemaps[sourceId] = resolvedMountId;
          final mergedLocal = StorageMount(
            id: resolvedMountId,
            kind: existingByCanonical.kind,
            displayName: existingByCanonical.displayName,
            config: existingByCanonical.config,
            secrets: existingByCanonical.secrets.isNotEmpty ? existingByCanonical.secrets : secrets,
            createdAt: existingByCanonical.createdAt,
          );
          await mountManager.registry.upsert(mergedLocal);
          if (remoteCp != null && remoteCp.isNotEmpty) {
            final curScan = await (db.select(
              db.libraryScanStates,
            )..where((t) => t.mountId.equals(resolvedMountId))).getSingleOrNull();
            final mergedCp = mergeQuarkCheckpoint(curScan?.quarkCheckpoint, remoteCp);
            if (mergedCp != null) {
              await db
                  .into(db.libraryScanStates)
                  .insertOnConflictUpdate(
                    LibraryScanStatesCompanion.insert(mountId: resolvedMountId, quarkCheckpoint: Value(mergedCp)),
                  );
            }
          }
          byId[resolvedMountId] = mergedLocal;
          if (canonicalKey.isNotEmpty) byCanonical[canonicalKey] = mergedLocal;
        }
      } else {
        await mountManager.registry.upsert(incomingMount);
        if (remoteCp != null && remoteCp.isNotEmpty) {
          final curScan = await (db.select(
            db.libraryScanStates,
          )..where((t) => t.mountId.equals(sourceId))).getSingleOrNull();
          final mergedCp = mergeQuarkCheckpoint(curScan?.quarkCheckpoint, remoteCp);
          if (mergedCp != null) {
            await db
                .into(db.libraryScanStates)
                .insertOnConflictUpdate(
                  LibraryScanStatesCompanion.insert(mountId: sourceId, quarkCheckpoint: Value(mergedCp)),
                );
          }
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
    }
    return count;
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

  Future<int> _applyIncomingWorks(
    List<Map<String, dynamic>> rawWorks, {
    required Map<String, int> workItemByKey,
    required Set<int> touchedItemIds,
  }) async {
    var count = 0;
    for (final w in rawWorks) {
      final workKey = w['work_key'] as String?;
      final kind = w['kind'] as String?;
      if (workKey == null || workKey.isEmpty || kind == null || kind.isEmpty) continue;
      count++;

      final meta = _mapOf(w['metadata_json']);
      final tmdbId = meta['tmdb_id'] as String?;
      final bangumiId = meta['bangumi_id'] as String?;
      final imdbId = meta['imdb_id'] as String?;
      final title = (meta['title'] as String?) ?? workKey;
      final year = (meta['year'] as num?)?.toInt();
      final remoteStatus = (w['match_status'] as num?)?.toInt() ?? MatchStatusRank.matched;
      final remoteUpdatedAt = (w['client_updated_at'] as num?)?.toInt() ?? _nowMs();
      final remoteDeleted = w['is_deleted'] == true;

      var existing = await _findExistingWorkItem(
        kind: kind,
        tmdbId: tmdbId,
        bangumiId: bangumiId,
        imdbId: imdbId,
        title: title,
        year: year,
      );

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
          if (remoteDeleted) {
            await repo.deleteItem(existing.id);
            existing = null;
          } else {
            await repo.updateItem(existing.id, _buildWorkCompanionUpdate(w, meta));
            await _applyWorkRelations(existing.id, meta);
            touchedItemIds.add(existing.id);
          }
        }
      } else if (!remoteDeleted) {
        final newId = await repo.insertItem(_buildWorkCompanionInsert(w, meta));
        await _applyWorkRelations(newId, meta);
        existing = (await repo.getItem(newId))?.item;
        touchedItemIds.add(newId);
      }

      if (existing != null) {
        workItemByKey[workKey] = existing.id;
      }
    }
    return count;
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

  Future<int> _applyIncomingFiles(
    List<Map<String, dynamic>> rawFiles, {
    required Map<String, int> workItemByKey,
    required Set<int> touchedItemIds,
  }) async {
    var count = 0;
    final rowIdBySyncFileId = <String, int>{};

    final videos = [
      for (final f in rawFiles)
        if ((f['role'] as String? ?? LibraryFileRoles.video) != LibraryFileRoles.subtitle) f,
    ];
    final subtitles = [
      for (final f in rawFiles)
        if (f['role'] == LibraryFileRoles.subtitle) f,
    ];

    for (final f in videos) {
      count++;
      final rowId = await _applySingleFile(f, workItemByKey: workItemByKey, touchedItemIds: touchedItemIds);
      final fileId = f['file_id'] as String?;
      if (rowId != null && fileId != null) {
        rowIdBySyncFileId[fileId] = rowId;
      }
    }

    for (final f in subtitles) {
      count++;
      final ownerSyncId = f['owner_file_id'] as String?;
      int? ownerRowId = ownerSyncId == null ? null : rowIdBySyncFileId[ownerSyncId];
      if (ownerRowId == null && ownerSyncId != null) {
        final mountId = f['source_id'] as String?;
        if (mountId != null) {
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
      }
      await _applySingleFile(
        f,
        workItemByKey: workItemByKey,
        touchedItemIds: touchedItemIds,
        ownerRowIdOverride: ownerRowId,
      );
    }

    return count;
  }

  Future<int?> _applySingleFile(
    Map<String, dynamic> f, {
    required Map<String, int> workItemByKey,
    required Set<int> touchedItemIds,
    int? ownerRowIdOverride,
  }) async {
    final mountId = f['source_id'] as String?;
    final rawPath = f['relative_path'] as String?;
    if (mountId == null || mountId.isEmpty || rawPath == null || rawPath.isEmpty) return null;

    final mountExists = await (db.select(db.mounts)..where((t) => t.id.equals(mountId))).getSingleOrNull();
    if (mountExists == null) return null;

    final path = DeterministicKeys.normalizeMountPath(rawPath);
    final role = (f['role'] as String?) ?? LibraryFileRoles.video;
    final existing = await (db.select(
      db.libraryFiles,
    )..where((t) => t.mountId.equals(mountId) & t.path.equals(path))).getSingleOrNull();

    final remoteDeleted = f['is_deleted'] == true;
    final remoteUpdatedAt = (f['client_updated_at'] as num?)?.toInt() ?? _nowMs();
    final remoteMatchStatus = (f['match_status'] as num?)?.toInt() ?? MatchStatusRank.pending;

    if (existing != null) {
      final canOverride = shouldOverrideEntity(
        remoteDeleted: remoteDeleted,
        localDeleted: false,
        remoteMatchStatus: remoteMatchStatus,
        localMatchStatus: MatchStatusRank.fromFile(existing),
        remoteUpdatedAt: remoteUpdatedAt,
        localUpdatedAt: existing.addedAt,
        explicitUnlock: f['explicit_unlock'] == true,
      );
      if (!canOverride) return existing.id;
      if (remoteDeleted) {
        await (db.delete(db.libraryFiles)..where((t) => t.id.equals(existing.id))).go();
        return null;
      }
    } else if (remoteDeleted) {
      return null;
    }

    final fileRowId = await repo.upsertFile(
      mountId: mountId,
      path: path,
      role: role,
      scanId: 0,
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

    return fileRowId;
  }

  Future<int?> _resolveWorkItemId(String workKey, Map<String, int> cache) async {
    if (cache.containsKey(workKey)) return cache[workKey];
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
          metadataSource: Value(spec['ep_metadata_source'] as String? ?? show.metadataSource),
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
        updatedAt: Value(updatedAt),
      ),
    );
    return ep.id;
  }

  Future<int> _applyIncomingWorkPrefs(
    List<Map<String, dynamic>> rawPrefs, {
    required Set<int> touchedItemIds,
  }) async {
    var count = 0;
    final skipStore = WorkSkipSettingsStore(db);
    for (final p in rawPrefs) {
      final workKey = p['work_key'] as String?;
      if (workKey == null || workKey.isEmpty) continue;
      final parts = workKey.split(':');
      if (parts.length < 3) continue;
      final provider = parts[0];
      if (provider == 'raw') continue;
      count++;

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
      if (remoteUpdatedAt < localStamp) continue;

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
      } else if (remoteUpdatedAt >= existingState.updatedAt) {
        await (db.update(db.workWatchStates)..where((t) => t.stateKey.equals(stateKey))).write(
          WorkWatchStatesCompanion(
            favorite: Value(favorite),
            hiddenFromContinue: Value(hidden),
            updatedAt: Value(remoteUpdatedAt),
          ),
        );
      }

      await db
          .into(db.librarySettings)
          .insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: stampKey, value: '$remoteUpdatedAt'));

      final item = await _findExistingWorkItem(kind: kind, tmdbId: provider == 'tmdb' ? externalId : null, bangumiId: provider == 'bangumi' ? externalId : null, imdbId: provider == 'imdb' ? externalId : null, title: '');
      if (item != null) touchedItemIds.add(item.id);
    }
    return count;
  }

  Future<int> _applyIncomingWatchProgress(
    List<Map<String, dynamic>> rawProgress, {
    required Set<int> touchedItemIds,
  }) async {
    var count = 0;
    for (final g in rawProgress) {
      final workKey = g['work_key'] as String?;
      if (workKey == null || workKey.isEmpty) continue;
      final parts = workKey.split(':');
      if (parts.length < 3 || parts[0] == 'raw') continue;
      count++;

      final provider = parts[0];
      final kind = parts[1];
      final externalId = parts.sublist(2).join(':');
      final seasonNum = (g['season_num'] as num?)?.toInt() ?? -1;
      final episodeNum = (g['episode_num'] as num?)?.toInt() ?? -1;
      final remoteUpdatedAt = (g['client_updated_at'] as num?)?.toInt() ?? 0;

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
      if (existing != null && remoteUpdatedAt < existing.updatedAt) continue;

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
              updatedAt: remoteUpdatedAt,
            ),
          );

      final item = await _findExistingWorkItem(
        kind: kind,
        tmdbId: provider == 'tmdb' ? externalId : null,
        bangumiId: provider == 'bangumi' ? externalId : null,
        imdbId: provider == 'imdb' ? externalId : null,
        title: '',
      );
      if (item != null) touchedItemIds.add(item.id);
    }
    return count;
  }

  static Map<String, Object?> _mapOf(Object? raw) =>
      raw is Map ? {for (final entry in raw.entries) '${entry.key}': entry.value} : const {};
}
