import 'dart:typed_data';

import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// MediaPipe 468 点稠密脸部拓扑，仅在原生 GPU 后端初始化时构建一次。
abstract final class NativeFaceMeshTopology {
  static final Uint16List skinIndices = _buildSkinIndices();

  /// 剔除与眼睛、眉毛或唇部轮廓相邻的三角形，保留原始高频纹理。
  static const Set<int> _protectedVertices = <int>{
    33,
    7,
    163,
    144,
    145,
    153,
    154,
    155,
    133,
    173,
    157,
    158,
    159,
    160,
    161,
    246,
    362,
    382,
    381,
    380,
    374,
    373,
    390,
    249,
    263,
    466,
    388,
    387,
    386,
    385,
    384,
    398,
    70,
    63,
    105,
    66,
    107,
    336,
    296,
    334,
    293,
    300,
    61,
    185,
    40,
    39,
    37,
    0,
    267,
    269,
    270,
    409,
    291,
    375,
    321,
    405,
    314,
    17,
    84,
    181,
    91,
    146,
    78,
    191,
    80,
    81,
    82,
    13,
    312,
    311,
    310,
    415,
    308,
    324,
    318,
    402,
    317,
    14,
    87,
    178,
    88,
    95,
  };

  static Uint16List _buildSkinIndices() {
    final landmarks = List<FaceMeshLandmark>.generate(
      468,
      (_) => FaceMeshLandmark(x: 0, y: 0, z: 0),
      growable: false,
    );
    final mesh = FaceMeshResult(
      landmarks: landmarks,
      rect: const NormalizedRect(
        xCenter: 0.5,
        yCenter: 0.5,
        width: 1,
        height: 1,
        rotation: 0,
      ),
      score: 1,
      imageWidth: 1,
      imageHeight: 1,
    );
    final indices = <int>[];
    for (final triangle in mesh.triangles) {
      if (triangle.indices.any(_protectedVertices.contains)) continue;
      indices.addAll(triangle.indices);
    }
    return Uint16List.fromList(indices);
  }
}
