import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class BrowPainter extends CustomPainter {
  const BrowPainter({required this.landmarks, required this.config});

  final List<Offset> landmarks;
  final MakeupLayerConfig config;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final width = MakeupPainterUtils.faceWidth(landmarks);
    for (final indices in <List<int>>[
      MakeupPainterUtils.leftBrow,
      MakeupPainterUtils.rightBrow,
    ]) {
      final path = MakeupPainterUtils.smoothOpenPath(landmarks, indices);
      canvas.drawPath(
        path,
        Paint()
          ..color = config.color.withValues(alpha: config.intensity * 0.62)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * (0.009 + config.detail * 0.006)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.multiply
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.0025),
      );

      final hairPaint = Paint()
        ..color = config.color.withValues(alpha: config.intensity * 0.4)
        ..strokeWidth = width * 0.0018
        ..strokeCap = StrokeCap.round
        ..blendMode = BlendMode.multiply;
      for (var i = 0; i < indices.length; i++) {
        final p = landmarks[indices[i]];
        final direction = i < 2 ? -0.018 : -0.012;
        canvas.drawLine(
          p,
          Offset(p.dx + width * 0.006, p.dy + width * direction),
          hairPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(BrowPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks || oldDelegate.config != config;
}
