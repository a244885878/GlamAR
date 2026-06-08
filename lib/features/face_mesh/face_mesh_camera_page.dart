import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/face_mesh/utils/face_mesh_camera_image_adapter.dart';
import 'package:mediapipe_face_mesh/face_mesh_painter.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';
class FaceMeshCameraPage extends StatefulWidget {
  const FaceMeshCameraPage({super.key});

  @override
  State<FaceMeshCameraPage> createState() => _FaceMeshCameraPageState();
}

class _FaceMeshCameraPageState extends State<FaceMeshCameraPage>
    with WidgetsBindingObserver {
  static const Map<DeviceOrientation, int> _orientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  CameraController? _cameraController;
  FaceDetectorProcessor? _detector;
  FaceMeshProcessor? _meshProcessor;
  FaceMeshInferenceStreamProcessor? _streamProcessor;

  StreamController<FaceMeshNv21Image>? _nv21Controller;
  StreamController<FaceMeshImage>? _bgraController;
  StreamSubscription<FaceMeshInferenceResult>? _inferenceSubscription;
  int? _streamRotation;

  FaceMeshResult? _meshResult;
  int _landmarkCount = 0;
  String? _errorMessage;
  bool _isInitializing = true;
  bool _isModelReady = false;
  bool _isProcessingFrame = false;
  bool _showSkeleton = true;
  double _inferenceFps = 0;
  String _statusMessage = '正在启动相机...';

  DateTime? _lastInferenceTime;
  DateTime? _lastFpsUpdate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      _detector = await _createDetectorProcessor();
      _meshProcessor = await _createMeshProcessor();
      _streamProcessor = FaceMeshInferenceStreamProcessor(
        FaceMeshInferencePipeline(
          detector: _detector!,
          mesh: _meshProcessor!,
        ),
      );
      if (mounted) {
        setState(() {
          _isModelReady = true;
          _statusMessage = '';
        });
      } else {
        _isModelReady = true;
        _statusMessage = '';
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage ??= '人脸模型加载失败: $error');
      } else {
        _errorMessage ??= '人脸模型加载失败: $error';
      }
    }
  }

  Future<FaceDetectorProcessor> _createDetectorProcessor() async {
    return _createWithDelegateFallback(
      (delegate) => FaceDetectorProcessor.create(
        model: FaceDetectionModel.shortRange,
        delegate: delegate,
        maxResults: 1,
        roiScaleY: 1.7,
        roiShiftY: -0.2,
      ),
    );
  }

  Future<FaceMeshProcessor> _createMeshProcessor() async {
    return _createWithDelegateFallback(
      (delegate) => FaceMeshProcessor.create(
        delegate: delegate,
        enableSmoothing: true,
        enableRoiTracking: true,
        enableIris: true,
      ),
    );
  }

  Future<T> _createWithDelegateFallback<T>(
    Future<T> Function(FaceMeshDelegate delegate) create,
  ) async {
    const timeout = Duration(seconds: 20);
    for (final delegate in [
      FaceMeshDelegate.cpu,
      FaceMeshDelegate.xnnpack,
    ]) {
      try {
        return await create(delegate).timeout(timeout);
      } on TimeoutException {
        continue;
      }
    }
    throw StateError('人脸模型初始化超时，请重启应用后重试。');
  }

  Future<void> _startCamera(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
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

  void _ensureInferenceStream(int rotationDegrees) {
    if (_inferenceSubscription != null && _streamRotation == rotationDegrees) {
      return;
    }
    _stopInferenceStream();
    _streamRotation = rotationDegrees;

    if (Platform.isAndroid) {
      _nv21Controller = StreamController<FaceMeshNv21Image>();
      _inferenceSubscription = _streamProcessor!
          .processNv21(
            _nv21Controller!.stream,
            runMeshResolver: (_) => true,
            rotationDegrees: rotationDegrees,
          )
          .listen(_onInferenceResult, onError: _onInferenceError);
    } else if (Platform.isIOS) {
      _bgraController = StreamController<FaceMeshImage>();
      _inferenceSubscription = _streamProcessor!
          .process(
            _bgraController!.stream,
            runMeshResolver: (_) => true,
            rotationDegrees: rotationDegrees,
          )
          .listen(_onInferenceResult, onError: _onInferenceError);
    }
  }

  void _onInferenceResult(FaceMeshInferenceResult result) {
    _isProcessingFrame = false;
    _updateInferenceFps();

    final mesh = result.meshResult;
    if (!mounted) {
      return;
    }
    setState(() {
      _meshResult = mesh;
      _landmarkCount = mesh?.landmarks.length ?? 0;
    });
  }

  void _onInferenceError(Object error) {
    _isProcessingFrame = false;
    if (mounted) {
      setState(() => _errorMessage ??= '$error');
    }
  }

  void _updateInferenceFps() {
    final now = DateTime.now();
    final prev = _lastInferenceTime;
    _lastInferenceTime = now;
    if (prev == null) {
      return;
    }
    final elapsed = now.difference(prev).inMicroseconds;
    if (elapsed <= 0) {
      return;
    }
    if (_lastFpsUpdate != null &&
        now.difference(_lastFpsUpdate!) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastFpsUpdate = now;
    _inferenceFps = 1000000 / elapsed;
  }

  void _onCameraFrame(CameraImage image) {
    if (_isProcessingFrame || !_isModelReady || _streamProcessor == null) {
      return;
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final rotation = _rotationCompensation(controller);
    if (rotation == null) {
      return;
    }

    if (Platform.isAndroid) {
      final nv21 = FaceMeshCameraImageAdapter.toNv21(image);
      if (nv21 == null) {
        return;
      }
      _ensureInferenceStream(rotation);
      final stream = _nv21Controller;
      if (stream == null || stream.isClosed) {
        return;
      }
      _isProcessingFrame = true;
      stream.add(nv21);
    } else if (Platform.isIOS) {
      final bgra = FaceMeshCameraImageAdapter.toBgra(image);
      if (bgra == null) {
        return;
      }
      _ensureInferenceStream(rotation);
      final stream = _bgraController;
      if (stream == null || stream.isClosed) {
        return;
      }
      _isProcessingFrame = true;
      stream.add(bgra);
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
    _inferenceSubscription?.cancel();
    _inferenceSubscription = null;
    _nv21Controller?.close();
    _bgraController?.close();
    _nv21Controller = null;
    _bgraController = null;
    _streamRotation = null;
    _isProcessingFrame = false;
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
      _isModelReady = false;
      _meshResult = null;
      _landmarkCount = 0;
    } else if (state == AppLifecycleState.resumed && _cameraController == null) {
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
    _stopInferenceStream();
    _cameraController?.dispose();
    _detector?.close();
    _meshProcessor?.close();
    super.dispose();
  }

  bool get _mirrorHorizontal {
    final controller = _cameraController;
    return !Platform.isIOS &&
        controller?.description.lensDirection == CameraLensDirection.front;
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
                        height: width / nativeAspect,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(controller),
                            if (_showSkeleton && _meshResult != null)
                              RepaintBoundary(
                                child: CustomPaint(
                                  painter: FaceMeshPainter(
                                    result: _meshResult!,
                                    rotationDegrees: 0,
                                    mirrorHorizontal: _mirrorHorizontal,
                                    strokeColor: GlamARColors.mesh.withValues(
                                      alpha: 0.85,
                                    ),
                                    irisColor: GlamARColors.meshIris,
                                    refinedEyeColor: GlamARColors.rose,
                                    strokeWidth: 0.35,
                                    drawIris: true,
                                    drawRefinedEyeEdges: true,
                                  ),
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
        _TopBar(onBack: () => Navigator.of(context).pop()),
        _BottomHud(
          landmarkCount: _landmarkCount,
          fps: _inferenceFps,
          showSkeleton: _showSkeleton,
          onToggleSkeleton: () {
            setState(() => _showSkeleton = !_showSkeleton);
          },
        ),
        if (!_isModelReady && _statusMessage.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            top: MediaQuery.of(context).size.height * 0.42,
            child: _ModelLoadingBanner(message: _statusMessage),
          ),
        if (_isModelReady && _landmarkCount == 0)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 140,
            child: Center(
              child: _HintChip(text: '请将面部置于画面中央'),
            ),
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
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

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
              const Spacer(),
              const _HintChip(text: '16:9'),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomHud extends StatelessWidget {
  const _BottomHud({
    required this.landmarkCount,
    required this.fps,
    required this.showSkeleton,
    required this.onToggleSkeleton,
  });

  final int landmarkCount;
  final double fps;
  final bool showSkeleton;
  final VoidCallback onToggleSkeleton;

  @override
  Widget build(BuildContext context) {
    final fpsLabel = fps > 0 ? '${fps.toStringAsFixed(0)} fps' : '-- fps';

    return Positioned(
      left: 16,
      right: 16,
      bottom: 28,
      child: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: GlamARColors.champagne.withValues(alpha: 0.12),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _Stat(label: '关键点', value: '$landmarkCount'),
                const SizedBox(width: 20),
                _Stat(label: '追踪', value: fpsLabel),
                const Spacer(),
                GestureDetector(
                  onTap: onToggleSkeleton,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: showSkeleton
                          ? GlamARColors.rose.withValues(alpha: 0.25)
                          : Colors.white.withValues(alpha: 0.08),
                      border: Border.all(
                        color: showSkeleton
                            ? GlamARColors.rose.withValues(alpha: 0.6)
                            : Colors.white24,
                      ),
                    ),
                    child: Text(
                      showSkeleton ? '骨骼 ON' : '骨骼 OFF',
                      style: TextStyle(
                        color: showSkeleton
                            ? GlamARColors.champagne
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: GlamARColors.champagne.withValues(alpha: 0.5),
            fontSize: 10,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: GlamARColors.pearl,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
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
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: GlamARColors.champagne,
              ),
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
