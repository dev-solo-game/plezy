import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/library/media_probe.dart';

// ---- Matroska building blocks ----

List<int> _idBytes(int id) {
  final out = <int>[];
  for (var v = id; v > 0; v >>= 8) {
    out.insert(0, v & 0xFF);
  }
  return out;
}

/// An element with an 8-byte size, the way many muxers write them.
List<int> _el(int id, List<int> body) {
  final size = body.length;
  return [..._idBytes(id), 0x01, for (var i = 6; i >= 0; i--) (size >> (8 * i)) & 0xFF, ...body];
}

List<int> _uintBody(int v) => [for (var i = 3; i >= 0; i--) (v >> (8 * i)) & 0xFF];
List<int> _f64(double v) => (ByteData(8)..setFloat64(0, v)).buffer.asUint8List();
List<int> _str(String s) => utf8.encode(s);

List<int> _mkvTracks() => _el(0x1654AE6B, [
  ..._el(0xAE, [
    ..._el(0xD7, _uintBody(1)),
    ..._el(0x83, _uintBody(1)),
    ..._el(0x86, _str('V_MPEGH/ISO/HEVC')),
    ..._el(0x23E383, _uintBody(41708333)),
    ..._el(0xE0, [
      ..._el(0xB0, _uintBody(3840)),
      ..._el(0xBA, _uintBody(2160)),
      ..._el(0x55B0, _el(0x55BA, _uintBody(16))),
    ]),
  ]),
  ..._el(0xAE, [
    ..._el(0xD7, _uintBody(2)),
    ..._el(0x83, _uintBody(2)),
    ..._el(0x86, _str('A_EAC3')),
    ..._el(0x22B59C, _str('jpn')),
    ..._el(0x536E, _str('Japanese 5.1')),
    ..._el(0xE1, [..._el(0xB5, _f64(48000)), ..._el(0x9F, _uintBody(6))]),
  ]),
  ..._el(0xAE, [
    ..._el(0xD7, _uintBody(3)),
    ..._el(0x83, _uintBody(17)),
    ..._el(0x86, _str('S_TEXT/ASS')),
    ..._el(0x22B59D, _str('zh-Hans')),
    ..._el(0x88, _uintBody(0)),
    ..._el(0x55AA, _uintBody(1)),
  ]),
]);

List<int> _mkvInfo() => _el(0x1549A966, [..._el(0x2AD7B1, _uintBody(1000000)), ..._el(0x4489, _f64(5400000))]);

List<int> _mkvHeader() => _el(0x1A45DFA3, _el(0x4282, _str('matroska')));

// ---- MP4 building blocks ----

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u32(int v) => [for (var i = 3; i >= 0; i--) (v >> (8 * i)) & 0xFF];

List<int> _box(String type, List<int> content) => [..._u32(content.length + 8), ...ascii.encode(type), ...content];

List<int> _mdhd(int timescale, String language) {
  final packed = language.codeUnits.fold(0, (v, c) => (v << 5) | (c - 0x60));
  return _box('mdhd', [
    0,
    0,
    0,
    0,
    ..._u32(0),
    ..._u32(0),
    ..._u32(timescale),
    ..._u32(timescale * 60),
    ..._u16(packed),
    0,
    0,
  ]);
}

List<int> _hdlr(String handler) =>
    _box('hdlr', [0, 0, 0, 0, ..._u32(0), ...ascii.encode(handler), ...List.filled(12, 0), 0]);

List<int> _stsd(List<int> entry) => _box('stsd', [0, 0, 0, 0, ..._u32(1), ...entry]);

List<int> _videoTrak() {
  final entry = _box('hvc1', [
    ...List.filled(6, 0), ..._u16(1), // SampleEntry
    ...List.filled(16, 0), ..._u16(1920), ..._u16(1080),
    ...List.filled(50, 0), // resolutions, frame count, compressor name, depth, pre_defined
    ..._box('colr', [...ascii.encode('nclx'), ..._u16(9), ..._u16(18), ..._u16(9), 0x80]),
  ]);
  final stts = _box('stts', [0, 0, 0, 0, ..._u32(1), ..._u32(1440), ..._u32(1001)]);
  return _box('trak', [
    ..._box('tkhd', [0, 0, 0, 3, ...List.filled(80, 0)]),
    ..._box('mdia', [
      ..._mdhd(24000, 'und'),
      ..._hdlr('vide'),
      ..._box('minf', _box('stbl', [..._stsd(entry), ...stts])),
    ]),
  ]);
}

List<int> _audioTrak() {
  final entry = _box('mp4a', [
    ...List.filled(6, 0),
    ..._u16(1),
    ...List.filled(8, 0),
    ..._u16(2),
    ..._u16(16),
    ..._u16(0),
    ..._u16(0),
    ..._u32(48000 << 16),
  ]);
  return _box('trak', [
    ..._box('tkhd', [0, 0, 0, 2, ...List.filled(80, 0)]),
    ..._box('mdia', [..._mdhd(48000, 'eng'), ..._hdlr('soun'), ..._box('minf', _box('stbl', _stsd(entry)))]),
  ]);
}

List<int> _moov() => _box('moov', [
  ..._box('mvhd', [0, 0, 0, 0, ..._u32(0), ..._u32(0), ..._u32(1000), ..._u32(60000), ...List.filled(80, 0)]),
  ..._videoTrak(),
  ..._audioTrak(),
]);

/// A file in memory, recording what the probe fetched.
class _File {
  _File(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final List<({int start, int length})> reads = [];

  int get fetched => reads.fold(0, (sum, r) => sum + r.length);

  Future<ProbedMedia> probe(String extension) => MediaProbe.probe(
    extension: extension,
    size: bytes.length,
    read: (start, length) async {
      final end = min(bytes.length, start + length);
      reads.add((start: start, length: end - start));
      return Uint8List.sublistView(bytes, start, end);
    },
  );
}

void main() {
  test('reads Matroska tracks, languages, HDR and duration', () async {
    final segment = [..._mkvInfo(), ..._mkvTracks(), ..._el(0x1F43B675, List.filled(4096, 0))];
    final file = _File([..._mkvHeader(), ..._el(0x18538067, segment)]);
    final media = await file.probe('mkv');

    expect(media.container, 'mkv');
    expect(media.durationMs, 5400000);
    expect(media.streams, hasLength(3));

    final video = media.firstVideo!;
    expect(video.codec, 'hevc');
    expect((video.width, video.height), (3840, 2160));
    expect(video.hdr, 'hdr10');
    expect(video.frameRate, closeTo(23.976, 0.001));
    expect(video.language, 'eng'); // Matroska's default when unset.

    final audio = media.firstAudio!;
    expect(audio.codec, 'eac3');
    expect(audio.language, 'jpn');
    expect(audio.title, 'Japanese 5.1');
    expect(audio.channels, 6);
    expect(audio.sampleRate, 48000);

    final subtitle = media.streams[2];
    expect(subtitle.kind, 'subtitle');
    expect(subtitle.codec, 'ass');
    expect(subtitle.language, 'zh-Hans');
    expect(subtitle.isDefault, isFalse);
    expect(subtitle.isForced, isTrue);
  });

  test('finds Matroska tracks written after the media through the seek index', () async {
    final cluster = _el(0x1F43B675, List.filled(2 * 1024 * 1024, 0));
    // Seek head, then info, cluster and finally the tracks.
    List<int> segmentWith(int tracksAt) => [
      ..._el(0x114D9B74, _el(0x4DBB, [..._el(0x53AB, _idBytes(0x1654AE6B)), ..._el(0x53AC, _uintBody(tracksAt))])),
      ..._mkvInfo(),
      ...cluster,
      ..._mkvTracks(),
    ];
    final seekHeadLength = segmentWith(0).length - _mkvInfo().length - cluster.length - _mkvTracks().length;
    final tracksAt = seekHeadLength + _mkvInfo().length + cluster.length;
    final file = _File([..._mkvHeader(), ..._el(0x18538067, segmentWith(tracksAt))]);
    final media = await file.probe('mkv');

    expect(media.streams.map((s) => s.kind), ['video', 'audio', 'subtitle']);
    // The cluster in between was skipped, not read.
    expect(file.fetched, lessThan(cluster.length));
  });

  test('reads an MP4 whose index sits after the media without reading the media', () async {
    final mdat = _box('mdat', List.filled(3 * 1024 * 1024, 0));
    final file = _File([
      ..._box('ftyp', [...ascii.encode('isom'), ..._u32(0)]),
      ...mdat,
      ..._moov(),
    ]);
    final media = await file.probe('mp4');

    expect(media.container, 'mp4');
    expect(media.durationMs, 60000);
    expect(media.bitrateKbps, (file.bytes.length * 8 / 60000).round());

    final video = media.firstVideo!;
    expect(video.codec, 'hevc');
    expect((video.width, video.height), (1920, 1080));
    expect(video.hdr, 'hlg');
    expect(video.frameRate, closeTo(23.976, 0.001));
    expect(video.language, isNull);

    final audio = media.firstAudio!;
    expect(audio.codec, 'aac');
    expect(audio.language, 'eng');
    expect(audio.channels, 2);
    expect(audio.sampleRate, 48000);
    expect(audio.bitDepth, isNull);

    expect(file.fetched, lessThan(mdat.length));
  });

  test('a QuickTime brand reads as mov', () async {
    final file = _File([
      ..._box('ftyp', [...ascii.encode('qt  '), ..._u32(0)]),
      ..._moov(),
    ]);
    expect((await file.probe('mov')).container, 'mov');
  });

  test('an unknown container keeps its extension and no streams', () async {
    final file = _File(List.filled(1000, 0x47));
    final media = await file.probe('TS');
    expect(media.container, 'ts');
    expect(media.streams, isEmpty);
  });

  test('streams survive the library round trip', () async {
    final segment = [..._mkvInfo(), ..._mkvTracks()];
    final media = await _File([..._mkvHeader(), ..._el(0x18538067, segment)]).probe('mkv');
    final decoded = ProbedMedia.decodeStreams(media.encodeStreams());
    expect(decoded.bitrateKbps, media.bitrateKbps);
    expect(decoded.streams.map((s) => s.toJson()), media.streams.map((s) => s.toJson()));
    expect(ProbedMedia.decodeStreams('not json').streams, isEmpty);
  });
}
