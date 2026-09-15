import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/config_service.dart';

final themeModelProvider = NotifierProvider<ThemeModel, ThemeMode>(ThemeModel.new);

class ThemeModel extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // 默认跟随系统主题
    _loadTheme();
    return ThemeMode.system;
  }

  Future<void> _loadTheme() async {
    final configService = ref.read(configServiceProvider);
    try {
      final savedTheme = await configService.getThemeMode();
      // 只有当有保存的主题时才更新
      if (savedTheme != ThemeMode.system) {
        state = savedTheme;
      }
    } catch (e) {
      // 加载失败时保持默认的系统主题
      state = ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final configService = ref.read(configServiceProvider);
    await configService.setThemeMode(mode);
  }
}

final playerVolumeProvider = NotifierProvider<PlayerVolumeModel, double>(PlayerVolumeModel.new);

class PlayerVolumeModel extends Notifier<double> {
  @override
  double build() {
    _load();
    return 0.5;
  }

  Future<void> _load() async {
    final configService = ref.read(configServiceProvider);
    state = await configService.getPlayerVolume();
  }

  Future<void> setVolume(double volume) async {
    state = volume;
    final configService = ref.read(configServiceProvider);
    await configService.setPlayerVolume(volume);
  }
}

final pipEnabledProvider = NotifierProvider<PipEnabledModel, bool>(PipEnabledModel.new);

class PipEnabledModel extends Notifier<bool> {
  @override
  bool build() {
    _load();
    // 画中画默认开启
    return true;
  }

  Future<void> _load() async {
    final configService = ref.read(configServiceProvider);
    state = await configService.getPipEnabled();
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final configService = ref.read(configServiceProvider);
    await configService.setPipEnabled(enabled);
  }
}