import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../pages/home.dart';
import '../pages/rank.dart';
import '../pages/short_drama_tab.dart';
import '../pages/profile.dart';
import 'appad_widgets.dart';

/// 手机端主框架：底部 4-Tab 导航（首页 / 排行榜 / 短剧 / 我的）。
///
/// 页面用 [PageView] 托管，支持左右滑动切换；切换过程叠加 3D 卡片旋转效果。
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

  /// 3D 卡片旋转：越接近当前页越正视，两侧页面绕 Y 轴旋转并轻微缩小。
  Widget _build3DPage(int index, Widget child) {
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
        final angle = t * 0.30;
        final scale = 1.0 - t.abs() * 0.08;
        return Transform(
          alignment: t >= 0 ? Alignment.centerRight : Alignment.centerLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0014)
            ..rotateY(angle)
            ..scaleByDouble(scale, scale, scale, 1),
          child: inner,
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
          child: _build3DPage(i, _pages[i]),
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
