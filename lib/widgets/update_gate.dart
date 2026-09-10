import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/navigation.dart';
import '../services/app_api_service.dart';
import '../services/config_service.dart';

/// 启动时通过 App 网关检查版本，必要时提示更新。
///
/// 网关不可用时静默跳过，不影响正常启动。
class UpdateGate extends ConsumerStatefulWidget {
  final Widget child;

  const UpdateGate({super.key, required this.child});

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final config = ref.read(configServiceProvider);
      final api = ref.read(appApiServiceProvider);
      final base = await config.getApiBaseUrl();
      final pkg = await PackageInfo.fromPlatform();
      final info = await api.checkVersion(base, pkg.version);
      if (!mounted) return;
      await _waitForNavigator();
      if (!mounted) return;
      if (info.forceUpdate) {
        _showUpdateDialog(info, force: true);
      } else if (info.needUpdate) {
        _showUpdateDialog(info, force: false);
      }
    } catch (_) {
      // 网关不可用时静默降级
    }
  }

  /// 等待根 Navigator 挂载完成，避免 builder 上下文尚未就绪。
  Future<void> _waitForNavigator() async {
    for (var i = 0; i < 20; i++) {
      if (rootNavigatorKey.currentContext != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _launch(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showUpdateDialog(AppVersionInfo info, {required bool force}) {
    final navContext = rootNavigatorKey.currentContext;
    if (navContext == null) return;
    final hasUrl = (info.updateUrl ?? '').isNotEmpty;
    showDialog<void>(
      context: navContext,
      barrierDismissible: !force,
      builder: (ctx) => PopScope(
        canPop: !force,
        child: AlertDialog(
          title: Text(force ? '需要更新' : '发现新版本'),
          content: Text(
            '最新版本：${info.latestVersion}\n'
            '${force ? '当前版本过低，请更新后继续使用。' : '建议更新到最新版本以获得更好体验。'}',
          ),
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('稍后'),
              ),
            if (hasUrl)
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _launch(info.updateUrl);
                },
                child: const Text('立即更新'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
