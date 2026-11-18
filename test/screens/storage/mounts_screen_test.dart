import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/screens/storage/mount_edit_screen.dart';
import 'package:plezy/screens/storage/mounts_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

class _ClosingRaceDriver implements StorageDriver {
  bool _closed = false;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<void> check() async {
    await Future<void>.delayed(Duration.zero);
    if (_closed) throw StateError('Client is closed');
  }

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    await Future<void>.delayed(Duration.zero);
    if (_closed) throw StateError('Client is closed');
    return const [];
  }

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: path, isDirectory: true);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) => const Stream.empty();

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  testWidgets('MountsScreen omits the manual scrape status card and keeps scraper settings action', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final registry = MountRegistry(db);
    await registry.upsert(
      const StorageMount(
        id: 'm1',
        kind: StorageKind.local,
        displayName: 'Local Movies',
        config: {MountKeys.rootPath: '/movies'},
      ),
    );
    final mounts = MountManager(registry);
    final repo = LibraryRepository(db);
    final scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mounts);
    addTearDown(() async {
      scans.dispose();
      await mounts.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<MountManager>.value(value: mounts),
          ChangeNotifierProvider<LibraryScanService>.value(value: scans),
        ],
        child: const InputModeTracker(
          child: MaterialApp(home: MountsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local Movies'), findsOneWidget);
    expect(find.text(t.storage.scrapeStart), findsNothing);
    expect(find.text(t.storage.scrapeTitle), findsNothing);
    expect(find.byTooltip(t.storage.scraperSettings), findsOneWidget);

    // Unmount MountsScreen and drain Drift's StreamQueryStore close timer before closing db.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('saving a Quark mount from MountEditScreen does not close the newly created scan driver', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final registry = MountRegistry(db);
    final mounts = MountManager(registry, driverFactory: (mount, {bool useFallback = false}) => _ClosingRaceDriver());
    final repo = LibraryRepository(db);
    final scans = LibraryScanService(repository: repo, scanner: LibraryScanner(db, repo), mounts: mounts);
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: mounts,
      scanService: scans,
      enableLanUdp: false,
      autoStartLanService: false,
    );
    await sync.initialize();
    addTearDown(() async {
      sync.dispose();
      scans.dispose();
      await mounts.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<MountManager>.value(value: mounts),
          ChangeNotifierProvider<LibraryScanService>.value(value: scans),
          ChangeNotifierProvider<SyncAndScanCoordinator>.value(value: sync),
        ],
        child: const InputModeTracker(child: MaterialApp(home: MountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.storage.addMount));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.storage.kind.quark));
    await tester.pumpAndSettle();

    final editScrollable = find.descendant(of: find.byType(MountEditScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text(t.storage.sectionAdvanced), 200, scrollable: editScrollable);
    await tester.tap(find.text(t.storage.sectionAdvanced));
    await tester.pumpAndSettle();

    final cookieField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == t.storage.quarkCookieManual,
    );
    await tester.scrollUntilVisible(cookieField, 200, scrollable: editScrollable);
    await tester.enterText(cookieField, '__pus=test-cookie; uid=12345');
    await tester.pump();

    await tester.tap(find.text(t.storage.testAndSave));
    await tester.pumpAndSettle();

    expect(find.byType(MountsScreen), findsOneWidget);
    expect(find.byType(MountEditScreen), findsNothing);

    final savedMounts = await registry.list();
    expect(savedMounts, hasLength(1));
    final savedMount = savedMounts.single;
    expect(scans.statusOf(savedMount.id).error, isNull);
    expect(find.textContaining('Client is closed'), findsNothing);
    expect(mounts.statusOf(savedMount.id), MountOnlineStatus.onlinePrimary);

    // Unmount MountsScreen and drain Drift's StreamQueryStore close timer before closing db.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
