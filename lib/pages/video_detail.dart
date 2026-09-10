import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/movie.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
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
  bool _favorited = false;

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

    setState(() {
      _video = detail;
      _doubanId = detail.id;
      _loadingMessage = '正在准备播放...';
      _isSearching = false;
    });

    _loadSkipConfig();
    _handlePlayAction(_currentEpisodeIndex, resumePosition: _initialResumePosition);
  }

  /// 搜索兜底时挑选最匹配的一条
  VideoDetail? _pickBestMatch(List<VideoDetail> results) {
    final target = widget.subject.title.replaceAll(' ', '').toLowerCase();
    VideoDetail? loose;
    for (final r in results) {
      if (r.playGroups.isEmpty) continue;
      final name = r.title.replaceAll(' ', '').toLowerCase();
      if (name == target) return r;
      if (loose == null && (name.contains(target) || target.contains(name))) {
        loose = r;
      }
    }
    if (loose != null) return loose;
    for (final r in results) {
      if (r.playGroups.isNotEmpty) return r;
    }
    return null;
  }

  void _handlePlayAction(int index, {double? resumePosition}) {
    final video = _video;
    if (video == null) return;
    final total = video.playGroups.first.urls.length;
    final safeIndex = total <= 0 ? 0 : index.clamp(0, total - 1);
    setState(() {
      _initialResumePosition = resumePosition ?? _initialResumePosition;
      _currentEpisodeIndex = safeIndex;
    });
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
    return EchoVideoPlayer(
      key: _playerKey,
      url: group.urls[_currentEpisodeIndex],
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
          _buildDanmakuButton(),
        ],
      ),
    );
  }

  Widget _buildContentTab(ThemeData theme, String label, int index) {
    final active = _contentTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _contentTab = index),
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
      onTap: () => _comingSoon('弹幕'),
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
    return ListView(
      padding: const EdgeInsets.only(top: 120),
      children: [
        Icon(Icons.forum_outlined,
            size: 46, color: theme.colorScheme.secondary),
        const SizedBox(height: 12),
        Center(
          child: Text('暂无评论，快来抢沙发',
              style:
                  TextStyle(fontSize: 13, color: theme.colorScheme.secondary)),
        ),
      ],
    );
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => _favorited = !_favorited),
            child: Icon(
              _favorited ? Icons.star_rounded : Icons.star_border_rounded,
              size: 26,
              color: _favorited
                  ? AppColors.vipGold
                  : theme.colorScheme.secondary,
            ),
          ),
          const Spacer(),
          _buildActionIcon(Icons.favorite_rounded, const Color(0xFFFF6B9D),
              () => setState(() => _favorited = true)),
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
