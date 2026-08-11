import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/utils/ar_frame_timeline.dart';

void main() {
  test('assigns monotonic frame identities and estimates camera cadence', () {
    var now = Duration.zero;
    final timeline = ArFrameTimeline(clock: () => now);

    final first = timeline.markCameraFrame();
    now = const Duration(milliseconds: 33);
    final second = timeline.markCameraFrame();
    now = const Duration(milliseconds: 66);
    final third = timeline.markCameraFrame();

    expect((first.sequence, second.sequence, third.sequence), (1, 2, 3));
    expect(timeline.captureFps, closeTo(30.1, 0.5));
    expect(timeline.framesSince(first), 2);
  });

  test('measures end-to-end latency and expands prediction safely', () {
    var now = Duration.zero;
    final timeline = ArFrameTimeline(clock: () => now);
    final source = timeline.markCameraFrame();

    now = const Duration(milliseconds: 120);
    timeline.markInferenceCompleted(source);

    expect(timeline.pipelineLatencyMs, closeTo(120, 0.01));
    expect(
      timeline.maximumPredictionHorizon,
      greaterThan(const Duration(milliseconds: 120)),
    );
    expect(
      timeline.maximumPredictionHorizon,
      lessThanOrEqualTo(const Duration(milliseconds: 132)),
    );
  });

  test('targets preview presentation slightly before the current vsync', () {
    var now = Duration.zero;
    final timeline = ArFrameTimeline(clock: () => now);
    timeline.markCameraFrame();
    now = const Duration(milliseconds: 33);
    timeline.markCameraFrame();
    now = const Duration(milliseconds: 100);

    expect(timeline.renderTimestamp, lessThan(now));
    final presentationDelay = now - timeline.renderTimestamp;
    expect(
      presentationDelay,
      greaterThanOrEqualTo(const Duration(milliseconds: 4)),
    );
    expect(
      presentationDelay,
      lessThanOrEqualTo(const Duration(milliseconds: 14)),
    );
  });
}
