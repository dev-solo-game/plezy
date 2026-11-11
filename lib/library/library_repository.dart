import 'package:clock/clock.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import 'media_probe.dart';

/// String ids persisted in the library tables.
abstract final class LibraryKinds {
  static const String movie = 'movie';
  static const String show = 'show';
  static const String season = 'season';
  static const String episode = 'episode';
}

/// The shelves of the library, persisted as a title's `libraryType`.
///
/// A title starts as [pending] when the scanner creates it from a file name
/// and gets its shelf from what the scraper finds out about it. Pending
/// titles are on no shelf.
abstract final class LibraryTypes {
  static const String movie = 'movie';
  static const String show = 'show';
  static const String anime = 'anime';
  static const String variety = 'variety';
  static const String documentary = 'documentary';
  static const String pending = 'pending';

  /// In the order the UI lists them.
  static const List<String> shelves = [movie, show, anime, variety, documentary];
}

abstract final class LibraryFileRoles {
  static const String video = 'video';
  static const String subtitle = 'subtitle';
  static const String artwork = 'artwork';
  static const String nfo = 'nfo';
}

abstract final class LibraryMatchStates {
  static const String pending = 'pending';
  static const String matched = 'matched';
  static const String unmatched = 'unmatched';
  static const String ignored = 'ignored';
}

abstract final class LibraryListKinds {
  static const String collection = 'collection';
  static const String playlist = 'playlist';
}

enum LibrarySort { title, year, releaseDate, rating, addedAt, lastPlayed }

/// What a library grid asks for: one shelf, optionally narrowed and ordered.
class LibraryQuery {
  const LibraryQuery({
    required this.libraryType,
    this.kind,
    this.sort = LibrarySort.title,
    this.descending = false,
    this.genreId,
    this.year,
    this.watched,
    this.favoritesOnly = false,
    this.search,
    this.offset = 0,
    this.limit = 60,
  });

  /// One of [LibraryTypes].
  final String libraryType;

  /// [LibraryKinds.movie] or [LibraryKinds.show]; null lists both together,
  /// as the shelves that mix series and films do.
  final String? kind;
  final LibrarySort sort;
  final bool descending;
  final int? genreId;
  final int? year;

  /// True keeps only watched titles, false only unwatched, null both.
  final bool? watched;
  final bool favoritesOnly;
  final String? search;
  final int offset;
  final int limit;
}

/// A title with the user's state for it. For shows and seasons the episode
/// counts say how much has been watched; for movies and episodes they are 0.
class LibraryItemView {
  const LibraryItemView({required this.item, this.state, this.episodeCount = 0, this.watchedEpisodeCount = 0});

  final LibraryItemRow item;
  final LibraryUserStateRow? state;
  final int episodeCount;
  final int watchedEpisodeCount;

  bool get isContainer => item.kind == LibraryKinds.show || item.kind == LibraryKinds.season;

  bool get isWatched =>
      isContainer ? episodeCount > 0 && watchedEpisodeCount >= episodeCount : (state?.watched ?? false);

  bool get isFavorite => state?.favorite ?? false;
}

class LibraryPage {
  const LibraryPage({required this.items, required this.total});

  final List<LibraryItemView> items;
  final int total;
}

class LibraryCredit {
  const LibraryCredit({required this.person, required this.job, this.character});

  final LibraryPersonRow person;
  final String job;
  final String? character;
}

/// Reads and writes the local media library. The scanner and scrapers write
/// through it; the local backend answers the UI's queries from it.
class LibraryRepository {
  LibraryRepository(this._db);

  final AppDatabase _db;

  /// A playback this far in counts as finished.
  static const double watchedThreshold = 0.9;

  static int _now() => clock.now().millisecondsSinceEpoch;

  /// Ordering key for a title: lower-cased, without a leading English article.
  static String sortTitleFor(String title) {
    final lower = title.trim().toLowerCase();
    for (final article in const ['the ', 'a ', 'an ']) {
      if (lower.startsWith(article) && lower.length > article.length) return lower.substring(article.length);
    }
    return lower;
  }

  // ─── Episode-count expressions ─────────────────────────────────────────

  // Correlated on the outer `library_items` row: a show counts the episodes
  // pointing at it through show_id, a season through parent_id.
  static const String _episodesOf =
      "FROM library_items e WHERE e.kind = 'episode' AND "
      "((library_items.kind = 'show' AND e.show_id = library_items.id) OR "
      "(library_items.kind = 'season' AND e.parent_id = library_items.id))";

  static const CustomExpression<int> _episodeCount = CustomExpression<int>('(SELECT COUNT(*) $_episodesOf)');

  static const CustomExpression<int> _watchedEpisodeCount = CustomExpression<int>(
    '(SELECT COUNT(*) $_episodesOf AND EXISTS '
    '(SELECT 1 FROM library_user_states us WHERE us.item_id = e.id AND us.watched = 1))',
  );

  /// Watched state that works for both leaves and containers.
  static const CustomExpression<bool> _isWatched = CustomExpression<bool>(
    "(CASE WHEN library_items.kind IN ('show', 'season') THEN "
    '((SELECT COUNT(*) $_episodesOf) > 0 AND (SELECT COUNT(*) $_episodesOf) = '
    '(SELECT COUNT(*) $_episodesOf AND EXISTS '
    '(SELECT 1 FROM library_user_states us WHERE us.item_id = e.id AND us.watched = 1))) '
    'ELSE COALESCE(library_user_states.watched, 0) END)',
  );

  JoinedSelectStatement<HasResultSet, dynamic> _viewSelect() {
    final items = _db.libraryItems;
    final states = _db.libraryUserStates;
    return _db.select(items).join([leftOuterJoin(states, states.itemId.equalsExp(items.id))])
      ..addColumns([_episodeCount, _watchedEpisodeCount]);
  }

  LibraryItemView _toView(TypedResult row) {
    return LibraryItemView(
      item: row.readTable(_db.libraryItems),
      state: row.readTableOrNull(_db.libraryUserStates),
      episodeCount: row.read(_episodeCount) ?? 0,
      watchedEpisodeCount: row.read(_watchedEpisodeCount) ?? 0,
    );
  }

  static String _likePattern(String text) {
    final escaped = text.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    return '%$escaped%';
  }

  Expression<bool> _matchesText(String text) {
    final items = _db.libraryItems;
    final pattern = _likePattern(text.trim());
    return items.title.like(pattern, escapeChar: r'\') |
        items.originalTitle.like(pattern, escapeChar: r'\') |
        items.aliases.like(pattern, escapeChar: r'\');
  }

  // ─── Titles ────────────────────────────────────────────────────────────

  Future<int> insertItem(LibraryItemsCompanion item) => _db.into(_db.libraryItems).insert(item);

  Future<void> updateItem(int id, LibraryItemsCompanion changes) async {
    await (_db.update(
      _db.libraryItems,
    )..where((t) => t.id.equals(id))).write(changes.copyWith(updatedAt: Value(_now())));
  }

  /// Moves the watch state of [fromId] onto [toId], for when one title is
  /// folded into another or a file moves to a different title. When both
  /// have state they are combined: the more recent progress, watched if
  /// either was, plays added up, favourite if either was.
  Future<void> mergeUserState(int fromId, int toId) async {
    if (fromId == toId) return;
    final states = _db.libraryUserStates;
    await _db.transaction(() async {
      final from = await (_db.select(states)..where((t) => t.itemId.equals(fromId))).getSingleOrNull();
      if (from == null) return;
      final to = await (_db.select(states)..where((t) => t.itemId.equals(toId))).getSingleOrNull();
      if (to == null) {
        await (_db.update(
          states,
        )..where((t) => t.itemId.equals(fromId))).write(LibraryUserStatesCompanion(itemId: Value(toId)));
        return;
      }
      final fromNewer = (from.lastPlayedAt ?? 0) > (to.lastPlayedAt ?? 0);
      final newer = fromNewer ? from : to;
      await (_db.update(states)..where((t) => t.itemId.equals(toId))).write(
        LibraryUserStatesCompanion(
          positionMs: Value(newer.positionMs),
          durationMs: Value(newer.durationMs ?? from.durationMs ?? to.durationMs),
          watched: Value(from.watched || to.watched),
          playCount: Value(from.playCount + to.playCount),
          lastPlayedAt: Value(newer.lastPlayedAt),
          favorite: Value(from.favorite || to.favorite),
          hiddenFromContinue: Value(newer.hiddenFromContinue),
          updatedAt: Value(_now()),
        ),
      );
      await (_db.delete(states)..where((t) => t.itemId.equals(fromId))).go();
    });
  }

  /// How many videos are filed under [itemId].
  Future<int> videoCount(int itemId) async {
    final files = _db.libraryFiles;
    final count = files.id.count();
    return (_db.selectOnly(files)
          ..addColumns([count])
          ..where(files.itemId.equals(itemId) & files.role.equals(LibraryFileRoles.video)))
        .map((row) => row.read(count) ?? 0)
        .getSingle();
  }

  Future<void> deleteItem(int id) async {
    await (_db.delete(_db.libraryItems)..where((t) => t.id.equals(id))).go();
  }

  Future<LibraryItemView?> getItem(int id) async {
    final row = await (_viewSelect()..where(_db.libraryItems.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toView(row);
  }

  /// Finds a title a scraper already created, so a second file for the same
  /// film becomes another version instead of a duplicate entry.
  Future<LibraryItemRow?> findByExternalId({
    required String kind,
    String? tmdbId,
    String? bangumiId,
    String? imdbId,
  }) async {
    final items = _db.libraryItems;
    final Expression<bool> idMatch;
    if (tmdbId != null) {
      idMatch = items.tmdbId.equals(tmdbId);
    } else if (bangumiId != null) {
      idMatch = items.bangumiId.equals(bangumiId);
    } else if (imdbId != null) {
      idMatch = items.imdbId.equals(imdbId);
    } else {
      return null;
    }
    final query = _db.select(items)
      ..where((t) => t.kind.equals(kind) & idMatch)
      ..limit(1);
    return query.getSingleOrNull();
  }

  /// Finds a movie or show by the name a file gave it: its sort title or one
  /// of its aliases, on whichever shelf it ended up. A [year] only rules a
  /// candidate out when both sides have one and they differ.
  Future<LibraryItemRow?> findTitleByName({required String kind, required String name, int? year}) async {
    final items = _db.libraryItems;
    final key = sortTitleFor(name);
    final wanted = name.trim().toLowerCase();
    Expression<bool> filter =
        items.kind.equals(kind) &
        (items.sortTitle.equals(key) | items.aliases.like(_likePattern(name.trim()), escapeChar: r'\'));
    if (year != null) filter = filter & (items.year.isNull() | items.year.equals(year));
    final candidates =
        await (_db.select(items)
              ..where((_) => filter)
              // An exact-year candidate beats one with no year.
              ..orderBy([(t) => OrderingTerm(expression: t.year, mode: OrderingMode.desc, nulls: NullsOrder.last)]))
            .get();
    for (final candidate in candidates) {
      if (candidate.sortTitle == key) return candidate;
      // LIKE finds the name anywhere in the alias list; it has to be a whole line.
      final aliases = (candidate.aliases ?? '').toLowerCase().split('\n').map((a) => a.trim());
      if (aliases.contains(wanted)) return candidate;
    }
    return null;
  }

  /// The season of [showId] numbered [seasonNumber], or the episode of a
  /// season numbered [episodeNumber].
  Future<LibraryItemRow?> findChild(int parentId, {int? seasonNumber, int? episodeNumber}) {
    final query = _db.select(_db.libraryItems)
      ..where((t) {
        Expression<bool> filter = t.parentId.equals(parentId);
        if (episodeNumber != null) {
          filter = filter & t.kind.equals(LibraryKinds.episode) & t.episodeNumber.equals(episodeNumber);
        } else if (seasonNumber != null) {
          filter = filter & t.kind.equals(LibraryKinds.season) & t.seasonNumber.equals(seasonNumber);
        }
        return filter;
      })
      ..limit(1);
    return query.getSingleOrNull();
  }

  Expression<bool> _shelfFilter(LibraryQuery query) {
    final items = _db.libraryItems;
    final states = _db.libraryUserStates;
    final kind = query.kind;
    Expression<bool> filter =
        (kind == null ? items.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) : items.kind.equals(kind)) &
        items.libraryType.equals(query.libraryType);
    if (query.genreId case final genreId?) {
      filter =
          filter &
          existsQuery(
            _db.selectOnly(_db.libraryItemGenres)
              ..addColumns([_db.libraryItemGenres.itemId])
              ..where(_db.libraryItemGenres.itemId.equalsExp(items.id) & _db.libraryItemGenres.genreId.equals(genreId)),
          );
    }
    if (query.year case final year?) filter = filter & items.year.equals(year);
    if (query.watched case final watched?) filter = filter & _isWatched.equals(watched);
    if (query.favoritesOnly) filter = filter & states.favorite.equals(true);
    final search = query.search?.trim();
    if (search != null && search.isNotEmpty) filter = filter & _matchesText(search);
    return filter;
  }

  /// One page of a library shelf, with the total for the same filters.
  Future<LibraryPage> queryTitles(LibraryQuery query) async {
    final items = _db.libraryItems;
    final states = _db.libraryUserStates;
    final filter = _shelfFilter(query);
    final mode = query.descending ? OrderingMode.desc : OrderingMode.asc;

    final Expression<Object> key = switch (query.sort) {
      LibrarySort.title => items.sortTitle,
      LibrarySort.year => items.year,
      LibrarySort.releaseDate => items.releaseDate,
      LibrarySort.rating => items.rating,
      LibrarySort.addedAt => items.addedAt,
      LibrarySort.lastPlayed => states.lastPlayedAt,
    };

    final rows =
        await (_viewSelect()
              ..where(filter)
              ..orderBy([
                // Titles missing the sort key go last in either direction.
                OrderingTerm(expression: key, mode: mode, nulls: NullsOrder.last),
                OrderingTerm.asc(items.sortTitle),
                OrderingTerm.asc(items.id),
              ])
              ..limit(query.limit, offset: query.offset))
            .get();

    final count = items.id.count();
    final total =
        await (_db.selectOnly(items).join([leftOuterJoin(states, states.itemId.equalsExp(items.id))])
              ..addColumns([count])
              ..where(filter))
            .map((row) => row.read(count) ?? 0)
            .getSingle();

    return LibraryPage(items: rows.map(_toView).toList(), total: total);
  }

  /// Seasons of a show or episodes of a season, in broadcast order.
  Future<List<LibraryItemView>> children(int parentId) async {
    final items = _db.libraryItems;
    final rows =
        await (_viewSelect()
              ..where(items.parentId.equals(parentId))
              ..orderBy([
                OrderingTerm.asc(items.seasonNumber),
                OrderingTerm.asc(items.episodeNumber),
                OrderingTerm.asc(items.id),
              ]))
            .get();
    return rows.map(_toView).toList();
  }

  /// Every episode of a show in watch order: numbered seasons first, then
  /// specials.
  Future<List<LibraryItemView>> episodesOfShow(int showId) async {
    final items = _db.libraryItems;
    final rows =
        await (_viewSelect()
              ..where(items.showId.equals(showId) & items.kind.equals(LibraryKinds.episode))
              ..orderBy([
                OrderingTerm.asc(CustomExpression<int>('(COALESCE(library_items.season_number, 0) = 0)')),
                OrderingTerm.asc(items.seasonNumber),
                OrderingTerm.asc(items.episodeNumber),
                OrderingTerm.asc(items.id),
              ]))
            .get();
    return rows.map(_toView).toList();
  }

  /// The episode to play next for a show: the first one not yet watched.
  Future<LibraryItemView?> nextUnwatchedEpisode(int showId) async {
    for (final episode in await episodesOfShow(showId)) {
      if (!episode.isWatched) return episode;
    }
    return null;
  }

  /// Titles still waiting for the scraper to place them are on no shelf.
  Expression<bool> get _onAShelf => _db.libraryItems.libraryType.isNotValue(LibraryTypes.pending);

  /// Movies and shows waiting to be placed on a shelf: not looked up yet, or
  /// looked up without a match.
  Future<List<LibraryItemView>> pendingTitles({int limit = 500}) async {
    final items = _db.libraryItems;
    final rows =
        await (_viewSelect()
              ..where(
                items.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) &
                    items.libraryType.equals(LibraryTypes.pending),
              )
              ..orderBy([OrderingTerm.asc(items.sortTitle)])
              ..limit(limit))
            .get();
    return rows.map(_toView).toList();
  }

  /// Movies and shows off every shelf: [queued] not looked up yet, and
  /// [unmatched] looked up without a match.
  Future<({int queued, int unmatched})> pendingCounts() async {
    final items = _db.libraryItems;
    final count = items.id.count();
    Future<int> countWhere(Expression<bool> filter) =>
        (_db.selectOnly(items)
              ..addColumns([count])
              ..where(
                items.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) &
                    items.libraryType.equals(LibraryTypes.pending) &
                    filter,
              ))
            .map((row) => row.read(count) ?? 0)
            .getSingle();
    return (
      queued: await countWhere(items.scrapedAt.isNull()),
      unmatched: await countWhere(items.scrapedAt.isNotNull()),
    );
  }

  /// Moves a movie or show, with its seasons and episodes, to [libraryType].
  Future<void> setLibraryType(int itemId, String libraryType) async {
    await (_db.update(_db.libraryItems)..where((t) => t.id.equals(itemId) | t.showId.equals(itemId))).write(
      LibraryItemsCompanion(libraryType: Value(libraryType)),
    );
  }

  /// Movies and shows whose names contain [text], unmatched ones included:
  /// their file name is the only thing to find them by.
  Future<List<LibraryItemView>> search(String text, {int limit = 50}) async {
    if (text.trim().isEmpty) return const [];
    final items = _db.libraryItems;
    final rows =
        await (_viewSelect()
              ..where(items.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) & _matchesText(text))
              ..orderBy([OrderingTerm.asc(items.sortTitle)])
              ..limit(limit))
            .get();
    return rows.map(_toView).toList();
  }

  Future<List<LibraryItemView>> recentlyAdded({String? libraryType, int limit = 20}) async {
    final items = _db.libraryItems;
    Expression<bool> filter = items.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) & _onAShelf;
    if (libraryType != null) filter = filter & items.libraryType.equals(libraryType);
    final rows =
        await (_viewSelect()
              ..where(filter)
              ..orderBy([OrderingTerm.desc(items.addedAt), OrderingTerm.desc(items.id)])
              ..limit(limit))
            .get();
    return rows.map(_toView).toList();
  }

  /// Movies and episodes that were started and not finished, most recent first.
  Future<List<LibraryItemView>> continueWatching({int limit = 20}) async {
    final items = _db.libraryItems;
    final states = _db.libraryUserStates;
    final rows =
        await (_viewSelect()
              ..where(
                items.kind.isIn([LibraryKinds.movie, LibraryKinds.episode]) &
                    states.positionMs.isBiggerThanValue(0) &
                    states.watched.equals(false) &
                    states.hiddenFromContinue.equals(false),
              )
              ..orderBy([OrderingTerm.desc(states.lastPlayedAt)])
              ..limit(limit))
            .get();
    return rows.map(_toView).toList();
  }

  /// Release years present on a shelf, newest first.
  Future<List<int>> years({required String libraryType, required String kind}) async {
    final items = _db.libraryItems;
    final query = _db.selectOnly(items, distinct: true)
      ..addColumns([items.year])
      ..where(items.libraryType.equals(libraryType) & items.kind.equals(kind) & items.year.isNotNull())
      ..orderBy([OrderingTerm.desc(items.year)]);
    return (await query.map((row) => row.read(items.year)).get()).whereType<int>().toList();
  }

  // ─── User state ────────────────────────────────────────────────────────

  Future<void> _writeState(int itemId, LibraryUserStatesCompanion changes) async {
    final now = _now();
    final updated = await (_db.update(
      _db.libraryUserStates,
    )..where((t) => t.itemId.equals(itemId))).write(changes.copyWith(updatedAt: Value(now)));
    if (updated == 0) {
      await _db.into(_db.libraryUserStates).insert(changes.copyWith(itemId: Value(itemId), updatedAt: Value(now)));
    }
  }

  /// Records where playback of a movie or episode is. Reaching
  /// [watchedThreshold] of the duration marks it watched and clears the
  /// resume point.
  Future<void> setProgress(int itemId, {required int positionMs, int? durationMs}) async {
    final finished = durationMs != null && durationMs > 0 && positionMs >= durationMs * watchedThreshold;
    if (finished) {
      await markWatched(itemId, watched: true);
      return;
    }
    await _writeState(
      itemId,
      LibraryUserStatesCompanion(
        positionMs: Value(positionMs),
        durationMs: Value(durationMs),
        lastPlayedAt: Value(_now()),
        hiddenFromContinue: const Value(false),
      ),
    );
  }

  /// Marks a title watched or unwatched. A show or season applies to every
  /// episode under it.
  Future<void> markWatched(int itemId, {required bool watched}) async {
    final item = await (_db.select(_db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null) return;

    final List<int> targets;
    if (item.kind == LibraryKinds.show || item.kind == LibraryKinds.season) {
      final items = _db.libraryItems;
      final byShow = item.kind == LibraryKinds.show;
      final query = _db.selectOnly(items)
        ..addColumns([items.id])
        ..where(
          items.kind.equals(LibraryKinds.episode) &
              (byShow ? items.showId.equals(itemId) : items.parentId.equals(itemId)),
        );
      targets = (await query.map((row) => row.read(items.id)).get()).whereType<int>().toList();
    } else {
      targets = [itemId];
    }

    await _db.transaction(() async {
      final now = _now();
      for (final target in targets) {
        final existing = await (_db.select(
          _db.libraryUserStates,
        )..where((t) => t.itemId.equals(target))).getSingleOrNull();
        final becameWatched = watched && !(existing?.watched ?? false);
        await _writeState(
          target,
          LibraryUserStatesCompanion(
            watched: Value(watched),
            positionMs: const Value(0),
            playCount: Value(watched ? (existing?.playCount ?? 0) + (becameWatched ? 1 : 0) : 0),
            lastPlayedAt: watched ? Value(now) : Value(existing?.lastPlayedAt),
          ),
        );
      }
    });
  }

  Future<void> setFavorite(int itemId, {required bool favorite}) {
    return _writeState(itemId, LibraryUserStatesCompanion(favorite: Value(favorite)));
  }

  /// Drops a title from Continue Watching while keeping its resume point.
  Future<void> hideFromContinueWatching(int itemId) {
    return _writeState(itemId, const LibraryUserStatesCompanion(hiddenFromContinue: Value(true)));
  }

  // ─── Genres ────────────────────────────────────────────────────────────

  /// Replaces the genres of [itemId] with [names], creating any that are new.
  Future<void> setGenres(int itemId, Iterable<String> names) async {
    final wanted = {
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    };
    await _db.transaction(() async {
      await (_db.delete(_db.libraryItemGenres)..where((t) => t.itemId.equals(itemId))).go();
      for (final name in wanted) {
        await _db
            .into(_db.libraryGenres)
            .insert(LibraryGenresCompanion.insert(name: name), mode: InsertMode.insertOrIgnore);
        final genre = await (_db.select(_db.libraryGenres)..where((t) => t.name.equals(name))).getSingle();
        await _db
            .into(_db.libraryItemGenres)
            .insert(LibraryItemGenresCompanion.insert(itemId: itemId, genreId: genre.id));
      }
    });
  }

  Future<List<LibraryGenreRow>> genresOf(int itemId) {
    final genres = _db.libraryGenres;
    final links = _db.libraryItemGenres;
    final query = _db.select(genres).join([innerJoin(links, links.genreId.equalsExp(genres.id))])
      ..where(links.itemId.equals(itemId))
      ..orderBy([OrderingTerm.asc(genres.name)]);
    return query.map((row) => row.readTable(genres)).get();
  }

  /// Genres that at least one title on the shelf has.
  Future<List<LibraryGenreRow>> genresOnShelf({required String libraryType, required String kind}) {
    final genres = _db.libraryGenres;
    final links = _db.libraryItemGenres;
    final items = _db.libraryItems;
    // An EXISTS rather than a join: a join yields one row per tagged title.
    final onShelf = existsQuery(
      _db.selectOnly(links).join([innerJoin(items, items.id.equalsExp(links.itemId))])
        ..addColumns([links.itemId])
        ..where(links.genreId.equalsExp(genres.id) & items.libraryType.equals(libraryType) & items.kind.equals(kind)),
    );
    final query = _db.select(genres)
      ..where((_) => onShelf)
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return query.get();
  }

  // ─── Cast and crew ─────────────────────────────────────────────────────

  /// Replaces the credits of [itemId]. People are matched by TMDB id when
  /// they have one, otherwise by name.
  Future<void> setCredits(
    int itemId,
    List<({String name, String job, String? character, String? tmdbId, String? photoSource})> credits,
  ) async {
    await _db.transaction(() async {
      await (_db.delete(_db.libraryCredits)..where((t) => t.itemId.equals(itemId))).go();
      for (final (index, credit) in credits.indexed) {
        final people = _db.libraryPeople;
        final existing =
            await (_db.select(people)
                  ..where((t) => credit.tmdbId != null ? t.tmdbId.equals(credit.tmdbId!) : t.name.equals(credit.name))
                  ..limit(1))
                .getSingleOrNull();
        final personId =
            existing?.id ??
            await _db
                .into(people)
                .insert(
                  LibraryPeopleCompanion.insert(
                    name: credit.name,
                    tmdbId: Value(credit.tmdbId),
                    photoSource: Value(credit.photoSource),
                  ),
                );
        if (existing != null && existing.photoSource == null && credit.photoSource != null) {
          await (_db.update(
            people,
          )..where((t) => t.id.equals(personId))).write(LibraryPeopleCompanion(photoSource: Value(credit.photoSource)));
        }
        await _db
            .into(_db.libraryCredits)
            .insert(
              LibraryCreditsCompanion.insert(
                itemId: itemId,
                personId: personId,
                job: credit.job,
                character: Value(credit.character),
                sortOrder: Value(index),
              ),
              // The same person listed twice in one job keeps the first entry.
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  Future<List<LibraryCredit>> creditsOf(int itemId) {
    final credits = _db.libraryCredits;
    final people = _db.libraryPeople;
    final query = _db.select(credits).join([innerJoin(people, people.id.equalsExp(credits.personId))])
      ..where(credits.itemId.equals(itemId))
      ..orderBy([OrderingTerm.asc(credits.sortOrder)]);
    return query.map((row) {
      final credit = row.readTable(credits);
      return LibraryCredit(person: row.readTable(people), job: credit.job, character: credit.character);
    }).get();
  }

  Future<List<LibraryItemView>> titlesWithPerson(int personId) async {
    final items = _db.libraryItems;
    final rows =
        await (_viewSelect()
              ..where(
                existsQuery(
                  _db.selectOnly(_db.libraryCredits)
                    ..addColumns([_db.libraryCredits.itemId])
                    ..where(
                      _db.libraryCredits.itemId.equalsExp(items.id) & _db.libraryCredits.personId.equals(personId),
                    ),
                ),
              )
              ..orderBy([OrderingTerm.desc(items.year), OrderingTerm.asc(items.sortTitle)]))
            .get();
    return rows.map(_toView).toList();
  }

  // ─── Files ─────────────────────────────────────────────────────────────

  /// Records a file the scanner saw. A file already known at the same path
  /// keeps its id, its match and its probed media info; only what the scan
  /// can observe is refreshed. Returns the row id.
  Future<int> upsertFile({
    required String mountId,
    required String path,
    required String role,
    required int scanId,
    String? remoteId,
    int? size,
    int? modifiedAt,
    String? parsed,
    String? versionLabel,
    String? language,
    int? ownerFileId,
  }) async {
    final files = _db.libraryFiles;
    final existing = await (_db.select(
      files,
    )..where((t) => t.mountId.equals(mountId) & t.path.equals(path))).getSingleOrNull();
    if (existing == null) {
      return _db
          .into(files)
          .insert(
            LibraryFilesCompanion.insert(
              mountId: mountId,
              path: path,
              role: role,
              remoteId: Value(remoteId),
              size: Value(size),
              modifiedAt: Value(modifiedAt),
              parsed: Value(parsed),
              versionLabel: Value(versionLabel),
              language: Value(language),
              ownerFileId: Value(ownerFileId),
              seenInScan: Value(scanId),
              addedAt: _now(),
            ),
          );
    }
    // A different size or timestamp means different content: what was probed
    // from the old bytes no longer applies.
    final replaced = existing.size != size || existing.modifiedAt != modifiedAt;
    await (_db.update(files)..where((t) => t.id.equals(existing.id))).write(
      LibraryFilesCompanion(
        role: Value(role),
        remoteId: Value(remoteId),
        size: Value(size),
        modifiedAt: Value(modifiedAt),
        parsed: Value(parsed),
        versionLabel: Value(versionLabel),
        language: Value(language),
        ownerFileId: Value(ownerFileId),
        seenInScan: Value(scanId),
        durationMs: replaced ? const Value(null) : const Value.absent(),
        container: replaced ? const Value(null) : const Value.absent(),
        videoCodec: replaced ? const Value(null) : const Value.absent(),
        width: replaced ? const Value(null) : const Value.absent(),
        height: replaced ? const Value(null) : const Value.absent(),
        hdrFormat: replaced ? const Value(null) : const Value.absent(),
        streams: replaced ? const Value(null) : const Value.absent(),
        probedAt: replaced ? const Value(null) : const Value.absent(),
      ),
    );
    return existing.id;
  }

  Future<LibraryFileRow?> getFile(int id) {
    return (_db.select(_db.libraryFiles)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> updateFile(int id, LibraryFilesCompanion changes) async {
    await (_db.update(_db.libraryFiles)..where((t) => t.id.equals(id))).write(changes);
  }

  /// The playable versions of a movie or episode, largest first.
  Future<List<LibraryFileRow>> versionsOf(int itemId) {
    final files = _db.libraryFiles;
    final query = _db.select(files)
      ..where((t) => t.itemId.equals(itemId) & t.role.equals(LibraryFileRoles.video))
      ..orderBy([(t) => OrderingTerm(expression: t.size, mode: OrderingMode.desc, nulls: NullsOrder.last)]);
    return query.get();
  }

  Future<List<LibraryFileRow>> subtitlesOf(int videoFileId) {
    final files = _db.libraryFiles;
    final query = _db.select(files)
      ..where((t) => t.ownerFileId.equals(videoFileId) & t.role.equals(LibraryFileRoles.subtitle))
      ..orderBy([(t) => OrderingTerm.asc(t.path)]);
    return query.get();
  }

  /// Videos in [state], oldest first — the scraper's queue for `pending`, the
  /// Unmatched shelf for `unmatched`.
  Future<List<LibraryFileRow>> videosInState(String state, {String? mountId, int limit = 100, int offset = 0}) {
    final files = _db.libraryFiles;
    final query = _db.select(files)
      ..where((t) {
        final base = t.role.equals(LibraryFileRoles.video) & t.matchState.equals(state);
        return mountId == null ? base : base & t.mountId.equals(mountId);
      })
      ..orderBy([(t) => OrderingTerm.asc(t.path)])
      ..limit(limit, offset: offset);
    return query.get();
  }

  Future<int> countVideosInState(String state) async {
    final files = _db.libraryFiles;
    final count = files.id.count();
    final query = _db.selectOnly(files)
      ..addColumns([count])
      ..where(files.role.equals(LibraryFileRoles.video) & files.matchState.equals(state));
    return await query.map((row) => row.read(count) ?? 0).getSingle();
  }

  /// Attaches a video to a title. [locked] records that the user chose it,
  /// so later scans and scrapes keep the link.
  Future<void> assignFile(int fileId, int itemId, {bool locked = false}) async {
    await (_db.update(_db.libraryFiles)..where((t) => t.id.equals(fileId))).write(
      LibraryFilesCompanion(
        itemId: Value(itemId),
        matchState: const Value(LibraryMatchStates.matched),
        matchLocked: locked ? const Value(true) : const Value.absent(),
      ),
    );
  }

  /// Records what probing [fileId]'s header found. A file the probe cannot
  /// read still gets its container and a timestamp, so it is not re-probed
  /// on every look; a rescan that sees the file change clears it all.
  Future<void> saveProbe(int fileId, ProbedMedia media) async {
    final video = media.firstVideo;
    await (_db.update(_db.libraryFiles)..where((t) => t.id.equals(fileId))).write(
      LibraryFilesCompanion(
        durationMs: Value(media.durationMs),
        container: Value(media.container),
        videoCodec: Value(video?.codec),
        width: Value(video?.width),
        height: Value(video?.height),
        hdrFormat: Value(video?.hdr),
        streams: Value(media.encodeStreams()),
        probedAt: Value(clock.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Points a video at a title without recording a match: the scanner files
  /// it under the name it parsed, and the scraper confirms or corrects that.
  Future<void> linkFile(int fileId, int? itemId) async {
    await (_db.update(
      _db.libraryFiles,
    )..where((t) => t.id.equals(fileId))).write(LibraryFilesCompanion(itemId: Value(itemId)));
  }

  /// How many videos a mount holds, and how many of them no title claims.
  Future<({int videos, int unidentified})> mountSummary(String mountId) async {
    final files = _db.libraryFiles;
    final total = files.id.count();
    final loose = files.id.count(filter: files.itemId.isNull());
    final query = _db.selectOnly(files)
      ..addColumns([total, loose])
      ..where(files.mountId.equals(mountId) & files.role.equals(LibraryFileRoles.video));
    final row = await query.getSingle();
    return (videos: row.read(total) ?? 0, unidentified: row.read(loose) ?? 0);
  }

  Future<void> setFileMatchState(int fileId, String state) async {
    await (_db.update(
      _db.libraryFiles,
    )..where((t) => t.id.equals(fileId))).write(LibraryFilesCompanion(matchState: Value(state)));
  }

  /// Removes the files of [mountId] that scan [scanId] did not see, then the
  /// titles left with nothing to play. Returns how many files were removed.
  Future<int> removeFilesNotSeen(String mountId, int scanId) async {
    return _db.transaction(() async {
      final removed = await (_db.delete(
        _db.libraryFiles,
      )..where((t) => t.mountId.equals(mountId) & t.seenInScan.isSmallerThanValue(scanId))).go();
      if (removed > 0) await pruneEmptyTitles();
      return removed;
    });
  }

  /// Deletes movies and episodes that no video points at any more, then the
  /// seasons and shows left without children. A lock only keeps a re-scrape
  /// from overwriting the user's match; a locked title whose files are all
  /// gone has nothing left to play and goes too.
  Future<void> pruneEmptyTitles() async {
    await _db.customUpdate(
      "DELETE FROM library_items WHERE kind IN ('movie', 'episode') AND NOT EXISTS "
      "(SELECT 1 FROM library_files f WHERE f.item_id = library_items.id AND f.role = 'video')",
      updates: {_db.libraryItems},
      updateKind: UpdateKind.delete,
    );
    // Seasons first, so a show whose last season just went is caught too.
    for (final kind in const ['season', 'show']) {
      await _db.customUpdate(
        'DELETE FROM library_items WHERE kind = ? AND NOT EXISTS '
        '(SELECT 1 FROM library_items c WHERE c.parent_id = library_items.id)',
        variables: [Variable.withString(kind)],
        updates: {_db.libraryItems},
        updateKind: UpdateKind.delete,
      );
    }
  }

  // ─── Collections and playlists ─────────────────────────────────────────

  Future<int> createList({required String kind, required String title, String? summary, String? tmdbId}) {
    final now = _now();
    return _db
        .into(_db.libraryLists)
        .insert(
          LibraryListsCompanion.insert(
            kind: kind,
            title: title,
            summary: Value(summary),
            tmdbId: Value(tmdbId),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<List<LibraryListRow>> lists(String kind) {
    final query = _db.select(_db.libraryLists)
      ..where((t) => t.kind.equals(kind))
      ..orderBy([(t) => OrderingTerm.asc(t.title)]);
    return query.get();
  }

  Future<void> deleteList(int listId) async {
    await (_db.delete(_db.libraryLists)..where((t) => t.id.equals(listId))).go();
  }

  /// Appends [itemId] to the list; a title already in it stays where it is.
  Future<void> addToList(int listId, int itemId) async {
    final links = _db.libraryListItems;
    final max = links.sortOrder.max();
    final last =
        await (_db.selectOnly(links)
              ..addColumns([max])
              ..where(links.listId.equals(listId)))
            .map((row) => row.read(max))
            .getSingle();
    await _db
        .into(links)
        .insert(
          LibraryListItemsCompanion.insert(listId: listId, itemId: itemId, sortOrder: Value((last ?? -1) + 1)),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removeFromList(int listId, int itemId) async {
    await (_db.delete(_db.libraryListItems)..where((t) => t.listId.equals(listId) & t.itemId.equals(itemId))).go();
  }

  Future<List<LibraryItemView>> listItems(int listId) async {
    final items = _db.libraryItems;
    final links = _db.libraryListItems;
    final states = _db.libraryUserStates;
    final query =
        _db.select(items).join([
            innerJoin(links, links.itemId.equalsExp(items.id)),
            leftOuterJoin(states, states.itemId.equalsExp(items.id)),
          ])
          ..addColumns([_episodeCount, _watchedEpisodeCount])
          ..where(links.listId.equals(listId))
          ..orderBy([OrderingTerm.asc(links.sortOrder)]);
    return (await query.get()).map(_toView).toList();
  }
}
