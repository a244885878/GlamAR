import 'dart:typed_data';

import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// 可在 [compute] 中执行的 NV21 转换请求（避免 Android 三平面 YUV 阻塞 UI 线程）。
class Nv21ConvertRequest {
  const Nv21ConvertRequest({
    required this.width,
    required this.height,
    required this.yPlane,
    required this.yBytesPerRow,
    required this.uPlane,
    required this.uBytesPerRow,
    required this.uPixelStride,
    required this.vPlane,
    required this.vBytesPerRow,
    required this.vPixelStride,
  });

  final int width;
  final int height;
  final Uint8List yPlane;
  final int yBytesPerRow;
  final Uint8List uPlane;
  final int uBytesPerRow;
  final int uPixelStride;
  final Uint8List vPlane;
  final int vBytesPerRow;
  final int vPixelStride;
}

FaceMeshNv21Image? convertNv21InIsolate(Nv21ConvertRequest request) {
  final width = request.width;
  final height = request.height;
  if ((width & 1) != 0 || (height & 1) != 0) {
    return null;
  }

  final yOut = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    final srcRow = row * request.yBytesPerRow;
    final dstRow = row * width;
    for (var col = 0; col < width; col++) {
      yOut[dstRow + col] = request.yPlane[srcRow + col];
    }
  }

  final uvHeight = height ~/ 2;
  final uvWidth = width ~/ 2;
  final vuOut = Uint8List(width * uvHeight);

  for (var row = 0; row < uvHeight; row++) {
    for (var col = 0; col < uvWidth; col++) {
      final uIndex = row * request.uBytesPerRow + col * request.uPixelStride;
      final vIndex = row * request.vBytesPerRow + col * request.vPixelStride;
      if (uIndex >= request.uPlane.length || vIndex >= request.vPlane.length) {
        return null;
      }
      final out = row * width + col * 2;
      vuOut[out] = request.vPlane[vIndex];
      vuOut[out + 1] = request.uPlane[uIndex];
    }
  }

  return FaceMeshNv21Image(
    yPlane: yOut,
    vuPlane: vuOut,
    width: width,
    height: height,
    yBytesPerRow: width,
    vuBytesPerRow: width,
  );
}
