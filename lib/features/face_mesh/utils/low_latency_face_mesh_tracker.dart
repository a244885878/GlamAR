import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// MediaPipe 标准的“检测一次、持续跟踪”调度。
///
/// 原有 inference pipeline 每帧都会同时跑人脸检测器和 Face Mesh。这里仅在
/// 首帧或跟踪置信度丢失时重检测，其余帧复用 Face Mesh 内部 ROI 跟踪状态。
class LowLatencyFaceMeshTracker {
  LowLatencyFaceMeshTracker(
    this._detector,
    this._mesh, {
    this.minimumUsableScore = 0.48,
  });

  final FaceDetectorProcessor _detector;
  final FaceMeshProcessor _mesh;
  final double minimumUsableScore;

  bool _needsDetection = true;
  int _consecutiveTrackingFailures = 0;

  FaceMeshResult? processNv21(
    FaceMeshNv21Image image, {
    required int rotationDegrees,
  }) {
    if (_needsDetection) {
      final detection = _detector
          .processNv21(image, rotationDegrees: rotationDegrees)
          .primaryDetection;
      final roi = detection?.expandedFaceRect ?? detection?.faceRect;
      if (roi == null) return null;
      final result = _mesh.processNv21(
        image,
        roi: roi,
        rotationDegrees: rotationDegrees,
      );
      return _accept(result);
    }

    final result = _mesh.processNv21(image, rotationDegrees: rotationDegrees);
    return _accept(result);
  }

  FaceMeshResult? processBgra(
    FaceMeshImage image, {
    required int rotationDegrees,
  }) {
    if (_needsDetection) {
      final detection = _detector
          .process(image, rotationDegrees: rotationDegrees)
          .primaryDetection;
      final roi = detection?.expandedFaceRect ?? detection?.faceRect;
      if (roi == null) return null;
      final result = _mesh.process(
        image,
        roi: roi,
        rotationDegrees: rotationDegrees,
      );
      return _accept(result);
    }

    final result = _mesh.process(image, rotationDegrees: rotationDegrees);
    return _accept(result);
  }

  FaceMeshResult? _accept(FaceMeshResult result) {
    final usable =
        result.landmarks.length >= 468 && result.score >= minimumUsableScore;
    if (usable) {
      _needsDetection = false;
      _consecutiveTrackingFailures = 0;
      return result;
    }
    _consecutiveTrackingFailures++;
    // 遮挡或快速转头常会造成单帧低置信度。先给 ROI 跟踪一次自恢复
    // 机会，连续两帧失效才重跑更贵的人脸检测。
    _needsDetection = _consecutiveTrackingFailures >= 2;
    return null;
  }

  void reset() {
    _needsDetection = true;
    _consecutiveTrackingFailures = 0;
  }
}
