import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/media/work_identity.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late LibraryRepository repo;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plezy_work_state_');
    file = File('${directory.path}/library.db');
    db = AppDatabase.forTesting(NativeDatabase(file));
    repo = LibraryRepository(db);
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    repo = LibraryRepository(db);
  }

  Future<int> movie({String? tmdb = '100', String? imdb, bool scraped = true}) => repo.insertItem(
    LibraryItemsCompanion.insert(
      kind: 'movie',
      libraryType: scraped ? 'movie' : 'pending',
      title: 'Film',
      sortTitle: 'film',
      tmdbId: Value(tmdb),
      imdbId: Value(imdb),
      scrapedAt: Value(scraped ? 1 : null),
      addedAt: 1,
      updatedAt: 1,
    ),
  );

  Future<({int show, List<int> episodes})> series() async {
    final show = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: 'show',
        libraryType: 'show',
        title: 'Series',
        sortTitle: 'series',
        tmdbId: const Value('100'),
        scrapedAt: const Value(1),
        addedAt: 1,
        updatedAt: 1,
      ),
    );
    final season = await repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: 'season',
        libraryType: 'show',
        title: 'Season',
        sortTitle: 'season',
        parentId: Value(show),
        seasonNumber: const Value(1),
        addedAt: 1,
        updatedAt: 1,
      ),
    );
    final episodes = <int>[];
    for (var number = 1; number <= 3; number++) {
      episodes.add(
        await repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: 'episode',
            libraryType: 'show',
            title: 'Episode $number',
            sortTitle: 'episode $number',
            parentId: Value(season),
            showId: Value(show),
            seasonNumber: const Value(1),
            episodeNumber: Value(number),
            addedAt: 1,
            updatedAt: 1,
          ),
        ),
      );
    }
    return (show: show, episodes: episodes);
  }

  test('disk restart and rebuilt movie id recover progress, favorite and visibility', () async {
    final oldId = await movie();
    await repo.setProgress(oldId, positionMs: 600000, durationMs: 3600000);
    await repo.setFavorite(oldId, favorite: true);
    await repo.hideFromContinueWatching(oldId);
    await repo.deleteItem(oldId);
    await reopen();
    final newId = await movie();
    expect(newId, isNot(oldId));
    final restored = (await repo.getItem(newId))!.state!;
    expect(restored.positionMs, 600000);
    expect(restored.durationMs, 3600000);
    expect(restored.favorite, isTrue);
    expect(restored.hiddenFromContinue, isTrue);
    expect(await repo.continueWatching(), isEmpty);
    await repo.setProgress(newId, positionMs: 610000, durationMs: 3600000);
    expect((await repo.continueWatching()).single.item.id, newId);
  });

  test('series rebuild restores per-episode progress and unique watched count', () async {
    final old = await series();
    await repo.markWatched(old.episodes[0], watched: true);
    await repo.markWatched(old.episodes[2], watched: true);
    await repo.markWatched(old.episodes[0], watched: true);
    await repo.setProgress(old.episodes[1], positionMs: 123000, durationMs: 2700000);
    expect((await repo.getItem(old.show))!.watchedEpisodeCount, 2);
    await repo.deleteItem(old.show);
    await reopen();
    final next = await series();
    expect(next.show, isNot(old.show));
    expect((await repo.getItem(next.show))!.watchedEpisodeCount, 2);
    expect((await repo.getItem(next.episodes[0]))!.state!.playCount, 1);
    expect((await repo.continueWatching()).single.state!.positionMs, 123000);
    await repo.markWatched(next.episodes[0], watched: false);
    await repo.deleteItem(next.show);
    final again = await series();
    expect((await repo.getItem(again.show))!.watchedEpisodeCount, 1);
  });

  test('index projections never seed persistent work state', () async {
    final matched = await movie();
    await db.delete(db.libraryWorkBindings).go();
    await db
        .into(db.libraryUserStates)
        .insert(
          LibraryUserStatesCompanion.insert(
            itemId: Value(matched),
            positionMs: const Value(111000),
            durationMs: const Value(3600000),
            updatedAt: 5,
          ),
        );
    await reopen();
    expect(await db.select(db.workWatchStates).get(), isEmpty);
    expect((await repo.getItem(matched))!.state, isNull);
    await repo.setProgress(matched, positionMs: 222000, durationMs: 3600000);
    await reopen();
    expect((await repo.getItem(matched))!.state!.positionMs, 222000);
    expect(await db.select(db.workWatchStates).get(), hasLength(1));
  });

  test('unmatched and missing external identity never create new state', () async {
    for (final id in [await movie(scraped: false), await movie(tmdb: null)]) {
      await repo.setProgress(id, positionMs: 120000, durationMs: 3600000);
      await repo.markWatched(id, watched: true);
      await repo.setFavorite(id, favorite: true);
    }
    expect(await db.select(db.workWatchStates).get(), isEmpty);
    expect(await db.select(db.libraryUserStates).get(), isEmpty);
  });

  test('completed playback retains duration and watched state after rebuilding', () async {
    final id = await movie();
    await repo.setProgress(id, positionMs: 3600000, durationMs: 3600000);
    await repo.deleteItem(id);
    final next = await movie();
    final state = (await repo.getItem(next))!.state!;
    expect(state.watched, isTrue);
    expect(state.positionMs, 0);
    expect(state.durationMs, 3600000);
    expect(await repo.continueWatching(), isEmpty);
  });

  test('local, Emby servers, Jellyfin and movie/show namespaces stay independent', () async {
    for (final source in ['emby/server-1', 'emby/server-2', 'jellyfin/server-1']) {
      final identity = WorkIdentity.resolve(source: source, kind: 'movie', tmdbId: '100')!;
      await db
          .into(db.workWatchStates)
          .insert(
            WorkWatchStatesCompanion.insert(
              stateKey: identity.stateKey(),
              source: source,
              kind: identity.kind,
              provider: identity.provider,
              externalId: identity.externalId,
              positionMs: const Value(99000),
              updatedAt: 1,
            ),
          );
    }
    final local = await movie();
    expect((await repo.getItem(local))!.state, isNull);
    await repo.setProgress(local, positionMs: 45000, durationMs: 3600000);
    final show = await series();
    expect((await repo.getItem(show.show))!.state, isNull);
    await reopen();
    await repo.deleteItem(local);
    final rebuilt = await movie();
    expect((await repo.getItem(rebuilt))!.state!.positionMs, 45000);
    final remote = await (db.select(db.workWatchStates)..where((t) => t.source.isNotValue('local-library'))).get();
    expect(remote, hasLength(3));
    expect(remote.every((s) => s.positionMs == 99000), isTrue);
  });

  test('correcting a match switches states and retains the original work progress', () async {
    final id = await movie();
    await repo.setProgress(id, positionMs: 60000, durationMs: 3600000);
    await repo.updateItem(id, const LibraryItemsCompanion(tmdbId: Value('200')));
    expect((await repo.getItem(id))!.state, isNull);
    await repo.setProgress(id, positionMs: 120000, durationMs: 3600000);
    await repo.updateItem(id, const LibraryItemsCompanion(tmdbId: Value('100')));
    expect((await repo.getItem(id))!.state!.positionMs, 60000);
  });

  test('adding TMDB to the same IMDb work preserves progress across rebuild', () async {
    final id = await movie(tmdb: null, imdb: 'tt0000001');
    await repo.setProgress(id, positionMs: 60000, durationMs: 3600000);
    await repo.updateItem(id, const LibraryItemsCompanion(tmdbId: Value('100')));
    expect((await repo.getItem(id))!.state!.positionMs, 60000);
    await repo.deleteItem(id);
    final rebuilt = await movie();
    expect((await repo.getItem(rebuilt))!.state!.positionMs, 60000);
  });

  test('two file versions and duplicate index entries share one persisted state', () async {
    final first = await movie();
    final second = await movie();
    await repo.setProgress(first, positionMs: 60000, durationMs: 3600000);
    expect((await repo.getItem(second))!.state!.positionMs, 60000);
    await repo.setProgress(second, positionMs: 120000, durationMs: 3600000);
    expect((await repo.getItem(first))!.state!.positionMs, 120000);
    expect(await db.select(db.workWatchStates).get(), hasLength(1));
  });
}
