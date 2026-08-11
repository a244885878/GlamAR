import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

@immutable
class FaceLighting {
  const FaceLighting({
    this.exposure = 0.52,
    this.sideAExposure = 0.52,
    this.sideBExposure = 0.52,
    this.warmth = 0,
  });

  final double exposure;
  final double sideAExposure;
  final double sideBExposure;
  final double warmth;

  static const neutral = FaceLighting();

  static FaceLighting lerp(FaceLighting a, FaceLighting b, double t) {
    return FaceLighting(
      exposure: _lerp(a.exposure, b.exposure, t),
      sideAExposure: _lerp(a.sideAExposure, b.sideAExposure, t),
      sideBExposure: _lerp(a.sideBExposure, b.sideBExposure, t),
      warmth: _lerp(a.warmth, b.warmth, t),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

@immutable
class FaceRenderContext {
  const FaceRenderContext({
    this.lighting = FaceLighting.neutral,
    this.sideAVisibility = 1,
    this.sideBVisibility = 1,
    this.profileOpacity = 1,
    this.fineDetailVisibility = 1,
  });

  const FaceRenderContext.neutral()
    : lighting = FaceLighting.neutral,
      sideAVisibility = 1,
      sideBVisibility = 1,
      profileOpacity = 1,
      fineDetailVisibility = 1;

  factory FaceRenderContext.fromMesh(
    FaceMeshResult mesh,
    FaceLighting lighting,
  ) {
    if (mesh.landmarks.length < 468) {
      return FaceRenderContext(lighting: lighting);
    }
    final points = mesh.landmarks;
    final sideASpan = _distance(points[117], points[234]);
    final sideBSpan = _distance(points[346], points[454]);
    final widestSide = math.max(0.0001, math.max(sideASpan, sideBSpan));
    final sideAVisibility = _perspectiveVisibility(sideASpan / widestSide);
    final sideBVisibility = _perspectiveVisibility(sideBSpan / widestSide);
    final profileVisibility = math.min(sideAVisibility, sideBVisibility);
    final faceSpan = _distance(points[234], points[454]);
    return FaceRenderContext(
      lighting: lighting,
      sideAVisibility: sideAVisibility,
      sideBVisibility: sideBVisibility,
      // 极端侧脸时中心区域仍保留妆效，但降低材质强度，避免唇妆和底妆
      // 在轮廓边缘形成一块过于平整的色片。
      profileOpacity: 0.76 + math.sqrt(profileVisibility) * 0.24,
      // 小脸在预览中的有效像素更少，保留主体色彩并收敛睫毛、珠光等
      // 高频细节，减少远距离锯齿和闪烁。
      fineDetailVisibility: 0.42 + _smoothStep(0.11, 0.28, faceSpan) * 0.58,
    );
  }

  /// 光照本身已单独平滑，这里只稳定随姿态变化的几何权重。
  static FaceRenderContext stabilizeGeometry(
    FaceRenderContext previous,
    FaceRenderContext current,
    double t,
  ) {
    return FaceRenderContext(
      lighting: current.lighting,
      sideAVisibility: _lerp(
        previous.sideAVisibility,
        current.sideAVisibility,
        t,
      ),
      sideBVisibility: _lerp(
        previous.sideBVisibility,
        current.sideBVisibility,
        t,
      ),
      profileOpacity: _lerp(previous.profileOpacity, current.profileOpacity, t),
      fineDetailVisibility: _lerp(
        previous.fineDetailVisibility,
        current.fineDetailVisibility,
        t,
      ),
    );
  }

  final FaceLighting lighting;

  /// MediaPipe 117/234 所在侧与 346/454 所在侧的透视可见度。
  final double sideAVisibility;
  final double sideBVisibility;
  final double profileOpacity;
  final double fineDetailVisibility;

  double opacityForSide({required bool sideA}) {
    final sideExposure = sideA
        ? lighting.sideAExposure
        : lighting.sideBExposure;
    final lightResponse = (0.76 + sideExposure * 0.46).clamp(0.72, 1.12);
    final visibility = sideA ? sideAVisibility : sideBVisibility;
    return (lightResponse * visibility).clamp(0.1, 1.12);
  }

  double detailOpacityForSide({required bool sideA}) =>
      (opacityForSide(sideA: sideA) * fineDetailVisibility).clamp(0.06, 1.12);

  double get centralOpacity =>
      ((0.78 + lighting.exposure * 0.42) * profileOpacity).clamp(0.64, 1.1);

  double get highlightOpacity =>
      ((0.58 + lighting.exposure * 0.7) * profileOpacity * fineDetailVisibility)
          .clamp(0.34, 1.16);

  Color adaptColor(Color source) {
    final target = lighting.warmth >= 0
        ? const Color(0xFFFFB28F)
        : const Color(0xFF9FBCE8);
    return Color.lerp(source, target, lighting.warmth.abs() * 0.075)!;
  }

  static double _distance(FaceMeshLandmark a, FaceMeshLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _perspectiveVisibility(double ratio) =>
      0.12 + _smoothStep(0.06, 0.92, ratio) * 0.88;

  static double _smoothStep(double edge0, double edge1, double value) {
    final t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
