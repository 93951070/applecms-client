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
                    color:
                        Colors.black.withValues(alpha: FlipConfig.maxDim * depth),
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
class FlipPageRoute<T> extends PageRouteBuilder<T> {
  FlipPageRoute({required WidgetBuilder builder, super.settings})
      : super(
          transitionDuration: FlipConfig.duration,
          reverseTransitionDuration: FlipConfig.duration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
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
                                alpha: FlipConfig.maxDim * depth),
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
