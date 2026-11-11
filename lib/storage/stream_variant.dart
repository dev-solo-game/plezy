import 'storage_driver.dart';

/// A rendition of a file that the backend transcoded itself, such as the
/// lower resolutions a cloud drive offers next to the original.
class StreamVariant {
  const StreamVariant({
    required this.id,
    required this.url,
    this.headers = const {},
    this.width,
    this.height,
    this.isHls = false,
  });

  /// The backend's name for this rendition. Stable across files, so a choice
  /// made on one episode can be found again on the next.
  final String id;
  final Uri url;

  /// Headers every request for this rendition, playlist and segments alike,
  /// must carry.
  final Map<String, String> headers;
  final int? width;
  final int? height;

  /// Whether [url] is an HLS playlist rather than a single media file.
  final bool isHls;

  /// The rendition to play when [wanted] was asked for: that one when
  /// [offered] has it, else the best one ranked below it in [order], else
  /// the lowest offered. Null for the original file or nothing offered.
  /// [offered] is best first.
  static StreamVariant? pick(List<StreamVariant> offered, String wanted, List<String> order) {
    if (offered.isEmpty) return null;
    for (final variant in offered) {
      if (variant.id == wanted) return variant;
    }
    final wantedRank = order.indexOf(wanted);
    if (wantedRank < 0) return null;
    for (final variant in offered) {
      if (order.indexOf(variant.id) > wantedRank) return variant;
    }
    return offered.last;
  }

  @override
  String toString() => 'StreamVariant($id, ${width ?? '?'}x${height ?? '?'}${isHls ? ', hls' : ''})';
}

/// A driver whose backend can serve transcoded renditions of its files.
abstract interface class StreamVariantSource {
  /// Every rendition name the backend uses, best first.
  List<String> get variantOrder;

  /// The renditions currently playable for [entry], best first. Empty when
  /// the backend offers none (not transcoded yet, or not for this account).
  ///
  /// [forceRefresh] discards cached links, for when the origin refused one.
  Future<List<StreamVariant>> streamVariants(StorageEntry entry, {bool forceRefresh = false});
}
