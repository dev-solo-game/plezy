import 'package:flutter/material.dart';
import '../../../media/media_source_info.dart';

/// Marks where each skip starts, above the played and buffered track layers.
class SkipRangePainter extends CustomPainter {
  const SkipRangePainter({required this.markers, required this.duration});
  final List<MediaMarker> markers;
  final Duration duration;

  @override
  void paint(Canvas canvas, Size size) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0 || size.isEmpty) return;

    final width = size.width < 3.0 ? size.width : 3.0;
    const height = 14.0;
    final top = (size.height - height) / 2;
    final paint = Paint();
    for (final marker in markers) {
      final x = marker.startTimeOffset / durationMs * size.width;
      final left = (x - width / 2).clamp(0.0, size.width - width);
      paint.color = marker.isCredits ? Colors.amber : Colors.lightBlueAccent;
      canvas.drawRect(Rect.fromLTWH(left, top, width, height), paint);
    }
  }

  @override
  bool shouldRepaint(SkipRangePainter oldDelegate) =>
      oldDelegate.duration != duration || oldDelegate.markers != markers;
}
