/// A search hit: enough to show the user and to fetch details with.
class ScrapedCandidate {
  const ScrapedCandidate({
    required this.source,
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.summary,
    this.posterUrl,
  });

  /// `'tmdb'` or `'bangumi'`.
  final String source;
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? summary;
  final String? posterUrl;
}

class ScrapedCredit {
  const ScrapedCredit({required this.name, required this.job, this.character, this.tmdbId, this.photoUrl});

  final String name;

  /// `'actor'`, `'director'` or `'writer'`.
  final String job;
  final String? character;
  final String? tmdbId;
  final String? photoUrl;
}

/// Everything a scraper knows about a movie or a show.
class ScrapedTitle {
  const ScrapedTitle({
    required this.source,
    required this.title,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.bangumiId,
    this.originalTitle,
    this.aliases = const [],
    this.year,
    this.releaseDate,
    this.summary,
    this.tagline,
    this.rating,
    this.runtimeMs,
    this.contentRating,
    this.studio,
    this.genres = const [],
    this.posterSource,
    this.backdropSource,
    this.logoSource,
    this.credits = const [],
    this.collectionId,
    this.collectionTitle,
    this.category,
  });

  /// `'nfo'`, `'tmdb'` or `'bangumi'`.
  final String source;
  final String title;
  final String? tmdbId;
  final String? imdbId;
  final String? tvdbId;
  final String? bangumiId;
  final String? originalTitle;
  final List<String> aliases;
  final int? year;
  final String? releaseDate;
  final String? summary;
  final String? tagline;
  final double? rating;
  final int? runtimeMs;
  final String? contentRating;
  final String? studio;
  final List<String> genres;
  final String? posterSource;
  final String? backdropSource;
  final String? logoSource;
  final List<ScrapedCredit> credits;

  /// The film series a movie belongs to, when the source models one.
  final String? collectionId;
  final String? collectionTitle;

  /// The shelf this title belongs on, one of `LibraryTypes.shelves`, when
  /// the source can tell. Null leaves it to the title being a movie or a show.
  final String? category;
}

class ScrapedEpisode {
  const ScrapedEpisode({
    required this.number,
    this.title,
    this.summary,
    this.airDate,
    this.runtimeMs,
    this.stillSource,
    this.rating,
  });

  final int number;
  final String? title;
  final String? summary;
  final String? airDate;
  final int? runtimeMs;
  final String? stillSource;
  final double? rating;
}

class ScrapedSeason {
  const ScrapedSeason({required this.number, this.title, this.summary, this.posterSource, this.episodes = const []});

  final int number;
  final String? title;
  final String? summary;
  final String? posterSource;
  final List<ScrapedEpisode> episodes;
}

/// Why a scraper could not answer.
class ScrapeException implements Exception {
  const ScrapeException(this.message, {this.isConfiguration = false, this.cause});

  final String message;

  /// True when the scraper cannot work until the user changes a setting (no
  /// API key, key rejected). Retrying every title would only repeat it.
  final bool isConfiguration;
  final Object? cause;

  @override
  String toString() => 'ScrapeException: $message';
}

/// An online metadata source.
abstract class MetadataProvider {
  /// `'tmdb'` or `'bangumi'`.
  String get source;

  Future<List<ScrapedCandidate>> searchMovie(String title, {int? year});

  Future<List<ScrapedCandidate>> searchShow(String title, {int? year});

  Future<ScrapedTitle> movie(String id);

  Future<ScrapedTitle> show(String id);

  /// Season [number] of show [id], or null when the source has none.
  Future<ScrapedSeason?> season(String id, int number);

  void close();
}
