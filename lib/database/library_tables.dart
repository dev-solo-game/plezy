import 'package:drift/drift.dart';

import 'tables.dart';

// The local media library. Everything here is derived from scanning mounts
// and scraping metadata, except [LibraryUserStates] and the rows flagged as
// locked, which hold what the user did and must survive a rescan.

/// Titles in the library: movies, shows, seasons and episodes in one table.
///
/// Seasons point at their show through [parentId]; episodes point at their
/// season through [parentId] and at the show through [showId] so "all
/// episodes of a show" needs no join.
@DataClassName('LibraryItemRow')
@TableIndex(name: 'idx_library_items_kind_type', columns: {#kind, #libraryType})
@TableIndex(name: 'idx_library_items_parent', columns: {#parentId})
@TableIndex(name: 'idx_library_items_show', columns: {#showId})
@TableIndex(name: 'idx_library_items_tmdb', columns: {#kind, #tmdbId})
@TableIndex(name: 'idx_library_items_added', columns: {#addedAt})
class LibraryItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// `'movie'`, `'show'`, `'season'` or `'episode'`.
  TextColumn get kind => text()();

  /// Which library the title is shelved in: `'movie'`, `'show'` or `'anime'`.
  /// Children carry their show's value.
  TextColumn get libraryType => text()();

  IntColumn get parentId => integer().nullable().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get showId => integer().nullable().references(LibraryItems, #id, onDelete: KeyAction.cascade)();

  TextColumn get title => text()();

  /// Lower-cased title with leading articles removed, for ordering.
  TextColumn get sortTitle => text()();
  TextColumn get originalTitle => text().nullable()();

  /// Other names the title is known by, newline-separated, for search.
  TextColumn get aliases => text().nullable()();

  IntColumn get year => integer().nullable()();

  /// First release or air date as `YYYY-MM-DD`.
  TextColumn get releaseDate => text().nullable()();
  TextColumn get summary => text().nullable()();
  TextColumn get tagline => text().nullable()();
  TextColumn get contentRating => text().nullable()();
  TextColumn get studio => text().nullable()();

  /// Community score on a 0–10 scale.
  RealColumn get rating => real().nullable()();
  IntColumn get runtimeMs => integer().nullable()();

  /// Season number for seasons and episodes; 0 is specials.
  IntColumn get seasonNumber => integer().nullable()();
  IntColumn get episodeNumber => integer().nullable()();

  /// Running episode count across seasons, as anime releases number them.
  IntColumn get absoluteNumber => integer().nullable()();

  /// Artwork sources: a remote URL, or `mount:<mountId>:<path>` for an image
  /// found next to the media.
  TextColumn get posterSource => text().nullable()();
  TextColumn get backdropSource => text().nullable()();
  TextColumn get logoSource => text().nullable()();

  TextColumn get tmdbId => text().nullable()();
  TextColumn get imdbId => text().nullable()();
  TextColumn get tvdbId => text().nullable()();
  TextColumn get bangumiId => text().nullable()();
  TextColumn get doubanId => text().nullable()();

  /// Which scraper filled this row: `'nfo'`, `'tmdb'`, `'bangumi'`, …
  /// Null while the row only holds what the file name gave away.
  TextColumn get metadataSource => text().nullable()();

  /// True once the user matched or edited the title by hand; scrapers and
  /// rescans then leave it alone.
  BoolColumn get locked => boolean().withDefault(const Constant(false))();

  IntColumn get addedAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get scrapedAt => integer().nullable()();
}

/// Files found on mounts: videos, and the subtitles, artwork and NFO files
/// that travel with them.
///
/// A movie or episode with several versions has several video rows pointing
/// at the same [itemId].
@DataClassName('LibraryFileRow')
@TableIndex(name: 'idx_library_files_mount_path', columns: {#mountId, #path}, unique: true)
@TableIndex(name: 'idx_library_files_item', columns: {#itemId})
@TableIndex(name: 'idx_library_files_match', columns: {#role, #matchState})
@TableIndex(name: 'idx_library_files_owner', columns: {#ownerFileId})
class LibraryFiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get mountId => text().references(Mounts, #id, onDelete: KeyAction.cascade)();

  /// Mount-relative path, normalized (`/Movies/Film (2020)/film.mkv`).
  TextColumn get path => text()();

  /// The driver's own id for the file, when it has one.
  TextColumn get remoteId => text().nullable()();
  IntColumn get size => integer().nullable()();
  IntColumn get modifiedAt => integer().nullable()();

  /// `'video'`, `'subtitle'`, `'artwork'` or `'nfo'`.
  TextColumn get role => text()();

  /// The movie or episode a video belongs to. Null until matched.
  IntColumn get itemId => integer().nullable().references(LibraryItems, #id, onDelete: KeyAction.setNull)();

  /// For subtitles: the video they accompany.
  IntColumn get ownerFileId => integer().nullable().references(LibraryFiles, #id, onDelete: KeyAction.cascade)();

  /// Videos only: `'pending'` (not looked up yet), `'matched'`,
  /// `'unmatched'` (lookup found nothing) or `'ignored'` (samples, extras).
  TextColumn get matchState => text().withDefault(const Constant('pending'))();

  /// True once the user chose the match by hand; rescans keep it.
  BoolColumn get matchLocked => boolean().withDefault(const Constant(false))();

  /// What the file name parser extracted, as JSON: guessed title, year,
  /// season, episode, resolution, source, release group…
  TextColumn get parsed => text().nullable()();

  /// What sets this version apart when an item has several: `'4K'`,
  /// `"Director's Cut"`…
  TextColumn get versionLabel => text().nullable()();

  /// Subtitles only: language tag taken from the file name.
  TextColumn get language => text().nullable()();

  // Probed lazily from the file itself; null until then.
  IntColumn get durationMs => integer().nullable()();
  TextColumn get container => text().nullable()();
  TextColumn get videoCodec => text().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  TextColumn get hdrFormat => text().nullable()();

  /// Audio and embedded subtitle tracks as JSON.
  TextColumn get streams => text().nullable()();
  IntColumn get probedAt => integer().nullable()();

  /// Id of the last scan run that saw this file. Rows a finished scan did
  /// not touch are gone from the mount.
  IntColumn get seenInScan => integer().withDefault(const Constant(0))();
  IntColumn get addedAt => integer()();
}

/// Progress, watched state and favorites, per playable or browsable title.
@DataClassName('LibraryUserStateRow')
@TableIndex(name: 'idx_library_user_states_played', columns: {#lastPlayedAt})
class LibraryUserStates extends Table {
  IntColumn get itemId => integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionMs => integer().withDefault(const Constant(0))();
  IntColumn get durationMs => integer().nullable()();
  BoolColumn get watched => boolean().withDefault(const Constant(false))();
  IntColumn get playCount => integer().withDefault(const Constant(0))();
  IntColumn get lastPlayedAt => integer().nullable()();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  /// Hidden from Continue Watching without touching progress.
  BoolColumn get hiddenFromContinue => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {itemId};
}

@DataClassName('LibraryGenreRow')
class LibraryGenres extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

@DataClassName('LibraryItemGenreRow')
@TableIndex(name: 'idx_library_item_genres_genre', columns: {#genreId})
class LibraryItemGenres extends Table {
  IntColumn get itemId => integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get genreId => integer().references(LibraryGenres, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {itemId, genreId};
}

@DataClassName('LibraryPersonRow')
@TableIndex(name: 'idx_library_people_tmdb', columns: {#tmdbId})
class LibraryPeople extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get tmdbId => text().nullable()();
  TextColumn get photoSource => text().nullable()();
}

/// Cast and crew of a title.
@DataClassName('LibraryCreditRow')
@TableIndex(name: 'idx_library_credits_person', columns: {#personId})
class LibraryCredits extends Table {
  IntColumn get itemId => integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get personId => integer().references(LibraryPeople, #id, onDelete: KeyAction.cascade)();

  /// `'actor'`, `'director'` or `'writer'`.
  TextColumn get job => text()();

  /// The character played, for actors.
  TextColumn get character => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {itemId, personId, job};
}

/// Collections (film series from the scraper, or made by the user) and
/// playlists. They differ only in [kind].
@DataClassName('LibraryListRow')
class LibraryLists extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// `'collection'` or `'playlist'`.
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get summary => text().nullable()();
  TextColumn get posterSource => text().nullable()();

  /// TMDB collection id when the scraper created it; null for the user's own.
  TextColumn get tmdbId => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

@DataClassName('LibraryListItemRow')
@TableIndex(name: 'idx_library_list_items_item', columns: {#itemId})
class LibraryListItems extends Table {
  IntColumn get listId => integer().references(LibraryLists, #id, onDelete: KeyAction.cascade)();
  IntColumn get itemId => integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {listId, itemId};
}

/// Where each mount's scanner is, so a scan can resume and the UI can show
/// when a mount was last looked at.
@DataClassName('LibraryScanStateRow')
class LibraryScanStates extends Table {
  TextColumn get mountId => text().references(Mounts, #id, onDelete: KeyAction.cascade)();

  /// Incremented each time a scan starts; stamped on the files it sees.
  IntColumn get scanId => integer().withDefault(const Constant(0))();

  /// `'idle'`, `'running'` or `'failed'`.
  TextColumn get status => text().withDefault(const Constant('idle'))();

  /// Directories still to visit, as a JSON array, while a scan is running.
  TextColumn get pending => text().nullable()();
  IntColumn get startedAt => integer().nullable()();
  IntColumn get finishedAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {mountId};
}
