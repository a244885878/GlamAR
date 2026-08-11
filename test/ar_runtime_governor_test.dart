import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/utils/ar_runtime_governor.dart';

void main() {
  test('holds briefly then fades a lost face smoothly', () {
    expect(
      ArRuntimeGovernor.trackingOpacity(const Duration(milliseconds: 100)),
      1,
    );
    final middle = ArRuntimeGovernor.trackingOpacity(
      const Duration(milliseconds: 180),
    );
    expect(middle, greaterThan(0));
    expect(middle, lessThan(1));
    expect(
      ArRuntimeGovernor.trackingOpacity(ArRuntimeGovernor.maximumTrackingGap),
      0,
    );
  });

  test('gives face tracking more CPU time when FPS drops', () {
    final healthy = ArRuntimeGovernor.occlusionCooldown(
      faceFps: 30,
      faceInferenceMs: 24,
      occlusionInferenceMs: 180,
    );
    final pressured = ArRuntimeGovernor.occlusionCooldown(
      faceFps: 13,
      faceInferenceMs: 55,
      occlusionInferenceMs: 340,
    );

    expect(pressured, greaterThan(healthy));
    expect(pressured, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
  });
}
