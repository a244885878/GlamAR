import 'dart:math' as math;
import 'dart:ui';

import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// 速度自适应全脸平滑：静止时压制亚像素抖动，转头/表情时提高响应速度。
class AdaptiveLandmarkSmoother {
  final List<Offset> _state = <Offset>[];
  DateTime? _lastUpdate;

  List<Offset>? smoothToPixelOffsets({
    required FaceMeshResult mesh,
    required Size targetSize,
    required bool mirrorHorizontal,
  }) {
    if (mesh.landmarks.length < 468 || targetSize.isEmpty) {
      reset();
      return null;
    }

    final now = DateTime.now();
    final dt = _lastUpdate == null
        ? 1 / 30
        : math.max(
            1 / 120,
            now.difference(_lastUpdate!).inMicroseconds / 1000000,
          );
    _lastUpdate = now;
    final raw = List<Offset>.generate(mesh.landmarks.length, (index) {
      return mesh.landmarkAsOffset(
        mesh.landmarks[index],
        targetSize: targetSize,
        rotationDegrees: 0,
        mirrorHorizontal: mirrorHorizontal,
      );
    }, growable: false);

    if (_state.length != raw.length) {
      _state
        ..clear()
        ..addAll(raw);
      return List<Offset>.unmodifiable(_state);
    }

    final scale = math.max(1.0, (raw[454] - raw[234]).distance);
    for (var i = 0; i < raw.length; i++) {
      final distance = (raw[i] - _state[i]).distance;
      final normalizedSpeed = distance / scale / dt;
      final response = (normalizedSpeed / 0.55).clamp(0.0, 1.0);
      final alpha = 0.2 + response * 0.62;
      final deadZone = scale * 0.0012;
      if (distance < deadZone) continue;
      _state[i] = Offset.lerp(_state[i], raw[i], alpha)!;
    }
    return List<Offset>.unmodifiable(_state);
  }

  void reset() {
    _state.clear();
    _lastUpdate = null;
  }
}
