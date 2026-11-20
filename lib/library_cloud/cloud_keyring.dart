import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Client-side E2EE keyring matching `media_library/internal/keyring`.
///
/// The 256-bit household master key (HK) is generated on the client during
/// registration and NEVER sent to the server in plaintext. Only PBKDF2-SHA256 +
/// AES-256-GCM wrapped blobs (`account_password` / `recovery_code`) are stored
/// server-side.
class CloudKeyring {
  static const int keyLengthBytes = 32;
  static const int nonceLengthBytes = 12;
  static const int macLengthBytes = 16;
  static const int defaultPbkdf2Iterations = 600000;
  static const String wrapTypeAccountPassword = 'account_password';
  static const String wrapTypeRecoveryCode = 'recovery_code';
  static const String kdfAlgPbkdf2Sha256 = 'pbkdf2-sha256';

  static final AesGcm _aesGcm = AesGcm.with256bits();

  /// Generates a cryptographically secure 256-bit random master key.
  static Uint8List generateMasterKey() {
    final rng = Random.secure();
    final bytes = Uint8List(keyLengthBytes);
    for (var i = 0; i < keyLengthBytes; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  /// Generates random bytes of [length].
  static Uint8List randomBytes(int length) {
    final rng = Random.secure();
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  /// Computes deterministic HMAC-SHA256 identity key for media source deduplication.
  static String computeIdentityKey(Uint8List masterKey, String normalizedValue) {
    final hmac = crypto.Hmac(crypto.sha256, masterKey);
    final digest = hmac.convert(utf8.encode(normalizedValue.trim()));
    return digest.toString();
  }

  /// Derives a 256-bit KEK from [secret] using PBKDF2-HMAC-SHA256.
  static Future<SecretKey> _deriveKek({
    required String secret,
    required List<int> salt,
    required int iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: salt,
    );
  }

  /// Wraps [masterKey] with [password] into the JSON payload expected by
  /// `media_library`'s `KeyWrapInput`.
  static Future<Map<String, dynamic>> wrapMasterKey({
    required Uint8List masterKey,
    required String password,
    String wrapType = wrapTypeAccountPassword,
    int keyEpoch = 1,
    int iterations = defaultPbkdf2Iterations,
  }) async {
    final salt = randomBytes(16);
    final kek = await _deriveKek(secret: password, salt: salt, iterations: iterations);
    final nonce = randomBytes(nonceLengthBytes);
    final box = await _aesGcm.encrypt(
      masterKey,
      secretKey: kek,
      nonce: nonce,
      aad: utf8.encode('$wrapType:$keyEpoch'),
    );
    final packed = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, box.cipherText)
      ..setAll(nonce.length + box.cipherText.length, box.mac.bytes);

    return {
      'wrap_type': wrapType,
      'kdf_alg': kdfAlgPbkdf2Sha256,
      'kdf_salt': base64Encode(salt),
      'kdf_params_json': jsonEncode({'iterations': iterations}),
      'wrapped_hk': base64Encode(packed),
      'key_epoch': keyEpoch,
    };
  }

  /// Unwraps a server-returned `KeyWrap` JSON object using [password].
  static Future<Uint8List> unwrapMasterKey({
    required Map<String, dynamic> wrap,
    required String password,
  }) async {
    final alg = (wrap['kdf_alg'] as String? ?? '').trim().toLowerCase();
    if (alg != kdfAlgPbkdf2Sha256) {
      throw UnsupportedError('Unsupported KDF algorithm: $alg');
    }
    final wrapType = (wrap['wrap_type'] as String? ?? wrapTypeAccountPassword).trim();
    final keyEpoch = (wrap['key_epoch'] as num?)?.toInt() ?? 1;
    final salt = base64Decode(wrap['kdf_salt'] as String? ?? '');
    final paramsRaw = wrap['kdf_params_json'] as String? ?? '{}';
    final params = jsonDecode(paramsRaw) as Map<String, dynamic>;
    final iterations = (params['iterations'] as num?)?.toInt() ?? defaultPbkdf2Iterations;

    final packed = base64Decode(wrap['wrapped_hk'] as String? ?? '');
    if (packed.length < nonceLengthBytes + macLengthBytes) {
      throw const FormatException('Corrupted wrapped master key payload');
    }
    final nonce = packed.sublist(0, nonceLengthBytes);
    final cipherText = packed.sublist(nonceLengthBytes, packed.length - macLengthBytes);
    final mac = Mac(packed.sublist(packed.length - macLengthBytes));

    final kek = await _deriveKek(secret: password, salt: salt, iterations: iterations);
    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: kek,
      aad: utf8.encode('$wrapType:$keyEpoch'),
    );
    return Uint8List.fromList(clear);
  }

  /// Encrypts a media source credential map into a base64 AES-256-GCM string.
  static Future<String> encryptCredentialJson({
    required Uint8List masterKey,
    required Map<String, dynamic> payload,
    String aad = 'source_credential:v1',
  }) async {
    final nonce = randomBytes(nonceLengthBytes);
    final clear = utf8.encode(jsonEncode(payload));
    final box = await _aesGcm.encrypt(
      clear,
      secretKey: SecretKey(masterKey),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    final packed = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, box.cipherText)
      ..setAll(nonce.length + box.cipherText.length, box.mac.bytes);
    return base64Encode(packed);
  }

  /// Decrypts a base64 AES-256-GCM source credential string back into a JSON map.
  static Future<Map<String, dynamic>> decryptCredentialJson({
    required Uint8List masterKey,
    required String ciphertextB64,
    String aad = 'source_credential:v1',
  }) async {
    final packed = base64Decode(ciphertextB64.trim());
    if (packed.length < nonceLengthBytes + macLengthBytes) {
      throw const FormatException('Corrupted credential ciphertext');
    }
    final nonce = packed.sublist(0, nonceLengthBytes);
    final cipherText = packed.sublist(nonceLengthBytes, packed.length - macLengthBytes);
    final mac = Mac(packed.sublist(packed.length - macLengthBytes));

    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(masterKey),
      aad: utf8.encode(aad),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map) {
      throw const FormatException('Decrypted credential is not a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
