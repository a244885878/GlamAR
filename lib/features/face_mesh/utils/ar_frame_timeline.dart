import 'dart:math' as math;

/// 一帧相机图像在 AR 管线中的稳定身份。
class ArFrameStamp {
  const ArFrameStamp({required this.sequence, required this.capturedAt});

  final int sequence;
  final Duration capturedAt;
}

/// 为相机回调、模型结果和屏幕呈现提供同一个单调时间轴。
///
/// 不使用系统墙上时钟，因此切换时区或系统时间不会制造负延迟。当前
/// Camera 插件没有暴露硬件时间戳，capturedAt 采用图像回调抵达时刻；未来
/// 原生纹理后端可直接用硬件时间戳替换，而不需要改变上层跟踪 API。
class ArFrameTimeline {
  ArFrameTimeline({Duration Function()? clock}) : _injectedClock = clock {
    _stopwatch.start();
  }

  final Duration Function()? _injectedClock;
  final Stopwatch _stopwatch = Stopwatch();

  int _latestSequence = 0;
  Duration? _lastCaptureAt;
  double _captureIntervalMicros = 1000000 / 30;
  double _pipelineLatencyMicros = 0;

  Duration get now => _injectedClock?.call() ?? _stopwatch.elapsed;

  double get captureFps =>
      _captureIntervalMicros <= 0 ? 0 : 1000000 / _captureIntervalMicros;

  double get pipelineLatencyMs => _pipelineLatencyMicros / 1000;

  ArFrameStamp markCameraFrame() {
    final timestamp = now;
    final previous = _lastCaptureAt;
    if (previous != null) {
      final interval = (timestamp - previous).inMicroseconds;
      if (interval >= 4000 && interval <= 120000) {
        _captureIntervalMicros =
            _captureIntervalMicros * 0.84 + interval * 0.16;
      }
    }
    _lastCaptureAt = timestamp;
    return ArFrameStamp(sequence: ++_latestSequence, capturedAt: timestamp);
  }

  void markInferenceCompleted(ArFrameStamp stamp) {
    final latency = math.max(0, (now - stamp.capturedAt).inMicroseconds);
    _pipelineLatencyMicros = _pipelineLatencyMicros == 0
        ? latency.toDouble()
        : _pipelineLatencyMicros * 0.82 + latency * 0.18;
  }

  int framesSince(ArFrameStamp stamp) =>
      math.max(0, _latestSequence - stamp.sequence);

  /// CameraPreview 通常在下一个合成帧显示最新纹理，目标时间略早于当前
  /// vsync。按采集间隔估算这个偏移可减少把妆容预测到视频前面的过冲。
  Duration get renderTimestamp {
    final presentationDelay = (_captureIntervalMicros * 0.35).clamp(
      4000,
      14000,
    );
    final targetMicros = math.max(0, now.inMicroseconds - presentationDelay);
    return Duration(microseconds: targetMicros.round());
  }

  /// 高延迟设备需要比固定 96ms 更长的安全预测窗口，但始终限制在
  /// 132ms，并继续受位移、缩放和旋转幅度上限保护。
  Duration get maximumPredictionHorizon {
    final latency = _pipelineLatencyMicros == 0
        ? 96000
        : _pipelineLatencyMicros + _captureIntervalMicros * 0.35;
    return Duration(microseconds: latency.clamp(96000, 132000).round());
  }

  void reset() {
    _latestSequence = 0;
    _lastCaptureAt = null;
    _captureIntervalMicros = 1000000 / 30;
    _pipelineLatencyMicros = 0;
    if (_injectedClock == null) {
      _stopwatch
        ..reset()
        ..start();
    }
  }
}
