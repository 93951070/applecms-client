import 'dart:math' as math;
import 'package:flutter/material.dart';

/// B 站风格的圆形加载动画：淡色轨道 + 带渐变拖尾的圆头圆弧，平滑旋转。
class BiliLoading extends StatefulWidget {
  final double size;
  final Color color;
  final double strokeWidth;

  const BiliLoading({
    super.key,
    this.size = 42,
    this.color = Colors.white,
    this.strokeWidth = 3,
  });

  @override
  State<BiliLoading> createState() => _BiliLoadingState();
}

class _BiliLoadingState extends State<BiliLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _BiliSpinnerPainter(
            progress: _controller.value,
            color: widget.color,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _BiliSpinnerPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _BiliSpinnerPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke =
        strokeWidth.clamp(1.0, size.shortestSide / 4).toDouble();
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.15);
    canvas.drawCircle(center, radius, track);

    final angle = progress * 2 * math.pi;
    final localRect = Rect.fromCircle(center: Offset.zero, radius: radius);
    final shader = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: -math.pi / 2 + 2 * math.pi,
      colors: [
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.35),
        color,
      ],
      stops: const [0.0, 0.6, 1.0],
    ).createShader(localRect);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = shader;

    const sweep = math.pi * 1.35;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.drawArc(localRect, -math.pi / 2, sweep, false, arc);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BiliSpinnerPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
