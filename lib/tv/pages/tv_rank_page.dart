import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/site.dart';
import '../../pages/home.dart';
import '../../services/cms_service.dart';
import '../../services/config_service.dart';
import '../tv_focus.dart';
import '../tv_grid.dart';
import '../tv_router.dart';
import '../tv_theme.dart';

/// TV 版排行榜：分类切换 + 每日热度榜。
class TvRankPage extends ConsumerStatefulWidget {
  const TvRankPage({super.key});

  @override
  ConsumerState<TvRankPage> createState() => _TvRankPageState();
}

class _TvRankPageState extends ConsumerState<TvRankPage> {
  final ScrollController _scroll = ScrollController();
  List<VideoDetail> _items = const [];
  bool _loading = false;
  int _typeId = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(0));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<CmsCategoryGroup> _groups() {
    final tree = ref.read(categoryTreeProvider).value;
    if (tree == null || tree.isEmpty) return defaultCategoryGroups;
    return tree;
  }

  Future<void> _load(int typeId) async {
    final groups = _groups();
    final effective = typeId <= 0 ? groups.first.category.typeId : typeId;
    setState(() {
      _typeId = effective;
      _loading = true;
      _items = const [];
    });
    try {
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final list = await cms.getCategoryList(
        site,
        effective,
        page: 1,
        pageSize: 50,
        sort: 'day',
      );
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
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
              const Icon(LucideIcons.trophy, size: 24, color: TvColors.gold),
              const SizedBox(width: 10),
              const Text(
                '排行榜',
                style: TextStyle(
                  fontSize: TvMetrics.sectionTitle,
                  fontWeight: FontWeight.w700,
                  color: TvColors.text1,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                '按每日热度实时更新',
                style: TextStyle(fontSize: 13, color: TvColors.text3),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      for (var i = 0; i < groups.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: TvChip(
                            label: groups[i].category.typeName,
                            autofocus: i == 0,
                            selected: groups[i].category.typeId == _typeId,
                            onSelect: () => _load(groups[i].category.typeId),
                          ),
                        ),
                    ],
                  ),
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
          '暂无榜单数据',
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
          subtitle: 'NO.${index + 1}',
          imageUrl: video.poster,
          year: video.year,
          heat: video.heat,
          onSelect: () => TvRouter.open(context, video),
        );
      },
    );
  }
}
