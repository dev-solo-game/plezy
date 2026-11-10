// Scaffolding: shows what the scanner filed, shelf by shelf, until the real
// library screens read from the local library.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../library/library_repository.dart';
import '../../widgets/app_icon.dart';
import 'mounts_screen.dart';

class LibraryPreviewScreen extends StatelessWidget {
  const LibraryPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.storage.scanResults),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              Tab(text: t.storage.content.movie),
              Tab(text: t.storage.content.show),
              Tab(text: t.storage.content.anime),
              Tab(text: t.storage.unidentified),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _Shelf(libraryType: 'movie', kind: LibraryKinds.movie),
            _Shelf(libraryType: 'show', kind: LibraryKinds.show),
            _AnimeShelf(),
            _UnidentifiedList(),
          ],
        ),
      ),
    );
  }
}

/// Anime holds both series and films, so its tab lists the two together.
class _AnimeShelf extends StatelessWidget {
  const _AnimeShelf();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LibraryRepository>();
    return _Loaded<List<LibraryItemView>>(
      load: () async => [
        ...(await repo.queryTitles(
          const LibraryQuery(libraryType: 'anime', kind: LibraryKinds.show, limit: 500),
        )).items,
        ...(await repo.queryTitles(
          const LibraryQuery(libraryType: 'anime', kind: LibraryKinds.movie, limit: 500),
        )).items,
      ],
      builder: (titles) => _TitleList(titles: titles),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.libraryType, required this.kind});

  final String libraryType;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LibraryRepository>();
    return _Loaded<List<LibraryItemView>>(
      load: () async => (await repo.queryTitles(LibraryQuery(libraryType: libraryType, kind: kind, limit: 500))).items,
      builder: (titles) => _TitleList(titles: titles),
    );
  }
}

class _TitleList extends StatelessWidget {
  const _TitleList({required this.titles});

  final List<LibraryItemView> titles;

  @override
  Widget build(BuildContext context) {
    if (titles.isEmpty) return Center(child: Text(t.storage.emptyShelf));
    final repo = context.read<LibraryRepository>();
    return _Centered(
      child: ListView.builder(
        itemCount: titles.length,
        itemBuilder: (context, index) {
          final view = titles[index];
          final item = view.item;
          final isShow = item.kind == LibraryKinds.show;
          return ListTile(
            leading: AppIcon(isShow ? Symbols.tv_rounded : Symbols.movie_rounded),
            title: Text(item.year == null ? item.title : '${item.title} (${item.year})'),
            subtitle: isShow
                ? Text(t.storage.episodeCount(n: view.episodeCount))
                : FutureBuilder<List<LibraryFileRow>>(
                    future: repo.versionsOf(item.id),
                    builder: (context, snapshot) {
                      final versions = snapshot.data ?? const [];
                      if (versions.length <= 1) return Text(versions.firstOrNull?.versionLabel ?? '');
                      final labels = versions.map((v) => v.versionLabel).whereType<String>().join(', ');
                      final count = t.storage.versionCount(n: versions.length);
                      return Text(labels.isEmpty ? count : '$count · $labels');
                    },
                  ),
          );
        },
      ),
    );
  }
}

class _UnidentifiedList extends StatelessWidget {
  const _UnidentifiedList();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LibraryRepository>();
    return _Loaded<List<LibraryFileRow>>(
      load: () => repo.videosInState(LibraryMatchStates.unmatched, limit: 500),
      builder: (files) {
        if (files.isEmpty) return Center(child: Text(t.storage.emptyShelf));
        return _Centered(
          child: ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) =>
                ListTile(leading: const AppIcon(Symbols.help_rounded), title: Text(files[index].path)),
          ),
        );
      },
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: storageContentMaxWidth),
        child: child,
      ),
    );
  }
}

/// Runs [load] once and shows a spinner, the error, or [builder]'s result.
class _Loaded<T> extends StatefulWidget {
  const _Loaded({required this.load, required this.builder});

  final Future<T> Function() load;
  final Widget Function(T data) builder;

  @override
  State<_Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<_Loaded<T>> {
  late final Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        final data = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done || data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return widget.builder(data);
      },
    );
  }
}
