import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/work_identity.dart';
import 'package:plezy/media/work_skip_settings.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/services/work_skip_settings_store.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/desktop_video_controls.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/sheets/video_settings_sheet.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/skip_marker_button.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import 'package:plezy/widgets/work_skip_settings_dialog.dart';
import 'package:plezy/widgets/dialog_action_button.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

/// Optional screenshot directory: Flutter renders production widgets headlessly.
const screenshotDirectory = String.fromEnvironment('SKIP_SCREENSHOTS');

class _Player implements Player {
  Duration position = const Duration(minutes: 10);
  Duration duration = const Duration(minutes: 40);
  bool playing = true;
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final playingEvents = StreamController<bool>.broadcast();
  final seeks = <Duration>[];
  Completer<void>? seekGate;
  Duration? seekLanding;
  void emit(Duration value) {
    position = value;
    positions.add(value);
  }

  void resize(Duration value) {
    duration = value;
    durations.add(value);
  }

  Future<void> close() async {
    await positions.close();
    await durations.close();
    await playingEvents.close();
  }

  @override
  Future<void> pause() async {
    playing = false;
    playingEvents.add(false);
  }

  @override
  Future<void> play() async {
    playing = true;
    playingEvents.add(true);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    if (seekGate != null) await seekGate!.future;
    emit(seekLanding ?? value);
  }

  @override
  String get playerType => 'mpv';
  @override
  PlayerState get state => PlayerState(playing: playing, position: position, duration: duration, seekable: true);
  @override
  PlayerStreams get streams => PlayerStreams(
    playing: playingEvents.stream,
    position: positions.stream,
    duration: durations.stream,
    completed: const Stream.empty(),
    buffering: const Stream.empty(),
    seekable: const Stream.empty(),
    buffer: const Stream.empty(),
    volume: const Stream.empty(),
    rate: const Stream.empty(),
    tracks: const Stream.empty(),
    track: const Stream.empty(),
    log: const Stream.empty(),
    error: const Stream.empty(),
    audioDevice: const Stream.empty(),
    audioDevices: const Stream.empty(),
    bufferRanges: const Stream.empty(),
    playbackRestart: const Stream.empty(),
    backendSwitched: const Stream.empty(),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late WorkSkipSettingsStore store;
  late MediaItem item;
  late WorkIdentity work;
  late _Player player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playback;
  late WatchTogetherProvider together;
  late SettingsService settings;
  late ValueNotifier<bool> firstFrame;
  late GlobalKey capture;
  int completions = 0;
  int nextCalls = 0;
  const rules = WorkSkipSettings(introEnabled: true, introEndMs: 60000, creditsEnabled: true, creditsDurationMs: 90000);

  setUp(() async {
    await LocaleSettings.setLocale(screenshotDirectory.isEmpty ? AppLocale.en : AppLocale.zh);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    TvDetectionService.debugSetAppleTVOverride(false);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = WorkSkipSettingsStore(db);
    final id = await LibraryRepository(db).insertItem(
      LibraryItemsCompanion.insert(
        kind: 'movie',
        libraryType: 'movie',
        title: '示例电影 A',
        sortTitle: 'a',
        tmdbId: const Value('100'),
        scrapedAt: const Value(1),
        addedAt: 1,
        updatedAt: 1,
      ),
    );
    item = testMediaItem(id: '$id', serverId: 'local-library', title: '示例电影 A · 夸克 / SMB', durationMs: 2400000);
    work = (await store.resolve(item, null))!;
    player = _Player();
    chrome = PlayerChromeController(initiallyVisible: true);
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playback = PlaybackStateProvider();
    together = WatchTogetherProvider();
    firstFrame = ValueNotifier(true);
    capture = GlobalKey();
    completions = 0;
    nextCalls = 0;
  });
  tearDown(() async {
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    volume.dispose();
    playback.dispose();
    together.dispose();
    chrome.dispose();
    toast.dispose();
    firstFrame.dispose();
    await player.close();
    await db.close();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pump(WidgetTester tester, {WorkSkipSettings? initial = rules, bool canControl = true}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    if (screenshotDirectory.isNotEmpty) {
      await tester.runAsync(() async {
        for (final (family, asset) in [
          ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
          ('Go Noto Current', 'assets/go-noto-current-regular.ttf'),
          (
            'packages/material_symbols_icons/MaterialSymbolsRounded',
            'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
          ),
        ]) {
          await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
        }
      });
    }
    final theme = monoTheme(MonoPalette.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: InputModeTracker(
          child: MultiProvider(
            providers: [
              Provider<AppDatabase>.value(value: db),
              ChangeNotifierProvider<PlaybackStateProvider>.value(value: playback),
              ChangeNotifierProvider<WatchTogetherProvider>.value(value: together),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                platform: TargetPlatform.windows,
                textTheme: theme.textTheme.apply(fontFamily: screenshotDirectory.isEmpty ? null : 'Go Noto Current'),
              ),
              home: Scaffold(
                body: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0xff141d29),
                        child: Center(
                          child: Text('隐藏模拟验收 · 本地电影 A', style: TextStyle(fontSize: 24, color: Colors.white38)),
                        ),
                      ),
                    ),
                    PlexVideoControls(
                      player: player,
                      volumeController: volume,
                      metadata: item,
                      initialSkipSettings: initial,
                      chromeController: chrome,
                      toastController: toast,
                      hasFirstFrame: firstFrame,
                      canControl: canControl,
                      canNavigateMediaItems: false,
                      onNext: () => nextCalls++,
                      onReachedEnd: ({skipAutoPlayCountdown = false}) => completions++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> flushDb(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (screenshotDirectory.isEmpty) return;
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(screenshotDirectory).create(recursive: true);
      await File('$screenshotDirectory/$name.png').writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chrome.cancelAutoHide();
    await tester.pump();
  }

  DesktopVideoControls controls(WidgetTester tester) => tester.widget(find.byType(DesktopVideoControls));

  testWidgets('intro immediately jumps; manually seeking back permits review', (tester) async {
    await pump(tester);
    player.emit(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();
    expect(player.seeks, [const Duration(seconds: 60)]);
    await controls(tester).onSeekRequested!(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(player.position, const Duration(seconds: 20));
    expect(find.byType(SkipMarkerButton), findsOneWidget);
    player.emit(const Duration(seconds: 61));
    await tester.pump();
    player.emit(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(seconds: 60), reason: 'leaving the range starts a new visit');
    await finish(tester);
  });

  testWidgets('credits wait five playing seconds, pause freezes timer, EOF uses completion', (tester) async {
    expect(settings.read(SettingsService.autoSkipDelay), 5);
    await pump(tester);
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump();
    await screenshot(tester, 'credits-countdown');
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 0);
    await player.pause();
    await tester.pump(const Duration(seconds: 10));
    expect(completions, 0);
    await player.play();
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(completions, 1);
    expect(nextCalls, 0);
    expect(player.playing, isFalse);
    await finish(tester);
  });

  testWidgets('cancel credits keeps playback and suppresses only this visit', (tester) async {
    await pump(tester);
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip(t.workSkip.cancelVisit));
    await tester.pump(const Duration(seconds: 8));
    expect(completions, 0);
    expect(player.playing, isTrue);
    player.emit(const Duration(minutes: 39, seconds: 5));
    await tester.pump(const Duration(seconds: 6));
    expect(completions, 0);
    await finish(tester);
  });

  testWidgets('zero credits delay and post-credit target', (tester) async {
    await settings.write(SettingsService.autoSkipDelay, 0);
    await pump(
      tester,
      initial: const WorkSkipSettings(creditsEnabled: true, creditsDurationMs: 90000, creditsResumeBeforeEndMs: 30000),
    );
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(minutes: 39, seconds: 30));
    expect(completions, 0);
    expect(player.playing, isTrue);
    await finish(tester);
  });

  testWidgets('invalid duration and first-frame gate never auto skip; duration is revalidated', (tester) async {
    firstFrame.value = false;
    player.position = const Duration(seconds: 15);
    await pump(tester);
    expect(player.seeks, isEmpty);
    firstFrame.value = true;
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(seconds: 60));
    player.resize(const Duration(seconds: 100));
    await tester.pump();
    player.emit(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 6));
    expect(player.position, const Duration(seconds: 15));
    expect(tester.widget<TimelineSlider>(find.byType(TimelineSlider)).skipMarkers, isEmpty);
    await finish(tester);
  });

  testWidgets('right click prefills intro, cancel resumes without seeking or saving', (tester) async {
    await pump(tester);
    final before = player.position;
    final rect = tester.getRect(find.byType(TimelineSlider));
    await tester.tapAt(Offset(rect.left + rect.width * .025, rect.center.dy), buttons: kSecondaryMouseButton);
    await flushDb(tester);
    expect(find.byType(WorkSkipSettingsDialog), findsOneWidget);
    expect(player.playing, isFalse);
    expect(find.text('01:00'), findsOneWidget);
    expect(player.position, before);
    expect(player.seeks, isEmpty);
    await screenshot(tester, 'timeline-right-click-intro');
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();
    expect(player.playing, isTrue);
    expect(player.position, before);
    expect((await tester.runAsync(() => store.read(work)))!.introEnabled, isFalse);
    await finish(tester);
  });

  testWidgets('right click credits preserves intro, saves bands and restores paused state', (tester) async {
    await tester.runAsync(() => store.save(work, rules));
    await player.pause();
    await pump(tester);
    final rect = tester.getRect(find.byType(TimelineSlider));
    await tester.tapAt(Offset(rect.left + rect.width * .95, rect.center.dy), buttons: kSecondaryMouseButton);
    await flushDb(tester);
    expect(player.playing, isFalse);
    expect(find.text('02:00'), findsOneWidget);
    expect(find.text('01:00'), findsOneWidget);
    await screenshot(tester, 'timeline-right-click-credits');
    await tester.tap(find.text(t.common.save));
    await flushDb(tester);
    expect(find.byType(WorkSkipSettingsDialog), findsNothing);
    expect(player.playing, isFalse);
    final saved = (await tester.runAsync(() => store.read(work)))!;
    expect(saved.creditsDurationMs, 120000);
    expect(saved.introEndMs, 60000);
    expect(tester.widget<TimelineSlider>(find.byType(TimelineSlider)).skipMarkers.length, 2);
    await screenshot(tester, 'saved-timeline-markers');
    await finish(tester);
  });

  testWidgets('player settings entry shares dialog, saving restores playback and immediately applies intro', (
    tester,
  ) async {
    await pump(tester);
    player.position = const Duration(seconds: 20);
    controls(tester).trackControlsState.onEditSkipSettings!();
    await flushDb(tester);
    expect(player.playing, isFalse);
    await tester.tap(find.text(t.workSkip.intro).first);
    await tester.pump();
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('intro-end')), matching: find.byType(TextField)),
      '01:10',
    );
    await screenshot(tester, 'work-skip-settings');
    await tester.tap(find.text(t.common.save));
    await flushDb(tester);
    expect(player.playing, isTrue);
    expect(player.position, const Duration(seconds: 70));
    expect((await tester.runAsync(() => store.read(work)))!.introEndMs, 70000);
    await finish(tester);
  });

  testWidgets('settings sheet exposes the common entry', (tester) async {
    await pump(tester);
    final state = controls(tester).trackControlsState;
    final context = tester.element(find.byType(PlexVideoControls));
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => VideoSettingsSheet(player: player, trackControlsState: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.workSkip.title), findsOneWidget);
    await screenshot(tester, 'player-settings-entry');
    await tester.tap(find.text(t.workSkip.title));
    await flushDb(tester);
    expect(find.byType(WorkSkipSettingsDialog), findsOneWidget);
    expect(player.playing, isFalse);
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();
    expect(player.playing, isTrue);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('one second post-credit scene is preserved, not completed', (tester) async {
    await settings.write(SettingsService.autoSkipDelay, 0);
    await pump(
      tester,
      initial: const WorkSkipSettings(creditsEnabled: true, creditsDurationMs: 90000, creditsResumeBeforeEndMs: 1000),
    );
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(minutes: 39, seconds: 59));
    expect(completions, 0);
    expect(player.playing, isTrue);
    await finish(tester);
  });

  testWidgets('replacement player has new position and duration subscriptions', (tester) async {
    await pump(tester);
    final oldPlayer = player;
    player = _Player();
    await pump(tester);
    oldPlayer.emit(const Duration(seconds: 15));
    await tester.pump();
    expect(player.seeks, isEmpty);
    player.emit(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(seconds: 60));
    player.resize(const Duration(seconds: 90));
    await tester.pump();
    player.emit(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 6));
    expect(player.position, const Duration(seconds: 10));
    await finish(tester);
    await oldPlayer.close();
  });

  testWidgets('late old position during seek cannot re-enable skipping the requested intro', (tester) async {
    await pump(tester);
    player.seekGate = Completer<void>();
    final seek = controls(tester).onSeekRequested!(const Duration(seconds: 20));
    player.emit(const Duration(seconds: 20)); // Optimistic target is not arrival.
    await tester.pump();
    player.emit(const Duration(minutes: 10, seconds: 1));
    await tester.pump(const Duration(seconds: 10));
    player.seekGate!.complete();
    await seek;
    player.seekGate = null;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(player.seeks, [const Duration(seconds: 20)]);
    expect(player.position, const Duration(seconds: 20));
    await finish(tester);
  });

  testWidgets('a seek landing outside the requested intro does not block later credits', (tester) async {
    await pump(tester);
    player.seekLanding = const Duration(seconds: 62);
    await controls(tester).onSeekRequested!(const Duration(seconds: 59));
    await tester.pump();
    expect(player.position, const Duration(seconds: 62));
    player.seekLanding = null;
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(completions, 1);
    await finish(tester);
  });

  testWidgets('editing freezes a running credits countdown and cancel resumes its remaining time', (tester) async {
    await pump(tester);
    player.emit(const Duration(minutes: 39));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    controls(tester).trackControlsState.onEditSkipSettings!();
    await flushDb(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(completions, 0);
    expect(player.playing, isFalse);
    await tester.tap(find.text(t.common.cancel));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(completions, 1);
    await finish(tester);
  });

  testWidgets('a new player loads saved work settings without injected ranges', (tester) async {
    await tester.runAsync(() => store.save(work, rules));
    await pump(tester, initial: null);
    await flushDb(tester);
    player.emit(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();
    expect(player.position, const Duration(seconds: 60));
    await finish(tester);
  });

  testWidgets('TV select operates the dialog toggle and cancel restores playback', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(null);
    await TvDetectionService.getInstance(forceTv: true);
    TvDetectionService.setForceTVSync(true);
    await pump(tester);
    controls(tester).trackControlsState.onEditSkipSettings!();
    await flushDb(tester);
    InputModeTracker.reportNonPointerInput();
    Focus.of(tester.element(find.text(t.workSkip.intro).first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    final end = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('intro-end')), matching: find.byType(TextField)),
    );
    expect(end.enabled, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await screenshot(tester, 'tv-work-skip-settings');
    bool cancelFocused() {
      var found = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
        if (element.widget case DialogActionButton(:final label) when label == t.common.cancel) found = true;
        return !found;
      });
      return found;
    }

    for (var i = 0; i < 8 && !cancelFocused(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(cancelFocused(), isTrue, reason: 'D-pad can reach the cancel action');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(WorkSkipSettingsDialog), findsNothing);
    expect(player.playing, isTrue);
    await finish(tester);
  });

  testWidgets('a viewer without control cannot auto skip or edit', (tester) async {
    await pump(tester, canControl: false);
    player.emit(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 6));
    expect(player.seeks, isEmpty);
    expect(controls(tester).trackControlsState.onEditSkipSettings, isNull);
    expect(controls(tester).onEditSkipAt, isNull);
    await finish(tester);
  });
}
