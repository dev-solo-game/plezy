import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_mount.dart';
import '../storage/storage_path.dart';
import '../utils/app_logger.dart';
import 'library_repository.dart';
import 'media_classifier.dart';
import 'media_name_parser.dart';

/// Lets a running scan be stopped between directories.
class ScanCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class ScanProgress {
  const ScanProgress({required this.directoriesDone, required this.filesSeen, required this.currentPath});

  final int directoriesDone;
  final int filesSeen;
  final String currentPath;
}

class ScanResult {
  const ScanResult({required this.videos, required this.removed, required this.cancelled});

  /// Videos seen by this run.
  final int videos;

  /// Files dropped because the mount no longer has them.
  final int removed;

  /// True when the run was stopped early. Its position is saved and the next
  /// scan of the mount resumes from it.
  final bool cancelled;
}

/// Walks a mount, records what it finds in the library tables, and files each
/// video under a provisional title derived from its name. It only ever lists
/// directories: no file is opened. Titles it creates wait as
/// [LibraryTypes.pending] for the scraper to identify them and pick a shelf.
///
/// A scan is incremental — unchanged files keep their rows, matches and
/// probed info — and resumable: the directories still to visit are saved
/// after every directory, so a cancelled or failed run continues where it
/// stopped instead of listing the whole mount again.
class LibraryScanner {
  LibraryScanner(this._db, this._repo);

  final AppDatabase _db;
  final LibraryRepository _repo;

  static const Set<String> videoExtensions = {
    'mkv', 'mp4', 'm4v', 'mov', 'avi', 'wmv', 'flv', 'f4v', 'webm', 'ts', 'm2ts', 'mts', 'mpg', 'mpeg', 'rmvb', //
    'rm', '3gp', 'ogv',
  };
  static const Set<String> subtitleExtensions = {'srt', 'ass', 'ssa', 'vtt', 'sub', 'sup', 'smi'};
  static const Set<String> imageExtensions = {'jpg', 'jpeg', 'png', 'webp'};

  /// Folders that never hold library content: system folders, disc
  /// structures, and the extras that ship beside a film.
  static const Set<String> _skippedFolders = {
    '@eadir', '#recycle', r'$recycle.bin', 'system volume information', 'lost+found', '.trash', //
    'bdmv', 'certificate', 'video_ts',
    'extras', 'extra', 'featurettes', 'behind the scenes', 'deleted scenes', 'interviews', 'trailers', 'samples',
    'sample', 'screens', 'screenshots', 'proof', '花絮', '特典', '预告', '預告', '样片', '樣片',
  };

  static final RegExp _sampleName = RegExp(
    r'(^|[\s._\-\[(])(sample|trailer|teaser|preview)([\s._\-\])]|$)|[-.](trailer|sample)$',
    caseSensitive: false,
  );

  static int _now() => clock.now().millisecondsSinceEpoch;

  Future<ScanResult> scan(
    StorageMount mount,
    StorageDriver driver, {
    ScanCancelToken? cancel,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final run = await _begin(mount.id);
    final queue = run.queue;
    var directoriesDone = 0;
    var filesSeen = 0;
    var videos = 0;

    try {
      while (queue.isNotEmpty) {
        if (cancel?.isCancelled ?? false) {
          // Left as "running" with its queue so the next scan resumes.
          return ScanResult(videos: videos, removed: 0, cancelled: true);
        }
        final directory = queue.removeLast();
        onProgress?.call(
          ScanProgress(directoriesDone: directoriesDone, filesSeen: filesSeen, currentPath: directory.path),
        );

        final List<StorageEntry> entries;
        try {
          entries = await driver.list(directory.path, parent: directory.id == null ? null : directory);
        } on StorageException catch (e) {
          if (e.kind == StorageErrorKind.notFound) {
            // Deleted between listing its parent and getting here.
            await _saveQueue(mount.id, queue);
            continue;
          }
          queue.add(directory);
          rethrow;
        }

        for (final entry in entries) {
          if (entry.isDirectory && !_isSkippedFolder(entry.name)) queue.add(entry);
        }
        final files = entries.where((e) => !e.isDirectory).toList();
        videos += await _recordDirectory(mount, directory.path, files, run.scanId);
        filesSeen += files.length;
        directoriesDone++;
        await _saveQueue(mount.id, queue);
      }
    } on Object catch (e) {
      await _saveQueue(mount.id, queue);
      await (_db.update(_db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).write(
        LibraryScanStatesCompanion(
          status: const Value('failed'),
          lastError: Value(e is StorageException ? e.message : '$e'),
        ),
      );
      rethrow;
    }

    final removed = await _repo.removeFilesNotSeen(mount.id, run.scanId);
    // Re-filed videos can leave their old titles empty even when no file went.
    await _repo.pruneEmptyTitles();
    await (_db.update(_db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).write(
      LibraryScanStatesCompanion(
        status: const Value('idle'),
        pending: const Value(null),
        finishedAt: Value(_now()),
        lastError: const Value(null),
      ),
    );
    return ScanResult(videos: videos, removed: removed, cancelled: false);
  }

  // ─── Run bookkeeping ───────────────────────────────────────────────────

  Future<({int scanId, List<StorageEntry> queue})> _begin(String mountId) async {
    final states = _db.libraryScanStates;
    final state = await (_db.select(states)..where((t) => t.mountId.equals(mountId))).getSingleOrNull();

    // An interrupted run left its queue behind: pick it up under the same
    // scan id, so files it already stamped still count as seen.
    if (state != null && state.status != 'idle' && state.pending != null) {
      final queue = _decodeQueue(state.pending!);
      if (queue.isNotEmpty) {
        await (_db.update(states)..where((t) => t.mountId.equals(mountId))).write(
          const LibraryScanStatesCompanion(status: Value('running'), lastError: Value(null)),
        );
        return (scanId: state.scanId, queue: queue);
      }
    }

    final scanId = (state?.scanId ?? 0) + 1;
    final queue = [const StorageEntry(path: StoragePath.root, name: '', isDirectory: true)];
    await _db
        .into(states)
        .insertOnConflictUpdate(
          LibraryScanStatesCompanion.insert(
            mountId: mountId,
            scanId: Value(scanId),
            status: const Value('running'),
            pending: Value(_encodeQueue(queue)),
            startedAt: Value(_now()),
            finishedAt: Value(state?.finishedAt),
            lastError: const Value(null),
          ),
        );
    return (scanId: scanId, queue: queue);
  }

  Future<void> _saveQueue(String mountId, List<StorageEntry> queue) async {
    await (_db.update(
      _db.libraryScanStates,
    )..where((t) => t.mountId.equals(mountId))).write(LibraryScanStatesCompanion(pending: Value(_encodeQueue(queue))));
  }

  static String _encodeQueue(List<StorageEntry> queue) {
    return jsonEncode([
      for (final entry in queue) {'p': entry.path, 'i': ?entry.id},
    ]);
  }

  static List<StorageEntry> _decodeQueue(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map && item['p'] is String)
            StorageEntry(
              path: item['p'] as String,
              name: StoragePath.name(item['p'] as String),
              isDirectory: true,
              id: item['i'] is String ? item['i'] as String : null,
            ),
      ];
    } on FormatException {
      return [];
    }
  }

  // ─── One directory ─────────────────────────────────────────────────────

  static bool _isSkippedFolder(String name) => name.startsWith('.') || _skippedFolders.contains(name.toLowerCase());

  /// Records the files of one directory. Returns how many were videos.
  Future<int> _recordDirectory(StorageMount mount, String directory, List<StorageEntry> files, int scanId) async {
    final videos = <StorageEntry>[];
    final subtitles = <StorageEntry>[];
    final others = <(StorageEntry, String)>[];
    for (final file in files) {
      final extension = StoragePath.extension(file.name);
      if (videoExtensions.contains(extension)) {
        if (!_sampleName.hasMatch(_baseName(file.name))) videos.add(file);
      } else if (subtitleExtensions.contains(extension)) {
        subtitles.add(file);
      } else if (extension == 'nfo') {
        others.add((file, LibraryFileRoles.nfo));
      } else if (imageExtensions.contains(extension)) {
        others.add((file, LibraryFileRoles.artwork));
      }
    }
    if (videos.isEmpty && subtitles.isEmpty && others.isEmpty) return 0;

    final folders = [
      for (final segment in StoragePath.segments(directory).reversed.take(3)) MediaNameParser.parseFolder(segment),
    ];
    final parsed = {for (final video in videos) video.path: MediaNameParser.parseFile(video.name)};
    final numbered = parsed.values.where((p) => p.episode != null || p.looseEpisode != null).length;

    await _db.transaction(() async {
      final videoIds = <String, int>{};
      for (final video in videos) {
        final name = parsed[video.path]!;
        final classified = MediaClassifier.classify(file: name, folders: folders, numberedSiblings: numbered);
        final previous = await _fileAt(mount.id, video.path);
        final id = await _repo.upsertFile(
          mountId: mount.id,
          path: video.path,
          role: LibraryFileRoles.video,
          scanId: scanId,
          remoteId: video.id,
          size: video.size,
          modifiedAt: video.modifiedAt?.millisecondsSinceEpoch,
          parsed: jsonEncode({...name.toJson(), 'key': classified.key}),
          versionLabel: classified.versionLabel,
        );
        videoIds[video.path] = id;
        await _file(id, previous, classified);
      }

      for (final subtitle in subtitles) {
        final owner = _ownerOf(subtitle, videos);
        if (owner == null) continue;
        await _repo.upsertFile(
          mountId: mount.id,
          path: subtitle.path,
          role: LibraryFileRoles.subtitle,
          scanId: scanId,
          remoteId: subtitle.id,
          size: subtitle.size,
          modifiedAt: subtitle.modifiedAt?.millisecondsSinceEpoch,
          ownerFileId: videoIds[owner.path],
          language: _subtitleLanguage(subtitle, owner),
        );
      }

      for (final (file, role) in others) {
        await _repo.upsertFile(
          mountId: mount.id,
          path: file.path,
          role: role,
          scanId: scanId,
          remoteId: file.id,
          size: file.size,
          modifiedAt: file.modifiedAt?.millisecondsSinceEpoch,
        );
      }
    });
    return videos.length;
  }

  /// Bumped whenever parsing or classification changes in a way that files
  /// already in the library should be re-filed under.
  static const int namingVersion = 1;

  /// Re-files every video of [mountId] from the paths already in the
  /// database, without listing the mount: for when the naming rules changed.
  /// Files whose classification is unchanged, and files the user matched by
  /// hand, stay where they are. Returns how many files moved.
  Future<int> refileFromNames(String mountId) async {
    final rows = await (_db.select(
      _db.libraryFiles,
    )..where((t) => t.mountId.equals(mountId) & t.role.equals(LibraryFileRoles.video))).get();
    final byDirectory = <String, List<LibraryFileRow>>{};
    for (final row in rows) {
      byDirectory.putIfAbsent(StoragePath.parent(row.path), () => []).add(row);
    }

    var moved = 0;
    for (final MapEntry(key: directory, value: files) in byDirectory.entries) {
      final folders = [
        for (final segment in StoragePath.segments(directory).reversed.take(3)) MediaNameParser.parseFolder(segment),
      ];
      final parsed = {for (final file in files) file.id: MediaNameParser.parseFile(StoragePath.name(file.path))};
      final numbered = parsed.values.where((p) => p.episode != null || p.looseEpisode != null).length;
      await _db.transaction(() async {
        for (final file in files) {
          if (file.matchLocked) continue;
          final name = parsed[file.id]!;
          final classified = MediaClassifier.classify(file: name, folders: folders, numberedSiblings: numbered);
          if (_keyOf(file.parsed) == classified.key) continue;
          await _repo.updateFile(
            file.id,
            LibraryFilesCompanion(
              parsed: Value(jsonEncode({...name.toJson(), 'key': classified.key})),
              versionLabel: Value(classified.versionLabel),
            ),
          );
          await _file(file.id, file, classified);
          moved++;
        }
      });
    }
    if (moved > 0) await _repo.pruneEmptyTitles();
    return moved;
  }

  Future<LibraryFileRow?> _fileAt(String mountId, String path) {
    return (_db.select(
      _db.libraryFiles,
    )..where((t) => t.mountId.equals(mountId) & t.path.equals(path))).getSingleOrNull();
  }

  /// Files a video under the title its name points at.
  ///
  /// A video that is already filed is left alone unless its classification
  /// changed (renamed or moved) — and never when the user chose its match by
  /// hand.
  Future<void> _file(int fileId, LibraryFileRow? previous, ClassifiedVideo classified) async {
    if (previous != null) {
      if (previous.matchLocked) return;
      if (previous.itemId != null && _keyOf(previous.parsed) == classified.key) return;
    }

    if (!classified.isKnown) {
      await _repo.updateFile(
        fileId,
        const LibraryFilesCompanion(itemId: Value(null), matchState: Value(LibraryMatchStates.unmatched)),
      );
      return;
    }

    final itemId = classified.kind == LibraryKinds.movie ? await _movieFor(classified) : await _episodeFor(classified);
    await _repo.updateFile(
      fileId,
      LibraryFilesCompanion(
        itemId: Value(itemId),
        // Filed by name only; the scraper still has to confirm it.
        matchState: const Value(LibraryMatchStates.pending),
      ),
    );
  }

  static String? _keyOf(String? parsedJson) {
    if (parsedJson == null) return null;
    try {
      final decoded = jsonDecode(parsedJson);
      return decoded is Map && decoded['key'] is String ? decoded['key'] as String : null;
    } on FormatException {
      return null;
    }
  }

  Future<int> _movieFor(ClassifiedVideo video) async {
    final existing = await _repo.findTitleByName(kind: LibraryKinds.movie, name: video.title!, year: video.year);
    if (existing != null) return existing.id;
    return _insert(kind: LibraryKinds.movie, libraryType: LibraryTypes.pending, title: video.title!, year: video.year);
  }

  Future<int> _episodeFor(ClassifiedVideo video) async {
    final known = await _repo.findTitleByName(kind: LibraryKinds.show, name: video.title!, year: video.year);
    // New seasons and episodes join the show on the shelf it already has.
    final libraryType = known?.libraryType ?? LibraryTypes.pending;
    final show =
        known?.id ??
        await _insert(kind: LibraryKinds.show, libraryType: libraryType, title: video.title!, year: video.year);

    final seasonNumber = video.season!;
    final season =
        (await _repo.findChild(show, seasonNumber: seasonNumber))?.id ??
        await _insert(
          kind: LibraryKinds.season,
          libraryType: libraryType,
          // Placeholder names; the UI localizes seasons from their number.
          title: seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber',
          parentId: show,
          showId: show,
          season: seasonNumber,
        );

    final episodeNumber = video.episode!;
    return (await _repo.findChild(season, episodeNumber: episodeNumber))?.id ??
        await _insert(
          kind: LibraryKinds.episode,
          libraryType: libraryType,
          title: 'Episode $episodeNumber',
          parentId: season,
          showId: show,
          season: seasonNumber,
          episode: episodeNumber,
        );
  }

  Future<int> _insert({
    required String kind,
    required String libraryType,
    required String title,
    int? year,
    int? parentId,
    int? showId,
    int? season,
    int? episode,
  }) {
    final now = _now();
    return _repo.insertItem(
      LibraryItemsCompanion.insert(
        kind: kind,
        libraryType: libraryType,
        title: title,
        sortTitle: LibraryRepository.sortTitleFor(title),
        year: Value(year),
        parentId: Value(parentId),
        showId: Value(showId),
        seasonNumber: Value(season),
        episodeNumber: Value(episode),
        addedAt: now,
        updatedAt: now,
      ),
    );
  }

  // ─── Subtitles ─────────────────────────────────────────────────────────

  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// The video a subtitle accompanies: the one whose base name the
  /// subtitle's starts with (longest wins), or the only video in the folder.
  static StorageEntry? _ownerOf(StorageEntry subtitle, List<StorageEntry> videos) {
    final base = _baseName(subtitle.name).toLowerCase();
    StorageEntry? best;
    var bestLength = -1;
    for (final video in videos) {
      final videoBase = _baseName(video.name).toLowerCase();
      if (base == videoBase || base.startsWith('$videoBase.') || base.startsWith('$videoBase-')) {
        if (videoBase.length > bestLength) {
          best = video;
          bestLength = videoBase.length;
        }
      }
    }
    return best ?? (videos.length == 1 ? videos.single : null);
  }

  static const Map<String, String> _languageTags = {
    'chs': 'zh-Hans', 'sc': 'zh-Hans', 'gb': 'zh-Hans', 'zh-cn': 'zh-Hans', 'zh-hans': 'zh-Hans', 'zhs': 'zh-Hans', //
    '简体': 'zh-Hans', '简中': 'zh-Hans', '简': 'zh-Hans',
    'cht': 'zh-Hant', 'tc': 'zh-Hant', 'big5': 'zh-Hant', 'zh-tw': 'zh-Hant', 'zh-hk': 'zh-Hant', 'zh-hant': 'zh-Hant',
    'zht': 'zh-Hant', '繁体': 'zh-Hant', '繁體': 'zh-Hant', '繁中': 'zh-Hant', '繁': 'zh-Hant',
    'zh': 'zh', 'chi': 'zh', 'zho': 'zh', 'chinese': 'zh', '中文': 'zh', '中字': 'zh',
    'en': 'en', 'eng': 'en', 'english': 'en', '英文': 'en',
    'ja': 'ja', 'jp': 'ja', 'jpn': 'ja', 'japanese': 'ja', '日文': 'ja', '日语': 'ja', '日語': 'ja',
    'ko': 'ko', 'kor': 'ko', 'korean': 'ko', '韩文': 'ko', '韓文': 'ko',
  };

  /// Language tag from what follows the video's name in the subtitle's:
  /// `film.zh.srt`, `film.chs&eng.ass`. The first recognised tag wins.
  static String? _subtitleLanguage(StorageEntry subtitle, StorageEntry owner) {
    final base = _baseName(subtitle.name).toLowerCase();
    final videoBase = _baseName(owner.name).toLowerCase();
    final suffix = base.startsWith(videoBase) ? base.substring(videoBase.length) : base;
    for (final token in suffix.split(RegExp(r'[.\s_\[\]()&+]+'))) {
      final language = _languageTags[token];
      if (language != null) return language;
    }
    // Hyphenated tags ("zh-cn") were kept whole above; try their parts last.
    for (final token in suffix.split(RegExp(r'[.\s_\[\]()&+\-]+'))) {
      final language = _languageTags[token];
      if (language != null) return language;
    }
    return null;
  }

  /// Logs a scan failure without the mount's credentials.
  static void logFailure(StorageMount mount, Object error) {
    appLogger.w('Scan of mount "${mount.displayName}" failed: ${error is StorageException ? error.message : error}');
  }
}
