import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme.dart';
import 'core/navigation.dart';
import 'pages/home.dart';
import 'pages/category_list.dart';
import 'pages/play.dart';
import 'pages/settings.dart';
import 'pages/search.dart';
import 'pages/rank.dart';
import 'pages/short_drama_tab.dart';
import 'pages/profile.dart';
import 'pages/login_page.dart';
import 'pages/messages_page.dart';
import 'pages/play_history_page.dart';
import 'providers/settings_provider.dart';
import 'services/config_service.dart';
import 'services/preload_service.dart';
import 'tv/tv_adaptive.dart';
import 'tv/tv_focus.dart';
import 'tv/tv_mode.dart';
import 'tv/tv_shell.dart';
import 'widgets/main_layout.dart';
import 'widgets/edit_dialog.dart';
import 'widgets/update_gate.dart';
import 'widgets/zen_ui.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const EchoTVApp(),
    ),
  );

  // 启动预热：分类树 / 首页聚合 / 主分类列表，提升首屏速度。
  unawaited(container.read(preloadServiceProvider).warmUp());
}

class EchoTVApp extends ConsumerStatefulWidget {
  const EchoTVApp({super.key});

  @override
  ConsumerState<EchoTVApp> createState() => _EchoTVAppState();
}

class _EchoTVAppState extends ConsumerState<EchoTVApp> {
  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModelProvider);
    
    return MaterialApp.router(
      title: 'EchoTV',
      debugShowCheckedModeBanner: false,
      theme: ZenTheme.lightTheme(),
      darkTheme: ZenTheme.darkTheme(),
      themeMode: themeMode,
      routerConfig: _router,
      builder: (context, child) {
        // Android TV 遥控器中央键（select）映射为激活：Material 按钮 / InkWell
        // 等原生控件也能被遥控器选中；自绘 TvFocusable / ZenButton 自行处理该键。
        return Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          },
          child: UpdateGate(
            child: TermsGate(child: TvAdaptiveScope(child: child!)),
          ),
        );
      },
    );
  }
}

/// 协议拦截门禁组件
class TermsGate extends ConsumerStatefulWidget {
  final Widget child;
  const TermsGate({super.key, required this.child});

  @override
  ConsumerState<TermsGate> createState() => _TermsGateState();
}

class _TermsGateState extends ConsumerState<TermsGate> {
  bool _hasAgreed = false;
  bool _isChecking = true;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _checkTerms();
  }

  Future<void> _checkTerms() async {
    final agreed = await ref.read(configServiceProvider).getHasAgreedTerms();
    if (!mounted) return;
    setState(() {
      _hasAgreed = agreed;
      _isChecking = false;
    });
    if (!agreed) _scheduleDialog();
  }

  void _scheduleDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _openTermsDialog());
  }

  /// 通过根 Navigator 弹出不可取消的模态对话框。
  ///
  /// 相比 Stack 覆盖层，模态路由自带独立 FocusScope 与针对底层页面的焦点拦截，
  /// Android TV 遥控器的方向键/确认键只会在协议弹窗内的按钮间移动。
  Future<void> _openTermsDialog() async {
    if (!mounted || _hasAgreed || _dialogOpen) return;
    final overlayContext = rootNavigatorKey.currentState?.overlay?.context;
    if (overlayContext == null) {
      // Navigator 尚未就绪时短暂等待后重试。
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted || _hasAgreed) return;
      return _openTermsDialog();
    }
    _dialogOpen = true;
    await showDialog<void>(
      context: overlayContext,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => _TermsDialog(
        onAgree: () async {
          await ref.read(configServiceProvider).setHasAgreedTerms(true);
          if (mounted) setState(() => _hasAgreed = true);
        },
      ),
    );
    _dialogOpen = false;
    // 若弹窗被异常关闭且仍未同意，则重新弹出，避免用户绕过条款。
    if (mounted && !_hasAgreed) _scheduleDialog();
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return Container(color: Theme.of(context).scaffoldBackgroundColor);
    }
    return widget.child;
  }
}

/// 用户条款模态弹窗：打开后显式聚焦「同意并继续」，
/// 保证 Android TV 遥控器无需先按方向键即可直接确认。
class _TermsDialog extends ConsumerStatefulWidget {
  final Future<void> Function() onAgree;

  const _TermsDialog({required this.onAgree});

  @override
  ConsumerState<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends ConsumerState<_TermsDialog> {
  final FocusNode _agreeFocus = FocusNode(debugLabel: 'terms_agree');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _agreeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _agreeFocus.dispose();
    super.dispose();
  }

  Future<void> _agree() async {
    await widget.onAgree();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // TV 模式直接使用已验证可遥控的 TvActionButton；触摸端保持 ZenButton。
    final isTv = resolveTvMode(context, ref.watch(tvModeSettingProvider));
    final actions = isTv
        ? <Widget>[
            TvActionButton(label: '退出应用', onSelect: () => exit(0)),
            const SizedBox(width: 12),
            TvActionButton(
              label: '同意并继续',
              primary: true,
              focusNode: _agreeFocus,
              onSelect: _agree,
            ),
          ]
        : <Widget>[
            ZenButton(
              onPressed: () => exit(0),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.05),
              foregroundColor: Theme.of(context).colorScheme.secondary,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              height: 44,
              borderRadius: 16,
              child: const Text('退出应用', style: TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 8),
            ZenButton(
              focusNode: _agreeFocus,
              onPressed: _agree,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              height: 44,
              borderRadius: 16,
              child: const Text('同意并继续', style: TextStyle(fontSize: 14)),
            ),
          ];
    return PopScope(
      canPop: false,
      child: EditDialog(
        title: const Text('用户条款'),
        width: 460,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '欢迎使用 EchoTV。在您开始之前，请务必阅读并理解以下条款：',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 16),
            _buildTermsItem('1. 工具性质', 'EchoTV 仅作为一个本地/远程资源管理工具，不内置、不提供、不分发任何影视或直播内容。'),
            _buildTermsItem('2. 数据来源', '应用内展示的所有资源均由用户自行配置，用户需对所配置资源的合法性承担全部法律责任。'),
            _buildTermsItem('3. 隐私声明', '我们不会收集您的个人隐私数据，您的配置信息仅存储在您的设备本地或您指定的云端。'),
            const SizedBox(height: 16),
            Text(
              '点击“同意”即代表您已阅读并同意上述条款。若您不同意，请选择“退出应用”。',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.secondary),
            ),
          ],
        ),
        actions: actions,
      ),
    );
  }

  Widget _buildTermsItem(String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Text(content, style: const TextStyle(fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
}

final _router = GoRouter(
  navigatorKey: rootNavigatorKey,
  observers: [routeObserver, FullscreenRouteObserver()],
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/play',
      pageBuilder: (context, state) {
        final params = state.uri.queryParameters;
        return _buildPageWithPlatformTransition(
          state,
          PlayPage(
            videoUrl: params['url'] ?? '',
            title: params['title'] ?? '正在播放',
          ),
        );
      },
    ),
    // 仅 4 个主 Tab 使用底部导航
    ShellRoute(
      builder: (context, state, child) {
        return Consumer(
          builder: (context, ref, _) {
            final setting = ref.watch(tvModeSettingProvider);
            if (resolveTvMode(context, setting)) {
              return const TvShell();
            }
            return MainLayout(
              currentPath: state.matchedLocation,
              child: child,
            );
          },
        );
      },
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) => _buildPageWithPlatformTransition(
            state,
            const HomePage(),
          ),
        ),
        GoRoute(
          path: '/rank',
          pageBuilder: (context, state) => _buildPageWithPlatformTransition(
            state,
            const RankPage(),
          ),
        ),
        GoRoute(
          path: '/shortdrama',
          pageBuilder: (context, state) => _buildPageWithPlatformTransition(
            state,
            const ShortDramaTabPage(),
          ),
        ),
        GoRoute(
          path: '/profile',
          pageBuilder: (context, state) => _buildPageWithPlatformTransition(
            state,
            const ProfilePage(),
          ),
        ),
      ],
    ),
    // 子页面：全屏，不显示底部导航
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _buildPageWithPlatformTransition(
        state,
        const SearchPage(),
      ),
    ),
    GoRoute(
      path: '/category',
      pageBuilder: (context, state) {
        final params = state.uri.queryParameters;
        final id = int.tryParse(params['id'] ?? '') ?? 0;
        return _buildPageWithPlatformTransition(
          state,
          CategoryListPage(
            typeId: id,
            title: params['title'] ?? '分类',
          ),
        );
      },
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => _buildPageWithPlatformTransition(
        state,
        const SettingsPage(),
      ),
    ),
    GoRoute(
      path: '/login',
      pageBuilder: (context, state) => _buildPageWithPlatformTransition(
        state,
        const LoginPage(),
      ),
    ),
    GoRoute(
      path: '/messages',
      pageBuilder: (context, state) => _buildPageWithPlatformTransition(
        state,
        const MessagesPage(),
      ),
    ),
    GoRoute(
      path: '/history',
      pageBuilder: (context, state) => _buildPageWithPlatformTransition(
        state,
        const PlayHistoryPage(),
      ),
    ),
  ],
);

/// 使用系统默认的过渡动画构建页面，这会应用我们在主题中定义的 PageTransitionsTheme

/// 从而在 iOS/macOS 上获得 Cupertino 风格的滑动切换和左滑返回手势

Page _buildPageWithPlatformTransition(GoRouterState state, Widget child) {

  return MaterialPage(

    key: state.pageKey,

    child: child,

  );

}


