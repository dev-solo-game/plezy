import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_pc_session.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';

void main() {
  final wsg = QuarkWsg();

  group('QuarkPcSession', () {
    test('serialize/parse round trips, nickname included', () {
      for (final nickname in ['Nick', '阿福', 'a&b=c', '']) {
        final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: nickname);
        final parsed = QuarkPcSession.parse(session.serialize());
        expect(parsed.ticket, 'TK');
        expect(parsed.uid, '42');
        expect(parsed.nickname, nickname);
      }
    });

    test('business headers decode back to the signed material', () async {
      final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: 'Nick');
      final headers = await session.businessHeaders(wsg);

      expect(int.tryParse(headers['x-u-vcode']!), isNotNull);
      expect(await wsg.decodeText(headers['x-u-kps-wg']!), 'token=TK&uid=42&nickname=Nick');
      // The sign header carries a 32-char MD5 hex digest.
      expect(await wsg.decodeText(headers['x-u-sign-wg']!), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('kuus cookie and common query carry the session', () async {
      final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: 'Nick', utdid: 'UT');
      final kuus = await session.kuusCookie(wsg);
      expect(kuus, startsWith('__kuus='));
      final kuusPlain = await wsg.decodeText(kuus.substring('__kuus='.length));
      expect(kuusPlain, matches(RegExp(r'^ucid=42&st=TK&time=\d+$')));

      final query = await session.commonQuery(wsg);
      expect(query['fr'], 'win');
      expect(await wsg.decodeText(query['ut']!), 'UT');
    });

    test('isValid needs a ticket and uid', () {
      expect(QuarkPcSession(ticket: 'TK', uid: '42', nickname: '').isValid, isTrue);
      expect(QuarkPcSession(ticket: '', uid: '42', nickname: '').isValid, isFalse);
      expect(QuarkPcSession.parse('garbage').isValid, isFalse);
    });
  });
}
