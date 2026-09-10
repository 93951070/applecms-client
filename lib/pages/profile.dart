import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';
import '../models/site.dart';
import '../models/movie.dart';
import '../providers/history_provider.dart';
import '../services/config_service.dart';
import '../services/update_service.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/cover_image.dart';
import 'source_manage.dart';
import 'video_detail.dart';

final profileSiteProvider = FutureProvider<SiteConfig>((ref) async {
  return ref.read(configServiceProvider).getPrimarySite();
});

/// 我的：账号/站点卡片 + 观看历史 + 功能入口
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final siteAsync = ref.watch(profileSiteProvider);
    final historyAsync = ref.watch(historyProvider);

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '我的',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _buildHeader(context, ref, siteAsync),
            _buildHistory(context, ref, historyAsync),
            const SizedBox(height: 8),
            _buildEntries(context, ref),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<SiteConfig> siteAsync,
  ) {
    final siteName = siteAsync.maybeWhen(
      data: (s) => s.name,
      orElse: () => '未配置',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ZenGlassContainer(
        borderRadius: 20,
        blur: 24,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFA8C0FF), Color(0xFFFF9AE0)],
                  ),
                ),
                child: const Icon(Icons.pets, size: 26, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'EchoTV',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '视频源：$siteName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => context.push('/settings'),
                icon: Icon(
                  Icons.settings_outlined,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistory(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<PlayRecord>> historyAsync,
  ) {
    final history = historyAsync.value ?? const <PlayRecord>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(
          icon: const Icon(Icons.history, size: 18, color: AppColors.pink),
          title: '观看历史',
          moreText: history.isEmpty ? null : '清空',
          onMore: history.isEmpty
              ? null
              : () => _confirmClearHistory(context, ref),
        ),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '还没有观看记录',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          )
        else
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: history.length,
              itemBuilder: (context, i) {
                final record = history[i];
                return Padding(
                  padding: EdgeInsets.only(
                    right: i == history.length - 1 ? 0 : 12,
                  ),
                  child: _HistoryCard(
                    record: record,
                    onTap: () {
                      final subject = DoubanSubject(
                        id: record.doubanId ?? '',
                        title: record.searchTitle,
                        rate: '0.0',
                        cover: record.cover,
                        year: record.year,
                      );
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (context) =>
                            VideoDetailPage(subject: subject),
                      ));
                    },
                    onDelete: () {
                      ref
                          .read(historyProvider.notifier)
                          .removeRecord(record.searchTitle);
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildEntries(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ZenGlassContainer(
        borderRadius: 18,
        blur: 24,
        child: Column(
          children: [
            _EntryItem(
              icon: Icons.dns_outlined,
              title: '视频源管理',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SourceManagePage()),
              ),
            ),
            _EntryItem(
              icon: Icons.tune,
              title: '偏好设置',
              onTap: () => context.push('/settings'),
            ),
            _EntryItem(
              icon: Icons.system_update_alt,
              title: '检查更新',
              onTap: () =>
                  UpdateService.checkUpdate(context, showNoUpdate: true),
            ),
            _EntryItem(
              icon: Icons.cleaning_services_outlined,
              title: '清空观看记录',
              showDivider: false,
              onTap: () => _confirmClearHistory(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClearHistory(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空观看记录'),
        content: const Text('确定要清空所有观看记录吗？'),
        actions: [
          ZenButton(
            isSecondary: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ZenButton(
            backgroundColor: AppColors.pink,
            onPressed: () {
              ref.read(historyProvider.notifier).clearHistory();
              Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  final PlayRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final progress =
        record.totalTime > 0 ? record.playTime / record.totalTime : 0.0;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 116,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                SizedBox(
                  width: 116,
                  height: 162,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CoverImage(
                      imageUrl: record.cover,
                      aspectRatio: 116 / 162,
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    onTap: onDelete,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          size: 13, color: Colors.white),
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.02, 1.0).toDouble(),
                      minHeight: 3,
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                      valueColor: const AlwaysStoppedAnimation(AppColors.pink),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              record.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '第 ${record.index + 1} 集',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryItem extends StatelessWidget {
  const _EntryItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Icon(icon, size: 20, color: AppColors.pink),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ],
            ),
          ),
          if (showDivider)
            Divider(
              height: 1,
              thickness: 0.5,
              indent: 50,
              color: Theme.of(context).dividerColor,
            ),
        ],
      ),
    );
  }
}
