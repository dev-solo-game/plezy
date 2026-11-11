import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  var tick = 1000;

  setUp(() async {
    tick = 1000;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    await db
        .into(db.mounts)
        .insert(MountsCompanion.insert(id: 'm1', kind: 'local', displayName: 'Disk', configJson: '{}', createdAt: 0));
  });

  tearDown(() async {
    await db.close();
  });

  /// Runs [body] with a clock that advances on every read, so rows written in
  /// sequence get distinct, ordered timestamps.
  Future<T> timed<T>(Future<T> Function() body) {
    return withClock(Clock(() => DateTime.fromMillisecondsSinceEpoch(tick += 1000)), body);
  }

  Future<int> addTitle(
    String title, {
    String kind = LibraryKinds.movie,
    String libraryType = 'movie',
    int? year,
    double? rating,
    int? parentId,
    int? showId,
    int? season,
    int? episode,
    String? originalTitle,
    String? aliases,
    String? tmdbId,
    bool locked = false,
  }) {
    return timed(
      () => repo.insertItem(
        LibraryItemsCompanion.insert(
          kind: kind,
          libraryType: libraryType,
          title: title,
          sortTitle: LibraryRepository.sortTitleFor(title),
          originalTitle: Value(originalTitle),
          aliases: Value(aliases),
          year: Value(year),
          rating: Value(rating),
          parentId: Value(parentId),
          showId: Value(showId),
          seasonNumber: Value(season),
          episodeNumber: Value(episode),
          tmdbId: Value(tmdbId),
          locked: Value(locked),
          addedAt: clock.now().millisecondsSinceEpoch,
          updatedAt: clock.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  Future<int> addVideo(String path, {int? itemId, int scanId = 1, int size = 100}) async {
    final id = await repo.upsertFile(
      mountId: 'm1',
      path: path,
      role: LibraryFileRoles.video,
      scanId: scanId,
      size: size,
      modifiedAt: 1,
    );
    if (itemId != null) await repo.assignFile(id, itemId);
    return id;
  }

  /// A show with two seasons of two episodes and one special.
  Future<({int show, int s1, int s2, List<int> episodes, int special})> addShow() async {
    final show = await addTitle('The Expanse', kind: LibraryKinds.show, libraryType: 'show');
    final s0 = await addTitle('Specials', kind: LibraryKinds.season, libraryType: 'show', parentId: show, season: 0);
    final s1 = await addTitle('Season 1', kind: LibraryKinds.season, libraryType: 'show', parentId: show, season: 1);
    final s2 = await addTitle('Season 2', kind: LibraryKinds.season, libraryType: 'show', parentId: show, season: 2);
    Future<int> ep(int parent, int season, int number) => addTitle(
      'S${season}E$number',
      kind: LibraryKinds.episode,
      libraryType: 'show',
      parentId: parent,
      showId: show,
      season: season,
      episode: number,
    );
    final special = await ep(s0, 0, 1);
    // Inserted out of order on purpose.
    final e22 = await ep(s2, 2, 2);
    final e11 = await ep(s1, 1, 1);
    final e21 = await ep(s2, 2, 1);
    final e12 = await ep(s1, 1, 2);
    return (show: show, s1: s1, s2: s2, episodes: [e11, e12, e21, e22], special: special);
  }

  test('sortTitleFor drops a leading article', () {
    expect(LibraryRepository.sortTitleFor('The Matrix'), 'matrix');
    expect(LibraryRepository.sortTitleFor('A Quiet Place'), 'quiet place');
    expect(LibraryRepository.sortTitleFor('Them!'), 'them!');
    expect(LibraryRepository.sortTitleFor('流浪地球'), '流浪地球');
  });

  group('queryTitles', () {
    test('pages a shelf by title and reports the total', () async {
      for (final title in ['The Matrix', 'Alien', 'Zodiac', 'Blade Runner']) {
        await addTitle(title);
      }
      await addTitle('Some Show', kind: LibraryKinds.show, libraryType: 'show');

      final first = await repo.queryTitles(
        const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, limit: 3),
      );
      expect(first.total, 4);
      expect(first.items.map((v) => v.item.title), ['Alien', 'Blade Runner', 'The Matrix']);

      final second = await repo.queryTitles(
        const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, limit: 3, offset: 3),
      );
      expect(second.items.map((v) => v.item.title), ['Zodiac']);
    });

    test('sorts by year and rating with missing values last', () async {
      await addTitle('Old', year: 1980, rating: 6);
      await addTitle('New', year: 2020, rating: 9);
      await addTitle('Unknown');

      Future<List<String>> titles(LibrarySort sort, {bool descending = false}) async {
        final page = await repo.queryTitles(
          LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, sort: sort, descending: descending),
        );
        return page.items.map((v) => v.item.title).toList();
      }

      expect(await titles(LibrarySort.year), ['Old', 'New', 'Unknown']);
      expect(await titles(LibrarySort.year, descending: true), ['New', 'Old', 'Unknown']);
      expect(await titles(LibrarySort.rating, descending: true), ['New', 'Old', 'Unknown']);
      expect(await titles(LibrarySort.addedAt, descending: true), ['Unknown', 'New', 'Old']);
    });

    test('filters by genre, year, favorite and search text', () async {
      final dune = await addTitle('Dune', year: 2021, originalTitle: 'Dune: Part One', aliases: '沙丘');
      final alien = await addTitle('Alien', year: 1979);
      await addTitle('50% Off', year: 2021);
      await repo.setGenres(dune, ['Sci-Fi', 'Adventure']);
      await repo.setGenres(alien, ['Sci-Fi', 'Horror']);
      await repo.setFavorite(alien, favorite: true);

      final genres = await repo.genresOnShelf(libraryType: 'movie', kind: LibraryKinds.movie);
      expect(genres.map((g) => g.name), ['Adventure', 'Horror', 'Sci-Fi']);
      final horror = genres.firstWhere((g) => g.name == 'Horror').id;

      Future<List<String>> titles(LibraryQuery query) async =>
          (await repo.queryTitles(query)).items.map((v) => v.item.title).toList();

      expect(await titles(LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, genreId: horror)), ['Alien']);
      expect(await titles(const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, year: 2021)), [
        '50% Off',
        'Dune',
      ]);
      expect(await titles(const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, favoritesOnly: true)), [
        'Alien',
      ]);
      expect(await titles(const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, search: '沙丘')), ['Dune']);
      expect(await titles(const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, search: 'part one')), [
        'Dune',
      ]);
      // "%" is matched literally, not as a wildcard.
      expect(await titles(const LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, search: '%')), [
        '50% Off',
      ]);
      expect(await repo.years(libraryType: 'movie', kind: LibraryKinds.movie), [2021, 1979]);
    });

    test('watched filter works for movies and for shows by their episodes', () async {
      final seen = await addTitle('Seen');
      await addTitle('Unseen');
      await repo.markWatched(seen, watched: true);

      Future<List<String>> movies(bool watched) async => (await repo.queryTitles(
        LibraryQuery(libraryType: 'movie', kind: LibraryKinds.movie, watched: watched),
      )).items.map((v) => v.item.title).toList();
      expect(await movies(true), ['Seen']);
      expect(await movies(false), ['Unseen']);

      final show = await addShow();
      Future<int> shows(bool watched) async =>
          (await repo.queryTitles(LibraryQuery(libraryType: 'show', kind: LibraryKinds.show, watched: watched))).total;
      expect(await shows(false), 1);
      await repo.markWatched(show.show, watched: true);
      expect(await shows(true), 1);
      expect(await shows(false), 0);
    });
  });

  group('shows', () {
    test('children and episodesOfShow come back in watch order with counts', () async {
      final show = await addShow();

      final seasons = await repo.children(show.show);
      expect(seasons.map((v) => v.item.seasonNumber), [0, 1, 2]);
      expect(seasons[1].episodeCount, 2);

      final episodes = await repo.episodesOfShow(show.show);
      expect(episodes.map((v) => v.item.title), ['S1E1', 'S1E2', 'S2E1', 'S2E2', 'S0E1']);

      final view = (await repo.getItem(show.show))!;
      expect(view.episodeCount, 5);
      expect(view.watchedEpisodeCount, 0);
      expect(view.isWatched, isFalse);
    });

    test('marking a season watched covers its episodes and moves next-up on', () async {
      final show = await addShow();
      expect((await repo.nextUnwatchedEpisode(show.show))!.item.title, 'S1E1');

      await repo.markWatched(show.s1, watched: true);
      expect((await repo.getItem(show.s1))!.isWatched, isTrue);
      expect((await repo.getItem(show.show))!.watchedEpisodeCount, 2);
      expect((await repo.nextUnwatchedEpisode(show.show))!.item.title, 'S2E1');

      await repo.markWatched(show.show, watched: true);
      expect((await repo.getItem(show.show))!.isWatched, isTrue);
      expect(await repo.nextUnwatchedEpisode(show.show), isNull);

      await repo.markWatched(show.show, watched: false);
      expect((await repo.getItem(show.show))!.watchedEpisodeCount, 0);
    });

    test('deleting a show removes its seasons, episodes and their state', () async {
      final show = await addShow();
      await repo.setProgress(show.episodes.first, positionMs: 5, durationMs: 100);
      await repo.deleteItem(show.show);
      expect(await db.select(db.libraryItems).get(), isEmpty);
      expect(await db.select(db.libraryUserStates).get(), isEmpty);
    });
  });

  group('user state', () {
    test('progress feeds Continue Watching, most recent first', () async {
      final a = await addTitle('A');
      final b = await addTitle('B');
      await addTitle('Untouched');
      await timed(() => repo.setProgress(a, positionMs: 60000, durationMs: 600000));
      await timed(() => repo.setProgress(b, positionMs: 30000, durationMs: 600000));

      final rows = await repo.continueWatching();
      expect(rows.map((v) => v.item.title), ['B', 'A']);
      expect(rows.first.state!.positionMs, 30000);
    });

    test('reaching the threshold marks watched and clears the resume point', () async {
      final a = await addTitle('A');
      await repo.setProgress(a, positionMs: 60000, durationMs: 600000);
      await repo.setProgress(a, positionMs: 590000, durationMs: 600000);

      final view = (await repo.getItem(a))!;
      expect(view.isWatched, isTrue);
      expect(view.state!.positionMs, 0);
      expect(view.state!.playCount, 1);
      expect(await repo.continueWatching(), isEmpty);

      // Watching it again counts a second play only once it finishes again.
      await repo.markWatched(a, watched: true);
      expect((await repo.getItem(a))!.state!.playCount, 1);
    });

    test('hiding keeps the resume point; playing again brings it back', () async {
      final a = await addTitle('A');
      await repo.setProgress(a, positionMs: 60000, durationMs: 600000);
      await repo.hideFromContinueWatching(a);
      expect(await repo.continueWatching(), isEmpty);
      expect((await repo.getItem(a))!.state!.positionMs, 60000);

      await repo.setProgress(a, positionMs: 70000, durationMs: 600000);
      expect((await repo.continueWatching()).single.item.title, 'A');
    });

    test('favorite and progress do not overwrite each other', () async {
      final a = await addTitle('A');
      await repo.setFavorite(a, favorite: true);
      await repo.setProgress(a, positionMs: 1000, durationMs: 600000);
      final state = (await repo.getItem(a))!.state!;
      expect(state.favorite, isTrue);
      expect(state.positionMs, 1000);
    });
  });

  group('files', () {
    test('a rescan keeps the row, its match and its probed info', () async {
      final film = await addTitle('Film');
      final id = await addVideo('/Movies/film.mkv', itemId: film);
      await repo.updateFile(id, const LibraryFilesCompanion(durationMs: Value(7200000), videoCodec: Value('hevc')));

      final again = await addVideo('/Movies/film.mkv', scanId: 2);
      expect(again, id);
      final row = (await repo.getFile(id))!;
      expect(row.itemId, film);
      expect(row.matchState, LibraryMatchStates.matched);
      expect(row.durationMs, 7200000);
      expect(row.seenInScan, 2);
    });

    test('a file whose content changed loses its probed info but not its match', () async {
      final film = await addTitle('Film');
      final id = await addVideo('/Movies/film.mkv', itemId: film);
      await repo.updateFile(id, const LibraryFilesCompanion(durationMs: Value(7200000)));

      await addVideo('/Movies/film.mkv', scanId: 2, size: 999);
      final row = (await repo.getFile(id))!;
      expect(row.durationMs, isNull);
      expect(row.itemId, film);
    });

    test('several videos of one title are versions, largest first, with subtitles', () async {
      final film = await addTitle('Film');
      final small = await addVideo('/Movies/film.1080p.mkv', itemId: film, size: 10);
      final large = await addVideo('/Movies/film.2160p.mkv', itemId: film, size: 50);
      await repo.upsertFile(
        mountId: 'm1',
        path: '/Movies/film.2160p.zh.srt',
        role: LibraryFileRoles.subtitle,
        scanId: 1,
        ownerFileId: large,
        language: 'zh',
      );

      expect((await repo.versionsOf(film)).map((f) => f.id), [large, small]);
      expect((await repo.subtitlesOf(large)).single.language, 'zh');
      expect(await repo.subtitlesOf(small), isEmpty);
    });

    test('unmatched videos are listed and counted; a manual match is locked', () async {
      final a = await addVideo('/Misc/a.mkv');
      await addVideo('/Misc/b.mkv');
      expect((await repo.videosInState(LibraryMatchStates.pending)).length, 2);

      await repo.setFileMatchState(a, LibraryMatchStates.unmatched);
      expect(await repo.countVideosInState(LibraryMatchStates.unmatched), 1);
      expect((await repo.videosInState(LibraryMatchStates.unmatched)).single.path, '/Misc/a.mkv');

      final film = await addTitle('Film');
      await repo.assignFile(a, film, locked: true);
      final row = (await repo.getFile(a))!;
      expect(row.matchState, LibraryMatchStates.matched);
      expect(row.matchLocked, isTrue);
      expect(await repo.countVideosInState(LibraryMatchStates.unmatched), 0);
    });

    test('files a scan did not see are removed along with emptied titles', () async {
      final gone = await addTitle('Gone');
      final kept = await addTitle('Kept');
      final pinned = await addTitle('Pinned', locked: true);
      final show = await addShow();
      await addVideo('/Movies/gone.mkv', itemId: gone);
      await addVideo('/Movies/pinned.mkv', itemId: pinned);
      await addVideo('/Movies/kept.mkv', itemId: kept);
      for (final (index, episode) in show.episodes.indexed) {
        await addVideo('/Shows/e$index.mkv', itemId: episode);
      }
      await addVideo('/Shows/special.mkv', itemId: show.special);

      // Scan 2 sees only the kept movie and one episode of season 2.
      await addVideo('/Movies/kept.mkv', scanId: 2);
      await addVideo('/Shows/e3.mkv', scanId: 2);
      final removed = await repo.removeFilesNotSeen('m1', 2);
      expect(removed, 6);

      final titles = (await db.select(db.libraryItems).get()).map((i) => i.title).toSet();
      expect(titles, {'Kept', 'Pinned', 'The Expanse', 'Season 2', 'S2E2'});
    });

    test('removing a mount removes its files but leaves titles for pruning', () async {
      final film = await addTitle('Film');
      await addVideo('/Movies/film.mkv', itemId: film);
      await (db.delete(db.mounts)..where((t) => t.id.equals('m1'))).go();
      expect(await db.select(db.libraryFiles).get(), isEmpty);

      await repo.pruneEmptyTitles();
      expect(await db.select(db.libraryItems).get(), isEmpty);
    });
  });

  group('credits, lists and lookups', () {
    test('credits reuse people and list in billing order', () async {
      final a = await addTitle('A');
      final b = await addTitle('B', year: 2001);
      await repo.setCredits(a, [
        (name: 'Jane Doe', job: 'actor', character: 'Hero', tmdbId: '7', photoSource: null),
        (name: 'John Roe', job: 'director', character: null, tmdbId: null, photoSource: null),
      ]);
      await repo.setCredits(b, [
        (name: 'Jane D.', job: 'actor', character: 'Villain', tmdbId: '7', photoSource: 'https://img/jane.jpg'),
      ]);

      expect(await db.select(db.libraryPeople).get(), hasLength(2));
      final credits = await repo.creditsOf(a);
      expect(credits.map((c) => '${c.person.name}:${c.job}:${c.character}'), [
        'Jane Doe:actor:Hero',
        'John Roe:director:null',
      ]);
      expect(credits.first.person.photoSource, 'https://img/jane.jpg', reason: 'a later photo fills the gap');

      final jane = credits.first.person.id;
      expect((await repo.titlesWithPerson(jane)).map((v) => v.item.title), ['B', 'A']);
    });

    test('lists keep insertion order and ignore duplicates', () async {
      final a = await addTitle('A');
      final b = await addTitle('B');
      final list = await repo.createList(kind: LibraryListKinds.collection, title: 'Saga');
      await repo.addToList(list, b);
      await repo.addToList(list, a);
      await repo.addToList(list, b);

      expect((await repo.listItems(list)).map((v) => v.item.title), ['B', 'A']);
      await repo.removeFromList(list, b);
      expect((await repo.listItems(list)).map((v) => v.item.title), ['A']);
      expect((await repo.lists(LibraryListKinds.collection)).single.title, 'Saga');
      expect(await repo.lists(LibraryListKinds.playlist), isEmpty);
    });

    test('findByExternalId, search and recentlyAdded', () async {
      await addTitle('Dune', tmdbId: '438631');
      await addTitle('Dune', kind: LibraryKinds.show, libraryType: 'show', tmdbId: '90228');
      final ep = await addTitle('Dune pilot', kind: LibraryKinds.episode, libraryType: 'show');

      final found = await repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '438631');
      expect(found?.kind, LibraryKinds.movie);
      expect(await repo.findByExternalId(kind: LibraryKinds.movie, tmdbId: '1'), isNull);

      final hits = await repo.search('dune');
      expect(hits.map((v) => v.item.kind).toSet(), {LibraryKinds.movie, LibraryKinds.show});
      expect(hits.any((v) => v.item.id == ep), isFalse, reason: 'episodes are not top-level results');

      expect((await repo.recentlyAdded()).first.item.kind, LibraryKinds.show);
      expect((await repo.recentlyAdded(libraryType: 'movie')).single.item.kind, LibraryKinds.movie);
    });
  });

  test('v27 migration adds the library tables and their indexes', () async {
    await db.close();
    final tempDir = await Directory.systemTemp.createTemp('plezy_db_v27_migration_test_');
    final file = File('${tempDir.path}/plezy.db');
    AppDatabase? reopened;
    try {
      // A v26-shaped database: the current schema minus what v27 adds.
      final seeded = AppDatabase.forTesting(NativeDatabase(file));
      await seeded.select(seeded.mounts).get();
      for (final table in [
        'library_scan_states',
        'library_list_items',
        'library_lists',
        'library_credits',
        'library_people',
        'library_item_genres',
        'library_genres',
        'library_user_states',
        'library_files',
        'library_items',
      ]) {
        await seeded.customStatement('DROP TABLE $table');
      }
      await seeded.customStatement('PRAGMA user_version = 26');
      await seeded.close();

      reopened = AppDatabase.forTesting(NativeDatabase(file));
      final migrated = LibraryRepository(reopened);
      final id = await migrated.insertItem(
        LibraryItemsCompanion.insert(
          kind: LibraryKinds.movie,
          libraryType: 'movie',
          title: 'After',
          sortTitle: 'after',
          addedAt: 1,
          updatedAt: 1,
        ),
      );
      expect((await migrated.getItem(id))!.item.title, 'After');

      final indexes = await reopened
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_library_%'")
          .map((row) => row.read<String>('name'))
          .get();
      expect(indexes, containsAll(['idx_library_items_kind_type', 'idx_library_files_mount_path']));
    } finally {
      await reopened?.close();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await tempDir.delete(recursive: true);
    }
  });
}
