import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';
import '../models/site.dart';
import '../models/movie.dart';
import '../providers/auth_provider.dart';
import '../providers/history_provider.dart';
import '../services/config_service.dart';
import '../widgets/zen_ui.dart';
import '../widgets/appad_widgets.dart';
import '../widgets/cover_image.dart';
import 'video_detail.dart';
import 'messages_page.dart';

final profileSiteProvider = FutureProvider<SiteConfig>((ref) async {
  return ref.read(configServiceProvider).getPrimarySite();
});

/// 我的：用户信息头 + VIP 横幅 + 观看历史 + 快捷入口 + 更多应用
/// 会员信息对接网站 /api/auth/*、/api/user/* 接口
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  static const _quick = [
    (Icons.star_rounded, Color(0xFFFF4D4F), Color(0xFFFFEEF0), '我的收藏'),
    (Icons.download_rounded, Color(0xFFFF8A00), Color(0xFFFFF3E6), '离线缓存'),
    (Icons.reply_rounded, Color(0xFF3B82F6), Color(0xFFEAF3FF), '分享好友'),
    (Icons.rate_review_outlined, Color(0xFFFF4D4F), Color(0xFFFFEEF0), '意见反馈'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final siteAsync = ref.watch(profileSiteProvider);
    final historyAsync = ref.watch(historyProvider);
    final siteName = siteAsync.maybeWhen(
      data: (s) => s.name,
      orElse: () => '未配置',
    );

    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _buildUserHeader(context, ref, siteName),
            _buildVipBanner(context, ref),
            SectionHead(
              icon: const Icon(Icons.history_rounded,
                  size: 18, color: AppColors.pink),
              title: '观看历史',
              moreText: '更多',
              onMore: () => _showHistoryActions(context, ref),
            ),
            _buildHistory(context, ref, historyAsync),
            _buildQuickEntries(context),
            SectionHead(
              icon: const Icon(Icons.widgets_outlined,
                  size: 18, color: AppColors.pink),
              title: '更多应用',
            ),
            _buildAppCells(context, ref),
            _buildAccountSection(context, ref),
          ],
        ),
      ),
    );
  }

  // ==================== 用户信息头 ====================

  Widget _buildUserHeader(
      BuildContext context, WidgetRef ref, String siteName) {
    final theme = Theme.of(context);
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final loggedIn = auth.isLoggedIn;
    final name = loggedIn ? (user?.displayName ?? '用户') : '点击登录';
    final uid = user != null && user.id.isNotEmpty
        ? user.id
        : (user?.userName ?? '未登录');
    final portrait = user?.portrait ?? '';
    final isVip = loggedIn && (user?.isVip ?? false);

    void onTapHeader() {
      if (!loggedIn) context.push('/login');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Row(
        children: [
          GestureDetector(
            onTap: onTapHeader,
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFC9D6FF), Color(0xFFFFD9F2)],
                ),
                border: Border.all(color: const Color(0xFFFFE4EE), width: 2),
                image: portrait.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(portrait), fit: BoxFit.cover)
                    : null,
              ),
              child: portrait.isEmpty
                  ? const Icon(Icons.pets, size: 34, color: Color(0xFF7A8AA8))
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: GestureDetector(
              onTap: onTapHeader,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w800)),
                      ),
                      if (loggedIn) ...[
                        const SizedBox(width: 6),
                        Icon(
                          isVip
                              ? Icons.workspace_premium_rounded
                              : Icons.person_rounded,
                          size: 18,
                          color: isVip
                              ? AppColors.vipGold
                              : theme.colorScheme.secondary,
                        ),
                        if (isVip) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                  colors: [Color(0xFFFFB84D), Color(0xFFFF7A00)]),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(user?.vipLabel ?? 'VIP',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5)),
                          ),
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    loggedIn
                        ? 'UID: $uid · 视频源：$siteName'
                        : '登录后同步会员权益 · 视频源：$siteName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: theme.colorScheme.secondary),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              context.push('/messages');
            },
            icon: Builder(builder: (context) {
              final unread =
                  ref.watch(unreadMessageCountProvider).maybeWhen(
                        data: (v) => v,
                        orElse: () => 0,
                      );
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.notifications_none_rounded,
                      size: 23, color: theme.colorScheme.secondary),
                  if (unread > 0)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        constraints:
                            const BoxConstraints(minWidth: 15, minHeight: 15),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF4D4F),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
          IconButton(
            onPressed: () => context.push('/settings'),
            icon: Icon(Icons.settings_outlined,
                size: 22, color: theme.colorScheme.secondary),
          ),
        ],
      ),
    );
  }

  // ==================== VIP 横幅 ====================

  Widget _buildVipBanner(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final loggedIn = auth.isLoggedIn;
    final isVip = loggedIn && (user?.isVip ?? false);

    final String title;
    final String subtitle;
    if (!loggedIn) {
      title = '开通会员';
      subtitle = '登录后可兑换卡密、同步会员权益';
    } else if (isVip) {
      title = user?.vipLabel ?? 'VIP会员';
      subtitle =
          '到期时间 ${_formatDate(user?.vipEndTime)} · 积分 ${user?.points ?? 0}';
    } else {
      title = '尚未开通会员';
      subtitle = '积分 ${user?.points ?? 0} · 兑换卡密即可开通';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: [0, 0.6, 1],
            colors: [Color(0xFF2A2B33), Color(0xFF3A3348), Color(0xFF4A3352)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -20,
              top: -30,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.vipGold.withValues(alpha: 0.25),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.7],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.workspace_premium_rounded,
                        size: 20, color: AppColors.vipGold),
                    const SizedBox(width: 8),
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(subtitle,
                    style: const TextStyle(
                        color: Color(0xFFB9B9C2), fontSize: 11)),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => loggedIn
                      ? _sponsor(context, ref)
                      : context.push('/login'),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [Color(0xFFFF7EB0), AppColors.pink]),
                      borderRadius: BorderRadius.circular(15),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.pink.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Text(isVip ? '续费会员' : '立即赞助',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '未知';
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _sponsor(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = await ref.read(authProvider.notifier).buyCardUrl();
    if (url == null || url.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('暂未配置购买链接')));
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('无法打开购买链接')));
    }
  }

  Future<void> _openOfficialSite(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    final uri = Uri.tryParse(base);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('无法打开网站')));
    }
  }

  Future<void> _redeemCard(BuildContext context, WidgetRef ref) async {
    if (!ref.read(authProvider).isLoggedIn) {
      context.push('/login');
      return;
    }
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卡密兑换'),
        content: TextField(
          controller: controller,
          maxLength: 10,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: '请输入 10 位卡密'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('兑换', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(authProvider.notifier).redeemCard(code);
    messenger.showSnackBar(SnackBar(
      content: Text(result.message),
      backgroundColor: result.success ? null : AppColors.yearRed,
    ));
  }

  Widget _buildAccountSection(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(authProvider).isLoggedIn;
    if (!loggedIn) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
        child: ZenButton(
          height: 46,
          backgroundColor: AppColors.pink,
          onPressed: () => context.push('/login'),
          child: const Text('登录 / 注册',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: ZenButton(
        height: 46,
        isSecondary: true,
        onPressed: () => _confirmLogout(context, ref),
        child: Text('退出登录',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface)),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(authProvider.notifier).logout();
            },
            child: const Text('退出', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
  }

  // ==================== 观看历史 ====================

  Widget _buildHistory(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<PlayRecord>> historyAsync,
  ) {
    final history = historyAsync.value ?? const <PlayRecord>[];
    if (history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('还没有观看记录',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.secondary)),
      );
    }
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: history.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final record = history[i];
          return _HistoryCard(
            record: record,
            onTap: () {
              final subject = DoubanSubject(
                id: record.doubanId ?? '',
                title: record.searchTitle,
                rate: '0.0',
                cover: record.cover,
                year: record.year,
              );
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                builder: (context) => VideoDetailPage(subject: subject),
              ));
            },
            onLongPress: () =>
                ref.read(historyProvider.notifier).removeRecord(record.searchTitle),
          );
        },
      ),
    );
  }

  void _showHistoryActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.pink),
              title: const Text('清空观看记录'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmClearHistory(context, ref);
              },
            ),
            ListTile(
              leading: Icon(Icons.close,
                  color: Theme.of(context).colorScheme.secondary),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(historyProvider.notifier).clearHistory();
              Navigator.pop(ctx);
            },
            child: const Text('清空',
                style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
  }

  // ==================== 快捷入口四宫格 ====================

  Widget _buildQuickEntries(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Row(
        children: [
          for (final (icon, iconColor, bgColor, label) in _quick)
            Expanded(
              child: _QuickItem(
                icon: icon,
                iconColor: iconColor,
                bgColor: bgColor,
                label: label,
                onTap: () => _comingSoon(context, label),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== 更多应用 ====================

  Widget _buildAppCells(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
      child: Row(
        children: [
          Expanded(
            child: _AppCell(
              icon: Icons.card_giftcard_rounded,
              iconColor: const Color(0xFF8B5CF6),
              bgColor: const Color(0xFFF3ECFF),
              label: '卡密兑换',
              onTap: () => _redeemCard(context, ref),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _AppCell(
              icon: Icons.public_rounded,
              iconColor: const Color(0xFF3B82F6),
              bgColor: const Color(0xFFE8F5FF),
              label: '官方网站',
              onTap: () => _openOfficialSite(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  void _comingSoon(BuildContext context, String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name 敬请期待'),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}

/// 观看历史卡片（横版缩略图 + 时间戳 + 进度条）
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.record,
    required this.onTap,
    required this.onLongPress,
  });

  final PlayRecord record;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  String get _time {
    final s = record.playTime;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        record.totalTime > 0 ? record.playTime / record.totalTime : 0.0;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 118,
                height: 74,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (record.cover.isNotEmpty)
                      CoverImage(imageUrl: record.cover, aspectRatio: 118 / 74)
                    else
                      const ColoredBox(color: Color(0xFF3A3A44)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.5, 1.0],
                          colors: [Colors.transparent, Color(0x99000000)],
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(_time,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 9)),
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
                            Container(color: Colors.white.withValues(alpha: 0.3)),
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
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快捷入口（图标 + 标签）
class _QuickItem extends StatelessWidget {
  const _QuickItem({
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 22, color: iconColor),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface)),
        ],
      ),
    );
  }
}

/// 应用入口卡片（卡密兑换 / 官方网站）
class _AppCell extends StatelessWidget {
  const _AppCell({
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C171B) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
