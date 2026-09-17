import 'package:flutter/material.dart';

import 'tv_theme.dart';

/// TV 海报网格。
///
/// 列数按可用宽度自适应，单元格高度用 [SliverGridDelegateWithFixedCrossAxisCount.mainAxisExtent]
/// 精确给出，避免不同分辨率下 childAspectRatio 估算导致的溢出。
class TvGrid extends StatelessWidget {
  const TvGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.cellGap = 18,
    this.cellPadding = const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    this.extraHeight = 56,
  });

  final int itemCount;

  /// [width] 为该单元格内卡片的可用宽度。
  final Widget Function(BuildContext context, int index, double width)
  itemBuilder;
  final ScrollController? controller;
  final EdgeInsets? padding;
  final double cellGap;
  final EdgeInsets cellPadding;

  /// 海报下方留给标题的高度。
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final pad = padding ?? TvMetrics.safePadding;
        final columns = tvGridColumns(width);
        final usable = width - pad.horizontal;
        final cellWidth = (usable - cellGap * (columns - 1)) / columns;
        final cardWidth = (cellWidth - cellPadding.horizontal).clamp(
          80.0,
          double.infinity,
        );
        final cardHeight = cardWidth / TvMetrics.posterAspect;

        return GridView.builder(
          controller: controller,
          padding: pad,
          physics: const BouncingScrollPhysics(),
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 24,
            crossAxisSpacing: cellGap,
            mainAxisExtent: cardHeight + extraHeight,
          ),
          itemBuilder: (context, index) => Padding(
            padding: cellPadding,
            child: itemBuilder(context, index, cardWidth),
          ),
        );
      },
    );
  }
}
