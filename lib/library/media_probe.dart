import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Fetches [length] bytes of a file from [start]. May return fewer at the end
/// of the file.
typedef ProbeRangeReader = Future<Uint8List> Function(int start, int length);

/// What a file's container header says about it: the tracks, their codecs
/// and sizes, and the running time. Read straight from the bytes, so it needs
/// no server, no ffprobe and no player.
class ProbedMedia {
  const ProbedMedia({required this.container, this.durationMs, this.bitrateKbps, this.streams = const []});

  /// `mkv`, `webm`, `mp4`, `mov`, or the file extension when the container
  /// is one the probe cannot read.
  final String container;
  final int? durationMs;

  /// Average over the whole file.
  final int? bitrateKbps;
  final List<ProbedStream> streams;

  ProbedStream? get firstVideo => _first('video');
  ProbedStream? get firstAudio => _first('audio');

  ProbedStream? _first(String kind) {
    for (final stream in streams) {
      if (stream.kind == kind) return stream;
    }
    return null;
  }

  /// [streams] plus the overall bitrate, as stored in the library's
  /// `streams` column.
  String encodeStreams() => jsonEncode({
    'bitrateKbps': ?bitrateKbps,
    'streams': [for (final s in streams) s.toJson()],
  });

  /// The [encodeStreams] payload, or empty when [raw] is not one.
  static ({int? bitrateKbps, List<ProbedStream> streams}) decodeStreams(String? raw) {
    if (raw == null || raw.isEmpty) return (bitrateKbps: null, streams: const []);
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return (bitrateKbps: null, streams: const []);
      final list = json['streams'];
      return (
        bitrateKbps: json['bitrateKbps'] is num ? (json['bitrateKbps'] as num).toInt() : null,
        streams: [
          if (list is List)
            for (final s in list)
              if (s is Map) ProbedStream.fromJson(s),
        ],
      );
    } on FormatException {
      return (bitrateKbps: null, streams: const []);
    }
  }
}

/// One track of a [ProbedMedia].
class ProbedStream {
  const ProbedStream({
    required this.kind,
    required this.index,
    this.codec,
    this.language,
    this.title,
    this.isDefault = false,
    this.isForced = false,
    this.width,
    this.height,
    this.frameRate,
    this.hdr,
    this.channels,
    this.sampleRate,
    this.bitDepth,
  });

  /// `video`, `audio` or `subtitle`.
  final String kind;

  /// Position among all of the file's tracks, from 0.
  final int index;

  /// ffmpeg-style codec name (`h264`, `hevc`, `aac`, `subrip`, …).
  final String? codec;

  /// ISO 639-2 or BCP 47 language tag as the file records it.
  final String? language;
  final String? title;
  final bool isDefault;
  final bool isForced;

  // Video.
  final int? width;
  final int? height;
  final double? frameRate;

  /// `hdr10`, `hlg` or `dolbyVision`; null for SDR or unknown.
  final String? hdr;

  // Audio.
  final int? channels;
  final int? sampleRate;
  final int? bitDepth;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'index': index,
    'codec': ?codec,
    'language': ?language,
    'title': ?title,
    if (isDefault) 'default': true,
    if (isForced) 'forced': true,
    'width': ?width,
    'height': ?height,
    'frameRate': ?frameRate,
    'hdr': ?hdr,
    'channels': ?channels,
    'sampleRate': ?sampleRate,
    'bitDepth': ?bitDepth,
  };

  factory ProbedStream.fromJson(Map<dynamic, dynamic> json) {
    int? integer(String key) => json[key] is num ? (json[key] as num).toInt() : null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return ProbedStream(
      kind: text('kind') ?? 'unknown',
      index: integer('index') ?? 0,
      codec: text('codec'),
      language: text('language'),
      title: text('title'),
      isDefault: json['default'] == true,
      isForced: json['forced'] == true,
      width: integer('width'),
      height: integer('height'),
      frameRate: json['frameRate'] is num ? (json['frameRate'] as num).toDouble() : null,
      hdr: text('hdr'),
      channels: integer('channels'),
      sampleRate: integer('sampleRate'),
      bitDepth: integer('bitDepth'),
    );
  }
}

/// Reads a video file's header — Matroska/WebM or MP4/MOV — over ranged
/// reads, fetching only the parts that describe the tracks (usually a few
/// kilobytes at the start, plus the `moov` box when an MP4 keeps it at the
/// end). Anything else comes back with just the container name.
class MediaProbe {
  MediaProbe._(this._read, this._size);

  final ProbeRangeReader _read;
  final int _size;
  final List<({int start, Uint8List bytes})> _windows = [];

  /// Bytes fetched per read that misses the cache: enough for a typical
  /// Matroska header in one round trip.
  static const int _window = 512 * 1024;

  /// Largest header element the probe will fetch whole.
  static const int _maxElement = 32 * 1024 * 1024;

  static Future<ProbedMedia> probe({required String extension, required int size, required ProbeRangeReader read}) {
    return MediaProbe._(read, size)._probe(extension.toLowerCase());
  }

  Future<ProbedMedia> _probe(String extension) async {
    final head = await _bytes(0, 12);
    if (head.length >= 4 && _u32(head, 0) == 0x1A45DFA3) return _probeMatroska(extension);
    if (head.length >= 8 && _isMp4Box(String.fromCharCodes(head.sublist(4, 8)))) return _probeMp4(extension);
    return ProbedMedia(container: extension);
  }

  // ---- reading ----

  /// [length] bytes from [start], served from what was already fetched when
  /// possible. Shorter only at the end of the file.
  Future<Uint8List> _bytes(int start, int length) async {
    if (start >= _size || length <= 0) return Uint8List(0);
    final want = min(length, _size - start);
    for (final w in _windows) {
      if (start >= w.start && start + want <= w.start + w.bytes.length) {
        return Uint8List.sublistView(w.bytes, start - w.start, start - w.start + want);
      }
    }
    final fetched = await _read(start, max(want, min(_window, _size - start)));
    _windows.add((start: start, bytes: fetched));
    return fetched.length <= want ? fetched : Uint8List.sublistView(fetched, 0, want);
  }

  static int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
  static int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  static int _u64(Uint8List b, int o) => (_u32(b, o) * 0x100000000) + _u32(b, o + 4);
  static String _fourcc(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));

  int? _bitrate(int? durationMs) => durationMs == null || durationMs <= 0 ? null : (_size * 8 / durationMs).round();

  // ---- Matroska ----

  static const int _idEbml = 0x1A45DFA3;
  static const int _idDocType = 0x4282;
  static const int _idSegment = 0x18538067;
  static const int _idSeekHead = 0x114D9B74;
  static const int _idSeek = 0x4DBB;
  static const int _idSeekId = 0x53AB;
  static const int _idSeekPosition = 0x53AC;
  static const int _idInfo = 0x1549A966;
  static const int _idTimestampScale = 0x2AD7B1;
  static const int _idDuration = 0x4489;
  static const int _idTracks = 0x1654AE6B;
  static const int _idCluster = 0x1F43B675;
  static const int _idTrackEntry = 0xAE;
  static const int _idTrackType = 0x83;
  static const int _idCodecId = 0x86;
  static const int _idName = 0x536E;
  static const int _idLanguage = 0x22B59C;
  static const int _idLanguageBcp47 = 0x22B59D;
  static const int _idFlagDefault = 0x88;
  static const int _idFlagForced = 0x55AA;
  static const int _idDefaultDuration = 0x23E383;
  static const int _idVideo = 0xE0;
  static const int _idPixelWidth = 0xB0;
  static const int _idPixelHeight = 0xBA;
  static const int _idColour = 0x55B0;
  static const int _idTransfer = 0x55BA;
  static const int _idBlockAdditionMapping = 0x41E4;
  static const int _idBlockAddIdType = 0x41E7;
  static const int _idAudio = 0xE1;
  static const int _idSamplingFrequency = 0xB5;
  static const int _idChannels = 0x9F;
  static const int _idBitDepth = 0x6264;

  /// An element header at [offset]: its id, where its body starts, and its
  /// size (null when the file leaves it unknown).
  Future<({int id, int body, int? size})?> _element(int offset) async {
    final b = await _bytes(offset, 12);
    final id = _vint(b, 0, keepMarker: true);
    if (id == null) return null;
    final size = _vint(b, id.length, keepMarker: false);
    if (size == null) return null;
    return (id: id.value, body: offset + id.length + size.length, size: size.unknown ? null : size.value);
  }

  /// An EBML variable-length integer at [o].
  static ({int value, int length, bool unknown})? _vint(Uint8List b, int o, {required bool keepMarker}) {
    if (o >= b.length || b[o] == 0) return null;
    var length = 1;
    while (length <= 8 && (b[o] & (0x80 >> (length - 1))) == 0) {
      length++;
    }
    if (length > 8 || o + length > b.length) return null;
    var value = keepMarker ? b[o] : b[o] & (0xFF >> length);
    var allOnes = value == (0xFF >> length);
    for (var i = 1; i < length; i++) {
      value = (value << 8) | b[o + i];
      if (b[o + i] != 0xFF) allOnes = false;
    }
    return (value: value, length: length, unknown: !keepMarker && allOnes);
  }

  /// The children of the element body [b] as `(id, bytes)` pairs.
  static Iterable<(int, Uint8List)> _children(Uint8List b) sync* {
    var o = 0;
    while (o < b.length) {
      final id = _vint(b, o, keepMarker: true);
      if (id == null) return;
      final size = _vint(b, o + id.length, keepMarker: false);
      if (size == null) return;
      final start = o + id.length + size.length;
      final end = size.unknown ? b.length : min(b.length, start + size.value);
      yield (id.value, Uint8List.sublistView(b, start, end));
      o = end;
    }
  }

  static int _uint(Uint8List b) => b.fold(0, (v, byte) => (v << 8) | byte);

  static double? _float(Uint8List b) => switch (b.length) {
    4 => ByteData.sublistView(b).getFloat32(0),
    8 => ByteData.sublistView(b).getFloat64(0),
    _ => null,
  };

  static String _string(Uint8List b) {
    final end = b.indexOf(0);
    return utf8.decode(end < 0 ? b : b.sublist(0, end), allowMalformed: true);
  }

  Future<ProbedMedia> _probeMatroska(String extension) async {
    final header = await _element(0);
    if (header == null || header.id != _idEbml || header.size == null) return ProbedMedia(container: extension);
    var docType = 'matroska';
    for (final (id, value) in _children(await _bytes(header.body, header.size!))) {
      if (id == _idDocType) docType = _string(value);
    }
    final container = docType == 'webm' ? 'webm' : 'mkv';

    final segment = await _element(header.body + header.size!);
    if (segment == null || segment.id != _idSegment) return ProbedMedia(container: container);
    final segmentEnd = segment.size == null ? _size : min(_size, segment.body + segment.size!);

    Uint8List? info;
    Uint8List? tracks;
    final seekTargets = <int, int>{};

    Future<Uint8List?> body(({int id, int body, int? size}) e) async {
      final size = e.size;
      if (size == null || size > _maxElement) return null;
      return _bytes(e.body, size);
    }

    // Walk the top-level elements until the media data starts.
    var offset = segment.body;
    for (var steps = 0; steps < 64 && offset < segmentEnd && (info == null || tracks == null); steps++) {
      final e = await _element(offset);
      if (e == null || e.id == _idCluster || e.size == null) break;
      if (e.id == _idInfo) info = await body(e);
      if (e.id == _idTracks) tracks = await body(e);
      if (e.id == _idSeekHead) {
        final seekHead = await body(e);
        if (seekHead != null) {
          for (final (id, seek) in _children(seekHead)) {
            if (id != _idSeek) continue;
            int? target;
            int? position;
            for (final (field, value) in _children(seek)) {
              if (field == _idSeekId) target = _uint(value);
              if (field == _idSeekPosition) position = _uint(value);
            }
            if (target != null && position != null) seekTargets[target] = segment.body + position;
          }
        }
      }
      offset = e.body + e.size!;
    }
    // Headers written after the media (some muxers) are found through the
    // seek index.
    Future<Uint8List?> seek(int wanted) async {
      final at = seekTargets[wanted];
      if (at == null) return null;
      final e = await _element(at);
      return e != null && e.id == wanted ? body(e) : null;
    }

    info ??= await seek(_idInfo);
    tracks ??= await seek(_idTracks);

    int? durationMs;
    if (info != null) {
      var scale = 1000000;
      double? duration;
      for (final (id, value) in _children(info)) {
        if (id == _idTimestampScale) scale = _uint(value);
        if (id == _idDuration) duration = _float(value);
      }
      if (duration != null) durationMs = (duration * scale / 1000000).round();
    }

    final streams = <ProbedStream>[];
    if (tracks != null) {
      for (final (id, entry) in _children(tracks)) {
        if (id != _idTrackEntry) continue;
        final stream = _matroskaTrack(entry, streams.length);
        if (stream != null) streams.add(stream);
      }
    }
    return ProbedMedia(
      container: container,
      durationMs: durationMs,
      bitrateKbps: _bitrate(durationMs),
      streams: streams,
    );
  }

  ProbedStream? _matroskaTrack(Uint8List entry, int index) {
    int? type;
    String? codecId;
    String? name;
    String? language = 'eng'; // The Matroska default when the field is absent.
    String? bcp47;
    var isDefault = true;
    var isForced = false;
    int? frameNs;
    int? width;
    int? height;
    String? hdr;
    int? channels;
    int? sampleRate;
    int? bitDepth;
    for (final (id, value) in _children(entry)) {
      switch (id) {
        case _idTrackType:
          type = _uint(value);
        case _idCodecId:
          codecId = _string(value);
        case _idName:
          name = _string(value);
        case _idLanguage:
          language = _string(value);
        case _idLanguageBcp47:
          bcp47 = _string(value);
        case _idFlagDefault:
          isDefault = _uint(value) != 0;
        case _idFlagForced:
          isForced = _uint(value) != 0;
        case _idDefaultDuration:
          frameNs = _uint(value);
        case _idBlockAdditionMapping:
          for (final (field, v) in _children(value)) {
            // `dvcC` / `dvvC`: a Dolby Vision configuration record.
            if (field == _idBlockAddIdType && (_uint(v) == 0x64766343 || _uint(v) == 0x64767643)) {
              hdr = 'dolbyVision';
            }
          }
        case _idVideo:
          for (final (field, v) in _children(value)) {
            if (field == _idPixelWidth) width = _uint(v);
            if (field == _idPixelHeight) height = _uint(v);
            if (field == _idColour) {
              for (final (colour, c) in _children(v)) {
                if (colour == _idTransfer) hdr ??= _hdrFromTransfer(_uint(c));
              }
            }
          }
        case _idAudio:
          for (final (field, v) in _children(value)) {
            if (field == _idSamplingFrequency) sampleRate = _float(v)?.round();
            if (field == _idChannels) channels = _uint(v);
            if (field == _idBitDepth) bitDepth = _uint(v);
          }
      }
    }
    final kind = switch (type) {
      1 => 'video',
      2 => 'audio',
      17 => 'subtitle',
      _ => null,
    };
    if (kind == null) return null;
    final lang = bcp47 ?? language;
    return ProbedStream(
      kind: kind,
      index: index,
      codec: codecId == null ? null : _matroskaCodec(codecId),
      language: lang == null || lang.isEmpty || lang == 'und' ? null : lang,
      title: name == null || name.isEmpty ? null : name,
      isDefault: isDefault,
      isForced: isForced,
      width: width,
      height: height,
      frameRate: kind == 'video' && frameNs != null && frameNs > 0 ? _roundRate(1e9 / frameNs) : null,
      hdr: kind == 'video' ? hdr : null,
      channels: channels,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
  }

  static String _matroskaCodec(String id) {
    if (id.startsWith('A_AAC')) return 'aac';
    if (id.startsWith('A_DTS')) return 'dts';
    if (id.startsWith('A_PCM')) return 'pcm';
    return switch (id) {
      'V_MPEG4/ISO/AVC' => 'h264',
      'V_MPEGH/ISO/HEVC' => 'hevc',
      'V_AV1' => 'av1',
      'V_VP9' => 'vp9',
      'V_VP8' => 'vp8',
      'V_MPEG2' => 'mpeg2video',
      'V_MPEG4/ISO/ASP' || 'V_MPEG4/ISO/SP' => 'mpeg4',
      'A_AC3' => 'ac3',
      'A_EAC3' => 'eac3',
      'A_TRUEHD' => 'truehd',
      'A_FLAC' => 'flac',
      'A_OPUS' => 'opus',
      'A_VORBIS' => 'vorbis',
      'A_MPEG/L3' => 'mp3',
      'A_MPEG/L2' => 'mp2',
      'S_TEXT/UTF8' => 'subrip',
      'S_TEXT/ASS' || 'S_ASS' => 'ass',
      'S_TEXT/SSA' || 'S_SSA' => 'ssa',
      'S_TEXT/WEBVTT' => 'webvtt',
      'S_HDMV/PGS' => 'hdmv_pgs_subtitle',
      'S_VOBSUB' => 'dvd_subtitle',
      _ => id,
    };
  }

  /// ITU-T H.273 transfer characteristics: 16 is PQ (HDR10), 18 is HLG.
  static String? _hdrFromTransfer(int transfer) => switch (transfer) {
    16 => 'hdr10',
    18 => 'hlg',
    _ => null,
  };

  static double _roundRate(double rate) => (rate * 1000).round() / 1000;

  // ---- MP4 / MOV ----

  static bool _isMp4Box(String type) =>
      const {'ftyp', 'moov', 'mdat', 'free', 'skip', 'wide', 'pnot', 'uuid'}.contains(type);

  Future<ProbedMedia> _probeMp4(String extension) async {
    var container = extension == 'mov' ? 'mov' : 'mp4';
    Uint8List? moov;
    var offset = 0;
    for (var steps = 0; steps < 64 && offset + 8 <= _size; steps++) {
      final h = await _bytes(offset, 16);
      if (h.length < 8) break;
      var size = _u32(h, 0);
      final type = _fourcc(h, 4);
      var headerSize = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = _u64(h, 8);
        headerSize = 16;
      } else if (size == 0) {
        size = _size - offset;
      }
      if (size < headerSize) break;
      if (type == 'ftyp' && h.length >= 12 && _fourcc(h, 8) == 'qt  ') container = 'mov';
      if (type == 'moov') {
        if (size > _maxElement) break;
        moov = await _bytes(offset + headerSize, size - headerSize);
        break;
      }
      offset += size;
    }
    if (moov == null) return ProbedMedia(container: container);

    int? durationMs;
    final streams = <ProbedStream>[];
    for (final (type, box) in _boxes(moov)) {
      if (type == 'mvhd') durationMs = _mp4Duration(box, timescaleAt: 12, durationAt: 16, v1TimescaleAt: 20);
      if (type == 'trak') {
        final stream = _mp4Track(box, streams.length);
        if (stream != null) streams.add(stream);
      }
    }
    return ProbedMedia(
      container: container,
      durationMs: durationMs,
      bitrateKbps: _bitrate(durationMs),
      streams: streams,
    );
  }

  /// The boxes inside [b], starting at [from].
  static Iterable<(String, Uint8List)> _boxes(Uint8List b, [int from = 0]) sync* {
    var o = from;
    while (o + 8 <= b.length) {
      var size = _u32(b, o);
      final type = _fourcc(b, o + 4);
      var header = 8;
      if (size == 1 && o + 16 <= b.length) {
        size = _u64(b, o + 8);
        header = 16;
      } else if (size == 0) {
        size = b.length - o;
      }
      if (size < header || o + size > b.length) return;
      yield (type, Uint8List.sublistView(b, o + header, o + size));
      o += size;
    }
  }

  static Uint8List? _box(Uint8List b, String path) {
    Uint8List? current = b;
    for (final name in path.split('/')) {
      Uint8List? next;
      for (final (type, box) in _boxes(current!)) {
        if (type == name) {
          next = box;
          break;
        }
      }
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  /// Milliseconds from a full box holding a timescale and duration (`mvhd`,
  /// `mdhd`); version 1 boxes use 64-bit times.
  static int? _mp4Duration(
    Uint8List b, {
    required int timescaleAt,
    required int durationAt,
    required int v1TimescaleAt,
  }) {
    if (b.isEmpty) return null;
    final v1 = b[0] == 1;
    final ts = v1 ? v1TimescaleAt : timescaleAt;
    if (b.length < ts + (v1 ? 12 : 8)) return null;
    final timescale = _u32(b, ts);
    final duration = v1 ? _u64(b, ts + 4) : _u32(b, durationAt);
    if (timescale == 0 || duration == 0 || duration == 0xFFFFFFFF) return null;
    return (duration * 1000 / timescale).round();
  }

  ProbedStream? _mp4Track(Uint8List trak, int index) {
    final mdia = _box(trak, 'mdia');
    if (mdia == null) return null;
    final hdlr = _box(mdia, 'hdlr');
    final handler = hdlr != null && hdlr.length >= 12 ? _fourcc(hdlr, 8) : null;
    final kind = switch (handler) {
      'vide' => 'video',
      'soun' => 'audio',
      'sbtl' || 'subt' || 'text' || 'clcp' => 'subtitle',
      _ => null,
    };
    if (kind == null) return null;

    String? language;
    int? timescale;
    final mdhd = _box(mdia, 'mdhd');
    if (mdhd != null && mdhd.isNotEmpty) {
      final v1 = mdhd[0] == 1;
      final ts = v1 ? 20 : 12;
      final lang = v1 ? 32 : 20;
      if (mdhd.length >= ts + 4) timescale = _u32(mdhd, ts);
      if (mdhd.length >= lang + 2) language = _mp4Language(_u16(mdhd, lang));
    }

    var isDefault = true;
    final tkhd = _box(trak, 'tkhd');
    if (tkhd != null && tkhd.length >= 4) isDefault = (tkhd[3] & 0x1) != 0;

    String? codec;
    int? width;
    int? height;
    String? hdr;
    int? channels;
    int? sampleRate;
    int? bitDepth;
    final stbl = _box(mdia, 'minf/stbl');
    final stsd = stbl == null ? null : _box(stbl, 'stsd');
    if (stsd != null && stsd.length >= 16) {
      // Full box header and entry count, then the first sample entry.
      final entries = _boxes(stsd, 8);
      if (entries.isNotEmpty) {
        final (fourcc, entry) = entries.first;
        codec = _mp4Codec(fourcc);
        if (fourcc.startsWith('dv')) hdr = 'dolbyVision';
        if (kind == 'video' && entry.length >= 78) {
          width = _u16(entry, 24);
          height = _u16(entry, 26);
          for (final (type, child) in _boxes(entry, 78)) {
            if (type == 'dvcC' || type == 'dvvC') hdr = 'dolbyVision';
            if (type == 'colr' && child.length >= 8 && _fourcc(child, 0) == 'nclx') {
              hdr ??= _hdrFromTransfer(_u16(child, 6));
            }
          }
        }
        if (kind == 'audio' && entry.length >= 28) {
          channels = _u16(entry, 16);
          bitDepth = _u16(entry, 18);
          sampleRate = _u32(entry, 24) >> 16;
          if (bitDepth == 16 && codec != 'pcm') bitDepth = null; // A placeholder for compressed audio.
        }
      }
    }

    double? frameRate;
    final stts = stbl == null ? null : _box(stbl, 'stts');
    if (kind == 'video' && stts != null && stts.length >= 16 && timescale != null && timescale > 0) {
      final delta = _u32(stts, 12);
      if (delta > 0) frameRate = _roundRate(timescale / delta);
    }

    return ProbedStream(
      kind: kind,
      index: index,
      codec: codec,
      language: language,
      isDefault: isDefault,
      width: width == 0 ? null : width,
      height: height == 0 ? null : height,
      frameRate: frameRate,
      hdr: kind == 'video' ? hdr : null,
      channels: channels == 0 ? null : channels,
      sampleRate: sampleRate == 0 ? null : sampleRate,
      bitDepth: bitDepth == 0 ? null : bitDepth,
    );
  }

  /// ISO 639-2/T code packed as three 5-bit letters.
  static String? _mp4Language(int packed) {
    if (packed == 0 || packed == 0x7FFF) return null;
    final code = String.fromCharCodes([
      (packed >> 10 & 0x1F) + 0x60,
      (packed >> 5 & 0x1F) + 0x60,
      (packed & 0x1F) + 0x60,
    ]);
    return code == 'und' || !RegExp(r'^[a-z]{3}$').hasMatch(code) ? null : code;
  }

  static String _mp4Codec(String fourcc) => switch (fourcc) {
    'avc1' || 'avc3' || 'dva1' || 'dvav' => 'h264',
    'hvc1' || 'hev1' || 'dvh1' || 'dvhe' => 'hevc',
    'av01' => 'av1',
    'vp09' => 'vp9',
    'mp4v' => 'mpeg4',
    'apcn' || 'apch' || 'apcs' || 'apco' || 'ap4h' => 'prores',
    'mp4a' => 'aac',
    'ac-3' => 'ac3',
    'ec-3' => 'eac3',
    'Opus' => 'opus',
    'fLaC' => 'flac',
    'alac' => 'alac',
    'dtsc' || 'dtsh' || 'dtsl' || 'dtse' => 'dts',
    'mlpa' => 'truehd',
    '.mp3' => 'mp3',
    'lpcm' || 'sowt' || 'twos' || 'in24' || 'in32' || 'fl32' => 'pcm',
    'tx3g' => 'mov_text',
    'wvtt' => 'webvtt',
    'c608' => 'eia_608',
    _ => fourcc.trim(),
  };
}
