import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/models/normalized_face_frame.dart';

void main() {
  test('projects one normalized frame into different render backends', () {
    final frame = NormalizedFaceFrame(
      xyz: Float32List.fromList([0.2, 0.3, -0.04, 0.8, 0.7, 0.02]),
      sourceSequence: 17,
      sourceTimestamp: const Duration(milliseconds: 100),
      presentationTimestamp: const Duration(milliseconds: 124),
    );

    final large = frame.projectToPixels(
      const Size(1000, 500),
      mirrorHorizontal: false,
    );
    final mirrored = frame.projectToPixels(
      const Size(500, 250),
      mirrorHorizontal: true,
    );

    expect(large[0].dx, closeTo(200, 0.001));
    expect(large[0].dy, closeTo(150, 0.001));
    expect(mirrored[0].dx, closeTo(400, 0.001));
    expect(mirrored[0].dy, closeTo(75, 0.001));
    expect(frame.z(0), closeTo(-0.04, 0.0001));
    expect(frame.sourceSequence, 17);
    expect(frame.predictionAge, const Duration(milliseconds: 24));
  });

  test('clamps only the Flutter projection, not canonical GPU data', () {
    final frame = NormalizedFaceFrame(
      xyz: Float32List.fromList([-0.05, 1.08, 0]),
      sourceSequence: 1,
      sourceTimestamp: Duration.zero,
      presentationTimestamp: Duration.zero,
    );

    final projected = frame.projectToPixels(
      const Size(200, 300),
      mirrorHorizontal: false,
    );

    expect(frame.x(0), closeTo(-0.05, 0.0001));
    expect(frame.y(0), closeTo(1.08, 0.0001));
    expect(projected.single, const Offset(0, 300));
  });
}
