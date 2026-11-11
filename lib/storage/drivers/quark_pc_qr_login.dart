import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../storage_driver.dart';
import 'quark_pc_session.dart';
import 'quark_qr_login.dart';
import 'quark_wsg.dart';

/// Signs in as the Quark desktop ("PC") client: every request goes through the
/// WSG gateway at `access-open.quark.cn`, where the form is signed and the
/// whole body is WSG-encrypted. On success it returns the desktop session
/// ([QuarkPcSession]) serialized as the secret the mount stores — the driver
/// turns that back into the per-request business headers.
class QuarkPcQrLogin implements QuarkQrAuthenticator {
  QuarkPcQrLogin({HttpClient? httpClient, QuarkWsg? wsg, Uri? gatewayBase, QuarkPcDevice? device})
    : _client = httpClient ?? HttpClient(),
      _wsg = wsg ?? QuarkWsg(),
      _gateway = gatewayBase ?? Uri.parse('https://access-open.quark.cn/wsg_access'),
      // Reuse the mount's stored device on a re-scan, so the account keeps
      // seeing one machine; generate one on a first sign-in.
      _device = device ?? QuarkPcDevice.generate() {
    _client
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
  }

  static const String _clientId = '640';
  static const String _apiVersion = '1.2';
  static const String _clientVersion = '7.5.0.825';
  static const int _statusOk = 20000;
  static const int _statusOkAlt = 20002;
  static const int _statusExpired = 55402;
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/130.0.0.0 Safari/537.36 QuarkPC/$_clientVersion QuarkCloudDrivePC/$_clientVersion';

  final HttpClient _client;
  final QuarkWsg _wsg;
  final Uri _gateway;

  /// The device identity this sign-in reports, carried through every gateway
  /// call and written into the resulting session so later requests match.
  final QuarkPcDevice _device;
  late final String _clientInfo = _makeClientInfo();

  @override
  Future<QuarkQrTicket> start() async {
    final json = await _gatewayCall('cas.getTokenForQrcodeLogin');
    final data = json['data'];
    final token = data is Map ? data['token'] : null;
    if (json['status'] != _statusOk || token is! String || token.isEmpty) {
      throw StorageException(StorageErrorKind.other, 'Quark did not issue a QR code: ${json['message']}');
    }
    final tid = data is Map && data['__trace_id__'] is String ? data['__trace_id__'] as String : const Uuid().v4();
    return QuarkQrTicket(token: token, qrContent: _qrContentFor(token, tid));
  }

  @override
  Future<QuarkQrStatus> poll(QuarkQrTicket ticket) async {
    final json = await _gatewayCall('cas.getServiceTicketByQrcodeToken', extra: {'token': ticket.token});
    final status = json['status'];
    if (status == _statusExpired) return const QuarkQrExpired();
    final data = json['data'];
    final serviceTicket = data is Map ? data['service_ticket'] : null;
    if (status == _statusOk && serviceTicket is String && serviceTicket.isNotEmpty) {
      return QuarkQrSuccess((await _fetchUser(serviceTicket)).serialize());
    }
    // 55401 (waiting), and anything else short of success, means keep polling.
    return const QuarkQrWaiting();
  }

  /// Trades a confirmed ticket for the refreshed ticket and the account's uid
  /// and nickname, which together authenticate every later business request.
  Future<QuarkPcSession> _fetchUser(String serviceTicket) async {
    final json = await _gatewayCall(
      'cas.getUserBasicInfoByServiceTicket',
      extra: {'service_ticket': serviceTicket},
    );
    final status = json['status'];
    final data = json['data'];
    if ((status != _statusOk && status != _statusOkAlt) || data is! Map) {
      throw StorageException(StorageErrorKind.other, 'Quark desktop sign-in failed: ${json['message']}');
    }
    final ticket = data['service_ticket'];
    final uid = data['uid_string'] ?? data['uid'];
    final nickname = data['nickname'];
    if (ticket is! String || ticket.isEmpty || uid == null || nickname is! String) {
      throw const StorageException(StorageErrorKind.other, 'Quark desktop sign-in returned no session');
    }
    return QuarkPcSession(ticket: ticket, uid: '$uid', nickname: nickname, device: _device);
  }

  String _qrContentFor(String token, String tid) {
    const bizOptions = 'S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
    return 'https://su.quark.cn/1_uNQL3'
        '?uc_param_str='
        '&token=${Uri.encodeQueryComponent(token)}'
        '&tid=${Uri.encodeQueryComponent(tid)}'
        '&client_id=$_clientId'
        '&uc_biz_str=${Uri.encodeQueryComponent(bizOptions)}'
        '&platform=win';
  }

  /// One gateway round trip: build and sign the form, WSG-wrap it, POST it as
  /// `text/plain`, and decode the reply (WSG-wrapped unless it is already
  /// JSON).
  Future<Map<String, dynamic>> _gatewayCall(String method, {Map<String, String> extra = const {}}) async {
    final fields = <String, String>{
      'client_id': _clientId,
      'client_info': _clientInfo,
      'method': method,
      'request_id': const Uuid().v4(),
      'v': _apiVersion,
      ...extra,
    };
    fields['sign'] = _wsg.sign(fields);
    final form = (fields.keys.toList()..sort())
        .map((k) => '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(fields[k]!)}')
        .join('&');
    final body = await _wsg.encode(form);

    final String text;
    try {
      final request = await _client.postUrl(_gateway);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'text/plain')
        ..set(HttpHeaders.acceptHeader, '*/*');
      request.add(ascii.encode(body));
      final response = await request.close().timeout(const Duration(seconds: 30));
      text = (await utf8.decodeStream(response).timeout(const Duration(seconds: 30))).trim();
    } on Exception catch (e) {
      throw _network(e);
    }

    final payload = text.startsWith('{') ? text : await _wsg.decodeText(text);
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Fall through.
    }
    throw const StorageException(StorageErrorKind.other, 'Quark sent an unreadable login response');
  }

  String _makeClientInfo() => [
    'app_name:qk_clouddrive',
    'bssid:',
    'client_identity:$_clientId',
    'idfa:',
    'imei:',
    'imsi:',
    'ip:',
    'mac:',
    'machine:${_device.machine}',
    'net_id:',
    'net_type:',
    'os:Windows',
    'port:9001',
    'sn:',
    'ssid:',
    'utdid:${_device.utdid}',
    'version:$_clientVersion',
  ].join('`');

  static StorageException _network(Exception error) {
    if (error is StorageException) return error;
    return StorageException(StorageErrorKind.network, 'Cannot reach Quark', cause: error);
  }

  @override
  void close() => _client.close(force: true);
}
