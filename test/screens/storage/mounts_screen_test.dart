import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/screens/storage/mounts_screen.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
