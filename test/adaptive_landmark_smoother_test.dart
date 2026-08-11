import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/utils/adaptive_landmark_smoother.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

void main() {
  const targetSize = Size(1000, 1000);

  test('keeps still landmarks stable', () {
    final smoother = AdaptiveLandmarkSmoother();
    final now = DateTime.now();
    final mesh = _mesh(shiftX: 0);
    final first = smoother.observe(
      mesh: mesh,
      targetSize: targetSize,
      mirrorHorizontal: false,
      sourceTimestamp: now.subtract(const Duration(milliseconds: 32)),
    )!;
    final second = smoother.observe(
      mesh: mesh,
      targetSize: targetSize,
      mirrorHorizontal: false,
      sourceTimestamp: now,
    )!;

    expect((second[1] - first[1]).distance, lessThan(0.01));
  });

  test('predicts moving face forward between inference frames', () {
    final smoother = AdaptiveLandmarkSmoother();
    final now = DateTime.now();
    smoother.observe(
      mesh: _mesh(shiftX: 0),
      targetSize: targetSize,
      mirrorHorizontal: false,
      sourceTimestamp: now.subtract(const Duration(milliseconds: 33)),
    );
    final observed = smoother.observe(
      mesh: _mesh(shiftX: 0.018),
      targetSize: targetSize,
      mirrorHorizontal: false,
      sourceTimestamp: now,
    )!;
    final predicted = smoother.predict(
      displayTimestamp: now.add(const Duration(milliseconds: 33)),
    )!;

    expect(predicted[1].dx, greaterThan(observed[1].dx));
  });
}

FaceMeshResult _mesh({required double shiftX}) {
  final landmarks = List<FaceMeshLandmark>.generate(468, (index) {
    final column = index % 22;
    final row = index ~/ 22;
    return FaceMeshLandmark(
      x: 0.25 + column / 44 + shiftX,
      y: 0.2 + row / 44,
      z: 0,
    );
  }, growable: false);
  // 给滤波器使用的左右脸、上下脸锚点设置稳定且合理的几何位置。
  landmarks[1] = FaceMeshLandmark(x: 0.5 + shiftX, y: 0.5, z: 0);
  landmarks[10] = FaceMeshLandmark(x: 0.5 + shiftX, y: 0.2, z: 0);
  landmarks[33] = FaceMeshLandmark(x: 0.4 + shiftX, y: 0.42, z: 0);
  landmarks[152] = FaceMeshLandmark(x: 0.5 + shiftX, y: 0.82, z: 0);
  landmarks[234] = FaceMeshLandmark(x: 0.28 + shiftX, y: 0.5, z: 0);
  landmarks[263] = FaceMeshLandmark(x: 0.6 + shiftX, y: 0.42, z: 0);
  landmarks[454] = FaceMeshLandmark(x: 0.72 + shiftX, y: 0.5, z: 0);
  return FaceMeshResult(
    landmarks: landmarks,
    rect: NormalizedRect(
      xCenter: 0.5 + shiftX,
      yCenter: 0.5,
      width: 0.5,
      height: 0.7,
    ),
    score: 0.99,
    imageWidth: 1000,
    imageHeight: 1000,
  );
}
