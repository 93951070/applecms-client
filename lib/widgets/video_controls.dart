import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../models/site.dart';
import 'zen_ui.dart';
import 'bili_loading.dart';

/// 自研播放器控制条（换内核前的布局与交互）。
///
/// 所有播放控制统一走 [BetterPlayerController] 的 API，控制条本身只负责
/// 布局、手势与状态展示，不重复实现播放逻辑。
class ZenVideoControls extends StatefulWidget {
  /// 播放器内核。
  final BetterPlayerController controller;

  final VoidCallback? onNextEpisode;
  final bool hasNextEpisode;
  final SkipConfig skipConfig;
  final Function(SkipConfig)? onSkipConfigChange;
  final double initialVolume;
  final Function(double)? onVolumeChanged;
  final bool danmakuEnabled;
  final ValueListenable<bool>? danmakuListenable;
  final ValueListenable<bool>? danmakuInputListenable;
  final VoidCallback? onDanmakuToggle;
  final List<String> episodeTitles;
  /// 与 [episodeTitles] 逐集对应的会员要求：0 免费，非 0 需会员。
  final List<int> episodeNeedVip;
  /// 当前用户是否已开通会员，用于决定是否在选集上显示锁。
  final bool isVip;
  final int currentEpisodeIndex;
  final void Function(int index, bool wasFullScreen)? onSelectEpisode;
  final bool danmakuInputActive;
  final TextEditingController? danmakuController;
  final FocusNode? danmakuFocus;
  final VoidCallback? onDanmakuInputActivate;
  final VoidCallback? onDanmakuInputClose;
  final VoidCallback? onDanmakuSubmit;
  /// 是否显示弹幕开关（一起看等无弹幕场景可关闭）。
  final bool showDanmakuControl;
  /// 是否显示播放设置入口（一起看跟随房主同步，无需本地设置）。
  final bool showSettingsControl;
  /// 是否显示全屏/放大按钮（一起看页面已是沉浸横屏）。
  final bool showFullscreenControl;
  /// 是否显示播放/暂停按钮与时间进度文字（一起看由房主同步，无需本地显示）。
  final bool showPlaybackStatus;

  /// 上锁状态变化回调，供页面同步拦截返回、隐藏返回入口。
  final void Function(bool locked)? onLockChanged;

  /// 画中画开关（写入播放器设置面板，默认开启）。
  final bool pipEnabled;
  final ValueChanged<bool>? onPipEnabledChanged;

  const ZenVideoControls({
    super.key,
    required this.controller,
    this.onNextEpisode,
    this.hasNextEpisode = false,
    required this.skipConfig,
    this.onSkipConfigChange,
    this.initialVolume = 0.5,
    this.onVolumeChanged,
    this.danmakuEnabled = true,
    this.danmakuListenable,
    this.danmakuInputListenable,
    this.onDanmakuToggle,
    this.episodeTitles = const [],
    this.episodeNeedVip = const [],
    this.isVip = false,
    this.currentEpisodeIndex = 0,
    this.onSelectEpisode,
    this.danmakuInputActive = false,
    this.danmakuController,
    this.danmakuFocus,
    this.onDanmakuInputActivate,
    this.onDanmakuInputClose,
    this.onDanmakuSubmit,
    this.showDanmakuControl = true,
    this.showSettingsControl = true,
    this.showFullscreenControl = true,
    this.showPlaybackStatus = true,
    this.onLockChanged,
    this.pipEnabled = true,
    this.onPipEnabledChanged,
  });

  @override
  State<ZenVideoControls> createState() => _ZenVideoControlsState();
}

class _ZenVideoControlsState extends State<ZenVideoControls> {
  Timer? _hideTimer;
  Timer? _hintTimer;
  bool _displayToggles = false;
  bool _showSettings = false;
  bool _showSpeedSubMenu = false;
  bool _showEpisodePanel = false;
  late final ValueNotifier<bool> _danmakuFallbackNotifier;
  late final ValueNotifier<bool> _danmakuInputFallbackNotifier;
  bool _isBarHovered = false;
  bool _isLocked = false;
  bool _showVolumeSlider = false;
  double _lastVolume = 0.5;
  bool _showHint = false;
  String _hintText = '';
  IconData _hintIcon = LucideIcons.play;
  final double _barHeight = 36.0;
  bool _pipSupported = false;

  // Gesture states
  double _brightness = 0.5;
  bool _isDragging = false;
  Offset _dragStartOffset = Offset.zero;
  double _dragStartVolume = 0.0;
  double _dragStartBrightness = 0.0;
  Duration _dragStartPosition = Duration.zero;
  String _dragHintType = ''; // 'volume', 'brightness', 'seek'

  late SkipConfig _localSkipConfig;

  // 固定复用同一个 FocusNode，避免控制层在播放期间不断抢焦点。
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'zen-video-controls');

  // 播放状态统一从内核读取，避免自建状态与内核不同步。
  VideoPlayerValue? get _latestValue => _controller.videoPlayerController?.value;
  bool get _isPlaying => _latestValue?.isPlaying ?? false;
  bool get _isInitialized => _latestValue?.initialized ?? false;
  bool get _isBuffering => _latestValue?.isBuffering ?? false;
  Duration get _position => _latestValue?.position ?? Duration.zero;
  Duration get _duration => _latestValue?.duration ?? Duration.zero;
  double get _volumeValue => _latestValue?.volume ?? 1.0;
  double get _speedValue => _latestValue?.speed ?? 1.0;
  bool get _hasError => _latestValue?.hasError ?? false;

  BetterPlayerController get _controller => widget.controller;

  bool get _isFullScreen => _controller.isFullScreen;

  bool get _isLive {
    try {
      return _controller.isLiveStream();
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _localSkipConfig = widget.skipConfig;
    _lastVolume = widget.initialVolume;
    _danmakuFallbackNotifier = ValueNotifier<bool>(widget.danmakuEnabled);
    _danmakuInputFallbackNotifier =
        ValueNotifier<bool>(widget.danmakuInputActive);
    _controller.addEventsListener(_onControllerEvent);
    _initBrightness();
    _loadPipSupport();
    // 仅初始化后请求一次焦点用于桌面端快捷键，之后不再抢占。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(ZenVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeEventsListener(_onControllerEvent);
      widget.controller.addEventsListener(_onControllerEvent);
      _loadPipSupport();
    }
    if (oldWidget.skipConfig != widget.skipConfig) {
      setState(() {
        _localSkipConfig = widget.skipConfig;
      });
    }
    if (oldWidget.danmakuInputActive != widget.danmakuInputActive) {
      _danmakuInputFallbackNotifier.value = widget.danmakuInputActive;
    }
  }

  @override
  void dispose() {
    _controller.removeEventsListener(_onControllerEvent);
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _danmakuFallbackNotifier.dispose();
    _danmakuInputFallbackNotifier.dispose();
    _keyboardFocus.dispose();
    unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness());
    super.dispose();
  }

  void _onControllerEvent(BetterPlayerEvent event) {
    if (!mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        // 控制器初始化后才能查询到设备是否支持画中画。
        _loadPipSupport();
        setState(() {});
        break;
      case BetterPlayerEventType.progress:
      case BetterPlayerEventType.play:
      case BetterPlayerEventType.pause:
      case BetterPlayerEventType.setSpeed:
      case BetterPlayerEventType.setVolume:
      case BetterPlayerEventType.bufferingStart:
      case BetterPlayerEventType.bufferingEnd:
        setState(() {});
        break;
      default:
        break;
    }
  }

  Future<void> _loadPipSupport() async {
    try {
      // 直接用底层播放器能力判断，避免控制器在非全屏/全屏切换时误判。
      final supported = await _controller.videoPlayerController
              ?.isPictureInPictureSupported() ??
          false;
      if (mounted && supported != _pipSupported) {
        setState(() => _pipSupported = supported);
      }
    } catch (_) {}
  }

  void _initBrightness() {
    unawaited(_loadBrightness());
  }

  Future<void> _loadBrightness() async {
    try {
      final value = await ScreenBrightness.instance.application;
      if (mounted) setState(() => _brightness = value.clamp(0.0, 1.0));
    } catch (_) {}
  }

  void _applyScreenBrightness(double value) {
    unawaited(
      ScreenBrightness.instance
          .setApplicationScreenBrightness(value.clamp(0.0, 1.0)),
    );
  }

  void _cancelAndRestartTimer() {
    _hideTimer?.cancel();
    _startHideTimer();
    setState(() {
      _displayToggles = true;
    });
  }

  bool get _danmakuInputActive =>
      (widget.danmakuInputListenable ?? _danmakuInputFallbackNotifier).value;

  void _startHideTimer() {
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          !_showSettings &&
          !_showEpisodePanel &&
          !_danmakuInputActive) {
        setState(() {
          _displayToggles = false;
        });
      }
    });
  }

  void _showActionHint(String text, IconData icon, {bool autoHide = true}) {
    _hintTimer?.cancel();
    setState(() {
      _hintText = text;
      _hintIcon = icon;
      _showHint = true;
    });
    if (autoHide) {
      _hintTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _showHint = false);
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;
    if (_isLocked && key != LogicalKeyboardKey.keyL) return;

    // 遥控器「OK / 确认」与手柄 A：播放/暂停（电视端最常用的按键）
    final isConfirm = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause;

    if (key == LogicalKeyboardKey.space || isConfirm) {
      if (_isPlaying) {
        _controller.pause();
        _showActionHint('已暂停', LucideIcons.pause);
      } else {
        _controller.play();
        _showActionHint('已播放', LucideIcons.play);
      }
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final newPos = _position - const Duration(seconds: 10);
      _controller.seekTo(newPos < Duration.zero ? Duration.zero : newPos);
      _showActionHint('-10s', LucideIcons.rewind);
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _controller.seekTo(_position + const Duration(seconds: 10));
      _showActionHint('+10s', LucideIcons.fastForward);
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final newVol = (_volumeValue + 0.1).clamp(0.0, 1.0);
      _controller.setVolume(newVol);
      if (newVol > 0) _lastVolume = newVol;
      _showActionHint('音量: ${(newVol * 100).toInt()}%', _volumeIcon(newVol));
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final newVol = (_volumeValue - 0.1).clamp(0.0, 1.0);
      _controller.setVolume(newVol);
      if (newVol > 0) _lastVolume = newVol;
      _showActionHint('音量: ${(newVol * 100).toInt()}%', _volumeIcon(newVol));
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.keyL) {
      _setLocked(!_isLocked);
      _showActionHint(_isLocked ? '已上锁' : '已解锁',
          _isLocked ? LucideIcons.lock : LucideIcons.unlock);
      _cancelAndRestartTimer();
    }
  }

  IconData _volumeIcon(double volume) {
    if (volume == 0) return LucideIcons.volumeX;
    if (volume < 0.5) return LucideIcons.volume1;
    return LucideIcons.volume2;
  }

  /// 统一切换上锁状态，并同步通知页面拦截返回。
  void _setLocked(bool value) {
    if (_isLocked == value) return;
    setState(() => _isLocked = value);
    widget.onLockChanged?.call(value);
  }

  void _toggleFullScreen(BuildContext context) {
    if (_isFullScreen) {
      _controller.exitFullScreen();
      // 针对部分机型 exitFullScreen 不触发路由返回的补丁
      if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (context.mounted && _controller.isFullScreen) {
            Navigator.of(context).maybePop();
          }
        });
      }
    } else {
      _controller.enterFullScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.alertCircle, color: Colors.white70, size: 32),
            const SizedBox(height: 12),
            const Text('播放出错', style: TextStyle(color: Colors.white70, fontSize: 12)),
            TextButton(
              onPressed: () => _controller.retryDataSource(),
              child: const Text('点击重试', style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_isLocked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isLocked) {
          _showActionHint('已上锁，请先解锁', LucideIcons.lock);
          _cancelAndRestartTimer();
        }
      },
      child: KeyboardListener(
        focusNode: _keyboardFocus,
        onKeyEvent: _handleKeyEvent,
        child: MouseRegion(
          onHover: (_) => _cancelAndRestartTimer(),
          child: GestureDetector(
            onVerticalDragStart: (details) {
              _dragStartOffset = details.localPosition;
              _dragStartVolume = _volumeValue;
              _dragStartBrightness = _brightness;
            },
            onVerticalDragUpdate: _handleVerticalDragUpdate,
            onVerticalDragEnd: _handleDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!_isInitialized || _isBuffering)
                  const Center(child: VideoLoadingBar()),

                // 点击 / 双击 / 横向拖动的命中区保持始终可交互，
                // 避免控制条隐藏时双击暂停、左右滑动快进退失效
                _buildHitArea(),

                // 中央提示
                if (_showHint)
                  Center(
                    child: AnimatedOpacity(
                      opacity: _showHint ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_hintIcon, color: Colors.white, size: 32),
                            const SizedBox(height: 8),
                            Text(_hintText,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 控制层：控制条隐藏时忽略点击让事件穿透到命中区，点击任意处即可唤出控制条
                IgnorePointer(
                  ignoring: !_displayToggles && !_showSettings && !_showEpisodePanel,
                  child: Stack(
                    children: [
                      if (_showSettings && !_isLocked) _buildSettingsOverlay(),
                      if (_showEpisodePanel && !_isLocked) _buildEpisodePanel(),

                      if (!_showSettings && !_showEpisodePanel) ...[
                        Column(
                          children: <Widget>[
                            _buildTopBar(context),
                            const Spacer(),
                            ValueListenableBuilder<bool>(
                              valueListenable:
                                  widget.danmakuListenable ?? _danmakuFallbackNotifier,
                              builder: (context, enabled, _) {
                                if (!enabled) return const SizedBox.shrink();
                                return ValueListenableBuilder<bool>(
                                  valueListenable: widget.danmakuInputListenable ??
                                      _danmakuInputFallbackNotifier,
                                  builder: (context, active, _) =>
                                      _buildDanmakuInputBar(active),
                                );
                              },
                            ),
                            _buildBottomBar(context),
                          ],
                        ),
                        _buildLockButton(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockButton() {
    return AnimatedOpacity(
      opacity: _displayToggles ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 24),
          child: _buildIconBtn(
            _isLocked ? LucideIcons.lock : LucideIcons.unlock,
            () {
              _setLocked(!_isLocked);
              _showActionHint(_isLocked ? '已上锁' : '已解锁',
                  _isLocked ? LucideIcons.lock : LucideIcons.unlock);
              _cancelAndRestartTimer();
            },
            size: 26,
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsOverlay() {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: GestureDetector(
        onTap: () {}, // 拦截点击，防止冒泡到顶层导致面板关闭
        behavior: HitTestBehavior.opaque,
        child: Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Container(
            width: 220,
            color: Colors.black.withValues(alpha: 0.9),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (_showSpeedSubMenu) {
                            setState(() => _showSpeedSubMenu = false);
                          } else {
                            setState(() {
                              _showSettings = false;
                              _startHideTimer();
                            });
                          }
                        },
                        child: const Icon(LucideIcons.chevronLeft,
                            color: Colors.white70, size: 16),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _showSpeedSubMenu ? '播放倍速' : '播放设置',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: _showSpeedSubMenu
                      ? _buildSpeedList()
                      : _buildMainSettingsList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodePanel() {
    final total = widget.episodeTitles.length;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: GestureDetector(
        onTap: () {}, // 拦截点击，防止冒泡到顶层导致面板关闭
        behavior: HitTestBehavior.opaque,
        child: Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Container(
            width: 250,
            color: Colors.black.withValues(alpha: 0.9),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _showEpisodePanel = false;
                            _startHideTimer();
                          });
                        },
                        child: const Icon(LucideIcons.chevronLeft,
                            color: Colors.white70, size: 16),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '选集 ($total)',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.3,
                    ),
                    itemCount: total,
                    itemBuilder: (context, index) {
                      final selected = index == widget.currentEpisodeIndex;
                      final locked = !widget.isVip &&
                          index < widget.episodeNeedVip.length &&
                          widget.episodeNeedVip[index] > 0;
                      return GestureDetector(
                        onTap: () {
                          setState(() => _showEpisodePanel = false);
                          widget.onSelectEpisode?.call(index, _isFullScreen);
                        },
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFF0A84FF)
                                : Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFF0A84FF)
                                  : Colors.white24,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (locked) ...[
                                const Icon(LucideIcons.lock,
                                    color: Color(0xFFFFC24B), size: 11),
                                const SizedBox(width: 2),
                              ],
                              Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainSettingsList() {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _buildSettingItem(
          title: '播放倍速',
          subtitle: '${_speedValue}x',
          trailing: const Icon(LucideIcons.chevronRight,
              color: Colors.white38, size: 12),
          onTap: () => setState(() => _showSpeedSubMenu = true),
        ),
        _buildSettingItem(
          title: '跳过片头片尾',
          trailing: Transform.scale(
            scale: 0.7,
            child: ZenSwitch(
              value: _localSkipConfig.enable,
              onChanged: (val) {
                final newConfig = SkipConfig(
                  enable: val,
                  introTime: _localSkipConfig.introTime,
                  outroTime: _localSkipConfig.outroTime,
                );
                setState(() => _localSkipConfig = newConfig);
                widget.onSkipConfigChange?.call(newConfig);
              },
            ),
          ),
        ),
        if (_pipSupported)
          _buildSettingItem(
            title: '画中画',
            subtitle: widget.pipEnabled ? '开启' : '关闭',
            trailing: Transform.scale(
              scale: 0.7,
              child: ZenSwitch(
                value: widget.pipEnabled,
                onChanged: (val) => widget.onPipEnabledChanged?.call(val),
              ),
            ),
          ),
        const Divider(color: Colors.white12, height: 10),
        _buildSettingItem(
          title: '设当前为片头',
          subtitle: _localSkipConfig.introTime > 0
              ? '${_localSkipConfig.introTime}s'
              : '未设置',
          onTap: () {
            final currentPos = _position.inSeconds;
            final newConfig = SkipConfig(
              enable: true,
              introTime: currentPos,
              outroTime: _localSkipConfig.outroTime,
            );
            setState(() => _localSkipConfig = newConfig);
            widget.onSkipConfigChange?.call(newConfig);
          },
        ),
        _buildSettingItem(
          title: '设当前为片尾',
          subtitle: _localSkipConfig.outroTime > 0
              ? '跳过最后 ${_localSkipConfig.outroTime}s'
              : '未设置',
          onTap: () {
            final currentPos = _position.inSeconds;
            final total = _duration.inSeconds;
            if (total > 0) {
              final newConfig = SkipConfig(
                enable: true,
                introTime: _localSkipConfig.introTime,
                outroTime: total - currentPos,
              );
              setState(() => _localSkipConfig = newConfig);
              widget.onSkipConfigChange?.call(newConfig);
            }
          },
        ),
        _buildSettingItem(
          title: '重置跳过设置',
          onTap: () {
            const newConfig =
                SkipConfig(enable: false, introTime: 0, outroTime: 0);
            setState(() => _localSkipConfig = newConfig);
            widget.onSkipConfigChange?.call(newConfig);
          },
          textColor: Colors.redAccent,
        ),
      ],
    );
  }

  Widget _buildSpeedList() {
    // 内核限定倍速在 0~2 之间，超出会抛错，因此这里最大只到 2.0。
    const List<double> speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return ListView(
      padding: EdgeInsets.zero,
      children: speeds.map((speed) {
        final isSelected = (_speedValue - speed).abs() < 0.01;
        return Container(
          color: isSelected
              ? Colors.greenAccent.withValues(alpha: 0.1)
              : Colors.transparent,
          child: _buildSettingItem(
            title: '${speed}x',
            textColor: isSelected ? Colors.greenAccent : Colors.white,
            trailing: isSelected
                ? const Icon(LucideIcons.check,
                    color: Colors.greenAccent, size: 14)
                : null,
            onTap: () {
              _controller.setSpeed(speed);
              setState(() => _showSpeedSubMenu = false);
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSettingItem(
      {required String title,
      String? subtitle,
      Widget? trailing,
      VoidCallback? onTap,
      Color? textColor}) {
    return ListTile(
      title: Text(title,
          style: TextStyle(color: textColor ?? Colors.white, fontSize: 12)),
      subtitle: subtitle != null
          ? Text(subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 9))
          : null,
      trailing: trailing,
      onTap: onTap,
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    if (!_isFullScreen) return const SizedBox.shrink();
    // 上锁后隐藏顶部返回按钮，避免误触退出，仅保留左下角解锁按钮。
    if (_isLocked) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: _displayToggles ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        height: _barHeight + 40,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(
          children: [
            _buildIconBtn(
              LucideIcons.chevronLeft,
              () {
                if (_isFullScreen) {
                  _toggleFullScreen(context);
                } else {
                  Navigator.of(context).maybePop();
                }
              },
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return AnimatedOpacity(
      opacity: _displayToggles ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(),
            const SizedBox(height: 8),
            Row(
              children: [
                if (!_isLocked) ...[
                  if (widget.showPlaybackStatus) _buildPlayPause(),
                  if (widget.hasNextEpisode && widget.onNextEpisode != null)
                    _buildIconBtn(LucideIcons.stepForward, widget.onNextEpisode!),
                  _buildVolumeButton(context),
                  if (widget.showPlaybackStatus) ...[
                    const SizedBox(width: 8),
                    _buildPosition(context),
                  ],

                  const Spacer(),

                  // 弹幕开关：与设置/放大同尺寸，随控制条一起显隐
                  if (widget.showDanmakuControl)
                    ValueListenableBuilder<bool>(
                      valueListenable:
                          widget.danmakuListenable ?? _danmakuFallbackNotifier,
                      builder: (context, enabled, _) => _buildIconBtn(
                        enabled ? LucideIcons.captions : LucideIcons.captionsOff,
                        () {
                          widget.onDanmakuToggle?.call();
                          _cancelAndRestartTimer();
                        },
                      ),
                    ),

                  // 选集：竖屏与全屏均可展开
                  if (widget.episodeTitles.length > 1)
                    _buildIconBtn(LucideIcons.listVideo, () {
                      setState(() {
                        _showEpisodePanel = true;
                        _showSettings = false;
                        _showSpeedSubMenu = false;
                        _displayToggles = true;
                      });
                    }),

                  // 右侧组合：[设置] [应用全屏]
                  if (!_isLive && widget.showSettingsControl)
                    _buildIconBtn(LucideIcons.settings, () {
                      setState(() {
                        _showSettings = true;
                        _showEpisodePanel = false;
                        _displayToggles = true;
                      });
                    }),

                  if (widget.showFullscreenControl)
                    _buildIconBtn(LucideIcons.expand, () {
                      _toggleFullScreen(context);
                    }),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 弹幕输入条：位于控制条正上方，不遮挡弹幕开关/设置/全屏按钮；
  /// 由控制条渲染，因此竖屏与全屏（横屏）都可用。
  Widget _buildDanmakuInputBar(bool active) {
    return AnimatedOpacity(
      opacity: _displayToggles ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: active
            ? Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: TextField(
                        controller: widget.danmakuController,
                        focusNode: widget.danmakuFocus,
                        maxLength: 50,
                        maxLines: 1,
                        textInputAction: TextInputAction.send,
                        onChanged: (_) => _cancelAndRestartTimer(),
                        onSubmitted: (_) => widget.onDanmakuSubmit?.call(),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: '发个弹幕吧...',
                          hintStyle:
                              TextStyle(color: Colors.white70, fontSize: 13),
                          counterText: '',
                          isDense: true,
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _danmakuBarButton('发送', () => widget.onDanmakuSubmit?.call()),
                  const SizedBox(width: 6),
                  _danmakuBarButton('取消', () => widget.onDanmakuInputClose?.call()),
                ],
              )
            : Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: () {
                        widget.onDanmakuInputActivate?.call();
                        _cancelAndRestartTimer();
                      },
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.squarePen,
                                size: 14, color: Colors.white70),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '发个弹幕吧...',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _danmakuBarButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Center(
          child: Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _buildIconBtn(IconData icon, VoidCallback onTap, {double size = 18}) {
    return _HoverableIcon(icon: icon, onTap: onTap, size: size);
  }

  Widget _buildVolumeButton(BuildContext context) {
    final volume = _volumeValue;

    return MouseRegion(
      onEnter: (_) => setState(() => _showVolumeSlider = true),
      onExit: (_) => setState(() => _showVolumeSlider = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HoverableIcon(
            icon: _volumeIcon(volume),
            onTap: () {
              if (volume > 0) {
                _lastVolume = volume;
                _controller.setVolume(0.0);
              } else {
                _controller.setVolume(_lastVolume);
              }
              _cancelAndRestartTimer();
            },
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _showVolumeSlider ? 100 : 0,
            height: 30,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: 100,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.0,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12.0),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: (val) {
                      _controller.setVolume(val);
                      if (val > 0) {
                        _lastVolume = val;
                        widget.onVolumeChanged?.call(val);
                      }
                      _cancelAndRestartTimer();
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    final width = MediaQuery.of(context).size.width;
    final delta = -details.primaryDelta! / 200; // 灵敏度调节

    _isDragging = true;
    if (_dragStartOffset.dx < width * 0.35) {
      // 左侧：音量
      _dragHintType = 'volume';
      _dragStartVolume = (_dragStartVolume + delta).clamp(0.0, 1.0);
      _controller.setVolume(_dragStartVolume);
      if (_dragStartVolume > 0) _lastVolume = _dragStartVolume;
      _showActionHint('音量: ${(_dragStartVolume * 100).toInt()}%',
          _volumeIcon(_dragStartVolume),
          autoHide: false);
    } else if (_dragStartOffset.dx > width * 0.65) {
      // 右侧：亮度
      _dragHintType = 'brightness';
      _dragStartBrightness = (_dragStartBrightness + delta).clamp(0.0, 1.0);
      _brightness = _dragStartBrightness;
      _applyScreenBrightness(_brightness);
      _showActionHint('亮度: ${(_brightness * 100).toInt()}%', LucideIcons.sun,
          autoHide: false);
    }
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isLocked) return;

    final width = MediaQuery.of(context).size.width;
    final totalDuration = _duration;
    if (totalDuration == Duration.zero) return;

    final delta =
        details.primaryDelta! / width * totalDuration.inSeconds * 0.5; // 灵敏度

    _isDragging = true;
    _dragHintType = 'seek';
    final newSeconds = (_dragStartPosition.inSeconds + delta)
        .clamp(0.0, totalDuration.inSeconds.toDouble());
    final newPosition = Duration(seconds: newSeconds.toInt());
    _dragStartPosition = newPosition;

    final isForward = delta > 0;
    _showActionHint(
      '进度: ${_formatDuration(newPosition)} / ${_formatDuration(totalDuration)}',
      isForward ? LucideIcons.fastForward : LucideIcons.rewind,
      autoHide: false,
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isDragging) return;

    if (_dragHintType == 'seek') {
      _controller.seekTo(_dragStartPosition);
    }

    setState(() {
      _isDragging = false;
      _dragHintType = '';
      // 拖动结束，800ms 后隐藏提示
      _hintTimer?.cancel();
      _hintTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _showHint = false);
      });
    });
    _cancelAndRestartTimer();
  }

  Widget _buildHitArea() {
    return GestureDetector(
      onTap: () {
        if (_isLocked) {
          _cancelAndRestartTimer();
          return;
        }
        if (_showSettings || _showEpisodePanel) {
          setState(() {
            _showSettings = false;
            _showSpeedSubMenu = false;
            _showEpisodePanel = false;
          });
        } else if (_displayToggles) {
          setState(() => _displayToggles = false);
        } else {
          _cancelAndRestartTimer();
        }
      },
      onDoubleTap: () {
        if (_isLocked) return;
        if (_isPlaying) {
          _controller.pause();
          _showActionHint('已暂停', LucideIcons.pause);
        } else {
          _controller.play();
          _showActionHint('已播放', LucideIcons.play);
        }
        _cancelAndRestartTimer();
      },
      onHorizontalDragStart: (details) {
        if (_isLocked) return;
        _dragStartPosition = _position;
      },
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: Container(color: Colors.transparent),
    );
  }

  Widget _buildPlayPause() {
    return _HoverableIcon(
      icon: _isPlaying ? LucideIcons.pause : LucideIcons.play,
      onTap: () {
        if (_isPlaying) {
          _controller.pause();
        } else {
          _controller.play();
        }
        _cancelAndRestartTimer();
      },
      size: 20,
    );
  }

  Widget _buildPosition(BuildContext context) {
    return Text(
      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
      style: const TextStyle(
          color: Colors.white, fontSize: 11, fontWeight: FontWeight.w400),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  Widget _buildProgressBar() {
    final totalMs = _duration.inMilliseconds.toDouble();
    if (totalMs <= 0) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) => setState(() => _isBarHovered = true),
      onExit: (_) => setState(() => _isBarHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: _isBarHovered ? 12 : 8,
        alignment: Alignment.center,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: _isBarHovered ? 4.0 : 2.0,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: _isBarHovered ? 6.0 : 0.0,
              elevation: 2,
              pressedElevation: 4,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
            activeTrackColor: const Color(0xFF0A84FF),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
            thumbColor: Colors.white,
            trackShape: const RectangularSliderTrackShape(),
          ),
          child: Slider(
            value: _position.inMilliseconds.toDouble().clamp(0.0, totalMs),
            max: totalMs,
            onChanged: _isLocked
                ? null
                : (value) {
                    _controller
                        .seekTo(Duration(milliseconds: value.toInt()));
                  },
            onChangeStart: _isLocked ? null : (_) => _hideTimer?.cancel(),
            onChangeEnd: _isLocked ? null : (_) => _cancelAndRestartTimer(),
          ),
        ),
      ),
    );
  }
}

class _HoverableIcon extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _HoverableIcon({
    required this.icon,
    required this.onTap,
    this.size = 18,
  });

  @override
  State<_HoverableIcon> createState() => _HoverableIconState();
}

class _HoverableIconState extends State<_HoverableIcon> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _isHovered ? 1.15 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Icon(
              widget.icon,
              color: _isHovered
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.85),
              size: widget.size,
            ),
          ),
        ),
      ),
    );
  }
}
