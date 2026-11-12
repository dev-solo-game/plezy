import 'dart:convert';

/// A scraped movie or series inside one media source. Item and file ids are
/// deliberately kept out so rebuilding the local index preserves watch state.
class WorkIdentity {
  const WorkIdentity({required this.source, required this.kind, required this.provider, required this.externalId});

  static const localSource = 'local-library';

  final String source;
  final String kind;
  final String provider;
  final String externalId;

  static WorkIdentity? resolve({required String source, required String kind, String? tmdbId, String? imdbId}) {
    if (source.trim().isEmpty || (kind != 'movie' && kind != 'show')) return null;
    final tmdb = int.tryParse(tmdbId?.trim() ?? '');
    if (tmdb != null && tmdb > 0) {
      return WorkIdentity(source: source, kind: kind, provider: 'tmdb', externalId: '$tmdb');
    }
    final imdb = imdbId?.trim().toLowerCase();
    if (imdb != null && RegExp(r'^tt\d+$').hasMatch(imdb)) {
      return WorkIdentity(source: source, kind: kind, provider: 'imdb', externalId: imdb);
    }
    return null;
  }

  /// -1 denotes the whole work; season 0 remains available for specials.
  String stateKey({int season = -1, int episode = -1}) =>
      jsonEncode([source, kind, provider, externalId, season, episode]);
}
