import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:glamar/features/face_mesh/utils/nv21_isolate_converter.dart';
import 'package:glamar/features/face_mesh/utils/occlusion_mask_postprocessor.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

const _modelSize = 256;
const _classCount = 6;
const _modelAsset = 'assets/models/selfie_multiclass_256x256.tflite';

class FaceOcclusionRoi {
  const FaceOcclusionRoi({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  bool isAlignedWith(FaceOcclusionRoi other) {
    final referenceWidth = width > other.width ? width : other.width;
    final referenceHeight = height > other.height ? height : other.height;
    if (referenceWidth <= 0 || referenceHeight <= 0) return false;
    final centerX = left + width * 0.5;
    final centerY = top + height * 0.5;
    final otherCenterX = other.left + other.width * 0.5;
    final otherCenterY = other.top + other.height * 0.5;
    final shiftX = (centerX - otherCenterX).abs() / referenceWidth;
    final shiftY = (centerY - otherCenterY).abs() / referenceHeight;
    final widthChange = (width - other.width).abs() / referenceWidth;
    final heightChange = (height - other.height).abs() / referenceHeight;
    return shiftX <= 0.22 &&
        shiftY <= 0.22 &&
        widthChange <= 0.24 &&
        heightChange <= 0.24;
  }

  Float64List encode() => Float64List.fromList([left, top, width, height]);

  static FaceOcclusionRoi decode(Float64List values) => FaceOcclusionRoi(
    left: values[0],
    top: values[1],
    width: values[2],
    height: values[3],
  );
}

class FaceOcclusionMask {
  const FaceOcclusionMask({
    required this.rgba,
    required this.roi,
    required this.inferenceDuration,
  });

  final Uint8List rgba;
  final FaceOcclusionRoi roi;
  final Duration inferenceDuration;
}

/// 独立于 FaceMesh 的低频遮挡推理 Isolate。多类别分割较重，不得与关键点
/// 跟踪串行，否则会直接增加跟脸延迟。
class FaceOcclusionInferenceWorker {
  FaceOcclusionInferenceWorker._({
    required this._isolate,
    required this._receivePort,
    required this._commandPort,
    required this._subscription,
  });

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final SendPort _commandPort;
  final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<FaceOcclusionMask>> _pending = {};
  var _nextRequestId = 1;
  var _closed = false;

  static Future<FaceOcclusionInferenceWorker> start() async {
    final modelData = await rootBundle.load(_modelAsset);
    final model = TransferableTypedData.fromList([
      modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      ),
    ]);
    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    final startupError = Completer<Object>();
    FaceOcclusionInferenceWorker? worker;
    late final StreamSubscription<Object?> subscription;
    subscription = receivePort.listen((message) {
      if (message is Map && message['type'] == 'ready') {
        if (!ready.isCompleted) ready.complete(message['port'] as SendPort);
        return;
      }
      if (message is Map && message['type'] == 'startupError') {
        if (!startupError.isCompleted) {
          startupError.complete(StateError('${message['error']}'));
        }
        return;
      }
      worker?._handleMessage(message);
    });
    final isolate = await Isolate.spawn<List<Object?>>(
      _occlusionWorkerMain,
      <Object?>[receivePort.sendPort, model],
      debugName: 'GlamAROcclusion',
    );
    try {
      final commandPort = await Future.any<SendPort>([
        ready.future,
        startupError.future.then<SendPort>((error) => throw error),
      ]).timeout(const Duration(seconds: 35));
      worker = FaceOcclusionInferenceWorker._(
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

  Future<FaceOcclusionMask> processCameraImage(
    CameraImage image, {
    required int rotationDegrees,
    required bool isAndroid,
    required FaceOcclusionRoi roi,
  }) {
    final planes = image.planes
        .map((plane) => TransferableTypedData.fromList([plane.bytes]))
        .toList(growable: false);
    return _send(<String, Object>{
      'kind': 'camera',
      'android': isAndroid,
      'width': image.width,
      'height': image.height,
      'rotation': rotationDegrees,
      'roi': roi.encode(),
      'planes': planes,
      'rowStrides': image.planes
          .map((plane) => plane.bytesPerRow)
          .toList(growable: false),
      'pixelStrides': image.planes
          .map((plane) => plane.bytesPerPixel ?? 1)
          .toList(growable: false),
    });
  }

  Future<FaceOcclusionMask> processRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    required FaceOcclusionRoi roi,
  }) {
    return _send(<String, Object>{
      'kind': 'rgba',
      'width': width,
      'height': height,
      'rotation': 0,
      'roi': roi.encode(),
      'rgba': TransferableTypedData.fromList([rgba]),
    });
  }

  Future<FaceOcclusionMask> _send(Map<String, Object> payload) {
    if (_closed) throw StateError('遮挡模型已关闭');
    final id = _nextRequestId++;
    final completer = Completer<FaceOcclusionMask>();
    _pending[id] = completer;
    _commandPort.send(<String, Object>{
      'type': 'process',
      'id': id,
      ...payload,
    });
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('遮挡分割超时');
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
        completer.completeError(StateError('遮挡模型已关闭'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  void _handleMessage(Object? message) {
    if (message is! Map || message['id'] is! int) return;
    final completer = _pending.remove(message['id'] as int);
    if (completer == null || completer.isCompleted) return;
    if (message['type'] == 'error') {
      completer.completeError(StateError('${message['error']}'));
      return;
    }
    final transferred = message['rgba'] as TransferableTypedData;
    completer.complete(
      FaceOcclusionMask(
        rgba: transferred.materialize().asUint8List(),
        roi: FaceOcclusionRoi.decode(message['roi'] as Float64List),
        inferenceDuration: Duration(
          microseconds: message['durationMicros'] as int,
        ),
      ),
    );
  }
}

Future<void> _occlusionWorkerMain(List<Object?> bootstrap) async {
  final resultPort = bootstrap[0]! as SendPort;
  final model = (bootstrap[1]! as TransferableTypedData)
      .materialize()
      .asUint8List();
  final commandPort = ReceivePort();
  Interpreter? interpreter;
  try {
    final options = InterpreterOptions()..threads = 2;
    interpreter = Interpreter.fromBuffer(model, options: options);
    options.delete();
    final inputShape = interpreter.getInputTensor(0).shape;
    final outputShape = interpreter.getOutputTensor(0).shape;
    if (!_sameShape(inputShape, const [1, 256, 256, 3]) ||
        !_sameShape(outputShape, const [1, 256, 256, 6])) {
      throw StateError('遮挡模型 Tensor 尺寸异常: $inputShape -> $outputShape');
    }
  } catch (error) {
    interpreter?.close();
    resultPort.send(<String, Object>{
      'type': 'startupError',
      'error': '$error',
    });
    commandPort.close();
    return;
  }

  final postprocessor = OcclusionMaskPostprocessor();
  final output = Float32List(_modelSize * _modelSize * _classCount);
  resultPort.send(<String, Object>{
    'type': 'ready',
    'port': commandPort.sendPort,
  });

  await for (final Object? rawMessage in commandPort) {
    if (rawMessage is! Map) continue;
    final type = rawMessage['type'];
    if (type == 'close') break;
    if (type == 'reset') {
      postprocessor.reset();
      continue;
    }
    if (type != 'process') continue;
    final id = rawMessage['id'] as int;
    try {
      final stopwatch = Stopwatch()..start();
      final input = _preprocess(rawMessage);
      interpreter.run(input.buffer, output.buffer);
      final rgba = postprocessor.process(
        output,
        width: _modelSize,
        height: _modelSize,
      );
      stopwatch.stop();
      resultPort.send(<String, Object>{
        'type': 'result',
        'id': id,
        'roi': rawMessage['roi'] as Float64List,
        'rgba': TransferableTypedData.fromList([rgba]),
        'durationMicros': stopwatch.elapsedMicroseconds,
      });
    } catch (error) {
      postprocessor.reset();
      resultPort.send(<String, Object>{
        'type': 'error',
        'id': id,
        'error': '$error',
      });
    }
  }
  interpreter.close();
  commandPort.close();
}

bool _sameShape(List<int> actual, List<int> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

Float32List _preprocess(Map<dynamic, dynamic> message) {
  final width = message['width'] as int;
  final height = message['height'] as int;
  final rotation = message['rotation'] as int;
  final roi = FaceOcclusionRoi.decode(message['roi'] as Float64List);
  if (message['kind'] == 'rgba') {
    final rgba = (message['rgba'] as TransferableTypedData)
        .materialize()
        .asUint8List();
    return _sampleModelInput(
      width: width,
      height: height,
      rotation: rotation,
      roi: roi,
      sampleRgb: (x, y) {
        final index = (y * width + x) * 4;
        return (rgba[index], rgba[index + 1], rgba[index + 2]);
      },
    );
  }

  final rowStrides = (message['rowStrides'] as List).cast<int>();
  final pixelStrides = (message['pixelStrides'] as List).cast<int>();
  final planes = (message['planes'] as List)
      .cast<TransferableTypedData>()
      .map((data) => data.materialize().asUint8List())
      .toList(growable: false);
  if (message['android'] as bool) {
    final nv21 = _toNv21(
      planes,
      width: width,
      height: height,
      rowStrides: rowStrides,
      pixelStrides: pixelStrides,
    );
    if (nv21 == null) throw StateError('无法转换 NV21 遮挡帧');
    return _sampleModelInput(
      width: width,
      height: height,
      rotation: rotation,
      roi: roi,
      sampleRgb: (x, y) => _nv21Rgb(nv21, x, y),
    );
  }

  final bgra = planes.first;
  final rowStride = rowStrides.first;
  return _sampleModelInput(
    width: width,
    height: height,
    rotation: rotation,
    roi: roi,
    sampleRgb: (x, y) {
      final index = y * rowStride + x * 4;
      return (bgra[index + 2], bgra[index + 1], bgra[index]);
    },
  );
}

Float32List _sampleModelInput({
  required int width,
  required int height,
  required int rotation,
  required FaceOcclusionRoi roi,
  required (int, int, int) Function(int x, int y) sampleRgb,
}) {
  final input = Float32List(_modelSize * _modelSize * 3);
  for (var y = 0; y < _modelSize; y++) {
    final logicalY = roi.top + (y + 0.5) / _modelSize * roi.height;
    for (var x = 0; x < _modelSize; x++) {
      final logicalX = roi.left + (x + 0.5) / _modelSize * roi.width;
      final raw = _logicalToRaw(logicalX, logicalY, rotation);
      final px = (raw.$1 * (width - 1)).round().clamp(0, width - 1);
      final py = (raw.$2 * (height - 1)).round().clamp(0, height - 1);
      final rgb = sampleRgb(px, py);
      final offset = (y * _modelSize + x) * 3;
      input[offset] = (rgb.$1 - 127.5) / 127.5;
      input[offset + 1] = (rgb.$2 - 127.5) / 127.5;
      input[offset + 2] = (rgb.$3 - 127.5) / 127.5;
    }
  }
  return input;
}

(int, int, int) _nv21Rgb(FaceMeshNv21Image image, int x, int y) {
  final luma = image.yPlane[y * image.yBytesPerRow + x];
  final uvIndex = (y ~/ 2) * image.vuBytesPerRow + (x ~/ 2) * 2;
  final v = image.vuPlane[uvIndex];
  final u = image.vuPlane[uvIndex + 1];
  final c = luma - 16;
  final d = u - 128;
  final e = v - 128;
  final red = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
  final green = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
  final blue = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);
  return (red, green, blue);
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
  return null;
}

(double, double) _logicalToRaw(double x, double y, int rotation) {
  return switch (rotation) {
    90 => (y, 1 - x),
    180 => (1 - x, 1 - y),
    270 => (1 - y, x),
    _ => (x, y),
  };
}
