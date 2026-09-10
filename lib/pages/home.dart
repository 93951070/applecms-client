import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../services/update_service.dart';
import '../providers/history_provider.dart';
import '../models/movie.dart';
import '../core/theme.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/cover_image.dart';
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
  static bool _hasCheckedUpdate = false;

  int _mainIndex = 0;
  int _subIndex = 0;
  int _heroPage = 0;

  bool _continueVisible = false;
  bool _continueScheduled = false;
  bool _continueDismissed = false;
  Timer? _continueTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasCheckedUpdate) {
        _hasCheckedUpdate = true;
        UpdateService.checkUpdate(context);
      }
    });
  }

  @override
  void dispose() {
    _continueTimer?.cancel();
    super.dispose();
  }

  void _openDetail(VideoDetail video) {
    Navigator.of(context).push(MaterialPageRoute(
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

    final subs = group?.subCategories ?? const <CmsCategory>[];
    final subIndex = _subIndex > subs.length ? 0 : _subIndex;
    final selectedSub =
        (subs.isNotEmpty && subIndex > 0) ? subs[subIndex - 1] : null;

    final typeId = recommend
        ? groups.first.category.typeId
        : (selectedSub?.typeId ?? group!.category.typeId);

    final mainTabs = <String>[
      '推荐',
      ...groups.map((g) => g.category.typeName),
    ];
    final subTabs = <String>['全部', ...subs.map((s) => s.typeName)];

    final current = ref.watch(cmsCategoryProvider(typeId));
    final anime = ref.watch(cmsCategoryProvider(3));

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
                    _subIndex = 0;
                    _heroPage = 0;
                  }),
                ),
                if (!recommend && subs.isNotEmpty)
                  AppTabStrip(
                    tabs: subTabs,
                    current: subIndex,
                    compact: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    onChanged: (i) => setState(() => _subIndex = i),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.pink,
                    onRefresh: () async {
                      ref.invalidate(categoryTreeProvider);
                      ref.invalidate(cmsCategoryProvider(typeId));
                      if (recommend) ref.invalidate(cmsCategoryProvider(3));
                    },
                    child: recommend
                        ? _buildRecommend(current, anime)
                        : _buildCategoryGrid(current),
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

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.go('/profile'),
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFA8C0FF), Color(0xFFFF9AE0)],
                ),
              ),
              child: const Icon(Icons.pets, size: 17, color: Colors.white),
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
            onTap: () => context.push('/search'),
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
        Navigator.of(context).push(MaterialPageRoute(
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

  Widget _buildRecommend(
    AsyncValue<List<VideoDetail>> current,
    AsyncValue<List<VideoDetail>> anime,
  ) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        current.maybeWhen(
          data: (list) => _buildHero(list),
          orElse: () => const SizedBox.shrink(),
        ),
        current.maybeWhen(
          data: (list) => _buildSection(
            title: '精品推荐',
            icon: Icons.local_fire_department,
            videos: list,
          ),
          orElse: () => _buildSectionSkeleton(),
        ),
        anime.maybeWhen(
          data: (list) => _buildSection(
            title: '次元世界',
            icon: Icons.auto_awesome,
            videos: list,
          ),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
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
  }) {
    if (videos.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          icon: Icon(icon, size: 18, color: AppColors.pink),
          title: title,
          moreText: '更多',
          onMore: () => context.push('/search'),
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
