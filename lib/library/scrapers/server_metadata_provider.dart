import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sync/sync_local_store.dart';
import 'scraped_metadata.dart';
import 'scraper_http.dart';
import 'tmdb_image_url.dart';
import 'tmdb_provider.dart';

class ServerMetadataConfig {
  const ServerMetadataConfig({
    this.tmdbConfigured = false,
    this.bangumiEnabled = true,
    this.tmdbImageBase = TmdbProvider.defaultImageBase,
    this.allowPublicMetadata = true,
    this.cachedWorks = 0,
    this.cachedSeasons = 0,
    this.cachedPeople = 0,
    this.cachedSearches = 0,
  });

  final bool tmdbConfigured;
  final bool bangumiEnabled;
  final String tmdbImageBase;
  final bool allowPublicMetadata;
  final int cachedWorks;
  final int cachedSeasons;
  final int cachedPeople;
  final int cachedSearches;

  factory ServerMetadataConfig.fromJson(Map<dynamic, dynamic> json) {
    final stats = json.obj('cache_stats');
    return ServerMetadataConfig(
      tmdbConfigured: json['tmdb_configured'] == true,
      bangumiEnabled: json['bangumi_enabled'] != false,
      tmdbImageBase: json.str('tmdb_image_base') ?? TmdbProvider.defaultImageBase,
      allowPublicMetadata: json['allow_public_metadata'] != false,
      cachedWorks: stats?.integer('works') ?? 0,
      cachedSeasons: stats?.integer('seasons') ?? 0,
      cachedPeople: stats?.integer('people') ?? 0,
      cachedSearches: stats?.integer('searches') ?? 0,
    );
  }
}

class ServerMetadataException extends ScrapeException {
  const ServerMetadataException(
    super.message, {
    super.isConfiguration = false,
    super.isMissingKey = false,
    super.cause,
    this.statusCode,
  });

  final int? statusCode;
}

/// Fetches cached/proxied public TMDB & Bangumi metadata from `sync_server`.
class ServerMetadataProvider implements MetadataProvider {
  ServerMetadataProvider({
    required String serverUrl,
    required this.source,
    this.language = 'zh-CN',
    this.accessToken,
    HttpClient? client,
    this.onImageBaseDiscovered,
  }) : _baseUrl = SyncLocalStore.normalizeServerUrl(serverUrl),
       _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsClient = client == null;

  final String _baseUrl;
  @override
  final String source;
  final String language;
  final String? accessToken;
  final HttpClient _client;
  final bool _ownsClient;
  final void Function(String imageBase)? onImageBaseDiscovered;

  static const int maxBatchItems = 50;

  static Future<ServerMetadataConfig> fetchConfig({
    required String serverUrl,
    String? accessToken,
    HttpClient? client,
  }) async {
    final prov = ServerMetadataProvider(serverUrl: serverUrl, source: 'tmdb', accessToken: accessToken, client: client);
    try {
      final decoded = await prov._requestJson('GET', '/api/v1/metadata/config');
      if (decoded is! Map) {
        throw const ServerMetadataException('Invalid metadata server response');
      }
      return ServerMetadataConfig.fromJson(decoded);
    } finally {
      if (client == null) {
        prov.close();
      }
    }
  }

  Future<Object?> _requestJson(String method, String path, {Map<String, String>? query, Object? body}) async {
    if (_baseUrl.isEmpty) {
      throw const ServerMetadataException('Metadata server URL is empty', isConfiguration: true);
    }
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: (query == null || query.isEmpty) ? null : query);
    final int status;
    final String text;
    try {
      final request = await _client.openUrl(method, uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final tok = accessToken?.trim() ?? '';
      if (tok.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $tok');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(const Duration(seconds: 30));
      status = response.statusCode;
      text = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
    } on TimeoutException catch (e) {
      throw ServerMetadataException('Metadata server did not answer in time', cause: e);
    } on IOException catch (e) {
      throw ServerMetadataException('Cannot reach ${uri.host}', cause: e);
    }

    if (status == HttpStatus.notFound) return null;

    Object? decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (e) {
        if (status >= 400) {
          throw ServerMetadataException('Metadata server answered HTTP $status', statusCode: status, cause: e);
        }
        throw ServerMetadataException('Metadata server sent an unreadable answer', cause: e);
      }
    }

    if (status >= 400) {
      final msg = decoded is Map ? (decoded.str('message') ?? 'Metadata error HTTP $status') : 'HTTP $status';
      if (status == HttpStatus.preconditionFailed) {
        throw ServerMetadataException(msg, isConfiguration: true, isMissingKey: true, statusCode: status);
      }
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        throw ServerMetadataException(msg, isConfiguration: true, statusCode: status);
      }
      throw ServerMetadataException(msg, statusCode: status);
    }

    if (decoded is Map) {
      final imgBase = decoded.str('image_base') ?? decoded.str('tmdb_image_base');
      if (imgBase != null && imgBase.isNotEmpty) {
        onImageBaseDiscovered?.call(imgBase);
      }
    }
    return decoded;
  }

  Future<List<ScrapedCandidate>> _search(String kind, String title, {int? year}) async {
    final decoded = await _requestJson(
      'GET',
      '/api/v1/metadata/search',
      query: {'provider': source, 'kind': kind, 'q': title, 'lang': language, if (year != null) 'year': '$year'},
    );
    if (decoded is! Map) {
      throw ServerMetadataException('Metadata search endpoint not found at $_baseUrl', isConfiguration: true);
    }
    final imageBase = decoded.str('image_base') ?? TmdbProvider.defaultImageBase;
    return [
      for (final row in decoded.objs('results'))
        if (row.str('id') != null && row.str('title') != null)
          ScrapedCandidate(
            source: row.str('source') ?? source,
            id: row.str('id')!,
            title: row.str('title')!,
            originalTitle: row.str('original_title'),
            year: row.integer('year'),
            summary: row.str('summary'),
            posterUrl: switch (row.str('poster_path')) {
              final String p when p.isNotEmpty => TmdbImageUrl.resolve(p, imageBase: imageBase, size: 'w342'),
              _ => null,
            },
          ),
    ];
  }

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) => _search('movie', title, year: year);

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) => _search('show', title, year: year);

  Future<ScrapedTitle> _work(String kind, String id) async {
    final decoded = await _requestJson(
      'GET',
      '/api/v1/metadata/work/${Uri.encodeComponent(source)}/$kind/${Uri.encodeComponent(id)}',
      query: {'lang': language},
    );
    if (decoded is! Map || decoded.obj('work') == null) {
      throw ServerMetadataException('$source has no $kind $id', statusCode: HttpStatus.notFound);
    }
    return workFromJson(decoded.obj('work')!);
  }

  @override
  Future<ScrapedTitle> movie(String id) => _work('movie', id);

  @override
  Future<ScrapedTitle> show(String id) => _work('show', id);

  @override
  Future<ScrapedSeason?> season(String id, int number) async {
    if (source == 'bangumi' && number != 1) return null;
    final decoded = await _requestJson(
      'GET',
      '/api/v1/metadata/season/${Uri.encodeComponent(source)}/${Uri.encodeComponent(id)}/$number',
      query: {'lang': language},
    );
    if (decoded is! Map || decoded.obj('season') == null) return null;
    return seasonFromJson(decoded.obj('season')!);
  }

  Future<({Map<String, ScrapedTitle> works, Map<String, ScrapedSeason> seasons, Map<String, String> errors})>
  fetchBatch({
    List<({String provider, String kind, String id, String? lang})> works = const [],
    List<({String provider, String id, int season, String? lang})> seasons = const [],
    String? lang,
    bool refresh = false,
  }) async {
    final outWorks = <String, ScrapedTitle>{};
    final outSeasons = <String, ScrapedSeason>{};
    final outErrors = <String, String>{};

    var wIdx = 0;
    var sIdx = 0;
    while (wIdx < works.length || sIdx < seasons.length) {
      final wChunk = works.sublist(wIdx, (wIdx + maxBatchItems).clamp(0, works.length));
      final sChunk = seasons.sublist(sIdx, (sIdx + maxBatchItems).clamp(0, seasons.length));
      wIdx += wChunk.length;
      sIdx += sChunk.length;

      final decoded = await _requestJson(
        'POST',
        '/api/v1/metadata/batch',
        body: {
          'lang': lang ?? language,
          if (refresh) 'refresh': true,
          if (wChunk.isNotEmpty)
            'works': [
              for (final w in wChunk)
                {
                  'provider': w.provider,
                  'kind': w.kind,
                  'id': w.id,
                  if (w.lang != null && w.lang!.isNotEmpty) 'lang': w.lang,
                },
            ],
          if (sChunk.isNotEmpty)
            'seasons': [
              for (final s in sChunk)
                {
                  'provider': s.provider,
                  'id': s.id,
                  'season': s.season,
                  if (s.lang != null && s.lang!.isNotEmpty) 'lang': s.lang,
                },
            ],
        },
      );
      if (decoded is! Map) continue;
      final worksObj = decoded.obj('works');
      if (worksObj != null) {
        for (final entry in worksObj.entries) {
          if (entry.value is Map) {
            outWorks['${entry.key}'] = workFromJson(entry.value as Map);
          }
        }
      }
      final seasonsObj = decoded.obj('seasons');
      if (seasonsObj != null) {
        for (final entry in seasonsObj.entries) {
          if (entry.value is Map) {
            outSeasons['${entry.key}'] = seasonFromJson(entry.value as Map);
          }
        }
      }
      final errorsObj = decoded.obj('errors');
      if (errorsObj != null) {
        for (final entry in errorsObj.entries) {
          outErrors['${entry.key}'] = '${entry.value}';
        }
      }
    }
    return (works: outWorks, seasons: outSeasons, errors: outErrors);
  }

  static ScrapedTitle workFromJson(Map<dynamic, dynamic> work) {
    final aliasesRaw = work['aliases'];
    final genresRaw = work['genres'];
    return ScrapedTitle(
      source: work.str('source') ?? 'tmdb',
      tmdbId: work.str('tmdb_id'),
      imdbId: work.str('imdb_id'),
      tvdbId: work.str('tvdb_id'),
      bangumiId: work.str('bangumi_id'),
      title: work.str('title') ?? '',
      originalTitle: work.str('original_title'),
      aliases: [
        if (aliasesRaw is List)
          for (final a in aliasesRaw)
            if ('$a'.trim().isNotEmpty) '$a'.trim(),
      ],
      year: work.integer('year'),
      releaseDate: work.str('release_date'),
      summary: work.str('summary'),
      tagline: work.str('tagline'),
      rating: work.number('rating'),
      runtimeMs: work.integer('runtime_ms'),
      contentRating: work.str('content_rating'),
      studio: work.str('studio'),
      genres: [
        if (genresRaw is List)
          for (final g in genresRaw)
            if ('$g'.trim().isNotEmpty) '$g'.trim(),
      ],
      posterSource: work.str('poster_path'),
      backdropSource: work.str('backdrop_path'),
      logoSource: work.str('logo_path'),
      credits: [
        for (final c in work.objs('credits'))
          if (c.str('name') != null && c.str('job') != null)
            ScrapedCredit(
              name: c.str('name')!,
              job: c.str('job')!,
              character: c.str('character'),
              tmdbId: c.str('tmdb_id'),
              photoUrl: c.str('photo_path'),
            ),
      ],
      collectionId: work.str('collection_id'),
      collectionTitle: work.str('collection_title'),
      category: work.str('category'),
    );
  }

  static ScrapedSeason seasonFromJson(Map<dynamic, dynamic> season) => ScrapedSeason(
    number: season.integer('number') ?? 0,
    title: season.str('title'),
    summary: season.str('summary'),
    posterSource: season.str('poster_path'),
    episodes: [
      for (final ep in season.objs('episodes'))
        if (ep.integer('number') != null)
          ScrapedEpisode(
            number: ep.integer('number')!,
            title: ep.str('title'),
            summary: ep.str('summary'),
            airDate: ep.str('air_date'),
            runtimeMs: ep.integer('runtime_ms'),
            stillSource: ep.str('still_path'),
            rating: ep.number('rating'),
          ),
    ],
  );

  @override
  void close() {
    if (_ownsClient) {
      _client.close(force: true);
    }
  }
}
