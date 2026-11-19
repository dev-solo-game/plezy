import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/companion_remote/remote_playback_models.dart';
import 'package:plezy/models/companion_remote/remote_session.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/companion_remote/mobile_remote_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

/// Drives the screen through session states without a peer connection.
class _SessionStatusProvider extends CompanionRemoteProvider {
  RemoteSessionStatus _status = RemoteSessionStatus.connected;
  RemotePlayerSnapshot _snapshot = RemotePlayerSnapshot.idle;
  final List<({RemoteCommandType type, Map<String, dynamic>? data})> sent = [];

  @override
  RemoteSessionStatus get status => _status;

  @override
  bool get isConnected => _status == RemoteSessionStatus.connected;

  @override
  RemotePlayerSnapshot get remotePlayerSnapshot => _snapshot;

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) {
    sent.add((type: type, data: data));
  }

  set sessionStatus(RemoteSessionStatus value) {
    _status = value;
    notifyListeners();
  }

  set snapshot(RemotePlayerSnapshot value) {
    _snapshot = value;
    notifyListeners();
  }
}

RemotePlayerSnapshot _sampleActiveSnapshot() => const RemotePlayerSnapshot(
  active: true,
  stage: 'playing',
  mediaKind: 'episode',
  currentItemKey: '102',
  title: 'The Kingsroad',
  seriesTitle: 'Game of Thrones',
  seasonNumber: 1,
  episodeNumber: 2,
  playing: true,
  positionMs: 120000,
  durationMs: 3600000,
  volume: 80,
  playbackRate: 1.0,
  boxFitMode: 0,
  isDesktopHost: true,
  audioSyncOffsetMs: 0,
  subtitleSyncOffsetMs: 100,
  canPrevious: true,
  canNext: true,
  canSkipIntro: true,
  audioTracks: [
    RemoteTrackOption(id: 'mpv:1', label: 'English (AAC Stereo)', selected: true),
    RemoteTrackOption(id: 'mpv:2', label: 'Japanese (AC3 5.1)'),
  ],
  subtitleTracks: [
    RemoteTrackOption(id: 'off', label: 'Off'),
    RemoteTrackOption(id: 'mpv:1', label: 'Chinese Simplified (ASS)', selected: true),
  ],
  qualities: [
    RemoteQualityOption(id: 'original', label: 'Original', selected: true),
    RemoteQualityOption(id: '1080p', label: '1080p'),
  ],
  seasons: [
    RemoteSeasonSummary(seasonId: 10, itemKey: '10', seasonNumber: 1, title: 'Season 1', episodeCount: 2),
    RemoteSeasonSummary(seasonId: 20, itemKey: '20', seasonNumber: 2, title: 'Season 2', episodeCount: 1),
  ],
  browsedSeasonNumber: 1,
  episodes: [
    RemoteEpisodeSummary(itemKey: '101', seasonNumber: 1, episodeNumber: 1, title: 'Winter Is Coming', watched: true),
    RemoteEpisodeSummary(itemKey: '102', seasonNumber: 1, episodeNumber: 2, title: 'The Kingsroad', current: true),
  ],
);

void main() {
  testWidgets('keeps scroll offset across a reconnect and renders playback snapshot controls', (tester) async {
    // Short enough that the playback control center scrolls.
    tester.view.physicalSize = const Size(420, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = _SessionStatusProvider()..snapshot = _sampleActiveSnapshot();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: provider,
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const MobileRemoteScreen()),
      ),
    );

    expect(find.textContaining('S01E02'), findsOneWidget);
    expect(find.text('Game of Thrones'), findsOneWidget);

    final verticalScrollFinder = find
        .descendant(
          of: find.byKey(const PageStorageKey<String>('remote_control_scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(find.byKey(const PageStorageKey<String>('remote_control_scroll')), const Offset(0, -240));
    await tester.pumpAndSettle();
    final scrolledTo = tester.state<ScrollableState>(verticalScrollFinder).position.pixels;
    expect(scrolledTo, greaterThan(0));

    provider.sessionStatus = RemoteSessionStatus.reconnecting;
    await tester.pump();
    expect(find.text(t.companionRemote.remote.reconnecting), findsOneWidget);
    expect(find.byKey(const PageStorageKey<String>('remote_control_scroll')), findsNothing);

    provider.sessionStatus = RemoteSessionStatus.connected;
    await tester.pump();
    expect(find.byKey(const PageStorageKey<String>('remote_control_scroll')), findsOneWidget);
    expect(tester.state<ScrollableState>(verticalScrollFinder).position.pixels, scrolledTo);
  });

  testWidgets('dispatches speed, episode, aspect mode, skip, and sync offset commands', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = _SessionStatusProvider()..snapshot = _sampleActiveSnapshot();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: provider,
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const RemoteControlScreen()),
      ),
    );

    await tester.tap(find.bySemanticsLabel(t.companionRemote.remote.playPause));
    expect(provider.sent.last.type, RemoteCommandType.playPause);

    await tester.tap(find.text(t.companionRemote.skipIntro));
    expect(provider.sent.last.type, RemoteCommandType.skipIntro);

    await tester.tap(find.text('1.5x'));
    expect(provider.sent.last.type, RemoteCommandType.setRate);
    expect(provider.sent.last.data, {'rate': 1.5});

    await tester.tap(find.text('Winter Is Coming'));
    expect(provider.sent.last.type, RemoteCommandType.playEpisodeItem);
    expect(provider.sent.last.data, {'itemKey': '101'});

    await tester.tap(find.text('1080p'));
    expect(provider.sent.last.type, RemoteCommandType.selectQuality);
    expect(provider.sent.last.data, {'qualityId': '1080p'});

    await tester.tap(find.text(t.companionRemote.aspectCover));
    expect(provider.sent.last.type, RemoteCommandType.setBoxFitMode);
    expect(provider.sent.last.data, {'mode': 1});

    await tester.tap(find.text(t.companionRemote.aspectStretch));
    expect(provider.sent.last.type, RemoteCommandType.setBoxFitMode);
    expect(provider.sent.last.data, {'mode': 2});

    await tester.tap(find.byTooltip('+100 ms').first);
    expect(provider.sent.last.type, RemoteCommandType.setSyncOffset);
    expect(provider.sent.last.data, {'subtitleMs': 200});
  });

  testWidgets('disables progress slider at zero instead of clamping positive position to full when duration is 0', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = _SessionStatusProvider()
      ..snapshot = const RemotePlayerSnapshot(
        active: true,
        stage: 'playing',
        title: 'Episode 16',
        playing: true,
        positionMs: 5000,
        durationMs: 0,
      );
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: provider,
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const RemoteControlScreen()),
      ),
    );

    final progressSlider = tester.widgetList<Slider>(find.byType(Slider)).first;
    expect(progressSlider.value, 0.0);
    expect(progressSlider.onChanged, isNull);
    expect(find.text('0:05'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
  });
}
