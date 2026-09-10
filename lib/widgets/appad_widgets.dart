import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'cover_image.dart';

/// ============ Appad 风格共享组件（融合粉调玻璃主题） ============

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _text1(BuildContext context) => _isDark(context)
    ? AppColors.darkText
    : AppColors.lightText;

Color _text2(BuildContext context) => _isDark(context)
    ? AppColors.darkText2
    : AppColors.lightText2;

Color _text3(BuildContext context) => _isDark(context)
    ? AppColors.darkText3
    : AppColors.lightText3;

/// 底部导航（扁平全宽，4 Tab：首页 / 排行榜 / 一起看 / 我的）
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.current, required this.onTap});

  final int current;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, '首页'),
    (Icons.leaderboard_outlined, Icons.leaderboard_rounded, '排行榜'),
    (Icons.slideshow_outlined, Icons.slideshow_rounded, '一起看'),
    (Icons.person_outline_rounded, Icons.person_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final inactive = isDark ? AppColors.darkText3 : const Color(0xFF9B9BA1);
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C171B) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2C262B) : const Color(0xFFEFEFF2),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: List.generate(_items.length, (i) {
              final (outline, filled, label) = _items[i];
              final active = i == current;
              final color = active ? AppColors.pink : inactive;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(active ? filled : outline, size: 22, color: color),
                      const SizedBox(height: 3),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 分类文字 Tab（粉色下划线）
class AppTabStrip extends StatelessWidget {
  const AppTabStrip({
    super.key,
    required this.tabs,
    required this.current,
    required this.onChanged,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 0),
  });

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onChanged;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = i == current;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(i),
            child: Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tabs[i],
                    style: TextStyle(
                      fontSize: 15,
                      color: active ? _text1(context) : _text2(context),
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 22,
                    height: 3,
                    decoration: BoxDecoration(
                      color: active ? AppColors.pink : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 视频卡片（海报 + 标题 + 集数 + 评分）
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.episode,
    this.score,
    this.year,
    this.onTap,
    this.width = 104,
    this.aspectRatio = 2 / 3,
  });

  final String title;
  final String? imageUrl;
  final String? episode;
  final String? score;
  final String? year;
  final VoidCallback? onTap;
  final double width;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PosterCard(
              imageUrl: imageUrl,
              title: title,
              year: year,
              width: width,
              height: width / aspectRatio,
            ),
            const SizedBox(height: 7),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _text1(context),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                if (episode != null)
                  Flexible(
                    child: Text(
                      episode!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: _text2(context)),
                    ),
                  ),
                if (episode != null && score != null) const SizedBox(width: 6),
                if (score != null) ScoreBadge(score: score!),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 海报卡片（真实图片 + 渐变兜底 + 年份角标 + 标题）
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.year,
    this.width = 104,
    this.height = 156,
    this.titleFontSize = 13,
    this.borderRadius = 12,
  });

  final String title;
  final String? imageUrl;
  final String? year;
  final double width;
  final double height;
  final double titleFontSize;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              CoverImage(
                imageUrl: imageUrl!,
                aspectRatio: width / height,
              )
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                  ),
                ),
              ),
            // 底部渐暗遮罩，保证标题可读
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.45, 1.0],
                    colors: [Colors.transparent, Color(0x99000000)],
                  ),
                ),
              ),
            ),
            if (year != null && year!.isNotEmpty)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.yearRed,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    year!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: titleFontSize,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  shadows: const [
                    Shadow(color: Colors.black54, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 绿色评分徽章
class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score});

  final String score;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.scoreGreen.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        score,
        style: const TextStyle(
          color: AppColors.scoreGreen,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.5,
        ),
      ),
    );
  }
}

/// 区块标题（图标 + 标题 + 更多箭头）
class SectionHead extends StatelessWidget {
  const SectionHead({
    super.key,
    required this.icon,
    required this.title,
    this.moreText,
    this.onMore,
  });

  final Widget icon;
  final String title;
  final String? moreText;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _text1(context),
            ),
          ),
          const Spacer(),
          if (moreText != null)
            GestureDetector(
              onTap: onMore,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text(
                    moreText!,
                    style: TextStyle(fontSize: 12, color: _text2(context)),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 14, color: _text2(context)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 继续观看/提示胶囊（粉色渐变）
class ContinueBar extends StatelessWidget {
  const ContinueBar({
    super.key,
    required this.text,
    this.onTap,
    this.onClose,
  });

  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      height: 44,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF7EB0), AppColors.pink],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: AppColors.pink.withValues(alpha: 0.32),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow,
                      size: 14, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onClose != null)
                  GestureDetector(
                    onTap: onClose,
                    child: const Icon(Icons.close,
                        size: 15, color: Colors.white),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横向滚动列表（自动隐藏滚动条）
class HScroll extends StatelessWidget {
  const HScroll({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 14),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: padding,
      child: child,
    );
  }
}
