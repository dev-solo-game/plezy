import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

class SyncKdfParams {
  const SyncKdfParams({this.memoryKiB = 16384, this.iterations = 2, this.parallelism = 1});

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() => {'algo': 'argon2id', 'm': memoryKiB, 't': iterations, 'p': parallelism};

  factory SyncKdfParams.fromJson(Map<String, dynamic> json) => SyncKdfParams(
    memoryKiB: (json['m'] as num?)?.toInt() ?? 16384,
    iterations: (json['t'] as num?)?.toInt() ?? 2,
    parallelism: (json['p'] as num?)?.toInt() ?? 1,
  );
}

class SyncQrKeyPair {
  const SyncQrKeyPair({required this.keyPair, required this.publicKeyBase64});

  final SimpleKeyPair keyPair;
  final String publicKeyBase64;
}

enum SyncServerKind { official, selfHosted }

const String defaultOfficialSyncUrl = String.fromEnvironment(
  'OFFICIAL_SYNC_URL',
  defaultValue: 'http://10.0.10.48:8088',
);

String normalizeSyncServerUrl(String raw) => raw.trim().replaceAll(RegExp(r'/+$'), '');

SyncServerKind inferSyncServerKind(String serverUrl) =>
    normalizeSyncServerUrl(serverUrl).toLowerCase() == normalizeSyncServerUrl(defaultOfficialSyncUrl).toLowerCase()
    ? SyncServerKind.official
    : SyncServerKind.selfHosted;

class SyncSessionCredentials {
  SyncSessionCredentials({
    required this.serverUrl,
    required this.userId,
    required this.username,
    required this.accessToken,
    required this.masterKey,
    SyncServerKind? serverKind,
  }) : serverKind = serverKind ?? inferSyncServerKind(serverUrl);

  final String serverUrl;
  final String userId;
  final String username;
  final String accessToken;
  final Uint8List masterKey;
  final SyncServerKind serverKind;
}

/// End-to-end encryption primitives for multi-device synchronization:
/// - 256-bit random `MasterKey` protecting storage credentials via `AES-256-GCM`
/// - `Argon2id` + `HKDF-SHA256` deriving independent login `authVerifier` and `KEK`
/// - `X25519` ephemeral ECDH + `AES-256-GCM` for 1-second TV QR key handoff
abstract final class SyncCrypto {
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  static final X25519 _x25519 = X25519();
  static final Random _rng = Random.secure();

  static const String _backupPrefix = 'enc:mk:v1:';
  static const String _payloadPrefix = 'enc:e2ee:v1:';
  static const String _qrPrefix = 'enc:qr:v1:';

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static Uint8List generateMasterKey() => randomBytes(32);

  static Future<({Uint8List kek, String authVerifier})> derivePasswordKeys({
    required String password,
    required List<int> salt,
    SyncKdfParams params = const SyncKdfParams(),
  }) async {
    final argon2 = Argon2id(
      memory: params.memoryKiB,
      parallelism: params.parallelism,
      iterations: params.iterations,
      hashLength: 32,
    );
    final rootKey = await argon2.deriveKeyFromPassword(password: password, nonce: salt);
    final kekKey = await _hkdf.deriveKey(secretKey: rootKey, nonce: const [], info: utf8.encode('plezy-sync-kek-v1'));
    final authKey = await _hkdf.deriveKey(secretKey: rootKey, nonce: const [], info: utf8.encode('plezy-sync-auth-v1'));
    return (
      kek: Uint8List.fromList(await kekKey.extractBytes()),
      authVerifier: base64Encode(await authKey.extractBytes()),
    );
  }

  static Future<String> sealMasterKeyBackup(Uint8List masterKey, Uint8List kek) =>
      _sealWithPrefix(_backupPrefix, masterKey, kek);

  static Future<Uint8List> unsealMasterKeyBackup(String envelope, Uint8List kek) =>
      _unsealWithPrefix(_backupPrefix, envelope, kek);

  static Future<String> encryptPayload(String plaintext, Uint8List masterKey) =>
      _sealWithPrefix(_payloadPrefix, utf8.encode(plaintext), masterKey);

  static Future<String> decryptPayload(String ciphertext, Uint8List masterKey) async =>
      utf8.decode(await _unsealWithPrefix(_payloadPrefix, ciphertext, masterKey));

  static Future<SyncQrKeyPair> generateQrKeyPair() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return SyncQrKeyPair(keyPair: kp, publicKeyBase64: base64Encode(pub.bytes));
  }

  static Future<({String privateKeyBase64, String publicKeyBase64})> generateLanIdentityKeyPair() async {
    final kp = await _x25519.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (privateKeyBase64: base64Encode(priv), publicKeyBase64: base64Encode(pub.bytes));
  }

  static Future<Uint8List> deriveLanSharedKey({
    required String myPrivateKeyBase64,
    required String myPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) async {
    final myPriv = SimpleKeyPairData(
      base64Decode(myPrivateKeyBase64),
      publicKey: SimplePublicKey(base64Decode(myPublicKeyBase64), type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final peerPub = SimplePublicKey(base64Decode(peerPublicKeyBase64), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: myPriv, remotePublicKey: peerPub);
    final derived = await _hkdf.deriveKey(secretKey: shared, nonce: const [], info: utf8.encode('plezy-lan-p2p-v1'));
    return Uint8List.fromList(await derived.extractBytes());
  }

  static String computePairingCode(String pubKeyA, String pubKeyB) {
    final ordered = [pubKeyA, pubKeyB]..sort();
    final digest = crypto.sha256.convert(utf8.encode('${ordered.first}|${ordered.last}')).bytes;
    final numeric = ((digest[0] << 8) | digest[1]) % 10000;
    return numeric.toString().padLeft(4, '0');
  }

  static String hmacSha256Base64({required Uint8List key, required String message}) {
    final digest = crypto.Hmac(crypto.sha256, key).convert(utf8.encode(message));
    return base64Encode(digest.bytes);
  }

  static bool constantTimeEquals(String a, String b) {
    final ba = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ba.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ba.length; i++) {
      diff |= ba[i] ^ bb[i];
    }
    return diff == 0;
  }

  static Future<String> sealMasterKeyForTv({required Uint8List masterKey, required String tvPubKeyBase64}) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemPub = await ephemeral.extractPublicKey();
    final tvPub = SimplePublicKey(base64Decode(tvPubKeyBase64), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: ephemeral, remotePublicKey: tvPub);
    final wrapKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('plezy-sync-qr-wrap-v1'),
    );
    final box = await _aesGcm.encrypt(masterKey, secretKey: wrapKey);
    return '$_qrPrefix${jsonEncode({'epk': base64Encode(ephemPub.bytes), 'n': base64Encode(box.nonce), 'c': base64Encode(box.cipherText), 'm': base64Encode(box.mac.bytes)})}';
  }

  static Future<Uint8List> unsealMasterKeyOnTv({
    required String sealedEnvelope,
    required SimpleKeyPair tvKeyPair,
  }) async {
    if (!sealedEnvelope.startsWith(_qrPrefix)) {
      throw const FormatException('Unsupported sealed QR key envelope');
    }
    final map = jsonDecode(sealedEnvelope.substring(_qrPrefix.length)) as Map<String, dynamic>;
    final epk = SimplePublicKey(base64Decode(map['epk'] as String), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: tvKeyPair, remotePublicKey: epk);
    final wrapKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('plezy-sync-qr-wrap-v1'),
    );
    final box = SecretBox(
      base64Decode(map['c'] as String),
      nonce: base64Decode(map['n'] as String),
      mac: Mac(base64Decode(map['m'] as String)),
    );
    return Uint8List.fromList(await _aesGcm.decrypt(box, secretKey: wrapKey));
  }

  static Future<String> _sealWithPrefix(String prefix, List<int> plaintext, Uint8List keyBytes) async {
    final box = await _aesGcm.encrypt(plaintext, secretKey: SecretKey(keyBytes));
    return '$prefix${jsonEncode({'n': base64Encode(box.nonce), 'c': base64Encode(box.cipherText), 'm': base64Encode(box.mac.bytes)})}';
  }

  static Future<Uint8List> _unsealWithPrefix(String prefix, String envelope, Uint8List keyBytes) async {
    if (!envelope.startsWith(prefix)) {
      throw FormatException('Expected encrypted envelope starting with $prefix');
    }
    final map = jsonDecode(envelope.substring(prefix.length)) as Map<String, dynamic>;
    final box = SecretBox(
      base64Decode(map['c'] as String),
      nonce: base64Decode(map['n'] as String),
      mac: Mac(base64Decode(map['m'] as String)),
    );
    return Uint8List.fromList(await _aesGcm.decrypt(box, secretKey: SecretKey(keyBytes)));
  }
}
