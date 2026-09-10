import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/movie.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../services/video_quality_service.dart';
import '../services/source_optimizer_service.dart';
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

enum LoadingStage { searching, preferring, fetching, ready }

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> with WidgetsBindingObserver {
  late HistoryNotifier _historyNotifier;

  bool _descExpanded = false;
  int _contentTab = 0;
  bool _favorited = false;
  
  DoubanSubject? _fullSubject;
  bool _isDetailLoading = false;
  String _doubanId = '';
  
  // 核心数据
  final List<VideoDetail> _availableSources = [];
  VideoDetail? _currentSource;
  int _currentEpisodeIndex = 0;
  double? _initialResumePosition;
  bool _autoPlayNext = true;
  SkipConfig _skipConfig = SkipConfig();

  // 状态跟踪
  LoadingStage _loadingStage = LoadingStage.searching;
  String _loadingMessage = '';
  bool _isSearching = true;
  final bool _isPlaying = false;
  bool _noSitesConfigured = false;
  bool _isOptimizing = false;
  bool _hasTriggeredInitialInit = false;
  bool _descending = false;

  final Map<String, double> _scoreMap = {};
  final Map<String, VideoQualityInfo> _qualityInfoMap = {};
  final Set<String> _testedSources = {};
  
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
    // 1. 尝试从历史记录中恢复状态
    final history = ref.read(historyProvider).value ?? [];
    final record = history.firstWhere(
      (r) => r.searchTitle == widget.subject.title,
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
        searchTitle: ''
      ),
    );

    if (record.title.isNotEmpty) {
      debugPrint('找到历史记录：第 ${record.index} 集，进度 ${record.playTime}s');
      setState(() {
        _currentEpisodeIndex = record.index;
        _initialResumePosition = record.playTime.toDouble();
        if (_doubanId.isEmpty && record.doubanId != null && record.doubanId!.isNotEmpty) {
          _doubanId = record.doubanId!;
        }
      });
    }

    // 2. 正常加载数据
    _loadData();
  }

  void _loadData() async {
    final cmsService = ref.read(cmsServiceProvider);
    final configService = ref.read(configServiceProvider);

    setState(() {
      _loadingStage = LoadingStage.searching;
      _loadingMessage = '🔍 正在搜索播放源...';
    });

    // 已彻底二开对接 CMS，不再通过豆瓣补全详情

    final site = await configService.getPrimarySite();

    if (site.disabled) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _noSitesConfigured = true;
          _loadingMessage = '❌ 未配置有效视频源';
        });
      }
      return;
    }

    setState(() {
      _noSitesConfigured = false;
    });

    final Set<String> processedKeys = {};

    final results = await cmsService.search(site, widget.subject.title);
    if (!mounted) return;

    final List<VideoDetail> newlyFound = [];

    for (var res in results) {
      final sTitle = res.title.replaceAll(' ', '').toLowerCase();
      final tTitle = widget.subject.title.replaceAll(' ', '').toLowerCase();
      if (sTitle.contains(tTitle) || tTitle.contains(sTitle)) {
        final key = '${res.source}-${res.id}';
        if (!processedKeys.contains(key)) {
          processedKeys.add(key);
          newlyFound.add(res);
        }
      }
    }

    if (mounted && newlyFound.isNotEmpty) {
      setState(() {
        _availableSources.addAll(newlyFound);
        _noSitesConfigured = false;
      });

      if (!_hasTriggeredInitialInit) {
        _hasTriggeredInitialInit = true;
        _startDynamicInitialization();
      }

      if (!_isOptimizing) {
        _optimizeBestSource(newlyFound);
      }
    }

    if (mounted) setState(() => _isSearching = false);
  }

  /// 动态轮询初始化：等待最佳时机启动播放器
  Future<void> _startDynamicInitialization() async {
    int tick = 0;
    const int maxTicks = 20; // 约 4 秒

    while (tick < maxTicks) {
      if (!mounted || _isPlaying) return;

      final bool hasHighQualitySource = _scoreMap.values.any((score) => score >= 90);
      final bool hasEnoughSamples = _testedSources.length >= 3 || _testedSources.length == _availableSources.length;
      final bool isSearchDone = !_isSearching;

      if (hasHighQualitySource || (isSearchDone && hasEnoughSamples) || tick >= 15) {
        break;
      }

      await Future.delayed(const Duration(milliseconds: 200));
      tick++;
    }

    if (mounted && _availableSources.isNotEmpty && !_isPlaying) {
      setState(() {
        _loadingStage = LoadingStage.preferring;
        _loadingMessage = '⚡ 正在优选最佳线路...';
      });

      final optimizer = ref.read(sourceOptimizerServiceProvider);
      final result = await optimizer.selectBestSource(_availableSources, cachedQualityInfo: _qualityInfoMap);
      
      if (mounted) {
        VideoDetail best = result.bestSource;
        setState(() {
          _currentSource = best;
          _qualityInfoMap.addAll(result.qualityInfoMap);
          _scoreMap.addAll(result.scoreMap);
          _loadingStage = LoadingStage.fetching;
          _loadingMessage = '🎬 正在准备播放...';
        });

        // 异步抓取更完整的详情（如完整播放列表），不阻塞 UI 但确保播放前数据最新
        await _fetchFullDetail(best);
        
        _loadSkipConfig();
        _handlePlayAction(_currentEpisodeIndex, resumePosition: _initialResumePosition);
      }
    }
  }

  Future<void> _optimizeBestSource(List<VideoDetail> sources) async {
    if (sources.isEmpty || _isOptimizing) return;
    setState(() => _isOptimizing = true);
    
    final qualityService = ref.read(videoQualityServiceProvider);
    final List<VideoDetail> queue = List.from(sources);
    int currentIndex = 0;
    const int maxConcurrent = 3;

    Future<void> worker() async {
      while (currentIndex < queue.length) {
        final source = queue[currentIndex++];
        final key = '${source.source}-${source.id}';
        if (_qualityInfoMap.containsKey(key) && !_qualityInfoMap[key]!.hasError) continue;
        
        try {
          final url = source.playGroups.first.urls.length > 1 ? source.playGroups.first.urls[1] : source.playGroups.first.urls[0];
          final quality = await qualityService.detectQuality(url);
                      if (mounted) {
                        setState(() {
                          _qualityInfoMap[key] = quality;
                          _testedSources.add(key);
                        });
                        // 移除 _applyIncrementalOptimization()，不再自动纠偏
                      }        } catch (e) {}
      }
    }

    await Future.wait(List.generate(queue.length < maxConcurrent ? queue.length : maxConcurrent, (_) => worker()));
    if (mounted) setState(() => _isOptimizing = false);
  }

  void _applyIncrementalOptimization() async {
    // 仅更新测速数据，不再自动更新 _currentSource
    if (!mounted) return;
    final optimizer = ref.read(sourceOptimizerServiceProvider);
    final result = await optimizer.selectBestSource(_availableSources, cachedQualityInfo: _qualityInfoMap);
    
    if (mounted) {
      setState(() {
        _qualityInfoMap.addAll(result.qualityInfoMap);
        _scoreMap.addAll(result.scoreMap);
      });
    }
  }

  void _handlePlayAction(int index, {double? resumePosition}) {
    if (_currentSource == null) return;
    setState(() {
      // 如果外部传入了 resumePosition 则使用，否则尝试沿用之前的（用于自动恢复）
      _initialResumePosition = resumePosition ?? _initialResumePosition;
      _currentEpisodeIndex = index;
    });
  }

  Future<void> _switchSource(VideoDetail newSource) async {
    setState(() {
      _currentSource = newSource;
    });
    
    // 异步尝试获取更完整的详情（如播放列表），不阻塞主线程切换
    _fetchFullDetail(newSource);

    _loadSkipConfig();
    final targetIndex = _currentEpisodeIndex >= newSource.playGroups.first.urls.length ? 0 : _currentEpisodeIndex;
    _handlePlayAction(targetIndex);
  }

  void _loadSkipConfig() async {
    if (_currentSource == null) return;
    final key = '${_currentSource!.source}-${_currentSource!.id}';
    final config = await ref.read(configServiceProvider).getSkipConfigs();
    if (mounted && config.containsKey(key)) {
      setState(() {
        _skipConfig = config[key]!;
      });
    }
  }

  Future<void> _fetchFullDetail(VideoDetail partial) async {
    try {
      final cmsService = ref.read(cmsServiceProvider);
      final configService = ref.read(configServiceProvider);
      final site = await configService.getPrimarySite();

      final fullDetail = await cmsService.getDetail(site, partial.id);
      if (fullDetail != null && mounted && _currentSource?.id == partial.id) {
        setState(() {
          _currentSource = fullDetail;
          // 同步更新缓存列表
          final idx = _availableSources.indexWhere((s) => s.id == partial.id && s.source == partial.source);
          if (idx != -1) _availableSources[idx] = fullDetail;
        });
      }
    } catch (_) {}
  }

  void _playNextEpisode() {
    if (_currentSource == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex < _currentSource!.playGroups.first.urls.length) {
      _handlePlayAction(nextIndex);
    }
  }

  Future<void> _savePlayRecord(Duration position, Duration duration, {bool isFinal = false}) async {
    if (_currentSource == null || !mounted) return;
    
    // 只有在进度有实际变化（大于0）或者为了保存最后进度时才记录
    if (position.inSeconds == 0 && duration.inSeconds == 0) return;

    // 如果不是强制保存（isFinal），则每 10 秒保存一次
    if (!isFinal && position.inSeconds % 10 != 0) return;

    final record = PlayRecord(
      title: widget.subject.title,
      sourceName: _currentSource!.sourceName,
      cover: widget.subject.cover,
      year: widget.subject.year ?? '',
      index: _currentEpisodeIndex,
      totalEpisodes: _currentSource!.playGroups.first.urls.length,
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
    if (_currentSource == null) {
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

    final group = _currentSource!.playGroups.first;
    return EchoVideoPlayer(
      key: _playerKey,
      url: group.urls[_currentEpisodeIndex],
      title: '${widget.subject.title} - ${group.titles[_currentEpisodeIndex]}',
      referer: '',
      initialPosition: _initialResumePosition,
      skipConfig: _skipConfig,
      onSkipConfigChange: (newConfig) async {
        final key = '${_currentSource!.source}-${_currentSource!.id}';
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
        _buildSourceRow(theme),
        _buildSourceChain(theme),
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
    final desc = _fullSubject?.description ??
        widget.subject.description ??
        _currentSource?.desc;
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

  Widget _buildSourceRow(ThemeData theme) {
    final n = _currentSource?.playGroups.first.urls.length ?? 0;
    final info = _currentSource == null
        ? (_isSearching ? '正在搜索…' : '暂无资源')
        : '共 $n 集';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          const Text('来源',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text(info,
              style:
                  TextStyle(fontSize: 12, color: theme.colorScheme.secondary)),
          Icon(Icons.chevron_right,
              size: 16, color: theme.colorScheme.secondary),
        ],
      ),
    );
  }

  Widget _buildSourceChain(ThemeData theme) {
    if (_availableSources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(_isSearching ? '正在全网搜索源站…' : '暂无可用源站',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary)),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          for (var i = 0; i < _availableSources.length; i++) ...[
            _buildSourceSegment(theme, _availableSources[i]),
            if (i != _availableSources.length - 1) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceSegment(ThemeData theme, VideoDetail res) {
    final selected = res == _currentSource;
    final n = res.playGroups.first.urls.length;
    return GestureDetector(
      onTap: () => _switchSource(res),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.pinkLight
                  : theme.colorScheme.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? AppColors.pink : Colors.transparent,
                width: 1.2,
              ),
            ),
            child: Text(
              res.sourceName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.pink : theme.colorScheme.onSurface,
              ),
            ),
          ),
          Positioned(
            top: -6,
            right: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('$n',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeHeader(ThemeData theme) {
    if (_currentSource == null) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Text('选集',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
    );
  }

  Widget _buildEpisodeChips(ThemeData theme) {
    if (_currentSource == null) return const SizedBox.shrink();
    final group = _currentSource!.playGroups.first;
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
