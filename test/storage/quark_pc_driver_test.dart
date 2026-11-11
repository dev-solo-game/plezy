import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';
import 'package:plezy/storage/storage_driver.dart';

/// Drives the desktop ("PC") transport end to end against a fake drive-pc
/// host: the request must carry the three WSG business headers and the
/// `__kuus` cookie, and the WSG-encrypted body must decode to the fids
/// payload. The reply keys `video_list` by fid, as the desktop API does.
void main() {
  group('Quark PC driver', () {
    late HttpServer server;
    late QuarkStorageDriver driver;
    final wsg = QuarkWsg();
    final requests = <HttpRequest>[];
    String? decodedBody;

    setUp(() async {
      HttpOverrides.global = null;
      requests.clear();
      decodedBody = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request);
        final raw = await utf8.decodeStream(request);
        final response = request.response;
        if (request.uri.path.endsWith('/batch/file/play/info')) {
          decodedBody = await wsg.decodeText(raw);
          response.headers
            ..contentType = ContentType.json
            ..add(HttpHeaders.setCookieHeader, 'Video-Auth=va-1; Path=/; HttpOnly');
          response.write(
            jsonEncode({
              'code': 0,
              'data': {
                'fid-1': {
                  'video_list': [
                    {
                      'resolution': 'low',
                      'video_info': {'url': 'https://cdn.example/low.m3u8', 'width': 480, 'height': 270},
                    },
                    {
                      'resolution': 'super',
                      'trans_status': 'raw',
                      'video_info': {'url': 'https://cdn.example/super.mp4', 'width': 1920, 'height': 1080},
                    },
                  ],
                },
              },
            }),
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      driver = QuarkStorageDriver(
        cookie: 'token=TK&uid=42&nickname=Nick',
        mode: QuarkMode.pc,
        requestInterval: Duration.zero,
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive'),
      );
    });

    tearDown(() async {
      await driver.close();
      await server.close(force: true);
    });

    test('signs the play-info request and reads the fid-keyed renditions', () async {
      const entry = StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1');
      final variants = await driver.streamVariants(entry);

      // Best first, both playable renditions, with their real sizes.
      expect([for (final v in variants) v.id], ['super', 'low']);
      expect(variants.first.height, 1080);

      // The CDN headers carry the play cookie and the renewed Video-Auth.
      final cookie = variants.first.headers[HttpHeaders.cookieHeader];
      expect(cookie, startsWith('__kuus='));
      expect(cookie, endsWith('; Video-Auth=va-1'));

      // The request was signed and encrypted, not sent in the clear.
      final request = requests.single;
      expect(request.headers.value('x-u-vcode'), isNotNull);
      expect(request.headers.value('x-u-kps-wg'), isNotNull);
      expect(request.headers.value('x-u-sign-wg'), isNotNull);
      expect(request.headers.value('x-u-content-encoding'), 'wg');
      expect(request.uri.queryParameters['fr'], 'win');
      expect(jsonDecode(decodedBody!)['fids'], ['fid-1']);
    });
  });
}
