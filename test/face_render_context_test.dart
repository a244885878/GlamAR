import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

void main() {
  test('reduces makeup opacity on the foreshortened face side', () {
    final mesh = _mesh(
      sideAInnerX: 0.31,
      sideAEdgeX: 0.28,
      sideBInnerX: 0.61,
      sideBEdgeX: 0.78,
    );
    final context = FaceRenderContext.fromMesh(mesh, FaceLighting.neutral);

    expect(context.sideAVisibility, lessThan(context.sideBVisibility));
    expect(
      context.opacityForSide(sideA: true),
      lessThan(context.opacityForSide(sideA: false)),
    );
  });

  test('uses per-side exposure without changing mesh geometry', () {
    final mesh = _mesh();
    final original = mesh.landmarks
        .map((point) => (point.x, point.y, point.z))
        .toList(growable: false);
    final context = FaceRenderContext.fromMesh(
      mesh,
      const FaceLighting(
        exposure: 0.48,
        sideAExposure: 0.22,
        sideBExposure: 0.82,
      ),
    );

    expect(
      context.opacityForSide(sideA: true),
      lessThan(context.opacityForSide(sideA: false)),
    );
    expect(
      mesh.landmarks.map((point) => (point.x, point.y, point.z)),
      orderedEquals(original),
    );
  });

  test('warmth adaptation stays subtle', () {
    const source = Color(0xFFB73255);
    const context = FaceRenderContext(lighting: FaceLighting(warmth: 1));

    final adapted = context.adaptColor(source);
    expect(adapted, isNot(source));
    expect((adapted.r - source.r).abs(), lessThan(0.08));
    expect((adapted.g - source.g).abs(), lessThan(0.08));
    expect((adapted.b - source.b).abs(), lessThan(0.08));
  });
}

FaceMeshResult _mesh({
  double sideAInnerX = 0.37,
  double sideAEdgeX = 0.27,
  double sideBInnerX = 0.63,
  double sideBEdgeX = 0.73,
}) {
  final landmarks = List<FaceMeshLandmark>.generate(
    468,
    (_) => FaceMeshLandmark(x: 0.5, y: 0.5, z: 0),
    growable: false,
  );
  landmarks[117] = FaceMeshLandmark(x: sideAInnerX, y: 0.5, z: 0);
  landmarks[234] = FaceMeshLandmark(x: sideAEdgeX, y: 0.5, z: 0);
  landmarks[346] = FaceMeshLandmark(x: sideBInnerX, y: 0.5, z: 0);
  landmarks[454] = FaceMeshLandmark(x: sideBEdgeX, y: 0.5, z: 0);
  return FaceMeshResult(
    landmarks: landmarks,
    rect: const NormalizedRect(
      xCenter: 0.5,
      yCenter: 0.5,
      width: 0.5,
      height: 0.7,
    ),
    score: 0.99,
    imageWidth: 1000,
    imageHeight: 1000,
  );
}
