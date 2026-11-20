import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../library/local_library_client.dart';
import '../library_cloud/cloud_api_client.dart';
import '../library_cloud/projection_sync.dart';
import '../library_cloud/scan_session_runner.dart';
import '../library_cloud/source_repository.dart';
import '../providers/multi_server_provider.dart';
import '../services/multi_server_manager.dart';
import '../session/app_session_controller.dart';
import '../session/app_session_models.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import 'ttplay_admin_service.dart';
import 'ttplay_api_client.dart';
import 'ttplay_external_server_client.dart';
import 'ttplay_server_client.dart';

/// Synchronizes [AppSessionController] mode transitions (`offline` vs
/// `selfHosted`) with [MultiServerManager] and [MultiServerProvider].
class TtplaySessionBinder extends ChangeNotifier {
  TtplaySessionBinder({
    required this.sessionController,
    required this.serverManager,
    required this.localLibraryClient,
    bool Function()? isTv,
    this.httpClientFactory,
  }) : _isTv = isTv ?? PlatformDetector.isTV;

  final AppSessionController sessionController;
  final MultiServerManager serverManager;
  final LocalLibraryClient localLibraryClient;
  final bool Function() _isTv;
  final http.Client Function()? httpClientFactory;

  MultiServerProvider? _multiServerProvider;
  TtplayApiClient? _apiClient;
  TtplayAdminService? _adminService;
  CloudApiClient? _cloudApiClient;
  CloudSourceRepository? _cloudSourceRepository;
  CloudScanSessionRunner? _cloudScanRunner;
  CloudProjectionSyncClient? _cloudProjectionSync;
  TtplayServerClient? _primaryClient;
  List<TtplayExternalServerClient> _externalClients = const [];
  List<TtplayExternalServerSummary> _externalSummaries = const [];
  String? _boundSessionKey;
  Object? _lastExternalRefreshError;
  int _syncGeneration = 0;
  bool _disposed = false;

  TtplayApiClient? get activeApiClient => _apiClient;
  TtplayAdminService? get adminService => _apiClient == null ? null : (_adminService ??= TtplayAdminService(_apiClient!));
  CloudApiClient? get cloudApiClient => _cloudApiClient;
  CloudSourceRepository? get cloudSourceRepository => _cloudSourceRepository;
  CloudScanSessionRunner? get cloudScanRunner => _cloudScanRunner;
  CloudProjectionSyncClient? get cloudProjectionSync => _cloudProjectionSync;
  TtplayServerClient? get primaryClient => _primaryClient;
  List<TtplayExternalServerClient> get externalClients => List.unmodifiable(_externalClients);
  List<TtplayExternalServerSummary> get externalServerSummaries => List.unmodifiable(_externalSummaries);
  bool get isSelfHostedActive => _primaryClient != null;
  Object? get lastExternalRefreshError => _lastExternalRefreshError;

  void attachMultiServerProvider(MultiServerProvider provider) {
    _multiServerProvider = provider;
  }

  /// Synchronously binds the primary `ttplay-server` client before Frame 1 on
  /// cold start when the persisted session is already `selfHosted`.
  void seedSelfHostedSynchronously(SelfHostedSession session) {
    if (_disposed) return;
    _syncGeneration++;
    final api = TtplayApiClient(
      baseUrl: session.serverUrl,
      accessToken: session.accessToken,
      httpClient: httpClientFactory?.call(),
    );
    final primary = TtplayServerClient(
      api: api,
      session: session,
      includePendingShelf: !_isTv(),
      onRawEvent: _handleRawSseEvent,
    );
    configureTtplayServerClientLabels(primary);

    _apiClient = api;
    _adminService = null;
    _bindCloudClients(session);
    _primaryClient = primary;
    _externalClients = const [];
    _externalSummaries = const [];
    _boundSessionKey = _sessionKeyFor(session);
    _lastExternalRefreshError = null;

    serverManager.unregisterLocalLibrary();
    serverManager.registerSelfHostedServers(primary, const []);
    _syncVisibleServerIds(includeLocal: false);
  }

  /// Reconciles server registrations with the current [AppSessionController] state.
  Future<void> syncFromSession({bool refreshExternalServers = true}) async {
    if (_disposed) return;
    final gen = ++_syncGeneration;

    if (sessionController.isSelfHosted && sessionController.selfHostedSession != null) {
      final session = sessionController.selfHostedSession!;
      final sessionKey = _sessionKeyFor(session);
      if (_primaryClient == null || _boundSessionKey != sessionKey) {
        final api = TtplayApiClient(
          baseUrl: session.serverUrl,
          accessToken: session.accessToken,
          httpClient: httpClientFactory?.call(),
        );
        final primary = TtplayServerClient(
          api: api,
          session: session,
          includePendingShelf: !_isTv(),
          onRawEvent: _handleRawSseEvent,
        );
        configureTtplayServerClientLabels(primary);

        _apiClient = api;
        _adminService = null;
        _bindCloudClients(session);
        _primaryClient = primary;
        _externalClients = const [];
        _externalSummaries = const [];
        _boundSessionKey = sessionKey;
        _lastExternalRefreshError = null;

        serverManager.unregisterLocalLibrary();
        serverManager.registerSelfHostedServers(primary, const []);
        _syncVisibleServerIds(includeLocal: false);
        if (!_disposed) notifyListeners();
      }
      if (refreshExternalServers) {
        await this.refreshExternalServers();
      }
      return;
    }

    if (sessionController.isOffline) {
      _clearSelfHostedState();
      configureLocalLibraryClientLabels(localLibraryClient);
      await localLibraryClient.refreshMounts();
      if (_disposed || gen != _syncGeneration) return;
      serverManager.registerLocalLibrary(localLibraryClient);
      _syncVisibleServerIds(includeLocal: true);
      if (!_disposed) notifyListeners();
      return;
    }

    // Logged out to mode selection: drop self-hosted clients while leaving any
    // previously registered LocalLibraryClient intact for Setup/Auth flows.
    _clearSelfHostedState();
    _syncVisibleServerIds(includeLocal: true);
    if (!_disposed) notifyListeners();
  }

  /// Refreshes the list of enabled external Emby/Jellyfin servers proxied
  /// through the active `ttplay-server`.
  Future<void> refreshExternalServers() async {
    if (_disposed) return;
    final api = _apiClient;
    final primary = _primaryClient;
    if (api == null || primary == null) return;
    final gen = _syncGeneration;

    try {
      final summaries = await api.fetchExternalServers();
      if (_disposed || gen != _syncGeneration || !identical(_apiClient, api) || !identical(_primaryClient, primary)) {
        return;
      }
      final enabled = summaries.where((s) => s.enabled && s.id.isNotEmpty).toList(growable: false);
      final clients = [for (final s in enabled) TtplayExternalServerClient(api: api, server: s)];
      _externalSummaries = summaries;
      _externalClients = clients;
      _lastExternalRefreshError = null;
      serverManager.registerSelfHostedServers(primary, clients);
      _syncVisibleServerIds(includeLocal: false);
      if (!_disposed) notifyListeners();
    } catch (e) {
      if (_disposed || gen != _syncGeneration || !identical(_apiClient, api)) return;
      _lastExternalRefreshError = e;
      appLogger.w('Failed to refresh ttplay-server external servers: $e');
      if (!_disposed) notifyListeners();
    }
  }

  void _handleRawSseEvent(String event, Map<String, dynamic> data) {
    if (event == 'ext_servers_changed' && !_disposed) {
      unawaited(refreshExternalServers());
    }
  }

  void _bindCloudClients(SelfHostedSession session) {
    _cloudApiClient?.close();
    final cloudApi = CloudApiClient(
      baseUrl: session.serverUrl,
      accessToken: session.accessToken,
      httpClient: httpClientFactory?.call(),
    );
    Uint8List? masterKeyProvider() {
      final raw = sessionController.selfHostedSession?.masterKeyB64 ?? session.masterKeyB64;
      if (raw == null || raw.isEmpty) return null;
      try {
        return Uint8List.fromList(base64Decode(raw));
      } catch (_) {
        return null;
      }
    }

    _cloudApiClient = cloudApi;
    _cloudSourceRepository = CloudSourceRepository(
      api: cloudApi,
      masterKeyProvider: masterKeyProvider,
      keyEpoch: session.keyEpoch,
    );
    _cloudScanRunner = CloudScanSessionRunner(api: cloudApi);
    _cloudProjectionSync = CloudProjectionSyncClient(cloudApi);
  }

  void _clearSelfHostedState() {
    final primaryRegistered = _primaryClient != null && serverManager.isSelfHostedServer(_primaryClient!.serverId);
    final staleApi = _apiClient;
    _cloudApiClient?.close();
    _cloudApiClient = null;
    _cloudSourceRepository = null;
    _cloudScanRunner = null;
    _cloudProjectionSync = null;
    _apiClient = null;
    _adminService = null;
    _primaryClient = null;
    _externalClients = const [];
    _externalSummaries = const [];
    _boundSessionKey = null;
    _lastExternalRefreshError = null;
    serverManager.clearSelfHostedServers();
    if (!primaryRegistered) {
      staleApi?.close();
    }
  }

  void _syncVisibleServerIds({required bool includeLocal}) {
    final provider = _multiServerProvider;
    if (provider == null) return;
    final current = serverManager.visibleServerIds;
    if (current == null) return;
    final next = <String>{
      for (final id in current)
        if (id != TtplayServerClient.primaryServerId &&
            !TtplayExternalServerClient.isExternalServerId(id) &&
            (includeLocal || id != LocalLibraryClient.localServerId))
          id,
      if (includeLocal && serverManager.registeredServerIds.contains(LocalLibraryClient.localServerId))
        LocalLibraryClient.localServerId,
      ...serverManager.selfHostedServerIds,
    };
    provider.setVisibleServerIds(next);
  }

  String _sessionKeyFor(SelfHostedSession session) => '${session.serverUrl}|${session.accessToken}';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _multiServerProvider = null;
    _cloudApiClient?.close();
    _cloudApiClient = null;
    _cloudSourceRepository = null;
    _cloudScanRunner = null;
    _cloudProjectionSync = null;
    _apiClient = null;
    _adminService = null;
    _primaryClient = null;
    _externalClients = const [];
    _externalSummaries = const [];
    _boundSessionKey = null;
    super.dispose();
  }
}
