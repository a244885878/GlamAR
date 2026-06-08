import 'package:flutter/material.dart';

class LipstickPainter extends CustomPainter {
  const LipstickPainter({
    required this.landmarks,
    required this.color,
    required this.mirrorHorizontal,
    this.opacity = 0.65,
  });

  /// 已平滑的归一化关键点坐标列表（x,y 均在 [0,1]）
  final List<Offset> landmarks;
  final Color color;
  final bool mirrorHorizontal;
  final double opacity;

  // MediaPipe Face Mesh 外嘴唇轮廓关键点索引（顺时针，从左嘴角出发）
  static const List<int> _outerLip = [
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
    291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
  ];

  // MediaPipe Face Mesh 内嘴唇轮廓关键点索引（嘴腔开口，张嘴时镂空）
  static const List<int> _innerLip = [
    78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
    308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.length < 468) return;

    Offset toOffset(int idx) {
      final lm = landmarks[idx];
      final dx = mirrorHorizontal ? (1.0 - lm.dx) * size.width : lm.dx * size.width;
      final dy = lm.dy * size.height;
      return Offset(dx, dy);
    }

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

    final outerPath = buildPath(_outerLip);
    final innerPath = buildPath(_innerLip);

    // 外轮廓减去内轮廓（张嘴时镂空嘴腔）
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

    // 边缘柔化描边
    final edgePaint = Paint()
      ..color = color.withValues(alpha: opacity * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..blendMode = BlendMode.multiply;

    canvas.drawPath(lipPath, edgePaint);
  }

  @override
  bool shouldRepaint(LipstickPainter old) =>
      old.landmarks != landmarks ||
      old.color != color ||
      old.mirrorHorizontal != mirrorHorizontal ||
      old.opacity != opacity;
}
