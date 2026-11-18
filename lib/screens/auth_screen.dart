import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../connection/connection_registry.dart';
import '../database/app_database.dart';
import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../library/local_library_client.dart';
import '../library/sync/sync_coordinator.dart';
import '../media/ids.dart';
import '../navigation/profile_session_screen.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_registry.dart';
import '../providers/multi_server_provider.dart';
import '../widgets/app_icon.dart';
import 'storage/sync_settings_screen.dart';

/// Populates localized shelf and sort titles on [local] from `t.storage`.
void configureLocalLibraryClientLabels(LocalLibraryClient local) {
  local
    ..serverName = t.storage.localLibraryName
    ..shelfTitles = {
      'movie': t.storage.content.movie,
      'show': t.storage.content.show,
      'anime': t.storage.content.anime,
      'variety': t.storage.content.variety,
      'documentary': t.storage.content.documentary,
      'pending': t.storage.unmatchedTitles,
    }
    ..sortTitles = {
      'title': t.storage.sortTitle,
      'year': t.storage.sortYear,
      'releaseDate': t.storage.sortReleaseDate,
      'rating': t.storage.sortRating,
      'addedAt': t.storage.sortAddedAt,
      'lastPlayed': t.storage.sortLastPlayed,
    }
    ..recentlyAddedTitle = t.storage.recentlyAdded(shelf: '{shelf}')
    ..continueWatchingTitle = t.storage.continueWatching;
}

/// Initial mode selection & sync onboarding screen.
///
/// Offers mutually exclusive synchronization modes:
/// 1) Local & Serverless LAN P2P Mode (no login required), or
/// 2) Sync Server (Go Server) for cross-network sync & 1-second TV QR login.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.initialErrorMessage,
    this.initializeServices = true,
    this.databaseRecoveryRequired = false,
    @visibleForTesting this.sessionBuilder,
  });

  final String? initialErrorMessage;
  final bool initializeServices;
  final bool databaseRecoveryRequired;
  @visibleForTesting
  final WidgetBuilder? sessionBuilder;

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

  Future<void> _ensureLocalSessionReady() async {
    final local = context.read<LocalLibraryClient?>();
    final multiServer = context.read<MultiServerProvider?>();
    if (local != null && multiServer != null) {
      configureLocalLibraryClientLabels(local);
      await local.refreshMounts();
      if (!mounted) return;
      multiServer.serverManager.registerLocalLibrary(local);
      multiServer.addToVisibleServerIds(ServerId(LocalLibraryClient.localServerId));
    }

    final activeProfile = context.read<ActiveProfileProvider?>();
    final profiles = context.read<ProfileRegistry?>();
    if (activeProfile != null && profiles != null) {
      await activeProfile.reloadFromStorage();
      if (!mounted) return;
      if (activeProfile.profiles.isEmpty) {
        await profiles.upsert(
          Profile.local(id: const Uuid().v4(), displayName: t.storage.defaultProfileName, createdAt: DateTime.now()),
        );
        await activeProfile.reloadFromStorage();
        if (!mounted) return;
      }
      if (activeProfile.active == null && activeProfile.profiles.isNotEmpty) {
        final candidate = activeProfile.profiles.firstOrNull;
        if (candidate != null) {
          await activeProfile.activate(candidate);
          if (!mounted) return;
        }
      }
    }

    final binder = context.read<ActiveProfileBinder?>();
    if (binder != null) {
      ConnectionRegistry? connectionRegistry;
      try {
        connectionRegistry = context.read<ConnectionRegistry?>();
      } on ProviderNotFoundException {
        connectionRegistry = null;
      }
      final hasRemoteConnections = (await connectionRegistry?.list() ?? const []).isNotEmpty;
      if (!hasRemoteConnections && !binder.hasBoundOnce) {
        binder.primeLocalOnlyStartup();
      } else {
        binder.start();
        unawaited(binder.rebindActive());
      }
    }
  }

  Future<void> _enterProfileSession() async {
    await _ensureLocalSessionReady();
    if (!mounted) return;
    final page = widget.sessionBuilder?.call(context) ?? const ProfileSessionScreen();
    unawaited(
      Navigator.pushReplacement(
        context,
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => page,
          transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 120),
          reverseTransitionDuration: const Duration(milliseconds: 120),
        ),
      ),
    );
  }

  Future<void> _selectLocalLanMode() async {
    if (_busy || !await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    setState(() => _busy = true);
    try {
      await _maybeCoordinator()?.selectLanMode();
      if (!mounted) return;
      await _enterProfileSession();
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
      setState(() => _busy = true);
      try {
        await _enterProfileSession();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
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
