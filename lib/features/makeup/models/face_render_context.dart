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
  });

  const FaceRenderContext.neutral()
    : lighting = FaceLighting.neutral,
      sideAVisibility = 1,
      sideBVisibility = 1;

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
    final average = math.max(0.0001, (sideASpan + sideBSpan) * 0.5);
    return FaceRenderContext(
      lighting: lighting,
      sideAVisibility: (sideASpan / average).clamp(0.52, 1.08),
      sideBVisibility: (sideBSpan / average).clamp(0.52, 1.08),
    );
  }

  final FaceLighting lighting;

  /// MediaPipe 117/234 所在侧与 346/454 所在侧的透视可见度。
  final double sideAVisibility;
  final double sideBVisibility;

  double opacityForSide({required bool sideA}) {
    final sideExposure = sideA
        ? lighting.sideAExposure
        : lighting.sideBExposure;
    final lightResponse = (0.76 + sideExposure * 0.46).clamp(0.72, 1.12);
    final visibility = sideA ? sideAVisibility : sideBVisibility;
    return (lightResponse * visibility).clamp(0.46, 1.12);
  }

  double get centralOpacity =>
      (0.78 + lighting.exposure * 0.42).clamp(0.7, 1.1);

  double get highlightOpacity =>
      (0.58 + lighting.exposure * 0.7).clamp(0.52, 1.16);

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
}
