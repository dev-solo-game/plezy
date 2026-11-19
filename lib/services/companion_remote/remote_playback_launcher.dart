import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../library/library_repository.dart';
import '../../library/local_library_client.dart';
import '../../library/deterministic_keys.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../models/companion_remote/remote_playback_models.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../providers/multi_server_provider.dart';
import '../../screens/video_player_screen.dart';
import '../../storage/mount_manager.dart';
import '../../storage/mount_registry.dart';
import '../../storage/storage_mount.dart';
import '../../utils/app_logger.dart';
import '../../utils/video_player_navigation.dart';
import '../settings_service.dart';
import 'companion_remote_receiver.dart';
import 'remote_host_catalog_handler.dart';

T? _readOptional<T>(BuildContext context) {
  try {
    return Provider.of<T?>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Builds a device-independent [RemoteMediaTarget] for handoff to another
/// Plezy device without relying on device-local SQLite row IDs.
Future<RemoteMediaTarget> buildRemoteMediaTarget({
  required MediaItem metadata,
  MediaServerClient? client,
  AppDatabase? db,
  MountManager? mountManager,
  int? selectedMediaIndex,
  int? positionMs,
  double? playbackRate,
  String? streamQuality,
}) async {
  final kind = metadata.kind == MediaKind.episode ? 'episode' : 'movie';
  final posterUrl = resolveRemoteReachablePosterUrl(client, metadata);

  if (metadata.serverId == LocalLibraryClient.localServerId && db != null) {
    final itemId = int.tryParse(metadata.id);
    if (itemId != null) {
      final itemRow = await (db.select(db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
      final showRow = (itemRow?.showId != null)
          ? await (db.select(db.libraryItems)..where((t) => t.id.equals(itemRow!.showId!))).getSingleOrNull()
          : null;
      final videoFiles =
          await (db.select(db.libraryFiles)
                ..where((t) => t.itemId.equals(itemId) & t.role.equals(LibraryFileRoles.video))
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get();

      LibraryFileRow? chosenFile;
      if (videoFiles.isNotEmpty) {
        final idx = (selectedMediaIndex ?? 0).clamp(0, videoFiles.length - 1);
        chosenFile = videoFiles[idx];
      }

      String? syncFileId;
      String? canonicalSourceKey;
      String? mountRelativePath;
      if (chosenFile != null) {
        final mountRow = await (db.select(db.mounts)..where((t) => t.id.equals(chosenFile!.mountId))).getSingleOrNull();
        final registry = mountManager?.registry ?? MountRegistry(db);
        final storageMount = await registry.get(chosenFile.mountId);
        final mountKind = storageMount?.kind ?? (mountRow == null ? null : StorageKind.fromId(mountRow.kind));
        if (mountKind != StorageKind.local) {
          syncFileId = DeterministicKeys.generateFileId(
            sourceId: chosenFile.mountId,
            mountRelativePath: chosenFile.path,
          );
          mountRelativePath = DeterministicKeys.normalizeMountPath(chosenFile.path);
          if (storageMount != null) {
            canonicalSourceKey = DeterministicKeys.canonicalSourceKey(storageMount);
          }
        }
      }

      final workRow = showRow ?? itemRow;
      final workKey = _workKeyForRow(workRow, chosenFile);

      return RemoteMediaTarget(
        kind: kind,
        title: metadata.title ?? '',
        seriesTitle: metadata.grandparentTitle ?? showRow?.title,
        posterUrl: posterUrl,
        syncFileId: syncFileId,
        canonicalSourceKey: canonicalSourceKey,
        mountRelativePath: mountRelativePath,
        workKey: workKey,
        seasonNumber: itemRow?.seasonNumber ?? metadata.parentIndex,
        episodeNumber: itemRow?.episodeNumber ?? metadata.index,
        positionMs: positionMs ?? metadata.viewOffsetMs,
        playbackRate: playbackRate,
        streamQuality: streamQuality,
      );
    }
  }

  return RemoteMediaTarget(
    kind: kind,
    title: metadata.title ?? '',
    seriesTitle: metadata.grandparentTitle,
    posterUrl: posterUrl,
    seasonNumber: metadata.parentIndex,
    episodeNumber: metadata.index,
    positionMs: positionMs ?? metadata.viewOffsetMs,
    playbackRate: playbackRate,
    streamQuality: streamQuality,
    remoteServerBackend: metadata.backend.id,
    remoteServerId: metadata.serverId,
    remoteItemId: metadata.id,
  );
}

String? _workKeyForRow(LibraryItemRow? row, LibraryFileRow? file) {
  if (row == null) return null;
  final workKind = row.kind == LibraryKinds.movie ? 'movie' : 'show';
  final tmdb = row.tmdbId?.trim();
  if (tmdb != null && tmdb.isNotEmpty) return 'tmdb:$workKind:$tmdb';
  final imdb = row.imdbId?.trim();
  if (imdb != null && imdb.isNotEmpty) return 'imdb:$workKind:$imdb';
  final bangumi = row.bangumiId?.trim();
  if (bangumi != null && bangumi.isNotEmpty) return 'bangumi:$workKind:$bangumi';
  if (file != null) {
    final norm = DeterministicKeys.normalizeMountPath(file.path);
    final fileName = norm.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => norm);
    return DeterministicKeys.generateWorkKey(
      matchStatus: 0,
      kind: workKind,
      fileName: fileName,
      fileSize: file.size ?? 0,
    );
  }
  return null;
}

typedef ResolvedRemoteTarget = ({MediaItem item, int? mediaIndex, String? mediaSourceId});

/// Resolves [target] against the host's local library (or shared media server)
/// using deterministic identifiers (`syncFileId`, `canonicalSourceKey`, `workKey`).
Future<ResolvedRemoteTarget?> resolveRemoteMediaTargetLocally({
  required RemoteMediaTarget target,
  required AppDatabase db,
  required LocalLibraryClient? localClient,
  MountManager? mountManager,
  MediaServerClient? Function(String serverId)? remoteClientLookup,
}) async {
  if (localClient != null) {
    // Priority 1: Exact file match by deterministic syncFileId (same mount ID + normalized path)
    if (target.syncFileId != null && target.syncFileId!.isNotEmpty) {
      final videoFiles = await (db.select(
        db.libraryFiles,
      )..where((t) => t.role.equals(LibraryFileRoles.video) & t.itemId.isNotNull())).get();

      for (final file in videoFiles) {
        final candidateId = DeterministicKeys.generateFileId(sourceId: file.mountId, mountRelativePath: file.path);
        if (candidateId == target.syncFileId) {
          final item = await localClient.fetchItem('${file.itemId}');
          if (item != null) {
            return _withMatchedFile(item, file);
          }
        }
      }

      // Secondary file fallback: same canonical mount + relative path when mounts were added separately
      if (target.canonicalSourceKey != null && target.mountRelativePath != null) {
        final registry = mountManager?.registry ?? MountRegistry(db);
        final mounts = await registry.list();
        final matchingMountIds = {
          for (final m in mounts)
            if (DeterministicKeys.canonicalSourceKey(m) == target.canonicalSourceKey) m.id,
        };
        if (matchingMountIds.isNotEmpty) {
          for (final file in videoFiles) {
            if (!matchingMountIds.contains(file.mountId)) continue;
            if (DeterministicKeys.normalizeMountPath(file.path) == target.mountRelativePath) {
              final item = await localClient.fetchItem('${file.itemId}');
              if (item != null) {
                return _withMatchedFile(item, file);
              }
            }
          }
        }
      }
    }

    // Priority 2: Semantic workKey match (+ seasonNumber & episodeNumber for episodes)
    final workKey = target.workKey;
    if (workKey != null && workKey.isNotEmpty) {
      final resolvedItemId = await _resolveItemIdByWorkKey(db, workKey, target);
      if (resolvedItemId != null) {
        final item = await localClient.fetchItem('$resolvedItemId');
        if (item != null) {
          return (item: item, mediaIndex: null, mediaSourceId: null);
        }
      }
    }
  }

  // Priority 3: Shared server item (local-library, ttplay-server, ttplay-ext, Plex, Jellyfin)
  if (target.remoteServerId != null && target.remoteItemId != null) {
    final client =
        remoteClientLookup?.call(target.remoteServerId!) ??
        (target.remoteServerId == LocalLibraryClient.localServerId ? localClient : null);
    if (client != null) {
      final item = await client.fetchItem(target.remoteItemId!);
      if (item != null) {
        final playable = await _resolvePlayableMediaItem(client, item);
        if (playable != null) {
          return (item: playable, mediaIndex: null, mediaSourceId: null);
        }
      }
    }
  }

  return null;
}

Future<MediaItem?> _resolvePlayableMediaItem(MediaServerClient client, MediaItem item) async {
  if (item.kind == MediaKind.movie || item.kind == MediaKind.episode || item.kind == MediaKind.clip) {
    return item;
  }
  if (item.kind == MediaKind.show) {
    try {
      final withOnDeck = await client.fetchItemWithOnDeck(item.id);
      if (withOnDeck.onDeckEpisode != null) {
        return withOnDeck.onDeckEpisode;
      }
    } catch (_) {}
    try {
      final episodes = await client.fetchPlayableDescendants(item.id);
      if (episodes.isNotEmpty) {
        return episodes.where((ep) => !ep.isWatched).firstOrNull ?? episodes.first;
      }
    } catch (_) {}
    return null;
  }
  if (item.kind == MediaKind.season) {
    try {
      final children = await client.fetchChildren(item.id);
      final playableChildren = [
        for (final c in children)
          if (c.kind == MediaKind.episode || c.kind == MediaKind.movie) c,
      ];
      if (playableChildren.isNotEmpty) {
        return playableChildren.where((ep) => !ep.isWatched).firstOrNull ?? playableChildren.first;
      }
    } catch (_) {}
    return null;
  }
  return null;
}

ResolvedRemoteTarget _withMatchedFile(MediaItem item, LibraryFileRow file) {
  final fileIdStr = '${file.id}';
  final versions = item.mediaVersions ?? const [];
  final idx = versions.indexWhere((v) => v.id == fileIdStr);
  return (item: item, mediaIndex: idx >= 0 ? idx : 0, mediaSourceId: fileIdStr);
}

Future<int?> _resolveItemIdByWorkKey(AppDatabase db, String workKey, RemoteMediaTarget target) async {
  if (workKey.startsWith('raw:')) {
    final targetKind = target.kind == 'movie' ? LibraryKinds.movie : LibraryKinds.show;
    final videoFiles = await (db.select(
      db.libraryFiles,
    )..where((t) => t.role.equals(LibraryFileRoles.video) & t.itemId.isNotNull())).get();
    for (final file in videoFiles) {
      final norm = DeterministicKeys.normalizeMountPath(file.path);
      final fileName = norm.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => norm);
      final candidate = DeterministicKeys.generateWorkKey(
        matchStatus: 0,
        kind: targetKind,
        fileName: fileName,
        fileSize: file.size ?? 0,
      );
      if (candidate == workKey) {
        return file.itemId;
      }
    }
    return null;
  }

  final parts = workKey.split(':');
  if (parts.length < 3) return null;
  final provider = parts[0];
  final workKind = parts[1];
  final externalId = parts.sublist(2).join(':');
  final expectedDbKind = workKind == 'movie' ? LibraryKinds.movie : LibraryKinds.show;

  final rows =
      await (db.select(db.libraryItems)..where((t) {
            final kindMatch = t.kind.equals(expectedDbKind);
            return switch (provider) {
              'tmdb' => kindMatch & t.tmdbId.equals(externalId),
              'imdb' => kindMatch & t.imdbId.equals(externalId),
              'bangumi' => kindMatch & t.bangumiId.equals(externalId),
              _ => const Constant(false),
            };
          }))
          .get();

  if (rows.isEmpty) return null;
  final workRow = rows.first;
  if (expectedDbKind == LibraryKinds.movie) {
    return workRow.id;
  }

  final episodes =
      await (db.select(db.libraryItems)
            ..where((t) => t.showId.equals(workRow.id) & t.kind.equals(LibraryKinds.episode))
            ..orderBy([(t) => OrderingTerm.asc(t.seasonNumber), (t) => OrderingTerm.asc(t.episodeNumber)]))
          .get();
  if (episodes.isEmpty) return null;

  if (target.seasonNumber != null && target.episodeNumber != null) {
    for (final ep in episodes) {
      if (ep.seasonNumber == target.seasonNumber && ep.episodeNumber == target.episodeNumber) {
        return ep.id;
      }
    }
  }
  return episodes.first.id;
}

/// Resolves [target] on the receiving host (triggering a quick incremental sync
/// once if needed) and launches or updates the built-in [VideoPlayerScreen].
Future<bool> launchRemoteMediaTarget({required BuildContext context, required RemoteMediaTarget target}) async {
  final db = _readOptional<AppDatabase>(context);
  final multiServer = _readOptional<MultiServerProvider>(context);
  final mountManager = _readOptional<MountManager>(context);

  final localClientRaw = multiServer?.serverManager.getClient(ServerId(LocalLibraryClient.localServerId));
  final localClient = localClientRaw is LocalLibraryClient ? localClientRaw : null;

  ResolvedRemoteTarget? resolved;
  if (db != null) {
    resolved = await resolveRemoteMediaTargetLocally(
      target: target,
      db: db,
      localClient: localClient,
      mountManager: mountManager,
      remoteClientLookup: (id) => multiServer?.serverManager.getClient(ServerId(id)),
    );
    final shouldRefreshLocalMounts =
        localClient != null &&
        (target.remoteServerId == null || target.remoteServerId == LocalLibraryClient.localServerId);
    if (resolved == null && shouldRefreshLocalMounts) {
      try {
        await localClient.refreshMounts();
      } catch (e) {
        appLogger.w('CompanionRemote: Mount refresh before remote launch failed', error: e);
      }
      resolved = await resolveRemoteMediaTargetLocally(
        target: target,
        db: db,
        localClient: localClient,
        mountManager: mountManager,
        remoteClientLookup: (id) => multiServer?.serverManager.getClient(ServerId(id)),
      );
    }
  } else if (multiServer != null && target.remoteServerId != null && target.remoteItemId != null) {
    final client = multiServer.serverManager.getClient(ServerId(target.remoteServerId!));
    if (client != null) {
      final item = await client.fetchItem(target.remoteItemId!);
      if (item != null) {
        final playable = await _resolvePlayableMediaItem(client, item);
        if (playable != null) {
          resolved = (item: playable, mediaIndex: null, mediaSourceId: null);
        }
      }
    }
  }

  if (resolved == null) {
    return false;
  }

  if (target.streamQuality != null && target.streamQuality!.isNotEmpty) {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.streamQuality, target.streamQuality!);
  }

  final initialPos = (target.positionMs != null && target.positionMs! > 0)
      ? Duration(milliseconds: target.positionMs!)
      : null;

  final launchIdentity = VideoPlayerLaunchIdentity(
    metadata: resolved.item,
    mediaIndex: resolved.mediaIndex ?? 0,
    selectedMediaSourceId: resolved.mediaSourceId,
    selectedQualityPreset: null,
    isOffline: false,
    routeKind: VideoPlayerRouteKind.vod,
  );

  if (VideoPlayerScreenState.isNavigationActive(launchIdentity)) {
    final receiver = CompanionRemoteReceiver.instance;
    if (initialPos != null) receiver.onSeekTo?.call(initialPos);
    if (target.playbackRate != null) receiver.onSetRate?.call(target.playbackRate!);
    receiver.onPlay?.call();
    return true;
  }

  final navContext = profileNavigationRegistry.navigator?.context ?? context;
  if (!navContext.mounted) return false;

  unawaited(
    navigateToVideoPlayer(
      navContext,
      metadata: resolved.item,
      selectedMediaIndex: resolved.mediaIndex,
      selectedMediaSourceId: resolved.mediaSourceId,
      initialPosition: initialPos,
      resolveWatchState: initialPos == null,
      explicitStartPolicy: initialPos != null,
    ),
  );

  final requestedRate = target.playbackRate;
  if (requestedRate != null && (requestedRate - 1.0).abs() > 0.01) {
    unawaited(_applyPlaybackRateOnceReady(requestedRate));
  }
  return true;
}

Future<void> _applyPlaybackRateOnceReady(double rate) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    final receiver = CompanionRemoteReceiver.instance;
    if (receiver.playerOwner != null && receiver.onSetRate != null) {
      receiver.onSetRate!(rate);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
