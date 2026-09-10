import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../services/download_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/zen_ui.dart';
import 'offline_player_page.dart';

/// 离线缓存：查看已缓存/缓存中的视频，支持播放和删除。
class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(downloadsProvider);

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(title: '离线缓存', subtitle: '无网络也能看'),
          if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('还没有缓存的视频')),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _DownloadTile(
                    item: items[index],
                    onPlay: items[index].isDone
                        ? () => Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute(
                                builder: (_) => OfflinePlayerPage(
                                  filePath: items[index].filePath,
                                  title: items[index].title,
                                ),
                              ),
                            )
                        : null,
                    onRemove: () =>
                        ref.read(downloadsProvider.notifier).remove(items[index].id),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final OfflineDownload item;
  final VoidCallback? onPlay;
  final VoidCallback onRemove;

  const _DownloadTile({
    required this.item,
    required this.onPlay,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onPlay,
        onLongPress: onRemove,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 74,
                  height: 100,
                  child: item.cover.isNotEmpty
                      ? CoverImage(imageUrl: item.cover)
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
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _buildStatus(theme),
                  ],
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline,
                    color: Colors.grey, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatus(ThemeData theme) {
    if (item.status == 'downloading') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: item.progress > 0 ? item.progress : null,
            minHeight: 4,
          ),
          const SizedBox(height: 6),
          Text(
            '缓存中 ${(item.progress * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary),
          ),
        ],
      );
    }
    if (item.status == 'failed') {
      return const Text('缓存失败',
          style: TextStyle(fontSize: 12, color: Colors.redAccent));
    }
    return Row(
      children: [
        const Icon(Icons.check_circle, size: 14, color: Colors.green),
        const SizedBox(width: 4),
        Text('已缓存',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary)),
      ],
    );
  }
}
