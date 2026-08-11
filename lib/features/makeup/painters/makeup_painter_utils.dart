import 'dart:math' as math;
import 'dart:ui';

import 'package:glamar/features/face_mesh/utils/lip_landmark_indices.dart';

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
  static const leftEyeContour = <int>[
    33,
    7,
    163,
    144,
    145,
    153,
    154,
    155,
    133,
    173,
    157,
    158,
    159,
    160,
    161,
    246,
  ];
  static const rightEyeContour = <int>[
    362,
    382,
    381,
    380,
    374,
    373,
    390,
    249,
    263,
    466,
    388,
    387,
    386,
    385,
    384,
    398,
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

  static Path smoothClosedPath(List<Offset> points, List<int> indices) {
    if (indices.length < 3) return closedPath(points, indices);
    final path = Path();
    final first = points[indices.first];
    final second = points[indices[1]];
    path.moveTo((first.dx + second.dx) / 2, (first.dy + second.dy) / 2);
    for (var index = 1; index <= indices.length; index++) {
      final current = points[indices[index % indices.length]];
      final next = points[indices[(index + 1) % indices.length]];
      path.quadraticBezierTo(
        current.dx,
        current.dy,
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
    }
    return path..close();
  }

  static Path smoothClosedOffsets(List<Offset> points) {
    if (points.length < 3) {
      final path = Path();
      if (points.isNotEmpty) path.moveTo(points.first.dx, points.first.dy);
      return path;
    }
    final path = Path();
    final first = points.first;
    final second = points[1];
    path.moveTo((first.dx + second.dx) / 2, (first.dy + second.dy) / 2);
    for (var index = 1; index <= points.length; index++) {
      final current = points[index % points.length];
      final next = points[(index + 1) % points.length];
      path.quadraticBezierTo(
        current.dx,
        current.dy,
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
    }
    return path..close();
  }

  static Path lipPath(List<Offset> points) {
    final outer = smoothClosedPath(points, LipLandmarkIndices.outerLip);
    final inner = smoothClosedPath(points, LipLandmarkIndices.innerLip);
    return Path.combine(PathOperation.difference, outer, inner);
  }

  /// 面部皮肤蒙版：保留脸部轮廓，同时挖掉眼睛和嘴唇，供底妆与像素柔化共用。
  static Path skinPath(List<Offset> points, {double featurePadding = 0}) {
    final face = closedPath(points, faceOval);
    final protectedFeatures = Path();
    for (final eyeIndices in <List<int>>[leftEyeContour, rightEyeContour]) {
      final eye = closedPath(points, eyeIndices);
      protectedFeatures.addOval(eye.getBounds().inflate(featurePadding));
    }
    for (final browIndices in <List<int>>[leftBrow, rightBrow]) {
      final brow = smoothOpenPath(points, browIndices);
      protectedFeatures.addRRect(
        RRect.fromRectAndRadius(
          brow.getBounds().inflate(featurePadding * 0.72),
          Radius.circular(featurePadding),
        ),
      );
    }
    protectedFeatures.addPath(
      smoothClosedPath(points, LipLandmarkIndices.outerLip),
      Offset.zero,
    );
    return Path.combine(PathOperation.difference, face, protectedFeatures);
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
