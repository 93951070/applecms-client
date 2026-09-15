import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/site.dart';
import '../pages/short_drama_feed.dart';
import '../pages/video_detail.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import '../widgets/page_flip.dart';
import 'content_kind.dart';

/// 统一的视频打开入口。
///
/// 短剧分类进入竖屏 Feed，其余内容进入常规详情页。所有入口（首页、分类、
/// 排行榜、搜索、推荐、播放记录、收藏）都应经过这里，避免各自复制跳转逻辑。
class VideoRouter {
  const VideoRouter._();

  /// 打开一个已知的 CMS 条目。
  ///
  /// [replace] 为 true 时用 `pushReplacement`，防止详情页之间层层压栈导致返回时
  /// 旧页面无法回收。[subjectId] 可覆盖传给详情页的条目 ID（留空时取 [video].id，
  /// 详情页据此拉取播放源）。[categoryTypeId]/[categoryTitle] 用于分类列表页，
  /// 以当前浏览的分类而非条目自身分类来判定是否进入 Feed。
  static void open(
    BuildContext context,
    VideoDetail video, {
    bool replace = false,
    String? subjectId,
    int? categoryTypeId,
    String? categoryTitle,
  }) {
    final nav = Navigator.of(context, rootNavigator: true);
    final feedTypeId = categoryTypeId ?? video.typeId;
    final feedTitle = categoryTitle ?? video.typeName;
    if (isFeedCategory(typeId: feedTypeId, typeName: feedTitle)) {
      final title = (feedTitle ?? '').trim();
      final route = _route(ShortDramaFeedPage(
        typeId: feedTypeId > 0 ? feedTypeId : kShortDramaTypeId,
        categoryTitle: title.isNotEmpty ? title : '短剧',
        initial: video,
      ));
      if (replace) {
        nav.pushReplacement(route);
      } else {
        nav.push(route);
      }
      return;
    }

    final subject = DoubanSubject(
      id: subjectId ?? video.id,
      title: video.title,
      rate: '0.0',
      cover: video.poster,
      year: video.year,
      description: video.desc,
    );
    final route = _route(VideoDetailPage(subject: subject));
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
  }

  /// 播放记录/收藏只保存了标题，点击时先回源解析，识别出短剧则进入 Feed；
  /// 其余情况沿用按标题的豆瓣匹配（保持原有详情页行为）。
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
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final resolved = _pickBest(await cms.search(site, query), query);
      if (!context.mounted) return;
      if (resolved != null &&
          isFeedCategory(
              typeId: resolved.typeId, typeName: resolved.typeName)) {
        open(context, resolved);
        return;
      }
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).push(_route(VideoDetailPage(
      subject: DoubanSubject(
        id: subjectId ?? '',
        title: title,
        rate: '0.0',
        cover: cover,
        year: year,
      ),
    )));
  }

  /// 从搜索结果里挑出最贴近标题的一条。
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

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_·:：()（）【】\[\]]'), '');

  static PageRoute<void> _route(Widget child) =>
      FlipPageRoute<void>(builder: (_) => child);
}
