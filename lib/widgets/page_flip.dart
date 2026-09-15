import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 3D 翻页转场的统一配置。
///
/// 首页分类切换、排行榜分类切换与底部 Tab 切换都复用这里的参数与
/// [FlipPageView]，保证几处的翻页特效完全一致。
class FlipConfig {
  const FlipConfig._();

  /// 点击 Tab 触发翻页时的时长与曲线。
  static const Duration duration = Duration(milliseconds: 380);
  static const Curve curve = Curves.easeOutCubic;

  /// 透视强度：0 为无透视的正交投影，0.001 附近接近真实景深。
  static const double perspective = 0.0012;

  /// 页面离开正中时最多绕 Y 轴旋转的角度。
  static const double maxAngle = math.pi / 3; // 60°

  /// 离开页的压暗上限，避免翻页时两页亮度差异过大。
  static const double maxDim = 0.28;

  /// 进入播放页时中心碎裂转场的时长与曲线。
  ///
  /// 比翻页略慢，让裂纹扩散的过程看得清；曲线前段快、后段缓，
  /// 观感上更像玻璃瞬间开裂后碎片向外摊开。
  static const Duration crackDuration = Duration(milliseconds: 460);
  static const Curve crackCurve = Curves.easeOutQuart;
}

/// 让某一页随 [controller] 的滚动进度做绕 Y 轴的 3D 翻页。
///
/// 当前页保持正视；相邻页以靠近中缝的一侧为轴旋转并轻微压暗，
/// 形成书页翻动的手感。
class FlipPage extends StatelessWidget {
  const FlipPage({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
  });

  final PageController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, inner) {
        double delta;
        if (controller.hasClients && controller.position.haveDimensions) {
          delta = (controller.page ?? index.toDouble()) - index;
        } else {
          delta = 0;
        }
        final t = delta.clamp(-1.0, 1.0);
        final depth = t.abs();
        if (depth <= 0.001) return inner!;

        final transform = Matrix4.identity()
          ..setEntry(3, 2, FlipConfig.perspective)
          ..rotateY(t * FlipConfig.maxAngle);

        return Transform(
          alignment: t >= 0 ? Alignment.centerLeft : Alignment.centerRight,
          transform: transform,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              inner!,
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: FlipConfig.maxDim * depth,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 首页分类 / 排行榜 / 底部 Tab 共用的 3D 翻页容器。
class FlipPageView extends StatelessWidget {
  const FlipPageView({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.physics,
  });

  final PageController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<int>? onPageChanged;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: controller,
      itemCount: itemCount,
      onPageChanged: onPageChanged,
      physics: physics,
      itemBuilder: (context, index) => FlipPage(
        controller: controller,
        index: index,
        child: itemBuilder(context, index),
      ),
    );
  }
}

/// 一级页面（列表 / 首页）进入播放页时的「中心碎裂」转场。
///
/// 从屏幕中心向外扩展一条带抖动的裂纹裁剪路径揭开新页面，配合与裁剪边界
/// 对齐的裂纹线与轻微缩放形成玻璃碎裂、碎片向外摊开的观感。
///
/// 这里刻意不做真实碎片切块：整页始终只构建一份，裁剪不会打断播放页里的
/// 视频纹理，播放器照常出画；碎片切块需要把页面渲染多次（或先截图），
/// 前者会让多个播放内核同时初始化，后者拿不到平台纹理层，视频区会变黑。
///
/// 转场由播放进度驱动，因此左缘右滑返回时碎裂效果会跟随手指实时收拢。
class CrackRevealPageRoute<T> extends PageRouteBuilder<T> {
  CrackRevealPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: FlipConfig.crackDuration,
        reverseTransitionDuration: FlipConfig.crackDuration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            FlipBackGestureDetector(child: builder(context)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: FlipConfig.crackCurve,
            reverseCurve: FlipConfig.crackCurve.flipped,
          );
          return AnimatedBuilder(
            animation: curved,
            child: child,
            builder: (context, inner) {
              final t = curved.value.clamp(0.0, 1.0);
              if (t >= 1) return inner!;
              return LayoutBuilder(
                builder: (context, constraints) {
                  // 尺寸不确定时退化为直接展示，避免用无穷大约束构造裂纹路径。
                  if (!constraints.hasBoundedWidth ||
                      !constraints.hasBoundedHeight) {
                    return inner!;
                  }
                  return Stack(
                    fit: StackFit.passthrough,
                    children: [
                      ClipPath(
                        clipper: _CrackClipper(progress: t),
                        child: Transform.scale(
                          scale: 1 + (1 - t) * 0.06,
                          child: inner!,
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _CrackLinesPainter(progress: t),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      );
}

/// 一条裂纹射线：角度与长度倍率固定，保证裁剪边界与裂纹线始终重合。
class _CrackRay {
  const _CrackRay(this.angle, this.scale);

  final double angle;
  final double scale;
}

/// 中心碎裂的射线集合：围绕中心均匀铺开并带固定抖动。
///
/// 用固定随机种子生成，避免每帧重新随机导致裂纹边界闪烁。
final List<_CrackRay> _crackRays = _buildCrackRays();

List<_CrackRay> _buildCrackRays() {
  const count = 28;
  final random = math.Random(20260915);
  final step = 2 * math.pi / count;
  final rays = List<_CrackRay>.generate(count, (i) {
    final angle = i * step + (random.nextDouble() - 0.5) * step * 0.85;
    return _CrackRay(angle, 1 + random.nextDouble() * 0.32);
  });
  rays.sort((a, b) => a.angle.compareTo(b.angle));
  return rays;
}

/// 裂纹裁剪：以屏幕中心为顶点的星形多边形，随时间向外扩张。
class _CrackClipper extends CustomClipper<Path> {
  const _CrackClipper({required this.progress});

  final double progress;

  @override
  Path getClip(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 射线长度上限取到最远角，保证 progress=1 时整屏都被揭开。
    final reach = size.longestSide * 0.72;
    final path = Path()..moveTo(center.dx, center.dy);
    for (final ray in _crackRays) {
      final length = reach * ray.scale * progress;
      path.lineTo(
        center.dx + math.cos(ray.angle) * length,
        center.dy + math.sin(ray.angle) * length,
      );
    }
    return path..close();
  }

  @override
  bool shouldReclip(covariant _CrackClipper oldClipper) =>
      oldClipper.progress != progress;
}

/// 裂纹线：与裁剪边界同向延伸并略微领先于揭示范围，随后逐渐淡出。
class _CrackLinesPainter extends CustomPainter {
  const _CrackLinesPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final fade = (1 - progress).clamp(0.0, 1.0);
    if (fade <= 0.01) return;
    final center = Offset(size.width / 2, size.height / 2);
    final reach = size.longestSide * 0.72;
    final lead = math.min(progress * 1.3, 1.0);
    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.6
      ..color = Colors.black.withValues(alpha: 0.32 * fade);
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.5 * fade);
    for (final ray in _crackRays) {
      final length = reach * ray.scale * lead;
      final tip = Offset(
        center.dx + math.cos(ray.angle) * length,
        center.dy + math.sin(ray.angle) * length,
      );
      canvas.drawLine(center, tip, shadow);
      canvas.drawLine(center, tip, glow);
    }
    // 撞击点的高光，让碎裂有个明确的起点。
    canvas.drawCircle(
      center,
      reach * 0.06 * fade,
      Paint()..color = Colors.white.withValues(alpha: 0.35 * fade),
    );
  }

  @override
  bool shouldRepaint(covariant _CrackLinesPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 给 [CrackRevealPageRoute] 补回 iOS 风格的左缘右滑返回手势。
///
/// [PageRouteBuilder] 自带转场后系统不再提供侧滑返回，这里在屏幕左缘
/// 铺一条窄手势带，拖动时直接改写转场进度，让碎裂效果跟随手指收拢。
class FlipBackGestureDetector extends StatefulWidget {
  const FlipBackGestureDetector({super.key, required this.child});

  final Widget child;

  /// 左缘手势带宽度，与 iOS 系统返回手势的判定区域接近。
  static const double edgeWidth = 22;

  @override
  State<FlipBackGestureDetector> createState() =>
      _FlipBackGestureDetectorState();
}

class _FlipBackGestureDetectorState extends State<FlipBackGestureDetector> {
  /// 判定为滑动返回的最小水平速度（像素/秒）。
  static const double _minFlingVelocity = 300;

  /// 位移小于该值时不动转场，避免轻触就抖动。
  static const double _dragTolerance = 6;

  AnimationController? _controller;
  double _dragStartX = 0;

  ModalRoute<Object?>? get _route => ModalRoute.of(context);

  /// 取当前路由的转场控制器。
  ///
  /// [ModalRoute.animation] 是只读的 [ProxyAnimation]，改写进度必须拿底层的
  /// [AnimationController]；这个 getter 在框架里标了 @protected，这里按官方
  /// Cupertino 返回手势的做法直接使用（cupertino/route.dart 同样如此）。
  AnimationController? get _routeController {
    final route = _route;
    if (route == null) return null;
    if (!route.isCurrent) return null;
    if (route.popDisposition != RoutePopDisposition.pop) return null;
    // ignore: invalid_use_of_protected_member
    final controller = route.controller;
    if (controller == null) return null;
    if (controller.status != AnimationStatus.completed) return null;
    return controller;
  }

  /// 拖动过程中即使控制器已不再处于 completed，也要保留手势带，否则一次重建
  /// 就会把手势识别器从树上摘掉，正在进行的拖动被静默取消、页面卡在半途。
  bool get _gestureEnabled => _controller != null || _routeController != null;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_gestureEnabled)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: FlipBackGestureDetector.edgeWidth,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _handleDragStart,
              onHorizontalDragUpdate: _handleDragUpdate,
              onHorizontalDragEnd: _handleDragEnd,
              onHorizontalDragCancel: _handleDragCancel,
            ),
          ),
      ],
    );
  }

  void _handleDragStart(DragStartDetails details) {
    if (_controller != null) return;
    final controller = _routeController;
    if (controller == null) return;
    controller.stop();
    _controller = controller;
    _dragStartX = details.globalPosition.dx;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final controller = _controller;
    if (controller == null) return;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final travelled = details.globalPosition.dx - _dragStartX;
    if (travelled.abs() < _dragTolerance) return;
    controller.value = (1 - travelled / width).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final shouldPop =
        velocity > _minFlingVelocity ||
        (velocity > -_minFlingVelocity && controller.value < 0.5);
    if (shouldPop && _route?.isCurrent == true) {
      Navigator.of(context).pop();
      return;
    }
    controller.forward();
  }

  void _handleDragCancel() {
    final controller = _controller;
    _controller = null;
    controller?.forward();
  }
}
