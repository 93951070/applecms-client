import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统画中画（Picture-in-Picture）服务。
///
/// 与原生 `echotv/pip` 通道通信：原生在进入/退出 PiP 时反向通知，Dart 侧据此
/// 在 PiP 期间保持播放（不因退到后台而暂停）。
class PipService {
  static const MethodChannel _channel = MethodChannel('echotv/pip');

  /// 当前是否处于系统画中画窗口。
  static final ValueNotifier<bool> inPip = ValueNotifier<bool>(false);

  /// 原生侧上报的画中画运行状态（诊断用）。
  static final ValueNotifier<String?> status = ValueNotifier<String?>(null);

  /// 当前播放器是否启用了画中画（启用后离开 App 应保持播放并进入小窗）。
  static bool get enabled => _enabled;
  static bool _enabled = false;

  static bool _initialized = false;

  /// 注册原生反向回调，App 启动时调用一次。
  static void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') {
        final args = call.arguments;
        if (args is Map) {
          inPip.value = args['isInPip'] == true;
        }
      } else if (call.method == 'onPipStatus') {
        status.value = call.arguments?.toString();
      }
      return null;
    });
  }

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  static Future<bool> isSupported() async {
    if (!_mobile) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 播放器就绪后开启，离开 App 时自动进入系统画中画；停止播放时关闭。
  ///
  /// `aspectRatio` 用于让系统画中画窗口按视频比例显示（Android 用）。
  static Future<void> setEnabled(bool enabled, {double? aspectRatio}) async {
    if (!_mobile) return;
    _enabled = enabled;
    try {
      await _channel.invokeMethod('setEnabled', {
        'enabled': enabled,
        if (aspectRatio != null && aspectRatio > 0) 'aspectRatio': aspectRatio,
      });
    } catch (_) {}
  }

  /// 主动进入系统画中画。
  static Future<bool> enter({double? aspectRatio}) async {
    if (!_mobile) return false;
    try {
      return await _channel.invokeMethod<bool>('enter', {
        if (aspectRatio != null && aspectRatio > 0) 'aspectRatio': aspectRatio,
      }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
