import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:string_similarity/string_similarity.dart';

import '../database/app_database.dart';
import '../storage/storage_path.dart';
import '../utils/app_logger.dart';
import 'library_repository.dart';
import 'scrapers/scraped_metadata.dart';

class ScrapeSummary {
  const ScrapeSummary({this.matched = 0, this.unmatched = 0, this.merged = 0, this.skipped = 0, this.stoppedBy});

  final int matched;
  final int unmatched;

  /// Titles folded into one that was already in the library.
  final int merged;

  /// Titles left queued because no source that could look them up is
  /// configured. They are tried again once one is.
  final int skipped;

  /// Set when scraping stopped early: a missing or rejected API key, or the
  /// network being down. The titles not reached stay queued.
  final String? stoppedBy;
}

/// Identifies the library's provisional titles and puts them on a shelf.
///
/// For each movie or show the scanner created from a file name: search the
/// online providers, pick a confident match, write its details, and file the
/// title under the shelf its metadata calls for (anime, variety, ...). A
/// title nothing matches stays off every shelf until the user matches it by
/// hand. Titles the user matched by hand are never touched.
///
/// Scraping works from the database alone; it never reads from a mount.
class LibraryScraper {
  LibraryScraper(this._db, this._repo, {required List<MetadataProvider> providers}) : _metadataProviders = providers;

  final AppDatabase _db;
  final LibraryRepository _repo;
  final List<MetadataProvider> _metadataProviders;

  /// Below this a search hit is not trusted and the title stays unmatched.
  static const double _acceptScore = 0.72;

  static const List<String> _posterNames = ['poster', 'folder', 'cover', 'movie'];
  static const List<String> _backdropNames = ['fanart', 'backdrop', 'background'];

  static int _now() => clock.now().millisecondsSinceEpoch;

  static String _mountSource(String mountId, String path) => 'mount:$mountId:$path';

  static final RegExp _animeFolder = RegExp(
    r'动漫|動漫|动画|動畫|番剧|番劇|国漫|國漫|日漫|美漫|卡通|anime|bangumi|cartoon',
    caseSensitive: false,
  );
  static final RegExp _varietyFolder = RegExp(r'综艺|綜藝|真人秀|脱口秀|脫口秀|variety|reality', caseSensitive: false);
  static final RegExp _documentaryFolder = RegExp(r'纪录|紀錄|documentar', caseSensitive: false);

  /// One video of [item], or null when it has none.
  Future<LibraryFileRow?> _videoOf(LibraryItemRow item) async {
    final leaves = await _leafIds(item);
    if (leaves.isEmpty) return null;
    return (_db.select(_db.libraryFiles)
          ..where((t) => t.itemId.isIn(leaves) & t.role.equals(LibraryFileRoles.video))
          ..limit(1))
        .getSingleOrNull();
  }

  /// The shelf the folders holding [item] name, if any: libraries are often
  /// laid out as `电视剧/综艺/...` or `电影/动画电影/...`. Only the folders
  /// above the title's own folder count, so a title named "动画..." does not
  /// put itself on the anime shelf.
  Future<String?> _folderCategory(LibraryItemRow item) async {
    final video = await _videoOf(item);
    if (video == null) return null;
    final folders = StoragePath.segments(StoragePath.parent(video.path));
    // Drop the title folder (and a season folder below it for shows).
    var keep = folders.length - 1;
    if (keep > 0 && _looksLikeSeasonFolder(folders.last)) keep--;
    final above = folders.take(keep < 0 ? 0 : keep).join('/');
    if (_animeFolder.hasMatch(above)) return LibraryTypes.anime;
    if (_varietyFolder.hasMatch(above)) return LibraryTypes.variety;
    if (_documentaryFolder.hasMatch(above)) return LibraryTypes.documentary;
    return null;
  }

  /// Whether the files of [item] look like anime: fansub-style names, or a
  /// folder that says so.
  Future<bool> _looksLikeAnime(LibraryItemRow item) async {
    final video = await _videoOf(item);
    if (video == null) return false;
    if (_animeFolder.hasMatch(StoragePath.parent(video.path))) return true;
    return video.parsed?.contains('"fansubStyle":true') ?? false;
  }

  /// Providers in the order to try them for [item]. Bangumi only knows
  /// anime, and would answer for a live-action title with its animated
  /// namesake, so it is asked only when the files look like anime. It goes
  /// first for series, where its episode lists are the better source; for
  /// films TMDB goes first, since an animation folder holds Pixar as much
  /// as Ghibli and TMDB knows both.
  Future<List<MetadataProvider>> _providersFor(LibraryItemRow item) async {
    final general = _metadataProviders.where((p) => p.source != 'bangumi').toList();
    if (!await _looksLikeAnime(item)) return general;
    final bangumi = _metadataProviders.where((p) => p.source == 'bangumi').toList();
    return item.kind == LibraryKinds.show ? [...bangumi, ...general] : [...general, ...bangumi];
  }

  /// The shelf for [item] once [details] are known. The source decides when
  /// it is specific (TMDB's animation, reality and documentary genres;
  /// everything from Bangumi). When it only says "a movie" or "a show", the
  /// folders the user filed it under decide: variety shows are often tagged
  /// as plain drama, and the folder knows better.
  Future<String> _shelfFor(LibraryItemRow item, ScrapedTitle details) async {
    final fromSource = details.category;
    final generic = fromSource == null || fromSource == LibraryTypes.movie || fromSource == LibraryTypes.show;
    if (!generic) return fromSource;
    final fromFolder = await _folderCategory(item);
    if (fromFolder != null) return fromFolder;
    return item.kind == LibraryKinds.show ? LibraryTypes.show : LibraryTypes.movie;
  }

  // ─── Queue ─────────────────────────────────────────────────────────────

  /// Scrapes every movie and show that has not been looked up yet.
  Future<ScrapeSummary> scrapePending({
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final items = _db.libraryItems;
    final queue =
        await (_db.select(items)
              ..where(
                (t) =>
                    t.kind.isIn([LibraryKinds.movie, LibraryKinds.show]) &
                    t.metadataSource.isNull() &
                    t.scrapedAt.isNull() &
                    t.locked.equals(false),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();

    var matched = 0;
    var unmatched = 0;
    var merged = 0;
    var skipped = 0;
    for (final (index, item) in queue.indexed) {
      if (isCancelled?.call() ?? false) break;
      onProgress?.call(index, queue.length);
      try {
        switch (await scrapeItem(item.id)) {
          case ScrapeOutcome.matched:
            matched++;
          case ScrapeOutcome.merged:
            merged++;
          case ScrapeOutcome.unmatched:
            unmatched++;
          case ScrapeOutcome.skipped:
            skipped++;
        }
      } on ScrapeException catch (e) {
        appLogger.w('Scraping "${item.title}" failed: ${e.message}');
        // The item keeps its place in the queue; nothing was decided about it.
        return ScrapeSummary(
          matched: matched,
          unmatched: unmatched,
          merged: merged,
          skipped: skipped,
          stoppedBy: e.message,
        );
      }
    }
    onProgress?.call(queue.length, queue.length);
    return ScrapeSummary(matched: matched, unmatched: unmatched, merged: merged, skipped: skipped);
  }

  /// Puts every title whose lookup found nothing back in the queue.
  Future<void> requeueUnmatched() async {
    await (_db.update(_db.libraryItems)..where((t) => t.metadataSource.isNull() & t.locked.equals(false))).write(
      const LibraryItemsCompanion(scrapedAt: Value(null)),
    );
  }

  // ─── One title ─────────────────────────────────────────────────────────

  /// Looks one movie or show up, applies what is found and files the title
  /// on its shelf. Exposed so a single title can be refreshed.
  Future<ScrapeOutcome> scrapeItem(int itemId) async {
    var item = await (_db.select(_db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null || item.locked) return ScrapeOutcome.unmatched;

    // With nothing to ask, the title stays queued rather than being written
    // off as unmatched.
    final providers = await _providersFor(item);
    if (providers.isEmpty) return ScrapeOutcome.skipped;

    final guessedShow = item.kind == LibraryKinds.show;
    var match = await _findMatch(providers, item, isShow: guessedShow);
    if (match == null && await canChangeKind(item.id)) {
      // Names alone can mistake a film for an episode and the reverse.
      match = await _findMatch(providers, item, isShow: !guessedShow);
      if (match != null) item = await _changeKind(item);
    }
    if (match == null) {
      await (_db.update(
        _db.libraryItems,
      )..where((t) => t.id.equals(itemId))).write(LibraryItemsCompanion(scrapedAt: Value(_now())));
      await _setFilesState(item, LibraryMatchStates.unmatched);
      return ScrapeOutcome.unmatched;
    }

    final (provider, candidate) = match;
    final isShow = item.kind == LibraryKinds.show;
    final target = await _existingWithIds(
      item,
      tmdbId: provider.source == 'tmdb' ? candidate.id : null,
      bangumiId: provider.source == 'bangumi' ? candidate.id : null,
    );
    if (target != null) return _mergeInto(item, target);

    final details = isShow ? await provider.show(candidate.id) : await provider.movie(candidate.id);
    await _apply(item, details, folder: await _folderOf(item));
    if (isShow) await _fillSeasons(item, provider, candidate.id, details.title);
    await _setFilesState(item, LibraryMatchStates.matched);
    return ScrapeOutcome.matched;
  }

  Future<(MetadataProvider, ScrapedCandidate)?> _findMatch(
    List<MetadataProvider> providers,
    LibraryItemRow item, {
    required bool isShow,
  }) async {
    for (final provider in providers) {
      final candidate = await _bestCandidate(provider, item, isShow: isShow);
      if (candidate != null) return (provider, candidate);
    }
    return null;
  }

  // ─── Movie or show ─────────────────────────────────────────────────────

  /// Whether a title can be turned from a movie into a show or back. A show
  /// can only become a movie while it has a single episode: several episodes
  /// are not versions of one film.
  Future<bool> canChangeKind(int itemId) async {
    final item = await (_db.select(_db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null) return false;
    if (item.kind == LibraryKinds.movie) return true;
    return item.kind == LibraryKinds.show && (await _repo.episodesOfShow(itemId)).length == 1;
  }

  /// Turns a movie into a show whose first episode holds its files, or a
  /// one-episode show into a movie. Returns the changed row.
  Future<LibraryItemRow> _changeKind(LibraryItemRow item) async {
    final items = _db.libraryItems;
    await _db.transaction(() async {
      if (item.kind == LibraryKinds.movie) {
        final now = _now();
        Future<int> child(String kind, String title, int parentId, {int? episode}) => _repo.insertItem(
          LibraryItemsCompanion.insert(
            kind: kind,
            libraryType: item.libraryType,
            title: title,
            sortTitle: LibraryRepository.sortTitleFor(title),
            parentId: Value(parentId),
            showId: Value(item.id),
            seasonNumber: const Value(1),
            episodeNumber: Value(episode),
            addedAt: now,
            updatedAt: now,
          ),
        );
        final season = await child(LibraryKinds.season, 'Season 1', item.id);
        final episode = await child(LibraryKinds.episode, 'Episode 1', season, episode: 1);
        await _moveFiles(item.id, episode);
        // Progress belongs to what is played: now the episode.
        await _repo.mergeUserState(item.id, episode);
        await _repo.updateItem(item.id, const LibraryItemsCompanion(kind: Value(LibraryKinds.show)));
      } else {
        for (final episode in await _repo.episodesOfShow(item.id)) {
          await _moveFiles(episode.item.id, item.id);
          await _repo.mergeUserState(episode.item.id, item.id);
        }
        await (_db.delete(items)..where((t) => t.showId.equals(item.id))).go();
        await _repo.updateItem(item.id, const LibraryItemsCompanion(kind: Value(LibraryKinds.movie)));
      }
    });
    return (_db.select(items)..where((t) => t.id.equals(item.id))).getSingle();
  }

  // ─── Manual matching ───────────────────────────────────────────────────

  /// Search results for the user to pick from when the automatic match was
  /// wrong or missing, from every source.
  Future<List<ScrapedCandidate>> searchCandidates({required String title, required bool asShow, int? year}) async {
    final results = <ScrapedCandidate>[];
    for (final provider in _metadataProviders) {
      results.addAll(
        asShow ? await provider.searchShow(title, year: year) : await provider.searchMovie(title, year: year),
      );
    }
    return results;
  }

  /// Applies the match the user chose and locks the title against rescans
  /// and automatic scraping. [asShow] says what the user searched for; the
  /// title is turned into that first when it was filed as the other kind.
  /// [libraryType] overrides the shelf the match's metadata calls for.
  Future<void> applyManualMatch(
    int itemId,
    ScrapedCandidate candidate, {
    required bool asShow,
    String? libraryType,
  }) async {
    var item = await (_db.select(_db.libraryItems)..where((t) => t.id.equals(itemId))).getSingle();
    if ((item.kind == LibraryKinds.show) != asShow && await canChangeKind(itemId)) item = await _changeKind(item);
    final provider = _metadataProviders.firstWhere((p) => p.source == candidate.source);
    final isShow = item.kind == LibraryKinds.show;
    final details = isShow ? await provider.show(candidate.id) : await provider.movie(candidate.id);
    await _apply(item, details, folder: await _folderOf(item), locked: true, libraryType: libraryType);
    if (isShow) await _fillSeasons(item, provider, candidate.id, details.title);
    await _setFilesState(item, LibraryMatchStates.matched, locked: true);
  }

  // ─── Matching ──────────────────────────────────────────────────────────

  Future<ScrapedCandidate?> _bestCandidate(
    MetadataProvider provider,
    LibraryItemRow item, {
    required bool isShow,
  }) async {
    Future<List<ScrapedCandidate>> search(int? year) =>
        isShow ? provider.searchShow(item.title, year: year) : provider.searchMovie(item.title, year: year);

    var candidates = await search(item.year);
    // A wrong year in the file name should not hide the right title.
    if (candidates.isEmpty && item.year != null) candidates = await search(null);

    ScrapedCandidate? best;
    var bestScore = 0.0;
    for (final (rank, candidate) in candidates.indexed) {
      // Providers already rank by relevance; break ties in their favour.
      final score = matchScore(item.title, item.year, candidate) - rank * 0.001;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= _acceptScore ? best : null;
  }

  /// How well [candidate] fits a title parsed from a file name, from 0 to
  /// about 1.15. Name similarity decides; the year confirms or vetoes.
  static double matchScore(String title, int? year, ScrapedCandidate candidate) {
    final wanted = _normalize(title);
    var similarity = 0.0;
    for (final name in [candidate.title, candidate.originalTitle]) {
      if (name == null) continue;
      final other = _normalize(name);
      if (other.isEmpty) continue;
      final score = other == wanted ? 1.0 : wanted.similarityTo(other);
      if (score > similarity) similarity = score;
    }
    if (year != null && candidate.year != null) {
      final gap = (year - candidate.year!).abs();
      // Release years drift by one between regions; more than that is a
      // different film with the same name.
      similarity += gap == 0 ? 0.15 : (gap == 1 ? 0.05 : -0.35);
    }
    return similarity;
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'''[\s\-_.:：,，!！?？'"“”‘’·•/\\()（）\[\]【】]+'''), '');

  Future<LibraryItemRow?> _existingWithIds(LibraryItemRow item, {String? tmdbId, String? bangumiId}) async {
    if (tmdbId == null && bangumiId == null) return null;
    final existing = await _repo.findByExternalId(
      kind: item.kind,
      tmdbId: tmdbId,
      bangumiId: tmdbId == null ? bangumiId : null,
    );
    return existing == null || existing.id == item.id ? null : existing;
  }

  // ─── Applying ──────────────────────────────────────────────────────────

  Future<void> _apply(
    LibraryItemRow item,
    ScrapedTitle details, {
    String? folder,
    bool locked = false,
    String? libraryType,
  }) async {
    final art = folder == null ? const <String, String>{} : await _localArt(item, folder);
    // The parsed name stays searchable after the title is replaced.
    final aliases = <String>{
      if (item.title.toLowerCase() != details.title.toLowerCase()) item.title,
      ...?item.aliases?.split('\n').where((a) => a.trim().isNotEmpty),
      ...details.aliases,
    };
    final title = details.title.isEmpty ? item.title : details.title;
    await _repo.updateItem(
      item.id,
      LibraryItemsCompanion(
        title: Value(title),
        sortTitle: Value(LibraryRepository.sortTitleFor(title)),
        originalTitle: Value(details.originalTitle),
        aliases: Value(aliases.isEmpty ? null : aliases.join('\n')),
        year: Value(details.year ?? item.year),
        releaseDate: Value(details.releaseDate),
        summary: Value(details.summary),
        tagline: Value(details.tagline),
        contentRating: Value(details.contentRating),
        studio: Value(details.studio),
        rating: Value(details.rating),
        runtimeMs: Value(details.runtimeMs),
        // Art beside the media is the user's own choice and wins.
        posterSource: Value(art['poster'] ?? details.posterSource),
        backdropSource: Value(art['backdrop'] ?? details.backdropSource),
        logoSource: Value(details.logoSource),
        tmdbId: Value(details.tmdbId),
        imdbId: Value(details.imdbId),
        tvdbId: Value(details.tvdbId),
        bangumiId: Value(details.bangumiId),
        metadataSource: Value(details.source),
        locked: locked ? const Value(true) : const Value.absent(),
        scrapedAt: Value(_now()),
      ),
    );
    await _repo.setGenres(item.id, details.genres);
    await _repo.setCredits(item.id, [
      for (final credit in details.credits)
        (
          name: credit.name,
          job: credit.job,
          character: credit.character,
          tmdbId: credit.tmdbId,
          photoSource: credit.photoUrl,
        ),
    ]);
    await _repo.setLibraryType(item.id, libraryType ?? await _shelfFor(item, details));
    if (details.collectionTitle case final String collectionTitle when item.kind == LibraryKinds.movie) {
      await _addToCollection(item.id, collectionTitle, details.collectionId);
    }
  }

  Future<void> _addToCollection(int itemId, String title, String? tmdbId) async {
    final lists = _db.libraryLists;
    final existing =
        await (_db.select(lists)
              ..where(
                (t) =>
                    t.kind.equals(LibraryListKinds.collection) &
                    (tmdbId != null ? t.tmdbId.equals(tmdbId) : t.title.equals(title)),
              )
              ..limit(1))
            .getSingleOrNull();
    final listId =
        existing?.id ?? await _repo.createList(kind: LibraryListKinds.collection, title: title, tmdbId: tmdbId);
    await _repo.addToList(listId, itemId);
  }

  /// Season and episode details for every season the library has files for.
  Future<void> _fillSeasons(LibraryItemRow show, MetadataProvider provider, String showId, String showTitle) async {
    for (final seasonView in await _repo.children(show.id)) {
      final seasonRow = seasonView.item;
      final number = seasonRow.seasonNumber;
      if (number == null) continue;

      var season = await provider.season(showId, number);
      if (season == null && provider.source == 'bangumi' && number > 1) {
        // Bangumi files each season as its own subject.
        final sequel = (await provider.searchShow('$showTitle 第$number季')).firstOrNull;
        if (sequel != null) season = await provider.season(sequel.id, 1);
      }
      if (season == null) continue;

      await _repo.updateItem(
        seasonRow.id,
        LibraryItemsCompanion(
          title: season.title == null ? const Value.absent() : Value(season.title!),
          summary: Value(season.summary),
          posterSource: Value(season.posterSource),
          metadataSource: Value(provider.source),
          scrapedAt: Value(_now()),
        ),
      );
      final byNumber = {for (final episode in season.episodes) episode.number: episode};
      for (final episodeView in await _repo.children(seasonRow.id)) {
        final scraped = byNumber[episodeView.item.episodeNumber];
        if (scraped != null) await _applyEpisode(episodeView.item, scraped, provider.source);
      }
    }
  }

  Future<void> _applyEpisode(LibraryItemRow episode, ScrapedEpisode scraped, String source) async {
    await _repo.updateItem(
      episode.id,
      LibraryItemsCompanion(
        title: scraped.title == null ? const Value.absent() : Value(scraped.title!),
        sortTitle: scraped.title == null ? const Value.absent() : Value(LibraryRepository.sortTitleFor(scraped.title!)),
        summary: Value(scraped.summary),
        releaseDate: Value(scraped.airDate),
        runtimeMs: Value(scraped.runtimeMs),
        rating: Value(scraped.rating),
        posterSource: Value(scraped.stillSource),
        metadataSource: Value(source),
        scrapedAt: Value(_now()),
      ),
    );
  }

  // ─── Files beside the media ────────────────────────────────────────────

  /// The folder that represents a title on disk: a movie's own folder, or
  /// the show folder above its season folders. Null when the title has no
  /// files, or when a movie shares its folder with other titles.
  Future<String?> _folderOf(LibraryItemRow item) async {
    final files = _db.libraryFiles;
    if (item.kind == LibraryKinds.movie) {
      final video =
          await (_db.select(files)
                ..where((t) => t.itemId.equals(item.id) & t.role.equals(LibraryFileRoles.video))
                ..limit(1))
              .getSingleOrNull();
      return video == null ? null : '${video.mountId}\u0000${StoragePath.parent(video.path)}';
    }
    final items = _db.libraryItems;
    final video =
        await (_db.select(files).join([innerJoin(items, items.id.equalsExp(files.itemId))])
              ..where(items.showId.equals(item.id) & files.role.equals(LibraryFileRoles.video))
              ..limit(1))
            .map((row) => row.readTable(files))
            .getSingleOrNull();
    if (video == null) return null;
    // Walk up to the folder holding tvshow.nfo, at most two levels: the
    // episode may sit in the show folder or in a season folder inside it.
    var directory = StoragePath.parent(video.path);
    for (var level = 0; level < 2; level++) {
      if (await _hasFile(video.mountId, StoragePath.join(directory, 'tvshow.nfo'))) break;
      final parent = StoragePath.parent(directory);
      if (level == 0 && parent != StoragePath.root && _looksLikeSeasonFolder(StoragePath.name(directory))) {
        directory = parent;
      } else {
        break;
      }
    }
    return '${video.mountId}\u0000$directory';
  }

  static bool _looksLikeSeasonFolder(String name) => RegExp(
    r'^\s*(season|series|s)[\s._-]*\d+\s*$|^\s*第.+季\s*$|^\s*specials?\s*$',
    caseSensitive: false,
  ).hasMatch(name);

  Future<bool> _hasFile(String mountId, String path) async {
    final files = _db.libraryFiles;
    final row =
        await (_db.select(files)
              ..where((t) => t.mountId.equals(mountId) & t.path.equals(path))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<List<LibraryFileRow>> _filesIn(String mountId, String directory, String role) async {
    final files = _db.libraryFiles;
    final prefix = directory == StoragePath.root ? '/' : '$directory/';
    final rows = await (_db.select(files)..where((t) => t.mountId.equals(mountId) & t.role.equals(role))).get();
    return rows.where((f) => f.path.startsWith(prefix) && !f.path.substring(prefix.length).contains('/')).toList();
  }

  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// Poster and backdrop images lying next to the media, as `mount:` sources.
  Future<Map<String, String>> _localArt(LibraryItemRow item, String folder) async {
    final [mountId, directory] = folder.split('\u0000');
    final images = await _filesIn(mountId, directory, LibraryFileRoles.artwork);
    if (images.isEmpty) return const {};

    // A movie sharing its folder with others only owns art named after it.
    final videoBases = item.kind == LibraryKinds.movie
        ? [for (final video in await _repo.versionsOf(item.id)) _baseName(StoragePath.name(video.path)).toLowerCase()]
        : const <String>[];
    final videosInFolder = (await _filesIn(mountId, directory, LibraryFileRoles.video)).length;
    final ownsFolder = item.kind == LibraryKinds.show || videosInFolder == videoBases.length;

    String? find(List<String> names) {
      for (final image in images) {
        final base = _baseName(StoragePath.name(image.path)).toLowerCase();
        final suffixed = videoBases.any((video) => names.any((n) => base == '$video-$n'));
        if (suffixed || (ownsFolder && names.contains(base))) return _mountSource(mountId, image.path);
      }
      return null;
    }

    return {'poster': ?find(_posterNames), 'backdrop': ?find(_backdropNames)};
  }

  // ─── Files and merging ─────────────────────────────────────────────────

  Future<List<int>> _leafIds(LibraryItemRow item) async {
    if (item.kind != LibraryKinds.show) return [item.id];
    return [for (final episode in await _repo.episodesOfShow(item.id)) episode.item.id];
  }

  Future<void> _setFilesState(LibraryItemRow item, String state, {bool locked = false}) async {
    final leaves = await _leafIds(item);
    if (leaves.isEmpty) return;
    await (_db.update(_db.libraryFiles)..where(
          (t) =>
              t.itemId.isIn(leaves) &
              t.role.equals(LibraryFileRoles.video) &
              // A lookup that found nothing must not undo a manual match.
              (locked ? const Constant(true) : t.matchLocked.equals(false)),
        ))
        .write(
          LibraryFilesCompanion(
            matchState: Value(state),
            matchLocked: locked ? const Value(true) : const Value.absent(),
          ),
        );
  }

  /// Folds [duplicate] into [target]: two file names that turned out to be
  /// the same title. Files move over; for shows, seasons and episodes are
  /// re-parented or merged by number.
  Future<ScrapeOutcome> _mergeInto(LibraryItemRow duplicate, LibraryItemRow target) async {
    await _db.transaction(() async {
      if (duplicate.kind == LibraryKinds.movie) {
        await _moveFiles(duplicate.id, target.id);
        await _repo.mergeUserState(duplicate.id, target.id);
      } else {
        await _repo.mergeUserState(duplicate.id, target.id);
        for (final seasonView in await _repo.children(duplicate.id)) {
          final season = seasonView.item;
          final targetSeason = await _repo.findChild(target.id, seasonNumber: season.seasonNumber);
          if (targetSeason == null) {
            await (_db.update(_db.libraryItems)..where((t) => t.id.equals(season.id))).write(
              LibraryItemsCompanion(parentId: Value(target.id), showId: Value(target.id)),
            );
            await (_db.update(
              _db.libraryItems,
            )..where((t) => t.parentId.equals(season.id))).write(LibraryItemsCompanion(showId: Value(target.id)));
            continue;
          }
          for (final episodeView in await _repo.children(season.id)) {
            final episode = episodeView.item;
            final targetEpisode = await _repo.findChild(targetSeason.id, episodeNumber: episode.episodeNumber);
            if (targetEpisode == null) {
              await (_db.update(_db.libraryItems)..where((t) => t.id.equals(episode.id))).write(
                LibraryItemsCompanion(parentId: Value(targetSeason.id), showId: Value(target.id)),
              );
            } else {
              await _moveFiles(episode.id, targetEpisode.id);
              await _repo.mergeUserState(episode.id, targetEpisode.id);
            }
          }
        }
      }
      // The duplicate's name is how its files will be recognised next scan.
      final aliases = <String>{
        ...?target.aliases?.split('\n').where((a) => a.trim().isNotEmpty),
        if (duplicate.title.toLowerCase() != target.title.toLowerCase()) duplicate.title,
      };
      await _repo.updateItem(
        target.id,
        LibraryItemsCompanion(aliases: Value(aliases.isEmpty ? null : aliases.join('\n'))),
      );
      await _repo.deleteItem(duplicate.id);
    });
    await _repo.pruneEmptyTitles();
    // What moved over was still unplaced; it belongs where the target is.
    await _repo.setLibraryType(target.id, target.libraryType);
    final merged = await (_db.select(_db.libraryItems)..where((t) => t.id.equals(target.id))).getSingle();
    await _setFilesState(merged, LibraryMatchStates.matched);
    return ScrapeOutcome.merged;
  }

  Future<void> _moveFiles(int fromItemId, int toItemId) async {
    await (_db.update(
      _db.libraryFiles,
    )..where((t) => t.itemId.equals(fromItemId))).write(LibraryFilesCompanion(itemId: Value(toItemId)));
  }
}

/// What scraping one title came to.
enum ScrapeOutcome { matched, merged, unmatched, skipped }
