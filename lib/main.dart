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

  @override
  void initState() {
    super.initState();
    _checkTerms();
  }

  Future<void> _checkTerms() async {
    final agreed = await ref.read(configServiceProvider).getHasAgreedTerms();
    if (mounted) {
      setState(() {
        _hasAgreed = agreed;
        _isChecking = false;
      });
    }
  }

  void _onAgree() async {
    await ref.read(configServiceProvider).setHasAgreedTerms(true);
    if (mounted) {
      setState(() => _hasAgreed = true);
    }
  }

  Widget _buildTermsOverlay(BuildContext context) {
    // TV 上给「同意并继续」自动聚焦，遥控器可直接确认；触摸端不自动聚焦。
    final isTv = resolveTvMode(context, ref.watch(tvModeSettingProvider));
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
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
          actions: [
            ZenButton(
              onPressed: () => exit(0),
              backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
              foregroundColor: Theme.of(context).colorScheme.secondary,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              height: 44,
              borderRadius: 16,
              child: const Text('退出应用', style: TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 8),
            ZenButton(
              onPressed: _onAgree,
              autofocus: isTv,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              height: 44,
              borderRadius: 16,
              child: const Text('同意并继续', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
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

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return Container(color: Theme.of(context).scaffoldBackgroundColor);
    }
    
    return Stack(
      children: [
        // 未同意条款前禁止底层页面参与焦点，确保遥控器只在协议弹窗内导航。
        ExcludeFocus(excluding: !_hasAgreed, child: widget.child),
        if (!_hasAgreed) _buildTermsOverlay(context),
      ],
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


