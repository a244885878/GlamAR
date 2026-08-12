import 'dart:math' as math;

import 'package:glamar/features/makeup/models/makeup_look.dart';

/// 将 UI 的线性 0–1 控制值映射为感知更均匀的材质参数。
///
/// 透明度、soft-light 与 multiply 的视觉响应并不线性：低段不易察觉，
/// 高段又会快速变厚。这里在低中段提供适量增益，并压低接近满量程时的
/// 斜率；端点保持不变，关闭与最大值仍具有明确语义。
abstract final class MakeupResponseCurve {
  static double intensity(MakeupPart part, double value) {
    final x = value.clamp(0.0, 1.0).toDouble();
    final lift = switch (part) {
      MakeupPart.complexion => 0.3,
      MakeupPart.blush => 0.26,
      MakeupPart.eyeshadow => 0.22,
      MakeupPart.brows => 0.16,
      MakeupPart.eyeliner => 0.12,
      MakeupPart.lips => 0.18,
    };
    return (x + lift * x * (1 - x)).clamp(0.0, 1.0).toDouble();
  }

  /// 细节控制采用 smootherstep，减少滑杆两端的几何/珠光突变。
  static double detail(double value) {
    final x = value.clamp(0.0, 1.0).toDouble();
    return x * x * x * (x * (x * 6 - 15) + 10);
  }

  static MakeupLayerConfig layer(MakeupPart part, MakeupLayerConfig source) =>
      source.copyWith(
        intensity: intensity(part, source.intensity),
        detail: detail(source.detail),
      );

  static MakeupLook look(MakeupLook source) => MakeupLook(
    id: source.id,
    name: source.name,
    subtitle: source.subtitle,
    category: source.category,
    imageAsset: source.imageAsset,
    tags: source.tags,
    complexion: layer(MakeupPart.complexion, source.complexion),
    blush: layer(MakeupPart.blush, source.blush),
    eyeshadow: layer(MakeupPart.eyeshadow, source.eyeshadow),
    brows: layer(MakeupPart.brows, source.brows),
    eyeliner: layer(MakeupPart.eyeliner, source.eyeliner),
    lips: layer(MakeupPart.lips, source.lips),
    lipFinish: source.lipFinish,
  );

  /// 用于测试和标定相邻控制点的最大感知跃迁。
  static double maximumStep(MakeupPart part, {int samples = 100}) {
    var previous = intensity(part, 0);
    var largest = 0.0;
    for (var index = 1; index <= samples; index++) {
      final current = intensity(part, index / samples);
      largest = math.max(largest, current - previous);
      previous = current;
    }
    return largest;
  }
}
