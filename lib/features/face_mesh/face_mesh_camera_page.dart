import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/face_mesh/utils/adaptive_landmark_smoother.dart';
import 'package:glamar/features/face_mesh/utils/face_occlusion_inference_worker.dart';
import 'package:glamar/features/face_mesh/utils/face_mesh_inference_worker.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_renderer.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';
import 'package:glamar/features/makeup/shaders/makeup_shader_programs.dart';
import 'package:glamar/features/makeup/widgets/makeup_control_dock.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

class FaceMeshCameraPage extends StatefulWidget {
  const FaceMeshCameraPage({super.key, required this.initialLook});

  final MakeupLook initialLook;

  @override
  State<FaceMeshCameraPage> createState() => _FaceMeshCameraPageState();
}

class _FaceMeshCameraPageState extends State<FaceMeshCameraPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const Map<DeviceOrientation, int> _orientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  CameraController? _cameraController;
  FaceMeshInferenceWorker? _inferenceWorker;
  FaceOcclusionInferenceWorker? _occlusionWorker;

  FaceMeshResult? _meshResult;
  int _landmarkCount = 0;
  String? _errorMessage;
  bool _isInitializing = true;
  bool _isModelReady = false;
  bool _inferBusy = false;
  bool _occlusionBusy = false;
  bool _isOcclusionReady = false;
  _PendingCameraFrame? _pendingCameraFrame;
  _PendingOcclusionFrame? _pendingOcclusionFrame;
  String _statusMessage = '正在启动相机...';
  Size _paintSize = Size.zero;

  final ValueNotifier<List<Offset>?> _makeupLandmarks =
      ValueNotifier<List<Offset>?>(null);
  final ValueNotifier<_TrackingPerformance> _trackingPerformance =
      ValueNotifier<_TrackingPerformance>(const _TrackingPerformance());
  final ValueNotifier<_OcclusionTexture?> _occlusionTexture =
      ValueNotifier<_OcclusionTexture?>(null);
  final AdaptiveLandmarkSmoother _landmarkSmoother = AdaptiveLandmarkSmoother();
  late final Ticker _renderTicker;
  late MakeupLook _activeLook;
  late MakeupLook _presetLook;
  MakeupPart _selectedPart = MakeupPart.lips;
  bool _panelExpanded = false;
  bool _makeupVisible = true;
  bool _isCapturing = false;
  bool _showCaptureFlash = false;

  DateTime? _lastMeshFrameTimestamp;
  DateTime? _performanceWindowStartedAt;
  int _performanceFrameCount = 0;
  double _inferenceMsEma = 0;
  int _consecutiveInferenceErrors = 0;
  int _consecutiveOcclusionErrors = 0;
  DateTime _nextOcclusionAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  FaceLighting _faceLighting = FaceLighting.neutral;
  FaceRenderContext _renderContext = const FaceRenderContext.neutral();

  @override
  void initState() {
    super.initState();
    _activeLook = widget.initialLook;
    _presetLook = widget.initialLook;
    WidgetsBinding.instance.addObserver(this);
    _renderTicker = createTicker(_onRenderTick)..start();
    unawaited(MakeupShaderPrograms.warmUp().catchError((_) {}));
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      _updateStatus('正在检测摄像头...');
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError('检测摄像头超时，请重试。'),
      );
      if (cameras.isEmpty) {
        throw StateError('未找到可用摄像头。');
      }

      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _updateStatus('正在启动相机...');
      await _startCamera(front);

      if (mounted) {
        setState(() => _isInitializing = false);
      }
      if (!mounted) return;
      unawaited(_initFaceMeshModels());
    } catch (error) {
      _errorMessage = '$error';
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _updateStatus(String message) {
    if (!mounted) {
      _statusMessage = message;
      return;
    }
    setState(() => _statusMessage = message);
  }

  Future<void> _initFaceMeshModels() async {
    try {
      _updateStatus('正在加载人脸模型...');
      final worker = await FaceMeshInferenceWorker.start();
      if (!mounted) {
        await worker.close();
        return;
      }
      _inferenceWorker = worker;
      if (mounted) {
        setState(() {
          _isModelReady = true;
          _statusMessage = '';
        });
      } else {
        _isModelReady = true;
        _statusMessage = '';
      }
      unawaited(_initOcclusionModel());
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage ??= '人脸模型加载失败: $error');
      } else {
        _errorMessage ??= '人脸模型加载失败: $error';
      }
    }
  }

  Future<void> _initOcclusionModel() async {
    try {
      final worker = await FaceOcclusionInferenceWorker.start();
      if (!mounted) {
        await worker.close();
        return;
      }
      _occlusionWorker = worker;
      _isOcclusionReady = true;
    } catch (_) {
      // 遮挡是增强链路：个别设备不支持 LiteRT 时仍保留完整 AR 妆容。
      _isOcclusionReady = false;
    }
  }

  Future<void> _startCamera(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      // Android 降低采集分辨率，减轻 NV21 转换与推理压力
      Platform.isAndroid ? ResolutionPreset.medium : ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
    );

    try {
      await controller.initialize().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError('相机启动超时，请检查权限或关闭占用相机的应用。'),
      );
    } on CameraException catch (error) {
      await controller.dispose();
      if (error.code == 'CameraAccessDenied') {
        throw StateError('未获得相机权限，请在系统设置中开启。');
      }
      rethrow;
    }

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() => _cameraController = controller);
    await controller.startImageStream(_onCameraFrame);
  }

  void _onInferenceResult(
    FaceMeshResult? mesh, {
    required FaceLighting lighting,
    required DateTime sourceTimestamp,
    required Duration inferenceDuration,
  }) {
    _consecutiveInferenceErrors = 0;
    final hadFace = _landmarkCount >= 468;
    _meshResult = mesh;
    _landmarkCount = mesh?.landmarks.length ?? 0;
    _faceLighting = FaceLighting.lerp(_faceLighting, lighting, 0.18);
    if (mesh != null) {
      _renderContext = FaceRenderContext.fromMesh(mesh, _faceLighting);
    } else {
      _clearOcclusionTexture();
    }
    _lastMeshFrameTimestamp = sourceTimestamp;
    _updateTrackedLandmarks(mesh, sourceTimestamp: sourceTimestamp);
    _recordPerformance(inferenceDuration, mesh != null);

    if (mounted && hadFace != (_landmarkCount >= 468)) {
      setState(() {});
    }
  }

  void _updateTrackedLandmarks(
    FaceMeshResult? mesh, {
    DateTime? sourceTimestamp,
  }) {
    if (mesh == null || _paintSize == Size.zero) {
      _landmarkSmoother.reset();
      _makeupLandmarks.value = null;
      return;
    }

    final pixels = _landmarkSmoother.observe(
      mesh: mesh,
      targetSize: _paintSize,
      mirrorHorizontal: _mirrorHorizontal,
      sourceTimestamp: sourceTimestamp ?? _lastMeshFrameTimestamp,
    );
    _makeupLandmarks.value = pixels;
  }

  void _onRenderTick(Duration _) {
    final now = DateTime.now();
    if (!_makeupVisible || !_landmarkSmoother.needsPredictionAt(now)) return;
    final predicted = _landmarkSmoother.predict(displayTimestamp: now);
    if (predicted != null) _makeupLandmarks.value = predicted;
  }

  void _recordPerformance(Duration duration, bool trackedFace) {
    final now = DateTime.now();
    _performanceWindowStartedAt ??= now;
    _performanceFrameCount++;
    final currentMs = duration.inMicroseconds / 1000;
    _inferenceMsEma = _inferenceMsEma == 0
        ? currentMs
        : _inferenceMsEma * 0.82 + currentMs * 0.18;

    final window = now.difference(_performanceWindowStartedAt!);
    if (window < const Duration(milliseconds: 600)) return;
    final fps =
        _performanceFrameCount /
        (window.inMicroseconds / Duration.microsecondsPerSecond);
    _trackingPerformance.value = _TrackingPerformance(
      fps: fps,
      inferenceMs: _inferenceMsEma,
      tracking: trackedFace,
    );
    _performanceWindowStartedAt = now;
    _performanceFrameCount = 0;
  }

  void _onInferenceError(Object error) {
    _consecutiveInferenceErrors++;
    _inferenceWorker?.reset();
    if (mounted && _errorMessage == null && _consecutiveInferenceErrors >= 3) {
      setState(() => _errorMessage = '$error');
    }
  }

  void _onCameraFrame(CameraImage image) {
    if (!_isModelReady || _inferenceWorker == null) {
      return;
    }
    // 永远只保留最新相机帧，推理来不及时直接丢弃旧帧，避免延迟不断累积。
    _pendingCameraFrame = _PendingCameraFrame(
      image: image,
      receivedAt: DateTime.now(),
    );
    unawaited(_processLatestFrame());

    final mesh = _meshResult;
    final now = DateTime.now();
    if (_isOcclusionReady &&
        _occlusionWorker != null &&
        mesh != null &&
        !now.isBefore(_nextOcclusionAllowedAt)) {
      _pendingOcclusionFrame = _PendingOcclusionFrame(
        image: image,
        roi: _occlusionRoiForMesh(mesh),
      );
      unawaited(_processLatestOcclusionFrame());
    }
  }

  Future<void> _processLatestFrame() async {
    if (_inferBusy || !_isModelReady || _inferenceWorker == null) {
      return;
    }
    final pending = _pendingCameraFrame;
    final controller = _cameraController;
    if (pending == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    final rotation = _rotationCompensation(controller);
    if (rotation == null) {
      return;
    }

    _pendingCameraFrame = null;
    _inferBusy = true;
    final stopwatch = Stopwatch()..start();

    try {
      final sample = await _inferenceWorker!.process(
        pending.image,
        rotationDegrees: rotation,
        isAndroid: Platform.isAndroid,
      );
      stopwatch.stop();
      _onInferenceResult(
        sample.mesh,
        lighting: sample.lighting,
        sourceTimestamp: pending.receivedAt,
        inferenceDuration: stopwatch.elapsed,
      );
    } catch (error) {
      _onInferenceError(error);
    } finally {
      _inferBusy = false;
      unawaited(_processLatestFrame());
    }
  }

  Future<void> _processLatestOcclusionFrame() async {
    if (_occlusionBusy || !_isOcclusionReady || _occlusionWorker == null) {
      return;
    }
    final pending = _pendingOcclusionFrame;
    final controller = _cameraController;
    if (pending == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    final rotation = _rotationCompensation(controller);
    if (rotation == null) return;

    _pendingOcclusionFrame = null;
    _occlusionBusy = true;
    try {
      final mask = await _occlusionWorker!.processCameraImage(
        pending.image,
        rotationDegrees: rotation,
        isAndroid: Platform.isAndroid,
        roi: pending.roi,
      );
      _consecutiveOcclusionErrors = 0;
      await _updateOcclusionTexture(mask);
    } catch (_) {
      _consecutiveOcclusionErrors++;
      _occlusionWorker?.reset();
      if (_consecutiveOcclusionErrors >= 3) {
        _isOcclusionReady = false;
        _clearOcclusionTexture();
      }
    } finally {
      _occlusionBusy = false;
      // 给 FaceMesh 留出 CPU 时片，遮挡蒙版以稳定性而非高帧率为主。
      _nextOcclusionAllowedAt = DateTime.now().add(
        const Duration(milliseconds: 70),
      );
    }
  }

  FaceOcclusionRoi _occlusionRoiForMesh(FaceMeshResult mesh) {
    var minX = 1.0;
    var maxX = 0.0;
    var minY = 1.0;
    var maxY = 0.0;
    for (final point in mesh.landmarks) {
      minX = point.x < minX ? point.x : minX;
      maxX = point.x > maxX ? point.x : maxX;
      minY = point.y < minY ? point.y : minY;
      maxY = point.y > maxY ? point.y : maxY;
    }
    final faceWidth = maxX - minX;
    final faceHeight = maxY - minY;
    final left = (minX - faceWidth * 0.16).clamp(0.0, 1.0);
    final right = (maxX + faceWidth * 0.16).clamp(0.0, 1.0);
    final top = (minY - faceHeight * 0.12).clamp(0.0, 1.0);
    final bottom = (maxY + faceHeight * 0.08).clamp(0.0, 1.0);
    return FaceOcclusionRoi(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
    );
  }

  Future<void> _updateOcclusionTexture(FaceOcclusionMask mask) async {
    final image = await _decodeOcclusionImage(mask.rgba);
    if (!mounted) {
      image.dispose();
      return;
    }
    final old = _occlusionTexture.value;
    _occlusionTexture.value = _OcclusionTexture(image: image, roi: mask.roi);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.image.dispose());
    }
  }

  Future<ui.Image> _decodeOcclusionImage(Uint8List rgba) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: 256,
      height: 256,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  void _clearOcclusionTexture() {
    final old = _occlusionTexture.value;
    _occlusionTexture.value = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.image.dispose());
    }
  }

  int? _rotationCompensation(CameraController controller) {
    if (Platform.isAndroid) {
      final deviceRotation =
          _orientationDegrees[controller.value.deviceOrientation];
      if (deviceRotation == null) {
        return null;
      }
      final camera = controller.description;
      if (camera.lensDirection == CameraLensDirection.front) {
        return (camera.sensorOrientation + deviceRotation) % 360;
      }
      return (camera.sensorOrientation - deviceRotation + 360) % 360;
    }
    if (Platform.isIOS) {
      return _orientationDegrees[controller.value.deviceOrientation];
    }
    return null;
  }

  void _stopInferenceStream() {
    _inferBusy = false;
    _occlusionBusy = false;
    _pendingCameraFrame = null;
    _pendingOcclusionFrame = null;
    _inferenceWorker?.reset();
    _occlusionWorker?.reset();
    _lastMeshFrameTimestamp = null;
    _performanceWindowStartedAt = null;
    _performanceFrameCount = 0;
    _consecutiveInferenceErrors = 0;
    _consecutiveOcclusionErrors = 0;
    _faceLighting = FaceLighting.neutral;
    _renderContext = const FaceRenderContext.neutral();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _stopInferenceStream();
      controller.dispose();
      _cameraController = null;
      unawaited(_inferenceWorker?.close());
      _inferenceWorker = null;
      unawaited(_occlusionWorker?.close());
      _occlusionWorker = null;
      _isOcclusionReady = false;
      _clearOcclusionTexture();
      _isModelReady = false;
      _meshResult = null;
      _landmarkCount = 0;
      _landmarkSmoother.reset();
      _makeupLandmarks.value = null;
    } else if (state == AppLifecycleState.resumed &&
        _cameraController == null) {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });
      _bootstrap();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _renderTicker.dispose();
    _stopInferenceStream();
    _cameraController?.dispose();
    unawaited(_inferenceWorker?.close());
    _inferenceWorker = null;
    unawaited(_occlusionWorker?.close());
    _occlusionWorker = null;
    _clearOcclusionTexture();
    _makeupLandmarks.dispose();
    _trackingPerformance.dispose();
    _occlusionTexture.dispose();
    super.dispose();
  }

  bool get _mirrorHorizontal {
    final controller = _cameraController;
    return !Platform.isIOS &&
        controller?.description.lensDirection == CameraLensDirection.front;
  }

  void _drawPhotoSource(
    Canvas canvas,
    ui.Image source,
    Size targetSize, {
    required bool mirrored,
    required Paint paint,
  }) {
    canvas.save();
    if (mirrored) {
      canvas.translate(targetSize.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Offset.zero & targetSize,
      paint,
    );
    canvas.restore();
  }

  Future<FaceOcclusionMask?> _inferPhotoOcclusion(
    ui.Image source,
    FaceMeshResult mesh,
  ) async {
    final worker = _occlusionWorker;
    if (!_isOcclusionReady || worker == null) return null;
    try {
      final longestSide = source.width > source.height
          ? source.width
          : source.height;
      final scale = longestSide > 512 ? 512 / longestSide : 1.0;
      final width = (source.width * scale).round().clamp(1, 512);
      final height = (source.height * scale).round().clamp(1, 512);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(width, height);
      picture.dispose();
      final bytes = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
      scaled.dispose();
      if (bytes == null) return null;
      return await worker.processRgba(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        width: width,
        height: height,
        roi: _occlusionRoiForMesh(mesh),
      );
    } catch (_) {
      return null;
    }
  }

  void _erasePhotoOcclusion(
    Canvas canvas,
    ui.Image mask,
    FaceOcclusionRoi roi,
    Size targetSize, {
    required bool mirrored,
  }) {
    final target = Rect.fromLTWH(
      roi.left * targetSize.width,
      roi.top * targetSize.height,
      roi.width * targetSize.width,
      roi.height * targetSize.height,
    );
    canvas.save();
    if (mirrored) {
      canvas.translate(targetSize.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImageRect(
      mask,
      Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
      target,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }

  Future<void> _capturePhoto() async {
    final controller = _cameraController;
    final mesh = _meshResult;
    if (_isCapturing || controller == null || !controller.value.isInitialized) {
      return;
    }
    if (mesh == null) {
      _showMessage('请先将面部置于画面中央');
      return;
    }

    setState(() => _isCapturing = true);
    try {
      _stopInferenceStream();
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final file = await controller.takePicture();
      final sourceBytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(sourceBytes);
      final frame = await codec.getNextFrame();
      final source = frame.image;
      final targetSize = Size(
        source.width.toDouble(),
        source.height.toDouble(),
      );
      final mirrorPhoto = _mirrorHorizontal;
      final photoOcclusion = _makeupVisible
          ? await _inferPhotoOcclusion(source, mesh)
          : null;
      final photoOcclusionImage = photoOcclusion == null
          ? null
          : await _decodeOcclusionImage(photoOcclusion.rgba);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final photoShaders = <ui.FragmentShader>[];
      _drawPhotoSource(
        canvas,
        source,
        targetSize,
        mirrored: mirrorPhoto,
        paint: Paint()..filterQuality = FilterQuality.high,
      );

      if (_makeupVisible) {
        if (photoOcclusionImage != null) {
          canvas.saveLayer(Offset.zero & targetSize, Paint());
        }
        final photoLandmarks = List<Offset>.generate(mesh.landmarks.length, (
          index,
        ) {
          return mesh.landmarkAsOffset(
            mesh.landmarks[index],
            targetSize: targetSize,
            rotationDegrees: 0,
            mirrorHorizontal: mirrorPhoto,
          );
        }, growable: false);
        if (_activeLook.complexion.enabled) {
          final faceWidth = MakeupPainterUtils.faceWidth(photoLandmarks);
          final skinPath = MakeupPainterUtils.skinPath(
            photoLandmarks,
            featurePadding: faceWidth * 0.018,
          );
          final previewSigma = _skinSmoothingSigma(_activeLook.complexion);
          final resolutionScale = _paintSize.width > 0
              ? targetSize.width / _paintSize.width
              : 1.0;
          final skinPaint = Paint()..filterQuality = FilterQuality.high;
          if (ui.ImageFilter.isShaderFilterSupported) {
            try {
              final shader = (await MakeupShaderPrograms.skin())
                  .fragmentShader();
              final config = _activeLook.complexion;
              final adaptedColor = _renderContext.adaptColor(config.color);
              shader
                ..setFloat(
                  2,
                  config.intensity *
                      _renderContext.centralOpacity *
                      (0.18 + config.detail * 0.12),
                )
                ..setFloat(3, adaptedColor.r)
                ..setFloat(4, adaptedColor.g)
                ..setFloat(5, adaptedColor.b)
                ..setFloat(
                  6,
                  config.intensity * _renderContext.centralOpacity * 0.055,
                );
              skinPaint.imageFilter = ui.ImageFilter.shader(shader);
              photoShaders.add(shader);
            } catch (_) {
              // Shader 不可用时使用保守的低强度回退。
            }
          }
          skinPaint.imageFilter ??= ui.ImageFilter.blur(
            sigmaX: previewSigma * resolutionScale,
            sigmaY: previewSigma * resolutionScale,
          );
          canvas.save();
          canvas.clipPath(skinPath);
          _drawPhotoSource(
            canvas,
            source,
            targetSize,
            mirrored: mirrorPhoto,
            paint: skinPaint,
          );
          canvas.restore();
        }
        if (_activeLook.lips.enabled &&
            ui.ImageFilter.isShaderFilterSupported) {
          try {
            final lipShader = (await MakeupShaderPrograms.lips())
                .fragmentShader();
            final config = _activeLook.lips;
            final adaptedColor = _renderContext.adaptColor(config.color);
            lipShader
              ..setFloat(2, adaptedColor.r)
              ..setFloat(3, adaptedColor.g)
              ..setFloat(4, adaptedColor.b)
              ..setFloat(5, config.intensity * _renderContext.centralOpacity)
              ..setFloat(6, switch (_activeLook.lipFinish) {
                LipFinish.velvet => 0,
                LipFinish.satin => 0.48,
                LipFinish.glass => 1,
              });
            canvas.save();
            canvas.clipPath(MakeupPainterUtils.lipPath(photoLandmarks));
            _drawPhotoSource(
              canvas,
              source,
              targetSize,
              mirrored: mirrorPhoto,
              paint: Paint()
                ..filterQuality = FilterQuality.high
                ..imageFilter = ui.ImageFilter.shader(lipShader),
            );
            canvas.restore();
            photoShaders.add(lipShader);
          } catch (_) {
            // Canvas 唇妆仍会完整绘制。
          }
        }
        MakeupRenderer.paintAll(
          canvas,
          targetSize,
          photoLandmarks,
          _activeLook,
          renderContext: _renderContext,
        );
        if (photoOcclusionImage != null && photoOcclusion != null) {
          _erasePhotoOcclusion(
            canvas,
            photoOcclusionImage,
            photoOcclusion.roi,
            targetSize,
            mirrored: mirrorPhoto,
          );
          canvas.restore();
        }
      }

      final picture = recorder.endRecording();
      final rendered = await picture.toImage(source.width, source.height);
      for (final shader in photoShaders) {
        shader.dispose();
      }
      final byteData = await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) throw StateError('照片编码失败');
      var hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) hasAccess = await Gal.requestAccess(toAlbum: true);
      if (!hasAccess) throw StateError('未获得相册写入权限');
      await Gal.putImageBytes(
        byteData.buffer.asUint8List(),
        album: 'GlamAR',
        name: 'GlamAR_${DateTime.now().millisecondsSinceEpoch}',
      );
      codec.dispose();
      source.dispose();
      photoOcclusionImage?.dispose();
      rendered.dispose();
      if (mounted) {
        setState(() => _showCaptureFlash = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (mounted) setState(() => _showCaptureFlash = false);
        _showMessage('妆容照片已保存到相册');
      }
    } on CameraException catch (error) {
      _showMessage('拍照失败：${error.description ?? error.code}');
    } on GalException catch (error) {
      _showMessage('保存失败：${error.type.message}');
    } catch (error) {
      _showMessage('拍照失败：$error');
    } finally {
      if (mounted &&
          _cameraController == controller &&
          controller.value.isInitialized) {
        try {
          await controller.startImageStream(_onCameraFrame);
        } catch (_) {
          // 生命周期切换时相机可能已经释放，resume 会重新初始化。
        }
      }
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xE81B171C),
        ),
      );
  }

  void _updateLayer(MakeupLayerConfig layer) {
    setState(() => _activeLook = _activeLook.withLayer(_selectedPart, layer));
  }

  void _resetSelectedPart() {
    setState(() {
      _activeLook = _activeLook.withLayer(
        _selectedPart,
        _presetLook.layer(_selectedPart),
      );
      if (_selectedPart == MakeupPart.lips) {
        _activeLook = _activeLook.withLipFinish(_presetLook.lipFinish);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _errorMessage != null
            ? _ErrorView(
                message: _errorMessage!,
                onBack: () => Navigator.of(context).pop(),
              )
            : _isInitializing
            ? _LoadingView(message: _statusMessage)
            : _buildCameraBody(),
      ),
    );
  }

  Widget _buildCameraBody() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Text('相机初始化失败', style: TextStyle(color: Colors.white70)),
      );
    }

    final previewSize = controller.value.previewSize;
    final nativeAspect = previewSize != null && previewSize.width > 0
        ? previewSize.height / previewSize.width
        : 16 / 9;

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final paintHeight = width / nativeAspect;
              final paintSize = Size(width, paintHeight);
              if (_paintSize != paintSize) {
                _paintSize = paintSize;
                _landmarkSmoother.reset();
                _updateTrackedLandmarks(_meshResult);
              }
              return SizedBox(
                width: width,
                child: AspectRatio(
                  aspectRatio: GlamARTheme.portraitCameraAspectRatio,
                  child: ClipRRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: width,
                        height: paintHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(controller),
                            if (_makeupVisible)
                              RepaintBoundary(
                                child: ListenableBuilder(
                                  listenable: _makeupLandmarks,
                                  builder: (context, _) {
                                    final pixels = _makeupLandmarks.value;
                                    if (pixels == null) {
                                      return const SizedBox.shrink();
                                    }
                                    final makeup = Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (_activeLook.complexion.enabled)
                                          _SkinSmoothingLayer(
                                            landmarks: pixels,
                                            config: _activeLook.complexion,
                                            renderContext: _renderContext,
                                          ),
                                        if (_activeLook.lips.enabled)
                                          _LipMaterialLayer(
                                            landmarks: pixels,
                                            config: _activeLook.lips,
                                            finish: _activeLook.lipFinish,
                                            renderContext: _renderContext,
                                          ),
                                        CustomPaint(
                                          painter: _FullMakeupPainter(
                                            landmarks: pixels,
                                            look: _activeLook,
                                            renderContext: _renderContext,
                                          ),
                                        ),
                                      ],
                                    );
                                    return ValueListenableBuilder<
                                      _OcclusionTexture?
                                    >(
                                      valueListenable: _occlusionTexture,
                                      child: makeup,
                                      builder: (context, texture, child) {
                                        if (texture == null) return child!;
                                        return _OcclusionMaskedMakeup(
                                          texture: texture,
                                          mirrorHorizontal: _mirrorHorizontal,
                                          child: child!,
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _TopBar(
          title: _activeLook.name,
          subtitle: _activeLook.subtitle,
          onBack: () => Navigator.of(context).pop(),
          onChangeLook: () => Navigator.of(context).pop(),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 56,
          right: 12,
          child: ValueListenableBuilder<_TrackingPerformance>(
            valueListenable: _trackingPerformance,
            builder: (context, performance, _) =>
                _PerformanceBadge(performance: performance),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: MakeupControlDock(
            look: _activeLook,
            selectedPart: _selectedPart,
            expanded: _panelExpanded,
            makeupVisible: _makeupVisible,
            isCapturing: _isCapturing,
            onToggleExpanded: () =>
                setState(() => _panelExpanded = !_panelExpanded),
            onSelectPart: (part) => setState(() => _selectedPart = part),
            onLayerChanged: _updateLayer,
            onLipFinishChanged: (finish) =>
                setState(() => _activeLook = _activeLook.withLipFinish(finish)),
            onResetPart: _resetSelectedPart,
            onToggleMakeup: () =>
                setState(() => _makeupVisible = !_makeupVisible),
            onCapture: _capturePhoto,
          ),
        ),
        if (!_isModelReady && _statusMessage.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            top: MediaQuery.of(context).size.height * 0.42,
            child: _ModelLoadingBanner(message: _statusMessage),
          ),
        if (_isModelReady && _landmarkCount == 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: _panelExpanded ? 354 : 112,
            child: const Center(child: _HintChip(text: '请将面部置于画面中央')),
          ),
        if (_showCaptureFlash)
          const Positioned.fill(
            child: IgnorePointer(child: ColoredBox(color: Colors.white)),
          ),
      ],
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: GlamARColors.rose),
          const SizedBox(height: 20),
          Text(
            message,
            style: TextStyle(
              color: GlamARColors.champagne.withValues(alpha: 0.85),
              fontSize: 14,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '首次启动需加载 AI 模型，约需 10~30 秒',
            style: TextStyle(
              color: GlamARColors.champagne.withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceBadge extends StatelessWidget {
  const _PerformanceBadge({required this.performance});

  final _TrackingPerformance performance;

  @override
  Widget build(BuildContext context) {
    final ready = performance.fps > 0;
    final healthy = performance.tracking && performance.fps >= 20;
    final accent = !ready
        ? Colors.white54
        : healthy
        ? const Color(0xFF8FE3B0)
        : GlamARColors.rose;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                ready
                    ? 'AR ${performance.fps.round()} FPS  ·  ${performance.inferenceMs.round()} ms'
                    : 'AR -- FPS',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 9,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelLoadingBanner extends StatelessWidget {
  const _ModelLoadingBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GlamARColors.rose.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: GlamARColors.rose,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: GlamARColors.champagne.withValues(alpha: 0.9),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onChangeLook,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback onChangeLook;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: GlamARColors.pearl,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: GlamARColors.pearl,
                      ),
                    ),
                    Text(
                      subtitle.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 8,
                        letterSpacing: 1.6,
                        color: GlamARColors.rose,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onChangeLook,
                icon: const Icon(Icons.grid_view_rounded, size: 15),
                label: const Text('换妆'),
                style: TextButton.styleFrom(
                  foregroundColor: GlamARColors.champagne,
                  backgroundColor: Colors.black.withValues(alpha: 0.38),
                  textStyle: const TextStyle(fontSize: 11),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FullMakeupPainter extends CustomPainter {
  const _FullMakeupPainter({
    required this.landmarks,
    required this.look,
    required this.renderContext,
  });

  final List<Offset> landmarks;
  final MakeupLook look;
  final FaceRenderContext renderContext;

  @override
  void paint(Canvas canvas, Size size) {
    MakeupRenderer.paintAll(
      canvas,
      size,
      landmarks,
      look,
      renderContext: renderContext,
    );
  }

  @override
  bool shouldRepaint(_FullMakeupPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks ||
      oldDelegate.look != look ||
      oldDelegate.renderContext != renderContext;
}

class _OcclusionMaskedMakeup extends StatelessWidget {
  const _OcclusionMaskedMakeup({
    required this.texture,
    required this.mirrorHorizontal,
    required this.child,
  });

  final _OcclusionTexture texture;
  final bool mirrorHorizontal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstOut,
      shaderCallback: (bounds) {
        final roi = texture.roi;
        final targetLeft = mirrorHorizontal
            ? (1 - roi.left - roi.width) * bounds.width
            : roi.left * bounds.width;
        final targetTop = roi.top * bounds.height;
        final targetWidth = roi.width * bounds.width;
        final targetHeight = roi.height * bounds.height;
        final transform = Matrix4.identity();
        if (mirrorHorizontal) {
          transform
            ..translateByDouble(targetLeft + targetWidth, targetTop, 0, 1)
            ..scaleByDouble(-targetWidth / 256, targetHeight / 256, 1, 1);
        } else {
          transform
            ..translateByDouble(targetLeft, targetTop, 0, 1)
            ..scaleByDouble(targetWidth / 256, targetHeight / 256, 1, 1);
        }
        return ui.ImageShader(
          texture.image,
          TileMode.decal,
          TileMode.decal,
          transform.storage,
        );
      },
      child: child,
    );
  }
}

class _SkinSmoothingLayer extends StatefulWidget {
  const _SkinSmoothingLayer({
    required this.landmarks,
    required this.config,
    required this.renderContext,
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig config;
  final FaceRenderContext renderContext;

  @override
  State<_SkinSmoothingLayer> createState() => _SkinSmoothingLayerState();
}

class _SkinSmoothingLayerState extends State<_SkinSmoothingLayer> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      final program = await MakeupShaderPrograms.skin();
      if (!mounted) return;
      _shader = program.fragmentShader();
      _updateUniforms();
      setState(() {});
    } catch (_) {
      // 非 Impeller 或个别 GPU 不支持时，build 会使用低强度模糊回退。
    }
  }

  @override
  void didUpdateWidget(_SkinSmoothingLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config ||
        oldWidget.renderContext != widget.renderContext) {
      _updateUniforms();
    }
  }

  void _updateUniforms() {
    final shader = _shader;
    if (shader == null) return;
    final config = widget.config;
    final color = widget.renderContext.adaptColor(config.color);
    final opacity = widget.renderContext.centralOpacity;
    shader
      ..setFloat(2, config.intensity * opacity * (0.18 + config.detail * 0.12))
      ..setFloat(3, color.r)
      ..setFloat(4, color.g)
      ..setFloat(5, color.b)
      ..setFloat(6, config.intensity * opacity * 0.055);
  }

  @override
  Widget build(BuildContext context) {
    final faceWidth = MakeupPainterUtils.faceWidth(widget.landmarks);
    final shader = _shader;
    final filter = shader != null && ui.ImageFilter.isShaderFilterSupported
        ? ui.ImageFilter.shader(shader)
        : ui.ImageFilter.blur(
            sigmaX: _skinSmoothingSigma(widget.config),
            sigmaY: _skinSmoothingSigma(widget.config),
          );
    return IgnorePointer(
      child: ClipPath(
        clipper: _FaceSkinClipper(
          landmarks: widget.landmarks,
          featurePadding: faceWidth * 0.018,
        ),
        clipBehavior: Clip.antiAlias,
        child: BackdropFilter(
          filter: filter,
          blendMode: BlendMode.srcOver,
          child: const _FilterCoveragePaint(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
}

double _skinSmoothingSigma(MakeupLayerConfig config) =>
    0.18 + config.intensity * (0.34 + config.detail * 0.22);

class _LipMaterialLayer extends StatefulWidget {
  const _LipMaterialLayer({
    required this.landmarks,
    required this.config,
    required this.finish,
    required this.renderContext,
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig config;
  final LipFinish finish;
  final FaceRenderContext renderContext;

  @override
  State<_LipMaterialLayer> createState() => _LipMaterialLayerState();
}

class _LipMaterialLayerState extends State<_LipMaterialLayer> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      final program = await MakeupShaderPrograms.lips();
      if (!mounted) return;
      _shader = program.fragmentShader();
      _updateUniforms();
      setState(() {});
    } catch (_) {
      // 保留 Canvas 唇妆作为兼容回退。
    }
  }

  @override
  void didUpdateWidget(_LipMaterialLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config ||
        oldWidget.finish != widget.finish ||
        oldWidget.renderContext != widget.renderContext) {
      _updateUniforms();
    }
  }

  void _updateUniforms() {
    final shader = _shader;
    if (shader == null) return;
    final color = widget.renderContext.adaptColor(widget.config.color);
    shader
      ..setFloat(2, color.r)
      ..setFloat(3, color.g)
      ..setFloat(4, color.b)
      ..setFloat(
        5,
        widget.config.intensity * widget.renderContext.centralOpacity,
      )
      ..setFloat(6, switch (widget.finish) {
        LipFinish.velvet => 0,
        LipFinish.satin => 0.48,
        LipFinish.glass => 1,
      });
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null || !ui.ImageFilter.isShaderFilterSupported) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ClipPath(
        clipper: _LipClipper(widget.landmarks),
        clipBehavior: Clip.antiAlias,
        child: BackdropFilter(
          filter: ui.ImageFilter.shader(shader),
          blendMode: BlendMode.srcOver,
          child: const _FilterCoveragePaint(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
}

class _LipClipper extends CustomClipper<Path> {
  const _LipClipper(this.landmarks);

  final List<Offset> landmarks;

  @override
  Path getClip(Size size) => MakeupPainterUtils.lipPath(landmarks);

  @override
  bool shouldReclip(_LipClipper oldClipper) =>
      oldClipper.landmarks != landmarks;
}

class _FilterCoveragePaint extends StatelessWidget {
  const _FilterCoveragePaint();

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _FilterCoveragePainter(),
    child: const SizedBox.expand(),
  );
}

class _FilterCoveragePainter extends CustomPainter {
  const _FilterCoveragePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color.fromARGB(1, 0, 0, 0);
    canvas.drawPoints(ui.PointMode.points, [
      Offset.zero,
      Offset(size.width - 1, 0),
      Offset(0, size.height - 1),
      Offset(size.width - 1, size.height - 1),
    ], paint);
  }

  @override
  bool shouldRepaint(_FilterCoveragePainter oldDelegate) => false;
}

class _FaceSkinClipper extends CustomClipper<Path> {
  const _FaceSkinClipper({
    required this.landmarks,
    required this.featurePadding,
  });

  final List<Offset> landmarks;
  final double featurePadding;

  @override
  Path getClip(Size size) =>
      MakeupPainterUtils.skinPath(landmarks, featurePadding: featurePadding);

  @override
  bool shouldReclip(_FaceSkinClipper oldClipper) =>
      oldClipper.landmarks != landmarks ||
      oldClipper.featurePadding != featurePadding;
}

class _HintChip extends StatelessWidget {
  const _HintChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: GlamARColors.champagne.withValues(alpha: 0.8),
          fontSize: 11,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off, color: GlamARColors.rose, size: 48),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: GlamARColors.champagne),
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: onBack,
              style: OutlinedButton.styleFrom(
                foregroundColor: GlamARColors.pearl,
                side: const BorderSide(color: GlamARColors.rose),
              ),
              child: const Text('返回首页'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingCameraFrame {
  const _PendingCameraFrame({required this.image, required this.receivedAt});

  final CameraImage image;
  final DateTime receivedAt;
}

class _PendingOcclusionFrame {
  const _PendingOcclusionFrame({required this.image, required this.roi});

  final CameraImage image;
  final FaceOcclusionRoi roi;
}

class _OcclusionTexture {
  const _OcclusionTexture({required this.image, required this.roi});

  final ui.Image image;
  final FaceOcclusionRoi roi;
}

class _TrackingPerformance {
  const _TrackingPerformance({
    this.fps = 0,
    this.inferenceMs = 0,
    this.tracking = false,
  });

  final double fps;
  final double inferenceMs;
  final bool tracking;
}
