part of '../../video_player_screen.dart';

/// Companion-remote playback control, show/episode snapshot building, and
/// incoming playback parameter dispatch on [VideoPlayerScreenState].
extension _VideoPlayerCompanionRemoteMethods on VideoPlayerScreenState {
  void _cycleSubtitleTrack() {
    final sourceTracks = _sourceSubtitleTracksForControls();
    if (!_isOfflinePlayback && sourceTracks.isNotEmpty) {
      _pendingSubtitleCycleCount++;
      if (!_subtitleCycleDrainActive) unawaited(_drainSubtitleCycles());
      return;
    }
    _cycleSubtitleTrackNatively();
  }

  void _cycleSubtitleTrackNatively() {
    final cycled = _trackManager?.cycleSubtitleTrack();
    if (cycled != null) _rememberNativeSubtitleSelection(cycled);
    _pushRemotePlayerSnapshot();
  }

  Future<void> _drainSubtitleCycles() async {
    if (_subtitleCycleDrainActive) return;
    _subtitleCycleDrainActive = true;
    try {
      while (mounted && _pendingSubtitleCycleCount > 0) {
        await _transitionGate.waitForIdle(() => mounted);
        if (!mounted || _pendingSubtitleCycleCount == 0) break;

        final advances = _pendingSubtitleCycleCount;
        final sourceTracks = _sourceSubtitleTracksForControls();
        if (_isOfflinePlayback || sourceTracks.isEmpty) {
          _pendingSubtitleCycleCount -= advances;
          for (var i = 0; i < advances; i++) {
            _cycleSubtitleTrackNatively();
          }
          continue;
        }
        final currentChoice =
            _selectedSourceSubtitleChoiceForControls(sourceTracks) ?? const PlaybackSourceSubtitleChoice.off();
        final targetChoice = PlaybackSubtitleResolver.advanceSourceChoice(sourceTracks, currentChoice, advances);
        final outcome = await _switchPlaybackSource(newSubtitleChoice: targetChoice);
        if (outcome == PlaybackSourceChangeOutcome.busy) {
          await _transitionGate.waitForIdle(() => mounted);
          continue;
        }
        _pendingSubtitleCycleCount -= advances;
        _pushRemotePlayerSnapshot();
      }
    } finally {
      _subtitleCycleDrainActive = false;
    }
  }

  void _cycleAudioTrack() {
    _trackManager?.cycleAudioTrack();
    _pushRemotePlayerSnapshot();
  }

  void _remotePlay() => _dispatchRemoteTransport(TransportCommand.play);

  void _remotePause() => _dispatchRemoteTransport(TransportCommand.pause);

  void _remoteTogglePlayPause() => _dispatchRemoteTransport(TransportCommand.toggle);

  void _dispatchRemoteTransport(TransportCommand command) {
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null || !_isPlayerInitialized) return;
    unawaited(
      _transportIntent(currentPlayer, command).whenComplete(() {
        if (!mounted || _shuttingDown) return;
        _announceTransportCommand(willPlay: _playbackIntentShouldPlay);
        _pushRemotePlayerSnapshot();
      }),
    );
  }

  void _remoteSeekTo(Duration position) {
    unawaited(
      _seekPlayback(position).whenComplete(() {
        if (mounted && !_shuttingDown) _pushRemotePlayerSnapshot();
      }),
    );
  }

  void _remoteSetRate(double rate) {
    unawaited(
      _setPlaybackRate(rate).whenComplete(() {
        if (mounted && !_shuttingDown) _pushRemotePlayerSnapshot();
      }),
    );
  }

  void _remoteSelectAudioTrack(String trackId) {
    final currentPlayer = player;
    if (!mounted || currentPlayer == null) return;
    if (trackId.startsWith('source:')) {
      final streamId = int.tryParse(trackId.substring('source:'.length));
      if (streamId == null) return;
      unawaited(
        _switchPlaybackSource(newAudioStreamId: streamId).whenComplete(() {
          if (mounted) _pushRemotePlayerSnapshot();
        }),
      );
      return;
    }
    final rawId = trackId.startsWith('mpv:') ? trackId.substring('mpv:'.length) : trackId;
    for (final track in currentPlayer.state.tracks.audio) {
      if (track.id == rawId) {
        unawaited(
          _onAudioTrackChanged(track).whenComplete(() {
            if (mounted) _pushRemotePlayerSnapshot();
          }),
        );
        return;
      }
    }
  }

  void _remoteSelectSubtitleTrack(String trackId) {
    final currentPlayer = player;
    if (!mounted || currentPlayer == null) return;
    if (trackId == 'off') {
      final sourceTracks = _sourceSubtitleTracksForControls();
      if (_isTranscoding && sourceTracks.isNotEmpty) {
        unawaited(
          _switchPlaybackSource(newSubtitleChoice: const PlaybackSourceSubtitleChoice.off()).whenComplete(() {
            if (mounted) _pushRemotePlayerSnapshot();
          }),
        );
      } else {
        unawaited(
          _onSubtitleTrackChanged(SubtitleTrack.off).whenComplete(() {
            if (mounted) _pushRemotePlayerSnapshot();
          }),
        );
      }
      return;
    }
    if (trackId.startsWith('source:')) {
      final streamId = int.tryParse(trackId.substring('source:'.length));
      if (streamId == null) return;
      unawaited(
        _switchPlaybackSource(newSubtitleChoice: PlaybackSourceSubtitleChoice.source(streamId)).whenComplete(() {
          if (mounted) _pushRemotePlayerSnapshot();
        }),
      );
      return;
    }
    final rawId = trackId.startsWith('mpv:') ? trackId.substring('mpv:'.length) : trackId;
    for (final track in currentPlayer.state.tracks.subtitle) {
      if (track.id == rawId) {
        unawaited(
          _onSubtitleTrackChanged(track).whenComplete(() {
            if (mounted) _pushRemotePlayerSnapshot();
          }),
        );
        return;
      }
    }
  }

  void _remoteSelectQuality(String qualityId) {
    unawaited(
      _switchStreamQuality(qualityId).whenComplete(() {
        if (mounted) _pushRemotePlayerSnapshot();
      }),
    );
  }

  void _remoteSetSyncOffset({int? audioMs, int? subtitleMs}) {
    final currentPlayer = player;
    if (!mounted || currentPlayer == null) return;
    unawaited(() async {
      final offsets = PlayerSyncOffsets.of(currentPlayer);
      if (audioMs != null) {
        await currentPlayer.setProperty(PlayerSyncOffsets.audioProperty, (audioMs / 1000.0).toString());
        offsets.recordApplied(PlayerSyncOffsets.audioProperty, audioMs);
        unawaited(ScopedPlayerPrefs.write(ScopedPlayerPrefs.audioSyncOffset, _currentMetadata, audioMs));
      }
      if (subtitleMs != null) {
        await currentPlayer.setProperty(PlayerSyncOffsets.subtitleProperty, (subtitleMs / 1000.0).toString());
        offsets.recordApplied(PlayerSyncOffsets.subtitleProperty, subtitleMs);
        unawaited(ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSyncOffset, _currentMetadata, subtitleMs));
      }
      if (mounted) {
        _setPlayerState(() {});
        _pushRemotePlayerSnapshot();
      }
    }());
  }

  void _remoteSetBoxFitMode(int mode) {
    final filterManager = _videoFilterManager;
    if (!mounted || filterManager == null) return;
    final clamped = mode.clamp(0, 2);
    unawaited(_ambientLightingService?.disable());
    filterManager.setBoxFitMode(clamped);
    unawaited(ScopedPlayerPrefs.write(ScopedPlayerPrefs.boxFitMode, _currentMetadata, clamped));
    _setPlayerState(() {});
    _pushRemotePlayerSnapshot();
  }

  void _remoteSkipIntro() {
    final target = _activeSkipTarget(isIntro: true);
    if (target != null) _remoteSeekTo(target);
  }

  void _remoteSkipCredits() {
    final target = _activeSkipTarget(isIntro: false);
    if (target != null) _remoteSeekTo(target);
  }

  Duration? _activeSkipTarget({required bool isIntro}) {
    final currentPlayer = player;
    if (currentPlayer == null || widget.isLive) return null;
    final dur = currentPlayer.state.duration;
    if (dur <= Duration.zero) return null;
    final pos = currentPlayer.state.position;
    for (final marker in _remoteSkipSettings.markersFor(dur)) {
      final matchesKind = isIntro ? marker.type == 'intro' : marker.isCredits;
      if (matchesKind && marker.containsPosition(pos)) {
        return marker.endTime;
      }
    }
    return null;
  }

  void _browseRemoteSeason(int seasonNumber) {
    final season = _remoteSeasons.where((s) => s.seasonNumber == seasonNumber).firstOrNull;
    if (season == null || !mounted || _isOfflinePlayback) return;
    final client = _getMediaServerClient(context);
    if (client == null) return;

    final seasonKey = season.itemKey ?? '${season.seasonId}';
    unawaited(() async {
      try {
        final episodes = await client.fetchChildren(seasonKey);
        if (!mounted || _shuttingDown) return;
        _remoteBrowsedSeasonNumber = seasonNumber;
        _remoteSeasonEpisodes = _mapRemoteEpisodes(episodes);
        _pushRemotePlayerSnapshot();
      } catch (e) {
        appLogger.d('CompanionRemote: Failed to browse season $seasonNumber', error: e);
      }
    }());
  }

  void _playRemoteEpisodeItem(String itemKey) {
    if (!mounted || _shuttingDown || _isOfflinePlayback) return;
    final client = _getMediaServerClient(context);
    if (client == null) return;

    unawaited(() async {
      try {
        final item = await client.fetchItem(itemKey);
        if (item == null || !mounted || _shuttingDown) return;
        await _navigateToEpisode(item);
      } catch (e) {
        appLogger.w('CompanionRemote: Failed to switch episode item $itemKey', error: e);
      }
    }());
  }

  void _loadRemoteShowCatalogAndSkipSettings() {
    if (!mounted || _shuttingDown) return;
    final metadata = _currentMetadata;
    final itemKey = metadata.globalKey;

    if (_remoteSkipSettingsKey != itemKey) {
      _remoteSkipSettingsKey = itemKey;
      AppDatabase? db;
      try {
        db = Provider.of<AppDatabase?>(context, listen: false);
      } on ProviderNotFoundException {
        db = null;
      }
      if (db != null && WorkSkipSettingsStore.supports(metadata)) {
        final store = WorkSkipSettingsStore(db);
        final client = _isOfflinePlayback ? null : _getMediaServerClient(context);
        unawaited(() async {
          try {
            final work = await store.resolve(metadata, client);
            final rules = work == null ? const WorkSkipSettings() : await store.read(work);
            if (!mounted || _shuttingDown || _currentMetadata.globalKey != itemKey) return;
            _remoteSkipSettings = rules;
            _pushRemotePlayerSnapshot();
          } catch (_) {}
        }());
      } else {
        _remoteSkipSettings = const WorkSkipSettings();
      }
    }

    if (_isOfflinePlayback || metadata.kind != MediaKind.episode) {
      if (_remoteLoadedShowKey != null) {
        _remoteLoadedShowKey = null;
        _remoteSeasons = const [];
        _remoteBrowsedSeasonNumber = null;
        _remoteSeasonEpisodes = const [];
      }
      return;
    }

    final showId = metadata.grandparentId;
    if (showId == null || showId.isEmpty) return;
    final showKey = '${metadata.serverId}:$showId';
    final currentSeasonNumber = metadata.parentIndex;
    final client = _getMediaServerClient(context);
    if (client == null) return;

    if (_remoteLoadedShowKey == showKey &&
        _remoteSeasons.isNotEmpty &&
        _remoteBrowsedSeasonNumber == currentSeasonNumber &&
        _remoteSeasonEpisodes.isNotEmpty) {
      return;
    }

    _remoteLoadedShowKey = showKey;
    unawaited(() async {
      try {
        final seasonItems = await client.fetchChildren(showId);
        if (!mounted || _shuttingDown || _remoteLoadedShowKey != showKey) return;

        final mappedSeasons = <RemoteSeasonSummary>[
          for (var i = 0; i < seasonItems.length; i++)
            RemoteSeasonSummary(
              seasonId: int.tryParse(seasonItems[i].id) ?? (i + 1),
              itemKey: seasonItems[i].id,
              seasonNumber: seasonItems[i].index ?? (i + 1),
              title: seasonItems[i].title ?? '',
              episodeCount: seasonItems[i].leafCount ?? 0,
            ),
        ];

        var selectedSeason = mappedSeasons.where((s) => s.seasonNumber == currentSeasonNumber).firstOrNull;
        selectedSeason ??= mappedSeasons.isNotEmpty ? mappedSeasons.first : null;
        List<MediaItem> episodes = const [];
        if (selectedSeason != null) {
          episodes = await client.fetchChildren(selectedSeason.itemKey ?? '${selectedSeason.seasonId}');
          if (!mounted || _shuttingDown || _remoteLoadedShowKey != showKey) return;
        }

        _remoteSeasons = mappedSeasons;
        _remoteBrowsedSeasonNumber = selectedSeason?.seasonNumber ?? currentSeasonNumber;
        _remoteSeasonEpisodes = _mapRemoteEpisodes(episodes);
        _pushRemotePlayerSnapshot();
      } catch (e) {
        appLogger.d('CompanionRemote: Failed to load show catalog', error: e);
      }
    }());
  }

  List<RemoteEpisodeSummary> _mapRemoteEpisodes(List<MediaItem> items) => [
    for (final ep in items)
      RemoteEpisodeSummary(
        itemKey: ep.id,
        seasonNumber: ep.parentIndex ?? 1,
        episodeNumber: ep.index ?? 0,
        title: ep.title ?? '',
        durationMs: ep.durationMs,
        viewOffsetMs: ep.viewOffsetMs,
        watched: ep.isWatched,
        current: ep.id == _currentMetadata.id,
      ),
  ];

  void _pushRemotePlayerSnapshot({bool throttled = false}) {
    if (!mounted || _shuttingDown) return;
    CompanionRemoteProvider? provider;
    try {
      provider = Provider.of<CompanionRemoteProvider?>(context, listen: false);
    } on ProviderNotFoundException {
      return;
    }
    if (provider == null) return;

    final now = DateTime.now();
    if (throttled && _lastRemotePositionPushAt != null) {
      if (now.difference(_lastRemotePositionPushAt!) < const Duration(milliseconds: 900)) {
        return;
      }
    }
    _lastRemotePositionPushAt = now;
    provider.updateHostPlayerSnapshot(_buildRemotePlayerSnapshot());
  }

  RemotePlayerSnapshot _buildRemotePlayerSnapshot() {
    final currentPlayer = player;
    final state = currentPlayer?.state;
    final playing = state?.playing ?? false;
    final buffering = state?.buffering ?? false;
    final positionMs = (currentPlayer?.currentPosition.inMilliseconds ?? state?.position.inMilliseconds ?? 0)
        .clamp(0, 1 << 30);
    final stateDurationMs = state?.duration.inMilliseconds ?? 0;
    final durationMs = (stateDurationMs > 0 ? stateDurationMs : (_currentMetadata.durationMs ?? 0)).clamp(0, 1 << 30);
    final volume = (_volumeController?.value ?? state?.volume ?? 100.0).clamp(0.0, 100.0).toDouble();
    final offsets = currentPlayer != null ? PlayerSyncOffsets.of(currentPlayer) : null;

    final rawThumb = _currentMetadata.thumbPath;
    final posterUrl =
        rawThumb != null && (rawThumb.startsWith('http://') || rawThumb.startsWith('https://')) ? rawThumb : null;

    final audioTracks = _buildRemoteAudioTrackOptions(currentPlayer);
    final subtitleTracks = _buildRemoteSubtitleTrackOptions(currentPlayer);
    final qualities = _buildRemoteQualityOptions();

    final currentSeasonEpisodes = [
      for (final ep in _remoteSeasonEpisodes) ep.copyWith(current: ep.itemKey == _currentMetadata.id),
    ];

    return RemotePlayerSnapshot(
      active: true,
      stage: buffering
          ? 'buffering'
          : playing
          ? 'playing'
          : 'paused',
      mediaKind: _currentMetadata.kind == MediaKind.episode ? 'episode' : 'movie',
      currentItemKey: _currentMetadata.id,
      title: _currentMetadata.title ?? '',
      seriesTitle: _currentMetadata.grandparentTitle,
      seasonNumber: _currentMetadata.parentIndex,
      episodeNumber: _currentMetadata.index,
      posterUrl: posterUrl,
      playing: playing,
      buffering: buffering,
      positionMs: positionMs,
      durationMs: durationMs,
      volume: volume,
      muted: volume <= 0.01,
      playbackRate: state?.rate ?? 1.0,
      boxFitMode: _videoFilterManager?.boxFitMode ?? 0,
      isFullscreen: FullscreenStateManager().isFullscreen,
      isDesktopHost: PlatformDetector.isDesktopOS(),
      audioSyncOffsetMs: offsets?.audioMs ?? 0,
      subtitleSyncOffsetMs: offsets?.subtitleMs ?? 0,
      canPrevious: _hasPreviousItem,
      canNext: _hasNextItem,
      canSkipIntro: _activeSkipTarget(isIntro: true) != null,
      canSkipCredits: _activeSkipTarget(isIntro: false) != null,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
      qualities: qualities,
      seasons: _remoteSeasons,
      browsedSeasonNumber: _remoteBrowsedSeasonNumber ?? _currentMetadata.parentIndex,
      episodes: currentSeasonEpisodes,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  List<RemoteTrackOption> _buildRemoteAudioTrackOptions(Player? currentPlayer) {
    final sourceAudio = _currentMediaInfo?.audioTracks ?? const <MediaAudioTrack>[];
    if (_isTranscoding && sourceAudio.isNotEmpty) {
      return [
        for (var i = 0; i < sourceAudio.length; i++)
          RemoteTrackOption(
            id: 'source:${sourceAudio[i].id}',
            label: TrackLabelBuilder.audioLabel(
              title: sourceAudio[i].title,
              language: sourceAudio[i].displayTitle ?? sourceAudio[i].language,
              codec: sourceAudio[i].codec,
              channels: sourceAudio[i].channels,
              index: i,
            ).joined,
            language: sourceAudio[i].languageCode ?? sourceAudio[i].language,
            codec: sourceAudio[i].codec,
            selected: sourceAudio[i].id == _selectedAudioStreamId,
          ),
      ];
    }

    if (currentPlayer == null) return const [];
    final tracks = TrackFilterHelper.filterTracks(currentPlayer.state.tracks.audio);
    final selectedId = currentPlayer.state.track.audio?.id;
    return [
      for (var i = 0; i < tracks.length; i++)
        RemoteTrackOption(
          id: 'mpv:${tracks[i].id}',
          label: TrackLabelBuilder.audioLabel(
            title: tracks[i].title,
            language: tracks[i].language,
            codec: tracks[i].codec,
            codecProfile: tracks[i].codecProfile,
            channels: tracks[i].channelsCount,
            index: i,
          ).joined,
          language: tracks[i].language,
          codec: tracks[i].codec,
          selected: tracks[i].id == selectedId,
        ),
    ];
  }

  List<RemoteTrackOption> _buildRemoteSubtitleTrackOptions(Player? currentPlayer) {
    final sourceSubs = _sourceSubtitleTracksForControls();
    if (_isTranscoding && sourceSubs.isNotEmpty) {
      final selectedChoice = _selectedSourceSubtitleChoiceForControls(sourceSubs);
      final isOff = selectedChoice == null || selectedChoice.isOff;
      return [
        RemoteTrackOption(id: 'off', label: t.companionRemote.subtitleTrackOff, selected: isOff),
        for (var i = 0; i < sourceSubs.length; i++)
          RemoteTrackOption(
            id: 'source:${sourceSubs[i].id}',
            label: TrackLabelBuilder.subtitleLabel(
              title: sourceSubs[i].title,
              language: sourceSubs[i].displayTitle ?? sourceSubs[i].language,
              codec: sourceSubs[i].codec,
              forced: sourceSubs[i].forced,
              index: i,
            ).joined,
            language: sourceSubs[i].languageCode ?? sourceSubs[i].language,
            codec: sourceSubs[i].codec,
            selected: selectedChoice?.sourceStreamId == sourceSubs[i].id,
          ),
      ];
    }

    if (currentPlayer == null) return const [];
    final tracks = TrackFilterHelper.filterTracks(currentPlayer.state.tracks.subtitle);
    final selectedId = currentPlayer.state.track.subtitle?.id;
    final isOff = selectedId == null || selectedId == SubtitleTrack.off.id;
    return [
      RemoteTrackOption(id: 'off', label: t.companionRemote.subtitleTrackOff, selected: isOff),
      for (var i = 0; i < tracks.length; i++)
        RemoteTrackOption(
          id: 'mpv:${tracks[i].id}',
          label: TrackLabelBuilder.subtitleLabel(
            title: tracks[i].title,
            language: tracks[i].language,
            codec: tracks[i].codec,
            forced: tracks[i].isForced,
            index: i,
          ).joined,
          language: tracks[i].language,
          codec: tracks[i].codec,
          selected: tracks[i].id == selectedId,
        ),
    ];
  }

  List<RemoteQualityOption> _buildRemoteQualityOptions() {
    final qualities = _playbackSession?.context.result.streamQualities ?? const <StreamQuality>[];
    if (qualities.isEmpty) return const [];
    final current = _playbackSession?.context.result.streamQuality ?? StreamQuality.original;
    return [
      RemoteQualityOption(
        id: StreamQuality.original,
        label: streamQualityName(StreamQuality.original),
        selected: current == StreamQuality.original,
      ),
      for (final q in qualities)
        RemoteQualityOption(id: q.id, label: streamQualityName(q.id), selected: q.id == current),
    ];
  }

  bool _hasCompanionRemoteProvider() {
    try {
      return Provider.of<CompanionRemoteProvider?>(context, listen: false) != null;
    } on ProviderNotFoundException {
      return false;
    }
  }

  Future<void> _handoffToRemoteDevice(BuildContext btnContext) async {
    CompanionRemoteProvider? provider;
    try {
      provider = Provider.of<CompanionRemoteProvider?>(context, listen: false);
    } on ProviderNotFoundException {
      return;
    }
    if (provider == null || !btnContext.mounted || !mounted || _shuttingDown) return;

    final selectedHost = await showRemotePlayPickerMenu(btnContext, title: t.companionRemote.handoffToRemote);
    if (selectedHost == null || !mounted || _shuttingDown) return;

    final currentPlayer = player;
    final posMs = currentPlayer?.currentPosition.inMilliseconds ?? _currentMetadata.viewOffsetMs ?? 0;
    final rate = currentPlayer?.state.rate ?? 1.0;
    final quality = _playbackSession?.context.result.streamQuality;
    final selectedMediaIndex = _effectiveSelectedMediaIndex;

    AppDatabase? db;
    try {
      db = Provider.of<AppDatabase?>(context, listen: false);
    } on ProviderNotFoundException {
      db = null;
    }
    MountManager? mountManager;
    try {
      mountManager = Provider.of<MountManager?>(context, listen: false);
    } on ProviderNotFoundException {
      mountManager = null;
    }

    final navigator = Navigator.of(context);
    final target = await buildRemoteMediaTarget(
      metadata: _currentMetadata,
      db: db,
      mountManager: mountManager,
      selectedMediaIndex: selectedMediaIndex,
      positionMs: posMs,
      playbackRate: rate,
      streamQuality: quality,
    );

    if (mounted && !_shuttingDown) {
      await _exitPlayerRoute(navigateHome: false, stop: true);
    }
    unawaited(provider.connectAndPlayMedia(selectedHost, target));
    if (navigator.mounted) {
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => RemoteControlScreen(initialHost: selectedHost, handoffInProgress: true),
          ),
        ),
      );
    }
  }
}
