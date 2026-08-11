import 'dart:typed_data';

/// 将 SelfieMulticlass 的 6 类输出变成用于 `dstOut` 的遮挡蒙版。
///
/// 类别顺序：背景、头发、身体皮肤、面部皮肤、衣物、配饰。我们只把
/// 面部皮肤之外的人体类别视为妆容前景，背景不参与，避免模型边缘误判
/// 把整片妆容抹掉。
class OcclusionMaskPostprocessor {
  Float32List? _history;

  void reset() => _history = null;

  Uint8List process(
    Float32List scores, {
    required int width,
    required int height,
    int classCount = 6,
  }) {
    final pixelCount = width * height;
    if (classCount < 6 || scores.length != pixelCount * classCount) {
      throw ArgumentError('SelfieMulticlass 输出尺寸不匹配');
    }

    final previous = _history;
    final next = Float32List(pixelCount);
    for (var pixel = 0; pixel < pixelCount; pixel++) {
      final base = pixel * classCount;
      var bestClass = 0;
      var best = scores[base];
      var second = double.negativeInfinity;
      for (var category = 1; category < classCount; category++) {
        final value = scores[base + category];
        if (value > best) {
          second = best;
          best = value;
          bestClass = category;
        } else if (value > second) {
          second = value;
        }
      }

      final baseOpacity = switch (bestClass) {
        1 || 2 => 1.0,
        4 => 0.88,
        5 => 0.82,
        _ => 0.0,
      };
      var target = 0.0;
      if (baseOpacity > 0) {
        // 同时兼容 logits 和概率输出：类别胜出越明显，遮挡越坚实。
        final separation = (best - second).clamp(0.0, 1.0);
        target = baseOpacity * (0.34 + separation * 1.9).clamp(0.34, 1.0);
      }

      if (previous == null || previous.length != pixelCount) {
        next[pixel] = target;
      } else {
        final old = previous[pixel];
        final response = target > old ? 0.72 : 0.22;
        next[pixel] = old + (target - old) * response;
      }
    }
    _history = next;

    // 3x3 空间羽化用来消除 256x256 类别蒙版的锯齿。
    final rgba = Uint8List(pixelCount * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var sum = 0.0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final sampleY = y + dy;
          if (sampleY < 0 || sampleY >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final sampleX = x + dx;
            if (sampleX < 0 || sampleX >= width) continue;
            sum += next[sampleY * width + sampleX];
            count++;
          }
        }
        final offset = (y * width + x) * 4;
        rgba[offset] = 255;
        rgba[offset + 1] = 255;
        rgba[offset + 2] = 255;
        rgba[offset + 3] = ((sum / count) * 255).round().clamp(0, 255);
      }
    }
    return rgba;
  }
}
