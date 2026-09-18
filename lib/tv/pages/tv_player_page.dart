import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/comment.dart';
import '../../models/site.dart';
import '../../pages/login_page.dart';
import '../../providers/auth_provider.dart';
import '../../providers/history_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/app_api_service.dart';
import '../../services/cms_service.dart';
import '../../services/config_service.dart';
import '../../widgets/video_player.dart';
import '../tv_focus.dart';
import '../tv_theme.dart';

/// TV 端全屏播放页。
///
/// 遥控器操作交给 [EchoVideoPlayer] 内置的按键处理：左右切进度、上下切音量、
/// 空格播放/暂停；返回键退出本页。
class TvPlayerPage extends ConsumerStatefulWidget {
  const TvPlayerPage({
    super.key,
    required this.video,
    required this.group,
    required this.initialIndex,
    this.resumePosition,
  });

  final VideoDetail video;
  final PlayGroup group;
  final int initialIndex;
  final double? resumePosition;

  @override
  ConsumerState<TvPlayerPage> createState() => _TvPlayerPageState();
}

class _TvPlayerPageState extends ConsumerState<TvPlayerPage> {
  final Map<int, String> _urlCache = {};
  final GlobalKey<EchoVideoPlayerState> _playerKey =
      GlobalKey<EchoVideoPlayerState>();
  List<DanmakuItem> _danmaku = const [];
  String _danmakuEpisodeKey = '';
  bool _danmakuEnabled = true;
  late int _index;
  String? _resolvedUrl;
  String _referer = '';
  String? _accessMessage;
  String? _errorMessage;
  double? _resumePosition;
  int _lastSavedSecond = -1;

  int get _episodeCount {
    final titles = widget.group.titles.length;
    return titles > 0 ? titles : widget.group.urls.length;
  }

  String get _episodeTitle {
    final titles = widget.group.titles;
    if (_index >= 0 && _index < titles.length && titles[_index].isNotEmpty) {
      return titles[_index];
    }
    return '第 ${_index + 1} 集';
  }

  @override
  void initState() {
    super.initState();
    final total = _episodeCount;
    _index = total <= 0 ? 0 : widget.initialIndex.clamp(0, total - 1);
    _resumePosition = widget.resumePosition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolve();
      _loadDanmaku();
    });
  }

  Future<void> _loadDanmaku({bool force = false}) async {
    final key = '${widget.video.id}-$_index';
    if (!force && key == _danmakuEpisodeKey) return;
    _danmakuEpisodeKey = key;
    try {
      final items = await ref
          .read(cmsServiceProvider)
          .getDanmaku(widget.video.id, episode: _index);
      if (!mounted) return;
      setState(() => _danmaku = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _danmaku = const []);
    }
  }

  void _toggleDanmaku() {
    setState(() => _danmakuEnabled = !_danmakuEnabled);
  }

  /// 弹出独立输入框写弹幕；未登录先去登录。
  ///
  /// TV 端不用播放器内嵌输入条：那条输入条依赖播放器控件的键盘焦点，
  /// 遥控器与系统输入法会互相抢焦点，输入条反复显隐，看起来就是「功能条
  /// 一直闪」。这里用独立对话框收敛焦点，输入完直接提交。
  Future<void> _openDanmakuInput() async {
    if (widget.video.id.isEmpty) return;
    final token = await ref.read(configServiceProvider).getAuthToken();
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const LoginPage()));
      return;
    }
    final text = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => const _DanmakuInputDialog(),
    );
    if (text == null || !mounted) return;
    await _submitDanmaku(text);
  }

  Future<void> _submitDanmaku(String text) async {
    final content = text.trim();
    if (content.isEmpty) return;
    final position = _playerKey.currentState?.currentPosition ?? Duration.zero;
    try {
      final result = await ref
          .read(cmsServiceProvider)
          .postDanmaku(
            widget.video.id,
            episode: _index,
            timeMs: position.inMilliseconds,
            content: content,
          );
      if (!mounted) return;
      if (result.ok && !result.pending) {
        setState(() {
          _danmakuEnabled = true;
          _danmaku = [
            ..._danmaku,
            DanmakuItem(timeMs: position.inMilliseconds, content: content),
          ]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
        });
      }
      final msg = !result.ok
          ? '弹幕发送失败'
          : (result.pending ? '弹幕已提交，等待审核' : '弹幕已发送');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('弹幕发送失败')));
    }
  }

  Future<void> _resolve({bool forceRefresh = false}) async {
    final video = widget.video;
    if (video.id.isEmpty || _episodeCount <= 0) {
      setState(() => _errorMessage = '暂无可播放的线路');
      return;
    }
    if (forceRefresh) _urlCache.remove(_index);
    final cached = _urlCache[_index];
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _resolvedUrl = cached;
        _referer = '';
        _accessMessage = null;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _resolvedUrl = null;
      _accessMessage = null;
      _errorMessage = null;
    });

    final config = ref.read(configServiceProvider);
    final api = ref.read(appApiServiceProvider);
    final base = await config.getApiBaseUrl();
    final token = await config.getAuthToken();
    final sourceIndex = video.playGroups.indexOf(widget.group);

    try {
      var result = await api.play(
        base,
        videoId: video.id,
        playSource: sourceIndex < 0 ? 0 : sourceIndex,
        playIndex: _index,
        token: token,
        refresh: forceRefresh,
      );

      // TV 端不做 WebView 嗅探：命中嗅探线路时直接回传失败，
      // 让服务端冷却该线路并自动换下一条。
      var guard = 0;
      while (mounted && result.isWebSniff && guard < 4) {
        guard++;
        result = await api.play(
          base,
          videoId: video.id,
          playSource: sourceIndex < 0 ? 0 : sourceIndex,
          playIndex: _index,
          token: token,
          reportSourceIndex: result.sourceIndex ?? 0,
          reportOutcome: 'fail',
        );
      }

      if (!mounted) return;
      if (result.hasAccess &&
          result.playUrl != null &&
          result.playUrl!.isNotEmpty) {
        _urlCache[_index] = result.playUrl!;
        setState(() {
          _resolvedUrl = result.playUrl;
          _referer = '';
        });
      } else if (!result.hasAccess) {
        setState(() {
          _accessMessage = result.message.isEmpty
              ? '该内容需要会员权限'
              : result.message;
        });
      } else if (!forceRefresh) {
        await _resolve(forceRefresh: true);
      } else {
        setState(() {
          _errorMessage = result.message.isEmpty ? '解析失败，请重试' : result.message;
        });
      }
    } catch (_) {
      if (!mounted) return;
      if (!forceRefresh) {
        await _resolve(forceRefresh: true);
        return;
      }
      setState(() => _errorMessage = '取流失败，请检查网络后重试');
    }
  }

  void _switchEpisode(int index) {
    final total = _episodeCount;
    if (total <= 0) return;
    final safe = index.clamp(0, total - 1);
    if (safe == _index && _resolvedUrl != null) return;
    setState(() {
      _index = safe;
      _resumePosition = null;
    });
    _resolve();
    _loadDanmaku();
  }

  void _saveProgress(
    Duration position,
    Duration duration, {
    bool isFinal = false,
  }) {
    final total = duration.inSeconds;
    if (total <= 0) return;
    if (!isFinal && position.inSeconds - _lastSavedSecond < 15) return;
    _lastSavedSecond = position.inSeconds;
    final video = widget.video;
    ref
        .read(historyProvider.notifier)
        .saveRecord(
          PlayRecord(
            title: video.title,
            sourceName: video.sourceName,
            cover: video.poster,
            year: video.year ?? '',
            index: _index,
            totalEpisodes: _episodeCount,
            playTime: position.inSeconds,
            totalTime: total,
            saveTime: DateTime.now().millisecondsSinceEpoch,
            searchTitle: video.title,
            doubanId: video.id.isEmpty ? null : video.id,
          ),
        );
  }

  void _handlePlaybackError(String message) {
    if (!mounted) return;
    _urlCache.remove(_index);
    setState(() => _errorMessage = message.isEmpty ? '播放失败' : message);
  }

  @override
  Widget build(BuildContext context) {
    final isVip = ref.watch(authProvider).user?.isVip ?? false;
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        // 键盘弹出时不压缩播放器区域，避免画面跳动，弹幕输入框浮在画面上层。
        resizeToAvoidBottomInset: false,
        body: _buildBody(isVip),
      ),
    );
  }

  Widget _buildBody(bool isVip) {
    if (_accessMessage != null) {
      return _buildNotice(
        icon: '该内容需要会员权限',
        message: _accessMessage!,
        retry: false,
      );
    }
    if (_errorMessage != null) {
      return _buildNotice(icon: '播放失败', message: _errorMessage!, retry: true);
    }
    final url = _resolvedUrl;
    if (url == null) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.accent),
      );
    }

    return _TvControlsLayer(
      playerKey: _playerKey,
      title: widget.video.title,
      subtitle: _episodeTitle,
      episodeTitles: widget.group.titles,
      index: _index,
      episodeCount: _episodeCount,
      danmakuEnabled: _danmakuEnabled,
      onToggleDanmaku: _toggleDanmaku,
      onOpenDanmaku: _openDanmakuInput,
      onSelectEpisode: _switchEpisode,
      onExit: () => Navigator.of(context).maybePop(),
      child: EchoVideoPlayer(
        key: _playerKey,
        url: url,
        title: '${widget.video.title} - $_episodeTitle',
        referer: _referer,
        isLive: false,
        initialPosition: _resumePosition,
        episodeTitles: widget.group.titles,
        episodeNeedVip: widget.group.needVip,
        isVip: isVip,
        currentEpisodeIndex: _index,
        danmaku: _danmaku,
        danmakuEnabled: _danmakuEnabled,
        onDanmakuToggle: _toggleDanmaku,
        onDanmakuInputActivate: _openDanmakuInput,
        onSelectEpisode: (index, _) => _switchEpisode(index),
        onPlaybackError: _handlePlaybackError,
        onProgress: _saveProgress,
        hasNextEpisode: _index < _episodeCount - 1,
        onNextEpisode: () => _switchEpisode(_index + 1),
        onEnded: () => _switchEpisode(_index + 1),
        showBuiltInControls: false,
      ),
    );
  }

  Widget _buildNotice({
    required String icon,
    required String message,
    required bool retry,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            icon,
            style: const TextStyle(
              fontSize: TvMetrics.sectionTitle,
              fontWeight: FontWeight.w700,
              color: TvColors.text1,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: TvMetrics.body,
              color: TvColors.text2,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TvActionButton(
                label: '返回',
                icon: Icons.arrow_back,
                autofocus: !retry,
                onSelect: () => Navigator.of(context).maybePop(),
              ),
              if (retry) ...[
                const SizedBox(width: 16),
                TvActionButton(
                  label: '重试',
                  icon: Icons.refresh,
                  primary: true,
                  autofocus: true,
                  onSelect: () {
                    _urlCache.remove(_index);
                    _resolve(forceRefresh: true);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// TV 播放器控制条上的按钮。
enum _Ctl {
  play,
  back15,
  fwd15,
  prev,
  next,
  episodes,
  danmaku,
  sendDanmaku,
  exit,
}

/// TV 播放器自绘遥控器控制层。
///
/// 播放器内置的触摸控制条会 3 秒自动隐藏、又依赖播放器控件的键盘焦点，
/// 遥控器上表现为「功能条闪一下就没」。这里改成面向遥控器的一套：
/// - 焦点由本层独占，方向键在控制条按钮间移动光标，不触发系统焦点遍历；
/// - 控制条显示后 7 秒无操作才隐藏，任何按键都会重新计时；
/// - 控制条隐藏时：左右快进退、上下调音量、确认键唤出控制条；
/// - 控制条显示时：左右移动光标、确认键触发，选集用独立面板（面板内恢复系统焦点遍历）。
class _TvControlsLayer extends ConsumerStatefulWidget {
  const _TvControlsLayer({
    required this.playerKey,
    required this.title,
    required this.subtitle,
    required this.episodeTitles,
    required this.index,
    required this.episodeCount,
    required this.danmakuEnabled,
    required this.onToggleDanmaku,
    required this.onOpenDanmaku,
    required this.onSelectEpisode,
    required this.onExit,
    required this.child,
  });

  final GlobalKey<EchoVideoPlayerState> playerKey;
  final String title;
  final String subtitle;
  final List<String> episodeTitles;
  final int index;
  final int episodeCount;
  final bool danmakuEnabled;
  final VoidCallback onToggleDanmaku;
  final Future<void> Function() onOpenDanmaku;
  final void Function(int index) onSelectEpisode;
  final VoidCallback onExit;
  final Widget child;

  @override
  ConsumerState<_TvControlsLayer> createState() => _TvControlsLayerState();
}

class _TvControlsLayerState extends ConsumerState<_TvControlsLayer> {
  static const Duration _hideDelay = Duration(seconds: 7);
  static const int _seekStep = 15;

  final FocusNode _rootFocus = FocusNode(debugLabel: 'tv-player-root');
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  Timer? _hideTimer;
  Timer? _ticker;
  Timer? _hintTimer;

  bool _barVisible = true;
  int _cursor = 0;
  bool _episodePanel = false;
  String? _hintText;
  IconData _hintIcon = LucideIcons.play;
  String _hintKind = '';

  @override
  void initState() {
    super.initState();
    // 每 0.5 秒刷新一次进度 / 播放状态，供控制层读取。
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _tick.value++;
    });
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ticker?.cancel();
    _hintTimer?.cancel();
    _tick.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  EchoVideoPlayerState? get _player => widget.playerKey.currentState;

  List<_Ctl> get _items => <_Ctl>[
    _Ctl.play,
    _Ctl.back15,
    _Ctl.fwd15,
    if (widget.index > 0) _Ctl.prev,
    if (widget.index < widget.episodeCount - 1) _Ctl.next,
    _Ctl.episodes,
    _Ctl.danmaku,
    _Ctl.sendDanmaku,
    _Ctl.exit,
  ];

  int get _safeCursor {
    final list = _items;
    if (list.isEmpty) return 0;
    return _cursor.clamp(0, list.length - 1);
  }

  bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.space;

  bool _isMenu(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.contextMenu ||
      key == LogicalKeyboardKey.info ||
      key == LogicalKeyboardKey.escape;

  void _showBar({int? cursor}) {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _barVisible = true;
      if (cursor != null) _cursor = cursor;
    });
    _restartHideTimer();
    if (!_episodePanel) _rootFocus.requestFocus();
  }

  void _hideBar() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _barVisible = false;
      _episodePanel = false;
    });
    _rootFocus.requestFocus();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted || _episodePanel) return;
      _hideBar();
    });
  }

  void _showHint(String text, IconData icon, {String kind = ''}) {
    _hintTimer?.cancel();
    setState(() {
      _hintText = text;
      _hintIcon = icon;
      _hintKind = kind;
    });
    _hintTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _hintText = null;
        _hintKind = '';
      });
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // 选集面板打开时把方向键交回系统焦点遍历，面板内只处理关闭。
    if (_episodePanel) {
      if (key == LogicalKeyboardKey.escape) {
        _closeEpisodePanel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (!_barVisible) {
      if (key == LogicalKeyboardKey.mediaPlayPause) {
        _togglePlay();
      } else if (_isSelect(key)) {
        _showBar(cursor: _items.indexOf(_Ctl.play));
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        _seek(-_seekStep);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _seek(_seekStep);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        _changeVolume(0.1);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _changeVolume(-0.1);
      } else if (_isMenu(key)) {
        _showBar();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveCursor(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _moveCursor(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _changeVolume(0.1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _changeVolume(-0.1);
    } else if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
    } else if (_isSelect(key)) {
      _activate(_items[_safeCursor]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _moveCursor(int delta) {
    final list = _items;
    if (list.isEmpty) return;
    final next = (_safeCursor + delta) % list.length;
    setState(() => _cursor = next < 0 ? next + list.length : next);
    _restartHideTimer();
  }

  void _seek(int seconds) {
    final player = _player;
    if (player == null) return;
    var target = player.currentPosition + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final total = player.duration;
    if (total > Duration.zero && target > total) target = total;
    player.seekToPosition(target);
    _showHint(
      seconds >= 0 ? '快进 ${seconds}s' : '快退 ${-seconds}s',
      seconds >= 0 ? LucideIcons.fastForward : LucideIcons.rewind,
      kind: 'seek',
    );
    if (_barVisible) _restartHideTimer();
  }

  void _changeVolume(double delta) {
    final player = _player;
    final current = player?.volume ?? ref.read(playerVolumeProvider);
    final next = (current + delta).clamp(0.0, 1.0).toDouble();
    player?.setVolume(next);
    unawaited(ref.read(playerVolumeProvider.notifier).setVolume(next));
    _showHint(
      '音量 ${(next * 100).round()}%',
      next == 0
          ? LucideIcons.volumeX
          : (next < 0.5 ? LucideIcons.volume1 : LucideIcons.volume2),
      kind: 'volume',
    );
    if (_barVisible) _restartHideTimer();
  }

  void _togglePlay() {
    final player = _player;
    if (player == null) return;
    if (player.isPlaying) {
      player.pausePlayback();
      _showHint('已暂停', LucideIcons.pause);
    } else {
      player.resumePlayback();
      _showHint('播放中', LucideIcons.play);
    }
  }

  void _activate(_Ctl ctl) {
    switch (ctl) {
      case _Ctl.play:
        _togglePlay();
        break;
      case _Ctl.back15:
        _seek(-_seekStep);
        break;
      case _Ctl.fwd15:
        _seek(_seekStep);
        break;
      case _Ctl.prev:
        widget.onSelectEpisode(widget.index - 1);
        break;
      case _Ctl.next:
        widget.onSelectEpisode(widget.index + 1);
        break;
      case _Ctl.episodes:
        _openEpisodePanel();
        return;
      case _Ctl.danmaku:
        widget.onToggleDanmaku();
        _showHint(
          widget.danmakuEnabled ? '弹幕已关闭' : '弹幕已开启',
          widget.danmakuEnabled
              ? LucideIcons.messageSquareOff
              : LucideIcons.messageSquare,
        );
        break;
      case _Ctl.sendDanmaku:
        unawaited(widget.onOpenDanmaku());
        break;
      case _Ctl.exit:
        widget.onExit();
        return;
    }
    _restartHideTimer();
  }

  void _openEpisodePanel() {
    if (widget.episodeTitles.isEmpty) return;
    _hideTimer?.cancel();
    setState(() => _episodePanel = true);
  }

  void _closeEpisodePanel() {
    if (!mounted) return;
    setState(() => _episodePanel = false);
    _showBar();
  }

  void _handleSurfaceTap() {
    if (_episodePanel) return;
    if (_barVisible) {
      _hideBar();
    } else {
      _showBar();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final cursor = _safeCursor;
    return PopScope(
      canPop: !_episodePanel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _episodePanel) _closeEpisodePanel();
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        canRequestFocus: true,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleSurfaceTap,
              ),
            ),
            if (_hintText != null) _buildHint(),
            if (_barVisible) _buildBar(items, cursor),
            if (_episodePanel) _buildEpisodePanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildHint() {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 22),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_hintIcon, color: Colors.white, size: 40),
              const SizedBox(height: 12),
              Text(
                _hintText!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: TvMetrics.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_hintKind == 'seek' || _hintKind == 'volume') ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: 260,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _tick,
                    builder: (_, __, ___) => _buildTrack(
                      _hintKind == 'volume'
                          ? (_player?.volume ?? 0)
                          : _progressFraction(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBar(List<_Ctl> items, int cursor) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.28, 0.6, 1.0],
                colors: [
                  Color(0xCC000000),
                  Color(0x00000000),
                  Color(0x33000000),
                  Color(0xE6000000),
                ],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: TvMetrics.safePadding.add(const EdgeInsets.only(top: 16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: TvMetrics.sectionTitle,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (widget.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: TvMetrics.body,
                      color: TvColors.text2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: TvMetrics.safePadding.add(
              const EdgeInsets.only(bottom: 18),
            ),
            child: ValueListenableBuilder<int>(
              valueListenable: _tick,
              builder: (_, __, ___) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildProgress(),
                  const SizedBox(height: 18),
                  _buildButtons(items, cursor),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final position = _player?.currentPosition ?? Duration.zero;
    final total = _player?.duration ?? Duration.zero;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: total.inMilliseconds <= 0
                  ? 0
                  : (position.inMilliseconds / total.inMilliseconds).clamp(
                      0.0,
                      1.0,
                    ),
              minHeight: 5,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(TvColors.accent),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(_formatDuration(position), style: _timeStyle),
            const Spacer(),
            Text(_formatDuration(total), style: _timeStyle),
          ],
        ),
      ],
    );
  }

  Widget _buildButtons(List<_Ctl> items, int cursor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < items.length; i++)
          _buildButton(items[i], i == cursor),
      ],
    );
  }

  Widget _buildButton(_Ctl ctl, bool focused) {
    return GestureDetector(
      onTap: () {
        setState(() => _cursor = _items.indexOf(ctl));
        _activate(ctl);
      },
      child: AnimatedContainer(
        duration: TvMetrics.focusDuration,
        curve: Curves.easeOut,
        width: 66,
        height: 66,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: focused
              ? TvColors.accent
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: 2,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: TvColors.accent.withValues(alpha: 0.5),
                    blurRadius: 20,
                  ),
                ]
              : null,
        ),
        child: Icon(
          _iconOf(ctl),
          size: 30,
          color: focused ? Colors.white : TvColors.text1,
        ),
      ),
    );
  }

  IconData _iconOf(_Ctl ctl) {
    switch (ctl) {
      case _Ctl.play:
        return (_player?.isPlaying ?? false)
            ? LucideIcons.pause
            : LucideIcons.play;
      case _Ctl.back15:
        return LucideIcons.rewind;
      case _Ctl.fwd15:
        return LucideIcons.fastForward;
      case _Ctl.prev:
        return LucideIcons.skipBack;
      case _Ctl.next:
        return LucideIcons.skipForward;
      case _Ctl.episodes:
        return LucideIcons.listVideo;
      case _Ctl.danmaku:
        return widget.danmakuEnabled
            ? LucideIcons.messageSquare
            : LucideIcons.messageSquareOff;
      case _Ctl.sendDanmaku:
        return LucideIcons.send;
      case _Ctl.exit:
        return LucideIcons.logOut;
    }
  }

  Widget _buildEpisodePanel() {
    final titles = widget.episodeTitles;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 980,
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: TvColors.surface,
            borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
            border: Border.all(color: TvColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '选集',
                    style: TextStyle(
                      fontSize: TvMetrics.sectionTitle,
                      fontWeight: FontWeight.w700,
                      color: TvColors.text1,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '共 ${titles.length} 集',
                    style: const TextStyle(
                      fontSize: TvMetrics.body,
                      color: TvColors.text3,
                    ),
                  ),
                  const Spacer(),
                  TvActionButton(
                    label: '关闭',
                    icon: LucideIcons.x,
                    onSelect: _closeEpisodePanel,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Flexible(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 132).floor().clamp(
                      4,
                      10,
                    );
                    return GridView.builder(
                      shrinkWrap: true,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 56,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: titles.length,
                      itemBuilder: (context, i) {
                        final title = titles[i].isNotEmpty
                            ? titles[i]
                            : '第 ${i + 1} 集';
                        return TvChip(
                          label: title,
                          selected: i == widget.index,
                          autofocus: i == widget.index,
                          onSelect: () {
                            _closeEpisodePanel();
                            widget.onSelectEpisode(i);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _progressFraction() {
    final player = _player;
    if (player == null) return 0;
    final total = player.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (player.currentPosition.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Widget _buildTrack(double value) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: 6,
        backgroundColor: Colors.white24,
        valueColor: const AlwaysStoppedAnimation<Color>(TvColors.accent),
      ),
    );
  }

  static const TextStyle _timeStyle = TextStyle(
    fontSize: 14,
    color: TvColors.text2,
  );

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

/// TV 端的弹幕输入对话框：系统输入法直接浮在画面上，不干扰播放器控件。
class _DanmakuInputDialog extends StatefulWidget {
  const _DanmakuInputDialog();

  @override
  State<_DanmakuInputDialog> createState() => _DanmakuInputDialogState();
}

class _DanmakuInputDialogState extends State<_DanmakuInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TvColors.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
      ),
      title: const Text(
        '发送弹幕',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: TvColors.text1,
        ),
      ),
      content: SizedBox(
        width: 560,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 50,
          maxLines: 2,
          minLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          cursorColor: TvColors.accent,
          style: const TextStyle(fontSize: 18, color: TvColors.text1),
          decoration: const InputDecoration(
            hintText: '发个友善的弹幕见证当下',
            hintStyle: TextStyle(fontSize: 18, color: TvColors.text3),
            counterStyle: TextStyle(fontSize: 14, color: TvColors.text3),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: TvColors.accent, width: 2),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: TvColors.divider),
            ),
          ),
        ),
      ),
      actions: [
        TvActionButton(
          label: '取消',
          icon: LucideIcons.x,
          onSelect: () => Navigator.of(context).pop(),
        ),
        TvActionButton(
          label: '发送',
          icon: LucideIcons.send,
          primary: true,
          onSelect: _submit,
        ),
      ],
    );
  }
}
