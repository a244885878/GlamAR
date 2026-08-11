import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class LipstickPainter extends CustomPainter {
  const LipstickPainter({
    required this.landmarkPixels,
    required this.config,
    required this.finish,
    this.renderContext = const FaceRenderContext.neutral(),
  });

  final List<Offset> landmarkPixels;
  final MakeupLayerConfig config;
  final LipFinish finish;
  final FaceRenderContext renderContext;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarkPixels)) return;

    final lipPath = MakeupPainterUtils.lipPath(landmarkPixels);
    final bounds = lipPath.getBounds();
    final faceWidth = MakeupPainterUtils.faceWidth(landmarkPixels);
    final color = renderContext.adaptColor(config.color);
    final opacity = renderContext.centralOpacity;
    final upperColor = Color.lerp(color, Colors.black, 0.13)!;
    final lowerColor = Color.lerp(color, Colors.white, 0.055)!;

    // 极轻的羽化底层只处理边界，不掩盖原有唇纹。
    canvas.drawPath(
      lipPath,
      Paint()
        ..color = color.withValues(alpha: config.intensity * opacity * 0.16)
        ..blendMode = BlendMode.softLight
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, faceWidth * 0.0035),
    );

    canvas.drawPath(
      lipPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            upperColor.withValues(alpha: config.intensity * opacity * 0.46),
            color.withValues(alpha: config.intensity * opacity * 0.36),
            lowerColor.withValues(alpha: config.intensity * opacity * 0.3),
          ],
          stops: const [0, 0.46, 1],
        ).createShader(bounds)
        ..blendMode = BlendMode.multiply,
    );

    canvas.drawPath(
      lipPath,
      Paint()
        ..color = color.withValues(alpha: config.intensity * opacity * 0.1)
        ..blendMode = BlendMode.color,
    );

    canvas.drawPath(
      lipPath,
      Paint()
        ..color = upperColor.withValues(
          alpha: config.intensity * opacity * 0.15,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = faceWidth * 0.0022
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply,
    );

    if (finish != LipFinish.velvet) {
      canvas.save();
      canvas.clipPath(lipPath);
      final glossRect = Rect.fromLTWH(
        bounds.left + bounds.width * 0.2,
        bounds.top + bounds.height * 0.56,
        bounds.width * 0.6,
        bounds.height * 0.16,
      );
      canvas.drawOval(
        glossRect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(
                alpha:
                    config.intensity *
                    opacity *
                    (finish == LipFinish.glass ? 0.2 : 0.075),
              ),
              Colors.transparent,
            ],
          ).createShader(glossRect)
          ..blendMode = BlendMode.screen
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, faceWidth * 0.003),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(LipstickPainter old) =>
      old.landmarkPixels != landmarkPixels ||
      old.config != config ||
      old.finish != finish ||
      old.renderContext != renderContext;
}
