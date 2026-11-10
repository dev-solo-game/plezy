import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/storage/storage_path.dart';

/// An in-memory mount: a set of file paths with sizes.
class _TreeDriver implements StorageDriver {
  final Map<String, int> files = {};
  final List<String> listed = [];
  String? failAt;
  StorageErrorKind failKind = StorageErrorKind.network;

  void add(String path, {int size = 1000}) => files[StoragePath.normalize(path)] = size;

  @override
  StorageKind get kind => StorageKind.local;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final directory = StoragePath.normalize(path);
    listed.add(directory);
    if (directory == failAt) throw StorageException(failKind, 'boom at $directory');
    final depth = StoragePath.segments(directory).length;
    final seen = <String, StorageEntry>{};
    for (final entry in files.entries) {
      final segments = StoragePath.segments(entry.key);
      if (segments.length <= depth) continue;
      final prefix = depth == 0 ? '' : '/${segments.sublist(0, depth).join('/')}';
      if (depth > 0 && prefix != directory) continue;
      final name = segments[depth];
      final childPath = '$prefix/$name';
      final isFile = segments.length == depth + 1;
      seen.putIfAbsent(
        childPath,
        () => StorageEntry(
          path: childPath,
          name: name,
          isDirectory: !isFile,
          size: isFile ? entry.value : null,
          modifiedAt: isFile ? DateTime.fromMillisecondsSinceEpoch(1) : null,
        ),
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

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late LibraryScanner scanner;
  late _TreeDriver driver;

  StorageMount mount([MountLibraryType type = MountLibraryType.auto]) =>
      StorageMount(id: 'm1', kind: StorageKind.local, displayName: 'Disk', libraryType: type);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    scanner = LibraryScanner(db, repo);
    driver = _TreeDriver();
    await db
        .into(db.mounts)
        .insert(MountsCompanion.insert(id: 'm1', kind: 'local', displayName: 'Disk', configJson: '{}', createdAt: 0));
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<LibraryItemRow>> items(String kind) async =>
      (await db.select(db.libraryItems).get()).where((i) => i.kind == kind).toList();

  Future<LibraryFileRow> fileAt(String path) async =>
      (await db.select(db.libraryFiles).get()).firstWhere((f) => f.path == path);

  group('auto classification', () {
    test('files movies, shows and anime on their shelves', () async {
      driver
        ..add('/Movies/The Matrix (1999)/The.Matrix.1999.1080p.BluRay.x264.mkv')
        ..add('/Movies/流浪地球2 (2023).mkv')
        ..add('/TV/Breaking Bad/Season 1/Breaking.Bad.S01E01.720p.mkv')
        ..add('/TV/Breaking Bad/Season 1/Breaking.Bad.S01E02.720p.mkv')
        ..add('/TV/庆余年/第二季/第01集.mp4')
        ..add('/TV/庆余年/第二季/第02集.mp4')
        ..add('/Anime/[SubsPlease] Sousou no Frieren - 01 (1080p) [ABCD1234].mkv')
        ..add('/Anime/[SubsPlease] Sousou no Frieren - 02 (1080p) [ABCD1235].mkv');

      final result = await scanner.scan(mount(), driver);
      expect(result.videos, 8);
      expect(result.cancelled, isFalse);

      final movies = await items(LibraryKinds.movie);
      expect(movies.map((m) => '${m.title}|${m.year}|${m.libraryType}').toSet(), {
        'The Matrix|1999|movie',
        '流浪地球2|2023|movie',
      });

      final shows = await items(LibraryKinds.show);
      expect(shows.map((s) => '${s.title}|${s.libraryType}').toSet(), {
        'Breaking Bad|show',
        '庆余年|show',
        'Sousou no Frieren|anime',
      });

      final qyn = shows.firstWhere((s) => s.title == '庆余年');
      final seasons = await repo.children(qyn.id);
      expect(seasons.single.item.seasonNumber, 2, reason: 'the season comes from the folder');
      final episodes = await repo.children(seasons.single.item.id);
      expect(episodes.map((e) => e.item.episodeNumber), [1, 2]);

      final frieren = shows.firstWhere((s) => s.title == 'Sousou no Frieren');
      expect((await repo.episodesOfShow(frieren.id)).map((e) => e.item.episodeNumber), [1, 2]);
    });

    test('bare numbers are episodes only when the folder agrees', () async {
      driver
        ..add('/Mixed/Some Show/01.mkv')
        ..add('/Mixed/Some Show/02.mkv')
        ..add('/Mixed/Some Show/03.mkv')
        ..add('/Mixed/Toy Story 3.mkv');
      await scanner.scan(mount(), driver);

      expect((await items(LibraryKinds.show)).single.title, 'Some Show');
      expect((await items(LibraryKinds.episode)).length, 3);
      expect((await items(LibraryKinds.movie)).single.title, 'Toy Story 3');
    });

    test('a video with no readable name goes to unmatched', () async {
      driver.add('/01.mkv');
      await scanner.scan(mount(), driver);
      final file = await fileAt('/01.mkv');
      expect(file.itemId, isNull);
      expect(file.matchState, LibraryMatchStates.unmatched);
      expect((await repo.mountSummary('m1')), (videos: 1, unidentified: 1));
    });
  });

  group('fixed mount types', () {
    test('a movie mount never guesses episodes', () async {
      driver
        ..add('/Show.S01E01.mkv')
        ..add('/Show.S01E02.mkv')
        ..add('/Show.S01E03.mkv');
      await scanner.scan(mount(MountLibraryType.movie), driver);
      expect(await items(LibraryKinds.show), isEmpty);
      // One "movie" with three files: same parsed title.
      expect((await items(LibraryKinds.movie)).single.title, 'Show');
    });

    test('a show mount treats loose numbers as episodes and shelves nothing as a movie', () async {
      driver
        ..add('/Planet Earth/Planet Earth 01.mkv')
        ..add('/Planet Earth/Behind.mkv');
      await scanner.scan(mount(MountLibraryType.show), driver);
      expect((await items(LibraryKinds.show)).single.title, 'Planet Earth');
      expect((await items(LibraryKinds.episode)).single.episodeNumber, 1);
      expect(await items(LibraryKinds.movie), isEmpty);
      expect((await fileAt('/Planet Earth/Behind.mkv')).matchState, LibraryMatchStates.unmatched);
    });

    test('an anime mount shelves everything as anime, specials in season 0', () async {
      driver
        ..add('/Frieren/Frieren - 01.mkv')
        ..add('/Frieren/Frieren - OVA 1.mkv');
      await scanner.scan(mount(MountLibraryType.anime), driver);
      final show = (await items(LibraryKinds.show)).single;
      expect(show.libraryType, 'anime');
      expect((await repo.children(show.id)).map((s) => s.item.seasonNumber), [0, 1]);
    });

    test('changing the mount type re-files what the user has not locked', () async {
      driver
        ..add('/Show.S01E01.mkv')
        ..add('/Locked.S01E01.mkv');
      await scanner.scan(mount(MountLibraryType.movie), driver);
      final locked = await fileAt('/Locked.S01E01.mkv');
      await repo.assignFile(locked.id, locked.itemId!, locked: true);

      await scanner.scan(mount(MountLibraryType.show), driver);
      expect((await items(LibraryKinds.show)).single.title, 'Show');
      expect((await items(LibraryKinds.movie)).map((m) => m.title), [
        'Locked',
      ], reason: 'the emptied movie is pruned; the locked match stays');
    });
  });

  group('versions, subtitles and extras', () {
    test('two files of one film become versions of one title', () async {
      driver
        ..add('/Dune (2021)/Dune.2021.1080p.BluRay.mkv', size: 10)
        ..add('/Dune (2021)/Dune.2021.2160p.UHD.BluRay.Extended.mkv', size: 50);
      await scanner.scan(mount(), driver);

      final movie = (await items(LibraryKinds.movie)).single;
      final versions = await repo.versionsOf(movie.id);
      expect(versions.map((v) => v.versionLabel), ['2160p · Extended', '1080p']);
    });

    test('subtitles attach to their video with a language', () async {
      driver
        ..add('/Films/A.2020.mkv')
        ..add('/Films/A.2020.chs.srt')
        ..add('/Films/A.2020.zh-TW.ass')
        ..add('/Films/A.2020.Extended.mkv')
        ..add('/Films/A.2020.Extended.en.srt')
        ..add('/Films/orphan.srt');
      await scanner.scan(mount(), driver);

      final plain = await fileAt('/Films/A.2020.mkv');
      final extended = await fileAt('/Films/A.2020.Extended.mkv');
      expect((await repo.subtitlesOf(plain.id)).map((s) => s.language), ['zh-Hans', 'zh-Hant']);
      expect((await repo.subtitlesOf(extended.id)).single.language, 'en');
      expect((await db.select(db.libraryFiles).get()).any((f) => f.path == '/Films/orphan.srt'), isFalse);
    });

    test('samples, extras folders and disc structures are skipped; nfo and art are kept', () async {
      driver
        ..add('/Film (2020)/Film.2020.mkv')
        ..add('/Film (2020)/Film.2020-sample.mkv')
        ..add('/Film (2020)/Extras/Making Of.mkv')
        ..add('/Film (2020)/movie.nfo')
        ..add('/Film (2020)/poster.jpg')
        ..add('/Disc/BDMV/STREAM/00001.m2ts')
        ..add('/.hidden/secret.mkv');
      await scanner.scan(mount(), driver);

      final files = await db.select(db.libraryFiles).get();
      expect(files.where((f) => f.role == LibraryFileRoles.video).map((f) => f.path), ['/Film (2020)/Film.2020.mkv']);
      expect(files.where((f) => f.role != LibraryFileRoles.video).map((f) => f.role).toSet(), {
        LibraryFileRoles.nfo,
        LibraryFileRoles.artwork,
      });
      expect(driver.listed, isNot(contains('/Disc/BDMV')));
      expect(driver.listed, isNot(contains('/.hidden')));
    });
  });

  group('incremental and resumable', () {
    test('a rescan keeps ids and matches, and drops what is gone', () async {
      driver
        ..add('/A (2020).mkv')
        ..add('/B (2021).mkv');
      await scanner.scan(mount(), driver);
      final a = await fileAt('/A (2020).mkv');
      await repo.assignFile(a.id, a.itemId!);

      driver.files.remove('/B (2021).mkv');
      driver.add('/C (2022).mkv');
      final result = await scanner.scan(mount(), driver);

      expect(result.removed, 1);
      final again = await fileAt('/A (2020).mkv');
      expect(again.id, a.id);
      expect(again.matchState, LibraryMatchStates.matched, reason: 'an unchanged file keeps its match');
      expect((await items(LibraryKinds.movie)).map((m) => m.title).toSet(), {'A', 'C'});
    });

    test('a cancelled scan resumes without relisting finished directories', () async {
      driver
        ..add('/One/A (2020).mkv')
        ..add('/Two/B (2021).mkv')
        ..add('/Three/C (2022).mkv');
      final token = ScanCancelToken();
      final first = await scanner.scan(
        mount(),
        driver,
        cancel: token,
        // Progress is reported as a directory starts: stop while the first
        // folder after the root is being read, so it is the last one done.
        onProgress: (p) {
          if (p.directoriesDone == 1) token.cancel();
        },
      );
      expect(first.cancelled, isTrue);
      expect((await items(LibraryKinds.movie)).length, 1);
      final state = await db.select(db.libraryScanStates).getSingle();
      expect(state.status, 'running');
      expect((jsonDecode(state.pending!) as List).length, 2);

      final listedBefore = driver.listed.length;
      final second = await scanner.scan(mount(), driver);
      expect(second.cancelled, isFalse);
      expect(second.removed, 0, reason: 'files stamped before the cancel still count as seen');
      expect(driver.listed.length - listedBefore, 2, reason: 'only the two unvisited folders are listed');
      expect((await items(LibraryKinds.movie)).length, 3);
      expect((await db.select(db.libraryScanStates).getSingle()).status, 'idle');
    });

    test('a failed listing keeps the library intact and resumes later', () async {
      driver
        ..add('/One/A (2020).mkv')
        ..add('/Two/B (2021).mkv');
      await scanner.scan(mount(), driver);

      driver.failAt = '/Two';
      await expectLater(scanner.scan(mount(), driver), throwsA(isA<StorageException>()));
      final state = await db.select(db.libraryScanStates).getSingle();
      expect(state.status, 'failed');
      expect(state.lastError, contains('boom'));
      expect((await items(LibraryKinds.movie)).length, 2, reason: 'nothing is removed by a scan that did not finish');

      driver.failAt = null;
      final resumed = await scanner.scan(mount(), driver);
      expect(resumed.removed, 0);
      expect((await db.select(db.libraryScanStates).getSingle()).lastError, isNull);
    });

    test('a folder that vanished mid-scan is skipped', () async {
      driver
        ..add('/One/A (2020).mkv')
        ..add('/Two/B (2021).mkv')
        ..failAt = '/Two'
        ..failKind = StorageErrorKind.notFound;
      final result = await scanner.scan(mount(), driver);
      expect(result.cancelled, isFalse);
      expect((await items(LibraryKinds.movie)).single.title, 'A');
    });
  });
}
