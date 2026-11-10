import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';

import '../storage_driver.dart';
import '../storage_mount.dart';
import '../storage_path.dart';

/// The slice of an SMB session the driver needs. It exists so the driver's
/// path mapping, chunking and error translation can be tested without a
/// server; production uses [_PoolSession] over `dart_smb2`.
abstract interface class SmbSession {
  /// [path] is share-relative with `/` separators; an empty string is the
  /// share root.
  Future<List<({String name, bool isDirectory, int size, DateTime? modifiedAt})>> list(String path);

  Future<({bool isDirectory, int size, DateTime? modifiedAt})> stat(String path);

  /// Reads up to [length] bytes at [offset]; fewer only at end of file.
  Future<Uint8List> read(String path, {required int offset, required int length});

  Future<void> close();
}

typedef SmbSessionFactory = Future<SmbSession> Function();

/// An SMB2/3 share (NAS, Windows share, Samba), optionally rooted at a
/// sub-folder of the share.
///
/// The connection is opened on first use and shared by every call; `dart_smb2`
/// runs it on worker isolates, so nothing here blocks the UI.
class SmbStorageDriver implements StorageDriver {
  SmbStorageDriver({required SmbSessionFactory connect, String rootPath = ''})
    : _connectSession = connect,
      _rootSegments = StoragePath.segments(rootPath);

  factory SmbStorageDriver.fromMount(StorageMount mount) {
    final host = mount.configString(MountKeys.host);
    final share = mount.configString(MountKeys.share);
    if (host == null || share == null) {
      throw const StorageException(StorageErrorKind.other, 'SMB mount needs a host and a share');
    }
    final user = mount.configString(MountKeys.username);
    final password = mount.secret(MountKeys.secretPassword);
    final domain = mount.configString(MountKeys.domain);
    return SmbStorageDriver(
      rootPath: mount.configString(MountKeys.rootPath) ?? '',
      connect: () async => _PoolSession(
        await Smb2Pool.connect(host: host, share: share, user: user, password: password, domain: domain),
      ),
    );
  }

  /// Bytes per read request. Large enough that a high-bitrate stream is not
  /// dominated by round trips, small enough to keep seeks responsive.
  static const int readChunkSize = 1024 * 1024;

  final SmbSessionFactory _connectSession;
  final List<String> _rootSegments;
  Future<SmbSession>? _session;
  bool _closed = false;

  @override
  StorageKind get kind => StorageKind.smb;

  Future<SmbSession> _open() {
    if (_closed) throw const StorageException(StorageErrorKind.other, 'SMB driver is closed');
    return _session ??= _connectSession().catchError((Object error) {
      // Let the next call try to connect again instead of caching the failure.
      _session = null;
      throw error;
    });
  }

  String _sharePath(String path) => [..._rootSegments, ...StoragePath.segments(path)].join('/');

  Future<T> _guard<T>(String path, Future<T> Function(SmbSession session) action) async {
    try {
      return await action(await _open());
    } on Smb2Exception catch (e) {
      throw _translate(e, path);
    }
  }

  @override
  Future<void> check() => _guard(StoragePath.root, (session) => session.list(_sharePath(StoragePath.root)));

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) {
    final normalized = StoragePath.normalize(path);
    return _guard(normalized, (session) async {
      final rows = await session.list(_sharePath(normalized));
      return [
        for (final row in rows)
          if (row.name != '.' && row.name != '..' && !row.name.contains('/') && !row.name.contains('\\'))
            StorageEntry(
              path: StoragePath.join(normalized, row.name),
              name: row.name,
              isDirectory: row.isDirectory,
              size: row.isDirectory ? null : row.size,
              modifiedAt: row.modifiedAt,
            ),
      ];
    });
  }

  @override
  Future<StorageEntry> stat(String path) {
    final normalized = StoragePath.normalize(path);
    return _guard(normalized, (session) async {
      final stat = await session.stat(_sharePath(normalized));
      return StorageEntry(
        path: normalized,
        name: StoragePath.name(normalized),
        isDirectory: stat.isDirectory,
        size: stat.isDirectory ? null : stat.size,
        modifiedAt: stat.modifiedAt,
      );
    });
  }

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {
    final sharePath = _sharePath(entry.path);
    var offset = start;
    while (end == null || offset <= end) {
      final want = end == null || end - offset + 1 > readChunkSize ? readChunkSize : end - offset + 1;
      final chunk = await _guard(entry.path, (session) => session.read(sharePath, offset: offset, length: want));
      if (chunk.isEmpty) return;
      yield chunk;
      offset += chunk.length;
      // A short read means the file ended.
      if (chunk.length < want) return;
    }
  }

  static StorageException _translate(Smb2Exception error, String path) {
    final kind = switch (error.type) {
      Smb2ErrorType.auth || Smb2ErrorType.accessDenied => StorageErrorKind.unauthorized,
      Smb2ErrorType.notFound => StorageErrorKind.notFound,
      _ => error.isNetworkFailure ? StorageErrorKind.network : StorageErrorKind.other,
    };
    return StorageException(kind, 'SMB: ${error.message}', cause: error);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final session = _session;
    _session = null;
    if (session == null) return;
    try {
      await (await session).close();
    } catch (_) {
      // Never connected, or already gone.
    }
  }
}

class _PoolSession implements SmbSession {
  _PoolSession(this._pool);

  final Smb2Pool _pool;

  @override
  Future<List<({String name, bool isDirectory, int size, DateTime? modifiedAt})>> list(String path) async {
    final entries = await _pool.listDirectory(path);
    return [
      for (final e in entries) (name: e.name, isDirectory: e.isDirectory, size: e.size, modifiedAt: e.stat.modified),
    ];
  }

  @override
  Future<({bool isDirectory, int size, DateTime? modifiedAt})> stat(String path) async {
    final stat = await _pool.stat(path);
    return (isDirectory: stat.isDirectory, size: stat.size, modifiedAt: stat.modified);
  }

  @override
  Future<Uint8List> read(String path, {required int offset, required int length}) {
    return _pool.readFileRange(path, offset: offset, length: length);
  }

  @override
  Future<void> close() => _pool.disconnect();
}
