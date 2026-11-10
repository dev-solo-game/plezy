import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage_driver.dart';
import '../storage_mount.dart';
import '../storage_path.dart';

/// A directory on this device's file system.
///
/// Uses `dart:io` directly, which covers desktop and any Android location the
/// app can read by path. Android folders that are only reachable through the
/// Storage Access Framework need a separate SAF-backed driver.
class LocalStorageDriver implements StorageDriver {
  LocalStorageDriver({required String rootPath}) : _root = p.normalize(p.absolute(rootPath));

  factory LocalStorageDriver.fromMount(StorageMount mount) {
    final rootPath = mount.configString(MountKeys.rootPath);
    if (rootPath == null) {
      throw const StorageException(StorageErrorKind.other, 'Local mount has no root path');
    }
    return LocalStorageDriver(rootPath: rootPath);
  }

  final String _root;

  @override
  StorageKind get kind => StorageKind.local;

  String _resolve(String path) {
    final parts = StoragePath.segments(path);
    return parts.isEmpty ? _root : p.joinAll([_root, ...parts]);
  }

  @override
  Future<void> check() async {
    if (!await Directory(_root).exists()) {
      throw StorageException(StorageErrorKind.notFound, 'Directory does not exist: $_root');
    }
  }

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    final normalized = StoragePath.normalize(path);
    final directory = Directory(_resolve(normalized));
    final entries = <StorageEntry>[];
    try {
      await for (final entity in directory.list(followLinks: true)) {
        final name = p.basename(entity.path);
        final entry = await _entryFor(entity.path, StoragePath.join(normalized, name), name);
        if (entry != null) entries.add(entry);
      }
    } on FileSystemException catch (e) {
      throw _translate(e, normalized);
    }
    return entries;
  }

  @override
  Future<StorageEntry> stat(String path) async {
    final normalized = StoragePath.normalize(path);
    final entry = await _entryFor(_resolve(normalized), normalized, StoragePath.name(normalized));
    if (entry == null) throw StorageException(StorageErrorKind.notFound, 'Not found: $normalized');
    return entry;
  }

  /// Returns null for entries that vanished or cannot be stat-ed (broken
  /// links, permission-denied children) so one bad child does not fail a
  /// whole listing.
  Future<StorageEntry?> _entryFor(String fsPath, String storagePath, String name) async {
    final FileStat stat;
    try {
      stat = await FileStat.stat(fsPath);
    } on FileSystemException {
      return null;
    }
    switch (stat.type) {
      case FileSystemEntityType.directory:
        return StorageEntry(path: storagePath, name: name, isDirectory: true, modifiedAt: stat.modified);
      case FileSystemEntityType.file:
        return StorageEntry(
          path: storagePath,
          name: name,
          isDirectory: false,
          size: stat.size,
          modifiedAt: stat.modified,
        );
      default:
        return null;
    }
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) {
    // File.openRead's end is exclusive; ours is inclusive.
    return File(_resolve(entry.path)).openRead(start, end == null ? null : end + 1).handleError((Object error) {
      if (error is FileSystemException) throw _translate(error, entry.path);
      throw error;
    });
  }

  StorageException _translate(FileSystemException error, String path) {
    final code = error.osError?.errorCode;
    // ENOENT / ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND.
    final missing = code == 2 || (Platform.isWindows && code == 3);
    return StorageException(
      missing ? StorageErrorKind.notFound : StorageErrorKind.other,
      missing ? 'Not found: $path' : 'Cannot read $path: ${error.message}',
      cause: error,
    );
  }

  @override
  Future<void> close() async {}
}
