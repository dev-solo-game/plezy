import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../ttplay/ttplay_admin_service.dart';
import '../../ttplay/ttplay_server_client.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import 'ttplay_admin_guard.dart';

/// Opens the server-authoritative Manual Match dialog for a `ttplay-server` item
/// on PC & mobile. Returns `true` if a match was applied.
Future<bool> showTtplayManualMatchDialog(BuildContext context, MediaItem item) async {
  if (PlatformDetector.isTV()) return false;
  final binder = maybeReadTtplayBinder(context);
  final admin = binder?.adminService;
  if (admin == null) return false;
  return await showDialog<bool>(
        context: context,
        builder: (_) => _TtplayManualMatchDialog(admin: admin, primaryClient: binder?.primaryClient, item: item),
      ) ??
      false;
}

/// Opens the server-authoritative Metadata Edit dialog for a `ttplay-server` item
/// on PC & mobile. Returns `true` if changes were saved.
Future<bool> showTtplayMetadataEditDialog(BuildContext context, MediaItem item) async {
  if (PlatformDetector.isTV()) return false;
  final admin = resolveTtplayAdminService(context);
  if (admin == null) return false;
  return await showDialog<bool>(
        context: context,
        builder: (_) => _TtplayMetadataEditDialog(admin: admin, item: item),
      ) ??
      false;
}

class _TtplayManualMatchDialog extends StatefulWidget {
  const _TtplayManualMatchDialog({required this.admin, required this.primaryClient, required this.item});

  final TtplayAdminService admin;
  final TtplayServerClient? primaryClient;
  final MediaItem item;

  @override
  State<_TtplayManualMatchDialog> createState() => _TtplayManualMatchDialogState();
}

class _TtplayManualMatchDialogState extends State<_TtplayManualMatchDialog> {
  static const List<String> _providers = ['all', 'tmdb', 'douban', 'bangumi', 'anilist', 'imdb', 'tvdb'];
  static const List<String?> _shelves = [null, 'movie', 'show', 'anime', 'variety', 'documentary'];

  late final TextEditingController _query = TextEditingController(text: widget.item.title);
  late final TextEditingController _year = TextEditingController(text: widget.item.year?.toString() ?? '');
  late bool _asShow = widget.item.kind == MediaKind.show;
  String _provider = 'all';
  String? _shelf;
  String? _filePath;
  List<TtplayScrapeCandidate>? _results;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareAndSearch());
  }

  @override
  void dispose() {
    _query.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _prepareAndSearch() async {
    try {
      final editable = await widget.admin.fetchEditableItem(widget.item.id);
      if (mounted && editable?.sampleFilePath != null) {
        setState(() => _filePath = editable!.sampleFilePath);
      }
    } catch (_) {}
    if (mounted) await _search();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await widget.admin.searchScrapeCandidates(
        query: q,
        asShow: _asShow,
        year: int.tryParse(_year.text.trim()),
        provider: _provider,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ttplayAdminErrorText(e);
          _busy = false;
        });
      }
    }
  }

  Future<void> _apply(TtplayScrapeCandidate candidate) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.admin.applyManualMatch(
        widget.item.id,
        provider: candidate.source,
        externalId: candidate.id,
        asShow: _asShow,
        libraryType: _shelf,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ttplayAdminErrorText(e);
          _busy = false;
        });
      }
    }
  }

  String _shelfLabel(String? shelf) => switch (shelf) {
    null => t.serverAdmin.targetShelfAuto,
    'movie' => t.storage.content.movie,
    'show' => t.storage.content.show,
    'anime' => t.storage.content.anime,
    'variety' => t.storage.content.variety,
    'documentary' => t.storage.content.documentary,
    _ => shelf,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.serverAdmin.manualMatch),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_filePath != null && _filePath!.isNotEmpty) ...[
              Text(
                _filePath!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _query,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      labelText: t.serverAdmin.fieldTitle,
                      hintText: t.serverAdmin.matchSearchHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: _year,
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      labelText: t.serverAdmin.fieldYear,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _search,
                  icon: const AppIcon(Symbols.search_rounded, size: 18),
                  label: Text(t.common.search),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(t.serverAdmin.mediaTypeMovie)),
                    ButtonSegment(value: true, label: Text(t.serverAdmin.mediaTypeShow)),
                  ],
                  selected: {_asShow},
                  onSelectionChanged: (s) {
                    setState(() => _asShow = s.first);
                    unawaited(_search());
                  },
                ),
                DropdownButton<String>(
                  value: _provider,
                  items: [
                    for (final p in _providers)
                      DropdownMenuItem(value: p, child: Text(p == 'all' ? t.serverAdmin.providerAll : p.toUpperCase())),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _provider = v);
                      unawaited(_search());
                    }
                  },
                ),
                DropdownButton<String?>(
                  value: _shelf,
                  items: [for (final s in _shelves) DropdownMenuItem(value: s, child: Text(_shelfLabel(s)))],
                  onChanged: (v) => setState(() => _shelf = v),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            Expanded(
              child: _busy && _results == null
                  ? const Center(child: CircularProgressIndicator())
                  : (_results == null || _results!.isEmpty)
                  ? Center(child: Text(t.storage.noMatchResults))
                  : ListView.separated(
                      itemCount: _results!.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final cand = _results![index];
                        final posterUrl = widget.primaryClient?.thumbnailUrl(cand.posterPath, width: 185);
                        return Card(
                          child: ListTile(
                            leading: posterUrl != null && posterUrl.isNotEmpty
                                ? Image.network(
                                    posterUrl,
                                    width: 44,
                                    height: 64,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const AppIcon(Symbols.movie_rounded),
                                  )
                                : const AppIcon(Symbols.movie_rounded),
                            title: Text(
                              cand.year != null ? '${cand.title} (${cand.year})' : cand.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${cand.source.toUpperCase()} #${cand.id}'
                              '${cand.originalTitle != null ? ' · ${cand.originalTitle}' : ''}'
                              '${cand.summary != null ? '\n${cand.summary}' : ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: FilledButton(
                              onPressed: _busy ? null : () => _apply(cand),
                              child: Text(t.serverAdmin.applyMatch),
                            ),
                            onTap: _busy ? null : () => _apply(cand),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
      ],
    );
  }
}

class _TtplayMetadataEditDialog extends StatefulWidget {
  const _TtplayMetadataEditDialog({required this.admin, required this.item});

  final TtplayAdminService admin;
  final MediaItem item;

  @override
  State<_TtplayMetadataEditDialog> createState() => _TtplayMetadataEditDialogState();
}

class _TtplayMetadataEditDialogState extends State<_TtplayMetadataEditDialog> {
  static const List<String> _shelves = ['movie', 'show', 'anime', 'variety', 'documentary'];

  final _title = TextEditingController();
  final _originalTitle = TextEditingController();
  final _year = TextEditingController();
  final _summary = TextEditingController();
  final _tagline = TextEditingController();
  final _studio = TextEditingController();
  final _rating = TextEditingController();

  String _libraryType = 'movie';
  bool _locked = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.text = widget.item.title ?? '';
    _originalTitle.text = widget.item.originalTitle ?? '';
    _year.text = widget.item.year?.toString() ?? '';
    _summary.text = widget.item.summary ?? '';
    _tagline.text = widget.item.tagline ?? '';
    _studio.text = widget.item.studio ?? '';
    _rating.text = widget.item.rating?.toString() ?? '';
    _libraryType = _shelves.contains(widget.item.libraryId) ? widget.item.libraryId! : 'movie';
    unawaited(_load());
  }

  @override
  void dispose() {
    _title.dispose();
    _originalTitle.dispose();
    _year.dispose();
    _summary.dispose();
    _tagline.dispose();
    _studio.dispose();
    _rating.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final editable = await widget.admin.fetchEditableItem(widget.item.id);
      if (!mounted) return;
      if (editable != null) {
        _title.text = editable.title;
        _originalTitle.text = editable.originalTitle ?? '';
        _year.text = editable.year?.toString() ?? '';
        _summary.text = editable.summary ?? '';
        _tagline.text = editable.tagline ?? '';
        _studio.text = editable.studio ?? '';
        _rating.text = editable.rating?.toString() ?? '';
        if (editable.libraryType != null && _shelves.contains(editable.libraryType)) {
          _libraryType = editable.libraryType!;
        }
        _locked = editable.locked;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final patch = <String, dynamic>{
        'title': _title.text.trim(),
        'original_title': _originalTitle.text.trim(),
        'library_type': _libraryType,
        'summary': _summary.text.trim(),
        'tagline': _tagline.text.trim(),
        'studio': _studio.text.trim(),
        'locked': _locked,
      };
      final parsedYear = int.tryParse(_year.text.trim());
      if (parsedYear != null) patch['year'] = parsedYear;
      final parsedRating = double.tryParse(_rating.text.trim());
      if (parsedRating != null) patch['rating'] = parsedRating;
      await widget.admin.updateItemMetadata(widget.item.id, patch);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = ttplayAdminErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.serverAdmin.editMetadata),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _title,
                      decoration: InputDecoration(labelText: t.serverAdmin.fieldTitle, border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _originalTitle,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.fieldOriginalTitle,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _year,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t.serverAdmin.fieldYear,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _rating,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: t.serverAdmin.fieldRating,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _libraryType,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.fieldShelf,
                        border: const OutlineInputBorder(),
                      ),
                      items: [for (final s in _shelves) DropdownMenuItem(value: s, child: Text(s))],
                      onChanged: (v) {
                        if (v != null) setState(() => _libraryType = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _studio,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.fieldStudio,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _tagline,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.fieldTagline,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _summary,
                      minLines: 3,
                      maxLines: 5,
                      decoration: InputDecoration(
                        labelText: t.serverAdmin.fieldSummary,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _locked,
                      onChanged: (v) => setState(() => _locked = v),
                      title: Text(t.serverAdmin.fieldLocked),
                    ),
                    if (_error != null)
                      Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
        FilledButton(onPressed: (_loading || _saving) ? null : _save, child: Text(t.common.save)),
      ],
    );
  }
}
