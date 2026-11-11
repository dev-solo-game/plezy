import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_pc_session.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';

void main() {
  final wsg = QuarkWsg();
  const device = QuarkPcDevice(utdid: 'UT', machine: 'DESKTOP-ABC123');

  group('QuarkPcSession', () {
    test('serialize/parse round trips the account and device', () {
      for (final nickname in ['Nick', '阿福', 'a&b=c', '']) {
        final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: nickname, device: device);
        final parsed = QuarkPcSession.parse(session.serialize());
        expect(parsed.ticket, 'TK');
        expect(parsed.uid, '42');
        expect(parsed.nickname, nickname);
        expect(parsed.device.utdid, 'UT');
        expect(parsed.device.machine, 'DESKTOP-ABC123');
      }
    });

    test('parses the legacy device-less form, minting a device', () {
      final parsed = QuarkPcSession.parse('token=TK&uid=42&nickname=Nick');
      expect(parsed.ticket, 'TK');
      expect(parsed.uid, '42');
      expect(parsed.nickname, 'Nick');
      expect(parsed.device.utdid, isNotEmpty);
    });

    test('business headers decode back to the signed material', () async {
      final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: 'Nick', device: device);
      final headers = await session.businessHeaders(wsg);

      expect(int.tryParse(headers['x-u-vcode']!), isNotNull);
      expect(await wsg.decodeText(headers['x-u-kps-wg']!), 'token=TK&uid=42&nickname=Nick');
      // The sign header carries a 32-char MD5 hex digest.
      expect(await wsg.decodeText(headers['x-u-sign-wg']!), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('kuus cookie and common query carry the session and device', () async {
      final session = QuarkPcSession(ticket: 'TK', uid: '42', nickname: 'Nick', device: device);
      final kuus = await session.kuusCookie(wsg);
      expect(kuus, startsWith('__kuus='));
      final kuusPlain = await wsg.decodeText(kuus.substring('__kuus='.length));
      expect(kuusPlain, matches(RegExp(r'^ucid=42&st=TK&time=\d+$')));

      final query = await session.commonQuery(wsg);
      expect(query['fr'], 'win');
      expect(await wsg.decodeText(query['ut']!), 'UT');
    });

    test('a generated device is a plausible desktop identity', () {
      final generated = QuarkPcDevice.generate();
      expect(generated.utdid, isNotEmpty);
      expect(generated.machine, startsWith('DESKTOP-'));
      // Distinct machines each time.
      expect(generated.machine, isNot(QuarkPcDevice.generate().machine));
    });

    test('isValid needs a ticket and uid', () {
      expect(QuarkPcSession(ticket: 'TK', uid: '42', nickname: '').isValid, isTrue);
      expect(QuarkPcSession(ticket: '', uid: '42', nickname: '').isValid, isFalse);
      expect(QuarkPcSession.parse('garbage').isValid, isFalse);
    });
  });
}
