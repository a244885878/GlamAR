import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/models/makeup_response_curve.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';

void main() {
  test('intensity response is bounded, monotonic and continuous', () {
    for (final part in MakeupPart.values) {
      expect(MakeupResponseCurve.intensity(part, -1), 0);
      expect(MakeupResponseCurve.intensity(part, 0), 0);
      expect(MakeupResponseCurve.intensity(part, 1), 1);
      expect(MakeupResponseCurve.intensity(part, 2), 1);
      expect(MakeupResponseCurve.maximumStep(part), lessThan(0.014));

      var previous = 0.0;
      for (var sample = 1; sample <= 100; sample++) {
        final current = MakeupResponseCurve.intensity(part, sample / 100);
        expect(current, greaterThan(previous));
        previous = current;
      }
    }
  });

  test('part-specific response preserves natural control hierarchy', () {
    final complexion = MakeupResponseCurve.intensity(
      MakeupPart.complexion,
      0.5,
    );
    final eyeliner = MakeupResponseCurve.intensity(MakeupPart.eyeliner, 0.5);

    expect(complexion, greaterThan(0.5));
    expect(complexion, greaterThan(eyeliner));
    expect(eyeliner, lessThan(0.54));
  });

  test('detail response has stable endpoints and a smooth midpoint', () {
    expect(MakeupResponseCurve.detail(-1), 0);
    expect(MakeupResponseCurve.detail(0), 0);
    expect(MakeupResponseCurve.detail(0.5), closeTo(0.5, 0.000001));
    expect(MakeupResponseCurve.detail(1), 1);
    expect(MakeupResponseCurve.detail(2), 1);

    var previous = 0.0;
    for (var sample = 1; sample <= 100; sample++) {
      final current = MakeupResponseCurve.detail(sample / 100);
      expect(current, greaterThan(previous));
      previous = current;
    }
  });

  test('material state calibrates a copy without mutating UI values', () {
    final source = MakeupLibrary.looks.first;
    final originalIntensity = source.lips.intensity;
    final originalDetail = source.lips.detail;
    final material = ArMakeupMaterialState.fromLook(source);

    expect(source.lips.intensity, originalIntensity);
    expect(source.lips.detail, originalDetail);
    expect(
      material.look.lips.intensity,
      MakeupResponseCurve.intensity(MakeupPart.lips, originalIntensity),
    );
    expect(
      material.look.lips.detail,
      MakeupResponseCurve.detail(originalDetail),
    );
  });
}
