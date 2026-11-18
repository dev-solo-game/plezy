import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/screens/storage/scraper_settings_screen.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/widgets/library_status_indicator.dart';
import 'package:provider/provider.dart';

class _StubScanService extends LibraryScanService {
  _StubScanService(LibraryRepository repository, AppDatabase db)
    : super(repository: repository, scanner: LibraryScanner(db, repository), mounts: MountManager(MountRegistry(db)));

  LibraryUpdate? _fakeUpdate;
  ({LibraryUpdateMode mode, String message})? _fakeUpdateError;
  LibraryScrapeStatus _fakeScrapeStatus = const LibraryScrapeStatus();

  @override
  LibraryUpdate? get update => _fakeUpdate;

  @override
  ({LibraryUpdateMode mode, String message})? get updateError => _fakeUpdateError;

  @override
  LibraryScrapeStatus get scrapeStatus => _fakeScrapeStatus;

  void setStatus({
    LibraryUpdate? update,
    ({LibraryUpdateMode mode, String message})? updateError,
    LibraryScrapeStatus scrapeStatus = const LibraryScrapeStatus(),
  }) {
    _fakeUpdate = update;
    _fakeUpdateError = updateError;
    _fakeScrapeStatus = scrapeStatus;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _StubScanService scans;
  late LibrarySettingsStore settingsStore;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    scans = _StubScanService(repo, db);
    settingsStore = LibrarySettingsStore(db);
  });

  tearDown(() async {
    scans.dispose();
    await db.close();
  });

  Future<void> pumpIndicator(WidgetTester tester, {bool includeSettingsStore = true}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryScanService>.value(value: scans),
          if (includeSettingsStore) Provider<LibrarySettingsStore>.value(value: settingsStore),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: const LibraryStatusIndicator(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows two-line tooltip and compact inline text when scan and scrape run together', (tester) async {
    final job = LibraryUpdate(LibraryUpdateMode.full, {'m1'})
      ..scanning = true
      ..scraping = true
      ..filesSeen = 12
      ..scraped = 3
      ..scrapeTotal = 10;
    scans.setStatus(
      update: job,
      scrapeStatus: const LibraryScrapeStatus(running: true, done: 3, total: 10),
    );

    await pumpIndicator(tester);

    expect(find.text('${t.storage.scanShort(files: 12)} · ${t.storage.scrapeShort(done: 3, total: 10)}'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(
      tooltip.message,
      '${t.storage.fullUpdate} · ${t.storage.scanning(files: 12)}\n'
      '${t.storage.scrapeTitle} · ${t.storage.scrapingProgress(done: 3, total: 10)}',
    );
  });

  testWidgets('shows waiting-to-scrape on tooltip line 2 before streaming scrape starts', (tester) async {
    final job = LibraryUpdate(LibraryUpdateMode.full, {'m1'})
      ..scanning = true
      ..scraping = false
      ..filesSeen = 5;
    scans.setStatus(update: job);

    await pumpIndicator(tester);

    expect(find.text('${t.storage.fullUpdate} · ${t.storage.scanning(files: 5)}'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(
      tooltip.message,
      '${t.storage.fullUpdate} · ${t.storage.scanning(files: 5)}\n'
      '${t.storage.scrapeTitle} · ${t.storage.waitingToScrape}',
    );
  });

  testWidgets('shows completed scan line 1 and scraping line 2 during post-scan scrape', (tester) async {
    final job = LibraryUpdate(LibraryUpdateMode.full, {'m1'})
      ..scanning = false
      ..scraping = true
      ..filesSeen = 24
      ..scraped = 4
      ..scrapeTotal = 8;
    scans.setStatus(
      update: job,
      scrapeStatus: const LibraryScrapeStatus(running: true, done: 4, total: 8),
    );

    await pumpIndicator(tester);

    expect(find.text(t.storage.scrapingProgress(done: 4, total: 8)), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(
      tooltip.message,
      '${t.storage.fullUpdate} · ${t.storage.scanCompletedFiles(files: 24)}\n'
      '${t.storage.scrapeTitle} · ${t.storage.scrapingProgress(done: 4, total: 8)}',
    );
  });

  testWidgets('surfaces standalone scrapeStatus progress when update is null', (tester) async {
    scans.setStatus(scrapeStatus: const LibraryScrapeStatus(running: true, done: 2, total: 5));

    await pumpIndicator(tester);

    expect(find.text(t.storage.scrapingProgress(done: 2, total: 5)), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, '${t.storage.scrapeTitle} · ${t.storage.scrapingProgress(done: 2, total: 5)}');
  });

  testWidgets('surfaces standalone noTmdbKey note and opens ScraperSettingsScreen on tap', (tester) async {
    scans.setStatus(scrapeStatus: const LibraryScrapeStatus(note: LibraryScrapeRunner.noTmdbKey));

    await pumpIndicator(tester);

    expect(find.text('${t.storage.scrapeTitle} · ${t.storage.tmdbTestNoKey}'), findsOneWidget);
    expect(find.byIcon(Symbols.error_outline_rounded), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, '${t.storage.scrapeTitle}\n${t.storage.scrapeNoKey}');

    await tester.tap(find.byType(LibraryStatusIndicator));
    await tester.pumpAndSettle();

    expect(find.byType(ScraperSettingsScreen), findsOneWidget);
  });
}
