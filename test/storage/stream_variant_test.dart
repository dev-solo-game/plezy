import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/storage/drivers/quark_storage_driver.dart';
import 'package:plezy/storage/storage_driver.dart';
import 'package:plezy/storage/stream_proxy.dart';
import 'package:plezy/storage/stream_variant.dart';

const _order = ['4k', '2k', 'super', 'high', 'normal', 'low'];

StreamVariant _variant(String id, {String url = 'https://cdn.example/v.m3u8'}) =>
    StreamVariant(id: id, url: Uri.parse(url), isHls: true);

/// A CDN that serves one HLS rendition, and only to requests carrying the
/// current play cookie.
class _FakeCdn {
  late HttpServer server;
  String acceptedAuth = 'auth-1';
  final List<String> requests = [];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      final path = request.uri.path;
      requests.add('$path ${request.headers.value(HttpHeaders.rangeHeader) ?? ''}'.trim());
      if (request.headers.value(HttpHeaders.cookieHeader) != 'Video-Auth=$acceptedAuth') {
        response.statusCode = HttpStatus.preconditionFailed;
        return response.close();
      }
      if (path == '/hls/master.m3u8') {
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nmedia/index.m3u8\n');
      } else if (path == '/hls/media/index.m3u8') {
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        response.write(
          '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4.0,\nseg0.m4s\n#EXTINF:4.0,\n'
          'http://127.0.0.1:${server.port}/abs/seg1.m4s\n#EXT-X-ENDLIST\n',
        );
      } else if (path.endsWith('.m4s') || path.endsWith('.mp4')) {
        response.headers.contentType = ContentType('video', 'mp4');
        response.add(utf8.encode('bytes of $path'));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }
}

class _FakeSource implements StreamVariantSource {
  _FakeSource(this.cdn);

  final _FakeCdn cdn;
  int refreshes = 0;

  @override
  List<String> get variantOrder => _order;

  @override
  Future<List<StreamVariant>> streamVariants(StorageEntry entry, {bool forceRefresh = false}) async {
    if (forceRefresh) refreshes++;
    return [
      StreamVariant(
        id: 'high',
        url: cdn.url('/hls/master.m3u8'),
        headers: {HttpHeaders.cookieHeader: 'Video-Auth=${cdn.acceptedAuth}'},
        isHls: true,
      ),
    ];
  }
}

void main() {
  group('StreamVariant.pick', () {
    final offered = [_variant('super'), _variant('high'), _variant('low')];

    test('plays the original when asked for it or when nothing is offered', () {
      expect(StreamVariant.pick(offered, 'original', _order), isNull);
      expect(StreamVariant.pick(const [], 'high', _order), isNull);
    });

    test('takes the rendition asked for', () {
      expect(StreamVariant.pick(offered, 'high', _order)?.id, 'high');
    });

    test('falls back to the best rendition below the one asked for', () {
      expect(StreamVariant.pick(offered, '4k', _order)?.id, 'super');
      expect(StreamVariant.pick(offered, 'normal', _order)?.id, 'low');
    });

    test('takes the lowest offered when every one is above the one asked for', () {
      expect(StreamVariant.pick([_variant('super'), _variant('high')], 'low', _order)?.id, 'high');
    });
  });

  test('rewritePlaylist points media lines and URI attributes at the proxy', () {
    final base = Uri.parse('https://cdn.example/a/b/index.m3u8?sign=1');
    final rewritten = StreamProxy.rewritePlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nseg 0.ts\n'
      '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://id"\n\nhttps://other.example/seg1.ts\n',
      base,
      (url) => 'P(${url.toString()})',
    );
    expect(
      const LineSplitter().convert(rewritten),
      [
        '#EXTM3U',
        '#EXT-X-KEY:METHOD=AES-128,URI="P(https://cdn.example/a/b/key.bin)"',
        '#EXTINF:4,',
        'P(https://cdn.example/a/b/seg%200.ts)',
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://id"',
        '',
        'P(https://other.example/seg1.ts)',
      ],
    );
  });

  group('proxy serves a rendition', () {
    late _FakeCdn cdn;
    late StreamProxy proxy;
    late HttpClient client;

    setUp(() async {
      HttpOverrides.global = null;
      cdn = _FakeCdn();
      await cdn.start();
      proxy = StreamProxy();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await cdn.server.close(force: true);
    });

    Future<(int, String, String?)> get(Uri url) async {
      final request = await client.getUrl(url);
      final response = await request.close();
      return (
        response.statusCode,
        await utf8.decodeStream(response),
        response.headers.contentType?.mimeType,
      );
    }

    Future<Uri> register(_FakeSource source) async {
      final variants = await source.streamVariants(
        const StorageEntry(path: '/Show/ep1.mkv', name: 'ep1.mkv', isDirectory: false),
      );
      return proxy.registerVariant(
        mountId: 'quark',
        source: source,
        entry: const StorageEntry(path: '/Show/ep1.mkv', name: 'ep1.mkv', isDirectory: false),
        variant: variants.single,
      );
    }

    test('rewrites nested playlists so every request goes through the proxy', () async {
      final url = await register(_FakeSource(cdn));
      expect(url.path, endsWith('/ep1.m3u8'));

      final (status, master, type) = await get(url);
      expect(status, HttpStatus.ok);
      expect(type, 'application/vnd.apple.mpegurl');
      final mediaUrl = const LineSplitter().convert(master).last;
      expect(mediaUrl, startsWith('http://127.0.0.1:${url.port}/v/'));
      expect(mediaUrl, endsWith('/index.m3u8'));

      final (_, media, _) = await get(Uri.parse(mediaUrl));
      final lines = const LineSplitter().convert(media);
      final init = RegExp(r'URI="([^"]+)"').firstMatch(lines[1])![1]!;
      final segments = lines.where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
      expect(segments, hasLength(2));
      for (final proxied in [init, ...segments]) {
        expect(proxied, startsWith('http://127.0.0.1:${url.port}/v/'));
      }

      expect((await get(Uri.parse(init))).$2, 'bytes of /hls/media/init.mp4');
      expect((await get(Uri.parse(segments[0]))).$2, 'bytes of /hls/media/seg0.m4s');
      expect((await get(Uri.parse(segments[1]))).$2, 'bytes of /abs/seg1.m4s');
    });

    test('renews the play cookie when the CDN refuses the old one', () async {
      final source = _FakeSource(cdn);
      final url = await register(source);
      cdn.acceptedAuth = 'auth-2';

      final (status, master, _) = await get(url);
      expect(status, HttpStatus.ok);
      expect(master, contains('#EXT-X-STREAM-INF'));
      expect(source.refreshes, 1);
    });

    test('only reaches URLs a playlist referred to', () async {
      final url = await register(_FakeSource(cdn));
      final token = url.pathSegments[1];
      final (status, _, _) = await get(url.replace(pathSegments: ['v', token, 'r', '7', 'x.ts']));
      expect(status, HttpStatus.notFound);
    });
  });

  group('Quark renditions', () {
    late HttpServer server;
    late QuarkStorageDriver driver;
    final bodies = <Map<String, dynamic>>[];

    setUp(() async {
      HttpOverrides.global = null;
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        bodies.add(jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>);
        response.headers
          ..contentType = ContentType.json
          ..add(HttpHeaders.setCookieHeader, 'Video-Auth=va-123; Path=/; HttpOnly');
        response.write(
          jsonEncode({
            'status': 200,
            'code': 0,
            'data': {
              'video_list': [
                {
                  'resolution': 'low',
                  'video_info': {'url': 'https://cdn.example/low.m3u8', 'width': 480, 'height': 270},
                },
                {
                  'resolution': 'super',
                  'accessable': false,
                  'video_info': {'url': 'https://cdn.example/super.m3u8'},
                },
                {'resolution': '2k', 'video_info': <String, Object?>{}},
                {
                  'resolution': 'high',
                  'video_info': {'url': 'https://cdn.example/high.m3u8', 'width': 960, 'height': 540},
                },
              ],
            },
          }),
        );
        await response.close();
      });
      driver = QuarkStorageDriver(
        cookie: '__pus=a; Video-Auth=old',
        requestInterval: Duration.zero,
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/1/clouddrive'),
      );
    });

    tearDown(() async {
      await driver.close();
      await server.close(force: true);
    });

    test('lists the playable renditions best first with the play cookie', () async {
      const entry = StorageEntry(path: '/a.mkv', name: 'a.mkv', isDirectory: false, id: 'fid-1');
      final variants = await driver.streamVariants(entry);

      expect(bodies.single['fid'], 'fid-1');
      expect([for (final v in variants) v.id], ['high', 'low']);
      expect(variants.first.height, 540);
      expect(variants.first.isHls, isTrue);
      expect(variants.first.headers[HttpHeaders.cookieHeader], '__pus=a; Video-Auth=va-123');

      // Cached until the link is refused.
      await driver.streamVariants(entry);
      expect(bodies, hasLength(1));
      await driver.streamVariants(entry, forceRefresh: true);
      expect(bodies, hasLength(2));
    });
  });
}
