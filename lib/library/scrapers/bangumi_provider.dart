import '../library_repository.dart';
import 'scraped_metadata.dart';
import 'scraper_http.dart';

/// Bangumi (bgm.tv), the anime database, through its public v0 API.
///
/// Bangumi lists every season of a series as its own subject, so [season]
/// only answers for the subject it is asked about: season 1 of the id it is
/// given. Later seasons are looked up as subjects of their own by the scraper.
class BangumiProvider implements MetadataProvider {
  BangumiProvider({String? apiBase, ScraperHttp? http})
    : _apiBase = Uri.parse((apiBase ?? defaultApiBase).replaceAll(RegExp(r'/+$'), '')),
      // Bangumi rejects requests without an identifying User-Agent.
      _http = http ?? ScraperHttp(userAgent: 'local-media-library/1.0 (anime metadata lookup)');

  static const String defaultApiBase = 'https://api.bgm.tv';
  static const int _animeType = 2;
  static const int _mainEpisodeType = 0;

  final Uri _apiBase;
  final ScraperHttp _http;

  @override
  String get source => 'bangumi';

  Uri _url(String path, [Map<String, String> query = const {}]) =>
      _apiBase.replace(path: '${_apiBase.path}$path', queryParameters: query.isEmpty ? null : query);

  Future<List<ScrapedCandidate>> _search(String title) async {
    final decoded = await _http.json(
      'POST',
      _url('/v0/search/subjects', {'limit': '10'}),
      body: {
        'keyword': title,
        'filter': {
          'type': [_animeType],
        },
      },
      service: 'Bangumi',
    );
    final rows = decoded is Map ? decoded.objs('data') : const <Map<dynamic, dynamic>>[];
    return [
      for (final row in rows)
        if (row.str('id') != null)
          ScrapedCandidate(
            source: source,
            id: row.str('id')!,
            // name_cn is the Chinese title; name is the original.
            title: row.str('name_cn') ?? row.str('name') ?? '',
            originalTitle: row.str('name'),
            year: yearOfDate(row.str('date')),
            summary: row.str('summary'),
            posterUrl: row.obj('images')?.str('common'),
          ),
    ];
  }

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) => _search(title);

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) => _search(title);

  Future<ScrapedTitle> _subject(String id) async {
    final decoded = await _http.json('GET', _url('/v0/subjects/$id'), service: 'Bangumi');
    if (decoded is! Map) throw ScrapeException('Bangumi has no subject $id');
    final images = decoded.obj('images');
    final score = decoded.obj('rating')?.number('score');
    return ScrapedTitle(
      source: source,
      category: LibraryTypes.anime,
      bangumiId: decoded.str('id') ?? id,
      title: decoded.str('name_cn') ?? decoded.str('name') ?? '',
      originalTitle: decoded.str('name'),
      aliases: _aliases(decoded),
      year: yearOfDate(decoded.str('date')),
      releaseDate: decoded.str('date'),
      summary: decoded.str('summary'),
      rating: score == null || score <= 0 ? null : score,
      genres: [
        // Tags are user-made and noisy; the few most-used ones read as genres.
        for (final tag in decoded.objs('tags').take(6)) ?tag.str('name'),
      ],
      posterSource: images?.str('large') ?? images?.str('common'),
    );
  }

  static List<String> _aliases(Map<dynamic, dynamic> subject) {
    final names = <String>[];
    for (final box in subject.objs('infobox')) {
      if (box.str('key') != '别名') continue;
      final value = box['value'];
      if (value is String) {
        names.add(value);
      } else if (value is List) {
        names.addAll(value.whereType<Map<dynamic, dynamic>>().map((v) => v.str('v')).whereType<String>());
      }
    }
    return names;
  }

  @override
  Future<ScrapedTitle> movie(String id) => _subject(id);

  @override
  Future<ScrapedTitle> show(String id) => _subject(id);

  @override
  Future<ScrapedSeason?> season(String id, int number) async {
    if (number != 1) return null;
    final episodes = <ScrapedEpisode>[];
    const pageSize = 100;
    for (var offset = 0; ; offset += pageSize) {
      final decoded = await _http.json(
        'GET',
        _url('/v0/episodes', {
          'subject_id': id,
          'type': '$_mainEpisodeType',
          'limit': '$pageSize',
          'offset': '$offset',
        }),
        service: 'Bangumi',
      );
      final rows = decoded is Map ? decoded.objs('data') : const <Map<dynamic, dynamic>>[];
      for (final row in rows) {
        // "ep" restarts per subject; "sort" may continue from earlier seasons.
        final number = row.integer('ep') ?? row.number('sort')?.round();
        if (number == null || number <= 0) continue;
        episodes.add(
          ScrapedEpisode(
            number: number,
            title: row.str('name_cn') ?? row.str('name'),
            summary: row.str('desc'),
            airDate: row.str('airdate'),
          ),
        );
      }
      if (rows.length < pageSize) break;
    }
    return ScrapedSeason(number: 1, episodes: episodes);
  }

  @override
  void close() => _http.close();
}
