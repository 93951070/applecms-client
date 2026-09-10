import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/site.dart';

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

class CmsService {
  final Ref _ref;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
    },
  ));

  CmsService(this._ref);

  Future<List<VideoDetail>> search(SiteConfig site, String query, {int page = 1}) async {
    try {
      final url = '${site.api}?ac=videolist&wd=${Uri.encodeComponent(query)}&pg=$page';
      final response = await _dio.get(url);

      if (response.data == null) {
        return [];
      }

      // Web 平台兼容：确保 data 是 Map
      Map<String, dynamic> data;
      if (response.data is String) {
        try {
          data = jsonDecode(response.data);
        } catch (e) {
          return [];
        }
      } else if (response.data is Map) {
        data = Map<String, dynamic>.from(response.data);
      } else {
        return [];
      }

      // 兼容性处理：list 字段可能是数组或字符串
      final listData = data['list'];
      if (listData == null) {
        return [];
      }

      // 如果 list 是字符串，尝试解析为 JSON
      List list;
      if (listData is String) {
        try {
          final decoded = jsonDecode(listData);
          if (decoded is List) {
            list = decoded;
          } else {
            return [];
          }
        } catch (e) {
          return [];
        }
      } else if (listData is List) {
        list = listData;
      } else {
        return [];
      }

      final List<VideoDetail> results = [];

      for (var item in list) {
        try {
          final detail = _parseVideoItem(item, site);
          if (detail.playGroups.isNotEmpty) {
            results.add(detail);
          }
        } catch (e) {
          // Skip invalid items
        }
      }

      // 第一页请求成功后，如果是搜索且有多页，全并发抓取后续页
      if (page == 1) {
        try {
          final pageCountData = data['pagecount'];
          if (pageCountData != null) {
            int pageCount = 1;
            if (pageCountData is int) {
              pageCount = pageCountData;
            } else if (pageCountData is String) {
              pageCount = int.tryParse(pageCountData) ?? 1;
            }

            if (pageCount > 1) {
              int limit = pageCount > 3 ? 3 : pageCount;
              final futures = <Future<List<VideoDetail>>>[];
              for (int i = 2; i <= limit; i++) {
                futures.add(search(site, query, page: i));
              }
              final moreResults = await Future.wait(futures);
              for (var extra in moreResults) {
                results.addAll(extra);
              }
            }
          }
        } catch (e) {
          // Ignore pagination errors
        }
      }
      return results;
    } catch (e) {
      return [];
    }
  }

  /// 按分类拉取列表（顶级分类自动聚合子分类）
  Future<List<VideoDetail>> getCategoryList(SiteConfig site, int typeId, {int page = 1, int pageSize = 20}) async {
    return _fetchCategoryBySite(site, typeId, page: page, pageSize: pageSize);
  }

  Future<List<VideoDetail>> _fetchCategoryBySite(SiteConfig site, int typeId, {int page = 1, int pageSize = 20}) async {
    try {
      final url = '${site.api}?ac=videolist&t=$typeId&pg=$page&pagesize=$pageSize';
      final response = await _dio.get(url);
      if (response.data == null) {
        return [];
      }

      Map<String, dynamic> data;
      if (response.data is String) {
        try {
          data = jsonDecode(response.data);
        } catch (e) {
          return [];
        }
      } else if (response.data is Map) {
        data = Map<String, dynamic>.from(response.data);
      } else {
        return [];
      }

      final listData = data['list'];
      if (listData == null) {
        return [];
      }

      List list;
      if (listData is String) {
        try {
          final decoded = jsonDecode(listData);
          list = decoded is List ? decoded : [];
        } catch (e) {
          return [];
        }
      } else if (listData is List) {
        list = listData;
      } else {
        return [];
      }

      final List<VideoDetail> results = [];
      for (var item in list) {
        try {
          final detail = _parseVideoItem(item, site);
          if (detail.playGroups.isNotEmpty) {
            results.add(detail);
          }
        } catch (e) {
          // Skip invalid items
        }
      }
      return results;
    } catch (e) {
      return [];
    }
  }

  /// 获取站点分类树（主分类 + 子分类）。
  /// 优先读取本站 `/api/categories/hierarchy`，失败时回退标准 AppleCMS `ac=list` 的 `class` 字段。
  Future<List<CmsCategoryGroup>> getCategoryTree(SiteConfig site) async {
    final groups = await _fetchHierarchy(site);
    if (groups.isNotEmpty) return groups;
    return _fetchAppleCmsClasses(site);
  }

  Future<List<CmsCategoryGroup>> _fetchHierarchy(SiteConfig site) async {
    try {
      final uri = Uri.tryParse(site.api);
      if (uri == null || uri.scheme.isEmpty || uri.authority.isEmpty) return [];
      final url = '${uri.scheme}://${uri.authority}/api/categories/hierarchy';
      final response = await _dio.get(url);
      final data = _asMap(response.data);
      if (data == null) return [];
      final hierarchy = data['hierarchy'];
      if (hierarchy is! List) return [];

      final groups = <CmsCategoryGroup>[];
      for (final entry in hierarchy) {
        if (entry is! Map) continue;
        final rawCategory = entry['category'];
        if (rawCategory is! Map) continue;
        final category =
            _categoryFromJson(Map<String, dynamic>.from(rawCategory));
        final subs = <CmsCategory>[];
        final rawSubs = entry['sub_categories'];
        if (rawSubs is List) {
          for (final s in rawSubs) {
            if (s is Map) {
              subs.add(_categoryFromJson(Map<String, dynamic>.from(s)));
            }
          }
        }
        groups.add(CmsCategoryGroup(category: category, subCategories: subs));
      }
      groups.sort((a, b) => a.category.typeId.compareTo(b.category.typeId));
      return groups;
    } catch (e) {
      return [];
    }
  }

  Future<List<CmsCategoryGroup>> _fetchAppleCmsClasses(SiteConfig site) async {
    try {
      final url = '${site.api}?ac=list';
      final response = await _dio.get(url);
      final data = _asMap(response.data);
      if (data == null) return [];
      final rawClass = data['class'];
      if (rawClass is! List) return [];

      final mains = <CmsCategory>[];
      final subsByPid = <int, List<CmsCategory>>{};
      for (final item in rawClass) {
        if (item is! Map) continue;
        final category = _categoryFromJson(Map<String, dynamic>.from(item));
        if (category.typePid == 0) {
          mains.add(category);
        } else {
          subsByPid.putIfAbsent(category.typePid, () => []).add(category);
        }
      }
      mains.sort((a, b) => a.typeId.compareTo(b.typeId));
      return mains
          .map((m) => CmsCategoryGroup(
                category: m,
                subCategories: subsByPid[m.typeId] ?? const [],
              ))
          .toList();
    } catch (e) {
      return [];
    }
  }

  CmsCategory _categoryFromJson(Map<String, dynamic> json) {
    return CmsCategory(
      typeId: _asInt(json['type_id']),
      typeName: (json['type_name'] ?? '').toString().trim(),
      typePid: _asInt(json['type_pid']),
    );
  }

  static Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<VideoDetail?> getDetail(SiteConfig site, String id) async {
    try {
      final url = '${site.api}?ac=videolist&ids=$id';
      final response = await _dio.get(url);

      if (response.data == null) return null;

      // Web 平台兼容：确保 data 是 Map
      Map<String, dynamic> data;
      if (response.data is String) {
        try {
          data = jsonDecode(response.data);
        } catch (e) {
          return null;
        }
      } else if (response.data is Map) {
        data = Map<String, dynamic>.from(response.data);
      } else {
        return null;
      }

      // 兼容性处理：list 字段可能是数组或字符串
      final listData = data['list'];
      if (listData == null) return null;

      List list;
      if (listData is String) {
        try {
          list = jsonDecode(listData) as List;
        } catch (e) {
          return null;
        }
      } else if (listData is List) {
        list = listData;
      } else {
        return null;
      }

      if (list.isEmpty) return null;

      return _parseVideoItem(list[0], site);
    } catch (e) {
      return null;
    }
  }

  VideoDetail _parseVideoItem(Map<String, dynamic> item, SiteConfig site) {
    List<PlayGroup> playGroups = [];
    final String playFrom = (item['vod_play_from'] ?? '').toString();
    final String playUrl = (item['vod_play_url'] ?? '').toString();

    if (playFrom.isNotEmpty && playUrl.isNotEmpty) {
      final froms = playFrom.split('\$\$\$');
      final urlsGroups = playUrl.split('\$\$\$');

      for (int i = 0; i < froms.length; i++) {
        if (i >= urlsGroups.length) break;
        List<String> urls = [];
        List<String> titles = [];
        final episodesList = urlsGroups[i].split('#');
        for (var ep in episodesList) {
          final parts = ep.split('\$');
          if (parts.length == 2) {
            titles.add(parts[0].trim());
            urls.add(parts[1].trim());
          } else if (parts.length == 1 && parts[0].isNotEmpty) {
            titles.add('正片');
            urls.add(parts[0].trim());
          }
        }
        if (urls.isNotEmpty) {
          playGroups.add(PlayGroup(name: froms[i], urls: urls, titles: titles));
        }
      }
    }

    // 单个资源条目下只选取最长的一条线路
    if (playGroups.isNotEmpty) {
      playGroups.sort((a, b) => b.urls.length.compareTo(a.urls.length));
      playGroups = [playGroups.first];
    }

    return VideoDetail(
      id: item['vod_id'].toString(),
      title: (item['vod_name'] ?? '').toString().trim(),
      poster: item['vod_pic'] ?? '',
      playGroups: playGroups,
      source: site.key,
      sourceName: site.name,
      year: item['vod_year']?.toString(),
      desc: (item['vod_content'] ?? '').toString().replaceAll(RegExp(r'<[^>]*>'), '').trim(),
      typeName: item['type_name'],
    );
  }
}
