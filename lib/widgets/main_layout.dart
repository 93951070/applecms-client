import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../pages/home.dart';
import '../pages/rank.dart';
import '../pages/short_drama_tab.dart';
import '../pages/profile.dart';
import 'appad_widgets.dart';

/// 手机端主框架：底部 4-Tab 导航（首页 / 排行榜 / 短剧 / 我的）。
///
/// 页面用 [PageView] 托管，支持左右滑动切换；切换过程叠加 3D 抽屉式过渡效果。
class MainLayout extends StatefulWidget {
  final Widget child;
  final String currentPath;

  const MainLayout({super.key, required this.child, required this.currentPath});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  static const _paths = ['/', '/rank', '/shortdrama', '/profile'];

  static const List<Widget> _pages = [
    HomePage(),
    RankPage(),
    ShortDramaTabPage(),
    ProfilePage(),
  ];

  late final PageController _controller;
  int _index = 0;

  int _indexForPath(String path) {
    final i = _paths.indexOf(path);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _index = _indexForPath(widget.currentPath);
    _controller = PageController(initialPage: _index, viewportFraction: 0.94);
  }

  @override
  void didUpdateWidget(covariant MainLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _indexForPath(widget.currentPath);
    if (target != _index) {
      _index = target;
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
    super.dispose();
  }

  /// 滑动切换后同步路由，保证底部栏高亮与深链一致。
  void _onPageChanged(int i) {
    if (i == _index) return;
    _index = i;
    context.go(_paths[i]);
  }

  void _onTabTap(int i) {
    if (i == _index) return;
    context.go(_paths[i]);
  }

  /// 3D 抽屉式过渡：当前页像抽出的面板保持正视，相邻页沿朝向当前页的
  /// 边缘（铰链）向后退让——同时缩小、绕 Y 轴旋转并压暗，形成抽屉层叠纵深。
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
        // 铰链落在两页相接的一侧：相邻页绕该边缘向后退让。
        final hinge = t >= 0 ? Alignment.centerRight : Alignment.centerLeft;
        // 相邻页朝自己那一侧回抽，当前页停在正中。
        final offsetX = t * MediaQuery.sizeOf(context).width * 0.06;
        final angle = t * 0.35;
        final scale = 1.0 - depth * 0.12;
        return Transform(
          alignment: hinge,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0016)
            ..rotateY(angle)
            ..scaleByDouble(scale, scale, scale, 1),
          child: Transform.translate(
            offset: Offset(offsetX, 0),
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
      backgroundColor: Colors.transparent,
      body: PageView.builder(
        controller: _controller,
        itemCount: _paths.length,
        physics: const BouncingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemBuilder: (context, i) => _KeepAlive(
          child: _buildDrawerPage(i, _pages[i]),
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

/// 抽屉纵深：按 [depth] 压暗页面内容，并在朝向堆叠的一侧投下阴影。
///
/// [depth] 为 0 表示该页正被拉出（当前页），不压暗、不投影。
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
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.22 * depth),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20 * depth),
                    blurRadius: 24 * depth,
                    offset: Offset(side * 8 * depth, 0),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
