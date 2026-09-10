import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/movie.dart';
import '../models/comment.dart';
import '../models/site.dart';
import '../services/app_api_service.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../providers/favorites_provider.dart';
import '../core/theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/video_player.dart';

/// 播放页「好剧推送」数据源（默认电影分类）
final _recommendProvider = FutureProvider<List<VideoDetail>>((ref) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryList(site, 1, page: 1, pageSize: 12);
});

class VideoDetailPage extends ConsumerStatefulWidget {
  final DoubanSubject subject;

  const VideoDetailPage({super.key, required this.subject});

  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> with WidgetsBindingObserver {
  late HistoryNotifier _historyNotifier;

  bool _descExpanded = false;
  int _contentTab = 0;

  String _doubanId = '';

  // 核心数据：单站点按 id 直取一条详情即可，无需多源聚合
  VideoDetail? _video;
  int _currentEpisodeIndex = 0;
  double? _initialResumePosition;
  bool _autoPlayNext = true;
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

  final GlobalKey<EchoVideoPlayerState> _playerKey = GlobalKey<EchoVideoPlayerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doubanId = widget.subject.id;
    _checkHistoryAndLoadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _historyNotifier = ref.read(historyProvider.notifier);
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

  Future<void> _loadData() async {
    final cmsService = ref.read(cmsServiceProvider);
    final configService = ref.read(configServiceProvider);

    setState(() {
      _loadingMessage = '正在加载播放源...';
    });

    final site = await configService.getPrimarySite();
    if (!mounted) return;

    if (site.disabled) {
      setState(() {
        _isSearching = false;
        _loadingMessage = '未配置有效视频源';
      });
      return;
    }

    // 1) 优先按 id 直取详情（对接收 CMS 时唯一可靠的方式）
    VideoDetail? detail;
    final id = widget.subject.id.trim();
    if (id.isNotEmpty) {
      detail = await cmsService.getDetail(site, id);
      if (!mounted) return;
    }

    // 2) 无 id 或直取失败时，按标题搜索兜底
    if (detail == null) {
      final results = await cmsService.search(site, widget.subject.title);
      if (!mounted) return;
      detail = _pickBestMatch(results);
    }

    if (detail == null || detail.playGroups.isEmpty) {
      setState(() {
        _isSearching = false;
        _loadingMessage = '暂无可播放资源';
      });
      return;
    }

    final fullDetail = detail;
    setState(() {
      _video = fullDetail;
      _doubanId = fullDetail.id;
      _loadingMessage = '正在准备播放...';
      _isSearching = false;
    });

    _loadSkipConfig();
    _loadComments();
    _handlePlayAction(_currentEpisodeIndex, resumePosition: _initialResumePosition);
  }

  /// 搜索兜底时挑选最匹配的一条
  VideoDetail? _pickBestMatch(List<VideoDetail> results) {
    final target = widget.subject.title.replaceAll(' ', '').toLowerCase();
    VideoDetail? loose;
    for (final r in results) {
      final name = r.title.replaceAll(' ', '').toLowerCase();
      if (name == target) return r;
      if (loose == null && (name.contains(target) || target.contains(name))) {
        loose = r;
      }
    }
    if (loose != null) return loose;
    return results.isEmpty ? null : results.first;
  }

  void _handlePlayAction(int index, {double? resumePosition}) {
    final video = _video;
    if (video == null || video.playGroups.isEmpty) return;
    final total = video.playGroups.first.urls.length;
    final safeIndex = total <= 0 ? 0 : index.clamp(0, total - 1);
    setState(() {
      _initialResumePosition = resumePosition ?? _initialResumePosition;
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
        setState(() {
          _resolvedUrl = result.playUrl;
          _resolvingPlay = false;
        });
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
          if (_video != null)
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: _buildDanmakuInputOverlay(),
            ),
        ],
      ),
    );
  }

  /// 播放器上方的弹幕输入条（B 站风格，非弹窗），点击后在原位唤起输入法。
  Widget _buildDanmakuInputOverlay() {
    if (_danmakuInputActive) {
      return Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white24),
              ),
              child: TextField(
                controller: _danmakuController,
                focusNode: _danmakuFocus,
                maxLength: 50,
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submitDanmaku(),
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
          _danmakuBarButton('发送', _submitDanmaku),
          const SizedBox(width: 6),
          _danmakuBarButton('关闭', () {
            _danmakuFocus.unfocus();
            setState(() => _danmakuInputActive = false);
          }),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _openDanmakuInput,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(17),
              ),
              child: const Row(
                children: [
                  Icon(Icons.edit_rounded, size: 15, color: Colors.white70),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '发个弹幕吧...',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => setState(() => _danmakuEnabled = !_danmakuEnabled),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Text(
              _danmakuEnabled ? '弹幕开' : '弹幕关',
              style: TextStyle(
                color: _danmakuEnabled ? AppColors.pinkLight : Colors.white60,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _danmakuBarButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.pink,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Text(
          label,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
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
                  const CircularProgressIndicator(color: Colors.white),
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
      return const Center(child: CircularProgressIndicator(color: Colors.white));
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
                onPressed: () => context.push('/login'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                child: const Text('登录 / 开通会员'),
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
          const Spacer(),
          _buildDanmakuToggle(),
          const SizedBox(width: 8),
          _buildDanmakuButton(),
        ],
      ),
    );
  }

  Widget _buildDanmakuToggle() {
    return GestureDetector(
      onTap: () => setState(() => _danmakuEnabled = !_danmakuEnabled),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: _danmakuEnabled ? AppColors.pinkLight : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _danmakuEnabled
                  ? Icons.chat_bubble
                  : Icons.chat_bubble_outline,
              size: 13,
              color: _danmakuEnabled ? AppColors.pink : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              _danmakuEnabled ? '弹幕开' : '弹幕关',
              style: TextStyle(
                fontSize: 12,
                color: _danmakuEnabled ? AppColors.pink : Colors.grey,
              ),
            ),
          ],
        ),
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

  Widget _buildDanmakuButton() {
    return GestureDetector(
      onTap: _openDanmakuInput,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
        decoration: BoxDecoration(
          color: AppColors.pinkLight,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('点我发弹幕',
                style: TextStyle(fontSize: 12, color: AppColors.pink)),
            const SizedBox(width: 8),
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.pink,
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Text('弹',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  void _comingSoon(String name) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$name 敬请期待'),
      duration: const Duration(seconds: 1),
    ));
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
                Text(name,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.secondary)),
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
    setState(() => _danmakuInputActive = true);
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
          _buildActionIcon(Icons.download_rounded, const Color(0xFFFF9F43),
              () => _comingSoon('缓存下载')),
          const SizedBox(width: 20),
          _buildActionIcon(Icons.share_rounded, const Color(0xFF3B82F6),
              () => _comingSoon('分享')),
          const SizedBox(width: 20),
          _buildActionIcon(Icons.edit_rounded, AppColors.pink,
              () => _comingSoon('编辑')),
        ],
      ),
    );
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
    final desc = widget.subject.description ?? _video?.desc;
    final text =
        (desc != null && desc.trim().isNotEmpty) ? desc.trim() : '暂无简介';
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

  // ==================== 好剧推送 ====================

  Widget _buildRecommend(ThemeData theme) {
    final async = ref.watch(_recommendProvider);
    final list = (async.value ?? const <VideoDetail>[])
        .where((v) => v.title != widget.subject.title)
        .take(12)
        .toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          icon: const Icon(Icons.live_tv_rounded,
              size: 18, color: AppColors.pink),
          title: '好剧推送',
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
                  onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                    builder: (context) => VideoDetailPage(
                      subject: DoubanSubject(
                        id: list[i].id,
                        title: list[i].title,
                        rate: '0.0',
                        cover: list[i].poster,
                        year: list[i].year,
                        description: list[i].desc,
                      ),
                    ),
                  )),
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
