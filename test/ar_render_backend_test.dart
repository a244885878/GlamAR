import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glamar/features/face_mesh/models/normalized_face_frame.dart';
import 'package:glamar/features/makeup/data/makeup_library.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/models/makeup_response_curve.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet_codec.dart';
import 'package:glamar/features/makeup/rendering/flutter_composite_render_backend.dart';
import 'package:glamar/features/makeup/rendering/native_face_mesh_topology.dart';
import 'package:glamar/features/makeup/rendering/native_gpu_render_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encodes a versioned fixed-layout makeup uniform block', () {
    final look = MakeupLibrary.looks.first
        .withLayer(
          MakeupPart.eyeshadow,
          const MakeupLayerConfig(
            color: Color(0xFFCC5577),
            secondaryColor: Color(0xFF6644AA),
            intensity: 0.72,
            detail: 0.36,
            product: 'Test shadow',
            enabled: false,
          ),
        )
        .withLipFinish(LipFinish.glass);
    final material = ArMakeupMaterialState.fromLook(look);
    final uniforms = material.gpuUniforms;
    final eyeshadow = ArMakeupMaterialState.layerOffset(MakeupPart.eyeshadow);

    expect(
      uniforms.length,
      ArMakeupMaterialState.headerLength +
          MakeupPart.values.length * ArMakeupMaterialState.layerStride,
    );
    expect(
      uniforms[ArMakeupMaterialState.versionOffset],
      ArMakeupMaterialState.protocolVersion,
    );
    expect(uniforms[ArMakeupMaterialState.lipFinishOffset], 1);
    expect(uniforms[eyeshadow + ArMakeupMaterialState.enabledOffset], 0);
    expect(
      uniforms[eyeshadow + ArMakeupMaterialState.intensityOffset],
      closeTo(
        MakeupResponseCurve.intensity(MakeupPart.eyeshadow, 0.72),
        0.0001,
      ),
    );
    expect(
      uniforms[eyeshadow + ArMakeupMaterialState.hasSecondaryColorOffset],
      1,
    );
    expect(
      uniforms[eyeshadow + ArMakeupMaterialState.secondaryBlueOffset],
      closeTo(const Color(0xFF6644AA).b, 0.0001),
    );
    expect(material.gpuBytes.lengthInBytes, uniforms.lengthInBytes);
  });

  test('encodes dynamic face state and clamps runtime controls', () {
    final state = ArFaceRenderState(
      context: const FaceRenderContext(
        lighting: FaceLighting(
          exposure: 0.6,
          sideAExposure: 0.5,
          sideBExposure: 0.7,
          warmth: -0.2,
          skinChroma: 0.24,
          localContrast: 0.13,
        ),
        sideAVisibility: 0.8,
        sideBVisibility: 0.4,
        profileOpacity: 0.9,
        fineDetailVisibility: 0.65,
        sideAEyeOpenness: 0.2,
        sideBEyeOpenness: 0.95,
        mouthOpenness: 0.45,
      ),
      trackingOpacity: 1.4,
      runtimeDetailQuality: -0.2,
      skinFilterEnabled: false,
      pixelMaterialEnabled: true,
    );

    expect(state.gpuUniforms.length, ArFaceRenderState.uniformLength);
    expect(
      state.gpuUniforms[ArFaceRenderState.versionOffset],
      ArFaceRenderState.protocolVersion,
    );
    expect(
      state.gpuUniforms[ArFaceRenderState.mouthOpennessOffset],
      closeTo(0.45, 0.0001),
    );
    expect(state.gpuUniforms[ArFaceRenderState.trackingOpacityOffset], 1);
    expect(state.gpuUniforms[ArFaceRenderState.runtimeDetailQualityOffset], 0);
    expect(state.gpuUniforms[ArFaceRenderState.skinFilterEnabledOffset], 0);
    expect(state.gpuUniforms[ArFaceRenderState.pixelMaterialEnabledOffset], 1);
    expect(
      state.gpuUniforms[ArFaceRenderState.skinChromaOffset],
      closeTo(0.24, 0.0001),
    );
    expect(
      state.gpuUniforms[ArFaceRenderState.localContrastOffset],
      closeTo(0.13, 0.0001),
    );
  });

  test('reuses dynamic uniforms across prediction-only render ticks', () {
    final cache = ArFaceRenderStateCache();
    const context = FaceRenderContext.neutral();
    final first = cache.resolve(
      context: context,
      trackingOpacity: 1,
      runtimeDetailQuality: 0.8,
      skinFilterEnabled: true,
    );
    final predictionTick = cache.resolve(
      context: context,
      trackingOpacity: 1,
      runtimeDetailQuality: 0.8,
      skinFilterEnabled: true,
    );
    final degraded = cache.resolve(
      context: context,
      trackingOpacity: 1,
      runtimeDetailQuality: 0.6,
      skinFilterEnabled: true,
    );

    expect(predictionTick, same(first));
    expect(predictionTick.gpuUniforms, same(first.gpuUniforms));
    expect(degraded, isNot(same(first)));
  });

  test('builds a protected official dense face mesh topology once', () {
    final indices = NativeFaceMeshTopology.skinIndices;
    expect(indices.length, greaterThan(1200));
    expect(indices.length % 3, 0);
    expect(indices.every((index) => index < 468), isTrue);
    expect(indices, same(NativeFaceMeshTopology.skinIndices));
  });

  test('encodes a native little-endian packet with stable offsets', () {
    final vertices = Float32List.fromList(<double>[
      0.2,
      0.3,
      -0.04,
      0.8,
      0.7,
      0.02,
    ]);
    final frame = NormalizedFaceFrame(
      xyz: vertices,
      sourceSequence: 27,
      sourceTimestamp: const Duration(microseconds: 123456),
      presentationTimestamp: const Duration(microseconds: 145678),
    );
    final material = ArMakeupMaterialState.fromLook(MakeupLibrary.looks.first);
    final faceState = ArFaceRenderState(
      context: const FaceRenderContext.neutral(),
      trackingOpacity: 0.82,
      runtimeDetailQuality: 0.7,
      skinFilterEnabled: true,
    );
    final packet = ArRenderPacket(
      submissionSequence: 42,
      faceFrame: frame,
      material: material,
      faceState: faceState,
      mirrorHorizontal: true,
    );

    final encoded = ArRenderPacketCodec.encode(packet);
    expect(
      encoded.getUint32(ArRenderPacketCodec.magicOffset, Endian.little),
      ArRenderPacketCodec.magic,
    );
    expect(
      encoded.getUint16(ArRenderPacketCodec.versionOffset, Endian.little),
      ArRenderPacketCodec.protocolVersion,
    );
    expect(
      encoded.getUint16(ArRenderPacketCodec.flagsOffset, Endian.little),
      ArRenderPacketCodec.mirrorHorizontalFlag,
    );
    expect(
      encoded.getUint64(
        ArRenderPacketCodec.submissionSequenceOffset,
        Endian.little,
      ),
      42,
    );
    expect(
      encoded.getUint64(
        ArRenderPacketCodec.sourceSequenceOffset,
        Endian.little,
      ),
      27,
    );
    expect(
      encoded.getUint32(ArRenderPacketCodec.landmarkCountOffset, Endian.little),
      2,
    );
    expect(
      encoded.getFloat32(ArRenderPacketCodec.headerLength, Endian.little),
      closeTo(0.2, 0.0001),
    );
    expect(
      encoded.lengthInBytes,
      ArRenderPacketCodec.headerLength +
          vertices.lengthInBytes +
          material.gpuUniforms.lengthInBytes +
          faceState.gpuUniforms.lengthInBytes,
    );
  });

  test(
    'keeps only the newest atomic render submission without vertex copy',
    () {
      final backend = FlutterCompositeRenderBackend();
      addTearDown(backend.dispose);
      var notifications = 0;
      backend.addListener(() => notifications++);

      final vertices = Float32List.fromList([0.2, 0.3, -0.04]);
      final frame = NormalizedFaceFrame(
        xyz: vertices,
        sourceSequence: 9,
        sourceTimestamp: const Duration(milliseconds: 90),
        presentationTimestamp: const Duration(milliseconds: 112),
      );
      final material = ArMakeupMaterialState.fromLook(
        MakeupLibrary.looks.first,
      );
      final faceState = ArFaceRenderState(
        context: const FaceRenderContext.neutral(),
        trackingOpacity: 1,
        runtimeDetailQuality: 1,
        skinFilterEnabled: true,
      );
      final newest = ArRenderPacket(
        submissionSequence: 12,
        faceFrame: frame,
        material: material,
        faceState: faceState,
        mirrorHorizontal: true,
      );
      final stale = ArRenderPacket(
        submissionSequence: 11,
        faceFrame: frame,
        material: material,
        faceState: faceState,
        mirrorHorizontal: false,
      );

      expect(backend.submit(newest), isTrue);
      expect(backend.submit(stale), isFalse);
      expect(backend.value, same(newest));
      expect(backend.value!.faceFrame.xyz, same(vertices));
      expect(backend.droppedSubmissions, 1);
      expect(notifications, 1);

      backend.clear();
      expect(backend.value, isNull);
      expect(notifications, 2);
    },
  );

  test(
    'native surface is exposed only after the first successful frame',
    () async {
      const control = MethodChannel('glamar/ar_test/control');
      const frames = BasicMessageChannel<ByteData?>(
        'glamar/ar_test/frames',
        BinaryCodec(),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(control, (call) async {
        if (call.method == 'initialize') {
          return <String, Object?>{
            'textureId': 88,
            'pixelWidth': 720,
            'pixelHeight': 1280,
          };
        }
        return null;
      });
      final replies = <Completer<ByteData?>>[];
      messenger.setMockDecodedMessageHandler<ByteData?>(frames, (message) {
        final reply = Completer<ByteData?>();
        replies.add(reply);
        return reply.future;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(control, null);
        messenger.setMockDecodedMessageHandler<ByteData?>(frames, null);
      });

      final backend = NativeGpuRenderBackend.test(
        controlChannel: control,
        frameChannel: frames,
      );
      addTearDown(backend.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(
        backend.nativeParts,
        equals(const <MakeupPart>{
          MakeupPart.complexion,
          MakeupPart.blush,
          MakeupPart.eyeshadow,
          MakeupPart.brows,
          MakeupPart.eyeliner,
          MakeupPart.lips,
        }),
      );

      final first = _packet(submissionSequence: 1);
      final second = _packet(submissionSequence: 2);
      final third = _packet(submissionSequence: 3);
      backend.submit(first);
      await Future<void>.delayed(Duration.zero);
      expect(replies, hasLength(1));
      expect(backend.nativeSurface.value, isNull);

      // 第一帧在途时只留下最新的第三帧。
      backend.submit(second);
      backend.submit(third);
      expect(backend.droppedSubmissions, 1);
      final successfulReply = ByteData(6)
        ..setUint8(0, 1)
        ..setFloat32(1, 6.5, Endian.little)
        ..setUint8(5, 3);
      replies.first.complete(successfulReply);
      await Future<void>.delayed(Duration.zero);
      expect(backend.nativeSurface.value?.textureId, 88);
      expect(backend.nativeRenderMs.value, closeTo(6.5, 0.001));
      expect(backend.thermalPressure.value, closeTo(0.75, 0.001));
      expect(replies, hasLength(2));
      expect(replies.last, isNot(same(replies.first)));
      replies.last.complete(ByteData.sublistView(Uint8List.fromList([1])));
      await Future<void>.delayed(Duration.zero);
    },
  );
}

ArRenderPacket _packet({required int submissionSequence}) {
  final frame = NormalizedFaceFrame(
    xyz: Float32List(468 * 3),
    sourceSequence: submissionSequence,
    sourceTimestamp: Duration(milliseconds: submissionSequence * 16),
    presentationTimestamp: Duration(milliseconds: submissionSequence * 16 + 8),
  );
  return ArRenderPacket(
    submissionSequence: submissionSequence,
    faceFrame: frame,
    material: ArMakeupMaterialState.fromLook(MakeupLibrary.looks.first),
    faceState: ArFaceRenderState(
      context: const FaceRenderContext.neutral(),
      trackingOpacity: 1,
      runtimeDetailQuality: 1,
      skinFilterEnabled: true,
    ),
    mirrorHorizontal: true,
  );
}
