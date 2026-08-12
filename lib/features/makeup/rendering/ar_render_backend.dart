import 'package:flutter/foundation.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';

@immutable
class ArRenderBackendCapabilities {
  const ArRenderBackendCapabilities({
    required this.name,
    required this.cameraTextureComposition,
    required this.canonicalVertexInput,
    required this.gpuUniformInput,
  });

  final String name;
  final bool cameraTextureComposition;
  final bool canonicalVertexInput;
  final bool gpuUniformInput;
}

@immutable
class ArNativeRenderSurface {
  const ArNativeRenderSurface({
    required this.textureId,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final int textureId;
  final int pixelWidth;
  final int pixelHeight;
}

/// 跟踪/妆容业务层只向这个接口提交帧，不感知 Canvas、
/// Metal 或 OpenGL ES 的具体实现。
abstract interface class ArRenderBackend {
  ArRenderBackendCapabilities get capabilities;

  /// 当前最新帧。Flutter 兼容面用它驱动重绘；原生纹理后端
  /// 可在提交时直接上传数据。
  ValueListenable<ArRenderPacket?> get frames;

  int get droppedSubmissions;

  bool submit(ArRenderPacket packet);

  void clear();

  void dispose();
}

/// 能够把部分妆容直接输出为 Flutter Texture 的后端。
///
/// 未就绪或初始化失败时 [nativeSurface] 为 null，页面会自动把
/// [nativeParts] 恢复给 Flutter 兼容后端绘制。
abstract interface class ArNativeTextureRenderBackend
    implements ArRenderBackend {
  ValueListenable<ArNativeRenderSurface?> get nativeSurface;

  /// 原生 GPU 从接收帧到完成绘制的平滑耗时（ms）。
  ValueListenable<double> get nativeRenderMs;

  /// 系统热压力，0 为正常，1 为严重/临界。用于长时试妆主动降档。
  ValueListenable<double> get thermalPressure;

  Set<MakeupPart> get nativeParts;
}
