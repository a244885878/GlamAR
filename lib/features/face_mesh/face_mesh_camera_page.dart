import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/face_mesh/models/normalized_face_frame.dart';
import 'package:glamar/features/face_mesh/utils/adaptive_landmark_smoother.dart';
import 'package:glamar/features/face_mesh/utils/ar_frame_timeline.dart';
import 'package:glamar/features/face_mesh/utils/ar_runtime_governor.dart';
import 'package:glamar/features/face_mesh/utils/face_occlusion_inference_worker.dart';
import 'package:glamar/features/face_mesh/utils/face_mesh_inference_worker.dart';
import 'package:glamar/features/makeup/models/face_render_context.dart';
import 'package:glamar/features/makeup/models/makeup_look.dart';
import 'package:glamar/features/makeup/painters/makeup_renderer.dart';
import 'package:glamar/features/makeup/painters/makeup_painter_utils.dart';
import 'package:glamar/features/makeup/rendering/ar_render_backend.dart';
import 'package:glamar/features/makeup/rendering/ar_render_packet.dart';
import 'package:glamar/features/makeup/rendering/flutter_composite_render_backend.dart';
import 'package:glamar/features/makeup/rendering/native_gpu_render_backend.dart';
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
  // A vendor EGL failure is a native process abort and cannot be caught by
  // Dart. Keep the custom Android renderer opt-in until a device allowlist is
  // established; Flutter/Impeller remains a complete GPU-backed renderer.
  static const bool _enableExperimentalAndroidOpenGl = bool.fromEnvironment(
    'GLAMAR_ANDROID_NATIVE_GPU',
  );
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

  final ValueNotifier<_TrackingPerformance> _trackingPerformance =
      ValueNotifier<_TrackingPerformance>(const _TrackingPerformance());
  final ValueNotifier<_OcclusionTexture?> _occlusionTexture =
      ValueNotifier<_OcclusionTexture?>(null);
  final AdaptiveLandmarkSmoother _landmarkSmoother = AdaptiveLandmarkSmoother();
  final ArFrameTimeline _frameTimeline = ArFrameTimeline();
  late final ArRenderBackend _renderBackend;
  late final Ticker _renderTicker;
  late MakeupLook _activeLook;
  late MakeupLook _presetLook;
  late ArMakeupMaterialState _materialState;
  final ArFaceRenderStateCache _faceRenderStateCache = ArFaceRenderStateCache();
  int _renderSubmissionSequence = 0;
  MakeupPart _selectedPart = MakeupPart.lips;
  bool _panelExpanded = false;
  bool _makeupVisible = true;
  bool _isCapturing = false;
  bool _showCaptureFlash = false;
  final GlobalKey _captureBoundaryKey = GlobalKey();
  bool _lifecyclePaused = false;
  int _cameraSessionGeneration = 0;
  Future<void>? _cameraSessionStartup;
  Future<void> _lifecycleTransition = Future<void>.value();

  Duration? _lastMeshFrameTimestamp;
  Duration? _lastValidMeshTimestamp;
  Duration? _performanceWindowStartedAt;
  int _performanceFrameCount = 0;
  double _inferenceMsEma = 0;
  int _consecutiveInferenceErrors = 0;
  int _consecutiveOcclusionErrors = 0;
  double _occlusionInferenceMsEma = 0;
  double _rasterFrameMsEma = 0;
  double _makeupTrackingOpacity = 1;
  double _runtimeRenderQuality = 1;
  bool _gpuSkinFilterEnabled = true;
  bool _pixelMaterialsEnabled = true;
  DateTime _nextOcclusionAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  FaceLighting _faceLighting = FaceLighting.neutral;
  FaceRenderContext _renderContext = const FaceRenderContext.neutral();

  @override
  void initState() {
    super.initState();
    _activeLook = widget.initialLook;
    _presetLook = widget.initialLook;
    _materialState = ArMakeupMaterialState.fromLook(_activeLook);
    _renderBackend = Platform.isIOS
        ? NativeGpuRenderBackend.iosMetal()
        : Platform.isAndroid && _enableExperimentalAndroidOpenGl
        ? NativeGpuRenderBackend.androidOpenGl()
        : FlutterCompositeRenderBackend();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _renderTicker = createTicker(_onRenderTick)..start();
    unawaited(MakeupShaderPrograms.warmUp().catchError((_) {}));
    _beginCameraSession();
  }

  void _beginCameraSession() {
    if (_cameraSessionStartup != null || _lifecyclePaused || !mounted) return;
    final generation = ++_cameraSessionGeneration;
    late final Future<void> startup;
    startup = _bootstrap(generation).whenComplete(() {
      if (identical(_cameraSessionStartup, startup)) {
        _cameraSessionStartup = null;
      }
    });
    _cameraSessionStartup = startup;
  }

  bool _isCurrentCameraSession(int generation) =>
      mounted && !_lifecyclePaused && generation == _cameraSessionGeneration;

  Future<void> _bootstrap(int generation) async {
    try {
      _updateStatus('正在检测摄像头...');
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError('检测摄像头超时，请重试。'),
      );
      if (cameras.isEmpty) {
        throw StateError('未找到可用摄像头。');
      }
      if (!_isCurrentCameraSession(generation)) return;

      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _updateStatus('正在启动相机...');
      await _startCamera(front, generation);

      if (_isCurrentCameraSession(generation)) {
        setState(() => _isInitializing = false);
      }
      if (!_isCurrentCameraSession(generation)) return;
      await _initFaceMeshModels(generation);
    } catch (error) {
      if (!_isCurrentCameraSession(generation)) return;
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

  Future<void> _initFaceMeshModels(int generation) async {
    try {
      _updateStatus('正在加载人脸模型...');
      final worker = await FaceMeshInferenceWorker.start();
      if (!_isCurrentCameraSession(generation)) {
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
      unawaited(_initOcclusionModel(generation));
    } catch (error) {
      if (!_isCurrentCameraSession(generation)) return;
      if (mounted) {
        setState(() => _errorMessage ??= '人脸模型加载失败: $error');
      } else {
        _errorMessage ??= '人脸模型加载失败: $error';
      }
    }
  }

  Future<void> _initOcclusionModel(int generation) async {
    try {
      final worker = await FaceOcclusionInferenceWorker.start();
      if (!_isCurrentCameraSession(generation)) {
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

  Future<void> _startCamera(CameraDescription camera, int generation) async {
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

    if (!_isCurrentCameraSession(generation)) {
      await controller.dispose();
      return;
    }

    setState(() => _cameraController = controller);
    try {
      await controller.startImageStream(_onCameraFrame);
    } catch (_) {
      if (identical(_cameraController, controller)) {
        _cameraController = null;
      }
      await controller.dispose();
      rethrow;
    }
  }

  void _onInferenceResult(
    FaceMeshResult? mesh, {
    required FaceLighting lighting,
    required ArFrameStamp sourceFrame,
    required Duration inferenceDuration,
  }) {
    _consecutiveInferenceErrors = 0;
    final hadFace = _landmarkCount >= 468;
    final hadRecentGeometry = _lastValidMeshTimestamp != null;
    _meshResult = mesh;
    if (mesh != null) {
      _landmarkCount = mesh.landmarks.length;
    }
    if (mesh != null) {
      // A failed detection carries neutral lighting because no trustworthy
      // face ROI exists. Preserve the last valid estimate during the tracking
      // bridge so makeup color does not pulse on a one-frame dropout.
      _faceLighting = FaceLighting.lerp(_faceLighting, lighting, 0.18);
      _lastValidMeshTimestamp = sourceFrame.capturedAt;
      _makeupTrackingOpacity = 1;
      final observedContext = FaceRenderContext.fromMesh(
        mesh,
        _faceLighting,
        runtimeDetailQuality: _runtimeRenderQuality,
      );
      _renderContext = hadRecentGeometry
          ? FaceRenderContext.stabilizeGeometry(
              _renderContext,
              observedContext,
              0.42,
            )
          : observedContext;
    }
    _lastMeshFrameTimestamp = sourceFrame.capturedAt;
    _updateTrackedLandmarks(mesh, sourceFrame: sourceFrame);
    _recordPerformance(inferenceDuration, mesh != null);

    if (mounted && hadFace != (_landmarkCount >= 468)) {
      setState(() {});
    }
  }

  void _updateTrackedLandmarks(
    FaceMeshResult? mesh, {
    ArFrameStamp? sourceFrame,
  }) {
    if (mesh == null) {
      _updateTrackingBridge(_frameTimeline.now);
      return;
    }

    final frame = _landmarkSmoother.observe(
      mesh: mesh,
      sourceSequence: sourceFrame?.sequence ?? 0,
      sourceTimestamp:
          sourceFrame?.capturedAt ??
          _lastMeshFrameTimestamp ??
          _frameTimeline.now,
      displayTimestamp: _frameTimeline.renderTimestamp,
      maximumPrediction: _frameTimeline.maximumPredictionHorizon,
    );
    if (frame != null) _submitRenderFrame(frame);
  }

  void _onRenderTick(Duration _) {
    final now = _frameTimeline.now;
    final renderTimestamp = _frameTimeline.renderTimestamp;
    if (!_makeupVisible) return;
    if (_meshResult == null) {
      _updateTrackingBridge(now);
      return;
    }
    if (!_landmarkSmoother.needsPredictionAt(
      renderTimestamp,
      maximumPrediction: _frameTimeline.maximumPredictionHorizon,
    )) {
      return;
    }
    final predicted = _landmarkSmoother.predict(
      displayTimestamp: renderTimestamp,
      maximumPrediction: _frameTimeline.maximumPredictionHorizon,
    );
    if (predicted != null) _submitRenderFrame(predicted);
  }

  void _updateTrackingBridge(Duration now) {
    final lastValid = _lastValidMeshTimestamp;
    if (lastValid == null || !_landmarkSmoother.hasFace) {
      _expireTrackingBridge();
      return;
    }
    final opacity = ArRuntimeGovernor.trackingOpacity(now - lastValid);
    if (opacity <= 0) {
      _expireTrackingBridge();
      return;
    }
    _makeupTrackingOpacity = opacity;
    final predicted = _landmarkSmoother.predict(
      displayTimestamp: _frameTimeline.renderTimestamp,
      maximumPrediction: _frameTimeline.maximumPredictionHorizon,
    );
    if (predicted != null) _submitRenderFrame(predicted);
  }

  void _expireTrackingBridge() {
    final hadFace = _landmarkCount >= 468;
    _makeupTrackingOpacity = 0;
    _lastValidMeshTimestamp = null;
    _landmarkCount = 0;
    _landmarkSmoother.reset();
    _renderBackend.clear();
    _clearOcclusionTexture();
    if (hadFace && mounted) setState(() {});
  }

  void _submitRenderFrame(NormalizedFaceFrame frame) {
    _renderBackend.submit(
      ArRenderPacket(
        submissionSequence: ++_renderSubmissionSequence,
        faceFrame: frame,
        material: _materialState,
        faceState: _faceRenderStateCache.resolve(
          context: _renderContext,
          trackingOpacity: _makeupTrackingOpacity,
          runtimeDetailQuality: _runtimeRenderQuality,
          skinFilterEnabled: _gpuSkinFilterEnabled,
          pixelMaterialEnabled:
              ui.ImageFilter.isShaderFilterSupported && _pixelMaterialsEnabled,
        ),
        mirrorHorizontal: _mirrorHorizontal,
      ),
    );
  }

  void _refreshMaterialAndRender() {
    _materialState = ArMakeupMaterialState.fromLook(_activeLook);
    final frame = _renderBackend.frames.value?.faceFrame;
    if (frame != null) _submitRenderFrame(frame);
  }

  void _recordPerformance(Duration duration, bool trackedFace) {
    final now = _frameTimeline.now;
    _performanceWindowStartedAt ??= now;
    _performanceFrameCount++;
    final currentMs = duration.inMicroseconds / 1000;
    _inferenceMsEma = _inferenceMsEma == 0
        ? currentMs
        : _inferenceMsEma * 0.82 + currentMs * 0.18;

    final window = now - _performanceWindowStartedAt!;
    if (window < const Duration(milliseconds: 600)) return;
    final fps =
        _performanceFrameCount /
        (window.inMicroseconds / Duration.microsecondsPerSecond);
    _trackingPerformance.value = _TrackingPerformance(
      fps: fps,
      inferenceMs: _inferenceMsEma,
      pipelineLatencyMs: _frameTimeline.pipelineLatencyMs,
      nativeGpuMs: _nativeRenderBackend?.nativeRenderMs.value ?? 0,
      rasterFrameMs: _rasterFrameMsEma,
      thermalPressure: _nativeRenderBackend?.thermalPressure.value ?? 0,
      tracking: trackedFace,
    );
    _updateRuntimeRenderQuality(
      fps,
      _inferenceMsEma,
      _nativeRenderBackend?.nativeRenderMs.value ?? 0,
      _rasterFrameMsEma,
      _nativeRenderBackend?.thermalPressure.value ?? 0,
    );
    _performanceWindowStartedAt = now;
    _performanceFrameCount = 0;
  }

  void _updateRuntimeRenderQuality(
    double fps,
    double inferenceMs,
    double nativeGpuMs,
    double rasterFrameMs,
    double thermalPressure,
  ) {
    final target = ArRuntimeGovernor.renderDetailQuality(
      faceFps: fps,
      faceInferenceMs: inferenceMs,
      gpuRenderMs: nativeGpuMs,
      rasterFrameMs: rasterFrameMs,
      thermalPressure: thermalPressure,
    );
    final response = target < _runtimeRenderQuality ? 0.55 : 0.16;
    _runtimeRenderQuality += (target - _runtimeRenderQuality) * response;
    // 使用不同的关闭/恢复阈值，避免 FPS 在边界附近时反复创建滤镜层。
    if (_gpuSkinFilterEnabled && _runtimeRenderQuality < 0.5) {
      _gpuSkinFilterEnabled = false;
    } else if (!_gpuSkinFilterEnabled && _runtimeRenderQuality > 0.74) {
      _gpuSkinFilterEnabled = true;
    }
    // 像素材质会改变原生底色的混合权重，必须用滞回避免临界负载下
    // 两条链路频繁切换产生肉眼可见的明暗闪烁。
    if (_pixelMaterialsEnabled && _runtimeRenderQuality < 0.7) {
      _pixelMaterialsEnabled = false;
    } else if (!_pixelMaterialsEnabled && _runtimeRenderQuality > 0.84) {
      _pixelMaterialsEnabled = true;
    }
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final currentMs = timing.rasterDuration.inMicroseconds / 1000;
      _rasterFrameMsEma = _rasterFrameMsEma == 0
          ? currentMs
          : _rasterFrameMsEma * 0.88 + currentMs * 0.12;
    }
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
      stamp: _frameTimeline.markCameraFrame(),
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
      _frameTimeline.markInferenceCompleted(pending.stamp);
      _onInferenceResult(
        sample.mesh,
        lighting: sample.lighting,
        sourceFrame: pending.stamp,
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
      final currentMs = mask.inferenceDuration.inMicroseconds / 1000;
      _occlusionInferenceMsEma = _occlusionInferenceMsEma == 0
          ? currentMs
          : _occlusionInferenceMsEma * 0.78 + currentMs * 0.22;
      final currentMesh = _meshResult;
      final bridgeIsActive =
          currentMesh == null && _lastValidMeshTimestamp != null;
      if (bridgeIsActive ||
          (currentMesh != null &&
              mask.roi.isAlignedWith(_occlusionRoiForMesh(currentMesh)))) {
        await _updateOcclusionTexture(mask);
      }
    } catch (_) {
      _consecutiveOcclusionErrors++;
      _occlusionWorker?.reset();
      if (_consecutiveOcclusionErrors >= 3) {
        _isOcclusionReady = false;
        _clearOcclusionTexture();
      }
    } finally {
      _occlusionBusy = false;
      final performance = _trackingPerformance.value;
      _nextOcclusionAllowedAt = DateTime.now().add(
        ArRuntimeGovernor.occlusionCooldown(
          faceFps: performance.fps,
          faceInferenceMs: performance.inferenceMs,
          occlusionInferenceMs: _occlusionInferenceMsEma,
          thermalPressure: _nativeRenderBackend?.thermalPressure.value ?? 0,
        ),
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
    _occlusionInferenceMsEma = 0;
    _rasterFrameMsEma = 0;
    _makeupTrackingOpacity = 1;
    _runtimeRenderQuality = 1;
    _gpuSkinFilterEnabled = true;
    _pixelMaterialsEnabled = true;
    _faceLighting = FaceLighting.neutral;
    _renderContext = const FaceRenderContext.neutral();
    _faceRenderStateCache.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lifecyclePaused = false;
      _queueLifecycleTransition(_resumeCameraSession);
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _lifecyclePaused = true;
      _cameraSessionGeneration++;
      _queueLifecycleTransition(_suspendCameraSession);
    }
  }

  void _queueLifecycleTransition(Future<void> Function() transition) {
    _lifecycleTransition = _lifecycleTransition
        .then((_) => transition())
        .catchError((Object _) {
          // Lifecycle events can race vendor camera teardown. The next resume
          // transition retries a clean session instead of surfacing a stale
          // platform exception.
        });
  }

  Future<void> _suspendCameraSession() async {
    final startup = _cameraSessionStartup;
    if (startup != null) await startup.catchError((Object _) {});

    _stopInferenceStream();
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {
        // Some Android vendors stop the stream as soon as the app is hidden.
      }
      await controller.dispose().catchError((Object _) {});
    }

    final inferenceWorker = _inferenceWorker;
    _inferenceWorker = null;
    if (inferenceWorker != null) await inferenceWorker.close();
    final occlusionWorker = _occlusionWorker;
    _occlusionWorker = null;
    if (occlusionWorker != null) await occlusionWorker.close();

    _isOcclusionReady = false;
    _clearOcclusionTexture();
    _isModelReady = false;
    _meshResult = null;
    _landmarkCount = 0;
    _lastValidMeshTimestamp = null;
    _makeupTrackingOpacity = 0;
    _frameTimeline.reset();
    _landmarkSmoother.reset();
    _renderBackend.clear();
  }

  Future<void> _resumeCameraSession() async {
    if (_lifecyclePaused || !mounted) return;
    if (_cameraController?.value.isInitialized ?? false) return;
    setState(() {
      _isInitializing = true;
      _statusMessage = '正在恢复相机...';
      _errorMessage = null;
    });
    _beginCameraSession();
    final startup = _cameraSessionStartup;
    if (startup != null) await startup;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _renderTicker.dispose();
    _lifecyclePaused = true;
    _cameraSessionGeneration++;
    _stopInferenceStream();
    _cameraController?.dispose();
    unawaited(_inferenceWorker?.close());
    _inferenceWorker = null;
    unawaited(_occlusionWorker?.close());
    _occlusionWorker = null;
    _clearOcclusionTexture();
    _renderBackend.dispose();
    _trackingPerformance.dispose();
    _occlusionTexture.dispose();
    super.dispose();
  }

  bool get _mirrorHorizontal {
    final controller = _cameraController;
    return !Platform.isIOS &&
        controller?.description.lensDirection == CameraLensDirection.front;
  }

  ArNativeTextureRenderBackend? get _nativeRenderBackend {
    final backend = _renderBackend;
    return backend is ArNativeTextureRenderBackend ? backend : null;
  }

  Future<void> _capturePhoto() async {
    final controller = _cameraController;
    if (_isCapturing || controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_meshResult == null) {
      _showMessage('请先将面部置于画面中央');
      return;
    }

    setState(() => _isCapturing = true);
    try {
      // Keep the CameraX analysis stream alive. On a subset of Android 16
      // devices, switching from ImageAnalysis to takePicture tears down the
      // Flutter SurfaceProducer and can SIGSEGV in libflutter's IO worker.
      // Capturing the isolated preview layer is also true WYSIWYG: camera,
      // smoothing, makeup materials and occlusion all come from one frame.
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _captureBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.attached) {
        throw StateError('拍照画面尚未就绪');
      }
      final devicePixelRatio = View.of(
        _captureBoundaryKey.currentContext!,
      ).devicePixelRatio;
      final captureRatio = devicePixelRatio.clamp(1.0, 2.0).toDouble();
      final renderedPhoto = await boundary.toImage(pixelRatio: captureRatio);
      final byteData = await renderedPhoto.toByteData(
        format: ui.ImageByteFormat.png,
      );
      renderedPhoto.dispose();
      if (byteData == null) throw StateError('照片编码失败');
      var hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) hasAccess = await Gal.requestAccess(toAlbum: true);
      if (!hasAccess) throw StateError('未获得相册写入权限');
      await Gal.putImageBytes(
        byteData.buffer.asUint8List(),
        album: 'GlamAR',
        name: 'GlamAR_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        setState(() => _showCaptureFlash = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (mounted) setState(() => _showCaptureFlash = false);
        _showMessage('妆容照片已保存到相册');
      }
    } on CameraException catch (error) {
      _showMessage('拍照失败：${error.description ?? error.code}');
    } on GalException catch (error) {
      debugPrint('GlamAR capture gallery error: ${error.type.message}');
      _showMessage('保存失败：${error.type.message}');
    } catch (error) {
      debugPrint('GlamAR capture error: $error');
      _showMessage('拍照失败：$error');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                color: GlamARColors.rose,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: GlamARColors.pearl,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xE81B171C),
          elevation: 12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: GlamARColors.rose.withValues(alpha: 0.35),
            ),
          ),
        ),
      );
  }

  void _updateLayer(MakeupLayerConfig layer) {
    setState(() => _activeLook = _activeLook.withLayer(_selectedPart, layer));
    _refreshMaterialAndRender();
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
    _refreshMaterialAndRender();
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
                        child: RepaintBoundary(
                          key: _captureBoundaryKey,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraPreview(controller),
                              if (_makeupVisible)
                                RepaintBoundary(
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge(<Listenable>[
                                      _renderBackend.frames,
                                      if (_renderBackend
                                          case final ArNativeTextureRenderBackend
                                              nativeBackend)
                                        nativeBackend.nativeSurface,
                                    ]),
                                    builder: (context, _) {
                                      final packet =
                                          _renderBackend.frames.value;
                                      if (packet == null) {
                                        return const SizedBox.shrink();
                                      }
                                      final nativeBackend =
                                          _nativeRenderBackend;
                                      final nativeSurface =
                                          nativeBackend?.nativeSurface.value;
                                      final nativeParts = nativeSurface == null
                                          ? const <MakeupPart>{}
                                          : nativeBackend!.nativeParts;
                                      final pixels = packet.faceFrame
                                          .projectToPixels(
                                            paintSize,
                                            mirrorHorizontal:
                                                packet.mirrorHorizontal,
                                          );
                                      final look = packet.material.look;
                                      final faceState = packet.faceState;
                                      final renderContext = faceState.context;
                                      final makeup = Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (look.complexion.enabled &&
                                              faceState.skinFilterEnabled)
                                            _SkinSmoothingLayer(
                                              landmarks: pixels,
                                              config: look.complexion,
                                              renderContext: renderContext,
                                            ),
                                          CustomPaint(
                                            painter: _FullMakeupPainter(
                                              landmarks: pixels,
                                              look: look,
                                              renderContext: renderContext,
                                              excludedParts: nativeParts,
                                            ),
                                          ),
                                          if (nativeSurface != null)
                                            IgnorePointer(
                                              child: Texture(
                                                textureId:
                                                    nativeSurface.textureId,
                                                filterQuality:
                                                    FilterQuality.medium,
                                              ),
                                            ),
                                          if ((look.blush.enabled ||
                                                  look.eyeshadow.enabled) &&
                                              faceState.pixelMaterialEnabled &&
                                              nativeSurface != null)
                                            _FaceColorMaterialLayer(
                                              landmarks: pixels,
                                              blush: look.blush,
                                              eyeshadow: look.eyeshadow,
                                              renderContext: renderContext,
                                            ),
                                          if (look.lips.enabled &&
                                              faceState.pixelMaterialEnabled &&
                                              nativeSurface != null)
                                            _LipMaterialLayer(
                                              landmarks: pixels,
                                              config: look.lips,
                                              finish: look.lipFinish,
                                              renderContext: renderContext,
                                            ),
                                        ],
                                      );
                                      return ValueListenableBuilder<
                                        _OcclusionTexture?
                                      >(
                                        valueListenable: _occlusionTexture,
                                        child: makeup,
                                        builder: (context, texture, child) {
                                          Widget rendered = child!;
                                          if (texture != null) {
                                            rendered = _OcclusionMaskedMakeup(
                                              texture: texture,
                                              mirrorHorizontal:
                                                  packet.mirrorHorizontal,
                                              child: rendered,
                                            );
                                          }
                                          if (faceState.trackingOpacity >=
                                              0.999) {
                                            return rendered;
                                          }
                                          return Opacity(
                                            opacity: faceState.trackingOpacity,
                                            child: rendered,
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
                ),
              );
            },
          ),
        ),
        if (_panelExpanded)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('makeup-panel-dismiss-area'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _panelExpanded = false),
              child: const SizedBox.expand(),
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
            onLipFinishChanged: (finish) {
              setState(() => _activeLook = _activeLook.withLipFinish(finish));
              _refreshMaterialAndRender();
            },
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
                    ? 'AR ${performance.fps.round()} FPS  ·  E2E ${performance.pipelineLatencyMs.round()} ms  ·  GPU ${performance.nativeGpuMs.toStringAsFixed(1)}  ·  R ${performance.rasterFrameMs.toStringAsFixed(1)} ms${performance.thermalPressure > 0.5 ? '  ·  温控' : ''}'
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
    this.excludedParts = const <MakeupPart>{},
  });

  final List<Offset> landmarks;
  final MakeupLook look;
  final FaceRenderContext renderContext;
  final Set<MakeupPart> excludedParts;

  @override
  void paint(Canvas canvas, Size size) {
    MakeupRenderer.paintAll(
      canvas,
      size,
      landmarks,
      look,
      renderContext: renderContext,
      excludedParts: excludedParts,
    );
  }

  @override
  bool shouldRepaint(_FullMakeupPainter oldDelegate) =>
      oldDelegate.landmarks != landmarks ||
      oldDelegate.look != look ||
      oldDelegate.renderContext != renderContext ||
      oldDelegate.excludedParts != excludedParts;
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
      ..setFloat(2, config.intensity * opacity * (0.34 + config.detail * 0.2))
      ..setFloat(3, color.r)
      ..setFloat(4, color.g)
      ..setFloat(5, color.b)
      ..setFloat(6, config.intensity * opacity * 0.085)
      ..setFloat(7, 0.86 - config.detail * 0.22)
      ..setFloat(8, widget.renderContext.lighting.exposure)
      ..setFloat(9, widget.renderContext.lighting.skinChroma)
      ..setFloat(10, widget.renderContext.lighting.localContrast);
  }

  @override
  Widget build(BuildContext context) {
    final faceWidth = MakeupPainterUtils.faceWidth(widget.landmarks);
    final shader = _shader;
    final filter = shader != null && ui.ImageFilter.isShaderFilterSupported
        ? ui.ImageFilter.shader(shader)
        : ui.ImageFilter.blur(
            sigmaX: _skinSmoothingSigma(widget.config) * _fallbackLightingGuard,
            sigmaY: _skinSmoothingSigma(widget.config) * _fallbackLightingGuard,
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

  double get _fallbackLightingGuard {
    final lighting = widget.renderContext.lighting;
    final exposure = ((lighting.exposure - 0.16) / 0.36).clamp(0.0, 1.0);
    final contrast = ((lighting.localContrast - 0.035) / 0.145).clamp(0.0, 1.0);
    return (0.82 + exposure * 0.18) * (0.86 + contrast * 0.14);
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
}

double _skinSmoothingSigma(MakeupLayerConfig config) =>
    0.24 + config.intensity * (0.48 + config.detail * 0.36);

typedef _ColorMaterialShapes = ({Rect first, Rect second, double angle});

_ColorMaterialShapes _colorMaterialShapes({
  required List<Offset> landmarks,
  required MakeupLayerConfig config,
  required FaceRenderContext renderContext,
  required MakeupPart part,
}) {
  final faceAngle = math.atan2(
    landmarks[263].dy - landmarks[33].dy,
    landmarks[263].dx - landmarks[33].dx,
  );
  if (part == MakeupPart.blush) {
    final shapes = <Rect>[];
    final faceCenter = landmarks[1];
    for (final (anchor, edge, high) in <(int, int, int)>[
      (117, 234, 50),
      (346, 454, 280),
    ]) {
      final raw = landmarks[anchor];
      final center = Offset.lerp(
        raw,
        landmarks[high],
        0.12 + config.detail * 0.2,
      )!;
      final pulled = Offset.lerp(center, faceCenter, 0.05)!;
      final span = math.max((raw - landmarks[edge]).distance, 1.0);
      shapes.add(
        Rect.fromCenter(
          center: pulled,
          width: span * (1.35 + config.detail * 0.34),
          height: span * (0.84 + (1 - config.detail) * 0.26),
        ),
      );
    }
    return (first: shapes.first, second: shapes.last, angle: faceAngle);
  }

  final shapes = <Rect>[];
  for (final (indices, sideA) in <(List<int>, bool)>[
    (MakeupPainterUtils.leftEyeUpper, true),
    (MakeupPainterUtils.rightEyeUpper, false),
  ]) {
    final points = indices.map((index) => landmarks[index]).toList();
    final axis = points.last - points.first;
    final axisLength = math.max(axis.distance, 1.0);
    var normal = Offset(-axis.dy, axis.dx) / axisLength;
    if (normal.dy > 0) normal = -normal;
    final center = points.reduce((a, b) => a + b) / points.length.toDouble();
    final blinkStability =
        0.62 + renderContext.eyeOpennessForSide(sideA: sideA) * 0.38;
    final lift = axisLength * (0.2 + config.detail * 0.14) * blinkStability;
    shapes.add(
      Rect.fromCenter(
        center: center + normal * lift * 0.48,
        width: axisLength * 1.08,
        height: math.max(lift * 1.35, 1.0),
      ),
    );
  }
  return (first: shapes.first, second: shapes.last, angle: faceAngle);
}

class _FaceColorMaterialLayer extends StatefulWidget {
  const _FaceColorMaterialLayer({
    required this.landmarks,
    required this.blush,
    required this.eyeshadow,
    required this.renderContext,
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig blush;
  final MakeupLayerConfig eyeshadow;
  final FaceRenderContext renderContext;

  @override
  State<_FaceColorMaterialLayer> createState() =>
      _FaceColorMaterialLayerState();
}

class _FaceColorMaterialLayerState extends State<_FaceColorMaterialLayer> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      final program = await MakeupShaderPrograms.faceColorMaterial();
      if (!mounted) return;
      _shader = program.fragmentShader();
      _updateMaterialUniforms();
      setState(() {});
    } catch (_) {
      // 原生 GPU 底色会继续显示，组合材质不可用时保持稳定回退。
    }
  }

  @override
  void didUpdateWidget(_FaceColorMaterialLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blush != widget.blush ||
        oldWidget.eyeshadow != widget.eyeshadow ||
        oldWidget.renderContext != widget.renderContext) {
      _updateMaterialUniforms();
    }
  }

  void _updateMaterialUniforms() {
    final shader = _shader;
    if (shader == null) return;
    final blushPrimary = widget.renderContext.adaptColor(widget.blush.color);
    final blushSecondary = widget.renderContext.adaptColor(
      widget.blush.secondaryColor ?? widget.blush.color,
    );
    final eyePrimary = widget.renderContext.adaptColor(widget.eyeshadow.color);
    final eyeSecondary = widget.renderContext.adaptColor(
      widget.eyeshadow.secondaryColor ?? widget.eyeshadow.color,
    );
    shader
      ..setFloat(2, blushPrimary.r)
      ..setFloat(3, blushPrimary.g)
      ..setFloat(4, blushPrimary.b)
      ..setFloat(5, blushSecondary.r)
      ..setFloat(6, blushSecondary.g)
      ..setFloat(7, blushSecondary.b)
      ..setFloat(
        8,
        widget.blush.enabled
            ? widget.blush.intensity *
                  widget.renderContext.profileOpacity *
                  0.21
            : 0,
      )
      ..setFloat(9, widget.blush.detail)
      ..setFloat(20, widget.renderContext.opacityForSide(sideA: true))
      ..setFloat(21, widget.renderContext.opacityForSide(sideA: false))
      ..setFloat(22, eyePrimary.r)
      ..setFloat(23, eyePrimary.g)
      ..setFloat(24, eyePrimary.b)
      ..setFloat(25, eyeSecondary.r)
      ..setFloat(26, eyeSecondary.g)
      ..setFloat(27, eyeSecondary.b)
      ..setFloat(
        28,
        widget.eyeshadow.enabled
            ? widget.eyeshadow.intensity *
                  widget.renderContext.profileOpacity *
                  0.28
            : 0,
      )
      ..setFloat(29, widget.eyeshadow.detail)
      ..setFloat(38, widget.renderContext.detailOpacityForSide(sideA: true))
      ..setFloat(39, widget.renderContext.detailOpacityForSide(sideA: false));
  }

  void _writeShape(int offset, Rect rect, Size size) {
    _shader!
      ..setFloat(offset, rect.center.dx / size.width)
      ..setFloat(offset + 1, rect.center.dy / size.height)
      ..setFloat(offset + 2, rect.width * 0.5 / size.width)
      ..setFloat(offset + 3, rect.height * 0.5 / size.height);
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null || !ui.ImageFilter.isShaderFilterSupported) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isEmpty && MakeupPainterUtils.valid(widget.landmarks)) {
          final blushShapes = _colorMaterialShapes(
            landmarks: widget.landmarks,
            config: widget.blush,
            renderContext: widget.renderContext,
            part: MakeupPart.blush,
          );
          final eyeShapes = _colorMaterialShapes(
            landmarks: widget.landmarks,
            config: widget.eyeshadow,
            renderContext: widget.renderContext,
            part: MakeupPart.eyeshadow,
          );
          _writeShape(10, blushShapes.first, size);
          _writeShape(14, blushShapes.second, size);
          shader
            ..setFloat(18, math.cos(-blushShapes.angle))
            ..setFloat(19, math.sin(-blushShapes.angle));
          _writeShape(30, eyeShapes.first, size);
          _writeShape(34, eyeShapes.second, size);
        }
        return IgnorePointer(
          child: ClipPath(
            clipper: _FaceColorMaterialClipper(
              landmarks: widget.landmarks,
              blush: widget.blush,
              eyeshadow: widget.eyeshadow,
              renderContext: widget.renderContext,
            ),
            clipBehavior: Clip.antiAlias,
            child: BackdropFilter(
              filter: ui.ImageFilter.shader(shader),
              blendMode: BlendMode.srcOver,
              child: const _FilterCoveragePaint(),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
}

class _FaceColorMaterialClipper extends CustomClipper<Path> {
  const _FaceColorMaterialClipper({
    required this.landmarks,
    required this.blush,
    required this.eyeshadow,
    required this.renderContext,
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig blush;
  final MakeupLayerConfig eyeshadow;
  final FaceRenderContext renderContext;

  @override
  Path getClip(Size size) {
    final result = Path();
    if (blush.enabled) {
      result.addPath(
        _ColorMaterialClipper(
          landmarks: landmarks,
          config: blush,
          renderContext: renderContext,
          part: MakeupPart.blush,
        ).getClip(size),
        Offset.zero,
      );
    }
    if (eyeshadow.enabled) {
      result.addPath(
        _ColorMaterialClipper(
          landmarks: landmarks,
          config: eyeshadow,
          renderContext: renderContext,
          part: MakeupPart.eyeshadow,
        ).getClip(size),
        Offset.zero,
      );
    }
    return result;
  }

  @override
  bool shouldReclip(_FaceColorMaterialClipper oldClipper) =>
      oldClipper.landmarks != landmarks ||
      oldClipper.blush != blush ||
      oldClipper.eyeshadow != eyeshadow ||
      oldClipper.renderContext != renderContext;
}

class _ColorMaterialClipper extends CustomClipper<Path> {
  const _ColorMaterialClipper({
    required this.landmarks,
    required this.config,
    required this.renderContext,
    required this.part,
  });

  final List<Offset> landmarks;
  final MakeupLayerConfig config;
  final FaceRenderContext renderContext;
  final MakeupPart part;

  @override
  Path getClip(Size size) {
    if (!MakeupPainterUtils.valid(landmarks)) return Path();
    return switch (part) {
      MakeupPart.blush => _blushPath(),
      MakeupPart.eyeshadow => _eyeshadowPath(),
      _ => Path(),
    };
  }

  Path _blushPath() {
    final result = Path();
    final shapes = _colorMaterialShapes(
      landmarks: landmarks,
      config: config,
      renderContext: renderContext,
      part: MakeupPart.blush,
    );
    for (final rect in <Rect>[shapes.first, shapes.second]) {
      final oval = Path()..addOval(rect);
      final transform = Matrix4.identity()
        ..translateByDouble(rect.center.dx, rect.center.dy, 0, 1)
        ..rotateZ(shapes.angle)
        ..translateByDouble(-rect.center.dx, -rect.center.dy, 0, 1);
      result.addPath(oval.transform(transform.storage), Offset.zero);
    }
    return result;
  }

  Path _eyeshadowPath() {
    final result = Path();
    for (final (indices, sideA) in <(List<int>, bool)>[
      (MakeupPainterUtils.leftEyeUpper, true),
      (MakeupPainterUtils.rightEyeUpper, false),
    ]) {
      final points = indices.map((index) => landmarks[index]).toList();
      final axis = points.last - points.first;
      var normal = Offset(-axis.dy, axis.dx) / math.max(axis.distance, 0.001);
      if (normal.dy > 0) normal = -normal;
      final blinkStability =
          0.62 + renderContext.eyeOpennessForSide(sideA: sideA) * 0.38;
      final lift =
          axis.distance * (0.2 + config.detail * 0.14) * blinkStability;
      result.addPath(
        MakeupPainterUtils.smoothClosedOffsets(<Offset>[
          ...points,
          ...points.reversed.map((point) => point + normal * lift),
        ]),
        Offset.zero,
      );
    }
    return result;
  }

  @override
  bool shouldReclip(_ColorMaterialClipper oldClipper) =>
      oldClipper.landmarks != landmarks ||
      oldClipper.config != config ||
      oldClipper.renderContext != renderContext ||
      oldClipper.part != part;
}

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
      })
      ..setFloat(7, widget.config.detail)
      ..setFloat(8, widget.renderContext.mouthOpenness);
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
  const _PendingCameraFrame({required this.image, required this.stamp});

  final CameraImage image;
  final ArFrameStamp stamp;
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
    this.pipelineLatencyMs = 0,
    this.nativeGpuMs = 0,
    this.rasterFrameMs = 0,
    this.thermalPressure = 0,
    this.tracking = false,
  });

  final double fps;
  final double inferenceMs;
  final double pipelineLatencyMs;
  final double nativeGpuMs;
  final double rasterFrameMs;
  final double thermalPressure;
  final bool tracking;
}
