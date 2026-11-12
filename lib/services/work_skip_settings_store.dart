import 'dart:convert';

import '../database/app_database.dart';
import '../library/library_watch_state_store.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/work_identity.dart';
import '../media/work_skip_settings.dart';

/// One row per work in the account workspace, not per scanned item or file.
/// Remote identity bindings are a local cache for previously opened downloads.
class WorkSkipSettingsStore {
  WorkSkipSettingsStore(this.db);
  final AppDatabase db;

  static bool supports(MediaItem item) =>
      const {MediaKind.movie, MediaKind.show, MediaKind.season, MediaKind.episode}.contains(item.kind);

  Future<WorkIdentity?> resolve(MediaItem item, MediaServerClient? client) async {
    if (!supports(item) || item.serverId == null) return null;
    if (item.serverId == WorkIdentity.localSource) {
      final id = int.tryParse(item.id);
      return id == null ? null : LibraryWatchStateStore(db).resolveWork(id);
    }
    final source = '${item.backend.id}/${item.serverId}';
    final cacheKey = 'work-identity:$source:${item.id}';
    if (client != null) {
      try {
        var workId = item.id;
        if (item.kind == MediaKind.episode || item.kind == MediaKind.season) {
          String? showId = item.grandparentId;
          if (showId == null && item.kind == MediaKind.season) showId = item.parentId;
          if (showId == null && item.parentId != null) {
            final parent = await client.fetchItem(item.parentId!);
            showId = parent?.kind == MediaKind.show ? parent?.id : parent?.parentId;
          }
          if (showId == null) return null;
          workId = showId;
        }
        final ids = await client.fetchExternalIds(workId);
        final work = WorkIdentity.resolve(
          source: source,
          kind: item.kind == MediaKind.movie ? 'movie' : 'show',
          tmdbId: ids.tmdb?.toString(),
          imdbId: ids.imdb,
        );
        if (work == null) {
          await (db.delete(db.librarySettings)..where((t) => t.key.equals(cacheKey))).go();
        } else {
          await _put(cacheKey, jsonEncode([work.source, work.kind, work.provider, work.externalId]));
        }
        return work;
      } catch (_) {
        // An offline server can use only a previously resolved identity.
      }
    }
    final cached = await _get(cacheKey);
    if (cached == null) return null;
    try {
      final parts = jsonDecode(cached) as List<dynamic>;
      return WorkIdentity(
        source: parts[0] as String,
        kind: parts[1] as String,
        provider: parts[2] as String,
        externalId: parts[3] as String,
      );
    } on Object {
      return null;
    }
  }

  String _key(WorkIdentity work) => 'work-skip:${work.stateKey()}';
  Future<String?> _get(String key) async =>
      (await (db.select(db.librarySettings)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;
  Future<void> _put(String key, String value) async {
    await db.into(db.librarySettings).insertOnConflictUpdate(LibrarySettingsCompanion.insert(key: key, value: value));
  }

  Future<WorkSkipSettings> read(WorkIdentity work) async {
    final raw = await _get(_key(work));
    if (raw == null) return const WorkSkipSettings();
    try {
      return WorkSkipSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const WorkSkipSettings();
    }
  }

  Future<void> save(WorkIdentity work, WorkSkipSettings settings) {
    if (!settings.validFor()) throw ArgumentError('Invalid skip ranges');
    return _put(_key(work), jsonEncode(settings.toJson()));
  }
}
