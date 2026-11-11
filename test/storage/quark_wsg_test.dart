import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';

void main() {
  final wsg = QuarkWsg();

  // Vectors computed from the reference (Python) implementation against the
  // prod gateway constants (`uwRrFVXjBeLMysYN` salt). They pin Dart to the protocol.
  group('QuarkWsg', () {
    test('encode matches the reference envelope', () async {
      expect(await wsg.encode('hello'), 'NekuJk6akqiCpTUTuJKfz1/z');
      expect(await wsg.encode('token=T&uid=U&nickname=N'), 'NelHlcq7CM++p8aMhOzFItdtbhH/aDo+52fEDHQQ8V3g/Q==');
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
      expect(wsg.sign({'a': '1', 'b': '2'}), '35e971172b86505735b593b748a287a961c1605ce109');
      expect(
        wsg.sign({'client_id': '640', 'method': 'cas.getTokenForQrcodeLogin', 'v': '1.2'}),
        '35e926799168bcaafec1a695b1be60a6fbd6159c427a',
      );
    });

    test('sign orders fields by key, not insertion order', () {
      final ordered = wsg.sign({'a': '1', 'b': '2'});
      final shuffled = wsg.sign({'b': '2', 'a': '1'});
      expect(shuffled, ordered);
    });
  });
}
