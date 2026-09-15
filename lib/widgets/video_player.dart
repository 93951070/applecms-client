import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/comment.dart';
import '../models/site.dart';
import '../providers/settings_provider.dart';
import 'video_controls.dart';
import 'bili_loading.dart';

class EchoVideoPlayer extends ConsumerStatefulWidget {
  final String url;
  final String title;
  final String? referer;
  final bool isLive;
  final double? initialPosition;
  final SkipConfig? skipConfig;
  final Function(SkipConfig)? onSkipConfigChange;
  final VoidCallback? onNextEpisode;
  final bool hasNextEpisode;
  final Function(Duration position, Duration duration, {bool isFinal})? onProgress;
  final VoidCallback? onEnded;
  final List<DanmakuItem> danmaku;
  final bool danmakuEnabled;
  final VoidCallback? onDanmakuToggle;
  final List<String> episodeTitles;
  final List<int> episodeNeedVip;
  final bool isVip;
  final int currentEpisodeIndex;
  final void Function(int index, bool wasFullScreen)? onSelectEpisode;
  final bool autoEnterFullScreen;
  final VoidCallback? onAutoFullScreenDone;
  final bool danmakuInputActive;
  final TextEditingController? danmakuController;
  final FocusNode? danmakuFocus;
  final VoidCallback? onDanmakuInputActivate;
  final VoidCallback? onDanmakuInputClose;
  final VoidCallback? onDanmakuSubmit;
  final bool showDanmakuControl;
  final bool showSettingsControl;
  final bool showFullscreenControl;
  final bool showPlaybackStatus;
  final bool startPaused;
  final void Function(String message)? onPlaybackError;
  final void Function(bool locked)? onLockChanged;

  const EchoVideoPlayer({
    super.key,
    required this.url,
    required this.title,
    this.referer,
    this.isLive = false,
    this.initialPosition,
    this.onPlaybackError,
    this.onLockChanged,
    this.skipConfig,
    this.onSkipConfigChange,
    this.onNextEpisode,
    this.hasNextEpisode = false,
    this.onProgress,
    this.onEnded,
    this.danmaku = const [],
    this.danmakuEnabled = true,
    this.onDanmakuToggle,
    this.episodeTitles = const [],
    this.episodeNeedVip = const [],
    this.isVip = false,
    this.currentEpisodeIndex = 0,
    this.onSelectEpisode,
    this.autoEnterFullScreen = false,
    this.onAutoFullScreenDone,
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
    this.startPaused = false,
  });

  @override
  ConsumerState<EchoVideoPlayer> createState() => EchoVideoPlayerState();
}

class EchoVideoPlayerState extends ConsumerState<EchoVideoPlayer>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin,
        SingleTickerProviderStateMixin {
  BetterPlayerController? _controller;
  final GlobalKey _betterPlayerKey = GlobalKey();
  bool _isInitializing = false;
  bool _isDisposed = false;
  Timer? _bufferingTimer;
  String? _errorMessage;

  /// 本次数据源是否已上报过「仅音频」错误，避免进度回调里反复上报。
  bool _reportedAudioOnly = false;
  bool _wasPlayingBeforePause = false;
  bool _holdPaused = false;
  bool _pipActive = false;
  bool _locked = false;
  bool _endedHandled = false;
  int _initToken = 0;
  Duration? _lastProgressSaveTime;

  late final AnimationController _danmakuTicker;
  final Set<int> _spawnedDanmaku = {};
  final List<_ActiveDanmaku> _activeDanmaku = [];
  static const int _danmakuLifetimeMs = 7000;

  final ValueNotifier<bool> _danmakuEnabledNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> _danmakuInputNotifier = ValueNotifier<bool>(false);

  VideoPlayerValue? get _value => _controller?.videoPlayerController?.value;

  Duration get currentPosition => _value?.position ?? Duration.zero;

  Duration get duration => _value?.duration ?? Duration.zero;

  bool get isPlaying => _value?.isPlaying ?? false;

  double get aspectRatio => _value?.aspectRatio ?? 0;

  bool get isBuffering => _value?.isBuffering ?? false;

  bool get isLocked => _locked;

  void pausePlayback() {
    if (_controller?.isFullScreen ?? false) return;
    _holdPaused = true;
    _safePause();
  }

  void forcePause() {
    _holdPaused = true;
    _safePause();
  }

  void resumePlayback() {
    _holdPaused = false;
    try {
      _controller?.play();
    } catch (_) {}
  }

  void seekToPosition(Duration position) {
    try {
      _controller?.seekTo(position);
    } catch (_) {}
  }

  Future<bool> isPipSupported() async {
    final c = _controller;
    if (c == null) return false;
    try {
      return await c.isPictureInPictureSupported();
    } catch (_) {
      return false;
    }
  }

  Future<void> enterPip() async {
    if (!ref.read(pipEnabledProvider)) return;
    try {
      await _controller?.enablePictureInPicture(_betterPlayerKey);
    } catch (_) {}
  }

  Future<void> exitPip() async {
    try {
      await _controller?.disablePictureInPicture();
    } catch (_) {}
  }

  void _safePause() {
    try {
      _controller?.pause();
    } catch (_) {}
    _cancelBufferingTimer();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _danmakuTicker =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
    _danmakuEnabledNotifier.value = widget.danmakuEnabled;
    _danmakuInputNotifier.value = widget.danmakuInputActive;
    _holdPaused = widget.startPaused;
    _initializePlayer();
  }

  @override
  void didUpdateWidget(EchoVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _initializePlayer();
    }
    if (oldWidget.danmaku != widget.danmaku) {
      _spawnedDanmaku.clear();
      _activeDanmaku.clear();
    }
    if (oldWidget.danmakuEnabled != widget.danmakuEnabled) {
      _danmakuEnabledNotifier.value = widget.danmakuEnabled;
      if (!widget.danmakuEnabled) {
        _activeDanmaku.clear();
      }
    }
    if (oldWidget.danmakuInputActive != widget.danmakuInputActive) {
      _danmakuInputNotifier.value = widget.danmakuInputActive;
    }
  }

  void _initializePlayer() {
    if (_isDisposed || !mounted) return;
    final token = ++_initToken;

    _releasePlayer();
    _endedHandled = false;

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
      _reportedAudioOnly = false;
    });

    final lowerUrl = widget.url.toLowerCase();
    final gatewayPath = Uri.tryParse(widget.url)?.path.toLowerCase() ?? '';
    final isGatewayHls =
        gatewayPath == '/api/app/v1/hls' || gatewayPath.startsWith('/api/app/v1/hls/');
    final isM3u8 = lowerUrl.contains('.m3u8') || isGatewayHls;
    bool useHlsHint = isM3u8;
    if (widget.isLive && !isM3u8) {
      const otherExtensions = ['.mp4', '.mov', '.mpd', '.mkv', '.webm'];
      if (!otherExtensions.any((ext) => widget.url.toLowerCase().contains(ext))) {
        useHlsHint = true;
      }
    }

    Duration? startAt;
    if (!widget.isLive &&
        widget.initialPosition != null &&
        widget.initialPosition! > 0) {
      startAt = Duration(seconds: widget.initialPosition!.toInt());
    }

    final volume = ref.read(playerVolumeProvider);

    final dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      widget.url,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
        if (widget.referer != null && widget.referer!.isNotEmpty)
          'Referer': widget.referer!,
      },
      liveStream: widget.isLive,
      videoFormat: useHlsHint ? BetterPlayerVideoFormat.hls : null,
    );

    final controller = BetterPlayerController(
      BetterPlayerConfiguration(
        autoPlay: !_holdPaused,
        startAt: startAt,
        fit: BoxFit.contain,
        allowedScreenSleep: false,
        handleLifecycle: false,
        autoDispose: false,
        fullScreenByDefault: widget.autoEnterFullScreen,
        deviceOrientationsAfterFullScreen: const [DeviceOrientation.portraitUp],
        controlsConfiguration: _buildControlsConfiguration(),
      ),
      betterPlayerDataSource: dataSource,
    );

    controller.setBetterPlayerGlobalKey(_betterPlayerKey);
    controller.addEventsListener(_onPlayerEvent);
    _controller = controller;

    if (volume != 1.0) {
      unawaited(_applyVolume(controller, volume));
    }

    if (token != _initToken || _isDisposed) return;
  }

  Future<void> _applyVolume(BetterPlayerController controller, double volume) async {
    try {
      await controller.setVolume(volume.clamp(0.0, 1.0).toDouble());
    } catch (_) {}
  }

  void _releasePlayer() {
    _cancelBufferingTimer();
    final old = _controller;
    _controller = null;
    if (old == null) return;
    try {
      old.removeEventsListener(_onPlayerEvent);
    } catch (_) {}
    try {
      old.dispose(forceDispose: true);
    } catch (_) {}
  }

  BetterPlayerControlsConfiguration _buildControlsConfiguration() {
    // 换内核前的自研控制条：内核只负责视频渲染，控制条通过
    // customControlsBuilder 注入，保持原有布局与功能。
    return BetterPlayerControlsConfiguration(
      playerTheme: BetterPlayerTheme.custom,
      customControlsBuilder: (controller, onVisibilityChanged, configuration) {
        return Positioned.fill(
          child: ZenVideoControls(
            controller: controller,
            skipConfig: widget.skipConfig ?? const SkipConfig(),
            onSkipConfigChange: widget.onSkipConfigChange,
            onNextEpisode: widget.onNextEpisode,
            hasNextEpisode: widget.hasNextEpisode,
            initialVolume: ref.read(playerVolumeProvider),
            onVolumeChanged: (v) =>
                ref.read(playerVolumeProvider.notifier).setVolume(v),
            danmakuEnabled: widget.danmakuEnabled,
            danmakuListenable: _danmakuEnabledNotifier,
            danmakuInputListenable: _danmakuInputNotifier,
            onDanmakuToggle: widget.onDanmakuToggle,
            episodeTitles: widget.episodeTitles,
            episodeNeedVip: widget.episodeNeedVip,
            isVip: widget.isVip,
            currentEpisodeIndex: widget.currentEpisodeIndex,
            onSelectEpisode: widget.onSelectEpisode,
            danmakuInputActive: widget.danmakuInputActive,
            danmakuController: widget.danmakuController,
            danmakuFocus: widget.danmakuFocus,
            onDanmakuInputActivate: widget.onDanmakuInputActivate,
            onDanmakuInputClose: widget.onDanmakuInputClose,
            onDanmakuSubmit: widget.onDanmakuSubmit,
            showDanmakuControl: widget.showDanmakuControl,
            showSettingsControl: widget.showSettingsControl,
            showFullscreenControl: widget.showFullscreenControl,
            showPlaybackStatus: widget.showPlaybackStatus,
            onLockChanged: _setLocked,
            pipEnabled: ref.read(pipEnabledProvider),
            onPipEnabledChanged: (v) =>
                ref.read(pipEnabledProvider.notifier).setEnabled(v),
          ),
        );
      },
    );
  }

  void _setLocked(bool value) {
    if (_locked == value) return;
    setState(() => _locked = value);
    widget.onLockChanged?.call(value);
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (_isDisposed || !mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        if (mounted) setState(() => _isInitializing = false);
        if (widget.autoEnterFullScreen) widget.onAutoFullScreenDone?.call();
        break;
      case BetterPlayerEventType.progress:
        final value = _value;
        if (value != null) _onTick(value.position, value.duration ?? Duration.zero);
        break;
      case BetterPlayerEventType.finished:
        _handleEnded();
        break;
      case BetterPlayerEventType.bufferingStart:
        _startBufferingTimer();
        break;
      case BetterPlayerEventType.bufferingEnd:
        _cancelBufferingTimer();
        break;
      case BetterPlayerEventType.pipStart:
        _pipActive = true;
        _holdPaused = false;
        // Android 进入画中画的时序可能先收到生命周期 paused（被误暂停），
        // 画中画生效后把播放恢复回来。
        if (!isPlaying) resumePlayback();
        break;
      case BetterPlayerEventType.pipStop:
        _pipActive = false;
        _holdPaused = false;
        break;
      case BetterPlayerEventType.exception:
        final message =
            event.parameters?['exception']?.toString() ?? '无法加载视频，请检查网络或更换线路';
        _handleError(message);
        break;
      default:
        break;
    }
  }

  void _onTick(Duration position, Duration total) {
    _updateDanmaku(position);

    final value = _value;
    if (value != null && value.initialized && !_isInitializing) {
      if (value.isBuffering) {
        _startBufferingTimer();
      } else {
        _cancelBufferingTimer();
      }
      if (!value.isBuffering &&
          value.size != null &&
          value.size!.width == 0 &&
          !widget.isLive) {
        setState(() {
          _errorMessage = '无法解析视频画面，请尝试切换线路';
        });
        // 只有声音没有画面（多半是纯音频清单）：上报一次，让上层自动换线路，
        // 否则用户会一直停在这条线上。
        if (!_reportedAudioOnly) {
          _reportedAudioOnly = true;
          widget.onPlaybackError?.call('该线路仅含音频，已自动更换线路');
        }
      }
    }

    if (widget.onProgress != null && (value?.isPlaying ?? false)) {
      if (_lastProgressSaveTime == null ||
          position.inSeconds != _lastProgressSaveTime!.inSeconds) {
        widget.onProgress!(position, total, isFinal: false);
        _lastProgressSaveTime = position;
      }
    }

    if (widget.skipConfig != null && widget.skipConfig!.enable && isPlaying) {
      final pos = position.inSeconds;
      final dur = total.inSeconds;
      if (widget.skipConfig!.introTime > 0 &&
          pos < widget.skipConfig!.introTime) {
        seekToPosition(Duration(seconds: widget.skipConfig!.introTime));
      }
      if (widget.skipConfig!.outroTime > 0 &&
          dur > 0 &&
          pos > (dur - widget.skipConfig!.outroTime)) {
        _handleEnded();
      }
    }

    if (total > Duration.zero && position >= total && !isPlaying) {
      _handleEnded();
    } else if (total == Duration.zero || position < total) {
      _endedHandled = false;
    }
  }

  void _handleEnded() {
    if (_endedHandled) return;
    _endedHandled = true;
    if (widget.onEnded != null) {
      widget.onEnded!();
    } else {
      _safePause();
    }
  }

  void _handleError(String message) {
    if (_isDisposed || !mounted) return;
    if (_errorMessage != null) return;
    setState(() {
      _errorMessage = message.contains('404') ? '资源不存在 (404)' : '无法加载视频，请检查网络或更换线路';
      _isInitializing = false;
    });
    widget.onPlaybackError?.call(message);
  }

  void _startBufferingTimer() {
    _bufferingTimer ??= Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      if (_value?.isBuffering ?? false) {
        _handleError('网络连接不稳定或资源加载失败');
      }
    });
  }

  void _cancelBufferingTimer() {
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
  }

  void _updateDanmaku(Duration position) {
    if (!widget.danmakuEnabled || widget.danmaku.isEmpty || !mounted) return;
    final nowMs = position.inMilliseconds;
    var changed = false;
    for (var i = 0; i < widget.danmaku.length; i++) {
      if (_spawnedDanmaku.contains(i)) continue;
      final item = widget.danmaku[i];
      if (item.timeMs > nowMs) continue;
      _spawnedDanmaku.add(i);
      if (nowMs - item.timeMs <= 1500) {
        _activeDanmaku.add(_ActiveDanmaku(item));
        changed = true;
      }
    }
    if (_activeDanmaku.isNotEmpty) {
      final before = _activeDanmaku.length;
      _activeDanmaku.removeWhere((a) =>
          DateTime.now().difference(a.started).inMilliseconds >
          _danmakuLifetimeMs);
      changed = changed || _activeDanmaku.length != before;
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    _isDisposed = true;
    _initToken++;
    _cancelBufferingTimer();
    WidgetsBinding.instance.removeObserver(this);

    if (_controller?.videoPlayerController != null &&
        widget.onProgress != null) {
      final value = _controller!.videoPlayerController!.value;
      if (value.initialized) {
        widget.onProgress!(value.position, value.duration ?? Duration.zero, isFinal: true);
      }
    }

    _releasePlayer();
    _danmakuTicker.dispose();
    _danmakuEnabledNotifier.dispose();
    _danmakuInputNotifier.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    if (state == AppLifecycleState.inactive) {
      // 进入后台前触发画中画：开关开启且正在播放时进入小窗。
      if (ref.read(pipEnabledProvider) && isPlaying && !_isInitializing) {
        unawaited(enterPip());
      }
      return;
    }
    if (state == AppLifecycleState.paused) {
      _wasPlayingBeforePause = isPlaying;
      _cancelBufferingTimer();
      // 画中画接管后保持播放，不再暂停。
      if (_pipActive) return;
      // iOS 保持播放等待系统接管画中画；Android 无画中画时按常理暂停。
      if (Platform.isIOS) return;
      _safePause();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    _cancelBufferingTimer();
    if (_pipActive) {
      _pipActive = false;
      // 回到应用时主动结束画中画，让画面归位到应用内，无需手动点关闭。
      unawaited(exitPip());
    }
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
    if (_wasPlayingBeforePause && !isPlaying) {
      resumePlayback();
    }
    _wasPlayingBeforePause = false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 订阅画中画开关，开关变化时重建控制条以同步状态。
    ref.watch(pipEnabledProvider);
    if (_errorMessage != null) {
      return _buildError();
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: VideoLoadingBar());
    }
    return PopScope(
      canPop: !_locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _locked) {
          _setLocked(false);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          BetterPlayer(controller: controller, key: _betterPlayerKey),
          _buildDanmakuOverlay(),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white54, size: 42),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '播放失败: ${widget.title}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _initializePlayer,
            child: const Text('重试', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildDanmakuOverlay() {
    if (!widget.danmakuEnabled || _activeDanmaku.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _danmakuTicker,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final now = DateTime.now();
              return Stack(
                children: List.generate(_activeDanmaku.length, (i) {
                  final active = _activeDanmaku[i];
                  final elapsed = now
                      .difference(active.started)
                      .inMilliseconds
                      .clamp(0, _danmakuLifetimeMs);
                  final progress = elapsed / _danmakuLifetimeMs;
                  final left = width - progress * (width + 240);
                  final top = 12.0 + (i % 6) * 26.0;
                  return Positioned(
                    left: left,
                    top: top,
                    child: Text(
                      active.item.content,
                      style: TextStyle(
                        color: _parseDanmakuColor(active.item.color),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 2),
                        ],
                      ),
                    ),
                  );
                }),
              );
            },
          );
        },
      ),
    );
  }

  Color _parseDanmakuColor(String hex) {
    final value = hex.replaceFirst('#', '');
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null || value.length != 6) return Colors.white;
    return Color(0xFF000000 | parsed);
  }
}

class _ActiveDanmaku {
  final DanmakuItem item;
  final DateTime started;

  _ActiveDanmaku(this.item) : started = DateTime.now();
}
