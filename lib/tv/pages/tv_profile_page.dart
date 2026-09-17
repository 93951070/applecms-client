import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/site.dart';
import '../../models/user.dart';
import '../../pages/downloads_page.dart';
import '../../pages/favorites_page.dart';
import '../../pages/feedback_page.dart';
import '../../pages/login_page.dart';
import '../../pages/play_history_page.dart';
import '../../pages/settings.dart';
import '../../pages/watch.dart';
import '../../providers/auth_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/history_provider.dart';
import '../tv_focus.dart';
import '../tv_mode.dart';
import '../tv_router.dart';
import '../tv_theme.dart';

/// TV 版「我的」：账号、界面模式、继续观看、收藏与快捷入口。
class TvProfilePage extends ConsumerWidget {
  const TvProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final setting = ref.watch(tvModeSettingProvider);
    final history = ref.watch(historyProvider).value ?? const <PlayRecord>[];
    final favorites = ref.watch(favoritesProvider).value ?? const <Favorite>[];

    return ListView(
      padding: TvMetrics.safePadding,
      physics: const BouncingScrollPhysics(),
      children: [
        _UserCard(user: auth.user),
        const SizedBox(height: 28),
        _ModeSection(
          setting: setting,
          onChanged: (mode) =>
              ref.read(tvModeSettingProvider.notifier).setMode(mode),
        ),
        const SizedBox(height: 28),
        const TvSectionHeader(title: '快捷入口', icon: LucideIcons.layoutGrid),
        _ShortcutSection(context: context),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 12),
          TvRow(
            title: '继续观看',
            icon: LucideIcons.history,
            children: [
              for (final record in history.take(20))
                TvPosterCard(
                  width: TvMetrics.posterWidthSmall,
                  title: record.title,
                  imageUrl: record.cover,
                  subtitle: record.totalEpisodes > 0
                      ? '第${record.index + 1}集 / 共${record.totalEpisodes}集'
                      : '第${record.index + 1}集',
                  onSelect: () => TvRouter.openByTitle(
                    context,
                    ref,
                    title: record.title,
                    cover: record.cover,
                    year: record.year,
                    subjectId: record.doubanId,
                  ),
                ),
            ],
          ),
        ],
        if (favorites.isNotEmpty) ...[
          const SizedBox(height: 12),
          TvRow(
            title: '我的收藏',
            icon: LucideIcons.sparkles,
            children: [
              for (final favorite in favorites.take(20))
                TvPosterCard(
                  width: TvMetrics.posterWidthSmall,
                  title: favorite.title,
                  imageUrl: favorite.cover,
                  subtitle: favorite.year.isEmpty ? null : favorite.year,
                  onSelect: () => TvRouter.openByTitle(
                    context,
                    ref,
                    title: favorite.title,
                    cover: favorite.cover,
                    year: favorite.year,
                    subjectId: favorite.subjectId,
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 40),
      ],
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user});

  final AppUser? user;

  @override
  Widget build(BuildContext context) {
    final portrait = user?.portrait ?? '';
    final hasPortrait = portrait.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.surface,
        borderRadius: BorderRadius.circular(TvMetrics.radiusPanel),
        border: Border.all(color: TvColors.divider),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: TvColors.surfaceHigh,
            backgroundImage: hasPortrait ? NetworkImage(portrait) : null,
            child: hasPortrait
                ? null
                : const Icon(LucideIcons.user, size: 32, color: TvColors.text3),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.displayName ?? '未登录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: TvColors.text1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  user == null
                      ? '登录后可同步收藏与播放记录'
                      : (user!.isVip ? '${user!.vipLabel} 会员' : user!.vipLabel),
                  style: const TextStyle(
                    fontSize: TvMetrics.body,
                    color: TvColors.text2,
                  ),
                ),
              ],
            ),
          ),
          TvActionButton(
            label: user == null ? '登录' : '设置',
            icon: user == null ? LucideIcons.user : LucideIcons.settings,
            primary: user == null,
            onSelect: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    user == null ? const LoginPage() : const SettingsPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSection extends StatelessWidget {
  const _ModeSection({required this.setting, required this.onChanged});

  final TvModeSetting setting;
  final ValueChanged<TvModeSetting> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TvSectionHeader(title: '界面模式', icon: LucideIcons.tv),
        Row(
          children: [
            TvChip(
              label: '自动识别',
              selected: setting == TvModeSetting.auto,
              onSelect: () => onChanged(TvModeSetting.auto),
            ),
            const SizedBox(width: 12),
            TvChip(
              label: 'TV 横屏版',
              selected: setting == TvModeSetting.on,
              onSelect: () => onChanged(TvModeSetting.on),
            ),
            const SizedBox(width: 12),
            TvChip(
              label: '手机版',
              selected: setting == TvModeSetting.off,
              onSelect: () => onChanged(TvModeSetting.off),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShortcutSection extends StatelessWidget {
  const _ShortcutSection({required this.context});

  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    void push(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        TvActionButton(
          label: '播放历史',
          icon: LucideIcons.history,
          onSelect: () => push(const PlayHistoryPage()),
        ),
        TvActionButton(
          label: '我的收藏',
          icon: LucideIcons.sparkles,
          onSelect: () => push(const FavoritesPage()),
        ),
        TvActionButton(
          label: '一起看',
          icon: LucideIcons.users,
          onSelect: () => push(const WatchPage()),
        ),
        TvActionButton(
          label: '离线缓存',
          icon: LucideIcons.download,
          onSelect: () => push(const DownloadsPage()),
        ),
        TvActionButton(
          label: '意见反馈',
          icon: LucideIcons.messageSquare,
          onSelect: () => push(const FeedbackPage()),
        ),
        TvActionButton(
          label: '播放设置',
          icon: LucideIcons.settings,
          onSelect: () => push(const SettingsPage()),
        ),
      ],
    );
  }
}
