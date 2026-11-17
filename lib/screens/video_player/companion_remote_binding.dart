import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/companion_remote/remote_playback_models.dart';
import '../../mpv/mpv.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/companion_remote/companion_remote_receiver.dart';
import '../../services/fullscreen_state_manager.dart';
import '../../services/video_volume_controller.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';

/// Wires the player screen into the [CompanionRemoteReceiver] callback slots
/// and owns the home-button fallback plus the provider handle used for
/// player-active sync notifications.
///
/// Plain State-owned helper. [bind] installs this instance as the receiver's
/// `playerOwner` token; [unbind] restores the slots only while this instance
/// still owns them, so a replacement screen's wiring survives the outgoing
/// screen's dispose. The player and volume controller are injected as
/// late-bound getters because both are re-created across playback attempts,
/// and volume/seek dispatch must bind to the player at command receipt.
class CompanionRemoteBinding {
  CompanionRemoteBinding({
    required this._player,
    required this._isMounted,
    required this._canControlPlayback,
    required this._volumeController,
    required this._hasNextItem,
    required this._onStop,
    required this._onNavigateToNextItem,
    required this._onNavigateToPreviousItem,
    required this._skipByConfiguredStep,
    required this._onCycleSubtitles,
    required this._onCycleAudio,
    required this._onHome,
    required this._readProvider,
    this.onPlay,
    this.onPause,
    this.onPlayPause,
    this.onSeekTo,
    this.onSetRate,
    this.onSelectAudioTrack,
    this.onSelectSubtitleTrack,
    this.onSelectQuality,
    this.onSetSyncOffset,
    this.onSetBoxFitMode,
    this.onSkipIntro,
    this.onSkipCredits,
    this.onBrowseSeason,
    this.onPlayEpisodeItem,
    this.onRequestState,
  });

  final Player? Function() _player;
  final bool Function() _isMounted;
  final bool Function() _canControlPlayback;
  final VideoVolumeController? Function() _volumeController;
  final bool Function() _hasNextItem;
  final void Function() _onStop;
  final Future<void> Function() _onNavigateToNextItem;
  final Future<void> Function() _onNavigateToPreviousItem;
  final void Function({required bool forward}) _skipByConfiguredStep;
  final void Function() _onCycleSubtitles;
  final void Function() _onCycleAudio;
  final void Function() _onHome;
  final CompanionRemoteProvider Function() _readProvider;
  final void Function()? onPlay;
  final void Function()? onPause;
  final void Function()? onPlayPause;
  final void Function(Duration position)? onSeekTo;
  final void Function(double rate)? onSetRate;
  final void Function(String trackId)? onSelectAudioTrack;
  final void Function(String trackId)? onSelectSubtitleTrack;
  final void Function(String qualityId)? onSelectQuality;
  final void Function({int? audioMs, int? subtitleMs})? onSetSyncOffset;
  final void Function(int mode)? onSetBoxFitMode;
  final void Function()? onSkipIntro;
  final void Function()? onSkipCredits;
  final void Function(int seasonNumber)? onBrowseSeason;
  final void Function(String itemKey)? onPlayEpisodeItem;
  final void Function()? onRequestState;

  CompanionRemoteProvider? _provider;
  VoidCallback? _savedOnHome;

  /// The MainScreen home callback saved while this screen overrides the
  /// receiver's home slot; the screen's home-button handler invokes it after
  /// popping back to the first route.
  VoidCallback? get savedOnHome => _savedOnHome;

  void bind() {
    final receiver = CompanionRemoteReceiver.instance;
    receiver.playerHomeFallback ??= receiver.onHome;
    receiver.playerOwner = this;
    receiver.onStop = () {
      if (_isMounted()) _onStop();
    };
    receiver.onPlay = () {
      if (_isMounted() && _canControlPlayback()) onPlay?.call();
    };
    receiver.onPause = () {
      if (_isMounted() && _canControlPlayback()) onPause?.call();
    };
    receiver.onPlayPause = () {
      if (_isMounted() && _canControlPlayback()) onPlayPause?.call();
    };
    receiver.onNextTrack = () {
      if (_isMounted() && _hasNextItem()) unawaited(_onNavigateToNextItem());
    };
    receiver.onPreviousTrack = () {
      if (_isMounted()) unawaited(_onNavigateToPreviousItem());
    };
    receiver.onSeekForward = () => _dispatchSeek(forward: true);
    receiver.onSeekBackward = () => _dispatchSeek(forward: false);
    receiver.onSeekTo = (pos) {
      if (_isMounted() && _canControlPlayback()) onSeekTo?.call(pos);
    };
    receiver.onVolumeUp = () => _dispatchVolume(10);
    receiver.onVolumeDown = () => _dispatchVolume(-10);
    receiver.onVolumeMute = _dispatchMute;
    receiver.onVolumeSet = _dispatchVolumeSet;
    receiver.onSubtitles = () {
      if (_canControlPlayback()) _onCycleSubtitles();
    };
    receiver.onAudioTracks = () {
      if (_canControlPlayback()) _onCycleAudio();
    };
    receiver.onSetRate = (rate) {
      if (_isMounted() && _canControlPlayback()) onSetRate?.call(rate);
    };
    receiver.onSelectAudioTrack = (id) {
      if (_isMounted() && _canControlPlayback()) onSelectAudioTrack?.call(id);
    };
    receiver.onSelectSubtitleTrack = (id) {
      if (_isMounted() && _canControlPlayback()) onSelectSubtitleTrack?.call(id);
    };
    receiver.onSelectQuality = (id) {
      if (_isMounted() && _canControlPlayback()) onSelectQuality?.call(id);
    };
    receiver.onSetSyncOffset = ({audioMs, subtitleMs}) {
      if (_isMounted() && _canControlPlayback()) {
        onSetSyncOffset?.call(audioMs: audioMs, subtitleMs: subtitleMs);
      }
    };
    receiver.onSetBoxFitMode = (mode) {
      if (_isMounted() && _canControlPlayback()) onSetBoxFitMode?.call(mode);
    };
    receiver.onSkipIntro = () {
      if (_isMounted() && _canControlPlayback()) onSkipIntro?.call();
    };
    receiver.onSkipCredits = () {
      if (_isMounted() && _canControlPlayback()) onSkipCredits?.call();
    };
    receiver.onBrowseSeason = (seasonNumber) {
      if (_isMounted()) onBrowseSeason?.call(seasonNumber);
    };
    receiver.onPlayEpisodeItem = (itemKey) {
      if (_isMounted() && _canControlPlayback()) onPlayEpisodeItem?.call(itemKey);
    };
    receiver.onRequestState = () {
      if (_isMounted()) onRequestState?.call();
    };
    receiver.onFullscreen = _toggleFullscreen;

    // Override home to exit the player first. Replacements inherit the base
    // MainScreen callback rather than chaining through the outgoing player.
    _savedOnHome = receiver.playerHomeFallback;
    receiver.onHome = () {
      if (_isMounted()) _onHome();
    };

    // Store provider reference for use in dispose and notify remote
    try {
      _provider = _readProvider();
      _provider!.setHostPlayerActive(true);
      onRequestState?.call();
    } catch (e) {
      appLogger.d('CompanionRemote provider unavailable', error: e);
    }
  }

  void _dispatchSeek({required bool forward}) {
    final currentPlayer = _player();
    if (!_isMounted() || currentPlayer == null || !_canControlPlayback()) return;
    // The viewer's configured step, like every other skip source, and the
    // screen coalesces a burst of these into one absolute seek so a remote
    // held on skip cannot dispatch a native seek per repeat.
    _skipByConfiguredStep(forward: forward);
  }

  void _dispatchVolume(double delta) {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.adjust(delta);
    onRequestState?.call();
  }

  void _dispatchMute() {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.toggleMute();
    onRequestState?.call();
  }

  void _dispatchVolumeSet(double volume) {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.commit(volume);
    onRequestState?.call();
  }

  Future<void> _toggleFullscreen() async {
    if (!PlatformDetector.isDesktopOS()) return;
    await FullscreenStateManager().toggleFullscreen();
    onRequestState?.call();
  }

  void unbind() {
    final receiver = CompanionRemoteReceiver.instance;
    if (!identical(receiver.playerOwner, this)) {
      _provider = null;
      return;
    }
    receiver.onStop = null;
    receiver.onPlay = null;
    receiver.onPause = null;
    receiver.onPlayPause = null;
    receiver.onNextTrack = null;
    receiver.onPreviousTrack = null;
    receiver.onSeekForward = null;
    receiver.onSeekBackward = null;
    receiver.onSeekTo = null;
    receiver.onVolumeUp = null;
    receiver.onVolumeDown = null;
    receiver.onVolumeMute = null;
    receiver.onVolumeSet = null;
    receiver.onSubtitles = null;
    receiver.onAudioTracks = null;
    receiver.onSetRate = null;
    receiver.onSelectAudioTrack = null;
    receiver.onSelectSubtitleTrack = null;
    receiver.onSelectQuality = null;
    receiver.onSetSyncOffset = null;
    receiver.onSetBoxFitMode = null;
    receiver.onSkipIntro = null;
    receiver.onSkipCredits = null;
    receiver.onBrowseSeason = null;
    receiver.onPlayEpisodeItem = null;
    receiver.onRequestState = null;
    receiver.onFullscreen = null;
    receiver.onHome = receiver.playerHomeFallback;
    receiver.playerHomeFallback = null;
    receiver.playerOwner = null;
    _savedOnHome = null;

    // Notify only when the active player owner exits.
    _provider?.updateHostPlayerSnapshot(RemotePlayerSnapshot.idle);
    _provider?.setHostPlayerActive(false);
    _provider = null;
  }
}
