import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../models/companion_remote/remote_playback_models.dart';
import '../../models/companion_remote/remote_session.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/companion_remote/companion_remote_host_controller.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/dialogs.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/companion_remote/discovery_view.dart';
import '../../widgets/companion_remote/remote_device_menu.dart';
import '../../widgets/companion_remote/remote_host_catalog_view.dart';
import '../../widgets/overlay_sheet.dart';

typedef MobileRemoteScreen = RemoteControlScreen;

enum _RemoteControlTab { control, media, dpad }

/// Unified cross-device Remote Playback Control Center replacing the legacy
/// 3-tab D-Pad remote view. Works identically across Mobile, Tablet, Desktop, and TV.
class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key, this.initialHost, this.handoffInProgress = false});

  final DiscoveredHost? initialHost;
  final bool handoffInProgress;

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  static const List<double> _speedPresets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
  static int _activeScreenCount = 0;

  double? _dragPositionMs;
  double? _dragVolume;
  bool _initiatedInitialConnect = false;
  _RemoteControlTab _selectedTab = _RemoteControlTab.control;
  CompanionRemoteProvider? _provider;

  @override
  void initState() {
    super.initState();
    _activeScreenCount++;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeConnectInitialHost());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = Provider.of<CompanionRemoteProvider?>(context, listen: false);
  }

  @override
  void dispose() {
    _activeScreenCount = math.max(0, _activeScreenCount - 1);
    final provider = _provider;
    if (_activeScreenCount == 0 &&
        provider != null &&
        !provider.isDisposed &&
        provider.session?.isRemote == true) {
      unawaited(provider.leaveSession());
    }
    super.dispose();
  }

  Future<void> _maybeConnectInitialHost() async {
    if (!mounted || _initiatedInitialConnect) return;
    final host = widget.initialHost;
    if (host == null) return;
    _initiatedInitialConnect = true;
    if (widget.handoffInProgress) return;

    final provider = context.read<CompanionRemoteProvider>();
    if (provider.isConnectedToHost(host)) {
      provider.sendCommand(RemoteCommandType.requestState);
      return;
    }
    if (provider.isConnectingToHost(host)) {
      return;
    }

    if (!provider.isCryptoReady) {
      await ensureCompanionRemoteCryptoFromContext(context);
      if (!mounted) return;
    }
    try {
      await provider.connectToDiscoveredHost(host);
    } catch (_) {
      // Errors surface through provider.session and DiscoveryView.
    }
  }

  Future<void> _handleDisconnect(BuildContext context, CompanionRemoteProvider provider) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.common.disconnect,
      message: t.companionRemote.remote.disconnectConfirm,
      confirmText: t.common.disconnect,
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;

    await provider.leaveSession();
    if (!context.mounted) return;

    final settings = SettingsService.instanceOrNull ?? await SettingsService.getInstance();
    if (context.mounted && settings.read(SettingsService.enableCompanionRemoteServer)) {
      unawaited(startCompanionRemoteHost(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlaySheetHost(
      canPop: true,
      child: Consumer<CompanionRemoteProvider>(
        builder: (context, provider, _) {
          final deviceName = provider.connectedDevice?.name ?? widget.initialHost?.name;
          final title = (provider.isConnected && deviceName != null && deviceName.isNotEmpty)
              ? t.companionRemote.controllingDevice(name: deviceName)
              : t.companionRemote.title;

          return Scaffold(
            appBar: AppBar(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                if (provider.isConnected || provider.onlineTrustedDevices.isNotEmpty)
                  Builder(
                    builder: (btnContext) => IconButton(
                      icon: const AppIcon(Symbols.devices_rounded),
                      tooltip: t.companionRemote.remoteDevices,
                      onPressed: () => unawaited(showRemoteDevicesStatusMenu(btnContext)),
                    ),
                  ),
                if (provider.isConnected)
                  IconButton(
                    icon: const AppIcon(Symbols.link_off_rounded),
                    tooltip: t.common.disconnect,
                    onPressed: () => unawaited(_handleDisconnect(context, provider)),
                  ),
              ],
            ),
            body: _buildBody(context, provider),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, CompanionRemoteProvider provider) {
    if (provider.status == RemoteSessionStatus.reconnecting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(t.companionRemote.remote.reconnecting, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                t.companionRemote.remote.attemptOf(current: provider.reconnectAttempts),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens(context).textMuted),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: () => unawaited(provider.cancelReconnect()),
                    child: Text(t.common.cancel),
                  ),
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: () => unawaited(provider.retryReconnectNow()),
                    child: Text(t.companionRemote.remote.retryNow),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (provider.status == RemoteSessionStatus.connecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t.companionRemote.pairing.connecting, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );
    }

    if (!provider.isConnected) {
      return const DiscoveryView();
    }

    final snapshot = provider.remotePlayerSnapshot;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_RemoteControlTab>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    ButtonSegment(
                      value: _RemoteControlTab.control,
                      icon: const AppIcon(Symbols.tune_rounded, size: 18),
                      label: Text(t.companionRemote.tabControl),
                    ),
                    ButtonSegment(
                      value: _RemoteControlTab.media,
                      icon: const AppIcon(Symbols.video_library_rounded, size: 18),
                      label: Text(t.companionRemote.tabMedia),
                    ),
                    ButtonSegment(
                      value: _RemoteControlTab.dpad,
                      icon: const AppIcon(Symbols.gamepad_rounded, size: 18),
                      label: Text(t.companionRemote.tabDpad),
                    ),
                  ],
                  selected: {_selectedTab},
                  onSelectionChanged: (next) {
                    if (next.isEmpty) return;
                    setState(() => _selectedTab = next.first);
                  },
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: switch (_selectedTab) {
            _RemoteControlTab.control => _buildControlTab(context, provider, snapshot),
            _RemoteControlTab.media => RemoteHostCatalogView(
              onPlaybackStarted: () {
                if (mounted) setState(() => _selectedTab = _RemoteControlTab.control);
              },
            ),
            _RemoteControlTab.dpad => _buildDpadTab(context, provider, snapshot),
          },
        ),
      ],
    );
  }

  Widget _buildControlTab(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const PageStorageKey<String>('remote_control_scroll'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            _buildNowPlayingCard(context, provider, snapshot),
            const SizedBox(height: 8),
            if (snapshot.active) ...[
              _buildProgressCard(context, provider, snapshot),
              const SizedBox(height: 8),
            ],
            _buildTransportCard(context, provider, snapshot),
            if (snapshot.seasons.isNotEmpty || snapshot.episodes.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildEpisodesCard(context, provider, snapshot),
            ],
            const SizedBox(height: 8),
            _buildVolumeAndSpeedCard(context, provider, snapshot),
            const SizedBox(height: 8),
            _buildTracksAndDisplayCard(context, provider, snapshot),
          ],
        ),
      ),
    );
  }

  Widget _buildDpadTab(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      t.companionRemote.dpadControls,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 16),
                    IconButton.filledTonal(
                      iconSize: 32,
                      tooltip: 'Up',
                      onPressed: () => provider.sendCommand(RemoteCommandType.dpadUp),
                      icon: const AppIcon(Symbols.keyboard_arrow_up_rounded),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          iconSize: 32,
                          tooltip: 'Left',
                          onPressed: () => provider.sendCommand(RemoteCommandType.dpadLeft),
                          icon: const AppIcon(Symbols.keyboard_arrow_left_rounded),
                        ),
                        const SizedBox(width: 18),
                        FilledButton(
                          onPressed: () => provider.sendCommand(RemoteCommandType.select),
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            minimumSize: const Size(72, 72),
                          ),
                          child: Text(t.companionRemote.ok),
                        ),
                        const SizedBox(width: 18),
                        IconButton.filledTonal(
                          iconSize: 32,
                          tooltip: 'Right',
                          onPressed: () => provider.sendCommand(RemoteCommandType.dpadRight),
                          icon: const AppIcon(Symbols.keyboard_arrow_right_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    IconButton.filledTonal(
                      iconSize: 32,
                      tooltip: 'Down',
                      onPressed: () => provider.sendCommand(RemoteCommandType.dpadDown),
                      icon: const AppIcon(Symbols.keyboard_arrow_down_rounded),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => provider.sendCommand(RemoteCommandType.back),
                          icon: const AppIcon(Symbols.arrow_back_rounded, size: 18),
                          label: Text(t.companionRemote.backToBrowse),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => provider.sendCommand(RemoteCommandType.home),
                          icon: const AppIcon(Symbols.home_rounded, size: 18),
                          label: Text(t.discover.title),
                        ),
                        IconButton.outlined(
                          tooltip: t.companionRemote.remote.menu,
                          onPressed: () => provider.sendCommand(RemoteCommandType.contextMenu),
                          icon: const AppIcon(Symbols.menu_rounded, size: 20),
                        ),
                        IconButton.outlined(
                          tooltip: t.companionRemote.remote.fullscreen,
                          onPressed: () => provider.sendCommand(RemoteCommandType.fullscreen),
                          icon: const AppIcon(Symbols.fullscreen_rounded, size: 20),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.companionRemote.quickActions,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          label: Text(t.companionRemote.remote.tabDiscover),
                          onPressed: () => provider.sendCommand(RemoteCommandType.tabDiscover),
                        ),
                        ActionChip(
                          label: Text(t.companionRemote.remote.tabLibraries),
                          onPressed: () => provider.sendCommand(RemoteCommandType.tabLibraries),
                        ),
                        ActionChip(
                          label: Text(t.companionRemote.remote.tabSearch),
                          onPressed: () => provider.sendCommand(RemoteCommandType.tabSearch),
                        ),
                        ActionChip(
                          label: Text(t.companionRemote.remote.tabSettings),
                          onPressed: () => provider.sendCommand(RemoteCommandType.tabSettings),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: t.companionRemote.remote.volumeDown,
                          onPressed: () => provider.sendCommand(RemoteCommandType.volumeDown),
                          icon: const AppIcon(Symbols.volume_down_rounded),
                        ),
                        IconButton(
                          tooltip: t.companionRemote.remote.volume,
                          onPressed: () => provider.sendCommand(RemoteCommandType.volumeMute),
                          icon: const AppIcon(Symbols.volume_off_rounded),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => provider.sendCommand(RemoteCommandType.playPause),
                          icon: AppIcon(snapshot.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                          label: Text(t.companionRemote.remote.playPause),
                        ),
                        IconButton(
                          tooltip: t.companionRemote.remote.volumeUp,
                          onPressed: () => provider.sendCommand(RemoteCommandType.volumeUp),
                          icon: const AppIcon(Symbols.volume_up_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNowPlayingCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (!snapshot.active) {
      final isOpening = snapshot.stage == 'opening';
      final isError = snapshot.stage == 'error';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              if (isOpening)
                const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
              else
                AppIcon(
                  isError ? Symbols.error_outline_rounded : Symbols.live_tv_rounded,
                  size: 32,
                  color: isError ? colorScheme.error : tokens(context).textMuted,
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOpening
                          ? t.companionRemote.openingOnRemote
                          : isError
                          ? (snapshot.errorMessage ?? t.companionRemote.mediaNotFoundOnDevice)
                          : t.companionRemote.idle,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isOpening ? (snapshot.title ?? '') : t.companionRemote.idleControlHint,
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                    ),
                    if (!isOpening) ...[
                      const SizedBox(height: 10),
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => _selectedTab = _RemoteControlTab.media),
                        icon: const AppIcon(Symbols.search_rounded, size: 18),
                        label: Text(t.companionRemote.browseTargetMedia),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final episodeTag = (snapshot.mediaKind == 'episode' &&
            snapshot.seasonNumber != null &&
            snapshot.episodeNumber != null)
        ? 'S${snapshot.seasonNumber!.toString().padLeft(2, '0')}E${snapshot.episodeNumber!.toString().padLeft(2, '0')}'
        : null;
    final stateText = snapshot.buffering
        ? t.companionRemote.buffering
        : snapshot.playing
        ? t.companionRemote.playingNow
        : t.companionRemote.paused;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot.posterUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  snapshot.posterUrl!,
                  width: 64,
                  height: 92,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _posterPlaceholder(context),
                ),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (snapshot.seriesTitle != null && snapshot.seriesTitle!.isNotEmpty)
                    Text(
                      snapshot.seriesTitle!,
                      style: theme.textTheme.labelLarge?.copyWith(color: colorScheme.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text(
                    episodeTag != null ? '$episodeTag · ${snapshot.title ?? ''}' : (snapshot.title ?? ''),
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        avatar: AppIcon(
                          snapshot.playing ? Symbols.play_arrow_rounded : Symbols.pause_rounded,
                          size: 16,
                        ),
                        label: Text(stateText),
                        visualDensity: VisualDensity.compact,
                      ),
                      OutlinedButton.icon(
                        onPressed: () => provider.sendCommand(RemoteCommandType.stop),
                        icon: const AppIcon(Symbols.stop_circle_rounded, size: 18),
                        label: Text(t.companionRemote.stopRemotePlayback),
                        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _posterPlaceholder(BuildContext context) {
    return Container(
      width: 64,
      height: 92,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: AppIcon(Symbols.movie_rounded, color: tokens(context).textMuted),
    );
  }

  Widget _buildProgressCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final hasDuration = snapshot.durationMs > 0;
    final maxMs = hasDuration ? snapshot.durationMs.toDouble() : 1.0;
    final displayMs = hasDuration ? (_dragPositionMs ?? snapshot.positionMs.toDouble()).clamp(0.0, maxMs) : 0.0;
    final shownPositionMs = hasDuration ? displayMs.round() : math.max(0, snapshot.positionMs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          children: [
            Slider(
              value: displayMs,
              min: 0,
              max: maxMs,
              onChanged: hasDuration ? (v) => setState(() => _dragPositionMs = v) : null,
              onChangeEnd: hasDuration
                  ? (v) {
                      setState(() => _dragPositionMs = null);
                      provider.sendCommand(RemoteCommandType.seekTo, data: {'positionMs': v.round()});
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDurationTimestamp(Duration(milliseconds: shownPositionMs))),
                  Text(formatDurationTimestamp(Duration(milliseconds: snapshot.durationMs))),
                ],
              ),
            ),
            if (snapshot.canSkipIntro || snapshot.canSkipCredits) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  if (snapshot.canSkipIntro)
                    FilledButton.tonalIcon(
                      onPressed: () => provider.sendCommand(RemoteCommandType.skipIntro),
                      icon: const AppIcon(Symbols.skip_next_rounded, size: 18),
                      label: Text(t.companionRemote.skipIntro),
                    ),
                  if (snapshot.canSkipCredits)
                    FilledButton.tonalIcon(
                      onPressed: () => provider.sendCommand(RemoteCommandType.skipCredits),
                      icon: const AppIcon(Symbols.skip_next_rounded, size: 18),
                      label: Text(t.companionRemote.skipCredits),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTransportCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final canPrev = !snapshot.active || snapshot.canPrevious;
    final canNext = !snapshot.active || snapshot.canNext;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const AppIcon(Symbols.skip_previous_rounded, size: 28),
              tooltip: t.companionRemote.remote.previous,
              onPressed: canPrev ? () => provider.sendCommand(RemoteCommandType.previousTrack) : null,
            ),
            IconButton(
              icon: const AppIcon(Symbols.replay_10_rounded, size: 28),
              tooltip: t.companionRemote.remote.seekBack,
              onPressed: () => provider.sendCommand(RemoteCommandType.seekBackward),
            ),
            FilledButton(
              onPressed: () => provider.sendCommand(RemoteCommandType.playPause),
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(18),
              ),
              child: Semantics(
                label: t.companionRemote.remote.playPause,
                child: AppIcon(
                  snapshot.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                  size: 32,
                  fill: 1,
                ),
              ),
            ),
            IconButton(
              icon: const AppIcon(Symbols.forward_10_rounded, size: 28),
              tooltip: t.companionRemote.remote.seekForward,
              onPressed: () => provider.sendCommand(RemoteCommandType.seekForward),
            ),
            IconButton(
              icon: const AppIcon(Symbols.skip_next_rounded, size: 28),
              tooltip: t.companionRemote.remote.next,
              onPressed: canNext ? () => provider.sendCommand(RemoteCommandType.nextTrack) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodesCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final selectedSeason = snapshot.browsedSeasonNumber ?? snapshot.seasonNumber;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.companionRemote.episodes, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (snapshot.seasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final season in snapshot.seasons) ...[
                      ChoiceChip(
                        label: Text(
                          season.title.isNotEmpty
                              ? season.title
                              : t.companionRemote.seasonNumber(number: season.seasonNumber),
                        ),
                        selected: season.seasonNumber == selectedSeason,
                        onSelected: (_) => provider.sendCommand(
                          RemoteCommandType.browseSeason,
                          data: {'seasonNumber': season.seasonNumber},
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ],
            if (snapshot.episodes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: snapshot.episodes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final ep = snapshot.episodes[index];
                    return ListTile(
                      dense: true,
                      selected: ep.current,
                      leading: CircleAvatar(
                        radius: 15,
                        child: Text('${ep.episodeNumber}', style: theme.textTheme.labelSmall),
                      ),
                      title: Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: ep.durationMs != null
                          ? Text(formatDurationTimestamp(Duration(milliseconds: ep.durationMs!)))
                          : null,
                      trailing: ep.current
                          ? AppIcon(Symbols.graphic_eq_rounded, color: theme.colorScheme.primary)
                          : ep.watched
                          ? AppIcon(Symbols.check_circle_rounded, size: 18, color: tokens(context).textMuted)
                          : null,
                      onTap: () => provider.sendCommand(
                        RemoteCommandType.playEpisodeItem,
                        data: {'itemKey': ep.itemKey},
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVolumeAndSpeedCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final displayVol = (_dragVolume ?? snapshot.volume).clamp(0.0, 100.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: AppIcon(
                    snapshot.muted || displayVol <= 0.5 ? Symbols.volume_off_rounded : Symbols.volume_up_rounded,
                  ),
                  tooltip: t.companionRemote.remote.volume,
                  onPressed: () => provider.sendCommand(RemoteCommandType.volumeMute),
                ),
                Expanded(
                  child: Slider(
                    value: displayVol,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    onChanged: (v) => setState(() => _dragVolume = v),
                    onChangeEnd: (v) {
                      setState(() => _dragVolume = null);
                      provider.sendCommand(RemoteCommandType.volumeSet, data: {'volume': v});
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${displayVol.round()}%', textAlign: TextAlign.end, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              t.companionRemote.playbackSpeed,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final speed in _speedPresets)
                  ChoiceChip(
                    label: Text('${speed}x'),
                    selected: (snapshot.playbackRate - speed).abs() < 0.05,
                    onSelected: (_) => provider.sendCommand(RemoteCommandType.setRate, data: {'rate': speed}),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTracksAndDisplayCard(
    BuildContext context,
    CompanionRemoteProvider provider,
    RemotePlayerSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final selectedSubtitle = snapshot.subtitleTracks.where((t) => t.selected).firstOrNull?.label ??
        t.companionRemote.subtitleTrackOff;
    final selectedAudio = snapshot.audioTracks.where((t) => t.selected).firstOrNull?.label ?? '-';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const AppIcon(Symbols.subtitles_rounded),
              title: Text(t.companionRemote.remote.subtitles),
              subtitle: Text(selectedSubtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const AppIcon(Symbols.chevron_right_rounded),
              onTap: snapshot.subtitleTracks.isEmpty
                  ? null
                  : () => _pickTrackSheet(
                        context,
                        title: t.companionRemote.remote.subtitles,
                        tracks: snapshot.subtitleTracks,
                        onPick: (id) => provider.sendCommand(
                          RemoteCommandType.selectSubtitleTrack,
                          data: {'trackId': id},
                        ),
                      ),
            ),
            _SyncOffsetStepperRow(
              label: t.companionRemote.subtitleDelay,
              offsetMs: snapshot.subtitleSyncOffsetMs,
              onChanged: (next) => provider.sendCommand(RemoteCommandType.setSyncOffset, data: {'subtitleMs': next}),
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const AppIcon(Symbols.audiotrack_rounded),
              title: Text(t.companionRemote.remote.audio),
              subtitle: Text(selectedAudio, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const AppIcon(Symbols.chevron_right_rounded),
              onTap: snapshot.audioTracks.isEmpty
                  ? null
                  : () => _pickTrackSheet(
                        context,
                        title: t.companionRemote.remote.audio,
                        tracks: snapshot.audioTracks,
                        onPick: (id) => provider.sendCommand(
                          RemoteCommandType.selectAudioTrack,
                          data: {'trackId': id},
                        ),
                      ),
            ),
            _SyncOffsetStepperRow(
              label: t.companionRemote.audioDelay,
              offsetMs: snapshot.audioSyncOffsetMs,
              onChanged: (next) => provider.sendCommand(RemoteCommandType.setSyncOffset, data: {'audioMs': next}),
            ),
            if (snapshot.qualities.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 6),
              Text(t.companionRemote.qualityLabel, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final quality in snapshot.qualities)
                    ChoiceChip(
                      label: Text(quality.label),
                      selected: quality.selected,
                      onSelected: (_) =>
                          provider.sendCommand(RemoteCommandType.selectQuality, data: {'qualityId': quality.id}),
                    ),
                ],
              ),
            ],
            const Divider(),
            const SizedBox(height: 6),
            Text(t.companionRemote.aspectRatio, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: Text(t.companionRemote.aspectContain)),
                  ButtonSegment(value: 1, label: Text(t.companionRemote.aspectCover)),
                  ButtonSegment(value: 2, label: Text(t.companionRemote.aspectStretch)),
                ],
                selected: {snapshot.boxFitMode.clamp(0, 2)},
                onSelectionChanged: (set) {
                  if (set.isEmpty) return;
                  provider.sendCommand(RemoteCommandType.setBoxFitMode, data: {'mode': set.first});
                },
              ),
            ),
            if (snapshot.isDesktopHost) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const AppIcon(Symbols.fullscreen_rounded),
                title: Text(t.companionRemote.remote.fullscreen),
                value: snapshot.isFullscreen,
                onChanged: (_) => provider.sendCommand(RemoteCommandType.fullscreen),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickTrackSheet(
    BuildContext context, {
    required String title,
    required List<RemoteTrackOption> tracks,
    required ValueChanged<String> onPick,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            for (final track in tracks)
              ListTile(
                leading: track.selected ? const AppIcon(Symbols.check_rounded) : const SizedBox(width: 24),
                title: Text(track.label),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onPick(track.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SyncOffsetStepperRow extends StatelessWidget {
  const _SyncOffsetStepperRow({required this.label, required this.offsetMs, required this.onChanged});

  final String label;
  final int offsetMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = offsetMs == 0 ? '0 ms' : '${offsetMs > 0 ? '+' : ''}$offsetMs ms';
    return Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        IconButton(
          icon: const AppIcon(Symbols.remove_rounded, size: 18),
          tooltip: '-100 ms',
          visualDensity: VisualDensity.compact,
          onPressed: () => onChanged(offsetMs - 100),
        ),
        TextButton(
          onPressed: offsetMs == 0 ? null : () => onChanged(0),
          child: Text(text),
        ),
        IconButton(
          icon: const AppIcon(Symbols.add_rounded, size: 18),
          tooltip: '+100 ms',
          visualDensity: VisualDensity.compact,
          onPressed: () => onChanged(offsetMs + 100),
        ),
      ],
    );
  }
}
