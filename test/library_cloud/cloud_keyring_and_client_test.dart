import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/library_cloud/cloud_api_client.dart';
import 'package:plezy/library_cloud/cloud_keyring.dart';
import 'package:plezy/library_cloud/projection_sync.dart';
import 'package:plezy/library_cloud/scan_session_runner.dart';
import 'package:plezy/library_cloud/source_repository.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

class _MemoryDriver implements StorageDriver {
  _MemoryDriver(
    this._tree,
    this._files, {
    this.driverKind = StorageKind.webdav,
    this.onList,
    this.onOpenRead,
  });

  final Map<String, List<StorageEntry>> _tree;
  final Map<String, Uint8List> _files;
  final StorageKind driverKind;
  final Future<void> Function(String path)? onList;
  final void Function(String path)? onOpenRead;

  @override
  StorageKind get kind => driverKind;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    if (onList != null) await onList!(path);
    return _tree[path] ?? const [];
  }

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path.split('/').last, isDirectory: false);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {
    onOpenRead?.call(entry.path);
    final data = _files[entry.path];
    if (data == null) return;
    final stop = end == null || end + 1 > data.length ? data.length : end + 1;
    if (start < stop) {
      yield data.sublist(start, stop);
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('CloudKeyring wraps/unwraps master key and encrypts/decrypts credentials', () async {
    final hk = CloudKeyring.generateMasterKey();
    expect(hk.length, CloudKeyring.keyLengthBytes);

    final wrap = await CloudKeyring.wrapMasterKey(
      masterKey: hk,
      password: 'StrongPassword123!',
      iterations: 1000, // fast for unit test
    );
    expect(wrap['wrap_type'], CloudKeyring.wrapTypeAccountPassword);
    expect(wrap['kdf_alg'], CloudKeyring.kdfAlgPbkdf2Sha256);

    final unwrapped = await CloudKeyring.unwrapMasterKey(
      wrap: wrap,
      password: 'StrongPassword123!',
    );
    expect(unwrapped, equals(hk));

    final cipher = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: {'url': 'https://nas.local/dav', 'user': 'alice', 'pass': 'secret'},
    );
    expect(cipher.contains('secret'), isFalse);

    final clear = await CloudKeyring.decryptCredentialJson(
      masterKey: hk,
      ciphertextB64: cipher,
    );
    expect(clear['user'], 'alice');
    expect(clear['pass'], 'secret');

    final id1 = CloudKeyring.computeIdentityKey(hk, 'quark:12345');
    final id2 = CloudKeyring.computeIdentityKey(hk, 'quark:12345');
    final id3 = CloudKeyring.computeIdentityKey(hk, 'quark:99999');
    expect(id1, equals(id2));
    expect(id1, isNot(equals(id3)));
  });

  test('CloudSourceRepository + CloudScanSessionRunner + CloudProjectionSyncClient end-to-end HTTP flow', () async {
    final hk = CloudKeyring.generateMasterKey();
    String? storedCiphertext;
    final uploadedSidecars = <String, List<int>>{};
    var batchesReceived = 0;
    var scanCompleted = false;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      List<int> rawBytes = await req.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (req.headers.value('content-encoding') == 'gzip') {
        rawBytes = gzip.decode(rawBytes);
      }

      if (req.method == 'POST' && path == '/api/v1/sources') {
        final body = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
        storedCiphertext = body['ciphertext'] as String?;
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'source': {
              'id': 'src_1',
              'kind': body['kind'],
              'name': body['name'],
              'identity_key': body['identity_key'],
              'status': 'active',
              'folders': [
                {'id': 'f_1', 'source_id': 'src_1', 'path': '/Movies'},
              ],
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/sources/src_1/credential') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'credential': {
              'source_id': 'src_1',
              'ciphertext': storedCiphertext,
              'version': 1,
              'key_epoch': 1,
              'status': 'valid',
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/v1/sources/src_1/scan-sessions') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'session': {
              'id': 'sess_1',
              'source_id': 'src_1',
              'type': 'full',
              'folders': [
                {'id': 'f_1', 'path': '/Movies', 'exclude_paths': <String>[]},
              ],
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_1/batches') {
        batchesReceived++;
        final body = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
        final upserts = body['upserts'] as List;
        final missing = <String>[
          for (final u in upserts)
            if ((u as Map)['sidecar_hash'] != null) u['sidecar_hash'] as String,
        ];
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'receipt': {
              'batch_no': body['batch_no'],
              'accepted': upserts.length,
              'missing_sidecars': missing,
            },
          }),
        );
        await req.response.close();
        return;
      }

      if (req.method == 'PUT' && path.startsWith('/api/v1/sidecars/')) {
        final hash = path.split('/').last;
        uploadedSidecars[hash] = rawBytes;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({'code': 0}));
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_1/complete') {
        scanCompleted = true;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({'code': 0}));
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/v1/library/snapshot') {
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'snapshot_seq': 7,
            'total': 1,
            'page': 1,
            'page_size': 100,
            'has_more': false,
            'items': [
              {'id': 42, 'title': 'Inception', 'kind': 'movie'},
            ],
          }),
        );
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_test');
    addTearDown(api.close);

    final repo = CloudSourceRepository(api: api, masterKeyProvider: () => hk);
    final created = await repo.createSource(
      kind: 'webdav',
      name: 'Home NAS',
      normalizedIdentity: 'webdav:https://alice@nas.local/movies',
      credentialPayload: {'url': 'https://nas.local/movies', 'username': 'alice', 'password': 'pw'},
      folders: [
        {'path': '/Movies'},
      ],
    );
    expect(created.id, 'src_1');

    final cred = await repo.fetchCredential('src_1');
    expect(cred.payload['password'], 'pw');

    final nfoBytes = Uint8List.fromList(utf8.encode('<movie><title>Inception</title></movie>'));
    final driver = _MemoryDriver(
      {
        '/Movies': [
          const StorageEntry(path: '/Movies/Inception.2010.mkv', name: 'Inception.2010.mkv', isDirectory: false, size: 1024),
          StorageEntry(path: '/Movies/Inception.2010.nfo', name: 'Inception.2010.nfo', isDirectory: false, size: nfoBytes.length),
        ],
      },
      {'/Movies/Inception.2010.nfo': nfoBytes},
    );

    final runner = CloudScanSessionRunner(api: api);
    final progress = await runner.runScan(sourceId: 'src_1', driver: driver);
    expect(progress.completed, isTrue);
    expect(progress.filesReported, 2);
    expect(batchesReceived, 1);
    expect(scanCompleted, isTrue);
    expect(uploadedSidecars.length, 1);

    final sync = CloudProjectionSyncClient(api);
    final snap = await sync.fetchSnapshot(kind: 'movie');
    expect(snap.snapshotSeq, 7);
    expect(snap.items.single['title'], 'Inception');
    runner.dispose();
  });

  test('CloudScanSessionRunner notifies globally, flushes pending files before /cancel, and skips Quark sidecars', () async {
    final events = <String>[];
    final uploadedPaths = <String>[];
    var cancelCalled = false;
    var openReadCount = 0;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      List<int> rawBytes = await req.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (req.headers.value('content-encoding') == 'gzip') {
        rawBytes = gzip.decode(rawBytes);
      }
      if (req.method == 'POST' && path == '/api/v1/sources/src_q/scan-sessions') {
        events.add('start');
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'session': {
              'id': 'sess_q',
              'source_id': 'src_q',
              'folder_id': 'f_q',
              'type': 'folder',
              'folders': [
                {'id': 'f_q', 'path': '/Anime', 'exclude_paths': <String>[]},
              ],
            },
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_q/batches') {
        events.add('batch');
        final body = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
        final upserts = body['upserts'] as List;
        for (final u in upserts) {
          uploadedPaths.add((u as Map)['path'] as String);
        }
        req.response.statusCode = 200;
        req.response.write(
          jsonEncode({
            'code': 0,
            'receipt': {
              'batch_no': body['batch_no'],
              'accepted': upserts.length,
              'added': upserts.length,
              'changed': 0,
              'missing_sidecars': <String>[],
            },
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_q/progress') {
        events.add('progress');
        req.response.statusCode = 200;
        req.response.write(jsonEncode({'code': 0}));
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_q/cancel') {
        events.add('cancel');
        cancelCalled = true;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({'code': 0}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_test');
    addTearDown(api.close);

    final runner = CloudScanSessionRunner(
      api: api,
      batchSize: 100, // large batch so only cancel-flush sends /Anime files when cancelled mid-scan
      flushInterval: const Duration(minutes: 5),
    );
    addTearDown(runner.dispose);

    final observedCancelling = <bool>[];
    runner.addListener(() {
      final p = runner.progressOf('src_q', folderId: 'f_q');
      if (p != null) observedCancelling.add(p.cancelling);
    });

    final driver = _MemoryDriver(
      {
        '/Anime': [
          const StorageEntry(path: '/Anime/Ep01.mkv', name: 'Ep01.mkv', isDirectory: false, size: 100),
          const StorageEntry(path: '/Anime/poster.jpg', name: 'poster.jpg', isDirectory: false, size: 50),
          const StorageEntry(path: '/Anime/Sub', name: 'Sub', isDirectory: true),
        ],
        '/Anime/Sub': [
          const StorageEntry(path: '/Anime/Sub/Ep02.mkv', name: 'Ep02.mkv', isDirectory: false, size: 100),
          const StorageEntry(path: '/Anime/Sub/Ep03.mkv', name: 'Ep03.mkv', isDirectory: false, size: 100),
        ],
      },
      {
        '/Anime/poster.jpg': Uint8List.fromList([1, 2, 3]),
      },
      driverKind: StorageKind.quark,
      onOpenRead: (_) => openReadCount++,
      onList: (path) async {
        if (path == '/Anime/Sub') {
          runner.cancelScan('src_q', folderId: 'f_q');
          expect(runner.isCancelling('src_q', folderId: 'f_q'), isTrue);
        }
      },
    );

    final summary = await runner.runScan(
      sourceId: 'src_q',
      folderId: 'f_q',
      scanType: 'folder',
      targetLabel: 'Quark · /Anime',
      driver: driver,
    );

    expect(summary.cancelled, isTrue);
    expect(summary.cancelling, isFalse);
    expect(summary.filesReported, 2);
    expect(uploadedPaths, ['/Anime/Ep01.mkv', '/Anime/poster.jpg']);
    expect(openReadCount, 0);
    expect(cancelCalled, isTrue);
    expect(events.indexOf('batch'), lessThan(events.indexOf('cancel')));
    expect(observedCancelling, contains(true));
    expect(runner.isScanning('src_q', folderId: 'f_q'), isFalse);
    expect(runner.progressOf('src_q', folderId: 'f_q')?.cancelled, isTrue);
  });

  test('CloudScanSessionRunner flushes incrementally when flushInterval elapses', () async {
    var batchesReceived = 0;
    final batchSizes = <int>[];
    var completeCalled = false;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      List<int> rawBytes = await req.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (req.headers.value('content-encoding') == 'gzip') {
        rawBytes = gzip.decode(rawBytes);
      }
      if (req.method == 'POST' && path == '/api/v1/sources/src_t/scan-sessions') {
        req.response.write(
          jsonEncode({
            'code': 0,
            'session': {
              'id': 'sess_t',
              'source_id': 'src_t',
              'type': 'full',
              'folders': [
                {'id': 'f_t', 'path': '/Shows', 'exclude_paths': <String>[]},
              ],
            },
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_t/batches') {
        batchesReceived++;
        final body = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
        final upserts = body['upserts'] as List;
        batchSizes.add(upserts.length);
        req.response.write(
          jsonEncode({
            'code': 0,
            'receipt': {'batch_no': body['batch_no'], 'accepted': upserts.length, 'added': upserts.length, 'changed': 0},
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_t/progress') {
        req.response.write(jsonEncode({'code': 0}));
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_t/complete') {
        completeCalled = true;
        req.response.write(jsonEncode({'code': 0}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_test');
    addTearDown(api.close);

    final runner = CloudScanSessionRunner(
      api: api,
      batchSize: 50,
      flushInterval: const Duration(milliseconds: 15),
    );
    addTearDown(runner.dispose);

    final driver = _MemoryDriver(
      {
        '/Shows': [
          const StorageEntry(path: '/Shows/S01E01.mkv', name: 'S01E01.mkv', isDirectory: false, size: 100),
          const StorageEntry(path: '/Shows/Season 1', name: 'Season 1', isDirectory: true),
        ],
        '/Shows/Season 1': [
          const StorageEntry(path: '/Shows/Season 1/S01E02.mkv', name: 'S01E02.mkv', isDirectory: false, size: 100),
        ],
      },
      const {},
      onList: (p) async {
        if (p == '/Shows/Season 1') {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      },
    );

    final done = await runner.runScan(sourceId: 'src_t', driver: driver);
    expect(done.completed, isTrue);
    expect(done.filesReported, 2);
    expect(completeCalled, isTrue);
    expect(batchesReceived, 2);
    expect(batchSizes, [1, 1]);
  });

  test('CloudScanSessionRunner.runQuarkIncrementalScan reports changed folder files, out-of-scope removals, and new watermark', () async {
    String? requestedScanType;
    final upsertedPaths = <String>[];
    final removedIds = <String>[];
    int? completedWatermark;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      List<int> rawBytes = await req.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (req.headers.value('content-encoding') == 'gzip') {
        rawBytes = gzip.decode(rawBytes);
      }
      final bodyText = utf8.decode(rawBytes);
      final bodyMap = bodyText.isNotEmpty ? jsonDecode(bodyText) as Map<String, dynamic> : const <String, dynamic>{};

      if (req.method == 'POST' && path == '/api/v1/sources/src_qk/scan-sessions') {
        requestedScanType = bodyMap['type'] as String?;
        req.response.write(
          jsonEncode({
            'code': 0,
            'session': {
              'id': 'sess_inc',
              'source_id': 'src_qk',
              'type': 'incremental',
              'incremental_watermark': 1700000000000,
              'folders': [
                {'id': 'f_anime', 'path': '/Anime', 'exclude_paths': <String>[]},
              ],
            },
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_inc/batches') {
        for (final u in (bodyMap['upserts'] as List? ?? const [])) {
          upsertedPaths.add((u as Map)['path'] as String);
        }
        for (final r in (bodyMap['removed'] as List? ?? const [])) {
          final id = (r as Map)['remote_id'] as String?;
          if (id != null) removedIds.add(id);
        }
        final upsertsLen = (bodyMap['upserts'] as List? ?? const []).length;
        final removedLen = (bodyMap['removed'] as List? ?? const []).length;
        req.response.write(
          jsonEncode({
            'code': 0,
            'receipt': {
              'batch_no': bodyMap['batch_no'],
              'accepted': upsertsLen,
              'added': upsertsLen,
              'changed': 0,
              'removed': removedLen,
            },
          }),
        );
      } else if (req.method == 'POST' && path == '/api/v1/scan-sessions/sess_inc/complete') {
        completedWatermark = (bodyMap['new_watermark'] as num?)?.toInt();
        req.response.write(jsonEncode({'code': 0}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    final api = CloudApiClient(baseUrl: 'http://127.0.0.1:${server.port}', accessToken: 'usr_inc');
    addTearDown(api.close);

    final runner = CloudScanSessionRunner(api: api);
    addTearDown(runner.dispose);

    final driver = _MemoryDriver(
      {
        '/Anime/Show1': [
          const StorageEntry(
            id: 'fid_ep9',
            path: '/Anime/Show1/S01E09.mkv',
            name: 'S01E09.mkv',
            isDirectory: false,
            size: 4096,
          ),
          const StorageEntry(
            id: 'fid_sub9',
            path: '/Anime/Show1/S01E09.zh.srt',
            name: 'S01E09.zh.srt',
            isDirectory: false,
            size: 256,
          ),
        ],
      },
      const {},
      driverKind: StorageKind.quark,
    );

    final res = await runner.runQuarkIncrementalScan(
      sourceId: 'src_qk',
      driver: driver,
      targetLabel: 'Quark',
      rootFolderIdOverride: '0',
      searchUpdatedPageOverride: (page, {size = 100}) async {
        if (page > 1) return const [];
        return [
          (
            entry: const StorageEntry(id: 'fid_ep9', path: '/S01E09.mkv', name: 'S01E09.mkv', isDirectory: false),
            parentId: 'dir_show1',
            updatedAt: 1700000100000,
          ),
          (
            entry: const StorageEntry(id: 'fid_moved_out', path: '/Old.mkv', name: 'Old.mkv', isDirectory: false),
            parentId: 'dir_trash',
            updatedAt: 1700000090000,
          ),
          // Older than watermark overlap threshold -> ignored.
          (
            entry: const StorageEntry(id: 'fid_old', path: '/Ep01.mkv', name: 'Ep01.mkv', isDirectory: false),
            parentId: 'dir_other',
            updatedAt: 1699999000000,
          ),
        ];
      },
      folderAncestryOverride: (id) async => switch (id) {
        'dir_show1' => [(id: 'dir_anime', name: 'Anime'), (id: 'dir_show1', name: 'Show1')],
        'dir_trash' => [(id: 'dir_trash', name: 'Trash')],
        _ => const [],
      },
    );

    expect(requestedScanType, 'incremental');
    expect(res.completed, isTrue);
    expect(res.scanType, 'incremental');
    expect(res.directoriesVisited, 1);
    expect(res.filesAdded, 2);
    expect(res.filesMissing, 1);
    expect(upsertedPaths, ['/Anime/Show1/S01E09.mkv', '/Anime/Show1/S01E09.zh.srt']);
    expect(removedIds, ['fid_moved_out']);
    expect(completedWatermark, 1700000100000);
  });
}
