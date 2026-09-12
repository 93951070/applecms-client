import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/share_utils.dart';
import '../core/theme.dart';
import '../models/site.dart';
import '../services/app_api_service.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../widgets/comment_sheet.dart';

/// 短剧竖屏 Feed：上下滑切集，滑到末尾自动续下一部剧。
///
/// 入口：[initial] 为分类列表点击项（已含剧集分组），[typeId] 用于续集拉取。
class ShortDramaFeedPage extends ConsumerStatefulWidget {
  final int typeId;
  final String categoryTitle;
  final VideoDetail initial;

  const ShortDramaFeedPage({
    super.key,
    required this.typeId,
    required this.categoryTitle,
    required this.initial,
  });

  @override
  ConsumerState<ShortDramaFeedPage> createState() => _ShortDramaFeedPageState();
}

/// 单集在 Feed 中的条目。
class _FeedEntry {
  final String vodId;
  final String dramaTitle;
  final String poster;
  final String episodeLabel;
  final int playSource;
  final int playIndex;
  final int episodeIndex;
  final int episodeCount;

  const _FeedEntry({
    required this.vodId,
    required this.dramaTitle,
    required this.poster,
    required this.episodeLabel,
    required this.playSource,
    required this.playIndex,
    required this.episodeIndex,
    required this.episodeCount,
  });
}

class _ShortDramaFeedPageState extends ConsumerState<ShortDramaFeedPage> {
  final PageController _pageController = PageController();
  final List<_FeedEntry> _entries = [];
  final Map<int, String?> _urlCache = {};
  final Map<int, String?> _msgCache = {};
  final Set<String> _queuedDramaIds = {};
  final List<VideoDetail> _pendingDramas = [];

  int _current = 0;
  int _listPage = 0;
  bool _listExhausted = false;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _commentsOpen = false;
  bool _liked = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final ok = await _expandDrama(widget.initial);
    if (!mounted) return;
    setState(() => _initialLoading = false);
    if (!ok) {
      setState(() => _msgCache[0] = '短剧加载失败，请稍后重试');
    }
    _prefetchAround(0);
  }

  /// 把一部剧的所有集展开追加到 Feed。
  Future<bool> _expandDrama(VideoDetail entry) async {
    if (_queuedDramaIds.contains(entry.id)) return false;
    _queuedDramaIds.add(entry.id);

    var detail = entry;
    if (detail.playGroups.isEmpty) {
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final fetched = await cms.getDetail(site, entry.id);
      if (fetched != null) detail = fetched;
    }
    if (detail.playGroups.isEmpty) return false;

    final srcIndex = _bestGroupIndex(detail.playGroups);
    final group = detail.playGroups[srcIndex];
    final count = group.urls.length;
    if (count == 0) return false;

    for (var i = 0; i < count; i++) {
      _entries.add(_FeedEntry(
        vodId: detail.id,
        dramaTitle: detail.title,
        poster: detail.poster,
        episodeLabel:
            i < group.titles.length && group.titles[i].isNotEmpty
                ? group.titles[i]
                : '第${i + 1}集',
        playSource: srcIndex,
        playIndex: i,
        episodeIndex: i,
        episodeCount: count,
      ));
    }
    return true;
  }

  int _bestGroupIndex(List<PlayGroup> groups) {
    var best = 0;
    for (var i = 1; i < groups.length; i++) {
      if (groups[i].urls.length > groups[best].urls.length) best = i;
    }
    return best;
  }

  /// 解析某一集的直连地址并缓存。
  Future<void> _resolve(int index) async {
    if (index < 0 || index >= _entries.length) return;
    if (_urlCache.containsKey(index)) return;
    final entry = _entries[index];
    final api = ref.read(appApiServiceProvider);
    final config = ref.read(configServiceProvider);
    try {
      final base = await config.getApiBaseUrl();
      final token = await config.getAuthToken();
      final res = await api.play(
        base,
        videoId: entry.vodId,
        playSource: entry.playSource,
        playIndex: entry.playIndex,
        token: token,
      );
      final url = (res.hasAccess && (res.playUrl ?? '').isNotEmpty)
          ? res.playUrl
          : null;
      _urlCache[index] = url;
      _msgCache[index] = url == null
          ? (res.message.isNotEmpty ? res.message : '该内容需要会员权限')
          : null;
    } catch (_) {
      _urlCache[index] = null;
      _msgCache[index] =
          _msgCache[index] ?? '取流失败，请检查网络后重试';
    }
    if (mounted) setState(() {});
  }

  void _prefetchAround(int center) {
    for (var i = center; i <= center + 2; i++) {
      if (i < _entries.length) unawaited(_resolve(i));
    }
  }

  /// 保证当前集之后至少有 3 集可用，不足则续拉下一部剧。
  Future<void> _ensureAhead() async {
    if (_loadingMore) return;
    if (_entries.length - _current > 3) return;
    setState(() => _loadingMore = true);
    try {
      while (_pendingDramas.isNotEmpty && _entries.length - _current <= 3) {
        await _expandDrama(_pendingDramas.removeAt(0));
      }
      while (!_listExhausted && _entries.length - _current <= 3) {
        final cms = ref.read(cmsServiceProvider);
        final site = await ref.read(configServiceProvider).getPrimarySite();
        final page = _listPage + 1;
        final list = await cms.getCategoryList(
          site,
          widget.typeId,
          page: page,
          pageSize: 12,
          sort: 'day',
        );
        _listPage = page;
        if (list.isEmpty) {
          _listExhausted = true;
          break;
        }
        _pendingDramas.addAll(
          list.where((v) => !_queuedDramaIds.contains(v.id)),
        );
        while (_pendingDramas.isNotEmpty && _entries.length - _current <= 3) {
          await _expandDrama(_pendingDramas.removeAt(0));
        }
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _current = index;
      _liked = false;
    });
    _prefetchAround(index);
    unawaited(_ensureAhead());
  }

  void _goNext() {
    if (_current + 1 < _entries.length) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } else {
      unawaited(_ensureAhead().then((_) {
        if (mounted && _current + 1 < _entries.length) {
          _pageController.nextPage(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
          );
        }
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final videoHeight = _commentsOpen ? size.height * 0.48 : size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
            top: 0,
            left: 0,
            right: 0,
            height: videoHeight,
            child: Stack(
              children: [
                _buildFeed(),
                _buildBackButton(),
                _buildRightRail(),
                _buildBottomInfo(),
              ],
            ),
          ),
          if (_commentsOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: size.height * 0.52,
              child: CommentSheet(
                key: ValueKey(_entries.isEmpty ? 'empty' : _entries[_current].vodId),
                vodId: _entries.isEmpty ? '' : _entries[_current].vodId,
                onClose: () => setState(() => _commentsOpen = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeed() {
    if (_initialLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.pink),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text('暂无短剧内容', style: TextStyle(color: Colors.white70)),
      );
    }
    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      itemCount: _entries.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, i) {
        return _DramaVideoPage(
          key: ValueKey('${_entries[i].vodId}_${_entries[i].playIndex}'),
          entry: _entries[i],
          url: _urlCache[i],
          isActive: i == _current,
          accessMessage: _msgCache[i],
          onCompleted: _goNext,
          onRetry: () {
            _urlCache.remove(i);
            _msgCache.remove(i);
            unawaited(_resolve(i));
          },
        );
      },
    );
  }

  Widget _buildBackButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 6,
      child: Material(
        color: Colors.black38,
        shape: const CircleBorder(),
        child: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.white, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: '返回',
        ),
      ),
    );
  }

  Widget _buildRightRail() {
    return Positioned(
      right: 8,
      bottom: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RailButton(
            icon: _liked ? Icons.favorite : Icons.favorite_border,
            color: _liked ? AppColors.pink : Colors.white,
            label: '点赞',
            onTap: () => setState(() => _liked = !_liked),
          ),
          const SizedBox(height: 18),
          _RailButton(
            icon: Icons.mode_comment_outlined,
            label: '评论',
            onTap: () => setState(() => _commentsOpen = true),
          ),
          const SizedBox(height: 18),
          _RailButton(
            icon: Icons.share_outlined,
            label: '分享',
            onTap: () {
              if (_entries.isEmpty) return;
              final e = _entries[_current];
              shareText(context, '${e.dramaTitle} ${e.episodeLabel}');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomInfo() {
    if (_entries.isEmpty) return const SizedBox.shrink();
    final e = _entries[_current];
    return Positioned(
      left: 14,
      right: 76,
      bottom: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            e.dramaTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.pink.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${e.episodeLabel} / 共${e.episodeCount}集',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单集播放页：自身管理 [VideoPlayerController]，非激活时暂停。
class _DramaVideoPage extends StatefulWidget {
  final _FeedEntry entry;
  final String? url;
  final bool isActive;
  final String? accessMessage;
  final VoidCallback onCompleted;
  final VoidCallback onRetry;

  const _DramaVideoPage({
    super.key,
    required this.entry,
    required this.url,
    required this.isActive,
    required this.accessMessage,
    required this.onCompleted,
    required this.onRetry,
  });

  @override
  State<_DramaVideoPage> createState() => _DramaVideoPageState();
}

class _DramaVideoPageState extends State<_DramaVideoPage> {
  VideoPlayerController? _controller;
  String? _loadedUrl;
  bool _initializing = false;
  bool _failed = false;
  bool _completed = false;
  int _syncToken = 0;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _DramaVideoPage old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url || widget.isActive != old.isActive) {
      _sync();
    }
  }

  @override
  void dispose() {
    _syncToken++;
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    final token = ++_syncToken;
    final controller = _controller;
    if (!widget.isActive) {
      await controller?.pause();
      return;
    }
    final url = widget.url;
    if (url == null || url.isEmpty) return;

    if (controller != null && _loadedUrl == url) {
      if (!controller.value.isPlaying) await controller.play();
      return;
    }

    await _release();
    if (!mounted || token != _syncToken) return;

    setState(() {
      _initializing = true;
      _failed = false;
      _completed = false;
    });

    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      await c.setVolume(1);
      if (!mounted || token != _syncToken) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _loadedUrl = url;
        _initializing = false;
      });
      c.addListener(_onTick);
      await c.play();
    } catch (_) {
      c.removeListener(_onTick);
      await c.dispose();
      if (!mounted || token != _syncToken) return;
      setState(() {
        _initializing = false;
        _failed = true;
      });
    }
  }

  Future<void> _release() async {
    final c = _controller;
    _controller = null;
    _loadedUrl = null;
    if (c != null) {
      c.removeListener(_onTick);
      await c.dispose();
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    if (!v.isInitialized) return;
    final ended = v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying;
    if (ended && widget.isActive && !_completed) {
      _completed = true;
      widget.onCompleted();
    } else if (!ended) {
      _completed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        controller.value.size.width > 0) {
      final size = controller.value.size;
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.entry.poster.isNotEmpty)
          Image.network(
            widget.entry.poster,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
          )
        else
          const ColoredBox(color: Colors.black),
        if (widget.accessMessage != null)
          _buildMessage(widget.accessMessage!)
        else if (_failed)
          _buildMessage('播放失败', retry: true)
        else if (_initializing || widget.url == null)
          const Center(
            child: CircularProgressIndicator(color: AppColors.pink),
          ),
      ],
    );
  }

  Widget _buildMessage(String message, {bool retry = false}) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              retry ? Icons.error_outline : Icons.lock_outline,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            if (retry) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                ),
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Icon(icon, color: color, size: 32, shadows: const [
            Shadow(color: Colors.black54, blurRadius: 6),
          ]),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
