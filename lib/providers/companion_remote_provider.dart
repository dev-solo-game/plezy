import 'dart:async';

import 'package:flutter/widgets.dart';

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../i18n/strings.g.dart';
import '../models/companion_remote/remote_command.dart';
import '../models/companion_remote/remote_playback_models.dart';
import '../models/companion_remote/remote_session.dart';
import '../models/plex/plex_home.dart';
import '../profiles/active_plex_identity.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection_registry.dart';
import '../services/companion_remote/companion_remote_peer_service.dart';
import '../services/companion_remote/companion_remote_receiver.dart';
import '../services/companion_remote/lan_discovery_service.dart';
import '../services/companion_remote/lan_identity_store.dart';
import '../services/companion_remote/lan_pairing_service.dart';
import '../services/companion_remote/remote_auth_context.dart';
import '../services/companion_remote/remote_auth_service.dart';
import '../utils/app_logger.dart';
import '../utils/device_identity.dart';
import '../utils/serial_future_queue.dart';
import '../mixins/disposable_change_notifier_mixin.dart';

export '../services/companion_remote/lan_discovery_service.dart' show DiscoveredHost;
export '../services/companion_remote/lan_pairing_service.dart' show LanDiscoveredPeer;

class CompanionRemoteTrustCancelledException implements Exception {
  const CompanionRemoteTrustCancelledException();
}

typedef CommandReceivedCallback = void Function(RemoteCommand command);
typedef PlexHomeResolver = Future<PlexHome?> Function(String connectionId);
typedef CompanionRemotePeerServiceFactory = CompanionRemotePeerService Function();
typedef LanDiscoveryServiceFactory = LanDiscoveryService Function();

String _localizedRemoteError(Object error, String Function(String details) fallback) {
  if (error is RemotePeerError) return error.message;
  return fallback(error.toString().replaceFirst('Exception: ', ''));
}

class CompanionRemoteProvider with ChangeNotifier, DisposableChangeNotifierMixin, WidgetsBindingObserver {
  CompanionRemoteProvider() : this._(CompanionRemotePeerService.new, LanDiscoveryService.new);

  @visibleForTesting
  CompanionRemoteProvider.forTesting({
    required CompanionRemotePeerServiceFactory peerServiceFactory,
    LanDiscoveryServiceFactory discoveryServiceFactory = LanDiscoveryService.new,
  }) : this._(peerServiceFactory, discoveryServiceFactory);

  CompanionRemoteProvider._(this._peerServiceFactory, this._discoveryServiceFactory) {
    WidgetsBinding.instance.addObserver(this);
    _initializeDeviceInfo();
  }

  final CompanionRemotePeerServiceFactory _peerServiceFactory;
  final LanDiscoveryServiceFactory _discoveryServiceFactory;

  // Outbound remote control session state (this device controlling another host).
  RemoteSession? _remoteSession;
  CompanionRemotePeerService? _remotePeerService;
  CompanionRemotePeerService? _pendingRemotePeer;

  // Inbound host server state (other devices connecting to control this device).
  RemoteSession? _hostSession;
  CompanionRemotePeerService? _hostPeerService;
  RemoteDevice? _hostConnectedDevice;

  LanDiscoveryService? _discoveryService;
  String _deviceName = t.companionRemote.unknownDevice;
  String _platform = 'unknown';
  bool _isPlayerActive = false;
  // Whether this device's own video player is up, as last advertised to a
  // remote. Kept so a remote that pairs mid-playback is told on connect.
  bool _hostPlayerActive = false;
  RemotePlayerSnapshot _hostPlayerSnapshot = RemotePlayerSnapshot.idle;
  bool _hasHostPlayerSnapshot = false;
  RemotePlayerSnapshot _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
  final Map<String, RemotePlayerSnapshot> _deviceSnapshots = {};
  final Set<String> _loadingDeviceKeys = {};
  List<DiscoveredHost> _beaconHosts = const [];
  StreamSubscription<List<DiscoveredHost>>? _passiveDiscoverySub;
  // Listen addresses of a running host server (`ip:port`), surfaced so the
  // host UI can show what a phone's manual connection should target.
  List<String> _hostServerAddresses = const [];

  static const int _maxReconnectAttempts = 5;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  Future<void>? _activeReconnect;
  int? _activeReconnectGeneration;

  // Lifecycle-aware reconnect state: Android restricts background network
  // access, so retries fired while backgrounded are guaranteed failures that
  // only consume the bounded budget. The cycle is held open instead and
  // retried on resume.
  bool _appBackgrounded = false;
  bool _resumeReconnectPending = false;
  int _resumeReconnectGeneration = 0;
  int _remoteGeneration = 0;
  int _hostGeneration = 0;
  final Expando<int> _intentionalDisconnectGeneration = Expando<int>(
    'companion remote intentional disconnect generation',
  );
  Future<void>? _inFlightHostConnect;
  int? _inFlightHostGeneration;
  String? _inFlightHostClientId;
  String? _inFlightAuthContextId;
  bool _passiveDiscoveryRequested = false;

  // Reconnection context (only hostAddresses and hostClientId are connection-specific)
  List<String>? _lastHostAddresses;
  String? _lastHostClientId;
  String? _lastAuthContextId;

  // Crypto context (derived in memory, never persisted)
  List<RemoteAuthContext> _authContexts = const [];
  bool _lanStandbyReady = false;
  int? _hostServerPort;
  String? _cryptoProfileId;
  String _myDeviceId = '';
  Completer<void>? _pendingTrustCancel;

  // Profile-scoped & app-scoped services watched so a running host's crypto
  // identity tracks home-user, connection, and LAN-trust changes.
  ConnectionRegistry? _boundConnections;
  ActiveProfileProvider? _boundActiveProfile;
  ProfileConnectionRegistry? _boundProfileConnections;
  PlexHomeService? _boundPlexHome;
  LanPairingService? _boundLan;
  LanIdentityStore? _boundLanIdentity;
  final List<StreamSubscription<void>> _profileServiceSubs = [];
  bool _authRefreshScheduled = false;

  // Serializes host start/stop/crypto-rebuild so overlapping lifecycle calls
  // (a user action and a live auth-context refresh) can't interleave and
  // corrupt the peer service.
  final SerialFutureQueue _lifecycle = SerialFutureQueue();

  int get reconnectAttempts => _reconnectAttempts;

  StreamSubscription<RemoteCommand>? _remoteCommandSubscription;
  StreamSubscription<RemoteDevice>? _remoteDeviceConnectedSubscription;
  StreamSubscription<void>? _remoteDeviceDisconnectedSubscription;
  StreamSubscription<RemotePeerError>? _remoteErrorSubscription;
  StreamSubscription<RemoteSessionStatus>? _remoteStatusSubscription;

  StreamSubscription<RemoteCommand>? _hostCommandSubscription;
  StreamSubscription<RemoteDevice>? _hostDeviceConnectedSubscription;
  StreamSubscription<void>? _hostDeviceDisconnectedSubscription;
  StreamSubscription<RemotePeerError>? _hostErrorSubscription;
  StreamSubscription<RemoteSessionStatus>? _hostStatusSubscription;

  int _catalogRequestSeq = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingCatalogRequests = {};

  CommandReceivedCallback? onCommandReceived;
  Future<bool> Function(RemoteMediaTarget target)? onPlayMediaRequested;
  Future<RemoteHostSearchResponse> Function(String query, int limit)? onSearchHostCatalog;
  Future<RemoteHostHomeResponse> Function()? onBrowseHostHome;
  Future<RemoteHostChildrenResponse> Function(String serverId, String itemId, String? kind)? onBrowseHostItemChildren;

  bool get isInSession => isRemote || _hostConnectedDevice != null;
  bool get isHost => isHostServerRunning;
  bool get isRemote => _remoteSession != null && _remoteSession!.status != RemoteSessionStatus.disconnected;
  bool get isConnected => _remoteSession?.isConnected ?? false;
  bool get hasActiveControlLink => isConnected || _hostConnectedDevice != null;
  RemoteSession? get session => _remoteSession;
  RemoteSession? get hostSession => _hostSession;
  RemoteSessionStatus get status => _remoteSession?.status ?? RemoteSessionStatus.disconnected;
  RemoteDevice? get connectedDevice => _remoteSession?.connectedDevice ?? _hostConnectedDevice;
  RemoteDevice? get hostConnectedDevice => _hostConnectedDevice;
  String? get hostErrorMessage => _hostSession?.errorMessage;
  bool get isPlayerActive => _isPlayerActive;
  RemotePlayerSnapshot get hostPlayerSnapshot => _hostPlayerSnapshot;
  RemotePlayerSnapshot get remotePlayerSnapshot => _remotePlayerSnapshot;
  bool get isHostServerRunning => _hostPeerService?.isServerRunning ?? false;
  List<String> get hostServerAddresses => _hostServerAddresses;

  Future<void> _initializeDeviceInfo() async {
    final identity = await DeviceIdentityService.resolve();
    final resolvedName = identity.deviceName?.trim();
    _deviceName = isMeaningfulDeviceName(resolvedName) ? resolvedName! : t.companionRemote.unknownDevice;
    _platform = identity.platform;

    safeNotifyListeners();
  }

  /// Bind the profile-scoped services (and optional LAN pairing service) whose
  /// changes must keep a running host's crypto identity current: a removed home
  /// user, revoked borrowed connection, or revoked LAN trust has to stop
  /// controlling an already-broadcasting host.
  void bindProfileServices({
    required ConnectionRegistry connections,
    required ActiveProfileProvider activeProfile,
    required ProfileConnectionRegistry profileConnections,
    required PlexHomeService plexHome,
    LanPairingService? lan,
    LanIdentityStore? identityStore,
  }) {
    if (lan != null || identityStore != null) {
      bindLanPairing(lan, identityStore: identityStore);
    }
    if (_boundActiveProfile != null) return;
    _boundConnections = connections;
    _boundActiveProfile = activeProfile;
    _boundProfileConnections = profileConnections;
    _boundPlexHome = plexHome;

    _profileServiceSubs.add(plexHome.stream.listen((_) => _scheduleAuthContextRefresh()));
    _profileServiceSubs.add(connections.watchConnections().listen((_) => _scheduleAuthContextRefresh()));
    _profileServiceSubs.add(profileConnections.watchAll().listen((_) => _scheduleAuthContextRefresh()));
    activeProfile.addListener(_scheduleAuthContextRefresh);
  }

  /// Bind the app-scoped [LanPairingService] so LAN P2P trust changes
  /// automatically drive companion remote discovery/host auth.
  void bindLanPairing(LanPairingService? lan, {LanIdentityStore? identityStore}) {
    if (identityStore != null) {
      _boundLanIdentity = identityStore;
    } else if (lan != null) {
      _boundLanIdentity ??= lan.identityStore;
    }
    if (identical(_boundLan, lan)) return;
    _boundLan?.removeListener(_onBoundLanChanged);
    _boundLan = lan;
    _boundLan?.addListener(_onBoundLanChanged);
  }

  void _onBoundLanChanged() {
    if (isDisposed) return;
    if (isHostServerRunning || isCryptoReady) {
      _scheduleAuthContextRefresh();
    }
    safeNotifyListeners();
  }

  /// Coalesce a burst of stream events into a single rebuild. Only an active
  /// host or initialized LAN-bound discovery view needs live identity updates.
  void _scheduleAuthContextRefresh() {
    if (!isHostServerRunning && !(isCryptoReady && _boundLan != null)) return;
    if (_authRefreshScheduled) return;
    _authRefreshScheduled = true;
    scheduleMicrotask(() {
      _authRefreshScheduled = false;
      unawaited(_refreshHostAuthContexts());
    });
  }

  Future<void> _refreshHostAuthContexts() async {
    final connections = _boundConnections;
    final activeProfile = _boundActiveProfile;
    final profileConnections = _boundProfileConnections;
    final plexHome = _boundPlexHome;
    final lan = _boundLan;
    final identityStore = _boundLanIdentity;
    final hasProfileServices = connections != null && activeProfile != null && profileConnections != null;
    if (!hasProfileServices && lan == null) {
      return;
    }
    final wasHostRunning = isHostServerRunning;
    if (!wasHostRunning && !(isCryptoReady && lan != null)) return;

    await _serializeLifecycle(() async {
      if (isDisposed) return;
      final generation = _remoteGeneration;
      final ok = await _ensureCryptoReadyLocked(
        null,
        connections: connections,
        activeProfile: activeProfile,
        profileConnections: profileConnections,
        plexHomeForConnection: plexHome?.materializePlexHomeForConnection,
        lan: lan,
        identityStore: identityStore,
      );
      // Unchanged identities leave the host running (no restart). When they
      // change across profile switches, the rebuild tore the host down — bring it
      // back so the new set is what's broadcasting. When every identity is gone
      // the host stays down by design (`ok` is false).
      if (wasHostRunning && ok && !isHostServerRunning && !isDisposed && generation == _remoteGeneration) {
        await _startHostServerLocked();
      }
    });
  }

  /// Run [action] after every previously-queued lifecycle action settles, so
  /// start/stop/crypto-rebuild never overlap. The chain survives a throwing
  /// action (errors surface to that action's caller, not the next in line).
  Future<T> _serializeLifecycle<T>(Future<T> Function() action) => _lifecycle.run(action);

  RemoteAuthContext? get _primaryAuthContext => _authContexts.isEmpty ? null : _authContexts.first;

  bool get isCryptoReady => _authContexts.isNotEmpty || _lanStandbyReady;

  /// Ensure crypto is initialized for LAN P2P without requiring profile services
  /// (useful for mode-decoupled LAN pairing flows and unit tests).
  Future<bool> ensureLanCryptoReady(
    LanPairingService lan, {
    LanIdentityStore? identityStore,
    void Function()? checkCurrent,
  }) {
    return _serializeLifecycle(
      () => _ensureCryptoReadyLocked(
        null,
        connections: _boundConnections,
        activeProfile: _boundActiveProfile,
        profileConnections: _boundProfileConnections,
        plexHomeForConnection: _boundPlexHome?.materializePlexHomeForConnection,
        lan: lan,
        identityStore: identityStore,
        checkCurrent: checkCurrent,
      ),
    );
  }

  /// Ensure crypto is initialized for every remote identity attached to the
  /// active profile and/or bound LAN pairing service. Serialized against host
  /// start/stop so a live refresh and a user-driven start can't interleave.
  /// Returns true if crypto is ready (already initialized or just initialized).
  Future<bool> ensureCryptoReady(
    PlexHome? home, {
    required ConnectionRegistry connections,
    required ActiveProfileProvider activeProfile,
    required ProfileConnectionRegistry profileConnections,
    ActivePlexIdentity? identity,
    PlexAccountConnection? account,
    PlexHomeResolver? plexHomeForConnection,
    LanPairingService? lan,
    LanIdentityStore? identityStore,
    void Function()? checkCurrent,
  }) {
    return _serializeLifecycle(
      () => _ensureCryptoReadyLocked(
        home,
        connections: connections,
        activeProfile: activeProfile,
        profileConnections: profileConnections,
        identity: identity,
        account: account,
        plexHomeForConnection: plexHomeForConnection,
        lan: lan,
        identityStore: identityStore,
        checkCurrent: checkCurrent,
      ),
    );
  }

  Future<bool> _ensureCryptoReadyLocked(
    PlexHome? home, {
    ConnectionRegistry? connections,
    ActiveProfileProvider? activeProfile,
    ProfileConnectionRegistry? profileConnections,
    ActivePlexIdentity? identity,
    PlexAccountConnection? account,
    PlexHomeResolver? plexHomeForConnection,
    LanPairingService? lan,
    LanIdentityStore? identityStore,
    void Function()? checkCurrent,
  }) async {
    checkCurrent?.call();
    final effectiveLan = lan ?? _boundLan;
    final effectiveIdentity = identityStore ?? _boundLanIdentity ?? effectiveLan?.identityStore;
    if (effectiveLan != null || effectiveIdentity != null) {
      bindLanPairing(effectiveLan, identityStore: effectiveIdentity);
    }

    if (effectiveIdentity != null) {
      final customName = await effectiveIdentity.getCustomDeviceName();
      checkCurrent?.call();
      if (customName != null && customName.isNotEmpty) {
        _deviceName = customName;
      } else if (!isMeaningfulDeviceName(_deviceName) || _deviceName == t.companionRemote.unknownDevice) {
        final fallbackName = (await effectiveIdentity.getDeviceName()).trim();
        checkCurrent?.call();
        if (isMeaningfulDeviceName(fallbackName)) {
          _deviceName = fallbackName;
        }
      }
      if (effectiveLan?.deviceId case final lanId? when lanId.isNotEmpty) {
        _myDeviceId = lanId;
      } else {
        _myDeviceId = await effectiveIdentity.getOrCreateDeviceId();
        checkCurrent?.call();
      }
    } else if (effectiveLan != null) {
      final lanName = effectiveLan.deviceName?.trim();
      if (lanName != null && isMeaningfulDeviceName(lanName)) {
        _deviceName = lanName;
      }
      _myDeviceId = effectiveLan.deviceId ?? '';
    }

    Profile? profile;
    if (activeProfile != null) {
      await activeProfile.initialize();
      checkCurrent?.call();
      profile = activeProfile.active;
    }

    if (profile == null && effectiveLan == null) {
      appLogger.w('CompanionRemote: Cannot init crypto — no active profile or LAN pairing service');
      return false;
    }

    final nextContexts = <RemoteAuthContext>[];
    final seenIds = <String>{};
    void addUniqueContext(RemoteAuthContext context) {
      if (seenIds.add(context.id)) {
        nextContexts.add(context);
      }
    }

    var nextLanStandby = false;
    if (effectiveLan != null) {
      final auth = RemoteAuthService.instance;
      if (effectiveLan.isRunning ||
          effectiveLan.trustedPeers.isNotEmpty ||
          effectiveIdentity != null) {
        final lanDeviceId = effectiveLan.deviceId;
        final myDeviceId = (lanDeviceId != null && lanDeviceId.isNotEmpty)
            ? lanDeviceId
            : (_myDeviceId.isNotEmpty
                  ? _myDeviceId
                  : (await effectiveIdentity?.getOrCreateDeviceId() ?? ''));
        if (myDeviceId.isNotEmpty) {
          _myDeviceId = myDeviceId;
        }
        checkCurrent?.call();
        final lanPeers = effectiveLan.isRunning
            ? effectiveLan.trustedPeers
            : (await effectiveIdentity?.loadTrustedLanPeers() ?? effectiveLan.trustedPeers);
        checkCurrent?.call();
        for (final trusted in lanPeers) {
          addUniqueContext(
            await auth.createLanPeerAuthContext(
              myDeviceId: myDeviceId,
              peerDeviceId: trusted.deviceId,
              sharedKey: trusted.sharedKey,
            ),
          );
        }
        nextLanStandby = effectiveLan.isRunning;
      }
    }

    if (profile != null && connections != null && profileConnections != null) {
      final profileContexts = await _buildAuthContextsForProfile(
        profile: profile,
        connections: connections,
        profileConnections: profileConnections,
        fallbackHome: home,
        identity: identity,
        preferredAccount: account,
        plexHomeForConnection: plexHomeForConnection,
      );
      checkCurrent?.call();
      for (final context in profileContexts) {
        addUniqueContext(context);
      }
    } else {
      checkCurrent?.call();
    }

    final nextProfileKey = profile?.id ?? '__lan__';

    if (nextContexts.isEmpty && !nextLanStandby) {
      if (isCryptoReady) await _prepareForCryptoRebuild();
      appLogger.w('CompanionRemote: Cannot init crypto — no active remote identities');
      return false;
    }

    if (_cryptoProfileId == nextProfileKey &&
        _lanStandbyReady == nextLanStandby &&
        _sameAuthContexts(_authContexts, nextContexts)) {
      if (isHostServerRunning && _hostServerPort != null) {
        effectiveLan?.setAdvertisedRemotePort(nextLanStandby ? _hostServerPort : null);
      }
      return true;
    }

    // When only the auth context set (e.g., LAN peer trusted/revoked)
    // changed within the same profile scope, hot-update in place instead of closing
    // the host listening port or disturbing unaffected outbound sessions.
    if (_cryptoProfileId == nextProfileKey && _cryptoProfileId != null) {
      _authContexts = nextContexts;
      _lanStandbyReady = nextLanStandby;
      if (isHostServerRunning && _hostPeerService != null) {
        await _hostPeerService!.updateHostAuthContexts(nextContexts);
        checkCurrent?.call();
        final port = _hostServerPort;
        effectiveLan?.setAdvertisedRemotePort(nextLanStandby ? port : null);
        if (nextContexts.isEmpty) {
          await _discoveryService?.stopBroadcasting();
        } else if (port != null && _hostServerAddresses.isNotEmpty) {
          _discoveryService ??= _discoveryServiceFactory();
          final localIps = _hostServerAddresses.map((a) => a.split(':').first).toList();
          await _discoveryService!.startBroadcastingForContexts(
            contexts: nextContexts,
            deviceName: _deviceName,
            platform: _platform,
            wsPort: port,
            ips: localIps,
          );
        }
      }
      if (_passiveDiscoverySub != null) {
        await _passiveDiscoverySub!.cancel();
        _passiveDiscoverySub = null;
        if (_authContexts.isEmpty) {
          _beaconHosts = const [];
          _discoveryService?.stopListening();
        } else {
          startPassiveDiscovery();
        }
      } else if (_passiveDiscoveryRequested && _authContexts.isNotEmpty) {
        startPassiveDiscovery();
      }
      if (_remoteSession != null &&
          _lastAuthContextId != null &&
          !nextContexts.any((c) => c.id == _lastAuthContextId)) {
        await leaveSession();
      }
      safeNotifyListeners();
      appLogger.d('CompanionRemote: Hot-updated crypto contexts (${nextContexts.length})');
      return true;
    }

    await _prepareForCryptoRebuild();
    checkCurrent?.call();
    _authContexts = nextContexts;
    _lanStandbyReady = nextLanStandby;
    _cryptoProfileId = nextProfileKey;
    safeNotifyListeners();
    appLogger.d('CompanionRemote: Crypto contexts initialized (${nextContexts.length}, standby=$nextLanStandby)');
    return true;
  }

  Future<List<RemoteAuthContext>> _buildAuthContextsForProfile({
    required Profile profile,
    required ConnectionRegistry connections,
    required ProfileConnectionRegistry profileConnections,
    required PlexHome? fallbackHome,
    required ActivePlexIdentity? identity,
    required PlexAccountConnection? preferredAccount,
    required PlexHomeResolver? plexHomeForConnection,
  }) async {
    final contexts = <RemoteAuthContext>[];
    final seen = <String>{};
    final all = await connections.list();
    final byId = {for (final c in all) c.id: c};

    Future<PlexHome?> resolvePlexHome(PlexAccountConnection account) async {
      if (fallbackHome != null &&
          (identity?.account.id == account.id || preferredAccount?.id == account.id || plexHomeForConnection == null)) {
        return fallbackHome;
      }
      return plexHomeForConnection?.call(account.id);
    }

    void addContext(RemoteAuthContext? context) {
      if (context == null || seen.contains(context.id)) return;
      contexts.add(context);
      seen.add(context.id);
    }

    Future<void> addConnection(Connection connection, {String? userUuid}) async {
      switch (connection) {
        case PlexAccountConnection():
          addContext(
            await _createPlexAuthContext(
              account: connection,
              home: await resolvePlexHome(connection),
              activeProfile: profile,
              userUuid: userUuid,
            ),
          );
        case JellyfinConnection():
          addContext(await _createMediaBrowserAuthContext(connection: connection));
      }
    }

    if (profile.parentConnectionId case final parentId?) {
      final parent = preferredAccount?.id == parentId
          ? preferredAccount
          : (identity?.account.id == parentId ? identity?.account : byId[parentId]);
      if (parent is PlexAccountConnection) {
        await addConnection(parent, userUuid: profile.plexHomeUserUuid);
      }
    }

    final pcs = await profileConnections.listForProfile(profile.id);
    for (final pc in pcs) {
      final connection = byId[pc.connectionId];
      if (connection == null) continue;
      await addConnection(connection, userUuid: pc.userIdentifier.isEmpty ? null : pc.userIdentifier);
    }

    return contexts;
  }

  Future<RemoteAuthContext?> _createPlexAuthContext({
    required PlexAccountConnection account,
    required PlexHome? home,
    required Profile activeProfile,
    required String? userUuid,
  }) async {
    if (home == null || home.adminUser == null) {
      appLogger.w('CompanionRemote: Skipping Plex remote identity — no home data for ${account.id}');
      return null;
    }

    final auth = RemoteAuthService.instance;
    final homeSecret = await auth.deriveHomeSecretFromHome(home);
    final resolvedUserUuid = userUuid != null && userUuid.isNotEmpty
        ? userUuid
        : (activeProfile.plexHomeUserUuid != null && activeProfile.plexHomeUserUuid!.isNotEmpty
              ? activeProfile.plexHomeUserUuid!
              : home.adminUser!.uuid);
    final allowedUserUuids = {
      for (final user in home.users)
        if (user.uuid.isNotEmpty) user.uuid,
      if (resolvedUserUuid.isNotEmpty) resolvedUserUuid,
    }.toList();

    return RemoteAuthContext(
      id: auth.computeAuthContextId(homeSecret),
      backend: account.kind.id,
      connectionId: account.id,
      homeSecret: homeSecret,
      discoveryKey: await auth.deriveDiscoveryKey(homeSecret),
      clientIdentifier: account.clientIdentifier.isNotEmpty ? account.clientIdentifier : account.id,
      userUuid: resolvedUserUuid,
      allowedUserUuids: allowedUserUuids,
    );
  }

  Future<RemoteAuthContext?> _createMediaBrowserAuthContext({required JellyfinConnection connection}) async {
    if (connection.accessToken.isEmpty || connection.userId.isEmpty || connection.serverMachineId.isEmpty) {
      appLogger.w('CompanionRemote: Skipping MediaBrowser remote identity — incomplete connection ${connection.id}');
      return null;
    }

    final auth = RemoteAuthService.instance;
    final homeSecret = await auth.deriveJellyfinSecret(
      serverMachineId: connection.serverMachineId,
      userId: connection.userId,
    );
    return RemoteAuthContext(
      id: auth.computeAuthContextId(homeSecret),
      backend: connection.kind.id,
      connectionId: connection.id,
      homeSecret: homeSecret,
      discoveryKey: await auth.deriveDiscoveryKey(homeSecret),
      clientIdentifier: connection.deviceId.isNotEmpty ? connection.deviceId : connection.id,
      userUuid: connection.userId,
      allowedUserUuids: [connection.userId],
    );
  }

  bool _sameAuthContexts(List<RemoteAuthContext> a, List<RemoteAuthContext> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.id != right.id ||
          left.backend != right.backend ||
          left.connectionId != right.connectionId ||
          left.clientIdentifier != right.clientIdentifier ||
          left.userUuid != right.userUuid ||
          !_sameStrings(left.allowedUserUuids, right.allowedUserUuids)) {
        return false;
      }
    }
    return true;
  }

  bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  RemoteAuthContext? _authContextForId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final context in _authContexts) {
      if (context.id == id) return context;
    }
    return null;
  }

  Future<void> _prepareForCryptoRebuild() async {
    // Always invoked from inside the lifecycle lock — use the unlocked stop so
    // we don't deadlock on our own chain.
    final leavingGeneration = _remoteGeneration;
    _markIntentionalDisconnect(_remotePeerService, leavingGeneration);
    _markIntentionalDisconnect(_pendingRemotePeer, leavingGeneration);
    final detachedPeers = _invalidateRemoteLifecycle();
    _reconnectAttempts = 0;
    _remoteSession = null;
    _isPlayerActive = false;
    _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
    await _disposeDetachedPeers(detachedPeers);
    if (isHostServerRunning || _hostPeerService != null || _hostSession != null) {
      await _stopHostServerLocked();
    }
    stopDiscovery();
    _clearCryptoContext();
  }

  void _clearCryptoContext() {
    _authContexts = const [];
    _lanStandbyReady = false;
    _hostServerPort = null;
    _cryptoProfileId = null;
  }

  void _markIntentionalDisconnect(CompanionRemotePeerService? peer, int generation) {
    if (peer != null) {
      _intentionalDisconnectGeneration[peer] = generation;
    }
  }

  bool _isIntentionalDisconnect(CompanionRemotePeerService peer, int generation) {
    return _intentionalDisconnectGeneration[peer] == generation;
  }

  bool _ownsRemotePeer(CompanionRemotePeerService peer, int generation) {
    return !isDisposed &&
        generation == _remoteGeneration &&
        (identical(_remotePeerService, peer) || identical(_pendingRemotePeer, peer));
  }

  bool _ownsHostPeer(CompanionRemotePeerService peer, int hostGeneration) {
    return !isDisposed && hostGeneration == _hostGeneration && identical(_hostPeerService, peer);
  }

  ({CompanionRemotePeerService? current, CompanionRemotePeerService? pending}) _invalidateRemoteLifecycle() {
    _remoteGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _resumeReconnectPending = false;
    _inFlightHostConnect = null;
    _inFlightHostGeneration = null;
    _inFlightHostClientId = null;
    _inFlightAuthContextId = null;
    cancelPendingTrust();

    final pending = _pendingRemotePeer;
    final current = _remotePeerService;
    _pendingRemotePeer = null;
    _remotePeerService = null;
    if (current != null || pending != null) {
      _cleanupRemoteSubscriptions();
    }
    return (current: current, pending: pending);
  }

  /// Peer disposal is idempotent and self-deduplicating
  /// ([CompanionRemotePeerService.dispose]); this wrapper only keeps cleanup
  /// failures from escaping teardown paths.
  Future<void> _disposePeer(CompanionRemotePeerService peer) async {
    try {
      await peer.dispose();
    } catch (error, stackTrace) {
      appLogger.d('CompanionRemote: Peer cleanup ignored', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _disposeDetachedPeers(
    ({CompanionRemotePeerService? current, CompanionRemotePeerService? pending}) peers,
  ) async {
    final current = peers.current;
    final pending = peers.pending;
    if (current != null) {
      await _disposePeer(current);
    }
    if (pending != null && !identical(pending, current)) {
      await _disposePeer(pending);
    }
  }

  _RemoteConnectRequest _beginRemoteConnectRequest() {
    final leavingGeneration = _remoteGeneration;
    _markIntentionalDisconnect(_remotePeerService, leavingGeneration);
    _markIntentionalDisconnect(_pendingRemotePeer, leavingGeneration);
    final peers = _invalidateRemoteLifecycle();
    _reconnectAttempts = 0;
    _remoteSession = null;
    _isPlayerActive = false;
    _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
    safeNotifyListeners();
    return _RemoteConnectRequest(generation: _remoteGeneration, current: peers.current, pending: peers.pending);
  }

  Future<bool> _prepareRemoteConnect(_RemoteConnectRequest request) async {
    await _disposeDetachedPeers((current: request.current, pending: request.pending));
    return !isDisposed && request.generation == _remoteGeneration;
  }

  /// Fully tear down network/session state and forget derived crypto material.
  /// Used by logout so an app-level provider surviving route replacement does
  /// not keep broadcasting with the previous Plex Home identity.
  Future<void> resetForLogout() {
    _passiveDiscoveryRequested = false;
    final leavingGeneration = _remoteGeneration;
    _markIntentionalDisconnect(_remotePeerService, leavingGeneration);
    _markIntentionalDisconnect(_pendingRemotePeer, leavingGeneration);
    final detachedPeers = _invalidateRemoteLifecycle();
    _reconnectAttempts = 0;
    _remoteSession = null;
    _isPlayerActive = false;
    _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
    _lastHostAddresses = null;
    _lastHostClientId = null;
    _lastAuthContextId = null;

    return _serializeLifecycle(() async {
      await _disposeDetachedPeers(detachedPeers);
      await _stopHostServerLocked();
      stopDiscovery();
      _clearCryptoContext();
      RemoteAuthService.instance.clearCache();
      safeNotifyListeners();
    });
  }

  @visibleForTesting
  String? get debugCryptoConnectionId => _primaryAuthContext?.connectionId;

  @visibleForTesting
  String? get debugCryptoProfileId => _cryptoProfileId;

  @visibleForTesting
  String? get debugCryptoUserUuid => _primaryAuthContext?.userUuid;

  @visibleForTesting
  List<String> get debugCryptoConnectionIds => _authContexts.map((context) => context.connectionId).toList();

  @visibleForTesting
  bool get debugIsDiscoveryBroadcasting => _discoveryService?.isBroadcasting ?? false;

  @visibleForTesting
  bool get debugIsDiscoveryListening => _discoveryService?.isListening ?? false;

  Future<void> startHostServer({void Function()? checkCurrent}) =>
      _serializeLifecycle(() => _startHostServerLocked(checkCurrent: checkCurrent));

  Future<void> _startHostServerLocked({void Function()? checkCurrent}) async {
    checkCurrent?.call();
    if (isDisposed || _hostPeerService?.isServerRunning == true) return;
    if (!isCryptoReady) {
      appLogger.w('CompanionRemote: Cannot start host — crypto not initialized');
      return;
    }

    appLogger.d('CompanionRemote: Starting host server');

    final peer = _hostPeerService ??= _peerServiceFactory();
    final hostGeneration = ++_hostGeneration;
    peer.hostStatusSnapshotBuilder = () => _hostPlayerSnapshot;
    peer.onHostQuickAction = (action, _) async {
      if (action == 'playPause') {
        CompanionRemoteReceiver.instance.handleCommand(const RemoteCommand(type: RemoteCommandType.playPause), null);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _hostPlayerSnapshot;
    };
    _setupHostPeerServiceListeners(peer, hostGeneration);

    try {
      final contexts = List<RemoteAuthContext>.unmodifiable(_authContexts);
      final result = (contexts.isEmpty && _lanStandbyReady)
          ? await peer.createStandbySession(_deviceName, _platform)
          : await peer.createSessionForContexts(_deviceName, _platform, contexts);
      try {
        checkCurrent?.call();
      } catch (_) {
        // The serialized start still owns this candidate. Retire it instead
        // of leaving a stale authorized listener running after a profile switch.
        if (identical(_hostPeerService, peer)) await _stopHostServerLocked();
        rethrow;
      }
      _hostServerAddresses = result.addresses;
      _hostServerPort = result.port;
      _boundLan?.setAdvertisedRemotePort(_lanStandbyReady ? result.port : null);

      _hostSession = RemoteSession(
        role: RemoteSessionRole.host,
        status: RemoteSessionStatus.connected,
        connectedDevice: _hostConnectedDevice,
        createdAt: DateTime.now(),
      );
      safeNotifyListeners();

      if (contexts.isNotEmpty) {
        // Start LAN discovery broadcasting
        _discoveryService ??= _discoveryServiceFactory();
        final localIps = result.addresses.map((a) => a.split(':').first).toList();
        await _discoveryService!.startBroadcastingForContexts(
          contexts: contexts,
          deviceName: _deviceName,
          platform: _platform,
          wsPort: result.port,
          ips: localIps,
        );
        try {
          checkCurrent?.call();
        } catch (_) {
          if (identical(_hostPeerService, peer)) await _stopHostServerLocked();
          rethrow;
        }
      }

      appLogger.d('CompanionRemote: Host server running (standby=${contexts.isEmpty})');
    } catch (e) {
      checkCurrent?.call();
      appLogger.e('CompanionRemote: Failed to start host server', error: e);
      _hostServerAddresses = const [];
      _hostServerPort = null;
      _boundLan?.setAdvertisedRemotePort(null);
      _hostSession = RemoteSession(
        role: RemoteSessionRole.host,
        status: RemoteSessionStatus.error,
        errorMessage: _localizedRemoteError(e, (details) => t.companionRemote.errors.serverStartFailed(error: details)),
        createdAt: DateTime.now(),
      );
      safeNotifyListeners();
    }
  }

  /// Stop the host server and LAN broadcasting.
  Future<void> stopHostServer({void Function()? checkCurrent}) => _serializeLifecycle(() async {
    checkCurrent?.call();
    await _stopHostServerLocked();
  });

  Future<void> _stopHostServerLocked() async {
    final stopGeneration = ++_hostGeneration;
    final peer = _hostPeerService;

    try {
      await _discoveryService?.stopBroadcasting();
      _hostServerAddresses = const [];
      _hostServerPort = null;
      _boundLan?.setAdvertisedRemotePort(null);

      if (identical(_hostPeerService, peer)) {
        _hostPeerService = null;
        _cleanupHostSubscriptions();
      }
      if (peer != null) {
        await _disposePeer(peer);
      }

      // A newer host start may arrive while an older peer's disposal settles.
      if (_hostGeneration == stopGeneration) {
        _hostSession = null;
        _hostConnectedDevice = null;
      }
      safeNotifyListeners();
    } catch (e, stackTrace) {
      appLogger.d('CompanionRemote: Host server stop cleanup ignored', error: e, stackTrace: stackTrace);
    }
  }

  bool _isSelfHost(DiscoveredHost host) {
    final myDeviceId = _boundLan?.deviceId ?? _myDeviceId;
    if (myDeviceId.isNotEmpty && host.clientId == myDeviceId) return true;
    for (final ctx in _authContexts) {
      if (ctx.id == host.authContextId && ctx.clientIdentifier.isNotEmpty && ctx.clientIdentifier == host.clientId) {
        return true;
      }
    }
    if (isHostServerRunning && _hostServerAddresses.isNotEmpty) {
      for (final addr in host.addresses) {
        if (_hostServerAddresses.contains(addr)) return true;
      }
    }
    return false;
  }

  Stream<List<DiscoveredHost>>? discoverHosts() {
    if (!isCryptoReady) {
      appLogger.w('CompanionRemote: Cannot discover — crypto not initialized');
      return null;
    }

    if (_authContexts.isEmpty && _lanStandbyReady) {
      return Stream<List<DiscoveredHost>>.value(const []);
    }

    _discoveryService ??= _discoveryServiceFactory();
    final raw = _discoveryService!.startListeningForContexts(_authContexts);
    return raw.map((hosts) => hosts.where((h) => !_isSelfHost(h)).toList());
  }

  /// Discovered LAN peers that are already trusted and advertising a remote host port.
  List<DiscoveredHost> get trustedLanRemoteHosts {
    final lan = _boundLan;
    if (lan == null || !lan.isRunning) return const [];
    final result = <DiscoveredHost>[];
    for (final peer in lan.discoveredPeers) {
      final remotePort = peer.remotePort;
      if (remotePort == null || remotePort <= 0 || !lan.isPeerTrusted(peer.deviceId)) continue;
      final ctx = _authContexts.where((c) => c.connectionId == 'lan:${peer.deviceId}').firstOrNull;
      if (ctx == null) continue;
      result.add(
        DiscoveredHost(
          authContextId: ctx.id,
          clientId: peer.deviceId,
          name: peer.deviceName,
          platform: peer.platform,
          port: remotePort,
          ips: [peer.host],
          lastSeen: peer.lastSeen,
        ),
      );
    }
    return result;
  }

  /// Starts passive background listening for UDP beacons across active auth
  /// contexts (when crypto is ready) so PopMenus can list online hosts immediately.
  void startPassiveDiscovery() {
    if (isDisposed) return;
    _passiveDiscoveryRequested = true;
    if (!isCryptoReady || _authContexts.isEmpty || _passiveDiscoverySub != null) {
      return;
    }
    final stream = discoverHosts();
    if (stream == null) return;
    _passiveDiscoverySub = stream.listen((hosts) {
      if (isDisposed) return;
      _beaconHosts = hosts;
      safeNotifyListeners();
    });
  }

  /// Combined online trusted LAN peers and same-account Sync hosts.
  List<DiscoveredHost> get onlineTrustedHosts {
    final merged = <String, DiscoveredHost>{};
    for (final host in [...trustedLanRemoteHosts, ..._beaconHosts]) {
      if (_isSelfHost(host)) continue;
      final dedupKey = host.clientId.isNotEmpty ? host.clientId : '${host.authContextId}:${host.clientId}';
      merged[dedupKey] = host;
    }
    return merged.values.toList(growable: false);
  }

  bool isConnectedToHost(DiscoveredHost host) {
    if (!isRemote || !isConnected) return false;
    if (_lastHostClientId != host.clientId) return false;
    return _lastAuthContextId == null || _lastAuthContextId == host.authContextId;
  }

  bool isConnectingToHost(DiscoveredHost host) {
    if (_inFlightHostConnect == null || _inFlightHostGeneration != _remoteGeneration) return false;
    if (_inFlightHostClientId != host.clientId) return false;
    return _inFlightAuthContextId == null || _inFlightAuthContextId == host.authContextId;
  }

  DiscoveredHost _resolveLatestDiscoveredHost(DiscoveredHost host) {
    for (final latest in onlineTrustedHosts) {
      if (latest.clientId == host.clientId && latest.authContextId == host.authContextId) {
        return latest;
      }
    }
    return host;
  }

  /// Live snapshot cards for every currently reachable trusted remote device.
  List<RemoteOnlineDevice> get onlineTrustedDevices {
    return [
      for (final host in onlineTrustedHosts)
        () {
          final key = '${host.authContextId}:${host.clientId}';
          final snapshot = isConnectedToHost(host)
              ? _remotePlayerSnapshot
              : (_deviceSnapshots[key] ?? RemotePlayerSnapshot.idle);
          return RemoteOnlineDevice(host: host, snapshot: snapshot, loadingStatus: _loadingDeviceKeys.contains(key));
        }(),
    ];
  }

  /// Polls every online trusted device's live playback snapshot over encrypted
  /// HTTP `/status` without disrupting any active `/ws` control session.
  Future<void> refreshOnlineDeviceStatuses() async {
    if (isDisposed) return;
    startPassiveDiscovery();
    final lan = _boundLan;
    if (lan != null && lan.isRunning) {
      await lan.probeTrustedPeers();
      if (isDisposed) return;
    }
    final hosts = onlineTrustedHosts;
    if (hosts.isEmpty) return;

    await Future.wait([
      for (final host in hosts)
        () async {
          if (isConnectedToHost(host)) return;
          final ctx = _authContextForId(host.authContextId);
          if (ctx == null) return;
          final key = '${host.authContextId}:${host.clientId}';
          _loadingDeviceKeys.add(key);
          safeNotifyListeners();
          try {
            final snapshot = await CompanionRemotePeerService.fetchHostStatus(host: host, context: ctx);
            if (!isDisposed && snapshot != null) {
              _deviceSnapshots[key] = snapshot;
            }
          } finally {
            _loadingDeviceKeys.remove(key);
            safeNotifyListeners();
          }
        }(),
    ]);
  }

  /// Toggles play/pause on [host], reusing the active `/ws` session if connected
  /// to [host] or issuing an authenticated HTTP `POST /action` otherwise.
  Future<void> toggleOnlineDevicePlayPause(DiscoveredHost host) async {
    if (isConnectedToHost(host)) {
      sendCommand(RemoteCommandType.playPause);
      return;
    }
    final ctx = _authContextForId(host.authContextId);
    if (ctx == null) return;
    final snapshot = await CompanionRemotePeerService.sendHostQuickAction(
      host: host,
      context: ctx,
      action: 'playPause',
    );
    if (!isDisposed && snapshot != null) {
      _deviceSnapshots['${host.authContextId}:${host.clientId}'] = snapshot;
      safeNotifyListeners();
    }
  }

  /// Connects to [host] (if not already connected) and launches playback of [target].
  Future<void> connectAndPlayMedia(DiscoveredHost host, RemoteMediaTarget target) async {
    try {
      if (!isConnectedToHost(host)) {
        await connectToDiscoveredHost(host);
      }
    } catch (e, stackTrace) {
      appLogger.w('CompanionRemote: Failed to connect for media handoff', error: e, stackTrace: stackTrace);
      return;
    }
    if (isDisposed || !isConnectedToHost(host)) return;
    _remotePlayerSnapshot = RemotePlayerSnapshot(
      active: true,
      stage: 'opening',
      mediaKind: target.kind,
      title: target.title,
      seriesTitle: target.seriesTitle,
      seasonNumber: target.seasonNumber,
      episodeNumber: target.episodeNumber,
      posterUrl: target.posterUrl,
      positionMs: target.positionMs ?? 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _isPlayerActive = true;
    safeNotifyListeners();
    sendCommand(RemoteCommandType.playMedia, data: target.toJson());
  }

  /// Discovered nearby LAN P2P peers running a remote server that have not yet been trusted.
  List<LanDiscoveredPeer> get untrustedLanRemotePeers {
    final lan = _boundLan;
    if (lan == null || !lan.isRunning) return const [];
    final knownBeaconClientIds = {
      for (final host in _beaconHosts)
        if (host.clientId.isNotEmpty) host.clientId,
    };
    return [
      for (final peer in lan.discoveredPeers)
        if (peer.remotePort != null &&
            peer.remotePort! > 0 &&
            !lan.isPeerTrusted(peer.deviceId) &&
            !knownBeaconClientIds.contains(peer.deviceId))
          peer,
    ];
  }

  /// 4-digit SAS verification code between this device and [peer], if LAN P2P is initialized.
  String? pairingCodeForLanPeer(LanDiscoveredPeer peer) {
    final myPub = _boundLan?.publicKeyBase64;
    if (myPub == null || myPub.isEmpty) return null;
    return peer.pairingCodeFor(myPub);
  }

  /// Aborts any in-flight [trustAndConnectLanPeer] wait.
  void cancelPendingTrust() {
    final pending = _pendingTrustCancel;
    _pendingTrustCancel = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  /// Initiates a LAN trust request to [peer], waits for trust confirmation on the
  /// host, refreshes derived remote credentials, and connects automatically.
  Future<void> trustAndConnectLanPeer(
    LanDiscoveredPeer peer, {
    Duration trustTimeout = const Duration(seconds: 20),
  }) async {
    final lan = _boundLan;
    if (lan == null) {
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.cryptoInitFailed);
    }
    final initialRemotePort = peer.remotePort;
    if (initialRemotePort == null || initialRemotePort <= 0) {
      throw RemotePeerError(
        type: RemotePeerErrorType.connectionFailed,
        message: t.companionRemote.pairing.sessionNotFound,
      );
    }

    if (!lan.isRunning) {
      await lan.start();
    }

    if (!lan.isPeerTrusted(peer.deviceId)) {
      cancelPendingTrust();
      final cancelCompleter = Completer<void>();
      _pendingTrustCancel = cancelCompleter;
      try {
        await lan.requestPairWithPeer(peer);
        if (cancelCompleter.isCompleted || isDisposed) {
          throw const CompanionRemoteTrustCancelledException();
        }
        if (!lan.isPeerTrusted(peer.deviceId)) {
          final trustDone = Completer<void>();
          late final Timer timer;
          void onLanChanged() {
            if (trustDone.isCompleted) return;
            if (lan.isPeerTrusted(peer.deviceId)) {
              trustDone.complete();
            } else if (!lan.isRunning || isDisposed) {
              trustDone.completeError(
                RemotePeerError(
                  type: RemotePeerErrorType.connectionFailed,
                  message: t.companionRemote.pairing.sessionNotFound,
                ),
              );
            }
          }

          timer = Timer(trustTimeout, () {
            if (!trustDone.isCompleted) {
              trustDone.completeError(
                RemotePeerError(type: RemotePeerErrorType.timeout, message: t.companionRemote.pairing.trustTimedOut),
              );
            }
          });
          lan.addListener(onLanChanged);
          try {
            await Future.any([trustDone.future, cancelCompleter.future]);
            if (cancelCompleter.isCompleted || isDisposed) {
              throw const CompanionRemoteTrustCancelledException();
            }
          } finally {
            lan.removeListener(onLanChanged);
            timer.cancel();
          }
        }
      } finally {
        if (identical(_pendingTrustCancel, cancelCompleter)) {
          _pendingTrustCancel = null;
        }
      }
    }

    if (isDisposed) return;

    // Rebuild crypto contexts so `lan:<peer.deviceId>` is present before connecting.
    await _serializeLifecycle(
      () => _ensureCryptoReadyLocked(
        null,
        connections: _boundConnections,
        activeProfile: _boundActiveProfile,
        profileConnections: _boundProfileConnections,
        plexHomeForConnection: _boundPlexHome?.materializePlexHomeForConnection,
        lan: lan,
        identityStore: _boundLanIdentity,
      ),
    );
    if (isDisposed) return;

    final ctx = _authContexts.where((c) => c.connectionId == 'lan:${peer.deviceId}').firstOrNull;
    if (ctx == null) {
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.authFailed);
    }

    final liveDiscovered = lan.discoveredPeers.where((p) => p.deviceId == peer.deviceId).firstOrNull;
    final liveTrusted = lan.trustedPeers.where((t) => t.deviceId == peer.deviceId).firstOrNull;
    final targetHost = liveDiscovered?.host ?? liveTrusted?.lastHost ?? peer.host;
    final liveDiscoveredPort = liveDiscovered?.remotePort;
    final liveTrustedPort = liveTrusted?.lastRemotePort;
    final targetPort = (liveDiscoveredPort != null && liveDiscoveredPort > 0)
        ? liveDiscoveredPort
        : ((liveTrustedPort != null && liveTrustedPort > 0) ? liveTrustedPort : initialRemotePort);

    final discoveredHost = DiscoveredHost(
      authContextId: ctx.id,
      clientId: peer.deviceId,
      name: liveDiscovered?.deviceName ?? peer.deviceName,
      platform: liveDiscovered?.platform ?? peer.platform,
      port: targetPort,
      ips: [targetHost],
    );

    // Retry briefly on authFailed in case the host's async HKDF update is still committing.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await connectToDiscoveredHost(discoveredHost);
        return;
      } on PeerError catch (e) {
        if (e.type != PeerErrorType.authFailed || attempt == 2 || isDisposed) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// Stop listening for host beacons.
  void stopDiscovery() {
    unawaited(_passiveDiscoverySub?.cancel());
    _passiveDiscoverySub = null;
    _beaconHosts = const [];
    _discoveryService?.stopListening();
  }

  /// Connect to a discovered host as a remote client.
  Future<void> connectToDiscoveredHost(DiscoveredHost host) async {
    if (!isCryptoReady) {
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.cryptoInitFailed);
    }
    if (isConnectedToHost(host)) return;
    if (isConnectingToHost(host)) {
      await _inFlightHostConnect!;
      return;
    }

    final resolvedHost = _resolveLatestDiscoveredHost(host);
    final authContext = _authContextForId(resolvedHost.authContextId);
    if (authContext == null) {
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.authFailed);
    }

    final request = _beginRemoteConnectRequest();
    late final Future<void> connectFuture;
    connectFuture = () async {
      if (!await _prepareRemoteConnect(request)) return;

      final generation = request.generation;
      _lastHostAddresses = resolvedHost.addresses;
      _lastHostClientId = resolvedHost.clientId;
      _lastAuthContextId = authContext.id;

      appLogger.d('CompanionRemote: Connecting to ${resolvedHost.name} at ${resolvedHost.addresses}');

      String? winner;
      final connected = await _runRemoteConnect(
        generation: generation,
        seedConnectingSession: true,
        rethrowOnFailure: true,
        join: (peer) async {
          winner = await peer.joinSessionRacingWithContexts(
            _deviceName,
            _platform,
            resolvedHost.addresses,
            _authContexts,
            authContextId: authContext.id,
            expectedHostClientId: resolvedHost.clientId,
          );
        },
        onConnected: (peer) {
          _lastHostAddresses = [winner!];
          _lastAuthContextId = peer.selectedAuthContextId ?? authContext.id;
          _lastHostClientId = peer.selectedHostClientId ?? resolvedHost.clientId;
          _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.connected);
        },
        failureLog: 'CompanionRemote: Failed to connect to host',
        onFailure: _failRemoteConnectSession,
      );
      if (connected) {
        appLogger.d('CompanionRemote: Connected to ${resolvedHost.name} via $winner');
      }
    }();

    _inFlightHostConnect = connectFuture;
    _inFlightHostGeneration = request.generation;
    _inFlightHostClientId = resolvedHost.clientId;
    _inFlightAuthContextId = authContext.id;
    try {
      await connectFuture;
    } finally {
      if (identical(_inFlightHostConnect, connectFuture)) {
        _inFlightHostConnect = null;
        _inFlightHostGeneration = null;
        _inFlightHostClientId = null;
        _inFlightAuthContextId = null;
      }
    }
  }

  /// Connect to a host by manual IP:port entry.
  Future<void> connectToManualHost(String hostAddress) async {
    if (!isCryptoReady) {
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.cryptoInitFailed);
    }

    if (_authContexts.isEmpty && _lanStandbyReady) {
      final targetIp = hostAddress.split(':').first.trim();
      final matched = untrustedLanRemotePeers.where((p) {
        final full = '${p.host}:${p.remotePort}';
        return full == hostAddress || p.host == targetIp;
      }).firstOrNull;
      if (matched != null) {
        await trustAndConnectLanPeer(matched);
        return;
      }
      throw RemotePeerError(type: RemotePeerErrorType.authFailed, message: t.companionRemote.pairing.authFailed);
    }

    final request = _beginRemoteConnectRequest();
    if (!await _prepareRemoteConnect(request)) return;

    final generation = request.generation;
    _lastHostAddresses = [hostAddress];
    _lastHostClientId = '';
    _lastAuthContextId = null;

    appLogger.d('CompanionRemote: Connecting to manual host $hostAddress');

    await _runRemoteConnect(
      generation: generation,
      seedConnectingSession: true,
      rethrowOnFailure: true,
      join: (peer) => peer.joinSessionWithContexts(_deviceName, _platform, hostAddress, _authContexts),
      onConnected: (peer) {
        _lastAuthContextId = peer.selectedAuthContextId;
        _lastHostClientId = peer.selectedHostClientId ?? '';
        _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.connected);
      },
      failureLog: 'CompanionRemote: Failed to connect to manual host',
      onFailure: _failRemoteConnectSession,
    );
  }

  void _failRemoteConnectSession(Object error) {
    _remoteSession = _remoteSession?.copyWith(
      status: RemoteSessionStatus.error,
      errorMessage: _localizedRemoteError(
        error,
        (details) => t.companionRemote.pairing.failedToConnect(error: details),
      ),
    );
    safeNotifyListeners();
  }

  /// Runs the candidate-peer connect lifecycle shared by the discovered/manual
  /// connect paths and by reconnect attempts: create a candidate, wire its
  /// listeners, then promote it to [_remotePeerService] or dispose it. The
  /// generation guards live here so a candidate that lost ownership while
  /// joining is disposed rather than promoted, in exactly one place. Returns
  /// true only when the candidate was promoted.
  ///
  /// [isReconnectAttempt] carries the attempt's own intent: a failed reconnect
  /// reschedules from this captured flag (plus the generation guard) rather
  /// than from `_remoteSession.status`, which the candidate's mirrored
  /// status/error emissions can overwrite while the join is in flight.
  Future<bool> _runRemoteConnect({
    required int generation,
    required Future<void> Function(CompanionRemotePeerService peer) join,
    required void Function(CompanionRemotePeerService peer) onConnected,
    required String failureLog,
    void Function(Object error)? onFailure,
    bool seedConnectingSession = false,
    bool rethrowOnFailure = false,
    bool isReconnectAttempt = false,
  }) async {
    final candidate = _peerServiceFactory();
    _pendingRemotePeer = candidate;
    if (seedConnectingSession) {
      _remoteSession = RemoteSession(
        role: RemoteSessionRole.remote,
        status: RemoteSessionStatus.connecting,
        createdAt: DateTime.now(),
      );
    }
    _setupRemotePeerServiceListeners(candidate, generation);
    if (seedConnectingSession) safeNotifyListeners();

    try {
      await join(candidate);
      if (!_ownsRemotePeer(candidate, generation)) {
        await _disposePeer(candidate);
        return false;
      }

      _pendingRemotePeer = null;
      _remotePeerService = candidate;
      onConnected(candidate);
      safeNotifyListeners();
      return true;
    } catch (error, stackTrace) {
      if (!_ownsRemotePeer(candidate, generation)) {
        await _disposePeer(candidate);
        return false;
      }

      _pendingRemotePeer = null;
      _cleanupRemoteSubscriptions();
      await _disposePeer(candidate);
      appLogger.e(failureLog, error: error, stackTrace: stackTrace);
      onFailure?.call(error);
      if (isReconnectAttempt && generation == _remoteGeneration) {
        _scheduleReconnect(generation);
      }
      if (rethrowOnFailure) rethrow;
      return false;
    }
  }

  void _setupHostPeerServiceListeners(CompanionRemotePeerService peer, int hostGeneration) {
    _cleanupHostSubscriptions();
    _hostCommandSubscription = peer.onCommandReceived.listen(
      (command) {
        if (!_ownsHostPeer(peer, hostGeneration)) return;
        appLogger.d('CompanionRemote: Host command received: ${command.type}');

        if (command.type == RemoteCommandType.deviceInfo) {
          _handleHostDeviceInfo(command);
        } else if (command.type == RemoteCommandType.requestState) {
          peer.sendCommand(
            RemoteCommand(
              type: RemoteCommandType.syncState,
              data: {
                'playerActive': _hostPlayerActive,
                if (_hasHostPlayerSnapshot) 'snapshot': _hostPlayerSnapshot.toJson(),
              },
            ),
          );
        } else if (command.type == RemoteCommandType.playMedia) {
          if (command.data != null) {
            unawaited(_handlePlayMediaRequest(RemoteMediaTarget.fromJson(command.data!)));
          }
        } else if (command.type == RemoteCommandType.searchHostCatalog ||
            command.type == RemoteCommandType.browseHostHome ||
            command.type == RemoteCommandType.browseHostItemChildren) {
          unawaited(_handleHostCatalogCommand(peer, hostGeneration, command));
        } else if (command.type != RemoteCommandType.ping &&
            command.type != RemoteCommandType.pong &&
            command.type != RemoteCommandType.ack &&
            command.type != RemoteCommandType.syncState &&
            command.type != RemoteCommandType.hostCatalogSearchResult &&
            command.type != RemoteCommandType.hostHomeResult &&
            command.type != RemoteCommandType.hostItemChildrenResult) {
          onCommandReceived?.call(command);
        }
      },
      onError: (Object error) {
        if (!_ownsHostPeer(peer, hostGeneration)) return;
        appLogger.e('CompanionRemote: Host stream error', error: error);
      },
    );

    _hostDeviceConnectedSubscription = peer.onDeviceConnected.listen((device) {
      if (!_ownsHostPeer(peer, hostGeneration)) return;
      appLogger.d('CompanionRemote: Remote client connected to host: ${device.name}');
      _hostConnectedDevice = device;
      _hostSession = _hostSession?.copyWith(status: RemoteSessionStatus.connected, connectedDevice: device);
      safeNotifyListeners();
      peer.sendCommand(
        RemoteCommand(
          type: RemoteCommandType.syncState,
          data: {
            'playerActive': _hostPlayerActive,
            if (_hasHostPlayerSnapshot) 'snapshot': _hostPlayerSnapshot.toJson(),
          },
        ),
      );
    });

    _hostDeviceDisconnectedSubscription = peer.onDeviceDisconnected.listen((_) {
      if (!_ownsHostPeer(peer, hostGeneration)) return;
      appLogger.d('CompanionRemote: Remote client disconnected from host');
      _hostConnectedDevice = null;
      _hostSession = _hostSession?.copyWith(
        status: RemoteSessionStatus.connected,
        connectedDevice: null,
        errorMessage: null,
      );
      safeNotifyListeners();
    });

    _hostErrorSubscription = peer.onError.listen((error) {
      if (!_ownsHostPeer(peer, hostGeneration)) return;
      appLogger.e('CompanionRemote: Host error: ${error.message}');
      if (!peer.isServerRunning) {
        _hostSession = _hostSession?.copyWith(status: RemoteSessionStatus.error, errorMessage: error.message);
        safeNotifyListeners();
      }
    });

    _hostStatusSubscription = peer.onConnectionStateChanged.listen((status) {
      if (!_ownsHostPeer(peer, hostGeneration)) return;
      appLogger.d('CompanionRemote: Host status event: $status');
      if (status == RemoteSessionStatus.error) {
        _hostSession = _hostSession?.copyWith(status: status);
        safeNotifyListeners();
      }
    });
  }

  void _setupRemotePeerServiceListeners(CompanionRemotePeerService peer, int generation) {
    // Only one outbound peer owns the remote listener set at a time. The
    // identity and generation checks also reject events already queued when
    // teardown synchronously cancels these subscriptions.
    _cleanupRemoteSubscriptions();
    _remoteCommandSubscription = peer.onCommandReceived.listen(
      (command) {
        if (!_ownsRemotePeer(peer, generation)) return;
        appLogger.d('CompanionRemote: Remote command received: ${command.type}');

        if (command.type == RemoteCommandType.deviceInfo) {
          _handleRemoteDeviceInfo(command);
        } else if (command.type == RemoteCommandType.syncState) {
          _handleSyncState(command);
        } else if (command.type == RemoteCommandType.hostCatalogSearchResult ||
            command.type == RemoteCommandType.hostHomeResult ||
            command.type == RemoteCommandType.hostItemChildrenResult) {
          _handleCatalogResponse(command);
        }
      },
      onError: (Object error) {
        if (!_ownsRemotePeer(peer, generation)) return;
        appLogger.e('CompanionRemote: Remote stream error', error: error);
      },
    );

    _remoteDeviceConnectedSubscription = peer.onDeviceConnected.listen((device) {
      if (!_ownsRemotePeer(peer, generation)) return;
      appLogger.d('CompanionRemote: Connected to host device: ${device.name}');
      _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.connected, connectedDevice: device);
      safeNotifyListeners();
      peer.sendCommand(const RemoteCommand(type: RemoteCommandType.requestState));
    });

    _remoteDeviceDisconnectedSubscription = peer.onDeviceDisconnected.listen((_) {
      if (!_ownsRemotePeer(peer, generation)) return;
      final intentional = _isIntentionalDisconnect(peer, generation);
      appLogger.d('CompanionRemote: Remote disconnected (intentional: $intentional)');
      if (intentional) {
        _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.disconnected, connectedDevice: null);
        safeNotifyListeners();
      } else {
        _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.reconnecting);
        safeNotifyListeners();
        _scheduleReconnect(generation);
      }
    });

    _remoteErrorSubscription = peer.onError.listen((error) {
      if (!_ownsRemotePeer(peer, generation)) return;
      appLogger.e('CompanionRemote: Remote error: ${error.message}');
      if (_remoteSession?.status == RemoteSessionStatus.reconnecting) {
        // An active reconnect cycle owns the session: attempt failures surface
        // through the join future and are rescheduled there. A stale error
        // from the dying socket must not end the cycle.
        return;
      }
      _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.error, errorMessage: error.message);
      safeNotifyListeners();
    });

    _remoteStatusSubscription = peer.onConnectionStateChanged.listen((status) {
      if (!_ownsRemotePeer(peer, generation)) return;
      appLogger.d('CompanionRemote: Remote status changed: $status');
      if (_remoteSession?.status == RemoteSessionStatus.reconnecting && status != RemoteSessionStatus.connected) {
        // The peer emits a disconnected status right after deviceDisconnected
        // (and candidates emit connecting/error while a retry is joining);
        // none of those may knock the session out of an active reconnect
        // cycle — only a successful connection ends it.
        return;
      }
      _remoteSession = _remoteSession?.copyWith(status: status);
      safeNotifyListeners();
    });
  }

  RemoteDevice? _parseDeviceInfo(RemoteCommand command) {
    final data = command.data;
    if (data == null) return null;
    final id = data['id'] as String? ?? 'unknown';
    final name = data['name'] as String? ?? t.companionRemote.unknownDevice;
    final platform = data['platform'] as String? ?? 'unknown';
    final role = data['role'] as String?;

    appLogger.d('CompanionRemote: Device info - name: $name, platform: $platform, role: $role');
    return RemoteDevice(id: id, name: name, platform: platform, connectedAt: DateTime.now());
  }

  void _handleHostDeviceInfo(RemoteCommand command) {
    final device = _parseDeviceInfo(command);
    if (device == null) return;
    _hostConnectedDevice = device;
    _hostSession = _hostSession?.copyWith(connectedDevice: device);
    safeNotifyListeners();
  }

  void _handleRemoteDeviceInfo(RemoteCommand command) {
    final device = _parseDeviceInfo(command);
    if (device == null) return;
    _remoteSession = _remoteSession?.copyWith(connectedDevice: device);
    safeNotifyListeners();
  }

  void _handleSyncState(RemoteCommand command) {
    final playerActive = command.data?['playerActive'] as bool? ?? false;
    final rawSnapshot = command.data?['snapshot'];
    if (rawSnapshot is Map) {
      _remotePlayerSnapshot = RemotePlayerSnapshot.fromJson(Map<String, dynamic>.from(rawSnapshot));
      if (_lastHostClientId != null && _lastAuthContextId != null) {
        _deviceSnapshots['${_lastAuthContextId!}:${_lastHostClientId!}'] = _remotePlayerSnapshot;
      }
    } else {
      _remotePlayerSnapshot = playerActive ? _remotePlayerSnapshot.copyWith(active: true) : RemotePlayerSnapshot.idle;
    }
    _isPlayerActive = playerActive || _remotePlayerSnapshot.active;
    safeNotifyListeners();
  }

  Future<void> _handlePlayMediaRequest(RemoteMediaTarget target) async {
    if (_remoteSession != null) {
      unawaited(leaveSession());
    }
    updateHostPlayerSnapshot(
      RemotePlayerSnapshot(
        active: true,
        stage: 'opening',
        mediaKind: target.kind,
        title: target.title,
        seriesTitle: target.seriesTitle,
        seasonNumber: target.seasonNumber,
        episodeNumber: target.episodeNumber,
        posterUrl: target.posterUrl,
        positionMs: target.positionMs ?? 0,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final ok = await (onPlayMediaRequested?.call(target) ?? Future.value(false));
    if (!ok && !isDisposed) {
      updateHostPlayerSnapshot(
        RemotePlayerSnapshot(
          active: false,
          stage: 'error',
          errorMessage: t.companionRemote.mediaNotFoundOnDevice,
          mediaKind: target.kind,
          title: target.title,
          seriesTitle: target.seriesTitle,
          seasonNumber: target.seasonNumber,
          episodeNumber: target.episodeNumber,
          posterUrl: target.posterUrl,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  void _failPendingCatalogRequests(String reason) {
    if (_pendingCatalogRequests.isEmpty) return;
    final pending = Map<String, Completer<Map<String, dynamic>>>.of(_pendingCatalogRequests);
    _pendingCatalogRequests.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(reason));
      }
    }
  }

  void _handleCatalogResponse(RemoteCommand command) {
    final data = command.data;
    if (data == null) return;
    final requestId = data['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return;
    final completer = _pendingCatalogRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(Map<String, dynamic>.from(data));
    }
  }

  Future<void> _handleHostCatalogCommand(
    CompanionRemotePeerService peer,
    int hostGeneration,
    RemoteCommand command,
  ) async {
    final data = command.data ?? const <String, dynamic>{};
    final requestId = data['requestId'] as String?;

    late final RemoteCommandType responseType;
    late final Map<String, dynamic> payload;

    switch (command.type) {
      case RemoteCommandType.searchHostCatalog:
        responseType = RemoteCommandType.hostCatalogSearchResult;
        final query = data['query'] as String? ?? '';
        final limit = (data['limit'] as num?)?.toInt() ?? 40;
        final handler = onSearchHostCatalog;
        if (handler == null) {
          payload = RemoteHostSearchResponse(query: query, error: 'Host catalog unavailable').toJson();
        } else {
          try {
            payload = (await handler(query, limit)).toJson();
          } catch (e) {
            payload = RemoteHostSearchResponse(query: query, error: '$e').toJson();
          }
        }
      case RemoteCommandType.browseHostHome:
        responseType = RemoteCommandType.hostHomeResult;
        final handler = onBrowseHostHome;
        if (handler == null) {
          payload = const RemoteHostHomeResponse(error: 'Host catalog unavailable').toJson();
        } else {
          try {
            payload = (await handler()).toJson();
          } catch (e) {
            payload = RemoteHostHomeResponse(error: '$e').toJson();
          }
        }
      case RemoteCommandType.browseHostItemChildren:
        responseType = RemoteCommandType.hostItemChildrenResult;
        final serverId = data['serverId'] as String? ?? '';
        final itemId = data['itemId'] as String? ?? '';
        final kind = data['kind'] as String?;
        final handler = onBrowseHostItemChildren;
        if (handler == null) {
          payload = RemoteHostChildrenResponse(
            serverId: serverId,
            itemId: itemId,
            error: 'Host catalog unavailable',
          ).toJson();
        } else {
          try {
            payload = (await handler(serverId, itemId, kind)).toJson();
          } catch (e) {
            payload = RemoteHostChildrenResponse(serverId: serverId, itemId: itemId, error: '$e').toJson();
          }
        }
      default:
        return;
    }

    if (!_ownsHostPeer(peer, hostGeneration) || isDisposed) return;
    peer.sendCommand(
      RemoteCommand(
        type: responseType,
        data: {if (requestId != null && requestId.isNotEmpty) 'requestId': requestId, ...payload},
      ),
    );
  }

  Future<Map<String, dynamic>> _sendCatalogRequest(
    RemoteCommandType type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final peer = _remotePeerService;
    if (peer == null || !isConnected) {
      throw StateError('CompanionRemote: Not connected to host');
    }
    final requestId = 'req_${++_catalogRequestSeq}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCatalogRequests[requestId] = completer;
    try {
      peer.sendCommand(RemoteCommand(type: type, data: {'requestId': requestId, ...payload}));
      return await completer.future.timeout(timeout);
    } finally {
      _pendingCatalogRequests.remove(requestId);
    }
  }

  Future<RemoteHostSearchResponse> searchHostCatalog(
    String query, {
    int limit = 40,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const RemoteHostSearchResponse(query: '', items: []);
    }
    final data = await _sendCatalogRequest(
      RemoteCommandType.searchHostCatalog,
      {'query': trimmed, 'limit': limit},
      timeout: timeout,
    );
    return RemoteHostSearchResponse.fromJson(data);
  }

  Future<RemoteHostHomeResponse> fetchHostHome({Duration timeout = const Duration(seconds: 10)}) async {
    final data = await _sendCatalogRequest(RemoteCommandType.browseHostHome, const {}, timeout: timeout);
    return RemoteHostHomeResponse.fromJson(data);
  }

  Future<RemoteHostChildrenResponse> fetchHostItemChildren({
    required String serverId,
    required String itemId,
    String? kind,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final data = await _sendCatalogRequest(
      RemoteCommandType.browseHostItemChildren,
      {'serverId': serverId, 'itemId': itemId, 'kind': ?kind},
      timeout: timeout,
    );
    return RemoteHostChildrenResponse.fromJson(data);
  }

  void playHostCatalogItem(RemoteCatalogItem item) {
    if (_remotePeerService == null || !isConnected) {
      appLogger.w('CompanionRemote: Cannot play catalog item - not connected');
      return;
    }
    _remotePlayerSnapshot = RemotePlayerSnapshot(
      active: true,
      stage: 'opening',
      mediaKind: item.kind,
      title: item.title,
      seriesTitle: item.seriesTitle,
      seasonNumber: item.seasonNumber,
      episodeNumber: item.episodeNumber,
      posterUrl: item.thumbUrl,
      positionMs: item.viewOffsetMs ?? 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _isPlayerActive = true;
    safeNotifyListeners();
    sendCommand(RemoteCommandType.playMedia, data: item.toRemoteMediaTarget().toJson());
  }

  void _cleanupRemoteSubscriptions() {
    _failPendingCatalogRequests('Remote session disconnected');
    _remoteCommandSubscription?.cancel();
    _remoteCommandSubscription = null;
    _remoteDeviceConnectedSubscription?.cancel();
    _remoteDeviceConnectedSubscription = null;
    _remoteDeviceDisconnectedSubscription?.cancel();
    _remoteDeviceDisconnectedSubscription = null;
    _remoteErrorSubscription?.cancel();
    _remoteErrorSubscription = null;
    _remoteStatusSubscription?.cancel();
    _remoteStatusSubscription = null;
  }

  void _cleanupHostSubscriptions() {
    _hostCommandSubscription?.cancel();
    _hostCommandSubscription = null;
    _hostDeviceConnectedSubscription?.cancel();
    _hostDeviceConnectedSubscription = null;
    _hostDeviceDisconnectedSubscription?.cancel();
    _hostDeviceDisconnectedSubscription = null;
    _hostErrorSubscription?.cancel();
    _hostErrorSubscription = null;
    _hostStatusSubscription?.cancel();
    _hostStatusSubscription = null;
  }

  /// Updates the rich playback snapshot advertised by this host over both
  /// WebSocket `syncState` and authenticated HTTP `/status`.
  void updateHostPlayerSnapshot(RemotePlayerSnapshot snapshot) {
    _hostPlayerSnapshot = snapshot;
    _hasHostPlayerSnapshot = snapshot.active;
    _hostPlayerActive = snapshot.active;
    final hostPeer = _hostPeerService;
    if (hostPeer == null || (_hostConnectedDevice == null && !hostPeer.isConnected)) return;
    hostPeer.sendCommand(
      RemoteCommand(
        type: RemoteCommandType.syncState,
        data: {'playerActive': snapshot.active, 'snapshot': snapshot.toJson()},
      ),
    );
  }

  /// Advertise whether this device's video player is up to the connected
  /// remote, and remember it for a remote that connects later.
  void setHostPlayerActive(bool active) {
    _hostPlayerActive = active;
    if (!active && _hostPlayerSnapshot.active) {
      _hostPlayerSnapshot = RemotePlayerSnapshot.idle;
      _hasHostPlayerSnapshot = false;
    }
    final hostPeer = _hostPeerService;
    if (hostPeer == null || (_hostConnectedDevice == null && !hostPeer.isConnected)) return;
    hostPeer.sendCommand(
      RemoteCommand(
        type: RemoteCommandType.syncState,
        data: {'playerActive': active, if (_hasHostPlayerSnapshot) 'snapshot': _hostPlayerSnapshot.toJson()},
      ),
    );
  }

  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) {
    if (_remotePeerService == null || !isConnected) {
      appLogger.w('CompanionRemote: Cannot send command - not connected');
      return;
    }

    appLogger.d('CompanionRemote: Sending command $type');
    _remotePeerService!.sendCommand(RemoteCommand(type: type, data: data));
  }

  void _scheduleReconnect(int generation) {
    if (generation != _remoteGeneration || isDisposed) return;
    if (_appBackgrounded) {
      // Hold the cycle instead of burning the bounded budget on retries that
      // are guaranteed to fail against restricted background networking;
      // resume retries immediately.
      _resumeReconnectPending = true;
      _resumeReconnectGeneration = generation;
      return;
    }
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      appLogger.w('CompanionRemote: Max reconnect attempts reached');
      _remoteSession = _remoteSession?.copyWith(
        status: RemoteSessionStatus.error,
        errorMessage: t.companionRemote.errors.connectionLostAfterAttempts(attempts: _maxReconnectAttempts),
      );
      _reconnectAttempts = 0;
      safeNotifyListeners();
      return;
    }

    final delay = Duration(seconds: 1 << _reconnectAttempts);
    _reconnectAttempts++;
    appLogger.d('CompanionRemote: Reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (generation != _remoteGeneration || isDisposed) return;
      unawaited(_attemptReconnect());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _appBackgrounded = true;
        _pauseReconnectBackoff();
      case AppLifecycleState.resumed:
        _appBackgrounded = false;
        _handleAppResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Stop the backoff clock while backgrounded; [_handleAppResumed] restarts
  /// the cycle the moment the app is visible again.
  void _pauseReconnectBackoff() {
    final timer = _reconnectTimer;
    if (timer == null) return;
    timer.cancel();
    _reconnectTimer = null;
    _resumeReconnectPending = true;
    _resumeReconnectGeneration = _remoteGeneration;
  }

  void _handleAppResumed() {
    if (isDisposed) return;
    if (_resumeReconnectPending) {
      _resumeReconnectPending = false;
      if (_resumeReconnectGeneration == _remoteGeneration &&
          _remoteSession?.status == RemoteSessionStatus.reconnecting) {
        // Fresh budget: failures accumulated around backgrounding say nothing
        // about reachability now that the network is back.
        unawaited(retryReconnectNow());
      }
      return;
    }
    // A remote session that slept through a socket death still looks
    // connected. A ping forces the dead socket to fail now, feeding the
    // normal disconnect → reconnect path instead of waiting for user input
    // to bounce.
    if (isConnected) {
      _remotePeerService?.sendPing();
    }
  }

  Future<void> _attemptReconnect() {
    final generation = _remoteGeneration;
    final active = _activeReconnect;
    if (active != null && _activeReconnectGeneration == generation) {
      return active;
    }

    late final Future<void> attempt;
    attempt = _runReconnectAttempt(generation).whenComplete(() {
      if (identical(_activeReconnect, attempt)) {
        _activeReconnect = null;
        _activeReconnectGeneration = null;
      }
    });
    _activeReconnect = attempt;
    _activeReconnectGeneration = generation;
    return attempt;
  }

  Future<void> _runReconnectAttempt(int generation) async {
    if (generation != _remoteGeneration || isDisposed) return;
    final hostAddresses = _lastHostAddresses;
    if (hostAddresses == null || !isCryptoReady) {
      appLogger.w('CompanionRemote: No stored context for reconnect');
      _remoteSession = _remoteSession?.copyWith(
        status: RemoteSessionStatus.error,
        errorMessage: t.companionRemote.errors.connectionLost,
      );
      safeNotifyListeners();
      return;
    }

    appLogger.d('CompanionRemote: Attempting reconnect...');
    final oldPeer = _remotePeerService;
    _remotePeerService = null;
    _cleanupRemoteSubscriptions();
    if (oldPeer != null) {
      await _disposePeer(oldPeer);
    }
    if (generation != _remoteGeneration || isDisposed) return;

    final authContextId = _authContextForId(_lastAuthContextId)?.id;
    final expectedHostClientId = _lastHostClientId ?? '';

    final reconnected = await _runRemoteConnect(
      generation: generation,
      join: (peer) => peer.joinSessionWithContexts(
        _deviceName,
        _platform,
        hostAddresses.first,
        _authContexts,
        authContextId: authContextId,
        expectedHostClientId: expectedHostClientId,
      ),
      onConnected: (peer) {
        _lastAuthContextId = peer.selectedAuthContextId ?? authContextId;
        _lastHostClientId = peer.selectedHostClientId ?? _lastHostClientId;
        _remoteSession = _remoteSession?.copyWith(status: RemoteSessionStatus.connected, errorMessage: null);
        _reconnectAttempts = 0;
      },
      failureLog: 'CompanionRemote: Reconnect failed',
      // Reschedule from the attempt's own intent, not from `_remoteSession.status`:
      // the candidate's status/error emissions overwrite `reconnecting` while
      // the join is in flight, which used to end the cycle after one failure.
      isReconnectAttempt: true,
    );
    if (reconnected) {
      appLogger.d('CompanionRemote: Reconnected successfully');
    }
  }

  Future<void> retryReconnectNow() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    return _attemptReconnect();
  }

  Future<void> cancelReconnect() async {
    final detachedPeers = _invalidateRemoteLifecycle();
    final cancelGeneration = _remoteGeneration;
    _reconnectAttempts = 0;
    _remoteSession = null;
    _isPlayerActive = false;
    _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
    safeNotifyListeners();
    await _disposeDetachedPeers(detachedPeers);
    if (!isDisposed &&
        cancelGeneration == _remoteGeneration &&
        _passiveDiscoveryRequested &&
        _passiveDiscoverySub == null &&
        _authContexts.isNotEmpty) {
      startPassiveDiscovery();
    }
  }

  Future<void> leaveSession() async {
    _failPendingCatalogRequests('Left remote session');
    final leavingGeneration = _remoteGeneration;
    _markIntentionalDisconnect(_remotePeerService, leavingGeneration);
    _markIntentionalDisconnect(_pendingRemotePeer, leavingGeneration);
    final detachedPeers = _invalidateRemoteLifecycle();
    final nextGeneration = _remoteGeneration;
    _reconnectAttempts = 0;
    _remoteSession = null;
    _isPlayerActive = false;
    _remotePlayerSnapshot = RemotePlayerSnapshot.idle;
    safeNotifyListeners();

    await _disposeDetachedPeers(detachedPeers);
    if (!isDisposed &&
        nextGeneration == _remoteGeneration &&
        _passiveDiscoveryRequested &&
        _passiveDiscoverySub == null &&
        _authContexts.isNotEmpty) {
      startPassiveDiscovery();
    }
  }

  @override
  void dispose() {
    _failPendingCatalogRequests('CompanionRemoteProvider disposed');
    WidgetsBinding.instance.removeObserver(this);
    _remoteGeneration++;
    _hostGeneration++;
    _passiveDiscoveryRequested = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    cancelPendingTrust();
    if (_hostServerPort != null) {
      _boundLan?.setAdvertisedRemotePort(null);
      _hostServerPort = null;
    }
    _boundLan?.removeListener(_onBoundLanChanged);
    final currentRemote = _remotePeerService;
    final pendingRemote = _pendingRemotePeer;
    final currentHost = _hostPeerService;
    _remotePeerService = null;
    _pendingRemotePeer = null;
    _hostPeerService = null;
    _cleanupRemoteSubscriptions();
    _cleanupHostSubscriptions();

    _boundActiveProfile?.removeListener(_scheduleAuthContextRefresh);
    for (final sub in _profileServiceSubs) {
      sub.cancel();
    }
    _profileServiceSubs.clear();
    _discoveryService?.dispose();
    unawaited(_passiveDiscoverySub?.cancel());
    _passiveDiscoverySub = null;
    unawaited(_disposeDetachedPeers((current: currentRemote, pending: pendingRemote)));
    if (currentHost != null && !identical(currentHost, currentRemote) && !identical(currentHost, pendingRemote)) {
      unawaited(_disposePeer(currentHost));
    }
    RemoteAuthService.instance.clearCache();
    super.dispose();
  }
}

class _RemoteConnectRequest {
  const _RemoteConnectRequest({required this.generation, required this.current, required this.pending});

  final int generation;
  final CompanionRemotePeerService? current;
  final CompanionRemotePeerService? pending;
}
