import 'package:flutter/material.dart';
import 'package:glamar/features/face_mesh/utils/lip_landmark_indices.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';

class LipstickPainter extends CustomPainter {
  const LipstickPainter({
    required this.landmarkPixels,
    required this.config,
    required this.finish,
  });

  /// 已映射到画布像素坐标的关键点（与预览 Stack 同尺寸）。
  final List<Offset> landmarkPixels;
  final MakeupLayerConfig config;
  final LipFinish finish;

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || landmarkPixels.length < 468) return;

    Offset toOffset(int idx) => landmarkPixels[idx];

    Path buildPath(List<int> indices) {
      final path = Path();
      final first = toOffset(indices[0]);
      path.moveTo(first.dx, first.dy);
      for (int i = 1; i < indices.length; i++) {
        final pt = toOffset(indices[i]);
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      return path;
    }

    final outerPath = buildPath(LipLandmarkIndices.outerLip);
    final innerPath = buildPath(LipLandmarkIndices.innerLip);

    final lipPath = Path.combine(
      PathOperation.difference,
      outerPath,
      innerPath,
    );

    final fillPaint = Paint()
      ..color = config.color.withValues(alpha: config.intensity * 0.72)
      ..style = PaintingStyle.fill
      ..blendMode = BlendMode.multiply;

    canvas.drawPath(lipPath, fillPaint);

    final edgePaint = Paint()
      ..color = config.color.withValues(alpha: config.intensity * 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..blendMode = BlendMode.multiply;

    canvas.drawPath(lipPath, edgePaint);

    if (finish != LipFinish.velvet) {
      final bounds = lipPath.getBounds();
      canvas.save();
      canvas.clipPath(lipPath);
      final glossRect = Rect.fromLTWH(
        bounds.left + bounds.width * 0.18,
        bounds.top + bounds.height * 0.47,
        bounds.width * 0.64,
        bounds.height * 0.25,
      );
      canvas.drawOval(
        glossRect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(
                alpha:
                    config.intensity *
                    (finish == LipFinish.glass ? 0.34 : 0.16),
              ),
              Colors.transparent,
            ],
          ).createShader(glossRect)
          ..blendMode = BlendMode.screen
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(LipstickPainter old) =>
      old.landmarkPixels != landmarkPixels ||
      old.config != config ||
      old.finish != finish;
}
