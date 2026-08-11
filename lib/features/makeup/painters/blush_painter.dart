import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class BlushPainter extends CustomPainter {
  const BlushPainter({
    required this.landmarks,
    required this.config,
    this.renderContext = const FaceRenderContext.neutral(),
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig config;
  final FaceRenderContext renderContext;

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
    final color = renderContext.adaptColor(config.color);
    for (final cheek in <({int anchor, int edge, int high, bool sideA})>[
      (anchor: 117, edge: 234, high: 50, sideA: true),
      (anchor: 346, edge: 454, high: 280, sideA: false),
    ]) {
      final raw = landmarks[cheek.anchor];
      final highTarget = landmarks[cheek.high];
      final highMix = 0.12 + config.detail * 0.2;
      final center = Offset.lerp(raw, highTarget, highMix)!;
      final pulled = Offset.lerp(center, faceCenter, 0.05)!;
      final localCheekSpan = (raw - landmarks[cheek.edge]).distance;
      final perspective = (localCheekSpan / (width * 0.2)).clamp(0.58, 1.08);
      final opacity = renderContext.opacityForSide(sideA: cheek.sideA);
      canvas.save();
      canvas.translate(pulled.dx, pulled.dy);
      canvas.rotate(angle);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: localCheekSpan * (1.35 + config.detail * 0.34),
        height: width * (0.17 + (1 - config.detail) * 0.05),
      );
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(
                alpha: config.intensity * perspective * opacity * 0.31,
              ),
              color.withValues(
                alpha: config.intensity * perspective * opacity * 0.12,
              ),
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
      oldDelegate.landmarks != landmarks ||
      oldDelegate.config != config ||
      oldDelegate.renderContext != renderContext;
}
