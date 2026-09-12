import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/video_router.dart';
import '../models/site.dart';
import '../providers/favorites_provider.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';

/// 我的收藏：来自本地持久化的 [Favorite] 列表。
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(favoritesProvider);
    final items = async.value ?? const <Favorite>[];

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(title: '我的收藏', subtitle: '追剧列表'),
          if (async.isLoading && items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('还没有收藏，去详情页点个星标吧')),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _FavoriteTile(
                    favorite: items[index],
                    onTap: () => _open(context, ref, items[index]),
                    onRemove: () => ref
                        .read(favoritesProvider.notifier)
                        .remove(items[index].subjectId, items[index].searchTitle),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, Favorite favorite) {
    final title = favorite.searchTitle.isNotEmpty
        ? favorite.searchTitle
        : favorite.title;
    VideoRouter.openByTitle(
      context,
      ref,
      title: title,
      cover: favorite.cover,
      year: favorite.year,
      subjectId: favorite.subjectId,
    );
  }
}

class _FavoriteTile extends StatelessWidget {
  final Favorite favorite;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteTile({
    required this.favorite,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onRemove,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 74,
                  height: 100,
                  child: favorite.cover.isNotEmpty
                      ? CoverImage(imageUrl: favorite.cover)
                      : Container(color: AppColors.pinkLight),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      favorite.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (favorite.year.isNotEmpty) favorite.year,
                        if (favorite.totalEpisodes > 0)
                          '共${favorite.totalEpisodes}集',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.star_rounded,
                    color: AppColors.vipGold, size: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
