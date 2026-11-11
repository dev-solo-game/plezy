import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'quark_wsg.dart';

/// The Quark desktop ("PC") session a mount holds: the refreshed service
/// ticket plus the account's uid and nickname. Unlike the web client, the
/// desktop API carries no session cookie — every request is authenticated by
/// three WSG business headers rebuilt from these three values on a fresh
/// millisecond timestamp, so the stored secret is just the three of them.
class QuarkPcSession {
  QuarkPcSession({required this.ticket, required this.uid, required this.nickname, String? utdid})
    : utdid = utdid ?? newUtdid();

  /// Reads the secret [serialize] writes. [nickname] is taken as the whole
  /// remainder, so a nickname containing `&` or `=` survives the round trip.
  factory QuarkPcSession.parse(String secret) {
    String between(String after, String? before) {
      final start = secret.indexOf(after);
      if (start < 0) return '';
      final from = start + after.length;
      if (before == null) return secret.substring(from);
      final end = secret.indexOf(before, from);
      return end < 0 ? secret.substring(from) : secret.substring(from, end);
    }

    return QuarkPcSession(
      ticket: between('token=', '&uid='),
      uid: between('&uid=', '&nickname='),
      nickname: between('&nickname=', null),
    );
  }

  final String ticket;
  final String uid;
  final String nickname;

  /// A per-session device id; the business query carries its WSG envelope. It
  /// need not match the one used at login, so it is generated, not persisted.
  final String utdid;

  bool get isValid => ticket.isNotEmpty && uid.isNotEmpty;

  /// The `token=…&uid=…&nickname=…` string: both the stored secret and the
  /// `x-u-kps-wg` plaintext.
  String serialize() => 'token=$ticket&uid=$uid&nickname=$nickname';

  /// The three per-request WSG headers. [x-u-vcode] is a millisecond
  /// timestamp; the sign header folds it with the ticket, uid and nickname.
  Future<Map<String, String>> businessHeaders(QuarkWsg wsg) async {
    final vcode = DateTime.now().millisecondsSinceEpoch.toString();
    final signPlain = '${vcode.substring(0, 5)}$ticket$uid$nickname${vcode.substring(vcode.length - 1)}';
    final signMd5 = crypto.md5.convert(utf8.encode(signPlain)).toString();
    return {
      'x-u-vcode': vcode,
      'x-u-kps-wg': await wsg.encode(serialize()),
      'x-u-sign-wg': await wsg.encode(signMd5),
    };
  }

  /// The play-scoped `__kuus` cookie value (`name=value`) the play-info call
  /// and the CDN need.
  Future<String> kuusCookie(QuarkWsg wsg) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '__kuus=${await wsg.encode('ucid=$uid&st=$ticket&time=$seconds')}';
  }

  /// The common query every desktop business request carries.
  Future<Map<String, String>> commonQuery(QuarkWsg wsg) async => {
    'uc_param_str': 'utfrpr',
    'device_model': 'Desktop',
    'pr': 'qk_clouddrive',
    'fr': 'win',
    'sys': 'win32',
    've': '7.5.0.825',
    'ut': await wsg.encode(utdid),
  };

  /// A fresh desktop device id: a 4-byte big-endian time prefix, random
  /// filler, and the client's two marker bytes, Base64-encoded.
  static String newUtdid() {
    final random = Random.secure();
    final bytes = Uint8List(18);
    ByteData.view(bytes.buffer).setUint32(0, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    for (var i = 4; i < 18; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[8] = 0x03;
    bytes[9] = 0x00;
    return base64.encode(bytes);
  }
}
