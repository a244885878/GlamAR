import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class BlushPainter extends CustomPainter {
  const BlushPainter({required this.landmarks, required this.config});

  final List<Offset> landmarks;
  final MakeupLayerConfig config;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final width = MakeupPainterUtils.faceWidth(landmarks);
    final angle = MakeupPainterUtils.angle(landmarks[234], landmarks[454]);
    final faceCenter = landmarks[1];
    canvas.save();
    canvas.clipPath(
      MakeupPainterUtils.closedPath(landmarks, MakeupPainterUtils.faceOval),
    );
    for (final anchor in <int>[117, 346]) {
      final raw = landmarks[anchor];
      final highTarget = anchor == 117 ? landmarks[50] : landmarks[280];
      final highMix = 0.12 + config.detail * 0.2;
      final center = Offset.lerp(raw, highTarget, highMix)!;
      final pulled = Offset.lerp(center, faceCenter, 0.05)!;
      canvas.save();
      canvas.translate(pulled.dx, pulled.dy);
      canvas.rotate(angle);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: width * (0.27 + config.detail * 0.07),
        height: width * (0.17 + (1 - config.detail) * 0.05),
      );
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              config.color.withValues(alpha: config.intensity * 0.38),
              config.color.withValues(alpha: config.intensity * 0.15),
              Colors.transparent,
            ],
            stops: const [0, 0.52, 1],
          ).createShader(rect)
          ..blendMode = BlendMode.softLight
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.018),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BlushPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks || oldDelegate.config != config;
}
