import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/site.dart';
import 'app_api_service.dart';
import 'config_service.dart';

final cmsServiceProvider = Provider((ref) => CmsService(ref));

/// CMS 分类节点（type_id / type_name / type_pid）
class CmsCategory {
  final int typeId;
  final String typeName;
  final int typePid;

  const CmsCategory({
    required this.typeId,
    required this.typeName,
    this.typePid = 0,
  });
}

/// 主分类及其子分类
class CmsCategoryGroup {
  final CmsCategory category;
  final List<CmsCategory> subCategories;

  const CmsCategoryGroup({
    required this.category,
    this.subCategories = const [],
  });
}

/// 无法取得站点分类树时的兜底分类（与后端默认数据一致）
const defaultCategoryGroups = <CmsCategoryGroup>[
  CmsCategoryGroup(category: CmsCategory(typeId: 1, typeName: '电影')),
  CmsCategoryGroup(category: CmsCategory(typeId: 2, typeName: '连续剧')),
  CmsCategoryGroup(category: CmsCategory(typeId: 3, typeName: '动漫')),
  CmsCategoryGroup(category: CmsCategory(typeId: 4, typeName: '综艺')),
];

/// 站点数据服务。
///
/// 所有请求均通过 App 加密网关 `/api/app/v1` 完成，不再直接访问明文
/// 的 `/api/provide/vod`。直连播放地址仅在调用 `/play` 时由服务端下发。
class CmsService {
  final Ref _ref;

  CmsService(this._ref);

  Future<String> _base() => _ref.read(configServiceProvider).getApiBaseUrl();

  AppApiService get _api => _ref.read(appApiServiceProvider);

  Future<List<VideoDetail>> search(SiteConfig site, String query,
      {int page = 1}) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        keyword: query,
        limit: 20,
      );
      return _listFromItems(data['items'], site);
    } catch (_) {
      return [];
    }
  }

  /// 按分类拉取列表（顶级分类由服务端聚合子分类）
  Future<List<VideoDetail>> getCategoryList(
    SiteConfig site,
    int typeId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        limit: pageSize,
        typeId: '$typeId',
      );
      return _listFromItems(data['items'], site);
    } catch (_) {
      return [];
    }
  }

  /// 获取站点分类树（主分类 + 子分类），经加密网关返回。
  Future<List<CmsCategoryGroup>> getCategoryTree(SiteConfig site) async {
    try {
      final hierarchy = await _api.categories(await _base());
      final groups = <CmsCategoryGroup>[];
      for (final entry in hierarchy) {
        final rawCategory = entry['category'];
        if (rawCategory is! Map) continue;
        final subs = <CmsCategory>[];
        final rawSubs = entry['sub_categories'];
        if (rawSubs is List) {
          for (final s in rawSubs) {
            if (s is Map) {
              subs.add(_categoryFromJson(Map<String, dynamic>.from(s)));
            }
          }
        }
        groups.add(CmsCategoryGroup(
          category: _categoryFromJson(Map<String, dynamic>.from(rawCategory)),
          subCategories: subs,
        ));
      }
      groups.sort((a, b) => a.category.typeId.compareTo(b.category.typeId));
      return groups;
    } catch (_) {
      return [];
    }
  }

  Future<VideoDetail?> getDetail(SiteConfig site, String id) async {
    if (id.trim().isEmpty) return null;
    try {
      final data = await _api.videoDetail(await _base(), id.trim());
      final detail = _detailFromGateway(data, site);
      if (detail.playGroups.isEmpty) return null;
      return detail;
    } catch (_) {
      return null;
    }
  }

  List<VideoDetail> _listFromItems(dynamic items, SiteConfig site) {
    if (items is! List) return [];
    final results = <VideoDetail>[];
    for (final item in items) {
      if (item is! Map) continue;
      results.add(_listEntryToDetail(Map<String, dynamic>.from(item), site));
    }
    return results;
  }

  VideoDetail _listEntryToDetail(Map<String, dynamic> item, SiteConfig site) {
    return VideoDetail(
      id: (item['vod_id'] ?? '').toString(),
      title: (item['vod_name'] ?? '').toString().trim(),
      poster: (item['vod_pic'] ?? '').toString(),
      playGroups: const [],
      source: site.key,
      sourceName: site.name,
      year: item['vod_year']?.toString(),
      desc: '',
      typeName: item['type_name']?.toString(),
    );
  }

  VideoDetail _detailFromGateway(Map<String, dynamic> data, SiteConfig site) {
    final sources = data['play_sources'];
    final groups = <PlayGroup>[];
    if (sources is List) {
      for (final s in sources) {
        if (s is! Map) continue;
        final titles = <String>[];
        final eps = s['episodes'];
        if (eps is List) {
          for (final e in eps) {
            if (e is Map) titles.add((e['name'] ?? '').toString());
          }
        }
        if (titles.isEmpty) continue;
        groups.add(PlayGroup(
          name: (s['source_name'] ?? '').toString(),
          // 直连地址由网关在取流时逐集下发，此处仅占位保持集数索引
          urls: List<String>.filled(titles.length, ''),
          titles: titles,
        ));
      }
    }
    return VideoDetail(
      id: (data['vod_id'] ?? '').toString(),
      title: (data['vod_name'] ?? '').toString().trim(),
      poster: (data['vod_pic'] ?? '').toString(),
      playGroups: groups,
      source: site.key,
      sourceName: site.name,
      year: data['vod_year']?.toString(),
      desc: (data['vod_content'] ?? '')
          .toString()
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim(),
      typeName: data['type_name']?.toString(),
    );
  }

  CmsCategory _categoryFromJson(Map<String, dynamic> json) {
    return CmsCategory(
      typeId: _asInt(json['type_id']),
      typeName: (json['type_name'] ?? '').toString().trim(),
      typePid: _asInt(json['type_pid']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
