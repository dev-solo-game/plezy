import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../credential_vault.dart';
import 'lan_crypto.dart';

class LanTrustedPeer {
  const LanTrustedPeer({
    required this.deviceId,
    required this.deviceName,
    required this.pubKeyBase64,
    required this.sharedKeyBase64,
    required this.pairedAtMs,
    this.lastHost,
    this.lastPort,
    this.lastRemotePort,
  });

  final String deviceId;
  final String deviceName;
  final String pubKeyBase64;
  final String sharedKeyBase64;
  final int pairedAtMs;
  final String? lastHost;
  final int? lastPort;
  final int? lastRemotePort;

  Uint8List get sharedKey => Uint8List.fromList(base64Decode(sharedKeyBase64));
  List<int> get sharedKeyBytes => sharedKey;

  LanTrustedPeer copyWith({
    String? deviceName,
    String? pubKeyBase64,
    String? sharedKeyBase64,
    int? pairedAtMs,
    String? lastHost,
    int? lastPort,
    int? lastRemotePort,
  }) => LanTrustedPeer(
    deviceId: deviceId,
    deviceName: deviceName ?? this.deviceName,
    pubKeyBase64: pubKeyBase64 ?? this.pubKeyBase64,
    sharedKeyBase64: sharedKeyBase64 ?? this.sharedKeyBase64,
    pairedAtMs: pairedAtMs ?? this.pairedAtMs,
    lastHost: lastHost ?? this.lastHost,
    lastPort: lastPort ?? this.lastPort,
    lastRemotePort: lastRemotePort ?? this.lastRemotePort,
  );

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'device_name': deviceName,
    'pub_key': pubKeyBase64,
    'shared_key': sharedKeyBase64,
    'paired_at_ms': pairedAtMs,
    if (lastHost != null) 'last_host': lastHost,
    if (lastPort != null) 'last_port': lastPort,
    if (lastRemotePort != null) 'last_remote_port': lastRemotePort,
  };

  factory LanTrustedPeer.fromJson(Map<String, dynamic> json) => LanTrustedPeer(
    deviceId: json['device_id'] as String? ?? '',
    deviceName: json['device_name'] as String? ?? '',
    pubKeyBase64: json['pub_key'] as String? ?? '',
    sharedKeyBase64: json['shared_key'] as String? ?? '',
    pairedAtMs: (json['paired_at_ms'] as num?)?.toInt() ?? 0,
    lastHost: json['last_host'] as String?,
    lastPort: (json['last_port'] as num?)?.toInt(),
    lastRemotePort: (json['last_remote_port'] as num?)?.toInt(),
  );
}

/// Persists device identity (`device_id`, `sync_device_name`) and trusted LAN
/// remote-control keys inside `sync_metadata`.
///
/// Key names preserve pre-existing `sync_lan_*` storage so paired LAN devices
/// remain paired without requiring re-pairing.
class LanIdentityStore {
  LanIdentityStore(this.db);

  final AppDatabase db;

  static const keyDeviceId = 'device_id';
  static const keyDeviceName = 'sync_device_name';
  static const keyLanPrivKey = 'sync_lan_priv_key';
  static const keyLanPubKey = 'sync_lan_pub_key';
  static const keyLanTrustedPeers = 'sync_lan_trusted_peers';
  static const keyLanPromptedPeers = 'sync_lan_prompted_peers';

  static const _uuid = Uuid();

  Future<String?> _getMeta(String key) async {
    final row = await (db.select(db.syncMetadata)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _setMeta(String key, String value) async {
    await db
        .into(db.syncMetadata)
        .insertOnConflictUpdate(SyncMetadataCompanion.insert(key: key, value: value));
  }

  Future<void> _deleteMeta(String key) async {
    await (db.delete(db.syncMetadata)..where((t) => t.key.equals(key))).go();
  }

  Future<String> getOrCreateDeviceId() async {
    final existing = await _getMeta(keyDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = _uuid.v4();
    await _setMeta(keyDeviceId, created);
    return created;
  }

  Future<String?> getCustomDeviceName() async {
    final saved = (await _getMeta(keyDeviceName))?.trim();
    if (saved == null || saved.isEmpty || !isMeaningfulDeviceName(saved)) {
      return null;
    }
    return saved;
  }

  Future<String> getDeviceName() async {
    final custom = await getCustomDeviceName();
    if (custom != null) return custom;

    try {
      final identity = await DeviceIdentityService.resolve();
      final resolved = identity.deviceName?.trim();
      if (isMeaningfulDeviceName(resolved)) {
        return resolved!;
      }
    } catch (_) {}

    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isIOS) return 'iOS Device';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isLinux) return 'Linux PC';
    return 'TTPlay Device';
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      await _deleteMeta(keyDeviceName);
      return;
    }
    await _setMeta(keyDeviceName, trimmed);
  }

  Future<LanKeyPair> getOrCreateLanKeyPair() async {
    final rawPriv = await _getMeta(keyLanPrivKey);
    final rawPub = await _getMeta(keyLanPubKey);
    if (rawPriv != null && rawPriv.isNotEmpty && rawPub != null && rawPub.isNotEmpty) {
      final clearPriv = await CredentialVault.reveal(rawPriv);
      if (clearPriv != null && clearPriv.isNotEmpty) {
        try {
          final privBytes = base64Decode(clearPriv);
          final pubBytes = base64Decode(rawPub);
          final keyPair = SimpleKeyPairData(
            privBytes,
            publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          return LanKeyPair(keyPair: keyPair, publicKeyBase64: rawPub, privateKeyBase64: clearPriv);
        } catch (e) {
          appLogger.w('Corrupt LAN key pair in sync_metadata, regenerating', error: e);
        }
      }
    }

    final generated = await LanCrypto.generateLanIdentityKeyPair();
    await _setMeta(keyLanPrivKey, await CredentialVault.protect(generated.privateKeyBase64));
    await _setMeta(keyLanPubKey, generated.publicKeyBase64);
    return generated;
  }

  Future<List<LanTrustedPeer>> loadTrustedLanPeers() async {
    final raw = await _getMeta(keyLanTrustedPeers);
    if (raw == null || raw.isEmpty) return const [];
    final clear = await CredentialVault.reveal(raw);
    if (clear == null || clear.isEmpty) return const [];
    try {
      final decoded = jsonDecode(clear);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map)
            () {
              final peer = LanTrustedPeer.fromJson(Map<String, dynamic>.from(entry));
              return peer.deviceId.isNotEmpty && peer.pubKeyBase64.isNotEmpty && peer.sharedKeyBase64.isNotEmpty
                  ? peer
                  : null;
            }(),
      ].whereType<LanTrustedPeer>().toList();
    } catch (e) {
      appLogger.w('Failed to decode trusted LAN peers', error: e);
      return const [];
    }
  }

  Future<void> saveTrustedLanPeers(List<LanTrustedPeer> peers) async {
    if (peers.isEmpty) {
      await _deleteMeta(keyLanTrustedPeers);
      return;
    }
    final encoded = jsonEncode([for (final peer in peers) peer.toJson()]);
    await _setMeta(keyLanTrustedPeers, await CredentialVault.protect(encoded));
  }

  Future<Set<String>> loadPromptedLanPeerIds() async {
    final raw = await _getMeta(keyLanPromptedPeers);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return {for (final item in decoded) if (item is String && item.isNotEmpty) item};
    } catch (_) {
      return {};
    }
  }

  Future<void> markLanPeerPrompted(String deviceId) async {
    if (deviceId.isEmpty) return;
    final current = await loadPromptedLanPeerIds();
    if (!current.add(deviceId)) return;
    await _setMeta(keyLanPromptedPeers, jsonEncode(current.toList()));
  }

  Future<void> savePromptedLanPeerIds(Set<String> ids) async {
    await _setMeta(keyLanPromptedPeers, jsonEncode(ids.where((id) => id.isNotEmpty).toList()));
  }
}
