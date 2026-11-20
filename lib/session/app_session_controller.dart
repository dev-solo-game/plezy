import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../database/app_database.dart';
import '../library/library_scan_service.dart';
import '../library/local_workspace_archive.dart';
import '../library_cloud/cloud_keyring.dart';
import '../services/companion_remote/lan_identity_store.dart';
import '../storage/mount_manager.dart';
import '../utils/app_logger.dart';
import '../utils/device_identity.dart';
import '../utils/platform_detector.dart';
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
      final protocolVersion = (body['protocol_version'] as num?)?.toInt() ?? 0;
      final minProtocolVersion = (body['min_protocol_version'] as num?)?.toInt() ?? 0;
      final regMode = (body['registration_mode'] as String?)?.trim().toLowerCase() ?? 'closed';
      final isInitialized = body.containsKey('initialized') ? body['initialized'] == true : protocolVersion >= 1;
      return SelfHostedServerBootstrap(
        serverUrl: normalized,
        initialized: isInitialized,
        serverName: (body['server_name'] as String?) ?? '',
        accentTheme: (body['accent_theme'] as String?) ?? '',
        version: (body['version'] as String?) ?? '',
        protocolVersion: protocolVersion,
        minProtocolVersion: minProtocolVersion,
        registrationMode: regMode,
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

      final device = await _resolveDeviceDescriptor();

      final resp = await _httpClient
          .post(
            Uri.parse('$normalized/api/v1/auth/login'),
            headers: const {'content-type': 'application/json', 'x-ttplay-client': 'plezy/client/1'},
            body: jsonEncode({
              'username': username.trim(),
              'password': password,
              'device_name': device.name,
              'platform': device.platform,
              'device': {
                if (device.deviceId != null && device.deviceId!.isNotEmpty) 'device_id': device.deviceId,
                'class': device.deviceClass,
                'platform': device.platform,
                'name': device.name,
                'app_version': '1.0.0',
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      final body = _decodeAuthBody(resp);
      final token = body['access_token'] as String? ?? '';
      if (token.isEmpty) {
        throw const SelfHostedAuthException(SelfHostedAuthErrorKind.serverError, 'Missing access token in response');
      }

      String? masterKeyB64;
      var keyEpoch = 1;
      final wrapsRaw = body['key_wraps'];
      if (wrapsRaw is List) {
        for (final w in wrapsRaw) {
          if (w is Map && (w['wrap_type'] == CloudKeyring.wrapTypeAccountPassword)) {
            try {
              final unwrapped = await CloudKeyring.unwrapMasterKey(
                wrap: Map<String, dynamic>.from(w),
                password: password,
              );
              masterKeyB64 = base64Encode(unwrapped);
              keyEpoch = (w['key_epoch'] as num?)?.toInt() ?? 1;
              break;
            } catch (e) {
              appLogger.w('Failed to unwrap E2EE master key from server wrap: $e');
            }
          }
        }
      }

      final householdMap = body['household'] is Map ? Map<String, dynamic>.from(body['household'] as Map) : null;
      final memberMap = body['member'] is Map ? Map<String, dynamic>.from(body['member'] as Map) : null;
      final principalMap = body['principal'] is Map ? Map<String, dynamic>.from(body['principal'] as Map) : null;

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
        householdId: (householdMap?['id'] as String?) ?? (principalMap?['household_id'] as String?),
        memberId: (memberMap?['id'] as String?) ?? (principalMap?['member_id'] as String?),
        deviceId: (principalMap?['device_id'] as String?) ?? device.deviceId,
        deviceClass: (principalMap?['device_class'] as String?) ?? device.deviceClass,
        masterKeyB64: masterKeyB64,
        keyEpoch: keyEpoch,
      );

      await _activateSelfHostedSession(nextSession);
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

  /// Registers a new single-account user on `media_library` (`POST /api/v1/auth/register`),
  /// generating a client-side 256-bit E2EE master key wrapped with [password].
  Future<SelfHostedSession> registerSelfHosted({
    required String serverUrl,
    required String username,
    required String password,
    String? email,
    String? inviteCode,
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
      final device = await _resolveDeviceDescriptor();

      final masterKey = CloudKeyring.generateMasterKey();
      final accountWrap = await CloudKeyring.wrapMasterKey(masterKey: masterKey, password: password);

      final resp = await _httpClient
          .post(
            Uri.parse('$normalized/api/v1/auth/register'),
            headers: const {'content-type': 'application/json', 'x-ttplay-client': 'plezy/client/1'},
            body: jsonEncode({
              'username': username.trim(),
              if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
              'password': password,
              if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
              'device': {
                if (device.deviceId != null && device.deviceId!.isNotEmpty) 'device_id': device.deviceId,
                'class': device.deviceClass,
                'platform': device.platform,
                'name': device.name,
                'app_version': '1.0.0',
              },
              'key_wraps': [accountWrap],
            }),
          )
          .timeout(const Duration(seconds: 15));

      final body = _decodeAuthBody(resp);
      final token = body['access_token'] as String? ?? '';
      if (token.isEmpty) {
        throw const SelfHostedAuthException(SelfHostedAuthErrorKind.serverError, 'Missing access token in response');
      }

      final householdMap = body['household'] is Map ? Map<String, dynamic>.from(body['household'] as Map) : null;
      final memberMap = body['member'] is Map ? Map<String, dynamic>.from(body['member'] as Map) : null;
      final principalMap = body['principal'] is Map ? Map<String, dynamic>.from(body['principal'] as Map) : null;

      final nextSession = SelfHostedSession(
        serverUrl: normalized,
        username: username.trim(),
        accessToken: token,
        tokenId: body['token_id'] as String?,
        serverName: probed.serverName.isNotEmpty ? probed.serverName : null,
        accentTheme: probed.accentTheme.isNotEmpty ? probed.accentTheme : null,
        expiresAt: (body['expires_at'] as num?)?.toInt(),
        householdId: (householdMap?['id'] as String?) ?? (principalMap?['household_id'] as String?),
        memberId: (memberMap?['id'] as String?) ?? (principalMap?['member_id'] as String?),
        deviceId: (principalMap?['device_id'] as String?) ?? device.deviceId,
        deviceClass: (principalMap?['device_class'] as String?) ?? device.deviceClass,
        masterKeyB64: base64Encode(masterKey),
        keyEpoch: 1,
      );

      await _activateSelfHostedSession(nextSession);
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

  Future<({String? deviceId, String deviceClass, String platform, String name})> _resolveDeviceDescriptor() async {
    String? deviceId;
    String deviceName = Platform.localHostname;
    String platform = Platform.operatingSystem;
    if (identityStore != null) {
      deviceName = await identityStore!.getDeviceName();
      deviceId = await identityStore!.getOrCreateDeviceId();
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
    final deviceClass = PlatformDetector.isTV()
        ? 'tv'
        : PlatformDetector.isDesktopOS()
        ? 'desktop'
        : 'phone';
    return (deviceId: deviceId, deviceClass: deviceClass, platform: platform, name: deviceName);
  }

  Map<String, dynamic> _decodeAuthBody(http.Response resp) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    } catch (_) {}

    if (resp.statusCode == HttpStatus.unauthorized || resp.statusCode == HttpStatus.forbidden) {
      throw SelfHostedAuthException(
        SelfHostedAuthErrorKind.invalidCredentials,
        (body?['message'] as String?) ?? (body?['error'] as String?) ?? 'Invalid username or password',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300 || body == null || body['code'] != 0) {
      throw SelfHostedAuthException(
        SelfHostedAuthErrorKind.serverError,
        (body?['message'] as String?) ?? (body?['error'] as String?) ?? 'HTTP ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }
    return body;
  }

  Future<void> _activateSelfHostedSession(SelfHostedSession nextSession) async {
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
