import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 当前平台是否支持原生投屏选择器（仅 iOS 提供 AVRoutePickerView）。
bool get airplayRoutePickerSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// iOS 原生 `AVRoutePickerView` 投屏按钮。
///
/// 这是一个原生按钮（不是可编程唤起的弹层）：用户点击后由系统直接弹出
/// AirPlay 设备列表，选中设备即把 App 播放器的音频/视频切到电视。
/// 非 iOS 平台渲染为空占位，调用方应先用 [airplayRoutePickerSupported] 判断。
class AirplayRoutePickerButton extends StatelessWidget {
  const AirplayRoutePickerButton({
    super.key,
    this.size = 26,
    this.color,
    this.activeColor,
    this.onShowPicker,
    this.onClosePicker,
  });

  static const String viewType = 'airplay_route_picker_view';
  static const String _channelName = 'airplay_route_picker';

  /// 按钮边长（正方形热区）。
  final double size;

  /// 常态图标颜色；为空时使用主题前景色。
  final Color? color;

  /// 选中态图标颜色；为空时同 [color]。
  final Color? activeColor;

  /// 投屏设备列表弹出/收起回调，可用于暂停或恢复画面。
  final VoidCallback? onShowPicker;
  final VoidCallback? onClosePicker;

  @override
  Widget build(BuildContext context) {
    if (!airplayRoutePickerSupported) return const SizedBox.shrink();
    final tint = color ?? IconTheme.of(context).color;
    MethodChannel? channel;
    return SizedBox(
      width: size,
      height: size,
      child: UiKitView(
        viewType: viewType,
        creationParams: <String, dynamic>{
          'prioritizesVideoDevices': true,
          if (tint != null) 'tintColor': _colorToParams(tint),
          if (tint != null)
            'activeTintColor': _colorToParams(activeColor ?? tint),
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (id) {
          channel = MethodChannel('$_channelName#$id');
          channel!.setMethodCallHandler((call) async {
            switch (call.method) {
              case 'onShowPickerView':
                onShowPicker?.call();
                break;
              case 'onClosePickerView':
                onClosePicker?.call();
                break;
            }
          });
        },
      ),
    );
  }

  /// 颜色按 0.0~1.0 分量传给原生，与 UIColor 的分量一致。
  static Map<String, double> _colorToParams(Color color) => <String, double>{
    'red': color.r,
    'green': color.g,
    'blue': color.b,
    'alpha': color.a,
  };
}
