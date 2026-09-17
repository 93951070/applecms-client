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

/// TV 版外壳：顶部横向导航 + 下方内容区。
///
/// 采用市面主流 TV 端的顶部 Tab 布局：左侧品牌标识，中间 Tab 导航，
/// 右侧固定入口（手机版），内容区整屏展示。
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
          Column(
            children: [
              _TopNav(
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

class _NavEntry {
  const _NavEntry(this.label, this.icon, this.tab);

  final String label;
  final IconData icon;
  final int tab;
}

/// 顶部导航栏：品牌标识 + Tab + 右侧固定入口。
class _TopNav extends StatelessWidget {
  const _TopNav({
    required this.current,
    required this.onSelect,
    required this.onPhoneMode,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final VoidCallback onPhoneMode;

  static const List<_NavEntry> _entries = [
    _NavEntry('首页', LucideIcons.home, 0),
    _NavEntry('分类', LucideIcons.layoutGrid, 1),
    _NavEntry('排行', LucideIcons.trophy, 2),
    _NavEntry('搜索', LucideIcons.search, 3),
    _NavEntry('我的', LucideIcons.user, 4),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TvMetrics.navHeight,
      padding: const EdgeInsets.symmetric(horizontal: TvMetrics.safeH),
      decoration: const BoxDecoration(
        color: Color(0xF2150F13),
        border: Border(bottom: BorderSide(color: TvColors.divider)),
      ),
      child: Row(
        children: [
          const _BrandLogo(),
          const SizedBox(width: 30),
          for (final entry in _entries)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _NavItem(
                entry: entry,
                selected: entry.tab == current,
                onSelect: () => onSelect(entry.tab),
              ),
            ),
          const Spacer(),
          _NavItem(
            entry: const _NavEntry('手机版', LucideIcons.smartphone, -1),
            selected: false,
            onSelect: onPhoneMode,
          ),
        ],
      ),
    );
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: TvMetrics.navLogoSize,
          height: TvMetrics.navLogoSize,
          decoration: BoxDecoration(
            gradient: TvGradients.brand,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(LucideIcons.play, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 10),
        const Text(
          'EchoTV',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: TvColors.text1,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

/// 顶部导航项：选中粉色描边胶囊，聚焦实心粉色。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.entry,
    required this.selected,
    required this.onSelect,
  });

  final _NavEntry entry;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: onSelect,
      focusedScale: 1.05,
      builder: (context, focused) {
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
          height: TvMetrics.navItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            gradient: focused ? TvGradients.brand : null,
            color: focused
                ? null
                : (selected
                      ? TvColors.accent.withValues(alpha: 0.16)
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
            border: Border.all(
              color: focused
                  ? Colors.white
                  : (selected ? TvColors.accent : Colors.transparent),
              width: focused ? 2 : 1.4,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: TvColors.accent.withValues(alpha: 0.45),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(entry.icon, size: 19, color: fg),
              const SizedBox(width: 8),
              Text(
                entry.label,
                style: TextStyle(
                  fontSize: 17,
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
