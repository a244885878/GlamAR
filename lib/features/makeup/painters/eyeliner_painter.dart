import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class EyelinerPainter extends CustomPainter {
  const EyelinerPainter({required this.landmarks, required this.config});

  final List<Offset> landmarks;
  final MakeupLayerConfig config;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final width = MakeupPainterUtils.faceWidth(landmarks);
    final paint = Paint()
      ..color = config.color.withValues(alpha: config.intensity * 0.9)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width * (0.004 + config.detail * 0.004)
      ..blendMode = BlendMode.multiply;

    for (final entry in <({List<int> indices, bool tailAtStart})>[
      (indices: MakeupPainterUtils.leftEyeUpper, tailAtStart: true),
      (indices: MakeupPainterUtils.rightEyeUpper, tailAtStart: false),
    ]) {
      final path = MakeupPainterUtils.smoothOpenPath(landmarks, entry.indices);
      final outerIndex = entry.tailAtStart
          ? entry.indices.first
          : entry.indices.last;
      final outer = landmarks[outerIndex];
      final sign = outer.dx < landmarks[1].dx ? -1.0 : 1.0;
      final tailLength = width * (0.02 + config.detail * 0.055);
      path.moveTo(outer.dx, outer.dy);
      path.quadraticBezierTo(
        outer.dx + sign * tailLength * 0.55,
        outer.dy - tailLength * 0.08,
        outer.dx + sign * tailLength,
        outer.dy - tailLength * (0.16 + config.detail * 0.22),
      );
      canvas.drawPath(path, paint);

      if (config.detail > 0.46) {
        final lashPaint = Paint()
          ..color = config.color.withValues(alpha: config.intensity * 0.55)
          ..strokeWidth = width * 0.002
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.multiply;
        for (var i = 2; i < entry.indices.length - 1; i += 2) {
          final p = landmarks[entry.indices[i]];
          final away = (p.dx - landmarks[1].dx).sign;
          canvas.drawLine(
            p,
            Offset(
              p.dx + away * width * 0.005,
              p.dy - width * (0.012 + config.detail * 0.012),
            ),
            lashPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(EyelinerPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks || oldDelegate.config != config;
}
