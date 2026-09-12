import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/video_router.dart';
import '../models/site.dart';
import '../providers/history_provider.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';

/// 播放记录页：展示账号/本机的观看历史，支持续看、删除单条与清空。
class PlayHistoryPage extends ConsumerWidget {
  const PlayHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(historyProvider);
    final items = async.value ?? const <PlayRecord>[];

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          ZenSliverAppBar(
            title: '播放记录',
            subtitle: '继续上次的精彩',
            actions: [
              if (items.isNotEmpty)
                IconButton(
                  tooltip: '清空',
                  onPressed: () => _confirmClear(context, ref),
                  icon: Icon(Icons.delete_outline,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              const SizedBox(width: 8),
            ],
          ),
          if (async.isLoading && items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('还没有播放记录')),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.62,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _HistoryTile(
                    record: items[index],
                    onTap: () => _open(context, ref, items[index]),
                    onRemove: () => _confirmRemove(context, ref, items[index]),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, PlayRecord record) {
    VideoRouter.openByTitle(
      context,
      ref,
      title: record.searchTitle.isNotEmpty ? record.searchTitle : record.title,
      cover: record.cover,
      year: record.year,
      subjectId: record.doubanId,
    );
  }

  void _confirmRemove(BuildContext context, WidgetRef ref, PlayRecord record) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确定删除「${record.title}」的播放记录吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              ref
                  .read(historyProvider.notifier)
                  .removeRecord(record.searchTitle);
              Navigator.pop(ctx);
            },
            child:
                const Text('删除', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空播放记录'),
        content: const Text('确定要清空所有播放记录吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              ref.read(historyProvider.notifier).clearHistory();
              Navigator.pop(ctx);
            },
            child: const Text('清空', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.record,
    required this.onTap,
    required this.onRemove,
  });

  final PlayRecord record;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final progress = record.totalTime > 0
        ? (record.playTime / record.totalTime).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final episode = record.index + 1;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onRemove,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  record.cover.isNotEmpty
                      ? CoverImage(imageUrl: record.cover)
                      : Container(color: AppColors.pinkLight),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.55, 1.0],
                        colors: [Colors.transparent, Color(0x99000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        record.totalEpisodes > 1
                            ? '第$episode集'
                            : (record.year.isNotEmpty ? record.year : '影片'),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 9),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SizedBox(
                      height: 2.5,
                      child: Stack(
                        children: [
                          Container(
                              color: Colors.white.withValues(alpha: 0.3)),
                          FractionallySizedBox(
                            widthFactor: progress.clamp(0.02, 1.0).toDouble(),
                            child: Container(color: AppColors.pink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            record.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
