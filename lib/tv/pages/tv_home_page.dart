import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format_utils.dart';
import '../../models/site.dart';
import '../../pages/home.dart';
import '../../services/cms_service.dart';
import '../tv_focus.dart';
import '../tv_router.dart';
import '../tv_theme.dart';
import 'tv_list_page.dart';

/// TV 版首页：顶部焦点大海报轮播 + 各分类横滑内容行。
class TvHomePage extends ConsumerStatefulWidget {
  const TvHomePage({super.key});

  @override
  ConsumerState<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends ConsumerState<TvHomePage> {
  Timer? _heroTimer;
  int _heroIndex = 0;
  int _heroLength = 0;

  @override
  void initState() {
    super.initState();
    _heroTimer = Timer.periodic(TvMetrics.heroInterval, (_) {
      if (!mounted || _heroLength <= 1) return;
      setState(() => _heroIndex = (_heroIndex + 1) % _heroLength);
    });
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    super.dispose();
  }

  List<VideoDetail> _heroItems(HomeFeed? feed) {
    if (feed != null && feed.hero.isNotEmpty) {
      return feed.hero.take(6).toList();
    }
    if (feed != null && feed.sections.isNotEmpty) {
      return feed.sections.first.items.take(6).toList();
    }
    return const [];
  }

  List<HomeSection> _sections(HomeFeed? feed, List<CmsCategoryGroup> groups) {
    if (feed != null && feed.sections.isNotEmpty) {
      return feed.sections.take(8).toList();
    }
    final out = <HomeSection>[];
    for (final group in groups) {
      final typeId = group.category.typeId;
      if (typeId <= 0) continue;
      final items = ref.watch(cmsCategoryProvider(typeId)).value;
      if (items == null || items.isEmpty) continue;
      out.add(
        HomeSection(
          typeId: typeId,
          title: group.category.typeName,
          items: items.take(18).toList(),
        ),
      );
    }
    return out;
  }

  void _openList(int typeId, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvListPage(typeId: typeId, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(homeFeedProvider);
    final feed = feedAsync.value;
    final groups =
        ref.watch(categoryTreeProvider).value ?? const <CmsCategoryGroup>[];
    final hero = _heroItems(feed);
    _heroLength = hero.length;
    final sections = _sections(feed, groups);

    if (feedAsync.isLoading &&
        feed == null &&
        hero.isEmpty &&
        sections.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.accent),
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(),
      children: [
        if (hero.isNotEmpty) _buildHero(hero),
        const SizedBox(height: 10),
        for (final section in sections) ...[
          TvRow(
            title: section.title,
            icon: LucideIcons.film,
            moreText: '更多',
            onMore: section.typeId > 0
                ? () => _openList(section.typeId, section.title)
                : null,
            children: [
              for (final video in section.items)
                TvPosterCard(
                  title: video.title,
                  imageUrl: video.poster,
                  year: video.year,
                  heat: video.heat,
                  onSelect: () => TvRouter.open(context, video),
                ),
            ],
          ),
          const SizedBox(height: 26),
        ],
      ],
    );
  }

  Widget _buildHero(List<VideoDetail> items) {
    final video = items[_heroIndex % items.length];
    final size = MediaQuery.sizeOf(context);
    final backdrop = (video.heroImage ?? '').isNotEmpty
        ? video.heroImage!
        : video.poster;
    // 幻灯片占满导航栏以下的绝大部分首屏，露出下一行的一角提示可下翻。
    final available = size.height - TvMetrics.navHeight;
    final bannerHeight = available * 0.82;

    return SizedBox(
      height: bannerHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: TvMetrics.heroFade,
            child: backdrop.isNotEmpty
                ? CachedNetworkImage(
                    key: ValueKey(video.id),
                    imageUrl: backdrop,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    placeholder: (_, __) => const SizedBox.shrink(),
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  )
                : const DecoratedBox(
                    key: ValueKey('placeholder'),
                    decoration: BoxDecoration(gradient: TvGradients.page),
                  ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: TvGradients.heroLeftScrim),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: TvGradients.heroBottomScrim),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TvMetrics.safeH,
              0,
              TvMetrics.safeH,
              TvMetrics.safeV,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_heroTag(video) != null) ...[
                        _buildHeroTag(_heroTag(video)!),
                        const SizedBox(height: 14),
                      ],
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: TvMetrics.heroTitle,
                          fontWeight: FontWeight.w800,
                          color: TvColors.text1,
                          height: 1.1,
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 18),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _heroMeta(video),
                        style: const TextStyle(
                          fontSize: TvMetrics.heroMeta,
                          color: TvColors.text2,
                        ),
                      ),
                      if ((video.desc ?? '').isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          video.desc!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: TvMetrics.body,
                            color: TvColors.text2,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    TvActionButton(
                      label: '立即播放',
                      icon: LucideIcons.play,
                      primary: true,
                      autofocus: true,
                      onSelect: () => TvRouter.open(context, video),
                    ),
                    const SizedBox(width: 14),
                    TvActionButton(
                      label: '详情',
                      icon: LucideIcons.info,
                      onSelect: () => TvRouter.open(context, video),
                    ),
                    const Spacer(),
                    if (items.length > 1) _buildDots(items.length),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 幻灯片右上角的粉底角标文案（分类名，缺省为热播）。
  String? _heroTag(VideoDetail video) {
    final typeName = video.typeName ?? '';
    if (typeName.isNotEmpty) return typeName;
    if (video.heat > 0) return '热播';
    return null;
  }

  Widget _buildHeroTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        gradient: TvGradients.brand,
        borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  String _heroMeta(VideoDetail video) {
    final parts = <String>[];
    final year = video.year ?? '';
    if (year.isNotEmpty) parts.add(year);
    final typeName = video.typeName ?? '';
    if (typeName.isNotEmpty) parts.add(typeName);
    if (video.heat > 0) parts.add('热度 ${formatCount(video.heat)}');
    final group = video.playGroups.isEmpty ? null : video.playGroups.first;
    if (group != null && group.titles.isNotEmpty) {
      parts.add('共 ${group.titles.length} 集');
    }
    return parts.join('   ·   ');
  }

  Widget _buildDots(int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _heroIndex ? 26 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == _heroIndex
                  ? TvColors.accent
                  : Colors.white.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
