import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/video_router.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/zen_ui.dart';

/// 分类列表页：按 type_id 展示网格，点击进入详情（二级页，不显示底部导航）
class CategoryListPage extends ConsumerStatefulWidget {
  final int typeId;
  final String title;

  const CategoryListPage({
    super.key,
    required this.typeId,
    required this.title,
  });

  @override
  ConsumerState<CategoryListPage> createState() => _CategoryListPageState();
}

class _CategoryListPageState extends ConsumerState<CategoryListPage> {
  final List<VideoDetail> _items = [];
  final ScrollController _scroll = ScrollController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _items.clear();
      _page = 0;
      _hasMore = true;
    });
    final data = await _fetch(0);
    if (!mounted) return;
    setState(() {
      _items.addAll(data);
      _loading = false;
      _hasMore = data.length >= 24;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final data = await _fetch(next);
    if (!mounted) return;
    setState(() {
      if (data.isNotEmpty) {
        _items.addAll(data);
        _page = next;
        _hasMore = data.length >= 24;
      } else {
        _hasMore = false;
      }
      _loadingMore = false;
    });
  }

  Future<List<VideoDetail>> _fetch(int page) async {
    final config = ref.read(configServiceProvider);
    final cms = ref.read(cmsServiceProvider);
    final site = await config.getPrimarySite();
    if (site.disabled) return [];
    return cms.getCategoryList(
      site,
      widget.typeId,
      page: page + 1,
      pageSize: 24,
    );
  }

  void _openDetail(VideoDetail video) {
    VideoRouter.open(
      context,
      video,
      categoryTypeId: widget.typeId,
      categoryTitle: widget.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final columns = width >= 600 ? 4 : 3;
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 10,
      mainAxisSpacing: 14,
      childAspectRatio: 0.58,
    );

    return ZenScaffold(
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          ZenSliverAppBar(title: widget.title, subtitle: '来自我的视频库'),
          if (_loading)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => const _SkeletonCard(),
                  childCount: 9,
                ),
              ),
            )
          else if (_items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: Text('暂无内容')),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => GestureDetector(
                    onTap: () => _openDetail(_items[i]),
                    behavior: HitTestBehavior.opaque,
                    child: PosterCard(
                      title: _items[i].title,
                      imageUrl: _items[i].poster,
                      year: _items[i].year,
                      heat: _items[i].heat,
                      width: width / columns,
                      height: width / columns * 1.45,
                    ),
                  ),
                  childCount: _items.length,
                ),
              ),
            ),
          if (_loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.pink),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return Container(
          width: c.maxWidth,
          height: c.maxWidth * 1.45,
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
