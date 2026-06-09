import 'package:flutter/material.dart';
import 'package:glamar/features/face_mesh/utils/lip_landmark_indices.dart';

class LipstickPainter extends CustomPainter {
  const LipstickPainter({
    required this.landmarkPixels,
    required this.color,
    this.opacity = 0.65,
  });

  /// 已映射到画布像素坐标的关键点（与预览 Stack 同尺寸）。
  final List<Offset> landmarkPixels;
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarkPixels.length < 468) return;

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
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.fill
      ..blendMode = BlendMode.multiply;

    canvas.drawPath(lipPath, fillPaint);

    final edgePaint = Paint()
      ..color = color.withValues(alpha: opacity * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..blendMode = BlendMode.multiply;

    canvas.drawPath(lipPath, edgePaint);
  }

  @override
  bool shouldRepaint(LipstickPainter old) =>
      old.landmarkPixels != landmarkPixels ||
      old.color != color ||
      old.opacity != opacity;
}
