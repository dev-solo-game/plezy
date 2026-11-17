import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/companion_remote/remote_playback_models.dart';
import '../../providers/companion_remote_provider.dart';
import '../../screens/companion_remote/mobile_remote_screen.dart';
import '../../services/companion_remote/companion_remote_host_controller.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/formatters.dart';
import '../app_icon.dart';

/// Opens a live-updating popover showing all online trusted/same-account
/// devices, their current playback title/progress, inline play/pause, and
/// navigation into [RemoteControlScreen].
Future<void> showRemoteDevicesStatusMenu(BuildContext buttonContext) async {
  final anchor = _computeAnchorRect(buttonContext);
  final provider = buttonContext.read<CompanionRemoteProvider>();
  if (!provider.isCryptoReady) {
    unawaited(ensureCompanionRemoteCryptoFromContext(buttonContext).then((ok) {
      if (ok && !provider.isDisposed) {
        unawaited(provider.refreshOnlineDeviceStatuses());
      }
    }));
  } else {
    provider.startPassiveDiscovery();
    unawaited(provider.refreshOnlineDeviceStatuses());
  }

  final selectedDevice = await Navigator.of(buttonContext, rootNavigator: false).push<RemoteOnlineDevice>(
    _AnchoredRemoteMenuRoute<RemoteOnlineDevice>(
      anchorRect: anchor,
      builder: (_) => const _RemoteDeviceMenuContent(isPickerMode: false),
    ),
  );

  if (selectedDevice == null || !buttonContext.mounted) return;
  await Navigator.of(buttonContext).push(
    MaterialPageRoute<void>(builder: (_) => RemoteControlScreen(initialHost: selectedDevice.host)),
  );
}

/// Opens a popover allowing the user to pick an online trusted/same-account
/// remote device to start or continue playback on.
Future<DiscoveredHost?> showRemotePlayPickerMenu(BuildContext buttonContext, {String? title}) {
  final anchor = _computeAnchorRect(buttonContext);
  final provider = buttonContext.read<CompanionRemoteProvider>();
  if (!provider.isCryptoReady) {
    unawaited(ensureCompanionRemoteCryptoFromContext(buttonContext).then((ok) {
      if (ok && !provider.isDisposed) {
        unawaited(provider.refreshOnlineDeviceStatuses());
      }
    }));
  } else {
    provider.startPassiveDiscovery();
    unawaited(provider.refreshOnlineDeviceStatuses());
  }

  return Navigator.of(buttonContext, rootNavigator: false).push<DiscoveredHost>(
    _AnchoredRemoteMenuRoute<DiscoveredHost>(
      anchorRect: anchor,
      builder: (_) => _RemoteDeviceMenuContent(isPickerMode: true, title: title),
    ),
  );
}

Rect? _computeAnchorRect(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return null;
  final offset = renderObject.localToGlobal(Offset.zero);
  return offset & renderObject.size;
}

class _AnchoredRemoteMenuRoute<T> extends PopupRoute<T> {
  _AnchoredRemoteMenuRoute({required this.anchorRect, required this.builder});

  final Rect? anchorRect;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => Colors.black26;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => MaterialLocalizations.of(navigator!.context).modalBarrierDismissLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final media = MediaQuery.of(context);
    final screenSize = media.size;
    final padding = media.padding;
    const menuWidth = 340.0;
    final maxWidth = math.min(menuWidth, screenSize.width - 24);

    final Widget menu = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: math.min(280.0, maxWidth),
        maxWidth: maxWidth,
        maxHeight: screenSize.height * 0.65,
      ),
      child: Material(
        elevation: 10,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: builder(context),
      ),
    );

    if (anchorRect == null) {
      return Center(child: Padding(padding: const EdgeInsets.all(16), child: menu));
    }

    final anchor = anchorRect!;
    final left = (anchor.right - maxWidth).clamp(12.0, math.max(12.0, screenSize.width - maxWidth - 12.0)).toDouble();
    final spaceBelow = screenSize.height - anchor.bottom - padding.bottom - 16;
    final preferAbove = spaceBelow < 220 && anchor.top > spaceBelow;
    final top = preferAbove ? null : math.max(padding.top + 8.0, anchor.bottom + 6.0);
    final bottom = preferAbove ? math.max(padding.bottom + 8.0, screenSize.height - anchor.top + 6.0) : null;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut), child: menu),
        ),
      ],
    );
  }
}

class _RemoteDeviceMenuContent extends StatefulWidget {
  const _RemoteDeviceMenuContent({required this.isPickerMode, this.title});

  final bool isPickerMode;
  final String? title;

  @override
  State<_RemoteDeviceMenuContent> createState() => _RemoteDeviceMenuContentState();
}

class _RemoteDeviceMenuContentState extends State<_RemoteDeviceMenuContent> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    if (!widget.isPickerMode) {
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted) return;
        unawaited(context.read<CompanionRemoteProvider>().refreshOnlineDeviceStatuses());
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = widget.title ??
        (widget.isPickerMode ? t.companionRemote.selectRemoteDevice : t.companionRemote.remoteDevices);

    return Consumer<CompanionRemoteProvider>(
      builder: (context, provider, _) {
        final devices = provider.onlineTrustedDevices;
        final isRefreshing = devices.any((d) => d.loadingStatus);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  AppIcon(Symbols.connected_tv_rounded, size: 20, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: isRefreshing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.primary),
                          )
                        : const AppIcon(Symbols.refresh_rounded, size: 18),
                    tooltip: t.common.refresh,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(provider.refreshOnlineDeviceStatuses()),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(Symbols.devices_other_rounded, size: 36, color: tokens(context).textMuted),
                    const SizedBox(height: 10),
                    Text(
                      t.companionRemote.noOnlineDevices,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.companionRemote.noOnlineDevicesHint,
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: devices.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return _RemoteDeviceRow(
                      device: device,
                      isPickerMode: widget.isPickerMode,
                      isActiveSession: provider.isConnectedToHost(device.host),
                      onTap: () {
                        if (widget.isPickerMode) {
                          Navigator.of(context).pop(device.host);
                        } else {
                          Navigator.of(context).pop(device);
                        }
                      },
                      onTogglePlayPause: device.snapshot.active && !widget.isPickerMode
                          ? () => unawaited(provider.toggleOnlineDevicePlayPause(device.host))
                          : null,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RemoteDeviceRow extends StatelessWidget {
  const _RemoteDeviceRow({
    required this.device,
    required this.isPickerMode,
    required this.isActiveSession,
    required this.onTap,
    this.onTogglePlayPause,
  });

  final RemoteOnlineDevice device;
  final bool isPickerMode;
  final bool isActiveSession;
  final VoidCallback onTap;
  final VoidCallback? onTogglePlayPause;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final snap = device.snapshot;

    final statusLabel = !snap.active
        ? (snap.stage == 'opening' ? t.companionRemote.openingOnRemote : t.companionRemote.idle)
        : snap.buffering
        ? t.companionRemote.buffering
        : snap.playing
        ? t.companionRemote.playingNow
        : t.companionRemote.paused;

    final mediaLabel = _formatMediaLabel(snap);

    return InkWell(
      autofocus: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isActiveSession ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: AppIcon(
                _platformIcon(device.host.platform),
                size: 20,
                color: isActiveSession ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.host.name,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: snap.active
                              ? (snap.playing ? colorScheme.primaryContainer : colorScheme.secondaryContainer)
                              : colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: snap.active
                                ? (snap.playing ? colorScheme.onPrimaryContainer : colorScheme.onSecondaryContainer)
                                : tokens(context).textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (mediaLabel != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      mediaLabel,
                      style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (snap.active && snap.durationMs > 0) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(value: snap.progressFraction, minHeight: 3),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${formatDurationTimestamp(Duration(milliseconds: snap.positionMs))} / '
                      '${formatDurationTimestamp(Duration(milliseconds: snap.durationMs))}',
                      style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted),
                    ),
                  ],
                ],
              ),
            ),
            if (onTogglePlayPause != null)
              IconButton(
                icon: AppIcon(snap.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded, size: 22),
                tooltip: snap.playing ? t.companionRemote.paused : t.companionRemote.playingNow,
                visualDensity: VisualDensity.compact,
                onPressed: onTogglePlayPause,
              )
            else if (!isPickerMode)
              AppIcon(Symbols.chevron_right_rounded, size: 20, color: tokens(context).textMuted),
          ],
        ),
      ),
    );
  }

  static String? _formatMediaLabel(RemotePlayerSnapshot snap) {
    if (!snap.active) return null;
    final title = snap.title ?? '';
    if (snap.mediaKind == 'episode' && snap.seasonNumber != null && snap.episodeNumber != null) {
      final code =
          'S${snap.seasonNumber!.toString().padLeft(2, '0')}E${snap.episodeNumber!.toString().padLeft(2, '0')}';
      final series = snap.seriesTitle;
      if (series != null && series.isNotEmpty) {
        return title.isNotEmpty ? '$series · $code $title' : '$series · $code';
      }
      return title.isNotEmpty ? '$code $title' : code;
    }
    return title.isEmpty ? null : title;
  }

  static IconData _platformIcon(String platform) {
    final lower = platform.toLowerCase();
    if (lower.contains('tv')) return Symbols.tv_rounded;
    if (lower.contains('android') || lower.contains('ios')) return Symbols.smartphone_rounded;
    return Symbols.computer_rounded;
  }
}
