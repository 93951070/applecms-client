import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format_utils.dart';
import '../widgets/cover_image.dart';
import 'tv_theme.dart';

/// 把聚焦中的自绘卡片包一层焦点描边 + 外发光。
Widget tvFocusRing({
  required bool focused,
  required Widget child,
  double radius = TvMetrics.radiusCard,
  bool glow = true,
}) {
  return AnimatedContainer(
    duration: TvMetrics.focusDuration,
    curve: Curves.easeOut,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: focused ? TvColors.focus : Colors.transparent,
        width: 2.5,
      ),
      boxShadow: focused && glow
          ? [
              BoxShadow(
                color: TvColors.accent.withValues(alpha: 0.45),
                blurRadius: 22,
                spreadRadius: 1,
              ),
              const BoxShadow(
                color: Color(0x66000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ]
          : null,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius - 2),
      child: child,
    ),
  );
}

/// TV 焦点容器：接管遥控器方向键之外的事件（OK/确认、回车、手柄 A），
/// 并在获得焦点时自动把自身滚动进可视区，供横滑行与外层纵向列表联动。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.builder,
    this.onSelect,
    this.onFocusChange,
    this.autofocus = false,
    this.enabled = true,
    this.focusedScale = TvMetrics.focusScale,
    this.ensureVisible = true,
    this.focusNode,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onSelect;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final bool enabled;
  final double focusedScale;

  /// 获得焦点时是否自动滚动进可视区。
  final bool ensureVisible;
  final FocusNode? focusNode;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late final FocusNode _node;
  late final bool _ownsNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ownsNode = widget.focusNode == null;
    _node = widget.focusNode ?? FocusNode(debugLabel: 'tv-focusable');
  }

  @override
  void dispose() {
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  bool _isSelectKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!widget.enabled) return KeyEventResult.ignored;
    if (_isSelectKey(event.logicalKey)) {
      final handler = widget.onSelect;
      if (handler == null) return KeyEventResult.ignored;
      handler();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 触摸屏（手机/平板）上的点击：遥控器走 [_onKeyEvent]，手指走这里。
  void _handleTap() {
    if (!widget.enabled) return;
    _node.requestFocus();
    widget.onSelect?.call();
  }

  void _handleFocusChange(bool focused) {
    if (!mounted) return;
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    if (focused && widget.ensureVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: TvMetrics.scrollDuration,
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget current = AnimatedScale(
      scale: _focused ? widget.focusedScale : 1.0,
      duration: TvMetrics.focusDuration,
      curve: Curves.easeOut,
      child: widget.builder(context, _focused),
    );
    if (widget.enabled && widget.onSelect != null) {
      current = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: current,
      );
    }
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      onFocusChange: _handleFocusChange,
      onKeyEvent: _onKeyEvent,
      child: current,
    );
  }
}

/// TV 海报卡片（2:3 竖版），带标题、副标题与热度角标。
class TvPosterCard extends StatelessWidget {
  const TvPosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.subtitle,
    this.year,
    this.heat = 0,
    this.width = TvMetrics.posterWidth,
    this.onSelect,
    this.autofocus = false,
  });

  final String title;
  final String? imageUrl;
  final String? subtitle;
  final String? year;
  final int heat;
  final double width;
  final VoidCallback? onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final height = width / TvMetrics.posterAspect;
    return TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: (context, focused) {
        return SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              tvFocusRing(
                focused: focused,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (imageUrl != null && imageUrl!.isNotEmpty)
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
                              colors: [Color(0xFF3A2130), Color(0xFF1F141C)],
                            ),
                          ),
                        ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: TvGradients.posterScrim,
                        ),
                      ),
                      if (year != null && year!.isNotEmpty)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              year!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (heat > 0)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  LucideIcons.sparkles,
                                  size: 10,
                                  color: TvColors.gold,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  formatCount(heat),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TvMetrics.cardTitle,
                  fontWeight: FontWeight.w600,
                  color: focused ? TvColors.accent : TvColors.text2,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: TvColors.text3),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// TV 焦点按钮（主/次两种形态）。
class TvActionButton extends StatelessWidget {
  const TvActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onSelect,
    this.primary = false,
    this.autofocus = false,
    this.gold = false,
    this.focusNode,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onSelect;
  final bool primary;
  final bool autofocus;
  final bool gold;

  /// 外部焦点节点，便于弹窗出现后显式聚焦。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onSelect: onSelect,
      builder: (context, focused) {
        final Color base;
        if (gold) {
          base = TvColors.gold;
        } else if (primary) {
          base = TvColors.accent;
        } else {
          base = Colors.white.withValues(alpha: focused ? 0.22 : 0.10);
        }
        return AnimatedContainer(
          duration: TvMetrics.focusDuration,
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
          decoration: BoxDecoration(
            color: primary && !gold ? null : base,
            gradient: primary && !gold ? TvGradients.brand : null,
            borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
            border: Border.all(
              color: focused ? TvColors.focus : Colors.transparent,
              width: 2,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: (gold ? TvColors.gold : TvColors.accent)
                          .withValues(alpha: 0.4),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 20,
                  color: primary || gold
                      ? Colors.white
                      : (focused ? TvColors.text1 : TvColors.text2),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: TvMetrics.body,
                  fontWeight: FontWeight.w600,
                  color: primary || gold
                      ? Colors.white
                      : (focused ? TvColors.text1 : TvColors.text2),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// TV 胶囊标签（选集、筛选等）。
class TvChip extends StatelessWidget {
  const TvChip({
    super.key,
    required this.label,
    this.onSelect,
    this.selected = false,
    this.locked = false,
    this.autofocus = false,
    this.width,
  });

  final String label;
  final VoidCallback? onSelect;
  final bool selected;
  final bool locked;
  final bool autofocus;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: (context, focused) {
        final Color bg;
        if (focused) {
          bg = TvColors.accent;
        } else if (selected) {
          bg = TvColors.accent.withValues(alpha: 0.22);
        } else {
          bg = TvColors.surfaceHigh;
        }
        return AnimatedContainer(
          duration: TvMetrics.focusDuration,
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
            border: Border.all(
              color: focused ? TvColors.focus : TvColors.divider,
              width: focused ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TvMetrics.chip,
                    fontWeight: FontWeight.w600,
                    color: focused || selected ? Colors.white : TvColors.text2,
                  ),
                ),
              ),
              if (locked) ...[
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.lock,
                  size: 14,
                  color: focused ? Colors.white : TvColors.gold,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// TV 区块标题（标题 + 可选的「更多」入口）。
class TvSectionHeader extends StatelessWidget {
  const TvSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.moreText,
    this.onMore,
  });

  final String title;
  final IconData? icon;
  final String? moreText;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 22, color: TvColors.highlight),
            const SizedBox(width: 10),
          ],
          Text(
            title,
            style: const TextStyle(
              fontSize: TvMetrics.sectionTitle,
              fontWeight: FontWeight.w700,
              color: TvColors.text1,
            ),
          ),
          const Spacer(),
          if (onMore != null)
            TvFocusable(
              onSelect: onMore,
              builder: (context, focused) => AnimatedContainer(
                duration: TvMetrics.focusDuration,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: focused
                      ? TvColors.accent.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
                  border: Border.all(
                    color: focused ? TvColors.accent : TvColors.divider,
                    width: focused ? 2 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      moreText ?? '更多',
                      style: TextStyle(
                        fontSize: 14,
                        color: focused ? TvColors.accent : TvColors.text3,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      LucideIcons.chevronRight,
                      size: 16,
                      color: focused ? TvColors.accent : TvColors.text3,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// TV 横滑内容行：标题 + 一排海报卡片，焦点移动时自动横向滚动。
class TvRow extends StatelessWidget {
  const TvRow({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.moreText,
    this.onMore,
    this.height,
  });

  final String title;
  final List<Widget> children;
  final IconData? icon;
  final String? moreText;
  final VoidCallback? onMore;
  final double? height;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final posterHeight = TvMetrics.posterWidth / TvMetrics.posterAspect;
    final rowHeight = height ?? posterHeight + 78;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: TvMetrics.safeH),
          child: TvSectionHeader(
            title: title,
            icon: icon,
            moreText: moreText,
            onMore: onMore,
          ),
        ),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: TvMetrics.safeH),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
              child: children[index],
            ),
          ),
        ),
      ],
    );
  }
}
