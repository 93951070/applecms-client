import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../widgets/zen_ui.dart';
import '../models/movie.dart';
import '../models/site.dart';
import 'video_detail.dart';

class ExplorePage extends ConsumerStatefulWidget {
  final String title;
  final String type;

  const ExplorePage({super.key, required this.title, required this.type});

  @override
  ConsumerState<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends ConsumerState<ExplorePage> {
  List<DoubanSubject> movies = [];
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasMore = true;
  int currentPage = 0;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 500) {
      if (!isLoadingMore && hasMore) {
        _loadMoreData();
      }
    }
  }

  Future<void> _loadData() async {
    if (isLoading) return;

    setState(() {
      isLoading = true;
      movies = [];
      currentPage = 0;
      hasMore = true;
    });

    final data = await _loadPage(0);

    if (mounted) {
      setState(() {
        movies = data;
        isLoading = false;
        hasMore = data.isNotEmpty;
      });
    }
  }

  Future<void> _loadMoreData() async {
    if (isLoadingMore || !hasMore) return;

    setState(() {
      isLoadingMore = true;
    });

    final nextPage = currentPage + 1;
    final data = await _loadPage(nextPage);

    if (mounted) {
      setState(() {
        if (data.isNotEmpty) {
          movies.addAll(data);
          currentPage = nextPage;
          hasMore = data.isNotEmpty;
        } else {
          hasMore = false;
        }
        isLoadingMore = false;
      });
    }
  }

  /// 当前分区的顶级分类 ID：movie=1, tv=2, anime=3, show=4
  int? _categoryId() {
    switch (widget.type) {
      case 'movie':
        return 1;
      case 'tv':
        return 2;
      case 'anime':
        return 3;
      case 'show':
        return 4;
      default:
        return null;
    }
  }

  Future<List<DoubanSubject>> _loadPage(int page) async {
    final typeId = _categoryId();
    if (typeId == null) {
      return [];
    }
    final config = ref.read(configServiceProvider);
    final cms = ref.read(cmsServiceProvider);
    final site = await config.getPrimarySite();
    final list = await cms.getCategoryList(site, typeId, page: page + 1, pageSize: 24);
    return list.map(_toSubject).toList();
  }

  /// 将 CMS 的 VideoDetail 桥接为页面展示用的 DoubanSubject
  DoubanSubject _toSubject(VideoDetail d) {
    return DoubanSubject(
      id: d.id,
      title: d.title,
      rate: '0.0',
      cover: d.poster,
      year: d.year,
      description: d.desc,
    );
  }

  void _handleMovieTap(BuildContext context, DoubanSubject movie) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (context) => VideoDetailPage(subject: movie),
    ));
  }

  @override
  Widget build(BuildContext context) {
    const gridSpacing = 16.0;
    const posterAspectRatio = 0.53;

    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = screenWidth > 800 ? 48.0 : 24.0;
    final availableWidth = screenWidth - 2 * horizontalPadding;
    final isPC = screenWidth > 800;

    // 根据屏幕宽度决定列数
    final crossAxisCount = availableWidth > 600
        ? 4  // 平板/大屏手机
        : availableWidth > 400
            ? 3  // 普通手机横屏/大屏手机
            : 2; // 小屏手机

    return ZenScaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          ZenSliverAppBar(
            title: widget.title,
            subtitle: '来自我的视频库',
            actions: [
              if (!isPC) ...[
                IconButton(
                  onPressed: () => context.push('/search'),
                  icon: const Icon(LucideIcons.search, size: 20),
                ),
                IconButton(
                  onPressed: () => context.push('/settings'),
                  icon: const Icon(LucideIcons.settings, size: 20),
                ),
              ],
            ],
          ),

          if (isLoading)
            // 骨架屏幕
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: gridSpacing,
                  mainAxisSpacing: 24,
                  childAspectRatio: posterAspectRatio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildSkeletonCard(Theme.of(context)),
                  childCount: 12, // 显示 12 个骨架卡片
                ),
              ),
            )
          else if (movies.isEmpty)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(48.0),
                  child: Text('暂无内容', style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: gridSpacing,
                  mainAxisSpacing: 24,
                  childAspectRatio: posterAspectRatio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => MovieCard(
                    movie: movies[index],
                    onTap: () => _handleMovieTap(context, movies[index]),
                  ),
                  childCount: movies.length,
                ),
              ),
            ),

          if (isLoadingMore)
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),

          if (!hasMore && movies.isNotEmpty)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Text('已加载全部内容', style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  /// 构建骨架卡片
  Widget _buildSkeletonCard(ThemeData theme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: -2.0, end: 2.0),
      duration: const Duration(milliseconds: 1500),
      builder: (context, value, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              ],
              stops: [
                (value - 1).clamp(0.0, 1.0),
                value.clamp(0.0, 1.0),
                (value + 1).clamp(0.0, 1.0),
              ],
            ).createShader(bounds);
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 骨架图片
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                  ),
                ),
                // 骨架文本
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 12,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 10,
                        width: 60,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
      onEnd: () {
        // 动画结束后重新开始
        if (mounted) {
          setState(() {});
        }
      },
    );
  }
}
