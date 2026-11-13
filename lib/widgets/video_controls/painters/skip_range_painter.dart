import 'package:flutter/material.dart';
import '../../../media/media_source_info.dart';

/// Marks the intro end and credits start over the played and buffered track.
class SkipRangePainter extends CustomPainter {
  const SkipRangePainter({required this.markers, required this.duration, required this.trackHeight});

  static const _introColor = Color(0xFF0057FF);
  static const _creditsColor = Color(0xFFFFA500);

  final List<MediaMarker> markers;
  final Duration duration;
  final double trackHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0 || size.isEmpty) return;

    final width = size.width < 3.0 ? size.width : 3.0;
    final height = trackHeight.clamp(0.0, size.height);
    final top = (size.height - height) / 2;
    final paint = Paint();
    for (final marker in markers) {
      final offsetMs = marker.isCredits ? marker.startTimeOffset : marker.endTimeOffset;
      final x = offsetMs / durationMs * size.width;
      final left = (x - width / 2).clamp(0.0, size.width - width);
      paint.color = marker.isCredits ? _creditsColor : _introColor;
      canvas.drawRect(Rect.fromLTWH(left, top, width, height), paint);
    }
  }

  @override
  bool shouldRepaint(SkipRangePainter oldDelegate) =>
      oldDelegate.duration != duration || oldDelegate.markers != markers || oldDelegate.trackHeight != trackHeight;
}
