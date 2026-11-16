import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../storage/drivers/quark_storage_driver.dart';
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
  const ScanResult({required this.videos, required this.removed, required this.cancelled, this.hasChanges = true});

  /// Videos seen by this run.
  final int videos;

  /// Files dropped because the mount no longer has them.
  final int removed;

  /// True when the run was stopped early.
  final bool cancelled;

  final bool hasChanges;
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

  Future<LibraryScanStateRow?> _state(String mountId) =>
      (_db.select(_db.libraryScanStates)..where((t) => t.mountId.equals(mountId))).getSingleOrNull();

  Future<bool> hasQuarkBaseline(StorageMount mount) async {
    return await quarkLastSuccessfulScan(mount) != null;
  }

  Future<DateTime?> quarkLastSuccessfulScan(StorageMount mount) async {
    final root = mount.configString(MountKeys.rootFolderId) ?? QuarkStorageDriver.defaultRootFolderId;
    final state = await _state(mount.id);
    final finishedAt = state?.finishedAt;
    if (finishedAt == null || _watermark(state, root) == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(finishedAt);
  }

  static int? _watermark(LibraryScanStateRow? state, String root) {
    final checkpoint = state?.quarkCheckpoint;
    if (checkpoint == null || !checkpoint.startsWith('$root:')) return null;
    return int.tryParse(checkpoint.substring(root.length + 1));
  }

  Future<ScanResult> scan(
    StorageMount mount,
    StorageDriver driver, {
    ScanCancelToken? cancel,
    void Function(ScanProgress progress)? onProgress,
    bool restart = false,
  }) async {
    final quark = driver is QuarkStorageDriver && driver.supportsIncremental ? driver : null;
    int? watermark;
    if (quark != null) {
      // Capture the server time before traversal so concurrent uploads are
      // still visible to the next incremental update. An empty drive starts at zero.
      try {
        final head = await quark.searchUpdatedPage(1, size: 1);
        watermark = head.where((row) => !row.entry.isDirectory).firstOrNull?.updatedAt ?? 0;
      } on StorageException catch (error) {
        appLogger.w('Quark: could not establish a new incremental baseline: ${error.message}');
      }
    }
    if (cancel?.isCancelled == true) return _cancelled;
    final run = await _begin(mount.id, restart: restart || quark != null);
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
          if (e.kind == StorageErrorKind.notFound && directory.path != StoragePath.root) {
            // Deleted between listing its parent and getting here.
            await _saveQueue(mount.id, queue);
            continue;
          }
          queue.add(directory);
          rethrow;
        }

        for (final entry in entries) {
          if (entry.isDirectory && !_isSkippedFolder(entry.name) && mount.canTraverseDirectory(entry.path)) {
            queue.add(entry);
          }
        }
        final files = entries.where((e) => !e.isDirectory && mount.isFileAllowed(e.path)).toList();
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

    return _db.transaction(() async {
      if (cancel?.isCancelled == true) return _cancelled;
      final removed = await _repo.removeFilesNotSeen(mount.id, run.scanId);
      await _repo.pruneEmptyTitles();
      await _repo.initializeSourceAddedTimes(mount.id, scanId: run.scanId);
      await (_db.update(_db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).write(
        LibraryScanStatesCompanion(
          status: const Value('idle'),
          pending: const Value(null),
          finishedAt: Value(_now()),
          lastError: const Value(null),
          quarkCheckpoint: quark == null
              ? const Value(null)
              : watermark == null
              ? const Value.absent()
              : Value('${quark.rootFolderId}:$watermark'),
        ),
      );
      return ScanResult(videos: videos, removed: removed, cancelled: false);
    });
  }

  static const _cancelled = ScanResult(videos: 0, removed: 0, cancelled: true);

  Future<ScanResult> scanQuarkIncremental(
    StorageMount mount,
    QuarkStorageDriver driver, {
    required ScanCancelToken cancel,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final state = await _state(mount.id);
    final watermark = _watermark(state, driver.rootFolderId);
    if (watermark == null) throw const StorageException(StorageErrorKind.other, 'Quark: full scan required');
    final threshold = watermark - const Duration(minutes: 1).inMilliseconds;
    final changed = <String, ({StorageEntry entry, String parentId, int updatedAt})>{};
    var latest = watermark;
    int? previousTimestamp;
    for (var page = 1; ; page++) {
      if (cancel.isCancelled) return _cancelled;
      final rows = await driver.searchUpdatedPage(page);
      int? lastFileTimestamp;
      for (final row in rows) {
        if (row.entry.isDirectory) continue;
        if (previousTimestamp != null && row.updatedAt > previousTimestamp) {
          throw const StorageException(StorageErrorKind.other, 'Quark: unexpected search order');
        }
        previousTimestamp = row.updatedAt;
        lastFileTimestamp = row.updatedAt;
        if (row.updatedAt > latest) latest = row.updatedAt;
        if (row.updatedAt < threshold || !_isVideo(row.entry.name)) continue;
        if (row.parentId.isEmpty) {
          throw const StorageException(StorageErrorKind.other, 'Quark: missing parent folder ID');
        }
        changed.putIfAbsent(row.entry.id!, () => row);
      }
      onProgress?.call(ScanProgress(directoriesDone: 0, filesSeen: changed.length, currentPath: StoragePath.root));
      if (rows.length < QuarkStorageDriver.searchPageSize ||
          (lastFileTimestamp != null && lastFileTimestamp < threshold)) {
        break;
      }
      if (page == 50) throw const StorageException(StorageErrorKind.other, 'Quark: full scan required after 50 pages');
    }

    final directories = <String, String>{};
    final paths = <String, String?>{driver.rootFolderId: StoragePath.root};
    final movedOut = <String>[];
    for (final row in changed.values) {
      if (cancel.isCancelled) return _cancelled;
      final parent = paths.containsKey(row.parentId)
          ? paths[row.parentId]
          : paths[row.parentId] = await _quarkFolderPath(driver, row.parentId);
      if (parent == null) {
        movedOut.add(row.entry.id!);
      } else {
        final path = StoragePath.join(parent, row.entry.name);
        if (!mount.isFileAllowed(path)) {
          movedOut.add(row.entry.id!);
        } else if (!directories.containsKey(row.parentId)) {
          final existing = await _fileAt(mount.id, path);
          if (existing?.remoteId != row.entry.id || existing?.modifiedAt != row.updatedAt) {
            directories[row.parentId] = parent;
          }
        }
      }
    }

    final listings = <String, List<StorageEntry>>{};
    for (final MapEntry(key: id, value: path) in directories.entries) {
      if (cancel.isCancelled) return _cancelled;
      final folder = StorageEntry(id: id, path: path, name: StoragePath.name(path), isDirectory: true);
      final entries = await driver.list(path, parent: folder);
      listings[path] = entries.where((entry) => !entry.isDirectory && mount.isFileAllowed(entry.path)).toList();
      onProgress?.call(ScanProgress(directoriesDone: listings.length, filesSeen: changed.length, currentPath: path));
    }

    // Fetch all pages and resolve all folders before changing the library.
    // Rolling back this transaction also rolls back the checkpoint.
    try {
      return await _db.transaction(() async {
        _checkIncrementalCancellation(cancel);
        var videos = 0;
        var removed = 0;
        final files = _db.libraryFiles;
        for (final ids in movedOut.slices(100)) {
          removed += await (_db.delete(files)..where((t) => t.mountId.equals(mount.id) & t.remoteId.isIn(ids))).go();
        }
        for (final directory in listings.entries) {
          _checkIncrementalCancellation(cancel);
          videos += await _recordDirectory(mount, directory.key, directory.value, state!.scanId);
        }
        if (removed > 0 || listings.isNotEmpty) await _repo.pruneEmptyTitles();
        if (listings.isNotEmpty) {
          await _repo.initializeSourceAddedTimes(mount.id, scanId: state!.scanId);
        }
        _checkIncrementalCancellation(cancel);
        await (_db.update(_db.libraryScanStates)..where((t) => t.mountId.equals(mount.id))).write(
          LibraryScanStatesCompanion(
            finishedAt: Value(_now()),
            quarkCheckpoint: Value('${driver.rootFolderId}:$latest'),
          ),
        );
        _checkIncrementalCancellation(cancel);
        return ScanResult(
          videos: videos,
          removed: removed,
          cancelled: false,
          hasChanges: listings.isNotEmpty || removed > 0,
        );
      });
    } on _IncrementalCancelled {
      return _cancelled;
    }
  }

  static void _checkIncrementalCancellation(ScanCancelToken cancel) {
    if (cancel.isCancelled) throw const _IncrementalCancelled();
  }

  Future<String?> _quarkFolderPath(QuarkStorageDriver driver, String id) async {
    final ancestry = await driver.folderAncestry(id);
    final root = driver.rootFolderId;
    final rootIndex = ancestry.indexWhere((folder) => folder.id == root);
    if (rootIndex == -1 && root != QuarkStorageDriver.defaultRootFolderId) return null;
    var path = StoragePath.root;
    for (final folder in ancestry.skip(rootIndex + 1)) {
      if (_isSkippedFolder(folder.name)) return null;
      path = StoragePath.join(path, folder.name);
    }
    return path;
  }

  static bool _isVideo(String name) =>
      videoExtensions.contains(StoragePath.extension(name)) && !_sampleName.hasMatch(_baseName(name));

  /// Lists [directory] once and updates library rows only when direct child
  /// files were added, modified, or removed.
  Future<bool> refreshSingleDirectory(StorageMount mount, StorageDriver driver, String directory) async {
    final dir = StoragePath.normalize(directory);
    if (!mount.canTraverseDirectory(dir)) return false;

    final entries = await driver.list(dir);
    final files = entries.where((e) => !e.isDirectory && mount.isFileAllowed(e.path)).toList();
    final trackedRemote = <(String, int?, int?, String?)>{
      for (final f in files)
        if (_isVideo(f.name) ||
            StoragePath.extension(f.name) == 'nfo' ||
            imageExtensions.contains(StoragePath.extension(f.name)))
          (f.path, f.size, f.modifiedAt?.millisecondsSinceEpoch, f.id),
      for (final m in matchSubtitles(files))
        (m.subtitle.path, m.subtitle.size, m.subtitle.modifiedAt?.millisecondsSinceEpoch, m.subtitle.id),
    };

    final existingInDir = await _directFilesIn(mount.id, dir);
    final trackedLocal = <(String, int?, int?, String?)>{
      for (final row in existingInDir) (row.path, row.size, row.modifiedAt, row.remoteId),
    };
    if (const SetEquality<(String, int?, int?, String?)>().equals(trackedRemote, trackedLocal)) {
      return false;
    }

    final state = await _state(mount.id);
    final scanId = state?.scanId ?? 1;
    final remotePaths = {for (final f in files) f.path};
    final removedIds = [
      for (final row in existingInDir)
        if (!remotePaths.contains(row.path)) row.id,
    ];

    await _db.transaction(() async {
      for (final batch in removedIds.slices(100)) {
        await (_db.delete(_db.libraryFiles)..where((t) => t.id.isIn(batch))).go();
      }
      if (files.isNotEmpty) {
        await _recordDirectory(mount, dir, files, scanId);
      }
      await _repo.pruneEmptyTitles();
      if (files.isNotEmpty) {
        await _repo.initializeSourceAddedTimes(mount.id, scanId: scanId);
      }
    });
    return true;
  }

  Future<List<LibraryFileRow>> _directFilesIn(String mountId, String dir) async {
    final prefix = dir == StoragePath.root ? '/' : '$dir/';
    final rows = await (_db.select(_db.libraryFiles)..where((t) => t.mountId.equals(mountId) & t.path.like('$prefix%')))
        .get();
    return [
      for (final row in rows)
        if (StoragePath.parent(row.path) == dir) row,
    ];
  }

  // ─── Run bookkeeping ───────────────────────────────────────────────────

  Future<({int scanId, List<StorageEntry> queue})> _begin(String mountId, {required bool restart}) async {
    final states = _db.libraryScanStates;
    final state = await _state(mountId);

    // An interrupted run left its queue behind: pick it up under the same
    // scan id, so files it already stamped still count as seen.
    if (!restart && state != null && state.status != 'idle' && state.pending != null) {
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
            quarkCheckpoint: Value(state?.quarkCheckpoint),
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
    final others = <(StorageEntry, String)>[];
    for (final file in files) {
      final extension = StoragePath.extension(file.name);
      if (videoExtensions.contains(extension)) {
        if (!_sampleName.hasMatch(_baseName(file.name))) videos.add(file);
      } else if (extension == 'nfo') {
        others.add((file, LibraryFileRoles.nfo));
      } else if (imageExtensions.contains(extension)) {
        others.add((file, LibraryFileRoles.artwork));
      }
    }
    if (videos.isEmpty && others.isEmpty) return 0;

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
        final previous = await _prepareFile(mount, video);
        final id = await _repo.upsertFile(
          mountId: mount.id,
          path: video.path,
          role: LibraryFileRoles.video,
          scanId: scanId,
          remoteId: video.id,
          size: video.size,
          modifiedAt: video.modifiedAt?.millisecondsSinceEpoch,
          sourceCreatedAt: video.createdAt?.millisecondsSinceEpoch,
          parsed: jsonEncode({...name.toJson(), 'key': classified.key}),
          versionLabel: classified.versionLabel,
        );
        videoIds[video.path] = id;
        if (previous == null || previous.remoteId != video.id || previous.path == video.path) {
          await _file(id, previous, classified);
        }
      }

      for (final (:subtitle, :owner, :language) in matchSubtitles(files)) {
        await _prepareFile(mount, subtitle);
        await _repo.upsertFile(
          mountId: mount.id,
          path: subtitle.path,
          role: LibraryFileRoles.subtitle,
          scanId: scanId,
          remoteId: subtitle.id,
          size: subtitle.size,
          modifiedAt: subtitle.modifiedAt?.millisecondsSinceEpoch,
          ownerFileId: videoIds[owner.path],
          language: language,
        );
      }

      for (final (file, role) in others) {
        await _prepareFile(mount, file);
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
  static const int namingVersion = 2;

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
    if (moved > 0) {
      await _repo.pruneEmptyTitles();
      await _repo.initializeSourceAddedTimes(mountId);
    }
    return moved;
  }

  Future<LibraryFileRow?> _fileAt(String mountId, String path) {
    return (_db.select(
      _db.libraryFiles,
    )..where((t) => t.mountId.equals(mountId) & t.path.equals(path))).getSingleOrNull();
  }

  Future<LibraryFileRow?> _prepareFile(StorageMount mount, StorageEntry entry) async {
    final existing = await _fileAt(mount.id, entry.path);
    final fid = entry.id;
    if (mount.kind != StorageKind.quark || fid == null || existing?.remoteId == fid) return existing;
    final files = _db.libraryFiles;
    final prior =
        await (_db.select(files)
              ..where((t) => t.mountId.equals(mount.id) & t.remoteId.equals(fid))
              ..limit(1))
            .getSingleOrNull();
    if (prior == null) return existing;
    if (existing != null) await (_db.delete(files)..where((t) => t.id.equals(existing.id))).go();
    await _repo.updateFile(prior.id, LibraryFilesCompanion(path: Value(entry.path)));
    return prior;
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
    // The last file leaving a title takes its progress along; the emptied
    // title is pruned afterwards.
    final oldItem = previous?.itemId;
    if (oldItem != null && oldItem != itemId && await _repo.videoCount(oldItem) == 0) {
      await _repo.mergeUserState(oldItem, itemId);
    }
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

  static Iterable<({StorageEntry subtitle, StorageEntry owner, String? language})> matchSubtitles(
    List<StorageEntry> entries,
  ) sync* {
    final videos = entries.where((entry) => !entry.isDirectory && _isVideo(entry.name)).toList();
    if (videos.isEmpty) return;
    for (final entry in entries) {
      if (entry.isDirectory || !subtitleExtensions.contains(StoragePath.extension(entry.name))) continue;
      final owner = _ownerOf(entry, videos);
      if (owner != null) yield (subtitle: entry, owner: owner, language: _subtitleLanguage(entry, owner));
    }
  }

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

class _IncrementalCancelled implements Exception {
  const _IncrementalCancelled();
}
