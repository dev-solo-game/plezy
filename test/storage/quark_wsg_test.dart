import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';

void main() {
  final wsg = QuarkWsg();

  // Vectors computed from the reference (Python) implementation against the
  // measured 7.5.0.825 constants. They pin the Dart cipher to the protocol.
  group('QuarkWsg', () {
    test('encode matches the reference envelope', () async {
      expect(await wsg.encode('hello'), 'NekuJk6akqiCpTUTuJKfz1/z');
      expect(
        await wsg.encode('token=T&uid=U&nickname=N'),
        'NelHlcq7CM++p8aMhOzFItdtbhH/aDo+52fEDHQQ8V3g/Q==',
      );
    });

    test('decode reverses encode', () async {
      for (final text in ['', 'hello', 'token=T&uid=U&nickname=N', '原画 1080P']) {
        expect(utf8.decode(await wsg.decode(await wsg.encode(text))), text);
      }
    });

    test('decode rejects a wrong selector', () async {
      expect(() => wsg.decode(base64.encode([0, 0, 1, 2, 3, 4])), throwsFormatException);
    });

    test('sign matches the reference HMAC', () {
      expect(wsg.sign({'a': '1', 'b': '2'}), '35e96fc1ffb3a2d50b38a5845950c53b2dbf7d383738');
      expect(
        wsg.sign({'client_id': '640', 'method': 'cas.getTokenForQrcodeLogin', 'v': '1.2'}),
        '35e9c0360a0b287c8462d570d06e84110148a3fc63a1',
      );
    });

    test('sign orders fields by key, not insertion order', () {
      final ordered = wsg.sign({'a': '1', 'b': '2'});
      final shuffled = wsg.sign({'b': '2', 'a': '1'});
      expect(shuffled, ordered);
    });
  });
}
