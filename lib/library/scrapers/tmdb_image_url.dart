import 'tmdb_provider.dart';

/// Helpers for converting between relative TMDB artwork paths (`/abc.jpg`)
/// and full image URLs at the desired resolution bucket.
abstract final class TmdbImageUrl {
  static final RegExp _tmdbFullImageRe = RegExp(
    r'^https?://[^/]+(?:/[^?#]*)?/t/p/[^/]+(/[^?#]+)$',
    caseSensitive: false,
  );

  /// Converts a full TMDB image URL into a mirror-independent relative path
  /// (`/foo.jpg`). Leaves already-relative paths, `mount:...` paths, and
  /// non-TMDB URLs (such as Bangumi URLs) unchanged.
  static String? toRelativePath(String? source) {
    final trimmed = source?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('mount:')) return trimmed;
    final match = _tmdbFullImageRe.firstMatch(trimmed);
    if (match != null) {
      return match.group(1);
    }
    return trimmed;
  }

  /// Picks a TMDB size bucket appropriate for [width] (or logo PNGs).
  static String sizeForWidth(int? width, {String? path}) {
    if (path != null && path.toLowerCase().endsWith('.png') && (width == null || width <= 500)) {
      return 'w500';
    }
    if (width == null || width <= 0) return 'w780';
    if (width <= 220) return 'w185';
    if (width <= 400) return 'w342';
    if (width <= 600) return 'w500';
    if (width <= 900) return 'w780';
    return 'w1280';
  }

  /// Expands a relative TMDB path (`/foo.jpg`) against [imageBase] and [size].
  /// Non-leading-slash values (`http://...`, `https://...`, `mount:...`) pass
  /// through unchanged.
  static String resolve(String path, {String? imageBase, String size = 'w780'}) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      final base = TmdbProvider.normalizeBase(imageBase, TmdbProvider.defaultImageBase, defaultPath: '/t/p');
      return '$base/$size$trimmed';
    }
    return trimmed;
  }
}
