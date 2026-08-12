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
    this.skinChroma = 0.18,
    this.localContrast = 0.16,
  });

  final double exposure;
  final double sideAExposure;
  final double sideBExposure;
  final double warmth;
  final double skinChroma;
  final double localContrast;

  static const neutral = FaceLighting();

  static FaceLighting lerp(FaceLighting a, FaceLighting b, double t) {
    return FaceLighting(
      exposure: _lerp(a.exposure, b.exposure, t),
      sideAExposure: _lerp(a.sideAExposure, b.sideAExposure, t),
      sideBExposure: _lerp(a.sideBExposure, b.sideBExposure, t),
      warmth: _lerp(a.warmth, b.warmth, t),
      skinChroma: _lerp(a.skinChroma, b.skinChroma, t),
      localContrast: _lerp(a.localContrast, b.localContrast, t),
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
    this.sideAEyeOpenness = 1,
    this.sideBEyeOpenness = 1,
    this.mouthOpenness = 0,
  });

  const FaceRenderContext.neutral()
    : lighting = FaceLighting.neutral,
      sideAVisibility = 1,
      sideBVisibility = 1,
      profileOpacity = 1,
      fineDetailVisibility = 1,
      sideAEyeOpenness = 1,
      sideBEyeOpenness = 1,
      mouthOpenness = 0;

  factory FaceRenderContext.fromMesh(
    FaceMeshResult mesh,
    FaceLighting lighting, {
    double runtimeDetailQuality = 1,
  }) {
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
      fineDetailVisibility:
          ((0.42 + _smoothStep(0.11, 0.28, faceSpan) * 0.58) *
                  runtimeDetailQuality.clamp(0.4, 1))
              .clamp(0.24, 1)
              .toDouble(),
      sideAEyeOpenness: _normalizedFeatureOpening(
        points,
        nearA: 159,
        nearB: 145,
        widthA: 33,
        widthB: 133,
        closedRatio: 0.045,
        openRatio: 0.24,
      ),
      sideBEyeOpenness: _normalizedFeatureOpening(
        points,
        nearA: 386,
        nearB: 374,
        widthA: 362,
        widthB: 263,
        closedRatio: 0.045,
        openRatio: 0.24,
      ),
      mouthOpenness: _normalizedFeatureOpening(
        points,
        nearA: 13,
        nearB: 14,
        widthA: 61,
        widthB: 291,
        closedRatio: 0.018,
        openRatio: 0.2,
      ),
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
      // 表情比头部姿态更快跟随；恢复稍慢，避免临界状态闪烁。
      sideAEyeOpenness: _lerp(
        previous.sideAEyeOpenness,
        current.sideAEyeOpenness,
        current.sideAEyeOpenness < previous.sideAEyeOpenness ? 0.76 : 0.54,
      ),
      sideBEyeOpenness: _lerp(
        previous.sideBEyeOpenness,
        current.sideBEyeOpenness,
        current.sideBEyeOpenness < previous.sideBEyeOpenness ? 0.76 : 0.54,
      ),
      mouthOpenness: _lerp(
        previous.mouthOpenness,
        current.mouthOpenness,
        current.mouthOpenness > previous.mouthOpenness ? 0.68 : 0.56,
      ),
    );
  }

  final FaceLighting lighting;

  /// MediaPipe 117/234 所在侧与 346/454 所在侧的透视可见度。
  final double sideAVisibility;
  final double sideBVisibility;
  final double profileOpacity;
  final double fineDetailVisibility;
  final double sideAEyeOpenness;
  final double sideBEyeOpenness;
  final double mouthOpenness;

  double eyeOpennessForSide({required bool sideA}) =>
      sideA ? sideAEyeOpenness : sideBEyeOpenness;

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
    final temperatureAdapted = Color.lerp(
      source,
      target,
      lighting.warmth.abs() * 0.075,
    )!;
    final hsl = HSLColor.fromColor(temperatureAdapted);
    final exposureDelta = (lighting.exposure - 0.52).clamp(-0.42, 0.42);
    final chromaGuard = _smoothStep(0.035, 0.2, lighting.skinChroma);
    final contrastGuard = _smoothStep(0.045, 0.18, lighting.localContrast);
    // 暗光/低色度环境适度收敛饱和度，避免红色和紫色浮在脸上；高光下
    // 略微压低明度，防止浅色底妆与腮红被相机 ISP 推成粉白色块。
    final saturationScale = 0.86 + chromaGuard * 0.11 + contrastGuard * 0.03;
    final protectedLightness =
        hsl.lightness +
        exposureDelta * 0.035 -
        math.max(exposureDelta, 0) * 0.04;
    return hsl
        .withSaturation((hsl.saturation * saturationScale).clamp(0.0, 1.0))
        .withLightness(protectedLightness.clamp(0.06, 0.92))
        .toColor();
  }

  static double _distance(FaceMeshLandmark a, FaceMeshLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _perspectiveVisibility(double ratio) =>
      0.12 + _smoothStep(0.06, 0.92, ratio) * 0.88;

  static double _normalizedFeatureOpening(
    List<FaceMeshLandmark> points, {
    required int nearA,
    required int nearB,
    required int widthA,
    required int widthB,
    required double closedRatio,
    required double openRatio,
  }) {
    final width = math.max(0.0001, _distance(points[widthA], points[widthB]));
    final ratio = _distance(points[nearA], points[nearB]) / width;
    return _smoothStep(closedRatio, openRatio, ratio);
  }

  static double _smoothStep(double edge0, double edge1, double value) {
    final t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
