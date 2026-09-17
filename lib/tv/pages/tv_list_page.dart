import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/site.dart';
import '../../services/cms_service.dart';
import '../../services/config_service.dart';
import '../tv_focus.dart';
import '../tv_grid.dart';
import '../tv_router.dart';
import '../tv_theme.dart';

/// TV 版分类列表页：综合/最热切换 + 海报网格 + 滚动加载更多。
class TvListPage extends ConsumerStatefulWidget {
  const TvListPage({super.key, required this.typeId, required this.title});

  final int typeId;
  final String title;

  @override
  ConsumerState<TvListPage> createState() => _TvListPageState();
}

class _TvListPageState extends ConsumerState<TvListPage> {
  static const int _pageSize = 24;

  final ScrollController _scroll = ScrollController();
  List<VideoDetail> _items = const [];
  bool _loading = false;
  bool _hasMore = false;
  int _page = 0;
  int _tab = 0;

  String? get _sort => _tab == 1 ? 'day' : null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      if (_hasMore && !_loading) _fetch(_page + 1);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _items = const [];
      _page = 0;
      _hasMore = false;
    });
    await _fetch(1);
  }

  Future<void> _fetch(int page) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final list = await cms.getCategoryList(
        site,
        widget.typeId,
        page: page,
        pageSize: _pageSize,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() {
        _items = page <= 1 ? list : [..._items, ...list];
        _page = page;
        _hasMore = list.length >= _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TvMetrics.safeH,
            12,
            TvMetrics.safeH,
            0,
          ),
          child: Row(
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: TvMetrics.sectionTitle,
                  fontWeight: FontWeight.w700,
                  color: TvColors.text1,
                ),
              ),
              const SizedBox(width: 24),
              TvChip(
                label: '综合',
                selected: _tab == 0,
                autofocus: true,
                onSelect: () => _selectTab(0),
              ),
              const SizedBox(width: 12),
              TvChip(
                label: '最热',
                selected: _tab == 1,
                onSelect: () => _selectTab(1),
              ),
              const Spacer(),
              if (_loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TvColors.accent,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty) {
      if (_loading) {
        return const Center(
          child: CircularProgressIndicator(color: TvColors.accent),
        );
      }
      return const Center(
        child: Text(
          '暂无内容',
          style: TextStyle(fontSize: TvMetrics.body, color: TvColors.text3),
        ),
      );
    }
    return TvGrid(
      controller: _scroll,
      itemCount: _items.length,
      itemBuilder: (context, index, width) {
        final video = _items[index];
        return TvPosterCard(
          width: width,
          title: video.title,
          imageUrl: video.poster,
          year: video.year,
          heat: video.heat,
          onSelect: () => TvRouter.open(context, video),
        );
      },
    );
  }
}
