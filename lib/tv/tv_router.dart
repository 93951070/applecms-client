import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import 'pages/tv_detail_page.dart';
import 'tv_mode.dart';

/// TV 版跳转入口：统一打开横版详情页。
///
/// 短剧在 TV 上不再走竖屏 Feed，同样按横版详情处理。
class TvRouter {
  const TvRouter._();

  /// 当前是否处于 TV 版 UI。
  static bool active(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    final setting = container.read(tvModeSettingProvider);
    return resolveTvMode(context, setting);
  }

  static void open(
    BuildContext context,
    VideoDetail video, {
    bool replace = false,
    String? subjectId,
  }) {
    final route = MaterialPageRoute<void>(
      builder: (_) => TvDetailPage(video: video, subjectId: subjectId),
    );
    final nav = Navigator.of(context, rootNavigator: true);
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
  }

  /// 只有标题/封面来源（播放历史、收藏）时先回源搜索再打开。
  static Future<void> openByTitle(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String cover,
    required String year,
    String? subjectId,
  }) async {
    final query = title.trim();
    if (query.isNotEmpty) {
      try {
        final cms = ref.read(cmsServiceProvider);
        final site = await ref.read(configServiceProvider).getPrimarySite();
        final list = await cms.search(site, query);
        if (!context.mounted) return;
        final best = _pickBest(list, query);
        if (best != null) {
          open(context, best, subjectId: subjectId);
          return;
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    open(
      context,
      VideoDetail(
        id: subjectId ?? '',
        title: title,
        poster: cover,
        playGroups: const [],
        source: '',
        sourceName: '',
        year: year,
      ),
    );
  }

  static VideoDetail? _pickBest(List<VideoDetail> list, String query) {
    if (list.isEmpty) return null;
    final target = _normalize(query);
    if (target.isEmpty) return list.first;
    for (final v in list) {
      if (_normalize(v.title) == target) return v;
    }
    for (final v in list) {
      final t = _normalize(v.title);
      if (t.contains(target) || target.contains(t)) return v;
    }
    return list.first;
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s\-_·:：()（）【】\[\]]'), '');
}
