import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/utils/download_version_utils.dart';

void main() {
  testWidgets('the version picker shows where each copy lives', (tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    const versions = [
      MediaVersion(id: '1', name: '夸克网盘 · 1080p', container: 'mkv', description: '/电影/沙丘 (2021)/沙丘 (2021) - 1080p.mkv'),
      MediaVersion(id: '2', name: '本地硬盘 · 1080p', container: 'mkv', description: '/Movies/Dune.2021.1080p.mkv'),
    ];
    final picked = showVersionPickerDialog(host, versions, 'Play version');
    await tester.pumpAndSettle();

    expect(find.text('夸克网盘 · 1080p · MKV'), findsOneWidget);
    expect(find.text('本地硬盘 · 1080p · MKV'), findsOneWidget);
    expect(find.byTooltip('/电影/沙丘 (2021)/沙丘 (2021) - 1080p.mkv'), findsOneWidget);
    expect(find.byTooltip('/Movies/Dune.2021.1080p.mkv'), findsOneWidget);
    expect(find.text('沙丘 (2021) - 1080p.mkv'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('本地硬盘 · 1080p · MKV'));
    await tester.pumpAndSettle();
    expect(await picked, 1);
  });

  testWidgets('a long path keeps its file name', (tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final longPath = '/${List.filled(30, '很长的文件夹名').join('/')}/沙丘 (2021) - 1080p.mkv';
    unawaitedPick(showVersionPickerDialog(host, [MediaVersion(id: '1', name: 'A', description: longPath)], 'Pick'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'no overflow or layout error');
    expect(find.text('沙丘 (2021) - 1080p.mkv'), findsOneWidget, reason: 'the file name is its own text');
    final folderText = tester.widget<Text>(find.textContaining('很长的文件夹名'));
    expect(folderText.overflow, TextOverflow.ellipsis);
  });
}

void unawaitedPick(Future<int?> _) {}
