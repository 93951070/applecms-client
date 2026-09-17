import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/site.dart';
import '../../services/cms_service.dart';
import '../../services/config_service.dart';
import '../tv_focus.dart';
import '../tv_grid.dart';
import '../tv_router.dart';
import '../tv_theme.dart';

/// TV 版搜索页：屏幕键盘输入 + 历史 + 结果网格。
class TvSearchPage extends ConsumerStatefulWidget {
  const TvSearchPage({super.key, this.showBack = true});

  /// 作为独立页面打开时显示返回键；嵌在 TV 外壳的 Tab 里时隐藏。
  final bool showBack;

  @override
  ConsumerState<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends ConsumerState<TvSearchPage> {
  static const int _pageSize = 30;
  static const String _historyKey = 'search_history';
  static const List<List<String>> _keyRows = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
    ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
  ];

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<VideoDetail> _results = const [];
  List<String> _history = const [];
  bool _loading = false;
  bool _hasMore = false;
  int _page = 0;
  String _submitted = '';

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_historyKey) ?? const <String>[];
    if (mounted) setState(() => _history = list);
  }

  Future<void> _saveHistory(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_historyKey) ?? <String>[];
    list.remove(query);
    list.insert(0, query);
    if (list.length > 15) list.removeRange(15, list.length);
    await prefs.setStringList(_historyKey, list);
    if (mounted) setState(() => _history = List<String>.from(list));
  }

  Future<void> _search(String raw, {int page = 1, bool append = false}) async {
    final query = raw.trim();
    if (query.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      if (!append) {
        _results = const [];
        _page = 0;
        _submitted = query;
      }
    });
    try {
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final result = await cms.searchPaged(
        site,
        query,
        page: page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _results = append ? [..._results, ...result.items] : result.items;
        _hasMore = result.hasMore;
        _page = page;
        _loading = false;
      });
      if (!append) await _saveHistory(query);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _loadMore() {
    if (!_hasMore || _loading || _submitted.isEmpty) return;
    _search(_submitted, page: _page + 1, append: true);
  }

  void _type(String ch) {
    _controller.text = _controller.text + ch;
    setState(() {});
  }

  void _backspace() {
    final text = _controller.text;
    if (text.isEmpty) return;
    _controller.text = text.substring(0, text.length - 1);
    setState(() {});
  }

  void _clearAll() {
    _controller.text = '';
    setState(() {
      _results = const [];
      _submitted = '';
      _hasMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.bgDeep,
      resizeToAvoidBottomInset: false,
      body: Container(
        decoration: const BoxDecoration(gradient: TvGradients.page),
        child: SafeArea(
          child: Column(
            children: [
              _buildSearchBar(),
              Expanded(child: _buildBody()),
              _buildKeyboard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final hasText = _controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.safeH,
        TvMetrics.safeV,
        TvMetrics.safeH,
        12,
      ),
      child: Row(
        children: [
          if (widget.showBack) ...[
            TvActionButton(
              label: '返回',
              icon: LucideIcons.chevronLeft,
              onSelect: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: TvColors.surface,
                borderRadius: BorderRadius.circular(TvMetrics.radiusPill),
                border: Border.all(color: TvColors.divider),
              ),
              child: Row(
                children: [
                  const Icon(
                    LucideIcons.search,
                    size: 20,
                    color: TvColors.text3,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      hasText ? _controller.text : '输入片名、演员或导演',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TvMetrics.body,
                        color: hasText ? TvColors.text1 : TvColors.text3,
                      ),
                    ),
                  ),
                  if (hasText)
                    GestureDetector(
                      onTap: _clearAll,
                      child: const Icon(
                        LucideIcons.x,
                        size: 18,
                        color: TvColors.text3,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          TvActionButton(
            label: '搜索',
            icon: LucideIcons.search,
            primary: true,
            onSelect: () => _search(_controller.text),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_submitted.isEmpty && _results.isEmpty) {
      if (_history.isEmpty) {
        return const Center(
          child: Text(
            '用遥控器在下方键盘输入关键词',
            style: TextStyle(fontSize: TvMetrics.body, color: TvColors.text3),
          ),
        );
      }
      return SingleChildScrollView(
        padding: TvMetrics.safePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TvSectionHeader(title: '搜索历史', icon: LucideIcons.history),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final query in _history)
                  TvChip(
                    label: query,
                    onSelect: () {
                      _controller.text = query;
                      _search(query);
                    },
                  ),
              ],
            ),
          ],
        ),
      );
    }
    if (_loading && _results.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.accent),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          '没有找到相关内容',
          style: TextStyle(fontSize: TvMetrics.body, color: TvColors.text3),
        ),
      );
    }
    return TvGrid(
      controller: _scroll,
      itemCount: _results.length,
      itemBuilder: (context, index, width) {
        final video = _results[index];
        return TvPosterCard(
          width: width,
          title: video.title,
          imageUrl: video.poster,
          year: video.year,
          heat: video.heat,
          onSelect: () => TvRouter.open(context, video),
        );
      },
    );
  }

  Widget _buildKeyboard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.safeH,
        8,
        TvMetrics.safeH,
        TvMetrics.safeV,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in _keyRows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final key in row)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TvChip(
                        label: key,
                        width: 64,
                        onSelect: () => _type(key),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TvChip(label: '清空', width: 100, onSelect: _clearAll),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TvChip(label: '删除', width: 100, onSelect: _backspace),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TvChip(
                  label: '搜索',
                  width: 100,
                  selected: true,
                  onSelect: () => _search(_controller.text),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
