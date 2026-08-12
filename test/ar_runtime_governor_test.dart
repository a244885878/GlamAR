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

  test('degrades only optional render detail under sustained pressure', () {
    final healthy = ArRuntimeGovernor.renderDetailQuality(
      faceFps: 28,
      faceInferenceMs: 25,
    );
    final pressured = ArRuntimeGovernor.renderDetailQuality(
      faceFps: 13,
      faceInferenceMs: 52,
    );

    expect(healthy, 1);
    expect(pressured, 0.4);
    expect(
      ArRuntimeGovernor.renderDetailQuality(faceFps: 0, faceInferenceMs: 0),
      1,
    );
  });

  test('accounts for native and Flutter raster GPU pressure separately', () {
    final nativePressure = ArRuntimeGovernor.renderDetailQuality(
      faceFps: 28,
      faceInferenceMs: 25,
      gpuRenderMs: 20,
    );
    final filterPressure = ArRuntimeGovernor.renderDetailQuality(
      faceFps: 28,
      faceInferenceMs: 25,
      rasterFrameMs: 20,
    );

    expect(nativePressure, lessThan(1));
    expect(filterPressure, lessThan(1));
  });

  test('backs off optional work before sustained thermal throttling', () {
    final quality = ArRuntimeGovernor.renderDetailQuality(
      faceFps: 28,
      faceInferenceMs: 25,
      thermalPressure: 1,
    );
    final cooldown = ArRuntimeGovernor.occlusionCooldown(
      faceFps: 28,
      faceInferenceMs: 25,
      occlusionInferenceMs: 180,
      thermalPressure: 1,
    );

    expect(quality, lessThan(0.7));
    expect(cooldown, greaterThan(const Duration(milliseconds: 400)));
  });
}
