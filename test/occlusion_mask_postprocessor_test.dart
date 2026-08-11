import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/utils/occlusion_mask_postprocessor.dart';

void main() {
  test('body skin occludes makeup while face skin does not', () {
    final scores = Float32List(3 * 6);
    _setScores(scores, 0, [0, 0, 4, 1, 0, 0]);
    _setScores(scores, 1, [4, 0, 0, 0, 0, 0]);
    _setScores(scores, 2, [0, 0, 1, 4, 0, 0]);

    final rgba = OcclusionMaskPostprocessor().process(
      scores,
      width: 3,
      height: 1,
    );

    expect(rgba[3], greaterThan(0));
    expect(rgba[11], 0);
  });

  test('background never erases makeup', () {
    final scores = Float32List.fromList([5, 0, 0, 0, 0, 0]);
    final rgba = OcclusionMaskPostprocessor().process(
      scores,
      width: 1,
      height: 1,
    );

    expect(rgba[3], 0);
  });

  test('temporal filter removes a disappearing occluder gradually', () {
    final processor = OcclusionMaskPostprocessor();
    final hand = Float32List.fromList([0, 0, 5, 0, 0, 0]);
    final face = Float32List.fromList([0, 0, 0, 5, 0, 0]);

    final visible = processor.process(hand, width: 1, height: 1)[3];
    final firstClear = processor.process(face, width: 1, height: 1)[3];
    final secondClear = processor.process(face, width: 1, height: 1)[3];

    expect(firstClear, lessThan(visible));
    expect(firstClear, greaterThan(0));
    expect(secondClear, lessThan(firstClear));
  });
}

void _setScores(Float32List target, int pixel, List<double> values) {
  target.setRange(pixel * 6, pixel * 6 + 6, values);
}
