part of '../video_controls.dart';

extension _PlexVideoControlsMarkerMethods on _PlexVideoControlsState {
  Future<void> _loadManualSkipSettings() async {
    if (widget.initialMarkers != null) {
      _markersLoaded = true;
      return;
    }
    final key = widget.metadata.globalKey;
    if (widget.initialSkipSettings == null) {
      try {
        final store = WorkSkipSettingsStore(context.read<AppDatabase>());
        final client = context.tryGetMediaClientForServer(serverIdOrNull(widget.metadata.serverId));
        final work = await store.resolve(widget.metadata, client);
        final rules = work == null ? const WorkSkipSettings() : await store.read(work);
        if (!mounted || key != widget.metadata.globalKey) return;
        _manualSkipRules = rules;
      } catch (error, stack) {
        appLogger.w('Unable to load manual skip settings', error: error, stackTrace: stack);
      }
    }
    if (!mounted || key != widget.metadata.globalKey) return;
    _manualDurationMs = -1;
    _markersLoaded = true;
    _refreshManualMarkers();
    _syncCurrentMarkerForCurrentPosition();
  }

  void _refreshManualMarkers() {
    if (widget.initialMarkers != null) return; // Test-only injected ranges.
    final ms = widget.player.state.duration.inMilliseconds;
    if (_manualDurationMs == ms) return;
    _manualDurationMs = ms;
    _clearCurrentMarker();
    _setControlsState(() => _markers = _manualSkipRules.markersFor(Duration(milliseconds: ms)));
  }

  Future<void> _editWorkSkipSettings({Duration? clicked}) async {
    if (_editingSkipSettings || !widget.canControl || widget.isLive) return;
    final player = widget.player;
    final key = widget.metadata.globalKey;
    final wasPlaying = player.state.playing;
    _editingSkipSettings = true;
    widget.chromeController.cancelAutoHide();
    try {
      await player.pause();
      if (!mounted || widget.player != player || widget.metadata.globalKey != key) return;
      final saved = await showWorkSkipSettingsDialog(
        context,
        widget.metadata,
        duration: player.state.duration,
        clicked: clicked,
      );
      if (!mounted || widget.player != player || widget.metadata.globalKey != key) return;
      if (saved != null) {
        _manualSkipRules = saved;
        _manualDurationMs = -1;
        _suppressedMarkerId = null;
        _pendingSkipSeekMarkerId = null;
        _markersLoaded = true;
        _refreshManualMarkers();
        _syncCurrentMarkerForCurrentPosition();
      }
    } catch (error, stack) {
      appLogger.w('Unable to edit skip settings', error: error, stackTrace: stack);
      if (mounted) showErrorSnackBar(context, t.workSkip.loadFailed);
    } finally {
      _editingSkipSettings = false;
      if (mounted && widget.player == player && widget.metadata.globalKey == key) {
        if (wasPlaying) await player.play();
        if (mounted) _startHideTimer();
      }
    }
  }

  void _suppressSkipForSeek(Duration target) {
    _manualSeekGeneration++;
    _clearCurrentMarker();
    _suppressedMarkerId = null;
    for (final marker in _markers) {
      if (marker.containsPosition(target)) {
        _suppressedMarkerId = marker.id;
        break;
      }
    }
    _pendingSkipSeekMarkerId = _suppressedMarkerId;
    // Ignore optimistic and stale positions until the player's seek command
    // settles. Player.runSeek reconciles its final position before returning.
  }

  void _listenToPosition() {
    _skipDurationSubscription = widget.player.streams.duration.listen((_) {
      _refreshManualMarkers();
      _syncCurrentMarkerForCurrentPosition();
    });
    _positionSubscription = widget.player.streams.position.listen((position) {
      _syncCurrentMarkerForPosition(position);
    });
  }

  void _syncCurrentMarkerForCurrentPosition() {
    _syncCurrentMarkerForPosition(widget.player.state.position);
  }

  void _syncCurrentMarkerForPosition(Duration position) {
    _refreshManualMarkers();
    if (!_hasRenderedFirstFrame || _markers.isEmpty || !_markersLoaded) {
      _clearCurrentMarker();
      return;
    }

    MediaMarker? foundMarker;
    for (final marker in _markers) {
      if (marker.containsPosition(position)) {
        foundMarker = marker;
        break;
      }
    }

    if (_pendingSkipSeekMarkerId != null) return;
    if (foundMarker == null) _suppressedMarkerId = null;
    if (foundMarker != _currentMarker && mounted) {
      _updateCurrentMarker(foundMarker);
    }
  }

  void _clearCurrentMarker() {
    final hasMarkerState =
        _currentMarker != null ||
        _skipButtonDismissed ||
        _autoSkipTimer != null ||
        _autoSkipActive.value ||
        _autoSkipProgress.value != 0.0 ||
        _skipButtonDismissTimer != null;
    if (!hasMarkerState) return;

    if (_currentMarker != null || _skipButtonDismissed) {
      _setControlsState(() {
        _currentMarker = null;
        _skipButtonDismissed = false;
      });
    }
    _releaseSkipMarkerFocusToSurface();
    _cancelAutoSkipTimer();
    _cancelSkipButtonDismissTimer();
  }

  /// Hands the remote back to the player surface when the skip button is
  /// about to leave the tree while holding focus. Without this, focus falls
  /// out of the controls subtree, the enclosing screen reclaims it onto its
  /// own node, and the next Select raises the chrome instead of toggling
  /// playback (#1890).
  void _releaseSkipMarkerFocusToSurface() {
    if (!_skipMarkerFocusNode.hasFocus) return;
    _claimPlayerSurfaceFocus();
  }

  /// Updates the current marker and manages auto-skip/focus behavior.
  void _updateCurrentMarker(MediaMarker? foundMarker) {
    if (!_hasRenderedFirstFrame) {
      _clearCurrentMarker();
      return;
    }

    if (foundMarker == null) {
      _clearCurrentMarker();
      return;
    }

    _setControlsState(() {
      _currentMarker = foundMarker;
      _skipButtonDismissed = false;
    });

    _startAutoSkipTimer(foundMarker);

    // Auto-skip OFF: dismiss button after 7s if no interaction
    // Auto-skip ON: button stays until controls hide
    if (!_shouldAutoSkipForMarker(foundMarker)) {
      _startSkipButtonDismissTimer();
    }

    // Auto-focus skip button on TV when marker appears (only in keyboard/TV mode)
    if (PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // An open sheet (tracks, settings, subtitle search) or a route above
        // the player owns the remote; the button stays reachable, but a marker
        // appearing must not pull focus out from under them.
        if (OverlaySheetController.maybeOf(context)?.isOpen ?? false) return;
        if (ModalRoute.of(context)?.isCurrent == false) return;
        _skipMarkerFocusNode.requestFocus();
      });
    }
  }

  Future<void> _skipMarker({bool skipAutoPlayCountdown = false}) async {
    if (!widget.canControl) return;
    if (_currentMarker == null || !_hasRenderedFirstFrame || _skipInFlight || _editingSkipSettings) return;
    _skipInFlight = true;

    final marker = _currentMarker!;
    final endTime = marker.endTime;
    final duration = widget.player.state.duration;
    final isAtEnd = duration > Duration.zero && endTime >= duration;

    final generation = _manualSeekGeneration;
    final handsOffToCompletion = marker.isCredits && isAtEnd;
    final player = widget.player;
    final key = widget.metadata.globalKey;
    _suppressedMarkerId = marker.id;
    _cancelAutoSkipTimer();
    try {
      if (handsOffToCompletion) {
        // Always use completion so watched state, sleep timers and autoplay run.
        await player.pause();
        if (mounted && widget.player == player && widget.metadata.globalKey == key) {
          widget.onReachedEnd?.call(skipAutoPlayCountdown: skipAutoPlayCountdown);
        }
      } else {
        await _seekToPosition(endTime, automatic: true);
      }
    } catch (error, stack) {
      appLogger.w('Manual range skip failed', error: error, stackTrace: stack);
    } finally {
      _skipInFlight = false;
    }
    if (!mounted ||
        widget.player != player ||
        widget.metadata.globalKey != key ||
        generation != _manualSeekGeneration) {
      return;
    }
    _setControlsState(() => _currentMarker = null);
    if (!handsOffToCompletion) _releaseSkipMarkerFocusToSurface();
    _cancelSkipButtonDismissTimer();
  }

  void _startAutoSkipTimer(MediaMarker marker) {
    _cancelAutoSkipTimer();
    if (!_hasRenderedFirstFrame || !_shouldAutoSkipForMarker(marker)) return;
    final delayMs = marker.isCredits ? _autoSkipDelay * 1000 : 0;
    var elapsedMs = 0;
    _autoSkipProgress.value = 0;
    _autoSkipActive.value = true;
    void tick({bool initial = false}) {
      if (!mounted || _currentMarker != marker) return;
      if (!_shouldAutoSkipForMarker(marker)) {
        _cancelAutoSkipTimer();
        return;
      }
      if (!widget.player.state.playing || _editingSkipSettings || _skipInFlight || !widget.canControl) return;
      if (!initial) elapsedMs += 100;
      _autoSkipProgress.value = delayMs <= 0 ? 1 : (elapsedMs / delayMs).clamp(0, 1);
      if (elapsedMs >= delayMs) {
        _cancelAutoSkipTimer();
        _performAutoSkip(skipAutoPlayCountdown: true);
      }
    }

    _autoSkipTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => tick());
    // Intro and a zero credits delay execute on the next microtask, without a countdown.
    Future.microtask(() {
      if (mounted && _autoSkipTimer?.isActive == true) tick(initial: true);
    });
  }

  void _cancelAutoSkipTimer() {
    final hadTimer = _autoSkipTimer != null;
    _autoSkipTimer?.cancel();
    _autoSkipTimer = null;
    if (!mounted) return;
    _autoSkipActive.value = false;
    if (hadTimer || _autoSkipProgress.value != 0.0) {
      _autoSkipProgress.value = 0.0;
    }
  }

  bool _cancelAutoSkipFromUserInteraction() {
    final hadActiveTimer = _autoSkipTimer?.isActive ?? false;
    if (!hadActiveTimer) return false;

    _suppressedMarkerId = _currentMarker?.id;
    _cancelAutoSkipTimer();
    if (_currentMarker != null && !_skipButtonDismissed) {
      _startSkipButtonDismissTimer();
    }
    return true;
  }

  /// Starts/restarts the skip button dismiss timer. When it fires, hides the
  /// button and cancels any active auto-skip countdown.
  void _startSkipButtonDismissTimer() {
    _skipButtonDismissTimer?.cancel();
    if (!_hasRenderedFirstFrame) return;
    _skipButtonDismissTimer = Timer(const Duration(seconds: 7), () {
      if (!mounted || _currentMarker == null) return;
      _setControlsState(() {
        _skipButtonDismissed = true;
      });
      // The dismissed flag only hides the button while the chrome is down;
      // with the chrome up the button stays visible and keeps its focus.
      if (!_showControls) _releaseSkipMarkerFocusToSurface();
      _cancelAutoSkipTimer();
    });
  }

  void _cancelSkipButtonDismissTimer() {
    _skipButtonDismissTimer?.cancel();
    _skipButtonDismissTimer = null;
  }

  /// Perform the appropriate skip action based on marker type and next episode availability
  void _performAutoSkip({bool skipAutoPlayCountdown = false}) {
    if (!widget.canControl) return;
    if (_currentMarker == null || !_hasRenderedFirstFrame) return;
    unawaited(_skipMarker(skipAutoPlayCountdown: skipAutoPlayCountdown));
  }

  bool _shouldAutoSkipForMarker(MediaMarker marker) => widget.canControl && _suppressedMarkerId != marker.id;

  bool _shouldShowAutoSkip() {
    if (_currentMarker == null) return false;
    return _shouldAutoSkipForMarker(_currentMarker!);
  }

  bool get _isSkipMarkerButtonVisible => shouldShowSkipMarkerButton(
    hasFirstFrame: _hasRenderedFirstFrame,
    hasMarker: _currentMarker != null,
    hasPlayNextPrompt: widget.playNextFocusNode != null,
    skipButtonDismissed: _skipButtonDismissed,
    controlsVisible: _showControls,
  );

  void _activateSkipMarker() {
    if (!_isSkipMarkerButtonVisible) return;
    _cancelAutoSkipTimer();
    _performAutoSkip();
  }

  /// The viewer's "no thanks" to a skip prompt: stops any running auto-skip
  /// countdown and hides the button for the rest of this marker.
  ///
  /// The mirror of [_activateSkipMarker]. The focus hand-back carries its own
  /// chrome guard rather than relying on the caller's: with the chrome up the
  /// button stays visible and keeps focus, so releasing it there would pull the
  /// remote off a control the viewer can still see.
  void _dismissSkipMarker() {
    if (!_isSkipMarkerButtonVisible) return;
    _suppressedMarkerId = _currentMarker?.id;
    // Cancelled here rather than left to the global key handler's
    // _cancelAutoSkipFromUserInteraction: gamepad and companion-remote presses
    // are synthesized straight onto the focus chain and never reach
    // HardwareKeyboard, so for those this is the only thing that stops the
    // countdown.
    _cancelAutoSkipTimer();
    _cancelSkipButtonDismissTimer();
    _setControlsState(() {
      _skipButtonDismissed = true;
    });
    if (!_showControls) _releaseSkipMarkerFocusToSurface();
  }

  Widget _buildSkipMarkerButton() {
    return ValueListenableBuilder<double>(
      valueListenable: _autoSkipProgress,
      builder: (context, autoSkipProgress, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: _autoSkipActive,
          builder: (context, isAutoSkipActive, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SkipMarkerButton(
                  marker: _currentMarker!,
                  playerDuration: widget.player.state.duration,
                  hasNextEpisode: widget.onNext != null,
                  isAutoSkipActive: isAutoSkipActive,
                  shouldShowAutoSkip: _shouldShowAutoSkip(),
                  autoSkipDelay: _currentMarker!.isCredits ? _autoSkipDelay : 0,
                  autoSkipProgress: autoSkipProgress,
                  focusNode: _skipMarkerFocusNode,
                  onActivate: _activateSkipMarker,
                  onFocusDown: () => _desktopControlsKey.currentState?.requestPlayPauseFocus(),
                ),
                if (isAutoSkipActive)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: IconButton.filledTonal(
                      tooltip: t.workSkip.cancelVisit,
                      onPressed: _dismissSkipMarker,
                      icon: const Icon(Icons.close),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
