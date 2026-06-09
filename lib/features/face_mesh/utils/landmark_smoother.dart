import 'dart:ui';

import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// 对嘴唇关键点做 EMA 平滑，减少抖动同时尽量保持跟手。
class LipLandmarkSmoother {
  LipLandmarkSmoother({required this.alpha, required this.lipIndices});

  final double alpha;
  final Set<int> lipIndices;

  final Map<int, Offset> _state = {};

  List<Offset>? smoothToPixelOffsets({
    required FaceMeshResult mesh,
    required Size targetSize,
    int rotationDegrees = 0,
    bool mirrorHorizontal = false,
  }) {
    final landmarks = mesh.landmarks;
    if (landmarks.length < 468) {
      _state.clear();
      return null;
    }

    final beta = 1.0 - alpha;
    for (final index in lipIndices) {
      final raw = landmarks[index];
      final mapped = mesh.landmarkAsOffset(
        raw,
        targetSize: targetSize,
        rotationDegrees: rotationDegrees,
        mirrorHorizontal: mirrorHorizontal,
      );
      final prev = _state[index];
      _state[index] = prev == null
          ? mapped
          : Offset(
              alpha * mapped.dx + beta * prev.dx,
              alpha * mapped.dy + beta * prev.dy,
            );
    }

    // 非嘴唇点直接映射，不参与跨帧平滑，供路径构建时索引访问
    final offsets = List<Offset>.generate(landmarks.length, (index) {
      if (lipIndices.contains(index)) {
        return _state[index]!;
      }
      return mesh.landmarkAsOffset(
        landmarks[index],
        targetSize: targetSize,
        rotationDegrees: rotationDegrees,
        mirrorHorizontal: mirrorHorizontal,
      );
    }, growable: false);

    return offsets;
  }

  void reset() => _state.clear();
}
