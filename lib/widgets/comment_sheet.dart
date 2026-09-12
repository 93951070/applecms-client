import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/comment.dart';
import '../services/cms_service.dart';

/// 评论面板：底部半屏、可滚动加载，视频播放不中断。
///
/// 供短剧竖屏 Feed 与详情页共用。按 [vodId] 绑定，切换剧集请重建 Key。
class CommentSheet extends ConsumerStatefulWidget {
  final String vodId;
  final VoidCallback? onClose;

  const CommentSheet({super.key, required this.vodId, this.onClose});

  @override
  ConsumerState<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends ConsumerState<CommentSheet> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final List<VideoComment> _items = [];

  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 120) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final next = _page + 1;
    try {
      final cms = ref.read(cmsServiceProvider);
      final res = await cms.getComments(widget.vodId, page: next, limit: 20);
      if (!mounted) return;
      setState(() {
        _items.addAll(res.items);
        _total = res.total;
        _page = next;
        _hasMore = res.items.isNotEmpty && _items.length < res.total;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    try {
      final cms = ref.read(cmsServiceProvider);
      final res = await cms.postComment(widget.vodId, text);
      if (!mounted) return;
      _input.clear();
      setState(() {
        if (res.comment != null) _items.insert(0, res.comment!);
        if (!res.pending) _total += 1;
        _sending = false;
      });
      _toast(res.pending ? '评论已提交，等待审核' : '评论成功');
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      _toast('发送失败，请先登录');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(top: Radius.circular(16));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: radius,
            border: const Border(
              top: BorderSide(color: Colors.white24),
            ),
          ),
          child: Column(
            children: [
              _buildHeader(),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: _buildList()),
              _buildInput(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: [
          Text(
            _total > 0 ? '$_total 条评论' : '评论',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: widget.onClose ?? () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: Colors.white70),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_items.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator(color: AppColors.pink)
            : const Text('还没有评论，快来抢沙发',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.pink),
              ),
            ),
          );
        }
        return _CommentTile(comment: _items[i]);
      },
    );
  }

  Widget _buildInput() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: const Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '说点什么...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.12),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.pink),
                  )
                : IconButton(
                    onPressed: _send,
                    icon: const Icon(Icons.send, color: AppColors.pink),
                    tooltip: '发送',
                  ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final VideoComment comment;

  const _CommentTile({required this.comment});

  @override
  Widget build(BuildContext context) {
    final portrait = comment.userPortrait;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xFF3A3A3E),
            backgroundImage: (portrait != null && portrait.isNotEmpty)
                ? NetworkImage(portrait)
                : null,
            child: (portrait == null || portrait.isEmpty)
                ? Text(
                    comment.userName.isNotEmpty
                        ? String.fromCharCode(comment.userName.runes.first)
                        : '用',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.userName,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text(
                  comment.content,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
