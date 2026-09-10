import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/system_message.dart';
import '../services/cms_service.dart';
import '../widgets/zen_ui.dart';

/// 个人中心消息角标未读数。
final unreadMessageCountProvider = FutureProvider<int>((ref) async {
  final page = await ref.watch(cmsServiceProvider).getMessages(limit: 1);
  return page.unread;
});

/// 系统消息页：展示禁言/封号等通知，支持标记已读。
class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  List<SystemMessage> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(cmsServiceProvider).getMessages(limit: 50);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '消息加载失败';
      });
    }
  }

  Future<void> _markRead(SystemMessage msg) async {
    if (msg.read) return;
    try {
      await ref.read(cmsServiceProvider).markMessageRead(msg.id);
      ref.invalidate(unreadMessageCountProvider);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((m) => m.id == msg.id
                ? SystemMessage(
                    id: m.id,
                    title: m.title,
                    content: m.content,
                    kind: m.kind,
                    read: true,
                    createdAt: m.createdAt,
                  )
                : m)
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    try {
      await ref.read(cmsServiceProvider).markAllMessagesRead();
    } catch (_) {}
    ref.invalidate(unreadMessageCountProvider);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          ZenSliverAppBar(
            title: '系统消息',
            subtitle: '禁言封号与系统通知',
            actions: [
              if (_items.any((m) => !m.read))
                IconButton(
                  tooltip: '全部已读',
                  onPressed: _markAllRead,
                  icon: const Icon(Icons.done_all),
                ),
            ],
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary)),
                    const SizedBox(height: 10),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            )
          else if (_items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('暂无消息')),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildCard(_items[index]),
                  childCount: _items.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(SystemMessage msg) {
    final theme = Theme.of(context);
    final isBan = msg.kind == 'ban';
    final isMute = msg.kind == 'mute';
    final accent = isBan
        ? const Color(0xFFFF4D4F)
        : (isMute ? const Color(0xFFFF8A00) : AppColors.pink);
    final icon = isBan
        ? Icons.block
        : (isMute ? Icons.volume_off_rounded : Icons.notifications_none_rounded);

    return GestureDetector(
      onTap: () => _markRead(msg),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: msg.read ? Colors.transparent : accent.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          msg.title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (!msg.read)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    msg.content,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  if (msg.createdAt > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      _formatTime(msg.createdAt),
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.secondary
                              .withValues(alpha: 0.7)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}
