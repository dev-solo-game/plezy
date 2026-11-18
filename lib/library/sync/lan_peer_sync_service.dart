import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/udp_broadcast_sockets.dart';
import 'deterministic_keys.dart';
import 'sync_crypto.dart';
import 'sync_local_store.dart';
import 'sync_mapper.dart';
import 'sync_models.dart';

class LanDiscoveredPeer {
  const LanDiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.host,
    required this.httpPort,
    required this.pubKeyBase64,
    required this.revision,
    required this.lastSeen,
    this.remotePort,
    this.syncEpoch,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String host;
  final int httpPort;
  final String pubKeyBase64;
  final int revision;
  final DateTime lastSeen;
  final int? remotePort;
  final String? syncEpoch;

  String pairingCodeFor(String myPubKeyBase64) => SyncCrypto.computePairingCode(myPubKeyBase64, pubKeyBase64);
}

class LanPairRequest {
  const LanPairRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.host,
    required this.httpPort,
    required this.pubKeyBase64,
    required this.pairingCode,
    required this.requestedAt,
    this.remotePort,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String host;
  final int httpPort;
  final String pubKeyBase64;
  final String pairingCode;
  final DateTime requestedAt;
  final int? remotePort;
}

/// Zero-server LAN P2P discovery, Trust-On-First-Use (TOFU) 4-digit pairing,
/// and E2EE catalog/progress synchronization over direct local HTTP.
class LanPeerSyncService extends ChangeNotifier {
  LanPeerSyncService({
    required this.syncStore,
    required this.mapper,
    this.onLibraryChanged,
    this.discoveryPort = defaultDiscoveryPort,
    this.enableUdpBroadcast = true,
  });

  static const int defaultDiscoveryPort = 48635;
  static const int defaultPullLimit = 500;
  static const Duration _broadcastInterval = Duration(seconds: 3);
  static const Duration _peerStaleTimeout = Duration(seconds: 15);
  static const Duration _hmacWindow = Duration(minutes: 5);
  static const Duration liveRefreshInterval = Duration(milliseconds: 1200);

  final SyncLocalStore syncStore;
  final SyncMapper mapper;
  final VoidCallback? onLibraryChanged;
  final int discoveryPort;
  final bool enableUdpBroadcast;

  HttpServer? _httpServer;
  http.Client? _httpClient;
  RawDatagramSocket? _udpListener;
  UdpBroadcastSocketSet? _udpBroadcaster;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;

  String? _deviceId;
  String? _deviceName;
  String? _privKeyB64;
  String? _pubKeyB64;
  String? _syncEpoch;
  int _cachedLocalRev = 0;

  @visibleForTesting
  int syncPageLimit = defaultPullLimit;

  @visibleForTesting
  FutureOr<void> Function(int pageIndex, int nextSeq)? debugOnPullPageCommitted;

  /// Count of network pull/push HTTP requests issued during [syncWithPeer], exposed for tests.
  @visibleForTesting
  int debugSyncHttpRequestCount = 0;

  final Map<String, LanDiscoveredPeer> _discovered = {};
  final Map<String, LanPairRequest> _incomingRequests = {};
  final Map<String, LanDiscoveredPeer> _outgoingPairTargets = {};
  final Map<String, Future<void>> _activePeerSyncs = {};
  final Map<String, DateTime> _dismissedIncomingRequestAt = {};
  Set<String> _promptedPeerIds = {};
  List<LanTrustedPeer> _trustedPeers = [];

  bool _running = false;
  bool _disposed = false;
  bool _syncing = false;
  int? _advertisedRemotePort;
  SyncProgress _progress = SyncProgress.idle;
  String? _lastError;

  bool get isRunning => _running;
  bool get isSyncing => _syncing || _activePeerSyncs.isNotEmpty || _progress.isActive;
  int? get advertisedRemotePort => _advertisedRemotePort;
  SyncProgress get progress => _progress;
  int? get listeningPort => _httpServer?.port;
  String? get publicKeyBase64 => _pubKeyB64;
  String? get deviceId => _deviceId;
  String? get lastError => _lastError;

  void setAdvertisedRemotePort(int? port) {
    final normalized = (port != null && port > 0) ? port : null;
    if (_advertisedRemotePort == normalized) return;
    _advertisedRemotePort = normalized;
    if (_running && !_disposed) {
      if (enableUdpBroadcast) {
        unawaited(_sendBeacon());
      }
      notifyListeners();
    }
  }

  void _setProgress(SyncProgress next) {
    if (_disposed || _progress == next) return;
    _progress = next;
    notifyListeners();
  }

  String get deviceName {
    final saved = _deviceName?.trim();
    if (isMeaningfulDeviceName(saved)) return saved!;
    try {
      final host = Platform.localHostname.trim();
      if (isMeaningfulDeviceName(host)) return host;
    } catch (_) {}
    return 'TTPlay';
  }

  /// Unicast-probes trusted peers with known host/HTTP ports over `/lan/v1/hello`
  /// so `remote_port` and device metadata refresh immediately even when UDP
  /// broadcasts are delayed or dropped (e.g., emulator NAT or recent host restarts).
  Future<void> probeTrustedPeers({Duration timeout = const Duration(milliseconds: 1200)}) async {
    final client = _httpClient;
    if (!_running || _disposed || client == null) return;
    final peers = List<LanTrustedPeer>.from(_trustedPeers);
    if (peers.isEmpty) return;

    await Future.wait([
      for (final trusted in peers)
        if (trusted.lastHost != null &&
            trusted.lastHost!.isNotEmpty &&
            trusted.lastPort != null &&
            trusted.lastPort! > 0)
          _probeSingleTrustedPeer(client, trusted, timeout),
    ]);
  }

  Future<void> _probeSingleTrustedPeer(http.Client client, LanTrustedPeer trusted, Duration timeout) async {
    final rawHost = trusted.lastHost!;
    final hostAuthority = (rawHost.contains(':') && !rawHost.startsWith('[')) ? '[$rawHost]' : rawHost;
    final uri = Uri.parse('http://$hostAuthority:${trusted.lastPort}/lan/v1/hello');
    try {
      final resp = await client.get(uri).timeout(timeout);
      if (!_running || _disposed || resp.statusCode != HttpStatus.ok) return;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return;
      final peerId = decoded['device_id'] as String?;
      final peerPub = decoded['pub_key'] as String?;
      if (peerId != trusted.deviceId || peerPub != trusted.pubKeyBase64) return;

      final rawRemotePort = (decoded['remote_port'] as num?)?.toInt();
      final remotePort = (rawRemotePort != null && rawRemotePort > 0) ? rawRemotePort : null;
      registerDiscoveredPeer(
        LanDiscoveredPeer(
          deviceId: peerId!,
          deviceName: decoded['device_name'] as String? ?? trusted.deviceName,
          platform: decoded['platform'] as String? ?? 'unknown',
          host: rawHost,
          httpPort: trusted.lastPort!,
          pubKeyBase64: peerPub!,
          revision: (decoded['revision'] as num?)?.toInt() ?? trusted.lastSyncedRevision,
          lastSeen: clock.now(),
          remotePort: remotePort,
          syncEpoch: decoded['sync_epoch'] as String?,
        ),
      );
    } catch (_) {
      // Best-effort probe; unreachable/offline peers are simply skipped.
    }
  }

  List<LanDiscoveredPeer> get discoveredPeers => List.unmodifiable(_discovered.values);
  List<LanPairRequest> get incomingPairRequests => List.unmodifiable(_incomingRequests.values);
  List<LanTrustedPeer> get trustedPeers => List.unmodifiable(_trustedPeers);
  Set<String> get promptedPeerIds => Set.unmodifiable(_promptedPeerIds);

  bool isPeerTrusted(String deviceId) => _trustedPeers.any((t) => t.deviceId == deviceId);

  bool shouldAutoPromptPeer(String deviceId) {
    return _running &&
        !_disposed &&
        deviceId.isNotEmpty &&
        deviceId != _deviceId &&
        !isPeerTrusted(deviceId) &&
        !_promptedPeerIds.contains(deviceId) &&
        !_outgoingPairTargets.containsKey(deviceId);
  }

  List<LanDiscoveredPeer> get unpromptedDiscoveredPeers => [
    for (final peer in _discovered.values)
      if (shouldAutoPromptPeer(peer.deviceId)) peer,
  ];

  List<LanPairRequest> get unpromptedIncomingRequests => [
    for (final req in _incomingRequests.values)
      if (!isPeerTrusted(req.deviceId) &&
          (_dismissedIncomingRequestAt[req.deviceId] == null ||
              req.requestedAt.isAfter(_dismissedIncomingRequestAt[req.deviceId]!)))
        req,
  ];

  Future<void> _recordPromptedPeer(String deviceId) async {
    if (deviceId.isEmpty) return;
    if (_promptedPeerIds.add(deviceId)) {
      await syncStore.savePromptedLanPeerIds(_promptedPeerIds);
    }
  }

  /// Persists that the one-time discovery popup has already been presented for [deviceId].
  Future<void> markPeerAutoPrompted(String deviceId) async {
    if (deviceId.isEmpty) return;
    if (_promptedPeerIds.add(deviceId)) {
      await syncStore.savePromptedLanPeerIds(_promptedPeerIds);
      if (!_disposed) notifyListeners();
    }
  }

  /// Suppresses re-popping the global modal for [req] while leaving [req] in
  /// [incomingPairRequests] so the user can still accept/reject it in LAN Devices.
  void dismissIncomingRequestPrompt(LanPairRequest req) {
    _dismissedIncomingRequestAt[req.deviceId] = req.requestedAt;
    if (!_disposed) notifyListeners();
  }

  Future<void> start({int bindHttpPort = 0, bool runTombstoneGc = true}) async {
    if (_running || _disposed) return;

    _deviceId = await syncStore.getOrCreateDeviceId();
    _syncEpoch = await syncStore.getOrCreateSyncEpoch();
    _cachedLocalRev = await syncStore.getLocalLanRevision();
    _deviceName = await syncStore.getDeviceName();
    final keyPair = await syncStore.getOrCreateLanKeyPair();
    _privKeyB64 = keyPair.privateKeyBase64;
    _pubKeyB64 = keyPair.publicKeyBase64;
    _trustedPeers = List<LanTrustedPeer>.from(await syncStore.loadTrustedLanPeers());
    _promptedPeerIds = Set<String>.from(await syncStore.loadPromptedLanPeerIds());
    var promptedDirty = false;
    for (final peer in _trustedPeers) {
      if (_promptedPeerIds.add(peer.deviceId)) {
        promptedDirty = true;
      }
    }
    if (promptedDirty) {
      await syncStore.savePromptedLanPeerIds(_promptedPeerIds);
    }

    if (runTombstoneGc) {
      // Prune tombstones older than 30 days and advance min_retained_seq.
      final gc = await syncStore.journal.pruneExpiredTombstones(nowMs: clock.now().millisecondsSinceEpoch);
      if (gc.maxPurgedSeq > 0) {
        final oldMin = await syncStore.getMinRetainedSeq();
        if (gc.maxPurgedSeq > oldMin) {
          await syncStore.saveMinRetainedSeq(gc.maxPurgedSeq);
        }
      }
    }

    _httpClient = http.Client();
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, bindHttpPort);
    _httpServer!.listen((req) => unawaited(_handleHttp(req)), onError: (Object e) {
      appLogger.w('[LanP2P] HTTP listener error', error: e);
    });

    _running = true;
    if (enableUdpBroadcast) {
      await _startUdpDiscovery();
    }

    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _udpSub?.cancel();
    _udpSub = null;
    _udpListener?.close();
    _udpListener = null;
    await _udpBroadcaster?.close();
    _udpBroadcaster = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
    _httpClient?.close();
    _httpClient = null;
    _discovered.clear();
    _incomingRequests.clear();
    _outgoingPairTargets.clear();
    _dismissedIncomingRequestAt.clear();
    if (!_disposed) notifyListeners();
  }

  Future<void> _startUdpDiscovery() async {
    try {
      _udpBroadcaster = await UdpBroadcastSockets.bind();
      _udpListener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      _udpListener!.broadcastEnabled = true;
      _udpSub = _udpListener!.listenDatagrams(_onUdpDatagram, debugLabel: 'LanP2P');

      unawaited(_sendBeacon());
      _broadcastTimer = Timer.periodic(_broadcastInterval, (_) => unawaited(_sendBeacon()));
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pruneStalePeers());
    } catch (e) {
      appLogger.d('[LanP2P] UDP discovery unavailable (port $discoveryPort)', error: e);
    }
  }

  Future<void> _sendBeacon() async {
    final sockSet = _udpBroadcaster;
    final port = _httpServer?.port;
    final devId = _deviceId;
    final pubKey = _pubKeyB64;
    if (!_running || sockSet == null || port == null || devId == null || pubKey == null) return;

    await mapper.ensureJournalUpToDate();
    if (!_running || _disposed) return;
    final rev = _cachedLocalRev = await syncStore.getLocalLanRevision();
    final epoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
    final payload = utf8.encode(
      jsonEncode({
        'type': 'plezy_lan_sync_v1',
        'device_id': devId,
        'device_name': deviceName,
        'platform': Platform.operatingSystem,
        'http_port': port,
        'pub_key': pubKey,
        'revision': rev,
        'sync_epoch': epoch,
        if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
      }),
    );
    sockSet.send(payload, UdpBroadcastSockets.limitedBroadcastAddress, discoveryPort);
  }

  void _onUdpDatagram(Datagram dg) {
    if (!_running || _disposed) return;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is! Map<String, dynamic> || decoded['type'] != 'plezy_lan_sync_v1') return;
      final peerId = decoded['device_id'] as String?;
      final peerPub = decoded['pub_key'] as String?;
      final port = (decoded['http_port'] as num?)?.toInt();
      if (peerId == null || peerId.isEmpty || peerId == _deviceId || peerPub == null || port == null || port <= 0) {
        return;
      }
      final rawRemotePort = (decoded['remote_port'] as num?)?.toInt();
      final remotePort = (rawRemotePort != null && rawRemotePort > 0) ? rawRemotePort : null;
      registerDiscoveredPeer(
        LanDiscoveredPeer(
          deviceId: peerId,
          deviceName: decoded['device_name'] as String? ?? 'Device',
          platform: decoded['platform'] as String? ?? 'unknown',
          host: dg.address.address,
          httpPort: port,
          pubKeyBase64: peerPub,
          revision: (decoded['revision'] as num?)?.toInt() ?? 0,
          lastSeen: clock.now(),
          remotePort: remotePort,
          syncEpoch: decoded['sync_epoch'] as String?,
        ),
      );
    } catch (_) {
      // Ignore malformed LAN datagrams from unrelated apps.
    }
  }

  void _pruneStalePeers() {
    if (!_running || _disposed) return;
    final now = clock.now();
    final before = _discovered.length;
    _discovered.removeWhere((_, p) => now.difference(p.lastSeen) > _peerStaleTimeout);
    if (_discovered.length != before) notifyListeners();
  }

  /// Registers or updates a nearby LAN peer (used by UDP discovery and tests).
  void registerDiscoveredPeer(LanDiscoveredPeer peer) {
    if (!_running || _disposed || peer.deviceId == _deviceId) return;
    _discovered[peer.deviceId] = peer;

    final idx = _trustedPeers.indexWhere((t) => t.deviceId == peer.deviceId && t.pubKeyBase64 == peer.pubKeyBase64);
    if (idx >= 0) {
      final trusted = _trustedPeers[idx];
      final endpointChanged =
          trusted.lastHost != peer.host ||
          trusted.lastPort != peer.httpPort ||
          trusted.lastRemotePort != peer.remotePort;
      if (endpointChanged || trusted.deviceName != peer.deviceName) {
        _trustedPeers[idx] = trusted.copyWith(
          deviceName: peer.deviceName,
          lastHost: peer.host,
          lastPort: peer.httpPort,
          lastRemotePort: peer.remotePort,
          clearLastRemotePort: peer.remotePort == null,
        );
        unawaited(syncStore.saveTrustedLanPeers(_trustedPeers));
      }
      final currentTrusted = _trustedPeers[idx];
      final peerEpoch = peer.syncEpoch;
      final epochChanged =
          peerEpoch != null &&
          peerEpoch.isNotEmpty &&
          currentTrusted.lastSyncedEpoch != null &&
          peerEpoch != currentTrusted.lastSyncedEpoch &&
          peer.revision > 0;
      final peerAhead = peer.revision > currentTrusted.lastSyncedRevision;
      final needsOutboundPush = _cachedLocalRev > currentTrusted.peerAckedMySeq;
      if (epochChanged || peerAhead || needsOutboundPush) {
        unawaited(
          syncWithPeer(
            currentTrusted,
            hostOverride: peer.host,
            portOverride: peer.httpPort,
            skipPullIfBeaconUnchanged: true,
          ).catchError((Object _) {}),
        );
      }
    }
    notifyListeners();
  }

  Future<void> requestPairWithPeer(LanDiscoveredPeer peer) async {
    if (!_running || _httpServer == null) throw StateError('LAN P2P service is not running');
    await _recordPromptedPeer(peer.deviceId);
    final existingIncoming = _incomingRequests[peer.deviceId];
    if (existingIncoming != null && existingIncoming.pubKeyBase64 == peer.pubKeyBase64) {
      await acceptPairRequest(existingIncoming);
      return;
    }
    _outgoingPairTargets[peer.deviceId] = peer;
    final uri = Uri.parse('http://${peer.host}:${peer.httpPort}/lan/v1/pair/request');
    final resp = await _httpClient!
        .post(
          uri,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'device_id': _deviceId,
            'device_name': deviceName,
            'platform': Platform.operatingSystem,
            'http_port': _httpServer!.port,
            'pub_key': _pubKeyB64,
            'host': '127.0.0.1',
            if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Pair request rejected (${resp.statusCode}): ${resp.body}');
    }
  }

  Future<void> acceptPairRequest(LanPairRequest req) async {
    if (!_running || _privKeyB64 == null || _pubKeyB64 == null || _httpServer == null) {
      throw StateError('LAN P2P service is not running');
    }
    final sharedKey = await SyncCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: _privKeyB64!,
      myPublicKeyBase64: _pubKeyB64!,
      peerPublicKeyBase64: req.pubKeyBase64,
    );
    final trusted = LanTrustedPeer(
      deviceId: req.deviceId,
      deviceName: req.deviceName,
      pubKeyBase64: req.pubKeyBase64,
      sharedKeyBase64: base64Encode(sharedKey),
      lastSyncedRevision: 0,
      pairedAtMs: clock.now().millisecondsSinceEpoch,
      lastHost: req.host,
      lastPort: req.httpPort,
      lastRemotePort: req.remotePort,
    );

    _trustedPeers.removeWhere((p) => p.deviceId == trusted.deviceId);
    _trustedPeers.add(trusted);
    _incomingRequests.remove(req.deviceId);
    _outgoingPairTargets.remove(req.deviceId);
    _dismissedIncomingRequestAt.remove(req.deviceId);
    await syncStore.saveTrustedLanPeers(_trustedPeers);
    await _recordPromptedPeer(req.deviceId);
    // Notify before confirming over HTTP so host-side listeners (such as Companion Remote)
    // can begin deriving and installing credentials before the initiator connects back.
    if (!_disposed) notifyListeners();

    final ts = clock.now().millisecondsSinceEpoch;
    final mac = SyncCrypto.hmacSha256Base64(key: sharedKey, message: 'PAIR:${req.deviceId}:$_deviceId:$ts');
    final uri = Uri.parse('http://${req.host}:${req.httpPort}/lan/v1/pair/confirm');
    final resp = await _httpClient!
        .post(
          uri,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'device_id': _deviceId,
            'device_name': deviceName,
            'pub_key': _pubKeyB64,
            'http_port': _httpServer!.port,
            'timestamp': ts,
            'hmac': mac,
            if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Pair confirm failed (${resp.statusCode}): ${resp.body}');
    }

    if (!_disposed) notifyListeners();
    await syncWithPeer(trusted, notifyBack: true);
  }

  void rejectPairRequest(String deviceId) {
    _dismissedIncomingRequestAt.remove(deviceId);
    if (_incomingRequests.remove(deviceId) != null && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> removeTrustedPeer(String deviceId) async {
    _trustedPeers.removeWhere((p) => p.deviceId == deviceId);
    await syncStore.saveTrustedLanPeers(_trustedPeers);
    if (!_disposed) notifyListeners();
  }

  Future<void> notifyTrustedPeersOfLocalChange({bool bumpRevision = false}) async {
    if (!_running || _disposed || _httpServer == null) return;
    await mapper.ensureJournalUpToDate();
    if (!_running || _disposed) return;
    final rev = bumpRevision ? await syncStore.bumpLocalLanRevision() : await syncStore.getLocalLanRevision();
    _cachedLocalRev = rev;
    final epoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
    unawaited(_sendBeacon());
    final snapshot = List<LanTrustedPeer>.from(_trustedPeers);
    for (final peer in snapshot) {
      final host = _discovered[peer.deviceId]?.host ?? peer.lastHost;
      final port = _discovered[peer.deviceId]?.httpPort ?? peer.lastPort;
      if (host == null || port == null || port <= 0) continue;
      unawaited(_postNotify(peer, host: host, port: port, revision: rev, syncEpoch: epoch));
    }
  }

  Future<void> _postNotify(
    LanTrustedPeer peer, {
    required String host,
    required int port,
    required int revision,
    String? syncEpoch,
  }) async {
    if (!_running || _httpClient == null || _httpServer == null) return;
    try {
      final ts = clock.now().millisecondsSinceEpoch;
      final path = '/lan/v1/sync/notify';
      final sig = SyncCrypto.hmacSha256Base64(key: peer.sharedKey, message: 'POST:$path:$ts');
      await _httpClient!
          .post(
            Uri.parse('http://$host:$port$path'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'X-Plezy-Device': _deviceId!,
              'X-Plezy-Timestamp': '$ts',
              'X-Plezy-Signature': sig,
            },
            body: jsonEncode({
              'revision': revision,
              'sync_epoch': ?syncEpoch,
              'http_port': _httpServer!.port,
            }),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Peer might currently be offline; UDP discovery or manual sync catches up later.
    }
  }

  Future<void> syncWithAllTrustedPeers() async {
    if (!_running || _disposed) return;
    _syncing = true;
    _lastError = null;
    if (!_disposed) notifyListeners();
    try {
      final peers = List<LanTrustedPeer>.from(_trustedPeers);
      for (final peer in peers) {
        await syncWithPeer(peer, notifyBack: false);
      }
    } catch (e) {
      _lastError = '$e';
    } finally {
      _syncing = false;
      if (_activePeerSyncs.isEmpty) {
        _progress = SyncProgress.idle;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> syncWithPeer(
    LanTrustedPeer peer, {
    String? hostOverride,
    int? portOverride,
    bool notifyBack = false,
    bool skipPullIfBeaconUnchanged = false,
  }) async {
    if (!_running || _disposed || _httpClient == null) return;
    final active = _activePeerSyncs[peer.deviceId];
    if (active != null) return active;

    final host = hostOverride ?? _discovered[peer.deviceId]?.host ?? peer.lastHost;
    final port = portOverride ?? _discovered[peer.deviceId]?.httpPort ?? peer.lastPort;
    if (host == null || port == null || port <= 0) return;

    final run = () async {
      _lastError = null;
      try {
        await mapper.ensureJournalUpToDate();
        if (!_running || _disposed) return;

        final myEpoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
        _cachedLocalRev = await syncStore.getLocalLanRevision();

        DateTime? lastLiveNotify;
        void maybeNotifyLive({bool force = false}) {
          final cb = onLibraryChanged;
          if (cb == null || _disposed) return;
          final now = clock.now();
          if (force || lastLiveNotify == null || now.difference(lastLiveNotify!) >= liveRefreshInterval) {
            lastLiveNotify = now;
            cb();
          }
        }

        final currentTrusted = _trustedPeers.where((p) => p.deviceId == peer.deviceId).firstOrNull ?? peer;
        final discovered = _discovered[peer.deviceId];
        final canSkipPull =
            skipPullIfBeaconUnchanged &&
            discovered != null &&
            currentTrusted.lastSyncedEpoch != null &&
            discovered.syncEpoch == currentTrusted.lastSyncedEpoch &&
            discovered.revision <= currentTrusted.lastSyncedRevision;

        var knownPeerEpoch = currentTrusted.lastSyncedEpoch;
        var peerAckedMySeq = currentTrusted.peerAckedMySeq;
        var anyPullApplied = false;

        if (!canSkipPull) {
          _setProgress(SyncProgress(phase: SyncPhase.pulling, peerName: peer.deviceName));
          var sinceSeq = currentTrusted.lastSyncedEpoch == null ? 0 : currentTrusted.lastSyncedRevision;
          var hasMore = true;
          var resetAttempted = false;
          var isRebuild = false;
          var appliedAcrossPages = 0;
          var pageIndex = 0;
          final sessionWorkCache = <String, int>{};
          final survivingFileIdsByMount = <String, Set<String>>{};
          final authoritativeMountIds = <String>{};

          while (hasMore && !_disposed) {
            final ts = clock.now().millisecondsSinceEpoch;
            const path = '/lan/v1/sync/pull';
            final sig = SyncCrypto.hmacSha256Base64(key: peer.sharedKey, message: 'GET:$path:$ts');
            final uri = Uri.parse('http://$host:$port$path').replace(
              queryParameters: {
                'since_seq': '$sinceSeq',
                if (knownPeerEpoch != null && knownPeerEpoch.isNotEmpty) 'epoch': knownPeerEpoch,
                'caller_epoch': myEpoch,
                'limit': '$syncPageLimit',
              },
            );
            debugSyncHttpRequestCount++;
            final resp = await _httpClient!
                .get(
                  uri,
                  headers: {
                    'Accept-Encoding': 'gzip',
                    'X-Plezy-Device': _deviceId!,
                    'X-Plezy-Timestamp': '$ts',
                    'X-Plezy-Signature': sig,
                  },
                )
                .timeout(const Duration(seconds: 15));

            if (resp.statusCode == HttpStatus.notFound) {
              await _legacyPullSnapshot(
                peer: peer,
                host: host,
                port: port,
                maybeNotifyLive: maybeNotifyLive,
              );
              break;
            }
            if (resp.statusCode != HttpStatus.ok) {
              throw HttpException('LAN pull failed (${resp.statusCode})');
            }

            final payload = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
            final respSyncEpoch = payload['sync_epoch'] as String?;
            final resetRequired = payload['reset_required'] == true;
            final ackedCallerEpoch = payload['acked_caller_epoch'] as String?;
            final ackedCallerSeq = (payload['acked_caller_seq'] as num?)?.toInt() ?? 0;
            if (ackedCallerEpoch == myEpoch) {
              peerAckedMySeq = math.max(peerAckedMySeq, ackedCallerSeq);
            } else if (ackedCallerEpoch != null && ackedCallerEpoch.isNotEmpty) {
              peerAckedMySeq = 0;
            }

            if (resetRequired) {
              if (resetAttempted) break;
              resetAttempted = true;
              isRebuild = true;
              sinceSeq = 0;
              knownPeerEpoch = respSyncEpoch;
              survivingFileIdsByMount.clear();
              authoritativeMountIds.clear();
              await _updateTrustedPeerState(
                peer.deviceId,
                lastSyncedRevision: 0,
                lastSyncedEpoch: respSyncEpoch,
                peerAckedMySeq: peerAckedMySeq,
                host: host,
                port: port,
              );
              continue;
            }

            final bundle = payload['bundle'] as Map<String, dynamic>? ?? const {};
            final sources = _listOfMaps(bundle['sources']);
            final works = _listOfMaps(bundle['works']);
            final files = _listOfMaps(bundle['files']);
            final workPrefs = _listOfMaps(bundle['work_prefs']);
            final watchProgress = _listOfMaps(bundle['watch_progress']);
            final pageTotal = sources.length + works.length + files.length + workPrefs.length + watchProgress.length;
            final respNextSeq = (payload['next_seq'] as num?)?.toInt() ?? sinceSeq;
            final respHasMore = payload['has_more'] == true;

            if (isRebuild) {
              final remaps = await syncStore.loadRemappedSources();
              for (final src in sources) {
                final srcId = src['source_id'] as String?;
                if (srcId != null && srcId.isNotEmpty && src['is_deleted'] != true) {
                  authoritativeMountIds.add(SyncLocalStore.resolveRemappedSourceIdFromMap(remaps, srcId));
                }
              }
              for (final f in files) {
                final rawSrcId = f['source_id'] as String?;
                final relPath = f['relative_path'] as String?;
                if (rawSrcId != null &&
                    rawSrcId.isNotEmpty &&
                    relPath != null &&
                    relPath.isNotEmpty &&
                    f['is_deleted'] != true) {
                  final srcId = SyncLocalStore.resolveRemappedSourceIdFromMap(remaps, rawSrcId);
                  authoritativeMountIds.add(srcId);
                  survivingFileIdsByMount
                      .putIfAbsent(srcId, () => <String>{})
                      .add(DeterministicKeys.generateFileId(sourceId: srcId, mountRelativePath: relPath));
                }
              }
            }

            if (pageTotal > 0) {
              await mapper.applyPullBatch(
                masterKey: peer.sharedKey,
                sources: sources,
                works: works,
                files: files,
                workPrefs: workPrefs,
                watchProgress: watchProgress,
                userSettings: _mapOf(bundle['user_settings']),
                nextSeq: respNextSeq,
                isFinalPage: !respHasMore,
                updateCloudCursor: false,
                deterministicP2pSourceTieBreak: true,
                originDeviceId: peer.deviceId,
                originEpoch: respSyncEpoch,
                sharedWorkItemCache: sessionWorkCache,
                onProgress: (done, total) => _setProgress(
                  SyncProgress(
                    phase: SyncPhase.applying,
                    processed: appliedAcrossPages + done,
                    total: respHasMore ? 0 : appliedAcrossPages + total,
                    peerName: peer.deviceName,
                  ),
                ),
                onChunkApplied: () {
                  anyPullApplied = true;
                  maybeNotifyLive();
                },
              );
              appliedAcrossPages += pageTotal;
            }

            await _updateTrustedPeerState(
              peer.deviceId,
              lastSyncedRevision: respNextSeq,
              lastSyncedEpoch: respSyncEpoch,
              peerAckedMySeq: peerAckedMySeq,
              host: host,
              port: port,
            );

            sinceSeq = respNextSeq;
            knownPeerEpoch = respSyncEpoch;
            hasMore = respHasMore;
            pageIndex++;
            if (debugOnPullPageCommitted != null) {
              await debugOnPullPageCommitted!(pageIndex, respNextSeq);
            }
          }

          if (isRebuild && authoritativeMountIds.isNotEmpty) {
            final pruned = await mapper.pruneStaleFilesAfterRebuild(
              survivingFileIdsByMount: survivingFileIdsByMount,
              authoritativeMountIds: authoritativeMountIds,
              remoteOriginId: peer.deviceId,
            );
            if (pruned > 0) anyPullApplied = true;
          }

          if (anyPullApplied) {
            maybeNotifyLive(force: true);
          }
        }

        // Phase 2: Outbound incremental push over the same working connection
        // so asymmetric firewalls still achieve bidirectional convergence.
        _cachedLocalRev = await syncStore.getLocalLanRevision();
        var pushCursor = peerAckedMySeq;
        final peerEpochForEcho = knownPeerEpoch ?? '';
        while (pushCursor < _cachedLocalRev && !_disposed) {
          _setProgress(
            SyncProgress(
              phase: SyncPhase.pushing,
              processed: pushCursor,
              total: _cachedLocalRev,
              peerName: peer.deviceName,
            ),
          );
          final delta = await mapper.buildDeltaBundle(
            encryptionKey: peer.sharedKey,
            sinceSeq: pushCursor,
            limit: syncPageLimit,
            skipOriginDeviceId: peer.deviceId,
            skipOriginEpoch: peerEpochForEcho,
            skipEchoEvenFromZero: true,
          );
          final nextPushSeq = delta.nextSeq;
          final ts = clock.now().millisecondsSinceEpoch;
          const pushPath = '/lan/v1/sync/push';
          final sig = SyncCrypto.hmacSha256Base64(key: peer.sharedKey, message: 'POST:$pushPath:$ts');
          final bodyBytes = utf8.encode(
            jsonEncode({
              'sender_epoch': myEpoch,
              'from_seq': pushCursor,
              'to_seq': nextPushSeq,
              'has_more': delta.hasMore,
              'bundle': {
                'user_settings': delta.userSettings,
                'sources': delta.sources,
                'works': delta.works,
                'files': delta.files,
                'work_prefs': delta.workPrefs,
                'watch_progress': delta.watchProgress,
              },
            }),
          );
          final useGzip = bodyBytes.length > 512;
          debugSyncHttpRequestCount++;
          final pushResp = await _httpClient!
              .post(
                Uri.parse('http://$host:$port$pushPath'),
                headers: {
                  'Content-Type': 'application/json; charset=utf-8',
                  if (useGzip) 'Content-Encoding': 'gzip',
                  'Accept-Encoding': 'gzip',
                  'X-Plezy-Device': _deviceId!,
                  'X-Plezy-Timestamp': '$ts',
                  'X-Plezy-Signature': sig,
                },
                body: useGzip ? gzip.encode(bodyBytes) : bodyBytes,
              )
              .timeout(const Duration(seconds: 15));
          if (pushResp.statusCode == HttpStatus.notFound) {
            if (notifyBack) {
              await _postNotify(peer, host: host, port: port, revision: _cachedLocalRev, syncEpoch: myEpoch);
            }
            break;
          }
          if (pushResp.statusCode < 200 || pushResp.statusCode >= 300) {
            throw HttpException('LAN push failed (${pushResp.statusCode})');
          }
          final pushDecoded = jsonDecode(utf8.decode(pushResp.bodyBytes)) as Map<String, dynamic>;
          final ackedSeq = (pushDecoded['acked_seq'] as num?)?.toInt() ?? nextPushSeq;
          final prevMaxSeq = (pushDecoded['prev_max_seq'] as num?)?.toInt();
          final respMaxSeq = (pushDecoded['current_max_seq'] as num?)?.toInt();
          final respEpoch = pushDecoded['sync_epoch'] as String?;
          final latestPeer = _trustedPeers.where((p) => p.deviceId == peer.deviceId).firstOrNull ?? peer;
          final bumpSyncedRev =
              prevMaxSeq != null &&
              respMaxSeq != null &&
              respEpoch != null &&
              latestPeer.lastSyncedEpoch == respEpoch &&
              latestPeer.lastSyncedRevision == prevMaxSeq &&
              respMaxSeq >= prevMaxSeq;
          await _updateTrustedPeerState(
            peer.deviceId,
            lastSyncedRevision: bumpSyncedRev ? respMaxSeq : null,
            peerAckedMySeq: ackedSeq,
            host: host,
            port: port,
          );
          if (ackedSeq <= pushCursor) break;
          pushCursor = ackedSeq;
        }
      } catch (e) {
        _lastError = '$e';
        rethrow;
      }
    }();

    _activePeerSyncs[peer.deviceId] = run;
    try {
      await run;
    } finally {
      unawaited(_activePeerSyncs.remove(peer.deviceId));
      if (_activePeerSyncs.isEmpty) {
        _progress = SyncProgress.idle;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _updateTrustedPeerState(
    String deviceId, {
    int? lastSyncedRevision,
    String? lastSyncedEpoch,
    int? peerAckedMySeq,
    String? host,
    int? port,
  }) async {
    final idx = _trustedPeers.indexWhere((p) => p.deviceId == deviceId);
    if (idx < 0) return;
    final cur = _trustedPeers[idx];
    final next = cur.copyWith(
      lastSyncedRevision: lastSyncedRevision,
      lastSyncedEpoch: lastSyncedEpoch,
      peerAckedMySeq: peerAckedMySeq,
      lastHost: host,
      lastPort: port,
    );
    if (next.lastSyncedRevision == cur.lastSyncedRevision &&
        next.lastSyncedEpoch == cur.lastSyncedEpoch &&
        next.peerAckedMySeq == cur.peerAckedMySeq &&
        next.lastHost == cur.lastHost &&
        next.lastPort == cur.lastPort) {
      return;
    }
    _trustedPeers[idx] = next;
    await syncStore.saveTrustedLanPeers(_trustedPeers);
  }

  Future<void> _legacyPullSnapshot({
    required LanTrustedPeer peer,
    required String host,
    required int port,
    required void Function({bool force}) maybeNotifyLive,
  }) async {
    final ts = clock.now().millisecondsSinceEpoch;
    const path = '/lan/v1/sync/snapshot';
    final sig = SyncCrypto.hmacSha256Base64(key: peer.sharedKey, message: 'GET:$path:$ts');
    final resp = await _httpClient!
        .get(
          Uri.parse('http://$host:$port$path'),
          headers: {
            'Accept-Encoding': 'gzip',
            'X-Plezy-Device': _deviceId!,
            'X-Plezy-Timestamp': '$ts',
            'X-Plezy-Signature': sig,
          },
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('LAN snapshot failed (${resp.statusCode})');
    }
    final payload = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final peerRev = (payload['revision'] as num?)?.toInt() ?? 0;
    final bundle = payload['bundle'] as Map<String, dynamic>? ?? const {};
    var changed = false;
    await mapper.applyPullBatch(
      masterKey: peer.sharedKey,
      sources: _listOfMaps(bundle['sources']),
      works: _listOfMaps(bundle['works']),
      files: _listOfMaps(bundle['files']),
      workPrefs: _listOfMaps(bundle['work_prefs']),
      watchProgress: _listOfMaps(bundle['watch_progress']),
      userSettings: _mapOf(bundle['user_settings']),
      nextSeq: 0,
      isFinalPage: true,
      updateCloudCursor: false,
      deterministicP2pSourceTieBreak: true,
      originDeviceId: peer.deviceId,
      originEpoch: payload['sync_epoch'] as String?,
      onProgress: (done, total) => _setProgress(
        SyncProgress(phase: SyncPhase.applying, processed: done, total: total, peerName: peer.deviceName),
      ),
      onChunkApplied: () {
        changed = true;
        maybeNotifyLive();
      },
    );
    await _updateTrustedPeerState(
      peer.deviceId,
      lastSyncedRevision: peerRev,
      lastSyncedEpoch: payload['sync_epoch'] as String?,
      host: host,
      port: port,
    );
    if (changed) maybeNotifyLive(force: true);
  }

  Future<void> _handleHttp(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/lan/v1/hello') {
        await mapper.ensureJournalUpToDate();
        final rev = _cachedLocalRev = await syncStore.getLocalLanRevision();
        final epoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
        await _writeJson(req.response, HttpStatus.ok, {
          'device_id': _deviceId,
          'device_name': deviceName,
          'platform': Platform.operatingSystem,
          'pub_key': _pubKeyB64,
          'revision': rev,
          'sync_epoch': epoch,
          if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
        });
        return;
      }

      if (req.method == 'POST' && path == '/lan/v1/pair/request') {
        await _handlePairRequest(req);
        return;
      }

      if (req.method == 'POST' && path == '/lan/v1/pair/confirm') {
        await _handlePairConfirm(req);
        return;
      }

      final verifiedPeer = _authenticateRequest(req);
      if (verifiedPeer == null) {
        await _writeJson(req.response, HttpStatus.forbidden, {'error': 'untrusted_peer'});
        return;
      }

      if (req.method == 'GET' && path == '/lan/v1/sync/pull') {
        await mapper.ensureJournalUpToDate();
        final myEpoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
        final currentMaxSeq = _cachedLocalRev = await syncStore.getLocalLanRevision();
        final minRetained = await syncStore.getMinRetainedSeq();
        final sinceSeq = int.tryParse(req.uri.queryParameters['since_seq'] ?? '') ?? 0;
        final requestedEpoch = req.uri.queryParameters['epoch'];
        final callerEpoch = req.uri.queryParameters['caller_epoch'];
        final limit = (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? defaultPullLimit).clamp(1, 2000);

        final currentTrusted = _trustedPeers.where((p) => p.deviceId == verifiedPeer.deviceId).firstOrNull ?? verifiedPeer;
        final needsReset =
            (requestedEpoch != null && requestedEpoch.isNotEmpty && requestedEpoch != myEpoch) ||
            (sinceSeq > 0 && sinceSeq < minRetained) ||
            (sinceSeq > currentMaxSeq);

        if (needsReset) {
          await _writeJson(
            req.response,
            HttpStatus.ok,
            {
              'sync_epoch': myEpoch,
              'current_max_seq': currentMaxSeq,
              'next_seq': 0,
              'has_more': false,
              'reset_required': true,
              'acked_caller_seq': currentTrusted.lastSyncedRevision,
              'acked_caller_epoch': currentTrusted.lastSyncedEpoch,
              'bundle': const <String, Object?>{},
            },
            compress: req.headers.value('Accept-Encoding')?.contains('gzip') == true,
          );
          return;
        }

        final delta = await mapper.buildDeltaBundle(
          encryptionKey: verifiedPeer.sharedKey,
          sinceSeq: sinceSeq,
          limit: limit,
          skipOriginDeviceId: verifiedPeer.deviceId,
          skipOriginEpoch: callerEpoch,
        );
        await _writeJson(
          req.response,
          HttpStatus.ok,
          {
            'sync_epoch': myEpoch,
            'current_max_seq': delta.currentMaxSeq,
            'next_seq': delta.nextSeq,
            'has_more': delta.hasMore,
            'reset_required': false,
            'acked_caller_seq': currentTrusted.lastSyncedRevision,
            'acked_caller_epoch': currentTrusted.lastSyncedEpoch,
            'bundle': {
              'user_settings': delta.userSettings,
              'sources': delta.sources,
              'works': delta.works,
              'files': delta.files,
              'work_prefs': delta.workPrefs,
              'watch_progress': delta.watchProgress,
            },
          },
          compress: req.headers.value('Accept-Encoding')?.contains('gzip') == true,
        );
        return;
      }

      if (req.method == 'POST' && path == '/lan/v1/sync/push') {
        final body = await _readJsonBody(req);
        final senderEpoch = body['sender_epoch'] as String?;
        final toSeq = (body['to_seq'] as num?)?.toInt() ?? 0;
        final hasMore = body['has_more'] == true;
        final bundle = body['bundle'] as Map<String, dynamic>? ?? const {};
        final sources = _listOfMaps(bundle['sources']);
        final works = _listOfMaps(bundle['works']);
        final files = _listOfMaps(bundle['files']);
        final workPrefs = _listOfMaps(bundle['work_prefs']);
        final watchProgress = _listOfMaps(bundle['watch_progress']);
        final total = sources.length + works.length + files.length + workPrefs.length + watchProgress.length;

        final prevMaxSeq = await syncStore.getLocalLanRevision();
        var changed = false;
        if (total > 0) {
          await mapper.applyPullBatch(
            masterKey: verifiedPeer.sharedKey,
            sources: sources,
            works: works,
            files: files,
            workPrefs: workPrefs,
            watchProgress: watchProgress,
            userSettings: _mapOf(bundle['user_settings']),
            nextSeq: 0,
            isFinalPage: !hasMore,
            updateCloudCursor: false,
            deterministicP2pSourceTieBreak: true,
            originDeviceId: verifiedPeer.deviceId,
            originEpoch: senderEpoch,
            onChunkApplied: () => changed = true,
          );
          if (changed && onLibraryChanged != null && !_disposed) {
            onLibraryChanged!();
          }
        }

        final latestTrusted = _trustedPeers.where((p) => p.deviceId == verifiedPeer.deviceId).firstOrNull ?? verifiedPeer;
        if (toSeq > latestTrusted.lastSyncedRevision ||
            (senderEpoch != null && senderEpoch != latestTrusted.lastSyncedEpoch)) {
          await _updateTrustedPeerState(
            verifiedPeer.deviceId,
            lastSyncedRevision: toSeq,
            lastSyncedEpoch: senderEpoch,
          );
        }

        final myEpoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
        final currentMaxSeq = _cachedLocalRev = await syncStore.getLocalLanRevision();
        await _writeJson(req.response, HttpStatus.ok, {
          'ok': true,
          'acked_seq': toSeq,
          'sync_epoch': myEpoch,
          'prev_max_seq': prevMaxSeq,
          'current_max_seq': currentMaxSeq,
        });
        return;
      }

      if (req.method == 'GET' && path == '/lan/v1/sync/snapshot') {
        await mapper.ensureJournalUpToDate();
        final rev = _cachedLocalRev = await syncStore.getLocalLanRevision();
        final epoch = _syncEpoch ??= await syncStore.getOrCreateSyncEpoch();
        final bundle = await mapper.buildSnapshotBundle(encryptionKey: verifiedPeer.sharedKey);
        await _writeJson(
          req.response,
          HttpStatus.ok,
          {'revision': rev, 'sync_epoch': epoch, 'bundle': bundle},
          compress: req.headers.value('Accept-Encoding')?.contains('gzip') == true,
        );
        return;
      }

      if (req.method == 'POST' && path == '/lan/v1/sync/notify') {
        final body = await _readJsonBody(req);
        final remoteHost = req.connectionInfo?.remoteAddress.address ?? verifiedPeer.lastHost;
        final remotePort = (body['http_port'] as num?)?.toInt() ?? verifiedPeer.lastPort;
        final notifyRev = (body['revision'] as num?)?.toInt();
        final notifyEpoch = body['sync_epoch'] as String?;
        final curTrusted = _trustedPeers.where((p) => p.deviceId == verifiedPeer.deviceId).firstOrNull ?? verifiedPeer;
        final existingDiscovered = _discovered[verifiedPeer.deviceId];
        if (existingDiscovered != null && notifyRev != null) {
          final nextEpoch = (notifyEpoch != null && notifyEpoch.isNotEmpty) ? notifyEpoch : existingDiscovered.syncEpoch;
          final sameEpoch = nextEpoch == existingDiscovered.syncEpoch;
          _discovered[verifiedPeer.deviceId] = LanDiscoveredPeer(
            deviceId: existingDiscovered.deviceId,
            deviceName: existingDiscovered.deviceName,
            platform: existingDiscovered.platform,
            host: remoteHost ?? existingDiscovered.host,
            httpPort: remotePort ?? existingDiscovered.httpPort,
            pubKeyBase64: existingDiscovered.pubKeyBase64,
            revision: sameEpoch ? math.max(existingDiscovered.revision, notifyRev) : notifyRev,
            lastSeen: clock.now(),
            remotePort: existingDiscovered.remotePort,
            syncEpoch: nextEpoch,
          );
        }
        final epochChanged = notifyEpoch != null &&
            notifyEpoch.isNotEmpty &&
            curTrusted.lastSyncedEpoch != null &&
            notifyEpoch != curTrusted.lastSyncedEpoch;
        final shouldSync = notifyRev == null || notifyRev > curTrusted.lastSyncedRevision || epochChanged;
        await _writeJson(req.response, HttpStatus.ok, {'ok': true});
        if (shouldSync) {
          unawaited(
            syncWithPeer(
              curTrusted,
              hostOverride: remoteHost,
              portOverride: remotePort,
              notifyBack: false,
            ).catchError((Object _) {}),
          );
        }
        return;
      }

      await _writeJson(req.response, HttpStatus.notFound, {'error': 'not_found'});
    } catch (e) {
      appLogger.d('[LanP2P] Request handler error', error: e);
      try {
        await req.drain<void>();
      } catch (_) {}
      try {
        await _writeJson(req.response, HttpStatus.badRequest, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _handlePairRequest(HttpRequest req) async {
    final body = await _readJsonBody(req);
    final peerId = body['device_id'] as String?;
    final peerName = body['device_name'] as String? ?? 'Device';
    final platform = body['platform'] as String? ?? 'unknown';
    final peerPub = body['pub_key'] as String?;
    final httpPort = (body['http_port'] as num?)?.toInt();
    final rawRemotePort = (body['remote_port'] as num?)?.toInt();
    final remotePort = (rawRemotePort != null && rawRemotePort > 0) ? rawRemotePort : null;
    final host = req.connectionInfo?.remoteAddress.address ?? body['host'] as String?;

    if (peerId == null ||
        peerId.isEmpty ||
        peerPub == null ||
        peerPub.isEmpty ||
        httpPort == null ||
        httpPort <= 0 ||
        host == null ||
        _pubKeyB64 == null) {
      await _writeJson(req.response, HttpStatus.badRequest, {'error': 'invalid_pair_request'});
      return;
    }

    // Auto-confirm if already trusted or mutually initiating pairing with the exact same X25519 public key.
    final already = _trustedPeers.where((p) => p.deviceId == peerId && p.pubKeyBase64 == peerPub).firstOrNull;
    final mutualTarget = _outgoingPairTargets[peerId];
    final isMutual = mutualTarget != null && mutualTarget.pubKeyBase64 == peerPub;
    final code = SyncCrypto.computePairingCode(_pubKeyB64!, peerPub);
    final pairReq = LanPairRequest(
      deviceId: peerId,
      deviceName: peerName,
      platform: platform,
      host: host,
      httpPort: httpPort,
      pubKeyBase64: peerPub,
      pairingCode: code,
      requestedAt: clock.now(),
      remotePort: remotePort,
    );

    if (already != null || isMutual) {
      await _writeJson(req.response, HttpStatus.ok, {'status': 'pending', 'pairing_code': code});
      unawaited(acceptPairRequest(pairReq).catchError((Object _) {}));
      return;
    }

    _incomingRequests[peerId] = pairReq;
    if (!_disposed) notifyListeners();
    await _writeJson(req.response, HttpStatus.ok, {'status': 'pending', 'pairing_code': code});
  }

  Future<void> _handlePairConfirm(HttpRequest req) async {
    final body = await _readJsonBody(req);
    final peerId = body['device_id'] as String?;
    final peerName = body['device_name'] as String? ?? 'Device';
    final peerPub = body['pub_key'] as String?;
    final httpPort = (body['http_port'] as num?)?.toInt();
    final rawRemotePort = (body['remote_port'] as num?)?.toInt();
    final remotePort = (rawRemotePort != null && rawRemotePort > 0) ? rawRemotePort : null;
    final ts = (body['timestamp'] as num?)?.toInt() ?? 0;
    final mac = body['hmac'] as String? ?? '';
    final host = req.connectionInfo?.remoteAddress.address;

    final pending = peerId == null ? null : _outgoingPairTargets[peerId];
    final existingTrusted = (peerId == null || peerPub == null)
        ? null
        : _trustedPeers.where((p) => p.deviceId == peerId && p.pubKeyBase64 == peerPub).firstOrNull;
    if ((pending == null && existingTrusted == null) ||
        peerId == null ||
        peerPub == null ||
        (pending != null && peerPub != pending.pubKeyBase64) ||
        _privKeyB64 == null ||
        _pubKeyB64 == null ||
        (clock.now().millisecondsSinceEpoch - ts).abs() > _hmacWindow.inMilliseconds) {
      await _writeJson(req.response, HttpStatus.forbidden, {'error': 'unexpected_pair_confirm'});
      return;
    }

    final sharedKey = await SyncCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: _privKeyB64!,
      myPublicKeyBase64: _pubKeyB64!,
      peerPublicKeyBase64: peerPub,
    );
    final expectedMac = SyncCrypto.hmacSha256Base64(key: sharedKey, message: 'PAIR:$_deviceId:$peerId:$ts');
    if (!SyncCrypto.constantTimeEquals(mac, expectedMac)) {
      await _writeJson(req.response, HttpStatus.forbidden, {'error': 'invalid_pair_hmac'});
      return;
    }

    if (pending == null && existingTrusted != null) {
      await _writeJson(req.response, HttpStatus.ok, {'status': 'paired'});
      return;
    }

    final trusted = LanTrustedPeer(
      deviceId: peerId,
      deviceName: peerName,
      pubKeyBase64: peerPub,
      sharedKeyBase64: base64Encode(sharedKey),
      lastSyncedRevision: 0,
      pairedAtMs: clock.now().millisecondsSinceEpoch,
      lastHost: host ?? pending!.host,
      lastPort: httpPort ?? pending!.httpPort,
      lastRemotePort: remotePort ?? pending?.remotePort,
    );
    _outgoingPairTargets.remove(peerId);
    _incomingRequests.remove(peerId);
    _dismissedIncomingRequestAt.remove(peerId);
    _trustedPeers.removeWhere((p) => p.deviceId == peerId);
    _trustedPeers.add(trusted);
    await syncStore.saveTrustedLanPeers(_trustedPeers);
    await _recordPromptedPeer(peerId);

    await _writeJson(req.response, HttpStatus.ok, {'status': 'paired'});
    if (!_disposed) notifyListeners();
    unawaited(syncWithPeer(trusted, notifyBack: false).catchError((Object _) {}));
  }

  LanTrustedPeer? _authenticateRequest(HttpRequest req) {
    final peerId = req.headers.value('X-Plezy-Device');
    final tsRaw = req.headers.value('X-Plezy-Timestamp');
    final sig = req.headers.value('X-Plezy-Signature');
    if (peerId == null || tsRaw == null || sig == null) return null;

    final ts = int.tryParse(tsRaw);
    if (ts == null || (clock.now().millisecondsSinceEpoch - ts).abs() > _hmacWindow.inMilliseconds) {
      return null;
    }

    final peer = _trustedPeers.where((p) => p.deviceId == peerId).firstOrNull;
    if (peer == null) return null;

    final expected = SyncCrypto.hmacSha256Base64(key: peer.sharedKey, message: '${req.method}:${req.uri.path}:$ts');
    return SyncCrypto.constantTimeEquals(sig, expected) ? peer : null;
  }

  static Future<Map<String, dynamic>> _readJsonBody(HttpRequest req) async {
    final isGzip = req.headers.value(HttpHeaders.contentEncodingHeader)?.toLowerCase().contains('gzip') == true;
    final Stream<List<int>> byteStream = isGzip ? gzip.decoder.bind(req) : req;
    final raw = await utf8.decodeStream(byteStream);
    if (raw.trim().isEmpty) return const {};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  static Future<void> _writeJson(HttpResponse resp, int status, Object body, {bool compress = false}) async {
    final raw = utf8.encode(jsonEncode(body));
    resp.statusCode = status;
    resp.headers.contentType = ContentType.json;
    if (compress && raw.length > 512) {
      resp.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      resp.add(gzip.encode(raw));
    } else {
      resp.add(raw);
    }
    await resp.close();
  }

  static Map<String, Object?> _mapOf(Object? raw) =>
      raw is Map ? {for (final entry in raw.entries) '${entry.key}': entry.value} : const {};

  static List<Map<String, dynamic>> _listOfMaps(Object? raw) =>
      raw is List ? [for (final entry in raw) if (entry is Map<String, dynamic>) entry] : const [];

  @visibleForTesting
  void debugSeedStateForTesting({
    bool running = true,
    String? deviceId,
    String? deviceName,
    String? publicKeyBase64,
    int? advertisedRemotePort,
    List<LanDiscoveredPeer> discovered = const [],
    List<LanPairRequest> incomingRequests = const [],
    List<LanTrustedPeer> trusted = const [],
    Set<String>? promptedPeerIds,
    SyncProgress? progress,
    String? lastError,
    bool clearError = false,
  }) {
    _running = running;
    if (deviceId != null) _deviceId = deviceId;
    if (deviceName != null) _deviceName = deviceName;
    if (publicKeyBase64 != null) _pubKeyB64 = publicKeyBase64;
    if (advertisedRemotePort != null) _advertisedRemotePort = advertisedRemotePort;
    if (promptedPeerIds != null) _promptedPeerIds = Set<String>.from(promptedPeerIds);
    if (progress != null) _progress = progress;
    if (clearError) {
      _lastError = null;
    } else if (lastError != null) {
      _lastError = lastError;
    }
    _discovered
      ..clear()
      ..addEntries(discovered.map((p) => MapEntry(p.deviceId, p)));
    _incomingRequests
      ..clear()
      ..addEntries(incomingRequests.map((r) => MapEntry(r.deviceId, r)));
    _dismissedIncomingRequestAt.removeWhere((id, _) => !_incomingRequests.containsKey(id));
    _trustedPeers = List<LanTrustedPeer>.from(trusted);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
