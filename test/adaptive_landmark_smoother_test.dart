import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/models/normalized_face_frame.dart';
import 'package:glamar/features/face_mesh/utils/adaptive_landmark_smoother.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

void main() {
  test('keeps still landmarks stable', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    final mesh = _mesh(shiftX: 0);
    final first = smoother.observe(
      mesh: mesh,
      sourceSequence: 1,
      sourceTimestamp: now - const Duration(milliseconds: 32),
    )!;
    final second = smoother.observe(
      mesh: mesh,
      sourceSequence: 2,
      sourceTimestamp: now,
    )!;

    expect((second[1] - first[1]).distance, lessThan(0.01));
    expect(second.sourceSequence, 2);
  });

  test('keeps canonical depth data for the future GPU backend', () {
    final smoother = AdaptiveLandmarkSmoother();
    final mesh = _mesh(shiftX: 0);
    final point = mesh.landmarks[1];
    mesh.landmarks[1] = FaceMeshLandmark(x: point.x, y: point.y, z: -0.12);

    final frame = smoother.observe(mesh: mesh, sourceSequence: 9)!;

    expect(frame.landmarkCount, 468);
    expect(frame.xyz.length, 468 * 3);
    expect(frame.z(1), closeTo(-0.12, 0.0001));
    expect(frame.sourceSequence, 9);
  });

  test('uses aspect-correct metrics while preserving normalized output', () {
    final smoother = AdaptiveLandmarkSmoother();
    final mesh = _mesh(shiftX: 0, imageWidth: 720, imageHeight: 1280);

    final frame = smoother.observe(mesh: mesh)!;

    expect(frame.x(10), closeTo(mesh.landmarks[10].x, 0.0001));
    expect(frame.y(10), closeTo(mesh.landmarks[10].y, 0.0001));
  });

  test('predicts moving face forward between inference frames', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    smoother.observe(
      mesh: _mesh(shiftX: 0),
      sourceTimestamp: now - const Duration(milliseconds: 33),
    );
    final observed = smoother.observe(
      mesh: _mesh(shiftX: 0.018),
      sourceTimestamp: now,
    )!;
    final predicted = smoother.predict(
      displayTimestamp: now + const Duration(milliseconds: 33),
    )!;

    expect(predicted[1].dx, greaterThan(observed[1].dx));
  });

  test('clamps prediction during a longer tracking dropout', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    smoother.observe(
      mesh: _mesh(shiftX: 0),
      sourceTimestamp: now - const Duration(milliseconds: 33),
    );
    smoother.observe(mesh: _mesh(shiftX: 0.018), sourceTimestamp: now);

    final clamped = smoother.predict(
      displayTimestamp: now + const Duration(milliseconds: 96),
    )!;
    final muchLater = smoother.predict(
      displayTimestamp: now + const Duration(milliseconds: 400),
    )!;

    expect((clamped[1] - muchLater[1]).distance, lessThan(0.001));
  });

  test('predicts an approaching face without distorting proportions', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    smoother.observe(
      mesh: _mesh(shiftX: 0, scale: 1),
      sourceTimestamp: now - const Duration(milliseconds: 33),
    );
    final observed = smoother.observe(
      mesh: _mesh(shiftX: 0, scale: 1.12),
      sourceTimestamp: now,
    )!;
    final predicted = smoother.predict(
      displayTimestamp: now + const Duration(milliseconds: 33),
    )!;

    final observedFaceWidth = (observed[454] - observed[234]).distance;
    final predictedFaceWidth = (predicted[454] - predicted[234]).distance;
    final observedEyeRatio =
        (observed[263] - observed[33]).distance / observedFaceWidth;
    final predictedEyeRatio =
        (predicted[263] - predicted[33]).distance / predictedFaceWidth;
    expect(predictedFaceWidth, greaterThan(observedFaceWidth));
    expect(predictedEyeRatio, closeTo(observedEyeRatio, 0.015));
  });

  test('limits a single landmark spike without freezing the face', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    final first = smoother.observe(
      mesh: _mesh(shiftX: 0),
      sourceTimestamp: now - const Duration(milliseconds: 33),
    )!;
    final observed = smoother.observe(
      mesh: _mesh(shiftX: 0, outlierIndex: 50, outlierDx: 0.2),
      sourceTimestamp: now,
    )!;

    final displacement = observed[50].dx - first[50].dx;
    expect(displacement, greaterThan(0));
    expect(displacement, lessThan(80));
  });

  test('follows a fast rigid rotation without stretching the face', () {
    final smoother = AdaptiveLandmarkSmoother();
    const now = Duration(seconds: 10);
    final first = smoother.observe(
      mesh: _mesh(shiftX: 0),
      sourceTimestamp: now - const Duration(milliseconds: 33),
    )!;
    final observed = smoother.observe(
      mesh: _mesh(shiftX: 0, rotation: 0.16),
      sourceTimestamp: now,
    )!;

    final firstRatio =
        (first[152] - first[10]).distance / (first[454] - first[234]).distance;
    final observedRatio =
        (observed[152] - observed[10]).distance /
        (observed[454] - observed[234]).distance;
    final observedAngle = math.atan2(
      observed[454].dy - observed[234].dy,
      observed[454].dx - observed[234].dx,
    );
    expect(observedAngle, greaterThan(0.1));
    expect(observedRatio, closeTo(firstRatio, 0.015));
  });
}

extension on NormalizedFaceFrame {
  Offset operator [](int index) => Offset(x(index) * 1000, y(index) * 1000);
}

FaceMeshResult _mesh({
  required double shiftX,
  double scale = 1,
  double rotation = 0,
  int imageWidth = 1000,
  int imageHeight = 1000,
  int? outlierIndex,
  double outlierDx = 0,
}) {
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
  for (var index = 0; index < landmarks.length; index++) {
    final point = landmarks[index];
    final relativeX = (point.x - 0.5 - shiftX) * scale;
    final relativeY = (point.y - 0.5) * scale;
    landmarks[index] = FaceMeshLandmark(
      x:
          0.5 +
          relativeX * math.cos(rotation) -
          relativeY * math.sin(rotation) +
          shiftX,
      y: 0.5 + relativeX * math.sin(rotation) + relativeY * math.cos(rotation),
      z: point.z * scale,
    );
  }
  if (outlierIndex != null) {
    final point = landmarks[outlierIndex];
    landmarks[outlierIndex] = FaceMeshLandmark(
      x: point.x + outlierDx,
      y: point.y,
      z: point.z,
    );
  }
  return FaceMeshResult(
    landmarks: landmarks,
    rect: NormalizedRect(
      xCenter: 0.5 + shiftX,
      yCenter: 0.5,
      width: 0.5 * scale,
      height: 0.7 * scale,
    ),
    score: 0.99,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}
