import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/utils/lip_landmark_indices.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';

void main() {
  test('lip mask keeps the mouth opening transparent', () {
    final points = List<Offset>.filled(468, const Offset(200, 200));
    _placeEllipse(points, LipLandmarkIndices.outerLip, 200, 220, 56, 25);
    _placeEllipse(points, LipLandmarkIndices.innerLip, 200, 220, 24, 9);

    final lipPath = MakeupPainterUtils.lipPath(points);

    expect(lipPath.contains(const Offset(200, 220)), isFalse);
    expect(lipPath.contains(const Offset(238, 220)), isTrue);
  });

  test('closed lips do not create an unstable inner cutout', () {
    final points = List<Offset>.filled(468, const Offset(200, 220));
    _placeEllipse(points, LipLandmarkIndices.outerLip, 200, 220, 56, 25);
    for (var index = 0; index < LipLandmarkIndices.innerLip.length; index++) {
      final t = index / (LipLandmarkIndices.innerLip.length - 1);
      points[LipLandmarkIndices.innerLip[index]] = Offset(176 + t * 48, 220);
    }
    points[13] = const Offset(200, 220);
    points[14] = const Offset(200, 220);

    final lipPath = MakeupPainterUtils.lipPath(points);

    expect(lipPath.contains(const Offset(200, 220)), isTrue);
  });

  test('skin mask protects eyes, brows and lips', () {
    final points = List<Offset>.filled(468, const Offset(200, 220));
    _placeEllipse(points, MakeupPainterUtils.faceOval, 200, 220, 150, 190);
    _placeEllipse(points, MakeupPainterUtils.leftEyeContour, 150, 190, 28, 12);
    _placeEllipse(points, MakeupPainterUtils.rightEyeContour, 250, 190, 28, 12);
    _placeLine(points, MakeupPainterUtils.leftBrow, 125, 160, 175, 155);
    _placeLine(points, MakeupPainterUtils.rightBrow, 225, 155, 275, 160);
    _placeEllipse(points, LipLandmarkIndices.outerLip, 200, 285, 48, 22);
    _placeEllipse(points, LipLandmarkIndices.innerLip, 200, 285, 21, 8);

    final skin = MakeupPainterUtils.skinPath(points, featurePadding: 8);

    expect(skin.contains(const Offset(150, 190)), isFalse);
    expect(skin.contains(const Offset(150, 158)), isFalse);
    expect(skin.contains(const Offset(200, 285)), isFalse);
    expect(skin.contains(const Offset(115, 235)), isTrue);
  });

  test('local detail sizes stay inside pixel safety bounds', () {
    expect(MakeupPainterUtils.scaledSize(8, 0.01, minimum: 0.4), 0.4);
    expect(MakeupPainterUtils.scaledSize(400, 0.1, maximum: 12), 12);
    expect(
      MakeupPainterUtils.scaledSize(80, 0.05, minimum: 0.5, maximum: 8),
      4,
    );
  });
}

void _placeEllipse(
  List<Offset> points,
  List<int> indices,
  double centerX,
  double centerY,
  double radiusX,
  double radiusY,
) {
  for (var index = 0; index < indices.length; index++) {
    final angle = math.pi * 2 * index / indices.length;
    points[indices[index]] = Offset(
      centerX + math.cos(angle) * radiusX,
      centerY + math.sin(angle) * radiusY,
    );
  }
}

void _placeLine(
  List<Offset> points,
  List<int> indices,
  double startX,
  double startY,
  double endX,
  double endY,
) {
  for (var index = 0; index < indices.length; index++) {
    final t = index / (indices.length - 1);
    points[indices[index]] = Offset(
      startX + (endX - startX) * t,
      startY + (endY - startY) * t,
    );
  }
}
