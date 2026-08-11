import 'dart:math' as math;
import 'dart:ui';

import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// 面向实时 AR 的关键点滤波器。
///
/// 新观测到来时按运动速度自适应抑制抖动；两次推理之间则用头部的平移、
/// 旋转和缩放速度做短时预测，让 15~30 FPS 的模型结果仍能贴着 60 FPS 预览。
class AdaptiveLandmarkSmoother {
  static const _poseAnchors = <int>[1, 10, 33, 152, 234, 263, 454];
  static const defaultMaximumPrediction = Duration(milliseconds: 96);

  final List<Offset> _positions = <Offset>[];
  final List<Offset> _velocities = <Offset>[];
  final Stopwatch _clock = Stopwatch()..start();

  Duration? _lastSourceTimestamp;
  Offset _center = Offset.zero;
  Offset _centerVelocity = Offset.zero;
  double _faceScale = 1;
  double _scaleVelocity = 0;
  double _angle = 0;
  double _angularVelocity = 0;

  bool get hasFace => _positions.length >= 468;

  bool needsPredictionAt(
    Duration timestamp, {
    Duration maximumPrediction = defaultMaximumPrediction,
  }) {
    if (!hasFace || _lastSourceTimestamp == null) return false;
    final elapsed = timestamp - _lastSourceTimestamp!;
    return !elapsed.isNegative && elapsed <= maximumPrediction;
  }

  /// 接收一帧模型观测，并返回补偿到当前显示时刻的关键点。
  List<Offset>? observe({
    required FaceMeshResult mesh,
    required Size targetSize,
    required bool mirrorHorizontal,
    Duration? sourceTimestamp,
    Duration? displayTimestamp,
    Duration maximumPrediction = defaultMaximumPrediction,
  }) {
    if (mesh.landmarks.length < 468 || targetSize.isEmpty) {
      reset();
      return null;
    }

    final timestamp = sourceTimestamp ?? _clock.elapsed;
    final displayTime = displayTimestamp ?? _clock.elapsed;
    final raw = List<Offset>.generate(mesh.landmarks.length, (index) {
      return mesh.landmarkAsOffset(
        mesh.landmarks[index],
        targetSize: targetSize,
        rotationDegrees: 0,
        mirrorHorizontal: mirrorHorizontal,
      );
    }, growable: false);

    if (_positions.length != raw.length || _lastSourceTimestamp == null) {
      _seed(raw, timestamp);
      return predict(
        displayTimestamp: displayTime,
        maximumPrediction: maximumPrediction,
      );
    }

    final elapsed = timestamp - _lastSourceTimestamp!;
    final dt = (elapsed.inMicroseconds / Duration.microsecondsPerSecond).clamp(
      1 / 120,
      0.12,
    );
    final previousCenter = _center;
    final previousScale = _faceScale;
    final previousAngle = _angle;
    final rawCenter = _average(raw, _poseAnchors);
    final rawScale = math.max(1.0, (raw[454] - raw[234]).distance);
    final rawAngle = math.atan2(
      raw[454].dy - raw[234].dy,
      raw[454].dx - raw[234].dx,
    );
    final centerSpeed = (rawCenter - previousCenter).distance / rawScale / dt;
    final scaleRatio = (rawScale / previousScale).clamp(0.76, 1.32);
    final poseRotation = _shortestAngle(
      rawAngle - previousAngle,
    ).clamp(-0.48, 0.48);
    final scaleSpeed = (rawScale - previousScale).abs() / previousScale / dt;
    final rotationSpeed = poseRotation.abs() / dt;
    final poseResponse = math
        .max(
          centerSpeed / 0.72,
          math.max(scaleSpeed / 1.4, rotationSpeed / 2.4),
        )
        .clamp(0.0, 1.0);
    final poseAlpha = 0.34 + poseResponse * 0.58;
    final cosPose = math.cos(poseRotation);
    final sinPose = math.sin(poseRotation);

    for (var i = 0; i < raw.length; i++) {
      final previous = _positions[i];
      final previousRelative = (previous - previousCenter) * scaleRatio;
      final poseAligned =
          rawCenter +
          Offset(
            previousRelative.dx * cosPose - previousRelative.dy * sinPose,
            previousRelative.dx * sinPose + previousRelative.dy * cosPose,
          );
      final coherent = Offset.lerp(previous, poseAligned, poseAlpha)!;
      var residual = raw[i] - poseAligned;
      final residualDistance = residual.distance;
      final maxResidual = rawScale * 0.075;
      if (residualDistance > maxResidual) {
        residual = residual / residualDistance * maxResidual;
      }
      final normalizedSpeed = residualDistance / rawScale / dt;
      final response = (normalizedSpeed / 0.58).clamp(0.0, 1.0);
      final localAlpha = 0.18 + response * 0.74;
      final deadZone = rawScale * 0.00075;
      final next = residualDistance <= deadZone
          ? coherent
          : coherent + residual * localAlpha;
      final measuredVelocity = (next - previous) / dt;
      final velocityAlpha = 0.28 + response * 0.5;
      _velocities[i] = Offset.lerp(
        _velocities[i],
        measuredVelocity,
        velocityAlpha,
      )!;
      _positions[i] = next;
    }

    _center = _average(_positions, _poseAnchors);
    final measuredCenterVelocity = (_center - previousCenter) / dt;
    _centerVelocity = Offset.lerp(
      _centerVelocity,
      measuredCenterVelocity,
      poseAlpha,
    )!;

    _faceScale = math.max(1.0, (_positions[454] - _positions[234]).distance);
    final measuredScaleVelocity = (_faceScale - previousScale) / dt;
    _scaleVelocity = _lerpDouble(
      _scaleVelocity,
      measuredScaleVelocity,
      poseAlpha * 0.72,
    );

    _angle = math.atan2(
      _positions[454].dy - _positions[234].dy,
      _positions[454].dx - _positions[234].dx,
    );
    final angleDelta = _shortestAngle(_angle - previousAngle);
    _angularVelocity = _lerpDouble(
      _angularVelocity,
      angleDelta / dt,
      poseAlpha * 0.72,
    );
    _lastSourceTimestamp = timestamp;
    return predict(
      displayTimestamp: displayTime,
      maximumPrediction: maximumPrediction,
    );
  }

  /// 生成显示时刻的预测结果。预测窗口很短，超过上限会自动钳制以免过冲。
  List<Offset>? predict({
    Duration? displayTimestamp,
    Duration maximumPrediction = defaultMaximumPrediction,
  }) {
    if (!hasFace || _lastSourceTimestamp == null) return null;
    final now = displayTimestamp ?? _clock.elapsed;
    final elapsed = now - _lastSourceTimestamp!;
    final micros = elapsed.inMicroseconds.clamp(
      0,
      maximumPrediction.inMicroseconds,
    );
    final horizon = micros / Duration.microsecondsPerSecond;
    if (horizon == 0) return List<Offset>.unmodifiable(_positions);

    final maxTranslation = _faceScale * 0.095;
    var translation = _centerVelocity * horizon;
    if (translation.distance > maxTranslation) {
      translation = translation / translation.distance * maxTranslation;
    }
    final scaleFactor = (1 + (_scaleVelocity / _faceScale) * horizon).clamp(
      0.94,
      1.06,
    );
    final rotation = (_angularVelocity * horizon).clamp(-0.075, 0.075);
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);

    return List<Offset>.unmodifiable(
      List<Offset>.generate(_positions.length, (index) {
        final relative = (_positions[index] - _center) * scaleFactor;
        final rigid = Offset(
          relative.dx * cosR - relative.dy * sinR,
          relative.dx * sinR + relative.dy * cosR,
        );
        final localVelocity = _velocities[index] - _centerVelocity;
        final localLead = localVelocity * (horizon * 0.16);
        final maxLocalLead = _faceScale * 0.012;
        final clampedLocalLead = localLead.distance > maxLocalLead
            ? localLead / localLead.distance * maxLocalLead
            : localLead;
        return _center + translation + rigid + clampedLocalLead;
      }, growable: false),
    );
  }

  /// 兼容原先的一次调用式 API。
  List<Offset>? smoothToPixelOffsets({
    required FaceMeshResult mesh,
    required Size targetSize,
    required bool mirrorHorizontal,
  }) => observe(
    mesh: mesh,
    targetSize: targetSize,
    mirrorHorizontal: mirrorHorizontal,
  );

  void reset() {
    _positions.clear();
    _velocities.clear();
    _lastSourceTimestamp = null;
    _center = Offset.zero;
    _centerVelocity = Offset.zero;
    _faceScale = 1;
    _scaleVelocity = 0;
    _angle = 0;
    _angularVelocity = 0;
  }

  void _seed(List<Offset> raw, Duration timestamp) {
    _positions
      ..clear()
      ..addAll(raw);
    _velocities
      ..clear()
      ..addAll(List<Offset>.filled(raw.length, Offset.zero));
    _center = _average(raw, _poseAnchors);
    _faceScale = math.max(1.0, (raw[454] - raw[234]).distance);
    _angle = math.atan2(raw[454].dy - raw[234].dy, raw[454].dx - raw[234].dx);
    _lastSourceTimestamp = timestamp;
  }

  static Offset _average(List<Offset> points, List<int> indices) {
    var dx = 0.0;
    var dy = 0.0;
    for (final index in indices) {
      dx += points[index].dx;
      dy += points[index].dy;
    }
    return Offset(dx / indices.length, dy / indices.length);
  }

  static double _shortestAngle(double angle) {
    while (angle > math.pi) {
      angle -= math.pi * 2;
    }
    while (angle < -math.pi) {
      angle += math.pi * 2;
    }
    return angle;
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
}
