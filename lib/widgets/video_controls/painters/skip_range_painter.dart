import 'package:flutter/material.dart';
import '../../../media/media_source_info.dart';

/// Separate bands above the track remain visible over played/buffered ranges.
class SkipRangePainter extends CustomPainter {
  const SkipRangePainter({required this.markers, required this.duration});
  final List<MediaMarker> markers;
  final Duration duration;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= Duration.zero) return;
    for (final marker in markers) {
      final x1 = (marker.startTimeOffset / duration.inMilliseconds).clamp(0, 1) * size.width;
      final x2 = (marker.endTimeOffset / duration.inMilliseconds).clamp(0, 1) * size.width;
      final paint = Paint()..color = marker.isCredits ? Colors.amber : Colors.lightBlueAccent;
      final y = size.height / 2 - 10;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x1, y, x2, y + 3), const Radius.circular(2)), paint);
      canvas.drawRect(Rect.fromLTWH(x1, y, 2, 8), paint);
      canvas.drawRect(Rect.fromLTWH(x2 - 2, y, 2, 8), paint);
    }
  }

  @override
  bool shouldRepaint(SkipRangePainter oldDelegate) =>
      oldDelegate.duration != duration || oldDelegate.markers != markers;
}
