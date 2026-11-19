import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/companion_remote/lan_identity_store.dart';
import '../../services/companion_remote/lan_pairing_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/setting_tile.dart';
import 'mounts_screen.dart';

/// Standalone view of LAN remote-control discovery status, receiver toggle,
/// pairing requests, nearby devices, and paired remote peers (no P2P library sync).
class LanDevicesScreen extends StatelessWidget {
  const LanDevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.sync.lanDevicesTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
          child: ListView(padding: const EdgeInsets.all(16), children: const [LanDevicesPanel(standalone: true)]),
        ),
      ),
    );
  }
}

/// Standalone LAN discovery & pairing panel shown in [LanDevicesScreen].
class LanDevicesPanel extends StatefulWidget {
  const LanDevicesPanel({super.key, this.standalone = false});

  final bool standalone;

  @override
  State<LanDevicesPanel> createState() => _LanDevicesPanelState();
}

class _LanDevicesPanelState extends State<LanDevicesPanel> {
  String? _statusMessage;
  String? _error;

  Future<void> _requestLanPair(LanPairingService lan, LanDiscoveredPeer peer) async {
    setState(() {
      _error = null;
      _statusMessage = null;
    });
    try {
      await lan.requestPairWithPeer(peer);
      if (mounted) setState(() => _statusMessage = t.sync.lanPairRequested);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _acceptLanPair(LanPairingService lan, LanPairRequest req) async {
    setState(() {
      _error = null;
      _statusMessage = null;
    });
    try {
      await lan.acceptPairRequest(req);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lan = context.watch<LanPairingService?>();
    final theme = Theme.of(context);
    if (lan == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(t.sync.lanDiscoveryStopped, style: theme.textTheme.bodyMedium),
        ),
      );
    }

    final trusted = lan.trustedPeers;
    final discoveredIds = {for (final p in lan.discoveredPeers) p.deviceId};
    final trustedIds = {for (final p in trusted) p.deviceId};
    final nearby = [
      for (final p in lan.discoveredPeers)
        if (!trustedIds.contains(p.deviceId)) p,
    ];
    final requests = lan.incomingPairRequests;
    final myPub = lan.publicKeyBase64 ?? '';

    if (widget.standalone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._buildBanners(theme),
          _buildStatusCard(lan, theme),
          if (SettingsService.instanceOrNull != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  SettingSwitchTile(
                    pref: SettingsService.enableCompanionRemoteServer,
                    icon: Symbols.phone_android_rounded,
                    title: t.settings.companionRemoteServer,
                    subtitle: t.settings.companionRemoteServerDescription,
                  ),
                ],
              ),
            ),
          ],
          if (requests.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildRequestsSection(lan, requests, theme),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildNearbySection(lan, nearby, lan.discoveredPeers.length, myPub, theme),
              ),
            ),
          ),
          if (trusted.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildTrustedSection(lan, trusted, discoveredIds, theme),
                ),
              ),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._buildBanners(theme),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AppIcon(
                      lan.isRunning ? Symbols.wifi_tethering_rounded : Symbols.portable_wifi_off_rounded,
                      size: 20,
                      color: lan.isRunning ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${t.sync.lanDevicesTitle} (${lan.deviceName ?? 'TTPlay'})',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(t.sync.remoteControlHint, style: theme.textTheme.bodySmall),
                if (requests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ..._buildRequestsSection(lan, requests, theme),
                ],
                if (trusted.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ..._buildTrustedSection(lan, trusted, discoveredIds, theme),
                ],
                const SizedBox(height: 16),
                ..._buildNearbySection(lan, nearby, lan.discoveredPeers.length, myPub, theme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildBanners(ThemeData theme) {
    final effectiveError = _error;
    return [
      if (effectiveError != null && effectiveError.isNotEmpty) ...[
        Material(
          color: theme.colorScheme.errorContainer,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(effectiveError, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_statusMessage != null) ...[
        Material(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_statusMessage!, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _buildStatusCard(LanPairingService lan, ThemeData theme) {
    final running = lan.isRunning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(
              running ? Symbols.wifi_tethering_rounded : Symbols.portable_wifi_off_rounded,
              size: 24,
              color: running ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t.sync.menuModeLanSubtitle(device: lan.deviceName ?? 'TTPlay'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    running ? t.sync.lanDiscoveryRunning : t.sync.lanDiscoveryStopped,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: running ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(t.sync.remoteControlHint, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRequestsSection(LanPairingService lan, List<LanPairRequest> requests, ThemeData theme) => [
    Text(t.sync.lanRequestsTitle, style: theme.textTheme.titleSmall),
    const SizedBox(height: 4),
    for (final req in requests)
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(req.deviceName),
        subtitle: Text(t.sync.lanPairingCode(code: req.pairingCode)),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: () => lan.rejectPairRequest(req.deviceId), child: Text(t.sync.lanRejectButton)),
            FilledButton(onPressed: () => unawaited(_acceptLanPair(lan, req)), child: Text(t.sync.lanAcceptButton)),
          ],
        ),
      ),
  ];

  List<Widget> _buildTrustedSection(
    LanPairingService lan,
    List<LanTrustedPeer> trusted,
    Set<String> discoveredIds,
    ThemeData theme,
  ) => [
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(t.sync.lanTrustedTitle, style: theme.textTheme.titleSmall),
        TextButton.icon(
          onPressed: () => unawaited(lan.probeTrustedPeers()),
          icon: const AppIcon(Symbols.refresh_rounded, size: 18),
          label: Text(t.sync.lanSyncNow),
        ),
      ],
    ),
    for (final peer in trusted)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const AppIcon(Symbols.devices_rounded),
        title: Row(
          children: [
            Flexible(child: Text(peer.deviceName, overflow: TextOverflow.ellipsis)),
            if (discoveredIds.contains(peer.deviceId)) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  t.sync.lanPeerOnline,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(peer.lastHost ?? ''),
        trailing: TextButton(
          onPressed: () => unawaited(lan.revokeTrustedPeer(peer.deviceId)),
          child: Text(t.sync.lanRemoveTrust),
        ),
      ),
  ];

  List<Widget> _buildNearbySection(
    LanPairingService lan,
    List<LanDiscoveredPeer> nearby,
    int totalDiscoveredCount,
    String myPub,
    ThemeData theme,
  ) => [
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(t.sync.lanNearbyTitle, style: theme.textTheme.titleSmall),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: totalDiscoveredCount > 0
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
          ),
          child: Text(
            t.sync.lanDiscoveredCount(count: totalDiscoveredCount),
            style: theme.textTheme.labelSmall?.copyWith(
              color: totalDiscoveredCount > 0
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 6),
    if (nearby.isEmpty)
      Text(t.sync.lanDiscoveryEmpty, style: theme.textTheme.bodySmall)
    else
      for (final peer in nearby)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const AppIcon(Symbols.radar_rounded),
          title: Text('${peer.deviceName} (${peer.platform})'),
          subtitle: Text(t.sync.lanPairingCode(code: peer.pairingCodeFor(myPub))),
          trailing: OutlinedButton(
            onPressed: () => unawaited(_requestLanPair(lan, peer)),
            child: Text(t.sync.lanPairButton),
          ),
        ),
  ];
}
