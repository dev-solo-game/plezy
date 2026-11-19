import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../library/sync/library_workspace_store.dart';
import '../../library/sync/sync_coordinator.dart';
import '../../library/sync/sync_crypto.dart';
import '../../library/sync/sync_local_store.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/library_status_indicator.dart';
import 'lan_devices_screen.dart';
import 'mounts_screen.dart';
import 'sync_qr_scanner_screen.dart';

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key, this.onboardingMode = false, this.initialServerKind});

  final bool onboardingMode;
  final SyncServerKind? initialServerKind;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final _serverController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _qrInputController = TextEditingController();

  SyncAndScanCoordinator? _coordinatorRef;
  late SyncServerKind _selectedKind;

  bool _busy = false;
  bool _probing = false;
  String? _probeMessage;
  bool? _probeSuccess;
  String? _statusMessage;
  String? _error;

  String? _qrSessionId;
  String? _qrUri;
  SyncQrKeyPair? _qrKeyPair;
  Timer? _qrPollTimer;
  LocalMergePolicy _pendingQrMergePolicy = LocalMergePolicy.mergeLocal;

  @override
  void initState() {
    super.initState();
    _selectedKind = widget.initialServerKind ?? SyncServerKind.official;
    try {
      _coordinatorRef = context.read<SyncAndScanCoordinator>();
    } on ProviderNotFoundException catch (_) {}
    _serverController.addListener(_onServerTextChanged);
    unawaited(_loadSavedSelfHostedUrl());
  }

  void _onServerTextChanged() {
    if (!mounted) return;
    if (_probeMessage != null) {
      setState(() {
        _probeMessage = null;
        _probeSuccess = null;
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _loadSavedSelfHostedUrl() async {
    final coordinator = _coordinatorRef;
    if (coordinator == null) return;
    final savedUrl = await coordinator.syncStore.getLastSelfHostedUrl();
    if (!mounted) return;
    if (savedUrl != null && savedUrl.isNotEmpty && _serverController.text.isEmpty) {
      _serverController.text = savedUrl;
    }
  }

  @override
  void dispose() {
    _cancelQr();
    _serverController.removeListener(_onServerTextChanged);
    _serverController.dispose();
    _userController.dispose();
    _passController.dispose();
    _qrInputController.dispose();
    super.dispose();
  }

  String _effectiveServerUrl() {
    if (_selectedKind == SyncServerKind.official) {
      return SyncLocalStore.effectiveDefaultOfficialSyncUrl;
    }
    return SyncLocalStore.normalizeServerUrl(_serverController.text);
  }

  static bool _isPublicCleartextHttp(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.toLowerCase() != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return false;
    }
    if (host.startsWith('127.') || host.startsWith('10.') || host.startsWith('192.168.')) {
      return false;
    }
    if (host.startsWith('172.')) {
      final parts = host.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]);
        if (second != null && second >= 16 && second <= 31) {
          return false;
        }
      }
    }
    return true;
  }

  Future<LocalMergePolicy?> _promptMergePolicyIfNeeded(SyncAndScanCoordinator coordinator) async {
    if (!await coordinator.hasLocalDataToMerge() || !mounted) {
      return LocalMergePolicy.mergeLocal;
    }
    return showDialog<LocalMergePolicy>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.sync.mergePromptTitle),
        content: Text(t.sync.mergePromptBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: Text(t.common.cancel)),
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop(LocalMergePolicy.accountOnly),
            child: Text(t.sync.accountOnlyOption),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(LocalMergePolicy.mergeLocal),
            child: Text(t.sync.mergeLocalOption),
          ),
        ],
      ),
    );
  }

  Future<void> _probeConnection() async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final server = _effectiveServerUrl();
    if (server.isEmpty || _probing) return;
    setState(() {
      _probing = true;
      _probeMessage = null;
      _probeSuccess = null;
    });
    try {
      final info = await coordinator.apiClient.probeServer(server);
      await coordinator.syncStore.saveLastSelfHostedUrl(server);
      if (!mounted) return;
      setState(() {
        _probeSuccess = true;
        _probeMessage = info.allowRegistration ? t.sync.connectionOkOpenReg : t.sync.connectionOkClosedReg;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _probeSuccess = false;
        _probeMessage = t.sync.connectionFailed(error: '$e');
      });
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _submitAuth({required bool isRegister}) async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final navigator = Navigator.of(context);
    final server = _effectiveServerUrl();
    final user = _userController.text.trim();
    final pass = _passController.text;
    if (server.isEmpty || user.isEmpty || pass.isEmpty || _busy) return;

    final mergePolicy = await _promptMergePolicyIfNeeded(coordinator);
    if (mergePolicy == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _statusMessage = null;
    });
    try {
      if (isRegister) {
        await coordinator.register(
          serverUrl: server,
          username: user,
          password: pass,
          mergePolicy: mergePolicy,
          serverKind: _selectedKind,
        );
      } else {
        await coordinator.loginWithPassword(
          serverUrl: server,
          username: user,
          password: pass,
          mergePolicy: mergePolicy,
          serverKind: _selectedKind,
        );
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

  Future<void> _startServerQr() async {
    final coordinator = context.read<SyncAndScanCoordinator>();
    final server = _effectiveServerUrl();
    if (server.isEmpty || _busy) return;
    final mergePolicy = await _promptMergePolicyIfNeeded(coordinator);
    if (mergePolicy == null || !mounted) return;
    _pendingQrMergePolicy = mergePolicy;
    _cancelQr();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await coordinator.startQrSession(serverUrl: server, serverKind: _selectedKind);
      if (!mounted) return;
      setState(() {
        _qrSessionId = res.sessionId;
        _qrUri = res.qrUri;
        _qrKeyPair = res.keyPair;
      });
      _qrPollTimer?.cancel();
      _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollQr(server, _selectedKind)));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pollQr(String server, SyncServerKind kind) async {
    final sessionId = _qrSessionId;
    final kp = _qrKeyPair;
    if (sessionId == null || kp == null || !mounted) return;
    final coordinator = context.read<SyncAndScanCoordinator>();
    final navigator = Navigator.of(context);
    try {
      final done = await coordinator.pollQrSession(
        serverUrl: server,
        sessionId: sessionId,
        keyPair: kp,
        mergePolicy: _pendingQrMergePolicy,
        serverKind: kind,
      );
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

  void _selectServerKind(SyncServerKind kind) {
    if (_selectedKind == kind) return;
    _cancelQr();
    setState(() {
      _selectedKind = kind;
      _error = null;
      _probeMessage = null;
      _probeSuccess = null;
    });
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
      if (mounted) setState(() => _error = formatSyncQrAuthError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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
              if (sess == null) ..._buildSignedOutCards(theme) else ..._buildSignedInCards(sync, sess, theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSignedOutCards(ThemeData theme) {
    final isSelfHosted = _selectedKind == SyncServerKind.selfHosted;
    final showCleartextWarning = isSelfHosted && _isPublicCleartextHttp(_serverController.text);
    final isMobile = PlatformDetector.isMobile(context);

    return [
      if (!widget.onboardingMode) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                AppIcon(Symbols.devices_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.sync.activeModeLan, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        t.sync.modeLanDesc,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const LanDevicesPanel(),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: !isSelfHosted
                        ? FilledButton.icon(
                            onPressed: _busy ? null : () => _selectServerKind(SyncServerKind.official),
                            icon: const AppIcon(Symbols.cloud_sync_rounded, size: 18),
                            label: Text(t.sync.modeOfficialTitle),
                          )
                        : OutlinedButton.icon(
                            onPressed: _busy ? null : () => _selectServerKind(SyncServerKind.official),
                            icon: const AppIcon(Symbols.cloud_sync_rounded, size: 18),
                            label: Text(t.sync.modeOfficialTitle),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: isSelfHosted
                        ? FilledButton.icon(
                            onPressed: _busy ? null : () => _selectServerKind(SyncServerKind.selfHosted),
                            icon: const AppIcon(Symbols.dns_rounded, size: 18),
                            label: Text(t.sync.modeSelfHostedTitle),
                          )
                        : OutlinedButton.icon(
                            onPressed: _busy ? null : () => _selectServerKind(SyncServerKind.selfHosted),
                            icon: const AppIcon(Symbols.dns_rounded, size: 18),
                            label: Text(t.sync.modeSelfHostedTitle),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                isSelfHosted ? t.sync.modeSelfHostedDesc : t.sync.modeOfficialDesc,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (isSelfHosted) ...[
                const SizedBox(height: 14),
                FocusableTextField(
                  controller: _serverController,
                  decoration: InputDecoration(labelText: t.sync.serverUrl, hintText: t.sync.selfHostedServerUrlHint),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: (_probing || _serverController.text.trim().isEmpty)
                          ? null
                          : () => unawaited(_probeConnection()),
                      icon: const AppIcon(Symbols.network_check_rounded, size: 18),
                      label: Text(_probing ? t.sync.testingConnection : t.sync.testConnection),
                    ),
                    if (_probeMessage != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _probeMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _probeSuccess == true ? theme.colorScheme.primary : theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (showCleartextWarning) ...[
                  const SizedBox(height: 8),
                  Material(
                    color: theme.colorScheme.tertiaryContainer,
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        t.sync.cleartextHttpWarning,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 14),
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
                      onPressed: _busy ? null : () => unawaited(_submitAuth(isRegister: true)),
                      child: Text(t.sync.register),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => unawaited(_submitAuth(isRegister: false)),
                      child: Text(t.sync.login),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (!isMobile) ...[
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.sync.qrLoginTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(t.sync.qrModeServerHint, style: theme.textTheme.bodySmall),
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
                  onPressed: (_busy || _effectiveServerUrl().isEmpty) ? null : () => unawaited(_startServerQr()),
                  icon: const AppIcon(Symbols.qr_code_2_rounded),
                  label: Text(_qrUri == null ? t.sync.qrGenerate : t.sync.qrRefreshButton),
                ),
              ],
            ),
          ),
        ),
      ],
    ];
  }

  Future<void> _confirmAndSignOut(SyncAndScanCoordinator sync) async {
    if (sync.pendingOutboxCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.sync.signOutPendingTitle),
          content: Text(t.sync.signOutPendingBody(count: sync.pendingOutboxCount)),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t.sync.signOut)),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await sync.signOut();
  }

  List<Widget> _buildSignedInCards(SyncAndScanCoordinator sync, SyncSessionCredentials sess, ThemeData theme) {
    final lastTime = sync.lastSyncedAt == null ? t.sync.neverSynced : sync.lastSyncedAt!.toLocal().toString();
    final isOfficial = sess.serverKind == SyncServerKind.official;
    final isMobile = PlatformDetector.isMobile(context);

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isOfficial ? t.sync.activeModeOfficial : t.sync.activeModeSelfHosted,
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 6),
              Text(t.sync.account(name: sess.username), style: theme.textTheme.titleMedium),
              if (!isOfficial) ...[const SizedBox(height: 4), Text(sess.serverUrl, style: theme.textTheme.bodySmall)],
              const SizedBox(height: 8),
              Text(t.sync.pendingChanges(count: sync.pendingOutboxCount), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(t.sync.lastSynced(time: lastTime), style: theme.textTheme.bodySmall),
              if (sync.isRestoringMounts) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.sync.initialSyncRestoring,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                  ],
                ),
              ],
              if (sync.lastError != null) ...[
                const SizedBox(height: 6),
                Text(sync.lastError!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
              if (sync.progress.isActive) ...[
                const SizedBox(height: 12),
                if (formatSyncProgressDetail(t, sync.progress) case final detail?) ...[
                  Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                  const SizedBox(height: 6),
                ],
                LinearProgressIndicator(value: sync.progress.fraction),
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
                    onPressed: sync.isSyncing ? null : () => unawaited(_confirmAndSignOut(sync)),
                    child: Text(t.sync.switchToLan),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (!widget.onboardingMode) ...[const SizedBox(height: 12), const LanDevicesPanel()],
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
              if (isMobile) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                          Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => const SyncQrScannerScreen())),
                        ),
                  icon: const AppIcon(Symbols.qr_code_scanner_rounded),
                  label: Text(t.sync.scanQrTileTitle),
                ),
              ],
              const SizedBox(height: 12),
              FocusableTextField(
                controller: _qrInputController,
                decoration: const InputDecoration(hintText: 'ttplay://qr-auth?...'),
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
