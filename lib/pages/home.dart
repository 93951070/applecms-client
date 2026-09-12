import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../providers/history_provider.dart';
import '../providers/auth_provider.dart';
import '../models/movie.dart';
import '../models/site.dart';
import '../core/content_kind.dart';
import '../core/theme.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/cover_image.dart';
import 'short_drama_feed.dart';
import 'video_detail.dart';

/// 按分类拉取 CMS 列表（1电影 / 2电视剧 / 3动漫 / 4综艺）
final cmsCategoryProvider =
    FutureProvider.family<List<VideoDetail>, int>((ref, typeId) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryList(site, typeId, page: 1, pageSize: 18);
});

/// 站点真实分类树（主分类 + 子分类）
final categoryTreeProvider =
    FutureProvider<List<CmsCategoryGroup>>((ref) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryTree(site);
});

/// 无法取得分类树时的兜底分类（与后端默认数据一致）
const _fallbackGroups = defaultCategoryGroups;

/// 将 CMS 的 VideoDetail 桥接为展示用的 DoubanSubject
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

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _mainIndex = 0;
  int _heroPage = 0;

  bool _continueVisible = false;
  bool _continueScheduled = false;
  bool _continueDismissed = false;
  Timer? _continueTimer;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _continueTimer?.cancel();
    super.dispose();
  }

  void _openDetail(VideoDetail video) {
    if (isFeedCategory(typeId: video.typeId, typeName: video.typeName)) {
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
        builder: (context) => ShortDramaFeedPage(
          typeId: video.typeId,
          categoryTitle: video.typeName ?? '短剧',
          initial: video,
        ),
      ));
      return;
    }
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (context) => VideoDetailPage(subject: _toSubject(video)),
    ));
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
    final groups = (treeAsync.value ?? const <CmsCategoryGroup>[]).isNotEmpty
        ? treeAsync.value!
        : _fallbackGroups;

    final mainIndex = _mainIndex > groups.length ? 0 : _mainIndex;
    final recommend = mainIndex == 0;
    final group = recommend ? null : groups[mainIndex - 1];

    final mainTabs = <String>[
      '推荐',
      ...groups.map((g) => g.category.typeName),
    ];

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTopBar(),
                AppTabStrip(
                  tabs: mainTabs,
                  current: mainIndex,
                  onChanged: (i) => setState(() {
                    _mainIndex = i;
                    _heroPage = 0;
                  }),
                ),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.pink,
                    onRefresh: () async {
                      ref.invalidate(categoryTreeProvider);
                      ref.invalidate(cmsCategoryProvider);
                    },
                    child: recommend
                        ? _buildRecommend(groups)
                        : _buildCategorySections(group!),
                  ),
                ),
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
                final baseUrl = ref.watch(apiBaseUrlProvider).maybeWhen(
                      data: (v) => v,
                      orElse: () => '',
                    );
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
                          errorBuilder: (_, __, ___) => const Icon(Icons.pets,
                              size: 17, color: Colors.white),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(Icons.search,
                        size: 16,
                        color: Theme.of(context).colorScheme.secondary),
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
            child: Icon(Icons.history,
                size: 21,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ],
      ),
    );
  }

  Widget _buildContinue(PlayRecord record) {
    return ContinueBar(
      text: '继续观看：${record.title} 第 ${record.index + 1} 集',
      onTap: () {
        final subject = DoubanSubject(
          id: record.doubanId ?? '',
          title: record.searchTitle,
          rate: '0.0',
          cover: record.cover,
          year: record.year,
        );
        Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
          builder: (context) => VideoDetailPage(subject: subject),
        ));
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

  // ==================== 推荐页 ====================

  /// 推荐：精品推荐 + 各主分类推荐栏目
  Widget _buildRecommend(List<CmsCategoryGroup> groups) {
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
              '${g.category.typeName}推荐', g.category.typeId);
        }
        final g = groups[i];
        return _categorySection('${g.category.typeName}推荐', g.category.typeId);
      },
    );
  }

  Widget _heroSection(int typeId) {
    return Consumer(
      builder: (context, ref, _) {
        final async = ref.watch(cmsCategoryProvider(typeId));
        return async.maybeWhen(
          data: (list) => _buildHero(list),
          orElse: () => const SizedBox.shrink(),
        );
      },
    );
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
                if (item.poster.isNotEmpty)
                  CoverImage(imageUrl: item.poster, aspectRatio: 1.9)
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
                          shadows: [Shadow(blurRadius: 10, color: Colors.black54)],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (item.typeName != null) item.typeName!,
                          if (item.year != null && item.year!.isNotEmpty)
                            item.year!,
                        ].join(' · '),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11,
                        ),
                      ),
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
          Icon(Icons.cloud_off,
              size: 44,
              color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 12),
          Center(
            child: Text('加载失败，下拉重试',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary)),
          ),
        ],
      ),
      data: (list) {
        if (list.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 120),
            children: [
              Icon(Icons.inbox_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.secondary),
              const SizedBox(height: 12),
              Center(
                child: Text('暂无内容',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary)),
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
          itemBuilder: (context, i) => _GridCard(
            video: list[i],
            onTap: () => _openDetail(list[i]),
          ),
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
              color:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
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
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }
}
