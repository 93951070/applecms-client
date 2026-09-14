import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/content_kind.dart';
import 'cms_service.dart';
import 'config_service.dart';

final preloadServiceProvider = Provider((ref) => PreloadService(ref));

/// 启动预热：把首屏需要的分类树、首页聚合、主分类列表提前拉一遍，
/// 让用户进入首页时直接从缓存渲染。
class PreloadService {
  final Ref _ref;

  PreloadService(this._ref);

  Future<void> warmUp() async {
    try {
      final cms = _ref.read(cmsServiceProvider);
      final config = _ref.read(configServiceProvider);
      final site = await config.getPrimarySite();
      if (site.disabled) return;

      final tree = await cms.getCategoryTree(site);
      final ids = tree
          .where((g) => !isFeedCategory(
                typeId: g.category.typeId,
                typeName: g.category.typeName,
              ))
          .map((g) => g.category.typeId)
          .toList();
      if (ids.isEmpty) return;

      // 首屏聚合（首页推荐页）
      unawaited(cms.getHomeFeed(site, ids, limit: 18, heroLimit: 6));

      // 顶部前 4 个主分类列表，并发预热
      unawaited(Future.wait(
        ids
            .take(4)
            .map((id) => cms.getCategoryList(site, id, page: 1, pageSize: 18)),
      ));
    } catch (_) {
      // 预热失败不影响启动。
    }
  }
}
