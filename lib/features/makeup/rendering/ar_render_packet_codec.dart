import 'dart:typed_data';

import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';

/// Dart / native GPU 共用的小端序二进制帧格式。
///
/// 整帧约 6KB，不包含 Map/String 等 StandardCodec 对象树。Native
/// 可以用固定 offset 直接验证和上传 Metal 缓冲。
abstract final class ArRenderPacketCodec {
  static const int magic = 0x52414C47; // ASCII "GLAR" in little endian.
  static const int protocolVersion = 1;
  static const int headerLength = 48;

  static const int magicOffset = 0;
  static const int versionOffset = 4;
  static const int flagsOffset = 6;
  static const int submissionSequenceOffset = 8;
  static const int sourceSequenceOffset = 16;
  static const int sourceTimestampMicrosOffset = 24;
  static const int presentationTimestampMicrosOffset = 32;
  static const int landmarkCountOffset = 40;
  static const int materialFloatCountOffset = 44;
  static const int faceFloatCountOffset = 46;

  static const int mirrorHorizontalFlag = 1 << 0;

  static ByteData encode(ArRenderPacket packet) {
    final vertices = packet.faceFrame.xyz;
    final material = packet.material.gpuUniforms;
    final face = packet.faceState.gpuUniforms;
    final byteLength =
        headerLength +
        vertices.lengthInBytes +
        material.lengthInBytes +
        face.lengthInBytes;
    final bytes = ByteData(byteLength);
    bytes
      ..setUint32(magicOffset, magic, Endian.little)
      ..setUint16(versionOffset, protocolVersion, Endian.little)
      ..setUint16(
        flagsOffset,
        packet.mirrorHorizontal ? mirrorHorizontalFlag : 0,
        Endian.little,
      )
      ..setUint64(
        submissionSequenceOffset,
        packet.submissionSequence,
        Endian.little,
      )
      ..setUint64(sourceSequenceOffset, packet.sourceSequence, Endian.little)
      ..setInt64(
        sourceTimestampMicrosOffset,
        packet.faceFrame.sourceTimestamp.inMicroseconds,
        Endian.little,
      )
      ..setInt64(
        presentationTimestampMicrosOffset,
        packet.presentationTimestamp.inMicroseconds,
        Endian.little,
      )
      ..setUint32(
        landmarkCountOffset,
        packet.faceFrame.landmarkCount,
        Endian.little,
      )
      ..setUint16(materialFloatCountOffset, material.length, Endian.little)
      ..setUint16(faceFloatCountOffset, face.length, Endian.little);

    var offset = headerLength;
    offset = _writeFloat32List(bytes, offset, vertices);
    offset = _writeFloat32List(bytes, offset, material);
    _writeFloat32List(bytes, offset, face);
    return bytes;
  }

  static int _writeFloat32List(
    ByteData target,
    int byteOffset,
    Float32List values,
  ) {
    if (Endian.host == Endian.little) {
      final source = values.buffer.asUint8List(
        values.offsetInBytes,
        values.lengthInBytes,
      );
      target.buffer
          .asUint8List(target.offsetInBytes + byteOffset, source.length)
          .setAll(0, source);
      return byteOffset + values.lengthInBytes;
    }
    for (var index = 0; index < values.length; index++) {
      target.setFloat32(
        byteOffset + index * Float32List.bytesPerElement,
        values[index],
        Endian.little,
      );
    }
    return byteOffset + values.lengthInBytes;
  }
}
