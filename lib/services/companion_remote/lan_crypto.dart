import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

class LanKeyPair {
  const LanKeyPair({
    required this.keyPair,
    required this.publicKeyBase64,
    required this.privateKeyBase64,
  });

  final SimpleKeyPair keyPair;
  final String publicKeyBase64;
  final String privateKeyBase64;
}

/// Cryptographic primitives for LAN peer discovery, 4-digit SAS verification,
/// and pairwise X25519 + HKDF shared secret derivation.
abstract final class LanCrypto {
  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<LanKeyPair> generateLanIdentityKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    final priv = await keyPair.extractPrivateKeyBytes();
    return LanKeyPair(
      keyPair: keyPair,
      publicKeyBase64: base64Encode(pub.bytes),
      privateKeyBase64: base64Encode(priv),
    );
  }

  static Future<Uint8List> deriveLanSharedKey({
    required String myPrivateKeyBase64,
    required String myPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) async {
    final privBytes = base64Decode(myPrivateKeyBase64);
    final myPubBytes = base64Decode(myPublicKeyBase64);
    final peerPubBytes = base64Decode(peerPublicKeyBase64);

    final ownKeyPair = SimpleKeyPairData(
      privBytes,
      publicKey: SimplePublicKey(myPubBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final peerPubKey = SimplePublicKey(peerPubBytes, type: KeyPairType.x25519);
    final sharedSecret = await _x25519.sharedSecretKey(keyPair: ownKeyPair, remotePublicKey: peerPubKey);

    final derived = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: const [],
      info: utf8.encode('plezy-lan-p2p-v1'),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  static String pairingCodeForKeys(String pubKeyA, String pubKeyB) {
    final sorted = [pubKeyA, pubKeyB]..sort();
    final digest = crypto.sha256.convert(utf8.encode('${sorted[0]}|${sorted[1]}')).bytes;
    final num = ((digest[0] << 8) | digest[1]) % 10000;
    return num.toString().padLeft(4, '0');
  }

  static String hmacSha256Base64(List<int> key, List<int> message) {
    final mac = crypto.Hmac(crypto.sha256, key).convert(message);
    return base64Encode(mac.bytes);
  }

  static bool constantTimeEquals(String a, String b) {
    final bytesA = utf8.encode(a);
    final bytesB = utf8.encode(b);
    if (bytesA.length != bytesB.length) return false;
    var diff = 0;
    for (var i = 0; i < bytesA.length; i++) {
      diff |= bytesA[i] ^ bytesB[i];
    }
    return diff == 0;
  }
}
