import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../library/library_repository.dart';
import '../../library/library_scan_service.dart';
import '../../library/library_scrape_runner.dart';
import '../../library/scrapers/scraped_metadata.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/path_text.dart';

/// Lets the user search the metadata sources for [item] and pick the right
/// entry. Resolves true when a match was applied.
Future<bool> showManualMatchDialog(BuildContext context, LibraryItemRow item) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => _ManualMatchDialog(item: item),
      ) ??
      false;
}

class _ManualMatchDialog extends StatefulWidget {
  const _ManualMatchDialog({required this.item});

  final LibraryItemRow item;

  @override
  State<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends State<_ManualMatchDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.item.title);
  late final TextEditingController _year = TextEditingController(text: widget.item.year?.toString() ?? '');
  List<ScrapedCandidate>? _results;
  String? _error;
  bool _busy = false;

  /// What to search for; starts as what the scanner took the files for.
  late bool _asShow = widget.item.kind == LibraryKinds.show;

  /// False for a show with several episodes, which cannot become a movie.
  bool _canChangeKind = false;

  /// The shelf to file the title on; null lets the match decide.
  String? _shelf;

  /// One of the title's files, so the user can see what is being matched.
  String? _filePath;

  @override
  void initState() {
    super.initState();
    final runner = context.read<LibraryScrapeRunner>();
    unawaited(
      runner.withScraper((scraper, _) => scraper.canChangeKind(widget.item.id)).then((allowed) {
        if (mounted) setState(() => _canChangeKind = allowed);
      }),
    );
    unawaited(_prepare());
  }

  /// Finds a file of the title and, when the title was matched before,
  /// searches with the name that file gives rather than the matched title:
  /// a wrong match is what is being corrected, so its title is the wrong
  /// thing to search for.
  Future<void> _prepare() async {
    final repo = context.read<LibraryRepository>();
    final item = widget.item;
    try {
      final leaf = item.kind == LibraryKinds.show ? (await repo.episodesOfShow(item.id)).firstOrNull?.item.id : item.id;
      final file = leaf == null ? null : (await repo.versionsOf(leaf)).firstOrNull;
      if (file != null && mounted) {
        setState(() => _filePath = file.path);
        if (item.metadataSource != null) {
          final parsed = _parsed(file.parsed);
          final title = parsed?['title'];
          if (title is String && title.trim().isNotEmpty) {
            _title.text = title.trim();
            final year = parsed?['year'];
            _year.text = year is int ? '$year' : (item.year?.toString() ?? '');
          }
        }
      }
    } catch (_) {
      // The search below still works from the title.
    }
    if (mounted) await _search();
  }

  static Map<String, Object?>? _parsed(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    super.dispose();
  }

  String _message(Object error) => error is ScrapeException ? error.message : '$error';

  Future<void> _search() async {
    final title = _title.text.trim();
    if (title.isEmpty || _busy) return;
    final runner = context.read<LibraryScrapeRunner>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await runner.withScraper(
        (scraper, settings) =>
            scraper.searchCandidates(title: title, asShow: _asShow, year: int.tryParse(_year.text.trim())),
      );
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(ScrapedCandidate candidate) async {
    if (_busy) return;
    final runner = context.read<LibraryScrapeRunner>();
    final scans = context.read<LibraryScanService>();
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await runner.withScraper(
        (scraper, settings) =>
            scraper.applyManualMatch(widget.item.id, candidate, asShow: _asShow, libraryType: _shelf),
      );
      scans.notifyLibraryChanged();
      if (mounted) navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    final error = _error;
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.storage.manualMatch),
          if (_filePath case final path?) ...[const SizedBox(height: 4), PathText(path)],
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 520,
        height: 500,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    controller: _title,
                    decoration: InputDecoration(labelText: t.storage.sortTitle, border: const OutlineInputBorder()),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _year,
                    decoration: InputDecoration(labelText: t.storage.sortYear, border: const OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: t.common.search,
                  onPressed: _busy ? null : _search,
                  icon: const AppIcon(Symbols.search_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, label: Text(t.storage.content.movie)),
                    ButtonSegment(value: true, label: Text(t.storage.kindSeries)),
                  ],
                  selected: {_asShow},
                  onSelectionChanged: _busy || !_canChangeKind
                      ? null
                      : (selection) {
                          setState(() => _asShow = selection.first);
                          unawaited(_search());
                        },
                ),
                const Spacer(),
                Text(t.storage.category, style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                DropdownButton<String?>(
                  value: _shelf,
                  onChanged: _busy ? null : (value) => setState(() => _shelf = value),
                  items: [
                    DropdownMenuItem(value: null, child: Text(t.storage.content.auto)),
                    DropdownMenuItem(value: LibraryTypes.movie, child: Text(t.storage.content.movie)),
                    DropdownMenuItem(value: LibraryTypes.show, child: Text(t.storage.content.show)),
                    DropdownMenuItem(value: LibraryTypes.anime, child: Text(t.storage.content.anime)),
                    DropdownMenuItem(value: LibraryTypes.variety, child: Text(t.storage.content.variety)),
                    DropdownMenuItem(value: LibraryTypes.documentary, child: Text(t.storage.content.documentary)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: error != null
                  ? Center(
                      child: Text(
                        error,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    )
                  : results == null
                  ? const SizedBox.shrink()
                  : results.isEmpty
                  ? Center(child: Text(t.storage.noMatchResults))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final candidate = results[index];
                        final poster = candidate.posterUrl;
                        final original = candidate.originalTitle;
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          leading: SizedBox(
                            width: 40,
                            height: 60,
                            child: poster == null
                                ? const AppIcon(Symbols.image_rounded)
                                : Image.network(
                                    poster,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const AppIcon(Symbols.broken_image_rounded),
                                  ),
                          ),
                          title: Text(
                            candidate.year == null ? candidate.title : '${candidate.title} (${candidate.year})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              candidate.source.toUpperCase(),
                              if (original != null && original != candidate.title) original,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          enabled: !_busy,
                          onTap: () => _apply(candidate),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel))],
    );
  }
}
