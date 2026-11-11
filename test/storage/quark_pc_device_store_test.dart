import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_pc_device_store.dart';
import 'package:plezy/storage/drivers/quark_pc_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late SharedPreferencesAsyncPlatform? previousAsyncPlatform;
  late InMemorySharedPreferencesAsync asyncStore;
  late SharedPreferencesWithCache prefs;

  setUp(() async {
    previousAsyncPlatform = SharedPreferencesAsyncPlatform.instance;
    asyncStore = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = asyncStore;
    prefs = await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions());
    QuarkPcDeviceStore.resetForTest();
  });

  tearDown(() {
    QuarkPcDeviceStore.resetForTest();
    SharedPreferencesAsyncPlatform.instance = previousAsyncPlatform;
  });

  group('QuarkPcDeviceStore', () {
    test('loadIfPresent does not generate a device when storage is empty', () async {
      expect(await QuarkPcDeviceStore.loadIfPresent(prefs: prefs), isNull);
      expect(QuarkPcDeviceStore.cached, isNull);
    });

    test('getOrCreate persists a single device across simulated restarts', () async {
      final first = await QuarkPcDeviceStore.getOrCreate(prefs: prefs);
      expect(first.utdid, isNotEmpty);
      expect(first.machine, startsWith('DESKTOP-'));
      expect(QuarkPcDeviceStore.cached?.utdid, first.utdid);

      // Same in-memory run (e.g., mode switch or second mount).
      final second = await QuarkPcDeviceStore.getOrCreate(prefs: prefs);
      expect(second.utdid, first.utdid);
      expect(second.machine, first.machine);

      // Simulate cold restart with a fresh cache over the same backing store.
      QuarkPcDeviceStore.resetForTest();
      final restartedPrefs = await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(),
      );
      final loaded = await QuarkPcDeviceStore.loadIfPresent(prefs: restartedPrefs);
      expect(loaded?.utdid, first.utdid);
      expect(loaded?.machine, first.machine);

      // In-memory fast path returns cached value without needing prefs again.
      final fromMemory = await QuarkPcDeviceStore.getOrCreate();
      expect(fromMemory.utdid, first.utdid);
      expect(fromMemory.machine, first.machine);
    });

    test('adoptIfAbsent saves existing mount device when store has none and preserves first owner', () async {
      const firstMountDevice = QuarkPcDevice(utdid: 'utdid-1', machine: 'DESKTOP-AAAAAA');
      const otherMountDevice = QuarkPcDevice(utdid: 'utdid-2', machine: 'DESKTOP-BBBBBB');

      final adopted = await QuarkPcDeviceStore.adoptIfAbsent(firstMountDevice, prefs: prefs);
      expect(adopted.utdid, 'utdid-1');
      expect(adopted.machine, 'DESKTOP-AAAAAA');

      final ignored = await QuarkPcDeviceStore.adoptIfAbsent(otherMountDevice, prefs: prefs);
      expect(ignored.utdid, 'utdid-1');
      expect(ignored.machine, 'DESKTOP-AAAAAA');

      // After clearing memory cache, persisted value still wins over a different seed.
      QuarkPcDeviceStore.resetForTest();
      final fromDisk = await QuarkPcDeviceStore.getOrCreate(seed: otherMountDevice, prefs: prefs);
      expect(fromDisk.utdid, 'utdid-1');
      expect(fromDisk.machine, 'DESKTOP-AAAAAA');
    });
  });
}
