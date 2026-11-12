import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';

import '../test_helpers/prefs.dart';

void main() {
  late AppDatabase db;
  late MountRegistry registry;

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    registry = MountRegistry(db);
  });

  tearDown(() async {
    await db.close();
  });

  StorageMount quarkMount({String id = 'm1'}) => StorageMount(
    id: id,
    kind: StorageKind.quark,
    displayName: 'My Quark',
    config: const {MountKeys.rootFolderId: 'abc', MountKeys.requestIntervalMs: 1500},
    secrets: const {MountKeys.secretCookie: '__pus=secret-value'},
  );

  test('round-trips a mount including its secrets', () async {
    await registry.upsert(quarkMount());
    final loaded = (await registry.list()).single;
    expect(loaded.kind, StorageKind.quark);
    expect(loaded.displayName, 'My Quark');
    expect(loaded.configString(MountKeys.rootFolderId), 'abc');
    expect(loaded.configInt(MountKeys.requestIntervalMs), 1500);
    expect(loaded.secret(MountKeys.secretCookie), '__pus=secret-value');
  });

  test('secrets are encrypted at rest and kept out of the config column', () async {
    await registry.upsert(quarkMount());
    final row = await db.select(db.mounts).getSingle();
    expect(row.secrets, startsWith('enc:v1:'));
    expect(row.secrets, isNot(contains('secret-value')));
    expect(row.configJson, isNot(contains('secret-value')));
  });

  test('editing keeps the creation time; updateSecret changes one secret', () async {
    await registry.upsert(quarkMount());
    final createdAt = (await registry.get('m1'))!.createdAt;

    await registry.upsert(quarkMount().copyWith(displayName: 'Renamed'));
    await registry.updateSecret('m1', MountKeys.secretCookie, '__pus=rotated');

    final loaded = (await registry.get('m1'))!;
    expect(loaded.displayName, 'Renamed');
    expect(loaded.createdAt, createdAt);
    expect(loaded.secret(MountKeys.secretCookie), '__pus=rotated');
  });

  test('Quark tuning preserves the live driver, folder and rotated cookie', () async {
    final mount = quarkMount();
    await registry.upsert(mount);
    final manager = MountManager(registry);
    addTearDown(manager.dispose);
    final driver = manager.driverFor(mount);

    await Future.wait([
      manager.saveQuarkDownloadOptions(mount.id, connections: 12, chunkMiB: 3),
      registry.updateSecret(mount.id, MountKeys.secretCookie, '__pus=rotated'),
    ]);

    final loaded = (await registry.get(mount.id))!;
    expect(loaded.configInt(MountKeys.quarkDownloadConnections), 12);
    expect(loaded.configInt(MountKeys.quarkDownloadChunkMiB), 3);
    expect(loaded.configString(MountKeys.rootFolderId), 'abc');
    expect(loaded.secret(MountKeys.secretCookie), '__pus=rotated');
    expect(manager.driverFor(loaded), same(driver));
  });

  test('a mount whose key was lost loads without secrets', () async {
    await registry.upsert(quarkMount());
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();

    final loaded = (await registry.list()).single;
    expect(loaded.displayName, 'My Quark');
    expect(loaded.secrets, isEmpty);
  });

  test('rows of an unknown kind are skipped; remove deletes', () async {
    await registry.upsert(quarkMount());
    await db.customStatement("UPDATE mounts SET kind = 'from-the-future' WHERE id = 'm1'");
    expect(await registry.list(), isEmpty);

    await registry.upsert(quarkMount(id: 'm2'));
    await registry.remove('m2');
    expect(await registry.get('m2'), isNull);
  });
}
