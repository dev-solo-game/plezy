import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/smb_storage_driver.dart';
import 'package:plezy/storage/storage_driver.dart';

class _FakeSession implements SmbSession {
  final Map<String, List<({String name, bool isDirectory, int size, DateTime? modifiedAt})>> directories = {};
  final Map<String, Uint8List> files = {};
  final List<String> calls = [];
  Smb2Exception? failWith;
  bool closed = false;

  @override
  Future<List<({String name, bool isDirectory, int size, DateTime? modifiedAt})>> list(String path) async {
    calls.add('list:$path');
    if (failWith case final failure?) throw failure;
    final rows = directories[path];
    if (rows == null) throw const Smb2Exception('no such directory', type: Smb2ErrorType.notFound);
    return rows;
  }

  @override
  Future<({bool isDirectory, int size, DateTime? modifiedAt})> stat(String path) async {
    calls.add('stat:$path');
    final file = files[path];
    if (file == null) throw const Smb2Exception('no such file', type: Smb2ErrorType.notFound);
    return (isDirectory: false, size: file.length, modifiedAt: null);
  }

  @override
  Future<Uint8List> read(String path, {required int offset, required int length}) async {
    calls.add('read:$path@$offset+$length');
    final file = files[path]!;
    if (offset >= file.length) return Uint8List(0);
    final end = offset + length > file.length ? file.length : offset + length;
    return Uint8List.sublistView(file, offset, end);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late _FakeSession session;
  late SmbStorageDriver driver;
  var connects = 0;

  setUp(() {
    connects = 0;
    session = _FakeSession()
      ..directories['Media'] = [
        (name: '.', isDirectory: true, size: 0, modifiedAt: null),
        (name: '..', isDirectory: true, size: 0, modifiedAt: null),
        (name: 'Movies', isDirectory: true, size: 0, modifiedAt: DateTime(2026)),
        (name: 'film.mkv', isDirectory: false, size: 10, modifiedAt: DateTime(2026, 2)),
      ]
      ..files['Media/film.mkv'] = Uint8List.fromList(List<int>.generate(10, (i) => i));
    driver = SmbStorageDriver(
      rootPath: '/Media/',
      connect: () async {
        connects++;
        return session;
      },
    );
  });

  test('lists relative to the configured sub-folder and drops dot entries', () async {
    final entries = await driver.list('/');
    expect(session.calls, ['list:Media']);
    expect(entries.map((e) => e.path), ['/Movies', '/film.mkv']);
    expect(entries[0].size, isNull);
    expect(entries[1].size, 10);
    expect(entries[1].modifiedAt, DateTime(2026, 2));
  });

  test('connects once and reuses the session', () async {
    await driver.check();
    await driver.list('/');
    await driver.stat('/film.mkv');
    expect(connects, 1);
  });

  test('a failed connection is retried on the next call', () async {
    var attempts = 0;
    final flaky = SmbStorageDriver(
      connect: () async {
        if (attempts++ == 0) throw const Smb2Exception('refused', type: Smb2ErrorType.connection);
        return session..directories[''] = const [];
      },
    );
    await expectLater(
      flaky.check(),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.network)),
    );
    await flaky.check();
    expect(attempts, 2);
  });

  test('translates SMB errors', () async {
    await expectLater(
      driver.list('/missing'),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.notFound)),
    );
    session.failWith = const Smb2Exception('logon failure', type: Smb2ErrorType.auth);
    await expectLater(
      driver.check(),
      throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.unauthorized)),
    );
  });

  test('reads an inclusive range in one request when it fits a chunk', () async {
    final entry = await driver.stat('/film.mkv');
    session.calls.clear();
    final bytes = await driver.openRead(entry, start: 2, end: 5).expand((c) => c).toList();
    expect(bytes, [2, 3, 4, 5]);
    expect(session.calls, ['read:Media/film.mkv@2+4']);
  });

  test('an open-ended read stops at end of file', () async {
    final entry = await driver.stat('/film.mkv');
    final bytes = await driver.openRead(entry, start: 7).expand((c) => c).toList();
    expect(bytes, [7, 8, 9]);
  });

  test('a large read is split into chunks at increasing offsets', () async {
    const size = SmbStorageDriver.readChunkSize * 2 + 5;
    session.files['Media/big.mkv'] = Uint8List(size);
    final entry = await driver.stat('/big.mkv');
    session.calls.clear();
    final total = await driver.openRead(entry).fold<int>(0, (sum, chunk) => sum + chunk.length);
    expect(total, size);
    expect(session.calls, [
      'read:Media/big.mkv@0+${SmbStorageDriver.readChunkSize}',
      'read:Media/big.mkv@${SmbStorageDriver.readChunkSize}+${SmbStorageDriver.readChunkSize}',
      'read:Media/big.mkv@${SmbStorageDriver.readChunkSize * 2}+${SmbStorageDriver.readChunkSize}',
    ]);
  });

  test('close disconnects and refuses further use', () async {
    await driver.check();
    await driver.close();
    expect(session.closed, isTrue);
    await expectLater(driver.check(), throwsA(isA<StorageException>()));
  });
}
