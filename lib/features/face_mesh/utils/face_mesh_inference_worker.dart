import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:glamar/features/face_mesh/utils/low_latency_face_mesh_tracker.dart';
import 'package:glamar/features/face_mesh/utils/nv21_isolate_converter.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

class FaceMeshInferenceSample {
  const FaceMeshInferenceSample({required this.mesh, required this.lighting});

  final FaceMeshResult? mesh;
  final FaceLighting lighting;
}

/// 常驻后台推理 Isolate。相机帧只保留一个在途请求，UI Isolate 不再被 TFLite
/// 和 YUV 转换阻塞。
class FaceMeshInferenceWorker {
  FaceMeshInferenceWorker._({
    required this._isolate,
    required this._receivePort,
    required this._commandPort,
    required this._subscription,
  });

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final SendPort _commandPort;
  final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<FaceMeshInferenceSample>> _pending = {};
  int _nextRequestId = 1;
  bool _closed = false;

  static Future<FaceMeshInferenceWorker> start() async {
    final modelPaths = await _materializeFaceModels();

    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    final startupError = Completer<Object>();
    FaceMeshInferenceWorker? worker;
    late final StreamSubscription<Object?> subscription;
    subscription = receivePort.listen((message) {
      if (message is Map && message['type'] == 'ready') {
        if (!ready.isCompleted) ready.complete(message['port'] as SendPort);
        return;
      }
      if (message is Map &&
          message['type'] == 'startupError' &&
          !startupError.isCompleted) {
        startupError.complete(StateError('${message['error']}'));
        return;
      }
      worker?._handleMessage(message);
    });

    final isolate = await Isolate.spawn<List<Object?>>(
      _faceMeshWorkerMain,
      <Object?>[receivePort.sendPort, modelPaths.detector, modelPaths.mesh],
      debugName: 'GlamARFaceMesh',
    );

    try {
      final commandPort = await Future.any<SendPort>([
        ready.future,
        startupError.future.then<SendPort>((error) => throw error),
      ]).timeout(const Duration(seconds: 35));
      worker = FaceMeshInferenceWorker._(
        isolate: isolate,
        receivePort: receivePort,
        commandPort: commandPort,
        subscription: subscription,
      );
      return worker;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
      rethrow;
    }
  }

  Future<FaceMeshInferenceSample> process(
    CameraImage image, {
    required int rotationDegrees,
    required bool isAndroid,
  }) {
    if (_closed) throw StateError('Face Mesh worker 已关闭');
    final requestId = _nextRequestId++;
    final completer = Completer<FaceMeshInferenceSample>();
    _pending[requestId] = completer;
    final planes = image.planes
        .map((plane) => TransferableTypedData.fromList([plane.bytes]))
        .toList(growable: false);
    _commandPort.send(<String, Object>{
      'type': 'process',
      'id': requestId,
      'android': isAndroid,
      'width': image.width,
      'height': image.height,
      'rotation': rotationDegrees,
      'planes': planes,
      'rowStrides': image.planes
          .map((plane) => plane.bytesPerRow)
          .toList(growable: false),
      'pixelStrides': image.planes
          .map((plane) => plane.bytesPerPixel ?? 1)
          .toList(growable: false),
    });
    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException('单帧人脸推理超时');
      },
    );
  }

  void reset() {
    if (!_closed) _commandPort.send(const <String, Object>{'type': 'reset'});
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _commandPort.send(const <String, Object>{'type': 'close'});
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Face Mesh worker 已关闭'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  void _handleMessage(Object? message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['type'] == 'error') {
      completer.completeError(StateError('${message['error']}'));
      return;
    }
    final encoded = message['mesh'];
    final lighting = _decodeLighting(message['lighting']);
    completer.complete(
      FaceMeshInferenceSample(
        mesh: encoded is Map ? _decodeMesh(encoded) : null,
        lighting: lighting,
      ),
    );
  }

  static FaceLighting _decodeLighting(Object? encoded) {
    if (encoded is! Float32List || encoded.length < 4) {
      return FaceLighting.neutral;
    }
    return FaceLighting(
      exposure: encoded[0],
      sideAExposure: encoded[1],
      sideBExposure: encoded[2],
      warmth: encoded[3],
      skinChroma: encoded.length > 4 ? encoded[4] : 0.18,
      localContrast: encoded.length > 5 ? encoded[5] : 0.16,
    );
  }

  static FaceMeshResult _decodeMesh(Map<dynamic, dynamic> encoded) {
    final values = encoded['landmarks'] as Float32List;
    final landmarks = List<FaceMeshLandmark>.generate(
      values.length ~/ 3,
      (index) => FaceMeshLandmark(
        x: values[index * 3],
        y: values[index * 3 + 1],
        z: values[index * 3 + 2],
      ),
      growable: false,
    );
    final rect = encoded['rect'] as Float64List;
    return FaceMeshResult(
      landmarks: landmarks,
      rect: NormalizedRect(
        xCenter: rect[0],
        yCenter: rect[1],
        width: rect[2],
        height: rect[3],
        rotation: rect[4],
      ),
      score: encoded['score'] as double,
      imageWidth: encoded['imageWidth'] as int,
      imageHeight: encoded['imageHeight'] as int,
    );
  }
}

Future<void> _faceMeshWorkerMain(List<Object?> bootstrap) async {
  final resultPort = bootstrap[0]! as SendPort;
  final detectorModelPath = bootstrap[1]! as String;
  final meshModelPath = bootstrap[2]! as String;
  final commandPort = ReceivePort();

  FaceDetectorProcessor? detector;
  FaceMeshProcessor? mesh;
  try {
    detector = await _createDetector(detectorModelPath);
    mesh = await _createMesh(meshModelPath);
  } catch (error) {
    detector?.close();
    mesh?.close();
    resultPort.send(<String, Object>{
      'type': 'startupError',
      'error': '$error',
    });
    commandPort.close();
    return;
  }

  final tracker = LowLatencyFaceMeshTracker(detector, mesh);
  resultPort.send(<String, Object>{
    'type': 'ready',
    'port': commandPort.sendPort,
  });

  await for (final Object? rawMessage in commandPort) {
    if (rawMessage is! Map) continue;
    final type = rawMessage['type'];
    if (type == 'close') break;
    if (type == 'reset') {
      tracker.reset();
      continue;
    }
    if (type != 'process') continue;
    final id = rawMessage['id'] as int;
    try {
      final sample = _processWorkerFrame(rawMessage, tracker);
      resultPort.send(<String, Object?>{
        'type': 'result',
        'id': id,
        'mesh': sample.mesh == null ? null : _encodeMesh(sample.mesh!),
        'lighting': _encodeLighting(sample.lighting),
      });
    } catch (error) {
      tracker.reset();
      resultPort.send(<String, Object>{
        'type': 'error',
        'id': id,
        'error': '$error',
      });
    }
  }

  detector.close();
  mesh.close();
  commandPort.close();
}

Future<FaceDetectorProcessor> _createDetector(String modelPath) =>
    _createWithFallback(
      (delegate) => FaceDetectorProcessor.createFromModelPath(
        modelPath,
        model: FaceDetectionModel.shortRange,
        delegate: delegate,
        threads: 4,
        allowDelegateFallback: false,
        maxResults: 1,
        roiScaleY: 1.7,
        roiShiftY: -0.2,
      ),
    );

Future<FaceMeshProcessor> _createMesh(String modelPath) => _createWithFallback(
  (delegate) => FaceMeshProcessor.createFromModelPath(
    modelPath,
    delegate: delegate,
    threads: 4,
    allowDelegateFallback: false,
    minTrackingConfidence: 0.5,
    enableSmoothing: false,
    enableRoiTracking: true,
    enableIris: false,
  ),
);

const _detectorModelAsset =
    'packages/mediapipe_face_mesh/assets/models/face_detection_short_range.tflite';
const _meshModelAsset =
    'packages/mediapipe_face_mesh/assets/models/mediapipe_face_mesh.tflite';

Future<({String detector, String mesh})> _materializeFaceModels() async {
  final cache = Directory('${Directory.systemTemp.path}/glamar_face_models');
  await cache.create(recursive: true);
  final detector = await _materializeModelAsset(
    _detectorModelAsset,
    File('${cache.path}/face_detection_short_range.tflite'),
  );
  final mesh = await _materializeModelAsset(
    _meshModelAsset,
    File('${cache.path}/mediapipe_face_mesh.tflite'),
  );
  return (detector: detector, mesh: mesh);
}

Future<String> _materializeModelAsset(String asset, File target) async {
  final data = await rootBundle.load(asset);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (!await target.exists() || await target.length() != bytes.length) {
    await target.writeAsBytes(bytes, flush: true);
  }
  return target.path;
}

Future<T> _createWithFallback<T>(
  Future<T> Function(FaceMeshDelegate delegate) create,
) async {
  // 后台 Isolate 使用 XNNPACK，避免部分机型 GPU delegate 的线程亲和限制。
  const delegates = [FaceMeshDelegate.xnnpack, FaceMeshDelegate.cpu];
  Object? lastError;
  for (final delegate in delegates) {
    try {
      return await create(delegate).timeout(const Duration(seconds: 20));
    } catch (error) {
      lastError = error;
    }
  }
  throw StateError('无法初始化人脸模型：$lastError');
}

({FaceMeshResult? mesh, FaceLighting lighting}) _processWorkerFrame(
  Map<dynamic, dynamic> message,
  LowLatencyFaceMeshTracker tracker,
) {
  final width = message['width'] as int;
  final height = message['height'] as int;
  final rotation = message['rotation'] as int;
  final rowStrides = (message['rowStrides'] as List).cast<int>();
  final pixelStrides = (message['pixelStrides'] as List).cast<int>();
  final transferred = (message['planes'] as List).cast<TransferableTypedData>();
  final planes = transferred
      .map((data) => data.materialize().asUint8List())
      .toList(growable: false);

  if (message['android'] as bool) {
    final image = _toNv21(
      planes,
      width: width,
      height: height,
      rowStrides: rowStrides,
      pixelStrides: pixelStrides,
    );
    if (image == null) {
      return (mesh: null, lighting: FaceLighting.neutral);
    }
    final mesh = tracker.processNv21(image, rotationDegrees: rotation);
    return (
      mesh: mesh,
      lighting: mesh == null
          ? FaceLighting.neutral
          : _analyzeNv21Lighting(image, mesh, rotation),
    );
  }

  if (planes.isEmpty) {
    return (mesh: null, lighting: FaceLighting.neutral);
  }
  final image = FaceMeshImage(
    pixels: planes.first,
    width: width,
    height: height,
    bytesPerRow: rowStrides.first,
    pixelFormat: FaceMeshPixelFormat.bgra,
  );
  final mesh = tracker.processBgra(image, rotationDegrees: rotation);
  return (
    mesh: mesh,
    lighting: mesh == null
        ? FaceLighting.neutral
        : _analyzeBgraLighting(image, mesh, rotation),
  );
}

FaceMeshNv21Image? _toNv21(
  List<Uint8List> planes, {
  required int width,
  required int height,
  required List<int> rowStrides,
  required List<int> pixelStrides,
}) {
  if (planes.isEmpty || width.isOdd || height.isOdd) return null;
  if (planes.length == 1) {
    final rowStride = rowStrides.first;
    final ySize = rowStride * height;
    final vuSize = rowStride * (height ~/ 2);
    if (planes.first.length < ySize + vuSize) return null;
    return FaceMeshNv21Image(
      yPlane: Uint8List.sublistView(planes.first, 0, ySize),
      vuPlane: Uint8List.sublistView(planes.first, ySize, ySize + vuSize),
      width: width,
      height: height,
      yBytesPerRow: rowStride,
      vuBytesPerRow: rowStride,
    );
  }
  if (planes.length >= 3) {
    return convertNv21InIsolate(
      Nv21ConvertRequest(
        width: width,
        height: height,
        yPlane: planes[0],
        yBytesPerRow: rowStrides[0],
        uPlane: planes[1],
        uBytesPerRow: rowStrides[1],
        uPixelStride: pixelStrides[1],
        vPlane: planes[2],
        vBytesPerRow: rowStrides[2],
        vPixelStride: pixelStrides[2],
      ),
    );
  }
  if (planes.length == 2) {
    final y = _copyPlane(
      planes[0],
      width,
      height,
      rowStrides[0],
      pixelStrides[0],
    );
    final vu = _copyPlane(
      planes[1],
      width,
      height ~/ 2,
      rowStrides[1],
      pixelStrides[1],
    );
    return FaceMeshNv21Image(
      yPlane: y,
      vuPlane: vu,
      width: width,
      height: height,
      yBytesPerRow: width,
      vuBytesPerRow: width,
    );
  }
  return null;
}

Uint8List _copyPlane(
  Uint8List source,
  int width,
  int height,
  int rowStride,
  int pixelStride,
) {
  final output = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    for (var column = 0; column < width; column++) {
      output[row * width + column] =
          source[row * rowStride + column * pixelStride];
    }
  }
  return output;
}

Map<String, Object> _encodeMesh(FaceMeshResult result) {
  final values = Float32List(result.landmarks.length * 3);
  for (var index = 0; index < result.landmarks.length; index++) {
    final point = result.landmarks[index];
    values[index * 3] = point.x;
    values[index * 3 + 1] = point.y;
    values[index * 3 + 2] = point.z;
  }
  return <String, Object>{
    'landmarks': values,
    'rect': Float64List.fromList([
      result.rect.xCenter,
      result.rect.yCenter,
      result.rect.width,
      result.rect.height,
      result.rect.rotation,
    ]),
    'score': result.score,
    'imageWidth': result.imageWidth,
    'imageHeight': result.imageHeight,
  };
}

Float32List _encodeLighting(FaceLighting lighting) => Float32List.fromList([
  lighting.exposure,
  lighting.sideAExposure,
  lighting.sideBExposure,
  lighting.warmth,
  lighting.skinChroma,
  lighting.localContrast,
]);

FaceLighting _analyzeNv21Lighting(
  FaceMeshNv21Image image,
  FaceMeshResult mesh,
  int rotation,
) {
  return _analyzeLighting(mesh, (x, y) {
    final raw = _logicalToRaw(x, y, rotation);
    final px = (raw.$1 * (image.width - 1)).round().clamp(0, image.width - 1);
    final py = (raw.$2 * (image.height - 1)).round().clamp(0, image.height - 1);
    final yIndex = py * image.yBytesPerRow + px;
    if (yIndex < 0 || yIndex >= image.yPlane.length) return null;
    final luma = ((image.yPlane[yIndex] - 16) / 219).clamp(0.0, 1.0);
    final uvIndex = (py ~/ 2) * image.vuBytesPerRow + (px ~/ 2) * 2;
    var warmth = 0.0;
    var u = 128;
    var v = 128;
    if (uvIndex + 1 < image.vuPlane.length) {
      v = image.vuPlane[uvIndex];
      u = image.vuPlane[uvIndex + 1];
      warmth = ((v - u) / 170).clamp(-1.0, 1.0);
    }
    final uDelta = (u - 128) / 128;
    final vDelta = (v - 128) / 128;
    final chroma = math.sqrt(uDelta * uDelta + vDelta * vDelta).clamp(0.0, 1.0);
    return (luma: luma, warmth: warmth, chroma: chroma);
  });
}

FaceLighting _analyzeBgraLighting(
  FaceMeshImage image,
  FaceMeshResult mesh,
  int rotation,
) {
  return _analyzeLighting(mesh, (x, y) {
    final raw = _logicalToRaw(x, y, rotation);
    final px = (raw.$1 * (image.width - 1)).round().clamp(0, image.width - 1);
    final py = (raw.$2 * (image.height - 1)).round().clamp(0, image.height - 1);
    final index = py * image.bytesPerRow + px * 4;
    if (index < 0 || index + 2 >= image.pixels.length) return null;
    final blue = image.pixels[index] / 255;
    final green = image.pixels[index + 1] / 255;
    final red = image.pixels[index + 2] / 255;
    final luma = red * 0.2126 + green * 0.7152 + blue * 0.0722;
    final maximum = math.max(red, math.max(green, blue));
    final minimum = math.min(red, math.min(green, blue));
    return (
      luma: luma,
      warmth: ((red - blue) * 1.55).clamp(-1.0, 1.0),
      chroma: (maximum - minimum).clamp(0.0, 1.0),
    );
  });
}

FaceLighting _analyzeLighting(
  FaceMeshResult mesh,
  ({double luma, double warmth, double chroma})? Function(double x, double y)
  sample,
) {
  final points = mesh.landmarks;
  var minX = 1.0;
  var maxX = 0.0;
  var minY = 1.0;
  var maxY = 0.0;
  for (final point in points) {
    minX = point.x < minX ? point.x : minX;
    maxX = point.x > maxX ? point.x : maxX;
    minY = point.y < minY ? point.y : minY;
    maxY = point.y > maxY ? point.y : maxY;
  }
  final width = maxX - minX;
  final height = maxY - minY;
  if (width <= 0 || height <= 0) return FaceLighting.neutral;
  minX += width * 0.12;
  maxX -= width * 0.12;
  minY += height * 0.16;
  maxY -= height * 0.1;
  final centerX = (minX + maxX) * 0.5;
  final featureRegions = _lightingFeatureRegions(points);

  var total = 0.0;
  var warmth = 0.0;
  var chroma = 0.0;
  var lumaSquared = 0.0;
  var count = 0;
  var leftTotal = 0.0;
  var leftCount = 0;
  var rightTotal = 0.0;
  var rightCount = 0;
  for (var row = 0; row < 9; row++) {
    final y = minY + (maxY - minY) * (row + 0.5) / 9;
    for (var column = 0; column < 11; column++) {
      final x = minX + (maxX - minX) * (column + 0.5) / 11;
      final dx = (x - centerX) / ((maxX - minX) * 0.5);
      final dy = (y - (minY + maxY) * 0.5) / ((maxY - minY) * 0.5);
      if (dx * dx + dy * dy > 0.92) continue;
      // Skin statistics must not be biased by naturally dark eyes/brows or
      // saturated lips. This is especially important for chroma and local
      // contrast guards, which otherwise make the makeup breathe on blinks.
      if (_insideFeatureRegion(featureRegions, x, y)) continue;
      final value = sample(x, y);
      if (value == null) continue;
      total += value.luma;
      warmth += value.warmth;
      chroma += value.chroma;
      lumaSquared += value.luma * value.luma;
      count++;
      if (x < centerX) {
        leftTotal += value.luma;
        leftCount++;
      } else {
        rightTotal += value.luma;
        rightCount++;
      }
    }
  }
  if (count == 0) return FaceLighting.neutral;
  final average = total / count;
  final variance = math.max(0, lumaSquared / count - average * average);
  final left = leftCount == 0 ? average : leftTotal / leftCount;
  final right = rightCount == 0 ? average : rightTotal / rightCount;
  final sideAOnLeft = points.length > 117 && points[117].x < centerX;
  return FaceLighting(
    exposure: average,
    sideAExposure: sideAOnLeft ? left : right,
    sideBExposure: sideAOnLeft ? right : left,
    warmth: (warmth / count).clamp(-1.0, 1.0),
    skinChroma: (chroma / count).clamp(0.0, 1.0),
    localContrast: math.sqrt(variance).clamp(0.0, 1.0),
  );
}

typedef _LightingFeatureRegion = ({
  double centerX,
  double centerY,
  double radiusX,
  double radiusY,
});

List<_LightingFeatureRegion> _lightingFeatureRegions(
  List<FaceMeshLandmark> points,
) {
  if (points.length < 468) return const <_LightingFeatureRegion>[];
  return <_LightingFeatureRegion>[
    _landmarkEllipse(points, 33, 133, 0.72, 0.36),
    _landmarkEllipse(points, 362, 263, 0.72, 0.36),
    _landmarkEllipse(points, 61, 291, 0.62, 0.27),
  ];
}

_LightingFeatureRegion _landmarkEllipse(
  List<FaceMeshLandmark> points,
  int firstIndex,
  int secondIndex,
  double radiusXScale,
  double radiusYScale,
) {
  final first = points[firstIndex];
  final second = points[secondIndex];
  final centerX = (first.x + second.x) * 0.5;
  final centerY = (first.y + second.y) * 0.5;
  final spanX = first.x - second.x;
  final spanY = first.y - second.y;
  final width = math.max(math.sqrt(spanX * spanX + spanY * spanY), 0.0001);
  return (
    centerX: centerX,
    centerY: centerY,
    radiusX: width * radiusXScale,
    radiusY: width * radiusYScale,
  );
}

bool _insideFeatureRegion(
  List<_LightingFeatureRegion> regions,
  double x,
  double y,
) {
  for (final region in regions) {
    final normalizedX = (x - region.centerX) / region.radiusX;
    final normalizedY = (y - region.centerY) / region.radiusY;
    if (normalizedX * normalizedX + normalizedY * normalizedY <= 1) {
      return true;
    }
  }
  return false;
}

(double, double) _logicalToRaw(double x, double y, int rotation) {
  return switch (rotation) {
    90 => (y, 1 - x),
    180 => (1 - x, 1 - y),
    270 => (1 - y, x),
    _ => (x, y),
  };
}
