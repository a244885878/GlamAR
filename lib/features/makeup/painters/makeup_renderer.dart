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
    Set<MakeupPart> excludedParts = const <MakeupPart>{},
  }) {
    if (!excludedParts.contains(MakeupPart.complexion)) {
      FoundationPainter(
        landmarks: landmarks,
        config: look.complexion,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
    if (!excludedParts.contains(MakeupPart.blush)) {
      BlushPainter(
        landmarks: landmarks,
        config: look.blush,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
    if (!excludedParts.contains(MakeupPart.eyeshadow)) {
      EyeshadowPainter(
        landmarks: landmarks,
        config: look.eyeshadow,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
    if (!excludedParts.contains(MakeupPart.brows)) {
      BrowPainter(
        landmarks: landmarks,
        config: look.brows,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
    if (!excludedParts.contains(MakeupPart.eyeliner)) {
      EyelinerPainter(
        landmarks: landmarks,
        config: look.eyeliner,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
    if (!excludedParts.contains(MakeupPart.lips)) {
      LipstickPainter(
        landmarkPixels: landmarks,
        config: look.lips,
        finish: look.lipFinish,
        renderContext: renderContext,
      ).paint(canvas, size);
    }
  }
}
