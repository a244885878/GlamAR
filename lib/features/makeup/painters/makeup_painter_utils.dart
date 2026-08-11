import 'dart:math' as math;
import 'dart:ui';

abstract final class MakeupPainterUtils {
  static const faceOval = <int>[
    10,
    338,
    297,
    332,
    284,
    251,
    389,
    356,
    454,
    323,
    361,
    288,
    397,
    365,
    379,
    378,
    400,
    377,
    152,
    148,
    176,
    149,
    150,
    136,
    172,
    58,
    132,
    93,
    234,
    127,
    162,
    21,
    54,
    103,
    67,
    109,
  ];

  static const leftEyeUpper = <int>[33, 246, 161, 160, 159, 158, 157, 173, 133];
  static const rightEyeUpper = <int>[
    362,
    398,
    384,
    385,
    386,
    387,
    388,
    466,
    263,
  ];
  static const leftBrow = <int>[70, 63, 105, 66, 107];
  static const rightBrow = <int>[336, 296, 334, 293, 300];

  static bool valid(List<Offset> points) => points.length >= 468;

  static double faceWidth(List<Offset> points) =>
      (points[454] - points[234]).distance;

  static Path closedPath(List<Offset> points, List<int> indices) {
    final path = Path()
      ..moveTo(points[indices.first].dx, points[indices.first].dy);
    for (final index in indices.skip(1)) {
      path.lineTo(points[index].dx, points[index].dy);
    }
    return path..close();
  }

  static Path smoothOpenPath(List<Offset> points, List<int> indices) {
    final path = Path();
    if (indices.isEmpty) return path;
    final first = points[indices.first];
    path.moveTo(first.dx, first.dy);
    for (var i = 1; i < indices.length - 1; i++) {
      final current = points[indices[i]];
      final next = points[indices[i + 1]];
      final mid = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
    }
    final last = points[indices.last];
    path.lineTo(last.dx, last.dy);
    return path;
  }

  static double angle(Offset a, Offset b) =>
      math.atan2(b.dy - a.dy, b.dx - a.dx);
}
