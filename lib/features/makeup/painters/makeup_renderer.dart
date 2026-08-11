import 'dart:ui';

import 'package:glamar/features/face_mesh/painters/lipstick_painter.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
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
    MakeupLook look, {
    FaceRenderContext renderContext = const FaceRenderContext.neutral(),
  }) {
    FoundationPainter(
      landmarks: landmarks,
      config: look.complexion,
      renderContext: renderContext,
    ).paint(canvas, size);
    BlushPainter(
      landmarks: landmarks,
      config: look.blush,
      renderContext: renderContext,
    ).paint(canvas, size);
    EyeshadowPainter(
      landmarks: landmarks,
      config: look.eyeshadow,
      renderContext: renderContext,
    ).paint(canvas, size);
    BrowPainter(
      landmarks: landmarks,
      config: look.brows,
      renderContext: renderContext,
    ).paint(canvas, size);
    EyelinerPainter(
      landmarks: landmarks,
      config: look.eyeliner,
      renderContext: renderContext,
    ).paint(canvas, size);
    LipstickPainter(
      landmarkPixels: landmarks,
      config: look.lips,
      finish: look.lipFinish,
      renderContext: renderContext,
    ).paint(canvas, size);
  }
}
