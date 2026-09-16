import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../providers/auth_provider.dart';
import '../models/site.dart';
import '../core/video_router.dart';
import '../core/content_kind.dart';
import '../core/theme.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/cover_image.dart';
import '../widgets/page_flip.dart';

/// 按分类拉取 CMS 列表（1电影 / 2电视剧 / 3动漫 / 4综艺）
final cmsCategoryProvider = FutureProvider.family<List<VideoDetail>, int>((
  ref,
  typeId,
) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final sub = cms.listUpdates.listen((key) {
    if (key == 'cat:$typeId:1:18:') ref.invalidateSelf();
  });
  ref.onDispose(sub.cancel);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryList(site, typeId, page: 1, pageSize: 18);
});

/// 站点真实分类树（主分类 + 子分类）
final categoryTreeProvider = FutureProvider<List<CmsCategoryGroup>>((
  ref,
) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final sub = cms.listUpdates.listen((key) {
    if (key == 'tree') ref.invalidateSelf();
  });
  ref.onDispose(sub.cancel);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryTree(site);
});

/// 首页聚合：一次返回幻灯片与各主分类栏目，首屏只需一次请求。
final homeFeedProvider = FutureProvider<HomeFeed?>((ref) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return null;
  final tree = await ref.watch(categoryTreeProvider.future);
  final groups = tree
      .where(
        (g) => !isFeedCategory(
          typeId: g.category.typeId,
          typeName: g.category.typeName,
        ),
      )
      .toList();
  final ids = groups.map((g) => g.category.typeId).toList();
  if (ids.isEmpty) return null;
  final sub = cms.listUpdates.listen((key) {
    if (key.startsWith('home:')) ref.invalidateSelf();
  });
  ref.onDispose(sub.cancel);
  return cms.getHomeFeed(site, ids, limit: 18, heroLimit: 6);
});

/// 无法取得分类树时的兜底分类（与后端默认数据一致）
const _fallbackGroups = defaultCategoryGroups;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _mainIndex = 0;
  int _heroPage = 0;

  /// 分类翻页（推荐 + 各主分类），横向滑动与点击 Tab 都作用在它上面。
  late final PageController _catController;

  /// 分类页总数（推荐 + 各主分类），用于翻页越界保护。
  int _catPageCount = 1;

  /// 内层横向滚动（分类 Tab 栏、海报行）到尽头后继续拖动的累计位移，
  /// 抬手时据此决定是否翻到上/下一个分类。
  double _catSwipeDrag = 0;

  /// 判定翻分类所需的额外拖动距离（逻辑像素）。
  static const double _catSwipeThreshold = 48;

  bool _continueVisible = false;
  bool _continueScheduled = false;
  bool _continueDismissed = false;
  Timer? _continueTimer;

  Timer? _heroTimer;
  int _heroCount = 0;

  /// 幻灯片横版图缓存（key 为视频 id，值为后端豆瓣图片代理地址）。
  final Map<String, String> _heroSlides = {};
  final Set<String> _heroSlideLoading = {};

  /// 幻灯片豆瓣简介缓存：列表接口只给短简介，豆瓣简介更完整。
  final Map<String, String> _heroBlurbs = {};

  /// 豆瓣年份缓存：列表里的年份可能是采集源的占位值，豆瓣更准。
  final Map<String, String> _heroYears = {};

  /// 已拉取过豆瓣信息的条目，避免同一部剧反复请求。
  final Set<String> _heroFetched = {};

  @override
  void initState() {
    super.initState();
    _catController = PageController(initialPage: _mainIndex);
  }

  @override
  void dispose() {
    _catController.dispose();
    _continueTimer?.cancel();
    _heroTimer?.cancel();
    super.dispose();
  }

  /// 切到指定分类页：Tab 点击与横向滑动共用同一套 3D 翻页转场。
  void _selectCategory(int i, {bool animate = true}) {
    if (i < 0 || i >= _catPageCount || i == _mainIndex) return;
    setState(() {
      _mainIndex = i;
      _heroPage = 0;
    });
    if (animate && _catController.hasClients) {
      _catController.animateToPage(
        i,
        duration: FlipConfig.duration,
        curve: FlipConfig.curve,
      );
    }
  }

  /// 横向手势接力：分类 Tab 栏与海报行本身都是横向可滚动的，Flutter 的手势
  /// 竞技场会把横滑优先给最内层的滚动，外层翻页器拿不到拖动。这里在它们滚到
  /// 尽头（pixels 越界）后继续累计手指位移，抬手超过阈值就翻一个分类，
  /// 既保住了内容行的横滑浏览，也能用左右侧滑切分类。
  bool _onCategoryScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.horizontal) return false;

    if (n is ScrollStartNotification && n.dragDetails != null) {
      _catSwipeDrag = 0;
      return false;
    }

    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final m = n.metrics;
      if (m.pixels > m.maxScrollExtent || m.pixels < m.minScrollExtent) {
        // 手指左滑（dx 为负）表示要往后翻，与内容行滚动的方向一致。
        _catSwipeDrag += n.dragDetails!.delta.dx;
      }
      return false;
    }

    if (n is ScrollEndNotification) {
      final drag = _catSwipeDrag;
      _catSwipeDrag = 0;
      if (drag == 0) return false;
      final velocity = n.dragDetails?.velocity.pixelsPerSecond.dx ?? 0;
      if (drag <= -_catSwipeThreshold || (drag < 0 && velocity <= -400)) {
        _selectCategory(_mainIndex + 1);
      } else if (drag >= _catSwipeThreshold || (drag > 0 && velocity >= 400)) {
        _selectCategory(_mainIndex - 1);
      }
      return false;
    }

    return false;
  }

  /// 按需拉取当前幻灯片的豆瓣信息：横版剧照 + 简介 + 年份，失败时保持原样。
  Future<void> _loadHeroSlide(VideoDetail item) async {
    final id = item.id.trim();
    if (id.isEmpty ||
        _heroFetched.contains(id) ||
        _heroSlideLoading.contains(id)) {
      return;
    }
    _heroSlideLoading.add(id);
    try {
      final base = await ref.read(configServiceProvider).getApiBaseUrl();
      final media = await ref.read(cmsServiceProvider).fetchDouban(id);
      if (!mounted) return;
      _heroFetched.add(id);
      final slide = (media?.slide ?? '').trim();
      final intro = (media?.intro ?? '').trim();
      final year = (media?.year ?? '').trim();
      setState(() {
        _heroBlurbs[id] = intro;
        if (year.isNotEmpty) _heroYears[id] = year;
        if (slide.isNotEmpty) {
          _heroSlides[id] =
              '$base/api/douban/image?u=${Uri.encodeQueryComponent(slide)}';
        }
      });
    } catch (_) {
      // 忽略：保持竖版海报
    } finally {
      _heroSlideLoading.remove(id);
    }
  }

  /// 幻灯片自动轮播：数据就绪后每 5 秒切到下一张，手动点圆点后会重置节奏
  void _startHeroAutoPlay(int count) {
    if (count <= 1) {
      _heroTimer?.cancel();
      _heroTimer = null;
      _heroCount = count;
      return;
    }
    if (_heroTimer != null && _heroCount == count) return;
    _heroCount = count;
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _heroCount <= 1) return;
      setState(() => _heroPage = (_heroPage + 1) % _heroCount);
    });
  }

  void _openDetail(VideoDetail video) {
    VideoRouter.open(context, video);
  }

  /// 观看记录首次出现时，底部浮出「继续观看」条，3 秒不点自动消失
  void _maybeScheduleContinue(List<PlayRecord> list) {
    if (list.isEmpty || _continueScheduled || _continueDismissed) return;
    _continueScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _continueVisible = true);
      _continueTimer?.cancel();
      _continueTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _continueVisible = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider);
    final historyList = history.value ?? const <PlayRecord>[];
    _maybeScheduleContinue(historyList);

    final treeAsync = ref.watch(categoryTreeProvider);
    final allGroups = (treeAsync.value ?? const <CmsCategoryGroup>[]).isNotEmpty
        ? treeAsync.value!
        : _fallbackGroups;
    final groups = allGroups
        .where(
          (g) => !isFeedCategory(
            typeId: g.category.typeId,
            typeName: g.category.typeName,
          ),
        )
        .toList();

    final mainIndex = _mainIndex > groups.length ? 0 : _mainIndex;
    // 分类树变化可能让当前页越界，回到推荐页并同步翻页器。
    if (mainIndex != _mainIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _mainIndex = mainIndex);
        if (_catController.hasClients) _catController.jumpToPage(mainIndex);
      });
    }

    final mainTabs = <String>['推荐', ...groups.map((g) => g.category.typeName)];
    _catPageCount = mainTabs.length;

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onCategoryScrollNotification,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTopBar(),
                  AppTabStrip(
                    tabs: mainTabs,
                    current: mainIndex,
                    onChanged: (i) => _selectCategory(i),
                  ),
                  Expanded(child: _buildCategoryPages(groups)),
                ],
              ),
              if (_continueVisible && historyList.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildContinue(historyList.first),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 跳转到某分类的列表页（二级页，不显示底部导航）
  void _pushCategory(int typeId, String title) {
    context.push('/category?id=$typeId&title=${Uri.encodeComponent(title)}');
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.go('/profile'),
            child: Consumer(
              builder: (context, ref, _) {
                final user = ref.watch(authProvider).user;
                final baseUrl = ref
                    .watch(apiBaseUrlProvider)
                    .maybeWhen(data: (v) => v, orElse: () => '');
                final portrait = absoluteMediaUrl(baseUrl, user?.portrait);
                return Container(
                  width: 34,
                  height: 34,
                  clipBehavior: Clip.antiAlias,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFA8C0FF), Color(0xFFFF9AE0)],
                    ),
                  ),
                  child: portrait.isNotEmpty
                      ? Image.network(
                          portrait,
                          width: 34,
                          height: 34,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.pets,
                            size: 17,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.pets, size: 17, color: Colors.white),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => context.push('/search'),
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(
                      Icons.search,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '搜索影视资源',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => context.push('/history'),
            child: Icon(
              Icons.history,
              size: 21,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinue(PlayRecord record) {
    return ContinueBar(
      text: '继续观看：${record.title} 第 ${record.index + 1} 集',
      onTap: () {
        VideoRouter.openByTitle(
          context,
          ref,
          title: record.searchTitle,
          cover: record.cover,
          year: record.year,
          subjectId: record.doubanId,
        );
      },
      onClose: () {
        _continueTimer?.cancel();
        setState(() {
          _continueVisible = false;
          _continueDismissed = true;
        });
      },
    );
  }

  /// 分类翻页容器：顶部 Tab 点击或内容区横向滑动时，整块分类内容做 3D 翻页。
  ///
  /// 第 0 页是推荐，第 i 页对应 `groups[i - 1]`；翻页器与 [AppTabStrip] 双向同步。
  Widget _buildCategoryPages(List<CmsCategoryGroup> groups) {
    return FlipPageView(
      controller: _catController,
      itemCount: groups.length + 1,
      onPageChanged: (i) => _selectCategory(i, animate: false),
      itemBuilder: (context, i) {
        final isRecommend = i == 0;
        return RefreshIndicator(
          color: AppColors.pink,
          onRefresh: () async {
            ref.invalidate(categoryTreeProvider);
            ref.invalidate(cmsCategoryProvider);
            ref.invalidate(homeFeedProvider);
          },
          child: isRecommend
              ? _buildRecommend(groups)
              : _buildCategorySections(groups[i - 1]),
        );
      },
    );
  }

  // ==================== 推荐页 ====================

  /// 推荐：优先使用首屏聚合数据（幻灯片 + 差异化栏目）；不可用时回退旧逻辑
  Widget _buildRecommend(List<CmsCategoryGroup> groups) {
    final feed = ref.watch(homeFeedProvider).value;
    if (feed != null &&
        feed.hero.isNotEmpty &&
        feed.sections.any((s) => s.items.isNotEmpty)) {
      return _buildRecommendFromFeed(feed);
    }
    final first = groups.isNotEmpty ? groups.first : null;
    final extra = first == null ? 0 : 2;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: extra + groups.length,
      itemBuilder: (context, i) {
        if (first != null) {
          if (i == 0) return _heroSection(first.category.typeId);
          if (i == 1) return _categorySection('精品推荐', first.category.typeId);
          final g = groups[i - 2];
          return _categorySection(
            '${g.category.typeName}推荐',
            g.category.typeId,
          );
        }
        final g = groups[i];
        return _categorySection('${g.category.typeName}推荐', g.category.typeId);
      },
    );
  }

  /// 用聚合数据渲染推荐页：幻灯片 + 精品推荐（跨栏混合）+ 各分类推荐
  Widget _buildRecommendFromFeed(HomeFeed feed) {
    final heroItems = feed.hero.take(5).toList();

    // 精品推荐：逐层取各栏目条目轮询混合，跨栏去重，与下方分类栏目互补
    final picks = <VideoDetail>[];
    final pickIds = <String>{};
    const depth = 3;
    for (var d = 0; d < depth; d++) {
      for (final s in feed.sections) {
        if (d < s.items.length) {
          final v = s.items[d];
          if (pickIds.add('${v.source}:${v.id}')) picks.add(v);
        }
      }
    }
    final jingpin = picks.take(18).toList();

    final sections = feed.sections
        .map(
          (s) => HomeSection(
            typeId: s.typeId,
            title: s.title,
            items: s.items
                .where((v) => !pickIds.contains('${v.source}:${v.id}'))
                .toList(),
          ),
        )
        .where((s) => s.items.isNotEmpty)
        .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (heroItems.isNotEmpty) _heroFromList(heroItems),
        if (jingpin.isNotEmpty && feed.sections.isNotEmpty)
          _buildSection(
            title: '精品推荐',
            icon: Icons.local_fire_department,
            videos: jingpin,
            onMore: () => _pushCategory(feed.sections.first.typeId, '精品推荐'),
          ),
        ...sections.map(
          (s) => _buildSection(
            title: '${s.title}推荐',
            icon: Icons.local_fire_department,
            videos: s.items,
            onMore: () => _pushCategory(s.typeId, '${s.title}推荐'),
          ),
        ),
      ],
    );
  }

  Widget _heroSection(int typeId) {
    return Consumer(
      builder: (context, ref, _) {
        final async = ref.watch(cmsCategoryProvider(typeId));
        return async.maybeWhen(
          skipLoadingOnReload: true,
          data: (list) => _heroFromList(list),
          orElse: () => const SizedBox.shrink(),
        );
      },
    );
  }

  /// 幻灯片：传入列表，自动轮播并懒加载横版图
  Widget _heroFromList(List<VideoDetail> list) {
    final count = list.length > 5 ? 5 : list.length;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _startHeroAutoPlay(count),
    );
    return _buildHero(list);
  }

  /// 分类页：按子分类自动加载栏目（子分类即栏目，而不是筛选）
  Widget _buildCategorySections(CmsCategoryGroup group) {
    final subs = group.subCategories;
    if (subs.isEmpty) {
      return Consumer(
        builder: (context, ref, _) {
          final async = ref.watch(cmsCategoryProvider(group.category.typeId));
          return _buildCategoryGrid(async);
        },
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: subs.length,
      itemBuilder: (context, i) =>
          _categorySection(subs[i].typeName, subs[i].typeId),
    );
  }

  /// 单个分类栏目：标题 + 横向内容 + 「更多」跳转对应分类
  Widget _categorySection(String title, int typeId) {
    return Consumer(
      builder: (context, ref, _) {
        final async = ref.watch(cmsCategoryProvider(typeId));
        return async.maybeWhen(
          skipLoadingOnReload: true,
          data: (list) => _buildSection(
            title: title,
            icon: Icons.local_fire_department,
            videos: list,
            onMore: () => _pushCategory(typeId, title),
          ),
          orElse: () => _buildSectionSkeleton(),
        );
      },
    );
  }

  Widget _buildHero(List<VideoDetail> list) {
    if (list.isEmpty) return const SizedBox.shrink();
    final items = list.take(5).toList();
    final page = _heroPage.clamp(0, items.length - 1).toInt();
    final item = items[page];
    final slide = (item.heroImage ?? '').trim();
    final heroImage =
        _heroSlides[item.id] ??
        (slide.startsWith('http') ? slide : null) ??
        item.poster;
    final year = (item.year ?? '').trim().isNotEmpty
        ? item.year!.trim()
        : (_heroYears[item.id] ?? '');
    final meta = [
      if ((item.typeName ?? '').trim().isNotEmpty) item.typeName!.trim(),
      if (year.isNotEmpty) year,
    ].join(' · ');
    final blurb = (item.desc ?? '').trim().isNotEmpty
        ? item.desc!.trim()
        : (_heroBlurbs[item.id] ?? '');
    // 缺横版图或缺简介时拉一次豆瓣信息补齐（每个条目只拉一次）。
    if ((item.heroImage ?? '').isEmpty || blurb.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadHeroSlide(item));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GestureDetector(
        onTap: () => _openDetail(item),
        child: Container(
          height: 180,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (heroImage.isNotEmpty)
                  CoverImage(imageUrl: heroImage, aspectRatio: 1.9)
                else
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                      ),
                    ),
                  ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.35, 1.0],
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 26,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          shadows: [
                            Shadow(blurRadius: 10, color: Colors.black54),
                          ],
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (blurb.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          blurb,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: 12,
                            height: 1.35,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  bottom: 10,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(items.length, (i) {
                      final active = i == page;
                      return GestureDetector(
                        onTap: () => setState(() => _heroPage = i),
                        child: Container(
                          width: active ? 14 : 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 2.5),
                          decoration: BoxDecoration(
                            color: active ? Colors.white : Colors.white54,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<VideoDetail> videos,
    required VoidCallback onMore,
  }) {
    if (videos.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          icon: Icon(icon, size: 18, color: AppColors.pink),
          title: title,
          moreText: '更多',
          onMore: onMore,
        ),
        HScroll(
          child: Row(
            children: [
              for (var i = 0; i < videos.length; i++) ...[
                VideoCard(
                  title: videos[i].title,
                  imageUrl: videos[i].poster,
                  year: videos[i].year,
                  episode: videos[i].typeName,
                  heat: videos[i].heat,
                  onTap: () => _openDetail(videos[i]),
                ),
                if (i != videos.length - 1) const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 分类页（网格） ====================

  Widget _buildCategoryGrid(AsyncValue<List<VideoDetail>> async) {
    return async.when(
      loading: () => GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gridDelegate: _gridDelegate(context),
        itemCount: 6,
        itemBuilder: (context, i) => const _GridSkeleton(),
      ),
      error: (e, _) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 120),
        children: [
          Icon(
            Icons.cloud_off,
            size: 44,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '加载失败，下拉重试',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
          ),
        ],
      ),
      data: (list) {
        if (list.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 120),
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 44,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  '暂无内容',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ),
            ],
          );
        }
        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          gridDelegate: _gridDelegate(context),
          itemCount: list.length,
          itemBuilder: (context, i) =>
              _GridCard(video: list[i], onTap: () => _openDetail(list[i])),
        );
      },
    );
  }

  SliverGridDelegate _gridDelegate(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final columns = w >= 600 ? 4 : (w >= 420 ? 3 : 3);
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 10,
      mainAxisSpacing: 14,
      childAspectRatio: 0.58,
    );
  }

  Widget _buildSectionSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            width: 120,
            height: 18,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        HScroll(
          child: Row(
            children: List.generate(
              4,
              (i) => Container(
                width: 104,
                height: 156,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 分类网格卡片（海报自适应格子宽度）
class _GridCard extends StatelessWidget {
  const _GridCard({required this.video, required this.onTap});

  final VideoDetail video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return PosterCard(
            title: video.title,
            imageUrl: video.poster,
            year: video.year,
            width: w,
            height: w * 1.45,
          );
        },
      ),
    );
  }
}

class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return Container(
          width: w,
          height: w * 1.45,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }
}
