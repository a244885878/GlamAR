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
      final detailOpacity = renderContext.detailOpacityForSide(
        sideA: brow.sideA,
      );
      final browSpan =
          (landmarks[indices.last] - landmarks[indices.first]).distance;
      final path = MakeupPainterUtils.smoothOpenPath(landmarks, indices);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: config.intensity * opacity * 0.62)
          ..style = PaintingStyle.stroke
          ..strokeWidth = MakeupPainterUtils.scaledSize(
            browSpan,
            0.05 + config.detail * 0.035,
            minimum: 0.65,
            maximum: width * 0.02,
          )
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.multiply
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            MakeupPainterUtils.scaledSize(
              browSpan,
              0.014,
              minimum: 0.28,
              maximum: width * 0.005,
            ),
          ),
      );

      final hairPaint = Paint()
        ..color = color.withValues(
          alpha: config.intensity * detailOpacity * 0.4,
        )
        ..strokeWidth = MakeupPainterUtils.scaledSize(
          browSpan,
          0.01,
          minimum: 0.32,
          maximum: width * 0.004,
        )
        ..strokeCap = StrokeCap.round
        ..blendMode = BlendMode.multiply;
      for (var i = 0; i < indices.length; i++) {
        final p = landmarks[indices[i]];
        final verticalFactor = i < 2 ? -0.1 : -0.067;
        canvas.drawLine(
          p,
          Offset(p.dx + browSpan * 0.033, p.dy + browSpan * verticalFactor),
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
