import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/library_scan_service.dart';
import 'package:plezy/library/library_scanner.dart';
import 'package:plezy/library/library_scrape_runner.dart';
import 'package:plezy/library/library_settings.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/screens/storage/scraper_settings_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/session/app_session_controller.dart';
import 'package:plezy/session/app_session_models.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/ttplay/ttplay_session_binder.dart';
import 'package:plezy/widgets/library_status_indicator.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

class _HoldDriver implements StorageDriver {
  _HoldDriver(this.gate, this.listedFirst);

  final Completer<void> gate;
  final Completer<void> listedFirst;

  @override
  StorageKind get kind => StorageKind.quark;

  @override
  Future<void> check() async {}

  @override
  Future<List<StorageEntry>> list(String path, {StorageEntry? parent}) async {
    if (path == '/Anime') {
      if (!listedFirst.isCompleted) listedFirst.complete();
      await gate.future;
      return const [
        StorageEntry(path: '/Anime/Ep01.mkv', name: 'Ep01.mkv', isDirectory: false, size: 100),
      ];
    }
    return const [];
  }

  @override
  Future<StorageEntry> stat(String path) async => StorageEntry(path: path, name: 'x', isDirectory: false);

  @override
  Stream<List<int>> openRead(StorageEntry entry, {int start = 0, int? end}) async* {}

  @override
  Future<void> close() async {}
}

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

  testWidgets('surfaces live cloud scan status and cancelling state from TtplaySessionBinder', (tester) async {
    resetSharedPreferencesForTest();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

    final gate = Completer<void>();
    final listedFirst = Completer<void>();
    final sseController = StreamController<List<int>>();

    final repo = LibraryRepository(db);
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
    final serverManager = MultiServerManager();
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    final liveSession = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:8090',
      username: 'alice',
      accessToken: 'usr_live',
      householdId: 'hh_1',
      memberId: 'mem_1',
    );
    sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: liveSession);

    final binder = TtplaySessionBinder(
      sessionController: sessionController,
      serverManager: serverManager,
      localLibraryClient: localClient,
      isTv: () => false,
      httpClientFactory: () => MockClient.streaming((req, _) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/api/v1/sources/src_1/scan-sessions') {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'code': 0,
                  'session': {
                    'id': 'sess_live',
                    'source_id': 'src_1',
                    'folder_id': 'f_1',
                    'type': 'folder',
                    'folders': [
                      {'id': 'f_1', 'path': '/Anime', 'exclude_paths': <String>[]},
                    ],
                  },
                }),
              ),
            ),
            200,
          );
        }
        if (req.method == 'POST' && path.startsWith('/api/v1/scan-sessions/')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'code': 0, 'receipt': {'batch_no': 1, 'accepted': 0}}))),
            200,
          );
        }
        if (req.method == 'GET' && path == '/api/v1/events') {
          return http.StreamedResponse(sseController.stream, 200);
        }
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'error': 'not_found'}))), 404);
      }),
    );
    binder.seedSelfHostedSynchronously(liveSession);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryScanService>.value(value: scans),
          ChangeNotifierProvider<TtplaySessionBinder?>.value(value: binder),
          Provider<LibrarySettingsStore>.value(value: settingsStore),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: const LibraryStatusIndicator(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scanFuture = binder.cloudScanRunner!.runScan(
      sourceId: 'src_1',
      folderId: 'f_1',
      scanType: 'folder',
      targetLabel: 'Quark · /Anime',
      driver: _HoldDriver(gate, listedFirst),
    );
    await listedFirst.future;
    await tester.pump();

    expect(find.text('云端扫描 · 已遍历 0 目录'), findsOneWidget);
    final tooltip1 = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip1.message, contains('Quark · /Anime（扫描中）'));

    binder.cloudScanRunner!.cancelScan('src_1', folderId: 'f_1');
    await tester.pump();
    expect(find.text('云端扫描 · 正在取消...'), findsOneWidget);

    gate.complete();
    await scanFuture;
    await sseController.close();
    binder.dispose();
    await tester.pump();
  });

  testWidgets('surfaces cloud incremental scan status text in LibraryStatusIndicator', (tester) async {
    resetSharedPreferencesForTest();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

    final gate = Completer<void>();
    final started = Completer<void>();
    final sseController = StreamController<List<int>>();

    final repo = LibraryRepository(db);
    final mounts = MountManager(MountRegistry(db));
    final localClient = LocalLibraryClient(repository: repo, mounts: mounts);
    final serverManager = MultiServerManager();
    final sessionController = AppSessionController(db: db, mountManager: mounts);
    final liveSession = SelfHostedSession(
      serverUrl: 'http://127.0.0.1:8090',
      username: 'alice',
      accessToken: 'usr_inc',
      householdId: 'hh_1',
      memberId: 'mem_1',
    );
    sessionController.debugSetStateForTesting(mode: AppLoginMode.selfHosted, selfHostedSession: liveSession);

    final binder = TtplaySessionBinder(
      sessionController: sessionController,
      serverManager: serverManager,
      localLibraryClient: localClient,
      isTv: () => false,
      httpClientFactory: () => MockClient.streaming((req, _) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/api/v1/sources/src_1/scan-sessions') {
          if (!started.isCompleted) started.complete();
          await gate.future;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'code': 0,
                  'session': {
                    'id': 'sess_inc',
                    'source_id': 'src_1',
                    'type': 'incremental',
                    'incremental_watermark': 0,
                    'folders': [
                      {'id': 'f_1', 'path': '/Anime', 'exclude_paths': <String>[]},
                    ],
                  },
                }),
              ),
            ),
            200,
          );
        }
        if (req.method == 'POST' && path.startsWith('/api/v1/scan-sessions/')) {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'code': 0}))), 200);
        }
        if (req.method == 'GET' && path == '/api/v1/events') {
          return http.StreamedResponse(sseController.stream, 200);
        }
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'error': 'not_found'}))), 404);
      }),
    );
    binder.seedSelfHostedSynchronously(liveSession);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryScanService>.value(value: scans),
          ChangeNotifierProvider<TtplaySessionBinder?>.value(value: binder),
          Provider<LibrarySettingsStore>.value(value: settingsStore),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: const LibraryStatusIndicator(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scanFuture = binder.cloudScanRunner!.runQuarkIncrementalScan(
      sourceId: 'src_1',
      targetLabel: 'Quark',
      driver: _HoldDriver(gate, started),
      searchUpdatedPageOverride: (_, {size = 100}) async => const [],
      folderAncestryOverride: (_) async => const [],
      rootFolderIdOverride: '0',
    );
    await started.future;
    await tester.pump();

    expect(find.text('云端增量检查中...'), findsOneWidget);

    gate.complete();
    await scanFuture;
    await sseController.close();
    binder.dispose();
    await tester.pump();
  });
}
