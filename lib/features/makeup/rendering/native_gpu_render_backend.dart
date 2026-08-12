import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/rendering/ar_render_backend.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet_codec.dart';
import 'package:glamar/features/makeup/rendering/flutter_composite_render_backend.dart';
import 'package:glamar/features/makeup/rendering/native_face_mesh_topology.dart';

/// iOS Metal / Android OpenGL ES 共用的透明原生纹理提交后端。
///
/// 跟踪与妆容帧先写入 Flutter 兼容面，然后以只有一个在途请求的
/// latest-frame-wins 通道提交给 GPU。原生面首帧未确认前不会丢失
/// 任何功能，连续失败则自动回退到 Flutter 合成。
class NativeGpuRenderBackend implements ArNativeTextureRenderBackend {
  NativeGpuRenderBackend._({
    required this._backendName,
    required String channelPrefix,
    MethodChannel? controlChannel,
    BasicMessageChannel<ByteData?>? frameChannel,
  }) : _controlChannel =
           controlChannel ?? MethodChannel('$channelPrefix/control'),
       _frameChannel =
           frameChannel ??
           BasicMessageChannel<ByteData?>(
             '$channelPrefix/frames',
             const BinaryCodec(),
           ) {
    unawaited(_initialize());
  }

  factory NativeGpuRenderBackend.iosMetal() => NativeGpuRenderBackend._(
    backendName: 'iOS Metal + Flutter fallback',
    channelPrefix: 'glamar/ar_metal',
  );

  factory NativeGpuRenderBackend.androidOpenGl() => NativeGpuRenderBackend._(
    backendName: 'Android OpenGL ES + Flutter fallback',
    channelPrefix: 'glamar/ar_opengl',
  );

  @visibleForTesting
  factory NativeGpuRenderBackend.test({
    required MethodChannel controlChannel,
    required BasicMessageChannel<ByteData?> frameChannel,
  }) => NativeGpuRenderBackend._(
    backendName: 'Test native GPU',
    channelPrefix: 'glamar/ar_test',
    controlChannel: controlChannel,
    frameChannel: frameChannel,
  );

  final String _backendName;
  final MethodChannel _controlChannel;
  final BasicMessageChannel<ByteData?> _frameChannel;
  final FlutterCompositeRenderBackend _fallback =
      FlutterCompositeRenderBackend();
  final ValueNotifier<ArNativeRenderSurface?> _surface =
      ValueNotifier<ArNativeRenderSurface?>(null);
  final ValueNotifier<double> _nativeRenderMs = ValueNotifier<double>(0);
  final ValueNotifier<double> _thermalPressure = ValueNotifier<double>(0);

  bool _disposed = false;
  bool _ready = false;
  bool _sendInFlight = false;
  ArNativeRenderSurface? _initializedSurface;
  ArRenderPacket? _pendingPacket;
  int _consecutiveNativeErrors = 0;
  int _droppedNativeSubmissions = 0;

  @override
  ArRenderBackendCapabilities get capabilities => ArRenderBackendCapabilities(
    name: _backendName,
    cameraTextureComposition: true,
    canonicalVertexInput: true,
    gpuUniformInput: true,
  );

  @override
  ValueListenable<ArRenderPacket?> get frames => _fallback.frames;

  @override
  ValueListenable<ArNativeRenderSurface?> get nativeSurface => _surface;

  @override
  ValueListenable<double> get nativeRenderMs => _nativeRenderMs;

  @override
  ValueListenable<double> get thermalPressure => _thermalPressure;

  @override
  Set<MakeupPart> get nativeParts => const <MakeupPart>{
    MakeupPart.complexion,
    MakeupPart.blush,
    MakeupPart.eyeshadow,
    MakeupPart.brows,
    MakeupPart.eyeliner,
    MakeupPart.lips,
  };

  @override
  int get droppedSubmissions =>
      _fallback.droppedSubmissions + _droppedNativeSubmissions;

  Future<void> _initialize() async {
    try {
      final response = await _controlChannel
          .invokeMapMethod<String, Object?>('initialize', <String, Object?>{
            'pixelWidth': 720,
            'pixelHeight': 1280,
            'faceMeshIndices': NativeFaceMeshTopology.skinIndices.buffer
                .asUint8List(),
          });
      if (_disposed) {
        unawaited(
          _controlChannel.invokeMethod<void>('dispose').catchError((_) {}),
        );
        return;
      }
      if (response == null) return;
      final textureId = response['textureId'];
      final width = response['pixelWidth'];
      final height = response['pixelHeight'];
      if (textureId is! int || width is! int || height is! int) return;
      _ready = true;
      _initializedSurface = ArNativeRenderSurface(
        textureId: textureId,
        pixelWidth: width,
        pixelHeight: height,
      );
      _pendingPacket = _fallback.value;
      _pumpFrames();
    } on PlatformException {
      // GPU 不可用时始终保持 Flutter 兼容面。
    } on MissingPluginException {
      // Widget 测试和非移动端引擎没有原生通道。
    }
  }

  @override
  bool submit(ArRenderPacket packet) {
    final accepted = _fallback.submit(packet);
    if (!accepted || _disposed) return accepted;
    if (_pendingPacket != null) _droppedNativeSubmissions++;
    _pendingPacket = packet;
    _pumpFrames();
    return true;
  }

  void _pumpFrames() {
    if (!_ready || _disposed || _sendInFlight) return;
    final packet = _pendingPacket;
    if (packet == null) return;
    _pendingPacket = null;
    _sendInFlight = true;
    unawaited(
      _frameChannel
          .send(ArRenderPacketCodec.encode(packet))
          .then<void>(_handleNativeReply, onError: _handleNativeError)
          .whenComplete(() {
            _sendInFlight = false;
            _pumpFrames();
          }),
    );
  }

  void _handleNativeReply(ByteData? response) {
    final rendered =
        response != null &&
        response.lengthInBytes > 0 &&
        response.getUint8(0) == 1;
    if (!rendered) {
      _handleNativeError(StateError('Native GPU rejected render packet'));
      return;
    }
    _consecutiveNativeErrors = 0;
    if (response.lengthInBytes >= 5) {
      final sample = response.getFloat32(1, Endian.little);
      if (sample.isFinite && sample >= 0) {
        _nativeRenderMs.value = _nativeRenderMs.value == 0
            ? sample
            : _nativeRenderMs.value * 0.82 + sample * 0.18;
      }
    }
    if (response.lengthInBytes >= 6) {
      final sample = response.getUint8(5) / 4.0;
      _thermalPressure.value = sample.clamp(0.0, 1.0);
    }
    final surface = _initializedSurface;
    if (!_disposed && surface != null && _surface.value == null) {
      _surface.value = surface;
    }
  }

  void _handleNativeError(Object _) {
    _consecutiveNativeErrors++;
    if (_consecutiveNativeErrors < 3 || _disposed) return;
    _ready = false;
    _pendingPacket = null;
    _initializedSurface = null;
    _surface.value = null;
    unawaited(_controlChannel.invokeMethod<void>('dispose').catchError((_) {}));
  }

  @override
  void clear() {
    _fallback.clear();
    _pendingPacket = null;
    _surface.value = null;
    if (_ready && !_disposed) {
      unawaited(_controlChannel.invokeMethod<void>('clear').catchError((_) {}));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _pendingPacket = null;
    _initializedSurface = null;
    _surface.value = null;
    _surface.dispose();
    _nativeRenderMs.dispose();
    _thermalPressure.dispose();
    _fallback.dispose();
    unawaited(_controlChannel.invokeMethod<void>('dispose').catchError((_) {}));
  }
}
