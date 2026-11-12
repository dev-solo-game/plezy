import 'media_source_info.dart';

/// Manual time ranges belonging to one movie or series, independent of files.
class WorkSkipSettings {
  const WorkSkipSettings({
    this.introEnabled = false,
    this.introStartMs = 0,
    this.introEndMs = 0,
    this.creditsEnabled = false,
    this.creditsDurationMs = 0,
    this.creditsResumeBeforeEndMs = 0,
  });

  final bool introEnabled;
  final int introStartMs;
  final int introEndMs;
  final bool creditsEnabled;
  final int creditsDurationMs;

  /// Zero completes playback; a positive value preserves the post-credit scene.
  final int creditsResumeBeforeEndMs;

  factory WorkSkipSettings.fromJson(Map<String, dynamic> json) => WorkSkipSettings(
    introEnabled: json['introEnabled'] == true,
    introStartMs: (json['introStartMs'] as num?)?.toInt() ?? 0,
    introEndMs: (json['introEndMs'] as num?)?.toInt() ?? 0,
    creditsEnabled: json['creditsEnabled'] == true,
    creditsDurationMs: (json['creditsDurationMs'] as num?)?.toInt() ?? 0,
    creditsResumeBeforeEndMs: (json['creditsResumeBeforeEndMs'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'introEnabled': introEnabled,
    'introStartMs': introStartMs,
    'introEndMs': introEndMs,
    'creditsEnabled': creditsEnabled,
    'creditsDurationMs': creditsDurationMs,
    'creditsResumeBeforeEndMs': creditsResumeBeforeEndMs,
  };

  bool validFor([int? durationMs]) {
    if (introEnabled && (introStartMs < 0 || introEndMs <= introStartMs)) return false;
    if (creditsEnabled &&
        (creditsDurationMs <= 0 || creditsResumeBeforeEndMs < 0 || creditsResumeBeforeEndMs >= creditsDurationMs)) {
      return false;
    }
    if (durationMs == null || durationMs <= 0) return true;
    if (introEnabled && introEndMs >= durationMs) return false;
    if (creditsEnabled && creditsDurationMs >= durationMs) return false;
    if (introEnabled && creditsEnabled && introEndMs > durationMs - creditsDurationMs) return false;
    return true;
  }

  /// Rechecked for every file's actual duration. Invalid rules never seek.
  List<MediaMarker> markersFor(Duration duration) {
    final ms = duration.inMilliseconds;
    if (ms <= 0 || !validFor(ms)) return const [];
    return [
      if (introEnabled) MediaMarker(id: -1, type: 'intro', startTimeOffset: introStartMs, endTimeOffset: introEndMs),
      if (creditsEnabled)
        MediaMarker(
          id: -2,
          type: 'credits',
          startTimeOffset: ms - creditsDurationMs,
          endTimeOffset: ms - creditsResumeBeforeEndMs,
        ),
    ];
  }

  WorkSkipSettings prefill(Duration clicked, Duration duration) {
    final ms = clicked.inMilliseconds.clamp(0, duration.inMilliseconds);
    final intro = ms < duration.inMilliseconds / 2;
    return WorkSkipSettings(
      introEnabled: intro || introEnabled,
      introStartMs: intro && introStartMs >= ms ? 0 : introStartMs,
      introEndMs: intro ? ms : introEndMs,
      creditsEnabled: !intro || creditsEnabled,
      creditsDurationMs: intro ? creditsDurationMs : duration.inMilliseconds - ms,
      creditsResumeBeforeEndMs: creditsResumeBeforeEndMs,
    );
  }
}
