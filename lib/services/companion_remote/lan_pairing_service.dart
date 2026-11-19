import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/udp_broadcast_sockets.dart';
import 'lan_crypto.dart';
import 'lan_identity_store.dart';

class LanDiscoveredPeer {
  const LanDiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.host,
    required this.httpPort,
    required this.pubKeyBase64,
    required this.lastSeen,
    this.remotePort,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String host;
  final int httpPort;
  final String pubKeyBase64;
  final DateTime lastSeen;
  final int? remotePort;

  String pairingCodeFor(String myPubKeyBase64) => LanCrypto.pairingCodeForKeys(myPubKeyBase64, pubKeyBase64);

  LanDiscoveredPeer copyWith({
    String? deviceName,
    String? platform,
    String? host,
    int? httpPort,
    String? pubKeyBase64,
    DateTime? lastSeen,
    int? remotePort,
  }) => LanDiscoveredPeer(
    deviceId: deviceId,
    deviceName: deviceName ?? this.deviceName,
    platform: platform ?? this.platform,
    host: host ?? this.host,
    httpPort: httpPort ?? this.httpPort,
    pubKeyBase64: pubKeyBase64 ?? this.pubKeyBase64,
    lastSeen: lastSeen ?? this.lastSeen,
    remotePort: remotePort ?? this.remotePort,
  );
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

/// Mode-independent LAN discovery and X25519 4-digit SAS pairing service for
/// Companion Remote control across offline and self-hosted devices.
class LanPairingService extends ChangeNotifier {
  LanPairingService({
    required this._identityStore,
    this.enableUdpBroadcast = true,
    this.discoveryPort = defaultDiscoveryPort,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  static const int defaultDiscoveryPort = 48635;
  static const String discoveryMagic = 'plezy_lan_sync_v1';
  static const Duration _udpInterval = Duration(seconds: 3);
  static const Duration _cleanupInterval = Duration(seconds: 5);
  static const Duration _peerTtl = Duration(seconds: 20);
  static const Duration _requestTtl = Duration(minutes: 2);

  final LanIdentityStore _identityStore;
  final bool enableUdpBroadcast;
  final int discoveryPort;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  HttpServer? _httpServer;
  RawDatagramSocket? _udpListenSocket;
  StreamSubscription<RawSocketEvent>? _udpListenSub;
  UdpBroadcastSocketSet? _broadcastSockets;
  Timer? _udpTimer;
  Timer? _cleanupTimer;
  Future<void>? _starting;
  bool _disposed = false;
  bool _debugSeeded = false;

  String? _deviceId;
  String? _deviceName;
  String _platform = Platform.operatingSystem;
  LanKeyPair? _keyPair;
  String? _debugPublicKeyOverride;
  int? _listeningPort;
  int? _advertisedRemotePort;

  final List<LanTrustedPeer> _trusted = [];
  final Set<String> _promptedPeerIds = {};
  final Map<String, LanDiscoveredPeer> _discovered = {};
  final Map<String, LanPairRequest> _incomingRequests = {};
  final Map<String, LanDiscoveredPeer> _outgoingPairTargets = {};
  final Map<String, DateTime> _dismissedIncomingRequestAt = {};

  bool get isRunning => _httpServer != null || _debugSeeded;
  LanIdentityStore get identityStore => _identityStore;
  int? get listeningPort => _listeningPort;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  String get platform => _platform;
  String? get publicKeyBase64 => _debugPublicKeyOverride ?? _keyPair?.publicKeyBase64;
  int? get advertisedRemotePort => _advertisedRemotePort;

  List<LanTrustedPeer> get trustedPeers => List.unmodifiable(_trusted);
  List<LanDiscoveredPeer> get discoveredPeers => List.unmodifiable(_discovered.values);
  List<LanPairRequest> get incomingPairRequests => List.unmodifiable(_incomingRequests.values);

  List<LanPairRequest> get unpromptedIncomingRequests => [
    for (final req in _incomingRequests.values)
      if (!isPeerTrusted(req.deviceId) &&
          (_dismissedIncomingRequestAt[req.deviceId] == null ||
              req.requestedAt.isAfter(_dismissedIncomingRequestAt[req.deviceId]!)))
        req,
  ];

  bool isPeerTrusted(String deviceId) => _trusted.any((t) => t.deviceId == deviceId);

  bool shouldAutoPromptPeer(String deviceId) {
    if (deviceId.isEmpty || deviceId == _deviceId) return false;
    if (isPeerTrusted(deviceId)) return false;
    return !_promptedPeerIds.contains(deviceId);
  }

  Future<void> start({int bindHttpPort = defaultDiscoveryPort}) {
    if (_httpServer != null) return Future.value();
    final existing = _starting;
    if (existing != null) return existing;

    final future = _startInternal(bindHttpPort: bindHttpPort).whenComplete(() => _starting = null);
    _starting = future;
    return future;
  }

  Future<void> _startInternal({required int bindHttpPort}) async {
    if (_disposed) return;

    _deviceId = await _identityStore.getOrCreateDeviceId();
    _deviceName = await _identityStore.getDeviceName();
    _platform = Platform.operatingSystem;
    _keyPair = await _identityStore.getOrCreateLanKeyPair();
    _debugPublicKeyOverride = null;
    _debugSeeded = false;

    final loadedTrusted = await _identityStore.loadTrustedLanPeers();
    _trusted
      ..clear()
      ..addAll(loadedTrusted);

    final loadedPrompted = await _identityStore.loadPromptedLanPeerIds();
    _promptedPeerIds
      ..clear()
      ..addAll(loadedPrompted);
    var promptedDirty = false;
    for (final peer in _trusted) {
      if (_promptedPeerIds.add(peer.deviceId)) {
        promptedDirty = true;
      }
    }
    if (promptedDirty) {
      await _identityStore.savePromptedLanPeerIds(_promptedPeerIds);
    }

    if (_disposed) return;

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, bindHttpPort);
    } on SocketException {
      if (bindHttpPort == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }

    if (_disposed) {
      await server.close(force: true);
      return;
    }

    _httpServer = server;
    _listeningPort = server.port;
    server.listen(_handleHttpRequest, onError: (Object e, StackTrace st) {
      appLogger.w('LAN pairing HTTP server error', error: e, stackTrace: st);
    });

    if (enableUdpBroadcast) {
      await _startUdp();
    }

    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) => _pruneStaleEntries());

    if (!_disposed) notifyListeners();
  }

  Future<void> _startUdp() async {
    try {
      RawDatagramSocket? listenSocket;
      try {
        listenSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      } catch (e) {
        appLogger.d('LAN pairing UDP listen bind($discoveryPort) skipped: $e');
      }
      if (listenSocket != null) {
        listenSocket.broadcastEnabled = true;
        _udpListenSocket = listenSocket;
        _udpListenSub = listenSocket.listen((event) {
          if (event != RawSocketEvent.read) return;
          Datagram? datagram;
          while ((datagram = listenSocket!.receive()) != null) {
            _handleUdpDatagram(datagram!);
          }
        }, onError: (Object e, StackTrace st) {
          appLogger.w('LAN pairing UDP listen error', error: e, stackTrace: st);
        });
      }

      _broadcastSockets = await UdpBroadcastSockets.bind();
      _sendUdpBeacon();
      _udpTimer?.cancel();
      _udpTimer = Timer.periodic(_udpInterval, (_) => _sendUdpBeacon());
    } catch (e, st) {
      appLogger.w('LAN pairing UDP startup failed', error: e, stackTrace: st);
    }
  }

  void _sendUdpBeacon() {
    final sockets = _broadcastSockets;
    final myId = _deviceId;
    final myPub = publicKeyBase64;
    final port = _listeningPort;
    if (sockets == null || sockets.isEmpty || myId == null || myPub == null || port == null) return;

    final payload = jsonEncode({
      'magic': discoveryMagic,
      'device_id': myId,
      'device_name': _deviceName ?? 'TTPlay',
      'platform': _platform,
      'pub_key': myPub,
      'http_port': port,
      if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
    });
    final bytes = utf8.encode(payload);
    sockets.send(bytes, UdpBroadcastSockets.limitedBroadcastAddress, discoveryPort);
  }

  void _handleUdpDatagram(Datagram datagram) {
    if (_disposed) return;
    try {
      final raw = utf8.decode(datagram.data);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      if (map['magic'] != discoveryMagic) return;

      final peerId = map['device_id'] as String?;
      final peerPub = map['pub_key'] as String?;
      final httpPort = (map['http_port'] as num?)?.toInt();
      if (peerId == null || peerId.isEmpty || peerId == _deviceId) return;
      if (peerPub == null || peerPub.isEmpty || httpPort == null || httpPort <= 0) return;

      final host = _normalizeIp(datagram.address.address);
      final peerName = (map['device_name'] as String?)?.trim();
      final remotePort = (map['remote_port'] as num?)?.toInt();
      final peer = LanDiscoveredPeer(
        deviceId: peerId,
        deviceName: (peerName != null && peerName.isNotEmpty) ? peerName : peerId,
        platform: (map['platform'] as String?) ?? 'unknown',
        host: host,
        httpPort: httpPort,
        pubKeyBase64: peerPub,
        lastSeen: clock.now(),
        remotePort: remotePort,
      );
      registerDiscoveredPeer(peer);
      _updateTrustedPeerEndpoint(peerId, host: host, httpPort: httpPort, remotePort: remotePort, deviceName: peer.deviceName);
    } catch (_) {}
  }

  Future<void> stop() async {
    _udpTimer?.cancel();
    _udpTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _udpListenSub?.cancel();
    _udpListenSub = null;
    _udpListenSocket?.close();
    _udpListenSocket = null;
    await _broadcastSockets?.close();
    _broadcastSockets = null;
    final server = _httpServer;
    _httpServer = null;
    _listeningPort = null;
    _debugSeeded = false;
    _dismissedIncomingRequestAt.clear();
    await server?.close(force: true);
    if (!_disposed) notifyListeners();
  }

  void setAdvertisedRemotePort(int? port) {
    if (_advertisedRemotePort == port) return;
    _advertisedRemotePort = port;
    if (isRunning && enableUdpBroadcast) {
      _sendUdpBeacon();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshDeviceIdentity() async {
    _deviceName = await _identityStore.getDeviceName();
    if (isRunning && enableUdpBroadcast) {
      _sendUdpBeacon();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> markPeerPrompted(String deviceId) async {
    if (deviceId.isEmpty) return;
    if (_promptedPeerIds.add(deviceId)) {
      await _identityStore.markLanPeerPrompted(deviceId);
    }
  }

  Future<void> markPeerAutoPrompted(String deviceId) async {
    if (deviceId.isEmpty) return;
    if (_promptedPeerIds.add(deviceId)) {
      await _identityStore.markLanPeerPrompted(deviceId);
      if (!_disposed) notifyListeners();
    }
  }

  void dismissIncomingRequestPrompt(LanPairRequest req) {
    _dismissedIncomingRequestAt[req.deviceId] = req.requestedAt;
    if (!_disposed) notifyListeners();
  }

  void registerDiscoveredPeer(LanDiscoveredPeer peer) {
    if (_disposed || peer.deviceId.isEmpty || peer.deviceId == _deviceId) return;
    _discovered[peer.deviceId] = peer;
    notifyListeners();
  }

  Future<void> probeTrustedPeers() async {
    if (!isRunning || _trusted.isEmpty) return;
    var updated = false;
    for (final trusted in List<LanTrustedPeer>.of(_trusted)) {
      final host = trusted.lastHost;
      final port = trusted.lastPort;
      if (host == null || host.isEmpty || port == null || port <= 0) continue;
      try {
        final resp = await _httpClient
            .get(Uri.parse('http://$host:$port/lan/v1/hello'))
            .timeout(const Duration(milliseconds: 1200));
        if (resp.statusCode != HttpStatus.ok) continue;
        final decoded = jsonDecode(resp.body);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        final id = map['device_id'] as String?;
        if (id != trusted.deviceId) continue;
        final remotePort = (map['remote_port'] as num?)?.toInt();
        final name = (map['device_name'] as String?)?.trim();
        final peer = LanDiscoveredPeer(
          deviceId: trusted.deviceId,
          deviceName: (name != null && name.isNotEmpty) ? name : trusted.deviceName,
          platform: (map['platform'] as String?) ?? 'unknown',
          host: host,
          httpPort: (map['http_port'] as num?)?.toInt() ?? port,
          pubKeyBase64: (map['pub_key'] as String?) ?? trusted.pubKeyBase64,
          lastSeen: clock.now(),
          remotePort: remotePort,
        );
        _discovered[trusted.deviceId] = peer;
        await _updateTrustedPeerEndpoint(
          trusted.deviceId,
          host: host,
          httpPort: peer.httpPort,
          remotePort: remotePort,
          deviceName: peer.deviceName,
          notify: false,
        );
        updated = true;
      } catch (_) {}
    }
    if (updated && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> requestPairWithPeer(LanDiscoveredPeer peer) async {
    final myId = _deviceId;
    final myPub = publicKeyBase64;
    final kp = _keyPair;
    final listenPort = _listeningPort;
    if (!isRunning || myId == null || myPub == null || kp == null || listenPort == null) {
      throw StateError('LAN pairing service is not running');
    }

    final existingIncoming = _incomingRequests[peer.deviceId];
    if (existingIncoming != null && existingIncoming.pubKeyBase64 == peer.pubKeyBase64) {
      await acceptPairRequest(existingIncoming);
      return;
    }

    _outgoingPairTargets[peer.deviceId] = peer;
    final uri = Uri.parse('http://${peer.host}:${peer.httpPort}/lan/v1/pair/request');
    final resp = await _httpClient
        .post(
          uri,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'device_id': myId,
            'device_name': _deviceName ?? 'TTPlay',
            'platform': _platform,
            'http_port': listenPort,
            'pub_key': myPub,
            if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
          }),
        )
        .timeout(const Duration(seconds: 5));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _outgoingPairTargets.remove(peer.deviceId);
      throw HttpException('Pair request failed with HTTP ${resp.statusCode}', uri: uri);
    }

    final body = jsonDecode(resp.body);
    if (body is Map && body['status'] == 'accepted') {
      final peerPub = (body['pub_key'] as String?)?.isNotEmpty == true ? body['pub_key'] as String : peer.pubKeyBase64;
      final peerName = (body['device_name'] as String?)?.isNotEmpty == true
          ? body['device_name'] as String
          : peer.deviceName;
      final remotePort = (body['remote_port'] as num?)?.toInt() ?? peer.remotePort;
      final httpPort = (body['http_port'] as num?)?.toInt() ?? peer.httpPort;
      await _trustPeer(
        peerId: peer.deviceId,
        peerName: peerName,
        peerPlatform: (body['platform'] as String?) ?? peer.platform,
        peerPubKeyBase64: peerPub,
        host: peer.host,
        httpPort: httpPort,
        remotePort: remotePort,
      );
    }
  }

  Future<void> acceptPairRequest(LanPairRequest req) async {
    final myId = _deviceId;
    final myPub = publicKeyBase64;
    final kp = _keyPair;
    if (!isRunning || myId == null || myPub == null || kp == null) {
      throw StateError('LAN pairing service is not running');
    }

    _dismissedIncomingRequestAt.remove(req.deviceId);
    final discovered = _discovered[req.deviceId];
    final remotePort = req.remotePort ?? discovered?.remotePort;
    final sharedKey = await _trustPeer(
      peerId: req.deviceId,
      peerName: req.deviceName,
      peerPlatform: req.platform,
      peerPubKeyBase64: req.pubKeyBase64,
      host: req.host,
      httpPort: req.httpPort,
      remotePort: remotePort,
    );

    final ts = clock.now().millisecondsSinceEpoch;
    final hmac = LanCrypto.hmacSha256Base64(sharedKey, utf8.encode('PAIR:${req.deviceId}:$myId:$ts'));
    final mac = LanCrypto.hmacSha256Base64(sharedKey, utf8.encode('pair-confirm:$myId:$myPub'));
    try {
      await _httpClient
          .post(
            Uri.parse('http://${req.host}:${req.httpPort}/lan/v1/pair/confirm'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'device_id': myId,
              'device_name': _deviceName ?? 'TTPlay',
              'platform': _platform,
              'http_port': _listeningPort ?? discoveryPort,
              'pub_key': myPub,
              if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
              'timestamp': ts,
              'hmac': hmac,
              'mac': mac,
            }),
          )
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      appLogger.w('LAN pair confirm POST failed for ${req.deviceId}', error: e);
    }
  }

  Future<void> rejectPairRequest(String deviceId) async {
    _dismissedIncomingRequestAt.remove(deviceId);
    if (_incomingRequests.remove(deviceId) != null && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> removeTrustedPeer(String deviceId) async {
    final idx = _trusted.indexWhere((t) => t.deviceId == deviceId);
    if (idx < 0) return;
    _trusted.removeAt(idx);
    await _identityStore.saveTrustedLanPeers(_trusted);
    if (!_disposed) notifyListeners();
  }

  Future<void> revokeTrustedPeer(String deviceId) async {
    final existing = _trusted.where((t) => t.deviceId == deviceId).firstOrNull;
    if (existing == null) return;
    final discovered = _discovered[deviceId];
    final targetHost = discovered?.host ?? existing.lastHost;
    final targetPort = discovered?.httpPort ?? existing.lastPort;

    _trusted.removeWhere((t) => t.deviceId == deviceId);
    await _identityStore.saveTrustedLanPeers(_trusted);
    if (!_disposed) notifyListeners();

    final myId = _deviceId;
    if (myId != null && targetHost != null && targetHost.isNotEmpty && targetPort != null && targetPort > 0) {
      try {
        final ts = clock.now().millisecondsSinceEpoch;
        const path = '/lan/v1/pair/revoke';
        final sig = LanCrypto.hmacSha256Base64(existing.sharedKeyBytes, utf8.encode('POST:$path:$ts'));
        final mac = LanCrypto.hmacSha256Base64(
          existing.sharedKeyBytes,
          utf8.encode('pair-revoke:$myId:$deviceId'),
        );
        final hostAuthority = (targetHost.contains(':') && !targetHost.startsWith('[')) ? '[$targetHost]' : targetHost;
        await _httpClient
            .post(
              Uri.parse('http://$hostAuthority:$targetPort$path'),
              headers: {
                'content-type': 'application/json',
                'X-Plezy-Device': myId,
                'X-Plezy-Timestamp': '$ts',
                'X-Plezy-Signature': sig,
              },
              body: jsonEncode({'device_id': myId, 'mac': mac}),
            )
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        appLogger.d('LAN pair revoke notification ignored for $deviceId: $e');
      }
    }
  }

  Future<List<int>> _trustPeer({
    required String peerId,
    required String peerName,
    required String peerPlatform,
    required String peerPubKeyBase64,
    required String host,
    required int httpPort,
    required int? remotePort,
  }) async {
    final kp = _keyPair;
    final myPub = publicKeyBase64;
    if (kp == null || myPub == null) {
      throw StateError('Missing local LAN key pair');
    }

    final sharedKey = await LanCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: kp.privateKeyBase64,
      myPublicKeyBase64: myPub,
      peerPublicKeyBase64: peerPubKeyBase64,
    );
    final trustedPeer = LanTrustedPeer(
      deviceId: peerId,
      deviceName: peerName,
      pubKeyBase64: peerPubKeyBase64,
      sharedKeyBase64: base64Encode(sharedKey),
      pairedAtMs: clock.now().millisecondsSinceEpoch,
      lastHost: host,
      lastPort: httpPort,
      lastRemotePort: remotePort,
    );
    _trusted.removeWhere((t) => t.deviceId == peerId);
    _trusted.add(trustedPeer);
    _incomingRequests.remove(peerId);
    _outgoingPairTargets.remove(peerId);
    _discovered[peerId] = LanDiscoveredPeer(
      deviceId: peerId,
      deviceName: peerName,
      platform: peerPlatform,
      host: host,
      httpPort: httpPort,
      pubKeyBase64: peerPubKeyBase64,
      lastSeen: clock.now(),
      remotePort: remotePort ?? _discovered[peerId]?.remotePort,
    );
    await _identityStore.saveTrustedLanPeers(_trusted);
    await markPeerPrompted(peerId);
    if (!_disposed) notifyListeners();
    return sharedKey;
  }

  Future<void> _updateTrustedPeerEndpoint(
    String deviceId, {
    required String host,
    required int httpPort,
    required int? remotePort,
    String? deviceName,
    bool notify = true,
  }) async {
    final idx = _trusted.indexWhere((t) => t.deviceId == deviceId);
    if (idx < 0) return;
    final cur = _trusted[idx];
    final nextName = (deviceName != null && deviceName.isNotEmpty) ? deviceName : cur.deviceName;
    final nextRemotePort = remotePort ?? cur.lastRemotePort;
    if (cur.lastHost == host &&
        cur.lastPort == httpPort &&
        cur.lastRemotePort == nextRemotePort &&
        cur.deviceName == nextName) {
      return;
    }
    _trusted[idx] = cur.copyWith(
      deviceName: nextName,
      lastHost: host,
      lastPort: httpPort,
      lastRemotePort: nextRemotePort,
    );
    await _identityStore.saveTrustedLanPeers(_trusted);
    if (notify && !_disposed) notifyListeners();
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/lan/v1/hello') {
        await _writeJson(request.response, HttpStatus.ok, {
          'device_id': _deviceId ?? '',
          'device_name': _deviceName ?? 'TTPlay',
          'platform': _platform,
          'pub_key': publicKeyBase64 ?? '',
          'http_port': _listeningPort ?? discoveryPort,
          if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
        });
        return;
      }

      if (path.startsWith('/lan/v1/sync/')) {
        await _writeJson(request.response, HttpStatus.gone, {'error': 'lan_library_sync_retired'});
        return;
      }

      if (request.method == 'POST' && path == '/lan/v1/pair/request') {
        await _handlePairRequest(request);
        return;
      }
      if (request.method == 'POST' && path == '/lan/v1/pair/confirm') {
        await _handlePairConfirm(request);
        return;
      }
      if (request.method == 'POST' && path == '/lan/v1/pair/revoke') {
        await _handlePairRevoke(request);
        return;
      }

      await _writeJson(request.response, HttpStatus.notFound, {'error': 'not_found'});
    } catch (e, st) {
      appLogger.w('LAN pairing HTTP handler error', error: e, stackTrace: st);
      try {
        await _writeJson(request.response, HttpStatus.internalServerError, {'error': 'internal_error'});
      } catch (_) {}
    }
  }

  Future<void> _handlePairRequest(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeJson(request.response, HttpStatus.badRequest, {'error': 'invalid_json'});
      return;
    }

    final peerId = body['device_id'] as String? ?? '';
    final peerPub = body['pub_key'] as String? ?? '';
    final peerName = (body['device_name'] as String?)?.trim();
    final peerPlatform = body['platform'] as String? ?? 'unknown';
    final peerHttpPort = (body['http_port'] as num?)?.toInt() ?? 0;
    final peerRemotePort = (body['remote_port'] as num?)?.toInt();
    if (peerId.isEmpty || peerPub.isEmpty || peerHttpPort <= 0 || peerId == _deviceId) {
      await _writeJson(request.response, HttpStatus.badRequest, {'error': 'invalid_peer'});
      return;
    }

    final myId = _deviceId;
    final myPub = publicKeyBase64;
    if (myId == null || myPub == null) {
      await _writeJson(request.response, HttpStatus.serviceUnavailable, {'error': 'not_ready'});
      return;
    }

    final remoteIp = _normalizeIp(request.connectionInfo?.remoteAddress.address ?? '127.0.0.1');
    final displayName = (peerName != null && peerName.isNotEmpty) ? peerName : peerId;

    // If mutual pairing clicked at the same time (or already trusted), promote directly.
    if (isPeerTrusted(peerId) || _outgoingPairTargets.containsKey(peerId)) {
      await _trustPeer(
        peerId: peerId,
        peerName: displayName,
        peerPlatform: peerPlatform,
        peerPubKeyBase64: peerPub,
        host: remoteIp,
        httpPort: peerHttpPort,
        remotePort: peerRemotePort,
      );
      await _writeJson(request.response, HttpStatus.ok, {
        'status': 'accepted',
        'device_id': myId,
        'device_name': _deviceName ?? 'TTPlay',
        'platform': _platform,
        'http_port': _listeningPort ?? discoveryPort,
        'pub_key': myPub,
        if (_advertisedRemotePort != null) 'remote_port': _advertisedRemotePort,
      });
      return;
    }

    final code = LanCrypto.pairingCodeForKeys(myPub, peerPub);
    final req = LanPairRequest(
      deviceId: peerId,
      deviceName: displayName,
      platform: peerPlatform,
      host: remoteIp,
      httpPort: peerHttpPort,
      pubKeyBase64: peerPub,
      pairingCode: code,
      requestedAt: clock.now(),
      remotePort: peerRemotePort,
    );
    _incomingRequests[peerId] = req;
    _discovered.putIfAbsent(
      peerId,
      () => LanDiscoveredPeer(
        deviceId: peerId,
        deviceName: displayName,
        platform: peerPlatform,
        host: remoteIp,
        httpPort: peerHttpPort,
        pubKeyBase64: peerPub,
        lastSeen: clock.now(),
        remotePort: peerRemotePort,
      ),
    );
    if (!_disposed) notifyListeners();
    await _writeJson(request.response, HttpStatus.ok, {'status': 'pending', 'pairing_code': code});
  }

  Future<void> _handlePairConfirm(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeJson(request.response, HttpStatus.badRequest, {'error': 'invalid_json'});
      return;
    }

    final peerId = body['device_id'] as String? ?? '';
    final peerPub = body['pub_key'] as String? ?? '';
    final mac = body['mac'] as String? ?? '';
    final hmac = body['hmac'] as String? ?? '';
    final timestamp = (body['timestamp'] as num?)?.toInt();
    final peerName = (body['device_name'] as String?)?.trim();
    final peerPlatform = body['platform'] as String? ?? 'unknown';
    final peerHttpPort = (body['http_port'] as num?)?.toInt() ?? 0;
    final peerRemotePort = (body['remote_port'] as num?)?.toInt();

    final kp = _keyPair;
    final myId = _deviceId;
    final myPub = publicKeyBase64;
    if (peerId.isEmpty || peerPub.isEmpty || (mac.isEmpty && hmac.isEmpty) || kp == null || myPub == null || myId == null) {
      await _writeJson(request.response, HttpStatus.badRequest, {'error': 'invalid_confirm'});
      return;
    }

    if (!_outgoingPairTargets.containsKey(peerId) && !isPeerTrusted(peerId)) {
      await _writeJson(request.response, HttpStatus.forbidden, {'error': 'unexpected_confirm'});
      return;
    }

    final sharedKey = await LanCrypto.deriveLanSharedKey(
      myPrivateKeyBase64: kp.privateKeyBase64,
      myPublicKeyBase64: myPub,
      peerPublicKeyBase64: peerPub,
    );
    var macOk = false;
    if (mac.isNotEmpty) {
      final expectedMac = LanCrypto.hmacSha256Base64(sharedKey, utf8.encode('pair-confirm:$peerId:$peerPub'));
      macOk = LanCrypto.constantTimeEquals(expectedMac, mac);
    }
    if (!macOk && hmac.isNotEmpty && timestamp != null) {
      final expectedHmac = LanCrypto.hmacSha256Base64(sharedKey, utf8.encode('PAIR:$myId:$peerId:$timestamp'));
      macOk = LanCrypto.constantTimeEquals(expectedHmac, hmac);
    }
    if (!macOk) {
      await _writeJson(request.response, HttpStatus.forbidden, {'error': 'invalid_mac'});
      return;
    }

    final remoteIp = _normalizeIp(request.connectionInfo?.remoteAddress.address ?? '127.0.0.1');
    final outgoing = _outgoingPairTargets[peerId];
    await _trustPeer(
      peerId: peerId,
      peerName: (peerName != null && peerName.isNotEmpty) ? peerName : (outgoing?.deviceName ?? peerId),
      peerPlatform: peerPlatform,
      peerPubKeyBase64: peerPub,
      host: remoteIp,
      httpPort: peerHttpPort > 0 ? peerHttpPort : (outgoing?.httpPort ?? discoveryPort),
      remotePort: peerRemotePort ?? outgoing?.remotePort,
    );
    await _writeJson(request.response, HttpStatus.ok, {'status': 'trusted'});
  }

  Future<void> _handlePairRevoke(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final headerDevice = request.headers.value('x-plezy-device') ?? '';
    final headerTs = request.headers.value('x-plezy-timestamp') ?? '';
    final headerSig = request.headers.value('x-plezy-signature') ?? '';

    final peerId = (body?['device_id'] as String?) ?? headerDevice;
    final mac = (body?['mac'] as String?) ?? '';
    final myId = _deviceId;
    final trusted = _trusted.where((t) => t.deviceId == peerId).firstOrNull;
    if (peerId.isEmpty || (mac.isEmpty && headerSig.isEmpty) || myId == null || trusted == null) {
      await _writeJson(request.response, HttpStatus.ok, {'status': 'ignored'});
      return;
    }

    var verified = false;
    if (headerSig.isNotEmpty && headerTs.isNotEmpty) {
      final expectedSig = LanCrypto.hmacSha256Base64(
        trusted.sharedKeyBytes,
        utf8.encode('POST:/lan/v1/pair/revoke:$headerTs'),
      );
      verified = LanCrypto.constantTimeEquals(expectedSig, headerSig);
    }
    if (!verified && mac.isNotEmpty) {
      final expectedMac = LanCrypto.hmacSha256Base64(
        trusted.sharedKeyBytes,
        utf8.encode('pair-revoke:$peerId:$myId'),
      );
      verified = LanCrypto.constantTimeEquals(expectedMac, mac);
    }
    if (!verified) {
      await _writeJson(request.response, HttpStatus.forbidden, {'error': 'invalid_mac'});
      return;
    }

    await removeTrustedPeer(peerId);
    await _writeJson(request.response, HttpStatus.ok, {'status': 'revoked'});
  }

  void _pruneStaleEntries() {
    if (_disposed || _debugSeeded) return;
    final now = clock.now();
    var changed = false;

    _discovered.removeWhere((_, peer) {
      final stale = now.difference(peer.lastSeen) > _peerTtl;
      if (stale) changed = true;
      return stale;
    });
    _incomingRequests.removeWhere((_, req) {
      final expired = now.difference(req.requestedAt) > _requestTtl;
      if (expired) changed = true;
      return expired;
    });

    if (changed) notifyListeners();
  }

  static String _normalizeIp(String raw) {
    var ip = raw.trim();
    if (ip.startsWith('::ffff:')) {
      ip = ip.substring('::ffff:'.length);
    }
    if (ip == '::1') return '127.0.0.1';
    return ip;
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    try {
      final raw = await utf8.decoder.bind(request).join();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(HttpResponse response, int statusCode, Map<String, dynamic> body) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  @visibleForTesting
  void debugSeedStateForTesting({
    String? deviceId,
    String? deviceName,
    String? platform,
    String? publicKeyBase64,
    List<LanDiscoveredPeer>? discovered,
    List<LanPairRequest>? incomingRequests,
    List<LanTrustedPeer>? trusted,
    Set<String>? promptedIds,
  }) {
    _debugSeeded = true;
    if (deviceId != null) _deviceId = deviceId;
    if (deviceName != null) _deviceName = deviceName;
    if (platform != null) _platform = platform;
    if (publicKeyBase64 != null) _debugPublicKeyOverride = publicKeyBase64;
    if (discovered != null) {
      _discovered
        ..clear()
        ..addEntries(discovered.map((p) => MapEntry(p.deviceId, p)));
    }
    if (incomingRequests != null) {
      _incomingRequests
        ..clear()
        ..addEntries(incomingRequests.map((r) => MapEntry(r.deviceId, r)));
    }
    if (trusted != null) {
      _trusted
        ..clear()
        ..addAll(trusted);
    }
    if (promptedIds != null) {
      _promptedPeerIds
        ..clear()
        ..addAll(promptedIds);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    super.dispose();
  }
}
