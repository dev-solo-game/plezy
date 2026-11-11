import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/library/media_name_parser.dart';

/// Expected fields for one file name. Only the keys given are checked, plus
/// the numbering keys, which must be absent when not listed — a stray season
/// or episode is how a movie ends up shelved as a show.
typedef _Case = ({String name, Map<String, Object?> expect});

void main() {
  void check(List<_Case> cases) {
    for (final c in cases) {
      test(c.name, () {
        final json = MediaNameParser.parseFile(c.name).toJson();
        for (final entry in c.expect.entries) {
          expect(json[entry.key], entry.value, reason: '${entry.key} of "${c.name}" (parsed $json)');
        }
        for (final key in const ['season', 'episode', 'episodeEnd', 'looseEpisode', 'isSpecial', 'year']) {
          if (!c.expect.containsKey(key)) {
            expect(json[key], isNull, reason: 'unexpected $key in "${c.name}" (parsed $json)');
          }
        }
      });
    }
  }

  group('movies', () {
    check([
      (
        name: 'The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv',
        expect: {
          'title': 'The Matrix',
          'year': 1999,
          'resolution': '1080p',
          'source': 'BluRay',
          'videoCodec': 'H.264',
          'releaseGroup': 'GROUP',
        },
      ),
      (
        name: 'Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv',
        expect: {
          'title': 'Dune Part Two',
          'year': 2024,
          'resolution': '2160p',
          'source': 'WEB-DL',
          'videoCodec': 'HEVC',
          'hdr': 'Dolby Vision',
        },
      ),
      (name: 'Inception (2010).mp4', expect: {'title': 'Inception', 'year': 2010}),
      (name: 'Blade Runner 2049 (2017) [1080p].mkv', expect: {'title': 'Blade Runner 2049', 'year': 2017}),
      (name: '2001.A.Space.Odyssey.1968.720p.BluRay.mkv', expect: {'title': '2001 A Space Odyssey', 'year': 1968}),
      (name: '1917.2019.1080p.BluRay.x265.mkv', expect: {'title': '1917', 'year': 2019, 'videoCodec': 'HEVC'}),
      (name: '2012.mkv', expect: {'title': '2012'}),
      (
        name: 'Alien.1979.Directors.Cut.1080p.mkv',
        expect: {'title': 'Alien', 'year': 1979, 'edition': "Director's Cut"},
      ),
      (
        name: 'Oppenheimer.2023.IMAX.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.5.1.mkv',
        expect: {'title': 'Oppenheimer', 'year': 2023, 'edition': 'IMAX', 'resolution': '2160p'},
      ),
      (name: 'Toy Story 3.mkv', expect: {'title': 'Toy Story 3'}),
      (name: 'Movie.Title.4K.mkv', expect: {'title': 'Movie Title', 'resolution': '2160p'}),
      (name: 'Some.Film.1920x1080.mkv', expect: {'title': 'Some Film', 'resolution': '1080p'}),
    ]);
  });

  group('Chinese naming', () {
    check([
      (name: '流浪地球2 (2023).mkv', expect: {'title': '流浪地球2', 'year': 2023}),
      (name: '流浪地球2.2023.2160p.WEB-DL.H265.国语中字.mkv', expect: {'title': '流浪地球2', 'year': 2023, 'resolution': '2160p'}),
      (name: '让子弹飞.2010.蓝光原盘.1080p.mkv', expect: {'title': '让子弹飞', 'year': 2010}),
      (name: '霸王别姬 1993 导演剪辑版 1080p.mkv', expect: {'title': '霸王别姬', 'year': 1993, 'edition': '导演剪辑版'}),
      (name: '庆余年.第二季.第03集.2024.2160p.mp4', expect: {'title': '庆余年', 'season': 2, 'episode': 3}),
      (name: '庆余年 第二季 EP03.mp4', expect: {'title': '庆余年', 'season': 2, 'episode': 3}),
      (name: '繁花.第十二集.mp4', expect: {'title': '繁花', 'episode': 12}),
      (name: '第01集.mp4', expect: {'title': null, 'episode': 1}),
      (name: '三体 第1季 第30集.mkv', expect: {'title': '三体', 'season': 1, 'episode': 30}),
      (name: '漫长的季节.S01E05.1080p.WEB-DL.mkv', expect: {'title': '漫长的季节', 'season': 1, 'episode': 5}),
      (name: '１９２２.第０３集.mkv', expect: {'title': '1922', 'episode': 3}),
      (name: '奔跑吧 第二十期.mp4', expect: {'title': '奔跑吧', 'episode': 20}),
    ]);
  });

  group('series', () {
    check([
      (
        name: 'Breaking.Bad.S01E02.Cat\'s.in.the.Bag.1080p.BluRay.x264-DEMAND.mkv',
        expect: {'title': 'Breaking Bad', 'season': 1, 'episode': 2, 'releaseGroup': 'DEMAND'},
      ),
      (name: 'The Expanse - S03E06 - Immolation.mkv', expect: {'title': 'The Expanse', 'season': 3, 'episode': 6}),
      (
        name: 'show.name.s01e01e02.720p.mkv',
        expect: {'title': 'show name', 'season': 1, 'episode': 1, 'episodeEnd': 2},
      ),
      (name: 'Show Name S01E03-E04.mkv', expect: {'title': 'Show Name', 'season': 1, 'episode': 3, 'episodeEnd': 4}),
      (name: 'Friends 2x05 The One.avi', expect: {'title': 'Friends', 'season': 2, 'episode': 5}),
      (
        name: 'Chernobyl.2019.S01E01.2160p.mkv',
        expect: {'title': 'Chernobyl', 'year': 2019, 'season': 1, 'episode': 1},
      ),
      (name: 'S01E07.mkv', expect: {'title': null, 'season': 1, 'episode': 7}),
      (name: 'Planet Earth Episode 4.mkv', expect: {'title': 'Planet Earth', 'episode': 4}),
      (name: 'EP12.mp4', expect: {'title': null, 'episode': 12}),
      (name: 'The.Office.Season.2.Complete.1080p', expect: {'title': 'The Office', 'season': 2}),
      (name: '03.mkv', expect: {'title': null, 'looseEpisode': 3}),
    ]);
  });

  group('anime', () {
    check([
      (
        name: '[SubsPlease] Sousou no Frieren - 01 (1080p) [ABCD1234].mkv',
        expect: {
          'title': 'Sousou no Frieren',
          'looseEpisode': 1,
          'resolution': '1080p',
          'releaseGroup': 'SubsPlease',
          'fansubStyle': true,
        },
      ),
      (
        name: '[Erai-raws] Jujutsu Kaisen 2nd Season - 23 [1080p][HEVC].mkv',
        expect: {'title': 'Jujutsu Kaisen 2nd Season', 'looseEpisode': 23, 'videoCodec': 'HEVC'},
      ),
      (
        name: '[桜都字幕组][葬送的芙莉莲][05][1080p][简体内嵌].mp4',
        expect: {'title': '葬送的芙莉莲', 'looseEpisode': 5, 'releaseGroup': '桜都字幕组', 'fansubStyle': true},
      ),
      (name: '【喵萌奶茶屋】★01月新番★[迷宫饭][12][1080p][简日双语].mkv', expect: {'looseEpisode': 12, 'releaseGroup': '喵萌奶茶屋'}),
      (
        name: '[VCB-Studio] Fate Zero [13][Ma10p_1080p][x265_flac].mkv',
        expect: {'title': 'Fate Zero', 'looseEpisode': 13},
      ),
      (name: '[Group] Title - 07v2 [720p].mkv', expect: {'title': 'Title', 'looseEpisode': 7}),
      (name: '[Group] Show S2 - 04 [1080p].mkv', expect: {'title': 'Show', 'season': 2, 'looseEpisode': 4}),
      (name: '[Group] Show - OVA 2 [1080p].mkv', expect: {'title': 'Show', 'isSpecial': true, 'episode': 2}),
      (name: '[Group] Show - SP01 [BD 1080p].mkv', expect: {'title': 'Show', 'isSpecial': true, 'episode': 1}),
      (name: '[Group] Kimi no Na wa. (2016) [BD 1080p].mkv', expect: {'title': 'Kimi no Na wa', 'year': 2016}),
      (name: '名侦探柯南 - 1100.mp4', expect: {'title': '名侦探柯南', 'looseEpisode': 1100}),
      (name: '[Group] 某作品 劇場版 [1080p].mkv', expect: {'title': '某作品'}),
    ]);
  });

  group('folders', () {
    test('season folders', () {
      for (final (name, season) in [
        ('Season 1', 1),
        ('season02', 2),
        ('S03', 3),
        ('第二季', 2),
        ('第 10 季', 10),
        ('Specials', 0),
        ('SP', 0),
      ]) {
        final folder = MediaNameParser.parseFolder(name);
        expect(folder.isSeasonFolder, isTrue, reason: name);
        expect(folder.season, season, reason: name);
        expect(folder.title, isNull, reason: name);
      }
    });

    test('title folders', () {
      var folder = MediaNameParser.parseFolder('The Matrix (1999)');
      expect((folder.title, folder.year, folder.isSeasonFolder), ('The Matrix', 1999, false));

      folder = MediaNameParser.parseFolder('庆余年 第二季');
      expect((folder.title, folder.season, folder.isSeasonFolder), ('庆余年', 2, false));

      folder = MediaNameParser.parseFolder('Breaking.Bad.S01.1080p.BluRay.x264');
      expect((folder.title, folder.season), ('Breaking Bad', 1));

      folder = MediaNameParser.parseFolder('[桜都字幕组] 葬送的芙莉莲 [1080p]');
      expect(folder.title, '葬送的芙莉莲');
    });
  });

  group('organised names (title (year) / Season N / title - S01E01)', () {
    test('film files keep their whole title and year', () {
      final a = MediaNameParser.parseFile('仙逆剧场版：弑仙之战 (2026) - 1080p.mkv');
      expect((a.title, a.year, a.resolution), ('仙逆剧场版:弑仙之战', 2026, '1080p'));
      final b = MediaNameParser.parseFile('三国的星空第一部 (2025) - 1080p.mkv');
      expect((b.title, b.year, b.season, b.episode), ('三国的星空第一部', 2025, null, null));
      final c = MediaNameParser.parseFile('F1：狂飙飞车 (2025) - 4k.mp4');
      expect((c.title, c.year), ('F1:狂飙飞车', 2025));
      final d = MediaNameParser.parseFile('V (2026) - 1080p.mkv');
      expect((d.title, d.year), ('V', 2026));
      final e = MediaNameParser.parseFile('罗小黑战记 2 (2025)-part2 - 2160p.mp4');
      expect((e.title, e.year, e.resolution), ('罗小黑战记 2', 2025, '2160p'));
      final f = MediaNameParser.parseFile('你行！你上！ (2025).mkv');
      expect((f.title, f.year), ('你行！你上！', 2025));
    });

    test('film folders read the same way', () {
      final folder = MediaNameParser.parseFolder('仙逆剧场版：神临之战 (2025)');
      expect((folder.title, folder.year), ('仙逆剧场版:神临之战', 2025));
    });

    test('episode files give title, season and episode', () {
      final a = MediaNameParser.parseFile('一瓯春 - S01E01 - 第 1 集.mkv');
      expect((a.title, a.season, a.episode, a.year), ('一瓯春', 1, 1, null));
      final b = MediaNameParser.parseFile('乘风破浪的姐姐 - S07E12 - 第 12 集.mkv');
      expect((b.title, b.season, b.episode), ('乘风破浪的姐姐', 7, 12));
      final c = MediaNameParser.parseFile('繁花 - S01E01-E02 - 第 1 集.mkv');
      expect((c.episode, c.episodeEnd), (1, 2));
      final d = MediaNameParser.parseFile('仙逆 - S00E03.mkv');
      expect((d.season, d.episode, d.isSpecial), (0, 3, true));
    });

    test('a loosely numbered episode after a year is still an episode', () {
      final a = MediaNameParser.parseFile('Some Show (2019) - 05.mkv');
      expect(a.looseEpisode ?? a.episode, 5);
    });
  });
}
