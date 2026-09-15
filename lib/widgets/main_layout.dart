import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../pages/home.dart';
import '../pages/rank.dart';
import '../pages/short_drama_tab.dart';
import '../pages/profile.dart';
import 'appad_widgets.dart';
import 'page_flip.dart';

/// 手机端主框架：底部 4-Tab 导航（首页 / 排行榜 / 短剧 / 我的）。
///
/// 底部 Tab 只用点击切换（横向滑动留给首页的分类翻页），
/// 切换过程与首页分类共用同一套 3D 翻页转场（见 [FlipPageView]）。
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
          duration: FlipConfig.duration,
          curve: FlipConfig.curve,
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

  /// 翻页结束后同步路由，保证底部栏高亮与深链一致。
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: MainTabScope(
        notifier: _activePath,
        child: Stack(
          children: [
            const Positioned.fill(child: _TabBackdrop()),
            FlipPageView(
              controller: _controller,
              itemCount: _paths.length,
              // 横向滑动留给首页的分类翻页，底部 Tab 只用点击切换。
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) => _KeepAlive(
                child: _pages[i],
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

/// 翻页底色：沿用极光同色系的柔和渐变 + 粉光晕，避免旋转页两侧露出黑色底。
class _TabBackdrop extends StatelessWidget {
  const _TabBackdrop();

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

