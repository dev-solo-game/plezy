import '../library_repository.dart';
import 'scraped_metadata.dart';
import 'scraper_http.dart';

/// The Movie Database, API v3.
///
/// [apiBase] and [imageBase] are configurable because the official hosts are
/// unreachable on some networks and users point them at a mirror.
class TmdbProvider implements MetadataProvider {
  TmdbProvider({required String apiKey, this.language = 'zh-CN', String? apiBase, String? imageBase, ScraperHttp? http})
    : _apiKey = apiKey.trim(),
      _apiBase = Uri.parse(normalizeBase(apiBase, defaultApiBase, defaultPath: '/3')),
      _imageBase = normalizeBase(imageBase, defaultImageBase, defaultPath: '/t/p'),
      _http = http ?? ScraperHttp();

  /// TMDB's own short API host; it answers like api.themoviedb.org and is
  /// reachable from more networks.
  static const String defaultApiHost = 'api.tmdb.org';
  static const String defaultImageHost = 'image.tmdb.org';
  static const String defaultApiBase = 'https://$defaultApiHost/3';
  static const String defaultImageBase = 'https://$defaultImageHost/t/p';

  final String _apiKey;
  final String language;
  final Uri _apiBase;
  final String _imageBase;
  final ScraperHttp _http;

  /// A base address as people type it, made usable: `https://` when no
  /// scheme is given, and [defaultPath] when only a host is given — the
  /// official hosts and most mirrors serve the API under `/3` and images
  /// under `/t/p`. An address with its own path is taken as it is.
  static String normalizeBase(String? value, String fallback, {required String defaultPath}) {
    var text = value?.trim() ?? '';
    if (text.isEmpty) return fallback;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) text = 'https://$text';
    text = text.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return fallback;
    return uri.path.isEmpty ? '$text$defaultPath' : text;
  }

  @override
  String get source => 'tmdb';

  /// v4 "read access tokens" are JWTs and go in a header; v3 keys go in the
  /// query string.
  bool get _usesBearer => _apiKey.startsWith('eyJ');

  Future<Map<dynamic, dynamic>?> _get(String path, [Map<String, String> query = const {}]) async {
    if (_apiKey.isEmpty) throw const ScrapeException('No TMDB API key is set', isConfiguration: true);
    final url = _apiBase.replace(
      path: '${_apiBase.path}$path',
      queryParameters: {if (!_usesBearer) 'api_key': _apiKey, 'language': language, ...query},
    );
    final decoded = await _http.json(
      'GET',
      url,
      headers: {if (_usesBearer) 'Authorization': 'Bearer $_apiKey'},
      service: 'TMDB',
    );
    return decoded is Map ? decoded : null;
  }

  /// Search answers 200 even when nothing matches, so a 404 means the API
  /// address is wrong — not that the title is unknown.
  ScrapeException _wrongAddress() =>
      ScrapeException('TMDB API not found at $_apiBase (check the API address)', isConfiguration: true);

  /// Checks the address, proxy and key with one cheap request.
  Future<void> checkConnection() async {
    if (await _get('/configuration') == null) throw _wrongAddress();
  }

  String? _image(String? path, String size) => path == null || path.isEmpty ? null : '$_imageBase/$size$path';

  // ─── Search ────────────────────────────────────────────────────────────

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) async {
    final json = await _get('/search/movie', {
      'query': title,
      'include_adult': 'false',
      if (year != null) 'year': '$year',
    });
    if (json == null) throw _wrongAddress();
    return [
      for (final row in json.objs('results'))
        if (row.str('id') != null && row.str('title') != null)
          ScrapedCandidate(
            source: source,
            id: row.str('id')!,
            title: row.str('title')!,
            originalTitle: row.str('original_title'),
            year: yearOfDate(row.str('release_date')),
            summary: row.str('overview'),
            posterUrl: _image(row.str('poster_path'), 'w342'),
          ),
    ];
  }

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) async {
    final json = await _get('/search/tv', {
      'query': title,
      'include_adult': 'false',
      if (year != null) 'first_air_date_year': '$year',
    });
    if (json == null) throw _wrongAddress();
    return [
      for (final row in json.objs('results'))
        if (row.str('id') != null && row.str('name') != null)
          ScrapedCandidate(
            source: source,
            id: row.str('id')!,
            title: row.str('name')!,
            originalTitle: row.str('original_name'),
            year: yearOfDate(row.str('first_air_date')),
            summary: row.str('overview'),
            posterUrl: _image(row.str('poster_path'), 'w342'),
          ),
    ];
  }

  // ─── Details ───────────────────────────────────────────────────────────

  @override
  Future<ScrapedTitle> movie(String id) async {
    final json = await _get('/movie/$id', {
      'append_to_response': 'credits,release_dates,alternative_titles,images',
      'include_image_language': '${language.split('-').first},en,null',
    });
    if (json == null) throw ScrapeException('TMDB has no movie $id');
    final collection = json.obj('belongs_to_collection');
    final runtime = json.integer('runtime');
    return ScrapedTitle(
      source: source,
      tmdbId: json.str('id') ?? id,
      imdbId: json.str('imdb_id'),
      title: json.str('title') ?? json.str('original_title') ?? '',
      originalTitle: json.str('original_title'),
      aliases: _aliases(json.obj('alternative_titles')?.objs('titles'), 'title'),
      year: yearOfDate(json.str('release_date')),
      releaseDate: json.str('release_date'),
      summary: json.str('overview'),
      tagline: json.str('tagline'),
      rating: _rating(json),
      runtimeMs: runtime == null || runtime <= 0 ? null : runtime * 60000,
      contentRating: _movieCertification(json.obj('release_dates')),
      studio: json.objs('production_companies').firstOrNull?.str('name'),
      genres: [for (final g in json.objs('genres')) ?g.str('name')],
      posterSource: _image(json.str('poster_path'), 'w780'),
      backdropSource: _image(json.str('backdrop_path'), 'w1280'),
      logoSource: _logo(json.obj('images')),
      credits: _credits(json.obj('credits')),
      collectionId: collection?.str('id'),
      collectionTitle: collection?.str('name'),
      category: _category(json, isShow: false),
    );
  }

  @override
  Future<ScrapedTitle> show(String id) async {
    final json = await _get('/tv/$id', {
      'append_to_response': 'credits,content_ratings,external_ids,alternative_titles,images',
      'include_image_language': '${language.split('-').first},en,null',
    });
    if (json == null) throw ScrapeException('TMDB has no show $id');
    final external = json.obj('external_ids');
    final runtime = (json['episode_run_time'] is List ? json['episode_run_time'] as List : const [])
        .whereType<num>()
        .firstOrNull;
    return ScrapedTitle(
      source: source,
      tmdbId: json.str('id') ?? id,
      imdbId: external?.str('imdb_id'),
      tvdbId: external?.str('tvdb_id'),
      title: json.str('name') ?? json.str('original_name') ?? '',
      originalTitle: json.str('original_name'),
      aliases: _aliases(json.obj('alternative_titles')?.objs('results'), 'title'),
      year: yearOfDate(json.str('first_air_date')),
      releaseDate: json.str('first_air_date'),
      summary: json.str('overview'),
      tagline: json.str('tagline'),
      rating: _rating(json),
      runtimeMs: runtime == null || runtime <= 0 ? null : runtime.toInt() * 60000,
      contentRating: _showRating(json.obj('content_ratings')),
      studio: json.objs('networks').firstOrNull?.str('name'),
      genres: [for (final g in json.objs('genres')) ?g.str('name')],
      posterSource: _image(json.str('poster_path'), 'w780'),
      backdropSource: _image(json.str('backdrop_path'), 'w1280'),
      logoSource: _logo(json.obj('images')),
      credits: _credits(json.obj('credits'), creators: json.objs('created_by')),
      category: _category(json, isShow: true),
    );
  }

  @override
  Future<ScrapedSeason?> season(String id, int number) async {
    final json = await _get('/tv/$id/season/$number');
    if (json == null) return null;
    return ScrapedSeason(
      number: number,
      title: json.str('name'),
      summary: json.str('overview'),
      posterSource: _image(json.str('poster_path'), 'w780'),
      episodes: [
        for (final row in json.objs('episodes'))
          if (row.integer('episode_number') != null)
            ScrapedEpisode(
              number: row.integer('episode_number')!,
              title: row.str('name'),
              summary: row.str('overview'),
              airDate: row.str('air_date'),
              runtimeMs: (row.integer('runtime') ?? 0) > 0 ? row.integer('runtime')! * 60000 : null,
              stillSource: _image(row.str('still_path'), 'w780'),
              rating: _rating(row),
            ),
      ],
    );
  }

  // ─── Field helpers ─────────────────────────────────────────────────────

  static const int _genreAnimation = 16;
  static const int _genreDocumentary = 99;
  static const int _genreReality = 10764;
  static const int _genreTalk = 10767;

  /// The shelf a title's genres put it on. Genre ids, unlike genre names, do
  /// not change with the language. Animation wins over everything else, so
  /// an animated documentary is still anime.
  static String _category(Map<dynamic, dynamic> json, {required bool isShow}) {
    final genres = {for (final g in json.objs('genres')) ?g.integer('id')};
    if (genres.contains(_genreAnimation)) return LibraryTypes.anime;
    if (isShow && (genres.contains(_genreReality) || genres.contains(_genreTalk))) return LibraryTypes.variety;
    if (genres.contains(_genreDocumentary)) return LibraryTypes.documentary;
    return isShow ? LibraryTypes.show : LibraryTypes.movie;
  }

  static double? _rating(Map<dynamic, dynamic> json) {
    final value = json.number('vote_average');
    // TMDB reports 0 for "nobody has voted", which is not a score.
    return value == null || value <= 0 ? null : value;
  }

  static List<String> _aliases(List<Map<dynamic, dynamic>>? rows, String key) {
    final seen = <String>{};
    return [
      for (final row in rows ?? const <Map<dynamic, dynamic>>[])
        if (row.str(key) case final String name when seen.add(name.toLowerCase())) name,
    ];
  }

  String? _logo(Map<dynamic, dynamic>? images) {
    final logos = images?.objs('logos') ?? const [];
    if (logos.isEmpty) return null;
    final wanted = language.split('-').first;
    final best =
        logos.where((l) => l.str('iso_639_1') == wanted).firstOrNull ??
        logos.where((l) => l.str('iso_639_1') == 'en').firstOrNull ??
        logos.first;
    return _image(best.str('file_path'), 'w500');
  }

  String? _movieCertification(Map<dynamic, dynamic>? releaseDates) {
    final region = language.contains('-') ? language.split('-').last : 'US';
    String? fallback;
    for (final country in releaseDates?.objs('results') ?? const <Map<dynamic, dynamic>>[]) {
      final certification = country
          .objs('release_dates')
          .map((r) => r.str('certification'))
          .whereType<String>()
          .firstOrNull;
      if (certification == null) continue;
      if (country.str('iso_3166_1') == region) return certification;
      if (country.str('iso_3166_1') == 'US') fallback = certification;
    }
    return fallback;
  }

  String? _showRating(Map<dynamic, dynamic>? ratings) {
    final region = language.contains('-') ? language.split('-').last : 'US';
    String? fallback;
    for (final row in ratings?.objs('results') ?? const <Map<dynamic, dynamic>>[]) {
      final rating = row.str('rating');
      if (rating == null) continue;
      if (row.str('iso_3166_1') == region) return rating;
      if (row.str('iso_3166_1') == 'US') fallback = rating;
    }
    return fallback;
  }

  List<ScrapedCredit> _credits(Map<dynamic, dynamic>? credits, {List<Map<dynamic, dynamic>> creators = const []}) {
    const castLimit = 20;
    return [
      for (final person in creators)
        if (person.str('name') != null)
          ScrapedCredit(
            name: person.str('name')!,
            job: 'director',
            tmdbId: person.str('id'),
            photoUrl: _image(person.str('profile_path'), 'w185'),
          ),
      for (final person in credits?.objs('crew') ?? const <Map<dynamic, dynamic>>[])
        if (person.str('name') != null)
          if (switch (person.str('job')) {
                'Director' => 'director',
                'Screenplay' || 'Writer' || 'Story' => 'writer',
                _ => null,
              }
              case final String job)
            ScrapedCredit(
              name: person.str('name')!,
              job: job,
              tmdbId: person.str('id'),
              photoUrl: _image(person.str('profile_path'), 'w185'),
            ),
      for (final person in (credits?.objs('cast') ?? const <Map<dynamic, dynamic>>[]).take(castLimit))
        if (person.str('name') != null)
          ScrapedCredit(
            name: person.str('name')!,
            job: 'actor',
            character: person.str('character'),
            tmdbId: person.str('id'),
            photoUrl: _image(person.str('profile_path'), 'w185'),
          ),
    ];
  }

  @override
  void close() => _http.close();
}
