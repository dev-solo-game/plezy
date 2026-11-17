import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../focus/input_mode_tracker.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../utils/app_logger.dart';
import '../../utils/key_event_simulator.dart';

class CompanionRemoteReceiver {
  CompanionRemoteReceiver._();

  static CompanionRemoteReceiver? _instance;

  static CompanionRemoteReceiver get instance {
    _instance ??= CompanionRemoteReceiver._();
    return _instance!;
  }

  /// Owners prevent a disposed screen from clearing callbacks installed by a
  /// replacement screen later in the same frame.
  Object? navigationOwner;
  Object? playerOwner;
  VoidCallback? playerHomeFallback;

  VoidCallback? onTabNext;
  VoidCallback? onTabPrevious;
  VoidCallback? onTabDiscover;
  VoidCallback? onTabLibraries;
  VoidCallback? onTabSearch;
  VoidCallback? onTabDownloads;
  VoidCallback? onTabSettings;
  VoidCallback? onHome;
  void Function(String? query)? onSearchAction;
  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onPlayPause;
  VoidCallback? onNextTrack;
  VoidCallback? onPreviousTrack;
  VoidCallback? onStop;
  VoidCallback? onSeekForward;
  VoidCallback? onSeekBackward;
  VoidCallback? onSkipIntro;
  VoidCallback? onSkipCredits;
  VoidCallback? onVolumeUp;
  VoidCallback? onVolumeDown;
  VoidCallback? onVolumeMute;
  void Function(double volume)? onVolumeSet;
  VoidCallback? onSubtitles;
  VoidCallback? onAudioTracks;
  VoidCallback? onFullscreen;
  void Function(Duration position)? onSeekTo;
  void Function(double rate)? onSetRate;
  void Function(String trackId)? onSelectAudioTrack;
  void Function(String trackId)? onSelectSubtitleTrack;
  void Function(String qualityId)? onSelectQuality;
  void Function({int? audioMs, int? subtitleMs})? onSetSyncOffset;
  void Function(int mode)? onSetBoxFitMode;
  void Function(int seasonNumber)? onBrowseSeason;
  void Function(String itemKey)? onPlayEpisodeItem;
  Future<void> Function(Map<String, dynamic> data)? onPlayMedia;
  VoidCallback? onRequestState;

  /// The live music session's transport, installed by the session for its
  /// lifetime; returns whether it acted on the command. Transport commands go
  /// here while no video player owns the slots above: the space key that
  /// play/pause otherwise simulates only toggles the video player, and
  /// seek/next/previous/stop have no other handler.
  bool Function(RemoteCommandType type)? musicTransport;

  void handleCommand(RemoteCommand command, BuildContext? _) {
    appLogger.d('CompanionRemoteReceiver: Handling command: ${command.type}');

    // A paired phone cannot point, so any viewer command is evidence of a
    // pointerless device. Protocol frames, playback-parameter updates, and
    // player-only commands received while nothing is playing locally are not
    // viewer input: promoting on periodic heartbeats, phone sliders, or ignored
    // player controls would flip an idle desktop host into keyboard mode and
    // hide its cursor.
    if (_isViewerInput(command.type) &&
        !(_isPlayerCommand(command.type) && playerOwner == null && musicTransport == null)) {
      InputModeTracker.reportNonPointerInput();
      scheduleFrameIfIdle();
    }

    if (playerOwner == null && _isTransport(command.type) && (musicTransport?.call(command.type) ?? false)) return;

    switch (command.type) {
      case RemoteCommandType.dpadUp:
        simulateKeyPress(LogicalKeyboardKey.arrowUp);
      case RemoteCommandType.dpadDown:
        simulateKeyPress(LogicalKeyboardKey.arrowDown);
      case RemoteCommandType.dpadLeft:
        simulateKeyPress(LogicalKeyboardKey.arrowLeft);
      case RemoteCommandType.dpadRight:
        simulateKeyPress(LogicalKeyboardKey.arrowRight);
      case RemoteCommandType.select:
        simulateKeyPress(LogicalKeyboardKey.enter);
      case RemoteCommandType.back:
        simulateKeyPress(LogicalKeyboardKey.gameButtonB);
      case RemoteCommandType.contextMenu:
        simulateKeyPress(LogicalKeyboardKey.contextMenu);

      case RemoteCommandType.play:
        onPlay?.call();
      case RemoteCommandType.pause:
        onPause?.call();
      case RemoteCommandType.playPause:
        onPlayPause?.call();
      case RemoteCommandType.seekForward:
        onSeekForward?.call();
      case RemoteCommandType.seekBackward:
        onSeekBackward?.call();
      case RemoteCommandType.skipIntro:
        onSkipIntro?.call();
      case RemoteCommandType.skipCredits:
        onSkipCredits?.call();

      case RemoteCommandType.volumeUp:
        onVolumeUp?.call();
      case RemoteCommandType.volumeDown:
        onVolumeDown?.call();
      case RemoteCommandType.volumeMute:
        onVolumeMute?.call();
      case RemoteCommandType.volumeSet:
        final volume = (command.data?['volume'] as num?)?.toDouble();
        if (volume != null) onVolumeSet?.call(volume);

      case RemoteCommandType.tabNext:
        onTabNext?.call();
      case RemoteCommandType.tabPrevious:
        onTabPrevious?.call();
      case RemoteCommandType.tabDiscover:
        onTabDiscover?.call();
      case RemoteCommandType.tabLibraries:
        onTabLibraries?.call();
      case RemoteCommandType.tabSearch:
        onTabSearch?.call();
      case RemoteCommandType.tabDownloads:
        onTabDownloads?.call();
      case RemoteCommandType.tabSettings:
        onTabSettings?.call();

      case RemoteCommandType.home:
        onHome?.call();
      case RemoteCommandType.search:
        final query = command.data?['query'] as String?;
        onSearchAction?.call(query);

      case RemoteCommandType.stop:
        onStop?.call();
      case RemoteCommandType.nextTrack:
        onNextTrack?.call();
      case RemoteCommandType.previousTrack:
        onPreviousTrack?.call();

      case RemoteCommandType.subtitles:
        onSubtitles?.call();
      case RemoteCommandType.audioTracks:
        onAudioTracks?.call();

      case RemoteCommandType.fullscreen:
        onFullscreen?.call();

      case RemoteCommandType.playMedia:
        final data = command.data;
        if (data != null && onPlayMedia != null) {
          unawaited(onPlayMedia!(data));
        }
      case RemoteCommandType.seekTo:
        final positionMs = (command.data?['positionMs'] as num?)?.toInt();
        if (positionMs != null) {
          onSeekTo?.call(Duration(milliseconds: positionMs));
        }
      case RemoteCommandType.setRate:
        final rate = (command.data?['rate'] as num?)?.toDouble();
        if (rate != null) onSetRate?.call(rate);
      case RemoteCommandType.selectAudioTrack:
        final trackId = command.data?['trackId'] as String?;
        if (trackId != null) onSelectAudioTrack?.call(trackId);
      case RemoteCommandType.selectSubtitleTrack:
        final trackId = command.data?['trackId'] as String?;
        if (trackId != null) onSelectSubtitleTrack?.call(trackId);
      case RemoteCommandType.selectQuality:
        final qualityId = command.data?['qualityId'] as String?;
        if (qualityId != null) onSelectQuality?.call(qualityId);
      case RemoteCommandType.setSyncOffset:
        final audioMs = (command.data?['audioMs'] as num?)?.toInt();
        final subtitleMs = (command.data?['subtitleMs'] as num?)?.toInt();
        if (audioMs != null || subtitleMs != null) {
          onSetSyncOffset?.call(audioMs: audioMs, subtitleMs: subtitleMs);
        }
      case RemoteCommandType.setBoxFitMode:
        final mode = (command.data?['mode'] as num?)?.toInt();
        if (mode != null) onSetBoxFitMode?.call(mode);
      case RemoteCommandType.browseSeason:
        final seasonNumber = (command.data?['seasonNumber'] as num?)?.toInt();
        if (seasonNumber != null) onBrowseSeason?.call(seasonNumber);
      case RemoteCommandType.playEpisodeItem:
        final itemKey = command.data?['itemKey'] as String?;
        if (itemKey != null && itemKey.isNotEmpty) onPlayEpisodeItem?.call(itemKey);
      case RemoteCommandType.requestState:
        onRequestState?.call();

      case RemoteCommandType.ping:
      case RemoteCommandType.pong:
      case RemoteCommandType.ack:
      case RemoteCommandType.deviceInfo:
      case RemoteCommandType.disconnect:
      case RemoteCommandType.syncState:
        break;

      case RemoteCommandType.qualitySettings:
        appLogger.w('CompanionRemoteReceiver: Unhandled command type: ${command.type}');
    }
  }
}

bool _isTransport(RemoteCommandType type) => switch (type) {
  RemoteCommandType.play ||
  RemoteCommandType.pause ||
  RemoteCommandType.playPause ||
  RemoteCommandType.stop ||
  RemoteCommandType.seekForward ||
  RemoteCommandType.seekBackward ||
  RemoteCommandType.nextTrack ||
  RemoteCommandType.previousTrack => true,
  _ => false,
};

bool _isPlayerCommand(RemoteCommandType type) => switch (type) {
  RemoteCommandType.play ||
  RemoteCommandType.pause ||
  RemoteCommandType.playPause ||
  RemoteCommandType.stop ||
  RemoteCommandType.seekForward ||
  RemoteCommandType.seekBackward ||
  RemoteCommandType.skipIntro ||
  RemoteCommandType.skipCredits ||
  RemoteCommandType.volumeUp ||
  RemoteCommandType.volumeDown ||
  RemoteCommandType.volumeMute ||
  RemoteCommandType.volumeSet ||
  RemoteCommandType.nextTrack ||
  RemoteCommandType.previousTrack ||
  RemoteCommandType.subtitles ||
  RemoteCommandType.audioTracks ||
  RemoteCommandType.qualitySettings ||
  RemoteCommandType.fullscreen => true,
  RemoteCommandType.ping ||
  RemoteCommandType.pong ||
  RemoteCommandType.ack ||
  RemoteCommandType.deviceInfo ||
  RemoteCommandType.disconnect ||
  RemoteCommandType.syncState ||
  RemoteCommandType.requestState ||
  RemoteCommandType.playMedia ||
  RemoteCommandType.seekTo ||
  RemoteCommandType.setRate ||
  RemoteCommandType.selectAudioTrack ||
  RemoteCommandType.selectSubtitleTrack ||
  RemoteCommandType.selectQuality ||
  RemoteCommandType.setSyncOffset ||
  RemoteCommandType.setBoxFitMode ||
  RemoteCommandType.browseSeason ||
  RemoteCommandType.playEpisodeItem ||
  RemoteCommandType.dpadUp ||
  RemoteCommandType.dpadDown ||
  RemoteCommandType.dpadLeft ||
  RemoteCommandType.dpadRight ||
  RemoteCommandType.select ||
  RemoteCommandType.back ||
  RemoteCommandType.contextMenu ||
  RemoteCommandType.tabNext ||
  RemoteCommandType.tabPrevious ||
  RemoteCommandType.tabDiscover ||
  RemoteCommandType.tabLibraries ||
  RemoteCommandType.tabSearch ||
  RemoteCommandType.tabDownloads ||
  RemoteCommandType.tabSettings ||
  RemoteCommandType.home ||
  RemoteCommandType.search => false,
};

/// Exhaustive by design: no default clause, so adding a [RemoteCommandType]
/// is a compile error until someone decides whether it counts as viewer input.
bool _isViewerInput(RemoteCommandType type) => switch (type) {
  RemoteCommandType.ping ||
  RemoteCommandType.pong ||
  RemoteCommandType.ack ||
  RemoteCommandType.deviceInfo ||
  RemoteCommandType.disconnect ||
  RemoteCommandType.syncState ||
  RemoteCommandType.requestState ||
  RemoteCommandType.playMedia ||
  RemoteCommandType.seekTo ||
  RemoteCommandType.setRate ||
  RemoteCommandType.selectAudioTrack ||
  RemoteCommandType.selectSubtitleTrack ||
  RemoteCommandType.selectQuality ||
  RemoteCommandType.setSyncOffset ||
  RemoteCommandType.setBoxFitMode ||
  RemoteCommandType.browseSeason ||
  RemoteCommandType.playEpisodeItem => false,
  RemoteCommandType.dpadUp ||
  RemoteCommandType.dpadDown ||
  RemoteCommandType.dpadLeft ||
  RemoteCommandType.dpadRight ||
  RemoteCommandType.select ||
  RemoteCommandType.back ||
  RemoteCommandType.contextMenu ||
  RemoteCommandType.play ||
  RemoteCommandType.pause ||
  RemoteCommandType.playPause ||
  RemoteCommandType.stop ||
  RemoteCommandType.seekForward ||
  RemoteCommandType.seekBackward ||
  RemoteCommandType.skipIntro ||
  RemoteCommandType.skipCredits ||
  RemoteCommandType.volumeUp ||
  RemoteCommandType.volumeDown ||
  RemoteCommandType.volumeMute ||
  RemoteCommandType.volumeSet ||
  RemoteCommandType.nextTrack ||
  RemoteCommandType.previousTrack ||
  RemoteCommandType.tabNext ||
  RemoteCommandType.tabPrevious ||
  RemoteCommandType.tabDiscover ||
  RemoteCommandType.tabLibraries ||
  RemoteCommandType.tabSearch ||
  RemoteCommandType.tabDownloads ||
  RemoteCommandType.tabSettings ||
  RemoteCommandType.home ||
  RemoteCommandType.search ||
  RemoteCommandType.subtitles ||
  RemoteCommandType.audioTracks ||
  RemoteCommandType.qualitySettings ||
  RemoteCommandType.fullscreen => true,
};
