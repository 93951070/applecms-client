import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'appad_widgets.dart';

/// 手机端主框架：底部扁平 4-Tab 导航（首页 / 排行榜 / 一起看 / 我的）
class MainLayout extends StatelessWidget {
  final Widget child;
  final String currentPath;

  const MainLayout({super.key, required this.child, required this.currentPath});

  static const _paths = ['/', '/rank', '/watch', '/profile'];

  int get _currentIndex {
    final i = _paths.indexOf(currentPath);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: child,
      bottomNavigationBar: AppTabBar(
        current: _currentIndex,
        onTap: (i) => context.go(_paths[i]),
      ),
    );
  }
}
