import 'storage_mount.dart';

/// One file or directory inside a mount.
///
/// [path] is mount-relative, POSIX-style and always absolute (`/` is the mount
/// root). [id] is the driver's own stable identifier when it has one — a
/// Quark `fid`, for example — so later reads don't have to re-resolve the path.
class StorageEntry {
  const StorageEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
    this.id,
    this.contentHash,
  });

  final String path;
  final String name;
  final bool isDirectory;

  /// Size in bytes. Null for directories and when the backend does not report it.
  final int? size;
  final DateTime? modifiedAt;
  final String? id;
  final String? contentHash;

  @override
  String toString() => 'StorageEntry($path${isDirectory ? '/' : ''}, size: $size)';
}

/// Why a storage operation failed, in terms the UI and the scanner can act on.
enum StorageErrorKind {
  /// The path does not exist (any more).
  notFound,

  /// Credentials are missing, wrong or expired. The mount needs attention.
  unauthorized,

  /// The backend asked us to slow down.
  rateLimited,

  /// The backend could not be reached.
  network,

  /// The driver does not implement this operation.
  unsupported,

  /// Anything else, including malformed backend responses.
  other,
}

class StorageException implements Exception {
  const StorageException(this.kind, this.message, {this.cause});

  final StorageErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'StorageException(${kind.name}): $message';
}

/// A mounted storage backend: a local folder, an SMB share, a WebDAV server or
/// a cloud drive. Modelled on the driver idea in OpenList, reduced to what a
/// read-only media library needs.
///
/// Implementations must be safe to call concurrently; the scanner, the stream
/// proxy and the downloader all share one instance per mount.
abstract class StorageDriver {
  StorageKind get kind;

  /// Verifies the configuration by talking to the backend. Throws a
  /// [StorageException] when the mount is unusable.
  Future<void> check();

  /// Lists the direct children of the directory at [path].
  ///
  /// Pass [parent] when the directory entry is already known so drivers that
  /// address by id can skip resolving the path.
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent});

  /// Looks up a single entry.
  Future<StorageEntry> stat(String path);

  /// Opens a byte range of [entry]. [start] is inclusive; [end] is inclusive
  /// too and defaults to the end of the file.
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end});

  /// Releases connections and caches. The driver is unusable afterwards.
  Future<void> close();
}

/// A driver that can fetch one read over several connections at once, for
/// bulk transfers from origins that cap each connection's speed.
abstract interface class ParallelReadSource {
  /// Like [StorageDriver.openRead], but fetched over up to [connections]
  /// connections, [chunkSize] bytes per request. [end] is inclusive and
  /// required.
  Stream<List<int>> openReadParallel(
    StorageEntry entry, {
    int start = 0,
    required int end,
    required int connections,
    required int chunkSize,
  });
}
