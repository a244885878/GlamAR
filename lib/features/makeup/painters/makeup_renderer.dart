import 'dart:ui';

import 'package:glamar/features/face_mesh/painters/lipstick_painter.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/blush_painter.dart';
import 'package:glamar/features/makeup/painters/brow_painter.dart';
import 'package:glamar/features/makeup/painters/eyeliner_painter.dart';
import 'package:glamar/features/makeup/painters/eyeshadow_painter.dart';
import 'package:glamar/features/makeup/painters/foundation_painter.dart';

abstract final class MakeupRenderer {
  static void paintAll(
    Canvas canvas,
    Size size,
    List<Offset> landmarks,
    MakeupLook look,
  ) {
    FoundationPainter(
      landmarks: landmarks,
      config: look.complexion,
    ).paint(canvas, size);
    BlushPainter(landmarks: landmarks, config: look.blush).paint(canvas, size);
    EyeshadowPainter(
      landmarks: landmarks,
      config: look.eyeshadow,
    ).paint(canvas, size);
    BrowPainter(landmarks: landmarks, config: look.brows).paint(canvas, size);
    EyelinerPainter(
      landmarks: landmarks,
      config: look.eyeliner,
    ).paint(canvas, size);
    LipstickPainter(
      landmarkPixels: landmarks,
      config: look.lips,
      finish: look.lipFinish,
    ).paint(canvas, size);
  }
}
