import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/site.dart';
import '../../providers/auth_provider.dart';
import '../../providers/history_provider.dart';
import '../../services/app_api_service.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
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
      child: Scaffold(backgroundColor: Colors.black, body: _buildBody(isVip)),
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

    return EchoVideoPlayer(
      url: url,
      title: '${widget.video.title} - $_episodeTitle',
      referer: _referer,
      isLive: false,
      initialPosition: _resumePosition,
      episodeTitles: widget.group.titles,
      episodeNeedVip: widget.group.needVip,
      isVip: isVip,
      currentEpisodeIndex: _index,
      onSelectEpisode: (index, _) => _switchEpisode(index),
      onPlaybackError: _handlePlaybackError,
      onProgress: _saveProgress,
      hasNextEpisode: _index < _episodeCount - 1,
      onNextEpisode: () => _switchEpisode(_index + 1),
      onEnded: () => _switchEpisode(_index + 1),
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
