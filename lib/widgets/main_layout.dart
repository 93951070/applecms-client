import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../pages/home.dart';
import '../pages/rank.dart';
import '../pages/short_drama_tab.dart';
import '../pages/profile.dart';
import 'appad_widgets.dart';

/// 手机端主框架：底部 4-Tab 导航（首页 / 排行榜 / 短剧 / 我的）。
///
/// 页面用 [PageView] 托管，支持左右滑动切换；切换过程叠加缩放抽屉式过渡效果。
class MainLayout extends StatefulWidget {
  final Widget child;
  final String currentPath;

  const MainLayout({super.key, required this.child, required this.currentPath});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  static const _paths = ['/', '/rank', shortDramaTabPath, '/profile'];

  static const List<Widget> _pages = [
    HomePage(),
    RankPage(),
    ShortDramaTabPage(),
    ProfilePage(),
  ];

  late final PageController _controller;
  int _index = 0;

  /// 当前激活的 Tab 路径，供页面订阅；页面据此在失活时停播。
  final ValueNotifier<String> _activePath = ValueNotifier<String>('/');

  int _indexForPath(String path) {
    final i = _paths.indexOf(path);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _index = _indexForPath(widget.currentPath);
    _activePath.value = _paths[_index];
    _controller = PageController(initialPage: _index, viewportFraction: 1.0);
  }

  @override
  void didUpdateWidget(covariant MainLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _indexForPath(widget.currentPath);
    if (target != _index) {
      _index = target;
      _activePath.value = _paths[target];
      if (_controller.hasClients) {
        _controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _activePath.dispose();
    super.dispose();
  }

  /// 滑动切换后同步路由，保证底部栏高亮与深链一致。
  void _onPageChanged(int i) {
    if (i == _index) return;
    _index = i;
    _activePath.value = _paths[i];
    context.go(_paths[i]);
  }

  void _onTabTap(int i) {
    if (i == _index) return;
    context.go(_paths[i]);
  }

  /// 缩放抽屉式过渡：当前页保持正视并停在正中，相邻页整体缩小、向侧向位移，
  /// 形成“抽出的面板 + 后退的层叠”纵深。
  ///
  /// 只做缩放与位移：不旋转、不加透视，页面始终是规整矩形，不会出现斜面或斜切。
  Widget _buildDrawerPage(int index, Widget child) {
    return AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, inner) {
        double delta;
        if (_controller.hasClients && _controller.position.haveDimensions) {
          delta = (_controller.page ?? _index.toDouble()) - index;
        } else {
          delta = (_index - index).toDouble();
        }
        final t = delta.clamp(-1.0, 1.0);
        final depth = t.abs();
        // 相邻页朝自己那一侧回抽，当前页停下时正好居中。
        final offsetX = t * MediaQuery.sizeOf(context).width * 0.06;
        // 背景页缩到 0.82（区间 0.78~0.86），当前页保持 1.0。
        final scale = 1.0 - depth * 0.18;
        return Transform.translate(
          offset: Offset(offsetX, 0),
          child: Transform.scale(
            scale: scale,
            child: _DrawerDepth(
              depth: depth,
              side: t >= 0 ? 1.0 : -1.0,
              child: inner!,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: MainTabScope(
        notifier: _activePath,
        child: Stack(
          children: [
            const Positioned.fill(child: _DrawerBackdrop()),
            PageView.builder(
              controller: _controller,
              itemCount: _paths.length,
              physics: const BouncingScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) => _KeepAlive(
                child: _buildDrawerPage(i, _pages[i]),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: AppTabBar(
        current: _index,
        immersive: _paths[_index] == '/shortdrama',
        onTap: _onTabTap,
      ),
    );
  }
}

/// 抽屉底色：沿用极光同色系的柔和渐变 + 粉光晕，避免后退页下方露出黑色底。
class _DrawerBackdrop extends StatelessWidget {
  const _DrawerBackdrop();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final top = isDark ? const Color(0xFF161016) : const Color(0xFFF6F0F4);
    final bottom = isDark ? const Color(0xFF0B080A) : const Color(0xFFF2F4FA);

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [top, bottom],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.85, -0.95),
                radius: 1.5,
                colors: [
                  AppColors.pink.withValues(alpha: isDark ? 0.16 : 0.20),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 抽屉纵深：给后退页加圆角与投影，并按 [depth] 压暗内容。
///
/// [depth] 为 0 表示该页正被拉出（当前页），保持规整矩形，不压暗、不投影。
class _DrawerDepth extends StatelessWidget {
  final double depth;
  final double side;
  final Widget child;

  const _DrawerDepth({
    required this.depth,
    required this.side,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (depth <= 0.001) return child;
    final radius = BorderRadius.circular(14 * depth);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24 * depth),
            blurRadius: 24 * depth,
            spreadRadius: 2 * depth,
            offset: Offset(side * 6 * depth, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.18 * depth),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 让 [PageView] 保活子页面，切换时保留各自滚动位置与状态。
class _KeepAlive extends StatefulWidget {
  final Widget child;

  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

