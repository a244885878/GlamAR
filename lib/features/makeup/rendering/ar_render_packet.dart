import 'package:flutter/foundation.dart';
import 'package:glamar/features/face_mesh/models/normalized_face_frame.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/models/makeup_response_curve.dart';

/// Native GPU 后端与 Flutter 兼容后端共用的妆容参数块。
///
/// 布局是显式版本化的。后续 Metal / OpenGL ES 可以直接按下列
/// offset 读取 [gpuUniforms]，无需在 platform channel 中传递颜色对象。
@immutable
class ArMakeupMaterialState {
  factory ArMakeupMaterialState.fromLook(MakeupLook source) {
    final calibrated = MakeupResponseCurve.look(source);
    return ArMakeupMaterialState._(
      calibrated,
      _encodeMaterialUniforms(calibrated),
    );
  }

  const ArMakeupMaterialState._(this.look, this.gpuUniforms);

  static const int protocolVersion = 1;
  static const int headerLength = 4;
  static const int layerStride = 12;

  static const int versionOffset = 0;
  static const int layerCountOffset = 1;
  static const int lipFinishOffset = 2;

  static const int enabledOffset = 0;
  static const int intensityOffset = 1;
  static const int detailOffset = 2;
  static const int primaryRedOffset = 3;
  static const int primaryGreenOffset = 4;
  static const int primaryBlueOffset = 5;
  static const int primaryAlphaOffset = 6;
  static const int hasSecondaryColorOffset = 7;
  static const int secondaryRedOffset = 8;
  static const int secondaryGreenOffset = 9;
  static const int secondaryBlueOffset = 10;
  static const int secondaryAlphaOffset = 11;

  static int layerOffset(MakeupPart part) =>
      headerLength + part.index * layerStride;

  /// 供所有渲染后端使用的校准后妆容；UI 状态仍保留原始控制值。
  final MakeupLook look;

  /// 读取时视为不可变；每次调妆才会构建新实例。
  final Float32List gpuUniforms;

  ByteData get gpuBytes => gpuUniforms.buffer.asByteData(
    gpuUniforms.offsetInBytes,
    gpuUniforms.lengthInBytes,
  );

  static Float32List _encodeMaterialUniforms(MakeupLook look) {
    final result = Float32List(
      headerLength + MakeupPart.values.length * layerStride,
    );
    result[versionOffset] = protocolVersion.toDouble();
    result[layerCountOffset] = MakeupPart.values.length.toDouble();
    result[lipFinishOffset] = switch (look.lipFinish) {
      LipFinish.velvet => 0,
      LipFinish.satin => 0.5,
      LipFinish.glass => 1,
    };

    for (final part in MakeupPart.values) {
      final config = look.layer(part);
      final offset = layerOffset(part);
      final primary = config.color;
      final secondary = config.secondaryColor;
      result[offset + enabledOffset] = config.enabled ? 1 : 0;
      result[offset + intensityOffset] = config.intensity;
      result[offset + detailOffset] = config.detail;
      result[offset + primaryRedOffset] = primary.r;
      result[offset + primaryGreenOffset] = primary.g;
      result[offset + primaryBlueOffset] = primary.b;
      result[offset + primaryAlphaOffset] = primary.a;
      result[offset + hasSecondaryColorOffset] = secondary == null ? 0 : 1;
      result[offset + secondaryRedOffset] = secondary?.r ?? primary.r;
      result[offset + secondaryGreenOffset] = secondary?.g ?? primary.g;
      result[offset + secondaryBlueOffset] = secondary?.b ?? primary.b;
      result[offset + secondaryAlphaOffset] = secondary?.a ?? primary.a;
    }
    return result;
  }
}

/// 每个跟踪帧都可能变化的姿态、光照和性能降级参数。
@immutable
class ArFaceRenderState {
  ArFaceRenderState({
    required this.context,
    required this.trackingOpacity,
    required this.runtimeDetailQuality,
    required this.skinFilterEnabled,
    this.pixelMaterialEnabled = false,
  }) : gpuUniforms = _encodeFaceUniforms(
         context,
         trackingOpacity: trackingOpacity,
         runtimeDetailQuality: runtimeDetailQuality,
         skinFilterEnabled: skinFilterEnabled,
         pixelMaterialEnabled: pixelMaterialEnabled,
       );

  static const int protocolVersion = 1;
  static const int uniformLength = 18;

  static const int versionOffset = 0;
  static const int exposureOffset = 1;
  static const int sideAExposureOffset = 2;
  static const int sideBExposureOffset = 3;
  static const int warmthOffset = 4;
  static const int sideAVisibilityOffset = 5;
  static const int sideBVisibilityOffset = 6;
  static const int profileOpacityOffset = 7;
  static const int fineDetailVisibilityOffset = 8;
  static const int sideAEyeOpennessOffset = 9;
  static const int sideBEyeOpennessOffset = 10;
  static const int mouthOpennessOffset = 11;
  static const int trackingOpacityOffset = 12;
  static const int runtimeDetailQualityOffset = 13;
  static const int skinFilterEnabledOffset = 14;
  static const int pixelMaterialEnabledOffset = 15;
  static const int skinChromaOffset = 16;
  static const int localContrastOffset = 17;

  final FaceRenderContext context;
  final double trackingOpacity;
  final double runtimeDetailQuality;
  final bool skinFilterEnabled;
  final bool pixelMaterialEnabled;
  final Float32List gpuUniforms;

  ByteData get gpuBytes => gpuUniforms.buffer.asByteData(
    gpuUniforms.offsetInBytes,
    gpuUniforms.lengthInBytes,
  );

  static Float32List _encodeFaceUniforms(
    FaceRenderContext context, {
    required double trackingOpacity,
    required double runtimeDetailQuality,
    required bool skinFilterEnabled,
    required bool pixelMaterialEnabled,
  }) {
    final lighting = context.lighting;
    return Float32List.fromList(<double>[
      protocolVersion.toDouble(),
      lighting.exposure,
      lighting.sideAExposure,
      lighting.sideBExposure,
      lighting.warmth,
      context.sideAVisibility,
      context.sideBVisibility,
      context.profileOpacity,
      context.fineDetailVisibility,
      context.sideAEyeOpenness,
      context.sideBEyeOpenness,
      context.mouthOpenness,
      trackingOpacity.clamp(0.0, 1.0).toDouble(),
      runtimeDetailQuality.clamp(0.0, 1.0).toDouble(),
      skinFilterEnabled ? 1 : 0,
      pixelMaterialEnabled ? 1 : 0,
      lighting.skinChroma.clamp(0.0, 1.0).toDouble(),
      lighting.localContrast.clamp(0.0, 1.0).toDouble(),
    ]);
  }
}

/// 避免在仅更新预测顶点的 vsync 上重复分配 dynamic uniform。
///
/// 人脸推理产生新 [FaceRenderContext] 或性能档位变化时才重建；
/// 普通的 60Hz 跟踪预测帧直接复用上一块 18-float buffer。
class ArFaceRenderStateCache {
  ArFaceRenderState? _cached;

  ArFaceRenderState resolve({
    required FaceRenderContext context,
    required double trackingOpacity,
    required double runtimeDetailQuality,
    required bool skinFilterEnabled,
    bool pixelMaterialEnabled = false,
  }) {
    final cached = _cached;
    if (cached != null &&
        identical(cached.context, context) &&
        cached.trackingOpacity == trackingOpacity &&
        cached.runtimeDetailQuality == runtimeDetailQuality &&
        cached.skinFilterEnabled == skinFilterEnabled &&
        cached.pixelMaterialEnabled == pixelMaterialEnabled) {
      return cached;
    }
    return _cached = ArFaceRenderState(
      context: context,
      trackingOpacity: trackingOpacity,
      runtimeDetailQuality: runtimeDetailQuality,
      skinFilterEnabled: skinFilterEnabled,
      pixelMaterialEnabled: pixelMaterialEnabled,
    );
  }

  void clear() => _cached = null;
}

/// 一次原子化的 AR 渲染提交。
///
/// [faceFrame] 中的 packed xyz 直接被引用，不复制 468 个顶点。
/// [submissionSequence] 用于 latest-frame-wins，并允许同一人脸
/// source frame 上的调妆变更立即提交。
@immutable
class ArRenderPacket {
  const ArRenderPacket({
    required this.submissionSequence,
    required this.faceFrame,
    required this.material,
    required this.faceState,
    required this.mirrorHorizontal,
  });

  static const int protocolVersion = 1;

  final int submissionSequence;
  final NormalizedFaceFrame faceFrame;
  final ArMakeupMaterialState material;
  final ArFaceRenderState faceState;
  final bool mirrorHorizontal;

  int get sourceSequence => faceFrame.sourceSequence;
  Duration get presentationTimestamp => faceFrame.presentationTimestamp;
}
