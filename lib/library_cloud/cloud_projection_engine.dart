import 'dart:async';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../library/deterministic_keys.dart';
import '../library/library_repository.dart';
import '../utils/app_logger.dart';
import 'cloud_mount_mirror.dart';
import 'projection_sync.dart';

class CloudSyncResult {
  const CloudSyncResult({
    required this.fullReset,
    required this.latestSeq,
    required this.itemsProjected,
    required this.filesProjected,
    required this.emptyShellsPruned,
  });

  final bool fullReset;
  final int latestSeq;
  final int itemsProjected;
  final int filesProjected;
  final int emptyShellsPruned;
}

/// Projects `media_library` S5 snapshots, incremental changes, and playback
/// states into the local Drift database (`LibraryItems`, `LibraryFiles`,
/// `LibraryUserStates`) so existing UI & [LocalLibraryClient] render a unified
/// direct-play library (C3).
class CloudProjectionEngine {
  CloudProjectionEngine({
    required this.db,
    required this.syncClient,
    required this.mountMirror,
    this.onLibraryUpdated,
  });

  final AppDatabase db;
  final CloudProjectionSyncClient syncClient;
  final CloudMountMirror mountMirror;
  final void Function()? onLibraryUpdated;

  int _lastSeq = 0;
  bool _syncing = false;
  StreamSubscription<CloudSseEvent>? _sseSub;
  Timer? _debounceTimer;

  int get lastSeq => _lastSeq;
  bool get isSyncing => _syncing;

  /// Runs a full cloud-to-local snapshot projection:
  /// 1. Mirrors cloud sources & E2EE credentials into [MountRegistry].
  /// 2. Pulls paginated movies/shows/seasons/episodes & item file locators.
  /// 3. Projects into `LibraryItems` & `LibraryFiles`, preserving local-folder
  ///    files and pruning stale cloud files + empty shells.
  Future<CloudSyncResult> syncFullSnapshot() async {
    if (_syncing) {
      return CloudSyncResult(
        fullReset: false,
        latestSeq: _lastSeq,
        itemsProjected: 0,
        filesProjected: 0,
        emptyShellsPruned: 0,
      );
    }
    _syncing = true;
    try {
      await mountMirror.mirrorAllSources();

      var snapshotSeq = _lastSeq;
      final serverIdToLocalId = <int, int>{};
      final projectedCloudFileKeys = <String>{};
      var itemsCount = 0;
      var filesCount = 0;

      // Project in dependency order so parentId/showId resolve cleanly.
      for (final kind in const ['movie', 'show', 'season', 'episode']) {
        var page = 1;
        while (true) {
          final snap = await syncClient.fetchSnapshot(kind: kind, page: page, pageSize: 100);
          if (snap.snapshotSeq > snapshotSeq) snapshotSeq = snap.snapshotSeq;

          for (final raw in snap.items) {
            final serverId = (raw['id'] as num?)?.toInt() ?? 0;
            if (serverId <= 0) continue;

            final localId = await _upsertProjectedItem(raw, serverIdToLocalId);
            serverIdToLocalId[serverId] = localId;
            itemsCount++;

            if (kind == 'movie' || kind == 'episode') {
              final detail = await syncClient.fetchItemDetail(serverId);
              final filesRaw = detail['files'];
              if (filesRaw is List) {
                for (final f in filesRaw) {
                  if (f is! Map) continue;
                  final fMap = Map<String, dynamic>.from(f);
                  final fileKey = await _upsertProjectedFile(localId, fMap);
                  if (fileKey != null) {
                    projectedCloudFileKeys.add(fileKey);
                    filesCount++;
                  }
                }
              }
            }
          }

          if (!snap.hasMore) break;
          page++;
        }
      }

      // Remove stale cloud files no longer present in the cloud snapshot.
      await _pruneStaleCloudFiles(projectedCloudFileKeys);
      final pruned = await pruneEmptyProjectedItems();

      await _syncUserStateFromServer();

      _lastSeq = snapshotSeq;
      onLibraryUpdated?.call();

      return CloudSyncResult(
        fullReset: true,
        latestSeq: _lastSeq,
        itemsProjected: itemsCount,
        filesProjected: filesCount,
        emptyShellsPruned: pruned,
      );
    } finally {
      _syncing = false;
    }
  }

  /// Pulls incremental `/api/v1/library/changes?since_seq=...` and falls back to
  /// [syncFullSnapshot] when `reset_required` is signaled (e.g. cursor too old
  /// or permission change).
  Future<CloudSyncResult> syncIncremental() async {
    if (_lastSeq <= 0) {
      return syncFullSnapshot();
    }
    if (_syncing) {
      return CloudSyncResult(
        fullReset: false,
        latestSeq: _lastSeq,
        itemsProjected: 0,
        filesProjected: 0,
        emptyShellsPruned: 0,
      );
    }
    final changesPage = await syncClient.fetchChanges(sinceSeq: _lastSeq, limit: 200);
    if (changesPage.resetRequired) {
      return syncFullSnapshot();
    }
    if (changesPage.changes.isEmpty) {
      if (changesPage.latestSeq > _lastSeq) _lastSeq = changesPage.latestSeq;
      return CloudSyncResult(
        fullReset: false,
        latestSeq: _lastSeq,
        itemsProjected: 0,
        filesProjected: 0,
        emptyShellsPruned: 0,
      );
    }

    // For V1, apply any source/library changes cleanly by refreshing snapshot
    // (or targeted user-data sync when only user data changed).
    final hasLibraryOrSourceChange = changesPage.changes.any((c) {
      final entity = (c['entity'] as String? ?? '').toLowerCase();
      return entity == 'item' || entity == 'file' || entity == 'source' || entity == 'folder';
    });
    if (hasLibraryOrSourceChange) {
      return syncFullSnapshot();
    }

    await _syncUserStateFromServer();
    _lastSeq = changesPage.nextSinceSeq > _lastSeq ? changesPage.nextSinceSeq : changesPage.latestSeq;
    onLibraryUpdated?.call();

    return CloudSyncResult(
      fullReset: false,
      latestSeq: _lastSeq,
      itemsProjected: 0,
      filesProjected: 0,
      emptyShellsPruned: 0,
    );
  }

  /// Removes any projected movie/episode/season/show that has zero remaining
  /// files in `LibraryFiles` (prevents empty-shell cards after single-source
  /// file deletion).
  Future<int> pruneEmptyProjectedItems() async {
    var removed = 0;

    // 1. Movies and episodes with no associated LibraryFiles
    final leafRows = await (db.select(db.libraryItems)
          ..where((t) => t.kind.isIn(const [LibraryKinds.movie, LibraryKinds.episode])))
        .get();
    for (final row in leafRows) {
      final fileCount = await (db.select(db.libraryFiles)..where((f) => f.itemId.equals(row.id))).get();
      if (fileCount.isEmpty) {
        await (db.delete(db.libraryItems)..where((t) => t.id.equals(row.id))).go();
        removed++;
      }
    }

    // 2. Seasons with zero remaining child episodes
    final seasonRows = await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.season))).get();
    for (final s in seasonRows) {
      final children = await (db.select(db.libraryItems)..where((t) => t.parentId.equals(s.id))).get();
      if (children.isEmpty) {
        await (db.delete(db.libraryItems)..where((t) => t.id.equals(s.id))).go();
        removed++;
      }
    }

    // 3. Shows with zero remaining seasons/episodes
    final showRows = await (db.select(db.libraryItems)..where((t) => t.kind.equals(LibraryKinds.show))).get();
    for (final sh in showRows) {
      final children = await (db.select(db.libraryItems)..where((t) => t.showId.equals(sh.id))).get();
      if (children.isEmpty) {
        await (db.delete(db.libraryItems)..where((t) => t.id.equals(sh.id))).go();
        removed++;
      }
    }

    return removed;
  }

  /// Subscribes to `/api/v1/events` SSE and triggers debounced incremental sync.
  void startListeningEvents() {
    stopListeningEvents();
    _sseSub = syncClient.watchEvents().listen(
      (event) {
        if (event.type == 'library.changed' ||
            event.type == 'source.changed' ||
            event.type == 'userdata.changed' ||
            event.type == 'credential.status') {
          _debounceTimer?.cancel();
          _debounceTimer = Timer(const Duration(milliseconds: 600), () {
            unawaited(syncIncremental().catchError((Object e) {
              appLogger.w('CloudProjectionEngine incremental sync failed: $e');
              return CloudSyncResult(
                fullReset: false,
                latestSeq: _lastSeq,
                itemsProjected: 0,
                filesProjected: 0,
                emptyShellsPruned: 0,
              );
            }));
          });
        }
      },
      onError: (Object err) {
        appLogger.d('CloudProjectionEngine SSE disconnected: $err');
      },
    );
  }

  void stopListeningEvents() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_sseSub?.cancel());
    _sseSub = null;
  }

  Future<int> _upsertProjectedItem(Map<String, dynamic> raw, Map<int, int> serverIdToLocalId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final kind = (raw['kind'] as String? ?? 'movie').toLowerCase();
    final libraryType = (raw['library_type'] as String? ?? kind).toLowerCase();
    final title = (raw['title'] as String? ?? '').trim();
    final sortTitle = ((raw['sort_title'] as String?)?.trim().isNotEmpty == true)
        ? (raw['sort_title'] as String).trim()
        : title.toLowerCase();
    final rawWorkKey = (raw['work_key'] as String? ?? '').trim();
    final workKey = rawWorkKey.isNotEmpty
        ? DeterministicKeys.canonicalizeWorkKey(rawWorkKey)
        : 'cloud:${raw['id']}';

    final serverParentId = (raw['parent_id'] as num?)?.toInt();
    final serverShowId = (raw['show_id'] as num?)?.toInt();
    final localParentId = serverParentId != null ? serverIdToLocalId[serverParentId] : null;
    final localShowId = serverShowId != null ? serverIdToLocalId[serverShowId] : null;

    final existing = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(workKey))).getSingleOrNull();
    final companion = LibraryItemsCompanion(
      workKey: Value(workKey),
      kind: Value(kind),
      libraryType: Value(libraryType),
      parentId: Value(localParentId),
      showId: Value(localShowId),
      title: Value(title),
      sortTitle: Value(sortTitle),
      originalTitle: Value(raw['original_title'] as String?),
      year: Value((raw['year'] as num?)?.toInt()),
      releaseDate: Value(raw['release_date'] as String?),
      summary: Value(raw['summary'] as String?),
      contentRating: Value(raw['content_rating'] as String?),
      rating: Value((raw['rating'] as num?)?.toDouble()),
      runtimeMs: Value((raw['runtime_ms'] as num?)?.toInt()),
      seasonNumber: Value((raw['season_number'] as num?)?.toInt()),
      episodeNumber: Value((raw['episode_number'] as num?)?.toInt()),
      posterSource: Value((raw['poster_url'] as String?) ?? (raw['poster_source'] as String?)),
      backdropSource: Value((raw['backdrop_url'] as String?) ?? (raw['backdrop_source'] as String?)),
      addedAt: Value((raw['added_at'] as num?)?.toInt() ?? nowMs),
      updatedAt: Value((raw['updated_at'] as num?)?.toInt() ?? nowMs),
    );

    if (existing != null) {
      await (db.update(db.libraryItems)..where((t) => t.id.equals(existing.id))).write(companion);
      return existing.id;
    }
    return db.into(db.libraryItems).insert(companion);
  }

  Future<String?> _upsertProjectedFile(int localItemId, Map<String, dynamic> raw) async {
    final sourceId = (raw['source_id'] as String? ?? '').trim();
    final path = (raw['path'] as String? ?? '').trim();
    if (sourceId.isEmpty || path.isEmpty) return null;

    final mountId = CloudMountMirror.mountIdForSource(sourceId);
    final mountExists = await (db.select(db.mounts)..where((m) => m.id.equals(mountId))).getSingleOrNull();
    if (mountExists == null) return null;

    final fileKey = DeterministicKeys.generateFileId(sourceId: mountId, mountRelativePath: path);
    final existing = await (db.select(db.libraryFiles)..where((f) => f.fileKey.equals(fileKey))).getSingleOrNull();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final companion = LibraryFilesCompanion(
      fileKey: Value(fileKey),
      mountId: Value(mountId),
      path: Value(path),
      remoteId: Value(raw['remote_id'] as String?),
      size: Value((raw['size'] as num?)?.toInt()),
      modifiedAt: Value((raw['mtime_s'] as num?)?.toInt()),
      role: Value((raw['role'] as String? ?? LibraryFileRoles.video).toLowerCase()),
      itemId: Value(localItemId),
      matchState: const Value(LibraryMatchStates.matched),
      versionLabel: Value(raw['version_label'] as String?),
      language: Value(raw['language'] as String?),
      addedAt: Value((raw['added_at'] as num?)?.toInt() ?? nowMs),
    );

    if (existing != null) {
      await (db.update(db.libraryFiles)..where((f) => f.id.equals(existing.id))).write(companion);
    } else {
      await db.into(db.libraryFiles).insert(companion);
    }
    return fileKey;
  }

  Future<void> _pruneStaleCloudFiles(Set<String> keepFileKeys) async {
    final cloudFiles = await (db.select(db.libraryFiles)
          ..where((f) => f.mountId.like('${CloudMountMirror.cloudMountPrefix}%')))
        .get();
    for (final f in cloudFiles) {
      final key = f.fileKey;
      if (key == null || !keepFileKeys.contains(key)) {
        await (db.delete(db.libraryFiles)..where((t) => t.id.equals(f.id))).go();
      }
    }
  }

  Future<void> _syncUserStateFromServer() async {
    try {
      final (progressList, favList) = await (syncClient.listProgress(limit: 500), syncClient.listFavorites()).wait;
      final favKeys = <String>{
        for (final f in favList)
          if ((f['work_key'] as String?)?.isNotEmpty == true)
            DeterministicKeys.canonicalizeWorkKey(f['work_key'] as String),
      };

      for (final p in progressList) {
        final rawWk = (p['work_key'] as String? ?? '').trim();
        if (rawWk.isEmpty) continue;
        final wk = DeterministicKeys.canonicalizeWorkKey(rawWk);
        final item = await (db.select(db.libraryItems)..where((t) => t.workKey.equals(wk))).getSingleOrNull();
        if (item == null) continue;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await db.into(db.libraryUserStates).insertOnConflictUpdate(
          LibraryUserStatesCompanion(
            itemId: Value(item.id),
            positionMs: Value((p['position_ms'] as num?)?.toInt() ?? 0),
            watched: Value(p['watched'] == true),
            playCount: Value((p['play_count'] as num?)?.toInt() ?? 0),
            lastPlayedAt: Value((p['last_played_at'] as num?)?.toInt()),
            favorite: Value(favKeys.contains(wk)),
            updatedAt: Value((p['updated_at'] as num?)?.toInt() ?? nowMs),
          ),
        );
      }
    } catch (e) {
      appLogger.d('CloudProjectionEngine: skipped user state sync: $e');
    }
  }
}
