import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../media/work_identity.dart';

typedef _LocalIdentity = ({WorkIdentity work, int season, int episode});

/// Persists scraped work state and projects it onto the current local index.
/// All callers run writes and projections in one database transaction.
class LibraryWatchStateStore {
  LibraryWatchStateStore(this.db);

  final AppDatabase db;

  Future<WorkIdentity?> resolveWork(int itemId) async {
    final item = await _item(itemId);
    if (item == null) return null;
    var work = item;
    if (item.kind == 'episode' || item.kind == 'season') {
      final parent = item.parentId == null ? null : await _item(item.parentId!);
      final showId = item.showId ?? (item.kind == 'season' ? item.parentId : parent?.parentId);
      final show = showId == null ? null : await _item(showId);
      if (show == null || show.kind != 'show') return null;
      work = show;
    }
    if (work.scrapedAt == null || work.libraryType == 'pending') return null;
    // Work-wide settings need a matched series, not a numbered episode.
    return WorkIdentity.resolve(
      source: WorkIdentity.localSource,
      kind: work.kind,
      tmdbId: work.tmdbId,
      imdbId: work.imdbId,
    );
  }

  Future<LibraryItemRow?> _item(int id) =>
      (db.select(db.libraryItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<_LocalIdentity?> _identity(LibraryItemRow item) async {
    var work = item;
    var season = -1;
    var episode = -1;
    if (item.kind == 'episode' || item.kind == 'season') {
      final parent = item.parentId == null ? null : await _item(item.parentId!);
      final showId = item.showId ?? (item.kind == 'season' ? item.parentId : parent?.parentId);
      final show = showId == null ? null : await _item(showId);
      if (show == null || show.kind != 'show') return null;
      work = show;
      season = item.seasonNumber ?? parent?.seasonNumber ?? -1;
      if (season < 0) return null;
      if (item.kind == 'episode') {
        episode = item.episodeNumber ?? -1;
        if (episode < 0) return null;
      }
    }
    if (work.scrapedAt == null || work.libraryType == 'pending') return null;
    final identity = WorkIdentity.resolve(
      source: WorkIdentity.localSource,
      kind: work.kind,
      tmdbId: work.tmdbId,
      imdbId: work.imdbId,
    );
    return identity == null ? null : (work: identity, season: season, episode: episode);
  }

  Future<WorkWatchStateRow?> read(String key) =>
      (db.select(db.workWatchStates)..where((t) => t.stateKey.equals(key))).getSingleOrNull();

  /// Restores current index projections from this version's work state.
  Future<void> restoreAll() => db.transaction(() async {
    final items = await db.select(db.libraryItems).get();
    for (final item in items) {
      await _restore(item);
    }
  });

  Future<void> restoreItemAndChildren(int id) => db.transaction(() async {
    final items = await (db.select(
      db.libraryItems,
    )..where((t) => t.id.equals(id) | t.showId.equals(id) | t.parentId.equals(id))).get();
    for (final item in items) {
      await _restore(item);
    }
  });

  Future<String?> _restore(LibraryItemRow item) async {
    final identity = await _identity(item);
    final binding = await (db.select(db.libraryWorkBindings)..where((t) => t.itemId.equals(item.id))).getSingleOrNull();
    if (identity == null) {
      if (binding != null) {
        await (db.delete(db.libraryUserStates)..where((t) => t.itemId.equals(item.id))).go();
        await (db.delete(db.libraryWorkBindings)..where((t) => t.itemId.equals(item.id))).go();
      }
      return null;
    }
    final key = identity.work.stateKey(season: identity.season, episode: identity.episode);
    final saved = await read(key);
    if (binding?.stateKey != key) {
      await (db.delete(db.libraryUserStates)..where((t) => t.itemId.equals(item.id))).go();
      await db
          .into(db.libraryWorkBindings)
          .insertOnConflictUpdate(LibraryWorkBindingsCompanion.insert(itemId: Value(item.id), stateKey: key));
    }
    if (saved != null) await _project(item.id, saved);
    return key;
  }

  Future<bool> prepareWrite(int itemId) async {
    final item = await _item(itemId);
    return item != null && await _restore(item) != null;
  }

  /// A newly supplied TMDB id can refine a known IMDb match. Carry state only
  /// when the unchanged IMDb id explicitly identifies the same scraped work.
  Future<void> addTmdbIdentity(LibraryItemRow previous, LibraryItemRow current) async {
    if (previous.kind != current.kind ||
        previous.tmdbId?.isNotEmpty == true ||
        previous.imdbId == null ||
        previous.imdbId != current.imdbId ||
        previous.scrapedAt == null ||
        current.scrapedAt == null) {
      return;
    }
    final oldIdentity = WorkIdentity.resolve(
      source: WorkIdentity.localSource,
      kind: previous.kind,
      imdbId: previous.imdbId,
    );
    final newIdentity = WorkIdentity.resolve(
      source: WorkIdentity.localSource,
      kind: current.kind,
      tmdbId: current.tmdbId,
    );
    if (oldIdentity == null || newIdentity == null) return;
    final states =
        await (db.select(db.workWatchStates)..where(
              (t) =>
                  t.source.equals(oldIdentity.source) &
                  t.kind.equals(oldIdentity.kind) &
                  t.provider.equals(oldIdentity.provider) &
                  t.externalId.equals(oldIdentity.externalId),
            ))
            .get();
    for (final state in states) {
      final key = newIdentity.stateKey(season: state.seasonNumber, episode: state.episodeNumber);
      if (await read(key) == null) {
        await db
            .into(db.workWatchStates)
            .insert(state.copyWith(stateKey: key, provider: newIdentity.provider, externalId: newIdentity.externalId));
      }
    }
  }

  Future<void> saveProjectedState(int itemId) async {
    final item = await _item(itemId);
    if (item == null) return;
    final identity = await _identity(item);
    if (identity == null) return;
    final state = await (db.select(db.libraryUserStates)..where((t) => t.itemId.equals(itemId))).getSingleOrNull();
    if (state == null) return;
    await _persist(identity, state);
    final key = identity.work.stateKey(season: identity.season, episode: identity.episode);
    final saved = (await read(key))!;
    final bindings = await (db.select(db.libraryWorkBindings)..where((t) => t.stateKey.equals(key))).get();
    for (final binding in bindings) {
      await _project(binding.itemId, saved);
    }
  }

  Future<void> _persist(_LocalIdentity identity, LibraryUserStateRow state) => db
      .into(db.workWatchStates)
      .insertOnConflictUpdate(
        WorkWatchStatesCompanion.insert(
          stateKey: identity.work.stateKey(season: identity.season, episode: identity.episode),
          source: identity.work.source,
          kind: identity.work.kind,
          provider: identity.work.provider,
          externalId: identity.work.externalId,
          seasonNumber: Value(identity.season),
          episodeNumber: Value(identity.episode),
          positionMs: Value(state.positionMs),
          durationMs: Value(state.durationMs),
          watched: Value(state.watched),
          playCount: Value(state.playCount),
          lastPlayedAt: Value(state.lastPlayedAt),
          favorite: Value(state.favorite),
          hiddenFromContinue: Value(state.hiddenFromContinue),
          updatedAt: state.updatedAt,
        ),
      );

  Future<void> _project(int itemId, WorkWatchStateRow state) => db
      .into(db.libraryUserStates)
      .insertOnConflictUpdate(
        LibraryUserStatesCompanion.insert(
          itemId: Value(itemId),
          positionMs: Value(state.positionMs),
          durationMs: Value(state.durationMs),
          watched: Value(state.watched),
          playCount: Value(state.playCount),
          lastPlayedAt: Value(state.lastPlayedAt),
          favorite: Value(state.favorite),
          hiddenFromContinue: Value(state.hiddenFromContinue),
          updatedAt: state.updatedAt,
        ),
      );
}
