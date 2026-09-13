import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/comment.dart';
import '../models/site.dart';
import '../providers/settings_provider.dart';
import '../services/pip_service.dart';
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
  /// 与 [episodeTitles] 逐集对应的会员要求：0 免费，非 0 需会员。
  final List<int> episodeNeedVip;
  /// 当前用户是否已开通会员。
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
  /// 控制条展示开关（一起看房间按需精简）。
  final bool showDanmakuControl;
  final bool showSettingsControl;
  final bool showFullscreenControl;
  final bool showPlaybackStatus;

  /// 首次初始化完成后保持暂停，不自动播放。
  /// 用于从一起看回到播放页时同步进度但避免立即出声。
  final bool startPaused;

  /// 运行期播放失败（缓冲超时、解码错误等）时回调，供上层自动重新解析。
  final void Function(String message)? onPlaybackError;

  const EchoVideoPlayer({
    super.key,
    required this.url,
    required this.title,
    this.referer,
    this.isLive = false,
    this.initialPosition,
    this.onPlaybackError,
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

class EchoVideoPlayerState extends ConsumerState<EchoVideoPlayer> with WidgetsBindingObserver, AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isInitializing = false;
  bool _isDisposed = false;
  Timer? _bufferingTimer;
  String? _errorMessage;
  bool _wasPlayingBeforePause = false;
  /// 主动暂停标记：缓冲/初始化完成前用户已离开播放（如进入一起看），
  /// 用于抑制 Chewie 的 autoPlay，避免「缓冲完成后在后台继续出声」。
  bool _holdPaused = false;

  /// 记录上一次的全屏状态，用于在全屏切换后重新绑定系统画中画来源。
  bool _lastFullScreen = false;

  /// 初始化代次号：切集/重试/离场时自增，使任何在途的旧初始化立即作废，
  /// 并强制释放它创建的控制器，避免出现「上一集还在后台出声」。
  int _initToken = 0;

  // 弹幕叠加层
  late final AnimationController _danmakuTicker;
  final Set<int> _spawnedDanmaku = {};
  final List<_ActiveDanmaku> _activeDanmaku = [];
  static const int _danmakuLifetimeMs = 7000;

  // 控制条上的弹幕开关控件只创建一次，用 Listenable 让图标能随状态刷新。
  final ValueNotifier<bool> _danmakuEnabledNotifier =
      ValueNotifier<bool>(true);
  final ValueNotifier<bool> _danmakuInputNotifier =
      ValueNotifier<bool>(false);

  Duration get currentPosition => _videoController?.value.position ?? Duration.zero;

  /// 视频总时长（一起看进度显示用）。
  Duration get duration => _videoController?.value.duration ?? Duration.zero;

  bool get isPlaying => _videoController?.value.isPlaying ?? false;

  /// 是否正在缓冲（一起看同步上报用）。
  bool get isBuffering => _videoController?.value.isBuffering ?? false;

  /// 暂停播放。用于离开当前页面时停止后台继续出声。
  /// 进入 Chewie 全屏同样会触发路由 push，此时不应暂停。
  void pausePlayback() {
    if (_chewieController?.isFullScreen ?? false) return;
    _holdPaused = true;
    _videoController?.pause();
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
  }

  /// 强制暂停，全屏时同样生效（一起看同步用）。
  void forcePause() {
    _holdPaused = true;
    _videoController?.pause();
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
  }

  /// 继续播放（一起看同步用）。
  void resumePlayback() {
    _holdPaused = false;
    _chewieController?.play();
  }

  /// 跳转到指定位置（一起看同步用）。
  void seekToPosition(Duration position) {
    _videoController?.seekTo(position);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PipService.inPip.addListener(_onPipChanged);
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

  Future<void> _initializePlayer() async {
    if (_isDisposed || !mounted) return;
    final token = ++_initToken;

    // 切集瞬间先暂停当前实例，旧音轨立即停止，不等待异步释放完成。
    _videoController?.pause();

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    VideoPlayerController? controller;

    try {
      final oldVideoController = _videoController;
      final oldChewieController = _chewieController;

      _videoController = null;
      _chewieController = null;

      if (oldChewieController != null) {
        try {
          oldChewieController.removeListener(_onChewieChanged);
          oldChewieController.dispose();
        } catch (e) {
          debugPrint('EchoVideoPlayer: dispose old chewie failed: $e');
        }
      }
      if (oldVideoController != null) {
        oldVideoController.removeListener(_videoListener);
        try {
          await oldVideoController.dispose();
        } catch (e) {
          debugPrint('EchoVideoPlayer: dispose old video failed: $e');
        }
        // 释放旧播放器资源后再创建新实例，避免底层解码器抢占。
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (_isDisposed || !mounted || token != _initToken) return;

      // 判定是否为标准的 M3U8 格式（用于 HLS 提示）。
      // 广告过滤已下沉到服务端，客户端直接播放后端下发的地址，不再起本地代理。
      // 后端 HLS 过滤入口可能不带扩展名（如 /api/app/v1/hls?t=），
      // 仅按扩展名判断会导致 Android ExoPlayer 误当渐进式媒体而播放失败。
      final lowerUrl = widget.url.toLowerCase();
      final gatewayPath = Uri.tryParse(widget.url)?.path.toLowerCase() ?? '';
      final isGatewayHls =
          gatewayPath == '/api/app/v1/hls' || gatewayPath.startsWith('/api/app/v1/hls/');
      final isM3u8 = lowerUrl.contains('.m3u8') || isGatewayHls;
      final playUrl = widget.url;

      // 判定是否给播放器 HLS 格式提示
      bool useHlsHint = isM3u8;
      if (widget.isLive && !isM3u8) {
        final otherExtensions = ['.mp4', '.mov', '.mpd', '.mkv', '.webm'];
        if (!otherExtensions.any((ext) => widget.url.toLowerCase().contains(ext))) {
          useHlsHint = true; 
        }
      }

      controller = VideoPlayerController.networkUrl(
        Uri.parse(playUrl),
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          if (widget.referer != null && widget.referer!.isNotEmpty) 'Referer': widget.referer!,
        },
        formatHint: useHlsHint ? VideoFormat.hls : null,
        // iOS 系统画中画必须以 AVPlayerLayer 为来源；默认的 textureView 走 Flutter
        // 纹理渲染，视图树里没有 AVPlayerLayer，画中画无法接入。因此 iOS 用平台视图，
        // Android 仍用纹理视图（平台视图在 Android 上限制较多）。
        viewType: Platform.isIOS
            ? VideoViewType.platformView
            : VideoViewType.textureView,
      );

      await controller.initialize();

      // 初始化期间若已切集或离场，直接丢弃该控制器，绝不允许它开始播放。
      if (_isDisposed || !mounted || token != _initToken) {
        if (_videoController == controller) _videoController = null;
        try {
          await controller.dispose();
        } catch (_) {}
        return;
      }

      _videoController = controller;

      // 若用户已主动离开播放（进入一起看等），初始化完成后保持暂停。
      if (_holdPaused) {
        await controller.pause();
      }

      // 计算跳转位置：使用页面传入的初始进度
      Duration? startAt;
      final resume = (widget.initialPosition != null && widget.initialPosition! > 0)
          ? Duration(seconds: widget.initialPosition!.toInt())
          : null;
      if (resume != null && resume > Duration.zero) {
        final seconds = resume.inSeconds;
        // 只有当进度小于总时长（或者总时长还未获取到）时才跳转
        if (controller.value.duration == Duration.zero || seconds < controller.value.duration.inSeconds) {
          startAt = resume;
          debugPrint('🎬 播放器准备跳转至: ${seconds}s');
        }
      }

      // 设置音量
      final volume = ref.read(playerVolumeProvider);
      await controller.setVolume(volume);

      // 期间若再次切集/离场，释放本控制器，避免出现「上一集还在后台出声」。
      if (_isDisposed || !mounted || token != _initToken) {
        if (_videoController == controller) _videoController = null;
        try {
          await controller.dispose();
        } catch (_) {}
        return;
      }

      // 进度监听
      controller.addListener(_videoListener);

      _chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: !_holdPaused,
        looping: false,
        startAt: startAt,
        aspectRatio: controller.value.aspectRatio,
        allowFullScreen: true,
        isLive: widget.isLive,
        customControls: ZenVideoControls(
          skipConfig: widget.skipConfig ?? SkipConfig(),
          onSkipConfigChange: widget.onSkipConfigChange,
          initialVolume: volume,
          onVolumeChanged: (vol) {
            ref.read(playerVolumeProvider.notifier).setVolume(vol);
          },
          hasNextEpisode: widget.hasNextEpisode,
          onNextEpisode: widget.onNextEpisode,
          danmakuEnabled: widget.danmakuEnabled,
          danmakuListenable: _danmakuEnabledNotifier,
          onDanmakuToggle: widget.onDanmakuToggle,
          episodeTitles: widget.episodeTitles,
          episodeNeedVip: widget.episodeNeedVip,
          isVip: widget.isVip,
          currentEpisodeIndex: widget.currentEpisodeIndex,
          onSelectEpisode: (index, wasFullScreen) {
            // 切集前先退出全屏，避免旧的 Chewie 全屏路由持有已被释放的控制器；
            // 页面会在新一集就绪后按需重新进入全屏。
            if (wasFullScreen) _chewieController?.exitFullScreen();
            widget.onSelectEpisode?.call(index, wasFullScreen);
          },
          danmakuInputActive: widget.danmakuInputActive,
          danmakuInputListenable: _danmakuInputNotifier,
          danmakuController: widget.danmakuController,
          danmakuFocus: widget.danmakuFocus,
          onDanmakuInputActivate: widget.onDanmakuInputActivate,
          onDanmakuInputClose: widget.onDanmakuInputClose,
          onDanmakuSubmit: widget.onDanmakuSubmit,
          showDanmakuControl: widget.showDanmakuControl,
          showSettingsControl: widget.showSettingsControl,
          showFullscreenControl: widget.showFullscreenControl,
          showPlaybackStatus: widget.showPlaybackStatus,
        ),
        materialProgressColors: ChewieProgressColors(
          playedColor: widget.isLive ? Colors.white : const Color(0xFF0A84FF),
          handleColor: widget.isLive ? Colors.white : const Color(0xFF0A84FF),
          bufferedColor: Colors.white.withOpacity(0.3),
          backgroundColor: Colors.white.withOpacity(0.1),
        ),
      );

      // 全屏切换会让 iOS 平台视图重建，画中画来源 AVPlayerLayer 会随之更换，
      // 这里监听全屏状态变化后重新绑定，保证离开 App 时仍能进入画中画。
      _lastFullScreen = _chewieController!.isFullScreen;
      _chewieController!.addListener(_onChewieChanged);

      // 播放器就绪后开启系统画中画：用户离开 App 时自动进入 PiP 小窗继续播放。
      // iOS 需要 AVPlayerLayer 已挂载到视图层级，稍作延迟再开启。
      final pipAspectRatio = controller.value.aspectRatio;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (_isDisposed || !mounted || token != _initToken) return;
        PipService.setEnabled(true, aspectRatio: pipAspectRatio);
      });

      if (widget.autoEnterFullScreen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isDisposed && mounted && _chewieController != null) {
            _chewieController!.enterFullScreen();
          }
          widget.onAutoFullScreenDone?.call();
        });
      }
    } catch (e) {
      if (controller != null && _videoController != controller) {
        try {
          await controller.dispose();
        } catch (_) {}
      }
      debugPrint('EchoVideoPlayer error: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _errorMessage = e.toString().contains('404') ? '资源不存在 (404)' : '无法加载视频，请检查网络或更换线路';
        });
      }
    } finally {
      if (!_isDisposed && mounted && token == _initToken) {
        setState(() => _isInitializing = false);
      }
    }
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
      _activeDanmaku.removeWhere(
          (a) => DateTime.now().difference(a.started).inMilliseconds > _danmakuLifetimeMs);
      changed = changed || _activeDanmaku.length != before;
    }
    if (changed) setState(() {});
  }

  void _videoListener() {
    if (_videoController == null || _isDisposed) return;
    
    final value = _videoController!.value;

    // 用户已开始播放（如点击播放键），解除主动暂停标记，恢复正常自动播放。
    if (value.isPlaying) _holdPaused = false;

    if (value.isInitialized) {
      _updateDanmaku(value.position);
    }
    
    // 监听缓冲状态（通用逻辑）
    if (value.isInitialized && value.isBuffering && !_isInitializing) {
      _bufferingTimer ??= Timer(const Duration(seconds: 15), () { // 点播宽限到 15s
        if (mounted && _videoController!.value.isBuffering) {
          setState(() {
            _errorMessage = '网络连接不稳定或资源加载失败';
          });
          widget.onPlaybackError?.call('网络连接不稳定或资源加载失败');
        }
      });
    } else {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
    }

    // 监听视频尺寸异常（通用逻辑：初始化完成但无有效画面数据）
    if (value.isInitialized && !value.isBuffering && value.size.width == 0) {
      // 排除掉纯音频流的情况（如果业务不需要显示纯音频，这里统一视为源异常）
      setState(() {
        _errorMessage = '无法解析视频画面，请尝试切换线路';
      });
    }

    // 进度回调
    // 进度回调 (每秒最多回调一次，且在播放时回调)
    if (widget.onProgress != null && value.isPlaying) {
      final currentPos = value.position;
      if (_lastProgressSaveTime == null || (currentPos.inSeconds != _lastProgressSaveTime!.inSeconds)) {
        widget.onProgress!(currentPos, value.duration, isFinal: false);
        _lastProgressSaveTime = currentPos;
      }
    }

    // --- 新增：跳过片头片尾逻辑 ---
    if (value.isPlaying && widget.skipConfig != null && widget.skipConfig!.enable) {
      final position = value.position.inSeconds;
      final duration = value.duration.inSeconds;

      // 跳过片头
      if (widget.skipConfig!.introTime > 0 && position < widget.skipConfig!.introTime) {
        _videoController!.seekTo(Duration(seconds: widget.skipConfig!.introTime));
        debugPrint('🛡️ 已跳过片头: ${widget.skipConfig!.introTime}s');
      }

      // 跳过片尾
      if (widget.skipConfig!.outroTime > 0 && duration > 0 && position > (duration - widget.skipConfig!.outroTime)) {
        debugPrint('🛡️ 已触碰片尾: ${widget.skipConfig!.outroTime}s');
        if (widget.onEnded != null) {
          widget.onEnded!();
        } else {
          _videoController!.pause();
        }
      }
    }

    // 结束回调
    if (value.position >= value.duration && value.duration > Duration.zero && !value.isPlaying) {
      if (widget.onEnded != null) {
        widget.onEnded!();
      }
    }
  }

  Duration? _lastProgressSaveTime;

  @override
  void dispose() {
    _isDisposed = true;
    _initToken++;
    PipService.inPip.removeListener(_onPipChanged);
    PipService.setEnabled(false);
    _bufferingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    
    // 销毁前保存最后进度
    if (_videoController != null && widget.onProgress != null) {
      final value = _videoController!.value;
      if (value.isInitialized) {
        widget.onProgress!(value.position, value.duration, isFinal: true);
      }
    }
    
    _videoController?.removeListener(_videoListener);
    _videoController?.dispose();
    _chewieController?.removeListener(_onChewieChanged);
    _chewieController?.dispose();
    _danmakuTicker.dispose();
    _danmakuEnabledNotifier.dispose();
    _danmakuInputNotifier.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 系统画中画下窗口仍可见，保持播放，不按退后台处理。
      if (PipService.inPip.value) return;
      _wasPlayingBeforePause = _videoController?.value.isPlaying ?? false;
      // 后台时取消缓冲误报计时，避免回前台立刻弹错误
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      _videoController?.pause();
      return;
    }
    if (state != AppLifecycleState.resumed || _isDisposed) return;

    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;

    final shouldResume = _wasPlayingBeforePause;
    _wasPlayingBeforePause = false;

    if (_errorMessage != null) {
      _errorMessage = null;
      setState(() {});
    }
    if (shouldResume && !controller.value.isPlaying) {
      // 回前台时连接可能刚被系统恢复，按当前位置重新起播即可，
      // 不再整实例重建，避免每次切后台回来都转圈重载。
      if (controller.value.isBuffering) {
        unawaited(controller.seekTo(controller.value.position));
      }
      controller.play();
    }
  }

  /// 进入系统画中画时确保继续播放。
  ///
  /// Android 进入 PiP 的时序可能先收到生命周期 paused（被误暂停、转圈），
  /// 这里在 PiP 生效后把播放恢复回来。
  void _onPipChanged() {
    if (!mounted || _isDisposed) return;
    if (!PipService.inPip.value) return;
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    _holdPaused = false;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
    if (!controller.value.isPlaying) {
      controller.play();
    }
  }

  /// 全屏切换后重新绑定画中画来源。
  ///
  /// iOS 平台视图在全屏路由重建时会产生新的 AVPlayerLayer，稍等其挂载后
  /// 再通知原生重新绑定，确保离开 App 时画中画仍可用。
  void _onChewieChanged() {
    final chewie = _chewieController;
    if (chewie == null) return;
    if (chewie.isFullScreen == _lastFullScreen) return;
    _lastFullScreen = chewie.isFullScreen;
    final aspect = _videoController?.value.aspectRatio ?? 0;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_isDisposed || !mounted) return;
      PipService.setEnabled(true, aspectRatio: aspect);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_errorMessage != null || (_videoController?.value.hasError ?? false)) {
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

    if (_isInitializing || _chewieController == null || !_videoController!.value.isInitialized) {
      return const Center(
        child: VideoLoadingBar(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Chewie(controller: _chewieController!),
        _buildDanmakuOverlay(),
      ],
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
