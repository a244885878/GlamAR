import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class EyelinerPainter extends CustomPainter {
  const EyelinerPainter({
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

    for (final entry in <({List<int> indices, bool tailAtStart, bool sideA})>[
      (
        indices: MakeupPainterUtils.leftEyeUpper,
        tailAtStart: true,
        sideA: true,
      ),
      (
        indices: MakeupPainterUtils.rightEyeUpper,
        tailAtStart: false,
        sideA: false,
      ),
    ]) {
      final opacity = renderContext.detailOpacityForSide(sideA: entry.sideA);
      final eyeOpenness = renderContext.eyeOpennessForSide(sideA: entry.sideA);
      final localEyeWidth =
          (landmarks[entry.indices.last] - landmarks[entry.indices.first])
              .distance;
      final paint = Paint()
        ..color = color.withValues(alpha: config.intensity * opacity * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = MakeupPainterUtils.scaledSize(
          localEyeWidth,
          0.02 + config.detail * 0.02,
          minimum: 0.52,
          maximum: width * 0.012,
        )
        ..blendMode = BlendMode.multiply;
      final path = MakeupPainterUtils.smoothOpenPath(landmarks, entry.indices);
      final outerIndex = entry.tailAtStart
          ? entry.indices.first
          : entry.indices.last;
      final outer = landmarks[outerIndex];
      final sign = outer.dx < landmarks[1].dx ? -1.0 : 1.0;
      final tailLength = localEyeWidth * (0.1 + config.detail * 0.24);
      path.moveTo(outer.dx, outer.dy);
      path.quadraticBezierTo(
        outer.dx + sign * tailLength * 0.55,
        outer.dy - tailLength * 0.08,
        outer.dx + sign * tailLength,
        outer.dy - tailLength * (0.16 + config.detail * 0.22),
      );
      canvas.drawPath(path, paint);

      if (config.detail > 0.46 && renderContext.fineDetailVisibility > 0.5) {
        final lashPaint = Paint()
          ..color = color.withValues(
            alpha:
                config.intensity * opacity * (0.38 + eyeOpenness * 0.62) * 0.55,
          )
          ..strokeWidth = MakeupPainterUtils.scaledSize(
            localEyeWidth,
            0.009,
            minimum: 0.34,
            maximum: width * 0.004,
          )
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.multiply;
        for (var i = 2; i < entry.indices.length - 1; i += 2) {
          final p = landmarks[entry.indices[i]];
          final away = (p.dx - landmarks[1].dx).sign;
          canvas.drawLine(
            p,
            Offset(
              p.dx + away * localEyeWidth * 0.025,
              p.dy - localEyeWidth * (0.06 + config.detail * 0.06),
            ),
            lashPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(EyelinerPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks ||
      oldDelegate.config != config ||
      oldDelegate.renderContext != renderContext;
}
