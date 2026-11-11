import 'package:xml/xml.dart';

import 'scraped_metadata.dart';

/// Reads Kodi-style `.nfo` files, the format tinyMediaManager, Emby and
/// Jellyfin write next to media. A library organised with one of those
/// tools needs no online lookup.
abstract final class NfoReader {
  /// Parses a `<movie>` or `<tvshow>` document. Returns null when [content]
  /// is not such a document or carries no title.
  static ScrapedTitle? readTitle(String content) {
    final root = _root(content);
    if (root == null || (root.name.local != 'movie' && root.name.local != 'tvshow')) return null;
    final title = _text(root, 'title');
    if (title == null) return null;

    final ids = _ids(root);
    final runtime = int.tryParse(_text(root, 'runtime') ?? '');
    final premiered = _text(root, 'premiered') ?? _text(root, 'releasedate') ?? _text(root, 'aired');
    return ScrapedTitle(
      source: 'nfo',
      title: title,
      tmdbId: ids['tmdb'],
      imdbId: ids['imdb'],
      tvdbId: ids['tvdb'],
      bangumiId: ids['bangumi'],
      originalTitle: _text(root, 'originaltitle'),
      year: int.tryParse(_text(root, 'year') ?? '') ?? _yearOf(premiered),
      releaseDate: premiered,
      summary: _text(root, 'plot') ?? _text(root, 'outline'),
      tagline: _text(root, 'tagline'),
      rating: _rating(root),
      runtimeMs: runtime == null || runtime <= 0 ? null : runtime * 60000,
      contentRating: _text(root, 'mpaa'),
      studio: _text(root, 'studio'),
      genres: _children(root, 'genre').map((e) => e.innerText.trim()).where((g) => g.isNotEmpty).toList(),
      credits: [
        for (final director in _children(root, 'director'))
          if (director.innerText.trim().isNotEmpty) ScrapedCredit(name: director.innerText.trim(), job: 'director'),
        for (final writer in [..._children(root, 'credits'), ..._children(root, 'writer')])
          if (writer.innerText.trim().isNotEmpty) ScrapedCredit(name: writer.innerText.trim(), job: 'writer'),
        for (final actor in _children(root, 'actor'))
          if (_text(actor, 'name') case final String name)
            ScrapedCredit(name: name, job: 'actor', character: _text(actor, 'role'), photoUrl: _text(actor, 'thumb')),
      ],
      collectionTitle: _text(root, 'set') ?? _child(root, 'set').map((s) => _text(s, 'name')).firstOrNull,
    );
  }

  /// Parses an `<episodedetails>` document.
  static ScrapedEpisode? readEpisode(String content) {
    final root = _root(content);
    if (root == null || root.name.local != 'episodedetails') return null;
    final number = int.tryParse(_text(root, 'episode') ?? '');
    if (number == null) return null;
    final runtime = int.tryParse(_text(root, 'runtime') ?? '');
    return ScrapedEpisode(
      number: number,
      title: _text(root, 'title'),
      summary: _text(root, 'plot'),
      airDate: _text(root, 'aired'),
      runtimeMs: runtime == null || runtime <= 0 ? null : runtime * 60000,
      rating: _rating(root),
    );
  }

  static XmlElement? _root(String content) {
    // Some tools append a URL after the closing tag; cut at the last one.
    final end = content.lastIndexOf('>');
    if (end < 0) return null;
    try {
      return XmlDocument.parse(content.substring(0, end + 1)).rootElement;
    } on XmlException {
      return null;
    }
  }

  static Iterable<XmlElement> _children(XmlElement parent, String name) =>
      parent.childElements.where((e) => e.name.local == name);

  static Iterable<XmlElement> _child(XmlElement parent, String name) => _children(parent, name).take(1);

  static String? _text(XmlElement parent, String name) {
    final element = _children(parent, name).firstOrNull;
    // An element with children of its own (like <set><name>) is not a value.
    if (element == null || element.childElements.isNotEmpty) return null;
    final text = element.innerText.trim();
    return text.isEmpty ? null : text;
  }

  static int? _yearOf(String? date) => date == null || date.length < 4 ? null : int.tryParse(date.substring(0, 4));

  static Map<String, String> _ids(XmlElement root) {
    final ids = <String, String>{};
    for (final unique in _children(root, 'uniqueid')) {
      final type = unique.getAttribute('type')?.toLowerCase();
      final value = unique.innerText.trim();
      if (type != null && value.isNotEmpty) ids[type] = value;
    }
    for (final (tag, key) in const [('tmdbid', 'tmdb'), ('imdbid', 'imdb'), ('tvdbid', 'tvdb')]) {
      final value = _text(root, tag);
      if (value != null) ids.putIfAbsent(key, () => value);
    }
    // Older files put the IMDb id in a bare <id>.
    final bare = _text(root, 'id');
    if (bare != null && bare.startsWith('tt')) ids.putIfAbsent('imdb', () => bare);
    return ids;
  }

  static double? _rating(XmlElement root) {
    final direct = double.tryParse(_text(root, 'rating') ?? '');
    if (direct != null && direct > 0) return direct;
    for (final ratings in _children(root, 'ratings')) {
      for (final rating in _children(ratings, 'rating')) {
        final value = double.tryParse(_text(rating, 'value') ?? '');
        if (value != null && value > 0) return value;
      }
    }
    return null;
  }
}
