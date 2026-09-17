import 'package:flutter/material.dart';

import '../core/theme.dart';

/// TV 版视觉令牌：深色底 + 粉色主色，与手机端 [AppColors.pink] 同一套品牌色。
class TvColors {
  TvColors._();

  /// 页面底色（粉调深黑，上浅下深）
  static const Color bg = Color(0xFF150F13);
  static const Color bgDeep = Color(0xFF0A0709);
  static const Color bgDeepStart = Color(0xFF211419);

  /// 容器层级
  static const Color surface = Color(0xFF1F1720);
  static const Color surfaceHigh = Color(0xFF2C212A);
  static const Color divider = Color(0x1FFFFFFF);

  /// 主色：与手机端一致的品牌粉
  static const Color accent = AppColors.pink;
  static const Color accentDeep = AppColors.pinkDeep;
  static const Color accentLight = AppColors.pinkLight;

  /// 点缀紫（区块图标、渐变过渡）
  static const Color highlight = AppColors.auroraPurple;

  /// 会员金
  static const Color gold = AppColors.vipGold;

  /// 文字层级
  static const Color text1 = Color(0xFFF7F3F6);
  static const Color text2 = Color(0xFFB5A9B2);
  static const Color text3 = Color(0xFF7A6E77);

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

  /// 顶部导航栏
  static const double navHeight = 76;
  static const double navItemHeight = 44;
  static const double navLogoSize = 34;

  /// 焦点放大倍数与动画时长
  static const double focusScale = 1.08;
  static const Duration focusDuration = Duration(milliseconds: 160);
  static const Duration scrollDuration = Duration(milliseconds: 240);

  /// 幻灯片自动轮播间隔
  static const Duration heroInterval = Duration(seconds: 6);
  static const Duration heroFade = Duration(milliseconds: 600);

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
    colors: [TvColors.bgDeepStart, TvColors.bgDeep],
  );

  /// 品牌粉渐变（主按钮、选中态）
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [TvColors.accent, TvColors.accentDeep],
  );

  /// 海报/剧照底部压暗，保证文字可读
  static const LinearGradient posterScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.4, 1.0],
    colors: [Colors.transparent, Color(0xCC000000)],
  );

  /// 幻灯片左侧压暗（右向渐隐，给标题留出可读区）
  static const LinearGradient heroLeftScrim = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    stops: [0.0, 0.55, 1.0],
    colors: [Color(0xF20A0709), Color(0x990A0709), Color(0x000A0709)],
  );

  /// 幻灯片底部压暗（接入页面底色，避免断层）
  static const LinearGradient heroBottomScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.5, 1.0],
    colors: [Colors.transparent, Color(0xFF150F13)],
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
