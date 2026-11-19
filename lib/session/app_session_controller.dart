import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../database/app_database.dart';
import '../library/library_scan_service.dart';
import '../library/local_workspace_archive.dart';
import '../services/companion_remote/lan_identity_store.dart';
import '../storage/mount_manager.dart';
import '../utils/app_logger.dart';
import '../utils/device_identity.dart';
import 'app_session_models.dart';
import 'app_session_store.dart';

/// Owns the application's active dual-mode session (`offline` local scraping vs
/// `selfHosted` ttplay-server), archiving/restoring local workspace tables when
/// transitioning between modes.
class AppSessionController extends ChangeNotifier {
  AppSessionController({
    required AppDatabase db,
    AppSessionStore? store,
    LocalWorkspaceArchive? archive,
    this.mountManager,
    this.scanService,
    this.identityStore,
    AppLoginMode? initialMode,
    SelfHostedSession? initialSelfHostedSession,
    http.Client? httpClient,
  }) : _store = store ?? AppSessionStore(db),
       _archive = archive ?? LocalWorkspaceArchive(db),
       _mode = initialMode,
       _selfHostedSession = initialSelfHostedSession,
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final AppSessionStore _store;
  final LocalWorkspaceArchive _archive;
  final MountManager? mountManager;
  final LibraryScanService? scanService;
  final LanIdentityStore? identityStore;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  bool _busy = false;
  String? _error;

  AppLoginMode? _mode;
  SelfHostedSession? _selfHostedSession;
  bool _explicitlyLoggedOut = false;

  AppLoginMode? get mode => _mode;
  SelfHostedSession? get selfHostedSession => _selfHostedSession;
  bool get explicitlyLoggedOut => _explicitlyLoggedOut;
  bool get isInitialized => _initialized;
  bool get hasSelectedMode => _mode != null && (_mode == AppLoginMode.offline || _selfHostedSession != null);
  bool get isOffline => _mode == AppLoginMode.offline;
  bool get isSelfHosted => _mode == AppLoginMode.selfHosted && _selfHostedSession != null;
  bool get isBusy => _busy;
  String? get error => _error;

  Future<bool> hasArchivedLocalWorkspace() => _archive.hasArchive();

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    try {
      final loaded = await _store.load();
      _mode = loaded.mode;
      _selfHostedSession = loaded.selfHosted;
      _explicitlyLoggedOut = loaded.explicitlyLoggedOut;
      _initialized = true;
      if (!_disposed) notifyListeners();
    } catch (e, st) {
      appLogger.e('AppSessionController initialization failed', error: e, stackTrace: st);
      _initialized = true;
      if (!_disposed) notifyListeners();
    }
  }

  Future<SelfHostedServerBootstrap> probeSelfHostedServer(String rawUrl) async {
    final normalized = SelfHostedSession.normalizeServerUrl(rawUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const SelfHostedAuthException(SelfHostedAuthErrorKind.invalidUrl, 'Invalid server URL');
    }

    try {
      final resp = await _httpClient
          .get(Uri.parse('$normalized/api/v1/public/bootstrap'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != HttpStatus.ok) {
        throw SelfHostedAuthException(
          SelfHostedAuthErrorKind.serverError,
          'HTTP ${resp.statusCode}',
          statusCode: resp.statusCode,
        );
      }
      final body = jsonDecode(resp.body);
      if (body is! Map || body['code'] != 0) {
        throw const SelfHostedAuthException(SelfHostedAuthErrorKind.serverError, 'Unexpected server response');
      }
      return SelfHostedServerBootstrap(
        serverUrl: normalized,
        initialized: body['initialized'] == true,
        serverName: (body['server_name'] as String?) ?? '',
        accentTheme: (body['accent_theme'] as String?) ?? '',
        version: (body['version'] as String?) ?? '',
      );
    } on SelfHostedAuthException {
      rethrow;
    } on SocketException catch (e) {
      throw SelfHostedAuthException(SelfHostedAuthErrorKind.network, e.message);
    } on TimeoutException {
      throw const SelfHostedAuthException(SelfHostedAuthErrorKind.network, 'Connection timed out');
    } catch (e) {
      throw SelfHostedAuthException(SelfHostedAuthErrorKind.network, e.toString());
    }
  }

  Future<void> selectOfflineMode() async {
    if (_busy) return;
    _setBusy(true, error: null);
    try {
      final previousSession = _selfHostedSession;
      await _cancelLocalActivity();

      if (await _archive.hasArchive()) {
        await _archive.restoreSnapshot();
      }

      await _store.saveOfflineMode();
      _mode = AppLoginMode.offline;
      _selfHostedSession = null;
      _explicitlyLoggedOut = false;

      if (previousSession != null) {
        unawaited(_bestEffortLogout(previousSession));
      }
    } catch (e, st) {
      appLogger.e('Failed to enter offline mode', error: e, stackTrace: st);
      _error = e.toString();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<SelfHostedSession> loginSelfHosted({
    required String serverUrl,
    required String username,
    required String password,
    SelfHostedServerBootstrap? bootstrap,
  }) async {
    if (_busy) {
      throw StateError('Session transition already in progress');
    }
    final normalized = SelfHostedSession.normalizeServerUrl(serverUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const SelfHostedAuthException(SelfHostedAuthErrorKind.invalidUrl, 'Invalid server URL');
    }

    _setBusy(true, error: null);
    try {
      final probed = bootstrap ?? await probeSelfHostedServer(normalized);
      if (!probed.initialized) {
        throw const SelfHostedAuthException(
          SelfHostedAuthErrorKind.uninitializedServer,
          'Server setup has not been completed yet',
        );
      }

      String deviceName = Platform.localHostname;
      String platform = Platform.operatingSystem;
      if (identityStore != null) {
        deviceName = await identityStore!.getDeviceName();
      } else {
        try {
          final id = await DeviceIdentityService.resolve();
          final candidate = id.deviceName?.trim();
          if (isMeaningfulDeviceName(candidate)) {
            deviceName = candidate!;
          }
          platform = id.platform;
        } catch (_) {}
      }

      final resp = await _httpClient
          .post(
            Uri.parse('$normalized/api/v1/auth/login'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'username': username.trim(),
              'password': password,
              'device_name': deviceName,
              'platform': platform,
            }),
          )
          .timeout(const Duration(seconds: 10));

      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map) body = Map<String, dynamic>.from(decoded);
      } catch (_) {}

      if (resp.statusCode == HttpStatus.unauthorized || resp.statusCode == HttpStatus.forbidden) {
        throw SelfHostedAuthException(
          SelfHostedAuthErrorKind.invalidCredentials,
          (body?['error'] as String?) ?? 'Invalid username or password',
          statusCode: resp.statusCode,
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300 || body == null || body['code'] != 0) {
        throw SelfHostedAuthException(
          SelfHostedAuthErrorKind.serverError,
          (body?['error'] as String?) ?? 'HTTP ${resp.statusCode}',
          statusCode: resp.statusCode,
        );
      }

      final token = body['access_token'] as String? ?? '';
      if (token.isEmpty) {
        throw const SelfHostedAuthException(SelfHostedAuthErrorKind.serverError, 'Missing access token in response');
      }

      final nextSession = SelfHostedSession(
        serverUrl: normalized,
        username: (body['username'] as String?)?.trim().isNotEmpty == true
            ? (body['username'] as String).trim()
            : username.trim(),
        accessToken: token,
        tokenId: body['token_id'] as String?,
        serverName: probed.serverName.isNotEmpty ? probed.serverName : null,
        accentTheme: probed.accentTheme.isNotEmpty ? probed.accentTheme : null,
        expiresAt: (body['expires_at'] as num?)?.toInt(),
      );

      final previousSession = _selfHostedSession;
      await _cancelLocalActivity();

      // Archive offline local library before clearing, preserving any existing
      // snapshot if we were already in self-hosted mode.
      final shouldArchive = _mode == AppLoginMode.offline || await _archive.hasLocalLibraryData();
      if (shouldArchive) {
        await _archive.captureSnapshot();
        await _archive.clearLocalLibraryTables();
      }

      await _store.saveSelfHostedSession(nextSession);
      _mode = AppLoginMode.selfHosted;
      _selfHostedSession = nextSession;
      _explicitlyLoggedOut = false;

      if (previousSession != null && previousSession.accessToken != nextSession.accessToken) {
        unawaited(_bestEffortLogout(previousSession));
      }

      return nextSession;
    } on SelfHostedAuthException catch (e) {
      _error = e.message;
      rethrow;
    } on SocketException catch (e) {
      _error = e.message;
      throw SelfHostedAuthException(SelfHostedAuthErrorKind.network, e.message);
    } on TimeoutException {
      _error = 'Connection timed out';
      throw const SelfHostedAuthException(SelfHostedAuthErrorKind.network, 'Connection timed out');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> switchToOfflineMode() => selectOfflineMode();

  Future<void> logoutToModeSelection() async {
    if (_busy) return;
    _setBusy(true, error: null);
    try {
      final previousSession = _selfHostedSession;
      await _cancelLocalActivity();
      await _store.clearMode();
      _mode = null;
      _selfHostedSession = null;
      _explicitlyLoggedOut = true;
      if (previousSession != null) {
        unawaited(_bestEffortLogout(previousSession));
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _cancelLocalActivity() async {
    await scanService?.cancelAll();
    final mounts = mountManager;
    if (mounts != null) {
      try {
        final list = await mounts.registry.list();
        for (final mount in list) {
          await mounts.dropCachedDriver(mount.id);
        }
      } catch (e) {
        appLogger.d('Ignoring mount driver drop error during mode transition: $e');
      }
    }
  }

  Future<void> _bestEffortLogout(SelfHostedSession session) async {
    try {
      await _httpClient
          .post(
            Uri.parse('${session.serverUrl}/api/v1/auth/logout'),
            headers: {'authorization': 'Bearer ${session.accessToken}'},
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _setBusy(bool busy, {String? error}) {
    _busy = busy;
    if (busy || error != null) {
      _error = error;
    }
    if (!_disposed) notifyListeners();
  }

  @visibleForTesting
  void debugSetStateForTesting({
    AppLoginMode? mode,
    SelfHostedSession? selfHostedSession,
    bool explicitlyLoggedOut = false,
  }) {
    _initialized = true;
    _mode = mode;
    _selfHostedSession = selfHostedSession;
    _explicitlyLoggedOut = explicitlyLoggedOut;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    super.dispose();
  }
}
