import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../session/app_session_models.dart';
import 'scraped_metadata.dart';
import 'scraper_http.dart';
import 'tmdb_image_url.dart';
import 'tmdb_provider.dart';

class ServerMetadataConfig {
  const ServerMetadataConfig({
    this.allowPublicMetadata = true,
    this.tmdbConfigured = false,
    this.bangumiEnabled = true,
    this.doubanEnabled = true,
    this.anilistEnabled = true,
    this.imdbEnabled = true,
    this.tvdbEnabled = false,
    this.enabledProviders = const [],
    this.tmdbImageBase = TmdbProvider.defaultImageBase,
    this.artworkProxyPath = '/api/v1/public/metadata/artwork',
    this.proxyImages = false,
    this.cachedWorks = 0,
    this.cachedSeasons = 0,
    this.cachedPeople = 0,
    this.cachedSearches = 0,
  });

  final bool allowPublicMetadata;
  final bool tmdbConfigured;
  final bool bangumiEnabled;
  final bool doubanEnabled;
  final bool anilistEnabled;
  final bool imdbEnabled;
  final bool tvdbEnabled;
  final List<String> enabledProviders;
  final String tmdbImageBase;
  final String artworkProxyPath;
  final bool proxyImages;
  final int cachedWorks;
  final int cachedSeasons;
  final int cachedPeople;
  final int cachedSearches;

  factory ServerMetadataConfig.fromJson(Map<dynamic, dynamic> json) {
    final stats = json.obj('cache_stats');
    final rawProviders = json['enabled_providers'];
    return ServerMetadataConfig(
      allowPublicMetadata: json['allow_public_metadata'] != false,
      tmdbConfigured: json['tmdb_configured'] == true,
      bangumiEnabled: json['bangumi_enabled'] != false,
      doubanEnabled: json['douban_enabled'] != false,
      anilistEnabled: json['anilist_enabled'] != false,
      imdbEnabled: json['imdb_enabled'] != false,
      tvdbEnabled: json['tvdb_enabled'] == true,
      enabledProviders: [
        if (rawProviders is List)
          for (final p in rawProviders)
            if ('$p'.trim().isNotEmpty) '$p'.trim(),
      ],
      tmdbImageBase: json.str('tmdb_image_base') ?? TmdbProvider.defaultImageBase,
      artworkProxyPath: json.str('artwork_proxy_path') ?? '/api/v1/public/metadata/artwork',
      proxyImages: json['proxy_images'] == true,
      cachedWorks: stats?.integer('works') ?? 0,
      cachedSeasons: stats?.integer('seasons') ?? 0,
      cachedPeople: stats?.integer('people') ?? 0,
      cachedSearches: stats?.integer('searches') ?? 0,
    );
  }
}

class ServerIdentifyResult {
  const ServerIdentifyResult({
    required this.matched,
    required this.kind,
    required this.source,
    required this.bridgedFrom,
    required this.impliedSeason,
    this.workKey,
    this.work,
  });

  final bool matched;
  final String kind;
  final String source;
  final String bridgedFrom;
  final int impliedSeason;
  final String? workKey;
  final ScrapedTitle? work;
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

/// Fetches generic metadata & smart-identification results from `media_server`
/// `/api/v1/public/metadata/*`, rewriting artwork URLs through the server's
/// image proxy when `proxy_images` is enabled.
class ServerMetadataProvider implements MetadataProvider {
  ServerMetadataProvider({
    required String serverUrl,
    this.source = 'all',
    this.language = 'zh-CN',
    this.accessToken,
    HttpClient? client,
    this.onImageBaseDiscovered,
  }) : _baseUrl = normalizeServerUrl(serverUrl),
       _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsClient = client == null;

  static const String defaultOfficialMetadataUrl = String.fromEnvironment(
    'PLEZY_OFFICIAL_METADATA_URL',
    defaultValue: 'http://10.0.10.48:8090',
  );

  static const String defaultArtworkProxyPath = '/api/v1/public/metadata/artwork';
  static const int maxBatchItems = 50;

  static String normalizeServerUrl(String raw) => SelfHostedSession.normalizeServerUrl(raw);

  final String _baseUrl;
  @override
  final String source;
  final String language;
  final String? accessToken;
  final HttpClient _client;
  final bool _ownsClient;
  final void Function(String imageBase)? onImageBaseDiscovered;

  bool get _useAuthenticatedEndpoints => (accessToken?.trim().isNotEmpty ?? false);

  static Future<ServerMetadataConfig> fetchConfig({
    required String serverUrl,
    String? accessToken,
    HttpClient? client,
  }) async {
    final prov = ServerMetadataProvider(serverUrl: serverUrl, source: 'all', accessToken: accessToken, client: client);
    try {
      final decoded = await prov._requestJson('GET', '/api/v1/public/metadata/config');
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
      final msg = decoded is Map
          ? (decoded.str('error') ?? decoded.str('message') ?? 'Metadata error HTTP $status')
          : 'HTTP $status';
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

  static String? resolveArtworkUrl(
    String? raw, {
    required String serverBaseUrl,
    required bool proxyImages,
    required String artworkProxyPath,
    required String size,
    String? imageBase,
    bool asCandidate = false,
  }) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('mount:')) return s;

    final proxyPath = artworkProxyPath.isNotEmpty ? artworkProxyPath : defaultArtworkProxyPath;
    if (proxyImages && serverBaseUrl.isNotEmpty) {
      if (s.startsWith('$serverBaseUrl$proxyPath')) return s;
      if (s.startsWith(proxyPath)) return '$serverBaseUrl$s';
      if (s.startsWith('/') || s.startsWith('http://') || s.startsWith('https://')) {
        return '$serverBaseUrl$proxyPath?src=${Uri.encodeQueryComponent(s)}&size=$size';
      }
    }

    if (asCandidate) {
      return TmdbImageUrl.resolve(s, imageBase: imageBase ?? TmdbProvider.defaultImageBase, size: size);
    }
    return s;
  }

  Future<List<ScrapedCandidate>> searchAll({
    required String kind,
    required String title,
    int? year,
    String? provider,
    bool refresh = false,
  }) async {
    final prov = (provider != null && provider.isNotEmpty) ? provider : source;
    final decoded = await _requestJson(
      'GET',
      _useAuthenticatedEndpoints ? '/api/v1/metadata/search' : '/api/v1/public/metadata/search',
      query: {
        'provider': prov,
        'kind': kind,
        'q': title,
        'lang': language,
        if (year != null) 'year': '$year',
        if (refresh) 'refresh': 'true',
      },
    );
    if (decoded is! Map) {
      throw ServerMetadataException('Metadata search endpoint not found at $_baseUrl', isConfiguration: true);
    }
    final imageBase = decoded.str('image_base') ?? TmdbProvider.defaultImageBase;
    final proxyImages = decoded['proxy_images'] == true;
    final artworkProxyPath = decoded.str('artwork_proxy_path') ?? defaultArtworkProxyPath;
    return [
      for (final row in decoded.objs('results'))
        if (row.str('id') != null && row.str('title') != null)
          ScrapedCandidate(
            source: row.str('source') ?? prov,
            id: row.str('id')!,
            title: row.str('title')!,
            originalTitle: row.str('original_title'),
            year: row.integer('year'),
            summary: row.str('summary'),
            posterUrl: resolveArtworkUrl(
              row.str('poster_path'),
              serverBaseUrl: _baseUrl,
              proxyImages: proxyImages,
              artworkProxyPath: artworkProxyPath,
              size: 'w342',
              imageBase: imageBase,
              asCandidate: true,
            ),
          ),
    ];
  }

  @override
  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year}) =>
      searchAll(kind: 'movie', title: title, year: year);

  @override
  Future<List<ScrapedCandidate>> searchShow(String title, {int? year}) =>
      searchAll(kind: 'show', title: title, year: year);

  Future<ServerIdentifyResult> identify({
    required String title,
    int? year,
    required String kind,
    String? filename,
    String? folderHint,
    bool isAnime = false,
    bool allowKindChange = true,
    bool refresh = false,
  }) async {
    final decoded = await _requestJson(
      'POST',
      _useAuthenticatedEndpoints ? '/api/v1/metadata/identify' : '/api/v1/public/metadata/identify',
      body: {
        'title': title,
        'year': ?year,
        'kind': kind,
        if (filename != null && filename.isNotEmpty) 'filename': filename,
        if (folderHint != null && folderHint.isNotEmpty) 'folder_hint': folderHint,
        'is_anime': isAnime,
        'allow_kind_change': allowKindChange,
        'lang': language,
        if (refresh) 'refresh': true,
      },
    );
    if (decoded is! Map) {
      throw ServerMetadataException('Metadata identify endpoint not found at $_baseUrl', isConfiguration: true);
    }
    final proxyImages = decoded['proxy_images'] == true;
    final artworkProxyPath = decoded.str('artwork_proxy_path') ?? defaultArtworkProxyPath;
    final workMap = decoded.obj('work');
    return ServerIdentifyResult(
      matched: decoded['matched'] == true && workMap != null,
      kind: decoded.str('kind') ?? kind,
      source: decoded.str('source') ?? '',
      bridgedFrom: decoded.str('bridged_from') ?? '',
      impliedSeason: decoded.integer('implied_season') ?? 0,
      workKey: decoded.str('work_key'),
      work: workMap == null
          ? null
          : workFromJson(
              workMap,
              serverBaseUrl: _baseUrl,
              proxyImages: proxyImages,
              artworkProxyPath: artworkProxyPath,
            ),
    );
  }

  Future<ScrapedTitle> workFor({
    required String provider,
    required String kind,
    required String id,
    bool refresh = false,
  }) async {
    final effectiveProvider = (provider.isEmpty || provider == 'all') ? 'tmdb' : provider;
    final workPrefix = _useAuthenticatedEndpoints ? '/api/v1/metadata/works' : '/api/v1/public/metadata/work';
    final decoded = await _requestJson(
      'GET',
      '$workPrefix/${Uri.encodeComponent(effectiveProvider)}/$kind/${Uri.encodeComponent(id)}',
      query: {'lang': language, if (refresh) 'refresh': 'true'},
    );
    if (decoded is! Map || decoded.obj('work') == null) {
      throw ServerMetadataException('$effectiveProvider has no $kind $id', statusCode: HttpStatus.notFound);
    }
    final proxyImages = decoded['proxy_images'] == true;
    final artworkProxyPath = decoded.str('artwork_proxy_path') ?? defaultArtworkProxyPath;
    return workFromJson(
      decoded.obj('work')!,
      serverBaseUrl: _baseUrl,
      proxyImages: proxyImages,
      artworkProxyPath: artworkProxyPath,
    );
  }

  @override
  Future<ScrapedTitle> movie(String id) => workFor(provider: source, kind: 'movie', id: id);

  @override
  Future<ScrapedTitle> show(String id) => workFor(provider: source, kind: 'show', id: id);

  Future<ScrapedSeason?> seasonFor({
    required String provider,
    required String id,
    required int season,
    bool refresh = false,
  }) async {
    final effectiveProvider = (provider.isEmpty || provider == 'all') ? 'tmdb' : provider;
    if (effectiveProvider == 'bangumi' && season != 1) return null;
    final seasonPrefix = _useAuthenticatedEndpoints ? '/api/v1/metadata/seasons' : '/api/v1/public/metadata/season';
    final decoded = await _requestJson(
      'GET',
      '$seasonPrefix/${Uri.encodeComponent(effectiveProvider)}/${Uri.encodeComponent(id)}/$season',
      query: {'lang': language, if (refresh) 'refresh': 'true'},
    );
    if (decoded is! Map || decoded.obj('season') == null) return null;
    final proxyImages = decoded['proxy_images'] == true;
    final artworkProxyPath = decoded.str('artwork_proxy_path') ?? defaultArtworkProxyPath;
    return seasonFromJson(
      decoded.obj('season')!,
      serverBaseUrl: _baseUrl,
      proxyImages: proxyImages,
      artworkProxyPath: artworkProxyPath,
    );
  }

  @override
  Future<ScrapedSeason?> season(String id, int number) => seasonFor(provider: source, id: id, season: number);

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
        '/api/v1/public/metadata/batch',
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
      final proxyImages = decoded['proxy_images'] == true;
      final artworkProxyPath = decoded.str('artwork_proxy_path') ?? defaultArtworkProxyPath;
      final worksObj = decoded.obj('works');
      if (worksObj != null) {
        for (final entry in worksObj.entries) {
          if (entry.value is Map) {
            outWorks['${entry.key}'] = workFromJson(
              entry.value as Map,
              serverBaseUrl: _baseUrl,
              proxyImages: proxyImages,
              artworkProxyPath: artworkProxyPath,
            );
          }
        }
      }
      final seasonsObj = decoded.obj('seasons');
      if (seasonsObj != null) {
        for (final entry in seasonsObj.entries) {
          if (entry.value is Map) {
            outSeasons['${entry.key}'] = seasonFromJson(
              entry.value as Map,
              serverBaseUrl: _baseUrl,
              proxyImages: proxyImages,
              artworkProxyPath: artworkProxyPath,
            );
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

  static ScrapedTitle workFromJson(
    Map<dynamic, dynamic> work, {
    String serverBaseUrl = '',
    bool proxyImages = false,
    String artworkProxyPath = defaultArtworkProxyPath,
  }) {
    final aliasesRaw = work['aliases'];
    final genresRaw = work['genres'];
    String? art(String? raw, String size) => resolveArtworkUrl(
      raw,
      serverBaseUrl: serverBaseUrl,
      proxyImages: proxyImages,
      artworkProxyPath: artworkProxyPath,
      size: size,
    );
    return ScrapedTitle(
      source: work.str('source') ?? 'tmdb',
      externalId: work.str('external_id'),
      tmdbId: work.str('tmdb_id'),
      imdbId: work.str('imdb_id'),
      tvdbId: work.str('tvdb_id'),
      bangumiId: work.str('bangumi_id'),
      doubanId: work.str('douban_id'),
      anilistId: work.str('anilist_id'),
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
      posterSource: art(work.str('poster_path'), 'w500'),
      backdropSource: art(work.str('backdrop_path'), 'w1280'),
      logoSource: art(work.str('logo_path'), 'w500'),
      credits: [
        for (final c in work.objs('credits'))
          if (c.str('name') != null && c.str('job') != null)
            ScrapedCredit(
              name: c.str('name')!,
              job: c.str('job')!,
              character: c.str('character'),
              tmdbId: c.str('tmdb_id'),
              photoUrl: art(c.str('photo_path'), 'w185'),
            ),
      ],
      collectionId: work.str('collection_id'),
      collectionTitle: work.str('collection_title'),
      category: work.str('category'),
    );
  }

  static ScrapedSeason seasonFromJson(
    Map<dynamic, dynamic> season, {
    String serverBaseUrl = '',
    bool proxyImages = false,
    String artworkProxyPath = defaultArtworkProxyPath,
  }) => ScrapedSeason(
    number: season.integer('number') ?? 0,
    title: season.str('title'),
    summary: season.str('summary'),
    posterSource: resolveArtworkUrl(
      season.str('poster_path'),
      serverBaseUrl: serverBaseUrl,
      proxyImages: proxyImages,
      artworkProxyPath: artworkProxyPath,
      size: 'w500',
    ),
    episodes: [
      for (final ep in season.objs('episodes'))
        if (ep.integer('number') != null)
          ScrapedEpisode(
            number: ep.integer('number')!,
            title: ep.str('title'),
            summary: ep.str('summary'),
            airDate: ep.str('air_date'),
            runtimeMs: ep.integer('runtime_ms'),
            stillSource: resolveArtworkUrl(
              ep.str('still_path'),
              serverBaseUrl: serverBaseUrl,
              proxyImages: proxyImages,
              artworkProxyPath: artworkProxyPath,
              size: 'w780',
            ),
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
