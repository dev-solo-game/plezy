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
  _MemoryDriver(this._tree, this._files);

  final Map<String, List<StorageEntry>> _tree;
  final Map<String, Uint8List> _files;

  @override
  StorageKind get kind => StorageKind.webdav;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async => _tree[path] ?? const [];

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path.split('/').last, isDirectory: false);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {
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
  });
}
