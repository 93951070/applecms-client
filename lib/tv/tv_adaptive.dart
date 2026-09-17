import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tv_mode.dart';

/// TV UI 的设计基准最短边（Android TV 典型逻辑尺寸 960×540）。
const double kTvDesignShortestSide = 540;

/// 按屏幕最短边推算 TV UI 的缩放系数，只缩小不放大。
///
/// 电视端最短边普遍 ≥540，系数为 1，与设计稿保持 1:1；手机横屏最短边约
/// 360-430，系数落在 0.67-0.8，10 尺 UI 的固定字号与卡片宽度等比收缩后
/// 仍能完整显示。
double tvUiScale(Size size) {
  final shortest = math.min(size.width, size.height);
  if (shortest <= 0 || !shortest.isFinite) return 1;
  return (shortest / kTvDesignShortestSide).clamp(0.5, 1.0);
}

/// 让 TV UI 自适应实际屏幕尺寸。
///
/// TV 版尺寸都是固定的 10 尺 UI 量级，直接渲染到小屏（手机、小尺寸平板）
/// 会溢出到屏幕外，表现为内容被裁、点不到。这里把整棵 TV 子树按更大的
/// 虚拟画布布局再等比缩回实际屏幕，等效于给所有 TV 页面统一做尺寸自适应，
/// 无需逐页改写固定尺寸。
class TvAdaptiveScope extends ConsumerWidget {
  const TvAdaptiveScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(tvModeSettingProvider);
    if (!resolveTvMode(context, setting)) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final real = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = tvUiScale(real);
        if (scale >= 1 || real.isEmpty) return child;

        final design = Size(real.width / scale, real.height / scale);
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topLeft,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: design),
              child: SizedBox(
                width: design.width,
                height: design.height,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
