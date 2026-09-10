import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/navigation.dart';
import '../services/app_api_service.dart';
import '../services/config_service.dart';

/// 启动时通过 App 网关检查版本，必要时提示更新。
///
/// - Android：下载 APK 后调起系统安装器，实现应用内更新。
/// - iOS：受系统限制无法应用内覆盖安装，跳转网页下载。
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
      final info = await api.checkVersion(
        base,
        pkg.version,
        platform: Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : ''),
      );
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
      if (rootNavigatorKey.currentState?.overlay?.context != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 执行更新动作：Android 走应用内下载安装，其余跳转外部链接。
  Future<void> _runUpdate(String url) async {
    if (url.toLowerCase().endsWith('.apk') && Platform.isAndroid) {
      await _downloadAndInstall(url);
    } else {
      await _launch(url);
    }
  }

  Future<void> _downloadAndInstall(String url) async {
    final navigator = rootNavigatorKey.currentState;
    final overlayContext = navigator?.overlay?.context;
    if (navigator == null || overlayContext == null) return;

    final progress = ValueNotifier<double>(0);
    var dialogOpen = true;
    navigator.push(
      DialogRoute<void>(
        context: overlayContext,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('正在下载更新'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value > 0 ? value : null),
                const SizedBox(height: 12),
                Text('${(value * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ),
      ),
    );

    void closeDialog() {
      if (dialogOpen) {
        dialogOpen = false;
        navigator.pop();
      }
    }

    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/echotv-update-${DateTime.now().millisecondsSinceEpoch}.apk';
      await Dio().download(
        url,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0) progress.value = received / total;
        },
      );
      closeDialog();
      final result = await OpenFilex.open(
        path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        _snack(overlayContext, '无法调起安装器：${result.message}');
      }
    } catch (_) {
      closeDialog();
      _snack(overlayContext, '下载更新失败，请稍后重试');
    } finally {
      progress.dispose();
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showUpdateDialog(AppVersionInfo info, {required bool force}) {
    final navigator = rootNavigatorKey.currentState;
    final overlayContext = navigator?.overlay?.context;
    if (navigator == null || overlayContext == null) return;

    final url = info.updateUrl ?? '';
    final hasUrl = url.isNotEmpty;
    final canInApp = Platform.isAndroid;

    showDialog<void>(
      context: overlayContext,
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
                  _runUpdate(url);
                },
                child: Text(canInApp ? '立即更新' : '去下载'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
