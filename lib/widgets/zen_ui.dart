import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format_utils.dart';
import '../core/theme.dart';
import '../models/movie.dart';
import 'cover_image.dart';

class ZenScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final bool extendBodyBehindAppBar;
  final Color? backgroundColor;

  const ZenScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
    this.extendBodyBehindAppBar = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: backgroundColor ?? theme.scaffoldBackgroundColor,
      appBar: appBar,
      body: ZenAuroraBackground(child: body),
      bottomNavigationBar: bottomNavigationBar,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
    );
  }
}

/// 极光背景：柔和渐变 + 粉/蓝/紫光斑，为玻璃容器提供折射底
class ZenAuroraBackground extends StatelessWidget {
  final Widget child;

  const ZenAuroraBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseTop = isDark ? const Color(0xFF140F13) : const Color(0xFFFDF7FA);
    final baseBottom = isDark
        ? const Color(0xFF0B080A)
        : const Color(0xFFF3F5FA);
    final blobAlpha = isDark ? 0.22 : 0.32;

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [baseTop, baseBottom],
              ),
            ),
          ),
        ),
        Positioned(
          top: -90,
          left: -70,
          child: _AuroraBlob(
            color: AppColors.pink.withValues(alpha: blobAlpha),
            size: 260,
          ),
        ),
        Positioned(
          top: 120,
          right: -100,
          child: _AuroraBlob(
            color: AppColors.auroraBlue.withValues(alpha: blobAlpha * 0.8),
            size: 280,
          ),
        ),
        Positioned(
          bottom: -80,
          left: 30,
          child: _AuroraBlob(
            color: AppColors.auroraPurple.withValues(alpha: blobAlpha * 0.7),
            size: 240,
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _AuroraBlob extends StatelessWidget {
  final Color color;
  final double size;

  const _AuroraBlob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class ZenSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeTrackColor;
  final Color? inactiveTrackColor;
  final double scale;

  const ZenSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeTrackColor,
    this.inactiveTrackColor,
    this.scale = 0.7,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Transform.scale(
        scale: scale,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: theme.colorScheme.onPrimary,
          activeTrackColor: activeTrackColor ?? theme.colorScheme.primary,
          inactiveThumbColor: isDark ? Colors.white38 : Colors.white,
          inactiveTrackColor: isDark ? Colors.white12 : Colors.black12,
          trackOutlineColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected))
              return Colors.transparent;
            return isDark
                ? Colors.white24
                : Colors.black.withValues(alpha: 0.1);
          }),
        ),
      ),
    );
  }
}

class ZenButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double borderRadius;
  final EdgeInsets padding;
  final double? height;
  final bool isSecondary;

  /// 是否在出现时自动获取焦点（TV 遥控器/键盘场景需要，触摸场景保持 false）。
  final bool autofocus;

  /// 外部焦点节点，便于调用方在弹窗出现后显式 `requestFocus`，
  /// 保证 Android TV 遥控器无需先按方向键即可直接确认。
  final FocusNode? focusNode;

  const ZenButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
    this.borderRadius = 14, // 稍微减小圆角，显得更现代
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    this.height,
    this.isSecondary = false,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<ZenButton> createState() => _ZenButtonState();
}

class _ZenButtonState extends State<ZenButton> {
  bool _isPressed = false;
  bool _isHovered = false;
  bool _isFocused = false;

  /// 遥控器/键盘的确认键（select 为 Android TV 遥控器中央键），
  /// 让自绘按钮在没有 Material 按钮 Action 的情况下也能被遥控器激活。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space) {
      widget.onPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bool active = _isHovered || _isFocused;

    Color bgColor;
    Color fgColor;

    if (widget.isSecondary) {
      bgColor =
          widget.backgroundColor ??
          (isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.05));
      fgColor = widget.foregroundColor ?? theme.colorScheme.onSurface;
      if (active) bgColor = bgColor.withValues(alpha: bgColor.opacity + 0.05);
    } else {
      bgColor = widget.backgroundColor ?? theme.colorScheme.primary;
      fgColor = widget.foregroundColor ?? Colors.white;
      if (active) bgColor = bgColor.withValues(alpha: 0.9);
    }

    // 聚焦描边：主按钮用白色，次级按钮用主题色。
    final focusRing = widget.isSecondary
        ? theme.colorScheme.primary
        : Colors.white;

    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        if (mounted) setState(() => _isFocused = focused);
      },
      onKeyEvent: _onKeyEvent,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _isPressed
                ? 0.96
                : (_isFocused ? 1.06 : (_isHovered ? 1.02 : 1.0)),
            duration: const Duration(milliseconds: 200),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: widget.height,
              padding: widget.padding,
              alignment: widget.height != null ? Alignment.center : null,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: _isFocused
                    ? Border.all(color: focusRing, width: 2)
                    : null,
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color: focusRing.withValues(alpha: 0.5),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                      ]
                    : (!widget.isSecondary && _isHovered
                          ? [
                              BoxShadow(
                                color: bgColor.withValues(alpha: 0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null),
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: fgColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ZenGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur;
  final Color? backgroundColor;
  final double opacity;

  const ZenGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 40,
    this.blur = 40,
    this.backgroundColor,
    this.opacity = 0.1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor =
        backgroundColor ?? (isDark ? theme.colorScheme.surface : Colors.white);
    // 浅色态用较高不透明度形成“磨砂白玻璃”，深色态保持原有低透明度
    final effectiveOpacity = isDark
        ? opacity
        : (opacity <= 0.15 ? 0.62 : opacity);
    final borderColor = isDark
        ? theme.dividerColor
        : Colors.white.withValues(alpha: 0.65);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: baseColor.withValues(alpha: effectiveOpacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: borderColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

class ZenSliverAppBar extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget>? actions;
  final double? expandedHeight;

  const ZenSliverAppBar({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions,
    this.expandedHeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPC = MediaQuery.of(context).size.width > 800;
    final horizontalPadding = isPC ? 48.0 : 24.0;
    final canPop = Navigator.canPop(context);
    final topPadding = MediaQuery.of(context).padding.top;

    // 采用更紧凑的固定高度，匹配“收缩后”的视觉感
    final headerHeight = expandedHeight ?? (isPC ? 72.0 : 64.0);

    return SliverAppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      expandedHeight: headerHeight,
      toolbarHeight: headerHeight, // 确保工具栏高度也同步，防止布局偏移
      floating: true,
      pinned: false,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: Container(
        padding: EdgeInsets.only(top: topPadding),
        child: Row(
          children: [
            if (canPop)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: IconButton(
                  icon: Icon(
                    LucideIcons.chevronLeft,
                    size: 24,
                    color: theme.colorScheme.onSurface,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: canPop ? 12 : horizontalPadding,
                  right: horizontalPadding,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: isPC ? 22 : 18,
                        fontWeight: FontWeight.w900,
                        color: theme.colorScheme.onSurface,
                        letterSpacing: -0.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle.toUpperCase(),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.secondary.withValues(
                          alpha: 0.6,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
            if (actions != null)
              Padding(
                padding: EdgeInsets.only(right: horizontalPadding - 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions!),
              ),
          ],
        ),
      ),
    );
  }
}

/// 标题关键词高亮：命中的部分用主色加粗显示。
class HighlightedTitle extends StatelessWidget {
  final String text;
  final String query;
  final int maxLines;
  final TextStyle style;

  const HighlightedTitle({
    super.key,
    required this.text,
    required this.query,
    required this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (start <= lower.length) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: style.copyWith(
            color: AppColors.pink,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
      start = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class MovieCard extends ConsumerWidget {
  final DoubanSubject movie;
  final VoidCallback onTap;
  final String? badge;

  /// 命中的搜索关键词：非空时在标题中高亮显示。
  final String? highlight;

  /// 服务端热度值，大于 0 时在评分后展示。
  final int? heat;

  const MovieCard({
    super.key,
    required this.movie,
    required this.onTap,
    this.badge,
    this.highlight,
    this.heat,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CoverImage(imageUrl: movie.cover),
                ),
                if (badge != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            HighlightedTitle(
              text: movie.title,
              query: highlight ?? '',
              maxLines: 1,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            Row(
              children: [
                Text(
                  '⭐ ${movie.rate}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if ((heat ?? 0) > 0) ...[
                  const SizedBox(width: 6),
                  Icon(
                    LucideIcons.sparkles,
                    size: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    formatCount(heat!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
