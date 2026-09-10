import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../services/update_service.dart';
import '../providers/history_provider.dart';
import '../models/movie.dart';
import '../models/site.dart';
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
  static const _tabs = ['电影', '连续剧', '动漫', '综艺'];
  static const _typeIds = [1, 2, 3, 4];

  int _tab = 0;
  int _heroPage = 0;
  static bool _hasCheckedUpdate = false;

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

  void _openDetail(VideoDetail video) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => VideoDetailPage(subject: _toSubject(video)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final typeId = _typeIds[_tab];
    final current = ref.watch(cmsCategoryProvider(typeId));
    final anime = ref.watch(cmsCategoryProvider(3));
    final history = ref.watch(historyProvider);

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopBar(),
            AppTabStrip(
              tabs: _tabs,
              current: _tab,
              onChanged: (i) => setState(() {
                _tab = i;
                _heroPage = 0;
              }),
            ),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.pink,
                onRefresh: () async {
                  ref.invalidate(cmsCategoryProvider(typeId));
                  ref.invalidate(cmsCategoryProvider(3));
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.only(bottom: 120),
                  children: [
                    history.maybeWhen(
                      data: (list) => _buildContinue(list),
                      orElse: () => const SizedBox.shrink(),
                    ),
                    current.maybeWhen(
                      data: (list) => _buildHero(list),
                      orElse: () => const SizedBox.shrink(),
                    ),
                    current.maybeWhen(
                      data: (list) => _buildSection(
                        title: '热门${_tabs[_tab]}',
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
                ),
              ),
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

  Widget _buildContinue(List<PlayRecord> history) {
    if (history.isEmpty) return const SizedBox.shrink();
    final record = history.first;
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
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
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
