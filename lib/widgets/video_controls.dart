import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../models/site.dart';
import 'zen_ui.dart';
import 'bili_loading.dart';

class ZenVideoControls extends StatefulWidget {
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

  const ZenVideoControls({
    super.key,
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
  });

  @override
  State<ZenVideoControls> createState() => _ZenVideoControlsState();
}

class _ZenVideoControlsState extends State<ZenVideoControls> {
  VideoPlayerValue? _latestValue;
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
  
  // Gesture states
  double _brightness = 0.5;
  bool _isDragging = false;
  Offset _dragStartOffset = Offset.zero;
  double _dragStartVolume = 0.0;
  double _dragStartBrightness = 0.0;
  Duration _dragStartPosition = Duration.zero;
  String _dragHintType = ''; // 'volume', 'brightness', 'seek'

  late SkipConfig _localSkipConfig;

  // 固定复用同一个 FocusNode。此前每次 build 都新建并 requestFocus，
  // 导致控制层在视频播放期间不断抢焦点，输入框刚唤起键盘就被顶掉。
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'zen-video-controls');

  ChewieController? _chewieController;
  VideoPlayerController? _videoPlayerController;

  @override
  void initState() {
    super.initState();
    _localSkipConfig = widget.skipConfig;
    _lastVolume = widget.initialVolume;
    _danmakuFallbackNotifier = ValueNotifier<bool>(widget.danmakuEnabled);
    _danmakuInputFallbackNotifier =
        ValueNotifier<bool>(widget.danmakuInputActive);
    _initBrightness();
    // 仅初始化后请求一次焦点用于桌面端快捷键，之后不再抢占。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
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
      ScreenBrightness.instance.setApplicationScreenBrightness(value.clamp(0.0, 1.0)),
    );
  }

  @override
  void didUpdateWidget(ZenVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newChewieController = ChewieController.of(context);
    if (_chewieController != newChewieController) {
      _videoPlayerController?.removeListener(_updateState);
      _chewieController = newChewieController;
      _videoPlayerController = newChewieController.videoPlayerController;
      _latestValue = _videoPlayerController?.value;
      _videoPlayerController?.addListener(_updateState);
    }
  }

  @override
  void dispose() {
    _videoPlayerController?.removeListener(_updateState);
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _danmakuFallbackNotifier.dispose();
    _danmakuInputFallbackNotifier.dispose();
    _keyboardFocus.dispose();
    ScreenBrightness.instance.resetApplicationScreenBrightness().ignore();
    super.dispose();
  }

  void _updateState() {
    if (mounted && _videoPlayerController != null) {
      setState(() {
        _latestValue = _videoPlayerController!.value;
      });
    }
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
    if (event is! KeyDownEvent || _videoPlayerController == null) return;
    
    final key = event.logicalKey;
    if (_isLocked && key != LogicalKeyboardKey.keyL) return;

    if (key == LogicalKeyboardKey.space) {
      if (_videoPlayerController!.value.isPlaying) {
        _videoPlayerController!.pause();
        _showActionHint('已暂停', LucideIcons.pause);
      } else {
        _videoPlayerController!.play();
        _showActionHint('已播放', LucideIcons.play);
      }
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final newPos = _videoPlayerController!.value.position - const Duration(seconds: 10);
      _videoPlayerController!.seekTo(newPos < Duration.zero ? Duration.zero : newPos);
      _showActionHint('-10s', LucideIcons.rewind);
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      final newPos = _videoPlayerController!.value.position + const Duration(seconds: 10);
      _videoPlayerController!.seekTo(newPos);
      _showActionHint('+10s', LucideIcons.fastForward);
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final newVol = (_videoPlayerController!.value.volume + 0.1).clamp(0.0, 1.0);
      _videoPlayerController!.setVolume(newVol);
      if (newVol > 0) _lastVolume = newVol;
      _showActionHint('音量: ${(newVol * 100).toInt()}%', newVol == 0 ? LucideIcons.volumeX : (newVol < 0.5 ? LucideIcons.volume1 : LucideIcons.volume2));
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final newVol = (_videoPlayerController!.value.volume - 0.1).clamp(0.0, 1.0);
      _videoPlayerController!.setVolume(newVol);
      if (newVol > 0) _lastVolume = newVol;
      _showActionHint('音量: ${(newVol * 100).toInt()}%', newVol == 0 ? LucideIcons.volumeX : (newVol < 0.5 ? LucideIcons.volume1 : LucideIcons.volume2));
      _cancelAndRestartTimer();
    } else if (key == LogicalKeyboardKey.keyL) {
      setState(() => _isLocked = !_isLocked);
      _showActionHint(_isLocked ? '已上锁' : '已解锁', _isLocked ? LucideIcons.lock : LucideIcons.unlock);
      _cancelAndRestartTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_latestValue?.hasError ?? false) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.alertCircle, color: Colors.white70, size: 32),
            const SizedBox(height: 12),
            const Text('播放出错', style: TextStyle(color: Colors.white70, fontSize: 12)),
            TextButton(
              onPressed: () => _videoPlayerController?.initialize(),
              child: const Text('点击重试', style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
      );
    }

    return KeyboardListener(
      focusNode: _keyboardFocus,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onHover: (_) => _cancelAndRestartTimer(),
        child: GestureDetector(
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
                _startHideTimer();
              });
            } else if (_displayToggles) {
              setState(() => _displayToggles = false);
            } else {
              _cancelAndRestartTimer();
            }
          },
          onVerticalDragStart: (details) {
            _dragStartOffset = details.localPosition;
            _dragStartVolume = _videoPlayerController?.value.volume ?? 0.0;
            _dragStartBrightness = _brightness;
          },
          onVerticalDragUpdate: _handleVerticalDragUpdate,
          onVerticalDragEnd: _handleDragEnd,
          child: AbsorbPointer(
            absorbing: !_displayToggles && !_showSettings && !_showEpisodePanel,
            child: Stack(
              children: [
                if (_latestValue == null || !_latestValue!.isInitialized || _latestValue!.isBuffering)
                  const Center(child: BiliLoading(size: 40, color: Colors.white, strokeWidth: 2.5)),
                
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
                            Text(_hintText, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),
                
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
              setState(() => _isLocked = !_isLocked);
              _showActionHint(_isLocked ? '已上锁' : '已解锁', _isLocked ? LucideIcons.lock : LucideIcons.unlock);
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
            color: Colors.black.withOpacity(0.9),
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
                        child: const Icon(LucideIcons.chevronLeft, color: Colors.white70, size: 16),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _showSpeedSubMenu ? '播放倍速' : '播放设置',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: _showSpeedSubMenu ? _buildSpeedList() : _buildMainSettingsList(),
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
            color: Colors.black.withOpacity(0.9),
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
                          final wasFull =
                              _chewieController?.isFullScreen ?? false;
                          widget.onSelectEpisode?.call(index, wasFull);
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
                                const Icon(Icons.lock,
                                    color: Color(0xFFFFC24B), size: 10),
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
          subtitle: '${_latestValue?.playbackSpeed}x',
          trailing: const Icon(LucideIcons.chevronRight, color: Colors.white38, size: 12),
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
        const Divider(color: Colors.white12, height: 10),
        _buildSettingItem(
          title: '设当前为片头',
          subtitle: _localSkipConfig.introTime > 0 ? '${_localSkipConfig.introTime}s' : '未设置',
          onTap: () {
            final currentPos = _videoPlayerController?.value.position.inSeconds ?? 0;
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
          subtitle: _localSkipConfig.outroTime > 0 ? '跳过最后 ${_localSkipConfig.outroTime}s' : '未设置',
          onTap: () {
            final currentPos = _videoPlayerController?.value.position.inSeconds ?? 0;
            final total = _videoPlayerController?.value.duration.inSeconds ?? 0;
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
            const newConfig = SkipConfig(enable: false, introTime: 0, outroTime: 0);
            setState(() => _localSkipConfig = newConfig);
            widget.onSkipConfigChange?.call(newConfig);
          },
          textColor: Colors.redAccent,
        ),
      ],
    );
  }

  Widget _buildSpeedList() {
    final List<double> speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    return ListView(
      padding: EdgeInsets.zero,
      children: speeds.map((speed) {
        final isSelected = _latestValue?.playbackSpeed == speed;
        return Container(
          color: isSelected ? Colors.greenAccent.withValues(alpha: 0.1) : Colors.transparent,
          child: _buildSettingItem(
            title: '${speed}x',
            textColor: isSelected ? Colors.greenAccent : Colors.white,
            trailing: isSelected ? const Icon(LucideIcons.check, color: Colors.greenAccent, size: 14) : null,
            onTap: () {
              _videoPlayerController?.setPlaybackSpeed(speed);
              setState(() => _showSpeedSubMenu = false);
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSettingItem({required String title, String? subtitle, Widget? trailing, VoidCallback? onTap, Color? textColor}) {
    return ListTile(
      title: Text(title, style: TextStyle(color: textColor ?? Colors.white, fontSize: 12)),
      subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 9)) : null,
      trailing: trailing,
      onTap: onTap,
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final isFullScreen = _chewieController?.isFullScreen ?? false;
    if (!isFullScreen) return const SizedBox.shrink();
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
            GestureDetector(
              onTap: () {
                if (_chewieController?.isFullScreen ?? false) {
                  _chewieController?.exitFullScreen();
                  // 针对部分机型 exitFullScreen 不触发路由返回的补丁
                  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (context.mounted && (_chewieController?.isFullScreen ?? false)) {
                        Navigator.of(context).maybePop();
                      }
                    });
                  }
                } else {
                  Navigator.of(context).maybePop();
                }
              },
              child: _buildIconBtn(LucideIcons.chevronLeft, () {
                if (_chewieController?.isFullScreen ?? false) {
                  _chewieController?.exitFullScreen();
                  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (context.mounted && (_chewieController?.isFullScreen ?? false)) {
                        Navigator.of(context).maybePop();
                      }
                    });
                  }
                } else {
                  Navigator.of(context).maybePop();
                }
              }, size: 28),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final isLive = _chewieController?.isLive ?? false;
    return AnimatedOpacity(
      opacity: _displayToggles ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.6), Colors.transparent],
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
                  if (_videoPlayerController != null) _buildPlayPause(_videoPlayerController!),
                  if (widget.hasNextEpisode && widget.onNextEpisode != null)
                    _buildIconBtn(LucideIcons.stepForward, widget.onNextEpisode!),
                  if (_videoPlayerController != null) _buildVolumeButton(context),
                  const SizedBox(width: 8),
                  _buildPosition(context),
                  
                  const Spacer(),

                  // 弹幕开关：与设置/放大同尺寸，随控制条一起显隐
                  if (widget.showDanmakuControl)
                    ValueListenableBuilder<bool>(
                      valueListenable: widget.danmakuListenable ??
                          _danmakuFallbackNotifier,
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

                  // 右侧组合：[设置] [应用全屏] [桌面全屏]
                  if (!isLive && widget.showSettingsControl)
                    _buildIconBtn(LucideIcons.settings, () {
                      setState(() {
                        _showSettings = true;
                        _showEpisodePanel = false;
                        _displayToggles = true;
                      });
                    }),

                  if (widget.showFullscreenControl)
                    _buildIconBtn(LucideIcons.expand, () {
                      if (_chewieController?.isFullScreen ?? false) {
                        _chewieController?.exitFullScreen();
                        if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
                          Future.delayed(const Duration(milliseconds: 100), () {
                            if (context.mounted && Navigator.of(context).canPop()) {
                              Navigator.of(context).maybePop();
                            }
                          });
                        }
                      } else {
                        _chewieController?.enterFullScreen();
                      }
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
  /// 由 Chewie 渲染，因此竖屏与全屏（横屏）都可用。
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
                        color: Colors.black.withOpacity(0.55),
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
                          hintStyle: TextStyle(color: Colors.white70, fontSize: 13),
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
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit_rounded,
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
          color: Colors.white.withOpacity(0.16),
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
    final volume = _videoPlayerController?.value.volume ?? 1.0;
    IconData iconData = LucideIcons.volume2;
    if (volume == 0) {
      iconData = LucideIcons.volumeX;
    } else if (volume < 0.5) {
      iconData = LucideIcons.volume1;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _showVolumeSlider = true),
      onExit: (_) => setState(() => _showVolumeSlider = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HoverableIcon(
            icon: iconData,
            onTap: () {
              if (volume > 0) {
                _lastVolume = volume;
                _videoPlayerController?.setVolume(0.0);
              } else {
                _videoPlayerController?.setVolume(_lastVolume);
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
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: (val) {
                      _videoPlayerController?.setVolume(val);
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
    if (_videoPlayerController == null) return;

    final width = MediaQuery.of(context).size.width;
    final delta = -details.primaryDelta! / 200; // 灵敏度调节

    _isDragging = true;
    if (_dragStartOffset.dx < width * 0.35) { // 增加判定范围
      // 左侧：音量
      _dragHintType = 'volume';
      _dragStartVolume = (_dragStartVolume + delta).clamp(0.0, 1.0);
      _videoPlayerController!.setVolume(_dragStartVolume);
      if (_dragStartVolume > 0) _lastVolume = _dragStartVolume;
      _showActionHint('音量: ${(_dragStartVolume * 100).toInt()}%', _dragStartVolume == 0 ? LucideIcons.volumeX : (_dragStartVolume < 0.5 ? LucideIcons.volume1 : LucideIcons.volume2), autoHide: false);
    } else if (_dragStartOffset.dx > width * 0.65) {
      // 右侧：亮度
      _dragHintType = 'brightness';
      _dragStartBrightness = (_dragStartBrightness + delta).clamp(0.0, 1.0);
      _brightness = _dragStartBrightness;
      _applyScreenBrightness(_brightness);
      _showActionHint('亮度: ${(_brightness * 100).toInt()}%', LucideIcons.sun, autoHide: false);
    }
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (_videoPlayerController == null || _isLocked) return;
    
    final width = MediaQuery.of(context).size.width;
    final totalDuration = _videoPlayerController!.value.duration;
    if (totalDuration == Duration.zero) return;

    final delta = details.primaryDelta! / width * totalDuration.inSeconds * 0.5; // 灵敏度
    
    _isDragging = true;
    _dragHintType = 'seek';
    final newSeconds = (_dragStartPosition.inSeconds + delta).clamp(0.0, totalDuration.inSeconds.toDouble());
    final newPosition = Duration(seconds: newSeconds.toInt());
    _dragStartPosition = newPosition;
    
    final isForward = delta > 0;
    _showActionHint(
      '进度: ${_formatDuration(newPosition)} / ${_formatDuration(totalDuration)}', 
      isForward ? LucideIcons.fastForward : LucideIcons.rewind,
      autoHide: false
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    
    if (_dragHintType == 'seek' && _videoPlayerController != null) {
      _videoPlayerController!.seekTo(_dragStartPosition);
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
        if (_isLocked || _videoPlayerController == null) return;
        if (_videoPlayerController!.value.isPlaying) {
          _videoPlayerController!.pause();
          _showActionHint('已暂停', LucideIcons.pause);
        } else {
          _videoPlayerController!.play();
          _showActionHint('已播放', LucideIcons.play);
        }
        _cancelAndRestartTimer();
      },
      onHorizontalDragStart: (details) {
        if (_isLocked) return;
        _dragStartPosition = _videoPlayerController?.value.position ?? Duration.zero;
      },
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: Container(color: Colors.transparent),
    );
  }

  Widget _buildPlayPause(VideoPlayerController controller) {
    return _HoverableIcon(
      icon: controller.value.isPlaying ? LucideIcons.pause : LucideIcons.play,
      onTap: () {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
        _cancelAndRestartTimer();
      },
      size: 20,
    );
  }

  Widget _buildPosition(BuildContext context) {
    final position = _latestValue?.position ?? Duration.zero;
    final duration = _latestValue?.duration ?? Duration.zero;
    return Text(
      '${_formatDuration(position)} / ${_formatDuration(duration)}',
      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w400),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  Widget _buildProgressBar() {
    if (_videoPlayerController == null) return const SizedBox.shrink();
    
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
            value: _videoPlayerController!.value.position.inMilliseconds.toDouble().clamp(
              0.0, 
              _videoPlayerController!.value.duration.inMilliseconds.toDouble()
            ),
            max: _videoPlayerController!.value.duration.inMilliseconds.toDouble(),
            onChanged: _isLocked ? null : (value) {
              _videoPlayerController!.seekTo(Duration(milliseconds: value.toInt()));
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
              color: _isHovered ? Colors.white : Colors.white.withOpacity(0.85),
              size: widget.size,
            ),
          ),
        ),
      ),
    );
  }
}
