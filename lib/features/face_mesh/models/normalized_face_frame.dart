import 'dart:typed_data';
import 'dart:ui';

/// 与具体 UI、镜像方式和渲染后端无关的一帧人脸状态。
///
/// 关键点按 xyz 连续存储，既减少 Dart 对象数量，也可以在原生 GPU 后端
/// 接入后直接作为顶点缓冲上传。坐标允许短时预测略微超出 0~1；Flutter
/// 回退渲染在投影时负责裁切。
class NormalizedFaceFrame {
  const NormalizedFaceFrame({
    required this.xyz,
    required this.sourceSequence,
    required this.sourceTimestamp,
    required this.presentationTimestamp,
  });

  final Float32List xyz;
  final int sourceSequence;
  final Duration sourceTimestamp;
  final Duration presentationTimestamp;

  int get landmarkCount => xyz.length ~/ 3;

  Duration get predictionAge {
    final age = presentationTimestamp - sourceTimestamp;
    return age.isNegative ? Duration.zero : age;
  }

  double x(int index) => xyz[index * 3];
  double y(int index) => xyz[index * 3 + 1];
  double z(int index) => xyz[index * 3 + 2];

  /// Flutter 兼容后端的唯一像素投影点。原生 GPU 后端直接使用 [xyz]。
  List<Offset> projectToPixels(
    Size targetSize, {
    required bool mirrorHorizontal,
    bool clampToBounds = true,
  }) {
    if (targetSize.isEmpty) return const <Offset>[];
    return List<Offset>.generate(landmarkCount, (index) {
      var normalizedX = x(index);
      var normalizedY = y(index);
      if (mirrorHorizontal) normalizedX = 1 - normalizedX;
      if (clampToBounds) {
        normalizedX = normalizedX.clamp(0.0, 1.0).toDouble();
        normalizedY = normalizedY.clamp(0.0, 1.0).toDouble();
      }
      return Offset(
        normalizedX * targetSize.width,
        normalizedY * targetSize.height,
      );
    }, growable: false);
  }
}
