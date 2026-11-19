import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_server_client.dart';
import '../../models/companion_remote/remote_playback_models.dart';
import '../../utils/app_logger.dart';
import '../multi_server_manager.dart';

const Set<String> _loopbackHosts = {'localhost', '127.0.0.1', '::1', '0.0.0.0'};

/// Resolves an HTTP(S) poster URL that another LAN device can reasonably fetch
/// directly, rejecting loopback addresses, local file URIs, and empty paths.
String? resolveRemoteReachablePosterUrl(MediaServerClient? client, MediaItem item) {
  final rawPath = item.thumbPath ?? item.grandparentThumbPath ?? item.parentThumbPath;
  if (rawPath == null || rawPath.trim().isEmpty) return null;

  var candidate = rawPath.trim();
  if (client != null) {
    final resolved = client.thumbnailUrl(candidate, width: 320);
    if (resolved.trim().isNotEmpty) {
      candidate = resolved.trim();
    }
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || _loopbackHosts.contains(host)) return null;
  return candidate;
}

String? _remoteCatalogKind(MediaKind kind) => switch (kind) {
  MediaKind.movie => 'movie',
  MediaKind.show => 'show',
  MediaKind.season => 'season',
  MediaKind.episode => 'episode',
  _ => null,
};

String? _buildItemSubtitle(MediaItem item) {
  switch (item.kind) {
    case MediaKind.episode:
      final code = (item.parentIndex != null && item.index != null)
          ? 'S${item.parentIndex!.toString().padLeft(2, '0')}E${item.index!.toString().padLeft(2, '0')}'
          : null;
      final series = item.grandparentTitle?.trim();
      final parts = [if (series != null && series.isNotEmpty) series, ?code];
      return parts.isEmpty ? null : parts.join(' · ');
    case MediaKind.season:
      final parts = [
        if (item.parentTitle != null && item.parentTitle!.trim().isNotEmpty) item.parentTitle!.trim(),
        if (item.leafCount != null && item.leafCount! > 0) '${item.leafCount}',
      ];
      return parts.isEmpty ? null : parts.join(' · ');
    case MediaKind.movie:
    case MediaKind.show:
      return item.year?.toString();
    default:
      return null;
  }
}

/// Converts a backend-neutral [MediaItem] into a wire [RemoteCatalogItem] for
/// host catalog search/browse over Companion Remote.
RemoteCatalogItem? remoteCatalogItemFromMediaItem(
  MediaItem item, {
  MediaServerClient? client,
  String? serverName,
}) {
  final wireKind = _remoteCatalogKind(item.kind);
  if (wireKind == null) return null;
  final resolvedServerId = item.serverId ?? client?.serverId.value ?? '';
  if (resolvedServerId.isEmpty || item.id.isEmpty) return null;

  return RemoteCatalogItem(
    serverId: resolvedServerId,
    serverName: serverName ?? item.serverName ?? client?.serverName,
    itemId: item.id,
    kind: wireKind,
    title: item.title ?? '',
    subtitle: _buildItemSubtitle(item),
    seriesTitle: item.grandparentTitle,
    year: item.year,
    seasonNumber: item.kind == MediaKind.season ? item.index : item.parentIndex,
    episodeNumber: item.kind == MediaKind.episode ? item.index : null,
    thumbUrl: resolveRemoteReachablePosterUrl(client, item),
    durationMs: item.durationMs,
    viewOffsetMs: item.viewOffsetMs,
    watched: item.isWatched,
  );
}

/// Executes catalog search and browse queries against all visible online servers
/// on the host device so any paired LAN remote can browse and launch playback
/// without owning the media locally.
class RemoteHostCatalogHandler {
  const RemoteHostCatalogHandler(this.serverManager);

  final MultiServerManager serverManager;

  List<MediaCatalogClientEntry> _activeClients() {
    final visible = serverManager.visibleOnlineClients;
    final clients = visible.isNotEmpty ? visible : serverManager.onlineClients;
    return [
      for (final entry in clients.entries)
        (serverId: entry.key, client: entry.value, serverName: _displayNameFor(entry.key, entry.value)),
    ];
  }

  String _displayNameFor(String serverId, MediaServerClient client) {
    final fromManager = serverManager.serverDisplayName(ServerId(serverId));
    if (fromManager.trim().isNotEmpty && fromManager != serverId) return fromManager;
    final fromClient = client.serverName?.trim();
    if (fromClient != null && fromClient.isNotEmpty) return fromClient;
    return serverId;
  }

  static bool _isVideoLibrary(MediaLibrary lib) =>
      !lib.hidden &&
      !lib.kind.isMusic &&
      lib.kind != MediaKind.photo &&
      lib.kind != MediaKind.playlist &&
      lib.kind != MediaKind.collection;

  static int _searchScore(RemoteCatalogItem item, String lowerQuery) {
    final title = item.title.trim().toLowerCase();
    if (title == lowerQuery) return 0;
    if (title.startsWith(lowerQuery)) return 1;
    if (title.contains(lowerQuery)) return 2;
    return 3;
  }

  Future<RemoteHostSearchResponse> searchCatalog(String query, {int limit = 40}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const RemoteHostSearchResponse(query: '', items: []);
    }
    final clampedLimit = limit.clamp(1, 100);
    final entries = _activeClients();
    if (entries.isEmpty) {
      return RemoteHostSearchResponse(query: trimmed, items: const []);
    }

    final perServer = await Future.wait(
      entries.map((entry) async {
        try {
          final raw = await entry.client.searchItems(trimmed, limit: clampedLimit);
          return [
            for (final item in raw)
              ?remoteCatalogItemFromMediaItem(item, client: entry.client, serverName: entry.serverName),
          ];
        } catch (e) {
          appLogger.d('CompanionRemote: Host catalog search failed on ${entry.serverId}', error: e);
          return const <RemoteCatalogItem>[];
        }
      }),
    );

    final seen = <String>{};
    final collected = <RemoteCatalogItem>[];
    for (final list in perServer) {
      for (final item in list) {
        if (seen.add('${item.serverId}:${item.itemId}')) {
          collected.add(item);
        }
      }
    }

    final lowerQuery = trimmed.toLowerCase();
    final indexed = collected.asMap().entries.toList()
      ..sort((a, b) {
        final cmp = _searchScore(a.value, lowerQuery).compareTo(_searchScore(b.value, lowerQuery));
        return cmp != 0 ? cmp : a.key.compareTo(b.key);
      });

    final sorted = [for (final e in indexed) e.value];
    return RemoteHostSearchResponse(
      query: trimmed,
      items: sorted.length > clampedLimit ? sorted.sublist(0, clampedLimit) : sorted,
    );
  }

  Future<RemoteHostHomeResponse> browseHome({int hubItemLimit = 12, String? continueWatchingTitle}) async {
    final entries = _activeClients();
    if (entries.isEmpty) {
      return const RemoteHostHomeResponse();
    }

    final clampedLimit = hubItemLimit.clamp(1, 40);
    final libraries = <RemoteCatalogLibrary>[];
    final continueItems = <RemoteCatalogItem>[];
    final hubs = <RemoteCatalogHub>[];

    final results = await Future.wait(
      entries.map((entry) async {
        List<MediaLibrary> serverLibs = const [];
        List<MediaItem> serverContinue = const [];
        List<MediaHub> serverHubs = const [];
        List<RemoteCatalogItem> fallbackItems = const [];

        try {
          serverLibs = (await entry.client.fetchLibraries()).where(_isVideoLibrary).toList();
        } catch (e) {
          appLogger.d('CompanionRemote: Host fetchLibraries failed on ${entry.serverId}', error: e);
        }

        try {
          serverContinue = await entry.client.fetchContinueWatching(count: clampedLimit);
        } catch (e) {
          appLogger.d('CompanionRemote: Host fetchContinueWatching failed on ${entry.serverId}', error: e);
        }

        try {
          serverHubs = await entry.client.fetchGlobalHubs(limit: clampedLimit, includePlaybackHubs: false);
        } catch (e) {
          appLogger.d('CompanionRemote: Host fetchGlobalHubs failed on ${entry.serverId}', error: e);
        }

        final mappedHubs = <RemoteCatalogHub>[];
        for (final hub in serverHubs) {
          if (hub.isContinueWatchingHub) continue;
          final items = [
            for (final item in hub.items.take(clampedLimit))
              ?remoteCatalogItemFromMediaItem(item, client: entry.client, serverName: entry.serverName),
          ];
          if (items.isEmpty) continue;
          mappedHubs.add(
            RemoteCatalogHub(
              id: '${entry.serverId}:${hub.id}',
              title: hub.title,
              serverId: entry.serverId,
              serverName: entry.serverName,
              items: items,
            ),
          );
        }

        if (mappedHubs.isEmpty && serverLibs.isNotEmpty) {
          final firstLib = serverLibs.first;
          try {
            final page = await entry.client.fetchLibraryPagedContent(
              firstLib.id,
              query: LibraryQuery(limit: clampedLimit),
              libraryKind: firstLib.kind == MediaKind.unknown ? null : firstLib.kind,
            );
            fallbackItems = [
              for (final item in page.items)
                ?remoteCatalogItemFromMediaItem(item, client: entry.client, serverName: entry.serverName),
            ];
            if (fallbackItems.isNotEmpty) {
              mappedHubs.add(
                RemoteCatalogHub(
                  id: '${entry.serverId}:lib:${firstLib.id}',
                  title: firstLib.title,
                  serverId: entry.serverId,
                  serverName: entry.serverName,
                  items: fallbackItems,
                ),
              );
            }
          } catch (e) {
            appLogger.d('CompanionRemote: Host fallback library browse failed on ${entry.serverId}', error: e);
          }
        }

        return (
          entry: entry,
          libs: serverLibs,
          continues: [
            for (final item in serverContinue.take(clampedLimit))
              ?remoteCatalogItemFromMediaItem(item, client: entry.client, serverName: entry.serverName),
          ],
          hubs: mappedHubs,
        );
      }),
    );

    final seenContinue = <String>{};
    for (final res in results) {
      for (final lib in res.libs) {
        libraries.add(
          RemoteCatalogLibrary(
            serverId: res.entry.serverId,
            serverName: res.entry.serverName,
            libraryId: lib.id,
            title: lib.title,
            kind: lib.kind.id,
          ),
        );
      }
      for (final item in res.continues) {
        if (seenContinue.add('${item.serverId}:${item.itemId}')) {
          continueItems.add(item);
        }
      }
    }

    if (continueItems.isNotEmpty) {
      hubs.add(
        RemoteCatalogHub(
          id: 'continue_watching',
          title: continueWatchingTitle ?? 'Continue Watching',
          items: continueItems.take(clampedLimit).toList(),
        ),
      );
    }
    for (final res in results) {
      hubs.addAll(res.hubs);
    }

    return RemoteHostHomeResponse(hubs: hubs, libraries: libraries);
  }

  Future<RemoteHostChildrenResponse> browseItemChildren({
    required String serverId,
    required String itemId,
    String? kind,
    int limit = 60,
  }) async {
    final client = serverManager.getClient(ServerId(serverId));
    if (client == null) {
      return RemoteHostChildrenResponse(serverId: serverId, itemId: itemId, error: 'Server not available');
    }

    final displayName = _displayNameFor(serverId, client);
    final clampedLimit = limit.clamp(1, 200);

    try {
      if (kind == 'library') {
        MediaKind? libraryKind;
        String? libraryTitle;
        try {
          final libs = await client.fetchLibraries();
          for (final lib in libs) {
            if (lib.id == itemId) {
              libraryKind = lib.kind == MediaKind.unknown ? null : lib.kind;
              libraryTitle = lib.title;
              break;
            }
          }
        } catch (_) {}

        final page = await client.fetchLibraryPagedContent(
          itemId,
          query: LibraryQuery(limit: clampedLimit),
          libraryKind: libraryKind,
        );
        return RemoteHostChildrenResponse(
          serverId: serverId,
          itemId: itemId,
          title: libraryTitle,
          items: [
            for (final item in page.items)
              ?remoteCatalogItemFromMediaItem(item, client: client, serverName: displayName),
          ],
        );
      }

      MediaItem? parent;
      try {
        parent = await client.fetchItem(itemId);
      } catch (_) {}

      final children = await client.fetchChildren(itemId);
      return RemoteHostChildrenResponse(
        serverId: serverId,
        itemId: itemId,
        title: parent?.title,
        items: [
          for (final item in children.take(clampedLimit))
            ?remoteCatalogItemFromMediaItem(item, client: client, serverName: displayName),
        ],
      );
    } catch (e) {
      appLogger.w('CompanionRemote: Failed to browse children for $serverId:$itemId', error: e);
      return RemoteHostChildrenResponse(serverId: serverId, itemId: itemId, error: '$e');
    }
  }
}

typedef MediaCatalogClientEntry = ({String serverId, MediaServerClient client, String serverName});
