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
