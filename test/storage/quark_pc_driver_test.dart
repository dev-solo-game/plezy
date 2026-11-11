import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_pc_session.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/drivers/quark_wsg.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/storage_mount.dart';

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
    final cdnCookies = <String?>[];
    String? decodedBody;
    String? downloadDecodedBody;
    var rejectDownload = false;

    setUp(() async {
      HttpOverrides.global = null;
      requests.clear();
      cdnCookies.clear();
      decodedBody = null;
      downloadDecodedBody = null;
      rejectDownload = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final raw = await utf8.decodeStream(request);
        final response = request.response;
        final path = request.uri.path;
        if (path.startsWith('/cdn/')) {
          final cookie = request.headers.value(HttpHeaders.cookieHeader);
          cdnCookies.add(cookie);
          if (cookie == null || !cookie.contains('__kuus=')) {
            response.statusCode = HttpStatus.forbidden;
            return response.close();
          }
          if (path == '/cdn/super.mp4' && !cookie.contains('Video-Auth=va-1')) {
            response.statusCode = HttpStatus.preconditionFailed;
            return response.close();
          }
          response.statusCode = HttpStatus.partialContent;
          response.add([10, 11, 12, 13]);
          return response.close();
        }
        requests.add(request);
        if (path.endsWith('/batch/file/play/info')) {
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
                      'video_info': {'url': 'http://127.0.0.1:${server.port}/cdn/super.mp4', 'width': 1920, 'height': 1080},
                    },
                  ],
                },
              },
            }),
          );
        } else if (path.endsWith('/file/download')) {
          downloadDecodedBody = await wsg.decodeText(raw);
          if (rejectDownload) {
            response.statusCode = HttpStatus.badRequest;
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode({'status': 400, 'code': 23008, 'message': 'only svip'}));
          } else {
            response.headers.contentType = ContentType.json;
            response.write(
              jsonEncode({
                'code': 0,
                'data': [
                  {'fid': 'fid-1', 'download_url': 'http://127.0.0.1:${server.port}/cdn/dl.mkv'},
                ],
              }),
            );
          }
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

    test('openRead signs /file/download with WSG body and sends __kuus to CDN', () async {
      const entry = StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1');
      final bytes = await driver.openRead(entry, start: 0, end: 3).expand((c) => c).toList();
      expect(bytes, [10, 11, 12, 13]);

      final dlRequest = requests.single;
      expect(dlRequest.uri.path, endsWith('/file/download'));
      expect(dlRequest.headers.value('x-u-vcode'), isNotNull);
      expect(dlRequest.headers.value('x-u-kps-wg'), isNotNull);
      expect(dlRequest.headers.value('x-u-sign-wg'), isNotNull);
      expect(dlRequest.headers.value('x-u-content-encoding'), 'wg');
      expect(dlRequest.headers.value(HttpHeaders.cookieHeader), startsWith('__kuus='));
      expect(jsonDecode(downloadDecodedBody!)['fids'], ['fid-1']);
      expect(cdnCookies.single, startsWith('__kuus='));
    });

    test('openRead reuses cached non-HLS raw rendition without calling /file/download', () async {
      const entry = StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1');
      await driver.streamVariants(entry);
      final bytes = await driver.openRead(entry, start: 0, end: 3).expand((c) => c).toList();
      expect(bytes, [10, 11, 12, 13]);

      expect(requests.map((r) => r.uri.path), [endsWith('/batch/file/play/info')]);
      expect(cdnCookies.single, allOf(startsWith('__kuus='), endsWith('; Video-Auth=va-1')));
    });

    test('openRead falls back to raw playInfo stream when /file/download fails', () async {
      rejectDownload = true;
      const entry = StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1');
      final bytes = await driver.openRead(entry, start: 0, end: 3).expand((c) => c).toList();
      expect(bytes, [10, 11, 12, 13]);

      expect(requests.map((r) => r.uri.path), [endsWith('/file/download'), endsWith('/batch/file/play/info')]);
      expect(cdnCookies.single, allOf(startsWith('__kuus='), endsWith('; Video-Auth=va-1')));
    });

    test('fromMount reuses fallbackDevice utdid across drivers for legacy secrets', () async {
      const sharedDevice = QuarkPcDevice(utdid: 'SHARED_UTDID_VALUE', machine: 'DESKTOP-SHARED1');
      final mount = StorageMount(
        id: 'm1',
        kind: StorageKind.quark,
        displayName: 'Quark PC',
        config: const {MountKeys.quarkMode: 'pc'},
        secrets: const {MountKeys.secretCookie: 'token=TK&uid=42&nickname=Nick'},
        createdAt: DateTime(2026),
      );
      final mountDriverA = QuarkStorageDriver(
        cookie: mount.secret(MountKeys.secretCookie)!,
        mode: QuarkMode.pc,
        requestInterval: Duration.zero,
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive'),
        fallbackDevice: sharedDevice,
      );
      final mountDriverB = QuarkStorageDriver.fromMount(mount, fallbackDevice: sharedDevice);
      await mountDriverB.close();
      try {
        await mountDriverA.streamVariants(const StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1'));
        final ut = requests.single.uri.queryParameters['ut']!;
        expect(await wsg.decodeText(ut), 'SHARED_UTDID_VALUE');
      } finally {
        await mountDriverA.close();
      }
    });
  });
}
