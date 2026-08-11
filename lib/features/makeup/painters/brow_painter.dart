import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class BrowPainter extends CustomPainter {
  const BrowPainter({
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
    final color = renderContext.adaptColor(config.color);
    for (final brow in <({List<int> indices, bool sideA})>[
      (indices: MakeupPainterUtils.leftBrow, sideA: true),
      (indices: MakeupPainterUtils.rightBrow, sideA: false),
    ]) {
      final indices = brow.indices;
      final opacity = renderContext.opacityForSide(sideA: brow.sideA);
      final path = MakeupPainterUtils.smoothOpenPath(landmarks, indices);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: config.intensity * opacity * 0.62)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * (0.009 + config.detail * 0.006)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.multiply
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.0025),
      );

      final hairPaint = Paint()
        ..color = color.withValues(alpha: config.intensity * opacity * 0.4)
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
      oldDelegate.landmarks != landmarks ||
      oldDelegate.config != config ||
      oldDelegate.renderContext != renderContext;
}
