import 'package:flutter/material.dart';
import 'package:glamar/app/theme/glamar_theme.dart';
import 'package:glamar/features/face_mesh/face_mesh_camera_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openCamera() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const FaceMeshCameraPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _AmbientBackground(),
          SafeArea(
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 36),
                      _BrandMark(textTheme: textTheme),
                      const Spacer(flex: 2),
                      Text(
                        '镜像里的\n另一种可能',
                        style: textTheme.displayLarge?.copyWith(
                          fontSize: 42,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '实时捕捉面部轮廓，以 AR 骨骼网格\n为美妆叠加铺就精准画布。',
                        style: textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 40),
                      _StartButton(onPressed: _openCamera),
                      const SizedBox(height: 20),
                      Center(
                        child: Text(
                          '需要前置摄像头权限',
                          style: textTheme.bodySmall?.copyWith(
                            color: GlamARColors.champagne.withValues(alpha: 0.4),
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [GlamARColors.rose, GlamARColors.roseDeep],
            ),
            boxShadow: [
              BoxShadow(
                color: GlamARColors.rose.withValues(alpha: 0.35),
                blurRadius: 20,
                spreadRadius: -4,
              ),
            ],
          ),
          child: const Icon(Icons.auto_awesome, size: 18, color: GlamARColors.ink),
        ),
        const SizedBox(width: 12),
        Text(
          'GlamAR',
          style: textTheme.titleLarge?.copyWith(
            letterSpacing: 3,
            color: GlamARColors.champagne,
          ),
        ),
      ],
    );
  }
}

class _StartButton extends StatefulWidget {
  const _StartButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedBuilder(
        animation: _shimmer,
        builder: (context, child) {
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment(-1 + _shimmer.value * 2, 0),
                end: Alignment(_shimmer.value * 2, 0),
                colors: const [
                  GlamARColors.roseDeep,
                  GlamARColors.rose,
                  GlamARColors.champagne,
                  GlamARColors.rose,
                  GlamARColors.roseDeep,
                ],
                stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: GlamARColors.rose.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          );
        },
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(28),
            child: Center(
              child: Text(
                '开启 AR 试妆镜',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: GlamARColors.ink,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AmbientPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()..color = GlamARColors.ink,
    );

    final roseGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.8, -0.6),
        radius: 0.9,
        colors: [
          GlamARColors.roseDeep.withValues(alpha: 0.28),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, roseGlow);

    final wineGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.7, 0.9),
        radius: 0.7,
        colors: [
          const Color(0xFF2A1520).withValues(alpha: 0.9),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, wineGlow);

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = GlamARColors.champagne.withValues(alpha: 0.08);

    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width * 0.85, size.height * 0.18),
        radius: size.width * 0.45,
      ),
      0.8,
      1.6,
      false,
      arcPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width * 0.1, size.height * 0.75),
        radius: size.width * 0.55,
      ),
      -2.2,
      1.2,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
