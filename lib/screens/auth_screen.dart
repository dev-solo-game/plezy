import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../library/sync/sync_coordinator.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../navigation/profile_session_screen.dart';
import '../utils/navigation_transitions.dart';
import '../widgets/app_icon.dart';
import '../widgets/backend_badge.dart';
import 'settings/add_jellyfin_screen.dart';
import 'storage/mounts_screen.dart';
import 'storage/sync_settings_screen.dart';

/// Initial mode selection & media-source onboarding screen.
///
/// Offers mutually exclusive synchronization modes:
/// 1) Local & Serverless LAN P2P Mode (no login required), or
/// 2) Sync Server (Go Server) for cross-network sync & 1-second TV QR login,
/// alongside secondary Emby / Jellyfin connection options.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.initialErrorMessage,
    this.initializeServices = true,
    this.databaseRecoveryRequired = false,
  });

  final String? initialErrorMessage;
  final bool initializeServices;
  final bool databaseRecoveryRequired;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  String? _errorMessage;
  bool _busy = false;
  Future<void>? _recoveryAcknowledgement;
  bool _recoveryAcknowledged = false;

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialErrorMessage;
  }

  SyncAndScanCoordinator? _maybeCoordinator() {
    try {
      return context.read<SyncAndScanCoordinator>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<bool> _prepareDatabaseRecoveryForSignIn() async {
    if (!widget.databaseRecoveryRequired || _recoveryAcknowledged) return true;
    final acknowledgement = _recoveryAcknowledgement ??= context
        .read<AppDatabase>()
        .acknowledgeTvosDatabaseRecoveryRequired();
    try {
      await acknowledgement;
      _recoveryAcknowledged = true;
      if (mounted) setState(() => _errorMessage = null);
      return mounted;
    } catch (_) {
      _recoveryAcknowledgement = null;
      if (mounted) setState(() => _errorMessage = t.auth.localDataRecoveryRequired);
      return false;
    }
  }

  Future<void> _selectLocalLanMode() async {
    if (_busy || !await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    setState(() => _busy = true);
    try {
      await _maybeCoordinator()?.selectLanMode();
      if (!mounted) return;
      unawaited(Navigator.pushReplacement(context, fadeRoute(const ProfileSessionScreen())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCloudSyncLogin() async {
    if (_busy || !await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    final signedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: (_) => const SyncSettingsScreen(onboardingMode: true)));
    if (!mounted) return;
    if (signedIn == true || _maybeCoordinator()?.isSignedIn == true) {
      unawaited(Navigator.pushReplacement(context, fadeRoute(const ProfileSessionScreen())));
    }
  }

  Future<void> _connectToMediaBrowser(MediaBrowserDialect dialect) async {
    if (!await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AddJellyfinScreen(dialect: dialect)),
    );
    if (!mounted || added != true) return;
    await _maybeCoordinator()?.selectLanMode();
    if (!mounted) return;
    unawaited(Navigator.pushReplacement(context, fadeRoute(const ProfileSessionScreen())));
  }

  void _openStorageMounts() {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MountsScreen())));
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width > 700;

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        body: Center(
          child: Container(
            constraints: BoxConstraints(maxWidth: isDesktop ? 800 : 420),
            padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
            child: isDesktop
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _buildBrandColumn(context)),
                      const SizedBox(width: 48),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(child: _buildModeChoices(context)),
                        ),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBrandColumn(context),
                        const SizedBox(height: 36),
                        _buildModeChoices(context),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandColumn(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Image.asset('assets/plezy.png', width: 120, height: 120),
      const SizedBox(height: 24),
      Text(
        t.app.title,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
        textAlign: TextAlign.center,
      ),
    ],
  );

  Widget _buildModeChoices(BuildContext context) {
    final theme = Theme.of(context);
    const jellyfinDialect = MediaBrowserDialect.jellyfin;
    const embyDialect = MediaBrowserDialect.emby;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableButton(
          autofocus: true,
          useBackgroundFocus: true,
          onPressed: _busy ? null : () => unawaited(_selectLocalLanMode()),
          child: FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_selectLocalLanMode()),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16)),
            icon: const AppIcon(Symbols.wifi_rounded, size: 20),
            label: Text(t.sync.modeLanTitle),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.sync.modeLanDesc,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FocusableButton(
          onPressed: _busy ? null : () => unawaited(_openCloudSyncLogin()),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_openCloudSyncLogin()),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16)),
            icon: const AppIcon(Symbols.cloud_sync_rounded, size: 20),
            label: Text(t.sync.modeCloudTitle),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.sync.modeCloudDesc,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                t.auth.or,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ),
            Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          ],
        ),
        const SizedBox(height: 12),
        FocusableButton(
          onPressed: () => unawaited(_connectToMediaBrowser(jellyfinDialect)),
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_connectToMediaBrowser(jellyfinDialect)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: const BackendBadge(backend: MediaBackend.jellyfin, size: 18),
            label: Text(t.auth.connectToMediaBrowser(product: jellyfinDialect.productName)),
          ),
        ),
        const SizedBox(height: 10),
        FocusableButton(
          onPressed: () => unawaited(_connectToMediaBrowser(embyDialect)),
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_connectToMediaBrowser(embyDialect)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: const BackendBadge(backend: MediaBackend.emby, size: 18),
            label: Text(t.auth.connectToMediaBrowser(product: embyDialect.productName)),
          ),
        ),
        const SizedBox(height: 10),
        FocusableButton(
          onPressed: _openStorageMounts,
          child: OutlinedButton.icon(
            onPressed: _openStorageMounts,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: const AppIcon(Symbols.hard_drive_rounded, size: 18),
            label: Text(t.storage.title),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
