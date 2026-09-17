import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TV 横屏 UI 的生效方式。
///
/// - [auto]：按屏幕形态自动判定（默认）
/// - [on]：强制使用 TV 版 UI
/// - [off]：强制使用手机版 UI
enum TvModeSetting { auto, on, off }

const String _kTvModeSetting = 'tv_mode_setting';

/// TV 模式设置，持久化在 SharedPreferences。
final tvModeSettingProvider = NotifierProvider<TvModeModel, TvModeSetting>(
  TvModeModel.new,
);

class TvModeModel extends Notifier<TvModeSetting> {
  @override
  TvModeSetting build() {
    _load();
    return TvModeSetting.auto;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _parse(prefs.getString(_kTvModeSetting));
  }

  Future<void> setMode(TvModeSetting mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTvModeSetting, mode.name);
  }

  static TvModeSetting _parse(String? raw) {
    for (final mode in TvModeSetting.values) {
      if (mode.name == raw) return mode;
    }
    return TvModeSetting.auto;
  }
}

/// 自动判定：横屏且最短边足够大时按 TV 处理。
///
/// Android TV 的逻辑尺寸一般在 540×960 以上，横屏手机最短边约 360-430，
/// 平板横屏最短边 600+，因此 500 可以把 TV/平板与手机区分开。识别不准时
/// 用户可在「我的 - 播放设置」里手动指定。
bool autoTvMode(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  if (size.width < size.height) return false;
  return size.shortestSide >= 500;
}

/// 结合用户设置解析当前是否走 TV 版 UI。
bool resolveTvMode(BuildContext context, TvModeSetting setting) {
  switch (setting) {
    case TvModeSetting.on:
      return true;
    case TvModeSetting.off:
      return false;
    case TvModeSetting.auto:
      return autoTvMode(context);
  }
}
