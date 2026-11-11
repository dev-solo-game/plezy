import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';

import 'quark_wsg.dart';

/// The desktop ("PC") client's device identity: the `utdid` the business query
/// carries and the machine name the login's `client_info` reports. Generated
/// once when a mount first signs in and then persisted with it, so the account
/// keeps seeing one stable device across requests, restarts and re-scans
/// rather than a new machine every time.
class QuarkPcDevice {
  const QuarkPcDevice({required this.utdid, required this.machine});

  /// A fresh identity: an 18-byte `utdid` (a 4-byte big-endian time prefix,
  /// random filler and the client's two marker bytes, Base64-encoded) and a
  /// `DESKTOP-xxxxxx` machine name.
  factory QuarkPcDevice.generate() {
    final random = Random.secure();
    final bytes = Uint8List(18);
    ByteData.view(bytes.buffer).setUint32(0, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    for (var i = 4; i < 18; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[8] = 0x03;
    bytes[9] = 0x00;
    return QuarkPcDevice(
      utdid: base64.encode(bytes),
      machine: 'DESKTOP-${const Uuid().v4().replaceAll('-', '').substring(0, 6).toUpperCase()}',
    );
  }

  /// Restores a persisted device from a JSON map, returning null if incomplete.
  static QuarkPcDevice? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final utdid = json['utdid'];
    final machine = json['machine'];
    if (utdid is String && utdid.isNotEmpty && machine is String && machine.isNotEmpty) {
      return QuarkPcDevice(utdid: utdid, machine: machine);
    }
    return null;
  }

  final String utdid;
  final String machine;

  Map<String, String> toJson() => {'utdid': utdid, 'machine': machine};
}

/// The Quark desktop ("PC") session a mount holds: the refreshed service
/// ticket, the account's uid and nickname, and the [device] identity. Unlike
/// the web client the desktop API carries no session cookie — every request is
/// authenticated by three WSG business headers rebuilt from the ticket, uid
/// and nickname on a fresh millisecond timestamp — so the stored secret is
/// those three plus the device, serialized as JSON.
class QuarkPcSession {
  QuarkPcSession({required this.ticket, required this.uid, required this.nickname, QuarkPcDevice? device})
    : device = device ?? QuarkPcDevice.generate();

  /// Reads a previously persisted device from a serialized [secret], or returns
  /// null for legacy device-less or unreadable secrets.
  static QuarkPcDevice? tryParseDevice(String secret) {
    final trimmed = secret.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      return QuarkPcDevice.tryFromJson(jsonDecode(trimmed));
    } on FormatException {
      return null;
    }
  }

  /// Reads the secret [serialize] writes. Falls back to the earlier
  /// `token=…&uid=…&nickname=…` form (reusing [fallbackDevice] when provided, or
  /// generating one otherwise), so a session stored before the device was
  /// persisted still loads.
  factory QuarkPcSession.parse(String secret, {QuarkPcDevice? fallbackDevice}) {
    if (secret.startsWith('{')) {
      try {
        final json = jsonDecode(secret);
        if (json is Map) {
          return QuarkPcSession(
            ticket: '${json['token'] ?? ''}',
            uid: '${json['uid'] ?? ''}',
            nickname: '${json['nickname'] ?? ''}',
            device: QuarkPcDevice.tryFromJson(json) ?? fallbackDevice,
          );
        }
      } on FormatException {
        // Fall through to the legacy form.
      }
    }

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
      device: fallbackDevice,
    );
  }

  final String ticket;
  final String uid;
  final String nickname;
  final QuarkPcDevice device;

  bool get isValid => ticket.isNotEmpty && uid.isNotEmpty;

  /// The stored secret: the ticket, account and device as JSON.
  String serialize() => jsonEncode({
    'token': ticket,
    'uid': uid,
    'nickname': nickname,
    'utdid': device.utdid,
    'machine': device.machine,
  });

  /// The `x-u-kps-wg` plaintext. Its shape is fixed by the protocol, so it is
  /// kept separate from [serialize].
  String get _kpsPlaintext => 'token=$ticket&uid=$uid&nickname=$nickname';

  /// The three per-request WSG headers. `x-u-vcode` is a millisecond
  /// timestamp; the sign header folds it with the ticket, uid and nickname.
  Future<Map<String, String>> businessHeaders(QuarkWsg wsg) async {
    final vcode = DateTime.now().millisecondsSinceEpoch.toString();
    final signPlain = '${vcode.substring(0, 5)}$ticket$uid$nickname${vcode.substring(vcode.length - 1)}';
    final signMd5 = crypto.md5.convert(utf8.encode(signPlain)).toString();
    return {
      'x-u-vcode': vcode,
      'x-u-kps-wg': await wsg.encode(_kpsPlaintext),
      'x-u-sign-wg': await wsg.encode(signMd5),
    };
  }

  /// The play-scoped `__kuus` cookie value (`name=value`) the play-info call
  /// and the CDN need.
  Future<String> kuusCookie(QuarkWsg wsg) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '__kuus=${await wsg.encode('ucid=$uid&st=$ticket&time=$seconds')}';
  }

  /// The common query every desktop business request carries; `ut` is the
  /// WSG envelope of the persisted device id.
  Future<Map<String, String>> commonQuery(QuarkWsg wsg) async => {
    'uc_param_str': 'utfrpr',
    'device_model': 'Desktop',
    'pr': 'qk_clouddrive',
    'fr': 'win',
    'sys': 'win32',
    've': '7.5.0.825',
    'ut': await wsg.encode(device.utdid),
  };
}
