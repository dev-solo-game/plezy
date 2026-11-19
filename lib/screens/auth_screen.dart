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
import '../media/ids.dart';
import '../navigation/profile_session_screen.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_registry.dart';
import '../providers/multi_server_provider.dart';
import '../session/app_session_controller.dart';
import '../ttplay/ttplay_session_binder.dart';
import '../widgets/app_icon.dart';
import 'auth/self_hosted_login_screen.dart';

/// Initial dual-mode onboarding screen:
/// 1) Offline / Local mode (local mounts + official public metadata service)
/// 2) Self-Hosted Server mode (login to ttplay-server)
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

  AppSessionController? _maybeSession() {
    try {
      return context.read<AppSessionController?>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  TtplaySessionBinder? _maybeTtplayBinder() {
    try {
      return context.read<TtplaySessionBinder?>();
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

  Future<void> _ensureLocalSessionReady({required bool includeLocalLibrary}) async {
    final ttplayBinder = _maybeTtplayBinder();
    if (ttplayBinder != null) {
      await ttplayBinder.syncFromSession(refreshExternalServers: !includeLocalLibrary);
      if (!mounted) return;
    } else {
      final local = context.read<LocalLibraryClient?>();
      final multiServer = context.read<MultiServerProvider?>();
      if (local != null && multiServer != null) {
        if (includeLocalLibrary) {
          configureLocalLibraryClientLabels(local);
          await local.refreshMounts();
          if (!mounted) return;
          multiServer.serverManager.registerLocalLibrary(local);
          multiServer.addToVisibleServerIds(ServerId(LocalLibraryClient.localServerId));
        } else {
          multiServer.serverManager.unregisterLocalLibrary();
        }
      }
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

  Future<void> _enterProfileSession({required bool includeLocalLibrary}) async {
    await _ensureLocalSessionReady(includeLocalLibrary: includeLocalLibrary);
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

  Future<void> _selectOfflineMode() async {
    if (_busy || !await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    setState(() => _busy = true);
    try {
      await _maybeSession()?.selectOfflineMode();
      if (!mounted) return;
      await _enterProfileSession(includeLocalLibrary: true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSelfHostedLogin() async {
    if (_busy || !await _prepareDatabaseRecoveryForSignIn() || !mounted) return;
    final existingUrl = _maybeSession()?.selfHostedSession?.serverUrl;
    final signedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => SelfHostedLoginScreen(initialServerUrl: existingUrl)),
    );
    if (!mounted) return;
    if (signedIn == true || _maybeSession()?.isSelfHosted == true) {
      setState(() => _busy = true);
      try {
        await _enterProfileSession(includeLocalLibrary: false);
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
                        child: Center(child: SingleChildScrollView(child: _buildModeChoices(context))),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_buildBrandColumn(context), const SizedBox(height: 36), _buildModeChoices(context)],
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
          onPressed: _busy ? null : () => unawaited(_selectOfflineMode()),
          child: FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_selectOfflineMode()),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
            icon: const AppIcon(Symbols.devices_rounded, size: 20),
            label: Text(t.session.modeOfflineTitle),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.session.modeOfflineDesc,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        FocusableButton(
          onPressed: _busy ? null : () => unawaited(_openSelfHostedLogin()),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_openSelfHostedLogin()),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
            icon: const AppIcon(Symbols.dns_rounded, size: 20),
            label: Text(t.session.modeSelfHostedTitle),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.session.modeSelfHostedDesc,
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
