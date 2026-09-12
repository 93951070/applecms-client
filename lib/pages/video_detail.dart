import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/movie.dart';
import '../models/comment.dart';
import '../models/site.dart';
import '../models/watch_party.dart';
import '../services/app_api_service.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/auth_provider.dart';
import '../services/download_service.dart';
import '../core/theme.dart';
import '../core/navigation.dart';
import '../core/share_utils.dart';
import '../core/video_router.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/video_player.dart';
import '../widgets/bili_loading.dart';
import '../widgets/watch_party_sheet.dart';

/// 播放页「同类推荐」数据源：按当前视频所属分类拉取同分类内容。
final _recommendProvider =
    FutureProvider.family<List<VideoDetail>, int>((ref, typeId) async {
  if (typeId <= 0) return [];
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryList(site, typeId, page: 1, pageSize: 18);
});

class VideoDetailPage extends ConsumerStatefulWidget {
  final DoubanSubject subject;

  const VideoDetailPage({super.key, required this.subject});

  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> with WidgetsBindingObserver, RouteAware {
  late HistoryNotifier _historyNotifier;

  bool _descExpanded = false;
  int _contentTab = 0;

  String _doubanId = '';

  // 核心数据：单站点按 id 直取一条详情即可，无需多源聚合
  VideoDetail? _video;
  int _currentEpisodeIndex = 0;
  double? _initialResumePosition;
  bool _autoPlayNext = true;

  /// 从一起看回到本页时置位：同步进度并保持暂停，直到用户真正开始播放。
  bool _resumePaused = false;
  SkipConfig _skipConfig = SkipConfig();

  // 状态跟踪
  String _loadingMessage = '';
  bool _isSearching = true;
  bool _descending = false;

  // App 网关取流
  String? _resolvedUrl;
  bool _resolvingPlay = false;
  String? _accessMessage;
  String? _errorMessage;

  // 评论与弹幕
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  final TextEditingController _danmakuController = TextEditingController();
  final FocusNode _danmakuFocus = FocusNode();
  bool _danmakuInputActive = false;
  final List<VideoComment> _comments = [];
  int _commentTotal = 0;
  int _commentPage = 1;
  bool _commentsLoading = false;
  bool _commentsLoaded = false;
  List<DanmakuItem> _danmaku = const [];
  String _danmakuEpisodeKey = '';
  bool _danmakuEnabled = true;

  /// 播放器内切集时，若当时处于全屏则在新一集加载完成后自动回到全屏。
  bool _restoreFullScreen = false;

  final GlobalKey<EchoVideoPlayerState> _playerKey = GlobalKey<EchoVideoPlayerState>();

  /// 详情后台静默刷新的订阅，用于同步最新选集会员状态。
  StreamSubscription<String>? _detailSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doubanId = widget.subject.id;
    _detailSub =
        ref.read(cmsServiceProvider).detailUpdates.listen(_onDetailUpdated);
    _checkHistoryAndLoadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _historyNotifier = ref.read(historyProvider.notifier);
    final route = ModalRoute.of<void>(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  // 跳转到其它视频/页面时，暂停当前播放，避免旧视频在后台继续出声。
  @override
  void didPushNext() {
    _playerKey.currentState?.pausePlayback();
    _commentFocus.unfocus();
    _danmakuFocus.unfocus();
  }

  void _checkHistoryAndLoadData() async {
    // 1. 尝试从历史记录中恢复状态（优先按 vod_id 匹配，其次按标题）
    final history = ref.read(historyProvider).value ?? [];
    final record = history.firstWhere(
      (r) =>
          (widget.subject.id.isNotEmpty && r.doubanId == widget.subject.id) ||
          r.searchTitle == widget.subject.title,
      orElse: () => PlayRecord(
        title: '',
        sourceName: '',
        cover: '',
        year: '',
        index: 0,
        totalEpisodes: 0,
        playTime: 0,
        totalTime: 0,
        saveTime: 0,
        searchTitle: '',
      ),
    );

    if (record.title.isNotEmpty) {
      debugPrint('找到历史记录：第 ${record.index} 集，进度 ${record.playTime}s');
      setState(() {
        _currentEpisodeIndex = record.index;
        _initialResumePosition = record.playTime.toDouble();
      });
    }

    // 2. 正常加载数据
    _loadData();
  }

  bool _didStartPlayback = false;
  final Map<String, String> _episodeUrlCache = {};
  final Set<String> _prefetchingKeys = {};

  Future<void> _loadData() async {
    final cmsService = ref.read(cmsServiceProvider);
    final id = widget.subject.id.trim();

    if (id.isEmpty) {
      setState(() {
        _isSearching = false;
        _loadingMessage = '视频信息缺失';
      });
      return;
    }

    // 单后端架构：只有唯一数据源，直接用缓存秒开，空闲时再静默刷新。
    // 命中缓存时立刻渲染简介与选集，避免「暂无简介」「正在加载播放源」。
    final cached = cmsService.cachedDetail(id);
    if (cached != null) {
      _applyDetail(cached, startPlayback: !_didStartPlayback);
    } else {
      setState(() {
        _isSearching = true;
        _loadingMessage = '';
      });
    }

    final site = await ref.read(configServiceProvider).getPrimarySite();
    if (!mounted) return;

    final detail = await cmsService.getDetail(site, id);
    if (!mounted) return;

    if (detail == null) {
      if (_video == null) {
        setState(() {
          _isSearching = false;
          _loadingMessage = '加载失败，请检查网络后重试';
        });
      }
      return;
    }
    _applyDetail(detail, startPlayback: !_didStartPlayback);
  }

  /// 应用详情数据。仅在尚未开始播放时启动取流，避免刷新时打断播放。
  void _applyDetail(VideoDetail detail, {required bool startPlayback}) {
    setState(() {
      _video = detail;
      if (detail.id.isNotEmpty) _doubanId = detail.id;
      _isSearching = false;
      _loadingMessage = '';
    });

    if (!startPlayback) return;
    _didStartPlayback = true;
    final total = detail.playGroups.first.urls.length;
    final index = total <= 0 ? 0 : _currentEpisodeIndex.clamp(0, total - 1);
    _currentEpisodeIndex = index;
    _loadSkipConfig();
    _loadComments();
    _handlePlayAction(index, resumePosition: _initialResumePosition);
  }

  /// 后台刷新拿到最新详情后，仅更新数据与选集锁，不打断正在进行的播放。
  void _onDetailUpdated(String id) {
    if (!mounted || id != widget.subject.id.trim()) return;
    final latest = ref.read(cmsServiceProvider).cachedDetail(id);
    if (latest == null || latest.playGroups.isEmpty) return;
    _applyDetail(latest, startPlayback: false);
  }

  void _handlePlayAction(int index, {double? resumePosition}) {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final total = video.playGroups.first.urls.length;
    final safeIndex = total <= 0 ? 0 : index.clamp(0, total - 1);
    final isEpisodeChange = safeIndex != _currentEpisodeIndex;
    setState(() {
      if (resumePosition != null) {
        _initialResumePosition = resumePosition;
      } else if (isEpisodeChange) {
        // 切换集数时不要沿用上一集的续播进度，从新一集开头播放。
        _initialResumePosition = null;
      }
      _currentEpisodeIndex = safeIndex;
      _resolvedUrl = null;
      _accessMessage = null;
      _errorMessage = null;
    });
    _resolveCurrentEpisode();
    _loadDanmaku();
  }

  /// 通过 App 网关做会员校验并解析直连地址。
  ///
  /// 直连地址只由服务端按次下发；网关不可用或校验不通过时不会回退到
  /// 客户端侧地址，避免绕过会员校验。
  Future<void> _resolveCurrentEpisode() async {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final group = video.playGroups.first;
    if (_currentEpisodeIndex >= group.urls.length) return;

    // 命中预取缓存：切集/重进无需再次等待网关解析。
    final cacheKey = '${video.id}:$_currentEpisodeIndex';
    final prefetched = _episodeUrlCache[cacheKey];
    if (prefetched != null && prefetched.isNotEmpty) {
      setState(() {
        _resolvedUrl = prefetched;
        _resolvingPlay = false;
        _accessMessage = null;
        _errorMessage = null;
      });
      _prefetchEpisodes();
      return;
    }

    setState(() {
      _resolvingPlay = true;
      _accessMessage = null;
      _errorMessage = null;
    });

    final config = ref.read(configServiceProvider);
    final api = ref.read(appApiServiceProvider);
    final base = await config.getApiBaseUrl();
    final token = await config.getAuthToken();
    final playSource = video.playGroups.indexOf(group);

    try {
      final result = await api.play(
        base,
        videoId: video.id,
        playSource: playSource < 0 ? 0 : playSource,
        playIndex: _currentEpisodeIndex,
        token: token,
      );
      if (!mounted) return;

      if (result.hasAccess &&
          result.playUrl != null &&
          result.playUrl!.isNotEmpty) {
        _episodeUrlCache[cacheKey] = result.playUrl!;
        setState(() {
          _resolvedUrl = result.playUrl;
          _resolvingPlay = false;
        });
        _prefetchEpisodes();
      } else if (!result.hasAccess) {
        setState(() {
          _accessMessage =
              result.message.isEmpty ? '该内容需要会员权限' : result.message;
          _resolvingPlay = false;
        });
      } else {
        setState(() {
          _errorMessage =
              result.message.isEmpty ? '解析失败，请重试' : result.message;
          _resolvingPlay = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('App 网关取流失败: $e');
      setState(() {
        _errorMessage = '取流失败，请检查网络后重试';
        _resolvingPlay = false;
      });
    }
  }

  /// 并行预取当前集之后最多 3 集的播放地址，减少切集时的缓冲等待。
  ///
  /// 串行逐个请求会让第 2、3 集依次等一个 RTT，切集明显变慢；这里改为
  /// 并发发起并对同一集做去重，最近一集能最快就绪。
  Future<void> _prefetchEpisodes() async {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final group = video.playGroups.first;
    final total = group.urls.length;
    final start = _currentEpisodeIndex + 1;
    final end = (start + 3) > total ? total : (start + 3);
    if (start >= end) return;

    final config = ref.read(configServiceProvider);
    final api = ref.read(appApiServiceProvider);
    final base = await config.getApiBaseUrl();
    final token = await config.getAuthToken();
    final playSource = video.playGroups.indexOf(group);
    final sourceIndex = playSource < 0 ? 0 : playSource;

    final pending = <Future<void>>[];
    for (var i = start; i < end; i++) {
      final key = '${video.id}:$i';
      if (_episodeUrlCache.containsKey(key)) continue;
      if (!_prefetchingKeys.add(key)) continue;
      pending.add(_prefetchEpisode(api, base, video.id, sourceIndex, i, key, token));
    }
    if (pending.isEmpty) return;
    await Future.wait(pending);
  }

  Future<void> _prefetchEpisode(
    AppApiService api,
    String base,
    String videoId,
    int playSource,
    int index,
    String key,
    String? token,
  ) async {
    try {
      final result = await api.play(
        base,
        videoId: videoId,
        playSource: playSource,
        playIndex: index,
        token: token,
      );
      if (result.hasAccess &&
          result.playUrl != null &&
          result.playUrl!.isNotEmpty) {
        _episodeUrlCache[key] = result.playUrl!;
      }
    } catch (e) {
      debugPrint('预取第 $index 集失败: $e');
    } finally {
      _prefetchingKeys.remove(key);
    }
  }

  Future<void> _loadSkipConfig() async {
    final video = _video;
    if (video == null) return;
    final key = '${video.source}-${video.id}';
    final config = await ref.read(configServiceProvider).getSkipConfigs();
    if (mounted && config.containsKey(key)) {
      setState(() {
        _skipConfig = config[key]!;
      });
    }
  }

  void _playNextEpisode() {
    final video = _video;
    if (video == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex < video.playGroups.first.urls.length) {
      _handlePlayAction(nextIndex);
    }
  }

  Future<void> _savePlayRecord(Duration position, Duration duration, {bool isFinal = false}) async {
    final video = _video;
    if (video == null || !mounted) return;

    // 播放真正开始后解除「同步后保持暂停」，避免影响后续手动切集。
    _resumePaused = false;

    // 只有在进度有实际变化（大于0）或者为了保存最后进度时才记录
    if (position.inSeconds == 0 && duration.inSeconds == 0) return;

    // 如果不是强制保存（isFinal），则每 10 秒保存一次
    if (!isFinal && position.inSeconds % 10 != 0) return;

    final record = PlayRecord(
      title: widget.subject.title,
      sourceName: video.sourceName,
      cover: widget.subject.cover,
      year: widget.subject.year ?? '',
      index: _currentEpisodeIndex,
      totalEpisodes: video.playGroups.first.urls.length,
      playTime: position.inSeconds,
      totalTime: duration.inSeconds > 0 ? duration.inSeconds : (_initialResumePosition?.toInt() ?? 0),
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: widget.subject.title,
      doubanId: _doubanId,
    );
    try {
      Future.microtask(() {
        _historyNotifier.saveRecord(record);
      });
    } catch (e) {
      debugPrint('保存历史记录失败: $e');
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _detailSub?.cancel();
    _commentController.dispose();
    _commentFocus.dispose();
    _danmakuController.dispose();
    _danmakuFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 这里的进度保存由 EchoVideoPlayer 的 onProgress 持续进行
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildPlayerArea(),
            _buildContentTabs(theme),
            Expanded(
              child: _contentTab == 0
                  ? _buildVideoTab(theme)
                  : _buildCommentTab(theme),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 播放器 ====================

  Widget _buildPlayerArea() {
    final screenWidth = MediaQuery.of(context).size.width;
    return Container(
      width: double.infinity,
      height: screenWidth / (16 / 9),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildPlayerContent(),
          Positioned(
            top: 4,
            left: 4,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(LucideIcons.chevronLeft,
                    size: 24, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开「一起看」主页弹层（大厅 / 创建 / 进入 / 我的房间）。
  Future<void> _openWatchParty() async {
    if (!ref.read(authProvider).isLoggedIn) {
      if (mounted) context.push('/login');
      return;
    }
    final vodId = _video?.id ?? _doubanId;
    if (vodId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('影片信息未就绪，请稍后再试')));
      return;
    }
    final position =
        _playerKey.currentState?.currentPosition.inMilliseconds ?? 0;
    final wasPlaying = _playerKey.currentState?.isPlaying ?? false;
    // 强制暂停（含缓冲中/全屏状态），避免进入一起看后主播放器在后台继续播放。
    _playerKey.currentState?.forcePause();
    final entered = await showWatchPartyHome(
      context,
      ref,
      vodId: vodId,
      episode: _currentEpisodeIndex,
      positionMs: position,
      onRoomExit: _applyWatchPlayback,
    );
    // 未进入房间（取消/关闭弹层）时恢复此前的播放状态。
    if (!entered && wasPlaying && mounted) {
      _playerKey.currentState?.resumePlayback();
    }
  }

  /// 一起看房间退出回调：把房间内最后所在集与进度同步回本页。
  ///
  /// 仅当房间播放的是当前影片时才应用；同步后保持暂停，避免突然出声。
  void _applyWatchPlayback(WatchPlaybackState state) {
    if (!mounted) return;
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    if (state.vodId.isNotEmpty && state.vodId != video.id) return;
    final total = video.playGroups.first.urls.length;
    final index = total <= 0 ? 0 : state.episode.clamp(0, total - 1);
    _resumePaused = true;
    _handlePlayAction(index, resumePosition: state.positionMs / 1000.0);
  }

  /// 弹幕开关（由播放器控制条上的按钮触发）：与「设置/放大」同尺寸、
  /// 随控制条一起显隐。
  void _toggleDanmaku() {
    setState(() {
      _danmakuEnabled = !_danmakuEnabled;
      if (!_danmakuEnabled) {
        _danmakuFocus.unfocus();
        _danmakuInputActive = false;
      }
    });
  }

  void _closeDanmakuInput() {
    _danmakuFocus.unfocus();
    setState(() => _danmakuInputActive = false);
  }

  Widget _buildPlayerContent() {
    final video = _video;
    if (video == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (widget.subject.cover.isNotEmpty)
            CoverImage(imageUrl: widget.subject.cover),
          Container(color: Colors.black.withValues(alpha: 0.6)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSearching) ...[
                  const VideoLoadingBar(),
                  const SizedBox(height: 16),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _loadingMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final group = video.playGroups.first;

    if (_accessMessage != null) {
      return _buildAccessDenied();
    }
    if (_errorMessage != null) {
      return _buildPlayError();
    }

    final resolved = _resolvedUrl;
    if (resolved == null) {
      return const Center(child: VideoLoadingBar());
    }

    return EchoVideoPlayer(
      key: _playerKey,
      url: resolved,
      title: '${widget.subject.title} - ${group.titles[_currentEpisodeIndex]}',
      referer: '',
      initialPosition: _initialResumePosition,
      skipConfig: _skipConfig,
      onSkipConfigChange: (newConfig) async {
        final key = '${video.source}-${video.id}';
        await ref.read(configServiceProvider).saveSkipConfig(key, newConfig);
        setState(() => _skipConfig = newConfig);
      },
      hasNextEpisode: _currentEpisodeIndex < group.urls.length - 1,
      onNextEpisode: _playNextEpisode,
      onProgress: (pos, dur, {isFinal = false}) =>
          _savePlayRecord(pos, dur, isFinal: isFinal),
      onEnded: _autoPlayNext ? _playNextEpisode : null,
      danmaku: _danmaku,
      danmakuEnabled: _danmakuEnabled,
      onDanmakuToggle: _toggleDanmaku,
      startPaused: _resumePaused,
      episodeTitles: group.titles,
      episodeNeedVip: group.needVip,
      isVip: ref.watch(authProvider).user?.isVip ?? false,
      currentEpisodeIndex: _currentEpisodeIndex,
      onSelectEpisode: (index, wasFullScreen) {
        _restoreFullScreen = wasFullScreen;
        _handlePlayAction(index);
      },
      autoEnterFullScreen: _restoreFullScreen,
      onAutoFullScreenDone: () {
        if (_restoreFullScreen && mounted) {
          setState(() => _restoreFullScreen = false);
        }
      },
      danmakuInputActive: _danmakuInputActive,
      danmakuController: _danmakuController,
      danmakuFocus: _danmakuFocus,
      onDanmakuInputActivate: _openDanmakuInput,
      onDanmakuInputClose: _closeDanmakuInput,
      onDanmakuSubmit: _submitDanmaku,
    );
  }

  Widget _buildAccessDenied() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.lock, color: Colors.white70, size: 32),
          const SizedBox(height: 10),
          Text(
            _accessMessage ?? '该内容需要会员权限',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () {
                  final loggedIn = ref.read(authProvider).isLoggedIn;
                  context.push(loggedIn ? '/profile' : '/login');
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                child: Text(
                  ref.read(authProvider).isLoggedIn ? '开通会员' : '登录 / 开通会员',
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => _handlePlayAction(_currentEpisodeIndex),
                child: const Text('重试',
                    style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayError() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.circleAlert, color: Colors.white70, size: 32),
          const SizedBox(height: 10),
          Text(
            _errorMessage ?? '取流失败，请重试',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => _handlePlayAction(_currentEpisodeIndex),
            child: const Text('重试',
                style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  // ==================== 信息区 ====================


  // ==================== 视频 / 评论 Tab ====================

  Widget _buildContentTabs(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Row(
        children: [
          _buildContentTab(theme, '视频', 0),
          const SizedBox(width: 22),
          _buildContentTab(theme, '评论', 1),
        ],
      ),
    );
  }

  Widget _buildContentTab(ThemeData theme, String label, int index) {
    final active = _contentTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _contentTab = index;
        if (index == 1 && !_commentsLoaded && !_commentsLoading) {
          _loadComments();
        }
      }),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              color: active ? AppColors.pink : theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 5),
          Container(
            width: 22,
            height: 3,
            decoration: BoxDecoration(
              color: active ? AppColors.pink : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 视频 Tab ====================

  Widget _buildVideoTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _buildTitleRow(theme),
        _buildDescRow(theme),
        _buildActionRow(theme),
        Divider(
            height: 26, indent: 14, endIndent: 14, color: theme.dividerColor),
        _buildEpisodeHeader(theme),
        _buildEpisodeChips(theme),
        const SizedBox(height: 6),
        _buildRecommend(theme),
      ],
    );
  }

  Widget _buildCommentTab(ThemeData theme) {
    return Column(
      children: [
        Expanded(child: _buildCommentList(theme)),
        _buildCommentInput(theme),
      ],
    );
  }

  Widget _buildCommentList(ThemeData theme) {
    if (_commentsLoading && _comments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_comments.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 120),
        children: [
          Icon(Icons.forum_outlined,
              size: 46, color: theme.colorScheme.secondary),
          const SizedBox(height: 12),
          Center(
            child: Text('暂无评论，快来抢沙发',
                style: TextStyle(
                    fontSize: 13, color: theme.colorScheme.secondary)),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadComments(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _comments.length + 1,
        itemBuilder: (context, index) {
          if (index == _comments.length) {
            if (_comments.length >= _commentTotal) {
              return const SizedBox(height: 16);
            }
            return TextButton(
              onPressed: _commentsLoading ? null : _loadMoreComments,
              child: const Text('加载更多'),
            );
          }
          return _buildCommentItem(theme, _comments[index]);
        },
      ),
    );
  }

  Widget _buildCommentItem(ThemeData theme, VideoComment comment) {
    final name = comment.userName.isEmpty ? '用户' : comment.userName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.pinkLight,
            backgroundImage: (comment.userPortrait != null &&
                    comment.userPortrait!.isNotEmpty)
                ? NetworkImage(comment.userPortrait!)
                : null,
            child: (comment.userPortrait == null ||
                    comment.userPortrait!.isEmpty)
                ? Text(name.characters.first,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.pink,
                        fontWeight: FontWeight.w700))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.secondary)),
                    if (comment.kind == 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.pinkLight,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('弹幕',
                            style: TextStyle(
                                fontSize: 10,
                                color: AppColors.pink,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(comment.content,
                    style: const TextStyle(fontSize: 14, height: 1.35)),
                if (comment.likeCount > 0) ...[
                  const SizedBox(height: 3),
                  Text('${comment.likeCount} 赞',
                      style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.secondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentInput(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _commentFocus.requestFocus(),
                child: TextField(
                  controller: _commentController,
                  focusNode: _commentFocus,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitComment(),
                  decoration: const InputDecoration(
                    hintText: '说点什么...',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: _commentsLoading ? null : _submitComment,
              child: const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadComments() async {
    final video = _video;
    if (video == null || _commentsLoading) return;
    setState(() => _commentsLoading = true);
    try {
      final result = await ref
          .read(cmsServiceProvider)
          .getComments(video.id, page: 1, limit: 20);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(result.items);
        _commentTotal = result.total;
        _commentPage = 1;
        _commentsLoaded = true;
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _commentsLoaded = true;
        _commentsLoading = false;
      });
    }
  }

  Future<void> _loadMoreComments() async {
    final video = _video;
    if (video == null || _commentsLoading) return;
    if (_comments.length >= _commentTotal) return;
    setState(() => _commentsLoading = true);
    try {
      final next = _commentPage + 1;
      final result = await ref
          .read(cmsServiceProvider)
          .getComments(video.id, page: next, limit: 20);
      if (!mounted) return;
      setState(() {
        _comments.addAll(result.items);
        _commentPage = next;
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsLoading = false);
    }
  }

  Future<void> _submitComment() async {
    final video = _video;
    final text = _commentController.text.trim();
    if (video == null || text.isEmpty) return;
    final token = await ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) {
      if (mounted) context.push('/login');
      return;
    }
    try {
      final result =
          await ref.read(cmsServiceProvider).postComment(video.id, text);
      if (!mounted) return;
      final created = result.comment;
      if (created != null) {
        if (!result.pending) {
          setState(() {
            _comments.insert(0, created);
            _commentTotal += 1;
          });
          // 服务端会补齐头像等资料，稍后以服务端数据为准刷新一次。
          unawaited(_loadComments());
        }
        _commentController.clear();
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.pending ? '评论已提交，等待审核' : '评论已发送')),
        );
      }
    } on AppApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论发送失败')));
    }
  }

  Future<void> _loadDanmaku({bool force = false}) async {
    final video = _video;
    if (video == null) return;
    final key = '${video.id}-$_currentEpisodeIndex';
    if (!force && key == _danmakuEpisodeKey) return;
    _danmakuEpisodeKey = key;
    try {
      final items = await ref
          .read(cmsServiceProvider)
          .getDanmaku(video.id, episode: _currentEpisodeIndex);
      if (!mounted) return;
      setState(() => _danmaku = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _danmaku = const []);
    }
  }

  /// 在播放器上方就地唤起弹幕输入框（非弹窗）。
  Future<void> _openDanmakuInput() async {
    final video = _video;
    if (video == null) return;
    final token = await ref.read(configServiceProvider).getAuthToken();
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      context.push('/login');
      return;
    }
    setState(() {
      _danmakuEnabled = true;
      _danmakuInputActive = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _danmakuFocus.requestFocus();
    });
  }

  Future<void> _submitDanmaku() async {
    final video = _video;
    final text = _danmakuController.text.trim();
    if (video == null || text.isEmpty) return;

    final position = _playerKey.currentState?.currentPosition ?? Duration.zero;
    try {
      final result = await ref.read(cmsServiceProvider).postDanmaku(
            video.id,
            episode: _currentEpisodeIndex,
            timeMs: position.inMilliseconds,
            content: text,
          );
      if (!mounted) return;
      if (result.ok && !result.pending) {
        setState(() {
          _danmaku = [..._danmaku, DanmakuItem(
            timeMs: position.inMilliseconds,
            content: text,
          )]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
        });
        // 评论与弹幕数据互通：发送弹幕后同步刷新评论区。
        _commentsLoaded = false;
        _loadComments();
      }
      _danmakuController.clear();
      _danmakuFocus.requestFocus();
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

  Widget _buildTitleRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.subject.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _descending = !_descending),
            child:
                const Icon(Icons.swap_horiz, size: 20, color: AppColors.pink),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(ThemeData theme) {
    final favorited = ref.watch(favoritesProvider).value?.any((f) {
          return widget.subject.id.isNotEmpty
              ? f.subjectId == widget.subject.id
              : f.searchTitle == widget.subject.title;
        }) ??
        false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _toggleFavorite(favorited),
            child: Icon(
              favorited ? Icons.star_rounded : Icons.star_border_rounded,
              size: 26,
              color: favorited
                  ? AppColors.vipGold
                  : theme.colorScheme.secondary,
            ),
          ),
          const Spacer(),
          _buildActionIcon(Icons.favorite_rounded, const Color(0xFFFF6B9D),
              () => _toggleFavorite(favorited)),
          const SizedBox(width: 20),
          _buildActionIcon(Icons.group_rounded, const Color(0xFF8B5CF6),
              _openWatchParty),
          const SizedBox(width: 20),
          _buildActionIcon(Icons.download_rounded, const Color(0xFFFF9F43),
              _cacheCurrentEpisode),
          const SizedBox(width: 20),
          _buildActionIcon(Icons.share_rounded, const Color(0xFF3B82F6),
              _shareVideo),
        ],
      ),
    );
  }

  Future<void> _shareVideo() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final base = await ref.read(configServiceProvider).getApiBaseUrl();
      final title = widget.subject.title;
      await shareText(
        context,
        '我正在看「$title」，一起来看：$base',
        subject: '推荐你看 $title',
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('分享失败，请稍后重试')));
    }
  }

  Future<void> _cacheCurrentEpisode() async {
    final resolved = _resolvedUrl;
    if (resolved == null || resolved.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请等待视频加载完成')));
      return;
    }
    final video = _video;
    final title = (video != null && video.playGroups.isNotEmpty)
        ? '${widget.subject.title} - ${video.playGroups.first.titles[_currentEpisodeIndex]}'
        : widget.subject.title;
    final error = await ref.read(downloadsProvider.notifier).start(
          title: title,
          cover: widget.subject.cover,
          url: resolved,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error ?? '已加入离线缓存')));
  }

  Future<void> _toggleFavorite(bool favorited) async {
    final notifier = ref.read(favoritesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    if (favorited) {
      await notifier.remove(widget.subject.id, widget.subject.title);
      messenger.showSnackBar(const SnackBar(content: Text('已取消收藏')));
      return;
    }
    final video = _video;
    await notifier.add(Favorite(
      subjectId: widget.subject.id,
      title: widget.subject.title,
      sourceName: video?.sourceName ?? video?.source ?? '',
      cover: widget.subject.cover,
      year: widget.subject.year ?? '',
      totalEpisodes: (video != null && video.playGroups.isNotEmpty)
          ? video.playGroups.first.urls.length
          : 0,
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: widget.subject.title,
    ));
    messenger.showSnackBar(const SnackBar(content: Text('已收藏')));
  }

  Widget _buildActionIcon(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(icon, size: 24, color: color),
    );
  }

  Widget _buildDescRow(ThemeData theme) {
    final subjectDesc = widget.subject.description;
    final loadedDesc = _video?.desc;
    // 列表页传入的 subject.description 常为空串，不能直接压制详情接口返回的简介
    final desc = (subjectDesc != null && subjectDesc.trim().isNotEmpty)
        ? subjectDesc
        : loadedDesc;
    final hasDesc = desc != null && desc.trim().isNotEmpty;
    // 详情仍在加载且尚无简介时，不显示占位，避免闪出「暂无简介」。
    if (!hasDesc && _isSearching) return const SizedBox.shrink();
    final text = (desc != null && desc.trim().isNotEmpty) ? desc.trim() : '暂无简介';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _descExpanded = !_descExpanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: _descExpanded ? null : 2,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.secondary,
                    height: 1.7),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                _descExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: AppColors.pink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeHeader(ThemeData theme) {
    final video = _video;
    if (video == null) return const SizedBox.shrink();
    final n = video.playGroups.first.urls.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Row(
        children: [
          const Text('选集',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text('共 $n 集',
              style:
                  TextStyle(fontSize: 12, color: theme.colorScheme.secondary)),
        ],
      ),
    );
  }

  Widget _buildEpisodeChips(ThemeData theme) {
    final video = _video;
    if (video == null) return const SizedBox.shrink();
    final group = video.playGroups.first;
    final vipActive = ref.watch(authProvider).user?.isVip ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: group.urls.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final index = _descending ? (group.urls.length - 1 - i) : i;
            final active = _currentEpisodeIndex == index;
            final locked = !vipActive &&
                index < group.needVip.length &&
                group.needVip[index] > 0;
            return GestureDetector(
              onTap: () => _handlePlayAction(index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.pinkLight
                      : theme.colorScheme.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: active ? AppColors.pink : Colors.transparent,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (locked) ...[
                      const Icon(Icons.lock,
                          size: 11, color: Color(0xFFFF8A00)),
                      const SizedBox(width: 3),
                    ],
                    Text(group.titles[index],
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w400,
                            color: active
                                ? AppColors.pink
                                : theme.colorScheme.onSurface)),
                    if (active) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.pause, size: 11, color: AppColors.pink),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ==================== 同类推荐 ====================

  Widget _buildRecommend(ThemeData theme) {
    final typeId = _video?.typeId ?? 0;
    if (typeId <= 0) return const SizedBox.shrink();
    final async = ref.watch(_recommendProvider(typeId));
    final list = (async.value ?? const <VideoDetail>[])
        .where((v) => v.id != _video?.id && v.title != widget.subject.title)
        .take(12)
        .toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          icon: const Icon(Icons.live_tv_rounded,
              size: 18, color: AppColors.pink),
          title: '同类推荐',
          moreText: '更多',
          onMore: () => context.push('/search'),
        ),
        HScroll(
          child: Row(
            children: [
              for (var i = 0; i < list.length; i++) ...[
                VideoCard(
                  title: list[i].title,
                  imageUrl: list[i].poster,
                  year: list[i].year,
                  episode: list[i].typeName,
                  // 用 pushReplacement 打开，避免同类推荐层层压栈导致返回时旧页面无法回收
                  onTap: () => VideoRouter.open(context, list[i], replace: true),
                ),
                if (i != list.length - 1) const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
