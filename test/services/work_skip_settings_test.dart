import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/work_skip_settings.dart';
import 'package:plezy/services/work_skip_settings_store.dart';
import 'package:plezy/utils/external_ids.dart';
import '../test_helpers/media_items.dart';

class FakeSkipClient implements MediaServerClient {
  ExternalIds ids = const ExternalIds(tmdb: 100);
  bool offline = false;
  final requests = <String>[];
  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    requests.add(itemId);
    if (offline) throw const SocketException('offline');
    return ids;
  }

  @override
  Future<MediaItem?> fetchItem(String id) async => testMediaItem(id: id, kind: MediaKind.season, parentId: 'show');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const rules = WorkSkipSettings(introEnabled: true, introEndMs: 60000, creditsEnabled: true, creditsDurationMs: 90000);

  test('ranges use the current file duration and keep post-credit scenes', () {
    expect(rules.markersFor(const Duration(minutes: 40)).last.startTime, const Duration(minutes: 38, seconds: 30));
    expect(rules.markersFor(const Duration(minutes: 45)).last.startTime, const Duration(minutes: 43, seconds: 30));
    const scene = WorkSkipSettings(creditsEnabled: true, creditsDurationMs: 90000, creditsResumeBeforeEndMs: 30000);
    expect(scene.markersFor(const Duration(minutes: 40)).single.endTime, const Duration(minutes: 39, seconds: 30));
    expect(
      rules.markersFor(const Duration(seconds: 100)),
      isEmpty,
      reason: 'overlapping ranges must not skip a short file',
    );
    expect(rules.markersFor(Duration.zero), isEmpty);
  });

  test('right click prefills actual time without overwriting the other range', () {
    final intro = rules.prefill(const Duration(seconds: 80), const Duration(minutes: 40));
    expect(intro.introEndMs, 80000);
    expect(intro.creditsDurationMs, 90000);
    final credits = rules.prefill(const Duration(minutes: 39), const Duration(minutes: 40));
    expect(credits.creditsDurationMs, 60000);
    expect(credits.introEndMs, 60000);
    expect(rules.prefill(const Duration(minutes: 20), const Duration(minutes: 40)).creditsDurationMs, 1200000);
  });

  test('rejects negative, empty, overlapping and overlong ranges', () {
    expect(const WorkSkipSettings(introEnabled: true).validFor(), isFalse);
    expect(const WorkSkipSettings(introEnabled: true, introStartMs: -1, introEndMs: 60000).validFor(), isFalse);
    expect(
      const WorkSkipSettings(creditsEnabled: true, creditsDurationMs: 1000, creditsResumeBeforeEndMs: 1000).validFor(),
      isFalse,
    );
    expect(rules.validFor(60000), isFalse);
    expect(rules.validFor(150000), isTrue);
    expect(WorkSkipSettings.fromJson(rules.toJson()).toJson(), rules.toJson());
  });

  group('work storage', () {
    late AppDatabase db;
    late Directory temp;
    late File file;
    late WorkSkipSettingsStore store;
    late LibraryRepository repo;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('plezy_skip_test');
      file = File('${temp.path}/library.db');
      db = AppDatabase.forTesting(NativeDatabase(file));
      store = WorkSkipSettingsStore(db);
      repo = LibraryRepository(db);
    });
    tearDown(() async {
      await db.close();
      await temp.delete(recursive: true);
    });

    Future<int> add({
      String kind = 'movie',
      String type = 'movie',
      String? tmdb = '100',
      int? parent,
      int? show,
      int? season,
      int? episode,
      bool scraped = true,
    }) => repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: kind,
        libraryType: type,
        title: '示例影视',
        sortTitle: 'demo',
        tmdbId: Value(tmdb),
        parentId: Value(parent),
        showId: Value(show),
        seasonNumber: Value(season),
        episodeNumber: Value(episode),
        scrapedAt: Value(scraped ? 1 : null),
        addedAt: 1,
        updatedAt: 1,
      ),
    );
    MediaItem local(int id, {MediaKind kind = MediaKind.movie}) =>
        testMediaItem(id: '$id', serverId: 'local-library', kind: kind);

    test('restart and re-scrape recover settings without a file or index ID', () async {
      final id = await add();
      final work = (await store.resolve(local(id), null))!;
      await store.save(work, rules);
      await (db.delete(db.libraryItems)..where((t) => t.id.equals(id))).go();
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      store = WorkSkipSettingsStore(db);
      repo = LibraryRepository(db);
      final replacement = await add();
      final resolved = (await store.resolve(local(replacement), null))!;
      expect((await store.read(resolved)).toJson(), rules.toJson());
      // A duplicate index / Quark or SMB version uses exactly the same work key.
      final duplicate = await add();
      expect((await store.resolve(local(duplicate), null))!.stateKey(), resolved.stateKey());
    });

    test('any episode and season share the series settings; progress stays separate', () async {
      final show = await add(kind: 'show', type: 'show');
      final season = await add(kind: 'season', type: 'show', tmdb: null, parent: show, season: 1);
      final first = await add(
        kind: 'episode',
        type: 'show',
        tmdb: null,
        parent: season,
        show: show,
        season: 1,
        episode: 1,
      );
      final second = await add(
        kind: 'episode',
        type: 'show',
        tmdb: null,
        parent: season,
        show: show,
        season: 1,
        episode: 2,
      );
      final work = (await store.resolve(local(first, kind: MediaKind.episode), null))!;
      await store.save(work, rules);
      for (final entry in [(show, MediaKind.show), (season, MediaKind.season), (second, MediaKind.episode)]) {
        final key = (await store.resolve(local(entry.$1, kind: entry.$2), null))!;
        expect(key.stateKey(), work.stateKey());
        expect((await store.read(key)).introEndMs, 60000);
      }
      expect(
        await db.select(db.workWatchStates).get(),
        isEmpty,
        reason: 'skip editing does not create or overwrite progress',
      );
    });

    test('a matched series supplies work rules even without episode numbering', () async {
      final show = await add(kind: 'show', type: 'show');
      final season = await add(kind: 'season', type: 'show', tmdb: null, parent: show);
      final episode = await add(kind: 'episode', type: 'show', tmdb: null, parent: season, show: show);
      final key = (await store.resolve(local(show, kind: MediaKind.show), null))!;
      await store.save(key, rules);
      final resolved = (await store.resolve(local(episode, kind: MediaKind.episode), null))!;
      expect(resolved.stateKey(), key.stateKey());
      expect((await store.read(resolved)).introEndMs, 60000);
      expect(await db.select(db.workWatchStates).get(), isEmpty);
    });

    test('unmatched items never get a settings identity', () async {
      final pending = await add(type: 'pending', scraped: false);
      final noId = await add(tmdb: null);
      expect(await store.resolve(local(pending), null), isNull);
      expect(await store.resolve(local(noId), null), isNull);
      expect(await db.select(db.librarySettings).get(), isEmpty);
    });

    test('local, Emby servers and Jellyfin remain independent; offline resolves cached series', () async {
      final localId = await add(kind: 'show', type: 'show');
      final work = (await store.resolve(local(localId, kind: MediaKind.show), null))!;
      await store.save(work, rules);
      final client = FakeSkipClient();
      final episode = testMediaItem(
        id: 'e1',
        kind: MediaKind.episode,
        grandparentId: 'show',
        backend: MediaBackend.emby,
        serverId: 'server-A',
      );
      final emby = (await store.resolve(episode, client))!;
      expect(client.requests.last, 'show');
      expect((await store.read(emby)).introEnabled, isFalse);
      const remoteRules = WorkSkipSettings(introEnabled: true, introEndMs: 120000);
      await store.save(emby, remoteRules);
      expect((await store.read(work)).introEndMs, 60000);
      final other = (await store.resolve(episode.copyWith(serverId: 'server-B'), client))!;
      expect((await store.read(other)).introEnabled, isFalse);
      final jellyfin = (await store.resolve(
        testMediaItem(id: 'e1', kind: MediaKind.show, backend: MediaBackend.jellyfin, serverId: 'server-A'),
        client,
      ))!;
      expect(jellyfin.stateKey(), isNot(emby.stateKey()));
      client.offline = true;
      expect((await store.resolve(episode, client))!.stateKey(), emby.stateKey());
      expect((await store.read((await store.resolve(episode, null))!)).introEndMs, 120000);
      client.offline = false;
      client.ids = const ExternalIds();
      expect(await store.resolve(episode, client), isNull, reason: 'successful unmatch invalidates cache');
      expect(await store.resolve(episode, null), isNull);
    });
  });
}
