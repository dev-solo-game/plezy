/// A rendition the source serves next to the file itself, as the player's
/// quality picker lists it. Unlike a `TranscodeQualityPreset`, which asks a
/// server to transcode to a ceiling, these are fixed renditions the backend
/// already made, and which ones exist differs from file to file.
class StreamQuality {
  const StreamQuality({required this.id, this.width, this.height});

  /// Plays the file itself.
  static const String original = 'original';

  /// The backend's name for the rendition, the same on every file, so a pick
  /// carries over to the next episode.
  final String id;
  final int? width;
  final int? height;

  @override
  bool operator ==(Object other) =>
      other is StreamQuality && other.id == id && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(id, width, height);
}
