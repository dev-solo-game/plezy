import 'package:flutter/material.dart';

/// A file path on one muted line. When it does not fit, the folders give
/// way before the file name — the part that tells two paths apart.
///
/// Built from plain rows and texts, so it also works inside dialogs that
/// size themselves to their content.
class PathText extends StatelessWidget {
  const PathText(this.path, {super.key});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final slash = path.lastIndexOf('/');
    final folder = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = slash < 0 ? path : path.substring(slash + 1);
    Text part(String text) => Text(text, style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis);
    return Tooltip(
      message: path,
      child: Row(
        children: [
          if (folder.isNotEmpty) Flexible(child: part(folder)),
          Flexible(flex: 3, child: part(name)),
        ],
      ),
    );
  }
}
