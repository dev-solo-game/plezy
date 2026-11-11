/// What a file or folder name says about the media it holds.
///
/// Everything is optional: the parser reports what it can see and leaves the
/// decision about what the file *is* to the classifier.
class ParsedName {
  const ParsedName({
    this.title,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    this.looseEpisode,
    this.isSpecial = false,
    this.resolution,
    this.source,
    this.videoCodec,
    this.hdr,
    this.edition,
    this.releaseGroup,
    this.fansubStyle = false,
  });

  final String? title;
  final int? year;
  final int? season;

  /// Episode number from an explicit marker (`S01E02`, `第2集`, `EP02`).
  final int? episode;

  /// Last episode when one file holds several (`S01E01E02`, `E01-E03`).
  final int? episodeEnd;

  /// A bare number that reads like an episode (`Title - 03`, `03.mkv`) but
  /// carries no marker. Only trusted when the surroundings agree.
  final int? looseEpisode;

  /// OVA, OAD, SP and "Special" releases, which belong in season 0.
  final bool isSpecial;

  /// `2160p`, `1080p`, `720p`…
  final String? resolution;
  final String? source;
  final String? videoCodec;
  final String? hdr;

  /// `Director's Cut`, `Extended`, `IMAX`…
  final String? edition;
  final String? releaseGroup;

  /// True for names in the fansub layout: a leading `[Group]` tag.
  final bool fansubStyle;

  bool get hasEpisodeMarker => episode != null || season != null || isSpecial;

  Map<String, Object?> toJson() => {
    'title': ?title,
    'year': ?year,
    'season': ?season,
    'episode': ?episode,
    'episodeEnd': ?episodeEnd,
    'looseEpisode': ?looseEpisode,
    if (isSpecial) 'isSpecial': true,
    'resolution': ?resolution,
    'source': ?source,
    'videoCodec': ?videoCodec,
    'hdr': ?hdr,
    'edition': ?edition,
    'releaseGroup': ?releaseGroup,
    if (fansubStyle) 'fansubStyle': true,
  };

  @override
  String toString() => 'ParsedName(${toJson()})';
}

/// What a folder name says: a season folder, or a title with maybe a year.
class ParsedFolder {
  const ParsedFolder({this.title, this.year, this.season, this.isSeasonFolder = false});

  final String? title;
  final int? year;
  final int? season;

  /// True for folders that only name a season (`Season 2`, `S02`, `第二季`,
  /// `Specials`); the show's title is then one level up.
  final bool isSeasonFolder;
}

/// Extracts titles, numbering and release details from media file names:
/// scene releases, Chinese naming, and fansub brackets.
abstract final class MediaNameParser {
  static final RegExp _extension = RegExp(r'\.[A-Za-z0-9]{2,5}$');

  // Release-detail tokens. A title ends where the first of these begins.
  static final RegExp _resolution = RegExp(r'(?<![A-Za-z0-9])(2160|1440|1080|720|576|480)[pPiI](?![A-Za-z0-9])');
  static final RegExp _fourK = RegExp(r'(?<![A-Za-z0-9])(4[kK]|UHD|8[kK])(?![A-Za-z0-9])');
  static final RegExp _dimensions = RegExp(r'(?<![0-9])(3840|1920|1280)\s*[xX×]\s*(2160|1080|720)(?![0-9])');
  static final RegExp _source = RegExp(
    r'(?<![A-Za-z0-9])(Blu-?Ray|BDRip|BRRip|BDMV|BD|UHD\s?BD|REMUX|WEB-?DL|WEB-?Rip|WEB|HDTV|PDTV|DVDRip|DVD|HDRip|HDTC|HDCAM|TS|TC|CAM)(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _codec = RegExp(
    r'(?<![A-Za-z0-9])([xXhH][\s.]?26[45]|HEVC|AVC|AV1|VP9|XviD|DivX|MPEG-?2|10bit|8bit|Hi10P)(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _hdr = RegExp(
    r'(?<![A-Za-z0-9])(HDR10\+|HDR10|HDR|DoVi|DV|Dolby[\s.]?Vision|HLG)(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _audio = RegExp(
    r'(?<![A-Za-z0-9])(DTS-?HD(?:[\s.]?MA)?|DTS-?X|DTS|TrueHD|Atmos|E-?AC-?3|AC-?3|DDP?[\s.]?[257]\.[01]|DD\+?|AAC(?:[\s.]?[257]\.[01])?|FLAC|LPCM|MP3|[257]\.[01])(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _edition = RegExp(
    r"(?<![A-Za-z0-9])(Director'?s[\s.]Cut|Extended(?:[\s.](?:Cut|Edition))?|Unrated|Uncut|Theatrical(?:[\s.]Cut)?|IMAX|Remastered|Criterion|Final[\s.]Cut|Special[\s.]Edition)(?![A-Za-z0-9])"
    r'|(导演剪辑版|導演剪輯版|加长版|加長版|未删减版|未刪減版|重制版|重製版|修复版|修復版)',
    caseSensitive: false,
  );
  static final RegExp _misc = RegExp(
    r'(?<![A-Za-z0-9])(PROPER|REPACK|INTERNAL|LIMITED|COMPLETE|MULTI|DUAL|SUBBED|DUBBED|HC|NF|AMZN|DSNP|HMAX|ATVP)(?![A-Za-z0-9])'
    r'|(国语|國語|粤语|粵語|中字|双语|雙語|简体|簡體|繁体|繁體|中英|简繁|簡繁|内封|內封|外挂|外掛|字幕|国粤|國粵|蓝光|藍光|原盘|原盤|高清|超清|完结|完結|全集)',
    caseSensitive: false,
  );

  // Numbering.
  static final RegExp _seasonEpisode = RegExp(
    r'(?<![A-Za-z0-9])[Ss](\d{1,2})[\s._-]*[Ee][Pp]?(\d{1,4})(?:[\s._-]*(?:-|[Ee][Pp]?)\s*[Ee]?[Pp]?(\d{1,4}))?(?![0-9])',
  );
  static final RegExp _crossFormat = RegExp(r'(?<![A-Za-z0-9])(\d{1,2})[xX](\d{2,3})(?![0-9xX])');
  static final RegExp _seasonWord = RegExp(r'(?<![A-Za-z])Season[\s._]*(\d{1,2})(?![0-9])', caseSensitive: false);
  static final RegExp _seasonOnly = RegExp(r'(?<![A-Za-z0-9])[Ss](\d{1,2})(?![A-Za-z0-9])');
  static final RegExp _seasonChinese = RegExp(r'第\s*([0-9０-９零〇一二三四五六七八九十百两兩]+)\s*[季部]');
  static final RegExp _episodeChinese = RegExp(r'第\s*([0-9０-９零〇一二三四五六七八九十百两兩]+)\s*[集话話回期]');
  static final RegExp _episodeWord = RegExp(
    r'(?<![A-Za-z])(?:Episode|Ep|E)[\s._-]*(\d{1,4})(?:\s*-\s*[Ee]?[Pp]?(\d{1,4}))?(?![0-9A-Za-z])',
    caseSensitive: false,
  );
  static final RegExp _special = RegExp(
    r'(?<![A-Za-z0-9])(OVA|OAD|ONA|SP|Specials?|NCOP|NCED|PV|CM)[\s._-]*(\d{1,3})?(?![A-Za-z0-9])'
    r'|(番外|特别篇|特別篇|剧场版|劇場版)',
    caseSensitive: false,
  );

  static final RegExp _year = RegExp(r'(?<![0-9A-Za-z])(19[0-9]{2}|20[0-9]{2})(?![0-9A-Za-z])');
  static final RegExp _brackets = RegExp(r'[\[【]([^\]】]*)[\]】]');
  static final RegExp _checksum = RegExp(r'^[0-9A-Fa-f]{8}$');
  static final RegExp _trailingGroup = RegExp(r'-\s*([A-Za-z0-9][A-Za-z0-9@.]{1,24})\s*$');
  static final RegExp _looseDash = RegExp(r'\s-\s*(\d{1,4})(?:[vV]\d)?(?=\s|$)');
  static final RegExp _looseTrailing = RegExp(r'(?:^|\s)(\d{1,4})(?:[vV]\d)?\s*$');

  static final RegExp _seasonFolder = RegExp(
    r'^\s*(?:Season|Series|S)[\s._-]*(\d{1,2})\s*$'
    r'|^\s*第\s*([0-9０-９零〇一二三四五六七八九十百两兩]+)\s*[季部]\s*$',
    caseSensitive: false,
  );
  static final RegExp _specialsFolder = RegExp(r'^\s*(Specials?|SP|SPs|OVA|OAD|番外|特别篇|特別篇)\s*$', caseSensitive: false);

  static const Set<String> _resolutionAliases = {'4k', 'uhd'};

  /// Parses a media file name. The extension is ignored when present.
  static ParsedName parseFile(String fileName) {
    var name = fileName.replaceFirst(_extension, '').trim();
    name = _fullWidthToAscii(name);

    final standard = _parseStandard(name);
    if (standard != null) return standard;

    // ─── Fansub brackets ────────────────────────────────────────────────
    String? group;
    var fansub = false;
    final bracketed = _brackets.allMatches(name).map((m) => m.group(1)!.trim()).toList();
    final leading = RegExp(r'^\s*[\[【]([^\]】]*)[\]】]').firstMatch(name);
    if (leading != null) {
      final tag = leading.group(1)!.trim();
      if (tag.isNotEmpty && !_isDetailTag(tag) && int.tryParse(tag) == null) {
        group = tag;
        fansub = true;
        name = name.substring(leading.end);
      }
    }

    int? bracketEpisode;
    String? bracketTitle;
    // Seasonal banners some groups wedge between the tags: ★01月新番★.
    final outside = name.replaceAll(_brackets, ' ').replaceAll(RegExp(r'★[^★]*★'), ' ').trim();
    if (fansub) {
      // Fansub tags after the group: [Title][01][1080p][CHS], in any mix with
      // a title written outside the brackets.
      final titleInBrackets = _stripDetails(outside).trim().isEmpty;
      for (final tag in bracketed.skip(1)) {
        if (tag.isEmpty || _checksum.hasMatch(tag)) continue;
        final number = RegExp(r'^(\d{1,4})(?:[vV]\d)?(?:\s*END)?$', caseSensitive: false).firstMatch(tag);
        if (number != null) {
          // A four-digit tag in the year range is a year, not episode 2016.
          if (!_year.hasMatch(number.group(1)!)) bracketEpisode ??= int.parse(number.group(1)!);
          continue;
        }
        if (titleInBrackets && bracketTitle == null && !_isDetailTag(tag)) bracketTitle = tag;
      }
    }

    // Detail lookups run over the whole name, brackets included.
    final details = name;
    // The title lives outside the brackets, unless brackets are all there is.
    var work = bracketTitle ?? name.replaceAll(_brackets, ' ').replaceAll(RegExp(r'★[^★]*★'), ' ');
    work = work.replaceAllMapped(RegExp(r'[（(]\s*([^）)]*)\s*[）)]'), (m) => ' ${m.group(1)} ');

    // ─── Numbering ──────────────────────────────────────────────────────
    int? season;
    int? episode;
    int? episodeEnd;
    var cut = work.length;
    void mark(Match m) {
      if (m.start < cut) cut = m.start;
    }

    final se = _seasonEpisode.firstMatch(work);
    if (se != null) {
      season = int.parse(se.group(1)!);
      episode = int.parse(se.group(2)!);
      final end = se.group(3);
      if (end != null) episodeEnd = int.parse(end);
      mark(se);
    } else {
      final cross = _crossFormat.firstMatch(work);
      // "1920x1080" is a frame size, not season 19 episode 20x….
      if (cross != null && !_dimensions.hasMatch(work.substring(cross.start))) {
        season = int.parse(cross.group(1)!);
        episode = int.parse(cross.group(2)!);
        mark(cross);
      }
    }
    final seasonCn = _seasonChinese.firstMatch(work);
    if (seasonCn != null) {
      season ??= _number(seasonCn.group(1)!);
      mark(seasonCn);
    }
    final seasonWord = _seasonWord.firstMatch(work);
    if (seasonWord != null) {
      season ??= int.parse(seasonWord.group(1)!);
      mark(seasonWord);
    }
    final episodeCn = _episodeChinese.firstMatch(work);
    if (episodeCn != null) {
      episode ??= _number(episodeCn.group(1)!);
      mark(episodeCn);
    }
    if (episode == null) {
      final word = _episodeWord.firstMatch(work);
      if (word != null) {
        episode = int.parse(word.group(1)!);
        final end = word.group(2);
        if (end != null) episodeEnd = int.parse(end);
        mark(word);
      }
    }
    if (season == null) {
      final only = _seasonOnly.firstMatch(work);
      if (only != null) {
        season = int.parse(only.group(1)!);
        mark(only);
      }
    }

    var isSpecial = false;
    int? specialNumber;
    final special = _special.firstMatch(work);
    if (special != null && episode == null) {
      // A "剧场版" is a film, not an episode; the others are season-0 extras.
      final label = (special.group(1) ?? special.group(3) ?? '').toLowerCase();
      if (label != '剧场版' && label != '劇場版') {
        isSpecial = true;
        specialNumber = int.tryParse(special.group(2) ?? '');
      }
      mark(special);
    }

    // ─── Release details ────────────────────────────────────────────────
    for (final pattern in [_resolution, _fourK, _dimensions, _source, _codec, _hdr, _audio, _edition, _misc]) {
      final m = pattern.firstMatch(work);
      if (m != null) mark(m);
    }

    // ─── Year ───────────────────────────────────────────────────────────
    // The last year before the details is the release year; an earlier one
    // is part of the title ("2001 A Space Odyssey 1968", "1917 2019").
    int? year;
    final years = _year.allMatches(work).where((m) => m.start <= cut).toList();
    if (years.isNotEmpty) {
      final chosen = years.last;
      final before = _clean(work.substring(0, chosen.start));
      if (before.isNotEmpty) {
        year = int.parse(chosen.group(1)!);
        if (chosen.start < cut) cut = chosen.start;
      }
    }

    var titlePart = work.substring(0, cut);

    // ─── Loose episode numbers ──────────────────────────────────────────
    int? loose = bracketEpisode;
    if (episode == null && loose == null && !isSpecial) {
      // "Title - 03" may sit after a season tag that already ended the title.
      final dash = _looseDash.firstMatch(work);
      if (dash != null) {
        loose = int.parse(dash.group(1)!);
        if (dash.start < titlePart.length) titlePart = titlePart.substring(0, dash.start);
      } else {
        final rest = _separatorsToSpaces(titlePart).trimRight();
        final trailing = _looseTrailing.firstMatch(rest);
        if (trailing != null) {
          final digits = trailing.group(1)!;
          final before = _clean(rest.substring(0, trailing.start));
          // Alone, a number is an episode ("03.mkv") unless it reads as a
          // year, which makes it a title ("2012", "1917"). After a title it
          // is more likely a sequel ("Toy Story 3"), unless it is
          // zero-padded the way episode numbers are.
          final yearLike = _year.hasMatch(digits);
          final zeroPadded = digits.length >= 2 && digits.startsWith('0');
          if (before.isEmpty ? !yearLike : zeroPadded) {
            loose = int.parse(digits);
            titlePart = rest.substring(0, trailing.start);
          }
        }
      }
    }
    if (isSpecial && specialNumber != null) episode = specialNumber;

    final title = _clean(titlePart);

    // ─── Release group ──────────────────────────────────────────────────
    if (group == null) {
      final tail = _trailingGroup.firstMatch(details.replaceAll(_brackets, '').trimRight());
      if (tail != null && cut < work.length && !_isDetailTag(tail.group(1)!)) group = tail.group(1);
    }

    final resolution = _resolutionOf(details);
    return ParsedName(
      title: title.isEmpty ? null : title,
      year: year,
      season: season,
      episode: episode,
      episodeEnd: episodeEnd != null && episode != null && episodeEnd > episode ? episodeEnd : null,
      looseEpisode: loose,
      isSpecial: isSpecial,
      resolution: resolution,
      source: _canonicalSource(_source.firstMatch(details)?.group(1)),
      videoCodec: _canonicalCodec(_codec.firstMatch(details)?.group(1)),
      hdr: _canonicalHdr(_hdr.firstMatch(details)?.group(1)),
      edition: _canonicalEdition(_edition.firstMatch(details)),
      releaseGroup: group,
      fansubStyle: fansub,
    );
  }

  // ─── Organised names ───────────────────────────────────────────────────

  /// `Title (2025)`, `Title (2025)-part - 1080p`: the shape organisers
  /// (MoviePilot, Radarr, Jellyfin's own) give film folders and files.
  static final RegExp _standardMovie = RegExp(
    r'^(?<title>[^\[\]【】]+?)\s\((?<year>(?:19|20)\d{2})\)(?:-(?<part>\S+?))?(?:\s-\s(?<rest>.+))?$',
  );

  /// `Title - S01E02`, `Title - S01E02-E03 - 第 2 集`: the same tools' episode
  /// files. The year sits on the show folder, not here.
  static final RegExp _standardEpisode = RegExp(
    r'^(?<title>[^\[\]【】]+?)\s-\s[Ss](?<season>\d{1,2})[Ee](?<episode>\d{1,4})(?:-?[Ee](?<end>\d{1,4}))?(?:-(?<part>\S+?))?(?:\s-\s(?<rest>.+))?$',
  );

  /// Names an organiser wrote are taken at their word: the title is
  /// everything before ` (year)` or ` - S01E02`, verbatim. Guessing would only
  /// lose information here — "仙逆剧场版:弑仙之战" is a title, not a film
  /// marker, and "三国的星空第一部" is not season one.
  static ParsedName? _parseStandard(String name) {
    final episode = _standardEpisode.firstMatch(name);
    if (episode != null) {
      final rest = episode.namedGroup('rest') ?? '';
      final start = int.parse(episode.namedGroup('episode')!);
      final end = int.tryParse(episode.namedGroup('end') ?? '');
      return ParsedName(
        title: episode.namedGroup('title')!.trim(),
        season: int.parse(episode.namedGroup('season')!),
        episode: start,
        episodeEnd: end != null && end > start ? end : null,
        isSpecial: int.parse(episode.namedGroup('season')!) == 0,
        resolution: _resolutionOf(rest),
        source: _canonicalSource(_source.firstMatch(rest)?.group(1)),
        videoCodec: _canonicalCodec(_codec.firstMatch(rest)?.group(1)),
        hdr: _canonicalHdr(_hdr.firstMatch(rest)?.group(1)),
        edition: _canonicalEdition(_edition.firstMatch(rest)),
      );
    }

    final movie = _standardMovie.firstMatch(name);
    if (movie == null) return null;
    final rest = movie.namedGroup('rest') ?? '';
    // "Show (2019) - 05" is an episode numbered loosely; leave it to the
    // general rules, which know about those.
    if (RegExp(r'^\d{1,4}(?:\s|$)').hasMatch(rest) ||
        _seasonEpisode.hasMatch(rest) ||
        _episodeChinese.hasMatch(rest) ||
        _episodeWord.hasMatch(rest)) {
      return null;
    }
    return ParsedName(
      title: movie.namedGroup('title')!.trim(),
      year: int.parse(movie.namedGroup('year')!),
      resolution: _resolutionOf(rest),
      source: _canonicalSource(_source.firstMatch(rest)?.group(1)),
      videoCodec: _canonicalCodec(_codec.firstMatch(rest)?.group(1)),
      hdr: _canonicalHdr(_hdr.firstMatch(rest)?.group(1)),
      edition: _canonicalEdition(_edition.firstMatch(rest)),
    );
  }

  /// Parses a folder name for the title, year or season it carries.
  static ParsedFolder parseFolder(String folderName) {
    final name = _fullWidthToAscii(folderName).trim();
    final seasonMatch = _seasonFolder.firstMatch(name);
    if (seasonMatch != null) {
      final raw = seasonMatch.group(1) ?? seasonMatch.group(2)!;
      return ParsedFolder(season: _number(raw), isSeasonFolder: true);
    }
    if (_specialsFolder.hasMatch(name)) return const ParsedFolder(season: 0, isSeasonFolder: true);

    final parsed = parseFile(name);
    // "Show Name S02" and "剧名 第二季": a title that also names the season.
    return ParsedFolder(title: parsed.title, year: parsed.year, season: parsed.season);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────

  static bool _isDetailTag(String tag) => _stripDetails(tag).trim().isEmpty || _checksum.hasMatch(tag.trim());

  static String _stripDetails(String text) {
    var out = text;
    for (final pattern in [_resolution, _fourK, _dimensions, _source, _codec, _hdr, _audio, _edition, _misc]) {
      out = out.replaceAll(pattern, ' ');
    }
    return out.replaceAll(RegExp(r'[\s._\-+&,/]+'), ' ');
  }

  static String _separatorsToSpaces(String text) => text.replaceAll(RegExp(r'[._]+'), ' ');

  static String _clean(String text) {
    var out = _separatorsToSpaces(text);
    out = out.replaceAll(RegExp(r'[\[\]【】()（）]'), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Separators left dangling where a token was cut away.
    out = out.replaceAll(RegExp(r'^[\s\-–—:：|~]+|[\s\-–—:：|~]+$'), '');
    return out.trim();
  }

  static String? _resolutionOf(String text) {
    final direct = _resolution.firstMatch(text);
    if (direct != null) return '${direct.group(1)}p';
    final dims = _dimensions.firstMatch(text);
    if (dims != null) return '${dims.group(2)}p';
    final alias = _fourK.firstMatch(text)?.group(1)?.toLowerCase();
    if (alias == null) return null;
    return _resolutionAliases.contains(alias) ? '2160p' : '4320p';
  }

  static String? _canonicalSource(String? raw) {
    if (raw == null) return null;
    final key = raw.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
    return switch (key) {
      'bluray' || 'bd' || 'bdrip' || 'brrip' || 'bdmv' || 'uhdbd' => 'BluRay',
      'remux' => 'Remux',
      'webdl' || 'web' => 'WEB-DL',
      'webrip' => 'WEBRip',
      'hdtv' || 'pdtv' => 'HDTV',
      'dvd' || 'dvdrip' => 'DVD',
      _ => raw.toUpperCase(),
    };
  }

  static String? _canonicalCodec(String? raw) {
    if (raw == null) return null;
    final key = raw.toLowerCase().replaceAll(RegExp(r'[\s.]'), '');
    return switch (key) {
      'x265' || 'h265' || 'hevc' => 'HEVC',
      'x264' || 'h264' || 'avc' => 'H.264',
      'av1' => 'AV1',
      'vp9' => 'VP9',
      // Bit depth alone says nothing about the codec.
      '10bit' || '8bit' || 'hi10p' => null,
      _ => raw.toUpperCase(),
    };
  }

  static String? _canonicalHdr(String? raw) {
    if (raw == null) return null;
    final key = raw.toLowerCase().replaceAll(RegExp(r'[\s.]'), '');
    return switch (key) {
      'dovi' || 'dv' || 'dolbyvision' => 'Dolby Vision',
      'hdr10+' => 'HDR10+',
      'hlg' => 'HLG',
      _ => 'HDR',
    };
  }

  static String? _canonicalEdition(Match? match) {
    if (match == null) return null;
    final chinese = match.group(2);
    if (chinese != null) return chinese;
    final key = match.group(1)!.toLowerCase().replaceAll('.', ' ');
    if (key.startsWith('director')) return "Director's Cut";
    if (key.startsWith('extended')) return 'Extended';
    if (key.startsWith('theatrical')) return 'Theatrical';
    if (key.startsWith('final')) return 'Final Cut';
    if (key.startsWith('special')) return 'Special Edition';
    return switch (key) {
      'imax' => 'IMAX',
      _ => '${key[0].toUpperCase()}${key.substring(1)}',
    };
  }

  static String _fullWidthToAscii(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      // Full-width digits and Latin letters, as typed with a CJK input method.
      buffer.writeCharCode(rune >= 0xFF10 && rune <= 0xFF5A ? rune - 0xFEE0 : rune);
    }
    return buffer.toString();
  }

  static const Map<String, int> _chineseDigits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };

  /// Reads Arabic digits or a Chinese numeral below 1000 (`十二`, `二十`, `一百零三`).
  static int? _number(String text) {
    final direct = int.tryParse(text);
    if (direct != null) return direct;
    var total = 0;
    var current = 0;
    var seen = false;
    for (final char in text.split('')) {
      final digit = _chineseDigits[char];
      if (digit != null) {
        current = digit;
        seen = true;
      } else if (char == '十') {
        total += (current == 0 ? 1 : current) * 10;
        current = 0;
        seen = true;
      } else if (char == '百') {
        total += (current == 0 ? 1 : current) * 100;
        current = 0;
        seen = true;
      } else {
        return null;
      }
    }
    return seen ? total + current : null;
  }
}
