import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Quark's desktop ("PC") client wraps every gateway and business request in
/// its WSG scheme: an AES-128-CBC envelope with a two-byte selector, plus an
/// HMAC-SHA1 gateway signature. This reimplements the two primitives the
/// native `wsg_impl.dll` exposes — `EncryptToBase64` and `Sign` — so the
/// desktop API can be reached without the official client installed.
///
/// The key material (`_hmacKey`, `_salt`, `_selector`) are constants the
/// client holds globally; they are not tied to a machine or account and have
/// held across desktop builds (7.5.0.825 → .826). If a future Quark release
/// rotates them, the desktop sign-in stops working until they are updated
/// here. They are measured from client version 7.5.0.825.
class QuarkWsg {
  QuarkWsg();

  /// The desktop client's protocol key, used both as the HMAC-SHA1 key for
  /// gateway signatures and, via its MD5, as the AES key.
  static const String _hmacKey = 'C88EAC2B-F07C-4FE2-ABDF-C8F049C46C7B';

  /// Appended to the signing input before the HMAC (prod `access-open.quark.cn`
  /// gateway salt; `nyztq31FYcsAvECM` is Quark's daily environment salt).
  static const String _salt = 'uwRrFVXjBeLMysYN';

  /// The two-byte envelope marker (big-endian `0x35e9`) and the hex prefix a
  /// signature carries.
  static const int _selector = 0x35e9;

  static final List<int> _hmacKeyBytes = ascii.encode(_hmacKey);
  static final List<int> _saltBytes = ascii.encode(_salt);

  /// AES key and IV, both `md5(hmacKey)[:16]` as ASCII. The desktop client
  /// uses the same 16 bytes for key and IV.
  static final List<int> _aesKeyIv = ascii.encode(crypto.md5.convert(_hmacKeyBytes).toString().substring(0, 16));

  static final AesCbc _aes = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
  static final SecretKey _secretKey = SecretKey(_aesKeyIv);

  /// `EncryptToBase64`: PKCS#7-pad, AES-128-CBC encrypt, prepend the selector,
  /// Base64. Used for request bodies and for the WSG business headers.
  Future<String> encode(String plaintext) async {
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey: _secretKey, nonce: _aesKeyIv);
    final body = Uint8List(2 + box.cipherText.length)
      ..[0] = (_selector >> 8) & 0xff
      ..[1] = _selector & 0xff
      ..setRange(2, 2 + box.cipherText.length, box.cipherText);
    return base64.encode(body);
  }

  /// Reverse of [encode]: strip the selector, AES-decrypt, unpad. Gateway
  /// replies that are not already JSON come back WSG-wrapped.
  Future<Uint8List> decode(String b64) async {
    final raw = base64.decode(b64);
    if (raw.length < 2 || raw[0] != ((_selector >> 8) & 0xff) || raw[1] != (_selector & 0xff)) {
      throw const FormatException('WSG selector mismatch');
    }
    final clear = await _aes.decrypt(
      SecretBox(raw.sublist(2), nonce: _aesKeyIv, mac: Mac.empty),
      secretKey: _secretKey,
    );
    return Uint8List.fromList(clear);
  }

  /// Decodes a WSG reply as UTF-8 text.
  Future<String> decodeText(String b64) async => utf8.decode(await decode(b64));

  /// `Sign`: sort the fields by key, join them as `k1=v1k2=v2…` with no
  /// separators, append the salt, HMAC-SHA1 under the protocol key, and
  /// prefix the selector's hex. This is the gateway `sign` field.
  String sign(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in keys) {
      buffer
        ..write(key)
        ..write('=')
        ..write(params[key]);
    }
    final input = <int>[...utf8.encode(buffer.toString()), ..._saltBytes];
    final digest = crypto.Hmac(crypto.sha1, _hmacKeyBytes).convert(input);
    return '${_selector.toRadixString(16).padLeft(4, '0')}$digest';
  }
}
