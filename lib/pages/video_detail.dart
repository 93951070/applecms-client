import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/movie.dart';
import '../models/comment.dart';
import '../models/douban_media.dart';
import '../models/site.dart';
import '../models/watch_party.dart';
import '../services/app_api_service.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/likes_provider.dart';
import '../providers/cast_provider.dart';
import '../providers/auth_provider.dart';
import '../services/download_service.dart';
import '../core/theme.dart';
import '../core/navigation.dart';
import '../core/format_utils.dart';
import '../core/video_router.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/video_player.dart';
import '../widgets/bili_loading.dart';
import '../widgets/synopsis_sheet.dart';
import '../widgets/watch_party_sheet.dart';
import '../widgets/cast_sheet.dart';
import '../services/web_sniff_service.dart';

/// 播放页「同类推荐」数据源：按当前视频所属分类拉取同分类内容。
final _recommendProvider = FutureProvider.family<List<VideoDetail>, int>((
  ref,
  typeId,
) async {
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

class _VideoDetailPageState extends ConsumerState<VideoDetailPage>
    with WidgetsBindingObserver, RouteAware {
  late HistoryNotifier _historyNotifier;

  int _contentTab = 0;

  String _doubanId = '';

  // 核心数据：单站点按 id 直取一条详情即可，无需多源聚合
  VideoDetail? _video;
  int _currentEpisodeIndex = 0;
  double? _initialResumePosition;
  final bool _autoPlayNext = true;

  /// 已触发过服务端预热的下一集下标，避免同一集重复请求。
  int _prefetchedEpisode = -1;

  /// 从一起看回到本页时置位：同步进度并保持暂停，直到用户真正开始播放。
  bool _resumePaused = false;
  SkipConfig _skipConfig = SkipConfig();

  // 状态跟踪
  String _loadingMessage = '';
  bool _isSearching = true;
  bool _descending = false;

  // App 网关取流
  String? _resolvedUrl;

  // 直连地址播放时需要携带的 Referer（防盗链）。web嗅探直链取其自身 origin；
  // 走服务端 HLS 网关的地址由服务端取流，这里留空。
  String _resolvedReferer = '';
  String? _accessMessage;
  String? _errorMessage;

  /// 播放器是否已上锁：上锁后拦截返回，避免误触退出。
  bool _playerLocked = false;

  /// 播放失败后自动重新解析的次数（每次进入播放页最多自动重试一次）。
  int _playRetryCount = 0;

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

  final GlobalKey<EchoVideoPlayerState> _playerKey =
      GlobalKey<EchoVideoPlayerState>();

  /// 画中画是否激活：此时应用内播放区域显示占位封面，避免露出黑底。
  bool _playerPipActive = false;

  /// 详情后台静默刷新的订阅，用于同步最新选集会员状态。
  StreamSubscription<String>? _detailSub;

  /// 服务端热度值（播放次数 + 推荐数加权），取流成功后会刷新。
  int _heat = 0;

  /// 服务端推荐数。
  int _likeCount = 0;

  /// 服务端返回的当前账号/设备推荐状态。
  bool _liked = false;

  /// 是否已拿到服务端推荐状态：未拿到前退回本地镜像，避免闪烁。
  bool _likeResolved = false;

  /// 推荐请求进行中，避免连点重复提交。
  bool _likeBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doubanId = widget.subject.id;
    _detailSub = ref
        .read(cmsServiceProvider)
        .detailUpdates
        .listen(_onDetailUpdated);
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

  // 简介等非跳转类弹层会压入 ModalRoute，此处用一次性豁免避免误暂停。
  bool _keepPlayingOnNextRoute = false;

  // 返回上一页时立刻停播，避免离开播放页后旧视频继续出声。
  @override
  void didPop() {
    WebSniffService.abortAll(owner: this);
    _playerKey.currentState?.forcePause();
  }

  // 跳转到其它视频/页面时，暂停当前播放，避免旧视频在后台继续出声。
  @override
  void didPushNext() {
    // 无界面嗅探 WebView 不随页面销毁，被覆盖时先掐掉，避免它继续出声。
    WebSniffService.abortAll(owner: this);
    if (_keepPlayingOnNextRoute) {
      _keepPlayingOnNextRoute = false;
      return;
    }
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
  final Map<String, String> _episodeRefererCache = {};
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
      // 服务端是最新权威值；推荐请求进行中时保留乐观状态，等接口回包覆盖。
      if (!_likeBusy) {
        _liked = detail.liked;
        _likeResolved = true;
        _likeCount = detail.likeCount;
      }
      if (detail.heat > 0) _heat = detail.heat;
    });

    // 详情到手就顺带把豆瓣信息取回来，点开「简介」时直接命中缓存。
    if (detail.id.isNotEmpty) {
      ref.read(cmsServiceProvider).prefetchDouban(detail.id);
    }

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
      _resolvedReferer = '';
      _accessMessage = null;
      _errorMessage = null;
      _playerLocked = false;
      if (isEpisodeChange) _prefetchedEpisode = -1;
    });
    _resolveCurrentEpisode();
    _loadDanmaku();
  }

  /// 通过 App 网关做会员校验并解析直连地址。
  ///
  /// 直连地址只由服务端按次下发；网关不可用或校验不通过时不会回退到
  /// 客户端侧地址，避免绕过会员校验。
  Future<void> _resolveCurrentEpisode({bool forceRefresh = false}) async {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final group = video.playGroups.first;
    if (_currentEpisodeIndex >= group.urls.length) return;

    // 命中预取缓存：切集/重进无需再次等待网关解析。
    // forceRefresh（播放失败重试）时跳过缓存，强制取新鲜地址。
    final cacheKey = '${video.id}:$_currentEpisodeIndex';
    final prefetched = forceRefresh ? null : _episodeUrlCache[cacheKey];
    if (prefetched != null && prefetched.isNotEmpty) {
      setState(() {
        _resolvedUrl = prefetched;
        _resolvedReferer = _episodeRefererCache[cacheKey] ?? '';
        _accessMessage = null;
        _errorMessage = null;
      });
      _prefetchEpisodes();
      return;
    }

    setState(() {
      _accessMessage = null;
      _errorMessage = null;
    });

    final config = ref.read(configServiceProvider);
    final api = ref.read(appApiServiceProvider);
    final base = await config.getApiBaseUrl();
    final token = await config.getAuthToken();
    final playSource = video.playGroups.indexOf(group);

    try {
      var result = await api.play(
        base,
        videoId: video.id,
        playSource: playSource < 0 ? 0 : playSource,
        playIndex: _currentEpisodeIndex,
        token: token,
        refresh: forceRefresh,
      );
      if (!mounted) return;

      // web嗅探线路：App 端 WebView 解析，嗅到直链后直接交给播放器，
      // 不再回传服务端转 HLS 网关，省去一次回传与二次拉流，首帧更快、更稳。
      // 只有嗅探失败时才回传，让服务端把该线路短暂冷却并自动换下一条（无感）。
      // 其他线路（服务端解析、直链）仍走原有逻辑，去广告能力不受影响。
      var guard = 0;
      while (mounted && result.isWebSniff && guard < 6) {
        guard++;
        final sniffed = await WebSniffService.sniff(
          result.sniffUrl!,
          owner: this,
        );
        if (!mounted) return;
        if (sniffed != null && sniffed.isNotEmpty) {
          _episodeUrlCache[cacheKey] = sniffed;
          _episodeRefererCache[cacheKey] = _originOf(sniffed);
          _playRetryCount = 0;
          setState(() {
            _resolvedUrl = sniffed;
            _resolvedReferer = _originOf(sniffed);
            _accessMessage = null;
            _errorMessage = null;
          });
          _prefetchEpisodes();
          return;
        }
        final reportSource =
            result.sourceIndex ?? (playSource < 0 ? 0 : playSource);
        result = await api.play(
          base,
          videoId: video.id,
          playSource: playSource < 0 ? 0 : playSource,
          playIndex: _currentEpisodeIndex,
          token: token,
          reportSourceIndex: reportSource,
          reportOutcome: 'fail',
        );
        if (!mounted) return;
      }

      if (result.hasAccess &&
          result.playUrl != null &&
          result.playUrl!.isNotEmpty) {
        _episodeUrlCache[cacheKey] = result.playUrl!;
        _episodeRefererCache[cacheKey] = '';
        _playRetryCount = 0;
        setState(() {
          _resolvedUrl = result.playUrl;
          _resolvedReferer = '';
          // 服务端在成功取流时已累加播放热度，这里同步最新数值。
          if (result.heat > 0) _heat = result.heat;
          if (result.likeCount > 0) _likeCount = result.likeCount;
        });
        _prefetchEpisodes();
      } else if (!result.hasAccess) {
        setState(() {
          _accessMessage = result.message.isEmpty
              ? '该内容需要会员权限'
              : result.message;
        });
      } else if (!forceRefresh) {
        // 服务端解析失败（非会员拦截）：丢弃缓存强制刷新一次，避免把失效地址定格。
        _episodeUrlCache.remove(cacheKey);
        return await _resolveCurrentEpisode(forceRefresh: true);
      } else {
        setState(() {
          _errorMessage = result.message.isEmpty ? '解析失败，请重试' : result.message;
        });
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('App 网关取流失败: $e');
      if (!forceRefresh) {
        _episodeUrlCache.remove(cacheKey);
        return await _resolveCurrentEpisode(forceRefresh: true);
      }
      setState(() {
        _errorMessage = '取流失败，请检查网络后重试';
      });
    }
  }

  /// 取直链的 origin 作为播放 Referer，规避多数源的防盗链校验。
  String _originOf(String url) {
    try {
      final uri = Uri.parse(url);
      if (!uri.hasAuthority || uri.host.isEmpty) return '';
      return uri.origin;
    } catch (_) {
      return '';
    }
  }

  /// 播放器运行期失败（如网页嗅探直链失效导致的缓冲超时）时自动重新解析一次。
  ///
  /// 强制跳过缓存重新嗅探，拿到新鲜直链后播放器会随 url 变化重建重试；
  /// 只重试一次，避免失败源陷入死循环。
  void _handlePlaybackError(String message) {
    if (!mounted || _playRetryCount >= 1) return;
    _playRetryCount++;
    debugPrint('播放失败，自动重新解析: $message');
    unawaited(_resolveCurrentEpisode(forceRefresh: true));
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
      pending.add(
        _prefetchEpisode(api, base, video.id, sourceIndex, i, key, token),
      );
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
        prefetch: true,
      );
      if (result.hasAccess &&
          result.playUrl != null &&
          result.playUrl!.isNotEmpty) {
        _episodeUrlCache[key] = result.playUrl!;
        _episodeRefererCache[key] = '';
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

  /// 进度接近结尾时提前通知服务端预热下一集分片缓存，切集时首个分片直接命中。
  void _maybePrefetchNext(Duration position, Duration duration) {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final group = video.playGroups.first;
    final next = _currentEpisodeIndex + 1;
    if (next >= group.urls.length) return;
    if (_prefetchedEpisode == next) return;
    if (duration <= Duration.zero) return;
    if (position < duration * 0.85) return;
    _prefetchedEpisode = next;
    unawaited(_prefetchNextOnServer(next));
  }

  Future<void> _prefetchNextOnServer(int next) async {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final group = video.playGroups.first;
    if (next >= group.urls.length) return;
    final api = ref.read(appApiServiceProvider);
    final config = ref.read(configServiceProvider);
    final playSource = video.playGroups.indexOf(group);
    try {
      final base = await config.getApiBaseUrl();
      final token = await config.getAuthToken();
      await api.prefetch(
        base,
        videoId: video.id,
        playSource: playSource < 0 ? 0 : playSource,
        playIndex: next,
        token: token,
      );
    } catch (_) {
      // 预热是尽力而为，失败不影响正常播放。
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

  Future<void> _savePlayRecord(
    Duration position,
    Duration duration, {
    bool isFinal = false,
  }) async {
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
      totalTime: duration.inSeconds > 0
          ? duration.inSeconds
          : (_initialResumePosition?.toInt() ?? 0),
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
    WebSniffService.abortAll(owner: this);
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
      // 无界面嗅探 WebView 不随页面销毁，退到后台先掐掉，避免后台继续出声。
      WebSniffService.abortAll(owner: this);
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
          // 画中画激活时画面已被系统挪到悬浮窗，用封面占位代替黑底。
          if (_playerPipActive) _buildPipPlaceholder(),
          Positioned(
            top: 4,
            left: 4,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(
                  LucideIcons.chevronLeft,
                  size: 24,
                  color: Colors.white,
                ),
                onPressed: () {
                  if (_playerLocked) {
                    ScaffoldMessenger.of(context)
                      ..removeCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('播放器已上锁，请先解锁'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    return;
                  }
                  Navigator.pop(context);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 画中画激活时的占位：封面 + 暗色蒙层 + 提示，避免播放区域黑成一片。
  Widget _buildPipPlaceholder() {
    final poster = _video?.poster ?? widget.subject.cover;
    return GestureDetector(
      onTap: _exitPipFromPlaceholder,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster.isNotEmpty)
            CoverImage(imageUrl: poster)
          else
            const ColoredBox(color: Color(0xFF161016)),
          const ColoredBox(color: Color(0x99000000)),
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.pictureInPicture2,
                  size: 30,
                  color: Colors.white70,
                ),
                SizedBox(height: 8),
                Text(
                  '正在画中画播放，点按回到页面',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 点占位封面时主动结束画中画，让画面回到页面内。
  Future<void> _exitPipFromPlaceholder() async {
    await _playerKey.currentState?.exitPip();
    if (mounted) setState(() => _playerPipActive = false);
    _playerKey.currentState?.resumePlayback();
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
                      fontWeight: FontWeight.bold,
                    ),
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
      referer: _resolvedReferer,
      initialPosition: _initialResumePosition,
      onPlaybackError: _handlePlaybackError,
      onPipChanged: (active) {
        if (mounted && _playerPipActive != active) {
          setState(() => _playerPipActive = active);
        }
      },
      onLockChanged: (locked) {
        if (mounted) setState(() => _playerLocked = locked);
      },
      skipConfig: _skipConfig,
      onSkipConfigChange: (newConfig) async {
        final key = '${video.source}-${video.id}';
        await ref.read(configServiceProvider).saveSkipConfig(key, newConfig);
        setState(() => _skipConfig = newConfig);
      },
      hasNextEpisode: _currentEpisodeIndex < group.urls.length - 1,
      onNextEpisode: _playNextEpisode,
      onProgress: (pos, dur, {isFinal = false}) {
        _savePlayRecord(pos, dur, isFinal: isFinal);
        _maybePrefetchNext(pos, dur);
      },
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
              fontWeight: FontWeight.bold,
            ),
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
                child: const Text(
                  '重试',
                  style: TextStyle(color: Colors.white54),
                ),
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
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => _handlePlayAction(_currentEpisodeIndex),
            child: const Text('重试', style: TextStyle(color: Colors.white54)),
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
        _buildActionRow(theme),
        Divider(
          height: 26,
          indent: 14,
          endIndent: 14,
          color: theme.dividerColor,
        ),
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
          Icon(
            LucideIcons.messageSquare,
            size: 46,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '暂无评论，快来抢沙发',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.secondary,
              ),
            ),
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
            backgroundImage:
                (comment.userPortrait != null &&
                    comment.userPortrait!.isNotEmpty)
                ? NetworkImage(comment.userPortrait!)
                : null,
            child:
                (comment.userPortrait == null || comment.userPortrait!.isEmpty)
                ? Text(
                    name.characters.first,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.pink,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    if (comment.kind == 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.pinkLight,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '弹幕',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.pink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  comment.content,
                  style: const TextStyle(fontSize: 14, height: 1.35),
                ),
                if (comment.likeCount > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    '${comment.likeCount} 赞',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
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
      final result = await ref
          .read(cmsServiceProvider)
          .postComment(video.id, text);
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
      final result = await ref
          .read(cmsServiceProvider)
          .postDanmaku(
            video.id,
            episode: _currentEpisodeIndex,
            timeMs: position.inMilliseconds,
            content: text,
          );
      if (!mounted) return;
      if (result.ok && !result.pending) {
        setState(() {
          _danmaku = [
            ..._danmaku,
            DanmakuItem(timeMs: position.inMilliseconds, content: text),
          ]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.subject.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              GestureDetector(
                onTap: _showSynopsisSheet,
                child: Row(
                  children: [
                    Text(
                      '简介',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: theme.colorScheme.secondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_heat > 0 || _likeCount > 0) ...[
            const SizedBox(height: 6),
            _buildHeatLine(theme),
          ],
        ],
      ),
    );
  }

  /// 标题下方的热度行：空心火花图标 + 服务端热度值，附带推荐数。
  Widget _buildHeatLine(ThemeData theme) {
    final accent = theme.colorScheme.primary;
    return Row(
      children: [
        Icon(LucideIcons.sparkles, size: 13, color: accent),
        const SizedBox(width: 4),
        Text(
          '热度 ${formatCount(_heat)}',
          style: TextStyle(fontSize: 12, color: accent),
        ),
        if (_likeCount > 0) ...[
          const SizedBox(width: 10),
          Icon(
            LucideIcons.thumbsUp,
            size: 12,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(width: 4),
          Text(
            '推荐 ${formatCount(_likeCount)}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary),
          ),
        ],
      ],
    );
  }

  /// 腾讯风格的「简介」底部弹层：按需拉取豆瓣评分/简介/演职员头像，失败静默降级。
  Future<void> _showSynopsisSheet() async {
    final vodId = (_video?.id ?? _doubanId).trim();
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    if (!mounted) return;
    final localDesc = (widget.subject.description ?? '').trim().isNotEmpty
        ? widget.subject.description!.trim()
        : (_video?.desc ?? '').trim();
    final future = vodId.isEmpty
        ? Future<DoubanMedia?>.value(null)
        : ref.read(cmsServiceProvider).fetchDouban(vodId);
    _keepPlayingOnNextRoute = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).cardColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => SynopsisSheet(
          title: (_video?.title ?? '').trim().isNotEmpty
              ? _video!.title
              : widget.subject.title,
          year: _video?.year ?? widget.subject.year,
          typeName: _video?.typeName,
          localDesc: localDesc,
          localActors: _video?.actors ?? '',
          localDirectors: _video?.directors ?? '',
          future: future,
          proxyImageUrl: (raw) => doubanImageUrl(base, raw),
        ),
      );
    } finally {
      _keepPlayingOnNextRoute = false;
    }
  }

  /// 播放页主操作区：推荐 / 加追 / 下载 / 投屏 / 一起看，一行等宽分散。
  Widget _buildActionRow(ThemeData theme) {
    final favorited =
        ref.watch(favoritesProvider).value?.any((f) {
          return widget.subject.id.isNotEmpty
              ? f.subjectId == widget.subject.id
              : f.searchTitle == widget.subject.title;
        }) ??
        false;
    final liked = _displayLiked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 2),
      child: Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: LucideIcons.thumbsUp,
              label: liked ? '已推荐' : '推荐',
              active: liked,
              onTap: _toggleLike,
            ),
          ),
          Expanded(
            child: _ActionButton(
              icon: LucideIcons.listPlus,
              label: favorited ? '已追' : '加追',
              active: favorited,
              onTap: () => _toggleFavorite(favorited),
            ),
          ),
          Expanded(
            child: _ActionButton(
              icon: LucideIcons.squareArrowDown,
              label: '下载',
              onTap: _cacheCurrentEpisode,
            ),
          ),
          Expanded(
            child: _ActionButton(
              iconWidget: _CastTvIcon(
                color: _casting ? AppColors.pink : theme.colorScheme.secondary,
              ),
              label: _casting ? '投屏中' : '投屏',
              active: _casting,
              onTap: _openCastSheet,
            ),
          ),
          Expanded(
            child: _ActionButton(
              icon: LucideIcons.users,
              label: '一起看',
              onTap: _openWatchParty,
            ),
          ),
        ],
      ),
    );
  }

  /// 推荐/加追共用的条目标识：优先用条目 ID，缺失时退化为标题。
  String get _interactionKey =>
      widget.subject.id.isNotEmpty ? widget.subject.id : widget.subject.title;

  /// 推荐状态优先取服务端结果；服务端尚未返回时退回本地镜像。
  bool get _displayLiked => _likeResolved
      ? _liked
      : (ref.watch(likesProvider).value?.contains(_interactionKey) ?? false);

  /// 推荐：以服务端统计为准，本地只做离线镜像与乐观更新。
  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    final videoId = widget.subject.id.trim();
    if (videoId.isEmpty) {
      _showLikeTip('该条目缺少 ID，暂不支持推荐');
      return;
    }
    final target = !_displayLiked;
    final previousCount = _likeCount;
    setState(() {
      _likeBusy = true;
      _liked = target;
      _likeResolved = true;
      _likeCount = (previousCount + (target ? 1 : -1)).clamp(0, 1 << 30);
    });
    try {
      final config = ref.read(configServiceProvider);
      final base = await config.getApiBaseUrl();
      final deviceId = await config.getOrCreateDeviceId();
      final data = await ref
          .read(appApiServiceProvider)
          .vodLike(base, videoId, liked: target, deviceId: deviceId);
      if (!mounted) return;
      final confirmed = data['liked'] == true;
      setState(() {
        _liked = confirmed;
        _likeCount = (data['like_count'] as num?)?.toInt() ?? _likeCount;
        final heat = (data['heat'] as num?)?.toInt() ?? 0;
        if (heat > 0) _heat = heat;
      });
      await ref
          .read(likesProvider.notifier)
          .setLiked(_interactionKey, confirmed);
      _showLikeTip(confirmed ? '已推荐，感谢支持' : '已取消推荐');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = !target;
        _likeCount = previousCount;
      });
      _showLikeTip('推荐失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  void _showLikeTip(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  /// 投屏：搜索局域网 DLNA 电视并把当前播放地址推给电视。
  Future<void> _openCastSheet() async {
    final url = _resolvedUrl ?? '';
    final video = _video;
    final episode = (video != null && video.playGroups.isNotEmpty)
        ? video.playGroups.first.titles[_currentEpisodeIndex]
        : '';
    final title = episode.isEmpty
        ? widget.subject.title
        : '${widget.subject.title} - $episode';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => CastSheet(
        url: url,
        title: title,
        // 投屏后电视独立播放，本机暂停避免两边同时出声。
        onCastStarted: () => _playerKey.currentState?.pausePlayback(),
      ),
    );
  }

  /// 是否正在投屏：用于操作区高亮。
  bool get _casting => ref.watch(dlnaCastProvider).casting;

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
    final error = await ref
        .read(downloadsProvider.notifier)
        .start(title: title, cover: widget.subject.cover, url: resolved);
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
    await notifier.add(
      Favorite(
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
      ),
    );
    messenger.showSnackBar(const SnackBar(content: Text('已收藏')));
  }

  Widget _buildEpisodeHeader(ThemeData theme) {
    final video = _video;
    if (video == null) return const SizedBox.shrink();
    final n = video.playGroups.first.urls.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Row(
        children: [
          const Text(
            '选集',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          Text(
            '共 $n 集',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => setState(() => _descending = !_descending),
            child: Row(
              children: [
                Icon(
                  LucideIcons.arrowUpDown,
                  size: 16,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 2),
                Text(
                  _descending ? '倒序' : '正序',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
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
            final locked =
                !vipActive &&
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
                      const Icon(
                        LucideIcons.lock,
                        size: 11,
                        color: Color(0xFFFF8A00),
                      ),
                      const SizedBox(width: 3),
                    ],
                    Text(
                      group.titles[index],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                        color: active
                            ? AppColors.pink
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        LucideIcons.pause,
                        size: 11,
                        color: AppColors.pink,
                      ),
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
          icon: const Icon(LucideIcons.tv, size: 18, color: AppColors.pink),
          title: '同类推荐',
          moreText: '更多',
          // 进入该分类的更多列表页，而不是搜索结果页。
          onMore: () {
            final name = _video?.typeName ?? '';
            final query = name.isEmpty
                ? 'id=$typeId'
                : 'id=$typeId&title=${Uri.encodeComponent(name)}';
            context.push('/category?$query');
          },
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
                  heat: list[i].heat,
                  // 用 pushReplacement 打开，避免同类推荐层层压栈导致返回时旧页面无法回收
                  onTap: () =>
                      VideoRouter.open(context, list[i], replace: true),
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

/// 播放页主操作区里的一个按钮：图标在上、文字在下，等宽分散。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    this.icon,
    this.iconWidget,
    required this.label,
    required this.onTap,
    this.active = false,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active ? AppColors.pink : theme.colorScheme.secondary;
    const size = 24.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: size,
              child: iconWidget != null
                  ? SizedBox(width: size, height: size, child: iconWidget)
                  : Icon(icon, size: size, color: color),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 投屏图标：空心显示器轮廓 + 中间小号 TV 字母（lucide 无此字形，自绘）。
class _CastTvIcon extends StatelessWidget {
  const _CastTvIcon({required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size * 0.76,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.6),
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Text(
            'TV',
            style: TextStyle(
              color: color,
              fontSize: size * 0.36,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              height: 1,
            ),
          ),
        ),
        Container(
          width: size * 0.42,
          height: 1.6,
          margin: EdgeInsets.only(top: size * 0.08),
          color: color,
        ),
      ],
    );
  }
}
