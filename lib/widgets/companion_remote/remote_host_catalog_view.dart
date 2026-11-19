import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/companion_remote/remote_playback_models.dart';
import '../../providers/companion_remote_provider.dart';
import '../../theme/mono_tokens.dart';
import '../app_icon.dart';

typedef _CatalogNode = ({String serverId, String itemId, String? kind, String title});

/// Search and browse media libraries hosted on the currently controlled
/// companion device, launching playback directly on that device without
/// requiring any local media ownership on this controller.
class RemoteHostCatalogView extends StatefulWidget {
  const RemoteHostCatalogView({super.key, this.onPlaybackStarted});

  final VoidCallback? onPlaybackStarted;

  @override
  State<RemoteHostCatalogView> createState() => _RemoteHostCatalogViewState();
}

class _RemoteHostCatalogViewState extends State<RemoteHostCatalogView> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  int _loadEpoch = 0;

  bool _loadingHome = true;
  RemoteHostHomeResponse? _home;
  String? _homeError;

  bool _searching = false;
  RemoteHostSearchResponse? _searchResponse;
  String? _searchError;

  final List<_CatalogNode> _browseStack = [];
  bool _loadingChildren = false;
  RemoteHostChildrenResponse? _childrenResponse;
  String? _childrenError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHome());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHome() async {
    final epoch = ++_loadEpoch;
    setState(() {
      _loadingHome = true;
      _homeError = null;
    });
    try {
      final resp = await context.read<CompanionRemoteProvider>().fetchHostHome();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingHome = false;
        _home = resp;
        _homeError = resp.error;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingHome = false;
        _homeError = e.toString();
      });
    }
  }

  void _onSearchChanged(String raw) {
    _searchDebounce?.cancel();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      _loadEpoch++;
      setState(() {
        _searching = false;
        _searchResponse = null;
        _searchError = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) unawaited(_runSearch(trimmed));
    });
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _onSearchChanged('');
      return;
    }
    final epoch = ++_loadEpoch;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final resp = await context.read<CompanionRemoteProvider>().searchHostCatalog(trimmed);
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _searching = false;
        _searchResponse = resp;
        _searchError = resp.error;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _searching = false;
        _searchError = e.toString();
      });
    }
  }

  Future<void> _openChildren(_CatalogNode node, {bool push = true}) async {
    final epoch = ++_loadEpoch;
    setState(() {
      if (push) _browseStack.add(node);
      _loadingChildren = true;
      _childrenResponse = null;
      _childrenError = null;
    });
    try {
      final resp = await context.read<CompanionRemoteProvider>().fetchHostItemChildren(
        serverId: node.serverId,
        itemId: node.itemId,
        kind: node.kind,
      );
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingChildren = false;
        _childrenResponse = resp;
        _childrenError = resp.error;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingChildren = false;
        _childrenError = e.toString();
      });
    }
  }

  void _popChildren() {
    if (_browseStack.isEmpty) return;
    _browseStack.removeLast();
    if (_browseStack.isEmpty) {
      _loadEpoch++;
      setState(() {
        _loadingChildren = false;
        _childrenResponse = null;
        _childrenError = null;
      });
      return;
    }
    unawaited(_openChildren(_browseStack.last, push: false));
  }

  void _playItem(RemoteCatalogItem item) {
    context.read<CompanionRemoteProvider>().playHostCatalogItem(item);
    widget.onPlaybackStarted?.call();
  }

  void _openItem(RemoteCatalogItem item) {
    if (item.isContainer) {
      unawaited(
        _openChildren((
          serverId: item.serverId,
          itemId: item.itemId,
          kind: item.kind,
          title: item.title,
        )),
      );
    } else {
      _playItem(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queryText = _searchController.text.trim();
    final isSearchActive = queryText.isNotEmpty;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onChanged: _onSearchChanged,
                      onSubmitted: (v) {
                        _searchDebounce?.cancel();
                        unawaited(_runSearch(v));
                      },
                      decoration: InputDecoration(
                        hintText: t.companionRemote.searchTargetHint,
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: t.common.clear,
                                icon: const AppIcon(Symbols.close_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchChanged('');
                                },
                              ),
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: t.common.refresh,
                    icon: const AppIcon(Symbols.refresh_rounded),
                    onPressed: () {
                      if (isSearchActive) {
                        unawaited(_runSearch(queryText));
                      } else if (_browseStack.isNotEmpty) {
                        unawaited(_openChildren(_browseStack.last, push: false));
                      } else {
                        unawaited(_loadHome());
                      }
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: isSearchActive
                  ? _buildSearchBody(context)
                  : _browseStack.isNotEmpty
                  ? _buildChildrenBody(context)
                  : _buildHomeBody(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBody(BuildContext context) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError != null && (_searchResponse?.items.isEmpty ?? true)) {
      return _buildErrorState(
        context,
        message: t.companionRemote.targetMediaLoadFailed,
        onRetry: () => unawaited(_runSearch(_searchController.text)),
      );
    }
    final items = _searchResponse?.items ?? const [];
    if (items.isEmpty) {
      return _buildEmptyState(context, t.companionRemote.noTargetMedia);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) => _CatalogItemTile(
        item: items[index],
        onTap: () => _openItem(items[index]),
        onPlay: () => _playItem(items[index]),
      ),
    );
  }

  Widget _buildChildrenBody(BuildContext context) {
    final current = _browseStack.last;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 16, 6),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _popChildren,
                icon: const AppIcon(Symbols.arrow_back_rounded, size: 18),
                label: Text(t.companionRemote.backToBrowse),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _childrenResponse?.title?.isNotEmpty == true ? _childrenResponse!.title! : current.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loadingChildren
              ? const Center(child: CircularProgressIndicator())
              : (_childrenError != null && (_childrenResponse?.items.isEmpty ?? true))
              ? _buildErrorState(
                  context,
                  message: t.companionRemote.targetMediaLoadFailed,
                  onRetry: () => unawaited(_openChildren(current, push: false)),
                )
              : (_childrenResponse?.items.isEmpty ?? true)
              ? _buildEmptyState(context, t.companionRemote.noTargetMedia)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _childrenResponse!.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = _childrenResponse!.items[index];
                    return _CatalogItemTile(
                      item: item,
                      onTap: () => _openItem(item),
                      onPlay: () => _playItem(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHomeBody(BuildContext context) {
    if (_loadingHome) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_homeError != null && (_home == null || (_home!.hubs.isEmpty && _home!.libraries.isEmpty))) {
      return _buildErrorState(context, message: t.companionRemote.targetMediaLoadFailed, onRetry: _loadHome);
    }

    final home = _home ?? const RemoteHostHomeResponse();
    if (home.libraries.isEmpty && home.hubs.isEmpty) {
      return _buildEmptyState(context, t.companionRemote.noTargetMedia, onRetry: _loadHome);
    }

    final distinctServerCount = {for (final lib in home.libraries) lib.serverId}.length;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (home.libraries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t.companionRemote.targetLibraries,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final lib in home.libraries) ...[
                  ActionChip(
                    avatar: AppIcon(
                      lib.kind == 'show' ? Symbols.tv_rounded : Symbols.movie_rounded,
                      size: 16,
                    ),
                    label: Text(
                      distinctServerCount > 1 && (lib.serverName?.isNotEmpty ?? false)
                          ? '${lib.title} · ${lib.serverName}'
                          : lib.title,
                    ),
                    onPressed: () => unawaited(
                      _openChildren((
                        serverId: lib.serverId,
                        itemId: lib.libraryId,
                        kind: 'library',
                        title: lib.title,
                      )),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        for (final hub in home.hubs) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    hub.title,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hub.serverName != null && hub.serverName!.isNotEmpty)
                  Text(
                    hub.serverName!,
                    style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted),
                  ),
              ],
            ),
          ),
          for (final item in hub.items) ...[
            _CatalogItemTile(item: item, onTap: () => _openItem(item), onPlay: () => _playItem(item)),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, String message, {VoidCallback? onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Symbols.video_library_rounded, size: 40, color: tokens(context).textMuted),
            const SizedBox(height: 10),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens(context).textMuted),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const AppIcon(Symbols.refresh_rounded, size: 18),
                label: Text(t.common.refresh),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, {required String message, required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Symbols.error_outline_rounded, size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 10),
            Text(message, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const AppIcon(Symbols.refresh_rounded, size: 18),
              label: Text(t.common.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogItemTile extends StatelessWidget {
  const _CatalogItemTile({required this.item, required this.onTap, required this.onPlay});

  final RemoteCatalogItem item;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final metaParts = [
      if (item.subtitle != null && item.subtitle!.isNotEmpty) item.subtitle!,
      if (item.serverName != null && item.serverName!.isNotEmpty) item.serverName!,
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: _PosterBox(thumbUrl: item.thumbUrl, kind: item.kind),
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: metaParts.isEmpty
            ? null
            : Text(metaParts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.isContainer) AppIcon(Symbols.chevron_right_rounded, size: 20, color: tokens(context).textMuted),
            IconButton(
              icon: const AppIcon(Symbols.play_arrow_rounded),
              tooltip: t.companionRemote.playOnTarget,
              onPressed: onPlay,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _PosterBox extends StatelessWidget {
  const _PosterBox({required this.thumbUrl, required this.kind});

  final String? thumbUrl;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final fallbackIcon = switch (kind) {
      'show' || 'season' => Symbols.tv_rounded,
      _ => Symbols.movie_rounded,
    };

    Widget placeholder() => Container(
      width: 40,
      height: 56,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: AppIcon(fallbackIcon, size: 20, color: tokens(context).textMuted),
    );

    if (thumbUrl == null || thumbUrl!.isEmpty) {
      return placeholder();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        thumbUrl!,
        width: 40,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder(),
      ),
    );
  }
}
