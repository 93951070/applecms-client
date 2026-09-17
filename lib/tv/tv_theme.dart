import 'package:flutter/material.dart';

/// TV 版视觉令牌：深色底 + 蓝青强调 + 金色会员，走 10 尺 UI 的量级。
class TvColors {
  TvColors._();

  /// 页面底色（上浅下深的深空蓝黑）
  static const Color bg = Color(0xFF0B1220);
  static const Color bgDeep = Color(0xFF05080F);

  /// 容器层级
  static const Color surface = Color(0xFF141C2E);
  static const Color surfaceHigh = Color(0xFF1E283D);
  static const Color divider = Color(0x1FFFFFFF);

  /// 强调色：焦点/主按钮用蓝，进度与热度点缀用青
  static const Color accent = Color(0xFF3D8BFF);
  static const Color accentDeep = Color(0xFF1E6BE0);
  static const Color cyan = Color(0xFF00C2FF);

  /// 会员金
  static const Color gold = Color(0xFFFFB300);

  /// 文字层级
  static const Color text1 = Color(0xFFF2F5FA);
  static const Color text2 = Color(0xFFA9B3C6);
  static const Color text3 = Color(0xFF6C7789);

  /// 焦点描边
  static const Color focus = Color(0xFFFFFFFF);
}

/// TV 版尺寸令牌。
class TvMetrics {
  TvMetrics._();

  /// 电视过扫描安全边距：左右留得比上下多，避免贴边被裁。
  static const double safeH = 48;
  static const double safeV = 28;
  static const EdgeInsets safePadding = EdgeInsets.symmetric(
    horizontal: safeH,
    vertical: safeV,
  );

  /// 左侧导航栏
  static const double railWidth = 112;
  static const double railItemHeight = 78;

  /// 焦点放大倍数与动画时长
  static const double focusScale = 1.08;
  static const Duration focusDuration = Duration(milliseconds: 160);
  static const Duration scrollDuration = Duration(milliseconds: 240);

  /// 字号（10 尺 UI，整体比手机端大一档）
  static const double heroTitle = 42;
  static const double heroMeta = 16;
  static const double sectionTitle = 22;
  static const double cardTitle = 16;
  static const double body = 15;
  static const double chip = 16;

  /// 卡片尺寸
  static const double posterWidth = 150;

  /// 次要排列（历史/收藏）用的稍小海报
  static const double posterWidthSmall = 132;
  static const double posterAspect = 2 / 3;
  static const double wideAspect = 16 / 9;

  /// 圆角
  static const double radiusCard = 10;
  static const double radiusPanel = 16;
  static const double radiusPill = 8;
}

/// TV 版常用渐变。
class TvGradients {
  TvGradients._();

  /// 页面底色
  static const LinearGradient page = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [TvColors.bg, TvColors.bgDeep],
  );

  /// 海报/剧照底部压暗，保证文字可读
  static const LinearGradient posterScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.4, 1.0],
    colors: [Colors.transparent, Color(0xCC000000)],
  );

  /// 详情页左侧压暗（右向渐隐，给标题留出可读区）
  static const LinearGradient heroLeftScrim = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    stops: [0.0, 0.62, 1.0],
    colors: [Color(0xF205080F), Color(0x9905080F), Color(0x0005080F)],
  );

  /// 详情页底部压暗
  static const LinearGradient heroBottomScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.55, 1.0],
    colors: [Colors.transparent, Color(0xF205080F)],
  );
}

/// 按可用宽度算出 TV 网格列数，尽量让海报宽度落在 140-200 之间。
int tvGridColumns(double width, {double cardWidth = TvMetrics.posterWidth}) {
  const gap = 20.0;
  final usable = width - TvMetrics.safeH * 2;
  if (usable <= 0) return 4;
  final count = ((usable + gap) / (cardWidth + gap)).floor();
  return count.clamp(3, 8);
}
