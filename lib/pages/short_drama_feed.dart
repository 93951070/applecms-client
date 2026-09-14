import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:better_player_plus/better_player_plus.dart';

import '../core/share_utils.dart';
import '../core/theme.dart';
import '../models/site.dart';
import '../providers/auth_provider.dart';
import '../services/app_api_service.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../services/web_sniff_service.dart';
import '../widgets/comment_sheet.dart';

/// 短剧竖屏 Feed：上下滑切集，滑到末尾自动续下一部剧。
///
/// 入口：[initial] 为分类列表点击项（可含剧集分组），[typeId] 用于续集拉取。
class ShortDramaFeedPage extends ConsumerStatefulWidget {
  final int typeId;
  final String categoryTitle;
  final VideoDetail initial;

  /// 随机模式：续集时随机挑选剧集与分页，形成无限随机上下滑。
  final bool random;

  /// 是否显示左上返回按钮（作为 Tab 时不显示）。
  final bool showBack;

  const ShortDramaFeedPage({
    super.key,
    required this.typeId,
    required this.categoryTitle,
    required this.initial,
    this.random = false,
    this.showBack = true,
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

  /// 服务端下发的会员要求（0 免费，非 0 需会员）。是否已解锁需结合用户会员状态。
  /// 详情后台刷新后可能更新，故非 final。
  bool requiresVip;

  _FeedEntry({
    required this.vodId,
    required this.dramaTitle,
    required this.poster,
    required this.episodeLabel,
    required this.playSource,
    required this.playIndex,
    required this.episodeIndex,
    required this.episodeCount,
    this.requiresVip = false,
  });
}

class _ShortDramaFeedPageState extends ConsumerState<ShortDramaFeedPage> {
  final PageController _pageController = PageController();
  final List<_FeedEntry> _entries = [];
  final Map<int, String?> _urlCache = {};
  final Map<int, String?> _msgCache = {};

  /// 直连地址播放需要的 Referer（web嗅探直链取自身 origin）。
  final Map<int, String> _refererCache = {};
  final Random _rng = Random();

  /// 每部剧的详情（简介、年份、演员等），用于底部信息与详情面板。
  final Map<String, VideoDetail> _dramaDetails = {};
  final Set<String> _queuedDramaIds = {};
  final List<VideoDetail> _pendingDramas = [];

  /// 详情后台静默刷新的订阅，用于同步最新选集会员状态。
  StreamSubscription<String>? _detailSub;

  int _current = 0;
  int _listPage = 0;
  bool _listExhausted = false;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _commentsOpen = false;
  bool _liked = false;
  bool _hinted = false;

  @override
  void initState() {
    super.initState();
    _detailSub =
        ref.read(cmsServiceProvider).detailUpdates.listen(_onDetailUpdated);
    _bootstrap();
  }

  @override
  void dispose() {
    _detailSub?.cancel();
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
    unawaited(_ensureAhead());
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
    _dramaDetails[detail.id] = detail;

    final srcIndex = _bestGroupIndex(detail.playGroups);
    final group = detail.playGroups[srcIndex];
    final count = group.urls.length;
    if (count == 0) return false;

    for (var i = 0; i < count; i++) {
      final needsVip = i < group.needVip.length && group.needVip[i] > 0;
      _entries.add(_FeedEntry(
        vodId: detail.id,
        dramaTitle: detail.title,
        poster: detail.poster,
        episodeLabel: i < group.titles.length && group.titles[i].isNotEmpty
            ? group.titles[i]
            : '第${i + 1}集',
        playSource: srcIndex,
        playIndex: i,
        episodeIndex: i,
        episodeCount: count,
        requiresVip: needsVip,
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

  /// 详情后台刷新后，用最新的会员标记更新已展开的选集，避免锁图标滞后。
  void _onDetailUpdated(String id) {
    if (!mounted) return;
    final latest = ref.read(cmsServiceProvider).cachedDetail(id);
    if (latest == null || latest.playGroups.isEmpty) return;
    _dramaDetails[latest.id] = latest;
    final srcIndex = _bestGroupIndex(latest.playGroups);
    final group = latest.playGroups[srcIndex];
    var changed = false;
    for (final entry in _entries) {
      if (entry.vodId != latest.id) continue;
      final needVip = entry.episodeIndex < group.needVip.length &&
          group.needVip[entry.episodeIndex] > 0;
      if (entry.requiresVip != needVip) {
        entry.requiresVip = needVip;
        changed = true;
      }
    }
    if (changed) setState(() {});
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
      var res = await api.play(
        base,
        videoId: entry.vodId,
        playSource: entry.playSource,
        playIndex: entry.playIndex,
        token: token,
      );
      // web嗅探线路：复用与主播放页一致的客户端 WebView 嗅探，
      // 嗅到直链直接播放；失败才回传让服务端换源，不再把「请客户端网页解析」当结果展示。
      var guard = 0;
      while (mounted && res.isWebSniff && guard < 6) {
        guard++;
        final sniffed = await WebSniffService.sniff(res.sniffUrl!);
        if (sniffed != null && sniffed.isNotEmpty) {
          _urlCache[index] = sniffed;
          _refererCache[index] = _originOf(sniffed);
          _msgCache[index] = null;
          if (mounted) setState(() {});
          return;
        }
        final reportSource = res.sourceIndex ?? entry.playSource;
        res = await api.play(
          base,
          videoId: entry.vodId,
          playSource: entry.playSource,
          playIndex: entry.playIndex,
          token: token,
          reportSourceIndex: reportSource,
          reportOutcome: 'fail',
        );
      }
      final url =
          (res.hasAccess && (res.playUrl ?? '').isNotEmpty) ? res.playUrl : null;
      _urlCache[index] = url;
      _refererCache[index] = '';
      _msgCache[index] = url == null
          ? (res.message.isNotEmpty ? res.message : '该内容需要会员权限')
          : null;
    } catch (_) {
      _urlCache[index] = null;
      _msgCache[index] = _msgCache[index] ?? '取流失败，请检查网络后重试';
    }
    if (mounted) setState(() {});
  }

  /// 从直链地址推出 origin，作为播放防盗链的 Referer。
  String _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.host}';
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
      var attempts = 0;
      while (!_listExhausted && _entries.length - _current <= 3) {
        if (widget.random && ++attempts > 12) break;
        final cms = ref.read(cmsServiceProvider);
        final site = await ref.read(configServiceProvider).getPrimarySite();
        final page = widget.random ? 1 + _rng.nextInt(10) : _listPage + 1;
        final list = await cms.getCategoryList(
          site,
          widget.typeId,
          page: page,
          pageSize: 12,
          sort: 'day',
        );
        if (!widget.random) _listPage = page;
        if (list.isEmpty) {
          if (widget.random) continue;
          _listExhausted = true;
          break;
        }
        final pool = widget.random ? (List.of(list)..shuffle(_rng)) : list;
        _pendingDramas.addAll(
          pool.where((v) => !_queuedDramaIds.contains(v.id)),
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
      _hinted = true;
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

  void _jumpTo(int index) {
    if (index < 0 || index >= _entries.length) return;
    _pageController.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final sheetHeight = size.height * 0.52;
    final vipActive = ref.watch(authProvider).user?.isVip ?? false;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: Stack(
              children: [
                _buildFeed(vipActive),
                if (_commentsOpen) _buildDim(),
                if (widget.showBack) _buildBackButton(),
                _buildRightRail(),
                _buildBottomInfo(vipActive),
                _buildSwipeHint(),
              ],
            ),
          ),
          if (_commentsOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: sheetHeight,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 1, end: 0),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                builder: (context, t, child) => FractionalTranslation(
                  translation: Offset(0, t),
                  child: child,
                ),
                child: CommentSheet(
                  key: ValueKey(
                      _entries.isEmpty ? 'empty' : _entries[_current].vodId),
                  vodId: _entries.isEmpty ? '' : _entries[_current].vodId,
                  onClose: () => setState(() => _commentsOpen = false),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 评论面板浮出时给视频压一层暗色，突出面板（视频本身不位移）。
  Widget _buildDim() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _commentsOpen = false),
        child: const ColoredBox(color: Colors.black26),
      ),
    );
  }

  Widget _buildFeed(bool vipActive) {
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
      physics: const PageScrollPhysics(),
      itemCount: _entries.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, i) {
        final entry = _entries[i];
        return _DramaVideoPage(
          key: ValueKey('${entry.vodId}_${entry.playIndex}'),
          entry: entry,
          url: _urlCache[i],
          referer: _refererCache[i],
          isActive: i == _current,
          accessMessage: _msgCache[i],
          locked: entry.requiresVip && !vipActive,
          onUpgrade: _openUpgrade,
          onCompleted: _goNext,
          onRetry: () {
            _urlCache.remove(i);
            _msgCache.remove(i);
            _refererCache.remove(i);
            unawaited(_resolve(i));
          },
        );
      },
    );
  }

  /// 未登录先去登录，已登录引导到"我的"开通/续费会员。
  void _openUpgrade() {
    final loggedIn = ref.read(authProvider).isLoggedIn;
    context.push(loggedIn ? '/profile' : '/login');
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

  Widget _buildSwipeHint() {
    if (_hinted || _commentsOpen || _entries.length <= 1) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 90,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 26),
            Text('上滑看下一集',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildRightRail() {
    return Positioned(
      right: 8,
      bottom: 96,
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
            icon: Icons.video_library_outlined,
            label: '选集',
            onTap: _showEpisodes,
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

  Widget _buildBottomInfo(bool vipActive) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    final e = _entries[_current];
    final detail = _dramaDetails[e.vodId];
    final desc = detail?.desc?.trim() ?? '';
    final locked = e.requiresVip && !vipActive;
    return Positioned(
      left: 14,
      right: 76,
      bottom: 44,
      child: GestureDetector(
        onTap: _showDramaInfo,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              e.dramaTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.pink.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${e.episodeLabel} / 共${e.episodeCount}集',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                if (locked) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _openUpgrade,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFFFFC24B), Color(0xFFFF8A00)]),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock, color: Colors.white, size: 11),
                          SizedBox(width: 3),
                          Text('开通会员观看',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ],
                if (desc.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.info_outline,
                      color: Colors.white70, size: 14),
                  const SizedBox(width: 2),
                  const Text('详情',
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                desc,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.4,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showDramaInfo() {
    if (_entries.isEmpty) return;
    final e = _entries[_current];
    final d = _dramaDetails[e.vodId];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scroll) {
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
              children: [
                Text(
                  e.dramaTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if ((d?.year ?? '').isNotEmpty)
                      _infoChip(d!.year!),
                    if ((d?.typeName ?? '').isNotEmpty) _infoChip(d!.typeName!),
                    _infoChip('共${e.episodeCount}集'),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  (d?.desc?.trim().isNotEmpty ?? false) ? d!.desc! : '暂无简介',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _infoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }

  void _showEpisodes() {
    if (_entries.isEmpty) return;
    final e = _entries[_current];
    final vipActive = ref.read(authProvider).user?.isVip ?? false;
    final indices = <int>[];
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].vodId == e.vodId) indices.add(i);
    }
    if (indices.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (ctx) {
        final sheetHeight = MediaQuery.of(ctx).size.height * 0.6;
        return SafeArea(
          child: SizedBox(
            height: sheetHeight,
            child: Column(
              children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选集 · ${e.dramaTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text('${indices.length} 集',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.5,
                  ),
                  itemCount: indices.length,
                  itemBuilder: (ctx, k) {
                    final idx = indices[k];
                    final active = idx == _current;
                    final locked = _entries[idx].requiresVip && !vipActive;
                    return GestureDetector(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _jumpTo(idx);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? AppColors.pink
                              : const Color(0xFF2A2A2E),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (locked) ...[
                              const Icon(Icons.lock,
                                  color: Color(0xFFFFC24B), size: 10),
                              const SizedBox(width: 2),
                            ],
                            Flexible(
                              child: Text(
                                _entries[idx].episodeLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 单集播放页：自身管理 [BetterPlayerController]，非激活时暂停。
class _DramaVideoPage extends StatefulWidget {
  final _FeedEntry entry;
  final String? url;

  /// 直链播放需要的 Referer（web嗅探直链防盗链）。
  final String? referer;
  final bool isActive;
  final String? accessMessage;

  /// 当前集需会员且用户未开通。
  final bool locked;
  final VoidCallback onUpgrade;
  final VoidCallback onCompleted;
  final VoidCallback onRetry;

  const _DramaVideoPage({
    super.key,
    required this.entry,
    required this.url,
    this.referer,
    required this.isActive,
    required this.accessMessage,
    required this.locked,
    required this.onUpgrade,
    required this.onCompleted,
    required this.onRetry,
  });

  @override
  State<_DramaVideoPage> createState() => _DramaVideoPageState();
}

class _DramaVideoPageState extends State<_DramaVideoPage> {
  BetterPlayerController? _controller;
  String? _loadedUrl;
  bool _initializing = false;
  bool _failed = false;
  bool _completed = false;
  int _syncToken = 0;
  double _aspectRatio = 0;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _DramaVideoPage old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url ||
        widget.referer != old.referer ||
        widget.isActive != old.isActive) {
      _sync();
    }
  }

  @override
  void dispose() {
    _syncToken++;
    _release();
    super.dispose();
  }

  void _sync() {
    final token = ++_syncToken;
    final controller = _controller;
    if (!widget.isActive) {
      _pause();
      return;
    }
    final url = widget.url;
    if (url == null || url.isEmpty) return;

    if (controller != null && _loadedUrl == url) {
      controller.play();
      return;
    }

    _release();
    if (!mounted || token != _syncToken) return;

    setState(() {
      _initializing = true;
      _failed = false;
      _completed = false;
      _aspectRatio = 0;
    });

    final c = BetterPlayerController(
      BetterPlayerConfiguration(
        autoPlay: true,
        fit: BoxFit.contain,
        allowedScreenSleep: false,
        handleLifecycle: false,
        autoDispose: false,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          playerTheme: BetterPlayerTheme.material,
          progressBarPlayedColor: AppColors.pink,
          progressBarBufferedColor: Colors.white30,
          progressBarBackgroundColor: Colors.white24,
          controlBarColor: Colors.transparent,
          loadingColor: AppColors.pink,
          enablePip: false,
          enableFullscreen: false,
          enableOverflowMenu: false,
          enablePlaybackSpeed: false,
          enableSubtitles: false,
          enableQualities: false,
          enableAudioTracks: false,
          enableRetry: false,
          enableMute: true,
          showControlsOnInitialize: false,
          controlsHideTime: const Duration(milliseconds: 600),
        ),
      ),
      betterPlayerDataSource: BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        url,
        headers: {
          if (widget.referer != null && widget.referer!.isNotEmpty) ...{
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
            'Referer': widget.referer!,
          },
        },
      ),
    );
    c.addEventsListener((event) => _onPlayerEvent(event, token));
    if (!mounted || token != _syncToken) {
      c.dispose(forceDispose: true);
      return;
    }
    setState(() {
      _controller = c;
      _loadedUrl = url;
    });
  }

  void _release() {
    final c = _controller;
    _controller = null;
    _loadedUrl = null;
    _aspectRatio = 0;
    if (c != null) {
      try {
        c.dispose(forceDispose: true);
      } catch (_) {}
    }
  }

  void _pause() {
    try {
      _controller?.pause();
    } catch (_) {}
  }

  void _onPlayerEvent(BetterPlayerEvent event, int token) {
    if (!mounted || token != _syncToken) return;
    final c = _controller;
    if (c == null) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        final value = c.videoPlayerController?.value;
        final size = value?.size;
        final aspect = (size != null && size.width > 0 && size.height > 0)
            ? size.width / size.height
            : 0.0;
        setState(() {
          _initializing = false;
          _aspectRatio = aspect;
        });
        break;
      case BetterPlayerEventType.finished:
        _notifyCompleted();
        break;
      case BetterPlayerEventType.exception:
        setState(() {
          _initializing = false;
          _failed = true;
        });
        break;
      case BetterPlayerEventType.progress:
        final value = c.videoPlayerController?.value;
        if (value == null) break;
        // 首帧初始化时尺寸可能还没上报，播放中补齐一次比例。
        if (_aspectRatio <= 0) {
          final size = value.size;
          if (size != null && size.width > 0 && size.height > 0) {
            setState(() => _aspectRatio = size.width / size.height);
          }
        }
        final total = value.duration ?? Duration.zero;
        final ended =
            total > Duration.zero && value.position >= total && !value.isPlaying;
        if (ended) {
          _notifyCompleted();
        } else {
          _completed = false;
        }
        break;
      default:
        break;
    }
  }

  void _notifyCompleted() {
    if (!widget.isActive || _completed) return;
    _completed = true;
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null &&
        !_failed &&
        !_initializing &&
        _aspectRatio > 0;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready) _buildVideo(controller) else _buildPlaceholder(),
        if (widget.accessMessage != null) _buildMessage(widget.accessMessage!),
        if (!ready && _failed) _buildMessage('播放失败', retry: true),
      ],
    );
  }

  Widget _buildVideo(BetterPlayerController controller) {
    final aspect = _aspectRatio;
    // 横屏源等比完整显示（模糊海报补边）；竖屏源按真实比例铺满裁切。
    // 两种都按视频真实比例缩放，不做拉伸。
    if (aspect >= 1) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildBlurredPoster(),
          Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: BetterPlayer(controller: controller),
            ),
          ),
        ],
      );
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: aspect * 1000,
          height: 1000,
          child: BetterPlayer(controller: controller),
        ),
      ),
    );
  }

  Widget _buildBlurredPoster() {
    final poster = widget.entry.poster;
    if (poster.isEmpty) return const ColoredBox(color: Colors.black);
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
      child: Image.network(
        poster,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBlurredPoster(),
        if (_initializing || widget.url == null)
          const Center(
            child: CircularProgressIndicator(color: AppColors.pink),
          ),
      ],
    );
  }

  Widget _buildMessage(String message, {bool retry = false}) {
    final isLock = !retry &&
        (widget.locked || message.contains('会员') || message.contains('VIP'));
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isLock ? Icons.lock_outline : Icons.error_outline,
              color: isLock ? const Color(0xFFFFC24B) : Colors.white70,
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
            if (isLock) ...[
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: widget.onUpgrade,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF8A00),
                  foregroundColor: Colors.white,
                ),
                child: const Text('开通会员观看'),
              ),
            ],
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
          Icon(
            icon,
            color: color,
            size: 32,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}
