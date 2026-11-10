import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_qr_login.dart';

void main() {
  late HttpServer server;
  late QuarkQrLogin login;
  late Uri base;
  final requests = <Uri>[];
  final cookiesOnInfo = <String?>[];
  var pollStatus = 50004001;

  setUp(() async {
    HttpOverrides.global = null;
    requests.clear();
    cookiesOnInfo.clear();
    pollStatus = 50004001;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      requests.add(request.uri);
      final response = request.response;
      switch (request.uri.path) {
        case '/cas/ajax/getTokenForQrcodeLogin':
          response.headers.add(HttpHeaders.setCookieHeader, 'cas_session=s1; Path=/');
          response.write(
            jsonEncode({
              'status': 2000000,
              'message': 'ok',
              'data': {
                'members': {'token': 'qr-token-1'},
              },
            }),
          );
        case '/cas/ajax/getServiceTicketByQrcodeToken':
          response.write(
            jsonEncode({
              'status': pollStatus,
              'message': pollStatus == 2000000 ? 'ok' : 'Query result is empty',
              if (pollStatus == 2000000)
                'data': {
                  'members': {'service_ticket': 'st-abc'},
                },
            }),
          );
        case '/account/info':
          cookiesOnInfo.add(request.headers.value(HttpHeaders.cookieHeader));
          if (request.uri.queryParameters['hop'] == null) {
            // First hop sets one cookie and redirects, like the real flow.
            response.statusCode = HttpStatus.found;
            response.headers
              ..add(HttpHeaders.setCookieHeader, '__pus=session-1; Path=/; HttpOnly')
              ..set(HttpHeaders.locationHeader, '/account/info?hop=2');
          } else {
            response.headers
              ..add(HttpHeaders.setCookieHeader, '__puus=rotating-1; Path=/')
              ..add(HttpHeaders.setCookieHeader, '__uid=42; Path=/')
              ..add(HttpHeaders.setCookieHeader, 'empty=; Path=/');
            response.write('{}');
          }
      }
      await response.close();
    });
    // The fake's hosts are not *.quark.cn, so the redirect guard would stop
    // the hop; panBase and the redirect share one loopback host on purpose.
    login = QuarkQrLogin(casBase: base, panBase: base, allowedCookieHostSuffix: '127.0.0.1');
  });

  tearDown(() async {
    login.close();
    await server.close(force: true);
  });

  test('start returns a ticket whose QR content matches what the app expects', () async {
    final ticket = await login.start();
    expect(ticket.token, 'qr-token-1');
    // Byte-for-byte: the app rejects the code when the empty parameter loses
    // its "=".
    expect(
      ticket.qrContent,
      'https://su.quark.cn/4_eMHBJ?token=qr-token-1&client_id=532&ssb=weblogin&uc_param_str='
      '&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400',
    );
  });

  test('poll reports waiting, then expired, with a fresh request id each time', () async {
    final ticket = await login.start();
    expect(await login.poll(ticket), isA<QuarkQrWaiting>());
    expect(await login.poll(ticket), isA<QuarkQrWaiting>());
    for (final failed in [50004002, 50004003, 50004004]) {
      pollStatus = failed;
      expect(await login.poll(ticket), isA<QuarkQrExpired>());
    }
    final ids = requests.map((u) => u.queryParameters['request_id']).toSet();
    expect(ids.length, requests.length);
    expect(requests.last.queryParameters['token'], 'qr-token-1');
  });

  test('an unrecognised poll status keeps waiting', () async {
    final ticket = await login.start();
    pollStatus = 50000000;
    expect(await login.poll(ticket), isA<QuarkQrWaiting>());
  });

  test('a confirmed login collects cookies across the redirect', () async {
    final ticket = await login.start();
    pollStatus = 2000000;
    final status = await login.poll(ticket);
    expect(status, isA<QuarkQrSuccess>());
    expect((status as QuarkQrSuccess).cookie, 'cas_session=s1; __pus=session-1; __puus=rotating-1; __uid=42');
    expect(cookiesOnInfo, [
      'cas_session=s1',
      'cas_session=s1; __pus=session-1',
    ], reason: 'the session keeps cookies from every earlier response');
    expect(requests.firstWhere((u) => u.path == '/account/info').queryParameters['st'], 'st-abc');
  });
}
