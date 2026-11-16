import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../library/sync/lan_peer_sync_service.dart';
import '../../library/sync/sync_coordinator.dart';
import '../../library/sync/sync_crypto.dart';
import '../../widgets/app_icon.dart';
import 'mounts_screen.dart';

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key, this.onboardingMode = false});

  final bool onboardingMode;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final _serverController = TextEditingController(text: 'http://127.0.0.1:8088');
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _qrInputController = TextEditingController();

  bool _busy = false;
  String? _statusMessage;
  String? _error;

  String? _qrSessionId;
  String? _qrUri;
  SyncQrKeyPair? _qrKeyPair;
  Timer? _qrPollTimer;

  @override
  void dispose() {
    _qrPollTimer?.cancel();
    _serverController.dispose();
    _userController.dispose();
    _passController.dispose();
    _qrInputController.dispose();
    super.dispose();
  }

  Future<void> _submitAuth({required bool isRegister}) async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final navigator = Navigator.of(context);
    final server = _serverController.text.trim();
    final user = _userController.text.trim();
    final pass = _passController.text;
    if (server.isEmpty || user.isEmpty || pass.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
      _statusMessage = null;
    });
    try {
      if (isRegister) {
        await coordinator.register(serverUrl: server, username: user, password: pass);
      } else {
        await coordinator.loginWithPassword(serverUrl: server, username: user, password: pass);
      }
      _passController.clear();
      _cancelQr();
      if (mounted && widget.onboardingMode) {
        navigator.pop(true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startQr() async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final server = _serverController.text.trim();
    if (server.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await coordinator.startQrSession(serverUrl: server, deviceName: coordinator.lanService.deviceName);
      if (!mounted) return;
      setState(() {
        _qrSessionId = res.sessionId;
        _qrUri = res.qrUri;
        _qrKeyPair = res.keyPair;
      });
      _qrPollTimer?.cancel();
      _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollQr(server)));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pollQr(String server) async {
    final sessionId = _qrSessionId;
    final kp = _qrKeyPair;
    if (sessionId == null || kp == null || !mounted) return;
    final coordinator = context.read<SyncAndScanCoordinator>();
    final navigator = Navigator.of(context);
    try {
      final done = await coordinator.pollQrSession(serverUrl: server, sessionId: sessionId, keyPair: kp);
      if (done && mounted) {
        _cancelQr();
        if (widget.onboardingMode) {
          navigator.pop(true);
        }
      }
    } catch (e) {
      if (mounted) {
        _cancelQr();
        setState(() => _error = '$e');
      }
    }
  }

  void _cancelQr() {
    _qrPollTimer?.cancel();
    _qrPollTimer = null;
    _qrSessionId = null;
    _qrUri = null;
    _qrKeyPair = null;
  }

  Future<void> _confirmQr() async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final uri = _qrInputController.text.trim();
    if (uri.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _statusMessage = null;
    });
    try {
      await coordinator.confirmQrUri(uri);
      _qrInputController.clear();
      if (mounted) setState(() => _statusMessage = t.sync.qrAuthorized);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestLanPair(LanDiscoveredPeer peer) async {
    final lan = context.read<SyncAndScanCoordinator>().lanService;
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

  Future<void> _acceptLanPair(LanPairRequest req) async {
    final lan = context.read<SyncAndScanCoordinator>().lanService;
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
    final sync = context.watch<SyncAndScanCoordinator>();
    final sess = sync.session;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(t.sync.title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) ...[
                Material(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
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
              if (sess == null)
                ..._buildLanAndCloudSwitchCards(sync, theme)
              else
                ..._buildSignedInCards(sync, sess, theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLanAndCloudSwitchCards(SyncAndScanCoordinator sync, ThemeData theme) {
    final lan = sync.lanService;
    final trusted = lan.trustedPeers;
    final trustedIds = {for (final p in trusted) p.deviceId};
    final nearby = [
      for (final p in lan.discoveredPeers)
        if (!trustedIds.contains(p.deviceId)) p,
    ];
    final requests = lan.incomingPairRequests;
    final myPub = lan.publicKeyBase64 ?? '';

    return [
      if (!widget.onboardingMode) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${t.sync.activeModeLan} (${lan.deviceName})', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(t.sync.modeLanDesc, style: theme.textTheme.bodySmall),
                if (requests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(t.sync.lanRequestsTitle, style: theme.textTheme.titleSmall),
                  for (final req in requests)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(req.deviceName),
                      subtitle: Text(t.sync.lanPairingCode(code: req.pairingCode)),
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => lan.rejectPairRequest(req.deviceId),
                            child: Text(t.sync.lanRejectButton),
                          ),
                          FilledButton(
                            onPressed: () => unawaited(_acceptLanPair(req)),
                            child: Text(t.sync.lanAcceptButton),
                          ),
                        ],
                      ),
                    ),
                ],
                if (trusted.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t.sync.lanTrustedTitle, style: theme.textTheme.titleSmall),
                      TextButton.icon(
                        onPressed: lan.isSyncing ? null : () => unawaited(lan.syncWithAllTrustedPeers()),
                        icon: const AppIcon(Symbols.sync_rounded, size: 18),
                        label: Text(t.sync.lanSyncNow),
                      ),
                    ],
                  ),
                  for (final peer in trusted)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const AppIcon(Symbols.devices_rounded),
                      title: Text(peer.deviceName),
                      subtitle: Text(peer.lastHost ?? ''),
                      trailing: TextButton(
                        onPressed: () => unawaited(lan.removeTrustedPeer(peer.deviceId)),
                        child: Text(t.sync.lanRemoveTrust),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(t.sync.lanNearbyTitle, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
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
                        onPressed: () => unawaited(_requestLanPair(peer)),
                        child: Text(t.sync.lanPairButton),
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.onboardingMode ? t.sync.modeCloudTitle : t.sync.switchToCloudTitle,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(t.sync.modeCloudDesc, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              FocusableTextField(
                controller: _serverController,
                decoration: InputDecoration(labelText: t.sync.serverUrl),
              ),
              const SizedBox(height: 12),
              FocusableTextField(
                controller: _userController,
                decoration: InputDecoration(labelText: t.sync.username),
              ),
              const SizedBox(height: 12),
              FocusableTextField(
                controller: _passController,
                obscureText: true,
                decoration: InputDecoration(labelText: t.sync.password),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _submitAuth(isRegister: true),
                      child: Text(t.sync.register),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _submitAuth(isRegister: false),
                      child: Text(t.sync.login),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.sync.qrLoginTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(t.sync.qrHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              if (_qrUri != null) ...[
                Center(
                  child: QrImageView(
                    data: _qrUri!,
                    size: 180,
                    version: QrVersions.auto,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: _qrUri!)),
                  icon: const AppIcon(Symbols.content_copy_rounded, size: 18),
                  label: Text(_qrUri!, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
              OutlinedButton.icon(
                onPressed: _busy ? null : _startQr,
                icon: const AppIcon(Symbols.qr_code_2_rounded),
                label: Text(t.sync.qrGenerate),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildSignedInCards(SyncAndScanCoordinator sync, SyncSessionCredentials sess, ThemeData theme) {
    final lastTime = sync.lastSyncedAt == null ? t.sync.neverSynced : sync.lastSyncedAt!.toLocal().toString();
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.sync.activeModeCloud, style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(t.sync.account(name: sess.username), style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(sess.serverUrl, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(t.sync.pendingChanges(count: sync.pendingOutboxCount), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(t.sync.lastSynced(time: lastTime), style: theme.textTheme.bodySmall),
              if (sync.lastError != null) ...[
                const SizedBox(height: 6),
                Text(sync.lastError!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: sync.isSyncing ? null : () => unawaited(sync.syncNow(allowBackgroundScan: false)),
                      icon: const AppIcon(Symbols.sync_rounded),
                      label: Text(sync.isSyncing ? t.sync.syncing : t.sync.syncNow),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: sync.isSyncing ? null : () => unawaited(sync.signOut()),
                    child: Text(t.sync.switchToLan),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.sync.qrAuthorizeTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(t.sync.qrAuthorizeHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              FocusableTextField(
                controller: _qrInputController,
                decoration: const InputDecoration(hintText: 'plezy://qr-auth?...'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _confirmQr,
                icon: const AppIcon(Symbols.verified_user_rounded),
                label: Text(t.sync.qrAuthorizeButton),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}
