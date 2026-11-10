/// Helpers for mount-relative paths: POSIX separators, always absolute, no
/// trailing slash except for the root itself.
abstract final class StoragePath {
  static const String root = '/';

  /// Collapses separators, resolves `.` and `..`, and makes [path] absolute.
  /// `..` never climbs above the root, so a normalized path cannot escape the
  /// mount.
  static String normalize(String path) {
    final segments = <String>[];
    for (final segment in path.replaceAll('\\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    return '/${segments.join('/')}';
  }

  static List<String> segments(String path) {
    final normalized = normalize(path);
    return normalized == root ? const [] : normalized.substring(1).split('/');
  }

  static String join(String parent, String name) => normalize('$parent/$name');

  static String parent(String path) {
    final parts = segments(path);
    if (parts.length <= 1) return root;
    return '/${parts.sublist(0, parts.length - 1).join('/')}';
  }

  static String name(String path) {
    final parts = segments(path);
    return parts.isEmpty ? '' : parts.last;
  }

  /// Lower-case extension without the dot, or an empty string.
  static String extension(String path) {
    final base = name(path);
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || dot == base.length - 1) return '';
    return base.substring(dot + 1).toLowerCase();
  }
}
