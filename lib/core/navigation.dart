import 'package:flutter/material.dart';

/// 根导航器 key。
///
/// 更新弹窗等全局组件位于 [MaterialApp.builder] 中，其 context 在 Navigator
/// 之上，直接调用 showDialog 会找不到 Navigator。通过该 key 取得可用的
/// BuildContext。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// 全局路由观察者。
///
/// 用于页面感知自身何时被其它页面覆盖（如播放页跳转到另一个视频），
/// 从而及时暂停后台仍在播放的旧视频。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// 短剧 Tab 的路由路径：页面据此判断自己当前是否可见。
const String shortDramaTabPath = '/shortdrama';

/// 根导航器上「压在主界面之上的全屏页面」数量。
///
/// 主界面（含底部 4 个 Tab）自身为 0；每 push 一个全屏页面 +1，返回后 -1。
/// 底部 Tab 内的页面挂在 ShellRoute 的嵌套 Navigator 上，用
/// [ModalRoute.isCurrent] 判断不出被全屏页面盖住的情况，因此统一在这里计数。
///
/// 值大于 0 表示主界面已不可见，其中的播放器应立即停播。
final ValueNotifier<int> fullscreenRouteDepth = ValueNotifier<int>(0);

/// 维护 [fullscreenRouteDepth] 的根级导航观察者。
///
/// 注册在根导航器上（见 `main.dart` 的 `observers`）。弹层（弹窗、底部弹层等
/// [PopupRoute]）不遮挡播放，不计入深度。
class FullscreenRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // previousRoute 为空说明是导航器的首个路由，也就是主界面本身。
    if (previousRoute == null || route is PopupRoute) return;
    fullscreenRouteDepth.value = fullscreenRouteDepth.value + 1;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _decrease();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _decrease();
  }

  void _decrease() {
    if (fullscreenRouteDepth.value > 0) {
      fullscreenRouteDepth.value = fullscreenRouteDepth.value - 1;
    }
  }
}

/// 向子页面广播当前激活的 Tab 路径，页面据此在失活时停播。
///
/// Tab 页面被 [PageView] 保活后不会重建，自身也拿不到可靠的切换回调，
/// 因此统一由主框架下发当前路径，页面主动订阅。
class MainTabScope extends InheritedNotifier<ValueNotifier<String>> {
  const MainTabScope({
    super.key,
    required ValueNotifier<String> notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// 当前激活的 Tab 路径；主框架之外返回 null（表示不做 Tab 限制）。
  static String? activePathOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MainTabScope>()
        ?.notifier
        ?.value;
  }
}
