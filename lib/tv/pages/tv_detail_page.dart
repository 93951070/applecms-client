import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format_utils.dart';
import '../../models/site.dart';
import '../../pages/home.dart';
import '../../pages/login_page.dart';
import '../../providers/auth_provider.dart';
import '../../providers/history_provider.dart';
import '../../services/cms_service.dart';
import '../../services/config_service.dart';
import '../../widgets/watch_party_sheet.dart';
import '../tv_focus.dart';
import '../tv_router.dart';
import '../tv_theme.dart';
import 'tv_player_page.dart';
import 'tv_search_page.dart';

/// TV 版详情页：全幅剧照背景 + 左侧信息区 + 选集宫格 + 同类推荐。
class TvDetailPage extends ConsumerStatefulWidget {
  const TvDetailPage({super.key, required this.video, this.subjectId});

  final VideoDetail video;
  final String? subjectId;

  @override
  ConsumerState<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends ConsumerState<TvDetailPage> {
  /// 每 30 集一个模块，与腾讯视频一致：先选区间再选集。
  static const int _episodesPerModule = 30;

  late VideoDetail _video;
  bool _loading = true;
  int _episodePage = 0;
  bool _episodePagePinned = false;

  @override
  void initState() {
    super.initState();
    _video = widget.video;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String get _detailId => widget.subjectId ?? widget.video.id;

  Future<void> _load() async {
    final id = _detailId;
    if (id.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final cms = ref.read(cmsServiceProvider);
    final cached = cms.cachedDetail(id);
    if (cached != null && mounted) {
      setState(() {
        _video = cached;
        _loading = false;
      });
    }
    try {
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final fresh = await cms.getDetail(site, id);
      if (mounted && fresh != null) {
        setState(() {
          _video = fresh;
          _loading = false;
        });
      }
    } catch (_) {}
    if (mounted && _loading) setState(() => _loading = false);
  }

  PlayGroup? get _group =>
      _video.playGroups.isEmpty ? null : _video.playGroups.first;

  int get _episodeCount {
    final group = _group;
    if (group == null) return 0;
    return group.titles.isNotEmpty ? group.titles.length : group.urls.length;
  }

  /// 与当前条目匹配的播放记录，用于「继续观看」。
  PlayRecord? get _resumeRecord {
    final list = ref.watch(historyProvider).value;
    if (list == null) return null;
    for (final record in list) {
      if (record.doubanId != null && record.doubanId == _detailId) {
        return record;
      }
    }
    return null;
  }

  void _play(int index, {double? resume}) {
    final group = _group;
    if (group == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvPlayerPage(
          video: _video,
          group: group,
          initialIndex: index,
          resumePosition: resume,
        ),
      ),
    );
  }

  /// 打开「一起看」弹层：未登录先去登录，进度从播放记录续起。
  Future<void> _openWatchParty(PlayRecord? resume) async {
    final video = _video;
    if (video.id.isEmpty) return;
    if (!ref.read(authProvider).isLoggedIn) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const LoginPage()));
      return;
    }
    await showWatchPartyHome(
      context,
      ref,
      vodId: video.id,
      episode: resume?.index ?? 0,
      positionMs: ((resume?.playTime ?? 0) * 1000).round(),
    );
  }

  List<({String label, bool locked})> _episodeEntries() {
    final group = _group;
    if (group == null) return const [];
    final titles = group.titles;
    final count = titles.isNotEmpty ? titles.length : group.urls.length;
    final out = <({String label, bool locked})>[];
    for (var i = 0; i < count; i++) {
      final label = i < titles.length && titles[i].isNotEmpty
          ? titles[i]
          : '第 ${i + 1} 集';
      final locked = i < group.needVip.length && group.needVip[i] > 0;
      out.add((label: label, locked: locked));
    }
    return out;
  }

  /// 选集区：集数多时先展示区间模块，只渲染当前模块内的集数宫格。
  Widget _buildEpisodes(
    PlayRecord? resume,
    List<({String label, bool locked})> episodes,
  ) {
    final total = episodes.length;
    final modules = (total + _episodesPerModule - 1) ~/ _episodesPerModule;
    final preferred =
        !_episodePagePinned && resume != null && resume.index < total
        ? resume.index ~/ _episodesPerModule
        : _episodePage;
    final page = modules <= 1 ? 0 : preferred.clamp(0, modules - 1).toInt();
    final start = page * _episodesPerModule;
    final end = math.min(start + _episodesPerModule, total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (modules > 1) ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var module = 0; module < modules; module++)
                TvChip(
                  label:
                      '${module * _episodesPerModule + 1}-'
                      '${math.min((module + 1) * _episodesPerModule, total)}',
                  selected: module == page,
                  onSelect: () => setState(() {
                    _episodePage = module;
                    _episodePagePinned = true;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = start; i < end; i++)
                TvChip(
                  label: episodes[i].label,
                  locked: episodes[i].locked,
                  selected: resume != null && resume.index == i,
                  onSelect: () => _play(i),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final backdrop = (_video.heroImage ?? '').isNotEmpty
        ? _video.heroImage!
        : _video.poster;
    return Scaffold(
      backgroundColor: TvColors.bgDeep,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              placeholder: (_, __) => const SizedBox.shrink(),
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            )
          else
            const DecoratedBox(
              decoration: BoxDecoration(gradient: TvGradients.page),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: TvGradients.heroLeftScrim),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: TvGradients.heroBottomScrim),
          ),
          SafeArea(bottom: false, child: _buildContent(size)),
        ],
      ),
    );
  }

  Widget _buildContent(Size size) {
    final resume = _resumeRecord;
    final episodes = _episodeEntries();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.safeH,
        TvMetrics.safeV,
        TvMetrics.safeH,
        48,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: size.height - TvMetrics.safeV * 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: size.height * 0.14),
            _buildTitleBlock(),
            const SizedBox(height: 26),
            _buildActions(resume, episodes.isNotEmpty),
            if (episodes.isNotEmpty) ...[
              const SizedBox(height: 34),
              const TvSectionHeader(title: '选集', icon: LucideIcons.layoutGrid),
              const SizedBox(height: 4),
              _buildEpisodes(resume, episodes),
            ] else if (_loading) ...[
              const SizedBox(height: 34),
              const Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: TvColors.accent,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 40),
            _buildRecommend(),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBlock() {
    final meta = <String>[];
    final year = _video.year ?? '';
    if (year.isNotEmpty) meta.add(year);
    final typeName = _video.typeName ?? '';
    if (typeName.isNotEmpty) meta.add(typeName);
    if (_video.heat > 0) meta.add('热度 ${formatCount(_video.heat)}');
    if (_episodeCount > 0) meta.add('共 $_episodeCount 集');
    final desc = _video.desc ?? '';
    final actors = _video.actors ?? '';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: TvMetrics.heroTitle,
              fontWeight: FontWeight.w800,
              color: TvColors.text1,
              height: 1.15,
              shadows: [Shadow(color: Colors.black87, blurRadius: 18)],
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              meta.join('   ·   '),
              style: const TextStyle(
                fontSize: TvMetrics.heroMeta,
                color: TvColors.text2,
              ),
            ),
          ],
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              desc,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: TvMetrics.body,
                color: TvColors.text2,
                height: 1.6,
              ),
            ),
          ],
          if (actors.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '主演：$actors',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: TvColors.text3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(PlayRecord? resume, bool hasSource) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        if (resume != null)
          TvActionButton(
            label: '继续观看 第 ${resume.index + 1} 集',
            icon: LucideIcons.play,
            primary: true,
            autofocus: true,
            onSelect: () =>
                _play(resume.index, resume: resume.playTime.toDouble()),
          )
        else
          TvActionButton(
            label: '立即播放',
            icon: LucideIcons.play,
            primary: true,
            autofocus: true,
            onSelect: hasSource ? () => _play(0) : null,
          ),
        if (resume != null)
          TvActionButton(
            label: '从头播放',
            icon: LucideIcons.rotateCcw,
            onSelect: hasSource ? () => _play(0) : null,
          ),
        TvActionButton(
          label: '一起看',
          icon: LucideIcons.users,
          onSelect: hasSource ? () => _openWatchParty(resume) : null,
        ),
        TvActionButton(
          label: '搜索',
          icon: LucideIcons.search,
          onSelect: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const TvSearchPage())),
        ),
        TvActionButton(
          label: '返回',
          icon: LucideIcons.chevronLeft,
          onSelect: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildRecommend() {
    if (_video.typeId <= 0) return const SizedBox.shrink();
    final async = ref.watch(cmsCategoryProvider(_video.typeId));
    final items = (async.value ?? const <VideoDetail>[])
        .where((v) => v.id != _video.id)
        .take(14)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return TvRow(
      title: '同类推荐',
      icon: LucideIcons.sparkles,
      children: [
        for (final v in items)
          TvPosterCard(
            title: v.title,
            imageUrl: v.poster,
            year: v.year,
            heat: v.heat,
            onSelect: () => TvRouter.open(context, v, replace: true),
          ),
      ],
    );
  }
}
