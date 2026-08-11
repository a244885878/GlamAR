import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

class EyeshadowPainter extends CustomPainter {
  const EyeshadowPainter({
    required this.landmarks,
    required this.config,
    this.renderContext = const FaceRenderContext.neutral(),
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig config;
  final FaceRenderContext renderContext;

  Path _lidPath(List<int> indices, double lift) {
    final eyePoints = indices.map((i) => landmarks[i]).toList(growable: false);
    final axis = eyePoints.last - eyePoints.first;
    var normal = Offset(-axis.dy, axis.dx) / math.max(axis.distance, 0.001);
    if (normal.dy > 0) normal = -normal;
    final lifted = eyePoints.reversed
        .map((point) => point + normal * lift)
        .toList(growable: false);
    return MakeupPainterUtils.smoothClosedOffsets([...eyePoints, ...lifted]);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled || !MakeupPainterUtils.valid(landmarks)) return;
    final width = MakeupPainterUtils.faceWidth(landmarks);
    final roll = MakeupPainterUtils.angle(landmarks[234], landmarks[454]);
    final color = renderContext.adaptColor(config.color);
    final secondaryColor = renderContext.adaptColor(
      config.secondaryColor ?? config.color,
    );
    for (final eye in <({List<int> indices, bool sideA})>[
      (indices: MakeupPainterUtils.leftEyeUpper, sideA: true),
      (indices: MakeupPainterUtils.rightEyeUpper, sideA: false),
    ]) {
      final indices = eye.indices;
      final opacity = renderContext.opacityForSide(sideA: eye.sideA);
      final detailOpacity = renderContext.detailOpacityForSide(
        sideA: eye.sideA,
      );
      final eyeOpenness = renderContext.eyeOpennessForSide(sideA: eye.sideA);
      final eyeWidth =
          (landmarks[indices.last] - landmarks[indices.first]).distance;
      // 闭眼时上眼睑关键点会向下移动；同步收敛上扬距离，让眼影面积
      // 平滑变化，避免眨眼瞬间向眉毛方向“呼吸”。
      final blinkStability = 0.62 + eyeOpenness * 0.38;
      final lift = eyeWidth * (0.2 + config.detail * 0.14) * blinkStability;
      final path = _lidPath(indices, lift);
      final bounds = path.getBounds();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Color.lerp(
                color,
                Colors.black,
                0.16,
              )!.withValues(alpha: config.intensity * opacity * 0.34),
              color.withValues(alpha: config.intensity * opacity * 0.24),
              secondaryColor.withValues(
                alpha: config.intensity * opacity * 0.1,
              ),
              Colors.transparent,
            ],
            stops: const [0, 0.28, 0.7, 1],
          ).createShader(bounds)
          ..blendMode = BlendMode.softLight
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            MakeupPainterUtils.scaledSize(
              eyeWidth,
              0.028,
              maximum: width * 0.01,
            ),
          ),
      );

      final lashLine = MakeupPainterUtils.smoothOpenPath(landmarks, indices);
      canvas.drawPath(
        lashLine,
        Paint()
          ..color = Color.lerp(
            color,
            Colors.black,
            0.38,
          )!.withValues(alpha: config.intensity * detailOpacity * 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = MakeupPainterUtils.scaledSize(
            eyeWidth,
            0.026,
            minimum: 0.5,
            maximum: width * 0.009,
          )
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.multiply
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            MakeupPainterUtils.scaledSize(
              eyeWidth,
              0.014,
              minimum: 0.3,
              maximum: width * 0.005,
            ),
          ),
      );

      if (config.detail > 0.62 && renderContext.fineDetailVisibility > 0.5) {
        final shimmerCenter = Offset(
          bounds.center.dx,
          bounds.top + bounds.height * 0.52,
        );
        final shimmerRect = Rect.fromCenter(
          center: shimmerCenter,
          width: bounds.width * 0.38,
          height: bounds.height * 0.24,
        );
        canvas.save();
        canvas.clipPath(path);
        canvas.translate(shimmerCenter.dx, shimmerCenter.dy);
        canvas.rotate(roll);
        canvas.translate(-shimmerCenter.dx, -shimmerCenter.dy);
        canvas.drawOval(
          shimmerRect,
          Paint()
            ..shader = RadialGradient(
              colors: [
                renderContext
                    .adaptColor(const Color(0xFFFFE4D1))
                    .withValues(
                      alpha:
                          config.intensity *
                          detailOpacity *
                          renderContext.highlightOpacity *
                          (0.68 + eyeOpenness * 0.32) *
                          0.22,
                    ),
                Colors.transparent,
              ],
            ).createShader(shimmerRect)
            ..blendMode = BlendMode.screen
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              MakeupPainterUtils.scaledSize(
                eyeWidth,
                0.018,
                minimum: 0.35,
                maximum: width * 0.007,
              ),
            ),
        );
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(EyeshadowPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks ||
      oldDelegate.config != config ||
      oldDelegate.renderContext != renderContext;
}
