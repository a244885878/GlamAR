import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class FoundationPainter extends CustomPainter {
  const FoundationPainter({required this.landmarks, required this.config});

  final List<Offset> landmarks;
  final MakeupLayerConfig config;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final facePath = MakeupPainterUtils.closedPath(
      landmarks,
      MakeupPainterUtils.faceOval,
    );
    final faceWidth = MakeupPainterUtils.faceWidth(landmarks);
    final center = landmarks[1];

    canvas.save();
    canvas.clipPath(facePath);

    canvas.drawPath(
      facePath,
      Paint()
        ..color = config.color.withValues(alpha: config.intensity * 0.12)
        ..blendMode = BlendMode.softLight,
    );

    final evenToneRect = Rect.fromCenter(
      center: center,
      width: faceWidth * 0.92,
      height: faceWidth * 1.22,
    );
    canvas.drawOval(
      evenToneRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            config.color.withValues(alpha: config.intensity * 0.07),
            config.color.withValues(alpha: config.intensity * 0.02),
            Colors.transparent,
          ],
          stops: const [0, 0.7, 1],
        ).createShader(evenToneRect)
        ..blendMode = BlendMode.softLight,
    );

    final contourColor = Color.lerp(config.color, Colors.black, 0.72)!;
    for (final anchor in <int>[127, 356]) {
      final p = landmarks[anchor];
      final rect = Rect.fromCenter(
        center: Offset(
          p.dx + (center.dx - p.dx) * 0.08,
          p.dy + faceWidth * 0.16,
        ),
        width: faceWidth * 0.24,
        height: faceWidth * 0.62,
      );
      canvas.drawOval(
        rect,
        Paint()
          ..color = contourColor.withValues(
            alpha: config.intensity * config.detail * 0.11,
          )
          ..blendMode = BlendMode.multiply
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, faceWidth * 0.045),
      );
    }

    final highlightPaint = Paint()
      ..color = const Color(
        0xFFFFEEE4,
      ).withValues(alpha: config.intensity * (0.09 + config.detail * 0.05))
      ..blendMode = BlendMode.screen
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, faceWidth * 0.018);
    canvas.drawLine(
      Offset(landmarks[168].dx, landmarks[168].dy + faceWidth * 0.05),
      Offset(landmarks[1].dx, landmarks[1].dy - faceWidth * 0.015),
      highlightPaint..strokeWidth = faceWidth * 0.028,
    );
    canvas.drawCircle(landmarks[1], faceWidth * 0.028, highlightPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(FoundationPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks || oldDelegate.config != config;
}
