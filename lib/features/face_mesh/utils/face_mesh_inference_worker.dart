import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:glamar/features/face_mesh/utils/low_latency_face_mesh_tracker.dart';
import 'package:glamar/features/face_mesh/utils/nv21_isolate_converter.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

/// 常驻后台推理 Isolate。相机帧只保留一个在途请求，UI Isolate 不再被 TFLite
/// 和 YUV 转换阻塞。
class FaceMeshInferenceWorker {
  FaceMeshInferenceWorker._({
    required Isolate isolate,
    required ReceivePort receivePort,
    required SendPort commandPort,
    required StreamSubscription<Object?> subscription,
  }) : _isolate = isolate,
       _receivePort = receivePort,
       _commandPort = commandPort,
       _subscription = subscription;

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final SendPort _commandPort;
  final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<FaceMeshResult?>> _pending = {};
  int _nextRequestId = 1;
  bool _closed = false;

  static Future<FaceMeshInferenceWorker> start() async {
    final rootToken = RootIsolateToken.instance;
    if (rootToken == null) {
      throw StateError('无法取得 Flutter RootIsolateToken');
    }

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
      <Object?>[receivePort.sendPort, rootToken],
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

  Future<FaceMeshResult?> process(
    CameraImage image, {
    required int rotationDegrees,
    required bool isAndroid,
  }) {
    if (_closed) throw StateError('Face Mesh worker 已关闭');
    final requestId = _nextRequestId++;
    final completer = Completer<FaceMeshResult?>();
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
    completer.complete(encoded is Map ? _decodeMesh(encoded) : null);
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
  final rootToken = bootstrap[1]! as RootIsolateToken;
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
  final commandPort = ReceivePort();

  FaceDetectorProcessor? detector;
  FaceMeshProcessor? mesh;
  try {
    detector = await _createDetector();
    mesh = await _createMesh();
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

  final tracker = LowLatencyFaceMeshTracker(detector: detector, mesh: mesh);
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
      final result = _processWorkerFrame(rawMessage, tracker);
      resultPort.send(<String, Object?>{
        'type': 'result',
        'id': id,
        'mesh': result == null ? null : _encodeMesh(result),
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

Future<FaceDetectorProcessor> _createDetector() => _createWithFallback(
  (delegate) => FaceDetectorProcessor.create(
    model: FaceDetectionModel.shortRange,
    delegate: delegate,
    threads: 4,
    allowDelegateFallback: false,
    maxResults: 1,
    roiScaleY: 1.7,
    roiShiftY: -0.2,
  ),
);

Future<FaceMeshProcessor> _createMesh() => _createWithFallback(
  (delegate) => FaceMeshProcessor.create(
    delegate: delegate,
    threads: 4,
    allowDelegateFallback: false,
    minTrackingConfidence: 0.5,
    enableSmoothing: false,
    enableRoiTracking: true,
    enableIris: false,
  ),
);

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

FaceMeshResult? _processWorkerFrame(
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
    if (image == null) return null;
    return tracker.processNv21(image, rotationDegrees: rotation);
  }

  if (planes.isEmpty) return null;
  return tracker.processBgra(
    FaceMeshImage(
      pixels: planes.first,
      width: width,
      height: height,
      bytesPerRow: rowStrides.first,
      pixelFormat: FaceMeshPixelFormat.bgra,
    ),
    rotationDegrees: rotation,
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
