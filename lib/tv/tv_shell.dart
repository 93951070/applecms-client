import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../pages/home.dart';
import '../services/cms_service.dart';
import 'pages/tv_home_page.dart';
import 'pages/tv_list_page.dart';
import 'pages/tv_profile_page.dart';
import 'pages/tv_rank_page.dart';
import 'pages/tv_search_page.dart';
import 'tv_focus.dart';
import 'tv_mode.dart';
import 'tv_theme.dart';

/// TV 版外壳：左侧常驻导航栏 + 右侧内容区。
///
/// 与手机版的底部 4 Tab 不同，遥控器在电视上更习惯左侧竖向导航，
/// 且各 Tab 内容全程复用同一外壳，避免整页重建导致的焦点丢失。
class TvShell extends ConsumerStatefulWidget {
  const TvShell({super.key});

  @override
  ConsumerState<TvShell> createState() => _TvShellState();
}

class _TvShellState extends ConsumerState<TvShell> {
  static const int _tabHome = 0;
  static const int _tabCategory = 1;
  static const int _tabRank = 2;
  static const int _tabSearch = 3;
  static const int _tabProfile = 4;

  int _tab = _tabHome;
  int _typeId = 0;
  String _typeName = '';

  @override
  void initState() {
    super.initState();
    // TV 版是横屏布局，手机等小屏上强制横屏，避免竖屏下被挤压到无法操作。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    // 退出 TV 版交还给系统自动旋转（手机版各页自行控制方向）。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
  }

  void _selectCategory(int typeId, String name) {
    setState(() {
      _tab = _tabCategory;
      _typeId = typeId;
      _typeName = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups =
        ref.watch(categoryTreeProvider).value ?? defaultCategoryGroups;

    return Scaffold(
      backgroundColor: TvColors.bg,
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: TvGradients.page),
            ),
          ),
          Row(
            children: [
              _Rail(
                current: _tab,
                onSelect: _selectTab,
                onPhoneMode: () => ref
                    .read(tvModeSettingProvider.notifier)
                    .setMode(TvModeSetting.off),
              ),
              Expanded(child: _buildContent(groups)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<CmsCategoryGroup> groups) {
    switch (_tab) {
      case _tabCategory:
        return _buildCategory(groups);
      case _tabRank:
        return const TvRankPage();
      case _tabSearch:
        return const TvSearchPage(showBack: false);
      case _tabProfile:
        return const TvProfilePage();
      case _tabHome:
      default:
        return const TvHomePage();
    }
  }

  Widget _buildCategory(List<CmsCategoryGroup> groups) {
    final fallback = groups.isEmpty ? null : groups.first.category;
    final effectiveId = _typeId > 0 ? _typeId : (fallback?.typeId ?? 0);
    final effectiveName = _typeId > 0
        ? _typeName
        : (fallback?.typeName ?? '分类');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 66,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: TvMetrics.safeH,
              vertical: 14,
            ),
            children: [
              for (final group in groups)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TvChip(
                    label: group.category.typeName,
                    selected: group.category.typeId == effectiveId,
                    onSelect: () => _selectCategory(
                      group.category.typeId,
                      group.category.typeName,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: TvListPage(
            key: ValueKey(effectiveId),
            typeId: effectiveId,
            title: effectiveName,
          ),
        ),
      ],
    );
  }
}

class _RailEntry {
  const _RailEntry(this.label, this.icon, this.tab);

  final String label;
  final IconData icon;
  final int tab;
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.current,
    required this.onSelect,
    required this.onPhoneMode,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final VoidCallback onPhoneMode;

  static const List<_RailEntry> _entries = [
    _RailEntry('首页', LucideIcons.home, 0),
    _RailEntry('分类', LucideIcons.layoutGrid, 1),
    _RailEntry('排行', LucideIcons.trophy, 2),
    _RailEntry('搜索', LucideIcons.search, 3),
    _RailEntry('我的', LucideIcons.user, 4),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: TvMetrics.railWidth,
      decoration: const BoxDecoration(
        color: TvColors.surface,
        border: Border(right: BorderSide(color: TvColors.divider)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 28),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.play, size: 22, color: TvColors.accent),
              SizedBox(width: 8),
              Text(
                'EchoTV',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: TvColors.text1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              physics: const BouncingScrollPhysics(),
              children: [
                for (final entry in _entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: _RailButton(
                      entry: entry,
                      selected: entry.tab == current,
                      onSelect: () => onSelect(entry.tab),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 22),
            child: _RailButton(
              entry: const _RailEntry('手机版', LucideIcons.smartphone, -1),
              selected: false,
              onSelect: onPhoneMode,
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.entry,
    required this.selected,
    required this.onSelect,
  });

  final _RailEntry entry;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: onSelect,
      focusedScale: 1.04,
      builder: (context, focused) {
        final Color bg;
        if (focused) {
          bg = TvColors.accent;
        } else if (selected) {
          bg = TvColors.surfaceHigh;
        } else {
          bg = Colors.transparent;
        }
        final Color fg;
        if (focused) {
          fg = Colors.white;
        } else if (selected) {
          fg = TvColors.accent;
        } else {
          fg = TvColors.text2;
        }
        return AnimatedContainer(
          duration: TvMetrics.focusDuration,
          height: TvMetrics.railItemHeight,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
            border: Border.all(
              color: focused ? TvColors.focus : Colors.transparent,
              width: 2,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: TvColors.accent.withValues(alpha: 0.4),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(entry.icon, size: 26, color: fg),
              const SizedBox(height: 6),
              Text(
                entry.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
