import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/storage/drivers/local_storage_driver.dart';
import 'package:plezy/storage/request_throttle.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_path.dart';

void main() {
  group('StoragePath', () {
    test('normalize makes paths absolute and collapses separators', () {
      expect(StoragePath.normalize(''), '/');
      expect(StoragePath.normalize('a//b/'), '/a/b');
      expect(StoragePath.normalize(r'a\b'), '/a/b');
      expect(StoragePath.normalize('/a/./b'), '/a/b');
    });

    test('normalize never climbs above the root', () {
      expect(StoragePath.normalize('/../../etc/passwd'), '/etc/passwd');
      expect(StoragePath.normalize('/a/../../b'), '/b');
    });

    test('parent, name and extension', () {
      expect(StoragePath.parent('/a/b/c.mkv'), '/a/b');
      expect(StoragePath.parent('/a'), '/');
      expect(StoragePath.parent('/'), '/');
      expect(StoragePath.name('/a/b/c.mkv'), 'c.mkv');
      expect(StoragePath.extension('/a/Movie.2020.MKV'), 'mkv');
      expect(StoragePath.extension('/a/.hidden'), '');
      expect(StoragePath.extension('/a/noext'), '');
    });
  });

  group('RequestThrottle', () {
    test('spaces calls by the interval and keeps arrival order', () {
      fakeAsync((async) {
        final throttle = RequestThrottle(const Duration(seconds: 1));
        final started = <String>[];
        for (final name in ['a', 'b', 'c']) {
          throttle.run(() async => started.add('$name@${async.elapsed.inMilliseconds}'));
        }
        async.elapse(const Duration(seconds: 5));
        expect(started, ['a@0', 'b@1000', 'c@2000']);
      });
    });

    test('a failing call does not block the queue', () {
      fakeAsync((async) {
        final throttle = RequestThrottle(const Duration(milliseconds: 100));
        Object? error;
        int? result;
        throttle.run<void>(() async => throw StateError('boom')).catchError((Object e) => error = e);
        throttle.run(() async => 7).then((v) => result = v);
        async.elapse(const Duration(seconds: 1));
        expect(error, isStateError);
        expect(result, 7);
      });
    });
  });

  group('LocalStorageDriver', () {
    late Directory root;
    late LocalStorageDriver driver;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('plezy_local_driver_');
      await Directory(p.join(root.path, 'Movies')).create();
      await File(p.join(root.path, 'Movies', 'film.mkv')).writeAsBytes(List<int>.generate(100, (i) => i));
      await File(p.join(root.path, 'readme.txt')).writeAsString('hi');
      driver = LocalStorageDriver(rootPath: root.path);
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('check fails for a missing root', () async {
      final missing = LocalStorageDriver(rootPath: p.join(root.path, 'nope'));
      await expectLater(
        missing.check(),
        throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.notFound)),
      );
    });

    test('lists children with sizes and mount-relative paths', () async {
      final entries = await driver.list('/')
        ..sort((a, b) => a.name.compareTo(b.name));
      expect(entries.map((e) => e.path), ['/Movies', '/readme.txt']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 2);

      final nested = await driver.list('/Movies');
      expect(nested.single.path, '/Movies/film.mkv');
      expect(nested.single.size, 100);
    });

    test('listing a missing directory reports notFound', () async {
      await expectLater(
        driver.list('/missing'),
        throwsA(isA<StorageException>().having((e) => e.kind, 'kind', StorageErrorKind.notFound)),
      );
    });

    test('paths cannot escape the root', () async {
      await File(p.join(root.parent.path, 'plezy_outside_secret.txt')).writeAsString('secret');
      addTearDown(() => File(p.join(root.parent.path, 'plezy_outside_secret.txt')).delete());
      await expectLater(driver.stat('/../plezy_outside_secret.txt'), throwsA(isA<StorageException>()));
    });

    test('openRead honours an inclusive byte range', () async {
      final entry = await driver.stat('/Movies/film.mkv');
      final bytes = await driver.openRead(entry, start: 10, end: 19).expand((c) => c).toList();
      expect(bytes, List<int>.generate(10, (i) => i + 10));

      final tail = await driver.openRead(entry, start: 95).expand((c) => c).toList();
      expect(tail, [95, 96, 97, 98, 99]);
    });
  });
}
