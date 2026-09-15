import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../core/video_router.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/page_flip.dart';
import 'home.dart';

/// 排行榜数据：按每日热度（vod_hits_day）由服务端真实排序。
final _rankProvider =
    FutureProvider.family<List<VideoDetail>, int>((ref, typeId) async {
  final config = ref.read(configServiceProvider);
  final cms = ref.read(cmsServiceProvider);
  final site = await config.getPrimarySite();
  if (site.disabled) return [];
  return cms.getCategoryList(
    site,
    typeId,
    page: 1,
    pageSize: 50,
    sort: 'day',
  );
});

/// 排行榜：分类 Tab + Top 榜单列表（数据来自 CMS）
class RankPage extends ConsumerStatefulWidget {
  const RankPage({super.key});

  @override
  ConsumerState<RankPage> createState() => _RankPageState();
}

class _RankPageState extends ConsumerState<RankPage> {
  int _tab = 0;
  late final PageController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = PageController(initialPage: _tab);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 切换榜单分类：与首页分类共用同一套 3D 翻页转场。
  void _selectTab(int i, {bool animate = true}) {
    if (i == _tab) return;
    setState(() => _tab = i);
    if (animate && _tabController.hasClients) {
      _tabController.animateToPage(
        i,
        duration: FlipConfig.duration,
        curve: FlipConfig.curve,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(categoryTreeProvider);
    final groups = (treeAsync.value ?? const <CmsCategoryGroup>[]).isNotEmpty
        ? treeAsync.value!
        : defaultCategoryGroups;

    final mainIndex = _tab > groups.length - 1 ? 0 : _tab;

    final tabs = groups.map((g) => g.category.typeName).toList();

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(
                '排行榜',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            AppTabStrip(
              tabs: tabs,
              current: mainIndex,
              onChanged: (i) => _selectTab(i),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
              child: Text(
                '根据每日热度实时更新',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
            Expanded(
              child: FlipPageView(
                controller: _tabController,
                itemCount: groups.length,
                onPageChanged: (i) => _selectTab(i, animate: false),
                itemBuilder: (context, i) =>
                    _RankList(typeId: groups[i].category.typeId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个榜单分类的列表（每个分类各自订阅自己的榜单数据）。
class _RankList extends ConsumerWidget {
  const _RankList({required this.typeId});

  final int typeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(_rankProvider(typeId)).when(
          data: (list) => list.isEmpty
              ? const _RankEmpty()
              : RefreshIndicator(
                  color: AppColors.pink,
                  onRefresh: () async {
                    ref.invalidate(_rankProvider(typeId));
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (context, i) => _RankItem(
                      no: i + 1,
                      video: list[i],
                      onTap: () => VideoRouter.open(context, list[i]),
                    ),
                  ),
                ),
          loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.pink),
          ),
          error: (e, st) => const _RankEmpty(),
        );
  }
}

class _RankEmpty extends StatelessWidget {
  const _RankEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined,
              size: 44, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 12),
          Text(
            '暂无数据，请检查视频源配置',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RankItem extends StatelessWidget {
  const _RankItem({
    required this.no,
    required this.video,
    required this.onTap,
  });

  final int no;
  final VideoDetail video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final top = no <= 3;
    final subtitle = [
      if (video.year != null && video.year!.isNotEmpty) video.year!,
      if (video.typeName != null) video.typeName!,
    ].join(' / ');

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Padding(
                padding: const EdgeInsets.only(top: 34),
                child: Text(
                  '$no',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    color: top ? AppColors.pink : const Color(0xFFC9C9CE),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            PosterCard(
              imageUrl: video.poster,
              title: video.title,
              width: 76,
              height: 104,
              titleFontSize: 11,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      (video.desc == null || video.desc!.isEmpty)
                          ? '暂无介绍'
                          : video.desc!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
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
}
