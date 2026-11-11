import 'library_repository.dart';
import 'media_name_parser.dart';

/// Where a video belongs in the library, as far as its name and folders say.
class ClassifiedVideo {
  const ClassifiedVideo.movie({required String this.title, this.year, this.versionLabel})
    : kind = LibraryKinds.movie,
      season = null,
      episode = null;

  const ClassifiedVideo.episode({
    required String this.title,
    required int this.season,
    required int this.episode,
    this.year,
    this.versionLabel,
  }) : kind = LibraryKinds.episode;

  /// Nothing usable could be read; the file goes to the Unmatched shelf.
  const ClassifiedVideo.unknown({this.versionLabel})
    : kind = null,
      title = null,
      year = null,
      season = null,
      episode = null;

  /// [LibraryKinds.movie], [LibraryKinds.episode], or null when unknown.
  final String? kind;

  /// The movie's title, or the show's for an episode.
  final String? title;
  final int? year;
  final int? season;
  final int? episode;
  final String? versionLabel;

  bool get isKnown => kind != null;

  /// Changes whenever the file would be filed somewhere else, so a rescan can
  /// tell that a renamed or moved file needs re-filing.
  String get key => isKnown ? '$kind|${title!.toLowerCase()}|${year ?? ''}|${season ?? ''}|${episode ?? ''}' : '';
}

/// Guesses from names alone whether a video is a movie or an episode, and of
/// what. The guess is only what the scraper searches with: which shelf the
/// title lands on is decided by what the scraper finds.
abstract final class MediaClassifier {
  /// Bare numbers are trusted as episodes once this many videos in one
  /// folder carry them.
  static const int _numberedSiblingThreshold = 3;

  /// [folders] are the parsed names of the folders holding the file, nearest
  /// first. [numberedSiblings] counts the videos in the same folder
  /// (including this one) whose names carry any kind of episode number.
  static ClassifiedVideo classify({
    required ParsedName file,
    required List<ParsedFolder> folders,
    required int numberedSiblings,
  }) {
    final label = _versionLabel(file);
    final inSeasonFolder = folders.isNotEmpty && folders.first.isSeasonFolder;
    // The folder that names the title: the nearest one that is not a bare
    // season folder.
    final titleFolder = folders.where((f) => !f.isSeasonFolder && f.title != null).firstOrNull;
    final folderSeason = inSeasonFolder ? folders.first.season : titleFolder?.season;

    final number = file.episode ?? file.looseEpisode ?? (file.isSpecial ? 1 : null);

    final marked = file.episode != null || file.isSpecial;
    final looseTrusted =
        file.looseEpisode != null &&
        (file.season != null || inSeasonFolder || file.fansubStyle || numberedSiblings >= _numberedSiblingThreshold);
    final isEpisode = marked || looseTrusted;

    if (isEpisode) {
      final title = file.title ?? titleFolder?.title;
      if (title == null || number == null) return ClassifiedVideo.unknown(versionLabel: label);
      return ClassifiedVideo.episode(
        title: title,
        // A year in an episode's own name is usually the air year of that
        // season, not the show's; only the show folder's year is trusted.
        year: titleFolder?.year,
        season: file.isSpecial ? 0 : (file.season ?? folderSeason ?? 1),
        episode: number,
        versionLabel: label,
      );
    }

    // A file named only by a number or a disc label takes its folder's name.
    final title = file.title ?? titleFolder?.title;
    if (title == null) return ClassifiedVideo.unknown(versionLabel: label);
    return ClassifiedVideo.movie(
      title: title,
      year: file.year ?? (file.title == null || titleFolder?.title == file.title ? titleFolder?.year : null),
      versionLabel: label,
    );
  }

  static String? _versionLabel(ParsedName file) {
    final parts = [?file.resolution, ?file.edition];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
