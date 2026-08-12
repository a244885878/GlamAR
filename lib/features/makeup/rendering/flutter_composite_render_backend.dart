import 'package:flutter/foundation.dart';
import 'package:glamar/features/makeup/rendering/ar_render_backend.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';

/// 现有 Canvas + FragmentShader 管线的兼容后端。
///
/// 它已经遵循与未来原生 GPU 后端相同的提交协议：乱序包直接
/// 丢弃，消费端永远只看最新的完整状态。
class FlutterCompositeRenderBackend extends ChangeNotifier
    implements ArRenderBackend, ValueListenable<ArRenderPacket?> {
  @override
  ArRenderBackendCapabilities get capabilities =>
      const ArRenderBackendCapabilities(
        name: 'Flutter Canvas / FragmentShader',
        cameraTextureComposition: false,
        canonicalVertexInput: true,
        gpuUniformInput: true,
      );

  ArRenderPacket? _value;
  int _latestSubmissionSequence = 0;
  int _droppedSubmissions = 0;

  @override
  ValueListenable<ArRenderPacket?> get frames => this;

  @override
  ArRenderPacket? get value => _value;

  @override
  int get droppedSubmissions => _droppedSubmissions;

  @override
  bool submit(ArRenderPacket packet) {
    if (packet.submissionSequence <= _latestSubmissionSequence) {
      _droppedSubmissions++;
      return false;
    }
    _latestSubmissionSequence = packet.submissionSequence;
    _value = packet;
    notifyListeners();
    return true;
  }

  @override
  void clear() {
    if (_value == null) return;
    _value = null;
    notifyListeners();
  }
}
