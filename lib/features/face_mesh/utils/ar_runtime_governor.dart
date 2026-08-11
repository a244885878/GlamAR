import 'dart:math' as math;

/// 将跟踪连续性和遮挡调度的阈值集中在一处，便于真机标定。
abstract final class ArRuntimeGovernor {
  static const trackingHold = Duration(milliseconds: 110);
  static const trackingFade = Duration(milliseconds: 140);

  static Duration get maximumTrackingGap => trackingHold + trackingFade;

  /// 单帧 FaceMesh 失效时不立刻撤掉妆容。先保持，再快速渐隐，既能跨过
  /// 手遮脸的短暂丢帧，也不会在人脸离开后长时间留下浮空妆容。
  static double trackingOpacity(Duration age) {
    if (age.isNegative || age <= trackingHold) return 1;
    if (age >= maximumTrackingGap) return 0;
    final fadeMicros = age.inMicroseconds - trackingHold.inMicroseconds;
    final progress = fadeMicros / trackingFade.inMicroseconds;
    // smoothstep 比线性渐隐更不容易看到亮度跳变。
    final smooth = progress * progress * (3 - 2 * progress);
    return 1 - smooth;
  }

  /// 遮挡模型比 FaceMesh 重，根据实际 AR FPS 和两条推理耗时动态让出
  /// CPU。跟踪健康时优先降低遮挡延迟，掉帧时则优先保住跟脸。
  static Duration occlusionCooldown({
    required double faceFps,
    required double faceInferenceMs,
    required double occlusionInferenceMs,
  }) {
    var milliseconds = switch (faceFps) {
      >= 27 => 45.0,
      >= 22 => 80.0,
      >= 18 => 140.0,
      >= 14 => 240.0,
      > 0 => 420.0,
      _ => 120.0,
    };
    if (faceInferenceMs > 42) milliseconds += 70;
    if (occlusionInferenceMs > 260) {
      milliseconds += math.min(180, (occlusionInferenceMs - 260) * 0.6);
    }
    return Duration(milliseconds: milliseconds.round());
  }

  /// 根据真实跟踪吞吐调整非核心渲染细节。启动期没有 FPS 样本时保持完整
  /// 质量；压力增大时优先让出 GPU/CPU 给 FaceMesh，而不撤掉主体妆容。
  static double renderDetailQuality({
    required double faceFps,
    required double faceInferenceMs,
  }) {
    if (faceFps <= 0) return 1;
    var quality = switch (faceFps) {
      >= 26 => 1.0,
      >= 22 => 0.86,
      >= 18 => 0.72,
      >= 14 => 0.58,
      _ => 0.44,
    };
    if (faceInferenceMs > 46) quality -= 0.08;
    return quality.clamp(0.4, 1).toDouble();
  }
}
