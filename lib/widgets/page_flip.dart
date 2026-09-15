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

/// 一级页面（列表 / 首页）进入二级页面（详情 / 播放页）时的 3D 翻页转场。
///
/// 参数与 [FlipPageView] 共用 [FlipConfig]，保证进入页面与切换分类的手感一致：
/// 新页面以靠近中缝的左侧为轴从侧面转入并渐亮。
///
/// 转场由阅读进度驱动，因此左缘右滑返回时翻页效果会跟随手指实时回退。
class FlipPageRoute<T> extends PageRouteBuilder<T> {
  FlipPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: FlipConfig.duration,
        reverseTransitionDuration: FlipConfig.duration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            FlipBackGestureDetector(child: builder(context)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: FlipConfig.curve,
            reverseCurve: FlipConfig.curve.flipped,
          );
          return AnimatedBuilder(
            animation: curved,
            child: child,
            builder: (context, inner) {
              final t = curved.value.clamp(0.0, 1.0);
              final depth = 1 - t;
              if (depth <= 0.001) return inner!;
              final transform = Matrix4.identity()
                ..setEntry(3, 2, FlipConfig.perspective)
                ..rotateY(-depth * FlipConfig.maxAngle);
              return Transform(
                alignment: Alignment.centerLeft,
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
        },
      );
}

/// 给 [FlipPageRoute] 补回 iOS 风格的左缘右滑返回手势。
///
/// [PageRouteBuilder] 自带转场后系统不再提供侧滑返回，这里在屏幕左缘
/// 铺一条窄手势带，拖动时直接改写转场进度，让 3D 翻页跟随手指回退。
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

  bool get _gestureEnabled {
    final route = _route;
    if (route == null) return false;
    if (!route.isCurrent) return false;
    if (route.popDisposition != RoutePopDisposition.pop) return false;
    return route.animation?.status == AnimationStatus.completed;
  }

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
    final animation = _route?.animation;
    if (animation is! AnimationController) return;
    animation.stop();
    _controller = animation;
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
