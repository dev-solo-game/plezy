import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scraper.dart';
import 'package:plezy/library/scrapers/bangumi_provider.dart';
import 'package:plezy/library/scrapers/nfo_reader.dart';
import 'package:plezy/library/scrapers/scraped_metadata.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/storage/storage_path.dart';

class _TreeDriver implements StorageDriver {
  final Set<String> files = {};

  @override
  StorageKind get kind => StorageKind.local;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final directory = StoragePath.normalize(path);
    final depth = StoragePath.segments(directory).length;
    final seen = <String, StorageEntry>{};
    for (final file in files) {
      final segments = StoragePath.segments(file);
      if (segments.length <= depth) continue;
      final prefix = depth == 0 ? '' : '/${segments.sublist(0, depth).join('/')}';
      if (depth > 0 && prefix != directory) continue;
      final childPath = '$prefix/${segments[depth]}';
      final isFile = segments.length == depth + 1;
      seen.putIfAbsent(
        childPath,
        () => StorageEntry(path: childPath, name: segments[depth], isDirectory: !isFile, size: isFile ? 10 : null),
      );
    }
    return seen.values.toList();
  }

  @override
  Future<StorageEntry> stat(String path) => throw UnimplementedError();

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

class _FakeProvider implements MetadataProvider {
  _FakeProvider(this.source);

  @override
  final String source;

  /// Search results by lower-cased query.
  final Map<String, List<ScrapedCandidate>> results = {};
  final Map<String, ScrapedTitle> details = {};
  final Map<String, ScrapedSeason> seasons = {};
  final List<String> calls = [];
  ScrapeException? failWith;

  ScrapedCandidate hit(String id, String title, {int? year, String? original}) =>
      ScrapedCandidate(source: source, id: id, title: title, year: year, originalTitle: original);

  Future<List<ScrapedCandidate>> _search(String kind, String title, int? year) async {
    calls.add('$kind:$title:${year ?? ''}');
    if (failWith case final failure?) throw failure;
    return results[title.toLowerCase()] ?? const [];
  }

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) => _search('movie', title, year);

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) => _search('show', title, year);

  @override
  Future<ScrapedTitle> movie(String id) async => details[id]!;

  @override
  Future<ScrapedTitle> show(String id) async => details[id]!;

  @override
  Future<ScrapedSeason?> season(String id, int number) async => seasons['$id/$number'];

  @override
  void close() {}
}

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late _TreeDriver driver;
  late _FakeProvider tmdb;
  late _FakeProvider bangumi;
  late LibraryScraper scraper;

  const mount = StorageMount(id: 'm1', kind: StorageKind.local, displayName: 'Disk');

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    driver = _TreeDriver();
    tmdb = _FakeProvider('tmdb');
    bangumi = _FakeProvider('bangumi');
    scraper = LibraryScraper(db, repo, providers: [tmdb, bangumi]);
    await db
        .into(db.mounts)
        .insert(MountsCompanion.insert(id: 'm1', kind: 'local', displayName: 'Disk', configJson: '{}', createdAt: 0));
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> scan() => LibraryScanner(db, repo).scan(mount, driver);

  Future<List<LibraryItemRow>> items(String kind) async =>
      (await db.select(db.libraryItems).get()).where((i) => i.kind == kind).toList();

  test('Bangumi tags that are dates, formats or sources are not genres', () {
    for (final noise in ['2016', '2018年7月', '2023年', 'TV', 'WEB', '漫画改', '剧场版', 'OVA', '日本', '']) {
      expect(BangumiProvider.isNoiseTag(noise), isTrue, reason: noise);
    }
    for (final genre in ['科幻', '治愈', '战斗', 'BL', '恋爱', 'Sci-Fi & Fantasy', '3年B组']) {
      expect(BangumiProvider.isNoiseTag(genre), isFalse, reason: genre);
    }
  });

  test('matchScore rewards the right year and vetoes a distant one', () {
    final same = ScrapedCandidate(source: 'tmdb', id: '1', title: 'Dune', year: 2021);
    final old = ScrapedCandidate(source: 'tmdb', id: '2', title: 'Dune', year: 1984);
    expect(LibraryScraper.matchScore('Dune', 2021, same), greaterThan(1));
    expect(LibraryScraper.matchScore('Dune', 2021, old), lessThan(0.72));
    expect(LibraryScraper.matchScore('dune', null, old), 1);
    final original = ScrapedCandidate(source: 'tmdb', id: '3', title: '沙丘', originalTitle: 'Dune', year: 2021);
    expect(LibraryScraper.matchScore('Dune', 2021, original), greaterThan(1));
    final other = ScrapedCandidate(source: 'tmdb', id: '4', title: 'Dunkirk', year: 2017);
    expect(LibraryScraper.matchScore('Dune', null, other), lessThan(0.72));
  });

  test('a movie is matched, filled in and its files marked', () async {
    driver.files.add('/Movies/Dune.2021.1080p.mkv');
    await scan();
    tmdb.results['dune'] = [tmdb.hit('99', 'Dune', year: 1984), tmdb.hit('438631', '沙丘', year: 2021, original: 'Dune')];
    tmdb.details['438631'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '438631',
      title: '沙丘',
      originalTitle: 'Dune',
      year: 2021,
      summary: 'Spice.',
      rating: 7.8,
      genres: ['科幻', '冒险'],
      posterSource: 'https://img/p.jpg',
      credits: [ScrapedCredit(name: 'Timothée Chalamet', job: 'actor', character: 'Paul', tmdbId: '1')],
      collectionId: '726871',
      collectionTitle: '沙丘系列',
    );

    final summary = await scraper.scrapePending();
    expect((summary.matched, summary.unmatched, summary.stoppedBy), (1, 0, null));

    final movie = (await items(LibraryKinds.movie)).single;
    expect(movie.title, '沙丘');
    expect(movie.tmdbId, '438631');
    expect(movie.metadataSource, 'tmdb');
    expect(movie.libraryType, LibraryTypes.movie, reason: 'no category from the source: movies go to Movies');
    expect(movie.aliases, contains('Dune'), reason: 'the parsed name stays searchable');
    expect((await repo.genresOf(movie.id)).map((g) => g.name), ['冒险', '科幻']);
    expect((await repo.creditsOf(movie.id)).single.character, 'Paul');
    expect((await repo.versionsOf(movie.id)).single.matchState, LibraryMatchStates.matched);
    final collection = (await repo.lists(LibraryListKinds.collection)).single;
    expect((await repo.listItems(collection.id)).single.item.id, movie.id);

    // A later file with the old name lands on the same title via its alias.
    driver.files.add('/Movies/Dune.2021.2160p.mkv');
    await scan();
    expect((await items(LibraryKinds.movie)).length, 1);
    expect((await repo.versionsOf(movie.id)).length, 2);
  });

  test('no confident hit leaves the title unmatched and out of the queue', () async {
    driver.files.add('/Movies/Obscure Home Video.mkv');
    await scan();
    tmdb.results['obscure home video'] = [tmdb.hit('5', 'Something Else Entirely')];

    final summary = await scraper.scrapePending();
    expect((summary.matched, summary.unmatched), (0, 1));
    expect((await repo.videosInState(LibraryMatchStates.unmatched)).single.path, '/Movies/Obscure Home Video.mkv');

    tmdb.calls.clear();
    await scraper.scrapePending();
    expect(tmdb.calls, isEmpty, reason: 'a failed lookup is not repeated on every run');

    await scraper.requeueUnmatched();
    await scraper.scrapePending();
    expect(tmdb.calls, isNotEmpty);
  });

  test('a year that hides the title is retried without it', () async {
    driver.files.add('/Movies/Dune (2020).mkv');
    await scan();
    // The fake ignores the year; an empty first answer forces the retry path.
    tmdb.results['dune'] = [];
    await scraper.scrapePending();
    expect(tmdb.calls, [
      'movie:Dune:2020',
      'movie:Dune:',
      // Nothing as a movie: maybe the name was mistaken for one.
      'show:Dune:2020',
      'show:Dune:',
    ]);
  });

  test('two names for one film merge into one title with two versions', () async {
    driver.files
      ..add('/A/流浪地球2 (2023).mkv')
      ..add('/B/The.Wandering.Earth.II.2023.2160p.mkv');
    await scan();
    expect((await items(LibraryKinds.movie)).length, 2);

    final hit = tmdb.hit('842675', '流浪地球2', year: 2023, original: 'The Wandering Earth II');
    tmdb.results['流浪地球2'] = [hit];
    tmdb.results['the wandering earth ii'] = [hit];
    tmdb.details['842675'] = const ScrapedTitle(source: 'tmdb', tmdbId: '842675', title: '流浪地球2', year: 2023);

    final summary = await scraper.scrapePending();
    expect((summary.matched, summary.merged), (1, 1));
    final movie = (await items(LibraryKinds.movie)).single;
    final versions = await repo.versionsOf(movie.id);
    expect(versions.length, 2);
    expect(versions.every((v) => v.matchState == LibraryMatchStates.matched), isTrue);
    expect(movie.aliases, contains('The Wandering Earth II'));
  });

  test('a show gets season and episode details for the seasons it has', () async {
    driver.files
      ..add('/TV/Severance/Season 1/Severance.S01E01.mkv')
      ..add('/TV/Severance/Season 1/Severance.S01E02.mkv');
    await scan();
    tmdb.results['severance'] = [tmdb.hit('95396', 'Severance', year: 2022)];
    tmdb.details['95396'] = const ScrapedTitle(source: 'tmdb', tmdbId: '95396', title: '人生切割术', year: 2022);
    tmdb.seasons['95396/1'] = const ScrapedSeason(
      number: 1,
      title: '第 1 季',
      episodes: [
        ScrapedEpisode(
          number: 1,
          title: 'Good News About Hell',
          airDate: '2022-02-18',
          stillSource: 'https://img/1.jpg',
        ),
        ScrapedEpisode(number: 2, title: 'Half Loop'),
      ],
    );

    await scraper.scrapePending();
    final show = (await items(LibraryKinds.show)).single;
    expect(show.title, '人生切割术');
    final season = (await repo.children(show.id)).single.item;
    expect(season.title, '第 1 季');
    final episodes = await repo.children(season.id);
    expect(episodes.map((e) => e.item.title), ['Good News About Hell', 'Half Loop']);
    expect(episodes.first.item.posterSource, 'https://img/1.jpg');
    expect((await repo.versionsOf(episodes.first.item.id)).single.matchState, LibraryMatchStates.matched);
  });

  test('anime asks Bangumi first and falls back to TMDB', () async {
    driver.files
      ..add('/Anime/[Group] Frieren - 01 [1080p].mkv')
      ..add('/Anime/[Group] Unknown Show - 01 [1080p].mkv');
    await scan();
    bangumi.results['frieren'] = [bangumi.hit('400602', 'Frieren', year: 2023)];
    bangumi.details['400602'] = const ScrapedTitle(
      source: 'bangumi',
      bangumiId: '400602',
      title: '葬送的芙莉莲',
      category: LibraryTypes.anime,
    );
    bangumi.seasons['400602/1'] = const ScrapedSeason(number: 1, episodes: [ScrapedEpisode(number: 1, title: '冒险的结束')]);
    tmdb.results['unknown show'] = [tmdb.hit('7', 'Unknown Show')];
    tmdb.details['7'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '7',
      title: 'Unknown Show',
      category: LibraryTypes.anime,
    );

    await scraper.scrapePending();
    final shows = await items(LibraryKinds.show);
    final frieren = shows.firstWhere((s) => s.bangumiId == '400602');
    expect(frieren.title, '葬送的芙莉莲');
    expect(frieren.libraryType, LibraryTypes.anime);
    expect((await repo.episodesOfShow(frieren.id)).single.item.title, '冒险的结束');
    expect(shows.firstWhere((s) => s.tmdbId == '7').metadataSource, 'tmdb');
    expect(tmdb.calls, ['show:Unknown Show:'], reason: 'TMDB is only asked when Bangumi has nothing');
  });

  test('the shelf comes from what the source says the title is', () async {
    driver.files
      ..add('/Mixed/Running Man/Running.Man.E01.mkv')
      ..add('/Mixed/Running Man/Running.Man.E02.mkv')
      ..add('/Mixed/Planet Earth (2006).mkv')
      ..add('/Mixed/Attack on Titan/Attack.on.Titan.S01E01.mkv');
    await scan();
    tmdb.results['running man'] = [tmdb.hit('33238', 'Running Man', year: 2010)];
    tmdb.details['33238'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '33238',
      title: '奔跑吧',
      category: LibraryTypes.variety,
    );
    tmdb.results['planet earth'] = [tmdb.hit('1044', 'Planet Earth', year: 2006)];
    tmdb.details['1044'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '1044',
      title: '地球脉动',
      category: LibraryTypes.documentary,
    );
    tmdb.results['attack on titan'] = [tmdb.hit('1429', 'Attack on Titan', year: 2013)];
    tmdb.details['1429'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '1429',
      title: '进击的巨人',
      category: LibraryTypes.anime,
    );

    await scraper.scrapePending();
    final shelves = {for (final row in await db.select(db.libraryItems).get()) row.title: row.libraryType};
    expect(shelves['奔跑吧'], LibraryTypes.variety);
    expect(shelves['地球脉动'], LibraryTypes.documentary);
    expect(shelves['进击的巨人'], LibraryTypes.anime);
    expect(bangumi.calls, isEmpty, reason: 'nothing in these names or folders looks like anime');

    final anime = await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.anime));
    expect(anime.items.single.item.title, '进击的巨人');
    final episodes = await repo.episodesOfShow(anime.items.single.item.id);
    expect(episodes.single.item.libraryType, LibraryTypes.anime, reason: 'episodes move with their show');
  });

  test('folders above the title pick the shelf when the source only says movie or show', () async {
    driver.files
      ..add('/电视剧/综艺/乘风破浪的姐姐 (2020)/Season 7/乘风破浪的姐姐 - S07E01 - 第 1 集.mkv')
      ..add('/电视剧/纪录片/河西走廊 (2015)/Season 1/河西走廊 - S01E01 - 第 1 集.mkv')
      ..add('/电视剧/国产剧/繁花 (2023)/Season 1/繁花 - S01E01 - 第 1 集.mkv')
      ..add('/电影/华语电影/动画人生 (2020)/动画人生 (2020) - 1080p.mkv');
    await scan();
    for (final (id, name, year) in [
      ('1', '乘风破浪的姐姐', 2020),
      ('2', '河西走廊', 2015),
      ('3', '繁花', 2023),
      ('4', '动画人生', 2020),
    ]) {
      tmdb.results[name] = [tmdb.hit(id, name, year: year)];
      tmdb.details[id] = ScrapedTitle(
        source: 'tmdb',
        tmdbId: id,
        title: name,
        // What TMDB says without a telling genre.
        category: name == '动画人生' ? LibraryTypes.movie : LibraryTypes.show,
      );
    }

    await scraper.scrapePending();
    final shelves = {for (final row in await db.select(db.libraryItems).get()) row.title: row.libraryType};
    expect(shelves['乘风破浪的姐姐'], LibraryTypes.variety);
    expect(shelves['河西走廊'], LibraryTypes.documentary);
    expect(shelves['繁花'], LibraryTypes.show);
    expect(shelves['动画人生'], LibraryTypes.movie, reason: "the title's own folder is not a category");
  });

  test('a specific genre from the source beats the folder', () async {
    driver.files.add('/电视剧/国产剧/中国奇谭 (2023)/Season 1/中国奇谭 - S01E01 - 第 1 集.mkv');
    await scan();
    tmdb.results['中国奇谭'] = [tmdb.hit('9', '中国奇谭', year: 2023)];
    tmdb.details['9'] = const ScrapedTitle(source: 'tmdb', tmdbId: '9', title: '中国奇谭', category: LibraryTypes.anime);
    await scraper.scrapePending();
    expect((await items(LibraryKinds.show)).single.libraryType, LibraryTypes.anime);
  });

  test('films in an animation folder ask TMDB first, series ask Bangumi first', () async {
    driver.files
      ..add('/电影/动画电影/头脑特工队2 (2024)/头脑特工队2 (2024) - 1080p.mkv')
      ..add('/电视剧/国漫/仙逆 (2023)/Season 1/仙逆 - S01E01 - 第 1 集.mkv');
    await scan();
    tmdb.results['头脑特工队2'] = [tmdb.hit('1022789', '头脑特工队2', year: 2024)];
    tmdb.details['1022789'] = const ScrapedTitle(
      source: 'tmdb',
      tmdbId: '1022789',
      title: '头脑特工队2',
      category: LibraryTypes.anime,
    );
    bangumi.results['仙逆'] = [bangumi.hit('376703', '仙逆', year: 2023)];
    bangumi.details['376703'] = const ScrapedTitle(
      source: 'bangumi',
      bangumiId: '376703',
      title: '仙逆',
      category: LibraryTypes.anime,
    );

    await scraper.scrapePending();
    expect(bangumi.calls, ['show:仙逆:2023'], reason: 'the film was found on TMDB before Bangumi was asked');
    expect(tmdb.calls, ['movie:头脑特工队2:2024']);
    final shelves = {for (final row in await db.select(db.libraryItems).get()) row.title: row.libraryType};
    expect((shelves['头脑特工队2'], shelves['仙逆']), (LibraryTypes.anime, LibraryTypes.anime));
  });

  test('a show with several episodes is never turned into a movie', () async {
    driver.files
      ..add('/Films/Spirited Away 01.mkv')
      ..add('/Films/Spirited Away 02.mkv')
      ..add('/Films/Spirited Away 03.mkv');
    await scan();
    final show = (await items(LibraryKinds.show)).single;
    expect(await scraper.canChangeKind(show.id), isFalse);

    driver.files.add('/Films/Your Name.mkv');
    await scan();
    expect(await scraper.canChangeKind((await items(LibraryKinds.movie)).single.id), isTrue);
  });

  test('a show filed as a movie is turned into a show when only the show search hits', () async {
    driver.files.add('/Docs/Chernobyl.mkv');
    await scan();
    expect((await items(LibraryKinds.movie)).single.title, 'Chernobyl');
    tmdb.results['chernobyl'] = [tmdb.hit('87108', 'Chernobyl', year: 2019)];
    tmdb.details['87108'] = const ScrapedTitle(source: 'tmdb', tmdbId: '87108', title: '切尔诺贝利');
    // The fake answers both searches the same; make the movie search miss.
    tmdb.results.remove('chernobyl');
    final showOnly = _ShowOnly(tmdb, {'chernobyl': tmdb.hit('87108', 'Chernobyl', year: 2019)});
    scraper = LibraryScraper(db, repo, providers: [showOnly]);

    await scraper.scrapePending();
    expect(await items(LibraryKinds.movie), isEmpty);
    final show = (await items(LibraryKinds.show)).single;
    expect((show.title, show.libraryType), ('切尔诺贝利', LibraryTypes.show));
    final episode = (await repo.episodesOfShow(show.id)).single;
    expect((episode.item.seasonNumber, episode.item.episodeNumber), (1, 1));
    expect((await repo.versionsOf(episode.item.id)).single.path, '/Docs/Chernobyl.mkv');
  });

  test('unmatched titles can be found without saving watch state', () async {
    driver.files.add('/Movies/Home Video 2019.mkv');
    await scan();
    await scraper.scrapePending();
    final title = (await repo.pendingTitles()).single.item;
    expect(title.title, 'Home Video');
    for (final shelf in LibraryTypes.shelves) {
      expect((await repo.queryTitles(LibraryQuery(libraryType: shelf))).total, 0);
    }
    expect(
      (await repo.queryTitles(const LibraryQuery(libraryType: LibraryTypes.pending))).items.single.item.id,
      title.id,
    );
    expect((await repo.search('home')).single.item.id, title.id, reason: 'found by the name its file gives');
    expect(await repo.recentlyAdded(), isEmpty, reason: 'no row of blank posters on the home screen');

    await repo.setProgress(title.id, positionMs: 60000, durationMs: 3600000);
    expect(await repo.continueWatching(), isEmpty);
    expect(await db.select(db.workWatchStates).get(), isEmpty);
  });

  test('scan removal and re-scraping recover a matched movie progress on its new id', () async {
    const path = '/Movies/The.Wandering.Earth.II.2023.mkv';
    driver.files.add(path);
    final hit = tmdb.hit('842675', '流浪地球2', year: 2023, original: 'The Wandering Earth II');
    tmdb.results['the wandering earth ii'] = [hit];
    tmdb.details['842675'] = const ScrapedTitle(source: 'tmdb', tmdbId: '842675', title: '流浪地球2', year: 2023);
    await scan();
    await scraper.scrapePending();
    final old = (await items(LibraryKinds.movie)).single;
    await repo.setProgress(old.id, positionMs: 600000, durationMs: 7200000);
    driver.files.clear();
    await scan();
    expect(await items(LibraryKinds.movie), isEmpty);
    expect(await db.select(db.workWatchStates).get(), hasLength(1));
    driver.files.add(path);
    await scan();
    expect(await repo.continueWatching(), isEmpty, reason: 'wait for a confirmed scraped identity');
    await scraper.scrapePending();
    final restored = (await repo.continueWatching()).single;
    expect(restored.item.id, isNot(old.id));
    expect(restored.state!.positionMs, 600000);
    expect(restored.state!.durationMs, 7200000);
  });

  test('unmatched progress is ignored when titles are merged', () async {
    driver.files
      ..add('/A/流浪地球2 (2023).mkv')
      ..add('/B/The.Wandering.Earth.II.2023.2160p.mkv');
    await scan();
    final english = (await items(LibraryKinds.movie)).firstWhere((m) => m.title.startsWith('The'));
    await repo.setProgress(english.id, positionMs: 600000, durationMs: 7200000);

    final hit = tmdb.hit('842675', '流浪地球2', year: 2023, original: 'The Wandering Earth II');
    tmdb.results['流浪地球2'] = [hit];
    tmdb.results['the wandering earth ii'] = [hit];
    tmdb.details['842675'] = const ScrapedTitle(source: 'tmdb', tmdbId: '842675', title: '流浪地球2', year: 2023);
    await scraper.scrapePending();

    final movie = (await items(LibraryKinds.movie)).single;
    expect(movie.tmdbId, '842675');
    expect(await repo.continueWatching(), isEmpty);
  });

  test('unmatched progress is ignored when a movie turns into a show', () async {
    driver.files.add('/Docs/Chernobyl.mkv');
    await scan();
    final movie = (await items(LibraryKinds.movie)).single;
    await repo.setProgress(movie.id, positionMs: 120000, durationMs: 3600000);
    tmdb.details['87108'] = const ScrapedTitle(source: 'tmdb', tmdbId: '87108', title: '切尔诺贝利');
    scraper = LibraryScraper(
      db,
      repo,
      providers: [
        _ShowOnly(tmdb, {'chernobyl': tmdb.hit('87108', 'Chernobyl')}),
      ],
    );

    await scraper.scrapePending();
    final episode = (await repo.episodesOfShow(movie.id)).single;
    expect(episode.state, isNull);
    expect(await db.select(db.workWatchStates).get(), isEmpty);
  });

  test('NfoReader ignores documents that are not titles', () {
    expect(NfoReader.readTitle('not xml at all'), isNull);
    expect(NfoReader.readTitle('<episodedetails><title>x</title></episodedetails>'), isNull);
    final episode = NfoReader.readEpisode(
      '<episodedetails><title>Pilot</title><season>1</season><episode>1</episode><aired>2020-01-02</aired></episodedetails>',
    );
    expect((episode?.number, episode?.title, episode?.airDate), (1, 'Pilot', '2020-01-02'));
  });

  test('a configuration failure stops the run and keeps the queue', () async {
    driver.files
      ..add('/Movies/A (2020).mkv')
      ..add('/Movies/B (2021).mkv');
    await scan();
    tmdb.failWith = const ScrapeException('No TMDB API key is set', isConfiguration: true);

    final summary = await scraper.scrapePending();
    expect(summary.stoppedBy, 'No TMDB API key is set');
    expect(tmdb.calls.length, 1, reason: 'the second title is not attempted');
    expect(await repo.countVideosInState(LibraryMatchStates.unmatched), 0);

    tmdb.failWith = null;
    final retry = await scraper.scrapePending();
    expect(retry.unmatched, 2, reason: 'both titles were still queued');
  });

  test('a manual match is locked against rescans and automatic scraping', () async {
    driver.files.add('/Movies/Mystery File.mkv');
    await scan();
    await scraper.scrapePending();
    final movie = (await items(LibraryKinds.movie)).single;

    tmdb.details['11'] = const ScrapedTitle(source: 'tmdb', tmdbId: '11', title: 'Star Wars', year: 1977);
    await scraper.applyManualMatch(movie.id, tmdb.hit('11', 'Star Wars', year: 1977), asShow: false);

    final matched = (await items(LibraryKinds.movie)).single;
    expect((matched.title, matched.locked, matched.libraryType), ('Star Wars', true, LibraryTypes.movie));
    final file = (await repo.versionsOf(matched.id)).single;
    expect((file.matchState, file.matchLocked), (LibraryMatchStates.matched, true));

    await scan();
    await scraper.requeueUnmatched();
    await scraper.scrapePending();
    expect((await items(LibraryKinds.movie)).single.title, 'Star Wars');
  });

  test('a manual match can change the kind and pick the shelf', () async {
    driver.files.add('/Misc/Some Concert.mkv');
    await scan();
    final movie = (await items(LibraryKinds.movie)).single;
    tmdb.details['55'] = const ScrapedTitle(source: 'tmdb', tmdbId: '55', title: '某演唱会', category: LibraryTypes.show);

    await scraper.applyManualMatch(
      movie.id,
      tmdb.hit('55', 'Some Concert'),
      asShow: true,
      libraryType: LibraryTypes.variety,
    );
    final show = (await items(LibraryKinds.show)).single;
    expect((show.id, show.title, show.libraryType, show.locked), (movie.id, '某演唱会', LibraryTypes.variety, true));
    expect((await repo.episodesOfShow(show.id)).single.item.libraryType, LibraryTypes.variety);
  });
}

/// TMDB as it behaves for a miniseries: found as a show, not as a movie.
class _ShowOnly implements MetadataProvider {
  _ShowOnly(this._inner, this._shows);

  final _FakeProvider _inner;
  final Map<String, ScrapedCandidate> _shows;

  @override
  String get source => _inner.source;

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) async => const [];

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) async => [?_shows[title.toLowerCase()]];

  @override
  Future<ScrapedTitle> movie(String id) => _inner.movie(id);

  @override
  Future<ScrapedTitle> show(String id) => _inner.show(id);

  @override
  Future<ScrapedSeason?> season(String id, int number) => _inner.season(id, number);

  @override
  void close() {}
}
