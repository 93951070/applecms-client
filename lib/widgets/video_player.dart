import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/comment.dart';
import '../models/site.dart';
import '../services/ad_block_service.dart';
import '../providers/settings_provider.dart';
import 'video_controls.dart';

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

  const EchoVideoPlayer({
    super.key,
    required this.url,
    required this.title,
    this.referer,
    this.isLive = false,
    this.initialPosition,
    this.skipConfig,
    this.onSkipConfigChange,
    this.onNextEpisode,
    this.hasNextEpisode = false,
    this.onProgress,
    this.onEnded,
    this.danmaku = const [],
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

  // 弹幕叠加层
  late final AnimationController _danmakuTicker;
  final Set<int> _spawnedDanmaku = {};
  final List<_ActiveDanmaku> _activeDanmaku = [];
  static const int _danmakuLifetimeMs = 7000;

  Duration get currentPosition => _videoController?.value.position ?? Duration.zero;

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
  }

  Future<void> _initializePlayer() async {
    if (_isDisposed) return;
    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    try {
      final oldVideoController = _videoController;
      final oldChewieController = _chewieController;
      
      _videoController = null;
      _chewieController = null;

      if (oldChewieController != null) {
        oldChewieController.dispose();
      }
      if (oldVideoController != null) {
        oldVideoController.removeListener(_videoListener);
        await oldVideoController.dispose();
      }

      // 为了确保旧播放器资源完全释放，稍微等一下
      await Future.delayed(const Duration(milliseconds: 200));
      if (_isDisposed) return;

      // 1. 判定是否为标准的 M3U8 格式（用于代理服务器处理）
      final isM3u8 = widget.url.toLowerCase().contains('.m3u8');
      
      // 2. 判定是否需要开启去广告代理（仅限点播且是 M3U8）
      final isAdBlockEnabled = ref.read(adBlockEnabledProvider);
      final playUrl = (!widget.isLive && isAdBlockEnabled && isM3u8)
          ? ref.read(adBlockServiceProvider).getProxyUrl(widget.url, referer: widget.referer)
          : widget.url;

      // 3. 判定是否给播放器 HLS 格式提示
      bool useHlsHint = isM3u8;
      if (widget.isLive && !isM3u8) {
        final otherExtensions = ['.mp4', '.mov', '.mpd', '.mkv', '.webm'];
        if (!otherExtensions.any((ext) => widget.url.toLowerCase().contains(ext))) {
          useHlsHint = true; 
        }
      }

      final controller = VideoPlayerController.networkUrl(
        Uri.parse(playUrl),
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          if (widget.referer != null && widget.referer!.isNotEmpty) 'Referer': widget.referer!,
        },
        formatHint: useHlsHint ? VideoFormat.hls : null,
      );
      
      _videoController = controller;
      await controller.initialize();
      if (_isDisposed) return;

      // 如果有初始进度，计算跳转位置
      Duration? startAt;
      if (widget.initialPosition != null && widget.initialPosition! > 0) {
        final seconds = widget.initialPosition!.toInt();
        // 只有当进度小于总时长（或者总时长还未获取到）时才跳转
        if (controller.value.duration == Duration.zero || seconds < controller.value.duration.inSeconds) {
          startAt = Duration(seconds: seconds);
          debugPrint('🎬 播放器准备跳转至: ${seconds}s');
        }
      }

      // 设置音量
      final volume = ref.read(playerVolumeProvider);
      await controller.setVolume(volume);

      // 进度监听
      controller.addListener(_videoListener);

      _chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        startAt: startAt,
        aspectRatio: controller.value.aspectRatio,
        allowFullScreen: true,
        isLive: widget.isLive,
        customControls: ZenVideoControls(
          isAdBlockingEnabled: isAdBlockEnabled,
          onAdBlockingToggle: () {
            final currentEnabled = ref.read(adBlockEnabledProvider);
            ref.read(adBlockEnabledProvider.notifier).setEnabled(!currentEnabled);
          },
          skipConfig: widget.skipConfig ?? SkipConfig(),
          onSkipConfigChange: widget.onSkipConfigChange,
          initialVolume: volume,
          onVolumeChanged: (vol) {
            ref.read(playerVolumeProvider.notifier).setVolume(vol);
          },
          hasNextEpisode: widget.hasNextEpisode,
          onNextEpisode: widget.onNextEpisode,
        ),
        materialProgressColors: ChewieProgressColors(
          playedColor: widget.isLive ? Colors.white : const Color(0xFF0A84FF),
          handleColor: widget.isLive ? Colors.white : const Color(0xFF0A84FF),
          bufferedColor: Colors.white.withOpacity(0.3),
          backgroundColor: Colors.white.withOpacity(0.1),
        ),
      );
    } catch (e) {
      debugPrint('EchoVideoPlayer error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().contains('404') ? '资源不存在 (404)' : '无法加载视频，请检查网络或更换线路';
        });
      }
    } finally {
      if (!_isDisposed && mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _updateDanmaku(Duration position) {
    if (widget.danmaku.isEmpty || !mounted) return;
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
    _chewieController?.dispose();
    _danmakuTicker.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _videoController?.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 核心修正：监听去广告开关，变化时重新初始化播放器
    ref.listen(adBlockEnabledProvider, (previous, next) {
      if (previous != next) {
        _initializePlayer();
      }
    });

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
        child: CircularProgressIndicator(color: Colors.white),
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
    if (_activeDanmaku.isEmpty) return const SizedBox.shrink();
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
