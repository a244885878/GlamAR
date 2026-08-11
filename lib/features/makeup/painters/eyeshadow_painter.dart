import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class EyeshadowPainter extends CustomPainter {
  const EyeshadowPainter({required this.landmarks, required this.config});

  final List<Offset> landmarks;
  final MakeupLayerConfig config;

  Path _lidPath(List<int> indices, double lift) {
    final eyePoints = indices.map((i) => landmarks[i]).toList(growable: false);
    final path = Path()..moveTo(eyePoints.first.dx, eyePoints.first.dy);
    for (final p in eyePoints.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (final p in eyePoints.reversed) {
      path.lineTo(p.dx, p.dy - lift);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final width = MakeupPainterUtils.faceWidth(landmarks);
    final lift = width * (0.045 + config.detail * 0.035);
    for (final indices in <List<int>>[
      MakeupPainterUtils.leftEyeUpper,
      MakeupPainterUtils.rightEyeUpper,
    ]) {
      final path = _lidPath(indices, lift);
      final bounds = path.getBounds();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              config.color.withValues(alpha: config.intensity * 0.46),
              (config.secondaryColor ?? config.color).withValues(
                alpha: config.intensity * 0.22,
              ),
              Colors.transparent,
            ],
          ).createShader(bounds)
          ..blendMode = BlendMode.softLight
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.008),
      );

      if (config.detail > 0.62) {
        final shimmer = Paint()
          ..color = const Color(
            0xFFFFE4D1,
          ).withValues(alpha: config.intensity * 0.48)
          ..blendMode = BlendMode.screen
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.003);
        for (var i = 2; i < indices.length - 2; i += 2) {
          final p = landmarks[indices[i]];
          canvas.drawCircle(
            Offset(p.dx, p.dy - lift * 0.38),
            width * 0.0045,
            shimmer,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(EyeshadowPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks || oldDelegate.config != config;
}
